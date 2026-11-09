#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : firewall.sh
# 所属目录    : deploy/
# 文件用途    : 为中转机落地上网边界: 放行 uptermd 的 relay 端口, 把管理面 SSH 限到白名单来源, 阻断指标端口的非环回访问
# 架构定位    : 运维网络层; 上游是 deploy/README.md 的防火墙章节, 下游是 ufw 或 nftables 的入站策略
# 核心功能    : 后端探测, 规则生成, 演练输出, 防锁死校验, 应用与持久化, 应用后核对
# 职责边界    : 不改 sshd 配置, 不改云安全组, 不处理出站策略; 后端冲突时只报错不做两种管理器的合并
# 运行环境    : Ubuntu 20.04 及以上, bash 5.x, 以 root 执行, 需已装 ufw 或 nftables 之一
# 依赖关系    : 依赖 ufw 或 nft, systemctl, jq, id, install; 由 deploy/README.md 的防火墙章节调用
#
# 输入        : 均可由同名环境变量预置, 命令行参数优先
#               FW_BACKEND           auto 或 ufw 或 nftables, 默认 auto
#               FW_RELAY_PORT        uptermd 对外端口, 默认 22
#               FW_ADMIN_PORT        管理面 SSH 端口, 默认 22022
#               FW_METRICS_PORT      指标端口, 默认 9100
#               FW_NFT_CONF          nftables 主配置路径, 默认 /etc/nftables.conf
#               FW_NFT_RULESET       规则文件路径, 默认 /etc/uptermd/uptermd-guard.nft
#               FW_DEPLOY_LOG_DIR    日志根目录, 默认 /var/log/uptermd-deploy/logs
# 退出码      : 0 成功或演练完成; 2 参数非法; 3 依赖缺失; 4 防锁死校验未通过; 5 规则应用或持久化失败;
#               130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _log <level> <event> <msg> [extra] -> 0: 追加 JSON Lines 事件
#   _say / _warn_once / _die -> 输出与终止
#   _parse_args -> 0/2: 解析参数
#   _require_root -> 0/4: 校验身份
#   _detect_backend -> 0/2/3: 决定使用 ufw 还是 nftables
#   _check_no_lockout -> 0/4: 确认管理面不会被自身规则切断
#   _ufw_cmd <args...> -> 0/5: 应用或演练一条 ufw 规则
#   _apply_ufw -> 0/5: 按顺序落 ufw 规则并启用
#   _render_nft -> 0: 生成 nftables 规则文件内容
#   _apply_nft -> 0/5: 写入规则, 应用并持久化
#   _verify -> 0/5: 应用后核对关键放行
#   _cleanup -> 0: 清理临时文件

# =========** 常量与默认值 =========**
BACKEND="${FW_BACKEND:-auto}"
RELAY_PORT="${FW_RELAY_PORT:-22}"
ADMIN_PORT="${FW_ADMIN_PORT:-22022}"
METRICS_PORT="${FW_METRICS_PORT:-9100}"
NFT_CONF="${FW_NFT_CONF:-/etc/nftables.conf}"
NFT_RULESET="${FW_NFT_RULESET:-/etc/uptermd/uptermd-guard.nft}"
LOG_DIR="${FW_DEPLOY_LOG_DIR:-/var/log/uptermd-deploy/logs}"
NFT_TABLE="uptermd_guard"
MARK_BEGIN="# BEGIN uptermd-guard (managed by deploy/firewall.sh)"
MARK_LINE="include \"${NFT_RULESET}\""
STORAGE_DIR="${UPTERMD_CONF_DIR:-/etc/uptermd}"

LOGGER="deploy.firewall"
RUN_ID="$(date -u '+%Y%m%d_%H%M%S')_$$"
LOG_FILE=""
APPLY=0
RATE_LIMIT_SSH=0
ALLOW_ADMIN_ANYWHERE=0
ADMIN_CIDRS=()
TMP_DIR=""
CLEANED=0
WARNED=0

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: firewall.sh [选项]

选项:
  --backend <auto|ufw|nftables> 指定后端
  --relay-port <port>           uptermd 对外端口, 默认 22
  --admin-port <port>           管理面 SSH 端口, 默认 22022
  --admin-cidr <cidr>           允许访问管理面的来源网段, 可重复
  --allow-admin-anywhere        管理面不限来源, 仅限临时排障
  --metrics-port <port>         指标端口, 默认 9100
  --rate-limit-ssh              对 relay 端口启用按源限速, 仅 ufw 后端有效
  --nft-conf <path>             nftables 主配置路径
  --nft-ruleset <path>          规则文件路径
  --apply                       实际应用; 缺省只做演练
  -h, --help                    打印本说明
USAGE
}

# =========** 函数 =========**
_warn_once() {
    # 用途: 同次运行只提示一次
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    if (( WARNED == 1 )); then
        return 0
    fi
    WARNED=1
    printf '[WARN] %s\n' "$1" >&2
}

_log() {
    # 用途: 追加一行 JSON Lines 事件
    # 参数: $1 级别; $2 事件; $3 描述; $4 可选 JSON 片段
    # 返回: 无; 退出码: 恒 0; 失败输出: stderr 一次提示
    local level="$1" event="$2" msg="$3" extra="${4:-}" line
    if [[ -z "$extra" ]]; then
        extra='{}'
    fi
    if [[ -z "$LOG_FILE" ]]; then
        return 0
    fi
    if ! line=$(jq -nc \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')" \
        --arg level "$level" --arg logger "$LOGGER" \
        --arg event "$event" --arg msg "$msg" --arg run_id "$RUN_ID" \
        --argjson extra "$extra" \
        '{ts:$ts,level:$level,logger:$logger,event:$event,msg:$msg,run_id:$run_id} + $extra' 2>/dev/null); then
        # 序列化失败由下方统一提示, 这里吞掉 jq 自身报错
        _warn_once "日志序列化失败: event=${event}"
        return 0
    fi
    printf '%s\n' "$line" >>"$LOG_FILE" || _warn_once "日志写入失败: path=${LOG_FILE}"
}

_say() {
    # 用途: 输出人读进度行
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    printf '%s\n' "$1"
}

_die() {
    # 用途: 记录 ERROR 后退出
    # 参数: $1 退出码; $2 事件; $3 描述
    # 返回: 不返回; 退出码: $1
    local code="$1" event="$2" msg="$3"
    _log ERROR "$event" "$msg" \
        "{\"exc_type\":\"FirewallError\",\"exc_msg\":$(jq -Rn --arg v "$msg" '$v'),\"stack\":null}"
    printf '[ERROR] %s\n' "$msg" >&2
    exit "$code"
}

_on_error() {
    # 用途: ERR 钩子, 记录失败命令与行号
    # 参数: $1 退出码; $2 行号; $3 命令
    # 返回: 无; 退出码: 0
    local code="$1" line="$2" cmd="$3"
    set +e   # 钩子内不再触发 ERR, 避免递归
    _log ERROR "firewall.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":$(jq -Rn --arg v "exit=${code} line=${line} cmd=${cmd}" '$v')}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    set -e   # 恢复失败即停
}

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --backend) BACKEND="${2:?缺少 --backend 取值}"; shift 2 ;;
            --relay-port) RELAY_PORT="${2:?缺少 --relay-port 取值}"; shift 2 ;;
            --admin-port) ADMIN_PORT="${2:?缺少 --admin-port 取值}"; shift 2 ;;
            --admin-cidr) ADMIN_CIDRS+=("${2:?缺少 --admin-cidr 取值}"); shift 2 ;;
            --allow-admin-anywhere) ALLOW_ADMIN_ANYWHERE=1; shift ;;
            --metrics-port) METRICS_PORT="${2:?缺少 --metrics-port 取值}"; shift 2 ;;
            --rate-limit-ssh) RATE_LIMIT_SSH=1; shift ;;
            --nft-conf) NFT_CONF="${2:?缺少 --nft-conf 取值}"; shift 2 ;;
            --nft-ruleset) NFT_RULESET="${2:?缺少 --nft-ruleset 取值}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    if [[ "$RELAY_PORT" == "$ADMIN_PORT" ]]; then
        _die 2 "firewall.args.conflict" "relay 端口与管理面端口相同, 需分开: port=${RELAY_PORT}"
    fi
    LOG_FILE="${LOG_DIR}/${RUN_ID}.jsonl"
}

_require_root() {
    # 用途: 校验 root 身份
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    if [[ "$(id -u)" -ne 0 ]]; then
        _die 4 "firewall.not_root" "需要以 root 执行, 当前 uid=$(id -u)"
    fi
}

_detect_backend() {
    # 用途: 决定使用哪个防火墙后端, 并阻止两个管理器并存
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2 或 3; 结果写入 BACKEND
    local ufw_active=0
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw_active=1
        fi
    fi
    if [[ "$BACKEND" == "auto" ]]; then
        if command -v ufw >/dev/null 2>&1; then
            BACKEND="ufw"
        elif command -v nft >/dev/null 2>&1; then
            BACKEND="nftables"
        else
            _die 3 "firewall.backend.missing" "未找到 ufw 或 nft, 无法应用规则"
        fi
    fi
    case "$BACKEND" in
        ufw)
            if ! command -v ufw >/dev/null 2>&1; then
                _die 3 "firewall.backend.missing" "指定了 ufw 后端但命令不存在"
            fi
            ;;
        nftables)
            if ! command -v nft >/dev/null 2>&1; then
                _die 3 "firewall.backend.missing" "指定了 nftables 后端但命令不存在"
            fi
            if (( ufw_active == 1 )); then
                # ufw 自身会写 nft 规则, 两者并存会互相覆盖
                _die 2 "firewall.backend.conflict" "ufw 正在启用, 不能同时使用 nftables 后端; 先 ufw disable 再切换"
            fi
            ;;
        *) _die 2 "firewall.backend.invalid" "不支持的后端: ${BACKEND}" ;;
    esac
    _log INFO "firewall.backend.selected" "已选择后端" "{\"backend\":$(jq -Rn --arg v "$BACKEND" '$v')}"
}

_check_no_lockout() {
    # 用途: 防止规则把运维自己挡在门外
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    local cidr
    if (( ALLOW_ADMIN_ANYWHERE == 1 )); then
        _log WARNING "firewall.admin.open" "管理面不限制来源, 仅应用于临时排障" "{}"
        return 0
    fi
    if (( ${#ADMIN_CIDRS[@]} == 0 )); then
        _die 4 "firewall.admin.no_source" "未提供 --admin-cidr 且未显式 --allow-admin-anywhere, 拒绝应用以免锁死管理面"
    fi
    for cidr in "${ADMIN_CIDRS[@]}"; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            _die 2 "firewall.admin.cidr_invalid" "来源网段格式非法, 仅支持 IPv4: ${cidr}"
        fi
    done
    _log INFO "firewall.admin.restricted" "管理面来源已限定" \
        "{\"cidrs\":$(jq -Rn --arg v "${ADMIN_CIDRS[*]}" '$v')}"
}

_ufw_cmd() {
    # 用途: 执行或演练一条 ufw 规则
    # 参数: 全部为 ufw 子命令与参数
    # 返回: 无; 退出码: 0 或 5
    if (( APPLY == 1 )); then
        if ! ufw "$@"; then
            _die 5 "firewall.ufw.failed" "ufw 规则失败: args=$*"
        fi
        return 0
    fi
    # 演练模式下由 ufw 自身计算规则效果, 不改变系统状态
    if ! ufw --dry-run "$@"; then
        _die 5 "firewall.ufw.dryrun" "ufw 演练失败: args=$*"
    fi
}

_apply_ufw() {
    # 用途: 按顺序落 ufw 规则; 先放行管理面再启用默认拒绝
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    local cidr rule
    _say "--- ufw 规则 (apply=${APPLY}) ---"
    _ufw_cmd default deny incoming
    _ufw_cmd default allow outgoing
    for cidr in "${ADMIN_CIDRS[@]}"; do
        _ufw_cmd allow from "$cidr" to any port "$ADMIN_PORT" proto tcp \
            comment 'uptermd admin ssh'
    done
    if (( ALLOW_ADMIN_ANYWHERE == 1 )); then
        _ufw_cmd allow "$ADMIN_PORT/tcp" comment 'uptermd admin ssh (open)'
    fi
    if (( RATE_LIMIT_SSH == 1 )); then
        rule="limit"
    else
        rule="allow"
    fi
    _ufw_cmd "$rule" "$RELAY_PORT/tcp" comment 'uptermd relay'
    _ufw_cmd deny "$METRICS_PORT/tcp" comment 'uptermd metrics loopback only'
    if (( APPLY == 1 )); then
        # --force 避免交互式确认, 否则脚本会挂在提示上
        if ! ufw --force enable; then
            _die 5 "firewall.ufw.enable" "启用 ufw 失败"
        fi
    else
        _say "演练: 将执行 ufw --force enable"
    fi
    _log INFO "firewall.ufw.applied" "ufw 规则已处理" "{\"apply\":$(( APPLY == 1 ? 1 : 0 ))}"
}

_render_nft() {
    # 用途: 生成 nftables 规则文件内容
    # 参数: $1 目标文件
    # 返回: 无; 退出码: 0
    local cidr_list="" cidr
    for cidr in "${ADMIN_CIDRS[@]}"; do
        if [[ -n "$cidr_list" ]]; then
            cidr_list+=", "
        fi
        cidr_list+="$cidr"
    done
    {
        printf '%s\n' "${MARK_BEGIN}"
        printf '%s\n' '# 主机防火墙只做兜底, 云安全组仍是第一道边界'
        printf 'table inet %s {\n' "$NFT_TABLE"
        printf '  chain input {\n'
        printf '    type filter hook input priority 0; policy accept;\n'
        printf '    iif lo accept\n'
        printf '    ct state established,related accept\n'
        printf '    ct state invalid drop\n'
        printf '    tcp dport %s accept\n' "$RELAY_PORT"
        if [[ -n "$cidr_list" ]]; then
            printf '    ip saddr { %s } tcp dport %s accept\n' "$cidr_list" "$ADMIN_PORT"
            printf '    tcp dport %s drop\n' "$ADMIN_PORT"
        else
            printf '    tcp dport %s accept\n' "$ADMIN_PORT"
        fi
        printf '    tcp dport %s drop\n' "$METRICS_PORT"
        printf '  }\n'
        printf '}\n'
    } >"$1"
}

_apply_nft() {
    # 用途: 写入规则文件, 应用并持久化到 nftables 主配置
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    local tmp="${TMP_DIR}/guard.nft"
    _render_nft "$tmp"
    _say "--- nftables 规则 (apply=${APPLY}) ---"
    cat "$tmp"
    if ! nft --check -f "$tmp"; then
        _die 5 "firewall.nft.syntax" "nftables 规则语法校验失败"
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将写入 ${NFT_RULESET} 并加载"
        _log INFO "firewall.nft.dryrun" "nftables 规则演练完成" "{}"
        return 0
    fi
    install -d -m 0755 -o root -g root "$STORAGE_DIR"
    install -m 0644 -o root -g root "$tmp" "${NFT_RULESET}.tmp.$$" \
        || _die 5 "firewall.nft.write" "写入暂存规则文件失败: path=${NFT_RULESET}"
    mv -f "${NFT_RULESET}.tmp.$$" "$NFT_RULESET" \
        || _die 5 "firewall.nft.write" "替换规则文件失败: path=${NFT_RULESET}"
    # 表不存在时 list 返回非零属预期分支, 此时无需删表
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" || _die 5 "firewall.nft.delete" "删除旧表失败: table=${NFT_TABLE}"
    fi
    nft -f "$NFT_RULESET" || _die 5 "firewall.nft.load" "加载规则失败: path=${NFT_RULESET}"

    if [[ ! -f "$NFT_CONF" ]]; then
        printf '%s\n' '#!/usr/sbin/nft -f' 'flush ruleset' >"$NFT_CONF"
    fi
    if ! grep -qF "$MARK_LINE" "$NFT_CONF"; then
        printf '\n%s\n%s\n' "$MARK_BEGIN" "$MARK_LINE" >>"$NFT_CONF"
    fi
    systemctl enable nftables.service >/dev/null \
        || _die 5 "firewall.nft.enable" "启用 nftables.service 失败"
    systemctl restart nftables.service \
        || _die 5 "firewall.nft.restart" "重启 nftables.service 失败"
    _log INFO "firewall.nft.applied" "nftables 规则已应用并持久化" \
        "{\"ruleset\":$(jq -Rn --arg v "$NFT_RULESET" '$v')}"
}

_verify() {
    # 用途: 应用后核对关键放行与阻断
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    if (( APPLY == 0 )); then
        return 0
    fi
    if [[ "$BACKEND" == "ufw" ]]; then
        if ! ufw status verbose | grep -q "${RELAY_PORT}"; then
            _die 5 "firewall.verify.relay" "核对失败: ufw 未显示 relay 端口放行 port=${RELAY_PORT}"
        fi
    else
        if ! nft list table inet "$NFT_TABLE" | grep -q "dport ${RELAY_PORT}"; then
            _die 5 "firewall.verify.relay" "核对失败: nftables 未显示 relay 端口放行"
        fi
    fi
    _say "核对通过: relay 端口 ${RELAY_PORT} 已放行, 管理面端口 ${ADMIN_PORT} 受来源限制, 指标端口 ${METRICS_PORT} 仅环回"
    _log INFO "firewall.verify.ok" "规则核对通过" "{\"relay_port\":${RELAY_PORT}}"
}

# =========** 清理 =========**
# 钩子先于主流程注册, 保证早期失败也能回收临时目录
_cleanup() {
    # 用途: 删除临时目录, 幂等
    # 参数: 无
    # 返回: 无; 退出码: 0
    if (( CLEANED == 1 )); then
        return 0
    fi
    CLEANED=1
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        if ! rm -rf "${TMP_DIR:?}"; then
            printf '[WARN] 临时目录清理失败: path=%s\n' "$TMP_DIR" >&2
        fi
    fi
    return 0
}

trap '_cleanup' EXIT
trap '_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

# =========** 主流程 =========**
_parse_args "$@"

# 日志目录不可写属降级分支: 提示一次后继续
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    _warn_once "日志目录不可写: path=${LOG_DIR}, 本次仅输出到终端"
    LOG_FILE=""
fi

_require_root
for cmd in jq id install; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        _die 3 "firewall.deps.missing" "依赖命令缺失: ${cmd}"
    fi
done

TMP_DIR="$(mktemp -d)"
_log INFO "firewall.run.started" "开始处理防火墙规则" \
    "{\"apply\":$(( APPLY == 1 ? 1 : 0 )),\"relay_port\":${RELAY_PORT}}"

_detect_backend
_check_no_lockout

if [[ "$BACKEND" == "ufw" ]]; then
    _apply_ufw
else
    _apply_nft
fi
_verify

if (( APPLY == 0 )); then
    _say "以上为演练结果; 确认无误后加 --apply 执行"
fi

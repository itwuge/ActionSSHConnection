#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : rotate-relay-key.sh
# 所属目录    : deploy/
# 文件用途    : 轮换中转端 uptermd 的反连注册标识, 即服务身份密钥; 产出可写入仓库变量 UPTERM_RELAY_KNOWN_HOST 的主机公钥行, 并支持回滚
# 架构定位    : 运维密钥生命周期层; 上游是运维人员手工执行, 下游是 uptermd 服务与仓库变量
# 核心功能    : 活动会话检查, 新密钥生成与校验, 旧密钥归档, 原子替换, 服务重启与就绪核对, 失败自动回滚, 公钥行与指纹输出
# 职责边界    : 不登记任何宿主或访客公钥, 不改白名单文件, 不改防火墙, 不推送仓库变量; 只处理服务身份密钥本身
# 运行环境    : Ubuntu 20.04 及以上, bash 5.x, 以 root 执行, uptermd 由 systemd 托管
# 依赖关系    : 依赖 ssh-keygen, systemctl, curl, jq, install, awk, id; 由 deploy/README.md 的轮换章节调用
#
# 说明        : 该密钥只用于中转服务身份与 known_hosts 防中间人; 中转不校验访客公钥, 门禁默认关闭,
#               因此轮换它不会改变任何准入范围, 只会改变用户侧 known_hosts 需要匹配的公钥行.
#
# 输入        : 均可由同名环境变量预置, 命令行参数优先
#               RK_STATE_DIR     密钥目录, 默认 /var/lib/uptermd
#               RK_KEY_NAME      密钥文件名, 默认 server_key
#               RK_RELAY_HOST    对外域名或地址, 默认 relay.wuge.fun
#               RK_RELAY_PORT    对外端口, 默认 22
#               RK_METRICS_URL   指标地址, 默认 http://127.0.0.1:9100/metrics
#               RK_UNIT          systemd 单元名, 默认 uptermd.service
#               RK_USER          密钥属主, 默认 upterm
#               RK_DEPLOY_LOG_DIR 日志根目录, 默认 /var/log/uptermd-deploy/logs
#               RK_START_WAIT_ATTEMPTS 就绪等待次数, 默认 15
# 退出码      : 0 成功或演练完成; 2 参数非法; 3 依赖缺失; 4 存在活动会话或指标不可用而拒绝轮换;
#               5 密钥生成或校验失败; 6 重启失败但已自动回滚; 7 回滚失败需人工介入; 130/143 中断
# 运行平台    : Linux only

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _log / _say / _warn_once / _die -> 日志与终止
#   _parse_args -> 0/2: 解析参数
#   _require_root -> 0/4: 校验身份
#   _active_sessions -> 0/1: 读取指标中的活动连接数
#   _new_key <dir> -> 0/5: 生成新密钥并校验
#   _archive_current -> 0/7: 归档当前密钥, 输出归档路径
#   _install_key <src> -> 0/7: 原子安装密钥对并设定权限
#   _restart_and_wait -> 0/6: 重启并等待就绪
#   _rollback <archive> -> 0/7: 用归档恢复并重启
#   _print_known_hosts <pub> -> 0: 输出公钥行与指纹
#   _cleanup -> 0: 清理临时目录

# =========** 常量与默认值 =========**
STATE_DIR="${RK_STATE_DIR:-/var/lib/uptermd}"
KEY_NAME="${RK_KEY_NAME:-server_key}"
RELAY_HOST="${RK_RELAY_HOST:-relay.wuge.fun}"
RELAY_PORT="${RK_RELAY_PORT:-22}"
METRICS_URL="${RK_METRICS_URL:-http://127.0.0.1:9100/metrics}"
UNIT_NAME="${RK_UNIT:-uptermd.service}"
KEY_USER="${RK_USER:-upterm}"
LOG_DIR="${RK_DEPLOY_LOG_DIR:-/var/log/uptermd-deploy/logs}"
WAIT_ATTEMPTS="${RK_START_WAIT_ATTEMPTS:-15}"
WAIT_INTERVAL_S="${RK_START_WAIT_INTERVAL_S:-1}"

LOGGER="deploy.rotate_relay_key"
RUN_ID="$(date -u '+%Y%m%d_%H%M%S')_$$"
TS="$(date -u '+%Y%m%dT%H%M%SZ')"
LOG_FILE=""
APPLY=0
FORCE=0
ROLLBACK_TO=""
TMP_DIR=""
CLEANED=0
WARNED=0

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: rotate-relay-key.sh [选项]

反连注册标识轮换: 替换中转服务身份密钥, 并输出新的 known_hosts 公钥行.

选项:
  --host <name>          对外域名或地址, 用于生成公钥行
  --port <port>          对外端口
  --state-dir <path>     密钥目录
  --key-name <name>      密钥文件名
  --metrics-url <url>    指标地址, 用于判断是否有活动会话
  --unit <name>          systemd 单元名
  --apply                实际执行轮换; 缺省只做演练
  --force                存在活动会话或指标不可用时仍继续
  --rollback <path>      用指定归档恢复密钥
  -h, --help             打印本说明
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
        "{\"exc_type\":\"RotateError\",\"exc_msg\":$(jq -Rn --arg v "$msg" '$v'),\"stack\":null}"
    printf '[ERROR] %s\n' "$msg" >&2
    exit "$code"
}

_on_error() {
    # 用途: ERR 钩子, 记录失败命令与行号
    # 参数: $1 退出码; $2 行号; $3 命令
    # 返回: 无; 退出码: 0
    local code="$1" line="$2" cmd="$3"
    set +e   # 钩子内不再触发 ERR, 避免递归
    _log ERROR "rotate.command.failed" "命令执行失败" \
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
            --host) RELAY_HOST="${2:?缺少 --host 取值}"; shift 2 ;;
            --port) RELAY_PORT="${2:?缺少 --port 取值}"; shift 2 ;;
            --state-dir) STATE_DIR="${2:?缺少 --state-dir 取值}"; shift 2 ;;
            --key-name) KEY_NAME="${2:?缺少 --key-name 取值}"; shift 2 ;;
            --metrics-url) METRICS_URL="${2:?缺少 --metrics-url 取值}"; shift 2 ;;
            --unit) UNIT_NAME="${2:?缺少 --unit 取值}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --force) FORCE=1; shift ;;
            --rollback) ROLLBACK_TO="${2:?缺少 --rollback 取值}"; APPLY=1; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    LOG_FILE="${LOG_DIR}/${RUN_ID}.jsonl"
}

_require_root() {
    # 用途: 校验 root 身份
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    if [[ "$(id -u)" -ne 0 ]]; then
        _die 4 "rotate.not_root" "需要以 root 执行, 当前 uid=$(id -u)"
    fi
}

_active_sessions() {
    # 用途: 从 Prometheus 指标读取活动连接数
    # 参数: 无
    # 返回: 标准输出整数; 退出码: 0 成功; 1 指标不可用或指标缺失
    local body value
    if ! body="$(curl -fsS --connect-timeout 3 --max-time 10 "$METRICS_URL")"; then
        return 1
    fi
    value="$(printf '%s\n' "$body" | awk '$1 ~ /^routing_active_connections_count/ { v = $NF } END { print v }')"
    if [[ -z "$value" ]]; then
        return 1
    fi
    printf '%s' "$value"
}

_new_key() {
    # 用途: 在临时目录生成新密钥并校验可用性
    # 参数: $1 临时目录
    # 返回: 无; 退出码: 0 或 5
    local dir="$1" path="${dir}/${KEY_NAME}" fp
    ssh-keygen -q -t ed25519 -N '' -C "uptermd-registration-${TS}" -f "$path" \
        || _die 5 "rotate.keygen.failed" "生成新密钥失败"
    if ! fp="$(ssh-keygen -lf "${path}.pub" | awk '{print $2}')"; then
        _die 5 "rotate.keygen.invalid" "新公钥无法解析"
    fi
    chmod 0600 "$path"
    chmod 0644 "${path}.pub"
    _log INFO "rotate.keygen.done" "新密钥已生成" "{\"fingerprint\":$(jq -Rn --arg v "$fp" '$v')}"
}

_archive_current() {
    # 用途: 归档当前密钥对, 供回滚使用
    # 参数: 无
    # 返回: 标准输出归档基础路径; 退出码: 0 或 7
    local key="${STATE_DIR}/${KEY_NAME}" archive_dir="${STATE_DIR}/archive" base
    if [[ ! -f "$key" ]]; then
        _die 7 "rotate.archive.missing" "当前密钥不存在, 无可归档: path=${key}"
    fi
    install -d -m 0700 -o root -g root "$archive_dir" \
        || _die 7 "rotate.archive.dir" "创建归档目录失败: path=${archive_dir}"
    base="${archive_dir}/${KEY_NAME}.${TS}"
    install -m 0600 -o root -g root "$key" "$base" \
        || _die 7 "rotate.archive.failed" "归档私钥失败"
    install -m 0644 -o root -g root "${key}.pub" "${base}.pub" \
        || _die 7 "rotate.archive.failed" "归档公钥失败"
    _log INFO "rotate.archive.done" "旧密钥已归档" "{\"archive\":$(jq -Rn --arg v "$base" '$v')}"
    printf '%s' "$base"
}

_install_key() {
    # 用途: 原子安装新密钥对并设定权限
    # 参数: $1 新密钥源路径
    # 返回: 无; 退出码: 0 或 7
    local src="$1" key="${STATE_DIR}/${KEY_NAME}"
    install -m 0600 -o "$KEY_USER" -g "$KEY_USER" "$src" "${key}.new" \
        || _die 7 "rotate.install.failed" "写入新私钥失败"
    install -m 0644 -o "$KEY_USER" -g "$KEY_USER" "${src}.pub" "${key}.pub.new" \
        || _die 7 "rotate.install.failed" "写入新公钥失败"
    mv -f "${key}.new" "$key"
    mv -f "${key}.pub.new" "${key}.pub"
    _log INFO "rotate.install.done" "新密钥已就位" "{\"path\":$(jq -Rn --arg v "$key" '$v')}"
}

_restart_and_wait() {
    # 用途: 重启服务并等待活跃, 失败返回 6
    # 参数: 无
    # 返回: 无; 退出码: 0 或 6
    local attempt
    if ! systemctl restart "$UNIT_NAME"; then
        _log ERROR "rotate.restart.failed" "重启服务失败" "{\"unit\":$(jq -Rn --arg v "$UNIT_NAME" '$v')}"
        return 6
    fi
    for (( attempt = 1; attempt <= WAIT_ATTEMPTS; attempt++ )); do
        if systemctl is-active --quiet "$UNIT_NAME"; then
            _log INFO "rotate.restart.ready" "服务已就绪" "{\"attempt\":${attempt}}"
            return 0
        fi
        _log WARNING "rotate.restart.wait" "服务尚未就绪" "{\"attempt\":${attempt}}"
        sleep "$WAIT_INTERVAL_S"
    done
    return 6
}

_rollback() {
    # 用途: 用归档恢复密钥并重启
    # 参数: $1 归档基础路径
    # 返回: 无; 退出码: 0 或 7
    local base="$1" key="${STATE_DIR}/${KEY_NAME}"
    if [[ ! -f "$base" || ! -f "${base}.pub" ]]; then
        _die 7 "rollback.archive_missing" "归档文件不完整: base=${base}"
    fi
    install -m 0600 -o "$KEY_USER" -g "$KEY_USER" "$base" "${key}.rb"
    install -m 0644 -o "$KEY_USER" -g "$KEY_USER" "${base}.pub" "${key}.pub.rb"
    mv -f "${key}.rb" "$key"
    mv -f "${key}.pub.rb" "${key}.pub"
    if ! systemctl restart "$UNIT_NAME"; then
        _die 7 "rollback.restart" "回滚后重启仍失败, 需人工介入: unit=${UNIT_NAME}"
    fi
    _log WARNING "rollback.done" "已回滚到归档密钥" "{\"archive\":$(jq -Rn --arg v "$base" '$v')}"
    _say "已回滚, 当前指纹: $(ssh-keygen -lf "${key}.pub" | awk '{print $2}')"
}

_print_known_hosts() {
    # 用途: 输出可直接写入仓库变量的公钥行与指纹
    # 参数: $1 公钥文件
    # 返回: 无; 退出码: 0
    local pub="$1" material fp
    material="$(awk '{print $1" "$2}' "$pub")"
    fp="$(ssh-keygen -lf "$pub" | awk '{print $2}')"
    _say "----------------------------------------"
    _say "公钥指纹: ${fp}"
    _say "写入仓库变量 UPTERM_RELAY_KNOWN_HOST 的内容:"
    _say "@cert-authority [${RELAY_HOST}]:${RELAY_PORT} ${material}"
    _say "----------------------------------------"
    _log INFO "rotate.published.line" "已产出公钥行" \
        "{\"fingerprint\":$(jq -Rn --arg v "$fp" '$v'),\"host\":$(jq -Rn --arg v "$RELAY_HOST" '$v'),\"port\":\"${RELAY_PORT}\"}"
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
for cmd in ssh-keygen systemctl curl jq install awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        _die 3 "rotate.deps.missing" "依赖命令缺失: ${cmd}"
    fi
done

TMP_DIR="$(mktemp -d)"
umask 077
_log INFO "rotate.run.started" "开始密钥轮换流程" "{\"apply\":$(( APPLY == 1 ? 1 : 0 ))}"

if [[ -n "$ROLLBACK_TO" ]]; then
    _say "回滚模式: 归档 ${ROLLBACK_TO}"
    if (( APPLY == 1 )); then
        _rollback "$ROLLBACK_TO"
        _print_known_hosts "${STATE_DIR}/${KEY_NAME}.pub"
    fi
    exit 0
fi

active=""
if active="$(_active_sessions)"; then
    _log INFO "rotate.sessions.read" "已读取活动会话数" "{\"active\":${active}}"
else
    _log WARNING "rotate.sessions.unavailable" "指标不可用, 无法确认是否有活动会话" "{}"
    if (( FORCE == 0 )); then
        _die 4 "rotate.sessions.unknown" "指标不可用且未加 --force, 拒绝轮换: url=${METRICS_URL}"
    fi
fi
if [[ -n "$active" && "$active" != "0" ]] && (( FORCE == 0 )); then
    _die 4 "rotate.sessions.active" "存在活动会话, 拒绝轮换: active=${active}; 确认无影响可加 --force"
fi

_new_key "$TMP_DIR"

if (( APPLY == 0 )); then
    _say "演练: 将归档现有密钥并替换为 ${TMP_DIR}/${KEY_NAME}, 随后重启 ${UNIT_NAME}"
    _print_known_hosts "${TMP_DIR}/${KEY_NAME}.pub"
    _say "演练结束, 加 --apply 执行轮换"
    exit 0
fi

archive_base="$(_archive_current)"
_install_key "${TMP_DIR}/${KEY_NAME}"

if ! _restart_and_wait; then
    _say "重启失败, 自动回滚到归档密钥"
    _rollback "$archive_base"
    _die 6 "rotate.restart.rollback" "新密钥启用失败, 已自动回滚: archive=${archive_base}"
fi

_print_known_hosts "${STATE_DIR}/${KEY_NAME}.pub"
_say "轮换完成; 该公钥行只用于 known_hosts 防中间人, 不改变任何准入范围; 写入仓库变量后同步更新本机与各 runner 的 known_hosts"
_say "旧密钥归档: ${archive_base}"
_log INFO "rotate.run.finished" "反连注册标识轮换完成" "{\"archive\":$(jq -Rn --arg v "$archive_base" '$v')}"

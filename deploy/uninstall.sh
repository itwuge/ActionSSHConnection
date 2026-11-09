#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : uninstall.sh
# 文件用途    : 可逆卸载 ActSSH 中继与网页桥接: 停单元, 删配置与程序, 按开关保留或删除数据
# 架构定位    : 运维回收入口; 上游是运维人员, 下游是 bootstrap.sh 安装的全部落地物
# 核心功能    : 逐项演练或删除, 单元停用, 防火墙规则可选回收, 数据保留与清理开关, 删除清单输出
# 职责边界    : 不卸载 apt 软件包, 不改系统 sshd, 不动发行版 nginx 站点, 不删除非本方案创建的路径
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行
# 依赖关系    : 依赖 systemctl, install, rm, jq; 复用 deploy/bootstrap/lib.sh 的日志函数
#
# 输入        : 命令行参数优先, 未给出时读取同名环境变量
#               --domain <fqdn>     可选; 给出时一并清理该域名的证书与续期配置
#               --keep-data         保留数据, 默认; 不删状态目录与中继状态
#               --purge-data        删除数据: /var/lib/uptermd, /etc/uptermd, /var/lib/actssh-bootstrap
#               --remove-firewall   回收本方案写入的 ufw 规则与 nftables 规则文件
#               --state-dir <dir>   状态目录, 默认 /var/lib/actssh-bootstrap
#               --relay-port <p>    uptermd SSH 端口, 默认 2222
#               --admin-ssh-port <p> 管理面 SSH 端口, 默认 22
#               --http-port <p>     HTTP 端口, 默认 80
#               --https-port <p>    HTTPS 端口, 默认 443
#               --metrics-port <p>  指标端口, 默认 9100
#               --apply             实际删除; 缺省只打印计划
# 退出码      : 0 成功或演练完成; 2 参数非法; 3 依赖缺失; 4 非 root; 5 单元停用失败;
#               6 路径删除失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/bootstrap/lib.sh
source "${SCRIPT_DIR}/bootstrap/lib.sh"

# =========** 方法一览 =========**
#   _log / _say / _die / _on_error -> 日志与终止
#   _parse_args / _validate -> 0/2: 参数解析与校验
#   _remove_path <path> <label> -> 0/6: 演练或删除一个路径
#   _stop_units -> 0/5: 停用并禁用单元
#   _remove_units -> 0/6: 删除单元文件
#   _remove_configs -> 0/6: 删除配置与程序
#   _remove_firewall -> 0/6: 回收本方案的防火墙规则
#   _purge_data -> 0/6: 删除数据目录与证书
#   _summary -> 0: 输出删除清单

# =========** 常量与默认值 =========**
DOMAIN="${ACTSSH_DOMAIN:-}"
STATE_DIR="${ACTSSH_STATE_DIR:-/var/lib/actssh-bootstrap}"
RELAY_PORT="${ACTSSH_RELAY_SSH_PORT:-2222}"
ADMIN_SSH_PORT="${ACTSSH_ADMIN_SSH_PORT:-22}"
HTTP_PORT="${ACTSSH_HTTP_PORT:-80}"
HTTPS_PORT="${ACTSSH_HTTPS_PORT:-443}"
METRICS_PORT="${ACTSSH_METRICS_PORT:-9100}"
PURGE_DATA=0
REMOVE_FIREWALL=0
APPLY=0

UNITS=(
    actssh-nginx.service
    actssh-web-bridge.service
    uptermd.service
)
# 配置与程序: 无条件删除, 属于本方案自建的独立路径
CONFIG_PATHS=(
    /etc/actssh
    /etc/systemd/system/actssh-nginx.service
    /etc/systemd/system/actssh-web-bridge.service
    /etc/systemd/system/uptermd.service
    /etc/uptermd/uptermd-guard.nft
    /etc/logrotate.d/actssh
    /etc/cron.d/actssh-certbot
    /usr/local/bin/uptermd
    /opt/actssh-web-bridge
)
# 运行数据: 只有 --purge-data 才删除
DATA_PATHS=(
    /var/lib/uptermd
    /etc/uptermd
    /var/www/actssh-acme
    "${STATE_DIR}"
)

LOGGER="deploy.uninstall"
RUN_ID="${BS_RUN_ID:-$(date '+%Y%m%d_%H%M%S')_$$}"
LOG_ROOT="${STATE_DIR}/logs"
REMOVED=0
KEPT=0

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: uninstall.sh [选项]

默认演练, --apply 才实际删除.
  --domain <fqdn>      一并清理该域名的证书与续期配置
  --keep-data          保留数据, 默认
  --purge-data         删除 /var/lib/uptermd, /etc/uptermd, /var/www/actssh-acme, 状态目录
  --remove-firewall    回收本方案写入的 ufw 规则与 nftables 规则文件
  --state-dir <dir>    状态目录, 默认 /var/lib/actssh-bootstrap
  --relay-port <p>     uptermd SSH 端口, 默认 2222
  --admin-ssh-port <p> 管理面 SSH 端口, 默认 22
  --http-port <p>      HTTP 端口, 默认 80
  --https-port <p>     HTTPS 端口, 默认 443
  --metrics-port <p>   指标端口, 默认 9100
  --apply              实际执行
  --dry-run            只演练, 与缺省一致
  -h, --help           打印本说明

删除内容:
  始终删除: 三个 systemd 单元及其文件, /etc/actssh, /etc/uptermd/uptermd-guard.nft,
            /etc/logrotate.d/actssh, /etc/cron.d/actssh-certbot, /usr/local/bin/uptermd,
            /opt/actssh-web-bridge
  可选删除: --purge-data 追加 /var/lib/uptermd, /etc/uptermd, /var/www/actssh-acme, 状态目录与备份
  从不删除: apt 软件包, 系统 sshd 配置, 发行版 nginx 站点, 非本方案创建的目录
USAGE
}

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --domain) DOMAIN="${2:?缺少 --domain 取值}"; shift 2 ;;
            --keep-data) PURGE_DATA=0; shift ;;
            --purge-data) PURGE_DATA=1; shift ;;
            --remove-firewall) REMOVE_FIREWALL=1; shift ;;
            --state-dir) STATE_DIR="${2:?缺少 --state-dir 取值}"; shift 2 ;;
            --relay-port) RELAY_PORT="${2:?缺少 --relay-port 取值}"; shift 2 ;;
            --admin-ssh-port) ADMIN_SSH_PORT="${2:?缺少 --admin-ssh-port 取值}"; shift 2 ;;
            --http-port) HTTP_PORT="${2:?缺少 --http-port 取值}"; shift 2 ;;
            --https-port) HTTPS_PORT="${2:?缺少 --https-port 取值}"; shift 2 ;;
            --metrics-port) METRICS_PORT="${2:?缺少 --metrics-port 取值}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --dry-run) APPLY=0; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    LOG_ROOT="${STATE_DIR}/logs"
}

_validate() {
    # 用途: 校验参数
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    bs_require_port "relay-port" "$RELAY_PORT"
    bs_require_port "admin-ssh-port" "$ADMIN_SSH_PORT"
    bs_require_port "http-port" "$HTTP_PORT"
    bs_require_port "https-port" "$HTTPS_PORT"
    bs_require_port "metrics-port" "$METRICS_PORT"
    if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        bs_die 2 "uninstall.args.domain" "域名格式非法: ${DOMAIN}"
    fi
}

_log() {
    # 用途: 写 JSONL 日志
    # 参数: $1 级别; $2 事件; $3 描述; $4 可选 JSON
    # 返回: 无; 退出码: 0
    bs_log "$1" "$2" "$3" "${4:-}"
}

_say() {
    # 用途: 输出进度
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    bs_say "$1"
}

_die() {
    # 用途: 记录后终止
    # 参数: $1 退出码; $2 事件; $3 描述
    # 返回: 不返回
    bs_die "$1" "$2" "$3"
}

_on_error() {
    # 用途: ERR 钩子, 记录后按 6 退出
    # 参数: $1 退出码; $2 行号; $3 命令
    # 返回: 不返回
    local code="$1" line="$2" cmd="$3"
    set +e
    _log ERROR "uninstall.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":$(jq -Rn --arg v "exit=${code} line=${line} cmd=${cmd}" '$v')}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    exit 6
}

_remove_path() {
    # 用途: 演练或删除单个路径
    # 参数: $1 路径; $2 说明
    # 返回: 无; 退出码: 0 或 6
    local path="$1" label="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将删除 ${path} (${label})"
        REMOVED=$((REMOVED + 1))
        return 0
    fi
    if ! rm -rf "$path"; then
        _die 6 "uninstall.path.remove" "删除失败: ${path}"
    fi
    _say "已删除: ${path} (${label})"
    _log INFO "uninstall.path.removed" "已删除路径" \
        "{\"path\":$(jq -Rn --arg v "$path" '$v')}"
    REMOVED=$((REMOVED + 1))
}

_stop_units() {
    # 用途: 停用并禁用本方案单元
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    local unit
    for unit in "${UNITS[@]}"; do
        if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
            continue
        fi
        if (( APPLY == 0 )); then
            _say "演练: 将执行 systemctl disable --now ${unit}"
            continue
        fi
        if ! systemctl disable --now "$unit" >/dev/null 2>&1; then
            _say "[WARN] 停用 ${unit} 失败, 继续删除其文件"
            _log WARNING "uninstall.unit.stop_failed" "停用单元失败" \
                "{\"unit\":$(jq -Rn --arg v "$unit" '$v')}"
        else
            _say "已停用: ${unit}"
        fi
    done
}

_remove_units() {
    # 用途: 删除单元文件
    # 参数: 无
    # 返回: 无; 退出码: 0
    local unit
    for unit in "${UNITS[@]}"; do
        _remove_path "/etc/systemd/system/${unit}" "systemd 单元"
    done
    if (( APPLY == 1 )); then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

_remove_configs() {
    # 用途: 删除配置与程序路径
    # 参数: 无
    # 返回: 无; 退出码: 0
    local path
    for path in "${CONFIG_PATHS[@]}"; do
        _remove_path "$path" "配置或程序"
    done
}

_remove_firewall() {
    # 用途: 回收本方案写入的防火墙规则
    # 参数: 无
    # 返回: 无; 退出码: 0
    local nft_ruleset="/etc/uptermd/uptermd-guard.nft" nft_conf="/etc/nftables.conf"
    if (( REMOVE_FIREWALL == 0 )); then
        _say "防火墙: 未指定 --remove-firewall, 保留现有规则"
        return 0
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将删除 ufw 规则 ${RELAY_PORT}/tcp ${HTTPS_PORT}/tcp ${HTTP_PORT}/tcp, 并移除 ${nft_ruleset}"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw --force delete allow "$RELAY_PORT/tcp" >/dev/null 2>&1 || true
        ufw --force delete allow "$HTTPS_PORT/tcp" >/dev/null 2>&1 || true
        ufw --force delete allow "$HTTP_PORT/tcp" >/dev/null 2>&1 || true
        ufw --force delete deny "$METRICS_PORT/tcp" >/dev/null 2>&1 || true
        _say "已回收 ufw 规则"
    fi
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet uptermd_guard >/dev/null 2>&1; then
            nft delete table inet uptermd_guard >/dev/null 2>&1 || true
        fi
    fi
    if [[ -f "$nft_conf" ]]; then
        sed -i '/# BEGIN uptermd-guard (managed by deploy\/firewall.sh)/,+1d' "$nft_conf" 2>/dev/null || true
    fi
    _remove_path "$nft_ruleset" "nftables 规则文件"
    _say "已回收防火墙规则; 管理面与系统 sshd 的规则未改动"
}

_purge_data() {
    # 用途: 按开关删除运行数据与证书
    # 参数: 无
    # 返回: 无; 退出码: 0
    local path
    if (( PURGE_DATA == 0 )); then
        _say "数据: 已保留 (--keep-data 默认); 需要清理时追加 --purge-data"
        KEPT=$((KEPT + 1))
        return 0
    fi
    for path in "${DATA_PATHS[@]}"; do
        _remove_path "$path" "运行数据"
    done
    if [[ -n "$DOMAIN" ]]; then
        _remove_path "/etc/letsencrypt/live/${DOMAIN}" "证书"
        _remove_path "/etc/letsencrypt/archive/${DOMAIN}" "证书归档"
        _remove_path "/etc/letsencrypt/renewal/${DOMAIN}.conf" "续期配置"
    else
        _say "提示: 未给 --domain, 保留 /etc/letsencrypt 下证书; 需要时加 --domain 重跑"
    fi
    _remove_path /etc/letsencrypt/renewal-hooks/deploy/actssh-nginx-reload "续期钩子"
}

_summary() {
    # 用途: 输出删除结果与残留提示
    # 参数: 无
    # 返回: 无; 退出码: 0
    _say "=== 卸载结果 (apply=${APPLY}) ==="
    _say "处理路径数: ${REMOVED}"
    _say "数据: $([[ "$PURGE_DATA" == "1" ]] && echo 已删除 || echo 已保留)"
    _say "说明: apt 软件包保留; 如需彻底清理可执行 apt-get remove nginx certbot uptermd 相关包"
    _say "日志: ${LOG_ROOT}/${RUN_ID}.jsonl"
    if (( APPLY == 0 )); then
        _say "当前为演练模式; 确认后追加 --apply 执行"
    fi
}

# =========** 主流程 =========**
trap '_on_error $? $LINENO "$BASH_COMMAND"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

_parse_args "$@"
bs_require_root
local_missing=()
for cmd in systemctl rm install jq sed; do
    command -v "$cmd" >/dev/null 2>&1 || local_missing+=("$cmd")
done
if (( ${#local_missing[@]} > 0 )); then
    printf '[ERROR] 依赖命令缺失: %s\n' "${local_missing[*]}" >&2
    exit 3
fi
bs_init_logging "$LOGGER" "$LOG_ROOT" "$RUN_ID"

_say "=== ActSSH 卸载 (apply=${APPLY} purge_data=${PURGE_DATA}) ==="
_log INFO "uninstall.start" "开始卸载" "{\"apply\":${APPLY},\"purge_data\":${PURGE_DATA}}"

_stop_units
_remove_units
_remove_configs
_remove_firewall
_purge_data
_summary

_log INFO "uninstall.done" "卸载流程结束" "{\"apply\":${APPLY},\"removed\":${REMOVED}}"
exit 0

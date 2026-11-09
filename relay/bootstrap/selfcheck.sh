#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : selfcheck.sh
# 所属目录    : relay/bootstrap/
# 文件用途    : bootstrap 收尾自检, 逐项验证单元状态, 端口监听, nginx 配置, 证书有效期, ACME 校验路径, WS 入口与中继健康检查
# 架构定位    : 部署脚本验收层; 上游是 relay/install.sh 的最后一步, 下游是运维人员与自动化巡检
# 核心功能    : 八类只读判定与逐项输出, 汇总失败项数量, 以非零退出码阻断"部署成功"的错误结论
# 职责边界    : 不重启服务, 不改配置, 不申请证书, 不读取任何私钥内容; 只做本机探测
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行
# 依赖关系    : 依赖 systemctl, ss, curl, openssl, jq, nginx, check-relay-health.sh; 由 relay/install.sh 调用
#
# 输入        : 命令行参数优先
#               --domain <fqdn>       证书域名
#               --cert-mode <mode>    acme 或 self-signed
#               --admin-ssh-port <p>  管理面 SSH 端口, 默认 22
#               --relay-port <p>      uptermd SSH 端口, 默认 2222
#               --http-port <p>       HTTP 端口, 默认 80
#               --https-port <p>      HTTPS 端口, 默认 443
#               --bridge-port <p>     桥接端口, 默认 8081
#               --ws-backend-port <p> uptermd WS 上游端口, 默认 8443
#               --metrics-port <p>    指标端口, 默认 9100
#               --cert-file <file>    证书路径, 缺省按模式推导
#               --acme-root <dir>     ACME 校验目录, 默认 /var/www/actssh-acme
#               --nginx-conf <file>   nginx 配置, 默认 /etc/actssh/nginx/nginx.conf
#               --health-script <f>   健康检查脚本, 默认 relay/check-relay-health.sh
#               --relay-only          只校验中继: 跳过 nginx, 证书, ACME 与 WS 入口
#               --no-direct           中继 SSH 只监听环回, 监听地址按 127.0.0.1 校验
# 退出码      : 0 全部通过; 1 存在失败项; 2 参数非法; 3 依赖缺失; 4 非 root; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=relay/bootstrap/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# =========** 常量与默认值 =========**
DOMAIN="${ACTSSH_DOMAIN:-}"
CERT_MODE="${ACTSSH_CERT_MODE:-acme}"
ADMIN_SSH_PORT="${ACTSSH_ADMIN_SSH_PORT:-22}"
RELAY_PORT="${ACTSSH_RELAY_SSH_PORT:-2222}"
HTTP_PORT="${ACTSSH_HTTP_PORT:-80}"
HTTPS_PORT="${ACTSSH_HTTPS_PORT:-443}"
BRIDGE_PORT="${ACTSSH_BRIDGE_PORT:-8081}"
WS_PATH="${ACTSSH_WS_PATH:-/ws/}"
RUNNER_PATH="${ACTSSH_RUNNER_PATH:-/runner/}"
WS_BACKEND_PORT="${ACTSSH_WS_BACKEND_PORT:-8443}"
METRICS_PORT="${ACTSSH_METRICS_PORT:-9100}"
CERT_FILE="${ACTSSH_CERT_FILE:-}"
ACME_ROOT="${ACTSSH_ACME_ROOT:-/var/www/actssh-acme}"
NGINX_CONF="${ACTSSH_NGINX_CONF_DIR:-/etc/actssh/nginx}/nginx.conf"
HEALTH_SCRIPT="${ACTSSH_HEALTH_SCRIPT:-${RELAY_DIR}/check-relay-health.sh}"
NGINX_BIN="${ACTSSH_NGINX_BIN:-/usr/sbin/nginx}"
TMP_DIR=""
RELAY_ONLY=0
NO_DIRECT=0

FAILS=0
CHECKS=0

# =========** 方法一览 =========**
#   _parse_args / _validate -> 0/2
#   _ok / _bad -> 输出判定并累计
#   _check_units -> 单元状态
#   _check_listeners -> 端口监听
#   _check_nginx -> 配置校验
#   _check_cert -> 证书有效期
#   _check_acme -> HTTP-01 校验路径
#   _check_ws -> /ws/ 与 /runner/ 入口
#   _check_health -> 中继健康检查 JSON
#   _check_renewal -> 续期机制存在
#   _cleanup -> 删除临时文件

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --domain) DOMAIN="${2:?缺少 --domain 取值}"; shift 2 ;;
            --cert-mode) CERT_MODE="${2:?缺少 --cert-mode 取值}"; shift 2 ;;
            --admin-ssh-port) ADMIN_SSH_PORT="${2:?缺少 --admin-ssh-port 取值}"; shift 2 ;;
            --relay-port) RELAY_PORT="${2:?缺少 --relay-port 取值}"; shift 2 ;;
            --http-port) HTTP_PORT="${2:?缺少 --http-port 取值}"; shift 2 ;;
            --https-port) HTTPS_PORT="${2:?缺少 --https-port 取值}"; shift 2 ;;
            --bridge-port) BRIDGE_PORT="${2:?缺少 --bridge-port 取值}"; shift 2 ;;
            --ws-path) WS_PATH="${2:?缺少 --ws-path 取值}"; shift 2 ;;
            --runner-path) RUNNER_PATH="${2:?缺少 --runner-path 取值}"; shift 2 ;;
            --ws-backend-port) WS_BACKEND_PORT="${2:?缺少 --ws-backend-port 取值}"; shift 2 ;;
            --metrics-port) METRICS_PORT="${2:?缺少 --metrics-port 取值}"; shift 2 ;;
            --cert-file) CERT_FILE="${2:?缺少 --cert-file 取值}"; shift 2 ;;
            --acme-root) ACME_ROOT="${2:?缺少 --acme-root 取值}"; shift 2 ;;
            --nginx-conf) NGINX_CONF="${2:?缺少 --nginx-conf 取值}"; shift 2 ;;
            --health-script) HEALTH_SCRIPT="${2:?缺少 --health-script 取值}"; shift 2 ;;
            --relay-only) RELAY_ONLY=1; shift ;;
            --no-direct) NO_DIRECT=1; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
}

show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: selfcheck.sh --domain <fqdn> [选项]

选项:
  --domain <fqdn>         证书域名
  --cert-mode <mode>      acme 或 self-signed
  --admin-ssh-port <p>    管理面 SSH 端口, 默认 22
  --relay-port <p>        uptermd SSH 端口, 默认 2222
  --http-port <p>         HTTP 端口, 默认 80
  --https-port <p>        HTTPS 端口, 默认 443
  --bridge-port <p>       桥接端口, 默认 8081
  --ws-path <path>        浏览器 WS 入口路径, 默认 /ws/
  --runner-path <path>    runner 反连路径, 默认 /runner/
  --ws-backend-port <p>   uptermd WS 上游端口, 默认 8443
  --metrics-port <p>      指标端口, 默认 9100
  --cert-file <file>      证书路径
  --acme-root <dir>       ACME 校验目录
  --nginx-conf <file>     nginx 配置路径
  --health-script <file>  健康检查脚本路径
  --relay-only            只校验中继, 跳过 nginx/证书/ACME/WS
  --no-direct             中继 SSH 只监听环回
  -h, --help              打印本说明
USAGE
}

_validate() {
    # 用途: 校验必填项与依赖参数
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    if [[ -z "$DOMAIN" && "$RELAY_ONLY" == "0" ]]; then
        bs_die 2 "selfcheck.args.domain" "缺少 --domain"
    fi
    case "$CERT_MODE" in
        acme|self-signed) ;;
        *) bs_die 2 "selfcheck.args.cert_mode" "cert-mode 仅支持 acme 或 self-signed: ${CERT_MODE}" ;;
    esac
    if [[ -z "$CERT_FILE" && -n "$DOMAIN" ]]; then
        if [[ "$CERT_MODE" == "acme" ]]; then
            CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        else
            CERT_FILE="${ACTSSH_CERT_DIR:-/etc/actssh/tls}/fullchain.pem"
        fi
    fi
}

_ok() {
    # 用途: 输出通过项并计数
    # 参数: $1 检查名; $2 证据
    # 返回: 无; 退出码: 0
    CHECKS=$((CHECKS + 1))
    printf '[OK]   %-18s %s\n' "$1" "$2"
}

_bad() {
    # 用途: 输出失败项并计数
    # 参数: $1 检查名; $2 证据
    # 返回: 无; 退出码: 0
    CHECKS=$((CHECKS + 1))
    FAILS=$((FAILS + 1))
    printf '[FAIL] %-18s %s\n' "$1" "$2"
}

_check_units() {
    # 用途: 校验三个单元均为 active
    # 参数: 无
    # 返回: 无; 退出码: 0
    local unit state
    local -a units=(uptermd.service)
    if [[ "$RELAY_ONLY" == "0" ]]; then
        units=(actssh-nginx.service uptermd.service actssh-web-bridge.service)
    fi
    for unit in "${units[@]}"; do
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        if [[ "$state" == "active" ]]; then
            _ok "unit:${unit}" "active"
        else
            _bad "unit:${unit}" "state=${state:-unknown}"
        fi
    done
}

_check_listeners() {
    # 用途: 校验各端口监听状态
    # 参数: 无
    # 返回: 无; 退出码: 0
    local item port host relay_host="0.0.0.0" rows=""
    if [[ "$NO_DIRECT" == "1" ]]; then
        relay_host="127.0.0.1"
    fi
    rows="admin-ssh|${ADMIN_SSH_PORT}|
relay-ssh|${RELAY_PORT}|${relay_host}
ws-upstream|${WS_BACKEND_PORT}|127.0.0.1
metrics|${METRICS_PORT}|127.0.0.1"
    if [[ "$RELAY_ONLY" == "0" ]]; then
        rows="http|${HTTP_PORT}|0.0.0.0
https|${HTTPS_PORT}|0.0.0.0
bridge|${BRIDGE_PORT}|127.0.0.1
${rows}"
    fi
    while IFS='|' read -r item port host; do
        [[ -n "$item" ]] || continue
        if bs_listen_ok "$port" "$host"; then
            _ok "listen:${item}" "${host:-any}:${port}"
        else
            _bad "listen:${item}" "${host:-any}:${port} 无监听"
        fi
    done <<<"$rows"
}

_check_nginx() {
    # 用途: 校验独立 nginx 配置语法
    # 参数: 无
    # 返回: 无; 退出码: 0
    local out
    if [[ ! -x "$NGINX_BIN" ]]; then
        _bad "nginx:config" "缺少 nginx: ${NGINX_BIN}"
        return 0
    fi
    if out="$("$NGINX_BIN" -t -c "$NGINX_CONF" 2>&1)"; then
        _ok "nginx:config" "syntax ok"
    else
        _bad "nginx:config" "$(printf '%s' "$out" | tail -n 1)"
    fi
}

_check_cert() {
    # 用途: 校验证书存在且剩余有效期不少于 7 天
    # 参数: 无
    # 返回: 无; 退出码: 0
    local days not_after
    if [[ ! -r "$CERT_FILE" ]]; then
        _bad "cert:file" "不存在: ${CERT_FILE}"
        return 0
    fi
    if ! openssl x509 -checkend 604800 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
        _bad "cert:expiry" "剩余不足 7 天: notAfter=$(bs_cert_not_after "$CERT_FILE")"
        return 0
    fi
    days="$(bs_cert_days_left "$CERT_FILE" || true)"
    not_after="$(bs_cert_not_after "$CERT_FILE" || true)"
    _ok "cert:expiry" "notAfter=${not_after} 剩余天数=${days}"
}

_check_acme() {
    # 用途: 用本机请求验证 HTTP-01 校验路径可读
    # 参数: 无
    # 返回: 无; 退出码: 0
    local dir token body
    dir="${ACME_ROOT}/.well-known/acme-challenge"
    token="selfcheck-$$"
    if [[ ! -d "$ACME_ROOT" ]]; then
        _bad "acme:webroot" "目录不存在: ${ACME_ROOT}"
        return 0
    fi
    if ! mkdir -p "$dir" 2>/dev/null || ! printf '%s' "actssh-selfcheck" >"${dir}/${token}" 2>/dev/null; then
        _bad "acme:webroot" "目录不可写: ${dir}"
        return 0
    fi
    body="$(curl -fsS --max-time 5 -H "Host: ${DOMAIN}" \
        "http://127.0.0.1:${HTTP_PORT}/.well-known/acme-challenge/${token}" 2>/dev/null || true)"
    rm -f "${dir}/${token}"
    if [[ "$body" == "actssh-selfcheck" ]]; then
        _ok "acme:webroot" "HTTP ${HTTP_PORT} 可返回校验文件"
    else
        _bad "acme:webroot" "响应不符: body=${body:-空}"
    fi
}

_check_ws() {
    # 用途: 校验 /ws/ 与 /runner/ 能到达桥接而非返回 502
    # 参数: 无
    # 返回: 无; 退出码: 0
    local path code extra
    extra=()
    if [[ "$CERT_MODE" == "self-signed" ]]; then
        extra=(-k)
    fi
    for path in "${WS_PATH}selfcheck" "${RUNNER_PATH}selfcheck"; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 \
            "${extra[@]}" --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: YWN0c3NoLXNlbGZjaGVjaw==' \
            "https://${DOMAIN}:${HTTPS_PORT}${path}" 2>/dev/null || true)"
        case "$code" in
            101|400|426) _ok "ws:${path}" "http=${code}" ;;
            *) _bad "ws:${path}" "http=${code:-000}" ;;
        esac
    done
}

_check_health() {
    # 用途: 调用中继健康检查脚本并要求 ok=true
    # 参数: 无
    # 返回: 无; 退出码: 0
    local out ok ws_port="$HTTPS_PORT"
    if [[ ! -x "$HEALTH_SCRIPT" ]]; then
        _bad "relay:health" "健康检查脚本不可执行: ${HEALTH_SCRIPT}"
        return 0
    fi
    if [[ "$RELAY_ONLY" == "1" ]]; then
        # 无 TLS 终止时用环回 WS 上游作为监听判据
        ws_port="$WS_BACKEND_PORT"
    fi
    out="$(CH_SSH_PORT="$RELAY_PORT" CH_WS_PORT="$ws_port" \
        CH_WS_BACKEND_PORT="$WS_BACKEND_PORT" CH_BRIDGE_PORT="$BRIDGE_PORT" \
        CH_METRICS_URL="http://127.0.0.1:${METRICS_PORT}/metrics" \
        "$HEALTH_SCRIPT" 127.0.0.1 "$RELAY_PORT" 2>/dev/null || true)"
    ok="$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null || echo false)"
    if [[ "$ok" == "true" ]]; then
        _ok "relay:health" "ok=true"
    else
        _bad "relay:health" "ok=${ok} message=$(printf '%s' "$out" | jq -r '.message // "无输出"' 2>/dev/null || echo '无输出')"
    fi
}

_check_renewal() {
    # 用途: 校验自动续期机制存在
    # 参数: 无
    # 返回: 无; 退出码: 0
    local state
    if [[ "$CERT_MODE" != "acme" ]]; then
        _ok "cert:renewal" "自签模式不适用"
        return 0
    fi
    state="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
    if [[ "$state" == "enabled" || "$state" == "static" ]]; then
        _ok "cert:renewal" "certbot.timer=${state}"
        return 0
    fi
    if [[ -f /etc/cron.d/certbot || -f /etc/cron.d/actssh-certbot ]]; then
        _ok "cert:renewal" "cron 已存在"
        return 0
    fi
    _bad "cert:renewal" "未发现 certbot.timer 或续期 cron"
}

_cleanup() {
    # 用途: 删除临时目录, 幂等
    # 参数: 无
    # 返回: 无; 退出码: 0
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# =========** 主流程 =========**
trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_parse_args "$@"
_validate
bs_require_root
bs_require_cmds systemctl ss curl openssl jq awk sed tail
TMP_DIR="$(mktemp -d)"

printf '%s\n' "=== 收尾自检 (domain=${DOMAIN} mode=${CERT_MODE}) ==="
_check_units
_check_listeners
if [[ "$RELAY_ONLY" == "0" ]]; then
    _check_nginx
    _check_cert
    _check_acme
    _check_ws
fi
_check_health
if [[ "$RELAY_ONLY" == "0" ]]; then
    _check_renewal
else
    printf '[SKIP] %-18s %s\n' "cert:renewal" "relay-only 形态无证书"
fi

printf '%s\n' "=== 自检结果: 通过 $((CHECKS - FAILS))/${CHECKS} ==="
if (( FAILS > 0 )); then
    exit 1
fi
exit 0

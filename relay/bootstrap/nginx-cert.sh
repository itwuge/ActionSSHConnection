#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : nginx-cert.sh
# 所属目录    : relay/bootstrap/
# 文件用途    : 在空机器上落地独立 nginx 实例与 HTTPS 入口, 用 certbot HTTP-01 签发并自动续期证书
# 架构定位    : 部署脚本 TLS 层; 上游是 relay/install.sh, 下游是 actssh-nginx.service 与 certbot 续期定时器
# 核心功能    : 独立配置目录与单元安装, 80 端口占用判定, 两阶段配置(先 ACME 后 TLS), 证书签发与续期钩子, 配置校验与重载
# 职责边界    : 不改 /etc/nginx/sites-enabled, 不接管发行版站点, 不迁移既有 80/443 占用, 不写云安全组, 不打印任何私钥
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行, 需可出网访问 ACME 目录
# 依赖关系    : 依赖 nginx, certbot, openssl, systemctl, ss, curl, jq; 由 relay/install.sh 调用
#
# 输入        : 命令行参数优先, 未给出时读取同名环境变量
#               --domain <fqdn>       证书域名, 必填
#               --cert-mode <acme|standalone|self-signed> 默认 acme(webroot, 别名 webroot); standalone 临时停 80 后签发; self-signed 仅用于无公网 DNS 的实验环境
#               --acme-email <mail>   注册邮箱, 可省略; 省略时使用无邮箱注册
#               --staging             使用 ACME 预发布目录, 避免调试时消耗正式配额
#               --http-port <port>    默认 80
#               --https-port <port>   默认 443
#               --bridge-host <host>  WS 上游地址, 默认 127.0.0.1
#               --bridge-port <port>  WS 上游端口, 默认 8081
#               --ws-path <path>      浏览器 WS 入口路径, 默认 /ws/
#               --runner-path <path>  runner 反连 WS 路径, 默认 /runner/
#               --web-root <dir>      网页终端静态资源根目录, 默认 /var/www/actssh/html
#               --www-alias           为 <域名> 增加 www.<域名> 301 跳转站点
#               --ssh-domain <fqdn>   额外站点: 把该域名整体反代到 uptermd 的 WS 端口
#               --acme-root <dir>     HTTP-01 校验目录, 默认 /var/www/actssh/acme
#               --cert-dir <dir>      self-signed 证书目录, 默认 /etc/actssh/tls
#               --ops-group <group>   运维只读组, 默认 actssh-ops
#               --apply               实际写入并启停; 缺省只演练
# 退出码      : 0 成功; 2 参数非法; 3 依赖缺失; 4 非 root; 5 目录或权限准备失败;
#               6 nginx 配置校验失败; 7 单元启动或端口监听失败; 8 证书签发失败;
#               9 80/443 被外部占用或存在既有站点; 10 重载失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=relay/bootstrap/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# =========** 方法一览 =========**
#   _log / _say / _die / _on_error -> 日志与终止
#   _parse_args -> 0/2: 解析参数
#   _validate -> 0/2: 参数组合与端口校验
#   _ensure_dirs -> 0/5: 创建配置, 日志, 校验与站点目录
#   _guard_ports -> 0/9: 确认 80/443 只被本实例或发行版 nginx 占用
#   _guard_distro_sites -> 0/9: 拒绝接管已有站点
#   _stop_distro_nginx -> 0/7: 停用发行版 nginx 单元, 让出 80/443
#   _render_conf <target> <tls> -> 0: 生成两阶段配置
#   _install_unit -> 0/7: 安装独立单元
#   _apply_conf <file> -> 0/6: 校验并原子落地配置
#   _reload_unit -> 0/7/10: 启动或重载并等待监听
#   _cert_paths -> 0: 输出证书与私钥路径
#   _issue_self_signed -> 0/8: 生成自签证书
#   _issue_acme -> 0/8: 调用 certbot 签发
#   _install_renewal -> 0/8: 安装续期钩子与定时器
#   _summary -> 0: 输出证书有效期

# =========** 常量与默认值 =========**
DOMAIN="${ACTSSH_DOMAIN:-}"
CERT_MODE="${ACTSSH_CERT_MODE:-acme}"
ACME_EMAIL="${ACTSSH_ACME_EMAIL:-7111479@qq.com}"
ACME_STAGING=0
HTTP_PORT="${ACTSSH_HTTP_PORT:-80}"
HTTPS_PORT="${ACTSSH_HTTPS_PORT:-443}"
BRIDGE_HOST="${ACTSSH_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${ACTSSH_BRIDGE_PORT:-8081}"
WS_BACKEND_HOST="${ACTSSH_WS_BACKEND_HOST:-127.0.0.1}"
WS_BACKEND_PORT="${ACTSSH_WS_BACKEND_PORT:-8443}"
WS_PATH="${ACTSSH_WS_PATH:-/ws/}"
RUNNER_PATH="${ACTSSH_RUNNER_PATH:-/runner/}"
WEB_ROOT="${ACTSSH_WEB_ROOT:-/var/www/actssh/html}"
WWW_ALIAS="${ACTSSH_WWW_ALIAS:-0}"
SSH_DOMAIN="${ACTSSH_SSH_DOMAIN:-}"
ACME_ROOT="${ACTSSH_ACME_ROOT:-/var/www/actssh/acme}"
CERT_DIR="${ACTSSH_CERT_DIR:-/etc/actssh/tls}"
OPS_GROUP="${ACTSSH_OPS_GROUP:-actssh-ops}"
NGINX_MODE="${ACTSSH_NGINX_MODE:-dedicated}"
CONF_DIR="${ACTSSH_NGINX_CONF_DIR:-/etc/actssh/nginx}"
LOG_DIR="${ACTSSH_NGINX_LOG_DIR:-/var/log/actssh/nginx}"
UNIT_SRC="${SCRIPT_DIR}/actssh-nginx.service"
UNIT_PATH="/etc/systemd/system/actssh-nginx.service"
NGINX_BIN="${ACTSSH_NGINX_BIN:-/usr/sbin/nginx}"
CERTBOT_BIN="${ACTSSH_CERTBOT_BIN:-/usr/bin/certbot}"
SERVICE="actssh-nginx.service"
# host 模式接管发行版 nginx: 只写 /etc/nginx/conf.d, 不安装独立单元, 不停止宿主 nginx
if [[ "$NGINX_MODE" == "host" ]]; then
    CONF_DIR="${ACTSSH_NGINX_CONF_DIR:-/etc/nginx}"
    LOG_DIR="${ACTSSH_NGINX_LOG_DIR:-/var/log/nginx}"
    SERVICE="nginx.service"
fi
RUN_DIR="/run/actssh-nginx"
APPLY=0

LOGGER="relay.bootstrap.nginx_cert"
RUN_ID="${BS_RUN_ID:-$(date '+%Y%m%d_%H%M%S')_$$}"
LOG_ROOT="${BS_LOG_DIR:-/var/log/actssh-bootstrap}"
TMP_DIR=""

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: nginx-cert.sh --domain <fqdn> [选项]

选项:
  --domain <fqdn>          证书域名, 必填
  --cert-mode <mode>       acme(webroot) | standalone | self-signed, 默认 acme
                           acme: 宿主 certbot webroot, 不停服
                           standalone: 签发时临时停本方案 nginx 以独占 80
                           self-signed: 自签, 仅无公网环境使用
  --acme-email <mail>      ACME 注册邮箱, 默认 7111479@qq.com; 别名 --email
  --staging                使用 ACME 预发布目录
  --http-port <port>       HTTP 端口, 默认 80
  --https-port <port>      HTTPS 端口, 默认 443
  --bridge-host <host>     WS 上游地址, 默认 127.0.0.1
  --bridge-port <port>     WS 上游端口, 默认 8081
  --ws-backend-host <h>    uptermd WS 上游地址, 默认 127.0.0.1
  --ws-backend-port <port> uptermd WS 上游端口, 默认 8443
  --ws-path <path>         浏览器 WS 入口路径, 默认 /ws/
  --runner-path <path>     runner 反连 WS 路径, 默认 /runner/
  --web-root <dir>         网页终端静态资源根目录, 默认 /var/www/actssh/html
  --www-alias              为域名增加 www 301 跳转站点
  --ssh-domain <fqdn>      额外站点: 该域名整体反代到 uptermd WS 端口
  --acme-root <dir>        HTTP-01 校验目录, 默认 /var/www/actssh/acme
  --nginx-mode <mode>      dedicated: 安装独立 actssh-nginx.service; host: 接管发行版 nginx 的 conf.d
                           默认 dedicated; host 模式不停止宿主 nginx, 已存在的等价配置直接采用
  --cert-dir <dir>         自签证书目录, 默认 /etc/actssh/tls
  --ops-group <group>      运维只读组, 默认 actssh-ops
  --apply                  实际写入并启停
  --dry-run                只演练, 与缺省一致
  -h, --help               打印本说明
USAGE
}

_log() {
    # 用途: 写 JSONL 日志
    # 参数: $1 级别; $2 事件; $3 描述; $4 可选 JSON
    # 返回: 无; 退出码: 0
    BS_LOGGER="$LOGGER" bs_log "$1" "$2" "$3" "${4:-}"
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
    BS_LOGGER="$LOGGER" bs_die "$1" "$2" "$3"
}

_on_error() {
    # 用途: ERR 钩子
    # 参数: $1 退出码; $2 行号; $3 命令
    # 返回: 不返回; 退出码: 7
    local code="$1" line="$2" cmd="$3"
    set +e
    _log ERROR "nginx.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":\"exit=${code} line=${line} cmd=${cmd}\"}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    exit 7
}

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --domain) DOMAIN="${2:?缺少 --domain 取值}"; shift 2 ;;
            --cert-mode) CERT_MODE="${2:?缺少 --cert-mode 取值}"; shift 2 ;;
            --acme-email|--email) ACME_EMAIL="${2:?缺少 --acme-email 取值}"; shift 2 ;;
            --staging) ACME_STAGING=1; shift ;;
            --http-port) HTTP_PORT="${2:?缺少 --http-port 取值}"; shift 2 ;;
            --https-port) HTTPS_PORT="${2:?缺少 --https-port 取值}"; shift 2 ;;
            --bridge-host) BRIDGE_HOST="${2:?缺少 --bridge-host 取值}"; shift 2 ;;
            --bridge-port) BRIDGE_PORT="${2:?缺少 --bridge-port 取值}"; shift 2 ;;
            --ws-backend-host) WS_BACKEND_HOST="${2:?缺少 --ws-backend-host 取值}"; shift 2 ;;
            --ws-backend-port) WS_BACKEND_PORT="${2:?缺少 --ws-backend-port 取值}"; shift 2 ;;
            --ws-path) WS_PATH="${2:?缺少 --ws-path 取值}"; shift 2 ;;
            --runner-path) RUNNER_PATH="${2:?缺少 --runner-path 取值}"; shift 2 ;;
            --web-root) WEB_ROOT="${2:?缺少 --web-root 取值}"; shift 2 ;;
            --www-alias) WWW_ALIAS=1; shift ;;
            --ssh-domain) SSH_DOMAIN="${2:?缺少 --ssh-domain 取值}"; shift 2 ;;
            --acme-root) ACME_ROOT="${2:?缺少 --acme-root 取值}"; shift 2 ;;
            --nginx-mode) NGINX_MODE="${2:?缺少 --nginx-mode 取值}"; shift 2 ;;
            --cert-dir) CERT_DIR="${2:?缺少 --cert-dir 取值}"; shift 2 ;;
            --ops-group) OPS_GROUP="${2:?缺少 --ops-group 取值}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --dry-run) APPLY=0; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
}

_validate() {
    # 用途: 校验必填项与端口, 端口相同视为配置错误
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    if [[ -z "$DOMAIN" ]]; then
        _die 2 "nginx.args.domain_required" "缺少 --domain"
    fi
    case "$NGINX_MODE" in
        host|dedicated) ;;
        *) _die 2 "nginx.args.nginx_mode" "nginx-mode 仅支持 host 或 dedicated: ${NGINX_MODE}" ;;
    esac
    if [[ "$NGINX_MODE" == "host" ]]; then
        CONF_DIR="${ACTSSH_NGINX_CONF_DIR:-/etc/nginx}"
        LOG_DIR="${ACTSSH_NGINX_LOG_DIR:-/var/log/nginx}"
        SERVICE="nginx.service"
    fi
    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _die 2 "nginx.args.domain_invalid" "域名格式非法: ${DOMAIN}"
    fi
    # webroot 是 acme 的同义写法, 统一归一化后再走后续分支
    if [[ "$CERT_MODE" == "webroot" ]]; then
        CERT_MODE="acme"
    fi
    case "$CERT_MODE" in
        acme|standalone|self-signed) ;;
        *) _die 2 "nginx.args.cert_mode" "cert-mode 仅支持 acme(webroot) / standalone / self-signed: ${CERT_MODE}" ;;
    esac
    if [[ "$CERT_MODE" != "self-signed" && "$HTTP_PORT" != "80" ]]; then
        _die 2 "nginx.args.http_port" "HTTP-01 校验固定访问 80 端口, ${CERT_MODE} 模式下 --http-port 必须为 80"
    fi
    if [[ "$NGINX_MODE" == "host" && "$CERT_MODE" == "standalone" ]]; then
        _die 2 "nginx.args.host_standalone" "host 模式不允许 --cert-mode standalone: 签发会停止宿主 nginx, 中断 80/443; 请改用 acme"
    fi
    bs_require_port "http-port" "$HTTP_PORT"
    bs_require_port "https-port" "$HTTPS_PORT"
    bs_require_port "bridge-port" "$BRIDGE_PORT"
    bs_require_port "ws-backend-port" "$WS_BACKEND_PORT"
    if [[ "$HTTP_PORT" == "$HTTPS_PORT" ]]; then
        _die 2 "nginx.args.port_conflict" "HTTP 与 HTTPS 端口不能相同: ${HTTP_PORT}"
    fi
    if [[ "$HTTP_PORT" == "$BRIDGE_PORT" || "$HTTPS_PORT" == "$BRIDGE_PORT" ]]; then
        _die 2 "nginx.args.port_conflict" "入口端口不能与 WS 上游端口相同: ${BRIDGE_PORT}"
    fi
    if [[ -n "$WEB_ROOT" && "$WEB_ROOT" != /* ]]; then
        _die 2 "nginx.args.web_root_relative" "静态站点目录必须是绝对路径: ${WEB_ROOT}"
    fi
    # 除自签实验模式外, ACME 注册邮箱必填; 缺省值由常量给出
    if [[ "$CERT_MODE" != "self-signed" ]]; then
        if [[ -z "$ACME_EMAIL" || ! "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            _die 2 "nginx.args.acme_email" "ACME 注册邮箱缺失或格式非法: ${ACME_EMAIL:-空}"
        fi
    fi
    if [[ -n "$SSH_DOMAIN" ]]; then
        if [[ "$CERT_MODE" == "self-signed" ]]; then
            _die 2 "nginx.args.ssh_domain_selfsigned" "--ssh-domain 需要独立 ACME 证书, 不能与 --cert-mode self-signed 同用"
        fi
        if [[ ! "$SSH_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
            _die 2 "nginx.args.ssh_domain_invalid" "ssh-domain 格式非法: ${SSH_DOMAIN}"
        fi
        if [[ "$SSH_DOMAIN" == "$DOMAIN" ]]; then
            _die 2 "nginx.args.ssh_domain_conflict" "ssh-domain 不能与 --domain 相同: ${SSH_DOMAIN}"
        fi
    fi
}

_ensure_dirs() {
    # 用途: 创建配置, 日志, ACME 校验与运行目录
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    if ! getent group "$OPS_GROUP" >/dev/null 2>&1; then
        if (( APPLY == 1 )); then
            groupadd --system "$OPS_GROUP" || _die 5 "nginx.dirs.group" "无法创建运维组: ${OPS_GROUP}"
        else
            _say "演练: 将创建系统组 ${OPS_GROUP}"
        fi
    fi
    if [[ "$NGINX_MODE" == "host" ]]; then
        # 接管宿主 nginx: 不改 /etc/nginx 所有权, 只补 conf.d 与数据目录
        bs_ensure_dir "${CONF_DIR}/conf.d" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建站点配置目录: ${CONF_DIR}/conf.d"
        bs_ensure_dir "$ACME_ROOT" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建校验目录: ${ACME_ROOT}"
        bs_ensure_dir "$WEB_ROOT" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建静态资源目录: ${WEB_ROOT}"
        if [[ "$CERT_MODE" == "self-signed" ]]; then
            bs_ensure_dir "$CERT_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建证书目录: ${CERT_DIR}"
        fi
        return 0
    fi
    bs_ensure_dir "$CONF_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建配置目录: ${CONF_DIR}"
    bs_ensure_dir "$LOG_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建日志目录: ${LOG_DIR}"
    bs_ensure_dir "$ACME_ROOT" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建校验目录: ${ACME_ROOT}"
    bs_ensure_dir "$WEB_ROOT" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建静态资源目录: ${WEB_ROOT}"
    bs_ensure_dir "${CONF_DIR}/conf.d" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建站点配置目录: ${CONF_DIR}/conf.d"
    bs_ensure_dir "$RUN_DIR" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建运行目录: ${RUN_DIR}"
    if [[ "$CERT_MODE" == "self-signed" ]]; then
        bs_ensure_dir "$CERT_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建证书目录: ${CERT_DIR}"
    fi
}

_guard_distro_sites() {
    # 用途: 拒绝接管发行版 nginx 的既有站点, 把共存/迁移交给 README 迁移节
    # 参数: 无
    # 返回: 无; 退出码: 0 或 9
    local site base
    if [[ ! -d /etc/nginx/sites-enabled ]]; then
        return 0
    fi
    for site in /etc/nginx/sites-enabled/*; do
        [[ -e "$site" ]] || continue
        base="$(basename "$site")"
        if [[ "$base" != "default" ]]; then
            _die 9 "nginx.distro.sites_present" \
                "检测到既有 nginx 站点: /etc/nginx/sites-enabled/${base}; 本脚本不接管既有站点, 请按 relay/README.md 迁移节处理"
        fi
    done
    return 0
}

_guard_ports() {
    # 用途: 确认入口端口空闲, 或只被本实例与发行版 nginx 占用
    # 参数: 无
    # 返回: 无; 退出码: 0 或 9
    local port
    for port in "$HTTP_PORT" "$HTTPS_PORT"; do
        if ! bs_listen_ok "$port"; then
            continue
        fi
        if bs_listener_owned_by "$port" "$SERVICE" nginx.service; then
            continue
        fi
        _die 9 "nginx.port.occupied" \
            "端口 ${port} 已被其他进程占用; 本脚本不自动迁移, 请先停止占用进程或按 README 迁移节处理"
    done
}

_stop_distro_nginx() {
    # 用途: 停用发行版 nginx 单元, 避免与本实例抢 80/443; host 模式接管宿主 nginx, 不执行本步骤
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if [[ "$NGINX_MODE" == "host" ]]; then
        return 0
    fi
    if ! systemctl list-unit-files nginx.service --no-legend >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-enabled --quiet nginx.service 2>/dev/null \
        && ! systemctl is-active --quiet nginx.service 2>/dev/null; then
        return 0
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将停用并禁用发行版 nginx.service, 让出端口 ${HTTP_PORT}/${HTTPS_PORT}"
        return 0
    fi
    _say "停用发行版 nginx.service"
    if ! systemctl disable --now nginx.service; then
        _die 7 "nginx.distro.stop_failed" "无法停用发行版 nginx.service"
    fi
    return 0
}

_render_ssl_conf() {
    # 用途: 生成共享证书片段, 供主站点与 www 站点 include
    # 参数: $1 输出文件
    # 返回: 无; 退出码: 0
    cat >"$1" <<EOF
# 入口域名证书(acme: 宿主 certbot; self-signed: 本地自签)
# 续期由 certbot 定时器触发, 部署钩子 reload actssh-nginx.service
ssl_certificate     ${CERT_FILE};
ssl_certificate_key ${KEY_FILE};
EOF
}

_render_bridge_inc() {
    # 用途: 生成 /ws/ 与 /runner/ 反代片段
    # 参数: $1 输出文件
    # 返回: 无; 退出码: 0
    cat >"$1" <<EOF
# 网页通道片段: 浏览器与 runner 的 WS 反代到宿主桥接 ${BRIDGE_HOST}:${BRIDGE_PORT}
# proxy_pass 末尾不带斜杠, 保留原始 URI, 桥接按路径中的 session_id 配对
location ^~ ${WS_PATH} {
    proxy_pass http://${BRIDGE_HOST}:${BRIDGE_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_connect_timeout 5s;
}

location ^~ ${RUNNER_PATH} {
    proxy_pass http://${BRIDGE_HOST}:${BRIDGE_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_connect_timeout 5s;
}
EOF
}

_render_static_inc() {
    # 用途: 生成网页终端静态资源片段
    # 参数: $1 输出文件
    # 返回: 无; 退出码: 0
    cat >"$1" <<EOF
# 网页终端静态资源: 前端文件放在 ${WEB_ROOT}/actssh/{index.html,dist/}
# /t/<session_id> 一律返回前端 index.html, 由前端 JS 解析会话参数
location ^~ /dist/ {
    root ${WEB_ROOT}/actssh;
    try_files \$uri =404;
    expires 1h;
    add_header Cache-Control "public";
}

location ^~ /t/ {
    root ${WEB_ROOT};
    try_files /actssh/index.html =404;
    add_header Cache-Control "no-store";
}
EOF
}

_render_site_default() {
    # 用途: 生成主入口站点(网页终端 + WS 片段)
    # 参数: $1 输出文件; $2 是否含 TLS(1/0)
    # 返回: 无; 退出码: 0
    local target="$1" tls="$2" redirect
    if (( tls == 1 )); then
        # shellcheck disable=SC2016  # nginx 变量不能由 shell 展开
        redirect='return 301 https://$host$request_uri;'
    else
        redirect='return 503 "TLS certificate is being issued\n";'
    fi
    cat >"$target" <<EOF
# 主入口站点: 网页终端 /t/ 与网页通道 ${WS_PATH} ${RUNNER_PATH}
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        ${redirect}
    }
}
EOF
    if (( tls == 1 )); then
        cat >>"$target" <<EOF

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DOMAIN};

    include conf.d/ssl.conf;
    ssl_session_cache    shared:SSL:10m;
    ssl_session_timeout  5m;
    ssl_ciphers  HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers  on;

    include conf.d/web-bridge-location.inc;
    include conf.d/actssh-web-static.inc;

    location / {
        return 404;
    }
}
EOF
    fi
}

_render_site_www() {
    # 用途: 生成 www.<域名> 到主域名的 301 站点
    # 参数: $1 输出文件; $2 是否含 TLS(1/0)
    # 返回: 无; 退出码: 0
    local target="$1" tls="$2"
    cat >"$target" <<EOF
# www 别名: 统一 301 到 ${DOMAIN}
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name www.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF
    if (( tls == 1 )); then
        cat >>"$target" <<EOF

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name www.${DOMAIN};

    include conf.d/ssl.conf;
    ssl_session_cache    shared:SSL:10m;
    ssl_session_timeout  5m;

    return 301 https://${DOMAIN}\$request_uri;
}
EOF
    fi
}

_render_site_ssh() {
    # 用途: 生成 ssh 入口域名站点, 整体反代到 uptermd 的 WS 端口
    # 参数: $1 输出文件; $2 是否含 TLS(1/0)
    # 返回: 无; 退出码: 0
    local target="$1" tls="$2" redirect cert key
    if (( tls == 1 )); then
        # shellcheck disable=SC2016
        redirect='return 301 https://$host$request_uri;'
    else
        redirect='return 503 "TLS certificate is being issued\n";'
    fi
    cat >"$target" <<EOF
# 网页终端入口域名: 整体反代到 uptermd WS ${WS_BACKEND_HOST}:${WS_BACKEND_PORT}
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${SSH_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        ${redirect}
    }
}
EOF
    if (( tls == 1 )); then
        cert="/etc/letsencrypt/live/${SSH_DOMAIN}/fullchain.pem"
        key="/etc/letsencrypt/live/${SSH_DOMAIN}/privkey.pem"
        cat >>"$target" <<EOF

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${SSH_DOMAIN};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL_ssh:10m;
    ssl_session_timeout 1d;

    location / {
        proxy_pass http://${WS_BACKEND_HOST}:${WS_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
    fi
}

_render_tree() {
    # 用途: 按 conf.d 组织生成主配置与站点文件; tls=0 仅 HTTP 供 ACME, tls=1 追加 TLS 与反代
    # 参数: $1 输出目录; $2 是否包含 TLS(1/0)
    # 返回: 无; 退出码: 0
    local out="$1" tls="$2"
    mkdir -p "${out}/conf.d"
    if [[ "$NGINX_MODE" != "host" ]]; then
        cat >"${out}/nginx.conf" <<EOF
# 由 relay/bootstrap/nginx-cert.sh 生成, 请勿手工编辑
worker_processes auto;
pid ${RUN_DIR}/nginx.pid;
error_log ${LOG_DIR}/error.log warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format actssh '\$remote_addr - \$remote_user [\$time_local] "\$request" \$status '
                      '\$body_bytes_sent "\$http_referer" "\$http_user_agent" \$request_time';
    access_log ${LOG_DIR}/access.log actssh;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;
    client_max_body_size 2m;

    include conf.d/*.conf;
}
EOF
    fi
    _render_site_default "${out}/conf.d/default.conf" "$tls"
    _render_bridge_inc "${out}/conf.d/web-bridge-location.inc"
    _render_static_inc "${out}/conf.d/actssh-web-static.inc"
    if (( tls == 1 )); then
        _render_ssl_conf "${out}/conf.d/ssl.conf"
    fi
    if (( WWW_ALIAS == 1 )); then
        _render_site_www "${out}/conf.d/www.conf" "$tls"
    fi
    if [[ -n "$SSH_DOMAIN" ]]; then
        _render_site_ssh "${out}/conf.d/${SSH_DOMAIN}.conf" "$tls"
    fi
}

_install_unit() {
    # 用途: 安装独立 nginx 单元并重载 systemd; host 模式复用发行版单元, 不安装
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if [[ "$NGINX_MODE" == "host" ]]; then
        _say "host 模式: 复用发行版 ${SERVICE}, 不安装独立单元"
        return 0
    fi
    if (( APPLY == 1 )); then
        bs_apply_file "$UNIT_SRC" "$UNIT_PATH" 0644 root root 1 || _die 7 "nginx.unit.write_failed" "写入单元失败: ${UNIT_PATH}"
        systemctl daemon-reload || _die 7 "nginx.unit.reload_failed" "systemctl daemon-reload 失败"
        systemctl enable "$SERVICE" >/dev/null 2>&1 || _die 7 "nginx.unit.enable_failed" "启用 ${SERVICE} 失败"
    else
        _say "演练: 将安装 ${UNIT_PATH} 并启用 ${SERVICE}"
    fi
}

_managed_conf_files() {
    # 用途: 列出本次需要管理的 conf.d 文件名
    # 参数: $1 是否包含 TLS(1/0)
    # 返回: 标准输出文件名; 退出码: 0
    local tls="$1"
    printf '%s\n' default.conf web-bridge-location.inc actssh-web-static.inc
    if (( tls == 1 )); then
        printf '%s\n' ssl.conf
    fi
    if (( WWW_ALIAS == 1 )); then
        printf '%s\n' www.conf
    fi
    if [[ -n "$SSH_DOMAIN" ]]; then
        printf '%s\n' "${SSH_DOMAIN}.conf"
    fi
}

_norm_config() {
    # 用途: 去掉注释与空行并压缩空白, 用于判断两份配置是否语义等价
    # 参数: $1 配置文件
    # 返回: 标准输出规范化内容; 退出码: 0
    sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' -e '/^#/d' -e '/^$/d' "$1"
}

_config_equivalent() {
    # 用途: 判断两份配置在忽略注释与空白后是否一致
    # 参数: $1 $2 配置文件
    # 返回: 退出码: 0 等价; 1 不同
    diff -q <(_norm_config "$1") <(_norm_config "$2") >/dev/null 2>&1
}

_apply_tree() {
    # 用途: 渲染 conf.d 树; host 模式接管 /etc/nginx/conf.d, dedicated 模式落地独立实例
    #       已存在的等价配置直接采用, 不重写; 写入后 nginx -t, 失败回滚上一版
    # 参数: $1 是否包含 TLS(1/0)
    # 返回: 无; 退出码: 0 或 6
    local tls="$1" stage="${TMP_DIR}/tree-tls${1}" final="${TMP_DIR}/tree-final${1}"
    local backup="${TMP_DIR}/conf-backup-tls${1}.tar" out rel src dst changed=0
    rm -rf "$stage" "$final"
    mkdir -p "$stage" "$final"
    _render_tree "$stage" "$tls"
    if (( APPLY == 0 )); then
        _say "演练: mode=${NGINX_MODE} CONF_DIR=${CONF_DIR}, 只比对不写入"
        if [[ "$NGINX_MODE" == "host" ]]; then
            while IFS= read -r rel; do
                [[ -n "$rel" ]] || continue
                src="${stage}/conf.d/${rel}"
                dst="${CONF_DIR}/conf.d/${rel}"
                if [[ ! -f "$dst" ]]; then
                    _say "演练差异: ${rel} -> 新建"
                elif _config_equivalent "$src" "$dst"; then
                    _say "演练差异: ${rel} -> 采用(规范化后等价)"
                else
                    _say "演练差异: ${rel} -> 将更新(内容不同)"
                fi
            done < <(_managed_conf_files "$tls")
        else
            _say "演练: 将重写独立实例 ${CONF_DIR}/nginx.conf 与 conf.d"
        fi
        return 0
    fi

    if [[ "$NGINX_MODE" == "host" ]]; then
        if [[ -d "${CONF_DIR}/conf.d" ]]; then
            tar -C "$CONF_DIR" -cf "$backup" conf.d \
                || _die 6 "nginx.config.backup" "无法为 ${CONF_DIR}/conf.d 建立回滚缓冲"
        fi
        install -d -m 0755 -o root -g root "${CONF_DIR}/conf.d" \
            || _die 6 "nginx.config.apply" "无法创建目录: ${CONF_DIR}/conf.d"
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            src="${stage}/conf.d/${rel}"
            dst="${CONF_DIR}/conf.d/${rel}"
            if [[ -f "$dst" ]] && _config_equivalent "$src" "$dst"; then
                _say "配置采用(已存在且等价): ${dst}"
                continue
            fi
            install -m 0644 -o root -g root "$src" "$dst" \
                || _die 6 "nginx.config.apply" "写入站点配置失败: ${dst}"
            _say "配置更新: ${dst}"
            changed=1
        done < <(_managed_conf_files "$tls")
        # 清理本次不再生成的已知站点文件, 避免不同形态之间残留
        if (( WWW_ALIAS == 0 )); then rm -f "${CONF_DIR}/conf.d/www.conf"; fi
        if [[ -z "$SSH_DOMAIN" ]]; then rm -f "${CONF_DIR}/conf.d/ssh."*.conf 2>/dev/null || true; fi
        if (( tls == 0 )); then rm -f "${CONF_DIR}/conf.d/ssl.conf"; fi
        # host 模式必须用默认前缀校验: 加 -p 会把 load_module 的相对路径改到 ${CONF_DIR}/modules,
        # 而发行版模块实际在 /usr/lib/nginx/modules, 导致误报配置失败
        if ! out="$("$NGINX_BIN" -t 2>&1)"; then
            rm -rf "${CONF_DIR}/conf.d"
            if [[ -f "$backup" ]]; then
                tar -C "$CONF_DIR" -xf "$backup" || true
            fi
            printf '%s\n' "$out" >&2
            _die 6 "nginx.config.invalid" "落地后宿主 nginx 配置校验失败, 已回滚 conf.d"
        fi
        if (( changed == 1 )); then
            _say "conf.d 已更新, 等待重载 ${SERVICE}"
        else
            _say "conf.d 与期望一致, 未写入任何文件"
        fi
        rm -f "$backup"
        return 0
    fi

    # dedicated: 先在候选目录校验, 再落地独立实例的 nginx.conf 与 conf.d
    if ! out="$("$NGINX_BIN" -t -p "${stage}/" -c "${stage}/nginx.conf" 2>&1)"; then
        printf '%s\n' "$out" >&2
        _die 6 "nginx.config.invalid" "候选 nginx 配置校验失败, 正式配置未变更"
    fi
    if [[ -d "$CONF_DIR" ]]; then
        tar -C "$(dirname "$CONF_DIR")" -cf "$backup" "$(basename "$CONF_DIR")" \
            || _die 6 "nginx.config.backup" "无法为现有配置建立回滚缓冲: ${CONF_DIR}"
    fi
    _render_tree "$final" "$tls"
    install -d -m 0750 -o root -g "$OPS_GROUP" "${CONF_DIR}/conf.d" \
        || _die 6 "nginx.config.apply" "无法创建配置目录: ${CONF_DIR}/conf.d"
    if [[ ! -f "${CONF_DIR}/nginx.conf" ]] || ! _config_equivalent "${final}/nginx.conf" "${CONF_DIR}/nginx.conf"; then
        install -m 0640 -o root -g "$OPS_GROUP" "${final}/nginx.conf" "${CONF_DIR}/nginx.conf" \
            || _die 6 "nginx.config.apply" "写入主配置失败: ${CONF_DIR}/nginx.conf"
        changed=1
    fi
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        src="${final}/conf.d/${rel}"
        dst="${CONF_DIR}/conf.d/${rel}"
        if [[ -f "$dst" ]] && _config_equivalent "$src" "$dst"; then
            continue
        fi
        install -m 0640 -o root -g "$OPS_GROUP" "$src" "$dst" \
            || _die 6 "nginx.config.apply" "写入站点配置失败: ${dst}"
        changed=1
    done < <(_managed_conf_files "$tls")
    if (( WWW_ALIAS == 0 )); then rm -f "${CONF_DIR}/conf.d/www.conf"; fi
    if [[ -z "$SSH_DOMAIN" ]]; then rm -f "${CONF_DIR}/conf.d/ssh."*.conf 2>/dev/null || true; fi
    if (( tls == 0 )); then rm -f "${CONF_DIR}/conf.d/ssl.conf"; fi
    if ! out="$("$NGINX_BIN" -t -p "${CONF_DIR}/" -c "${CONF_DIR}/nginx.conf" 2>&1)"; then
        rm -rf "$CONF_DIR"
        if [[ -f "$backup" ]]; then
            tar -C "$(dirname "$CONF_DIR")" -xf "$backup" || true
        fi
        printf '%s\n' "$out" >&2
        _die 6 "nginx.config.invalid" "落地后 nginx 配置校验失败, 已回滚上一版配置"
    fi
    if (( changed == 0 )); then
        _say "配置与期望一致, 未写入任何文件"
    fi
    rm -f "$backup"
}

_reload_unit() {
    # 用途: 启动或重载本实例, 并等待端口进入监听
    # 参数: $1 需要等待的端口
    # 返回: 无; 退出码: 0 或 7 或 10
    local port="$1" i
    if (( APPLY == 0 )); then
        _say "演练: 将启动或重载 ${SERVICE}, 并等待端口 ${port} 监听"
        return 0
    fi
    if systemctl is-active --quiet "$SERVICE"; then
        if ! systemctl reload "$SERVICE"; then
            _die 10 "nginx.reload.failed" "重载 ${SERVICE} 失败"
        fi
    else
        if ! systemctl start "$SERVICE"; then
            systemctl --no-pager --lines=20 status "$SERVICE" >&2 || true
            _die 7 "nginx.start.failed" "启动 ${SERVICE} 失败"
        fi
    fi
    for (( i = 1; i <= 15; i++ )); do
        if bs_listen_ok "$port"; then
            return 0
        fi
        sleep 1
    done
    _die 7 "nginx.listen.timeout" "等待端口 ${port} 监听超时"
}

_cert_paths() {
    # 用途: 按证书模式输出证书与私钥路径
    # 参数: 无
    # 返回: 无; 副作用: 设置 CERT_FILE 与 KEY_FILE
    if [[ "$CERT_MODE" != "self-signed" ]]; then
        CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    else
        CERT_FILE="${CERT_DIR}/fullchain.pem"
        KEY_FILE="${CERT_DIR}/key.pem"
    fi
}

_issue_self_signed() {
    # 用途: 生成自签证书, 仅用于无公网 DNS 的实验环境
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8
    local san
    if [[ "$DOMAIN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        san="IP:${DOMAIN}"
    else
        san="DNS:${DOMAIN}"
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将生成自签证书 ${CERT_FILE} (SAN=${san}, 90 天)"
        return 0
    fi
    _say "生成自签证书: ${CERT_FILE}"
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/CN=${DOMAIN}" -addext "subjectAltName=${san}" >/dev/null 2>&1; then
        _die 8 "nginx.cert.selfsigned_failed" "自签证书生成失败: ${CERT_FILE}"
    fi
    chmod 0600 "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
}

_cert_ready() {
    # 用途: 判断证书是否存在且剩余有效期超过 30 天
    # 参数: $1 证书路径
    # 返回: 退出码: 0 可用; 1 需要签发
    [[ -f "$1" ]] && openssl x509 -checkend 2592000 -noout -in "$1" >/dev/null 2>&1
}

_issue_acme() {
    # 用途: 用 certbot 签发主域名与可选 ssh 域名两张独立证书; acme 走 webroot 不停服, standalone 临时停本方案 nginx 独占 80
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8
    local -a base main_args ssh_args
    local ssh_cert="/etc/letsencrypt/live/${SSH_DOMAIN}/fullchain.pem"
    local need_main=1 need_ssh=0
    if _cert_ready "$CERT_FILE"; then
        need_main=0
    fi
    if [[ -n "$SSH_DOMAIN" ]]; then
        need_ssh=1
        if _cert_ready "$ssh_cert"; then
            need_ssh=0
        fi
    fi
    if (( need_main == 0 && need_ssh == 0 )); then
        _say "证书仍有效超过 30 天, 跳过签发: ${CERT_FILE}${SSH_DOMAIN:+ 与 ${ssh_cert}}"
        return 0
    fi
    if (( APPLY == 0 )); then
        if [[ "$CERT_MODE" == "standalone" ]]; then
            _say "演练: 将临时停止 actssh-nginx.service, 用 --standalone 为 ${DOMAIN}${SSH_DOMAIN:+, ${SSH_DOMAIN}} 签发"
        else
            _say "演练: 将用 --webroot ${ACME_ROOT} 为 ${DOMAIN}${SSH_DOMAIN:+, ${SSH_DOMAIN}} 签发"
        fi
        return 0
    fi
    if [[ "$CERT_MODE" == "standalone" ]]; then
        # 先让出 80 端口, 校验期间由 certbot 自己监听
        if ! systemctl stop actssh-nginx.service; then
            _die 8 "nginx.cert.stop_failed" "standalone 签发前无法停止 actssh-nginx.service"
        fi
        if ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; then
            systemctl start actssh-nginx.service >/dev/null 2>&1 || true
            _die 8 "nginx.cert.port_busy" "停止本方案 nginx 后 80 端口仍被占用, 无法使用 standalone"
        fi
        base=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring)
    else
        base=(certonly --webroot -w "$ACME_ROOT" --non-interactive --agree-tos --keep-until-expiring)
    fi
    if (( ACME_STAGING == 1 )); then
        base+=(--staging)
    fi
    # 自签模式不走本函数; 其余模式邮箱必填, 由 _validate 保证
    base+=(-m "$ACME_EMAIL")

    if (( need_main == 1 )); then
        main_args=("${base[@]}" --cert-name "$DOMAIN" -d "$DOMAIN")
        if (( WWW_ALIAS == 1 )); then
            main_args+=(-d "www.${DOMAIN}" --expand)
        fi
        _say "申请证书: ${DOMAIN} (mode=${CERT_MODE} staging=${ACME_STAGING})"
        if ! "$CERTBOT_BIN" "${main_args[@]}"; then
            # standalone 失败时也要把 nginx 拉起来, 否则站点整体不可用
            if [[ "$CERT_MODE" == "standalone" ]]; then
                systemctl start actssh-nginx.service >/dev/null 2>&1 || true
            fi
            _die 8 "nginx.cert.acme_failed" \
                "certbot 签发失败; 检查 DNS 是否指向本机, 80 端口是否公网可达, 以及 ACME 配额"
        fi
        if [[ ! -f "$CERT_FILE" ]]; then
            _die 8 "nginx.cert.missing_after_issue" "certbot 返回成功但证书不存在: ${CERT_FILE}"
        fi
    fi
    if (( need_ssh == 1 )); then
        ssh_args=("${base[@]}" --cert-name "$SSH_DOMAIN" -d "$SSH_DOMAIN")
        _say "申请证书: ${SSH_DOMAIN} (mode=${CERT_MODE} staging=${ACME_STAGING})"
        if ! "$CERTBOT_BIN" "${ssh_args[@]}"; then
            if [[ "$CERT_MODE" == "standalone" ]]; then
                systemctl start actssh-nginx.service >/dev/null 2>&1 || true
            fi
            _die 8 "nginx.cert.acme_failed" \
                "ssh 域名证书签发失败: ${SSH_DOMAIN}; 检查 DNS 与 80 端口可达性"
        fi
        if [[ ! -f "$ssh_cert" ]]; then
            _die 8 "nginx.cert.missing_after_issue" "certbot 返回成功但证书不存在: ${ssh_cert}"
        fi
    fi
    if [[ "$CERT_MODE" == "standalone" ]]; then
        systemctl start actssh-nginx.service || _die 8 "nginx.cert.start_failed" "签发后无法启动 actssh-nginx.service"
    fi
}

_install_renewal() {
    # 用途: 安装续期后重载钩子, 并启用 certbot 定时器或 cron 兜底
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="${hook_dir}/actssh-nginx-reload"
    local cron_file="/etc/cron.d/actssh-certbot"
    local tmp
    if [[ "$CERT_MODE" == "self-signed" ]]; then
        _say "自签模式不安装续期定时器"
        return 0
    fi
    tmp="$(mktemp "${TMP_DIR}/renew-hook.XXXXXX")"
    if [[ "$NGINX_MODE" == "host" ]]; then
        # 现有谱系已用 renew_hook 逐条 reload 时不再叠加部署钩子, 避免重复重载
        if grep -qE '^[[:space:]]*renew_hook[[:space:]]*=' /etc/letsencrypt/renewal/*.conf 2>/dev/null; then
            _say "检测到现有 renewal 配置自带 renew_hook, 沿用宿主 nginx 重载方式"
        else
            cat >"$tmp" <<'EOF'
#!/bin/sh
# 由 relay/bootstrap/nginx-cert.sh 生成: 证书续期后重载宿主 nginx
# 钩子失败不得让 certbot 续期整体失败, 因此显式忽略返回码
systemctl reload nginx.service || true
EOF
        fi
    else
        cat >"$tmp" <<'EOF'
#!/bin/sh
# 由 relay/bootstrap/nginx-cert.sh 生成: 证书续期后重载独立 nginx 实例
# 钩子失败不得让 certbot 续期整体失败, 因此显式忽略返回码
systemctl reload actssh-nginx.service || true
EOF
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将安装续期钩子 ${hook} 并启用 certbot 续期"
        return 0
    fi
    bs_ensure_dir "$hook_dir" 0755 root root 1 || _die 8 "nginx.renew.hook_dir" "无法创建续期钩子目录"
    if [[ -s "$tmp" ]]; then
        bs_apply_file "$tmp" "$hook" 0755 root root 1 || _die 8 "nginx.renew.hook_write" "写入续期钩子失败"
    fi
    if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then
        systemctl enable --now certbot.timer >/dev/null 2>&1 || _die 8 "nginx.renew.timer" "启用 certbot.timer 失败"
        _say "已启用 certbot.timer"
        return 0
    fi
    if [[ -f /etc/cron.d/certbot ]]; then
        _say "使用发行版自带的 /etc/cron.d/certbot 续期"
        return 0
    fi
    # 既无 timer 也无发行版 cron 时补一条最小 cron, 保证自动续期存在
    printf '%s\n' '17 3 * * * root /usr/bin/certbot renew -q' >"$tmp"
    bs_apply_file "$tmp" "$cron_file" 0644 root root 1 || _die 8 "nginx.renew.cron" "写入续期 cron 失败"
    _say "已写入续期 cron: ${cron_file}"
}

_summary() {
    # 用途: 输出证书有效期与入口地址
    # 参数: 无
    # 返回: 无; 退出码: 0
    local days
    if [[ -f "$CERT_FILE" ]]; then
        days="$(bs_cert_days_left "$CERT_FILE" || echo '未知')"
        _say "证书有效期: notAfter=$(bs_cert_not_after "$CERT_FILE") 剩余天数=${days}"
    fi
    _say "入口: https://${DOMAIN}:${HTTPS_PORT}${WS_PATH} 与 ${RUNNER_PATH} 反代到 ${BRIDGE_HOST}:${BRIDGE_PORT}"
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
trap '_on_error $? $LINENO "$BASH_COMMAND"' ERR
trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_parse_args "$@"
_validate
bs_init_logging "$LOGGER" "$LOG_ROOT" "$RUN_ID"
bs_require_root
bs_require_cmds install systemctl ss openssl awk sed grep tar
if [[ "$CERT_MODE" != "self-signed" ]]; then
    bs_require_cmds "$CERTBOT_BIN"
else
    bs_require_cmds openssl
fi
if (( APPLY == 1 )); then
    bs_require_cmds "$NGINX_BIN"
fi

TMP_DIR="$(mktemp -d)"
_cert_paths
_say "=== nginx 与证书 (apply=${APPLY} domain=${DOMAIN} mode=${CERT_MODE}) ==="
_log INFO "nginx.start" "开始配置 nginx 与证书" \
    "{\"domain\":\"${DOMAIN}\",\"cert_mode\":\"${CERT_MODE}\",\"apply\":${APPLY}}"

_ensure_dirs
_guard_distro_sites
_guard_ports
_stop_distro_nginx
_install_unit

if [[ ! -f "$CERT_FILE" ]]; then
    # 阶段一: 仅 HTTP, 让 ACME 校验可达; 自签模式则直接生成证书
    _apply_tree 0
    _reload_unit "$HTTP_PORT"
    if [[ "$CERT_MODE" != "self-signed" ]]; then
        _issue_acme
    else
        _issue_self_signed
    fi
elif [[ -n "$SSH_DOMAIN" && ! -f "/etc/letsencrypt/live/${SSH_DOMAIN}/fullchain.pem" ]]; then
    # 主证书已在, 仅补 ssh 域名证书; 不切回 HTTP-only, 避免中断现有 443
    _issue_acme
fi

# 阶段二: 完整 TLS 配置与反向代理
_apply_tree 1
_reload_unit "$HTTPS_PORT"

# 证书临近到期时在完整配置已生效的前提下补一次续期
if [[ "$CERT_MODE" != "self-signed" ]]; then
    days="$(bs_cert_days_left "$CERT_FILE" || echo 0)"
    if (( days < 30 )); then
        _issue_acme
        _reload_unit "$HTTPS_PORT"
    fi
    _install_renewal
fi

_summary
_log INFO "nginx.done" "nginx 与证书配置完成" "{\"domain\":\"${DOMAIN}\"}"
exit 0

#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : nginx-cert.sh
# 所属目录    : deploy/bootstrap/
# 文件用途    : 在空机器上落地独立 nginx 实例与 HTTPS 入口, 用 certbot HTTP-01 签发并自动续期证书
# 架构定位    : 部署脚本 TLS 层; 上游是 deploy/bootstrap.sh, 下游是 actssh-nginx.service 与 certbot 续期定时器
# 核心功能    : 独立配置目录与单元安装, 80 端口占用判定, 两阶段配置(先 ACME 后 TLS), 证书签发与续期钩子, 配置校验与重载
# 职责边界    : 不改 /etc/nginx/sites-enabled, 不接管发行版站点, 不迁移既有 80/443 占用, 不写云安全组, 不打印任何私钥
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行, 需可出网访问 ACME 目录
# 依赖关系    : 依赖 nginx, certbot, openssl, systemctl, ss, curl, jq; 由 deploy/bootstrap.sh 调用
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
#               --web-root <dir>      可选静态站点根目录; 缺省时根路径返回 404
#               --acme-root <dir>     HTTP-01 校验目录, 默认 /var/www/actssh-acme
#               --cert-dir <dir>      self-signed 证书目录, 默认 /etc/actssh/tls
#               --ops-group <group>   运维只读组, 默认 actssh-ops
#               --apply               实际写入并启停; 缺省只演练
# 退出码      : 0 成功; 2 参数非法; 3 依赖缺失; 4 非 root; 5 目录或权限准备失败;
#               6 nginx 配置校验失败; 7 单元启动或端口监听失败; 8 证书签发失败;
#               9 80/443 被外部占用或存在既有站点; 10 重载失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/bootstrap/lib.sh
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
ACME_EMAIL="${ACTSSH_ACME_EMAIL:-}"
ACME_STAGING=0
HTTP_PORT="${ACTSSH_HTTP_PORT:-80}"
HTTPS_PORT="${ACTSSH_HTTPS_PORT:-443}"
BRIDGE_HOST="${ACTSSH_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${ACTSSH_BRIDGE_PORT:-8081}"
WEB_ROOT="${ACTSSH_WEB_ROOT:-}"
ACME_ROOT="${ACTSSH_ACME_ROOT:-/var/www/actssh-acme}"
CERT_DIR="${ACTSSH_CERT_DIR:-/etc/actssh/tls}"
OPS_GROUP="${ACTSSH_OPS_GROUP:-actssh-ops}"
CONF_DIR="${ACTSSH_NGINX_CONF_DIR:-/etc/actssh/nginx}"
LOG_DIR="${ACTSSH_NGINX_LOG_DIR:-/var/log/actssh/nginx}"
UNIT_SRC="${SCRIPT_DIR}/actssh-nginx.service"
UNIT_PATH="/etc/systemd/system/actssh-nginx.service"
NGINX_BIN="${ACTSSH_NGINX_BIN:-/usr/sbin/nginx}"
CERTBOT_BIN="${ACTSSH_CERTBOT_BIN:-/usr/bin/certbot}"
SERVICE="actssh-nginx.service"
RUN_DIR="/run/actssh-nginx"
APPLY=0

LOGGER="deploy.bootstrap.nginx_cert"
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
  --acme-email <mail>      ACME 注册邮箱, 可省略
  --staging                使用 ACME 预发布目录
  --http-port <port>       HTTP 端口, 默认 80
  --https-port <port>      HTTPS 端口, 默认 443
  --bridge-host <host>     WS 上游地址, 默认 127.0.0.1
  --bridge-port <port>     WS 上游端口, 默认 8081
  --web-root <dir>         静态站点根目录, 可省略
  --acme-root <dir>        HTTP-01 校验目录, 默认 /var/www/actssh-acme
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
            --acme-email) ACME_EMAIL="${2:?缺少 --acme-email 取值}"; shift 2 ;;
            --staging) ACME_STAGING=1; shift ;;
            --http-port) HTTP_PORT="${2:?缺少 --http-port 取值}"; shift 2 ;;
            --https-port) HTTPS_PORT="${2:?缺少 --https-port 取值}"; shift 2 ;;
            --bridge-host) BRIDGE_HOST="${2:?缺少 --bridge-host 取值}"; shift 2 ;;
            --bridge-port) BRIDGE_PORT="${2:?缺少 --bridge-port 取值}"; shift 2 ;;
            --web-root) WEB_ROOT="${2:?缺少 --web-root 取值}"; shift 2 ;;
            --acme-root) ACME_ROOT="${2:?缺少 --acme-root 取值}"; shift 2 ;;
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
    bs_require_port "http-port" "$HTTP_PORT"
    bs_require_port "https-port" "$HTTPS_PORT"
    bs_require_port "bridge-port" "$BRIDGE_PORT"
    if [[ "$HTTP_PORT" == "$HTTPS_PORT" ]]; then
        _die 2 "nginx.args.port_conflict" "HTTP 与 HTTPS 端口不能相同: ${HTTP_PORT}"
    fi
    if [[ "$HTTP_PORT" == "$BRIDGE_PORT" || "$HTTPS_PORT" == "$BRIDGE_PORT" ]]; then
        _die 2 "nginx.args.port_conflict" "入口端口不能与 WS 上游端口相同: ${BRIDGE_PORT}"
    fi
    if [[ -n "$WEB_ROOT" && ! -d "$WEB_ROOT" ]]; then
        _die 2 "nginx.args.web_root_missing" "静态站点目录不存在: ${WEB_ROOT}"
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
    bs_ensure_dir "$CONF_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建配置目录: ${CONF_DIR}"
    bs_ensure_dir "$LOG_DIR" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建日志目录: ${LOG_DIR}"
    bs_ensure_dir "$ACME_ROOT" 0755 root root "$APPLY" || _die 5 "nginx.dirs.failed" "无法创建校验目录: ${ACME_ROOT}"
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
                "检测到既有 nginx 站点: /etc/nginx/sites-enabled/${base}; 本脚本不接管既有站点, 请按 deploy/README.md 迁移节处理"
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
    # 用途: 停用发行版 nginx 单元, 避免与本实例抢 80/443
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
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

_render_conf() {
    # 用途: 生成 nginx 主配置; tls=0 时只监听 HTTP 用于 ACME, tls=1 时追加 TLS 与反代
    # 参数: $1 输出文件; $2 是否包含 TLS(1/0)
    # 返回: 无; 退出码: 0
    local target="$1" tls="$2" acme_redirect
    if (( tls == 1 )); then
        # shellcheck disable=SC2016  # $host 与 $request_uri 是 nginx 变量, 不能由 shell 展开
        acme_redirect='return 301 https://$host$request_uri;'
    else
        acme_redirect='return 503 "TLS certificate is being issued\n";'
    fi
    cat >"$target" <<EOF
# 由 deploy/bootstrap/nginx-cert.sh 生成, 请勿手工编辑
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
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen ${HTTP_PORT} default_server;
        server_name _;
        location /.well-known/acme-challenge/ {
            root ${ACME_ROOT};
            try_files \$uri =404;
        }
        location / {
            return 444;
        }
    }

    server {
        listen ${HTTP_PORT};
        server_name ${DOMAIN};
        location /.well-known/acme-challenge/ {
            root ${ACME_ROOT};
            try_files \$uri =404;
        }
        location / {
            ${acme_redirect}
        }
    }
EOF
    if (( tls == 1 )); then
        cat >>"$target" <<EOF

    server {
        listen ${HTTPS_PORT} ssl http2;
        server_name ${DOMAIN};

        ssl_certificate ${CERT_FILE};
        ssl_certificate_key ${KEY_FILE};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:ACTSSH:10m;
        ssl_session_timeout 1h;
        add_header X-Content-Type-Options nosniff always;

        location /ws/ {
            proxy_pass http://${BRIDGE_HOST}:${BRIDGE_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }

        location /runner/ {
            proxy_pass http://${BRIDGE_HOST}:${BRIDGE_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }
EOF
        if [[ -n "$WEB_ROOT" ]]; then
            cat >>"$target" <<EOF

        location /dist/ {
            root ${WEB_ROOT};
            try_files \$uri =404;
        }

        location / {
            root ${WEB_ROOT};
            index index.html;
            try_files \$uri \$uri/ /index.html;
        }
    }
EOF
        else
            cat >>"$target" <<'EOF'

        location / {
            return 404 "actssh web assets are not deployed on this host\n";
        }
    }
EOF
        fi
    fi
    printf '}\n' >>"$target"
}

_install_unit() {
    # 用途: 安装独立 nginx 单元并重载 systemd
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if (( APPLY == 1 )); then
        bs_apply_file "$UNIT_SRC" "$UNIT_PATH" 0644 root root 1 || _die 7 "nginx.unit.write_failed" "写入单元失败: ${UNIT_PATH}"
        systemctl daemon-reload || _die 7 "nginx.unit.reload_failed" "systemctl daemon-reload 失败"
        systemctl enable "$SERVICE" >/dev/null 2>&1 || _die 7 "nginx.unit.enable_failed" "启用 ${SERVICE} 失败"
    else
        _say "演练: 将安装 ${UNIT_PATH} 并启用 ${SERVICE}"
    fi
}

_apply_conf() {
    # 用途: 先用候选文件做 nginx -t, 通过后原子替换正式配置
    # 参数: $1 候选配置文件
    # 返回: 无; 退出码: 0 或 6
    local candidate="$1" stage="${CONF_DIR}/.nginx.conf.stage" out
    if (( APPLY == 0 )); then
        _say "演练: 候选配置如下, 未做 nginx -t"
        sed 's/^/    /' "$candidate"
        return 0
    fi
    install -m 0640 -o root -g "$OPS_GROUP" "$candidate" "$stage"
    if ! out="$("$NGINX_BIN" -t -c "$stage" 2>&1)"; then
        rm -f "$stage"
        printf '%s\n' "$out" >&2
        _die 6 "nginx.config.invalid" "nginx 配置校验失败, 正式配置未变更"
    fi
    mv -f "$stage" "${CONF_DIR}/nginx.conf"
    chmod 0640 "${CONF_DIR}/nginx.conf"
    chown "root:${OPS_GROUP}" "${CONF_DIR}/nginx.conf"
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

_issue_acme() {
    # 用途: 用 certbot 签发证书; acme 走 webroot 不停服, standalone 临时停本方案 nginx 独占 80; 已有证书未到期时跳过
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8
    local -a args
    if [[ -f "$CERT_FILE" ]] && openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
        _say "证书仍有效超过 30 天, 跳过签发: ${CERT_FILE}"
        return 0
    fi
    if (( APPLY == 0 )); then
        if [[ "$CERT_MODE" == "standalone" ]]; then
            _say "演练: 将临时停止 actssh-nginx.service, 执行 certbot certonly --standalone -d ${DOMAIN}, 再启动 nginx"
        else
            _say "演练: 将执行 certbot certonly --webroot -w ${ACME_ROOT} -d ${DOMAIN}"
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
        args=(certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring
            --pre-hook "systemctl stop actssh-nginx.service || true"
            --post-hook "systemctl start actssh-nginx.service || true")
    else
        args=(certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring)
    fi
    if (( ACME_STAGING == 1 )); then
        args+=(--staging)
    fi
    if [[ -n "$ACME_EMAIL" ]]; then
        args+=(-m "$ACME_EMAIL")
    else
        args+=(--register-unsafely-without-email)
    fi
    _say "申请证书: ${DOMAIN} (mode=${CERT_MODE} staging=${ACME_STAGING})"
    if ! "$CERTBOT_BIN" "${args[@]}"; then
        # standalone 失败时也要把 nginx 拉起来, 否则站点整体不可用
        if [[ "$CERT_MODE" == "standalone" ]]; then
            systemctl start actssh-nginx.service >/dev/null 2>&1 || true
        fi
        _die 8 "nginx.cert.acme_failed" \
            "certbot 签发失败; 检查 DNS 是否指向本机, 80 端口是否公网可达, 以及 ACME 配额"
    fi
    if [[ "$CERT_MODE" == "standalone" ]]; then
        systemctl start actssh-nginx.service || _die 8 "nginx.cert.start_failed" "签发后无法启动 actssh-nginx.service"
    fi
    if [[ ! -f "$CERT_FILE" ]]; then
        _die 8 "nginx.cert.missing_after_issue" "certbot 返回成功但证书不存在: ${CERT_FILE}"
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
    cat >"$tmp" <<'EOF'
#!/bin/sh
# 由 deploy/bootstrap/nginx-cert.sh 生成: 证书续期后重载独立 nginx 实例
# 钩子失败不得让 certbot 续期整体失败, 因此显式忽略返回码
systemctl reload actssh-nginx.service || true
EOF
    if (( APPLY == 0 )); then
        _say "演练: 将安装续期钩子 ${hook} 并启用 certbot 续期"
        return 0
    fi
    bs_ensure_dir "$hook_dir" 0755 root root 1 || _die 8 "nginx.renew.hook_dir" "无法创建续期钩子目录"
    bs_apply_file "$tmp" "$hook" 0755 root root 1 || _die 8 "nginx.renew.hook_write" "写入续期钩子失败"
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
    _say "入口: https://${DOMAIN}:${HTTPS_PORT}/ws/ 与 /runner/ 反代到 ${BRIDGE_HOST}:${BRIDGE_PORT}"
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
bs_require_cmds install systemctl ss openssl awk sed grep
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

if [[ -f "$CERT_FILE" ]] && openssl x509 -checkend 86400 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
    : # 证书可用时直接进入完整配置, 避免无谓的两阶段切换
else
    # 阶段一: 仅 HTTP, 让 ACME 校验可达; 自签模式则直接生成证书
    _render_conf "${TMP_DIR}/nginx.http.conf" 0
    _apply_conf "${TMP_DIR}/nginx.http.conf"
    _reload_unit "$HTTP_PORT"
    if [[ "$CERT_MODE" != "self-signed" ]]; then
        _issue_acme
    else
        _issue_self_signed
    fi
fi

# 阶段二: 完整 TLS 配置与反向代理
_render_conf "${TMP_DIR}/nginx.full.conf" 1
_apply_conf "${TMP_DIR}/nginx.full.conf"
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

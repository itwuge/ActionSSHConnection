#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : bootstrap.sh
# 所属目录    : deploy/
# 文件用途    : 在一台干净的 Ubuntu 20.04 / 22.04 x86_64 上, 用一条命令从零装完 ActSSH 中继与网页桥接, 并做收尾自检
# 架构定位    : 部署编排层; 上游是运维人员, 下游是 nginx-cert.sh, install-uptermd.sh, web-bridge.sh, firewall.sh, selfcheck.sh
# 核心功能    : 前置校验, 端口冲突判定, 分步执行与计时, 变更前备份, 防火墙演练或落地, 收尾自检, 失败回滚
# 职责边界    : 不改系统 sshd 端口, 不改云安全组, 不迁移既有服务占用, 不接管发行版 nginx 站点, 不打印任何凭据
# 运行环境    : Ubuntu 20.04 与 22.04, x86_64, bash 5.x, 以 root 执行, 需出网访问 apt, GitHub Releases, PyPI, ACME
# 依赖关系    : 依赖 apt-get, systemctl, ss, jq, curl, nginx, certbot, python3-venv; 由本脚本自行安装
#
# 输入        : 命令行参数优先, 未给出时读取同名环境变量
#               --domain <fqdn>       证书域名, 必填; 回滚与 relay-only 时不需要
#               --acme-email <mail>   ACME 注册邮箱, 可省略; --email 为别名
#               --acme-staging        使用 ACME 预发布目录
#               --cert-mode <mode>    acme 或 self-signed; self-signed 仅用于无公网 DNS 的实验环境
#               --web-root <dir>      可选网页终端静态目录; 缺省时根路径返回 404
#               --admin-cidr <cidr>   允许访问管理面 SSH 的来源, 可重复; 防火墙落地时必填
#               --allow-admin-anywhere 管理面不限来源, 仅限临时排障
#               --rate-limit-ssh      对 SSH 与 WS 入口按源限速, 仅 ufw 后端有效
#               --ops-user <name>     加入 actssh-ops 只读组的既有账号, 缺省取 SUDO_USER
#               --admin-ssh-port <p>  系统 sshd 端口, 默认 22, 不修改; --ssh-port 为别名
#               --relay-port <p>      uptermd SSH 端口, 默认 2222; --uptermd-port 为别名
#               --uptermd-version <v> 待安装 uptermd 版本, 默认 v0.41.1
#               --relay-only          只装中继: 不装 nginx, 证书, 网页桥接
#               --with-direct         中继 SSH 直连对外, 默认
#               --no-direct           中继 SSH 只监听环回, 关闭直连
#               --bridge-wheelhouse <dir> 离线 pip wheel 目录, 供无外网环境安装桥接依赖
#               --upgrade             版本升级: 读取上次参数, 备份后重跑全部幂等步骤, 失败自动回滚
#               --http-port <p>       HTTP 端口, 默认 80
#               --https-port <p>      HTTPS 端口, 默认 443
#               --bridge-port <p>     桥接监听端口, 默认 8081
#               --ws-backend-port <p> uptermd WS 上游端口, 默认 8443
#               --metrics-port <p>    指标端口, 默认 9100
#               --state-dir <dir>     状态, 备份与日志根目录, 默认 /var/lib/actssh-bootstrap
#               --skip-firewall       本次不处理防火墙
#               --apply               实际安装与生效; 缺省只演练
#               --rollback            回滚; 需再给 --apply 才执行, 否则只打印计划
# 退出码      : 0 成功或演练完成; 2 参数非法; 3 系统或架构不支持; 4 非 root 或存在锁死风险;
#               5 软件包安装失败; 6 依赖缺失; 7 未预期错误; 8 端口冲突; 9 既有站点或 80/443 被外部占用;
#               10 nginx 与证书步骤失败; 11 uptermd 步骤失败; 12 桥接步骤失败; 13 防火墙步骤失败;
#               14 收尾自检失败; 15 回滚失败; 16 升级前置条件不满足; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/bootstrap/lib.sh
source "${SCRIPT_DIR}/bootstrap/lib.sh"

# =========** 方法一览 =========**
#   _log / _say / _die / _on_error -> 日志与终止
#   _parse_args -> 0/2: 解析参数
#   _validate_args -> 0/2: 参数组合与端口校验
#   _check_os -> 0/3: 发行版, 版本与架构
#   _preflight_ports -> 0/8/9: 逐端口判定占用归属
#   _check_admin_source -> 0/4: 防火墙落地前防锁死
#   _prepare_state -> 0/5: 状态目录与日志初始化
#   _prepare_backup -> 0/7: 变更前备份与清单
#   _step_packages -> 0/5: 安装软件包与运维组
#   _step_nginx -> 0/10: 独立 nginx, 证书与日志轮转
#   _step_uptermd -> 0/11: uptermd 与单元
#   _step_bridge -> 0/12: 桥接用户, venv 与单元
#   _step_firewall -> 0/13: 防火墙演练或落地
#   _step_selfcheck -> 0/14: 收尾自检
#   _run_step <name> <exit-code> <fn> -> 分步计时与退出码映射
#   _load_previous -> 0/16: 升级时补齐上次参数
#   _print_ports -> 0: 打印端口与目录对照
#   _summary -> 0: 输出分步结果
#   _run_rollback -> 0/15: 按备份清单回滚
#   _cleanup -> 0: 删除临时文件

# =========** 常量与默认值 =========**
DOMAIN="${ACTSSH_DOMAIN:-}"
ACME_EMAIL="${ACTSSH_ACME_EMAIL:-}"
ACME_STAGING=0
CERT_MODE="${ACTSSH_CERT_MODE:-acme}"
WEB_ROOT="${ACTSSH_WEB_ROOT:-}"
ADMIN_CIDRS=()
ALLOW_ADMIN_ANYWHERE=0
RATE_LIMIT_SSH=0
OPS_USER="${ACTSSH_OPS_USER:-${SUDO_USER:-}}"
DEPLOY_MODE="${ACTSSH_DEPLOY_MODE:-full}"
WITH_DIRECT="${ACTSSH_WITH_DIRECT:-1}"
UPGRADE=0
UPTERMD_VERSION_ARG="${ACTSSH_UPTERMD_VERSION:-}"
BRIDGE_WHEELHOUSE="${ACTSSH_BRIDGE_WHEELHOUSE:-}"
ADMIN_SSH_PORT="${ACTSSH_ADMIN_SSH_PORT:-22}"
RELAY_PORT="${ACTSSH_RELAY_SSH_PORT:-2222}"
HTTP_PORT="${ACTSSH_HTTP_PORT:-80}"
HTTPS_PORT="${ACTSSH_HTTPS_PORT:-443}"
BRIDGE_PORT="${ACTSSH_BRIDGE_PORT:-8081}"
WS_BACKEND_PORT="${ACTSSH_WS_BACKEND_PORT:-8443}"
METRICS_PORT="${ACTSSH_METRICS_PORT:-9100}"
PUBLIC_BIND="${ACTSSH_PUBLIC_BIND:-0.0.0.0}"
STATE_DIR="${ACTSSH_STATE_DIR:-/var/lib/actssh-bootstrap}"
OPS_GROUP="${ACTSSH_OPS_GROUP:-actssh-ops}"
ACME_ROOT="${ACTSSH_ACME_ROOT:-/var/www/actssh-acme}"

APPLY=0
ROLLBACK=0
SKIP_FIREWALL=0

# 基础包在任何形态都需要; 网页包只在 full 形态安装
BASE_PACKAGES=(
    curl
    jq
    ca-certificates
    openssl
    ufw
    openssh-server
    openssh-client
)
WEB_PACKAGES=(
    nginx
    certbot
    python3
    python3-venv
    python3-pip
    logrotate
)
PACKAGES=()

LOGGER="deploy.bootstrap"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
LOG_ROOT=""
BACKUP_DIR=""
BACKUP_POINTER=""
LAST_BACKUP=""
TMP_DIR=""
STEP_ROWS=()
FIREWALL_RESULT="未处理"
AUTO_ROLLBACK=0
RELAY_BIND="${PUBLIC_BIND}"
declare -A EXPLICIT=()

# =========** 参数校验 =========**
_on_error() {
    # 用途: ERR 钩子包装, 转交公共库统一记录并退出 7
    # 参数: $1 退出码; $2 行号; $3 失败命令
    # 返回: 不返回
    bs_on_error "$@"
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

show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: bootstrap.sh --domain <fqdn> [选项]
      bootstrap.sh --rollback [--apply]

从零部署 (默认演练, --apply 才落地):
  --domain <fqdn>          证书域名, full 形态必填
  --acme-email <mail>      ACME 注册邮箱, 可省略; 别名 --email
  --acme-staging           使用 ACME 预发布目录
  --cert-mode <mode>       acme 或 self-signed, 默认 acme
  --web-root <dir>         可选静态站点目录
  --relay-only             只装中继: 不装 nginx, 证书, 网页桥接
  --with-direct            中继 SSH 直连对外, 默认
  --no-direct              中继 SSH 只监听环回, 关闭直连
  --uptermd-version <v>    待安装 uptermd 版本, 默认 v0.41.1
  --bridge-wheelhouse <d>  离线 pip wheel 目录
  --upgrade                升级: 读取上次参数, 备份后重跑, 失败自动回滚
  --admin-cidr <cidr>      管理面 SSH 允许来源, 可重复; 防火墙落地时必填
  --allow-admin-anywhere   管理面不限来源, 仅限临时排障
  --rate-limit-ssh         对 SSH 与 WS 入口按源限速, 仅 ufw 有效
  --ops-user <name>        加入 actssh-ops 只读组的既有账号
  --admin-ssh-port <p>     sshd 端口, 默认 22; 别名 --ssh-port
  --relay-port <p>         uptermd SSH 端口, 默认 2222; 别名 --uptermd-port
  --http-port <p>          HTTP 端口, 默认 80
  --https-port <p>         HTTPS 端口, 默认 443
  --bridge-port <p>        桥接端口, 默认 8081
  --ws-backend-port <p>    uptermd WS 上游端口, 默认 8443
  --metrics-port <p>       指标端口, 默认 9100
  --state-dir <dir>        状态与备份目录, 默认 /var/lib/actssh-bootstrap
  --skip-firewall          本次不处理防火墙
  --apply                  实际安装与生效
  --dry-run                仅演练, 与缺省一致
  --rollback               回滚; 与 --apply 连用才执行
  -h, --help               打印本说明

退出码: 0 成功; 2 参数; 3 系统; 4 非 root 或锁死风险; 5 软件包; 6 依赖; 7 未预期;
        8 端口冲突; 9 既有站点; 10 nginx/证书; 11 uptermd; 12 桥接; 13 防火墙;
        14 自检; 15 回滚失败; 16 升级前置不满足
USAGE
}

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --domain) DOMAIN="${2:?缺少 --domain 取值}"; EXPLICIT[domain]=1; shift 2 ;;
            --acme-email|--email) ACME_EMAIL="${2:?缺少 --acme-email 取值}"; EXPLICIT[acme_email]=1; shift 2 ;;
            --acme-staging) ACME_STAGING=1; EXPLICIT[acme_staging]=1; shift ;;
            --cert-mode) CERT_MODE="${2:?缺少 --cert-mode 取值}"; EXPLICIT[cert_mode]=1; shift 2 ;;
            --web-root) WEB_ROOT="${2:?缺少 --web-root 取值}"; EXPLICIT[web_root]=1; shift 2 ;;
            --relay-only) DEPLOY_MODE="relay-only"; EXPLICIT[deploy_mode]=1; shift ;;
            --with-direct) WITH_DIRECT=1; EXPLICIT[with_direct]=1; shift ;;
            --no-direct) WITH_DIRECT=0; EXPLICIT[with_direct]=1; shift ;;
            --uptermd-version) UPTERMD_VERSION_ARG="${2:?缺少 --uptermd-version 取值}"; EXPLICIT[uptermd_version]=1; shift 2 ;;
            --bridge-wheelhouse) BRIDGE_WHEELHOUSE="${2:?缺少 --bridge-wheelhouse 取值}"; EXPLICIT[bridge_wheelhouse]=1; shift 2 ;;
            --upgrade) UPGRADE=1; shift ;;
            --admin-cidr) ADMIN_CIDRS+=("${2:?缺少 --admin-cidr 取值}"); EXPLICIT[admin_cidr]=1; shift 2 ;;
            --allow-admin-anywhere) ALLOW_ADMIN_ANYWHERE=1; shift ;;
            --rate-limit-ssh) RATE_LIMIT_SSH=1; shift ;;
            --ops-user) OPS_USER="${2:?缺少 --ops-user 取值}"; EXPLICIT[ops_user]=1; shift 2 ;;
            --admin-ssh-port|--ssh-port) ADMIN_SSH_PORT="${2:?缺少 --admin-ssh-port 取值}"; EXPLICIT[admin_ssh_port]=1; shift 2 ;;
            --relay-port|--uptermd-port) RELAY_PORT="${2:?缺少 --relay-port 取值}"; EXPLICIT[relay_port]=1; shift 2 ;;
            --http-port) HTTP_PORT="${2:?缺少 --http-port 取值}"; EXPLICIT[http_port]=1; shift 2 ;;
            --https-port) HTTPS_PORT="${2:?缺少 --https-port 取值}"; EXPLICIT[https_port]=1; shift 2 ;;
            --bridge-port) BRIDGE_PORT="${2:?缺少 --bridge-port 取值}"; EXPLICIT[bridge_port]=1; shift 2 ;;
            --ws-backend-port) WS_BACKEND_PORT="${2:?缺少 --ws-backend-port 取值}"; EXPLICIT[ws_backend_port]=1; shift 2 ;;
            --metrics-port) METRICS_PORT="${2:?缺少 --metrics-port 取值}"; EXPLICIT[metrics_port]=1; shift 2 ;;
            --state-dir) STATE_DIR="${2:?缺少 --state-dir 取值}"; EXPLICIT[state_dir]=1; shift 2 ;;
            --skip-firewall) SKIP_FIREWALL=1; shift ;;
            --apply) APPLY=1; shift ;;
            --dry-run) APPLY=0; shift ;;
            --rollback) ROLLBACK=1; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
}

_validate_args() {
    # 用途: 校验必填项, 枚举值, 端口范围与端口互斥
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    case "$DEPLOY_MODE" in
        full|relay-only) ;;
        *) _die 2 "bootstrap.args.deploy_mode" "deploy-mode 仅支持 full 或 relay-only: ${DEPLOY_MODE}" ;;
    esac
    case "$WITH_DIRECT" in
        0|1) ;;
        *) _die 2 "bootstrap.args.with_direct" "with-direct 仅支持 0 或 1: ${WITH_DIRECT}" ;;
    esac
    # 关闭直连时中继 SSH 只监听环回, 不暴露公网
    if [[ "$WITH_DIRECT" == "1" ]]; then
        RELAY_BIND="$PUBLIC_BIND"
    else
        RELAY_BIND="127.0.0.1"
    fi
    bs_require_port "admin-ssh-port" "$ADMIN_SSH_PORT"
    bs_require_port "relay-port" "$RELAY_PORT"
    bs_require_port "http-port" "$HTTP_PORT"
    bs_require_port "https-port" "$HTTPS_PORT"
    bs_require_port "bridge-port" "$BRIDGE_PORT"
    bs_require_port "ws-backend-port" "$WS_BACKEND_PORT"
    bs_require_port "metrics-port" "$METRICS_PORT"
    if [[ "$ROLE" == "deploy" && "$DEPLOY_MODE" == "full" && -z "$DOMAIN" ]]; then
        _die 2 "bootstrap.args.domain" "缺少 --domain; relay-only 形态可省略; 回滚请显式使用 --rollback"
    fi
    if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _die 2 "bootstrap.args.domain_invalid" "域名格式非法: ${DOMAIN}"
    fi
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        case "$CERT_MODE" in
            acme|self-signed) ;;
            *) _die 2 "bootstrap.args.cert_mode" "cert-mode 仅支持 acme 或 self-signed: ${CERT_MODE}" ;;
        esac
        if [[ "$CERT_MODE" == "acme" && "$HTTP_PORT" != "80" ]]; then
            _die 2 "bootstrap.args.http_port_acme" \
                "HTTP-01 校验固定访问 80 端口, acme 模式下 --http-port 必须为 80; 无 80 端口请改用 --cert-mode self-signed"
        fi
        if [[ -n "$WEB_ROOT" && ! -d "$WEB_ROOT" ]]; then
            _die 2 "bootstrap.args.web_root" "静态站点目录不存在: ${WEB_ROOT}"
        fi
        if [[ -n "$BRIDGE_WHEELHOUSE" && ! -d "$BRIDGE_WHEELHOUSE" ]]; then
            _die 2 "bootstrap.args.wheelhouse" "离线 wheel 目录不存在: ${BRIDGE_WHEELHOUSE}"
        fi
    fi
    # 只校验本次真正会用到的端口, 未安装的入口不参与冲突判定
    local -a ports=("$ADMIN_SSH_PORT" "$RELAY_PORT")
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        ports+=("$HTTP_PORT" "$HTTPS_PORT" "$BRIDGE_PORT")
    fi
    ports+=("$WS_BACKEND_PORT" "$METRICS_PORT")
    local i j
    for (( i = 0; i < ${#ports[@]}; i++ )); do
        for (( j = i + 1; j < ${#ports[@]}; j++ )); do
            if [[ "${ports[$i]}" == "${ports[$j]}" ]]; then
                _die 2 "bootstrap.args.port_conflict" "端口重复: ${ports[$i]}; 端口必须显式区分, 脚本不自动迁移"
            fi
        done
    done
    local cidr
    for cidr in "${ADMIN_CIDRS[@]}"; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            _die 2 "bootstrap.args.cidr" "来源网段仅支持 IPv4 CIDR: ${cidr}"
        fi
    done
}

_check_os() {
    # 用途: 校验 Ubuntu 20.04 或 22.04 与 x86_64
    # 参数: 无
    # 返回: 无; 退出码: 0 或 3
    local id version arch
    if [[ ! -r /etc/os-release ]]; then
        _die 3 "bootstrap.os.unknown" "无法读取 /etc/os-release"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    version="${VERSION_ID:-}"
    arch="$(uname -m)"
    if [[ "$id" != "ubuntu" ]]; then
        _die 3 "bootstrap.os.unsupported" "仅支持 Ubuntu, 当前 ID=${id}"
    fi
    case "$version" in
        20.04|22.04) ;;
        *) _die 3 "bootstrap.os.version" "仅支持 Ubuntu 20.04 与 22.04, 当前 ${version}" ;;
    esac
    if [[ "$arch" != "x86_64" ]]; then
        _die 3 "bootstrap.os.arch" "仅支持 x86_64, 当前 ${arch}"
    fi
}

_ip_to_int() {
    # 用途: 把 IPv4 点分十进制转为整数
    # 参数: $1 IPv4 地址
    # 返回: 标准输出整数; 退出码: 0 或 1
    local ip="$1" a b c d
    IFS=. read -r a b c d <<<"$ip"
    if [[ -z "$d" ]]; then
        return 1
    fi
    printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

_cidr_match() {
    # 用途: 判断 IPv4 是否落在指定 CIDR 内
    # 参数: $1 IPv4; $2 CIDR
    # 返回: 退出码: 0 匹配; 1 不匹配
    local ip="$1" cidr="$2" net prefix ip_i net_i mask
    if [[ "$cidr" == */* ]]; then
        net="${cidr%/*}"
        prefix="${cidr#*/}"
    else
        net="$cidr"
        prefix=32
    fi
    ip_i="$(_ip_to_int "$ip" || true)"
    net_i="$(_ip_to_int "$net" || true)"
    if [[ -z "$ip_i" || -z "$net_i" ]]; then
        return 1
    fi
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    (( (ip_i & mask) == (net_i & mask) ))
}

_check_admin_source() {
    # 用途: 防火墙落地前确认当前 SSH 来源在允许网段内, 避免把自己锁在门外
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    if (( APPLY == 0 || SKIP_FIREWALL == 1 )); then
        return 0
    fi
    if (( ALLOW_ADMIN_ANYWHERE == 1 )); then
        _say "[WARN] 管理面不限制来源, 仅应用于临时排障"
        return 0
    fi
    if (( ${#ADMIN_CIDRS[@]} == 0 )); then
        _die 4 "bootstrap.admin.no_cidr" "防火墙落地需要 --admin-cidr, 或显式 --allow-admin-anywhere"
    fi
    if [[ -z "${SSH_CONNECTION:-}" ]]; then
        _say "[WARN] 当前不是 SSH 会话, 无法校验管理面来源; 请确认控制台可用"
        return 0
    fi
    local src cidr matched=0
    src="${SSH_CONNECTION%% *}"
    for cidr in "${ADMIN_CIDRS[@]}"; do
        if _cidr_match "$src" "$cidr"; then
            matched=1
        fi
    done
    if (( matched == 0 )); then
        _die 4 "bootstrap.admin.lockout_risk" \
            "当前 SSH 来源 ${src} 不在 --admin-cidr 内, 落地防火墙会锁死连接; 请补充来源或先换到允许网段"
    fi
}

_preflight_ports() {
    # 用途: 逐端口判定占用归属; 外部占用直接报错, 不自动迁移
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8 或 9
    _check_port_owner "$ADMIN_SSH_PORT" "管理面 sshd" ssh.service sshd.service
    _check_port_owner "$RELAY_PORT" "uptermd SSH" uptermd.service
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        _check_port_owner "$HTTP_PORT" "HTTP" nginx.service actssh-nginx.service
        _check_port_owner "$HTTPS_PORT" "HTTPS" nginx.service actssh-nginx.service
        _check_port_owner "$BRIDGE_PORT" "网页桥接" actssh-web-bridge.service
    fi
    _check_port_owner "$WS_BACKEND_PORT" "uptermd WS 上游" uptermd.service
    _check_port_owner "$METRICS_PORT" "uptermd 指标" uptermd.service
    if [[ "$DEPLOY_MODE" != "full" ]]; then
        return 0
    fi
    local site base
    if [[ -d /etc/nginx/sites-enabled ]]; then
        for site in /etc/nginx/sites-enabled/*; do
            [[ -e "$site" ]] || continue
            base="$(basename "$site")"
            if [[ "$base" != "default" ]]; then
                _die 9 "bootstrap.nginx.sites_present" \
                    "检测到既有 nginx 站点 /etc/nginx/sites-enabled/${base}; 本脚本不接管既有站点, 请按 README 迁移节处理"
            fi
        done
    fi
    return 0
}

_check_port_owner() {
    # 用途: 端口为空闲或属于允许单元时放行, 否则按占用报错
    # 参数: $1 端口; $2 说明; 其余为允许单元
    # 返回: 无; 退出码: 0 或 8
    local port="$1" label="$2" pid unit owner=""
    shift 2
    local pids
    pids="$(bs_port_pids "$port")"
    if [[ -z "$pids" ]]; then
        return 0
    fi
    if bs_listener_owned_by "$port" "$@"; then
        return 0
    fi
    for pid in $pids; do
        unit="$(bs_pid_unit "$pid" || true)"
        owner+="${unit:-pid:${pid}} "
    done
    _die 8 "bootstrap.port.occupied" \
        "端口 ${port} (${label}) 已被 ${owner:-未知进程} 占用; 脚本不自动迁移, 请先停止占用或改用参数指定其他端口"
}

_prepare_state() {
    # 用途: 初始化状态目录与日志; 演练写系统临时目录, 落地写状态目录
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    if (( APPLY == 1 )); then
        LOG_ROOT="${STATE_DIR}/logs"
        install -d -m 0700 -o root -g root "$STATE_DIR" || _die 5 "bootstrap.state.dir" "无法创建状态目录: ${STATE_DIR}"
        BACKUP_POINTER="${STATE_DIR}/last_backup"
    else
        LOG_ROOT="${TMPDIR:-/tmp}/actssh-bootstrap-logs"
    fi
    bs_init_logging "$LOGGER" "$LOG_ROOT" "$RUN_ID"
}

_manifest_set() {
    # 用途: 向本次备份清单追加键值
    # 参数: $1 键; $2 值
    # 返回: 无; 退出码: 0
    if [[ -n "$BACKUP_DIR" ]]; then
        printf '%s\t%s\n' "$1" "$2" >>"${BACKUP_DIR}/manifest.tsv"
    fi
}

_manifest_get() {
    # 用途: 从清单读取键值, 同键取最后一次
    # 参数: $1 键; $2 清单文件
    # 返回: 标准输出值; 退出码: 0
    local key="$1" file="$2"
    awk -F '\t' -v k="$key" '$1 == k { v = $2 } END { print v }' "$file" 2>/dev/null || true
}

_load_previous() {
    # 用途: 升级时读取上次部署参数, 未在命令行显式给出的键沿用旧值
    # 参数: 无
    # 返回: 无; 退出码: 0 或 16
    local ptr="${STATE_DIR}/last_backup" dir manifest key val cidrs
    if [[ ! -f "$ptr" ]]; then
        _die 16 "bootstrap.upgrade.no_state" "升级需要上次部署记录, 未找到: ${ptr}; 请先完成一次 --apply 部署"
    fi
    dir="$(cat "$ptr")"
    manifest="${dir}/manifest.tsv"
    if [[ ! -f "$manifest" || ! -f "${dir}/files.tsv" ]]; then
        _die 16 "bootstrap.upgrade.no_manifest" "上次部署记录不完整: ${dir}"
    fi
    if [[ ! -f /etc/systemd/system/uptermd.service ]]; then
        _die 16 "bootstrap.upgrade.not_installed" "未检测到 uptermd.service, 无法升级; 请先执行部署"
    fi
    while IFS=$'\t' read -r key val; do
        [[ -n "$key" ]] || continue
        case "$key" in
            DOMAIN) [[ -n "${EXPLICIT[domain]:-}" ]] || DOMAIN="$val" ;;
            ACME_EMAIL) [[ -n "${EXPLICIT[acme_email]:-}" ]] || ACME_EMAIL="$val" ;;
            CERT_MODE) [[ -n "${EXPLICIT[cert_mode]:-}" ]] || CERT_MODE="$val" ;;
            DEPLOY_MODE) [[ -n "${EXPLICIT[deploy_mode]:-}" ]] || DEPLOY_MODE="$val" ;;
            WITH_DIRECT) [[ -n "${EXPLICIT[with_direct]:-}" ]] || WITH_DIRECT="$val" ;;
            WEB_ROOT) [[ -n "${EXPLICIT[web_root]:-}" ]] || WEB_ROOT="$val" ;;
            UPTERMD_VERSION) [[ -n "${EXPLICIT[uptermd_version]:-}" ]] || UPTERMD_VERSION_ARG="$val" ;;
            ADMIN_SSH_PORT) [[ -n "${EXPLICIT[admin_ssh_port]:-}" ]] || ADMIN_SSH_PORT="$val" ;;
            RELAY_PORT) [[ -n "${EXPLICIT[relay_port]:-}" ]] || RELAY_PORT="$val" ;;
            HTTP_PORT) [[ -n "${EXPLICIT[http_port]:-}" ]] || HTTP_PORT="$val" ;;
            HTTPS_PORT) [[ -n "${EXPLICIT[https_port]:-}" ]] || HTTPS_PORT="$val" ;;
            BRIDGE_PORT) [[ -n "${EXPLICIT[bridge_port]:-}" ]] || BRIDGE_PORT="$val" ;;
            WS_BACKEND_PORT) [[ -n "${EXPLICIT[ws_backend_port]:-}" ]] || WS_BACKEND_PORT="$val" ;;
            METRICS_PORT) [[ -n "${EXPLICIT[metrics_port]:-}" ]] || METRICS_PORT="$val" ;;
            OPS_USER) [[ -n "${EXPLICIT[ops_user]:-}" ]] || OPS_USER="$val" ;;
            ADMIN_CIDRS)
                if [[ -z "${EXPLICIT[admin_cidr]:-}" && -n "$val" ]]; then
                    IFS=, read -r -a cidrs <<<"$val"
                    ADMIN_CIDRS=("${cidrs[@]}")
                fi
                ;;
            ALLOW_ADMIN_ANYWHERE) [[ -n "${EXPLICIT[admin_cidr]:-}" ]] || ALLOW_ADMIN_ANYWHERE="${val:-0}" ;;
            RATE_LIMIT_SSH) RATE_LIMIT_SSH="${val:-0}" ;;
        esac
    done <"$manifest"
    _say "升级参数: domain=${DOMAIN:-无} mode=${DEPLOY_MODE} direct=${WITH_DIRECT} uptermd=${UPTERMD_VERSION_ARG:-默认}"
}

_backup_path() {
    # 用途: 变更前复制路径并在清单登记恢复动作
    # 参数: $1 绝对路径
    # 返回: 无; 退出码: 0 或 1
    local path="$1" target
    if [[ -e "$path" || -L "$path" ]]; then
        target="${BACKUP_DIR}/root${path}"
        mkdir -p "$(dirname "$target")"
        cp -a "$path" "$target" || return 1
        printf 'restore\t%s\n' "$path" >>"${BACKUP_DIR}/files.tsv"
    else
        printf 'remove\t%s\n' "$path" >>"${BACKUP_DIR}/files.tsv"
    fi
}

_record_path() {
    # 用途: 只记录存在性, 不复制内容; 用于私钥目录与体积较大的二进制
    # 参数: $1 绝对路径
    # 返回: 无; 退出码: 0
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        printf 'keep\t%s\n' "$path" >>"${BACKUP_DIR}/files.tsv"
    else
        printf 'remove\t%s\n' "$path" >>"${BACKUP_DIR}/files.tsv"
    fi
}

_prepare_backup() {
    # 用途: 落地前建立备份目录, 记录服务与防火墙前置状态, 备份将被覆盖的配置
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if (( APPLY == 0 )); then
        return 0
    fi
    BACKUP_DIR="${STATE_DIR}/backups/${RUN_ID}"
    install -d -m 0700 -o root -g root "$BACKUP_DIR" || _die 7 "bootstrap.backup.dir" "无法创建备份目录"
    : >"${BACKUP_DIR}/files.tsv"
    : >"${BACKUP_DIR}/manifest.tsv"
    _manifest_set RUN_ID "$RUN_ID"
    _manifest_set DOMAIN "$DOMAIN"
    _manifest_set ACME_EMAIL "$ACME_EMAIL"
    _manifest_set CERT_MODE "$CERT_MODE"
    _manifest_set DEPLOY_MODE "$DEPLOY_MODE"
    _manifest_set WITH_DIRECT "$WITH_DIRECT"
    _manifest_set WEB_ROOT "$WEB_ROOT"
    _manifest_set UPTERMD_VERSION "${UPTERMD_VERSION_ARG:-v0.41.1}"
    _manifest_set ADMIN_SSH_PORT "$ADMIN_SSH_PORT"
    _manifest_set RELAY_PORT "$RELAY_PORT"
    _manifest_set HTTP_PORT "$HTTP_PORT"
    _manifest_set HTTPS_PORT "$HTTPS_PORT"
    _manifest_set BRIDGE_PORT "$BRIDGE_PORT"
    _manifest_set WS_BACKEND_PORT "$WS_BACKEND_PORT"
    _manifest_set METRICS_PORT "$METRICS_PORT"
    _manifest_set OPS_USER "$OPS_USER"
    local cidr_joined=""
    if (( ${#ADMIN_CIDRS[@]} > 0 )); then
        cidr_joined="$(IFS=,; printf '%s' "${ADMIN_CIDRS[*]}")"
    fi
    _manifest_set ADMIN_CIDRS "$cidr_joined"
    _manifest_set ALLOW_ADMIN_ANYWHERE "$ALLOW_ADMIN_ANYWHERE"
    _manifest_set RATE_LIMIT_SSH "$RATE_LIMIT_SSH"
    _manifest_set NGINX_PRE_ACTIVE "$(systemctl is-active nginx.service 2>/dev/null || true)"
    _manifest_set NGINX_PRE_ENABLED "$(systemctl is-enabled nginx.service 2>/dev/null || true)"
    _manifest_set UPTERMD_PREEXISTING "$([[ -f /etc/systemd/system/uptermd.service ]] && echo 1 || echo 0)"
    _manifest_set UPTERMD_PRE_ACTIVE "$(systemctl is-active uptermd.service 2>/dev/null || true)"
    _manifest_set UFW_PRE_ACTIVE "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}' || true)"
    _manifest_set NFT_PRE_ACTIVE "$(systemctl is-active nftables.service 2>/dev/null || true)"

    _backup_path /etc/actssh
    _backup_path /etc/systemd/system/uptermd.service
    _backup_path /etc/uptermd/uptermd.env
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        _backup_path /opt/actssh-web-bridge
        _backup_path /var/www/actssh-acme
        _backup_path /etc/logrotate.d/actssh
        _backup_path /etc/cron.d/actssh-certbot
        _backup_path /etc/systemd/system/actssh-nginx.service
        _backup_path /etc/systemd/system/actssh-web-bridge.service
    fi
    # 升级时把旧二进制纳入备份, 便于失败后整体回退到上一版本
    if (( UPGRADE == 1 )) && [[ -f /usr/local/bin/uptermd ]]; then
        _backup_path /usr/local/bin/uptermd
    fi
    # 防火墙配置: 原本存在才备份恢复; 原本不存在时只记录, 回滚不删除 apt 生成的新默认配置
    if [[ -d /etc/ufw ]]; then
        _backup_path /etc/ufw
    fi
    if [[ -f /etc/nftables.conf ]]; then
        _backup_path /etc/nftables.conf
    fi
    if [[ -f /etc/uptermd/uptermd-guard.nft ]]; then
        _backup_path /etc/uptermd/uptermd-guard.nft
    fi
    # 证书与运行身份只记录存在性, 避免把私钥复制到第二处
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        _record_path "/etc/letsencrypt/live/${DOMAIN}"
        _record_path "/etc/letsencrypt/archive/${DOMAIN}"
        _record_path "/etc/letsencrypt/renewal/${DOMAIN}.conf"
        _backup_path /etc/letsencrypt/renewal-hooks/deploy/actssh-nginx-reload
    fi
    _record_path /var/lib/uptermd
    if (( UPGRADE == 0 )); then
        _record_path /usr/local/bin/uptermd
    fi
    printf '%s\n' "$BACKUP_DIR" >"$BACKUP_POINTER"
    _say "备份目录: ${BACKUP_DIR}"
}

_ensure_ops_user() {
    # 用途: 幂等创建 actssh-ops 只读组, 并把既有运维账号加入
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    if ! getent group "$OPS_GROUP" >/dev/null 2>&1; then
        if (( APPLY == 1 )); then
            groupadd --system "$OPS_GROUP" || _die 5 "bootstrap.pkg.ops_group" "创建运维组失败: ${OPS_GROUP}"
        else
            _say "演练: 将创建运维组 ${OPS_GROUP}"
            return 0
        fi
    fi
    if [[ -n "$OPS_USER" ]]; then
        if ! id -u "$OPS_USER" >/dev/null 2>&1; then
            _say "[WARN] 运维账号不存在, 未加入 ${OPS_GROUP}: ${OPS_USER}"
            return 0
        fi
        if (( APPLY == 1 )); then
            usermod -aG "$OPS_GROUP" "$OPS_USER" || _die 5 "bootstrap.pkg.ops_user" "把 ${OPS_USER} 加入 ${OPS_GROUP} 失败"
        else
            _say "演练: 将把 ${OPS_USER} 加入 ${OPS_GROUP}"
        fi
    fi
    return 0
}

_step_packages() {
    # 用途: 安装缺失软件包, 再确保运维组存在
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    local missing=() pkg
    PACKAGES=("${BASE_PACKAGES[@]}")
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        PACKAGES+=("${WEB_PACKAGES[@]}")
    fi
    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        _say "软件包已齐备, 跳过 apt"
        _ensure_ops_user
        return 0
    fi
    if (( APPLY == 0 )); then
        _say "演练: 将安装 ${missing[*]}"
        _ensure_ops_user
        return 0
    fi
    _say "安装软件包: ${missing[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -o DPkg::Lock::Timeout=120; then
        _die 5 "bootstrap.pkg.apt_update" "apt-get update 失败; 检查出网与软件源"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o DPkg::Lock::Timeout=120 "${missing[@]}"; then
        _die 5 "bootstrap.pkg.apt_install" "软件包安装失败: ${missing[*]}"
    fi
    _ensure_ops_user
    return 0
}

_write_logrotate() {
    # 用途: 写独立 nginx 日志轮转配置; 桥接与中继日志走 journald, 不设全局上限以免影响同机其他服务
    # 参数: 无
    # 返回: 无; 退出码: 0 或 10
    local tmp
    tmp="$(mktemp "${TMP_DIR}/logrotate.XXXXXX")"
    cat >"$tmp" <<'EOF'
# 由 deploy/bootstrap.sh 生成: 只轮转独立 nginx 实例的日志
/var/log/actssh/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root actssh-ops
    sharedscripts
    postrotate
        systemctl reload actssh-nginx.service >/dev/null 2>&1 || true
    endscript
}
EOF
    bs_apply_file "$tmp" /etc/logrotate.d/actssh 0644 root root "$APPLY" \
        || _die 10 "bootstrap.logrotate.write" "写入日志轮转配置失败"
}

_step_nginx() {
    # 用途: 调用 nginx-cert.sh 完成独立 nginx 与证书, 再写日志轮转
    # 参数: 无
    # 返回: 无; 退出码: 0 或 10
    local -a args=(
        --domain "$DOMAIN"
        --cert-mode "$CERT_MODE"
        --http-port "$HTTP_PORT"
        --https-port "$HTTPS_PORT"
        --bridge-host "127.0.0.1"
        --bridge-port "$BRIDGE_PORT"
        --acme-root "$ACME_ROOT"
        --ops-group "$OPS_GROUP"
    )
    if [[ -n "$ACME_EMAIL" ]]; then
        args+=(--acme-email "$ACME_EMAIL")
    fi
    if (( ACME_STAGING == 1 )); then
        args+=(--staging)
    fi
    if [[ -n "$WEB_ROOT" ]]; then
        args+=(--web-root "$WEB_ROOT")
    fi
    if (( APPLY == 1 )); then
        args+=(--apply)
    else
        args+=(--dry-run)
    fi
    local rc=0
    "${SCRIPT_DIR}/bootstrap/nginx-cert.sh" "${args[@]}" || rc=$?
    if (( rc != 0 )); then
        return "$rc"
    fi
    _write_logrotate
}

_step_uptermd() {
    # 用途: 调用 install-uptermd.sh 安装中继, SSH 入口固定在独立端口, 不占用系统 sshd 的端口
    # 参数: 无
    # 返回: 无; 退出码: 0 或 11
    local -a args=(
        --ssh-addr "${RELAY_BIND}:${RELAY_PORT}"
        --ws-addr "127.0.0.1:${WS_BACKEND_PORT}"
        --metric-addr "127.0.0.1:${METRICS_PORT}"
        --unit-src "${SCRIPT_DIR}/uptermd.service"
    )
    if [[ -n "$UPTERMD_VERSION_ARG" ]]; then
        args+=(--version "$UPTERMD_VERSION_ARG")
    fi
    if (( APPLY == 1 )); then
        local rc=0
        "${SCRIPT_DIR}/install-uptermd.sh" "${args[@]}" || rc=$?
        return "$rc"
    fi
    # 演练模式不执行子脚本: 干净机器上 jq/curl 可能尚未安装, 直接打印等价命令
    _say "演练: 将执行 install-uptermd.sh ${args[*]}"
}

_step_bridge() {
    # 用途: 调用 web-bridge.sh 安装桥接用户, venv, 环境文件与单元
    # 参数: 无
    # 返回: 无; 退出码: 0 或 12
    local -a args=(
        --bridge-host "127.0.0.1"
        --bridge-port "$BRIDGE_PORT"
        --ops-group "$OPS_GROUP"
        --install-dir /opt/actssh-web-bridge
        --source-dir "${SCRIPT_DIR}/../scripts/bridge"
        --requirements "${SCRIPT_DIR}/../scripts/requirements-web-bridge.txt"
        --unit-src "${SCRIPT_DIR}/actssh-web-bridge.service"
    )
    if [[ -n "$BRIDGE_WHEELHOUSE" ]]; then
        args+=(--wheelhouse "$BRIDGE_WHEELHOUSE")
    fi
    if (( APPLY == 1 )); then
        args+=(--apply)
    else
        args+=(--dry-run)
    fi
    local rc=0
    "${SCRIPT_DIR}/bootstrap/web-bridge.sh" "${args[@]}" || rc=$?
    return "$rc"
}

_step_firewall() {
    # 用途: 生成并应用或演练防火墙规则; 落地前记录前态用于回滚
    # 参数: 无
    # 返回: 无; 退出码: 0 或 13
    if (( SKIP_FIREWALL == 1 )); then
        FIREWALL_RESULT="已跳过"
        _say "已按 --skip-firewall 跳过防火墙"
        return 0
    fi
    if (( APPLY == 0 )) && ! command -v ufw >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
        FIREWALL_RESULT="演练: 缺少 ufw 与 nft, 跳过规则演练"
        _say "${FIREWALL_RESULT}"
        return 0
    fi
    local -a args=(
        --relay-port "$RELAY_PORT"
        --admin-port "$ADMIN_SSH_PORT"
        --metrics-port "$METRICS_PORT"
    )
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        args+=(--ws-port "$HTTPS_PORT" --http-port "$HTTP_PORT")
    else
        args+=(--no-web)
    fi
    if [[ "$WITH_DIRECT" != "1" ]]; then
        args+=(--no-relay)
    fi
    local cidr
    for cidr in "${ADMIN_CIDRS[@]}"; do
        args+=(--admin-cidr "$cidr")
    done
    if (( ALLOW_ADMIN_ANYWHERE == 1 )); then
        args+=(--allow-admin-anywhere)
    fi
    if (( RATE_LIMIT_SSH == 1 )); then
        args+=(--rate-limit-ssh)
    fi
    if (( APPLY == 1 )); then
        _manifest_set FIREWALL_ATTEMPTED 1
        args+=(--apply)
        FIREWALL_RESULT="已应用"
    else
        args+=(--dry-run)
        FIREWALL_RESULT="演练完成"
    fi
    "${SCRIPT_DIR}/firewall.sh" "${args[@]}"
}

_step_selfcheck() {
    # 用途: 调用 selfcheck.sh 逐项验证监听, 单元, 证书与健康检查
    # 参数: 无
    # 返回: 无; 退出码: 0 或 14
    local -a args=(
        --admin-ssh-port "$ADMIN_SSH_PORT"
        --relay-port "$RELAY_PORT"
        --http-port "$HTTP_PORT"
        --https-port "$HTTPS_PORT"
        --bridge-port "$BRIDGE_PORT"
        --ws-backend-port "$WS_BACKEND_PORT"
        --metrics-port "$METRICS_PORT"
        --acme-root "$ACME_ROOT"
        --nginx-conf "${ACTSSH_NGINX_CONF_DIR:-/etc/actssh/nginx}/nginx.conf"
        --health-script "${SCRIPT_DIR}/check-relay-health.sh"
    )
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        args+=(--domain "$DOMAIN" --cert-mode "$CERT_MODE")
    else
        args+=(--relay-only)
    fi
    if [[ "$WITH_DIRECT" != "1" ]]; then
        args+=(--no-direct)
    fi
    "${SCRIPT_DIR}/bootstrap/selfcheck.sh" "${args[@]}"
}

_run_step() {
    # 用途: 执行一个步骤并记录耗时与返回码, 失败时映射为顶层退出码
    # 参数: $1 步骤名; $2 失败退出码; $3 函数名
    # 返回: 无; 退出码: 0 或映射码或 130/143
    local name="$1" fail_code="$2" fn="$3" start rc elapsed
    start="$(date +%s)"
    _say "[STEP] ${name} 开始"
    _log INFO "bootstrap.step.start" "步骤开始" "{\"step\":\"${name}\"}"
    # 子步骤返回码需要映射: 临时摘掉 ERR 钩子, 否则钩子会先于 rc 捕获直接退出
    trap - ERR
    set +e
    "$fn"
    rc=$?
    set -e
    trap '_on_error $? $LINENO "$BASH_COMMAND"' ERR
    elapsed=$(( $(date +%s) - start ))
    STEP_ROWS+=("${name}|${rc}|${elapsed}")
    _log INFO "bootstrap.step.done" "步骤结束" \
        "{\"step\":\"${name}\",\"rc\":${rc},\"seconds\":${elapsed}}"
    if (( rc == 130 || rc == 143 )); then
        _say "[STEP] ${name} 被中断 rc=${rc}"
        exit "$rc"
    fi
    if (( rc != 0 )); then
        _say "[STEP] ${name} 失败 rc=${rc} 耗时=${elapsed}s"
        if (( AUTO_ROLLBACK == 1 )); then
            _say "[STEP] 触发自动回滚到升级前状态"
            # 回滚自身失败不得掩盖原始失败码, 只追加提示
            trap - ERR
            set +e
            _run_rollback
            local rb=$?
            set -e
            trap '_on_error $? $LINENO "$BASH_COMMAND"' ERR
            if (( rb != 0 )); then
                _say "[ERROR] 自动回滚失败 rc=${rb}; 请人工按 ${BACKUP_DIR}/files.tsv 恢复"
                exit 15
            fi
            _say "[STEP] 自动回滚完成"
        fi
        exit "$fail_code"
    fi
    _say "[STEP] ${name} 完成 耗时=${elapsed}s"
}

_print_ports() {
    # 用途: 打印端口与来源限制对照, 便于上线前核对
    # 参数: 无
    # 返回: 无; 退出码: 0
    local relay_note="公网直连入口"
    if [[ "$WITH_DIRECT" != "1" ]]; then
        relay_note="仅环回, 直连已关闭"
    fi
    cat <<EOF
=== 端口与监听规划 (IPv4) ===
管理面 sshd      ${PUBLIC_BIND}:${ADMIN_SSH_PORT}    仅 --admin-cidr 来源
uptermd SSH      ${RELAY_BIND}:${RELAY_PORT}    ${relay_note}
EOF
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        cat <<EOF
HTTP             ${PUBLIC_BIND}:${HTTP_PORT}    ACME 校验与 301
HTTPS            ${PUBLIC_BIND}:${HTTPS_PORT}    公网入口, 反代 /ws/ 与 /runner/
桥接后端          127.0.0.1:${BRIDGE_PORT}    仅环回
EOF
    else
        echo "网页入口         未安装 (relay-only), 无 HTTP/HTTPS/桥接"
    fi
    cat <<EOF
uptermd WS 上游   127.0.0.1:${WS_BACKEND_PORT}    仅环回
uptermd 指标      127.0.0.1:${METRICS_PORT}    仅环回
EOF
}

_summary() {
    # 用途: 输出分步结果与后续动作
    # 参数: 无
    # 返回: 无; 退出码: 0
    local row name rc secs
    _say "=== 分步结果 ==="
    printf '%-12s %-6s %s\n' "步骤" "rc" "耗时"
    for row in "${STEP_ROWS[@]}"; do
        IFS='|' read -r name rc secs <<<"$row"
        printf '%-12s %-6s %ss\n' "$name" "$rc" "$secs"
    done
    _say "防火墙: ${FIREWALL_RESULT}"
    _say "形态: ${DEPLOY_MODE} 直连=$([[ "$WITH_DIRECT" == "1" ]] && echo on || echo off)"
    _say "日志: ${LOG_ROOT}/${RUN_ID}.jsonl"
    if (( APPLY == 1 )); then
        _say "备份: ${BACKUP_DIR}"
        _say "回滚: ${SCRIPT_DIR}/bootstrap.sh --rollback --apply"
    fi
    if (( APPLY == 0 )); then
        _say "当前为演练模式; 确认无误后追加 --apply 落地"
    fi
    if [[ "$DEPLOY_MODE" == "full" ]]; then
        _say "后续: 解析 ${DOMAIN} 到本机, 放行云安全组 ${HTTP_PORT}/${HTTPS_PORT}/${RELAY_PORT}; 网页静态资源用 --web-root 指定"
    else
        _say "后续: 放行云安全组 ${RELAY_PORT}; 升级用 ${SCRIPT_DIR}/bootstrap.sh --upgrade --apply"
    fi
}

_run_rollback() {
    # 用途: 按最近一次备份清单停止服务并恢复文件与防火墙前态
    # 参数: 无
    # 返回: 无; 退出码: 0 或 15
    bs_require_root
    LAST_BACKUP="${STATE_DIR}/last_backup"
    if [[ ! -f "$LAST_BACKUP" ]]; then
        _die 15 "bootstrap.rollback.no_backup" "未找到备份指针: ${LAST_BACKUP}"
    fi
    BACKUP_DIR="$(cat "$LAST_BACKUP")"
    if [[ ! -f "${BACKUP_DIR}/files.tsv" || ! -f "${BACKUP_DIR}/manifest.tsv" ]]; then
        _die 15 "bootstrap.rollback.incomplete" "备份目录不完整: ${BACKUP_DIR}"
    fi
    _say "=== 回滚计划 (backup=${BACKUP_DIR}) ==="
    local action path
    while IFS=$'\t' read -r action path; do
        [[ -n "$path" ]] || continue
        case "$action" in
            restore) _say "恢复: ${path}" ;;
            remove) _say "删除: ${path}" ;;
            keep) _say "保留: ${path}" ;;
        esac
    done <"${BACKUP_DIR}/files.tsv"
    if (( APPLY == 0 )); then
        _say "演练模式, 未执行回滚; 确认后追加 --apply"
        return 0
    fi

    local unit
    for unit in actssh-nginx.service actssh-web-bridge.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    if [[ "$(_manifest_get UPTERMD_PREEXISTING "${BACKUP_DIR}/manifest.tsv")" != "1" ]]; then
        systemctl disable --now uptermd.service >/dev/null 2>&1 || true
    fi
    # 先关闭防火墙再恢复规则文件, 避免恢复过程中出现半套规则
    if [[ "$(_manifest_get FIREWALL_ATTEMPTED "${BACKUP_DIR}/manifest.tsv")" == "1" ]]; then
        ufw disable >/dev/null 2>&1 || true
        systemctl stop nftables.service >/dev/null 2>&1 || true
    fi
    while IFS=$'\t' read -r action path; do
        [[ -n "$path" ]] || continue
        case "$action" in
            restore)
                rm -rf "$path"
                mkdir -p "$(dirname "$path")"
                cp -a "${BACKUP_DIR}/root${path}" "$path" \
                    || { _say "[ERROR] 恢复失败: ${path}"; exit 15; }
                ;;
            remove) rm -rf "$path" ;;
            keep) : ;;
        esac
    done <"${BACKUP_DIR}/files.tsv"
    systemctl daemon-reload || true
    # 升级回滚: 旧二进制已恢复, 重启中继让它重新加载
    if [[ "$(_manifest_get UPTERMD_PREEXISTING "${BACKUP_DIR}/manifest.tsv")" == "1" ]]; then
        systemctl restart uptermd.service >/dev/null 2>&1 \
            || _say "[WARN] 重启 uptermd 失败, 请人工核对"
    fi
    if [[ "$(_manifest_get FIREWALL_ATTEMPTED "${BACKUP_DIR}/manifest.tsv")" == "1" ]]; then
        if [[ "$(_manifest_get UFW_PRE_ACTIVE "${BACKUP_DIR}/manifest.tsv")" == "active" ]]; then
            ufw --force enable >/dev/null 2>&1 || _say "[WARN] 恢复 ufw 启用失败, 请人工核对"
        fi
        if [[ "$(_manifest_get NFT_PRE_ACTIVE "${BACKUP_DIR}/manifest.tsv")" == "active" ]]; then
            systemctl restart nftables.service >/dev/null 2>&1 || _say "[WARN] 恢复 nftables 失败, 请人工核对"
        fi
    fi
    local nginx_active nginx_enabled
    nginx_active="$(_manifest_get NGINX_PRE_ACTIVE "${BACKUP_DIR}/manifest.tsv")"
    nginx_enabled="$(_manifest_get NGINX_PRE_ENABLED "${BACKUP_DIR}/manifest.tsv")"
    if [[ "$nginx_active" == "active" ]]; then
        systemctl enable --now nginx.service >/dev/null 2>&1 || _say "[WARN] 恢复发行版 nginx 失败"
    elif [[ "$nginx_enabled" == "enabled" ]]; then
        systemctl enable nginx.service >/dev/null 2>&1 || true
    else
        systemctl disable nginx.service >/dev/null 2>&1 || true
    fi
    _say "回滚完成; apt 软件包保留不卸载, 备份目录保留: ${BACKUP_DIR}"
    return 0
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
# ROLE 在参数解析后确定: 带 --rollback 时不要求域名
if (( ROLLBACK == 1 )); then
    ROLE="rollback"
else
    ROLE="deploy"
fi
bs_require_root
# 升级需要先读上次记录, 再进入参数校验; 状态目录只有 root 可读
if (( UPGRADE == 1 && ROLLBACK == 0 )); then
    _load_previous
    AUTO_ROLLBACK=1
fi
_validate_args
_prepare_state

if (( ROLLBACK == 1 )); then
    _say "=== ActSSH bootstrap 回滚 (apply=${APPLY}) ==="
    _run_rollback
    exit 0
fi

_check_os
bs_require_cmds apt-get dpkg-query systemctl ss awk sed install cp rm mkdir date id getent
TMP_DIR="$(mktemp -d)"

_say "=== ActSSH bootstrap (apply=${APPLY} mode=${DEPLOY_MODE} domain=${DOMAIN:-无}) ==="
_log INFO "bootstrap.start" "开始从零部署" \
    "{\"domain\":\"${DOMAIN}\",\"apply\":${APPLY},\"cert_mode\":\"${CERT_MODE}\",\"mode\":\"${DEPLOY_MODE}\",\"direct\":${WITH_DIRECT},\"upgrade\":${UPGRADE}}"
_print_ports
_preflight_ports
_check_admin_source
_prepare_backup

_run_step "packages" 5 _step_packages
if [[ "$DEPLOY_MODE" == "full" ]]; then
    _run_step "nginx" 10 _step_nginx
else
    _say "[STEP] nginx 跳过: relay-only 形态不安装网页入口与证书"
fi
_run_step "uptermd" 11 _step_uptermd
if [[ "$DEPLOY_MODE" == "full" ]]; then
    _run_step "bridge" 12 _step_bridge
else
    _say "[STEP] bridge 跳过: relay-only 形态不安装网页桥接"
fi
_run_step "firewall" 13 _step_firewall
if (( APPLY == 1 )); then
    _run_step "selfcheck" 14 _step_selfcheck
else
    _say "[STEP] selfcheck 跳过: 演练模式没有可检查的在线服务"
fi

_summary
_log INFO "bootstrap.done" "部署流程结束" "{\"domain\":\"${DOMAIN}\",\"apply\":${APPLY},\"upgrade\":${UPGRADE}}"
exit 0

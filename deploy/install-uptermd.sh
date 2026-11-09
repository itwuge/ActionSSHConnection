#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : install-uptermd.sh
# 所属目录    : deploy/
# 文件用途    : 在 Ubuntu 主机上幂等地部署或升级自托管 uptermd, 落地无状态字节转发所需的最小面: 系统用户, 目录权限, 主机密钥, 环境文件, systemd 单元, journald 上限, 禁落盘与空路由自检
# 架构定位    : 运维部署层; 上游是运维人员手工执行, 下游是 systemd 托管的 uptermd 进程与 relay 客户端
# 核心功能    : 依赖校验, 系统用户与目录准备, 主机密钥生成, 发布包下载与哈希校验, 二进制安装与版本核对, 环境文件与单元写入, 服务启停, 监听与资源上限核对, 重启后空路由自检, 禁落盘校验
# 职责边界    : 不改系统 sshd 端口, 不改云安全组, 不登记任何宿主或访客公钥, 不写 authorized_keys, 不做密钥轮换, 不应用防火墙规则; 22 端口被占用时只报错并给出处置提示, 不自动迁移
# 运行环境    : Ubuntu 20.04 及以上, bash 5.x, 以 root 执行, 需出网访问 GitHub Releases
# 依赖关系    : 依赖 curl, tar, find, sha256sum, ssh-keygen, systemctl, jq, ss, install, id, getent, awk, cmp, mktemp; 由 deploy/README.md 的部署章节调用
#
# 输入        : 以下均可用同名环境变量预置, 命令行参数优先于环境变量
#               UPTERMD_VERSION          待安装版本, 默认 v0.41.1
#               UPTERMD_SHA256           发布包 sha256, 可选; 缺省时回落读取同版本 checksums.txt
#               UPTERMD_RELEASE_BASE     发布包根地址, 默认 https://github.com/owenthereal/upterm/releases/download
#               UPTERMD_BIN_PATH         二进制安装路径, 默认 /usr/local/bin/uptermd
#               UPTERMD_USER             运行身份, 默认 upterm
#               UPTERMD_STATE_DIR        状态与主机密钥目录, 默认 /var/lib/uptermd
#               UPTERMD_CONF_DIR         配置目录, 默认 /etc/uptermd
#               UPTERMD_SSH_ADDR         relay SSH 监听地址, 默认 0.0.0.0:22
#               UPTERMD_WS_ADDR          relay WS 监听地址, 默认 127.0.0.1:8443; 公网 443 由 TLS 终止层转发
#               UPTERMD_SSH_NETWORK      监听协议族, 默认 tcp4
#               UPTERMD_METRIC_ADDR      指标监听地址, 默认 127.0.0.1:9100, 只允许环回
#               UPTERMD_RUNTIME_DIR      运行期内存目录, 默认 /run/uptermd; 只允许该目录可写
#               UPTERMD_HANDSHAKE_TIMEOUT 握手超时, 默认 60s
#               UPTERMD_CHECK_WAIT_ATTEMPTS 自检等待次数, 默认 10
#               UPTERMD_UNIT_PATH        systemd 单元安装路径, 默认 /etc/systemd/system/uptermd.service
#               UPTERMD_UNIT_SRC         单元模板路径, 默认与本脚本同目录的 uptermd.service
#               UPTERMD_DEPLOY_LOG_DIR   部署日志根目录, 默认 /var/log/uptermd-deploy/logs
#               UPTERMD_FETCH_ATTEMPTS   下载重试次数, 默认 3
# 退出码      : 0 成功或无需变更; 2 参数或环境非法; 3 依赖命令缺失; 4 非 root; 5 下载或哈希校验失败;
#               6 二进制版本与请求不符; 7 目录或密钥准备失败; 8 systemd 写入或服务启动失败; 9 relay 端口被占用;
#               10 重启后空路由或禁落盘自检未通过; 11 资源上限未生效; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _log <level> <event> <msg> [extra_json] -> 0: 追加一行 JSON Lines 事件
#   _say <text> -> 0: 输出面向运维人员的进度行
#   _warn_once <text> -> 0: 同次运行只向 stderr 提示一次
#   _die <code> <event> <msg> -> 不返回: 记录日志后按退出码终止
#   _parse_args <args...> -> 0/2: 解析命令行参数并覆盖默认值
#   _require_root -> 0/4: 校验执行身份
#   _require_cmds -> 0/3: 校验外部命令齐全
#   _ensure_user -> 0/7: 幂等创建运行身份
#   _ensure_dirs -> 0/7: 幂等创建目录与权限
#   _ensure_host_key -> 0/7: 缺密钥时生成, 已有则保留
#   _detect_arch -> 0/2: 输出发布包架构后缀
#   _fetch <url> <dest> -> 0/5: 带次数上限下载
#   _resolve_sha256 <asset> <dir> -> 0/5: 取期望哈希
#   _binary_version <bin> -> 0/1: 探测版本号
#   _install_binary <dir> -> 0/5/6: 解包, 校验, 原子替换与版本核对
#   _render_env <file> -> 0: 生成环境文件内容
#   _apply_file <src> <dst> <mode> <owner> <group> -> 0/7: 内容有差异才写入
#   _apply_journald_limits -> 0/8: 写入并生效 journald 上限
#   _port_in_use <addr> -> 0/1: 判断监听端口是否已被占用
#   _metrics_url -> 0: 由指标监听地址生成环回访问地址
#   _active_routes_value -> 0/1: 按候选指标名读取活动路由数
#   _restart_service -> 0/8/9: 按变更情况启停并等待监听就绪
#   _verify_empty_routes -> 0/10: 重启后确认内存路由为空
#   _verify_no_disk_write -> 0/10: 确认运行期未落盘会话文件
#   _verify_limits -> 0/11: 确认单元资源上限已生效
#   _summary -> 0: 输出部署结果摘要
#   _cleanup -> 0: 删除临时目录, 幂等

# =========** 常量与默认值 =========**
VERSION="${UPTERMD_VERSION:-v0.41.1}"
EXPECTED_SHA256="${UPTERMD_SHA256:-}"
RELEASE_BASE="${UPTERMD_RELEASE_BASE:-https://github.com/owenthereal/upterm/releases/download}"
BIN_PATH="${UPTERMD_BIN_PATH:-/usr/local/bin/uptermd}"
SVC_USER="${UPTERMD_USER:-upterm}"
STATE_DIR="${UPTERMD_STATE_DIR:-/var/lib/uptermd}"
CONF_DIR="${UPTERMD_CONF_DIR:-/etc/uptermd}"
SSH_ADDR="${UPTERMD_SSH_ADDR:-0.0.0.0:22}"
WS_ADDR="${UPTERMD_WS_ADDR:-127.0.0.1:8443}"
SSH_NETWORK="${UPTERMD_SSH_NETWORK:-tcp4}"
METRIC_ADDR="${UPTERMD_METRIC_ADDR:-127.0.0.1:9100}"
RUNTIME_DIR="${UPTERMD_RUNTIME_DIR:-/run/uptermd}"
HANDSHAKE_TIMEOUT="${UPTERMD_HANDSHAKE_TIMEOUT:-60s}"
UNIT_PATH="${UPTERMD_UNIT_PATH:-/etc/systemd/system/uptermd.service}"
LOG_DIR="${UPTERMD_DEPLOY_LOG_DIR:-/var/log/uptermd-deploy/logs}"
FETCH_ATTEMPTS="${UPTERMD_FETCH_ATTEMPTS:-3}"
START_WAIT_ATTEMPTS="${UPTERMD_START_WAIT_ATTEMPTS:-15}"
START_WAIT_INTERVAL_S="${UPTERMD_START_WAIT_INTERVAL_S:-1}"
CHECK_WAIT_ATTEMPTS="${UPTERMD_CHECK_WAIT_ATTEMPTS:-10}"

# 单元模板默认取脚本同目录, 不依赖调用者工作目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="${UPTERMD_UNIT_SRC:-${SCRIPT_DIR}/uptermd.service}"

SERVICE_NAME="uptermd.service"
KEY_PATH="${STATE_DIR}/server_key"
ENV_FILE="${CONF_DIR}/uptermd.env"
JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="${JOURNALD_DROPIN_DIR}/90-uptermd-limits.conf"
LOGGER="deploy.install_uptermd"

RUN_ID="$(date -u '+%Y%m%d_%H%M%S')_$$"
LOG_FILE=""
DRY_RUN=0
CHANGED=0
WARNED=0
RESTARTED=0
TMP_DIR=""
CLEANED=0

# =========** 参数校验 =========**
# 命令行参数与同名环境变量同义, 全部端口与路径均来自参数, 逻辑区不写死取值

log_usage() {
    # 用途: 打印用法与默认值
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: install-uptermd.sh [选项]

选项:
  --version <tag>           待安装版本, 形如 v0.41.1
  --sha256 <hex>            发布包 sha256, 建议提供; 缺省时回落读取 checksums.txt
  --bin-path <path>         二进制安装路径
  --user <name>             运行身份
  --state-dir <path>        状态与主机密钥目录
  --conf-dir <path>         配置目录
  --ssh-addr <addr:port>    relay SSH 监听地址
  --ws-addr <addr:port>     relay WS 监听地址, 公网 443 由 TLS 终止层转发
  --ssh-network <tcp4>      监听协议族
  --metric-addr <addr:port> 指标监听地址, 只允许环回
  --handshake-timeout <dur> 握手超时, 取值 1s 到 120s
  --unit-path <path>        systemd 单元安装路径
  --unit-src <path>         单元模板路径
  --log-dir <path>          部署日志根目录
  --dry-run                 只打印将要执行的动作, 不写盘不启停
  -h, --help                打印本说明
USAGE
}

# =========** 函数 =========**
_warn_once() {
    # 用途: 日志写入失败时向 stderr 提示, 每次运行只提示一次
    # 参数: $1 提示文本
    # 返回: 无; 退出码: 0
    if (( WARNED == 1 )); then
        return 0
    fi
    WARNED=1
    printf '[WARN] %s\n' "$1" >&2
}

_log() {
    # 用途: 追加一行 JSON Lines 事件, 写失败只降级提示不中断主流程
    # 参数: $1 级别; $2 事件名; $3 描述; $4 可选 JSON 对象片段
    # 返回: 无; 退出码: 恒 0; 失败输出: stderr 一次提示, 含日志路径
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
        # 序列化失败由下方统一提示一次, 这里吞掉 jq 自身报错以免刷屏
        _warn_once "日志序列化失败: event=${event} path=${LOG_FILE}"
        return 0
    fi
    printf '%s\n' "$line" >>"$LOG_FILE" || _warn_once "日志写入失败: path=${LOG_FILE}"
}

_say() {
    # 用途: 输出面向运维人员的进度行, 与日志分离
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    printf '%s\n' "$1"
}

_die() {
    # 用途: 记录 ERROR 后按指定码退出
    # 参数: $1 退出码; $2 事件名; $3 描述
    # 返回: 不返回; 退出码: $1
    local code="$1" event="$2" msg="$3"
    _log ERROR "$event" "$msg" \
        "{\"exc_type\":\"DeployError\",\"exc_msg\":$(jq -Rn --arg v "$msg" '$v'),\"stack\":null}"
    printf '[ERROR] %s\n' "$msg" >&2
    exit "$code"
}

_on_error() {
    # 用途: ERR 钩子, 输出失败位置与命令, 作为入口兜底的证据
    # 参数: $1 退出码; $2 行号; $3 失败命令
    # 返回: 无; 退出码: 0; 失败输出: stderr 与日志各一条 ERROR
    local code="$1" line="$2" cmd="$3" trace="" i
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
        trace+="${FUNCNAME[$i]}(${BASH_LINENO[$((i - 1))]}) "
    done
    set +e   # 钩子内不得再触发 ERR, 由各函数自行判定并记录
    _log ERROR "deploy.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":$(jq -Rn --arg v "exit=${code} line=${line} cmd=${cmd}" '$v'),\"stack\":$(jq -Rn --arg v "$trace" '$v')}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    set -e   # 恢复失败即停, 交由 EXIT 钩子清理
}

_parse_args() {
    # 用途: 解析命令行参数, 覆盖同名默认值
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 成功; 2 未知参数或取值缺失
    while (( $# > 0 )); do
        case "$1" in
            --version) VERSION="${2:?缺少 --version 取值}"; shift 2 ;;
            --sha256) EXPECTED_SHA256="${2:?缺少 --sha256 取值}"; shift 2 ;;
            --bin-path) BIN_PATH="${2:?缺少 --bin-path 取值}"; shift 2 ;;
            --user) SVC_USER="${2:?缺少 --user 取值}"; shift 2 ;;
            --state-dir) STATE_DIR="${2:?缺少 --state-dir 取值}"; shift 2 ;;
            --conf-dir) CONF_DIR="${2:?缺少 --conf-dir 取值}"; shift 2 ;;
            --ssh-addr) SSH_ADDR="${2:?缺少 --ssh-addr 取值}"; shift 2 ;;
            --ws-addr) WS_ADDR="${2:?缺少 --ws-addr 取值}"; shift 2 ;;
            --ssh-network) SSH_NETWORK="${2:?缺少 --ssh-network 取值}"; shift 2 ;;
            --metric-addr) METRIC_ADDR="${2:?缺少 --metric-addr 取值}"; shift 2 ;;
            --handshake-timeout) HANDSHAKE_TIMEOUT="${2:?缺少 --handshake-timeout 取值}"; shift 2 ;;
            --unit-path) UNIT_PATH="${2:?缺少 --unit-path 取值}"; shift 2 ;;
            --unit-src) UNIT_SRC="${2:?缺少 --unit-src 取值}"; shift 2 ;;
            --log-dir) LOG_DIR="${2:?缺少 --log-dir 取值}"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) log_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    # 派生路径在解析后重算, 避免沿用默认目录
    KEY_PATH="${STATE_DIR}/server_key"
    ENV_FILE="${CONF_DIR}/uptermd.env"
    LOG_FILE="${LOG_DIR}/${RUN_ID}.jsonl"
}

_require_root() {
    # 用途: 校验以 root 执行
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    if [[ "$(id -u)" -ne 0 ]]; then
        _die 4 "deploy.not_root" "需要以 root 执行, 当前 uid=$(id -u)"
    fi
}

_require_cmds() {
    # 用途: 校验依赖命令齐全, 缺失时一次性列出
    # 参数: 无
    # 返回: 无; 退出码: 0 或 3
    local missing=() cmd
    for cmd in curl tar find sha256sum ssh-keygen systemctl jq ss install getent awk cmp mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            # 命令不存在属确定失败, 先收集再统一报出, 不逐条中断
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        _die 3 "deploy.deps.missing" "依赖命令缺失: ${missing[*]}"
    fi
}

_ensure_user() {
    # 用途: 幂等创建运行身份, 已存在则跳过
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if getent passwd "$SVC_USER" >/dev/null 2>&1; then
        _log INFO "deploy.user.exists" "运行身份已存在" "{\"user\":$(jq -Rn --arg v "$SVC_USER" '$v')}"
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        _say "演练: 将创建系统用户 ${SVC_USER}"
        CHANGED=1
        return 0
    fi
    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SVC_USER" \
        || _die 7 "deploy.user.failed" "创建用户失败: user=${SVC_USER}"
    CHANGED=1
    _log INFO "deploy.user.created" "已创建运行身份" "{\"user\":$(jq -Rn --arg v "$SVC_USER" '$v')}"
}

_ensure_dirs() {
    # 用途: 幂等创建状态与配置目录并设定属主权限
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7
    if (( DRY_RUN == 1 )); then
        _say "演练: 将创建目录 ${STATE_DIR} (0750) 与 ${CONF_DIR} (0750)"
        return 0
    fi
    install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$STATE_DIR" \
        || _die 7 "deploy.dir.failed" "创建状态目录失败: path=${STATE_DIR}"
    # 配置目录属主 root, 组为运行身份只读, 运行身份无法改写配置
    install -d -m 0750 -o root -g "$SVC_USER" "$CONF_DIR" \
        || _die 7 "deploy.dir.failed" "创建配置目录失败: path=${CONF_DIR}"
}

_ensure_host_key() {
    # 用途: 缺主机密钥时生成, 已存在则保留不动
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7; 失败输出: 不含密钥内容的错误行
    local fp
    if [[ -f "$KEY_PATH" ]]; then
        _log INFO "deploy.hostkey.exists" "主机密钥已存在, 保留不覆盖" "{\"path\":$(jq -Rn --arg v "$KEY_PATH" '$v')}"
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        _say "演练: 将生成 ed25519 主机密钥 ${KEY_PATH}"
        CHANGED=1
        return 0
    fi
    ssh-keygen -q -t ed25519 -N '' -C "uptermd-relay" -f "$KEY_PATH" \
        || _die 7 "deploy.hostkey.failed" "生成主机密钥失败: path=${KEY_PATH}"
    chown "$SVC_USER:$SVC_USER" "$KEY_PATH" "$KEY_PATH.pub" \
        || _die 7 "deploy.hostkey.failed" "设置主机密钥属主失败: path=${KEY_PATH}"
    chmod 0600 "$KEY_PATH"
    chmod 0644 "$KEY_PATH.pub"
    fp="$(ssh-keygen -lf "$KEY_PATH.pub" | awk '{print $2}')"
    CHANGED=1
    # 指纹属路由信息可公开; 私钥内容不打印
    _log INFO "deploy.hostkey.created" "已生成主机密钥" "{\"fingerprint\":$(jq -Rn --arg v "$fp" '$v')}"
}

_detect_arch() {
    # 用途: 按 uname -m 映射发布包架构后缀
    # 参数: 无
    # 返回: 标准输出架构名; 退出码: 0 或 2
    case "$(uname -m)" in
        x86_64) printf 'amd64' ;;
        aarch64) printf 'arm64' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x) printf 's390x' ;;
        *) _die 2 "deploy.arch.unsupported" "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

_fetch() {
    # 用途: 带次数上限的下载, 每次失败记录 attempt
    # 参数: $1 源地址; $2 目标文件
    # 返回: 无; 退出码: 0 或 5
    local url="$1" dest="$2" attempt
    for (( attempt = 1; attempt <= FETCH_ATTEMPTS; attempt++ )); do
        # GitHub Releases 先 302 跳转到对象存储, 必须 -L 跟随; 空文件视为失败
        if curl -fsSL --connect-timeout 10 --max-time 300 -o "$dest" "$url" && [[ -s "$dest" ]]; then
            _log INFO "deploy.fetch.done" "下载完成" "{\"attempt\":${attempt}}"
            return 0
        fi
        _log WARNING "deploy.fetch.retry" "下载失败, 准备重试" "{\"attempt\":${attempt}}"
    done
    _die 5 "deploy.fetch.failed" "下载失败且重试耗尽: url=${url} attempts=${FETCH_ATTEMPTS}"
}

_resolve_sha256() {
    # 用途: 取发布包期望哈希; 优先用显式传入值, 否则读 checksums.txt
    # 参数: $1 发布包文件名; $2 临时目录
    # 返回: 标准输出哈希值; 退出码: 0 或 5
    local asset="$1" dir="$2" sums="$dir/checksums.txt" hash
    if [[ -n "$EXPECTED_SHA256" ]]; then
        printf '%s' "$EXPECTED_SHA256"
        return 0
    fi
    _fetch "${RELEASE_BASE}/${VERSION}/checksums.txt" "$sums"
    # 只做完整性校验: 来源与发布包同域, 不构成真实性证明, 故降级为 WARNING
    _log WARNING "deploy.sha256.fallback" "未提供 --sha256, 回落到同版本 checksums.txt, 仅能发现传输损坏" "{}"
    hash="$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")"
    if [[ -z "$hash" ]]; then
        _die 5 "deploy.sha256.missing" "checksums.txt 中未找到发布包条目: asset=${asset}"
    fi
    printf '%s' "$hash"
}

_binary_version() {
    # 用途: 探测二进制版本, 兼容 --version 与 version 两种入口
    # 参数: $1 二进制路径
    # 返回: 标准输出纯版本号; 退出码: 0 或 1
    local bin="$1" out
    if out="$("$bin" --version 2>&1)"; then
        if [[ "$out" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    if out="$("$bin" version 2>&1)"; then
        if [[ "$out" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    return 1
}

_install_binary() {
    # 用途: 下载解包, 校验哈希, 版本核对后原子替换二进制
    # 参数: $1 临时目录
    # 返回: 无; 退出码: 0 或 5 或 6 或 7
    local dir="$1" arch asset tarball want got extract newbin detected desired
    arch="$(_detect_arch)"
    asset="uptermd_linux_${arch}.tar.gz"
    tarball="${dir}/${asset}"
    extract="${dir}/extract"
    desired="${VERSION#v}"

    _fetch "${RELEASE_BASE}/${VERSION}/${asset}" "$tarball"
    want="$(_resolve_sha256 "$asset" "$dir")"
    got="$(sha256sum "$tarball" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        _die 5 "deploy.sha256.mismatch" "发布包哈希不匹配: expect=${want} actual=${got}"
    fi

    mkdir -p "$extract"
    tar -xzf "$tarball" -C "$extract" \
        || _die 5 "deploy.unpack.failed" "解包失败: asset=${asset}"
    newbin="$(find "$extract" -maxdepth 2 -type f -name uptermd -print -quit)"
    if [[ -z "$newbin" ]]; then
        _die 5 "deploy.unpack.failed" "解包结果中未找到 uptermd: asset=${asset}"
    fi
    chmod 0755 "$newbin"

    detected=""
    if ! detected="$(_binary_version "$newbin")"; then
        _die 6 "deploy.version.unknown" "无法识别新二进制版本: asset=${asset}"
    fi
    if [[ "$detected" != "$desired" ]]; then
        _die 6 "deploy.version.mismatch" "二进制版本与请求不符: expect=${desired} actual=${detected}"
    fi

    if (( DRY_RUN == 1 )); then
        _say "演练: 将安装 ${newbin} 到 ${BIN_PATH}, 版本 ${detected}"
        CHANGED=1
        return 0
    fi
    install -m 0755 -o root -g root "$newbin" "${BIN_PATH}.new" \
        || _die 7 "deploy.binary.install" "写入二进制失败: path=${BIN_PATH}.new"
    mv -f "${BIN_PATH}.new" "$BIN_PATH"
    CHANGED=1
    _log INFO "deploy.binary.installed" "二进制已更新" \
        "{\"version\":$(jq -Rn --arg v "$detected" '$v'),\"path\":$(jq -Rn --arg v "$BIN_PATH" '$v')}"
}

_render_env() {
    # 用途: 生成环境文件内容, 作为单元唯一的参数来源
    # 参数: $1 目标临时文件
    # 返回: 无; 退出码: 0
    cat >"$1" <<EOF
# 由 deploy/install-uptermd.sh 生成, 手工修改会被下次执行覆盖
# 只放路由与密钥路径, 不放任何私钥内容
# 不设置 UPTERMD_AUTHORIZED_KEYS: 宿主注册门禁关闭, 中转不做任何准入判定
UPTERMD_SSH_ADDR=${SSH_ADDR}
UPTERMD_WS_ADDR=${WS_ADDR}
UPTERMD_SSH_NETWORK=${SSH_NETWORK}
UPTERMD_PRIVATE_KEY=${KEY_PATH}
UPTERMD_HANDSHAKE_TIMEOUT=${HANDSHAKE_TIMEOUT}
UPTERMD_METRIC_ADDR=${METRIC_ADDR}
EOF
}

_apply_file() {
    # 用途: 内容有差异才写入, 无差异跳过, 保证重复执行不产生变更
    # 参数: $1 源文件; $2 目标文件; $3 权限; $4 属主; $5 属组
    # 返回: 无; 退出码: 0 或 7
    local src="$1" dst="$2" mode="$3" owner="$4" group="$5"
    local stage="${dst}.tmp.$$"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        _log INFO "deploy.file.unchanged" "文件内容未变化, 跳过写入" "{\"path\":$(jq -Rn --arg v "$dst" '$v')}"
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        _say "演练: 将写入 ${dst} (mode=${mode} owner=${owner}:${group})"
        CHANGED=1
        return 0
    fi
    # 先写同目录暂存文件再改名, 避免进程读到半截内容
    install -m "$mode" -o "$owner" -g "$group" "$src" "$stage" \
        || _die 7 "deploy.file.write_failed" "写入暂存文件失败: path=${stage}"
    mv -f "$stage" "$dst" || _die 7 "deploy.file.write_failed" "替换文件失败: path=${dst}"
    CHANGED=1
    _log INFO "deploy.file.written" "文件已更新" "{\"path\":$(jq -Rn --arg v "$dst" '$v')}"
}

_apply_journald_limits() {
    # 用途: 写入 journald 保留量上限, 仅在该文件确实变化时重启 journald
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8
    local tmp="${TMP_DIR}/journald.conf" before="$CHANGED"
    if [[ ! -d "$JOURNALD_DROPIN_DIR" ]]; then
        if (( DRY_RUN == 1 )); then
            _say "演练: 将创建目录 ${JOURNALD_DROPIN_DIR}"
        else
            install -d -m 0755 -o root -g root "$JOURNALD_DROPIN_DIR"
        fi
    fi
    printf '%s\n' \
        '[Journal]' \
        '# 由 deploy/install-uptermd.sh 生成, 全局生效' \
        'SystemMaxUse=200M' \
        'SystemMaxFileSize=50M' \
        >"$tmp"
    _apply_file "$tmp" "$JOURNALD_DROPIN" 0644 root root
    if (( CHANGED != before && DRY_RUN == 0 )); then
        systemctl restart systemd-journald \
            || _die 8 "deploy.journald.restart" "重启 systemd-journald 失败"
    fi
}

_port_in_use() {
    # 用途: 判断监听端口是否已被占用
    # 参数: $1 地址端口串, 如 0.0.0.0:22
    # 返回: 退出码: 0 已占用; 1 未占用
    local port="${1##*:}" listeners
    listeners="$(ss -Hltn "sport = :${port}")"
    if [[ -n "$listeners" ]]; then
        return 0
    fi
    return 1
}

_metrics_url() {
    # 用途: 由指标监听地址生成环回访问地址, 避免把 0.0.0.0 当作可连接目标
    # 参数: 无
    # 返回: 标准输出 URL; 退出码: 0 或 2
    local host="${METRIC_ADDR%:*}" port="${METRIC_ADDR##*:}"
    if [[ -z "$host" || -z "$port" || "$host" == "$METRIC_ADDR" ]]; then
        _die 2 "deploy.metric_addr.invalid" "指标监听地址需为 host:port 形式: addr=${METRIC_ADDR}"
    fi
    if [[ "$host" == "0.0.0.0" ]]; then
        host="127.0.0.1"
    fi
    printf 'http://%s:%s/metrics' "$host" "$port"
}

_active_routes_value() {
    # 用途: 读取活动路由数; v0.41.1 实际指标带 upterm_uptermd_ 前缀且没有 routing_active_connections_count
    # 参数: 无
    # 返回: 标准输出指标值; 退出码: 0 成功; 1 指标不可用或候选名均缺失
    local url body name value
    url="$(_metrics_url)"
    if ! body="$(curl -fsS --connect-timeout 2 --max-time 5 "$url")"; then
        return 1
    fi
    for name in routing_active_connections_count \
        upterm_uptermd_routing_active_connections_count \
        upterm_uptermd_sessions_active_count; do
        value="$(printf '%s\n' "$body" | awk -v n="$name" '$1 == n { v = $2 } END { if (v != "") print v }')"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

_cpu_quota_usec() {
    # 用途: 把 CPUQuotaPerSecUSec 字面值统一换算为微秒, 兼容 1500000 与 1.5s 与 1.500000s
    # 参数: $1 systemctl 输出的字面值
    # 返回: 标准输出微秒整数
    local v="$1"
    if [[ "$v" == *s ]]; then
        awk -v v="${v%s}" 'BEGIN { printf "%.0f", v * 1000000 }'
        return 0
    fi
    printf '%s' "$v"
}

_restart_service() {
    # 用途: 按变更情况启停服务并等待 SSH 与 WS 监听就绪, 未变更时保持运行
    # 参数: 无
    # 返回: 无; 退出码: 0 或 8 或 9
    local attempt addr
    if (( DRY_RUN == 1 )); then
        _say "演练: 将执行 systemctl daemon-reload 并按变更情况 enable/restart ${SERVICE_NAME}"
        return 0
    fi
    systemctl daemon-reload || _die 8 "deploy.systemd.reload" "daemon-reload 失败"
    # enable 的输出只是链接已存在的提示, 不承载判定信息
    systemctl enable "$SERVICE_NAME" >/dev/null || _die 8 "deploy.systemd.enable" "设置开机自启失败"
    if (( CHANGED == 1 )); then
        for addr in "$SSH_ADDR" "$WS_ADDR"; do
            if [[ -n "$addr" ]] && _port_in_use "$addr" && ! systemctl is-active --quiet "$SERVICE_NAME"; then
                _die 9 "deploy.port.conflict" "监听地址已被占用: addr=${addr}; 请先迁移系统 sshd 或改用 --ssh-addr/--ws-addr"
            fi
        done
        systemctl restart "$SERVICE_NAME" || _die 8 "deploy.service.restart" "重启服务失败: unit=${SERVICE_NAME}"
        RESTARTED=1
    elif ! systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl start "$SERVICE_NAME" || _die 8 "deploy.service.start" "启动服务失败: unit=${SERVICE_NAME}"
        RESTARTED=1
    else
        _log INFO "deploy.service.running" "服务已在运行且无变更, 不重启" "{}"
    fi
    for (( attempt = 1; attempt <= START_WAIT_ATTEMPTS; attempt++ )); do
        if systemctl is-active --quiet "$SERVICE_NAME" \
            && _port_in_use "$SSH_ADDR" \
            && { [[ -z "$WS_ADDR" ]] || _port_in_use "$WS_ADDR"; }; then
            _log INFO "deploy.service.ready" "服务已就绪" "{\"attempt\":${attempt}}"
            return 0
        fi
        _log WARNING "deploy.service.wait" "服务尚未就绪, 继续等待" "{\"attempt\":${attempt}}"
        sleep "$START_WAIT_INTERVAL_S"
    done
    _die 8 "deploy.service.not_ready" "服务在等待上限内未就绪: attempts=${START_WAIT_ATTEMPTS} ssh=${SSH_ADDR} ws=${WS_ADDR}"
}

_verify_empty_routes() {
    # 用途: 重启后确认中转内存路由为空, 作为无状态自检
    # 参数: 无
    # 返回: 无; 退出码: 0 或 10
    local attempt value
    if (( DRY_RUN == 1 )); then
        _say "演练: 重启后读取 routing_active_connections_count 并确认其为 0"
        return 0
    fi
    if (( RESTARTED == 0 )); then
        _log INFO "deploy.routes.skip" "本次未重启服务, 空路由自检由健康检查脚本负责" "{}"
        return 0
    fi
    for (( attempt = 1; attempt <= CHECK_WAIT_ATTEMPTS; attempt++ )); do
        if value="$(_active_routes_value)"; then
            if [[ "$value" == "0" ]]; then
                _log INFO "deploy.routes.empty" "重启后路由为空" "{\"attempt\":${attempt}}"
                return 0
            fi
            _log WARNING "deploy.routes.not_empty" "重启后仍有活动路由, 继续观察" \
                "{\"attempt\":${attempt},\"active\":${value}}"
        else
            _log WARNING "deploy.routes.unavailable" "指标不可用, 继续观察" "{\"attempt\":${attempt}}"
        fi
        sleep "$START_WAIT_INTERVAL_S"
    done
    _die 10 "deploy.routes.not_empty" "重启后路由未清空或指标不可用, 不满足无状态判据: active=${value:-unknown}"
}

_verify_no_disk_write() {
    # 用途: 确认运行期目录为空, 状态目录除主机密钥与轮换归档外没有新增文件
    # 参数: 无
    # 返回: 无; 退出码: 0 或 10
    local extras=() path base
    if (( DRY_RUN == 1 )); then
        _say "演练: 检查 ${RUNTIME_DIR} 为空, 且 ${STATE_DIR} 只含主机密钥与轮换归档"
        return 0
    fi
    if [[ -d "$RUNTIME_DIR" ]]; then
        while read -r path; do
            extras+=("$path")
        done < <(find "$RUNTIME_DIR" -mindepth 1 -maxdepth 2 -print)
    fi
    if [[ -d "$STATE_DIR" ]]; then
        while read -r path; do
            base="${path#"${STATE_DIR}"/}"
            case "$base" in
                server_key|server_key.pub|archive|archive/*) ;;
                *) extras+=("$path") ;;
            esac
        done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 2 -type f)
    fi
    if (( ${#extras[@]} > 0 )); then
        _log ERROR "deploy.disk_write.detected" "运行期出现预期外文件, 可能发生会话落盘" \
            "{\"extra_count\":${#extras[@]},\"first_path\":$(jq -Rn --arg v "${extras[0]}" '$v')}"
        _die 10 "deploy.disk_write.detected" "禁落盘校验未通过: extra_count=${#extras[@]} first=${extras[0]}"
    fi
    _log INFO "deploy.disk_write.clean" "运行期未发现会话文件" \
        "{\"runtime_dir\":$(jq -Rn --arg v "$RUNTIME_DIR" '$v'),\"state_dir\":$(jq -Rn --arg v "$STATE_DIR" '$v')}"
}

_verify_limits() {
    # 用途: 确认单元的内存, CPU 与任务数上限已由 systemd 生效
    # 参数: 无
    # 返回: 无; 退出码: 0 或 11
    local mem cpu tasks cpu_usec
    if (( DRY_RUN == 1 )); then
        _say "演练: 核对 MemoryMax=1G, CPUQuota=150%, TasksMax=512 已生效"
        return 0
    fi
    mem="$(systemctl show -p MemoryMax --value "$SERVICE_NAME")" \
        || _die 11 "deploy.limits.read" "读取 MemoryMax 失败"
    cpu="$(systemctl show -p CPUQuotaPerSecUSec --value "$SERVICE_NAME")" \
        || _die 11 "deploy.limits.read" "读取 CPUQuota 失败"
    tasks="$(systemctl show -p TasksMax --value "$SERVICE_NAME")" \
        || _die 11 "deploy.limits.read" "读取 TasksMax 失败"
    if [[ "$mem" != "1073741824" && "$mem" != "1G" ]]; then
        _die 11 "deploy.limits.memory" "MemoryMax 与设计不符: actual=${mem}"
    fi
    cpu_usec="$(_cpu_quota_usec "$cpu")"
    if [[ "$cpu_usec" != "1500000" ]]; then
        _die 11 "deploy.limits.cpu" "CPUQuota 与设计不符: actual=${cpu}"
    fi
    if [[ "$tasks" != "512" ]]; then
        _die 11 "deploy.limits.tasks" "TasksMax 与设计不符: actual=${tasks}"
    fi
    _log INFO "deploy.limits.ok" "资源上限已生效" \
        "{\"memory_max\":$(jq -Rn --arg v "$mem" '$v'),\"cpu_quota\":$(jq -Rn --arg v "$cpu" '$v'),\"tasks_max\":${tasks}}"
}

_summary() {
    # 用途: 输出部署结果摘要, 只含路由信息与公钥指纹
    # 参数: 无
    # 返回: 无; 退出码: 0
    local ver="未知" fp="未生成" state="unknown"
    if ! ver="$(_binary_version "$BIN_PATH")"; then
        ver="未知"
    fi
    if [[ -f "${KEY_PATH}.pub" ]]; then
        fp="$(ssh-keygen -lf "${KEY_PATH}.pub" | awk '{print $2}')"
    fi
    # 服务未启动时 systemctl 把提示写到 stderr, 属预期分支, 由下方统一标注
    if ! state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"; then
        state="unknown"
    fi
    _say "----------------------------------------"
    _say "uptermd 版本     : ${ver}"
    _say "SSH 监听地址     : ${SSH_ADDR} (${SSH_NETWORK})"
    _say "WS 监听地址      : ${WS_ADDR}"
    _say "指标地址         : ${METRIC_ADDR}"
    _say "运行期目录       : ${RUNTIME_DIR}"
    _say "主机密钥指纹     : ${fp}"
    _say "宿主注册门禁     : 关闭 (未设置 UPTERMD_AUTHORIZED_KEYS)"
    _say "防火墙           : 需单独执行 deploy/firewall.sh --apply"
    _say "服务状态         : ${state}"
    _say "本次是否变更     : $(( CHANGED == 1 ? 1 : 0 ))"
    _say "部署日志         : ${LOG_FILE}"
    _say "----------------------------------------"
    _log INFO "deploy.run.finished" "部署流程结束" "{\"changed\":$(( CHANGED == 1 ? 1 : 0 ))}"
}

# =========** 清理 =========**
# 钩子必须先于主流程注册, 否则早期失败不会触发临时目录回收
_cleanup() {
    # 用途: 删除本次临时目录; 幂等, EXIT 与 INT 与 TERM 均可重复触发
    # 参数: 无
    # 返回: 无; 退出码: 0
    if (( CLEANED == 1 )); then
        return 0
    fi
    CLEANED=1
    # 目标只来自 mktemp -d, 为空时跳过, 防变量异常时误删
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

# 日志目录不可写属降级分支: 提示一次后继续, 不影响部署结果
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    _warn_once "日志目录不可写: path=${LOG_DIR}, 本次仅输出到终端"
    LOG_FILE=""
fi

_require_root
_require_cmds

TMP_DIR="$(mktemp -d)"
_log INFO "deploy.run.started" "开始部署 uptermd" \
    "{\"version\":$(jq -Rn --arg v "$VERSION" '$v'),\"dry_run\":$(( DRY_RUN == 1 ? 1 : 0 ))}"

_ensure_user
_ensure_dirs
_ensure_host_key
_install_binary "$TMP_DIR"

ENV_TMP="${TMP_DIR}/uptermd.env"
_render_env "$ENV_TMP"
_apply_file "$ENV_TMP" "$ENV_FILE" 0640 root "$SVC_USER"

if [[ ! -f "$UNIT_SRC" ]]; then
    _die 8 "deploy.unit.missing" "单元模板不存在: path=${UNIT_SRC}"
fi
_apply_file "$UNIT_SRC" "$UNIT_PATH" 0644 root root

_apply_journald_limits
_restart_service
_verify_limits
_verify_empty_routes
_verify_no_disk_write
_summary

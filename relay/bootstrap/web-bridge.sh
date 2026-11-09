#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : web-bridge.sh
# 所属目录    : relay/bootstrap/
# 文件用途    : 在空机器上落地网页桥接服务: 专用系统用户, 独立 venv, 固定版本依赖, 环境文件与 systemd 单元
# 架构定位    : 部署脚本应用层; 上游是 relay/install.sh, 下游是 actssh-web-bridge.service 与 relay_bridge.py
# 核心功能    : 用户与目录权限, 代码与依赖安装, venv 复用与版本核对, 环境文件生成, 单元落地与启动等待
# 职责边界    : 不改 nginx, 不签发证书, 不写防火墙, 不打印依赖凭据; 端口只从参数读取
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行, 需出网访问 PyPI
# 依赖关系    : 依赖 python3, python3-venv, systemctl, install, ss, getent, sed; 由 relay/install.sh 调用
#
# 输入        : 命令行参数优先
#               --bridge-host <host>  监听地址, 默认 127.0.0.1
#               --bridge-port <port>  监听端口, 默认 8081
#               --install-dir <dir>   安装目录, 默认 /opt/actssh-web-bridge
#               --source-dir <dir>    桥接代码目录, 默认 relay 目录下的 bridge/
#               --requirements <file> 依赖清单, 默认 relay/bridge/requirements-web-bridge.txt
#               --env-file <file>     环境文件, 默认 /etc/actssh/bridge.env
#               --unit-src <file>     单元模板, 默认 relay/actssh-web-bridge.service
#               --user <name>         运行用户, 默认 actssh-bridge
#               --group <name>        运行组, 默认 actssh-bridge
#               --ops-group <group>   运维只读组, 默认 actssh-ops
#               --python <path>       python3 解释器, 默认 /usr/bin/python3
#               --wheelhouse <dir>    离线 wheel 目录; 给出时 pip 不走网络
#               --apply               实际写入并启停; 缺省只演练
# 退出码      : 0 成功; 2 参数非法; 3 依赖缺失; 4 非 root; 5 用户或目录准备失败;
#               6 代码复制失败; 7 venv 创建失败; 8 依赖安装或版本核对失败; 9 环境文件或单元写入失败;
#               10 服务启动或端口监听失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux only

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=relay/bootstrap/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# =========** 常量与默认值 =========**
BRIDGE_HOST="${ACTSSH_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${ACTSSH_BRIDGE_PORT:-8081}"
WS_PATH="${ACTSSH_WS_PATH:-/ws/}"
RUNNER_PATH="${ACTSSH_RUNNER_PATH:-/runner/}"
INSTALL_DIR="${ACTSSH_BRIDGE_DIR:-/opt/actssh-web-bridge}"
SOURCE_DIR="${ACTSSH_BRIDGE_SOURCE:-${RELAY_DIR}/bridge}"
REQUIREMENTS="${ACTSSH_BRIDGE_REQUIREMENTS:-${RELAY_DIR}/bridge/requirements-web-bridge.txt}"
ENV_FILE="${ACTSSH_BRIDGE_ENV:-/etc/actssh/bridge.env}"
UNIT_SRC="${ACTSSH_BRIDGE_UNIT_SRC:-${RELAY_DIR}/actssh-web-bridge.service}"
UNIT_PATH="/etc/systemd/system/actssh-web-bridge.service"
SVC_USER="${ACTSSH_BRIDGE_USER:-actssh-bridge}"
SVC_GROUP="${ACTSSH_BRIDGE_GROUP:-actssh-bridge}"
OPS_GROUP="${ACTSSH_OPS_GROUP:-actssh-ops}"
PYTHON_BIN="${ACTSSH_PYTHON:-/usr/bin/python3}"
WHEELHOUSE="${ACTSSH_BRIDGE_WHEELHOUSE:-}"
EXPECTED_WS_VERSION="10.4"
SERVICE="actssh-web-bridge.service"
APPLY=0

LOGGER="relay.bootstrap.web_bridge"
RUN_ID="${BS_RUN_ID:-$(date '+%Y%m%d_%H%M%S')_$$}"
LOG_ROOT="${BS_LOG_DIR:-/var/log/actssh-bootstrap}"
TMP_DIR=""

# =========** 方法一览 =========**
#   _log / _say / _die / _on_error -> 日志与终止
#   _parse_args / _validate -> 0/2: 参数校验
#   _ensure_user -> 0/5: 幂等创建运行用户与组
#   _ensure_dirs -> 0/5: 创建安装目录与环境文件目录
#   _install_code -> 0/6: 复制桥接代码与依赖清单
#   _install_venv -> 0/7/8: 创建或复用 venv, 安装并核对 websockets 版本
#   _write_env -> 0/9: 生成环境文件
#   _install_unit -> 0/9/10: 渲染并安装单元, 启动并等待监听
#   _summary -> 0: 输出结果

_parse_args() {
    # 用途: 解析命令行参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --bridge-host) BRIDGE_HOST="${2:?缺少 --bridge-host 取值}"; shift 2 ;;
            --bridge-port) BRIDGE_PORT="${2:?缺少 --bridge-port 取值}"; shift 2 ;;
            --ws-path) WS_PATH="${2:?缺少 --ws-path 取值}"; shift 2 ;;
            --runner-path) RUNNER_PATH="${2:?缺少 --runner-path 取值}"; shift 2 ;;
            --install-dir) INSTALL_DIR="${2:?缺少 --install-dir 取值}"; shift 2 ;;
            --source-dir) SOURCE_DIR="${2:?缺少 --source-dir 取值}"; shift 2 ;;
            --requirements) REQUIREMENTS="${2:?缺少 --requirements 取值}"; shift 2 ;;
            --env-file) ENV_FILE="${2:?缺少 --env-file 取值}"; shift 2 ;;
            --unit-src) UNIT_SRC="${2:?缺少 --unit-src 取值}"; shift 2 ;;
            --user) SVC_USER="${2:?缺少 --user 取值}"; shift 2 ;;
            --group) SVC_GROUP="${2:?缺少 --group 取值}"; shift 2 ;;
            --ops-group) OPS_GROUP="${2:?缺少 --ops-group 取值}"; shift 2 ;;
            --python) PYTHON_BIN="${2:?缺少 --python 取值}"; shift 2 ;;
            --wheelhouse) WHEELHOUSE="${2:?缺少 --wheelhouse 取值}"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --dry-run) APPLY=0; shift ;;
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
用法: web-bridge.sh [选项]

选项:
  --bridge-host <host>   监听地址, 默认 127.0.0.1
  --bridge-port <port>   监听端口, 默认 8081
  --ws-path <path>       浏览器 WS 入口前缀, 默认 /ws/
  --runner-path <path>   runner 反连关键前缀, 默认 /runner/
  --install-dir <dir>    安装目录, 默认 /opt/actssh-web-bridge
  --source-dir <dir>     桥接代码目录
  --requirements <file>  依赖清单
  --env-file <file>      环境文件, 默认 /etc/actssh/bridge.env
  --unit-src <file>      systemd 单元模板
  --user <name>          运行用户, 默认 actssh-bridge
  --group <name>         运行组, 默认 actssh-bridge
  --python <path>        python3 解释器
  --wheelhouse <dir>     离线 wheel 目录, 给出时 pip 不走网络
  --apply                实际写入并启停
  --dry-run              只演练, 与缺省一致
  -h, --help             打印本说明
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
    _log ERROR "bridge.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":\"exit=${code} line=${line} cmd=${cmd}\"}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    exit 7
}

_validate() {
    # 用途: 校验参数组合与源文件
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    bs_require_port "bridge-port" "$BRIDGE_PORT"
    if [[ "$BRIDGE_HOST" == "0.0.0.0" || "$BRIDGE_HOST" == "::" ]]; then
        _die 2 "bridge.args.wildcard" "桥接监听地址不允许通配: ${BRIDGE_HOST}"
    fi
    if [[ ! -f "${SOURCE_DIR}/relay_bridge.py" || ! -f "${SOURCE_DIR}/jsonl_logger.py" ]]; then
        _die 2 "bridge.args.source_missing" "桥接代码不完整: ${SOURCE_DIR}"
    fi
    if [[ ! -f "$REQUIREMENTS" ]]; then
        _die 2 "bridge.args.requirements_missing" "依赖清单不存在: ${REQUIREMENTS}"
    fi
    if [[ ! -f "$UNIT_SRC" ]]; then
        _die 2 "bridge.args.unit_missing" "单元模板不存在: ${UNIT_SRC}"
    fi
    if [[ -n "$WHEELHOUSE" && ! -d "$WHEELHOUSE" ]]; then
        _die 2 "bridge.args.wheelhouse_missing" "离线 wheel 目录不存在: ${WHEELHOUSE}"
    fi
}

_ensure_user() {
    # 用途: 幂等创建运行组与系统用户
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    if ! getent group "$SVC_GROUP" >/dev/null 2>&1; then
        if (( APPLY == 1 )); then
            groupadd --system "$SVC_GROUP" || _die 5 "bridge.user.group" "创建运行组失败: ${SVC_GROUP}"
        else
            _say "演练: 将创建运行组 ${SVC_GROUP}"
        fi
    fi
    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        if (( APPLY == 1 )); then
            useradd --system --gid "$SVC_GROUP" --home-dir /nonexistent \
                --shell /usr/sbin/nologin --comment "ActSSH web bridge" "$SVC_USER" \
                || _die 5 "bridge.user.create" "创建运行用户失败: ${SVC_USER}"
        else
            _say "演练: 将创建运行用户 ${SVC_USER}"
        fi
    fi
    if ! getent group "$OPS_GROUP" >/dev/null 2>&1; then
        if (( APPLY == 1 )); then
            groupadd --system "$OPS_GROUP" || _die 5 "bridge.user.ops_group" "创建运维组失败: ${OPS_GROUP}"
        else
            _say "演练: 将创建运维组 ${OPS_GROUP}"
        fi
    fi
}

_ensure_dirs() {
    # 用途: 创建安装目录与环境文件目录
    # 参数: 无
    # 返回: 无; 退出码: 0 或 5
    bs_ensure_dir "$INSTALL_DIR" 0750 root "$SVC_GROUP" "$APPLY" || _die 5 "bridge.dirs.install" "无法创建安装目录: ${INSTALL_DIR}"
    bs_ensure_dir "$(dirname "$ENV_FILE")" 0750 root "$OPS_GROUP" "$APPLY" || _die 5 "bridge.dirs.env" "无法创建环境文件目录: $(dirname "$ENV_FILE")"
}

_install_code() {
    # 用途: 复制桥接代码与依赖清单, 内容一致时跳过
    # 参数: 无
    # 返回: 无; 退出码: 0 或 6
    local f
    for f in relay_bridge.py jsonl_logger.py; do
        bs_apply_file "${SOURCE_DIR}/${f}" "${INSTALL_DIR}/${f}" 0640 root "$SVC_GROUP" "$APPLY" \
            || _die 6 "bridge.code.copy" "复制失败: ${f}"
    done
    bs_apply_file "$REQUIREMENTS" "${INSTALL_DIR}/requirements-web-bridge.txt" 0640 root "$SVC_GROUP" "$APPLY" \
        || _die 6 "bridge.code.requirements" "复制依赖清单失败"
}

_install_venv() {
    # 用途: 创建或复用 venv, 按需安装并核对 websockets 版本
    # 参数: 无
    # 返回: 无; 退出码: 0 或 7 或 8
    local venv="${INSTALL_DIR}/venv"
    local installed=""
    if (( APPLY == 0 )); then
        _say "演练: 将创建 ${venv} 并安装 websockets==${EXPECTED_WS_VERSION}"
        return 0
    fi
    if [[ ! -x "${venv}/bin/python" ]]; then
        _say "创建 venv: ${venv}"
        if ! "$PYTHON_BIN" -m venv "$venv"; then
            _die 7 "bridge.venv.create" "创建 venv 失败: 确认 python3-venv 已安装"
        fi
    fi
    installed="$("${venv}/bin/python" -c 'import websockets; print(websockets.__version__)' 2>/dev/null || true)"
    if [[ "$installed" == "$EXPECTED_WS_VERSION" ]]; then
        _say "依赖已就绪: websockets==${installed}"
        return 0
    fi
    _say "安装依赖: websockets==${EXPECTED_WS_VERSION} (当前=${installed:-未安装})"
    local -a pip_args=(install --no-cache-dir --disable-pip-version-check -q)
    if [[ -n "$WHEELHOUSE" ]]; then
        # 离线: 只用本地 wheel, 不访问网络
        pip_args+=(--no-index --find-links "$WHEELHOUSE")
    fi
    if ! "${venv}/bin/pip" "${pip_args[@]}" \
        -r "${INSTALL_DIR}/requirements-web-bridge.txt"; then
        _die 8 "bridge.venv.pip_failed" "依赖安装失败; 检查出网与 PyPI 可达性, 或用 --wheelhouse 指定离线包"
    fi
    installed="$("${venv}/bin/python" -c 'import websockets; print(websockets.__version__)' 2>/dev/null || true)"
    if [[ "$installed" != "$EXPECTED_WS_VERSION" ]]; then
        _die 8 "bridge.venv.version_mismatch" \
            "依赖版本不符: 期望 ${EXPECTED_WS_VERSION} 实际 ${installed:-未知}"
    fi
    return 0
}

_write_env() {
    # 用途: 生成桥接环境文件, 只包含监听地址, 端口与两个 WS 前缀, 不含任何凭据
    # 参数: 无
    # 返回: 无; 退出码: 0 或 9
    local tmp
    tmp="$(mktemp "${TMP_DIR}/bridge.env.XXXXXX")"
    cat >"$tmp" <<EOF
# 由 relay/bootstrap/web-bridge.sh 生成
# 桥接只允许回环或受控网桥地址, 不接受通配地址
BRIDGE_LISTEN_HOST=${BRIDGE_HOST}
BRIDGE_LISTEN_PORT=${BRIDGE_PORT}
BRIDGE_BROWSER_PREFIX=${WS_PATH%/}
BRIDGE_RUNNER_PREFIX=${RUNNER_PATH%/}
EOF
    bs_apply_file "$tmp" "$ENV_FILE" 0640 root "$SVC_GROUP" "$APPLY" \
        || _die 9 "bridge.env.write" "写入环境文件失败: ${ENV_FILE}"
}

_install_unit() {
    # 用途: 按实际安装路径渲染单元, 启动并等待端口监听
    # 参数: 无
    # 返回: 无; 退出码: 0 或 9 或 10
    local tmp i
    tmp="$(mktemp "${TMP_DIR}/bridge.service.XXXXXX")"
    sed -e "s#/opt/actssh-web-bridge#${INSTALL_DIR}#g" \
        -e "s#/etc/actssh/bridge.env#${ENV_FILE}#g" \
        -e "s#^User=.*#User=${SVC_USER}#" \
        -e "s#^Group=.*#Group=${SVC_GROUP}#" \
        "$UNIT_SRC" >"$tmp"
    bs_apply_file "$tmp" "$UNIT_PATH" 0644 root root "$APPLY" \
        || _die 9 "bridge.unit.write" "写入单元失败: ${UNIT_PATH}"
    if (( APPLY == 0 )); then
        _say "演练: 将启动 ${SERVICE} 并等待 ${BRIDGE_HOST}:${BRIDGE_PORT} 监听"
        return 0
    fi
    systemctl daemon-reload || _die 10 "bridge.unit.reload" "systemctl daemon-reload 失败"
    systemctl enable "$SERVICE" >/dev/null 2>&1 || _die 10 "bridge.unit.enable" "启用 ${SERVICE} 失败"
    if ! systemctl restart "$SERVICE"; then
        systemctl --no-pager --lines=20 status "$SERVICE" >&2 || true
        _die 10 "bridge.start.failed" "启动 ${SERVICE} 失败"
    fi
    for (( i = 1; i <= 15; i++ )); do
        if bs_listen_ok "$BRIDGE_PORT" "$BRIDGE_HOST"; then
            _say "${SERVICE} 已监听 ${BRIDGE_HOST}:${BRIDGE_PORT}"
            return 0
        fi
        sleep 1
    done
    _die 10 "bridge.listen.timeout" "等待桥接端口 ${BRIDGE_PORT} 监听超时"
}

_summary() {
    # 用途: 输出桥接部署结果
    # 参数: 无
    # 返回: 无; 退出码: 0
    _say "桥接: ${INSTALL_DIR} 用户=${SVC_USER}:${SVC_GROUP} 监听=${BRIDGE_HOST}:${BRIDGE_PORT}"
    _say "入口由 nginx 的 /ws/ 与 /runner/ 反代, 不直接对外暴露"
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
bs_require_cmds install systemctl ss getent sed awk groupadd useradd id
if (( APPLY == 1 )); then
    bs_require_cmds "$PYTHON_BIN"
fi

TMP_DIR="$(mktemp -d)"
_say "=== 网页桥接 (apply=${APPLY} listen=${BRIDGE_HOST}:${BRIDGE_PORT}) ==="
_log INFO "bridge.start" "开始部署网页桥接" \
    "{\"host\":\"${BRIDGE_HOST}\",\"port\":${BRIDGE_PORT},\"apply\":${APPLY}}"

_ensure_user
_ensure_dirs
_install_code
_install_venv
_write_env
_install_unit
_summary
_log INFO "bridge.done" "网页桥接部署完成" "{}"
exit 0

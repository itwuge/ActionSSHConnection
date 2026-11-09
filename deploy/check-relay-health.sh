#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : check-relay-health.sh
# 所属目录    : deploy/
# 文件用途    : 检查中转机是否满足 v3 无状态判据: 重启后内存映射为空, 无会话文件落盘, 监听与资源上限生效
# 架构定位    : 运维健康检查层; 上游是运维人员或自动化巡检, 下游是 systemd 单元与 uptermd 指标端点
# 核心功能    : 单元状态, SSH/WS/指标监听, 活动路由数, 会话文件, 资源上限五类判定, journald 容量仅作提示, 汇总为单行 JSON
# 职责边界    : 不重启服务, 不改配置, 不读取会话内容, 不判定访客身份; 只做只读探测
# 运行环境    : Ubuntu 20.04 及以上, bash 5.x, 以 root 或有权限读取单元状态的账号执行
# 依赖关系    : 依赖 systemctl, curl, jq, ss, find, awk; 由 deploy/README.md 的验证章节调用
#
# 输入        : 位置参数 <host> [port]; host 仅用于输出标识, 端口缺省取 CH_SSH_PORT
#               CH_SSH_PORT        SSH 入口端口, 默认 22
#               CH_WS_PORT         WS 对外端口, 默认 443
#               CH_WS_BACKEND_PORT 环回 WS 端口, 默认 8443
#               CH_METRICS_URL     指标地址, 默认 http://127.0.0.1:9100/metrics
#               CH_STATE_DIR       持久状态目录, 默认 /var/lib/uptermd
#               CH_RUNTIME_DIR     内存运行目录, 默认 /run/uptermd
#               CH_UNIT            systemd 单元名, 默认 uptermd.service
#               CH_JOURNAL_DROPIN  journald 上限片段, 默认 /etc/systemd/journald.conf.d/90-uptermd-limits.conf
#               CH_JOURNAL_MAX     journald 占用提示阈值, 默认 200M; 只告警, 不影响 ok 判定
#               CH_LOG_DIR         检查日志根目录, 默认 /var/log/uptermd-deploy/logs
#               CH_BRIDGE_UNIT     网页桥接单元名, 默认 actssh-web-bridge.service; 未安装则该项跳过
#               CH_BRIDGE_PORT     网页桥接监听端口, 默认 8081
# 退出码      : 0 全部判据通过; 1 判据未通过或状态取不到; 2 参数或依赖错误; 130/143 中断
# 输出        : 标准输出恰好一行 JSON: {ok, message, error_code, data, confirm}
#               人读进度与告警一律写 stderr, 避免污染调用方的 JSON 解析
# 运行平台    : Linux only

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _log <level> <event> <msg> [extra] -> 0: 追加 JSON Lines 事件
#   _say <text> -> 0: 向 stderr 输出人读进度
#   _warn_once <text> -> 0: 同次运行只提示一次
#   _die <code> <message> -> 不返回: 输出单行 JSON 后按码退出
#   _parse_args <args...> -> 0/2: 解析位置参数与选项
#   _require_cmds -> 0/2: 校验依赖命令
#   _unit_active -> 0/1: 判断单元是否 active
#   _listen_ok <port> -> 0/1: 判断本地端口是否有监听
#   _read_metrics -> 0/1: 拉取指标文本
#   _active_routes <body> -> 0/1: 解析活动路由数
#   _cpu_quota_usec <v> -> 0: 把 CPUQuota 字面值换算为微秒
#   _session_files -> 0: 输出 JSON 数组
#   _resource_limits -> 0/1: 输出资源上限 JSON 与是否达标
#   _journal_cap -> 0: 输出 journald 容量 JSON, 仅提示不判定
#   _bridge_state -> 0: 输出网页桥接 JSON(单元 active/端口监听/配对残留), 未安装则标记跳过
#   _emit <ok> <message> <error_code> <data_json> <confirm> -> 不返回
#   _cleanup -> 0: 删除临时文件

# =========** 常量与默认值 =========**
SSH_PORT="${CH_SSH_PORT:-22}"
WS_PORT="${CH_WS_PORT:-443}"
WS_BACKEND_PORT="${CH_WS_BACKEND_PORT:-8443}"
METRICS_URL="${CH_METRICS_URL:-http://127.0.0.1:9100/metrics}"
STATE_DIR="${CH_STATE_DIR:-/var/lib/uptermd}"
RUNTIME_DIR="${CH_RUNTIME_DIR:-/run/uptermd}"
UNIT_NAME="${CH_UNIT:-uptermd.service}"
JOURNAL_DROPIN="${CH_JOURNAL_DROPIN:-/etc/systemd/journald.conf.d/90-uptermd-limits.conf}"
JOURNAL_MAX="${CH_JOURNAL_MAX:-200M}"
LOG_DIR="${CH_LOG_DIR:-/var/log/uptermd-deploy/logs}"
BRIDGE_UNIT="${CH_BRIDGE_UNIT:-actssh-web-bridge.service}"
BRIDGE_PORT="${CH_BRIDGE_PORT:-8081}"

LOGGER="deploy.check_relay_health"
RUN_ID="$(date -u '+%Y%m%d_%H%M%S')_$$"
LOG_FILE=""
HOST=""
WARNED=0
CLEANED=0
CHECK_DATA=""
CHECK_CONFIRM=""

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法到 stderr
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat >&2 <<'USAGE'
用法: check-relay-health.sh [host] [port]

只读检查中转机, 标准输出为一行 JSON.
  host  输出标识, 可省略
  port  SSH 入口端口, 可省略, 默认取 CH_SSH_PORT 或 22

可用环境变量: CH_SSH_PORT, CH_WS_PORT, CH_METRICS_URL, CH_STATE_DIR,
              CH_RUNTIME_DIR, CH_UNIT, CH_JOURNAL_DROPIN, CH_JOURNAL_MAX
USAGE
}

# =========** 函数 =========**
_warn_once() {
    # 用途: 同次运行只向 stderr 提示一次
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    if (( WARNED == 1 )); then
        return 0
    fi
    WARNED=1
    printf '[WARN] %s\n' "$1" >&2
}

_log() {
    # 用途: 追加一行 JSON Lines 事件, 写失败只降级提示
    # 参数: $1 级别; $2 事件; $3 描述; $4 可选 JSON 片段
    # 返回: 无; 退出码: 恒 0
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
        _warn_once "日志序列化失败: event=${event}"
        return 0
    fi
    printf '%s\n' "$line" >>"$LOG_FILE" || _warn_once "日志写入失败: path=${LOG_FILE}"
}

_say() {
    # 用途: 向 stderr 输出人读进度, stdout 只留结果 JSON
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    printf '%s\n' "$1" >&2
}

_emit() {
    # 用途: 输出唯一一行结果 JSON 并退出
    # 参数: $1 ok; $2 message; $3 error_code; $4 data JSON; $5 confirm
    # 返回: 不返回; 退出码: ok 为 true 时 0, 否则 1
    local ok="$1" msg="$2" code="$3" data="$4" confirm="$5"
    jq -nc \
        --argjson ok "$ok" --arg message "$msg" \
        --arg error_code "$code" --argjson data "$data" --arg confirm "$confirm" \
        '{ok:$ok,message:$message,error_code:(if $error_code == "" then null else $error_code end),data:$data,confirm:$confirm}'
    if [[ "$ok" == "true" ]]; then
        exit 0
    fi
    exit 1
}

_die() {
    # 用途: 参数或依赖错误时仍输出一行 JSON, 便于调用方统一解析
    # 参数: $1 退出码; $2 描述
    # 返回: 不返回; 退出码: $1
    local code="$1" msg="$2"
    _log ERROR "health.check.failed" "$msg" \
        "{\"exc_type\":\"HealthCheckError\",\"exc_msg\":$(jq -Rn --arg v "$msg" '$v')}"
    jq -nc --arg message "$msg" \
        '{ok:false,message:$message,error_code:"CHECK_FAILED",data:{listen_state:"unknown",route_table_empty:false,session_files_found:[],journal_cap:{}},confirm:""}'
    exit "$code"
}

_parse_args() {
    # 用途: 解析位置参数与帮助
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) show_usage; exit 0 ;;
            --ssh-port) SSH_PORT="${2:?缺少 --ssh-port 取值}"; shift 2 ;;
            --ws-port) WS_PORT="${2:?缺少 --ws-port 取值}"; shift 2 ;;
            --metrics-url) METRICS_URL="${2:?缺少 --metrics-url 取值}"; shift 2 ;;
            --unit) UNIT_NAME="${2:?缺少 --unit 取值}"; shift 2 ;;
            -*) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
            *)
                if [[ -z "$HOST" ]]; then
                    HOST="$1"
                else
                    SSH_PORT="$1"
                fi
                shift
                ;;
        esac
    done
    if [[ -z "$HOST" ]]; then
        HOST="127.0.0.1"
    fi
    LOG_FILE="${LOG_DIR}/${RUN_ID}.jsonl"
}

_require_cmds() {
    # 用途: 校验依赖命令齐全
    # 参数: 无
    # 返回: 无; 退出码: 0 或 2
    local cmd missing=()
    for cmd in systemctl curl jq ss find awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        _die 2 "依赖命令缺失: ${missing[*]}"
    fi
}

_unit_active() {
    # 用途: 判断单元是否处于 active
    # 参数: 无
    # 返回: 退出码: 0 active; 1 非 active 或不存在
    systemctl is-active --quiet "$UNIT_NAME"
}

_listen_ok() {
    # 用途: 判断本地端口是否有监听
    # 参数: $1 端口
    # 返回: 退出码: 0 有监听; 1 无监听
    local port="$1" listeners
    listeners="$(ss -Hltn "sport = :${port}")"
    [[ -n "$listeners" ]]
}

_read_metrics() {
    # 用途: 拉取指标文本
    # 参数: $1 输出变量名由调用方保存
    # 返回: 标准输出指标文本; 退出码: 0 成功; 1 不可达
    curl -fsS --connect-timeout 3 --max-time 10 "$METRICS_URL"
}

_active_routes() {
    # 用途: 从指标文本解析活动路由数; v0.41.1 实际指标带 upterm_uptermd_ 前缀且没有 routing_active_connections_count
    # 参数: $1 指标文本
    # 返回: 标准输出整数; 退出码: 0 成功; 1 候选指标均缺失
    local body="$1" name value
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

_session_files() {
    # 用途: 列出运行目录全部条目与状态目录中的预期外文件, 输出 JSON 数组
    # 参数: 无
    # 返回: 标准输出 JSON 数组; 退出码: 0
    local files=() path base entry
    if [[ -d "$RUNTIME_DIR" ]]; then
        while read -r entry; do
            files+=("$entry")
        done < <(find "$RUNTIME_DIR" -mindepth 1 -maxdepth 2 -print)
    fi
    if [[ -d "$STATE_DIR" ]]; then
        while read -r path; do
            base="${path#"${STATE_DIR}"/}"
            case "$base" in
                server_key|server_key.pub|archive|archive/*) ;;
                *) files+=("$path") ;;
            esac
        done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 2 -type f)
    fi
    if (( ${#files[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    printf '%s\n' "${files[@]}" | jq -R . | jq -s .
}

_resource_limits() {
    # 用途: 读取单元资源上限并判断是否与设计一致
    # 参数: 无
    # 返回: 标准输出 JSON 对象; 退出码: 0 达标; 1 未达标
    local mem cpu tasks cpu_usec ok=true
    mem="$(systemctl show -p MemoryMax --value "$UNIT_NAME")" || return 1
    cpu="$(systemctl show -p CPUQuotaPerSecUSec --value "$UNIT_NAME")" || return 1
    tasks="$(systemctl show -p TasksMax --value "$UNIT_NAME")" || return 1
    cpu_usec="$(_cpu_quota_usec "$cpu")"
    if [[ "$mem" != "1073741824" && "$mem" != "1G" ]]; then
        ok=false
    fi
    if [[ "$cpu_usec" != "1500000" ]]; then
        ok=false
    fi
    if [[ "$tasks" != "512" ]]; then
        ok=false
    fi
    jq -nc \
        --arg memory_max "$mem" --arg cpu_quota "$cpu" --arg tasks_max "$tasks" \
        --argjson ok "$ok" \
        '{memory_max:$memory_max,cpu_quota:$cpu_quota,tasks_max:$tasks_max,ok:$ok}'
    if [[ "$ok" == "true" ]]; then
        return 0
    fi
    return 1
}

_to_bytes() {
    # 用途: 把 journalctl 的容量字面量换算为字节
    # 参数: $1 形如 12.3M 或 0B
    # 返回: 标准输出字节数; 退出码: 0
    awk -v v="$1" 'BEGIN {
        unit = substr(v, length(v), 1)
        num = v + 0
        if (unit == "K") num *= 1024
        else if (unit == "M") num *= 1024 * 1024
        else if (unit == "G") num *= 1024 * 1024 * 1024
        printf "%.0f", num
    }'
}

_journal_cap() {
    # 用途: 读取 journald 上限配置与实际占用, 仅作提示; 中继可能与其他服务共用一台机, 全局封顶会影响别人, 故不计入判定
    # 参数: 无
    # 返回: 标准输出 JSON 对象; 退出码: 恒 0
    local configured="" usage_bytes=0 usage_text="" ok=false
    if [[ -f "$JOURNAL_DROPIN" ]]; then
        configured="$(awk -F= '$1 == "SystemMaxUse" { print $2 }' "$JOURNAL_DROPIN" | tail -n 1)"
    fi
    if command -v journalctl >/dev/null 2>&1; then
        usage_text="$(LC_ALL=C journalctl --disk-usage 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+([KMGTP]B?|B)$/) { print $i; exit } }')"
        if [[ -n "$usage_text" ]]; then
            usage_bytes="$(_to_bytes "$usage_text")"
        fi
    fi
    if [[ "$configured" == "$JOURNAL_MAX" && -n "$usage_text" ]] && (( usage_bytes <= 209715200 )); then
        ok=true
    fi
    jq -nc \
        --arg limit "$JOURNAL_MAX" --arg configured "$configured" \
        --arg usage "$usage_text" --argjson usage_bytes "$usage_bytes" \
        --argjson ok "$ok" \
        '{limit:$limit,configured:$configured,usage:$usage,usage_bytes:$usage_bytes,within_cap:$ok,advisory:true}'
    return 0
}

_bridge_state() {
    # 用途: 检查网页桥接单元, 输出进程状态/端口监听/配对残留
    # 参数: 无; 读取 CH_BRIDGE_UNIT 与 CH_BRIDGE_PORT
    # 返回: 标准输出 JSON; 退出码: 0 未安装(跳过) 或状态已输出
    local installed=false unit_active=false listen_ok=false
    local active_routes=null restart_clean=null since raw last_start ok=false
    if ! systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1; then
        jq -nc '{installed:false,unit_active:false,listen_ok:false,active_routes:null,restart_clean:null,ok:true,advisory:true}'
        return 0
    fi
    installed=true
    if systemctl is-active --quiet "$BRIDGE_UNIT"; then
        unit_active=true
    fi
    if _listen_ok "$BRIDGE_PORT"; then
        listen_ok=true
    fi
    since="$(systemctl show -p ActiveEnterTimestamp --value "$BRIDGE_UNIT" 2>/dev/null | awk '{ print $2" "$3 }')"
    if [[ -n "$since" ]]; then
        raw="$(journalctl -u "$BRIDGE_UNIT" -o cat --since "$since" --no-pager 2>/dev/null || true)"
        last_start="$(printf '%s\n' "$raw" | jq -Rr 'fromjson? | select(.event=="bridge.started") | (.active_routes // 0)' 2>/dev/null | tail -n 1)"
        if [[ -n "$last_start" ]]; then
            if [[ "$last_start" == "0" ]]; then
                restart_clean=true
            else
                restart_clean=false
            fi
        fi
        active_routes="$(printf '%s\n' "$raw" | jq -Rr 'fromjson? | select(.event=="bridge.started" or .event=="bridge.runner.connected" or .event=="bridge.runner.closed") | (.active_routes // 0)' 2>/dev/null | tail -n 1)"
        if [[ -z "$active_routes" ]]; then
            active_routes="${last_start:-0}"
        fi
    fi
    if [[ "$unit_active" == "true" && "$listen_ok" == "true" ]]; then
        ok=true
    fi
    jq -nc \
        --argjson installed "$installed" --argjson unit_active "$unit_active" \
        --argjson listen_ok "$listen_ok" --argjson active_routes "${active_routes:-null}" \
        --argjson restart_clean "${restart_clean:-null}" --argjson ok "$ok" \
        --arg port "$BRIDGE_PORT" --arg unit "$BRIDGE_UNIT" \
        '{installed:$installed,unit:$unit,port:$port,unit_active:$unit_active,listen_ok:$listen_ok,active_routes:$active_routes,restart_clean:$restart_clean,ok:$ok,advisory:false}'
    return 0
}

# =========** 清理 =========**
_cleanup() {
    # 用途: 单次运行无临时文件, 保留幂等占位以统一钩子形态
    # 参数: 无
    # 返回: 无; 退出码: 0
    if (( CLEANED == 1 )); then
        return 0
    fi
    CLEANED=1
    return 0
}

trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =========** 主流程 =========**
_parse_args "$@"

# 日志目录不可写属降级分支: 提示一次后继续
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    _warn_once "日志目录不可写: path=${LOG_DIR}, 本次仅输出终端"
    LOG_FILE=""
fi

_require_cmds
_log INFO "health.run.started" "开始中转健康检查" \
    "{\"host\":$(jq -Rn --arg v "$HOST" '$v'),\"ssh_port\":${SSH_PORT}}"

unit_active=false
if _unit_active; then
    unit_active=true
fi

listen_ssh=false
listen_ws=false
listen_ws_backend=false
if _listen_ok "$SSH_PORT"; then
    listen_ssh=true
fi
if _listen_ok "$WS_PORT"; then
    listen_ws=true
fi
if _listen_ok "$WS_BACKEND_PORT"; then
    listen_ws_backend=true
fi
listen_state="$(jq -nc \
    --arg ssh "${HOST}:${SSH_PORT}" --argjson ssh_ok "$listen_ssh" \
    --arg ws "${HOST}:${WS_PORT}" --argjson ws_ok "$listen_ws" \
    --arg ws_backend "port:${WS_BACKEND_PORT}" --argjson ws_backend_ok "$listen_ws_backend" \
    '{ssh:$ssh,ssh_ok:$ssh_ok,ws:$ws,ws_ok:$ws_ok,ws_backend:$ws_backend,ws_backend_ok:$ws_backend_ok}')"

metrics_body=""
route_empty=false
active_value=""
error_code=""
message=""
if metrics_body="$(_read_metrics)"; then
    if active_value="$(_active_routes "$metrics_body")"; then
        if [[ "$active_value" == "0" ]]; then
            route_empty=true
        fi
    else
        error_code="RELAY_METRIC_MISSING"
        message="指标端点可用但缺少 routing_active_connections_count"
    fi
else
    error_code="RELAY_METRICS_UNREACHABLE"
    message="指标端点不可达: url=${METRICS_URL}"
fi

session_files_found="$(_session_files)"

limits_json="{}"
limits_ok=false
if limits_json="$(_resource_limits)"; then
    limits_ok=true
fi
if [[ -z "$limits_json" ]]; then
    limits_json='{}'
fi

journal_json="$(_journal_cap)"
if [[ -z "$journal_json" ]]; then
    journal_json='{}'
fi
journal_within_cap="$(printf '%s' "$journal_json" | jq -r '.within_cap // false')"

bridge_json="$(_bridge_state)"
if [[ -z "$bridge_json" ]]; then
    bridge_json='{}'
fi
bridge_installed="$(printf '%s' "$bridge_json" | jq -r '.installed // false')"
bridge_ok="$(printf '%s' "$bridge_json" | jq -r '.ok // true')"

listen_ok=false
if [[ "$listen_ssh" == "true" && ( "$listen_ws" == "true" || "$listen_ws_backend" == "true" ) ]]; then
    listen_ok=true
fi

session_count="$(printf '%s' "$session_files_found" | jq 'length')"

data="$(jq -nc \
    --argjson listen_state "$listen_state" \
    --argjson route_table_empty "$route_empty" \
    --argjson session_files_found "$session_files_found" \
    --argjson journal_cap "$journal_json" \
    --argjson resource_limits "$limits_json" \
    --argjson unit_active "$unit_active" \
    --argjson active_routes "${active_value:-null}" \
    --argjson bridge "$bridge_json" \
    '{listen_state:$listen_state,route_table_empty:$route_table_empty,session_files_found:$session_files_found,journal_cap:$journal_cap,resource_limits:$resource_limits,unit_active:$unit_active,active_routes:$active_routes,bridge:$bridge}')"

confirm="本检查判定「重启后映射为空」的方式是活动路由为 0 且无会话文件; 若刚发生重启, 该状态可直接作为空路由证据, 否则请先重启再复查."

if [[ "$unit_active" != "true" ]]; then
    _log ERROR "health.unit.inactive" "单元未运行" "{\"unit\":$(jq -Rn --arg v "$UNIT_NAME" '$v')}"
    _emit false "单元未运行: unit=${UNIT_NAME}" "RELAY_UNIT_INACTIVE" "$data" "$confirm"
fi
if [[ -n "$error_code" ]]; then
    _log ERROR "health.metrics.failed" "$message" "{}"
    _emit false "$message" "$error_code" "$data" "$confirm"
fi
if [[ "$listen_ok" != "true" ]]; then
    _log ERROR "health.listen.failed" "入口监听不完整" "{}"
    _emit false "入口监听不完整: ssh=${listen_ssh} ws=${listen_ws} ws_backend=${listen_ws_backend}" "RELAY_LISTEN_MISSING" "$data" "$confirm"
fi
if [[ "$route_empty" != "true" ]]; then
    _log ERROR "health.routes.not_empty" "存在活动路由, 不满足无状态判据" "{\"active\":${active_value:-unknown}}"
    _emit false "存在活动路由, 中转不是空状态: active=${active_value:-unknown}" "RELAY_ROUTES_NOT_EMPTY" "$data" "$confirm"
fi
if (( session_count > 0 )); then
    _log ERROR "health.session_files.found" "发现会话文件或预期外文件" "{\"count\":${session_count}}"
    _emit false "发现会话文件或预期外文件: count=${session_count}" "RELAY_SESSION_FILES_FOUND" "$data" "$confirm"
fi
if [[ "$limits_ok" != "true" ]]; then
    _log ERROR "health.limits.invalid" "资源上限与设计不符" "{}"
    _emit false "资源上限与设计不符, 需核对单元文件与 systemd 版本" "RELAY_LIMITS_INVALID" "$data" "$confirm"
fi
if [[ "$bridge_installed" == "true" && "$bridge_ok" != "true" ]]; then
    _log ERROR "health.bridge.unhealthy" "网页桥接单元或监听异常" "{\"unit\":$(jq -Rn --arg v "$BRIDGE_UNIT" '$v'),\"port\":${BRIDGE_PORT}}"
    _emit false "网页桥接异常: unit=${BRIDGE_UNIT} active=$(printf '%s' "$bridge_json" | jq -r '.unit_active') listen=$(printf '%s' "$bridge_json" | jq -r '.listen_ok')" "BRIDGE_UNHEALTHY" "$data" "$confirm"
fi
if [[ "$journal_within_cap" != "true" ]]; then
    # 中继可能与非中继服务共用一台机, 全局封顶会影响别人, 这里只提示不拦截
    _say "[WARN] journald 容量仅作提示, 不影响判定: max=${JOURNAL_MAX} usage=$(printf '%s' "$journal_json" | jq -r '.usage // "unknown"')"
    _log WARN "health.journal.advisory" "journald 容量超出提示阈值, 不影响判定" "{}"
fi

_log INFO "health.run.finished" "全部判据通过" "{\"active_routes\":0}"
bridge_note=""
if [[ "$bridge_installed" == "true" ]]; then
    bridge_note=", 网页桥接正常(配对残留=$(printf '%s' "$bridge_json" | jq -r '.active_routes'))"
fi
_emit true "中转运行正常: 监听齐备, 路由为空, 无会话文件, 资源上限生效${bridge_note}" "" "$data" "$confirm"

#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : lib.sh
# 所属目录    : relay/bootstrap/
# 文件用途    : 为 bootstrap 系列脚本提供日志, 幂等写文件, 端口归属与证书有效期判定的公共函数
# 架构定位    : 部署脚本公共层; 由 relay/install.sh 与同目录子脚本 source, 不直接执行
# 核心功能    : JSONL 日志与终端进度, 失败退出与 ERR 钩子, 幂等写文件与建目录, 监听端口与 cgroup 归属判定, 证书到期计算
# 职责边界    : 不安装软件, 不改服务配置, 不定义业务端口默认值; 只提供可复用的判定与写入原语
# 运行环境    : Ubuntu 20.04 与 22.04, bash 5.x, 以 root 执行
# 依赖关系    : 依赖 jq, ss, systemctl, install, openssl, date, awk; 由各调用脚本在文件头声明
#
# 输入        : 调用方预置 BS_LOG_DIR 与 BS_RUN_ID, 并调用 bs_init_logging 指定 logger
# 退出码      : 本文件只提供函数; 函数返回 0 或 1, 终止由调用方的 bs_die 完成
# 依赖命令    : jq, ss, systemctl, install, openssl, date, awk, cp, rm, mkdir
# 运行平台    : Linux only

# =========** 常量与默认值 =========**
# 日志相关状态由 bs_init_logging 赋值, 未初始化时所有日志函数静默返回
BS_LOGGER="${BS_LOGGER:-bootstrap}"
BS_LOG_DIR="${BS_LOG_DIR:-}"
BS_RUN_ID="${BS_RUN_ID:-}"
BS_LOG_FILE="${BS_LOG_FILE:-}"
BS_LOG_WARNED=0

# =========** 函数 =========**
bs_now() {
    # 用途: 生成带时区的 ISO 8601 时间戳
    # 参数: 无
    # 返回: 标准输出时间戳; 退出码: 0
    date '+%Y-%m-%dT%H:%M:%S%:z'
}

bs_init_logging() {
    # 用途: 初始化 JSONL 日志文件; 目录不可写时降级为只输出终端
    # 参数: $1 logger 名; $2 日志目录; $3 run_id
    # 返回: 无; 退出码: 0; 副作用: 设置 BS_LOGGER 与 BS_LOG_FILE
    BS_LOGGER="$1"
    BS_LOG_DIR="$2"
    BS_RUN_ID="$3"
    BS_LOG_FILE="${BS_LOG_DIR}/${BS_RUN_ID}.jsonl"
    BS_LOG_WARNED=0
    if ! mkdir -p "$BS_LOG_DIR" 2>/dev/null; then
        BS_LOG_FILE=""
        printf '[WARN] 日志目录不可写: path=%s\n' "$BS_LOG_DIR" >&2
        return 0
    fi
    # 追加而非截断: 同一 run_id 下主脚本与子脚本共用一份日志
    if ! : >>"$BS_LOG_FILE" 2>/dev/null; then
        BS_LOG_FILE=""
        printf '[WARN] 日志文件不可写: path=%s\n' "${BS_LOG_DIR}/${BS_RUN_ID}.jsonl" >&2
    fi
    return 0
}

bs_warn_once() {
    # 用途: 同次运行只向 stderr 提示一次
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    if (( BS_LOG_WARNED == 1 )); then
        return 0
    fi
    BS_LOG_WARNED=1
    printf '[WARN] %s\n' "$1" >&2
}

bs_log() {
    # 用途: 追加一行 JSONL 事件; 写失败只降级提示, 不中断业务
    # 参数: $1 级别; $2 事件名; $3 描述; $4 可选 JSON 对象片段
    # 返回: 无; 退出码: 恒 0
    local level="$1" event="$2" msg="$3" extra="${4:-}" line
    if [[ -z "$BS_LOG_FILE" ]]; then
        return 0
    fi
    if [[ -z "$extra" ]]; then
        extra='{}'
    fi
    if ! line=$(jq -nc \
        --arg ts "$(bs_now)" --arg level "$level" --arg logger "$BS_LOGGER" \
        --arg event "$event" --arg msg "$msg" --arg run_id "$BS_RUN_ID" \
        --argjson extra "$extra" \
        '{ts:$ts,level:$level,logger:$logger,event:$event,msg:$msg,run_id:$run_id} + $extra' 2>/dev/null); then
        bs_warn_once "日志序列化失败: event=${event}"
        return 0
    fi
    printf '%s\n' "$line" >>"$BS_LOG_FILE" || bs_warn_once "日志写入失败: path=${BS_LOG_FILE}"
}

bs_say() {
    # 用途: 输出面向运维人员的进度行, 与 JSONL 日志分离
    # 参数: $1 文本
    # 返回: 无; 退出码: 0
    printf '%s\n' "$1"
}

bs_die() {
    # 用途: 记录 ERROR 后按指定退出码终止
    # 参数: $1 退出码; $2 事件名; $3 描述
    # 返回: 不返回; 退出码: $1
    local code="$1" event="$2" msg="$3"
    bs_log ERROR "$event" "$msg" \
        "{\"exc_type\":\"BootstrapError\",\"exc_msg\":$(jq -Rn --arg v "$msg" '$v'),\"stack\":null}"
    printf '[ERROR] %s\n' "$msg" >&2
    exit "$code"
}

bs_on_error() {
    # 用途: ERR 钩子, 记录未预期失败的命令与行号后按统一码退出
    # 参数: $1 退出码; $2 行号; $3 失败命令
    # 返回: 不返回; 退出码: 7
    local code="$1" line="$2" cmd="$3" trace="" i
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
        trace+="${FUNCNAME[$i]}(${BASH_LINENO[$((i - 1))]}) "
    done
    # 钩子内不得再触发 ERR, 否则递归; 记录后直接退出由主流程语义决定
    set +e
    bs_log ERROR "bootstrap.command.failed" "命令执行失败" \
        "{\"exc_type\":\"ShellCommandError\",\"exc_msg\":$(jq -Rn --arg v "exit=${code} line=${line} cmd=${cmd}" '$v'),\"stack\":$(jq -Rn --arg v "$trace" '$v')}"
    printf '[ERROR] 命令失败: exit=%s line=%s cmd=%s\n' "$code" "$line" "$cmd" >&2
    exit 7
}

bs_require_root() {
    # 用途: 校验 root 身份
    # 参数: 无
    # 返回: 无; 退出码: 0 或 4
    if [[ "$(id -u)" -ne 0 ]]; then
        bs_die 4 "bootstrap.not_root" "需要以 root 执行, 当前 uid=$(id -u)"
    fi
}

bs_require_cmds() {
    # 用途: 校验外部命令齐全, 缺失时一次列出全部
    # 参数: 全部为命令名
    # 返回: 无; 退出码: 0 或 6
    local missing=() cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        bs_die 6 "bootstrap.deps.missing" "依赖命令缺失: ${missing[*]}"
    fi
}

bs_ensure_dir() {
    # 用途: 幂等创建目录并校正权限
    # 参数: $1 路径; $2 权限; $3 属主; $4 属组; $5 是否落地(1 落地, 0 演练)
    # 返回: 无; 退出码: 0 或 1
    local path="$1" mode="$2" owner="$3" group="$4" apply="$5"
    if (( apply == 0 )); then
        bs_say "演练: 将创建目录 ${path} (mode=${mode} owner=${owner}:${group})"
        return 0
    fi
    install -d -m "$mode" -o "$owner" -g "$group" "$path"
}

bs_apply_file() {
    # 用途: 内容有差异才写入, 无差异跳过; 先写同目录暂存文件再原子改名
    # 参数: $1 源文件; $2 目标文件; $3 权限; $4 属主; $5 属组; $6 是否落地
    # 返回: 无; 退出码: 0 或 1
    local src="$1" dst="$2" mode="$3" owner="$4" group="$5" apply="$6"
    local stage="${dst}.tmp.$$"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        return 0
    fi
    if (( apply == 0 )); then
        bs_say "演练: 将写入 ${dst} (mode=${mode} owner=${owner}:${group})"
        return 0
    fi
    install -D -m "$mode" -o "$owner" -g "$group" "$src" "$stage" || return 1
    mv -f "$stage" "$dst" || return 1
}

bs_port_pids() {
    # 用途: 取监听指定 TCP 端口的进程号
    # 参数: $1 端口
    # 返回: 标准输出 pid 列表, 每行一个; 退出码: 0; 无监听时输出为空
    local port="$1" pids
    # 端口空闲时 grep 无匹配会返回 1, 在 pipefail 下必须显式吞掉
    pids="$(ss -Hltnp "sport = :${port}" 2>/dev/null | grep -oE 'pid=[0-9]+' || true)"
    if [[ -z "$pids" ]]; then
        return 0
    fi
    printf '%s\n' "$pids" | cut -d= -f2 | sort -u
}

bs_pid_unit() {
    # 用途: 由进程号反查所属 systemd 单元
    # 参数: $1 pid
    # 返回: 标准输出单元名; 退出码: 0 找到; 1 未知
    local pid="$1" cg
    if [[ ! -r "/proc/${pid}/cgroup" ]]; then
        return 1
    fi
    cg="$(tr '\n' ' ' <"/proc/${pid}/cgroup")"
    if [[ "$cg" =~ ([A-Za-z0-9_.@-]+\.service) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

bs_listen_ok() {
    # 用途: 判断指定端口是否有监听, 并可选校验绑定地址
    # 参数: $1 端口; $2 期望绑定地址, 空表示任意, 0.0.0.0 表示要求通配监听
    # 返回: 退出码: 0 有监听; 1 无监听或地址不匹配
    local port="$1" host="${2:-}" lines line addr
    lines="$(ss -Hltn "sport = :${port}" 2>/dev/null || true)"
    if [[ -z "$lines" ]]; then
        return 1
    fi
    if [[ -z "$host" ]]; then
        return 0
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        addr="$(awk '{print $4}' <<<"$line")"
        case "$addr" in
            "${host}:"*) return 0 ;;
        esac
        if [[ "$host" == "0.0.0.0" ]]; then
            case "$addr" in
                "0.0.0.0:"*|"*:"*) return 0 ;;
            esac
        fi
    done <<<"$lines"
    return 1
}

bs_listener_owned_by() {
    # 用途: 判断端口上的全部监听进程是否都属于给定单元, 用于区分自有服务与外部占用
    # 参数: $1 端口; 其余为允许的单元名
    # 返回: 退出码: 0 全部属于允许单元; 1 空闲或存在外部占用
    local port="$1" pid unit allowed match
    shift
    local pids
    pids="$(bs_port_pids "$port")"
    if [[ -z "$pids" ]]; then
        return 1
    fi
    for pid in $pids; do
        unit="$(bs_pid_unit "$pid" || true)"
        if [[ -z "$unit" ]]; then
            return 1
        fi
        match=0
        for allowed in "$@"; do
            if [[ "$unit" == "$allowed" ]]; then
                match=1
            fi
        done
        if (( match == 0 )); then
            return 1
        fi
    done
    return 0
}

bs_cert_not_after() {
    # 用途: 读取证书到期时间
    # 参数: $1 证书路径
    # 返回: 标准输出日期字符串; 退出码: 0 或 1
    local cert="$1"
    if [[ ! -r "$cert" ]]; then
        return 1
    fi
    openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/^notAfter=//'
}

bs_cert_days_left() {
    # 用途: 计算证书剩余天数, 用于自检与续期阈值
    # 参数: $1 证书路径
    # 返回: 标准输出整数天数; 退出码: 0 或 1
    local cert="$1" end now
    end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/^notAfter=//')"
    if [[ -z "$end" ]]; then
        return 1
    fi
    now="$(date +%s)"
    local end_s
    end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
    printf '%s' "$(( (end_s - now) / 86400 ))"
}

bs_require_uint() {
    # 用途: 校验参数为非负整数
    # 参数: $1 名称; $2 取值
    # 返回: 无; 退出码: 0 或 2
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        bs_die 2 "bootstrap.args.invalid" "参数需为非负整数: name=${name} value=${value}"
    fi
}

bs_require_port() {
    # 用途: 校验端口取值在 1 到 65535 之间
    # 参数: $1 名称; $2 取值
    # 返回: 无; 退出码: 0 或 2
    local name="$1" value="$2"
    bs_require_uint "$name" "$value"
    if (( value < 1 || value > 65535 )); then
        bs_die 2 "bootstrap.args.invalid" "端口越界: name=${name} value=${value}"
    fi
}

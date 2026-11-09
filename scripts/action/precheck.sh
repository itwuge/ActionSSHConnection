#!/usr/bin/env bash
# 文件: scripts/action/precheck.sh
# 所属目录: scripts/action/
# 文件用途: 校验调用输入与前置配置, 生成 known_hosts 与访客公钥闸门, 计算到期时间与连接路径.
# 架构定位: Action 步骤脚本; 上游是 action.yml 传入的 ACTSSH_* 环境变量, 下游是 start-session.sh 与 route.sh.
# 职责边界: 不安装客户端, 不建立会话, 不输出连接串; 只写 GITHUB_OUTPUT.
# 运行环境: POSIX shell + bash 4; 依赖 gh / jq / python3 / ssh-keygen / tmux（ssh 关闭时只要求 jq 与 python3）.

set -euo pipefail

fail() {
  echo "失败[阶段 $1]：$2" >&2
  exit 1
}

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
relay_host="${ACTSSH_RELAY_HOST:?缺少 relay-host}"
relay_port="${ACTSSH_RELAY_PORT:?缺少 relay-port}"
ssh_user="${ACTSSH_SSH_USER:?缺少 ssh-user}"
known_host="${ACTSSH_KNOWN_HOST:-}"
web_base="${ACTSSH_WEB_BASE_URL:-}"
session_minutes="${ACTSSH_SESSION_MINUTES:-45}"

ssh_enabled="$(printf '%s' "${ACTSSH_SSH_ENABLED:-false}" | tr -d '[:space:]')"
case "$ssh_enabled" in
  true|True|TRUE) ssh_enabled=true ;;
  *) ssh_enabled=false ;;
esac

# repository_dispatch 入口沿用原工作流的发起者闸门; workflow_dispatch 无 client_payload, 不适用
if [ "${GITHUB_EVENT_NAME:-}" = "repository_dispatch" ]; then
  [ "${ACTSSH_DISPATCH_KEYWORD:-}" = "start-session" ] ||
    fail precheck "client_payload.keyword 必须为 start-session"
  [ "${ACTSSH_DISPATCH_SENDER:-}" = "$ssh_user" ] ||
    fail precheck "repository_dispatch 发起者不是 $ssh_user"
fi

[ -n "$known_host" ] || fail precheck "缺少 known-hosts（中继主机公钥行）"
[ -n "$web_base" ] || fail precheck "缺少 web-base-url"
case "$session_minutes" in
  ''|*[!0-9]*) fail precheck "session-minutes 必须是正整数" ;;
esac
[ "$session_minutes" -gt 0 ] || fail precheck "session-minutes 必须大于 0"

command -v jq >/dev/null 2>&1 || fail precheck "运行器缺少 jq"
command -v python3 >/dev/null 2>&1 || fail precheck "运行器缺少 python3"

mkdir -p "$workdir"
chmod 700 "$workdir"

# 中继主机公钥只用于防中间人，不作为授权依据
printf '%s\n' "$known_host" > "$workdir/known_hosts"

# 到期时间按 session-minutes 推算，误差为前置步骤耗时（数秒）
expires_at="$(date -u -d "@$(( $(date +%s) + session_minutes * 60 ))" '+%Y-%m-%dT%H:%M:%SZ')"

# 阶段一：打洞。托管 runner 无入站端口，通常无可用对端地址，按「无可用对端地址」直接回落中继。
# 配置了候选地址时只做 5 秒 TCP 可达性探针；数据面是否真的直连 [待真机确认]。
mode=relay
if [ -n "${ACTSSH_DIRECT_ENDPOINT:-}" ]; then
  host="${ACTSSH_DIRECT_ENDPOINT%%:*}"
  port=22
  case "$ACTSSH_DIRECT_ENDPOINT" in *:*) port="${ACTSSH_DIRECT_ENDPOINT##*:}" ;; esac
  if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    mode=direct
  fi
fi
if [ "$mode" = "direct" ]; then
  echo "直连已建立（直连）"
  echo "::warning::直连判定为 TCP 可达性探针，数据面直连未验证"
else
  echo "直连未建立，已切换到中继转发"
fi

# ssh=false：只做前置校验，不开会话；输出 enabled=false 供后续步骤跳过
if [ "$ssh_enabled" != "true" ]; then
  echo "::warning::ssh=false：只做前置校验，不建立会话（不安装客户端、不反连中继、不启动网页桥接）"
  {
    echo "enabled=false"
    echo "fingerprints="
    echo "expires_at=$expires_at"
    echo "path_mode=disabled"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

command -v ssh-keygen >/dev/null 2>&1 || fail precheck "运行器缺少 ssh-keygen"
command -v tmux >/dev/null 2>&1 || fail precheck "运行器缺少 tmux"
command -v gh >/dev/null 2>&1 || fail precheck "运行器缺少 gh"

# runner 侧访客公钥闸门：只放行该 GitHub 用户登记的公钥
gh api "users/$ssh_user/keys" --paginate --jq '.[].key' > "$workdir/authorized_keys" || {
  fail fetch-keys "取不到 $ssh_user 的公钥"
}
[ -s "$workdir/authorized_keys" ] || fail fetch-keys "$ssh_user 未登记 SSH 公钥"

fingerprints=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  fp="$(printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')"
  [ -n "$fp" ] || continue
  fingerprints="${fingerprints:+$fingerprints,}$fp"
done < "$workdir/authorized_keys"
[ -n "$fingerprints" ] || fail fetch-keys "公钥指纹计算失败"

{
  echo "enabled=true"
  echo "fingerprints=$fingerprints"
  echo "expires_at=$expires_at"
  echo "path_mode=$mode"
} >> "$GITHUB_OUTPUT"

echo "前置校验通过：$ssh_user 公钥 ${fingerprints}"
echo "中继 ${relay_host}:${relay_port}，会话上限 ${session_minutes} 分钟，Action ref ${ACTSSH_ACTION_REF:-未标注}"

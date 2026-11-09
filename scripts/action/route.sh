#!/usr/bin/env bash
# 文件: scripts/action/route.sh
# 所属目录: scripts/action/
# 文件用途: 按白名单输出 9 个路由字段, 并写入步骤摘要与字段文件.
# 架构定位: Action 步骤脚本; 上游是 precheck / start-session, 下游是 Action outputs 与可选制品.
# 职责边界: 只输出 9 项路由字段, 不输出连接串、公钥内容或凭据.
# 运行环境: POSIX shell + bash 4; 仅依赖标准命令.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
enabled="$(printf '%s' "${ACTSSH_ENABLED:-true}" | tr -d '[:space:]')"
relay_host="${ACTSSH_RELAY_HOST:?缺少 ACTSSH_RELAY_HOST}"
relay_port="${ACTSSH_RELAY_PORT:?缺少 ACTSSH_RELAY_PORT}"
web_base="${ACTSSH_WEB_BASE_URL:?缺少 ACTSSH_WEB_BASE_URL}"

if [ "$enabled" != "true" ]; then
  # ssh=false：字段仍要齐备（调用方按 9 项解析），会话相关项统一写 none
  session_id=none
  ssh_user=none
  web_url=none
  fingerprints=none
  path_mode=disabled
else
  session_id="${ACTSSH_SESSION_ID:-}"
  ssh_user="${ACTSSH_SSH_LOGIN_USER:-}"
  fingerprints="${ACTSSH_FINGERPRINTS:-}"
  path_mode="${ACTSSH_PATH_MODE:-relay}"
  if [ -z "$session_id" ] || [ -z "$ssh_user" ]; then
    echo "失败[阶段 parse-connection]：会话标识或 SSH 登录名为空" >&2
    exit 1
  fi
  web_url="${web_base%/}/t/${session_id}"
fi

credential_id="${ACTSSH_CREDENTIAL_ID:-unset}"
[ -n "$credential_id" ] || credential_id=unset
expires_at="${ACTSSH_EXPIRES_AT:-}"
[ -n "$expires_at" ] || expires_at=none

fields="$workdir/fields"
{
  echo "relay_host=$relay_host"
  echo "port=$relay_port"
  echo "session_id=$session_id"
  echo "ssh_user=$ssh_user"
  echo "pubkey_fingerprint=$fingerprints"
  echo "expires_at=$expires_at"
  echo "web_url=$web_url"
  echo "pubkey_credential_id=$credential_id"
  echo "path_mode=$path_mode"
} > "$fields"

{
  echo "session_id=$session_id"
  echo "ssh_user=$ssh_user"
  echo "relay_host=$relay_host"
  echo "relay_port=$relay_port"
  echo "web_url=$web_url"
  echo "pubkey_fingerprint=$fingerprints"
  echo "expires_at=$expires_at"
  echo "pubkey_credential_id=$credential_id"
  echo "path_mode=$path_mode"
} >> "$GITHUB_OUTPUT"

cat "$fields"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '```text'
    cat "$fields"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
# 字段文件保留到收尾统一删除，期间可由 action.yml 的暂存步骤另存为制品（只含这 9 行）

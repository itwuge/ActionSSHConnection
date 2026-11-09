#!/usr/bin/env bash
# 文件: scripts/action/route.sh
# 所属目录: scripts/action/
# 文件用途: 按白名单输出 9 个路由字段, 直连时另在日志与摘要输出 direct_endpoint/path_verified.
# 架构定位: Action 步骤脚本; 上游是 precheck / start-session / direct-path, 下游是 Action outputs 与可选制品.
# 职责边界: 9 行制品与 9 个 outputs 不变; 只额外输出两个条件路由字段, 不输出连接串、公钥内容或凭据.
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
  direct_endpoint=""
  path_verified=""
  relay_login=""
else
  session_id="${ACTSSH_SESSION_ID:-}"
  relay_login="${ACTSSH_SSH_LOGIN_USER:-}"
  fingerprints="${ACTSSH_FINGERPRINTS:-}"
  path_mode="${ACTSSH_PATH_MODE:-relay}"
  direct_endpoint="${ACTSSH_DIRECT_ENDPOINT:-}"
  path_verified="${ACTSSH_PATH_VERIFIED:-}"
  case "$path_mode" in
    direct)
      # 直连时 ssh_user 是专用非 root 用户名（无冒号）；中继登录名不再出现在 9 字段里
      ssh_user="${ACTSSH_DIRECT_LOGIN_USER:-}"
      [ -n "$direct_endpoint" ] || {
        echo "失败[阶段 parse-connection]：path_mode=direct 但缺少 direct_endpoint" >&2
        exit 1
      }
      [ -n "$ssh_user" ] || {
        echo "失败[阶段 parse-connection]：path_mode=direct 但缺少直连登录名" >&2
        exit 1
      }
      [ -n "$path_verified" ] || path_verified=unknown
      ;;
    relay|disabled)
      ssh_user="$relay_login"
      direct_endpoint=""
      path_verified=""
      ;;
    *)
      echo "失败[阶段 parse-connection]：path_mode 取值非法（$path_mode）" >&2
      exit 1
      ;;
  esac
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

# 直连条件字段：不属于 9 个 outputs，也不写进 fields 制品；只在 direct 时写入日志与作业摘要。
# path_verified 初始为 unknown，首次连接后由 direct-verify.sh 后续追加 direct/derp。
if [ "$path_mode" = "direct" ]; then
  echo "direct_endpoint=$direct_endpoint"
  echo "path_verified=$path_verified"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '```text'
    cat "$fields"
    echo '```'
    if [ "$path_mode" = "direct" ]; then
      echo ""
      echo "直连条件字段（不属于 9 个 outputs）："
      echo '```text'
      echo "direct_endpoint=$direct_endpoint"
      echo "path_verified=$path_verified"
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
# 字段文件保留到收尾统一删除，期间可由 action.yml 的暂存步骤另存为制品（只含这 9 行）

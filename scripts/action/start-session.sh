#!/usr/bin/env bash
# 文件: scripts/action/start-session.sh
# 所属目录: scripts/action/
# 文件用途: 反连中继建立会话, 解析客户端 JSON 得到会话标识与 SSH 登录名, 并确认共享终端.
# 架构定位: Action 步骤脚本; 上游是 install-upterm, 下游是 route.sh / bridge.sh / wait-session.sh.
# 职责边界: 客户端原始输出只落文件并随即删除; 只输出 session_id 与 ssh_user 两个字段.
# 运行环境: Linux runner; 依赖 upterm（已在 PATH）/ jq / tmux.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
relay_host="${ACTSSH_RELAY_HOST:?缺少 ACTSSH_RELAY_HOST}"
relay_port="${ACTSSH_RELAY_PORT:?缺少 ACTSSH_RELAY_PORT}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"
join_timeout="${ACTSSH_JOIN_TIMEOUT:-10m}"

# v0.41.1 已核实：--detach 在没有可询问的终端时必须配 --accept；
# --detach 成功时退出码为 0，失败为 1；-o json 只把 JSON 打到 stdout。
# 必须显式给出长驻托管命令（v0.41.1 源码：run COMMAND, or $SHELL without one）：
# 缺省 $SHELL 在无访客的 detached PTY 下立即退出，会话会在启动数秒后自行结束。
# 托管命令用 tmux，使 SSH 与网页访客进入同一终端进程；访客在会话内 exit 即 tmux 退出、会话结束。
if ! upterm host \
    --accept \
    --detach \
    --name "$session_name" \
    --server "ssh://${relay_host}:${relay_port}" \
    --known-hosts "$workdir/known_hosts" \
    --authorized-keys "$workdir/authorized_keys" \
    --join-timeout "$join_timeout" \
    --no-sftp \
    --pty-size 80x24 \
    -o json \
    -- tmux new-session -A -s "$session_name" \
    > "$workdir/session.json" 2> "$workdir/session.err"; then
  rm -f "$workdir/session.json" "$workdir/session.err"
  echo "失败[阶段 start-session]：客户端异常退出，原因见运行报告，具体输出不外显" >&2
  exit 1
fi

# 键名以 v0.41.1 源码为准；解析完立即删除原始 JSON，不留在运行器上
session_id_json="$(jq -r '.sessionId // empty' "$workdir/session.json" 2>/dev/null || true)"
ssh_command="$(jq -r '.sshCommand // empty' "$workdir/session.json" 2>/dev/null || true)"
status="$(jq -r '.status // empty' "$workdir/session.json" 2>/dev/null || true)"
rm -f "$workdir/session.json" "$workdir/session.err"

if [ -z "${ssh_command:-}" ]; then
  echo "失败[阶段 linking]：未取得可接入的连接串，会话未完成注册" >&2
  exit 1
fi
if [ "${status:-}" != "ready" ]; then
  echo "失败[阶段 linking]：会话状态为 ${status:-不可读}，未达到 ready" >&2
  exit 1
fi

# 只取用户位，不保留整条命令；ssh:// 中继下形式为 ssh <登录名>@<主机> [-p <端口>]
if [[ "$ssh_command" =~ ^ssh\ ([A-Za-z0-9._:-]+)@ ]]; then
  ssh_user="${BASH_REMATCH[1]}"
else
  echo "失败[阶段 parse-connection]：无法从连接串取出 SSH 登录名" >&2
  exit 1
fi
if [ -z "${session_id_json:-}" ]; then
  echo "失败[阶段 parse-connection]：JSON 中缺少 sessionId" >&2
  exit 1
fi

# session_id 只取冒号前片段；冒号后是 embedded 路由的节点编码，不作会话标识
session_id="${ssh_user%%:*}"
if [ -z "$session_id" ]; then
  echo "失败[阶段 parse-connection]：无法解析会话标识" >&2
  exit 1
fi
case "$session_id" in
  *[!A-Za-z0-9._-]*)
    echo "失败[阶段 parse-connection]：会话标识含非法字符" >&2
    exit 1
    ;;
esac
if [ "$session_id" != "$session_id_json" ]; then
  echo "失败[阶段 parse-connection]：连接串登录名与 JSON sessionId 不一致" >&2
  exit 1
fi

# 共享终端由 upterm host 直接托管（host 命令即 tmux 客户端），这里只确认它已起来，不再另起会话
for _ in $(seq 1 10); do
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "共享终端就绪：tmux 会话 $session_name（由 upterm host 托管）"
    {
      echo "session_id=$session_id"
      echo "ssh_user=$ssh_user"
    } >> "$GITHUB_OUTPUT"
    echo "会话已创建：session_id=$session_id"
    exit 0
  fi
  sleep 1
done
echo "失败[阶段 shared-terminal]：未发现 tmux 会话 $session_name" >&2
exit 1

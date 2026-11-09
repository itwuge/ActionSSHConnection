#!/usr/bin/env bash
# 文件: scripts/action/idle-watch.sh
# 所属目录: scripts/action/
# 文件用途: 会话空闲看门狗: 无人连接超过 idle-minutes 即停止会话, 让作业正常收尾.
# 架构定位: Action 步骤脚本的辅助脚本; 由 wait-session.sh 在等待前拉起, 随收尾一起结束.
# 职责边界: 只做「在连人数」判定与 stop; 不结束 tmux、不清理文件、不判断凭据.
# 运行环境: Linux runner; 依赖 jq 与 upterm 在 PATH.

set -uo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"
session_id="${ACTSSH_SESSION_ID:-}"
idle_minutes="${ACTSSH_IDLE_MINUTES:-10}"
upterm_log="${ACTSSH_UPTERM_LOG:-$HOME/.local/state/upterm/upterm.log}"

case "$idle_minutes" in
  ''|*[!0-9]*) idle_minutes=10 ;;
esac
[ "$idle_minutes" -ge 1 ] || idle_minutes=10
idle_seconds=$((idle_minutes * 60))

# 在连人数 = SSH 访客（upterm 日志里的 Client joined/left）+ 网页访客（准入进程写的存在标记）。
# SSH 访客共享托管 tmux 客户端的同一 PTY，无法从 tmux 客户端数看出，只能看 upterm 的进出事件。
ssh_guests() {
  [ -s "$upterm_log" ] || { echo 0; return; }
  local joined left
  joined="$(jq -R --arg sid "$session_id" \
    'fromjson? | select(.session == $sid and .msg == "Client joined") | 1' \
    "$upterm_log" 2>/dev/null | wc -l)"
  left="$(jq -R --arg sid "$session_id" \
    'fromjson? | select(.session == $sid and .msg == "Client left") | 1' \
    "$upterm_log" 2>/dev/null | wc -l)"
  local diff=$((joined - left))
  [ "$diff" -gt 0 ] || diff=0
  echo "$diff"
}

web_guests() {
  local dir="$workdir/web-presence"
  [ -d "$dir" ] || { echo 0; return; }
  find "$dir" -maxdepth 1 -type f -name '*.present' 2>/dev/null | wc -l
}

last_active="$(date +%s)"
echo "空闲超时：${idle_minutes} 分钟无人连接即结束会话（SSH 与网页共用同一判定）"
echo "::notice::空闲超时 ${idle_minutes} 分钟；会话存活期内可反复进入"

while [ -d "$workdir" ] && [ ! -f "$workdir/lifecycle.stop" ]; do
  ssh_count="$(ssh_guests)"
  web_count="$(web_guests)"
  total=$((ssh_count + web_count))
  now="$(date +%s)"
  if [ "$total" -gt 0 ]; then
    last_active="$now"
  else
    idle=$((now - last_active))
    if [ "$idle" -ge "$idle_seconds" ]; then
      echo "会话空闲超时：已 $((idle / 60)) 分钟无人在连（上限 ${idle_minutes} 分钟），结束会话"
      echo "::warning::空闲超时结束会话（${idle_minutes} 分钟无人连接）"
      upterm session stop "$session_name" >/dev/null 2>&1 || true
      exit 0
    fi
  fi
  sleep 10
done

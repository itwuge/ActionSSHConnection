#!/usr/bin/env bash
# 文件: scripts/action/wait-session.sh
# 所属目录: scripts/action/
# 文件用途: 等待会话结束并在退出时停止会话与清理临时目录.
# 架构定位: Action 步骤脚本; 上游是 start-session / bridge, 下游是 cleanup.sh.
# 职责边界: 只判定会话结局, 不读写连接串, 不触碰网页桥接实现.
# 运行环境: Linux runner; 依赖 upterm / jq.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"
session_minutes="${ACTSSH_SESSION_MINUTES:-45}"

# 退出钩子：先停会话（进程退出即会话消失），再清临时文件
cleanup_on_exit() {
  upterm session stop "$session_name" >/dev/null 2>&1 || true
  if [ -n "${workdir:-}" ]; then rm -rf -- "$workdir"; fi
}
trap cleanup_on_exit EXIT INT TERM

# 无人接入 10 分钟后会话自行结束；有访客接入则持续到会话退出。
# v0.41.1 退出码：0=被停止或无人接入超时；125=结局不可知；128+N=被信号结束；其余为会话内命令的退出码。
set +e
timeout --signal=TERM "${session_minutes}m" upterm session wait "$session_name" >/dev/null 2>&1
rc=$?
set -e

if [ "$rc" -eq 124 ]; then
  echo "失败[阶段 session-wait]：会话在 ${session_minutes} 分钟内未结束，已按超时终止" >&2
  exit 1
fi
if [ "$rc" -eq 125 ]; then
  echo "失败[阶段 session-wait]：无法确认会话结局（upterm session wait 返回 125）" >&2
  exit 1
fi

# 已结束的会话仍会从本地记录回答，因此按 status 判定，不能只看命令是否成功
status="$(upterm session info "$session_name" -o json 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)"
case "${status:-}" in
  ready|starting)
    echo "失败[阶段 session-wait]：等待返回 $rc，但会话状态仍为 $status" >&2
    exit 1
    ;;
esac
echo "会话已结束（upterm session wait 返回码 $rc，记录状态 ${status:-不可读}）"

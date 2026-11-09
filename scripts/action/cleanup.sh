#!/usr/bin/env bash
# 文件: scripts/action/cleanup.sh
# 所属目录: scripts/action/
# 文件用途: 无条件停止会话、清理网页桥接与准入进程、删除临时目录与虚拟环境.
# 架构定位: Action 步骤脚本; 上游是 wait-session 或任一失败分支, 由 action.yml 以 if: always() 调用.
# 职责边界: 只做清理, 不判断会话结局; 任何清理失败都不影响作业结论.
# 运行环境: Linux runner; 依赖 upterm / pkill / tmux（缺失时忽略）.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:-}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"

# session stop 在会话已结束时不算错误（源码：已结束会报出结局并以 0 退出），无此会话为 4
upterm session stop "$session_name" >/dev/null 2>&1 || true
pkill -f "upterm host" >/dev/null 2>&1 || true

# 网页桥接与准入子进程一并清理，不遗留反连
if [ -n "$workdir" ] && [ -f "$workdir/bridge.pid" ]; then
  kill "$(cat "$workdir/bridge.pid")" >/dev/null 2>&1 || true
fi
pkill -f "scripts/start_web_bridge.py" >/dev/null 2>&1 || true
pkill -f "scripts/web_admission.py" >/dev/null 2>&1 || true
rm -rf "${RUNNER_TEMP:-/tmp}/actssh-web-bridge-venv"
tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
if [ -n "$workdir" ]; then rm -rf -- "$workdir"; fi
echo "会话进程、网页桥接与临时文件已清理"

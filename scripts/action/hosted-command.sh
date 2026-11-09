#!/usr/bin/env bash
# 文件: scripts/action/hosted-command.sh
# 所属目录: scripts/action/
# 文件用途: upterm host 的托管命令: 常驻 tmux 客户端, 访客断开或退出 shell 都不结束会话.
# 架构定位: Action 步骤脚本的辅助脚本; 由 start-session.sh 通过 upterm 托管, 被 SSH 与网页访客共享.
# 职责边界: 只维护 tmux 会话与客户端存活; 不判断空闲、不停止会话、不涉及准入与凭据.
# 运行环境: Linux runner; 依赖 tmux.

set -uo pipefail

session="${1:-actssh}"

# 访客断开 SSH 时, tmux 客户端会收到挂断; 默认配置下 tmux 服务端仍保留会话,
# 但托管命令一旦退出, upterm 会判定会话结束. 因此这里用循环把客户端重新拉起来.
# destroy-unattached 关闭: 无人 attach 时也保留会话, 保证会话存活期内可反复进入.
tmux set-option -g destroy-unattached off 2>/dev/null || true

while :; do
  if ! tmux has-session -t "$session" 2>/dev/null; then
    # 窗口内再套一层 shell 循环: 访客在会话里 exit / Ctrl-D 只结束当前 shell,
    # 不会关掉窗口与 tmux 会话, 也就不会让 upterm 会话结束.
    tmux new-session -d -s "$session" -- bash -lc 'while :; do bash -l; done' 2>/dev/null || true
    tmux set-option -t "$session" destroy-unattached off 2>/dev/null || true
  fi
  # attach 会阻塞到客户端退出(断开、detach、tmux 服务端消失), 随后循环重新 attach
  tmux attach-session -t "$session" 2>/dev/null || true
  sleep 1
done

#!/usr/bin/env bash
# 文件: scripts/action/cleanup.sh
# 所属目录: scripts/action/
# 文件用途: 无条件停止会话、清理直连 sshd 与 Tailscale 节点、清理网页桥接与准入进程、删除临时目录.
# 架构定位: Action 步骤脚本; 上游是 wait-session 或任一失败分支, 由 action.yml 以 if: always() 调用.
# 职责边界: 只做清理与最终 path_verified 打印, 不判断会话结局; 任何清理失败都不影响作业结论.
# 运行环境: Linux runner; 依赖 upterm / pkill / tmux（缺失时忽略）.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:-}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"

# 直连路径收尾：先按最终状态把 path_verified 与固定提示语打进日志，再拆 sshd、Tailscale 与临时状态
# 只有直连面真正起来过（写过 path_verified）才打印，避免回落中继时误报“直连待验证”
if [ -n "$workdir" ] && [ -f "$workdir/direct.state" ] && [ -f "$workdir/path_verified" ]; then
  final_verified="$(cat "$workdir/path_verified" 2>/dev/null || true)"
  case "${final_verified:-unknown}" in
    direct)
      echo "path_verified=direct"
      echo "直连已建立"
      ;;
    derp)
      echo "path_verified=derp"
      echo "直连未建立，数据经 Tailscale DERP 中继转发"
      ;;
    *)
      echo "path_verified=unknown"
      echo "直连待验证，尚未确认是否经过 DERP"
      ;;
  esac
  # 后台校验进程的输出只在会话期间的步骤日志里；最终值写进收尾步骤摘要，作业结束后可查
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo ""
      echo "直连路径最终判定（条件字段，不属于 9 个 outputs）："
      echo '```text'
      echo "path_verified=${final_verified:-unknown}"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

if [ -n "$workdir" ] && [ -f "$workdir/direct-verify.follow.pid" ]; then
  kill "$(cat "$workdir/direct-verify.follow.pid")" >/dev/null 2>&1 || true
fi
pkill -f "scripts/action/direct-verify.sh" >/dev/null 2>&1 || true

# sshd 作为作业子进程启动：先按 pid 与配置路径杀，再随临时目录一起删 host key 与授权清单
if [ -n "$workdir" ] && [ -f "$workdir/sshd.pid" ]; then
  sudo -n kill "$(cat "$workdir/sshd.pid")" >/dev/null 2>&1 || true
fi
if [ -n "$workdir" ]; then
  pkill -f "sshd -f $workdir/sshd_config" >/dev/null 2>&1 || true
fi

# 防火墙只加了本项目的前缀表；整表删除，不影响宿主既有规则
sudo -n nft delete table inet actssh >/dev/null 2>&1 || true

# 节点下线并注销；auth key 用 ephemeral，节点随会话移除。手动拉起的守护进程一并结束
if [ -n "$workdir" ] && [ -f "$workdir/direct.state" ]; then
  ts_socket="$(sed -n 's/^ts_socket=//p' "$workdir/direct.state" 2>/dev/null | head -n1)"
  if [ -n "$ts_socket" ]; then
    sudo -n tailscale --socket="$ts_socket" down >/dev/null 2>&1 || true
    sudo -n tailscale --socket="$ts_socket" logout >/dev/null 2>&1 || true
  else
    sudo -n tailscale down >/dev/null 2>&1 || true
    sudo -n tailscale logout >/dev/null 2>&1 || true
  fi
  if grep -q '^manual_daemon=1$' "$workdir/direct.state" 2>/dev/null; then
    sudo -n pkill -f "tailscaled --state=$workdir/ts-state" >/dev/null 2>&1 || true
    sudo -n rm -rf "$workdir/ts-state" >/dev/null 2>&1 || true
  fi
fi
if [ -n "$workdir" ]; then rm -f -- "$workdir/ts-authkey"; fi

# session stop 在会话已结束时不算错误（源码：已结束会报出结局并以 0 退出），无此会话为 4
upterm session stop "$session_name" >/dev/null 2>&1 || true
pkill -f "upterm host" >/dev/null 2>&1 || true

# 网页桥接与准入子进程一并清理，不遗留反连
if [ -n "$workdir" ] && [ -f "$workdir/bridge.pid" ]; then
  kill "$(cat "$workdir/bridge.pid")" >/dev/null 2>&1 || true
fi
pkill -f "scripts/start_web_bridge.py" >/dev/null 2>&1 || true
pkill -f "scripts/web_admission.py" >/dev/null 2>&1 || true
pkill -f "scripts/action/idle-watch.sh" >/dev/null 2>&1 || true
rm -rf "${RUNNER_TEMP:-/tmp}/actssh-web-bridge-venv"
tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
if [ -n "$workdir" ]; then rm -rf -- "$workdir"; fi
echo "会话进程、直连 sshd/Tailscale 节点、网页桥接与临时文件已清理"

#!/usr/bin/env bash
# 文件: scripts/action/direct-verify.sh
# 所属目录: scripts/action/
# 文件用途: 首次连接后按 tailscale status --json 判定数据面是真直连还是 DERP, 并输出 path_verified 与固定提示语.
# 架构定位: Action 步骤脚本的常驻辅助进程; 由 direct-path.sh 后台拉起, 随作业收尾结束.
# 职责边界: 只读 Tailscale 状态并写 path_verified; 不改变连接、不停止会话、不接触任何密钥.
# 运行环境: Linux runner; 依赖 jq 与 tailscale（均在 PATH 或由 sudo 调用）.

set -uo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
ts_socket="${ACTSSH_TS_SOCKET:-}"
state_file="$workdir/path_verified"
last="unknown"

ts() {
  if [ -n "$ts_socket" ]; then
    sudo -n tailscale --socket="$ts_socket" "$@"
  else
    sudo -n tailscale "$@"
  fi
}

# 判定规则（设计第五节）：Active 为真表示该 peer 与当前节点有活动连接；
# 有 CurAddr 说明走了打洞直连，只有 Relay 说明数据经 Tailscale DERP 转发。
# 没有 Active peer（首次连接尚未发生）或状态不可读时为 unknown，不能笼统写成 direct。
classify() {
  jq -r '
    [ (.Peer // {}) | to_entries[] | .value | select((.Active // false) == true) ] as $p
    | if ($p | length) == 0 then "unknown"
      elif ([ $p[] | select(((.CurAddr // "") | length) > 0) ] | length) > 0 then "direct"
      elif ([ $p[] | select(((.Relay // "") | length) > 0) ] | length) > 0 then "derp"
      else "unknown" end
  ' 2>/dev/null || echo unknown
}

while [ -d "$workdir" ]; do
  raw="$(ts status --json 2>/dev/null || true)"
  if [ -n "$raw" ]; then
    value="$(printf '%s' "$raw" | classify)"
    case "$value" in direct|derp|unknown) ;; *) value=unknown ;; esac
    printf '%s\n' "$value" > "$state_file.tmp" 2>/dev/null && mv -f "$state_file.tmp" "$state_file" 2>/dev/null
    if [ "$value" != "$last" ]; then
      case "$value" in
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
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "path_verified=$value" >> "$GITHUB_STEP_SUMMARY"
      fi
      last="$value"
    fi
  fi
  sleep 5
done

#!/usr/bin/env bash
# 文件: scripts/action/direct-path.sh
# 所属目录: scripts/action/
# 文件用途: 按 direct-mode 在 runner 侧自行安装并拉起 Tailscale, 加入 tailnet, 在 tailnet 地址上启动 sshd.
# 架构定位: Action 步骤脚本; 上游是 precheck / start-session, 下游是 route.sh / direct-verify.sh / cleanup.sh.
# 职责边界: 只建立 SSH 直连面, 不建立中继会话、不承载网页; 任何失败都回落中继且不让作业失败.
# 运行环境: Linux runner; 全新机器口径, Tailscale 与 openssh-server 缺失时自行安装; 需要免密 sudo.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
mode="$(printf '%s' "${ACTSSH_DIRECT_MODE:-none}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
port="${ACTSSH_DIRECT_SSH_PORT:-2222}"
auth_key="$(printf '%s' "${ACTSSH_TAILSCALE_AUTH_KEY:-}" | tr -d '[:space:]')"
run_id="${ACTSSH_RUN_ID:-${GITHUB_RUN_ID:-local}}"
tag="${ACTSSH_TAILSCALE_TAG:-tag:actssh-runner}"
ts_socket=""
manual_daemon=0
keyfile=""

cleanup_key() {
  if [ -n "$keyfile" ]; then rm -f -- "$keyfile"; fi
}
trap cleanup_key EXIT

# 回落：path_mode=relay, 不输出 direct_endpoint/path_verified; session_id 由 start-session 决定, 这里不碰
relay_out() {
  {
    echo "path_mode=relay"
    echo "direct_endpoint="
    echo "login_user="
    echo "path_verified="
  } >> "$GITHUB_OUTPUT"
  echo "直连未建立，已切换到中继转发"
}

skip_relay() {
  echo "$1"
  relay_out
  exit 0
}

fail_relay() {
  echo "失败[阶段 $1]：$2；直连不可用，按设计回落中继" >&2
  echo "::warning::直连不可用（$1）：$2；已回落中继，session_id 不变"
  relay_out
  exit 0
}

# Tailscale CLI 统一走免密 sudo：守护进程套接字属 root；手动拉起的守护进程另带 --socket
ts() {
  if [ -n "$ts_socket" ]; then
    sudo -n tailscale --socket="$ts_socket" "$@"
  else
    sudo -n tailscale "$@"
  fi
}

ts_timeout() {
  local secs="$1"
  shift
  if [ -n "$ts_socket" ]; then
    timeout "$secs" sudo -n tailscale --socket="$ts_socket" "$@"
  else
    timeout "$secs" sudo -n tailscale "$@"
  fi
}

start_daemon() {
  if command -v systemctl >/dev/null 2>&1 && sudo -n systemctl start tailscaled >/dev/null 2>&1; then
    for _ in $(seq 1 15); do
      if ts status --json >/dev/null 2>&1; then return 0; fi
      sleep 1
    done
  fi
  # 无 systemd 或服务起不来时，自带守护进程；状态与套接字都放作业临时目录，随作业删除
  sudo -n mkdir -p "$workdir/ts-state"
  sudo -n nohup tailscaled --state="$workdir/ts-state/tailscaled.state" --socket="$workdir/ts-socket" \
    > "$workdir/tailscaled.log" 2>&1 &
  ts_socket="$workdir/ts-socket"
  manual_daemon=1
  for _ in $(seq 1 15); do
    if ts status --json >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

case "$mode" in
  none) skip_relay "直连未启用（direct-mode=none），按中继转发" ;;
  tailscale) ;;
  *) fail_relay direct-mode "direct-mode 取值非法（$mode）" ;;
esac

if [ -z "$auth_key" ]; then
  fail_relay authkey "未提供 tailscale-auth-key（调用方 Secret 未传入）"
fi

for cmd in curl jq timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail_relay direct-deps "运行器缺少 $cmd"
done
if ! sudo -n true >/dev/null 2>&1; then
  fail_relay direct-sudo "运行器没有免密 sudo，无法安装并启动 Tailscale 与 sshd"
fi

# 全新机器口径：不假设宿主已装 Tailscale，缺失时用官方安装脚本装
if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
  echo "安装 Tailscale（全新机器口径，不假设宿主已装）"
  if ! timeout 300 sudo -n sh -c 'curl -fsSL https://tailscale.com/install.sh | sh' \
      > "$workdir/tailscale-install.log" 2>&1; then
    fail_relay direct-install "Tailscale 安装失败，详见本步骤日志"
  fi
fi
if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
  fail_relay direct-install "安装后仍找不到 tailscale/tailscaled"
fi

if ! ts status --json >/dev/null 2>&1; then
  start_daemon || fail_relay tailscaled "tailscaled 未能在 15 秒内就绪"
fi
if [ "$manual_daemon" = "1" ]; then
  echo "Tailscale 守护进程由作业自行拉起（无可用 systemd），套接字与状态在作业临时目录"
fi

# auth key 只落临时文件, 由 tailscale up 以 file: 方式读取; 不打印、不进命令行、用完立即删除
umask 077
keyfile="$workdir/ts-authkey"
printf '%s' "$auth_key" > "$keyfile"
chmod 600 "$keyfile"
unset auth_key

hostname="actssh-$(printf '%s' "$run_id" | tr -cd 'a-z0-9-')"
[ -n "$hostname" ] || hostname="actssh-${RANDOM}"

echo "加入 tailnet：节点名 ${hostname}，tag ${tag}，ephemeral"
if ! ts_timeout 30 up \
    --auth-key="file:$keyfile" \
    --hostname="$hostname" \
    --advertise-tags="$tag" \
    --ephemeral \
    --ssh=false \
    --accept-routes=false \
    --accept-dns=false \
    > "$workdir/tailscale-up.log" 2>&1; then
  tail -n 5 "$workdir/tailscale-up.log" >&2 2>/dev/null || true
  fail_relay tailscale-up "30 秒内未完成加入 tailnet"
fi
rm -f -- "$keyfile"
keyfile=""

ip=""
for _ in $(seq 1 10); do
  ip="$(ts ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [ -n "$ip" ] && break
  sleep 1
done
if ! printf '%s' "$ip" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\.[0-9]+\.[0-9]+$'; then
  fail_relay tailnet-address "未取得 tailnet IPv4（100.64.0.0/10）"
fi

sshd_bin=""
for candidate in /usr/sbin/sshd /usr/local/sbin/sshd; do
  if [ -x "$candidate" ]; then sshd_bin="$candidate"; break; fi
done
if [ -z "$sshd_bin" ]; then
  echo "安装 openssh-server（全新机器口径）"
  if ! command -v apt-get >/dev/null 2>&1; then
    fail_relay direct-sshd "运行器没有 sshd，且不是 apt 系发行版"
  fi
  sudo -n apt-get update -qq > "$workdir/sshd-install.log" 2>&1 || true
  if ! sudo -n apt-get install -y -qq openssh-server >> "$workdir/sshd-install.log" 2>&1; then
    fail_relay direct-sshd "安装 openssh-server 失败，详见本步骤日志"
  fi
  for candidate in /usr/sbin/sshd /usr/local/sbin/sshd; do
    if [ -x "$candidate" ]; then sshd_bin="$candidate"; break; fi
  done
fi
[ -n "$sshd_bin" ] || fail_relay direct-sshd "安装后仍找不到 sshd"

# 专用非 root 用户：默认 runner；与作业用户不一致时无法安全共享授权清单，按设计回落中继
login_user="${ACTSSH_DIRECT_LOGIN_USER:-runner}"
if ! id "$login_user" >/dev/null 2>&1; then
  login_user="$(id -un)"
fi
if [ "$login_user" = "root" ]; then
  fail_relay direct-user "没有可用的非 root 登录用户（设计禁止 root 登录）"
fi
if [ "$login_user" != "$(id -un)" ]; then
  fail_relay direct-user "登录用户 ${login_user} 与作业用户 $(id -un) 不一致，授权清单无法安全共享"
fi
[ -s "$workdir/authorized_keys" ] || fail_relay direct-keys "缺少从 GitHub 公钥接口拉取的授权清单"
chmod 600 "$workdir/authorized_keys"

rm -f -- "$workdir/sshd_hostkey" "$workdir/sshd_hostkey.pub" "$workdir/sshd.pid"
ssh-keygen -q -t ed25519 -N '' -f "$workdir/sshd_hostkey" >/dev/null 2>&1 ||
  fail_relay direct-hostkey "临时 host key 生成失败"
chmod 600 "$workdir/sshd_hostkey"

sudo -n mkdir -p /run/sshd >/dev/null 2>&1 || true
sudo -n chmod 0755 /run/sshd >/dev/null 2>&1 || true

cat > "$workdir/sshd_config" <<EOF
# 由 scripts/action/direct-path.sh 生成；随作业销毁，不落仓库
Port $port
ListenAddress $ip
HostKey $workdir/sshd_hostkey
PidFile $workdir/sshd.pid
AuthorizedKeysFile $workdir/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers $login_user
MaxAuthTries 3
MaxSessions 1
LoginGraceTime 30
ClientAliveInterval 30
ClientAliveCountMax 3
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
UsePAM no
PrintMotd no
PrintLastLog no
LogLevel VERBOSE
EOF
chmod 600 "$workdir/sshd_config"

if ! sudo -n "$sshd_bin" -t -f "$workdir/sshd_config" > "$workdir/sshd-check.log" 2>&1; then
  cat "$workdir/sshd-check.log" >&2 || true
  fail_relay direct-sshd "sshd 配置校验失败"
fi
if ! sudo -n "$sshd_bin" -f "$workdir/sshd_config" -E "$workdir/sshd.log"; then
  fail_relay direct-sshd "sshd 未能启动"
fi

listening=0
for _ in $(seq 1 10); do
  if ss -lnt 2>/dev/null | grep -qF "$ip:$port"; then listening=1; break; fi
  sleep 1
done
if [ "$listening" != "1" ]; then
  sudo -n pkill -f "sshd -f $workdir/sshd_config" >/dev/null 2>&1 || true
  fail_relay direct-sshd "sshd 未在 ${ip}:${port} 监听"
fi

# 防火墙：只允许 tailscale0 访问该端口；sshd 本身只绑 tailnet 地址，公网网卡不监听
if command -v nft >/dev/null 2>&1 && sudo -n nft add table inet actssh 2>/dev/null; then
  sudo -n nft 'add chain inet actssh input { type filter hook input priority 0; policy accept; }' >/dev/null 2>&1 || true
  if sudo -n nft add rule inet actssh input tcp dport "$port" iifname != "tailscale0" drop >/dev/null 2>&1; then
    echo "防火墙：仅允许 tailscale0 到 ${port}，其余接口同端口一律丢弃"
  else
    echo "::warning::nftables 规则未生效；sshd 仍只绑定 tailnet 地址"
  fi
else
  echo "防火墙：未启用 nftables；sshd 仅绑定 tailnet 地址，公网网卡不监听该端口"
fi

cat > "$workdir/direct.state" <<EOF
mode=tailscale
ip=$ip
port=$port
login_user=$login_user
sshd_config=$workdir/sshd_config
ts_socket=$ts_socket
manual_daemon=$manual_daemon
EOF

# 首连前为 unknown；direct-verify.sh 在首次连接后改写为 direct/derp
printf '%s\n' "unknown" > "$workdir/path_verified"

{
  echo "path_mode=direct"
  echo "direct_endpoint=$ip:$port"
  echo "login_user=$login_user"
  echo "path_verified=unknown"
} >> "$GITHUB_OUTPUT"

echo "path_mode=direct"
echo "direct_endpoint=$ip:$port"
echo "direct_login_user=$login_user"
echo "path_verified=unknown"
echo "直连待验证，尚未确认是否经过 DERP"
echo "::notice::直连入口 ${ip}:${port}（${login_user}）已就绪；数据面是否为真 P2P 由 path_verified 判定"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "直连路径（Tailscale 条件字段，不属于 9 个 outputs）："
    echo '```text'
    echo "path_mode=direct"
    echo "direct_endpoint=$ip:$port"
    echo "direct_login_user=$login_user"
    echo "path_verified=unknown"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

ACTSSH_WORKDIR="$workdir" \
ACTSSH_DIRECT_SSH_PORT="$port" \
ACTSSH_TS_SOCKET="$ts_socket" \
  nohup bash "$(dirname "$0")/direct-verify.sh" > "$workdir/direct-verify.log" 2>&1 &
echo $! > "$workdir/direct-verify.pid"
echo "直连校验进程已启动：首次连接后按 tailscale status --json 判定 direct/derp"

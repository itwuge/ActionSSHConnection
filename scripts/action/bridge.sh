#!/usr/bin/env bash
# 文件: scripts/action/bridge.sh
# 所属目录: scripts/action/
# 文件用途: 启动 runner 侧网页桥接并确认就绪; 任何失败只告警, 不中断作业.
# 架构定位: Action 步骤脚本; 上游是 start-session, 下游是 scripts/start_web_bridge.py 与 web_admission.py.
# 职责边界: 不改桥接与准入实现, 只按三档阶段名（bridge-connect / bridge-register / bridge-admission）上报.
# 运行环境: Linux runner; 依赖 python3 venv 与两份 requirements.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
# ACTSSH_SCRIPTS_DIR 是 Action 根目录（本地调用为仓库根，远程调用为 _actions/.../<ref>），
# 桥接与准入脚本、依赖清单都在它下面的 scripts/ 里
action_root="${ACTSSH_SCRIPTS_DIR:?缺少 ACTSSH_SCRIPTS_DIR}"
scripts_dir="$action_root/scripts"
session_id="${ACTSSH_SESSION_ID:-}"
session_name="${ACTSSH_SESSION_NAME:-actssh}"
allowed_json="${ACTSSH_ALLOWED_JSON:-}"
credential_id="${ACTSSH_CREDENTIAL_ID:-}"

# 网页通道与 SSH 反连并行：桥接起不来时只记录失败并标注，不中断本步骤，SSH 通道保持可用。
# 失败阶段名固定三档：bridge-connect / bridge-register / bridge-admission。
unavailable() {
  echo "失败[阶段 $1]：$2；网页通道不可用，SSH 通道不受影响" >&2
  echo "::warning::网页通道不可用（$1）：$2；SSH 通道不受影响"
  exit 0
}

[ -n "${session_id:-}" ] || unavailable bridge-connect "未取得会话标识"

# 基地址缺省 wss://wuge.fun；只接受站点根或已带 /runner 的终点，路径规则与中继 /runner/<id> 一致
base="${ACTSSH_BRIDGE_BASE:-wss://wuge.fun}"
base="${base%/}"
case "$base" in
  ws://*/*|wss://*/*)
    case "$base" in
      */runner) bridge_base="$base" ;;
      *) unavailable bridge-connect "bridge-base-url 只允许 /runner 路径" ;;
    esac
    ;;
  ws://?*|wss://?*) bridge_base="${base}/runner" ;;
  *) unavailable bridge-connect "bridge-base-url 只接受 ws:// 或 wss:// 地址" ;;
esac

# 准入允许清单：只放公开的凭据标识与公钥，作业内生成、随作业销毁。
# 空数组 [] 仅在开放注册（pubkey_credential_id 为空）时合法，按单次自举注册运行。
[ -n "${allowed_json:-}" ] || unavailable bridge-admission "未配置 allowed-credentials，准入无允许清单可用"
printf '%s' "$allowed_json" > "$workdir/webauthn-allowed.json"
allow_empty=0
if [ -z "${credential_id:-}" ]; then
  allow_empty=1
fi
if ! python3 - "$workdir/webauthn-allowed.json" "$allow_empty" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(raw, list):
    raise SystemExit("允许清单顶层必须是数组")
if not raw and sys.argv[2] != "1":
    raise SystemExit("允许清单为空且未开放注册")
for item in raw:
    if not isinstance(item, dict) or not item.get("credential_id") or not item.get("public_key"):
        raise SystemExit("允许清单条目缺少 credential_id 或 public_key")
if raw:
    print(f"允许清单条目数 {len(raw)}")
else:
    print("允许清单为空数组，按自举注册运行（本会话只接受首个注册）")
PY
then
  unavailable bridge-admission "allowed-credentials 不是合法 JSON 数组，或空数组未配合开放注册"
fi

# 依赖装在 RUNNER_TEMP 虚拟环境里，避免宿主 Python 的 externally-managed 限制，也不占用制品目录
venv="${RUNNER_TEMP:-/tmp}/actssh-web-bridge-venv"
rm -rf "$venv"
if ! python3 -m venv "$venv" >/dev/null 2>&1; then
  unavailable bridge-connect "无法创建 Python 虚拟环境"
fi
if ! "$venv/bin/pip" install --quiet --disable-pip-version-check \
    -r "$scripts_dir/requirements-web-bridge.txt" \
    -r "$scripts_dir/requirements-web-admission.txt"; then
  unavailable bridge-connect "网页桥接或准入依赖安装失败（websockets/fido2）"
fi

# 准入命令走同一虚拟环境；凭据标识为空时开放注册引导，由浏览器首次注册生成。
# --state-dir 让准入进程把「网页在连标记」「跨连接失败计数」「自举后的公钥回写」放进作业临时目录，
# 使同一会话内浏览器断开重开仍可用同一设备直接进入，并让空闲看门狗把网页访客计入在连人数。
admission="$venv/bin/python $scripts_dir/web_admission.py --session-id $session_id --tmux-session $session_name --allowed-credentials $workdir/webauthn-allowed.json --state-dir $workdir"
if [ -z "${credential_id:-}" ]; then
  admission="$admission --allow-registration"
fi

# 后台反连，不阻塞随后的会话等待；标准输出与 JSONL 日志只落文件
nohup "$venv/bin/python" "$scripts_dir/start_web_bridge.py" \
  "$session_id" "$bridge_base" "$admission" \
  --run-id "${GITHUB_RUN_ID:-}" \
  > "$workdir/bridge.out" 2> "$workdir/bridge.err" &
bridge_pid=$!
echo "$bridge_pid" > "$workdir/bridge.pid"

bridge_host="${bridge_base#*://}"
bridge_host="${bridge_host%%/*}"
for _ in $(seq 1 20); do
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    set +e
    wait "$bridge_pid"
    rc=$?
    set -e
    stage="$(jq -r '.data.stage // empty' "$workdir/bridge.out" 2>/dev/null || true)"
    error_code="$(jq -r '.error_code // empty' "$workdir/bridge.out" 2>/dev/null || true)"
    message="$(jq -r '.message // empty' "$workdir/bridge.out" 2>/dev/null || true)"
    if [ "$rc" -eq 0 ]; then
      echo "网页通道已结束（桥接进程正常退出，阶段 ${stage:-unknown}）"
      exit 0
    fi
    case "${stage:-}" in
      register-rejected) stage_name=bridge-register ;;
      admission-start|admission-exit) stage_name=bridge-admission ;;
      *) stage_name=bridge-connect ;;
    esac
    unavailable "$stage_name" "桥接进程退出码 ${rc}，阶段 ${stage:-unknown}，error_code ${error_code:-none}，${message:-无输出}"
  fi
  if grep -q '"event":"bridge.connected"' "$workdir/bridge.err" 2>/dev/null &&
     grep -q '"event":"admission.started"' "$workdir/bridge.err" 2>/dev/null; then
    echo "网页通道已就绪：runner 已反连 ${bridge_host}/runner/${session_id}，等待浏览器注册与准入"
    exit 0
  fi
  sleep 1
done
echo "::warning::网页通道状态待确认：20 秒内未观测到 connected/admission.started 事件"
echo "网页通道已启动但未确认：桥接进程 ${bridge_pid} 仍在运行"

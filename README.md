# ActionSSHConnection

在 GitHub Actions 作业里开一个临时调试会话：SSH 登入 runner，或浏览器打开网页终端，两边进的是同一个 tmux。runner 主动反连自建中继，不需要入站端口；中继无状态，只按 `session_id` 转发字节流。

- 调用方式：Composite Action（一步）或可复用工作流（一个 job）
- 默认中继：`ssh.wuge.fun:2222`（uptermd），网页站点 `https://wuge.fun`
- 默认不建立会话：必须显式写 `ssh: true`

---

## 1. 原理

```text
                        ┌──────────────── 中继 47.109.32.249（无状态） ────────────────┐
  ssh 访客 ──:2222─────▶│ uptermd ──按 session_id 转发──▶ runner 的 upterm host 反连    │
                        │                                                              │
  浏览器 ──:443──▶ nginx│ /t/<id>  → 静态页面（/var/www/actssh/html）                  │
                        │ /ws/<id> → 桥接 127.0.0.1:8081 ⇄ runner 的 /runner/<id>       │
                        │ /runner/ → 桥接 127.0.0.1:8081                               │
                        └──────────────────────────────────────────────────────────────┘
                                        ▲                          ▲
                                        │ 反连（出站 wss）          │ 反连（出站 ssh）
                              start_web_bridge.py            upterm host
                                        │                          │
                                        ▼                          ▼
                        web_admission.py（WebAuthn 验签）      runner 内 tmux 会话 actssh
                                        └────── 同一个 tmux ───────┘
  可选直连：调用方设备 ──tailnet──▶ runner 内 sshd（只绑 100.x:2222）
```

**为什么 SSH 与网页是同一个 tmux。** `start-session.sh` 在 runner 上建一个名为 `actssh` 的 tmux 会话并让托管命令常驻；`upterm host` 进入这个会话，`web_admission.py` 验签通过后也 `tmux attach` 到同一个会话。两个入口只是同一终端的两条接入路径，谁先进入看到的是同一份屏幕历史。

**准入在哪一侧判定。**

| 通道 | 谁判定 | 依据 |
|---|---|---|
| SSH | 中继 + runner | 中继按 `session_id` 路由；runner 侧授权清单只放行 `ssh-user` 这个 GitHub 账号登记的公钥 |
| 直连 SSH | runner | runner 内 sshd 只认同一份授权清单，`MaxAuthTries 3`、`LoginTimeout 30` |
| 网页 | runner | `web_admission.py` 校验 WebAuthn 断言签名与允许清单；中继桥接不做任何身份判断 |

中继因此始终是「无状态字节转发器」：不解析协议、不识别终端内容、不落盘会话状态。

**为什么日志只有 9 个字段。** 凭据模型是「源头不产生凭据」，不是事后打码：runner 不生成、不打印、不落盘私钥或一次性 token，日志只输出公开路由信息——`session_id`、`ssh_user`、`relay_host`、`relay_port`、`web_url`、`pubkey_fingerprint`、`expires_at`、`pubkey_credential_id`、`path_mode`。直连时另有条件字段 `direct_endpoint`、`path_verified`，仅出现在日志与摘要，不新增 output。GitHub 的掩码只用于 Secret（如 `tailscale-auth-key`），路由信息不做掩码，否则整行会变成不可读占位符。

**直连与中继的顺序。** 中继面先建立，保证任何情况下都有可用入口；`direct-mode: tailscale` 才建立直连面，任一步失败立即回落中继，`session_id` 不重建、入口地址不变。`path_mode` 记录实际路径（`relay` / `direct`），`path_verified` 区分点对点（`direct`）与经 Tailscale DERP 转发（`derp`）。

---

## 2. 用法

### 2.1 最小接入

在调用方仓库加一个 workflow 和两个仓库变量即可（变量清单见 3.2）：

```yaml
name: 调试会话
on: { workflow_dispatch: { inputs: { start_session: { type: boolean, default: false } } } }
permissions: { contents: read }
jobs:
  debug:
    runs-on: ubuntu-latest
    timeout-minutes: 50
    if: inputs.start_session
    steps:
      - uses: itwuge/ActionSSHConnection@v1
        with:
          ssh: true
```

`ssh: true` 必须显式写；默认 `false` 只做前置校验，不会开出可登入的 shell。

### 2.2 触发方式

| 入口 | 触发 | 条件 |
|---|---|---|
| `workflow_dispatch` | Actions 页面或 API `POST /actions/workflows/<file>/dispatches` | 布尔输入 `start_session=true` |
| `repository_dispatch` | API `POST /repos/<owner>/<repo>/dispatches`，`event_type: start-session`，`client_payload.keyword: start-session` | 发起者必须等于 `ssh-user` |

### 2.3 日志里看哪几行

运行开始后，「输出路由字段」步骤打印九行 `key=value`，随后摘要里重复一次：

```text
session_id=tKJvWvuZSDdZMCl6dJ8l
ssh_user=tKJvWvuZSDdZMCl6dJ8l:MC4wLjAuMDoyMjIy
relay_host=ssh.wuge.fun
relay_port=2222
web_url=https://wuge.fun/t/tKJvWvuZSDdZMCl6dJ8l
pubkey_fingerprint=SHA256:...
expires_at=2026-11-09T18:49:00Z
pubkey_credential_id=unset
path_mode=relay
```

会话进行中要机器读取这些字段，传 `route-artifact-name: route-fields`，从制品取同名文件（9 行）。

### 2.4 怎么连

SSH（中继）：

```bash
ssh -p 2222 '<session_id>:<节点编码>'@ssh.wuge.fun
# 登入名直接用日志里的 ssh_user 整行；不要自己拼
```

网页：浏览器打开 `web_url`（`https://wuge.fun/t/<session_id>`），首次进入按提示注册本机通行密钥，之后同一设备打开即直接进入。

直连（`direct-mode: tailscale` 且成功时）：日志给出 `direct_endpoint=<100.x>:2222`，登入名是 `ssh_user`（无冒号，通常 `runner`）：

```bash
ssh -o StrictHostKeyChecking=accept-new -p 2222 runner@100.x.y.z
```

### 2.5 生命周期

| 结束方式 | 默认 | 说明 |
|---|---|---|
| 显式结束 | — | 会话内执行 `upterm session stop actssh` |
| 空闲超时 | `idle-minutes: 10` | SSH 与网页合计无人连接超过该时长 |
| 会话上限 | `session-minutes: 45` | 同时决定 `expires_at` |
| 作业超时 | 调用方 `timeout-minutes` | 必须大于 `session-minutes` |

存活期内可反复进入：断开、`exit`、关标签页后用同一链接重连即可，不需要重新触发；网页设备已注册时直接进，不再要求注册。会话结束后，旧链接显示「会话不存在或已结束」，SSH 重连被拒。

---

## 3. 部署

### 3.1 中继一键安装（`relay/` 独立组件）

`relay/` 自带 `README.md`、`VERSION`、安装/卸载/打包脚本，不读取 `.github/` 与 `scripts/action/`。

```bash
# 纯 SSH 反向隧道中继：不装 nginx / 证书 / 网页桥接
sudo ./relay/install.sh --relay-only --no-direct --apply

# 完整形态：宿主 nginx + 证书 + 网页桥接（本项目生产即此形态）
sudo ./relay/install.sh --domain wuge.fun --email <ACME 邮箱> --cert-mode acme \
  --www-alias --ssh-domain ssh.wuge.fun --web-root /var/www/actssh/html \
  --nginx-mode host --admin-ssh-port 22 --relay-port 2222 --bridge-port 8081 --apply
```

| 形态 | 说明 |
|---|---|
| `--relay-only`（`--no-web-bridge` 等价） | 只有 uptermd，无域名依赖，无网页入口 |
| 完整形态 | 加 nginx、证书与网页桥接；`--nginx-mode dedicated` 装独立 `actssh-nginx`，`host` 接管宿主 `/etc/nginx/conf.d` |

证书三档（`--cert-mode`）：`acme`（webroot，默认，需 80 端口可达）、`standalone`（临时占用 80，host 模式不允许）、`self-signed`（仅无公网 DNS 的实验环境）。

端口与路径要求：`--relay-port` 默认 `2222`（系统 sshd 保持 22 不动，见 `relay/README.md` 6.1.1）；桥接固定 `127.0.0.1:8081`；uptermd WS `127.0.0.1:8443`；指标 `127.0.0.1:9100`。上游全部环回，公网只暴露 `443` 与 `2222`。

卸载：

```bash
sudo ./relay/uninstall.sh                 # 保留数据（默认）
sudo ./relay/uninstall.sh --purge-data    # 连证书与数据一起清
sudo ./relay/uninstall.sh --remove-firewall
```

升级用 `--upgrade --apply`；有活动会话时升级会在无状态判据处失败并自动回滚，属预期保护。

### 3.2 调用方仓库变量与 Secret

仓库变量（Settings → Secrets and variables → Actions → Variables，均为非秘密路由信息）：

| 名称 | 必填 | 填什么 | 在哪拿 |
|---|---|---|---|
| `UPTERM_RELAY_KNOWN_HOST` | 是 | 中继主机公钥行，端口非 22 时方括号形式 | `ssh-keyscan -p 2222 ssh.wuge.fun` |
| `WEB_TERMINAL_BASE_URL` | 是 | 网页站点根，如 `https://wuge.fun` | 中继部署的 `--domain` |
| `WEB_BRIDGE_BASE_URL` | 网页通道必填 | runner 反连基地址，如 `wss://wuge.fun`，自动补 `/runner` | 同站点域名 |
| `WEBAUTHN_ALLOWED_CREDENTIALS` | 网页通道必填 | 单行 JSON 数组；`[]` 表示开放一次自举注册 | 注册后由日志 `pubkey_credential_id` 与凭据公钥组成 |
| `WEBAUTHN_CREDENTIAL_ID` | 否 | 已注册凭据标识；留空输出 `unset` 并走自举注册 | 首次注册后的日志/摘要 |
| `UPTERM_DIRECT_MODE` | 否 | `none`（默认）/ `tailscale` | 自选 |

Secret（只给直连模式用）：

| 名称 | 必填 | 填什么 | 在哪拿 |
|---|---|---|---|
| `TS_AUTHKEY` | 直连时必填 | Tailscale 临时 auth key，建议 ephemeral + `tag:actssh-runner` | `tailscale authkey --ephemeral --preauth --tags tag:actssh-runner` |

`TS_AUTHKEY` **必须走 Secret**：GitHub 会把步骤日志 `env` 块里的 Secret 掩码为 `***`，直接写字面量会被原样回显。缺失或过期时按设计回落中继，作业不失败。

只用 SSH 通道时，第 3、4、5 行可以留空，但 `WEB_TERMINAL_BASE_URL` 当前仍是校验必填项。

---

## 4. YAML 详细示例

三份都在 [`examples/`](examples/) 下，可直接另存为 `.github/workflows/*.yml`。

### 4.1 最小调用

```yaml
name: 调试会话（最小调用）
on:
  workflow_dispatch:
    inputs:
      start_session:
        type: boolean
        default: false
permissions:
  contents: read
jobs:
  debug:
    runs-on: ubuntu-latest
    timeout-minutes: 50
    if: inputs.start_session
    steps:
      - uses: itwuge/ActionSSHConnection@v1
        with:
          ssh: true
```

复制后可跑，需改：`ssh-user`（改成你的 GitHub 用户名，默认 `itwuge`）。换自建中继时三件套一起改：`relay-host`、`relay-port`、`known-hosts`。

### 4.2 带 outputs 与制品

```yaml
name: 调试会话（读取 outputs）
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  debug:
    runs-on: ubuntu-latest
    timeout-minutes: 50
    steps:
      - name: 建立调试会话
        id: ssh
        uses: itwuge/ActionSSHConnection@v1
        with:
          ssh: true
          session-minutes: "30"
          # 会话进行中就要读字段时必须用制品；outputs 在会话结束后才有值
          route-artifact-name: route-fields
          route-artifact-retention-days: "1"

      - name: 打印路由字段
        if: always()
        run: |
          set -euo pipefail
          echo "session_id=${{ steps.ssh.outputs.session-id }}"
          echo "ssh_user=${{ steps.ssh.outputs.ssh-user }}"
          echo "relay=${{ steps.ssh.outputs.relay-host }}:${{ steps.ssh.outputs.relay-port }}"
          echo "web_url=${{ steps.ssh.outputs.web-url }}"
          echo "expires_at=${{ steps.ssh.outputs.expires-at }}"
          echo "path_mode=${{ steps.ssh.outputs.path-mode }}"
```

复制后可跑，需改：`ssh-user`、`route-artifact-name`（不需要制品就删掉这两行）。9 个 output 名称见 5.2。

### 4.3 可复用工作流调用

```yaml
name: 调试会话（可复用工作流）
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  debug:
    permissions:
      contents: read
    uses: itwuge/ActionSSHConnection/.github/workflows/reusable-session.yml@v1
    with:
      ssh: true
      ssh-user: itwuge
      session-minutes: "30"
      allowed-credentials: "[]"
      action-upterm-ref: v1

  report:
    needs: debug
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "web-url: ${{ needs.debug.outputs.web-url }}"
          echo "ssh-user: ${{ needs.debug.outputs.ssh-user }}"
          echo "path-mode: ${{ needs.debug.outputs.path-mode }}"
```

复制后可跑，需改：`ssh-user`；若锁定 SHA，`uses:` 与 `action-upterm-ref` 都换成同一个 SHA（默认值已是本项目生产中继，无需再写 `relay-host` 等）。

---

## 5. 验证状态

三档含义：**已验证** = 在生产域名与真实中继上端到端取证；**仅 VM 验证** = 干净虚拟机上跑通安装/自检/卸载，未在公网域名下复现；**未验证** = 没有可信证据，不当作能力。

### 5.1 功能点

| 功能点 | 状态 | 证据或缺口 |
|---|---|---|
| 外部项目只加一个 workflow + 变量即可拿到 SSH 会话 | 已验证 | 调用方仓库以 `ssh: true` 建立会话并登入成功 |
| `ssh.wuge.fun:2222` 连通与 `known_hosts` 校验 | 已验证 | 现网 banner `SSH-2.0-uptermd-0.41.1`；`ssh-keyscan` 公钥与默认值逐字节一致 |
| 中继路由模式 | 已验证 | embedded，登录名形如 `<session_id>:<base64(0.0.0.0:2222)>` |
| 网页静态入口 `https://wuge.fun/t/<session_id>` | 已验证 | 返回页面并回退 `index.html`；`/dist/app.js`、`app.css` 与本地构建产物 SHA-256 相同 |
| `/ws/` 与 `/runner/` Upgrade | 已验证 | 生产 nginx 返回 101；runner 反连可持续保持（会话存续期内） |
| 网页通行密钥注册 → 进入 tmux → 执行命令 | 虚拟认证器验证，真实设备未验 | Chrome CDP 虚拟认证器（ctap2 internal）完成注册与断言，终端执行 `echo` 有回显；**真实认证器未验** |
| 刷新后免注册直接再进 | 虚拟认证器验证，真实设备未验 | 同一虚拟凭据重载后直接进入，终端继续执行 `echo` 有回显；旧屏幕内容只部分重绘（可见 tmux 状态行），未做完整回放 |
| 会话结束后旧链接可读提示 | 已验证 | 打开旧链接先显示入口页，点击入口按钮后提示「会话不存在或已结束. 请向发起者索取新的连接串.」 |
| 中继一键安装（纯中继形态） | 仅 VM 验证 | Ubuntu 22.04 干净机：安装 10.3s、自检 6/6、登入成功、卸载后无残留 |
| 中继一键安装（完整形态，self-signed） | 仅 VM 验证 | 91.8s、自检 17/17；公网域名 + 真实 ACME 未在干净机复跑 |
| 生产宿主接管（host nginx） | 已验证 | 6 个 conf 规范化后等价、证书序列号不变、nginx master PID 不变、`/t/` 200、`/ws/` `/runner/` 101 |
| 升级与回滚 | 仅 VM 验证 | 活动会话下升级触发回滚；回滚后按单元重启已修复并复验 |
| Tailscale 直连成功路径 | 未验证 | 无 tailnet 凭据；`path_verified=direct` 未取证 |
| 直连失败回落中继 | 已验证 | 不传 key、传无效 key 两种真机运行均 `path_mode=relay` 且会话可用 |
| `repository_dispatch` 的发起者校验语义 | 未验证 | 语义待真机确认 |

### 5.2 outputs

| 输出 | 说明 |
|---|---|
| `session-id` | 会话标识；`ssh: false` 时为 `none` |
| `ssh-user` | 直连为专用非 root 用户名（无冒号）；中继为 `<session_id>:<节点编码>` |
| `relay-host` / `relay-port` | 中继地址 |
| `web-url` | `https://<站点>/t/<session_id>` |
| `pubkey-fingerprint` | 允许登入的公钥指纹，逗号分隔 |
| `expires-at` | 预计到期时间（UTC） |
| `pubkey-credential-id` | WebAuthn 凭据标识或 `unset` |
| `path-mode` | `relay` / `direct` / `disabled` |

---

## 6. 已知限制

- **直连不是纯 P2P**：`path_mode=direct` 只说明 tailnet 路径可用；对称 NAT 下退到 DERP，只有 `path_verified=direct` 才是点对点。
- **网页通道依赖中继侧桥接**：`/ws/`、`/runner/` 或 `actssh-web-bridge.service` 不可用时 SSH 仍可用，日志按 `bridge-connect` / `bridge-register` / `bridge-admission` 报阶段。
- **刷新后屏幕历史不完整**：重连会重新 `tmux attach`，只重绘部分内容；新输出正常，历史滚动区不做回放。
- **旧链接的失效提示要一次点击**：入口页先展示「注册/直接进入」，点击后才由 WebSocket 关闭原因给出「会话不存在或已结束」。
- **自举注册的残余风险**：`allowed-credentials: "[]"` 时第一个完成注册的人拿到终端；生产应预置凭据条目。
- **仅 Linux runner**：依赖 bash、tmux、jq、python3；Windows / macOS 未支持。
- **upterm 客户端只内置 `v0.41.1` 校验和**，其他版本被拒绝。
- **Composite 的 outputs 在会话结束后才有值**：会话进行中读字段用 `route-artifact-name`。
- **可复用工作流 job 上限固定 55 分钟**：`session-minutes` 请勿超过 45；更长会话用 Composite 自设超时。
- **SSH 失败尝试计数不在 runner 侧**：防爆破需在 uptermd 或前置网关按来源做。
- 中继与网页站点需自行部署；本仓库不提供托管服务。

---

## 7. 目录与版本

```text
action.yml                    # Composite Action 入口（唯一实现起点）
.github/workflows/
  session.yml                 # 本仓库入口：检出后调用本地 Action
  reusable-session.yml        # 可复用工作流（workflow_call）
scripts/action/               # precheck/install/start/direct/route/bridge/wait/cleanup
scripts/start_web_bridge.py   # runner 反连 /runner/<id>（按帧切分后转发）
scripts/web_admission.py      # WebAuthn 准入与 tmux 桥接
web/                          # 浏览器终端前端
relay/                        # 中继独立部署组件（自带 README 与版本号）
docs/                         # 使用说明 / 接入指南
examples/                     # 四份调用样式
```

版本：`v0.1.0` 首个可用版本；`v0.3.0` 增加 Tailscale 直连路径；`v1` 为移动标签。锁定到 tag 或 SHA，不要用浮动分支。组件细节见 [relay/README.md](relay/README.md)，接入排查见 [docs/接入指南.md](docs/接入指南.md)。

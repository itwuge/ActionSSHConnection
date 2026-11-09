# ActionSSHConnection

在 GitHub Actions 作业里开一个临时调试会话：用 SSH 登入 runner，或用浏览器打开网页终端；runner 主动反连自建中继，不需要入站端口。用途与 tmate 类似，但中继可自建、日志只输出固定的公开路由字段。

## 30 秒接入

```yaml
- uses: itwuge/ActionSSHConnection@v1
  with:
    ssh: true
```

至少需要：

| 配置 | 说明 |
| --- | --- |
| 仓库变量 `UPTERM_RELAY_KNOWN_HOST` | 中继主机公钥行，格式 `[host]:port ssh-ed25519 AAAA...` |
| `ssh-user`（input） | 改成你自己的 GitHub 用户名；访客公钥闸门只放行该账号登记的公钥 |
| 仓库变量 `WEB_TERMINAL_BASE_URL` | 网页站点根地址；只用 SSH 通道时也要填（当前为校验必填项） |

网页通道另需 `WEB_BRIDGE_BASE_URL`（如 `wss://wuge.fun`）与 `WEBAUTHN_ALLOWED_CREDENTIALS`（单行 JSON，`[]` 表示开放一次自举注册）。字段与排查见 [docs/接入指南.md](docs/接入指南.md)。

> `ssh` 默认是 `false`：只做前置校验、不建立会话。要真正拿到会话必须显式写 `ssh: true`。

## 两种接入方式

| 方式 | 写法 | 适合 |
| --- | --- | --- |
| Composite Action | `uses: itwuge/ActionSSHConnection@v1`（你 job 里的一步） | 大多数项目：保留自己的 job 结构、超时与前后步骤 |
| 可复用工作流 | `uses: itwuge/ActionSSHConnection/.github/workflows/reusable-session.yml@v1`（job 级） | 不想维护 job 模板，整段生命周期交给本仓库 |

两者 inputs 与 9 个 outputs 同名；可复用工作流内部检出本仓库后调用**同一个** Composite Action，不存在两份实现。

## 架构

```
SSH 访客 ──ssh──▶ 中继 ssh.wuge.fun:2222 (uptermd) ◀──反连── runner 内 upterm host
浏览器 ──https/wss──▶ 中继 nginx /t/ /ws/ /runner/ ▶ WebAuthn 准入 ▶ tmux
```

- runner 无入站端口：SSH 侧由 `upterm host` 主动反连中继；网页侧由 `start_web_bridge.py` 反连 `wss://<中继>/runner/<session_id>`，准入脚本 `web_admission.py` 验签后把字节流接到同一个 tmux 会话。
- 日志与摘要只输出 9 个公开路由字段：`session_id`、`ssh_user`、`relay_host`、`relay_port`、`web_url`、`pubkey_fingerprint`、`expires_at`、`pubkey_credential_id`、`path_mode`。客户端原始 JSON、连接串、公钥内容不外显。
- 会话由 `session-minutes`（默认 45）限时；无人接入时 `join-timeout`（10 分钟）先结束。

## 前置条件与安全边界（摘要）

- 运行器必须是 Linux（`ubuntu-latest`），自带 `bash`、`jq`、`python3`、`gh`、`tmux`、`ssh-keygen`。
- 需要一台已部署的 uptermd 中继（`deploy/` 下有 nginx 与桥接资产），以及可达 `github.com`、中继 `2222`、`443` 的出网。
- 访客公钥只从 `ssh-user` 账号的公开公钥接口拉取；`repository_dispatch` 入口还校验发起者与 `ssh-user` 一致。
- 凭据不落四类载体：仓库变量、日志、制品、提交。仓库里只存公开标识（公钥指纹、凭据标识、known_hosts 公钥）。
- `allowed-credentials: "[]"` 的自举模式下，第一个完成注册的人获得终端；生产应预置凭据条目。

完整说明见 [docs/接入指南.md](docs/接入指南.md)，日常使用见 [docs/使用说明.md](docs/使用说明.md)。

## 已知限制与未验证项

以下为事实，不是已具备能力：

- **直连（打洞）未验证**：`path-mode=direct` 只表示 5 秒 TCP 探针通过，数据面仍走中继。
- **WebAuthn 真实域名验签未完成**：浏览器注册在无平台认证器的环境中会于 45 秒认证超时后失败；服务端注册请求与超时行为已取证，签名验签链路待有认证器的机器确认。
- **网页通道依赖中继侧部署**：`/ws/`、`/runner/` 与桥接服务不可用时，SSH 仍可用，日志会按 `bridge-connect` / `bridge-register` / `bridge-admission` 报出阶段。
- **仅支持 Linux runner**；Windows / macOS 未支持。
- **upterm 客户端只内置 `v0.41.1` 的校验和**，其他版本会被拒绝。
- **Composite 的 outputs 在会话结束后才有值**：会话进行中要读字段，需传 `route-artifact-name` 走制品。
- 中继与网页站点需自行部署；本仓库不提供托管服务。

## 目录结构

```
.
├── action.yml                       # Composite Action 入口（唯一实现起点）
├── .github/workflows/
│   ├── session.yml                  # 本仓库自己的入口（薄封装：检出后调用本地 Action）
│   └── reusable-session.yml         # 可复用工作流入口（workflow_call）
├── scripts/
│   ├── action/                      # Action 步骤脚本：precheck/install/start/route/bridge/wait/cleanup
│   ├── start_web_bridge.py          # runner 反连中继 /runner/<id>
│   ├── web_admission.py             # WebAuthn 准入与 tmux 桥接
│   ├── bridge/                      # 中继侧桥接服务与 JSONL 日志器
│   └── requirements-web-*.txt       # 网页通道依赖
├── web/                             # 浏览器终端前端
├── deploy/                          # nginx 与中继部署资产（生产资产，只读）
├── docs/                            # 使用说明 / 接入指南
├── examples/                        # 三种调用样式与对比说明
└── .team/                           # 设计书、需求条目与裁决记录
```

## 版本

`v0.1.0` 为首个可用版本，`v1` 是移动标签。锁定到具体 tag 或 SHA，不要用浮动分支。

# 示例对比

三个示例都只依赖本仓库的 Action / 可复用工作流，不需要复制任何脚本。

| 文件 | 接入方式 | 适用场景 | 复杂度 |
| --- | --- | --- | --- |
| [action-minimal.yml](action-minimal.yml) | Composite Action | 只想临时开一个调试会话，几行搞定 | 最低 |
| [action-with-outputs.yml](action-with-outputs.yml) | Composite Action | 拿到会话后还要在自己的步骤里用 9 个字段（通知、写文件、二次校验） | 中 |
| [reusable-workflow.yml](reusable-workflow.yml) | 可复用工作流（`workflow_call`） | 不想维护 job 结构，整段运行器生命周期交给本仓库 | 中 |

## 三者的核心差别

- **Composite Action**：`uses: itwuge/ActionSSHConnection@v1` 是你自己 job 里的一步。job 的 `runs-on`、`timeout-minutes`、`permissions`、前后的准备/收尾步骤都由你控制。
- **可复用工作流**：`uses: itwuge/ActionSSHConnection/.github/workflows/reusable-session.yml@v1` 占的是 **job 级** 位置，job 本身由本仓库定义，你不能往里插步骤；需要 outputs 时用 `needs.<job>.outputs.*`。

两者输出字段完全同名，都是 9 个。

## 复制后需要改哪几行

1. **中继三件套**（只换其中一项会导致 known_hosts 不匹配或连错端口）：
   - `relay-host`
   - `relay-port`
   - `known-hosts`（端口非 22 时必须写成 `[host]:port ssh-ed25519 AAAA...`）
2. **站点地址**：`web-base-url`（浏览器打开的 `/t/<id>` 前缀）与 `bridge-base-url`（runner 反连的 `wss://` 地址）。
3. **登入用户**：`ssh-user` 改成你自己的 GitHub 用户名，闸门只放行该用户登记的公钥。
4. **权限**：job 或 workflow 需要 `permissions: contents: read`。
5. **会话时长**：`session-minutes` 与 job 的 `timeout-minutes` 要匹配（后者更大）。
6. **必须显式 `ssh: true`**：默认 `false` 只做前置校验，不会开出可登入的 shell。

## 使用 outputs 的两个注意点

- Composite Action 的 outputs 在**这一步结束时**才有值；如果会话还在跑（Action 会阻塞到会话结束），下游步骤拿不到"实时"字段。需要在会话进行中读取字段时，给 Action 传 `route-artifact-name: route-fields`，由制品读取（见本仓库 `.github/workflows/session.yml`）。
- 可复用工作流的 outputs 需要 `needs` 引用；作业失败时下游 `needs` 默认不执行，需要 `if: always()`。

## 变量与凭据

- 网页准入允许清单用 `allowed-credentials` 传（单行 JSON）。`[]` 表示开放一次自举注册，任何人都能成为第一个注册者，生产环境建议预置条目。
- 已预置凭据时，Composite 调用会读取**调用方仓库**的 `WEBAUTHN_CREDENTIAL_ID` 变量；未设置即按自举注册处理。

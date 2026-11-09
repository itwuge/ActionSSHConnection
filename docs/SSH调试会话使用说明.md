# SSH 调试会话使用说明

适用工作流：`.github/workflows/ssh-debug.yml`

## 一、前提

| 项 | 要求 |
| --- | --- |
| 中转端 | 已按设计方案部署 `uptermd`，`relay.wuge.fun:22` 可连 |
| 仓库变量 | `UPTERM_RELAY_KNOWN_HOST` 已设置为中转主机的 known_hosts 行（公钥，不是私钥） |
| GitHub 账号 | `itwuge` 已在该账号下登记 SSH 公钥；会话只允许这些公钥进入 |
| 本机 | 有 SSH 客户端；私钥即你平时连 GitHub 的那把（未登记则先登记） |

## 二、触发方式

### 方式 1：workflow_dispatch

Actions → 选择「SSH 调试会话」→ Run workflow → 把 `ssh` 勾为 true → 运行。

`ssh` 默认 false，不勾选不会建会话。

### 方式 2：repository_dispatch（webhook 关键词）

```bash
gh api repos/<owner>/<repo>/dispatches -f event_type=ssh
```

- `event_type` 必须正好是 `ssh`（工作流按 `types: [ssh]` 过滤）。
- 调用凭据需具备仓库 `Contents: write`（classic token 为 `repo`）。
- 该事件固定使用默认分支上的工作流。
- 工作流会校验发起者必须是 `itwuge`；`github.event.sender.login` 的实际取值尚待真机确认。

## 三、日志里看哪几行

1. 作业摘要（Summary）中的「SSH 调试会话路由信息」：中转地址、授权用户、公钥指纹、无人接入超时、最迟结束时间。
2. 「建立 SSH 调试会话」这一步的日志：出现

   ```text
   ssh <会话标识>@relay.wuge.fun
   ```

   的整行，以及该 action 自己写入摘要的 SSH config 块（`Host` / `HostName` / `User`）。
3. 路由信息不会被打码，也不会出现私钥或 token。

## 四、怎么连进去

直接复制日志里的整行命令执行：

```bash
ssh <会话标识>@relay.wuge.fun
```

- 若默认私钥不是 GitHub 上登记的那把，加 `-i <私钥路径>`。
- 会话标识只是路由标识，单独拿到它没有你的私钥进不来。
- 需要访问 runner 上的服务时，用 `ssh -L`（本方案未开启免审批端口转发，具体以会话提示为准）。

## 五、结束与续跑

| 操作 | 结果 |
| --- | --- |
| 输入 `exit` 或 `Ctrl-D` | 会话结束，工作流继续执行 |
| `~.` 或直接关终端 | 只断开你的连接，会话继续等待重连 |
| 会话内 `touch $GITHUB_WORKSPACE/continue` | 工作流继续，会话保留到作业结束 |

## 六、时限

- 无人接入：10 分钟后自动结束。
- 会话单步上限：40 分钟；作业上限：45 分钟。

## 七、安全约定

- 日志、摘要、制品、仓库中不得出现私钥、口令、一次性 token、GitHub token。
- 路由行不得加掩码；出现 `***` 即视为失败。
- 会话标识可以出现在日志，但不得作为唯一认证手段；认证始终依赖你 GitHub 账号上的公钥。
- 仓库变量与 Secret 只用于中转地址、主机指纹等非秘密路由信息，不得让路由字段取自 Secret。

## 八、当前占位/待确认值

| 值 | 现状 |
| --- | --- |
| `relay.wuge.fun:22` | 按设计方案填写，待中转端就绪后实测 |
| `itwuge` | 按设计方案填写，待确认实际账号名 |
| `UPTERM_RELAY_KNOWN_HOST` | 待 O01/P08 提供主机公钥行后写入仓库变量 |
| `upterm-version: v0.41.1` | 已核实为当前最新 release（2026-11-05），待与中转端版本对齐 |
| `owenthereal/action-upterm` commit | 已核实 v2.8.1 对应 `6c2d60e09009f59cb4c45c88767c78701f14d121` |

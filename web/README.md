# 网页终端前端（P07）

本目录是 ActionSSHConnection 的网页通道前端：浏览器内 xterm 类终端、WebSocket 字节流连接、WebAuthn 设备内签名。前端只与中转的 WS 端点通信，不直连 runner，不实现浏览器打洞。

## 1. 交付边界

- 终端渲染、键盘输入、容器尺寸自适应、断线提示与重连。
- 到中转 WS 的二进制帧收发，路径只携带 `session_id`。
- WebAuthn 注册与断言的**浏览器端部分**（`navigator.credentials.create/get`），私钥留在认证器，页面只接触公钥侧材料。
- 准入状态机：等待挑战、等待验签结果、未对接、被拒绝、出错。
- 页面不保存任何可复用凭据，不使用 URL 带 token 的做法，不展示密钥材料。
- 首次进入引导注册本设备通行密钥；注册成功后仅在本机 `localStorage` 记录公开的凭据标识与登记时间，用于后续直接进入。记录中不含私钥、断言或任何可直接登录的凭据，单独泄露不能完成认证。

不在本目录内：runner 侧验签、中继实现、发布执行、浏览器打洞。

## 2. 构建（必须先构建）

`index.html` 只引用 `dist/app.js` 与 `dist/app.css`，`dist/` 已 gitignore、不入仓库。拿到仓库后**必须先构建**，否则直接双击 `index.html` 只会看到空白页面，终端不会出现。

要求 Node.js 18 以上。

```powershell
cd web
npm install
npm run check
```

- `npm run check` 等于 `tsc --noEmit` 加 esbuild 打包，一条命令完成类型检查与构造。
- 产物为 `dist/app.js`、`dist/app.css` 与 sourcemap。
- 只打包不检查可用 `npm run build`，日常交付建议用 `npm run check`。

## 3. 本地运行

```powershell
cd web
npm run check
npm run serve
```

打开 `http://127.0.0.1:5173/t/demo-local?relay=ws%3A%2F%2F127.0.0.1%3A8787`。

页面地址形态与 tmate 一致：会话标识放在路径末尾 `/t/<会话ID>`。`?relay=` 只在 `localhost`、`127.0.0.1`、`[::1]` 下生效，用于把页面指向本地模拟中继，不属于凭据；部署域下中继地址自动取页面同域。

页面脚本与样式按根路径 `/dist/` 引用，因此不要直接双击 `index.html`（`file://` 下加载不到 `/dist`），请用 `npm run serve` 打开。

页面已声明 `referrer=no-referrer`，避免路径中的会话标识通过 Referer 外泄。

## 4. 本地验证（不验签）

仓库内提供一个**仅供本地验证**的模拟中继，它不验签、不校验公钥、不代表 runner 侧准入实现：

```powershell
cd web
npm run mock-relay
```

另开一个终端：

```powershell
cd web
npm run serve
```

打开：

```text
http://127.0.0.1:5173/t/demo-local?relay=ws%3A%2F%2F127.0.0.1%3A8787
```

首次进入会出现「首次使用」引导，写明「一次注册, 之后直接进」。本地调试域无法完成真实注册，「注册本设备并进入」为禁用；点击「已注册过, 直接进入」后应看到：终端出现 `mock$`、状态行为「已连接(模拟环境, 未验签)」。模拟中继返回的 `verifier` 固定为 `mock`，页面据此显式区分真实准入与模拟放行。

模拟中继只监听 `127.0.0.1`，`ws://` 明文仅对本机地址放行；其他地址必须使用 `wss://`。

本地调试域只用于上述界面验证：通行密钥绑定 `wuge.fun`，`localhost` 与 `127.0.0.1` 无法完成真实准入，页面会常驻提示这一点。

## 5. 部署口径

- 依赖方标识（rpId）固定为 `wuge.fun`，配置位置：[config.ts](src/config.ts) 的 `WEB_RP_ID`。
- 页面地址固定为 `https://wuge.fun/t/<会话ID>`；静态资源从根路径 `/dist/` 加载，因此产物部署在站点根目录，且 `/t/<会话ID>` 需回退到 `index.html`。
- 中继端点同域，例如 `wss://wuge.fun/ws/<会话ID>`；部署域下页面不提供中继地址输入。
- 页面在非 `wuge.fun` 域打开时，页面会立即显示明确提示并禁用注册按钮；即使强行连接，服务端下发挑战后也会因依赖方标识不符而失败，不会静默无响应。
- 服务端下发的 `rpId` 必须等于 `wuge.fun`，否则前端拒绝发起认证并提示配置不一致。

### 5.1 首次注册到直接进

1. 打开 `https://wuge.fun/t/<会话ID>`。本机无登记记录时，终端上方显示「首次使用」引导，核心文案是「一次注册, 之后直接进」。
2. 点击「注册本设备并进入」。前端在已连通的 WS 上发送 `authBegin`（`intent=register`），由 runner 侧下发 `registrationOptions`。
3. 浏览器调用 `navigator.credentials.create` 在设备内生成通行密钥；私钥不出设备，页面只提交公钥侧材料（`registration`）。
4. runner 侧确认注册并回 `authResult.ok=true` 后，页面把公开凭据标识写入本机 `localStorage`，随即进入终端。
5. 之后同一浏览器再打开任一 `/t/<会话ID>`，页面直接以 `authBegin`（`intent=assert`）发起断言并进入，不再出现登记引导；清除站点数据或更换浏览器后回到第 1 步。
6. 若服务端允许清单不含本机凭据，页面提示「本机登记的凭据不在服务端允许清单内, 需要重新登记本设备」，不会卡在无提示状态。

## 6. 服务端对接清单（一页）

本节是 runner 侧与中继侧实现时可以直接对照的完整接口页。前端只使用一个网络入口：`wss://<中继主机>/ws/<session_id>`。

### 6.1 总览

| 项 | 约定 |
| --- | --- |
| 传输 | WebSocket，只收发二进制帧；文本帧按协议错误提示 |
| 页面地址 | `https://wuge.fun/t/<session_id>`，会话标识在路径，与 tmate 的 `/t/<id>` 一致 |
| 路径 | `/ws/<session_id>`，只放会话标识，不带 token、口令、公钥 |
| 会话标识 | 字母、数字、下划线、连字符，长度 1 到 128 |
| 中继职责 | 无状态字节转发，不解析帧，不判准入，不存凭据 |
| 认证位置 | runner 侧准入进程验签；中继只转发 `authChallenge` 与 `authAssertion` 的字节 |
| 私钥位置 | 用户设备认证器内，任何服务端都拿不到 |
| 终端开放条件 | `authResult.ok=true`；未准入前前端不发送也不显示终端数据 |

### 6.2 帧格式

帧头 8 字节，负载上限 1 MiB，大端序：

| 偏移 | 长度 | 含义 |
| --- | --- | --- |
| 0 | 1 | 魔数 `0xA1` |
| 1 | 1 | 版本 `0x01` |
| 2 | 1 | 帧类型 |
| 3 | 1 | 保留位，固定 0 |
| 4 | 4 | 负载长度 |
| 8 | n | 负载 |

中继若把 WS 帧转成字节流转发，允许合并或拆分边界，但不得改变字节顺序；runner 侧必须按 `魔数 + 版本 + 类型 + 长度` 重组完整帧后再处理。

帧类型总表：

| 编号 | 名称 | 方向 | 用途 |
| --- | --- | --- | --- |
| `0x01` | `terminalData` | 双向 | 终端原始字节 |
| `0x02` | `resize` | 浏览器到服务端 | 行列数变化 |
| `0x10` | `authBegin` | 浏览器到服务端 | 发起准入 |
| `0x11` | `authChallenge` | 服务端到浏览器 | 断言挑战 |
| `0x12` | `authAssertion` | 浏览器到服务端 | 断言签名 |
| `0x13` | `authResult` | 服务端到浏览器 | 准入结果 |
| `0x14` | `registrationOptions` | 服务端到浏览器 | 注册选项 |
| `0x15` | `registration` | 浏览器到服务端 | 注册材料 |

### 6.3 逐帧字段

`0x01 terminalData`：负载为原始终端字节，UTF-8 或 ANSI 转义序列，不做 JSON 包装。服务端在准入通过前不得发送；前端在准入通过前不发送，也不显示。

`0x02 resize`：浏览器到服务端。

```json
{ "cols": 120, "rows": 32 }
```

`cols`、`rows` 必须为正整数；服务端据此调整 PTY 尺寸，不需要回复。

`0x10 authBegin`：浏览器到服务端。

```json
{ "intent": "assert", "clientVersion": "0.1.0" }
```

`intent` 取 `assert`（进入）或 `register`（登记设备）；`clientVersion` 当前固定 `0.1.0`，服务端可据此拒绝过旧页面，拒绝时用 `BAD_CLIENT_VERSION` 回复。

`0x11 authChallenge`：服务端到浏览器。

```json
{
  "challenge": "<base64url，一次性随机数>",
  "rpId": "wuge.fun",
  "timeoutMs": 60000,
  "userVerification": "preferred",
  "allowCredentialIds": ["<base64url>"]
}
```

- `challenge` 必须非空且一次性，绑定当前 `session_id`，不得复用。
- `rpId` 必须为 `wuge.fun`。
- `timeoutMs` 前端会截断到 10000 到 300000 之间。
- `userVerification` 取 `required`、`preferred`、`discouraged`，缺省 `preferred`。
- `allowCredentialIds` 可省略或为空数组，表示不限定；建议只下发允许清单内的凭据标识。

`0x12 authAssertion`：浏览器到服务端。

```json
{
  "credentialId": "<base64url>",
  "authenticatorData": "<base64url>",
  "clientDataJSON": "<base64url>",
  "signature": "<base64url>",
  "userHandle": "<base64url，可省略>"
}
```

`userHandle` 为空时不发送该字段，不要传空字符串。

`0x13 authResult`：服务端到浏览器。

```json
{ "ok": true, "verifier": "runner", "reason": "" }
```

- 只有验签通过后 `ok` 才能为 `true`；此时 `verifier` 必须为 `runner`。
- `verifier` 不是 `runner` 时，前端会显示「本地模拟器放行，服务端未验签」警告。
- `reason` 面向界面展示，不得含凭据、公钥、内部路径或堆栈。

`0x14 registrationOptions`：服务端到浏览器。

```json
{
  "challenge": "<base64url>",
  "rpId": "wuge.fun",
  "rpName": "ActionSSHConnection",
  "userId": "<base64url>",
  "userName": "user",
  "userDisplayName": "用户",
  "timeoutMs": 60000,
  "userVerification": "preferred",
  "excludeCredentialIds": []
}
```

`userId` 必须非空；`rpId` 必须为 `wuge.fun`；`excludeCredentialIds` 用于避免同设备重复登记。

`0x15 registration`：浏览器到服务端。

```json
{
  "credentialId": "<base64url>",
  "clientDataJSON": "<base64url>",
  "attestationObject": "<base64url>",
  "transports": ["internal"]
}
```

`attestationObject` 内含公钥；服务端解析后只保存公钥与凭据标识，私钥无法由该材料还原。

### 6.4 错误码语义

关闭原因：中继或 runner 关闭 WS 时，`reason` 文本必须包含下列令牌之一，前端按令牌识别，不依赖关闭码数值（数值未定）。

| 令牌 | 含义 | 前端表现 |
| --- | --- | --- |
| `UNKNOWN_SESSION` | 会话不存在，尚未建立或已结束 | 提示「会话不存在或已结束. 请向发起者索取新的连接串.」 |
| `ROUTE_GONE` | 会话路由已回收，runner 侧连接已断开 | 提示「会话已结束, 连接已回收. 请重新发起会话获取新的连接串.」 |

准入失败：用 `authResult.ok=false` 加 `reason` 原因码表达。前端已映射以下原因码为中文提示：

| 原因码 | 含义 |
| --- | --- |
| `ASSERTION_INVALID` | 签名无效，或挑战与本次会话不符 |
| `CREDENTIAL_NOT_ALLOWED` | 凭据不在允许清单内 |
| `CHALLENGE_EXPIRED` | 挑战已过期 |
| `CHALLENGE_REUSED` | 挑战已被使用 |
| `BAD_CLIENT_VERSION` | 页面协议版本过旧 |

未登记的原因码按原文展示，因此服务端必须保证 `reason` 可展示且不含敏感信息。

前端自身错误（不发往服务端，仅供排查对照）：

| 错误 | 触发条件 | 前端表现 |
| --- | --- | --- |
| `RP_ID_MISMATCH` | 服务端 `rpId` 不是 `wuge.fun`，或页面不在 `wuge.fun` 域 | 明确提示域名或配置不一致，不发起签名 |
| `NOT_SECURE_CONTEXT` | 页面非 HTTPS 且非 localhost | 提示通行密钥只能在安全上下文使用 |
| `NOT_SUPPORTED` | 浏览器无 WebAuthn | 禁用注册入口并提示 |
| `INVALID_PAYLOAD` | 挑战字段缺失或 base64url 非法 | 提示准入帧格式不符 |
| `CREDENTIAL_FAILED` | 用户取消、超时或认证器异常 | 提示取消或认证器不可用 |

帧解码失败：魔数、版本、类型或长度不符时，前端在页面提示协议错误，不把该帧交给上层处理。

### 6.5 runner 侧实现清单

- [ ] 生成一次性挑战，绑定 `session_id`，设置过期时间，拒绝复用。
- [ ] 校验 `clientDataJSON` 的 `type`、`challenge`、`origin`；`origin` 必须是 `https://wuge.fun` 或其子域。
- [ ] 校验 `rpIdHash` 等于 `SHA-256("wuge.fun")`。
- [ ] 按允许清单中的公钥验签，支持 ES256 与 RS256。
- [ ] 只有验签通过才发送 `authResult.ok=true`，且 `verifier` 填 `runner`。
- [ ] 允许清单只存公钥与凭据标识，随作业销毁；不得写入日志或制品。
- [ ] 准入通过前不发送 `terminalData`，并丢弃准入前的终端输入帧。
- [ ] 收到 `resize` 后调整 PTY；不回复尺寸帧。
- [ ] `reason` 只放原因码或可展示的中文，不放凭据与内部细节。
- [ ] 注册入口的前置条件待定：注册必须发生在已认证通道（例如已通过 SSH 登录的会话）或 runner 本机，不得仅凭 `authBegin` 就接受新公钥；具体载体待 M03 确认后再开放。

### 6.6 中继侧边界

- 只按路径取 `session_id` 维持内存路由，进程重启即清空。
- 不解析帧内容，不判断谁可进入，不保存挑战、断言或公钥。
- 按字节顺序转发，允许边界合并或拆分；不得改写、压缩或重编码负载。
- 会话不存在或路由回收时按 6.4 的令牌关闭连接。

## 7. 已知未验证与待确认

- 中继 WS 端点 `/ws/<session_id>` 实际部署与 TLS 证书未真机验证。
- 线上静态站点需把 `/t/<会话ID>` 回退到 `index.html`，且 `/dist/` 按站点根路径提供；该部署形态未真机验证。
- 首次注册流程依赖 runner 侧接受 `intent=register` 并回 `registrationOptions`，注册前置条件尚未开放（见 6.5 最后一项）。
- 中继是否严格原样转发二进制帧、是否会改变帧边界，待真机确认；前端按 6.2 的长度前缀可容忍合并与拆分。
- 关闭码具体数值未确定；前端只识别 `reason` 中的 `UNKNOWN_SESSION` 与 `ROUTE_GONE`。
- 网页通道不实现浏览器打洞，一期固定走中继。

## 8. 文件清单

| 文件 | 用途 |
| --- | --- |
| `index.html` | 入口页，连接串与终端两段结构 |
| `src/main.ts` | 入口脚本，解析 `/t/<会话ID>` 路径与中继地址 |
| `src/config.ts` | 部署域名与 rpId 配置，页面域名判定 |
| `src/app-controller.ts` | 自动进入或登记引导、连接、帧分流、准入渲染、断线提示 |
| `src/storage/credential-store.ts` | 本机记录公开凭据标识，用于后续直接进入 |
| `src/transport/relay-client.ts` | 中继 WS 连接与地址校验 |
| `src/terminal/terminal-view.ts` | xterm 渲染、尺寸自适应、输入采集 |
| `src/protocol/frames.ts` | 二进制帧编解码 |
| `src/protocol/control.ts` | 控制负载类型与运行时校验 |
| `src/auth/webauthn-client.ts` | WebAuthn 注册与断言客户端 |
| `src/auth/admission-client.ts` | 准入状态机与未对接上报 |
| `src/styles.css` | 页面样式 |
| `tools/serve.mjs` | 本地静态预览服务器 |
| `tools/mock-relay.mjs` | 本地模拟中继，不验签 |

## 9. 自检

在 `web/` 下执行：

```powershell
npm run typecheck
npm run build
```

TypeScript 开启 `strict`、`noUncheckedIndexedAccess`、`verbatimModuleSyntax`，全仓未使用 `any` 兜底。

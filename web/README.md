# 网页终端前端（P07）

本目录是 ActionSSHConnection 的网页通道前端：浏览器内 xterm 类终端、WebSocket 字节流连接、WebAuthn 设备内签名。前端只与中转的 WS 端点通信，不直连 runner，不实现浏览器打洞。

## 1. 交付边界

- 终端渲染、键盘输入、容器尺寸自适应、断线提示与重连。
- 到中转 WS 的二进制帧收发，路径只携带 `session_id`。
- WebAuthn 注册与断言的**浏览器端部分**（`navigator.credentials.create/get`），私钥留在认证器，页面只接触公钥侧材料。
- 准入状态机：等待挑战、等待验签结果、未对接、被拒绝、出错。
- 页面不保存任何凭据，不使用 URL 带 token 的做法，不展示密钥材料，不使用 `localStorage`、`sessionStorage`、Cookie 或 IndexedDB。

不在本目录内：runner 侧验签、中继实现、静态托管发布、浏览器打洞。

## 2. 构建

要求 Node.js 18 以上。

```powershell
cd web
npm install
npm run typecheck
npm run build
```

- `npm run build` 由 esbuild 打包 `src/main.ts`，产物为 `dist/app.js`、`dist/app.css` 与 sourcemap。
- `dist/` 与 `node_modules/` 已列入 `.gitignore`，构建产物不进入仓库。
- 页面入口是 [index.html](index.html)，固定引用 `dist/app.js` 与 `dist/app.css`。

## 3. 本地运行

```powershell
cd web
npm run build
npm run serve
```

打开 `http://127.0.0.1:5173/`。`localhost` 属于安全上下文，WebAuthn 可用。

也可以直接双击 `index.html` 打开：终端界面可渲染，但 `file://` 不是安全上下文，通行密钥不可用，且页面无法读取同目录以外的资源；只建议用于查看布局。

页面支持两个查询参数预填表单，二者都不属于凭据：

```text
http://127.0.0.1:5173/?relay=wss%3A%2F%2Frelay.example&session=<session_id>
```

页面已声明 `referrer=no-referrer`，避免地址栏中的 `session_id` 通过 Referer 外泄。

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
http://127.0.0.1:5173/?relay=ws%3A%2F%2F127.0.0.1%3A8787&session=demo-local
```

点击「连接」后应看到：终端出现模拟中继横幅与 `mock$`、连接状态为「已连接」、当前路径为「中继转发(relay)」，并出现黄色提示「当前准入由本地模拟器放行，服务端未验签」。模拟中继返回的 `verifier` 固定为 `mock`，页面据此显式区分真实准入与模拟放行。

模拟中继只监听 `127.0.0.1`，`ws://` 明文仅对本机地址放行；其他地址必须使用 `wss://`。

## 5. 连接与帧格式

连接地址固定为：

```text
wss://<中继主机>[:端口]/ws/<session_id>
```

- 路径只放 `session_id`，不追加 token、口令或公钥。
- `session_id` 允许字符为字母、数字、下划线、连字符，长度 1 到 128。
- 浏览器与中继之间只收发二进制帧；收到文本帧按协议错误处理。
- 中继按设计不解析帧内容，只做字节转发；本节的帧格式只对浏览器与 runner 侧准入进程有意义。
- 关闭原因中的 `UNKNOWN_SESSION` 与 `ROUTE_GONE` 会被页面识别为「会话不存在」与「会话路由已回收」；关闭码具体数值尚未确定，页面不依赖数值。

帧头 8 字节，负载上限 1 MiB：

| 偏移 | 长度 | 含义 |
| --- | --- | --- |
| 0 | 1 | 魔数 `0xA1` |
| 1 | 1 | 版本 `0x01` |
| 2 | 1 | 帧类型 |
| 3 | 1 | 保留位，固定 0 |
| 4 | 4 | 负载长度，大端序 |
| 8 | n | 负载 |

帧类型与负载：

| 编号 | 名称 | 方向 | 负载 |
| --- | --- | --- | --- |
| `0x01` | `terminalData` | 双向 | 原始终端字节，UTF-8 或 ANSI 序列 |
| `0x02` | `resize` | 浏览器到服务端 | JSON `{ cols, rows }` |
| `0x10` | `authBegin` | 浏览器到服务端 | JSON `{ intent, clientVersion }` |
| `0x11` | `authChallenge` | 服务端到浏览器 | JSON 挑战，见第 6 节 |
| `0x12` | `authAssertion` | 浏览器到服务端 | JSON 断言，字段均为 base64url |
| `0x13` | `authResult` | 服务端到浏览器 | JSON `{ ok, verifier, reason }` |
| `0x14` | `registrationOptions` | 服务端到浏览器 | JSON 注册选项，见第 6 节 |
| `0x15` | `registration` | 浏览器到服务端 | JSON `{ credentialId, clientDataJSON, attestationObject, transports }` |

准入通过前，页面不向服务端发送任何 `terminalData`，也不把服务端终端字节写入屏幕。

## 6. 认证契约

### 6.1 进入会话（断言）

1. WS 打开后，浏览器发送 `authBegin`：`{ "intent": "assert", "clientVersion": "0.1.0" }`。
2. runner 侧准入进程生成一次性挑战，发送 `authChallenge`：

   ```json
   {
     "challenge": "<base64url，一次性随机数，不得复用>",
     "rpId": "relay.wuge.fun",
     "timeoutMs": 60000,
     "userVerification": "preferred",
     "allowCredentialIds": ["<base64url>"]
   }
   ```

3. 浏览器校验 `rpId` 与页面主机兼容后调用 `navigator.credentials.get`，把断言以 `authAssertion` 发回：

   ```json
   {
     "credentialId": "<base64url>",
     "authenticatorData": "<base64url>",
     "clientDataJSON": "<base64url>",
     "signature": "<base64url>"
   }
   ```

4. runner 侧按允许公钥清单验签，发送 `authResult`：

   ```json
   { "ok": true, "verifier": "runner", "reason": "" }
   ```

   `verifier` 必须为 `runner`。页面不对其他取值显示为真实准入，只显示未验签警告。

### 6.2 注册通行密钥

1. 浏览器发送 `authBegin`：`{ "intent": "register", "clientVersion": "0.1.0" }`。
2. 服务端下发 `registrationOptions`：

   ```json
   {
     "challenge": "<base64url>",
     "rpId": "relay.wuge.fun",
     "rpName": "ActionSSHConnection",
     "userId": "<base64url>",
     "userName": "user",
     "userDisplayName": "用户",
     "timeoutMs": 60000,
     "userVerification": "preferred",
     "excludeCredentialIds": []
   }
   ```

3. 浏览器调用 `navigator.credentials.create`，把 `credentialId`、`clientDataJSON`、`attestationObject` 与 `transports` 以 `registration` 发回；公钥包含在 `attestationObject` 内，私钥由认证器保管。
4. 服务端验签与登记后返回 `authResult`。

### 6.3 占位与未对接行为

- runner 侧准入进程与 `verify_web_admission` 尚未实现。页面发送 `authBegin` 后若 8 秒内收不到 `authChallenge`，进入「未对接」状态，提示「runner 侧准入进程尚未对接，终端保持锁定」，并保持输入锁定，不会伪造通过。
- 注册按钮同样依赖服务端下发 `registrationOptions`；服务端未实现时只显示未对接提示。
- 页面不对 `authAssertion`、`registration` 的字节做展示、日志或持久化，只在内存中编码后经 WS 发送。

### 6.4 安全约束

- 私钥永不进入页面：WebAuthn 私钥由平台认证器或安全密钥保管，`navigator.credentials` 只返回公钥侧材料。
- 页面不持有可复用凭据：没有 token、Cookie、登录态或长期 bearer。
- 页面不读取或写入任何存储型凭据。
- `session_id` 不是凭据，但页面仍避免将其写入历史记录以外的位置；地址栏参数由使用者自行决定是否使用。

## 7. 依赖尚不存在的服务端

以下事项在本仓库内没有实现，前端按契约留出接口并显式提示，不假装已连通：

| 项 | 现状 | 影响 |
| --- | --- | --- |
| runner 侧准入进程 | 未实现 | 收不到挑战，页面进入「未对接」并锁定终端 |
| `verify_web_admission` | 未实现（设计书 5.1 第 5 项） | 断言无法验签，无法产生真实准入 |
| 中继 WS 端点 `/ws/<session_id>` | 部署脚本已具备，实际端点未真机验证 | 连接可能以 `UNKNOWN_SESSION` 或网络错误失败 |
| 中继原样转发二进制帧 | 设计书 3.6、5.2 标注待真机确认 | 若中继改写帧边界，帧解码会报错并提示 |
| 关闭码数值 | 未确定 | 页面只按关闭原因文本识别，不按数值判断 |
| 浏览器打洞 | 不实现 | 一期固定走中继，页面不显示直连路径 |

## 8. 已知未验证项

- WebAuthn 的 `rpId` 必须是页面主机或其上级域。若前端托管在 `*.github.io`，则无法以 `relay.wuge.fun` 作为 `rpId`；客户端会拒绝并提示「依赖方标识与当前页面主机不匹配」。托管方式与 `rpId` 的最终取值需与设计书 3.6 节一并确认，当前未验证。
- 设计书把 GitHub Pages 列为静态托管候选，属于对外发布，需按四类升级第 2 类放行；本目录未执行任何发布。
- 中继是否允许仅按路径取 `session_id` 而完全不解析帧，待真机确认；本前端按「中继不解析帧」实现，帧格式只在浏览器与 runner 之间生效。

## 9. 文件清单

| 文件 | 用途 |
| --- | --- |
| `index.html` | 入口页，固定节点与静态文案 |
| `src/main.ts` | 入口脚本，节点校验与查询参数预填 |
| `src/app-controller.ts` | 连接、帧分流、准入渲染、断线提示 |
| `src/transport/relay-client.ts` | 中继 WS 连接与地址校验 |
| `src/terminal/terminal-view.ts` | xterm 渲染、尺寸自适应、输入采集 |
| `src/protocol/frames.ts` | 二进制帧编解码 |
| `src/protocol/control.ts` | 控制负载类型与运行时校验 |
| `src/auth/webauthn-client.ts` | WebAuthn 注册与断言客户端 |
| `src/auth/admission-client.ts` | 准入状态机与未对接上报 |
| `src/styles.css` | 页面样式 |
| `tools/serve.mjs` | 本地静态预览服务器 |
| `tools/mock-relay.mjs` | 本地模拟中继，不验签 |

## 10. 自检

在 `web/` 下执行：

```powershell
npm run typecheck
npm run build
```

两条命令在 2026-11-09 的本地执行结果均为退出码 0。TypeScript 开启 `strict`、`noUncheckedIndexedAccess`、`verbatimModuleSyntax`，全仓未使用 `any` 兜底。

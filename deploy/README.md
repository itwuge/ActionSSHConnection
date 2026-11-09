# 自托管中转部署（v3）

本目录是中转机的部署资产。v3 将中转定位为**无状态字节转发器**：只按 `session_id` 转发 SSH 或 WS 字节流，不做访客认证、不做访问判定、不落盘会话状态。访客认证完全在 runner 侧完成。

## 1. 准入核实结论

结论：`uptermd` **默认不强制**宿主在服务器 `authorized_keys` 白名单注册；设置 `UPTERMD_AUTHORIZED_KEYS` 后，只有清单内公钥可以注册为宿主，清单外密钥会被拒绝。

依据（上游仓库 `owenthereal/upterm`，标签 `v0.41.1`，核实日期 2026-11-09）：

- `cmd/uptermd/command/root.go`：`--authorized-keys` 的帮助文本是 “authorized_keys file(s) controlling which public keys may register as hosts; may be repeated”，即该参数只限制**宿主注册**，且是可选参数。
- `server/sshproxy.go`：`loadAuthorizedKeys` 在未提供任何文件时返回 `nil`，注释明确写着 “signaling that the gate is disabled”；`checkAuthorizedKeys` 在门禁为 `nil` 时直接放行。
- `server/sshproxy.go` 的门禁只作用于 `HostSSHClientVersion` 连接；访客/客户端连接不经过该校验，由 runner 侧内嵌 sshd 完成认证。
- `server/sshd.go` 的字段注释也写明：`HostGateEnabled` 设置时才只允许 `--authorized-keys` 中的宿主公钥，“Without the gate any key gets in”。
- 实测（2026-11-09，Ubuntu 22.04.5，uptermd v0.41.1）：未设置该变量时任意临时密钥可注册宿主；设置后仅清单内密钥可注册（exit 0），清单外密钥注册失败（exit 1，`Permission denied`）。同一中继开启宿主白名单时，不在该白名单内的访客公钥仍可登录，说明中继闸门只作用于宿主注册，访客只受 runner 侧 `--authorized-keys` 约束。

因此：

1. 默认部署**不设置** `UPTERMD_AUTHORIZED_KEYS`，宿主注册门禁关闭，中转不做任何准入判定。
2. 若显式设置该变量，其语义也仅是「准入仅限宿主注册」；访客认证仍完全在 runner 侧，中转从不校验访客公钥。
3. 本目录脚本与文档统一使用「宿主注册」这一命名，不再沿用旧的准入叫法；中转不承担任何访客判定。

注意：这是对源码的核对结论，不是真机握手实测；真机验证项见第 11 节。

## 2. 文件清单

| 文件 | 用途 |
|---|---|
| `install-uptermd.sh` | 幂等安装/升级 uptermd，写环境文件与 systemd 单元，执行监听、资源上限、空路由与禁落盘自检 |
| `uptermd.service` | systemd 单元：只读系统与密钥、仅 `/run` 可写、资源上限、低端口能力 |
| `firewall.sh` | ufw / nftables 双后端：SSH 与 WS 入口限速、管理面来源限制、指标端口仅环回 |
| `rotate-relay-key.sh` | 反连注册标识轮换（服务身份密钥），输出 known_hosts 公钥行，支持回滚 |
| `check-relay-health.sh` | 只读健康检查，输出单行 JSON，判据为监听齐备、路由为空、无会话文件、资源上限生效；journald 容量仅提示 |
| `nginx/ssh.wuge.fun.conf` | 网页终端子域入口的 nginx 站点片段，仅落仓库不自动部署；文件头写明部署与回滚步骤 |
| `actssh-web-bridge.service` | 网页桥接进程的 systemd 单元：非 root、整机只读、无写路径、内存/CPU/任务数上限 |
| `nginx/web-bridge-location.conf` | `/ws/` 与 `/runner/` 两个 location 片段，含 Upgrade 头、禁缓冲、长连接超时；仅落仓库不自动部署 |
| `../scripts/bridge/relay_bridge.py` | 桥接服务实现（无状态配对与字节转发），由上面的单元拉起 |
| `../scripts/start_web_bridge.py` | runner 侧桥接客户端，反连 `/runner/<session_id>` 并把字节流转给 `web_admission.py` |
| `README.md` | 本文件 |

## 3. 中转与打洞的关系

会话建立分两阶段，**先打洞、失败回落中继**：

- 阶段一：两端尝试直连。整体超时上限候选 5 秒，具体值待实测；超时即判失败，不反复重试。
- 阶段二：打洞失败后立即切到中继转发。`session_id` 不重建，用户侧入口地址不变。
- 日志用 `path_mode` 标记实际路径：`direct` 或 `relay`。
- 打洞成功时，中继不参与数据面，只保留会话登记与到期管理；打洞失败时，中继负责双向转发字节流。
- 网页通道一期固定走中继，不实现浏览器打洞。

限制：GitHub **托管** runner 没有入站端口，纯 P2P 直连通常不成立。托管 runner 上的预期结果就是走中继；`path_mode=direct` 只作为优化项，不作为能力承诺。

中继不解析协议、不识别终端内容、不保存会话。进程重启即清空全部内存映射，重启期间会话断开属预期行为。

## 4. 连接顺序

1. 显式触发工作流后，runner 侧进程按「先打洞、后中继」建立会话。
2. 打洞在超时内未完成，立即回落到中继；中继记录 `session_id → runner 反向连接` 的内存映射。
3. 运行日志输出九项可读路由信息：中转地址、端口、会话标识、SSH 用户名、公钥指纹、到期时间、网页地址、公钥凭据标识、当前路径。
4. 需求方从 SSH 入口或网页入口进入同一个 runner 终端。
5. 会话结束、runner 进程退出或中继重启后，两个入口同时失效，原信息重连被拒。

日志只允许出现上述路由信息。私钥、口令、一次性 token、GitHub token 不产生、不打印、不写入制品或仓库。不要对路由信息调用 GitHub 的掩码标记，否则整行会被替换成不可读的占位符；正确做法是从源头不产生凭据，而不是事后掩码。

## 5. 前置条件

- Ubuntu 20.04 及以上，systemd 245 及以上，bash 5.x，root 执行。
- 中转机可出网访问 GitHub Releases。
- 中继监听端口空闲。默认设计是 relay 占用 22、系统 sshd 迁到 22022（见 6.1）；若不允许动 22（例如既有生产机），改用 `--ssh-addr 0.0.0.0:2222`，此时 2222 必须空闲且云安全组放行（见 6.1.1）。
- 云安全组先放行管理面来源，再改主机防火墙；主机防火墙只做兜底。
- WS 入口需要 TLS 终止层：`uptermd` 只监听明文 WS（默认环回 `127.0.0.1:8443`），公网 `wss://` 由反向代理终止 TLS 后转发到该端口。反向代理选型与证书管理不在本目录脚本内，属真机实施项。
- 反向代理与 uptermd 同机部署时，WS 上游固定监听 `127.0.0.1:8443`，不对外暴露。本方案的 nginx 由脚本安装在宿主上（独立实例、独立 conf 与 pid），不使用容器；若机器上已有容器占用 80/443，预检直接报端口冲突，不做接管。

## 6. 部署步骤

### 6.1 迁移系统 sshd 到 22022

1. 修改 `/etc/ssh/sshd_config` 的 `Port`，保留或新增管理面端口。
2. 执行 `sshd -t` 校验配置，再重启 sshd。
3. 用新端口另开一个连接确认可登录，确认后再关闭旧连接。
4. 云安全组只对管理来源放行新端口。

不要在未确认新端口可登录前关闭当前连接，避免锁死。

### 6.1.1 不迁移 sshd：中继改用非 22 端口

既有生产机上不要动 22 时，保持系统 sshd 原样，只给中继另开端口：

```bash
sudo deploy/install-uptermd.sh --version v0.41.1 --ssh-addr 0.0.0.0:2222
sudo deploy/check-relay-health.sh <中转地址> 2222
```

监听地址只由 `/etc/uptermd/uptermd.env` 的 `UPTERMD_SSH_ADDR` 决定，单元文件不写死端口；`--ssh-addr` 是安装脚本既有参数，无需为端口改脚本。安全组需另行放行该端口，脚本不改云侧配置；未放行时机器内可自测，外部不可达属预期。

### 6.2 安装或升级 uptermd

```bash
sudo deploy/install-uptermd.sh --dry-run
sudo deploy/install-uptermd.sh --version v0.41.1
```

建议同时提供发布包哈希，避免依赖远端 `checksums.txt` 的可用性：

```bash
sudo deploy/install-uptermd.sh --version v0.41.1 --sha256 <发布包 SHA256>
```

脚本会：

- 创建 `upterm` 系统用户与目录，生成或保留主机密钥；
- 下载发布包并校验哈希，原子替换二进制；
- 写 `/etc/uptermd/uptermd.env`，**不写** `UPTERMD_AUTHORIZED_KEYS`，**不创建** `authorized_keys`；
- 安装 `uptermd.service`，设置开机自启；
- 默认**不写** journald 上限、**不重启** `systemd-journald`：中继可能与非中继服务共用一台机，全局 `SystemMaxUse` 会影响同机其它服务的日志保留。确实需要时显式加 `--journald-max 200M`，并在确认该机为专用中继后再用；
- 重启后核对 SSH 监听（默认 22，可由 `--ssh-addr` 覆盖）、8443 监听、`MemoryMax`/`CPUQuota`/`TasksMax`、活动路由为 0、运行期目录无会话文件。

退出码 10 表示空路由或禁落盘自检未通过，退出码 11 表示资源上限未生效。

### 6.3 应用防火墙

先演练，确认管理面来源无误后再应用：

```bash
sudo deploy/firewall.sh --admin-cidr <管理来源网段> --dry-run
sudo deploy/firewall.sh --admin-cidr <管理来源网段> --apply
```

默认放行 SSH 22 与 WS 443，管理面 22022 只允许 `--admin-cidr` 来源，指标 9100 显式阻断。nftables 后端对 22 与 443 的新连接施加全局速率上限，阈值由 `FW_RELAY_RATE`、`FW_RELAY_BURST`、`FW_WS_RATE`、`FW_WS_BURST` 调整，默认值需按真机流量标定。

### 6.4 健康检查

```bash
sudo deploy/check-relay-health.sh <中转地址> 22
```

stdout 恰好一行 JSON，字段为 `ok`、`message`、`error_code`、`data`、`confirm`；第二个参数是中继实际 SSH 端口（非 22 时如 `2222`），仅用于监听判定，检查在机器本机执行。`data` 至少包含：

- `listen_state`：SSH、WS、环回 WS 三类监听；
- `route_table_empty`：`routing_active_connections_count` 是否为 0；
- `session_files_found`：运行目录条目与状态目录中的预期外文件；
- `journal_cap`：journald 上限配置与实际占用，`advisory:true` 表示仅提示，不参与 `ok` 判定。
- `bridge`：网页桥接一项，字段 `installed`、`unit_active`、`listen_ok`、`active_routes`、`restart_clean`、`ok`。未安装 `actssh-web-bridge.service` 时 `installed:false` 并跳过（`advisory:true`）；已安装时单元未 active 或 8081 未监听会使整体判定失败。`active_routes` 取自 `bridge.started`/`bridge.runner.connected`/`bridge.runner.closed` 事件里最近一次的 `active_routes`；`restart_clean` 为 true 表示最近一次启动事件记录到 0 个配对，即重启后无残留。可用 `CH_BRIDGE_UNIT`、`CH_BRIDGE_PORT` 覆盖默认值。

退出码：0 全部通过；1 判据未通过或状态取不到；2 参数或依赖错误。`journal_cap` 不达标只向 stderr 打一条 `[WARN]`，不改变退出码。

## 7. 验证判据

部署完成后按以下顺序验证：

1. `systemctl is-active uptermd.service` 为 `active`。
2. `ss -Hltn` 能看到配置的 SSH 监听端口（默认 22，例如 `2222`）、配置的 WS 监听地址（固定 `127.0.0.1:8443`）、`127.0.0.1:9100`。
3. `curl -fsS http://127.0.0.1:9100/metrics` 可读，活动会话数为 0。v0.41.1 实际指标名是 `upterm_uptermd_sessions_active_count`（带 `upterm_uptermd_` 前缀），脚本按候选名依次识别。
4. `systemctl show -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax uptermd.service` 与 `1G`、`150%`、`512` 对应。
5. `/run/uptermd` 为空；`/var/lib/uptermd` 只有主机密钥与轮换归档。
6. 重启一次服务后立即复查第 3、5 项，作为「重启后映射为空、无会话文件」的证据。
7. journald 容量仅作提示：200M 为准的提示阈值，超出只在 stderr 告警，不计入 `ok`；是否封顶由运维按机器用途决定。

## 8. 反连注册标识轮换

轮换对象是中转服务身份密钥，用途是 known_hosts 防中间人，不是准入凭据。中转不校验访客公钥，门禁默认关闭，因此轮换不会改变任何准入范围。

```bash
sudo deploy/rotate-relay-key.sh --dry-run
sudo deploy/rotate-relay-key.sh --apply
```

- 存在活动会话或指标不可达时默认拒绝轮换；确认无影响才加 `--force`。
- 成功后按脚本输出更新仓库变量 `UPTERM_RELAY_KNOWN_HOST`，并同步本机与各 runner 的 `known_hosts`。
- 旧密钥归档在 `/var/lib/uptermd/archive/`，可用 `--rollback <归档基础路径>` 恢复。
- 脚本只在运行时打印公钥行与指纹；公钥与指纹属可公开元数据，不是凭据。

## 9. 常见故障

| 现象 | 排查 | 处置 |
|---|---|---|
| 22 端口冲突 | `ss -Hltn 'sport = :22'` | 先迁走系统 sshd，或改 `--ssh-addr`；不要两个进程抢同一端口 |
| WS 入口不可用 | 查 8443 是否监听、TLS 终止层是否转发到配置的 WS 地址 | 修反向代理或证书；uptermd 本身不终止 TLS |
| 反代返回 502 且 error.log 为 `connect() failed (111: Connection refused)` | nginx 与 uptermd 不在同一网络命名空间，或 uptermd 未监听 8443 | 确认 `ss -Hltn 'sport = :8443'` 有 `127.0.0.1:8443` 监听；本方案 nginx 与中继同机，不得改用其它地址 |
| 健康检查报活动路由非 0 | 是否有真实会话未结束 | 等会话结束或重启服务；重启后映射必须为空 |
| 健康检查报会话文件 | `find /run/uptermd /var/lib/uptermd` | 说明进程发生了预期外写盘，按退出码 10 处理并检查版本与单元沙箱 |
| 指标不可达 | 查 9100 是否只绑环回、服务是否 active | 不要为了排障把 9100 暴露到公网 |
| 服务起不来且日志提示只读文件系统 | 查是否往 `/var/lib/uptermd`、`/etc/uptermd` 或 home 写文件 | 这是沙箱预期行为；确认版本是否支持只读运行，必要时调整 `ReadOnlyPaths` 并记录 |
| 绑定 22 报权限不足 | 查单元是否授予 `CAP_NET_BIND_SERVICE` | 保留 `AmbientCapabilities`，不要改成 root 运行 |
| journal 占用偏高 | `journalctl --disk-usage` | 默认不封顶，健康检查只提示；确认该机为专用中继时才用 `--journald-max 200M` 写入并 `journalctl --vacuum-size` |

## 10. 回滚

1. `systemctl disable --now uptermd.service`。
2. 恢复旧版二进制或旧单元文件，执行 `systemctl daemon-reload`。
3. 如刚轮换过密钥，用 `rotate-relay-key.sh --rollback <归档基础路径>` 恢复，并同步撤回仓库变量。
4. 恢复防火墙规则到变更前版本，确认管理面仍可登录。
5. 重启服务后执行健康检查，确认监听、空路由、无会话文件与资源上限。

不要删除主机密钥来「重置」服务；删除会改变 known_hosts 指纹，需同步更新仓库变量与客户端。

## 11. 必须在真机确认

以下项目需逐项确认，未取得实测证据的不得写成已实现或已验证：

1. ~~`User=upterm` 加 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 能否在 Ubuntu 20.04 上稳定绑定 22。~~ 2026-11-09 在 Ubuntu 22.04.5（systemd 249）实测通过：服务以 `upterm` 身份监听 `0.0.0.0:22`；20.04 仍未验证。
2. ~~`ProtectSystem=strict`、`ReadOnlyPaths`、`WorkingDirectory=/run/uptermd` 与 uptermd 实际写路径是否冲突；若冲突，禁落盘判据需调整。~~ 2026-11-09 实测未冲突：服务正常运行，`/var/lib/uptermd` 与 `/etc/uptermd` 无新增写入，`/run/uptermd` 保持为空。
3. ~~不设置 `UPTERMD_AUTHORIZED_KEYS` 时，runner 反连注册是否确实无需服务器侧公钥登记；~~ 2026-11-09 实测通过：未设置时临时密钥可注册；设置单钥白名单后清单内注册成功、清单外失败（exit 1，`Permission denied`）。设置空文件时是否拒绝所有宿主注册仍未验证。
4. ~~WS 监听 8443 加 TLS 终止层的组合能否完成浏览器 `wss://` 连接；反向代理选型与证书轮换方式未定。~~ 2026-11-09 生产机实测：`ssh.wuge.fun` 片段已部署，`https://ssh.wuge.fun` 证书链正常（Let's Encrypt YR2，SAN 仅 `ssh.wuge.fun`，到期 2027-02-07），非 WS 请求由 uptermd 返回 400；带 `Upterm-Client-Version` 与 Basic 认证头时 `wss://ssh.wuge.fun/ws/<session_id>` 与 `/` 均升级为 Open（约 0.2s），缺头返回 400。浏览器页面本身未验证。
5. ~~指标名 `routing_active_connections_count` 在 v0.41.1 的实际输出格式与标签情况。~~ 2026-11-09 实测：v0.41.1 不存在该名字，实际为 `upterm_uptermd_sessions_active_count` 与 `upterm_uptermd_routing_authenticated_connections_count{kind=...}`；脚本已改为按候选名识别。
6. ~~重启后 `/run/uptermd` 确实为空、`/var/lib/uptermd` 无新增会话文件。~~ 2026-11-09 实测通过：重启后 `/run/uptermd` 为空，`/var/lib/uptermd` 仅有 `server_key` 与 `server_key.pub`。
7. ~~`systemctl show` 返回的 `MemoryMax`、`CPUQuotaPerSecUSec`、`TasksMax` 字面值与本脚本判定一致。~~ 2026-11-09 实测：实际字面值为 `1073741824`、`1.500000s`、`512`；脚本原判定只认 `1500000`/`1.5s`，已改为统一换算微秒后比较。
8. nftables 速率规则的默认阈值在真实流量下是否合适，是否误伤正常重连。
9. 打洞优先策略在自建 runner 或同 NAT 环境下是否可成功；托管 runner 只验中继分支。
10. 两个入口同时进入同一会话时，TUI 的实际可用性。

补充实测条件：Ubuntu 22.04.5 的 `journalctl --disk-usage` 在部署前为 416.1M，写入 `SystemMaxUse=200M` 并重启 journald 后不会立即压到上限，需按第 9 节执行一次 `journalctl --vacuum-size`；本机压到 144.0M 后健康检查通过。同日做了同机端到端会话（upterm host + ssh 访客）：建会话、访客执行命令、回收均成功；访客在共享 shell 内 `exit` 会结束宿主命令并立即回收会话（2026-11-09 生产机复测：`session wait` 0.040s 返回，指标 0.053s 归零；走 exec 通道执行单条命令不影响会话，需显式 stop）。全程 `/run/uptermd` 与 `/var/lib/uptermd` 无新增文件，监听端口不变，停后 `sessions_active_count` 归零。另：中继只接受 publickey 认证，runner 未设闸门时访客也必须提供任意一把私钥，无密钥连接被拒（exit 255，`Permission denied`）。2026-11-09 阿里云成都 ECS（Ubuntu 20.04.6，2 vCPU/2 GiB/40 GiB）以 `--ssh-addr 0.0.0.0:2222` 部署，系统 sshd 保持 22 未改，22 上的连接未中断。闸门与时延实测：中继白名单只拦宿主注册，清单外宿主 exit 1（`Permission denied`），清单内 exit 0；中继白名单外的访客仍可登录，runner 侧清单外访客 exit 255（`Permission denied`）。访客 `exit` 后会话立即结束：从访客 ssh 返回计，`upterm session wait` 0.160s 返回（exit 0），10ms 粒度下活动会话指标 0.045s 归零；原连接串立即重连失败（exit 255，`Permission denied`）。

journald 策略修正（2026-11-09 生产机）：该 ECS 同时承载 nginx、Nuxt 与其它服务，部署时写入的全局 `SystemMaxUse=200M` 会改变同机所有服务的日志保留，已删除 `/etc/systemd/journald.conf.d/90-uptermd-limits.conf` 并重启 `systemd-journald`，既有 1.4G 历史日志保留未动。安装脚本相应改为默认不写 journald 片段（需显式 `--journald-max`），健康检查把 `journal_cap` 降为提示项、`advisory:true`、不参与 `ok` 判定。

## 12. 网页桥接（中继侧无状态配对 + runner 第二条反连 WS）

背景见 `.team/records/设计更正-网页桥接落点-20261109.md`。本轮只落本地代码与部署资产，未在真机部署，第 12.8 节全部待确认。

### 12.1 模块划分

| 模块 | 路径 | 职责 |
|---|---|---|
| 中继桥接服务 | `scripts/bridge/relay_bridge.py` | 两条 WS 端点、内存配对、二进制原样转发；不解析业务帧、不验签、不落盘 |
| 共用日志器 | `scripts/bridge/jsonl_logger.py` | 单行 JSON；基础字段 ts/level/logger/event/msg/run_id，异常附三字段；只写 journal 或 stderr |
| runner 桥接客户端 | `scripts/start_web_bridge.py` | 主动出站 `/runner/<session_id>`，把字节流接到准入子进程 stdin/stdout，按阶段非零退出 |
| 依赖锁 | `scripts/requirements-web-bridge.txt` | `websockets==10.4` |
| 单元文件 | `deploy/actssh-web-bridge.service` | 非 root、整机只读、无写路径、`MemoryMax=128M` / `CPUQuota=50%` / `TasksMax=64` |
| nginx 片段 | `deploy/nginx/web-bridge-location.conf` | `/ws/` 与 `/runner/`，Upgrade 头、禁缓冲、3600s 读写超时；只落仓库不自动部署 |
| 自测 | `scripts/bridge/test_relay_bridge.py`、`scripts/test_start_web_bridge.py` | 配对、透传、拒绝、清理、1 MiB 边界、退出码与五字段 |

桥接服务放在 `scripts/bridge/`：设计更正 5.2 明确指定该路径，且它与 `scripts/web_admission.py` 同属 runner/中继共用的 Python 交付面；`deploy/` 只放进程托管与反代资产，与现有 `uptermd.service`、`nginx/` 的口径一致。

### 12.2 关键契约

| 项目 | 契约 |
|---|---|
| 端点 | `GET /ws/<session_id>`（浏览器）、`GET /runner/<session_id>`（runner 反连）；路径只带 `session_id` |
| 配对 | 内存字典 `session_id -> runner_ws`；runner 先注册，浏览器后接入；浏览器到达到无 runner 时以 `UNKNOWN_SESSION` 关闭 |
| 转发 | 只接受二进制帧，原样双向转发；runner 的帧广播给该会话最多 2 个浏览器，浏览器的帧直发 runner |
| 上限 | 单帧 1 MiB（超出由 WS 层以 1009 关闭）；每会话浏览器最多 2；无写入磁盘路径 |
| 关闭令牌 | `ROUTE_CONFLICT`（重复 runner 或第三路浏览器，1008）、`ROUTE_GONE`（runner 断开，1001）、`UNKNOWN_SESSION`（会话不存在，1008）；文本帧以 1003 `PROTOCOL_TEXT_FRAME` 关闭 |
| 会话结束 | runner 断开即删映射并关闭该会话全部浏览器；旧 `session_id` 无路由；进程重启即清空全部配对，不恢复不重放 |
| 日志 | 只记连接元数据（`session_id`、对端地址、字节数、关闭码/令牌）；不记帧内容、不记凭据；`session_id` 属路由信息可原样记录 |
| runner 客户端 | `start_web_bridge <session_id> <bridge_ws_base> <admission_cmd>`；stdout 恰好一行五字段 JSON；日志写 stderr；`web_admission.py` 命令行契约不变 |
| 退出码 | 0 正常结束；1 连不上、被拒（`ROUTE_CONFLICT`/`ROUTE_GONE`/`UNKNOWN_SESSION`）；2 参数错误、准入子进程启动失败或非零退出、转发异常 |
| 空清单自举 | 允许清单为空数组 `[]` 且准入开放注册时，首个完成的注册被接受并立即绑定本次 `session_id`；同一会话后续注册一律以 `BOOTSTRAP_CONSUMED` 拒绝。非空清单行为不变（仍需 `--allow-registration`） |

依赖锁定 `websockets==10.4`：`requires-python >=3.7`，Ubuntu 20.04 的 Python 3.8 可直接安装；纯 Python 无编译依赖；同时提供 `websockets.serve()` 与 `websockets.connect()` 两套稳定接口，满足中继与 runner 两侧，不引入更重的框架。

### 12.3 部署顺序与前提

前提：中继已部署 uptermd（SSH 入口可用）；反向代理为宿主 nginx（第 13 节 `bootstrap.sh` 已一并安装桥接，通常不需要手工执行本节）。本节是手工等价步骤，只面向宿主 nginx；不使用容器。

1. 建专用用户与目录（非 root，无 home 写权限）：
   ```bash
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin actssh-bridge
   sudo install -d -m 0750 -o root -g actssh-bridge /opt/actssh-web-bridge
   sudo install -m 0640 -o root -g actssh-bridge scripts/bridge/relay_bridge.py scripts/bridge/jsonl_logger.py /opt/actssh-web-bridge/
   sudo python3 -m venv /opt/actssh-web-bridge/venv
   sudo /opt/actssh-web-bridge/venv/bin/pip install -r scripts/requirements-web-bridge.txt
   ```
2. 写参数文件（唯一参数来源，单元不写死端口）：
   ```bash
   sudo install -d -m 0750 /etc/actssh
   printf 'BRIDGE_LISTEN_HOST=127.0.0.1\nBRIDGE_LISTEN_PORT=8081\n' | sudo tee /etc/actssh/bridge.env
   sudo chown root:actssh-bridge /etc/actssh/bridge.env && sudo chmod 0640 /etc/actssh/bridge.env
   ```
   nginx 与桥接同机部署，固定用 `127.0.0.1`。禁止 `0.0.0.0`，进程会拒绝启动。
3. 安装并启动单元：
   ```bash
   sudo install -m 0644 deploy/actssh-web-bridge.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now actssh-web-bridge.service
   sudo systemctl status actssh-web-bridge.service
   ```
4. 只 include nginx 片段，不改主配置：
   ```bash
   sudo install -m 0644 deploy/nginx/web-bridge-location.conf /etc/actssh/nginx/conf.d/web-bridge-location.conf
   # 在 443 server 块内加一行：include /etc/actssh/nginx/conf.d/web-bridge-location.conf;
   sudo nginx -t -c /etc/actssh/nginx/nginx.conf && sudo systemctl reload actssh-nginx.service
   ```
5. 在 runner 侧并行启动桥接客户端（不改 SSH 反连）：
   ```bash
   python3 scripts/start_web_bridge.py "$SESSION_ID" "wss://wuge.fun/runner" \
     "python3 scripts/web_admission.py --session-id $SESSION_ID --tmux-session actssh --allowed-credentials <清单路径>"
   ```

部署顺序固定为「桥接进程 → nginx location → runner 客户端」：先有监听再放流量，避免 nginx 返回 502 混淆排障。

### 12.4 工作流接入点与失败阶段名

接入点：runner 建好 tmux 会话并打印九项路由信息之后、等待会话结束之前，把 `start_web_bridge` 作为与 SSH 反连**并行**的后台进程启动；两入口共用同一 `session_id` 与同一 tmux 会话。本轮不改 `.github/workflows/session.yml`，接入由后续 P08 落地。

失败阶段名（`data.stage` 与日志 event 一致）：

| stage | 触发 | 退出码 / error_code |
|---|---|---|
| `precheck` | 会话标识非法、基地址非 ws/wss、带凭据或查询串、准入命令为空或引号不匹配、参数缺失 | 2 / `SESSION_ID_INVALID`、`BRIDGE_URL_INVALID`、`ADMISSION_CMD_INVALID`、`ARGUMENT_INVALID` |
| `connect` | 反连不可达、握手失败、超时 | 1 / `BRIDGE_CONNECT_FAILED` |
| `register-rejected` | 桥接以 `ROUTE_CONFLICT` 关闭 | 1 / `ROUTE_CONFLICT` |
| `bridge` | 会话已结束（`ROUTE_GONE`）、未知会话（`UNKNOWN_SESSION`）、连接被关闭、文本帧、转发异常 | 1 或 2 / 对应令牌或 `BRIDGE_CLOSED`、`PROTOCOL_TEXT_FRAME`、`BRIDGE_TRANSFER_FAILED` |
| `admission-start` | 准入子进程无法启动 | 2 / `ADMISSION_SPAWN_FAILED` |
| `admission-exit` | 准入子进程退出 | 0（正常）/ `ADMISSION_EXITED` 且退出码 2（非零） |

任何失败都显式非零退出并在 stdout 的 `ok:false` 中体现，不静默降级为「仅 SSH 入口可用」而不留痕迹；调用方按非零退出记录失败，不能当作成功。

### 12.5 自测命令与结果

```bash
python3 -m venv .venv-bridge
.venv-bridge/bin/pip install -r scripts/requirements-web-bridge.txt
.venv-bridge/bin/python scripts/bridge/test_relay_bridge.py
.venv-bridge/bin/python scripts/test_start_web_bridge.py
```

2026-11-09 本机（Windows + Python 3.12，`websockets==10.4`）结果：

- `test_relay_bridge.py`：11 项通过——未知会话、非法路径、配对双向透传、重复 runner 拒绝且首个仍有效、第三路浏览器拒绝、双浏览器广播、runner 断开清理并回 `ROUTE_GONE`、重启清空映射、1 MiB 恰好通过、1 MiB+1 以 1009 拒绝、双向文本帧以 1003 拒绝；并断言日志不含发送的负载标记。
- `test_start_web_bridge.py`：12 项通过——地址拼接与非法基地址、会话标识校验、缺参/非法参数五字段输出与退出码 2、连接拒绝退出码 1、端到端字节回环（浏览器→桥接→客户端→假准入→回程）、`ROUTE_CONFLICT` 映射 `register-rejected`、准入启动失败与准入非零退出均退出码 2。

未覆盖：真机 wss、nginx Upgrade、Actions 网络策略、真实 WebAuthn，见 12.8。

### 12.6 回滚

1. `sudo systemctl disable --now actssh-web-bridge.service`。
2. 从 443 server 块删除 include 行（或删除 `web-bridge-location.conf`），`sudo nginx -t -c /etc/actssh/nginx/nginx.conf && sudo systemctl reload actssh-nginx.service`。
3. 保留 `scripts/web_admission.py` 与前端代码；桥接不落盘，无需清理用户数据。
4. 回滚后 SSH 入口仍按第 7 节判据可用；网页入口不可用属预期，不得写成已具备。

### 12.7 本机未验证事项（真机必须逐项确认）

| 序号 | 待确认项 | 判定方式 |
|---|---|---|
| 1 | 宿主 nginx 实例能对 `/ws/` 与 `/runner/` 完成 Upgrade 并长时间保持 | 浏览器与 runner 各连一次，观察 101、空闲 30 分钟不断流 |
| 2 | runner 出站 `wss://wuge.fun/runner/<session_id>` 可达且不被 Actions 网络策略阻断 | runner 上跑最小客户端连一次并回显 |
| 3 | Ubuntu 20.04 的 Python 3.8 可安装 `websockets==10.4` | `pip install` 记录版本号与离线包校验 |
| 4 | 桥接在 2 vCPU / 2 GiB 下资源可接受 | 两路终端字节流压测，记录 RSS、CPU、连接数 |
| 5 | 会话结束后旧 `session_id` 被拒，新会话不串入旧标识 | 结束会话后重连；再起新会话用旧标识重试 |
| 6 | 桥接重启后无配对、无文件、无审计痕迹 | 重启前后 `ss`、文件清单与 `active_routes` 对比 |
| 7 | 同会话第二个 runner 注册被拒、不静默顶替 | 两路 runner 客户端同时注册，观察 1008 `ROUTE_CONFLICT` |
| 8 | 单元沙箱与真机内核兼容 | 重点看 `ProtectSystem=strict`、`SystemCallFilter=@system-service`、`IPAddressDeny=any` 是否导致启动失败；桥接只连环回时 `IPAddressAllow=localhost` 足够 |
| 9 | WebAuthn 的 RP ID / origin 与 `https://wuge.fun` 一致 | 真实域名下完成一次注册与一次断言 |

### 12.8 空清单自举注册（已知残余风险）

首次使用没有可预置的公开凭据，按 tmate 语义允许自举：`WEBAUTHN_ALLOWED_CREDENTIALS` 为空数组 `[]` 且准入开放注册时，`web_admission.py` 接受**首个**完成的注册请求，并立即把本次 `session_id` 绑定到该凭据；同一会话后续注册一律以 `BOOTSTRAP_CONSUMED` 拒绝，非空清单行为不变。

- 凭据只存在于准入进程内存与浏览器 localStorage，不写仓库变量、不落盘、不打印公钥；日志只多一条 `admission.bootstrap_registered`，字段为 `session_id`、`credential_id_prefix`（前 8 位）、`registered_at`。
- **残余风险**：自举窗口期内，会话链接等同门票。任何人拿到 `https://wuge.fun/t/<session_id>` 都能完成这次注册并成为凭据持有者；此期间不具备「只有本人能进」的保证。
- 窗口关闭时机：首个注册成功即关闭；会话结束、runner 断开或准入进程退出后绑定与凭据一并消失。进程重启不会恢复任何绑定。
- 需要限定设备的场景不要用空数组，改为预置该设备的公开凭据；该风险同时记录在 `.team/records/设计更正-网页桥接落点-20261109.md` 的「已知残余风险」。

## 13. 从零部署（bootstrap.sh）

### 13.1 设计前提

**按空机器设计，不依赖宿主已有任何东西。** 反向代理、证书、中继、桥接、Python 依赖、防火墙、日志轮转、资源上限全部由脚本自带安装与配置。此前「复用现有 `certbot-nginx` 容器」「机器已有 ZeroTier」的说法不再作为设计依据，只在第 17 节作为迁移特例出现。

### 13.2 脚本结构

```
deploy/
├── bootstrap.sh                    # 编排入口: 预检 → 备份 → 分步执行 → 自检 → 汇总
├── bootstrap/
│   ├── lib.sh                      # 公共库: JSONL 日志, 原子写文件, 端口归属, 证书天数
│   ├── nginx-cert.sh               # 独立 nginx 实例 + certbot HTTP-01 + 自动续期
│   ├── web-bridge.sh               # actssh-bridge 用户, venv, 依赖, 环境文件, unit
│   ├── selfcheck.sh                # 收尾自检: 单元/监听/证书/健康/探活
│   └── actssh-nginx.service        # 独立 nginx 的 systemd 单元
├── uninstall.sh                    # 可逆卸载 (默认演练, --apply 执行)
├── make-bundle.sh                  # 打包成脱离仓库的自包含 tar.gz
├── firewall.sh                     # ufw / nftables 双后端
├── install-uptermd.sh              # uptermd 二进制与单元
├── check-relay-health.sh           # 单行 JSON 健康检查
├── uptermd.service                 # 中继单元模板
└── actssh-web-bridge.service       # 桥接单元模板
```

### 13.3 参数表

所有参数都有默认值，支持完全非交互执行。命令行优先于同名环境变量。

| 参数 | 默认 | 说明 |
|---|---|---|
| `--domain <fqdn>` | 无 | `full` 形态必填；`relay-only` 可省略 |
| `--acme-email <mail>` / `--email` | 空 | ACME 注册邮箱，可省略 |
| `--acme-staging` | 关 | 使用 ACME 预发布目录，避免打爆正式配额 |
| `--cert-mode acme\|standalone\|self-signed` | `acme` | `acme`(别名 `webroot`) 用宿主 certbot webroot 签发，不停服；`standalone` 签发时临时停 `actssh-nginx` 独占 80；`self-signed` 仅无公网 DNS 的实验环境 |
| `--web-root <dir>` | 空 | 网页终端静态目录；缺省时根路径 404 |
| `--relay-only` | 关 | 只装中继，不装 nginx / 证书 / 桥接 |
| `--with-direct` / `--no-direct` | `with-direct` | 中继 SSH 是否对外直连；关闭时只监听 `127.0.0.1` |
| `--uptermd-version <v>` | `v0.41.1` | 中继版本 |
| `--bridge-wheelhouse <dir>` | 空 | 离线 pip wheel 目录 |
| `--upgrade` | 关 | 读取上次参数，备份后重跑，失败自动回滚 |
| `--admin-cidr <cidr>` | 空 | 管理面来源，可重复；防火墙落地时必填 |
| `--allow-admin-anywhere` | 关 | 管理面不限来源，仅限临时排障 |
| `--rate-limit-ssh` | 关 | SSH / WS 入口按源限速，仅 ufw 后端 |
| `--ops-user <name>` | `$SUDO_USER` | 加入 `actssh-ops` 只读组的既有账号 |
| `--admin-ssh-port` / `--ssh-port` | `22` | 系统 sshd 端口，脚本不修改 |
| `--relay-port` / `--uptermd-port` | `2222` | uptermd SSH 端口 |
| `--http-port` | `80` | HTTP 端口；`acme` 模式固定 80 |
| `--https-port` | `443` | HTTPS 端口 |
| `--bridge-port` | `8081` | 桥接监听端口 |
| `--ws-backend-port` | `8443` | uptermd 明文 WS 端口 |
| `--metrics-port` | `9100` | Prometheus 指标端口 |
| `--state-dir <dir>` | `/var/lib/actssh-bootstrap` | 状态、备份、日志根目录 |
| `--skip-firewall` | 关 | 本次不处理防火墙 |
| `--apply` / `--dry-run` | 演练 | 只有 `--apply` 才落地 |
| `--rollback` | 关 | 回滚；与 `--apply` 连用才执行 |

### 13.4 端口与目录对照（空机器规划）

| 用途 | 端口 | 监听地址 | 来源限制 |
|---|---|---|---|
| 系统 sshd | `22` | `0.0.0.0` | 防火墙限定 `--admin-cidr` |
| uptermd SSH | `2222` | `0.0.0.0`（`--no-direct` 时为 `127.0.0.1`） | 直连开启时公网可达 |
| HTTP | `80` | `0.0.0.0` | 公网，仅 ACME 校验与 301 |
| HTTPS | `443` | `0.0.0.0` | 公网，反代 `/ws/` 与 `/runner/` |
| 网页桥接 | `8081` | `127.0.0.1` | 仅环回 |
| uptermd WS 上游 | `8443` | `127.0.0.1` | 仅环回 |
| uptermd 指标 | `9100` | `127.0.0.1` | 仅环回，防火墙显式阻断 |

| 目录 / 文件 | 用途 | 权限 |
|---|---|---|
| `/etc/actssh/nginx/nginx.conf` | 独立 nginx 主配置 | `0640 root actssh-ops` |
| `/etc/actssh/tls/` | 证书与私钥 | `0750 root actssh-ops` |
| `/etc/actssh/bridge.env` | 桥接唯一参数来源 | `0640 root actssh-bridge` |
| `/var/log/actssh/nginx/` | nginx 访问与错误日志 | `0750 root actssh-ops` |
| `/var/www/actssh-acme/` | certbot webroot | `0755 root root` |
| `/opt/actssh-web-bridge/` | 桥接代码与 venv | `0750 root actssh-bridge` |
| `/var/lib/uptermd/` | 中继主机密钥 | `0700 upterm upterm` |
| `/etc/uptermd/uptermd.env` | 中继参数 | `0640 root root` |
| `/usr/local/bin/uptermd` | 中继二进制 | `0755 root root` |
| `/var/lib/actssh-bootstrap/` | 状态、备份、日志 | `0700 root root` |
| `/etc/logrotate.d/actssh` | nginx 日志轮转 | `0644 root root` |
| `/etc/cron.d/actssh-certbot` | 续期兜底 | `0644 root root` |

资源上限写在单元里：`uptermd` 为 `MemoryMax=1G` / `CPUQuota=150%` / `TasksMax=512`；`actssh-nginx` 为 `256M` / `50%` / `128`；`actssh-web-bridge` 为 `128M` / `50%` / `64`。

### 13.5 端口冲突策略

预检阶段用 `ss -Hltnp 'sport = :<端口>'` + `/proc/<pid>/cgroup` 反查归属：

- 端口空闲，或属于本方案自己的单元（`uptermd.service`、`actssh-nginx.service`、`actssh-web-bridge.service`）→ 放行，支持幂等重跑；
- 属于其它进程（`docker-proxy`、`apache2`、其它 nginx）→ **直接退出码 8，不自动迁移端口**，输出占用者的 systemd 单元或 pid；
- `/etc/nginx/sites-enabled` 下存在非 `default` 站点 → 退出码 9，指向第 17 节迁移流程。

证书三条路径（`--cert-mode`）：

| 模式 | 校验方式 | 是否停服 | 适用 |
|---|---|---|---|
| `acme`（默认，别名 `webroot`） | 宿主 certbot `--webroot -w /var/www/actssh-acme`，HTTP-01 | 不停服 | 有公网 DNS 与 80 入站，推荐 |
| `standalone` | 宿主 certbot `--standalone`，签发时停 `actssh-nginx` 独占 80，结束后自动拉起；续期沿用同一 pre/post hook | 签发与续期瞬间停服 | 80 端口能腾出但 webroot 不便暴露 |
| `self-signed` | 本地 openssl 自签 | 不停服 | 无公网 DNS 的实验环境，不访问 ACME |

80 端口被占用时的处置，脚本不做自动切换，因为 HTTP-01 校验固定访问 80：

1. 停掉占用进程后再跑；
2. 容器占 80/443：预检直接退出码 8；需人工释放端口，步骤见第 17 节，脚本不会停容器；
3. 机器无公网 DNS、只是实验：用 `--cert-mode self-signed`，此时不访问 ACME，也不需要 80。

### 13.6 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，或演练完成 |
| 2 | 参数非法或组合冲突 |
| 3 | 系统或架构不支持 |
| 4 | 非 root，或防火墙会锁死管理面 |
| 5 | 软件包、状态目录或 apt 失败 |
| 6 | 依赖命令缺失 |
| 7 | 未预期错误 |
| 8 | 端口被外部占用 |
| 9 | 存在既有 nginx 站点或 80/443 被外部占用 |
| 10 | nginx 与证书步骤失败 |
| 11 | uptermd 步骤失败 |
| 12 | 桥接步骤失败 |
| 13 | 防火墙步骤失败 |
| 14 | 收尾自检失败 |
| 15 | 回滚失败 |
| 16 | 升级前置条件不满足 |
| 130 / 143 | 收到 INT / TERM |

### 13.7 幂等、备份与回滚

- 所有配置文件用「先写同目录暂存文件再原子改名」，内容无差异时跳过；apt 安装前先 `dpkg-query` 判存；证书用 `--keep-until-expiring`，有效期内不重复签发。
- `--apply` 会在 `/var/lib/actssh-bootstrap/backups/<run_id>/` 生成 `manifest.tsv`（本次参数与前置状态）和 `files.tsv`（每条为 `restore` / `remove` / `keep`）。私钥与证书目录只记录存在性，不复制第二份。
- 回滚：`sudo ./deploy/bootstrap.sh --rollback --apply`，按清单逆序停止自有单元、恢复文件、恢复防火墙前态与发行版 nginx 启停状态。回滚不卸载 apt 包，不删除备份目录，便于二次排查。
- 日志：`/var/lib/actssh-bootstrap/logs/<run_id>.jsonl`，一行一个 JSON。

### 13.8 结尾自检

`--apply` 成功后自动执行 `bootstrap/selfcheck.sh`，任一项失败即退出码 14：

1. `actssh-nginx.service`、`uptermd.service`、`actssh-web-bridge.service` 均为 `active`（`relay-only` 只查 uptermd）；
2. 管理面、中继 SSH、HTTP、HTTPS、桥接、WS 上游、指标逐项监听地址匹配；
3. 独立 nginx `nginx -t` 通过；
4. 证书剩余有效期 ≥ 7 天；
5. HTTP-01 本机探活（`/.well-known/acme-challenge/` 返回 404 而非 5xx 即可）；
6. `https://<域名>/ws/selfcheck` 与 `/runner/selfcheck` 至少返回 101 / 400 / 426 之一，证明路由与 Upgrade 头可达；
7. `check-relay-health.sh` 输出 `.ok == true`；
8. 自动续期机制存在（`certbot.timer` 或 `/etc/cron.d/actssh-certbot`）。

### 13.9 升级

```bash
sudo ./deploy/bootstrap.sh --upgrade --apply
sudo ./deploy/bootstrap.sh --upgrade --apply --uptermd-version v0.41.2
```

- `--upgrade` 从 `last_backup` 读回上次的域名、端口、形态、直连开关与管理面来源，命令行显式给出的参数优先；
- 升级前把 `/usr/local/bin/uptermd`、单元与 `uptermd.env` 一并纳入备份；
- 重跑全部幂等步骤；任一步失败自动按备份回滚并退出，回滚失败返回 15；
- 未安装过（无 `last_backup` 或无 `uptermd.service`）时返回 16，不会误把升级当首次部署。

### 13.10 脚本质量校验

```bash
# 语法
for f in deploy/*.sh deploy/bootstrap/*.sh; do bash -n "$f" || echo "FAIL $f"; done

# 静态检查 (warning 及以上必须为 0)
shellcheck -x -S warning deploy/*.sh deploy/bootstrap/*.sh
```

本次实测（2026-11-09，Ubuntu 22.04.5 上的 `shellcheck 0.8.0`）：`deploy/` 与 `deploy/bootstrap/` 共 10 个脚本 `bash -n` 全部通过，`-x -S warning` 零发现（`check-relay-health.sh` 的 2 个 `SC2034` 已删除未使用变量修复）。以默认 severity 运行时只剩 `SC2317 (info)` 的误报——脚本通过 `trap` 与 `_die` 间接调用函数，shellcheck 的调用图判断不到；需要绝对干净时可加 `-e SC2317`。shellcheck 只在验收机上用于校验，不进入交付物，目标机不需要安装。

### 13.11 干净环境实测（2026-11-09，VM 192.168.37.132）

基线：Ubuntu 22.04.5 x86_64，无 nginx、无 certbot、无 `/etc/actssh`、无部署残留；VM 上以 `--cert-mode self-signed`（无公网 DNS）与离线种子（`UPTERMD_RELEASE_BASE=file:///root/uptermd-seed`、`--bridge-wheelhouse /root/wheelhouse`）替代公网依赖。

| 动作 | 命令要点 | 结果 | 耗时 |
| --- | --- | --- | --- |
| 首次部署 | `--domain lab.actssh.test --cert-mode self-signed --admin-ssh-port 22022 --admin-cidr 192.168.37.0/24 --apply` | 退出 0，自检 17/17：3 个单元 active、7 个监听、nginx 语法、证书 89 天、ACME webroot、`/ws/` 与 `/runner/` 均 101、`relay:health ok=true` | 147.7s（packages 111s / nginx 6s / uptermd 5s / bridge 7s / firewall 4s / selfcheck 12s） |
| 卸载（保留数据） | `./deploy/uninstall.sh --apply` | 退出 0；3 个单元 inactive、7 个端口全部释放、`/etc/actssh`、`/opt/actssh-web-bridge`、`/etc/logrotate.d/actssh` 已删；`/var/lib/uptermd`、`/var/www/actssh-acme` 保留 | 4.1s |
| 换参重装 | `--relay-only --relay-port 2323 --admin-ssh-port 22022 --admin-cidr 192.168.37.0/24 --apply` | 退出 0，自检 6/6：`uptermd` active、2222 不再监听、2323 监听、WS 8443 与指标 9100 仅环回、`relay:health ok=true` | 15.9s（packages 0s 复用 / uptermd 4s / firewall 8s / selfcheck 1s） |
| 升级路径 | `--upgrade --apply` | 退出 0，读回上次 relay-only 参数，自检 6/6，无副作用 | 15.4s |

未通过项：无。环境侧两处前置问题已排除，不属于脚本缺陷——VM 的 DHCP 未下发 DNS（`systemd-resolved` 无上游，已用 `resolvectl dns` 指向可用解析器），以及首次尝试时 apt 因该 DNS 问题无法下载 nginx/certbot。

## 14. 卸载（uninstall.sh）

默认演练，`--apply` 才执行：

```bash
sudo ./deploy/uninstall.sh                    # 打印将删除的清单
sudo ./deploy/uninstall.sh --apply            # 停止并删除配置与程序, 保留数据
sudo ./deploy/uninstall.sh --apply --purge-data --domain ssh.example.com
```

| 开关 | 行为 |
|---|---|
| 默认（`--keep-data`） | 停用并删除三个单元、`/etc/actssh`（含独立 nginx 实例与其 pid 目录）、`/etc/uptermd` 下的规则文件、logrotate、`/etc/cron.d/actssh-certbot`、`/etc/letsencrypt/renewal-hooks/deploy/actssh-nginx-reload`、`/usr/local/bin/uptermd`、`/opt/actssh-web-bridge`；保留 `/var/lib/uptermd`、`/etc/uptermd`、`/var/www/actssh-acme`、ACME 证书谱系、状态与备份 |
| `--purge-data` | 追加删除 `/var/lib/uptermd`、`/etc/uptermd`、`/var/www/actssh-acme`（webroot）、`/var/lib/actssh-bootstrap`；给出 `--domain` 时一并删除该域名的证书谱系：`/etc/letsencrypt/live|archive|renewal/<域名>` |
| `--remove-firewall` | 回收本方案写入的 ufw 放行规则与 `uptermd_guard` nftables 表 |

从不删除：apt 软件包、系统 sshd 配置、发行版 nginx 站点、非本方案创建的目录。

## 15. 依赖与版本清单

### 15.1 外部二进制

| 组件 | 版本 | 获取方式 | 校验 |
|---|---|---|---|
| uptermd | `v0.41.1`（可参数覆盖） | GitHub Releases | 发布包 SHA256 或同版本 `checksums.txt` |
| shellcheck | 仅开发机校验用，不参与部署 | GitHub Releases | 不校验 |

### 15.2 系统包（apt）

`full` 形态：`curl jq ca-certificates openssl ufw openssh-server openssh-client nginx certbot python3 python3-venv python3-pip logrotate`。
`relay-only` 形态：只装前七个基础包，不装 nginx / certbot / python3-venv / python3-pip / logrotate。

### 15.3 Python 依赖

`websockets==10.4`（见 `scripts/requirements-web-bridge.txt`），安装在 `/opt/actssh-web-bridge/venv`，不污染系统 Python。

### 15.4 离线或受限网络

| 受限项 | 替代做法 |
|---|---|
| apt 不可达 | 预先在可达网络 `apt-get install --download-only`，把 `/var/cache/apt/archives/*.deb` 拷到目标机 `dpkg -i`；或用本地镜像源 |
| uptermd 下载不了 | 预先下载发布包，`UPTERMD_RELEASE_BASE=file:///opt/releases` 或 `UPTERMD_SHA256` 显式给哈希 |
| PyPI 不可达 | 在有网机器 `pip download -r requirements-web-bridge.txt -d wheelhouse`，目标机 `--bridge-wheelhouse /path/wheelhouse` |
| ACME 不可达（80 被封或无公网 DNS） | 实验环境用 `--cert-mode self-signed`；生产需先解决 80 入站，或改走 DNS-01（当前脚本未实现） |

## 16. 换一台服务器怎么用

### 16.1 前置条件

- 干净的 Ubuntu 20.04 / 22.04 **x86_64**，root 或可 `sudo`；
- 至少 2 vCPU / 2 GiB / 20 GiB；
- 一个解析到该机公网 IP 的域名（`relay-only` 可不要）；
- 云安全组放行：管理面 SSH、`2222`（直连）、`80`、`443`；
- 出网可达 apt 源、GitHub Releases、PyPI、ACME。

### 16.2 要准备什么

1. 域名 A 记录；
2. 管理面来源网段（例如 `203.0.113.0/24`）；
3. 一个可接收 ACME 通知的邮箱（可选）；
4. 若离线：apt 包缓存、uptermd 发布包、pip wheelhouse 三样。

### 16.3 三到五条命令

```bash
# 1) 取得脚本（二选一）
git clone <repo-url> && cd ActionSSHConnection        # 有仓库
# 或：把 make-bundle.sh 产物拷过去
tar -xzf actssh-deploy-<version>.tar.gz -C actssh     # 无仓库

# 2) 演练，确认端口与参数
sudo ./deploy/bootstrap.sh --domain ssh.example.com --email ops@example.com \
  --admin-cidr 203.0.113.0/24

# 3) 落地（自动备份 + 安装 + 自检）
sudo ./deploy/bootstrap.sh --domain ssh.example.com --email ops@example.com \
  --admin-cidr 203.0.113.0/24 --apply

# 4) 只装中继（不要网页）
sudo ./deploy/bootstrap.sh --relay-only --admin-cidr 203.0.113.0/24 --apply

# 5) 出问题回滚
sudo ./deploy/bootstrap.sh --rollback --apply
```

`make-bundle.sh` 的产物里已经包含 `deploy/` 与 `scripts/bridge/`，目标机不需要整仓。

### 16.4 装完怎么验证

```bash
systemctl is-active actssh-nginx.service uptermd.service actssh-web-bridge.service
ss -Hltn
sudo ./deploy/bootstrap/selfcheck.sh --domain ssh.example.com --cert-mode acme
sudo ./deploy/check-relay-health.sh 127.0.0.1 2222
curl -sS -o /dev/null -w '%{http_code}\n' https://ssh.example.com/
```

自检脚本成功时退出码 0，逐项打印 `[OK]`；任一失败退出码 1 并打印 `[FAIL]` 与原因。

### 16.5 出问题看哪里

| 现象 | 先看 |
|---|---|
| 部署中断 | `/var/lib/actssh-bootstrap/logs/<run_id>.jsonl`，按退出码对第 13.6 节 |
| nginx 起不来 | `journalctl -u actssh-nginx -n 100`、`/var/log/actssh/nginx/error.log` |
| 证书失败 | `journalctl -u certbot`、`/var/log/letsencrypt/letsencrypt.log` |
| 中继不起 | `journalctl -u uptermd -n 100`；确认 2222 未被占用 |
| 桥接不起 | `journalctl -u actssh-web-bridge -n 100`；确认 `/etc/actssh/bridge.env` 存在 |
| 网页 502 | 桥接是否 active、8081 是否监听、uptermd 8443 是否监听 |
| 回滚后仍异常 | `/var/lib/actssh-bootstrap/backups/<run_id>/files.tsv`，按行手工恢复 |

## 17. 已有服务的机器怎么办（迁移特例）

> **这一节是迁移特例，不是新标准的依据。** 第 13 节才是空机器标准。本方案全部跑在宿主上（宿主 nginx 独立实例 + 宿主 certbot），**不使用任何容器**；机器上已有容器占用 80/443 时按端口冲突处理，不共存、不接管、不提供容器内操作步骤。

### 17.1 检测与处置

- `bootstrap.sh` 预检用 `ss -Hltnp` 取监听进程，再按 `/proc/<pid>/cgroup` 反查单元；`docker-proxy` 归属 `docker.service`，不在允许清单内，直接 **退出码 8**；
- 报错信息会给出占用端口、pid 与所属单元，需人工决定：停掉占用方把业务迁到本方案，或换一台机器；
- 脚本不会改容器端口映射、不会停容器、不会写 docker 配置。

### 17.2 从容器迁移到宿主 nginx（人工执行，可回滚）

1. **记录基线**（只读）：`docker ps --format '{{.Names}} {{.Ports}}'`、`ss -Hltnp`、`ufw status verbose`、`nft list ruleset`、`systemctl list-units --type=service --state=running`，存到 `/root/migration-baseline-<日期>.txt`。
2. **先部署不碰 80/443 的部分**：
   ```bash
   sudo ./deploy/bootstrap.sh --relay-only --admin-cidr <管理网段> --apply
   ./deploy/check-relay-health.sh 127.0.0.1 2222     # 期望 ok:true
   ```
3. **由人工停容器释放 80/443**（脚本不做）：
   ```bash
   docker stop <容器名>          # 记录容器名与端口映射，作为回滚依据
   ss -Hltn 'sport = :80 or sport = :443'   # 期望为空
   ```
4. **落地宿主 nginx 与证书**：
   ```bash
   sudo ./deploy/bootstrap.sh --domain <域名> --email <邮箱> \
     --cert-mode acme --admin-cidr <管理网段> --apply
   ```
   自检通过即完成切换；证书由宿主 certbot 用 webroot 签发，不需要停服。
5. **观察 24 小时**后再决定是否删除旧容器与镜像；在此之前保留它们。

### 17.3 回滚

1. 停本方案：`sudo ./deploy/uninstall.sh --apply`（默认保留数据）。
2. 恢复旧容器：`docker start <容器名>`，确认 80/443 监听恢复。
3. 若已改防火墙：`sudo ./deploy/uninstall.sh --apply --remove-firewall`，再按 17.2 第 1 步的基线恢复 `ufw` / `nft`。
4. 复查：`ss -Hltnp`、`docker ps`、`curl -I https://<域名>` 与基线一致。

### 17.4 不要做的事

- 不要在容器仍占用 80/443 时直接跑 `full --apply`（会被预检拦下，退出码 8）；
- 不要删容器镜像或数据卷作为「回滚准备」；
- 不要在本方案里复刻容器时代的 `172.17.0.1` 写法：宿主部署一律 `127.0.0.1`。

## 18. 验证记录与待实现

### 18.1 公网 ACME 真机签发（HTTP-01 链路已验证，2026-11-09）

> 本节是**历史验证记录**，记录当时在既有生产机容器上做的一次性验证；第 13 节起的部署流程已完全不使用容器（宿主 nginx + 宿主 certbot），不要把本节的容器命令当作操作步骤。

**已验证**：真实域名 + 公网 HTTP-01 + 正式 Let's Encrypt 签发 + 续期演练，全链路在真机跑通。验证在既有生产机 `47.109.32.249` 的 `certbot-nginx` 容器内进行，只做证书这一节，未安装 bootstrap、未改既有站点与证书谱系。

域名与解析：`lab.wuge.fun`，用户添加 `*.wuge.fun` 通配符 A 记录指向 `47.109.32.249`。权威 NS（`dns29/dns30.hichina.com`）已返回该 IP；`1.1.1.1` 已同步；`223.5.5.5`/`8.8.8.8` 一度仍有 NXDOMAIN 负缓存，以权威 NS 结果为准。

逐项结果（时间为本机时区）：

| 步骤 | 命令 | 结果 | 耗时 |
|---|---|---|---|
| 备份 | `tar czf /root/acme-lab-backup-<ts>/conf.d.tar.gz` | sha256 `78c3e912…b996`，server_name 行快照 16 行 | 1s |
| 临时 80 块 | 新增 `conf.d/lab-acme-temp.conf`，`location /.well-known/acme-challenge/` → `root /usr/local/nginx/html/acme-lab` | `nginx -t` 通过、reload 成功 | 2s |
| 公网探针 | `curl http://lab.wuge.fun/.well-known/acme-challenge/probe` | 返回 `probe-ok-20261109_231707` | <1s |
| dry-run | `certbot certonly --webroot -w /usr/local/nginx/html/acme-lab -d lab.wuge.fun --dry-run` | 23:17:09→23:17:25，`The dry run was successful`，rc=0 | 16s |
| 正式签发 | 同上去掉 `--dry-run` | 23:17:41→23:17:54，rc=0 | 13s |
| 证书链 | 宿主 `openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt` | `OK`；链为 `CN=lab.wuge.fun` → `YR2` → `ISRG Root YR` → `ISRG Root X1`（fullchain 3 张）；证书公钥与私钥指纹一致 | 1s |
| 续期演练 | `certbot renew --dry-run --cert-name lab.wuge.fun` | 23:18:13→23:25:35，`all simulated renewals succeeded`，rc=0 | 7m22s |

签发到的证书：`subject=CN=lab.wuge.fun`，`issuer=Let's Encrypt CN=YR2`，`serial=058209FD2405B7665A4A846552699A73F2C9`，`notBefore=2026-11-09 14:19:21Z`，`notAfter=2027-02-07 14:19:20Z`（90 天）。`renewal/lab.wuge.fun.conf` 的 `authenticator=webroot`、`webroot_path=/usr/local/nginx/html/acme-lab`，与既有两条谱系同构。

清理与回归（23:25:52 起）：

- `certbot delete --cert-name lab.wuge.fun` 删除 `live/`、`archive/`、`renewal/` 下该谱系，三处目录只剩原有两个谱系；
- 删除临时 `conf.d/lab-acme-temp.conf` 与 webroot 目录，`nginx -t` 通过后 reload；
- `conf.d` 下全部文件的 sha256 与操作前逐字节一致（`CONF_SHA_SAME`）；`server_name` 行数 16 行、内容完全一致（`SERVER_NAMES_SAME`）；
- 公网侧 TLS 复测：`wuge.fun`/`www`/`admin` 仍为同一张证书，序列号 `0688262A5ADD713CB15D02E89245647DB92C`、到期 `2026-12-27 16:54:14`；`ssh.wuge.fun` 仍为 `0630335A377AE9964B682731E47DF0331F66`、到期 `2027-02-07 19:10:57`，与操作前基线完全一致；四个站点 80 端口仍统一 301 到 HTTPS。

两条环境注记（复现时会遇到）：

1. 精简镜像内可能没有系统 CA 包，`openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt` 会报文件不存在；链校验应把 `cert.pem`/`chain.pem` 取到有完整 CA 包的主机再做，或用 `openssl crl2pkcs7 | openssl pkcs7 -print_certs` 核对链结构；
2. 直接复制 `live/` 下的符号链接会得到 `invalid symlink`，应按链接目标读取内容再落盘。

**仍未验证的部分（不要扩大结论）**：本节验证的是 certbot + 公网 HTTP-01 的签发与续期链路，跑在既有容器布局上；`bootstrap.sh` 自带的 `nginx-cert.sh` 在**干净机**上用公网域名完成正式签发这一步仍未实跑（干净机实测走的是 `--cert-mode self-signed`）。要补齐时，在一台有公网 IPv4、80 端口可入站、且有 A 记录指向它的干净 Ubuntu 22.04 上执行：

```bash
dig +short A <子域>                                  # 必须返回该机公网 IP
sudo ./deploy/bootstrap.sh --domain <子域> --email <邮箱> \
  --acme-staging --admin-cidr <管理网段> --apply      # 先 staging，避免消耗正式配额
sudo ./deploy/bootstrap.sh --domain <子域> --email <邮箱> \
  --admin-cidr <管理网段> --apply                     # 正式签发
sudo certbot renew --dry-run
sudo ./deploy/bootstrap/selfcheck.sh --domain <子域>  # 期望 cert:expiry 约 90 天且非 self-signed
```

### 18.2 待实现：SSH 鉴权失败限速

**现状**：访客用错误密钥连接中继 SSH（默认 `2222`）时，认证在中继的 SSH 层失败，请求不会转发到 runner，因此 runner 侧日志与计数看不到失败次数，无法据此做封禁或告警；`uptermd` 本身也不暴露按来源的鉴权失败计数。

**建议方案**（择一，实施前先做压测与误封评估）：

1. 中继前置流式代理（推荐）：在 `2222` 前加 HAProxy/nginx `stream`，用 `stick-table`/`limit_conn` 按来源限制新建连接速率与并发，失败即拒绝，不改 uptermd；
2. 主机层限速：`nftables` 用 `meter` + `limit` 或 `iptables hashlimit` 对新入站 SSH 连接按源 IP 限速（可与现有防火墙脚本合并，需提供白名单与回滚）；
3. 指标侧旁路：从中继连接指标做差值与来源聚合，超阈值时由守护脚本下发临时封禁（实现成本最高，且拿不到失败原因）。

**状态**：待实现，本轮不落地。落地时需同步更新第 13.4 节端口表（新增前置代理端口）与 `uninstall.sh` 的清理清单。

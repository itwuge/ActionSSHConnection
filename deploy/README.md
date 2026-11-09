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
- 反向代理若在容器内（例如本项目的 `certbot-nginx` 容器），容器无法访问宿主回环，`127.0.0.1:8443` 与 `172.17.0.1:8443` 都不通；此时必须让 uptermd 直接监听 docker0 网关，安装时用 `--ws-addr 172.17.0.1:8443`（2026-11-09 生产机实测：未改绑时 nginx 报 `connect() failed (111: Connection refused)` 并返回 502，改绑后 400 由 uptermd 应答）。该地址只在 docker 网桥内可达，不新增公网端口。

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
2. `ss -Hltn` 能看到配置的 SSH 监听端口（默认 22，例如 `2222`）、配置的 WS 监听地址（默认 `127.0.0.1:8443`；容器化反代场景为 `172.17.0.1:8443`）、127.0.0.1:9100。
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
| 反代返回 502 且 error.log 为 `connect() failed (111: Connection refused)` | 容器内访问宿主回环不可达 | 用 `--ws-addr 172.17.0.1:8443` 让 uptermd 监听 docker0 网关并重启 |
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

前提：中继已按第 6 节部署 uptermd（SSH 入口可用）；nginx 仍是现有 `certbot-nginx` 容器；不得改 443 上其它站点，也不得改 `nginx/ssh.wuge.fun.conf`。

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
   printf 'BRIDGE_LISTEN_HOST=172.17.0.1\nBRIDGE_LISTEN_PORT=8081\n' | sudo tee /etc/actssh/bridge.env
   sudo chown root:actssh-bridge /etc/actssh/bridge.env && sudo chmod 0640 /etc/actssh/bridge.env
   ```
   nginx 在容器内时必须用 `172.17.0.1`（容器内 `127.0.0.1` 指容器自身）；同网络命名空间时才用 `127.0.0.1`。禁止 `0.0.0.0`，进程会拒绝启动。
3. 安装并启动单元：
   ```bash
   sudo install -m 0644 deploy/actssh-web-bridge.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now actssh-web-bridge.service
   sudo systemctl status actssh-web-bridge.service
   ```
4. 只 include nginx 片段，不改主配置：
   ```bash
   sudo install -m 0644 deploy/nginx/web-bridge-location.conf /root/certbot-nginx/nginx/conf/conf.d/web-bridge-location.conf
   # 在 wuge.fun 的 443 server 块内加一行：include /etc/nginx/conf.d/web-bridge-location.conf;
   docker exec nginx nginx -t && docker exec nginx nginx -s reload
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
2. 从 `wuge.fun` 的 443 server 块删除 include 行（或删除 `web-bridge-location.conf`），`docker exec nginx nginx -t && docker exec nginx nginx -s reload`。
3. 保留 `scripts/web_admission.py` 与前端代码；桥接不落盘，无需清理用户数据。
4. 回滚后 SSH 入口仍按第 7 节判据可用；网页入口不可用属预期，不得写成已具备。

### 12.7 本机未验证事项（真机必须逐项确认）

| 序号 | 待确认项 | 判定方式 |
|---|---|---|
| 1 | nginx（certbot 容器）能对 `/ws/` 与 `/runner/` 完成 Upgrade 并长时间保持 | 浏览器与 runner 各连一次，观察 101、空闲 30 分钟不断流 |
| 2 | runner 出站 `wss://wuge.fun/runner/<session_id>` 可达且不被 Actions 网络策略阻断 | runner 上跑最小客户端连一次并回显 |
| 3 | Ubuntu 20.04 的 Python 3.8 可安装 `websockets==10.4` | `pip install` 记录版本号与离线包校验 |
| 4 | 桥接在 2 vCPU / 2 GiB 下资源可接受 | 两路终端字节流压测，记录 RSS、CPU、连接数 |
| 5 | 会话结束后旧 `session_id` 被拒，新会话不串入旧标识 | 结束会话后重连；再起新会话用旧标识重试 |
| 6 | 桥接重启后无配对、无文件、无审计痕迹 | 重启前后 `ss`、文件清单与 `active_routes` 对比 |
| 7 | 同会话第二个 runner 注册被拒、不静默顶替 | 两路 runner 客户端同时注册，观察 1008 `ROUTE_CONFLICT` |
| 8 | 单元沙箱与真机内核兼容 | 重点看 `ProtectSystem=strict`、`SystemCallFilter=@system-service`、`IPAddressDeny=any` 是否导致启动失败；docker0 网段不是 172.17.0.0/16 时须改 `IPAddressAllow` |
| 9 | WebAuthn 的 RP ID / origin 与 `https://wuge.fun` 一致 | 真实域名下完成一次注册与一次断言 |

### 12.8 空清单自举注册（已知残余风险）

首次使用没有可预置的公开凭据，按 tmate 语义允许自举：`WEBAUTHN_ALLOWED_CREDENTIALS` 为空数组 `[]` 且准入开放注册时，`web_admission.py` 接受**首个**完成的注册请求，并立即把本次 `session_id` 绑定到该凭据；同一会话后续注册一律以 `BOOTSTRAP_CONSUMED` 拒绝，非空清单行为不变。

- 凭据只存在于准入进程内存与浏览器 localStorage，不写仓库变量、不落盘、不打印公钥；日志只多一条 `admission.bootstrap_registered`，字段为 `session_id`、`credential_id_prefix`（前 8 位）、`registered_at`。
- **残余风险**：自举窗口期内，会话链接等同门票。任何人拿到 `https://wuge.fun/t/<session_id>` 都能完成这次注册并成为凭据持有者；此期间不具备「只有本人能进」的保证。
- 窗口关闭时机：首个注册成功即关闭；会话结束、runner 断开或准入进程退出后绑定与凭据一并消失。进程重启不会恢复任何绑定。
- 需要限定设备的场景不要用空数组，改为预置该设备的公开凭据；该风险同时记录在 `.team/records/设计更正-网页桥接落点-20261109.md` 的「已知残余风险」。

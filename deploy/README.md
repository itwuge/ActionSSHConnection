# 自托管中转部署（v3）

本目录是中转机的部署资产。v3 将中转定位为**无状态字节转发器**：只按 `session_id` 转发 SSH 或 WS 字节流，不做访客认证、不做访问判定、不落盘会话状态。访客认证完全在 runner 侧完成。

## 1. 准入核实结论

结论：`uptermd` **不强制**宿主在服务器 `authorized_keys` 白名单注册后才能建立会话。

依据（上游仓库 `owenthereal/upterm`，标签 `v0.41.1`，核实日期 2026-11-09）：

- `cmd/uptermd/command/root.go`：`--authorized-keys` 的帮助文本是 “authorized_keys file(s) controlling which public keys may register as hosts; may be repeated”，即该参数只限制**宿主注册**，且是可选参数。
- `server/sshproxy.go`：`loadAuthorizedKeys` 在未提供任何文件时返回 `nil`，注释明确写着 “signaling that the gate is disabled”；`checkAuthorizedKeys` 在门禁为 `nil` 时直接放行。
- `server/sshproxy.go` 的门禁只作用于 `HostSSHClientVersion` 连接；访客/客户端连接不经过该校验，由 runner 侧内嵌 sshd 完成认证。
- `server/sshd.go` 的字段注释也写明：`HostGateEnabled` 设置时才只允许 `--authorized-keys` 中的宿主公钥，“Without the gate any key gets in”。

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
| `check-relay-health.sh` | 只读健康检查，输出单行 JSON，判据为监听齐备、路由为空、无会话文件、资源与日志上限生效 |
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
- 22 端口空闲；系统 sshd 已迁到 22022，或另有可用的管理面入口。
- 云安全组先放行管理面来源，再改主机防火墙；主机防火墙只做兜底。
- WS 入口需要 TLS 终止层：`uptermd` 只监听环回 `127.0.0.1:8443` 的明文 WS，公网 `wss://` 由反向代理终止 TLS 后转发到该端口。反向代理选型与证书管理不在本目录脚本内，属真机实施项。

## 6. 部署步骤

### 6.1 迁移系统 sshd 到 22022

1. 修改 `/etc/ssh/sshd_config` 的 `Port`，保留或新增管理面端口。
2. 执行 `sshd -t` 校验配置，再重启 sshd。
3. 用新端口另开一个连接确认可登录，确认后再关闭旧连接。
4. 云安全组只对管理来源放行新端口。

不要在未确认新端口可登录前关闭当前连接，避免锁死。

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
- 重启后核对 22 与 8443 监听、`MemoryMax`/`CPUQuota`/`TasksMax`、活动路由为 0、运行期目录无会话文件。

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

标准输出恰好一行 JSON，字段为 `ok`、`message`、`error_code`、`data`、`confirm`；`data` 至少包含：

- `listen_state`：SSH、WS、环回 WS 三类监听；
- `route_table_empty`：`routing_active_connections_count` 是否为 0；
- `session_files_found`：运行目录条目与状态目录中的预期外文件；
- `journal_cap`：journald 上限配置与实际占用。

退出码：0 全部通过；1 判据未通过或状态取不到；2 参数或依赖错误。

## 7. 验证判据

部署完成后按以下顺序验证：

1. `systemctl is-active uptermd.service` 为 `active`。
2. `ss -Hltn` 能看到 22、127.0.0.1:8443、127.0.0.1:9100。
3. `curl -fsS http://127.0.0.1:9100/metrics` 可读，活动会话数为 0。v0.41.1 实际指标名是 `upterm_uptermd_sessions_active_count`（带 `upterm_uptermd_` 前缀），脚本按候选名依次识别。
4. `systemctl show -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax uptermd.service` 与 `1G`、`150%`、`512` 对应。
5. `/run/uptermd` 为空；`/var/lib/uptermd` 只有主机密钥与轮换归档。
6. 重启一次服务后立即复查第 3、5 项，作为「重启后映射为空、无会话文件」的证据。
7. journald 实际占用不超过 200M，且 `90-uptermd-limits.conf` 中 `SystemMaxUse=200M`。

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
| WS 入口不可用 | 查 8443 是否监听、TLS 终止层是否转发到 127.0.0.1:8443 | 修反向代理或证书；uptermd 本身不终止 TLS |
| 健康检查报活动路由非 0 | 是否有真实会话未结束 | 等会话结束或重启服务；重启后映射必须为空 |
| 健康检查报会话文件 | `find /run/uptermd /var/lib/uptermd` | 说明进程发生了预期外写盘，按退出码 10 处理并检查版本与单元沙箱 |
| 指标不可达 | 查 9100 是否只绑环回、服务是否 active | 不要为了排障把 9100 暴露到公网 |
| 服务起不来且日志提示只读文件系统 | 查是否往 `/var/lib/uptermd`、`/etc/uptermd` 或 home 写文件 | 这是沙箱预期行为；确认版本是否支持只读运行，必要时调整 `ReadOnlyPaths` 并记录 |
| 绑定 22 报权限不足 | 查单元是否授予 `CAP_NET_BIND_SERVICE` | 保留 `AmbientCapabilities`，不要改成 root 运行 |
| journal 占用超限 | `journalctl --disk-usage` | 检查 `90-uptermd-limits.conf` 是否生效并执行 vacuum |

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
3. ~~不设置 `UPTERMD_AUTHORIZED_KEYS` 时，runner 反连注册是否确实无需服务器侧公钥登记；~~ 2026-11-09 实测通过：未设置该项时客户端用临时密钥成功注册并建立会话。设置空文件时是否拒绝所有宿主注册仍未验证。
4. WS 监听 8443 加 TLS 终止层的组合能否完成浏览器 `wss://` 连接；反向代理选型与证书轮换方式未定。
5. ~~指标名 `routing_active_connections_count` 在 v0.41.1 的实际输出格式与标签情况。~~ 2026-11-09 实测：v0.41.1 不存在该名字，实际为 `upterm_uptermd_sessions_active_count` 与 `upterm_uptermd_routing_authenticated_connections_count{kind=...}`；脚本已改为按候选名识别。
6. ~~重启后 `/run/uptermd` 确实为空、`/var/lib/uptermd` 无新增会话文件。~~ 2026-11-09 实测通过：重启后 `/run/uptermd` 为空，`/var/lib/uptermd` 仅有 `server_key` 与 `server_key.pub`。
7. ~~`systemctl show` 返回的 `MemoryMax`、`CPUQuotaPerSecUSec`、`TasksMax` 字面值与本脚本判定一致。~~ 2026-11-09 实测：实际字面值为 `1073741824`、`1.500000s`、`512`；脚本原判定只认 `1500000`/`1.5s`，已改为统一换算微秒后比较。
8. nftables 速率规则的默认阈值在真实流量下是否合适，是否误伤正常重连。
9. 打洞优先策略在自建 runner 或同 NAT 环境下是否可成功；托管 runner 只验中继分支。
10. 两个入口同时进入同一会话时，TUI 的实际可用性。

补充实测条件：Ubuntu 22.04.5 的 `journalctl --disk-usage` 在部署前为 416.1M，写入 `SystemMaxUse=200M` 并重启 journald 后不会立即压到上限，需按第 9 节执行一次 `journalctl --vacuum-size`；本机压到 144.0M 后健康检查通过。同日做了同机端到端会话（upterm host + ssh 访客）：建会话、访客执行命令、显式 stop 均成功；访客退出不会结束会话，需显式 stop；全程 `/run/uptermd` 与 `/var/lib/uptermd` 无新增文件，监听端口不变，停后 `sessions_active_count` 归零。

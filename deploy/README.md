# 中转端部署与运维手册

本目录只放中转端的部署资产, 不改动 `.github/workflows/ssh-debug.yml`。

一期链路是 runner 用 `action-upterm` 反连到自托管 `uptermd`, 访客凭 GitHub 账号 `itwuge` 的公钥进入 runner 的会话。中转机只做路由, 不持有访客凭据, 也不保存会话内容。

## 一、文件清单

| 文件 | 用途 |
|---|---|
| `install-uptermd.sh` | 幂等安装或升级 uptermd, 建用户与目录, 生成主机密钥, 写白名单占位, 环境文件, systemd 单元, journald 上限 |
| `uptermd.service` | systemd 单元模板, 参数全部来自 `/etc/uptermd/uptermd.env` |
| `firewall.sh` | ufw 或 nftables 规则, 默认演练, `--apply` 才落盘 |
| `rotate-relay-key.sh` | 轮换服务身份密钥, 产出 `UPTERM_RELAY_KNOWN_HOST` 变量内容, 支持回滚 |

## 二、前置条件

1. 服务器为 Ubuntu 20.04 及以上, 具备 root 权限, 可出网访问 GitHub Releases。
2. 云安全组放行 `22/tcp` 入站; 管理面端口只对运维固定来源放行。
3. 域名 `relay.wuge.fun` 的 A 记录指向该机公网地址。
4. 本机已装 `curl jq openssh-client`。
5. 明确 `authorized_keys` 白名单里要放哪把宿主公钥。**私钥只进 GitHub Secrets, 公钥才进白名单**。

## 三、部署步骤

### 3.1 先处理 22 端口归属

uptermd 要占 `22`, 系统 sshd 默认也在 `22`, 两者不能共存。二选一:

方案甲, 系统 sshd 迁到 `22022`:

```bash
# 先确认能通过云控制台 VNC 登录, 避免断线后无法回退
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i 's/^#\?Port .*/Port 22022/' /etc/ssh/sshd_config
sudo sshd -t
sudo systemctl restart ssh
ss -Hltn 'sport = :22022'
```

在新端口验证可登录后, 再让 uptermd 使用 `22`。云安全组同步放行 `22022`, 并只对运维来源放开。

方案乙, 系统 sshd 留在 `22`, uptermd 换到 `2222`:

```bash
sudo ./install-uptermd.sh --ssh-addr 0.0.0.0:2222
```

此时 workflow 的 `upterm-server` 必须改成 `ssh://relay.wuge.fun:2222`。云安全组与 DNS 不变, 改动面最小, 但对外端口不是 22。

### 3.2 安装

```bash
# 取发布包哈希, 建议从官方 release 页面手工核对后填入
curl -fsSL https://github.com/owenthereal/upterm/releases/download/v0.41.1/checksums.txt | grep uptermd_linux_amd64

sudo ./install-uptermd.sh \
  --version v0.41.1 \
  --sha256 '<上一步得到的 sha256>' \
  --ssh-addr 0.0.0.0:22
```

不加 `--sha256` 时脚本会回落到同版本 `checksums.txt`, 并在日志里记 WARNING 说明这只能发现传输损坏, 不构成真实性证明。

重复执行是安全的: 用户已存在、目录已存在、密钥已存在、文件内容一致时均跳过, 服务只在内容真的变化时重启。

### 3.3 填宿主公钥白名单

```bash
sudo tee -a /etc/uptermd/authorized_keys >/dev/null <<'EOF'
ssh-ed25519 AAAA...占位... actions-host@github
EOF
sudo systemctl restart uptermd.service
```

白名单为空时, 任何宿主都无法注册会话, 这是刻意的默认拒绝。

### 3.4 防火墙

```bash
# 演练, 只打印规则
sudo ./firewall.sh --backend ufw --admin-cidr 203.0.113.0/24

# 确认后应用
sudo ./firewall.sh --backend ufw --admin-cidr 203.0.113.0/24 --apply
```

- 未提供 `--admin-cidr` 且未加 `--allow-admin-anywhere` 时脚本拒绝执行, 防止把自己锁在门外。
- `--rate-limit-ssh` 会把 relay 端口改成 `ufw limit`, 对扫描有抑制作用。
- 指标端口只绑 `127.0.0.1:9100`, 规则里再显式 drop 一次作为纵深防御。
- 使用 nftables 后端时, 若 ufw 处于 active 状态会直接报错, 两者不可并存。

## 四、验证

```bash
# 1 服务与监听
systemctl status uptermd.service --no-pager
ss -Hltnp 'sport = :22'

# 2 环境文件与权限
sudo stat -c '%a %U:%G %n' /etc/uptermd/uptermd.env /etc/uptermd/authorized_keys /var/lib/uptermd/server_key
# 期望 640 root:upterm, 640 root:upterm, 600 upterm:upterm

# 3 指标
curl -fsS http://127.0.0.1:9100/metrics | head -n 40

# 4 日志里不该出现密钥材料
sudo journalctl -u uptermd.service --since '10 min ago' | grep -Ei 'private key|BEGIN OPENSSH|password' || echo 'no secret pattern'

# 5 主机密钥指纹
ssh-keygen -lf /var/lib/uptermd/server_key.pub
```

端到端验证需要触发一次 workflow, 并在日志里拿到 `ssh -p 22 <会话标识>@relay.wuge.fun` 形态的连接串。

## 五、主机密钥轮换

```bash
# 演练, 不改动服务
sudo ./rotate-relay-key.sh --host relay.wuge.fun --port 22

# 执行
sudo ./rotate-relay-key.sh --host relay.wuge.fun --port 22 --apply
```

脚本行为:

1. 读 `routing_active_connections_count`, 有活动会话就拒绝, `--force` 可越过。
2. 指标不可用同样拒绝, 因为无法确认是否有人在会话里。
3. 旧密钥归档到 `/var/lib/uptermd/archive/`, 私钥 `0600` 仅 root 可读。
4. 新密钥就位后重启服务, 未就绪则自动回滚并返回 6。
5. 输出形如下面的行, 复制进仓库变量 `UPTERM_RELAY_KNOWN_HOST`:

```text
@cert-authority [relay.wuge.fun]:22 ssh-ed25519 AAAA...占位...
```

轮换后必须同步更新 runner 侧 `known-hosts` 输入所引用的变量, 否则下一次作业会因主机密钥不匹配而失败。

回滚:

```bash
sudo ./rotate-relay-key.sh --rollback /var/lib/uptermd/archive/server_key.20260101T000000Z --apply
```

## 六、常见故障

### 6.1 端口冲突

现象: `install-uptermd.sh` 返回 9, 或 `systemctl status` 显示 `Address already in use`。

```bash
ss -Hltnp 'sport = :22'
systemctl status ssh --no-pager
```

处置: 按 3.1 迁移系统 sshd, 或改用 `--ssh-addr 0.0.0.0:2222` 并同步改 workflow。不要在 uptermd 运行中改 sshd 端口后直接重启 ssh, 那样会短暂同时占用或同时释放, 先停服务再改。

### 6.2 僵尸路由

现象: 作业已结束或 runner 被杀, 指标里活动连接数迟迟不归零, 旧会话标识仍显示存在。

```bash
curl -fsS http://127.0.0.1:9100/metrics | grep '^routing_'
```

处置顺序:

1. 先等一个 `ClientAlive` 级别的周期, 观察是否自然回收。
2. 确认没有真实用户在线后, 才滚动重启: `systemctl restart uptermd.service`。有活动会话时重启会打断所有人。
3. 若指标长期不归零且无真实会话, 记为缺陷, 附时间点与指标快照。

回收时限目前没有实测数据, 见第八节。

### 6.3 主机密钥或证书失效

现象: runner 日志报 `Host key verification failed` 或 `REMOTE HOST IDENTIFICATION HAS CHANGED`。

原因只有两种: 轮换后 runner 侧变量未更新, 或中转机密钥被替换。

```bash
ssh-keygen -lf /var/lib/uptermd/server_key.pub
```

处置: 比对变量里的公钥与当前指纹是否一致; 一致则清 runner 侧陈旧 known_hosts, 不一致则确认是否有人轮换过密钥, 再决定改变量还是回滚密钥。**不要用 `StrictHostKeyChecking=no` 绕过**。

### 6.4 服务起不来

```bash
systemctl status uptermd.service --no-pager
journalctl -u uptermd.service -n 100 --no-pager
```

按报错分三类: 环境文件缺失或格式错, 密钥文件权限不对, 监听地址被占。环境文件必须是 `root:upterm 0640`, 密钥必须是 `upterm:upterm 0600`。

### 6.5 日志或磁盘增长

```bash
journalctl --disk-usage
du -sh /var/log/uptermd-deploy
```

journald 已在安装时写入 `SystemMaxUse=200M` 的 drop-in。部署脚本每次运行生成一个 JSON Lines 文件, 位于 `/var/log/uptermd-deploy/logs/`, 按需保留。

## 七、回滚

| 场景 | 操作 |
|---|---|
| 升级后服务异常 | 用上一版本重新执行 `install-uptermd.sh --version <旧版本> --sha256 <旧哈希>` |
| 密钥需退回 | `rotate-relay-key.sh --rollback <归档路径> --apply` |
| 防火墙规则需撤销 | ufw: `ufw disable` 或 `ufw delete <规则>`; nftables: `nft delete table inet uptermd_guard` 并从 `/etc/nftables.conf` 删掉 include 行 |
| sshd 端口需退回 | 恢复 `/etc/ssh/sshd_config.bak` 后重启 ssh, 先停 uptermd 让出 22 |
| 完全卸载 | 停用并禁用 unit, 删 `/etc/systemd/system/uptermd.service`, 删 `/usr/local/bin/uptermd`, 删 `/etc/uptermd` 与 `/var/lib/uptermd`, 删 journald drop-in 后重启 journald |

## 八、必须在真机确认的点

以下内容未经实机验证, 部署时逐条确认并记录结果:

1. `uptermd` 的版本探测入口是 `--version` 还是 `version` 子命令; 脚本对两者都做了尝试, 需确认实际命中哪个。
2. `UPTERMD_PRIVATE_KEY` 指向的确实是 relay 对外出示的服务身份密钥, 且公钥行应写成 `@cert-authority` 形式。
3. `UPTERMD_SSH_NETWORK=tcp4` 在目标机是否只绑定 IPv4; 若需 IPv6 需改 `tcp`。
4. `--handshake-timeout` 在 60s 下, 成都中转与 GitHub runner 之间是否够用。
5. 作业被取消或 runner 被强杀后, 指标归零的实际耗时, 以及是否需要人工重启清理。
6. 会话期间 `/var/lib/uptermd` 与 `/tmp` 是否新增文件。
7. 原始运行日志与 job summary 中的连接串未被 `***` 掩码, 且不含任何密钥片段。
8. 3 Mbps 下 `make menuconfig` 的实际流畅度, 记录两段 RTT 与会话期间吞吐。
9. ufw 与云安全组规则叠加后, 管理面仍可从白名单来源登录。
10. journald drop-in 生效后, `journalctl --disk-usage` 稳定在 200M 以内。

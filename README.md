# Vaultwarden 一键部署

使用 Docker Compose 部署 Vaultwarden，并通过 Caddy 自动配置 HTTPS。安装脚本还会创建每日自动备份任务：先在服务器本地生成完整备份，再上传到固定的 rclone 目标 `d:data/bitwarden`，最后清理过期的远端备份。

> 本脚本只用于全新安装。它不会停止、删除、覆盖或迁移已有容器和数据。

## 系统要求

- Debian 或 Ubuntu
- root 权限
- 域名已经解析到服务器
- 云服务商安全组已放行 TCP 80、TCP 443 和 UDP 443
- rclone 中配置了名为 `d` 的远端；脚本不会保存或生成任何 rclone 密钥

## 安装

登录服务器后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/keepraw/bit/main/Bitwarden.sh \
  -o /root/Bitwarden.sh

chmod 700 /root/Bitwarden.sh
bash /root/Bitwarden.sh
```

按照提示输入：

- 域名，不要包含 `https://`
- 用于申请 HTTPS 证书的邮箱

也可以通过环境变量运行：

```bash
DOMAIN=vault.example.com \
ACME_EMAIL=admin@example.com \
SIGNUPS_ALLOWED=true \
LOCAL_RETENTION_DAYS=14 \
REMOTE_RETENTION_DAYS=14 \
bash /root/Bitwarden.sh
```

## 为什么使用 systemd timer，而不是 cron

本脚本使用 `systemd` 定时器。它比 cron 更适合这套部署：

- `Persistent=true`：服务器在 03:30 关机或重启，恢复运行后会补做错过的备份；
- 备份日志统一由 journal 保存；
- 可以直接查看任务状态、上次结果和下次运行时间；
- 服务与定时计划分开，手工测试和排错更清楚。

定时任务不是只写在安装脚本的注释里。安装时会真实创建：

```text
/usr/local/sbin/vaultwarden-backup.sh
/etc/default/vaultwarden-backup
/etc/systemd/system/vaultwarden-backup.service
/etc/systemd/system/vaultwarden-backup.timer
```

并执行：

```bash
systemctl enable --now vaultwarden-backup.timer
```

## 自动备份流程

每天服务器时间 **03:30**，`vaultwarden-backup.timer` 会启动备份服务：

1. 短暂停止 Vaultwarden 容器，保证数据库、附件和 Send 文件处于一致状态；
2. 生成本地完整备份：

   ```text
   /opt/vaultwarden/backups/vaultwarden-full-日期-时间.tar.gz
   ```

3. 立即重新启动 Vaultwarden；Caddy 不停止；
4. 使用 `rclone copyto` 上传到：

   ```text
   d:data/bitwarden
   ```

5. 使用 `rclone delete --min-age` 删除远端过期的 `vaultwarden-full-*.tar.gz`；
6. 删除本地过期备份。

不会生成或上传 SHA256 文件，也没有使用 `rclone sync`。

默认本地和远端都保留 14 天。可以在安装前通过环境变量修改，也可以安装后编辑：

```text
/etc/default/vaultwarden-backup
```

## 配置 rclone

查看现有远端：

```bash
rclone listremotes
```

正常应当包含：

```text
d:
```

没有时运行：

```bash
rclone config
```

脚本只硬编码远端路径 `d:data/bitwarden`，不会把访问密钥、令牌或 `rclone.conf` 写入 GitHub 文件。

## 测试自动备份

手工触发一次与定时任务完全相同的流程：

```bash
systemctl start vaultwarden-backup.service
```

查看结果：

```bash
systemctl status vaultwarden-backup.service --no-pager
journalctl -u vaultwarden-backup.service -n 100 --no-pager
```

查看本地备份：

```bash
ls -lh /opt/vaultwarden/backups/
```

查看远端备份：

```bash
rclone lsf d:data/bitwarden
```

查看定时器是否启用及下次执行时间：

```bash
systemctl status vaultwarden-backup.timer --no-pager
systemctl list-timers vaultwarden-backup.timer --all
```

## 手工执行备份脚本

也可以直接运行：

```bash
/usr/local/sbin/vaultwarden-backup.sh
```

它与 systemd 定时任务调用的是同一个文件，不存在“README 写了自动备份，但实际只留在安装脚本里”的情况。

## 安装后的目录

```text
/opt/vaultwarden/
├── .env
├── Caddyfile
├── compose.yaml
├── data/
├── backups/
├── caddy-data/
└── caddy-config/
```

备份包包含：

- `.env`
- `compose.yaml`
- `Caddyfile`
- 完整的 `data/`，包括数据库、附件、Send 和 RSA 密钥

Caddy 的证书缓存不放进备份；恢复后 Caddy 可以重新申请证书。

## 日常管理

查看容器：

```bash
cd /opt/vaultwarden
docker compose ps
```

查看日志：

```bash
cd /opt/vaultwarden
docker compose logs --tail 100
```

升级镜像：

```bash
cd /opt/vaultwarden
docker compose pull
docker compose up -d
```

创建首个账户后关闭注册：

```bash
sed -i 's/^SIGNUPS_ALLOWED=true$/SIGNUPS_ALLOWED=false/' /opt/vaultwarden/.env
cd /opt/vaultwarden
docker compose up -d
```

## 防火墙

使用 UFW 时：

```bash
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw enable
```

启用前必须确认 SSH 已放行，避免把自己锁在服务器外。

## 注意事项

- Web Vault 必须通过 HTTPS 使用；
- DNS 必须先正确解析到服务器；
- 云服务商安全组也要开放相应端口；
- 不要把 `.env`、数据库、附件、RSA 私钥、rclone 配置或完整备份提交到公开仓库；
- 本脚本只负责新装，不负责卸载和历史数据迁移。

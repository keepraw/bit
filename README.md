# Vaultwarden 一键部署

`Bitwarden.sh` 使用 Docker Compose 部署全新的 Vaultwarden 和 Caddy，并创建每日自动备份任务。

> Vaultwarden 是兼容 Bitwarden 客户端的第三方自托管服务端，并非 Bitwarden 官方服务端。

## 脚本边界

这是全新安装脚本，不负责清理、停止、删除或迁移已有部署。

遇到以下情况会直接退出：

- `/opt/vaultwarden` 已存在；
- 已存在 `vaultwarden` 或 `vaultwarden-caddy` 容器；
- TCP 80 或 443 端口已被占用。

旧环境清理和历史数据恢复应当手工完成。

## 部署内容

- Vaultwarden：`vaultwarden/server:latest`
- Caddy 自动 HTTPS
- Docker Compose
- rclone
- 每日 systemd 定时备份
- 默认安装目录：`/opt/vaultwarden`
- rclone 远端：`d:data/bitwarden`

脚本不会写入 rclone 密钥。服务器需要事先或部署后通过 `rclone config` 配置名为 `d` 的远端。

## 使用方法

确保域名已解析到服务器，并使用 root 登录。

```bash
curl -fsSL https://raw.githubusercontent.com/keepraw/bit/main/Bitwarden.sh \
  -o /root/Bitwarden.sh

chmod 700 /root/Bitwarden.sh
bash /root/Bitwarden.sh
```

脚本会询问：

1. 域名，只填写域名，不要填写 `https://`；
2. HTTPS 证书通知邮箱。

默认允许注册，以便创建第一个账户。

## 非交互安装

```bash
DOMAIN=vault.example.com \
ACME_EMAIL=admin@example.com \
SIGNUPS_ALLOWED=true \
INSTALL_DIR=/opt/vaultwarden \
bash /root/Bitwarden.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DOMAIN` | 运行时询问 | 域名，不带协议和路径 |
| `ACME_EMAIL` | 运行时询问 | HTTPS 证书通知邮箱 |
| `SIGNUPS_ALLOWED` | `true` | 是否允许新用户注册 |
| `INSTALL_DIR` | `/opt/vaultwarden` | 安装目录 |

## 自动备份

安装时会创建：

```text
/usr/local/sbin/vaultwarden-backup.sh
/etc/default/vaultwarden-backup
/etc/systemd/system/vaultwarden-backup.service
/etc/systemd/system/vaultwarden-backup.timer
```

每天服务器时间 03:30 执行：

1. 短暂停止 Vaultwarden，保证 SQLite 与附件一致；
2. 在 `/opt/vaultwarden/backups/` 生成完整压缩备份；
3. 立即重新启动 Vaultwarden；
4. 使用 `rclone copyto` 上传到 `d:data/bitwarden`；
5. 使用 `rclone delete --min-age` 删除远端过期备份；
6. 删除本地过期备份。

默认保留 14 天，只处理名称匹配以下格式的备份：

```text
vaultwarden-full-YYYYMMDD-HHMMSS.tar.gz
```

不使用 `rclone sync`，也不生成 SHA256 文件。

### 配置 rclone

查看现有远端：

```bash
rclone listremotes
```

应当包含：

```text
d:
```

未配置时运行：

```bash
rclone config
```

配置完成后启动定时器：

```bash
systemctl enable --now vaultwarden-backup.timer
```

### 检查定时器

```bash
systemctl status vaultwarden-backup.timer
systemctl list-timers vaultwarden-backup.timer
```

### 手工测试完整备份

```bash
systemctl start vaultwarden-backup.service
journalctl -u vaultwarden-backup.service -n 100 --no-pager
```

检查本地备份：

```bash
ls -lh /opt/vaultwarden/backups/
```

检查远端备份：

```bash
rclone lsf d:data/bitwarden
```

## 创建账户后关闭注册

```bash
cd /opt/vaultwarden
sed -i 's/^SIGNUPS_ALLOWED=true$/SIGNUPS_ALLOWED=false/' .env
docker compose up -d
```

## 常用命令

查看状态：

```bash
cd /opt/vaultwarden
docker compose ps
```

查看日志：

```bash
cd /opt/vaultwarden
docker compose logs -f --tail=100
```

更新：

```bash
cd /opt/vaultwarden
docker compose pull
docker compose up -d
docker image prune -f
```

## 目录结构

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

不要把 `.env`、数据库、附件、私钥、rclone 配置或备份提交到公开仓库。

# Vaultwarden 一键部署

`Bitwarden.sh` 用 Docker Compose 部署全新的 Vaultwarden 和 Caddy。Caddy 自动申请并续期 HTTPS 证书。

> Vaultwarden 是兼容 Bitwarden 客户端的第三方自托管服务端，并非 Bitwarden 官方服务端。

## 脚本边界

这是**全新安装脚本**，不会处理历史环境。

脚本不会停止、删除、重命名或迁移任何已有容器和数据。检测到以下情况时会直接退出：

- 安装目录已经存在；
- 已存在同名容器；
- 80 或 443 端口已被占用。

旧环境清理、数据库恢复和迁移应当手工完成，不应写进通用安装脚本。

## 支持环境

- Debian 或 Ubuntu
- root 权限
- 域名已经解析到服务器公网 IP
- 公网能够访问 TCP 80、TCP 443；HTTP/3 还需要 UDP 443

Docker 尚未安装时，脚本会通过 Docker 官方软件源安装 Docker Engine 和 Docker Compose 插件。

## 使用方法

上传脚本到服务器，例如：

curl -fsSL https://raw.githubusercontent.com/keepraw/bit/main/Bitwarden.sh -o /root/Bitwarden.sh \
  && chmod 700 /root/Bitwarden.sh \
  && /root/Bitwarden.sh

脚本会询问：

1. 域名，只填写域名，不要填写 `https://`；
2. HTTPS 证书通知邮箱。

默认安装目录：

```text
/opt/vaultwarden
```

默认允许注册，以便创建第一个账户。

## 非交互安装

可以通过环境变量传入参数：

```bash
DOMAIN=vault.example.com \
ACME_EMAIL=admin@example.com \
SIGNUPS_ALLOWED=true \
INSTALL_DIR=/opt/vaultwarden \
bash Bitwarden.sh
```

变量说明：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DOMAIN` | 运行时询问 | Vaultwarden 域名，不带协议和路径 |
| `ACME_EMAIL` | 运行时询问 | HTTPS 证书通知邮箱 |
| `SIGNUPS_ALLOWED` | `true` | 是否允许新用户注册，只接受 `true` 或 `false` |
| `INSTALL_DIR` | `/opt/vaultwarden` | 安装目录，必须使用绝对路径 |

## 创建账户后关闭注册

创建第一个账户后，建议关闭公开注册：

```bash
cd /opt/vaultwarden
sed -i 's/^SIGNUPS_ALLOWED=true$/SIGNUPS_ALLOWED=false/' .env
docker compose up -d
```

确认当前值：

```bash
grep '^SIGNUPS_ALLOWED=' /opt/vaultwarden/.env
```

## 常用命令

查看服务状态：

```bash
cd /opt/vaultwarden
docker compose ps
```

查看日志：

```bash
cd /opt/vaultwarden
docker compose logs -f --tail=100
```

更新镜像并重建容器：

```bash
cd /opt/vaultwarden
docker compose pull
docker compose up -d
docker image prune -f
```

停止服务：

```bash
cd /opt/vaultwarden
docker compose stop
```

重新启动：

```bash
cd /opt/vaultwarden
docker compose start
```

## 数据位置

Vaultwarden 数据：

```text
/opt/vaultwarden/data
```

Caddy 证书和运行数据：

```text
/opt/vaultwarden/caddy-data
/opt/vaultwarden/caddy-config
```

部署参数保存在：

```text
/opt/vaultwarden/.env
```

`.env` 权限默认设置为 `0600`。不要把真实 `.env` 提交到 GitHub。

## 数据库备份

先让 Vaultwarden 生成一致性的 SQLite 备份：

```bash
docker exec vaultwarden /vaultwarden backup
```

备份数据库会生成在：

```text
/opt/vaultwarden/data/db_日期_时间.sqlite3
```

数据库并不包含所有附件和 Send 文件。完整备份还应保存整个数据目录：

```bash
cd /opt/vaultwarden
docker compose stop
tar -C /opt -czf "/root/vaultwarden-full-$(date +%Y%m%d-%H%M%S).tar.gz" vaultwarden
docker compose start
```

## 防火墙

使用 UFW 时，可以开放 SSH、HTTP 和 HTTPS：

```bash
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw enable
```

启用防火墙前，务必确认 SSH 规则已经放行，避免把自己锁在服务器外。

## 目录结构

安装完成后：

```text
/opt/vaultwarden/
├── .env
├── Caddyfile
├── compose.yaml
├── data/
├── caddy-data/
└── caddy-config/
```

## 注意事项

- Web Vault 需要 HTTPS；
- DNS 必须先正确解析到服务器；
- 云服务商的安全组也要开放 80 和 443；
- 不要将 `.env`、数据库、附件、私钥或完整备份提交到公开仓库；
- 本脚本只负责新装，不负责卸载和历史数据迁移。

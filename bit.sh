#!/bin/bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg() {
echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
echo -e "${YELLOW}[WARN]${NC} $1"
}

err() {
echo -e "${RED}[ERROR]${NC} $1"
}

if [ "$(id -u)" != "0" ]; then
err "请使用 root 用户运行"
exit 1
fi

read -p "请输入域名（例如 bit.example.com）: " DOMAIN
read -p "请输入邮箱（用于 SSL）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
err "域名和邮箱不能为空"
exit 1
fi

msg "安装 Docker"

if ! command -v docker >/dev/null 2>&1; then
apt update
apt install -y ca-certificates curl gnupg lsb-release

```
mkdir -p /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
```

fi

msg "安装 rclone"

if ! command -v rclone >/dev/null 2>&1; then
curl https://rclone.org/install.sh | bash
fi

msg "创建部署目录"

mkdir -p /root/bit
cd /root/bit

msg "生成 docker-compose.yml"

cat > docker-compose.yml <<EOF
services:
vaultwarden:
image: vaultwarden/server:1.36.0
container_name: vaultwarden
restart: always
environment:
- DOMAIN=https://${DOMAIN}
- SIGNUPS_ALLOWED=false
volumes:
- /root/.config/bitwarden:/data

caddy:
image: caddy:2
container_name: caddy
restart: always
ports:
- 80:80
- 443:443
volumes:
- ./Caddyfile:/etc/caddy/Caddyfile:ro
- ./caddy-config:/config
- ./caddy-data:/data
environment:
- DOMAIN=${DOMAIN}
- EMAIL=${EMAIL}
EOF

msg "生成 Caddyfile"

cat > Caddyfile <<EOF
{$DOMAIN} {

```
encode gzip

tls {\$EMAIL}

reverse_proxy /notifications/hub vaultwarden:3012

reverse_proxy vaultwarden:80
```

}
EOF

msg "创建备份目录"

mkdir -p /root/.config/bitwarden
mkdir -p /root/.config/up
mkdir -p /root/.config/sh
mkdir -p /root/.config/rclone

msg "生成 rclone 配置模板"

cat > /root/.config/rclone/rclone.conf <<EOF
[bitwarden]
type = s3
provider = Other
access_key_id = your_access_key
secret_access_key = your_secret_key
endpoint = your_endpoint
region = auto
EOF

msg "生成备份脚本"

cat > /root/.config/sh/backup.sh <<'EOF'
#!/bin/bash

mkdir -p /root/.config/up

tar -czf /root/.config/up/bitwarden_$(date +%Y%m%d%H%M%S).tar.gz /root/.config/bitwarden

find /root/.config/up -mtime +30 -name "*.tar.gz" -delete

rclone sync /root/.config/up bitwarden:data/bitwarden
EOF

chmod +x /root/.config/sh/backup.sh

msg "添加定时备份"

(crontab -l 2>/dev/null; echo "0 3 * * * /root/.config/sh/backup.sh") | crontab -

msg "启动 Vaultwarden"

docker compose pull
docker compose up -d

sleep 5

msg "部署完成"

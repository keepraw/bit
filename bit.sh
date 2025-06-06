#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_message() {
    echo -e "${GREEN}[信息]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "请使用 root 用户运行此脚本！"
        exit 1
    fi
}

# 安装 Docker
install_docker() {
    print_message "开始安装 Docker..."
    
    # 检查是否已安装 Docker
    if command -v docker &> /dev/null; then
        print_message "Docker 已安装，跳过安装步骤。"
        return
    fi
    
    # 安装依赖
    print_message "安装必要的依赖..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    
    # 添加 Docker 官方 GPG 密钥
    print_message "添加 Docker 官方 GPG 密钥..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    
    # 添加 Docker 软件源
    print_message "添加 Docker 软件源..."
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    
    # 安装 Docker
    print_message "安装 Docker..."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # 启动 Docker 服务
    print_message "启动 Docker 服务..."
    systemctl start docker
    systemctl enable docker
    
    print_message "Docker 安装完成！"
}

# 安装 Docker Compose
install_docker_compose() {
    print_message "开始安装 Docker Compose..."
    
    # 检查是否已安装 Docker Compose
    if command -v docker-compose &> /dev/null; then
        print_message "Docker Compose 已安装，跳过安装步骤。"
        return
    fi
    
    # 下载 Docker Compose
    print_message "下载 Docker Compose..."
    curl -L "https://get.daocloud.io/docker/compose/releases/download/v2.10.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    
    # 添加执行权限
    print_message "添加执行权限..."
    chmod +x /usr/local/bin/docker-compose
    
    # 创建软链接
    print_message "创建软链接..."
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    print_message "Docker Compose 安装完成！"
}

# 安装 rclone
install_rclone() {
    print_message "开始安装 rclone..."
    
    # 检查是否已安装 rclone
    if command -v rclone &> /dev/null; then
        print_message "rclone 已安装，跳过安装步骤。"
        return
    fi
    
    # 安装 rclone
    print_message "下载并安装 rclone..."
    curl https://rclone.org/install.sh | bash
    
    print_message "rclone 安装完成！"
}

# 配置 rclone
configure_rclone() {
    print_message "配置 rclone..."
    
    # 创建配置目录
    mkdir -p ~/.config/rclone
    
    # 创建配置文件模板
    cat > ~/.config/rclone/rclone.conf << 'EOF'
# 请将以下内容替换为您的实际配置
[bitwarden]
type = your_storage_type    # 例如：s3、oss、cos等
account = your_account      # 您的账号
key = your_key             # 您的密钥
endpoint = your_endpoint    # 端点地址
EOF
    
    print_message "rclone 配置文件已创建，请编辑 ~/.config/rclone/rclone.conf 文件进行配置"
}

# 检查 Docker 是否安装
check_docker() {
    print_message "检查 Docker 安装状态..."
    if ! command -v docker &> /dev/null; then
        print_warning "Docker 未安装，将自动安装..."
        install_docker
    fi
    if ! command -v docker-compose &> /dev/null; then
        print_warning "Docker Compose 未安装，将自动安装..."
        install_docker_compose
    fi
    print_message "Docker 和 Docker Compose 已准备就绪。"
}

# 创建必要的目录和文件
setup_environment() {
    print_message "创建部署目录..."
    mkdir -p bit
    cd bit || exit 1
}

# 获取用户输入
get_user_input() {
    read -p "请输入您的域名（例如：bit.example.com）: " domain
    read -p "请输入您的邮箱地址（用于 SSL 证书）: " email
    
    # 验证输入
    if [[ -z "$domain" || -z "$email" ]]; then
        print_error "域名和邮箱不能为空！"
        exit 1
    fi
}

# 创建 docker-compose.yml
create_docker_compose() {
    print_message "创建 docker-compose.yml 文件..."
    cat > docker-compose.yml << EOF
version: '3'
  
services: 
  bitwarden: 
    image: vaultwarden/server:latest 
    container_name: bit 
    restart: always 
    environment: 
      - WEBSOCKET_ENABLED=true
    volumes: 
      - /root/.config/bit:/data 
  
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
      - DOMAIN=https://${domain}
      - EMAIL=${email}
      - LOG_FILE=/data/access.log 
EOF
}

# 创建 Caddyfile
create_caddyfile() {
    print_message "创建 Caddyfile..."
    cat > Caddyfile << EOF
{\$DOMAIN}:443 { 
  log { 
    level INFO 
    output file {\$LOG_FILE} { 
      roll_size 10MB 
      roll_keep 10 
    } 
  } 
  
  tls {\$EMAIL} 
  encode gzip 
  reverse_proxy /notifications/hub bitwarden:3012 
  reverse_proxy bitwarden:80 { 
    header_up X-Real-IP {remote_host} 
  } 
} 
EOF
}

# 创建备份脚本
create_backup_script() {
    print_message "创建备份脚本..."
    mkdir -p /root/.config/sh
    cat > /root/.config/sh/backup.sh << 'EOF'
#!/bin/bash
# 创建备份目录
mkdir -p /root/.config/up

# 创建本地备份
tar -czvPf /root/.config/up/bit_$(date +%Y%m%d%H%M%S).tar.gz /root/.config/bit

# 删除30天前的本地备份
find /root/.config/up -mtime +30 -name "*.tar.gz" -exec rm -rf {} \;

# 同步到远程存储
rclone sync /root/.config/up d:data/bitwarden
EOF

    chmod +x /root/.config/sh/backup.sh
    
    # 设置定时任务
    (crontab -l 2>/dev/null; echo "0 1 * * * /root/.config/sh/backup.sh") | crontab -
}

# 启动服务
start_services() {
    print_message "启动 Bitwarden 服务..."
    docker-compose up -d
    
    print_message "等待服务启动..."
    sleep 10
    
    # 检查服务状态
    if docker ps | grep -q "bit"; then
        print_message "Bitwarden 服务已成功启动！"
    else
        print_error "Bitwarden 服务启动失败，请检查日志。"
        exit 1
    fi
}

# 显示部署信息
show_deployment_info() {
    print_message "部署完成！"
    echo -e "\n${GREEN}部署信息：${NC}"
    echo "域名: https://${domain}"
    echo "备份脚本位置: /root/.config/sh/backup.sh"
    echo "本地备份目录: /root/.config/up"
    echo "远程备份目录: d:data/bitwarden"
    echo -e "\n${YELLOW}重要提示：${NC}"
    echo "1. 请确保您的域名已正确解析到服务器IP"
    echo "2. 首次访问时，请创建管理员账户"
    echo "3. 建议启用双因素认证"
    echo "4. 本地备份文件将保存在 /root/.config/up 目录下"
    echo "5. 远程备份将同步到 d:data/bitwarden 目录"
    echo "6. 定期检查本地和远程备份是否成功"
    echo "7. 建议定期测试备份文件的恢复"
    echo -e "\n${YELLOW}常用命令：${NC}"
    echo "查看服务状态: docker ps"
    echo "查看服务日志: docker logs bit"
    echo "停止服务: docker-compose down"
    echo "更新服务: docker-compose pull && docker-compose up -d"
    echo "手动执行备份: /root/.config/sh/backup.sh"
    echo "查看远程备份: rclone ls bitwarden:d:data/bitwarden"
}

# 主函数
main() {
    print_message "开始部署 Bitwarden..."
    
    # 检查 root 权限
    check_root
    
    # 检查并安装 Docker
    check_docker
    
    # 安装并配置 rclone
    install_rclone
    configure_rclone
    
    # 设置环境
    setup_environment
    
    # 获取用户输入
    get_user_input
    
    # 创建配置文件
    create_docker_compose
    create_caddyfile
    
    # 创建备份脚本
    create_backup_script
    
    # 启动服务
    start_services
    
    # 显示部署信息
    show_deployment_info
}

# 运行主函数
main 
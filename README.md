# Bitwarden 部署脚本

## 简介
这个仓库包含一个用于部署 Bitwarden 的脚本 `bit.sh`。该脚本自动化了 Bitwarden 的安装、配置和备份过程。

## 功能
- 安装 Docker 和 Docker Compose
- 安装和配置 rclone
- 创建 Bitwarden 的 Docker 容器
- 配置 Caddy 作为反向代理
- 自动备份 Bitwarden 数据

## 使用方法
1. 确保以 root 用户运行脚本。
2. 运行脚本：
###
```bash
curl -O https://raw.githubusercontent.com/your-repo/bit.sh && chmod +x bit.sh && ./bit.sh
```
3. 按照提示输入域名和邮箱地址。

## 配置
- 编辑 `~/.config/rclone/rclone.conf` 文件以配置 rclone。
- 备份脚本位于 `/root/.config/sh/backup.sh`，每天自动执行。

## 注意事项
- 确保域名已正确解析到服务器 IP。
- 首次访问时，请创建管理员账户。
- 建议启用双因素认证。

## 常用命令
- 查看服务状态：`docker ps`
- 查看服务日志：`docker logs bit`
- 停止服务：`docker-compose down`
- 更新服务：`docker-compose pull && docker-compose up -d`
- 手动执行备份：`/root/.config/sh/backup.sh`
- 查看远程备份：`rclone ls bitwarden:d:data/bitwarden` 
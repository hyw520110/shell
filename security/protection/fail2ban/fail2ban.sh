#!/bin/bash
# ==============================================================================
# Fail2Ban 一键脚本 - 安装/配置/管理
# 用法: ./fail2ban.sh <命令> [参数]
# 注意: 仅支持 Linux
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
JAIL_DIR="/etc/fail2ban/jail.d"

# 显示帮助
show_help() {
    echo -e "${BLUE}Fail2Ban 一键脚本 - 入侵防护${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "安装命令:"
    echo "  install             安装 Fail2Ban"
    echo "  config-ssh          配置 SSH 防护"
    echo "  config-nginx        配置 Nginx 防护"
    echo ""
    echo "服务管理:"
    echo "  start               启动服务"
    echo "  stop                停止服务"
    echo "  restart             重启服务"
    echo "  status              查看服务状态"
    echo ""
    echo "封禁管理:"
    echo "  banned [jail]       查看封禁 IP"
    echo "  ban <jail> <ip>     封禁 IP"
    echo "  unban <ip>          解封 IP"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 config-ssh"
    echo "  $0 status"
    echo "  $0 banned sshd"
    echo "  $0 ban sshd 192.168.1.100"
}

# 检查是否安装
check_installed() {
    command -v fail2ban-client &> /dev/null
}

# 检查服务
check_service() {
    systemctl is-active --quiet fail2ban 2>/dev/null
}

# 安装
cmd_install() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo -e "${RED}[错误] Fail2Ban 仅支持 Linux${NC}"
        exit 1
    fi
    
    if check_installed; then
        echo -e "${GREEN}[信息] Fail2Ban 已安装${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 安装 Fail2Ban...${NC}"
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y fail2ban
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y fail2ban
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y fail2ban
    fi
    
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    
    echo -e "${GREEN}[完成] Fail2Ban 安装成功${NC}"
}

# 配置 SSH 防护
cmd_config_ssh() {
    check_installed || { echo -e "${RED}[错误] Fail2Ban 未安装${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] 配置 SSH 防护...${NC}"
    
    local log_path="/var/log/auth.log"
    [ -f /var/log/secure ] && log_path="/var/log/secure"
    
    cat << EOF | sudo tee "$JAIL_DIR/sshd.local"
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $log_path
maxretry = 5
findtime = 300
bantime = 3600
bantime.increment = true
bantime.factor = 2
EOF
    
    sudo systemctl restart fail2ban
    echo -e "${GREEN}[完成] SSH 防护已配置${NC}"
}

# 配置 Nginx 防护
cmd_config_nginx() {
    check_installed || { echo -e "${RED}[错误] Fail2Ban 未安装${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] 配置 Nginx 防护...${NC}"
    
    cat << 'EOF' | sudo tee /etc/fail2ban/filter.d/nginx-bot.local
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*".*(404|403|500).*$
ignoreregex =
EOF
    
    cat << 'EOF' | sudo tee "$JAIL_DIR/nginx.local"
[nginx-bot]
enabled = true
port = http,https
filter = nginx-bot
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 60
bantime = 3600
EOF
    
    sudo systemctl restart fail2ban
    echo -e "${GREEN}[完成] Nginx 防护已配置${NC}"
}

# 服务管理
cmd_service() {
    check_installed || { echo -e "${RED}[错误] Fail2Ban 未安装${NC}"; exit 1; }
    
    local action="$1"
    sudo systemctl "$action" fail2ban
    echo -e "${GREEN}[完成] 服务已${action}${NC}"
}

# 查看状态
cmd_status() {
    check_installed || { echo -e "${RED}[错误] Fail2Ban 未安装${NC}"; exit 1; }
    check_service || { echo -e "${YELLOW}[警告] 服务未运行${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] Jail 状态:${NC}"
    sudo fail2ban-client status
}

# 封禁 IP
cmd_ban() {
    local jail="$1"
    local ip="$2"
    
    echo -e "${GREEN}[信息] 封禁 IP: $ip (jail: $jail)${NC}"
    sudo fail2ban-client set "$jail" banip "$ip"
    echo -e "${GREEN}[完成] IP 已封禁${NC}"
}

# 解封 IP
cmd_unban() {
    local ip="$1"
    
    echo -e "${GREEN}[信息] 解封 IP: $ip${NC}"
    for jail in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,//g'); do
        sudo fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null || true
    done
    echo -e "${GREEN}[完成] IP 已解封${NC}"
}

# 查看封禁列表
cmd_banned() {
    check_service || { echo -e "${YELLOW}[警告] 服务未运行${NC}"; exit 1; }
    
    local jail="${1:-}"
    
    echo -e "${GREEN}[信息] 封禁 IP 列表:${NC}"
    
    if [ -n "$jail" ]; then
        sudo fail2ban-client get "$jail" banip 2>/dev/null || echo "无封禁 IP"
    else
        for j in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,//g'); do
            local banned=$(sudo fail2ban-client get "$j" banip 2>/dev/null)
            [ -n "$banned" ] && echo -e "  ${YELLOW}$j${NC}: $banned"
        done
    fi
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    shift
    
    case "$cmd" in
        install) cmd_install ;;
        config-ssh) cmd_config_ssh ;;
        config-nginx) cmd_config_nginx ;;
        start|stop|restart) cmd_service "$cmd" ;;
        status) cmd_status ;;
        banned) cmd_banned "$@" ;;
        ban)
            [ $# -lt 2 ] && { echo -e "${RED}[错误] 用法: $0 ban <jail> <ip>${NC}"; exit 1; }
            cmd_ban "$1" "$2"
            ;;
        unban)
            [ $# -lt 1 ] && { echo -e "${RED}[错误] 用法: $0 unban <ip>${NC}"; exit 1; }
            cmd_unban "$1"
            ;;
        -h|--help) show_help ;;
        *)
            echo -e "${RED}[错误] 未知命令: $cmd${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

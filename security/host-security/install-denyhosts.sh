#!/bin/bash
# DenyHosts - SSH暴力破解防护工具
# 功能：自动阻止SSH暴力破解攻击的IP地址
# 官方文档：http://denyhosts.sourceforge.net/
# GitHub: https://github.com/denyhosts/denyhosts

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
DENYHOSTS_VERSION="3.1"
DENYHOSTS_INSTALL_DIR="/opt/denyhosts"
DENYHOSTS_CONFIG_FILE="/etc/denyhosts.conf"
DENYHOSTS_URL="https://github.com/denyhosts/denyhosts/archive/refs/tags/v${DENYHOSTS_VERSION}.tar.gz"

echo -e "${GREEN}=== DenyHosts SSH暴力破解防护工具 安装脚本 ===${NC}"

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
else
    OS=$(uname -s)
    OS_VERSION=$(uname -r)
fi

echo -e "${YELLOW}检测到操作系统: ${OS} ${OS_VERSION}${NC}"

# 检查是否已安装fail2ban
if command -v fail2ban-client &> /dev/null; then
    echo -e "${YELLOW}注意: 系统已安装Fail2ban，功能与DenyHosts类似${NC}"
    echo -e "${YELLOW}是否继续安装DenyHosts? (y/n)${NC}"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "安装已取消"
        exit 0
    fi
fi

# 根据操作系统选择安装方式
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${YELLOW}使用APT安装DenyHosts...${NC}"
    sudo apt-get update
    sudo apt-get install -y denyhosts
    
    DENYHOSTS_SERVICE="denyhosts"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装DenyHosts...${NC}"
    sudo yum install -y denyhosts
    
    DENYHOSTS_SERVICE="denyhosts"
    
else
    echo -e "${YELLOW}从源码编译安装DenyHosts...${NC}"
    
    # 检查Python环境
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}错误: 未找到Python 3${NC}"
        exit 1
    fi
    
    # 创建安装目录
    sudo mkdir -p ${DENYHOSTS_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/denyhosts"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "denyhosts-${DENYHOSTS_VERSION}.tar.gz" ]; then
        echo -e "${YELLOW}下载DenyHosts源码...${NC}"
        curl -fsSL -o denyhosts-${DENYHOSTS_VERSION}.tar.gz ${DENYHOSTS_URL}
    fi
    
    # 解压
    tar -xzf denyhosts-${DENYHOSTS_VERSION}.tar.gz
    cd denyhosts-${DENYHOSTS_VERSION}
    
    # 安装
    echo -e "${YELLOW}安装DenyHosts...${NC}"
    sudo python3 setup.py install --prefix=${DENYHOSTS_INSTALL_DIR}
    
    # 创建配置文件
    sudo tee ${DENYHOSTS_CONFIG_FILE} > /dev/null << 'EOF'
# DenyHosts配置文件

# SSH日志文件位置
SECURE_LOG = /var/log/auth.log

# hosts.deny文件位置
HOSTS_DENY = /etc/hosts.deny

# 允许的主机（不被阻止）
# ALLOWED_HOSTS_HOSTNAME_FILE = /etc/hosts.allow

# 阻止方式
BLOCK_SERVICE = sshd

# 纯阻止模式（不发送邮件）
# PURGE_DENY = 

# 失败次数阈值
DENY_THRESHOLD_INVALID = 5
DENY_THRESHOLD_VALID = 10
DENY_THRESHOLD_ROOT = 1
DENY_THRESHOLD_RESTRICTED = 1

# 工作目录
WORK_DIR = /var/lib/denyhosts

# 是否阻止IP
BLOCKED = true

# SMTP设置（如果需要邮件通知）
# SMTP_HOST = localhost
# SMTP_PORT = 25
# SMTP_FROM = DenyHosts <nobody@localhost>
# SMTP_SUBJECT = DenyHosts Report from $[HOSTNAME]
# SMTP_DATE_FORMAT = %a, %d %b %Y %H:%M:%S

# 管理员邮箱
# ADMIN_EMAIL = root@localhost

# 同步模式（0=不同步，1=同步到denyhosts.net）
# SYNC_SERVER = http://xmlrpc.denyhosts.net:9911
# SYNC_INTERVAL = 1h
# SYNC_UPLOAD = yes
# SYNC_DOWNLOAD = yes
EOF
    
    # 创建systemd服务文件
    sudo tee /etc/systemd/system/denyhosts.service > /dev/null << 'EOF'
[Unit]
Description=DenyHosts SSH brute force protection
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/denyhostsctl start
ExecStop=/usr/local/bin/denyhostsctl stop
ExecReload=/usr/local/bin/denyhostsctl restart
PIDFile=/var/run/denyhosts.pid

[Install]
WantedBy=multi-user.target
EOF
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
    
    DENYHOSTS_SERVICE="denyhosts"
fi

# 创建管理脚本
cat << 'EOF' | sudo tee /usr/local/bin/denyhosts-control > /dev/null
#!/bin/bash
# DenyHosts控制脚本

if command -v systemctl &> /dev/null; then
    if [ "$1" == "start" ]; then
        echo "启动DenyHosts..."
        sudo systemctl start denyhosts
    elif [ "$1" == "stop" ]; then
        echo "停止DenyHosts..."
        sudo systemctl stop denyhosts
    elif [ "$1" == "restart" ]; then
        echo "重启DenyHosts..."
        sudo systemctl restart denyhosts
    elif [ "$1" == "status" ]; then
        echo "DenyHosts状态:"
        sudo systemctl status denyhosts
    elif [ "$1" == "enable" ]; then
        echo "启用DenyHosts开机自启动..."
        sudo systemctl enable denyhosts
    elif [ "$1" == "disable" ]; then
        echo "禁用DenyHosts开机自启动..."
        sudo systemctl disable denyhosts
    else
        echo "用法: denyhosts-control {start|stop|restart|status|enable|disable}"
    fi
else
    # 使用service命令
    if [ "$1" == "start" ]; then
        echo "启动DenyHosts..."
        sudo service denyhosts start
    elif [ "$1" == "stop" ]; then
        echo "停止DenyHosts..."
        sudo service denyhosts stop
    elif [ "$1" == "restart" ]; then
        echo "重启DenyHosts..."
        sudo service denyhosts restart
    elif [ "$1" == "status" ]; then
        echo "DenyHosts状态:"
        sudo service denyhosts status
    else
        echo "用法: denyhosts-control {start|stop|restart|status}"
    fi
fi
EOF

sudo chmod +x /usr/local/bin/denyhosts-control

# 创建白名单管理脚本
cat << 'EOF' | sudo tee /usr/local/bin/denyhosts-whitelist > /dev/null
#!/bin/bash
# DenyHosts白名单管理

HOSTS_DENY="/etc/hosts.deny"
ALLOWED_IPS_FILE="/etc/denyhosts.allowed"

if [ "$1" == "add" ]; then
    # 添加IP到白名单
    IP=$2
    if [ -z "$IP" ]; then
        echo "用法: denyhosts-whitelist add <IP地址>"
        exit 1
    fi
    
    echo "添加IP $IP 到白名单..."
    echo "$IP" >> ${ALLOWED_IPS_FILE}
    
    # 从hosts.deny中移除
    if grep -q "$IP" ${HOSTS_DENY}; then
        sudo sed -i "/$IP/d" ${HOSTS_DENY}
        echo "已从阻止列表中移除"
    fi
    
    echo "添加成功"
    
elif [ "$1" == "remove" ]; then
    # 从白名单移除IP
    IP=$2
    if [ -z "$IP" ]; then
        echo "用法: denyhosts-whitelist remove <IP地址>"
        exit 1
    fi
    
    echo "从白名单移除IP $IP..."
    sudo sed -i "/$IP/d" ${ALLOWED_IPS_FILE}
    echo "移除成功"
    
elif [ "$1" == "list" ]; then
    # 列出白名单
    if [ -f ${ALLOWED_IPS_FILE} ]; then
        echo "白名单中的IP:"
        cat ${ALLOWED_IPS_FILE}
    else
        echo "白名单为空"
    fi
    
elif [ "$1" == "blocked" ]; then
    # 列出被阻止的IP
    echo "被阻止的IP:"
    grep -v "^#" ${HOSTS_DENY} | grep -v "^$" | grep -v "^ALL: PARANOID"
    
else
    echo "用法: denyhosts-whitelist {add|remove|list|blocked} [IP地址]"
    echo ""
    echo "示例:"
    echo "  denyhosts-whitelist add 192.168.1.100"
    echo "  denyhosts-whitelist remove 192.168.1.100"
    echo "  denyhosts-whitelist list"
    echo "  denyhosts-whitelist blocked"
fi
EOF

sudo chmod +x /usr/local/bin/denyhosts-whitelist

# 显示安装信息
echo -e "${GREEN}=== DenyHosts安装完成 ===${NC}"
echo -e "配置文件: ${DENYHOSTS_CONFIG_FILE}"
echo -e "服务名称: ${DENYHOSTS_SERVICE}"
echo ""
echo "常用命令:"
echo "  启动服务: denyhosts-control start"
echo "  停止服务: denyhosts-control stop"
echo "  重启服务: denyhosts-control restart"
echo "  查看状态: denyhosts-control status"
echo "  开机自启: denyhosts-control enable"
echo ""
echo "白名单管理:"
echo "  添加IP: denyhosts-whitelist add <IP>"
echo "  移除IP: denyhosts-whitelist remove <IP>"
echo "  列出白名单: denyhosts-whitelist list"
echo "  查看被阻止的IP: denyhosts-whitelist blocked"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove denyhosts"
echo "  yum: sudo yum remove denyhosts"
echo "  手动: sudo systemctl stop denyhosts && sudo systemctl disable denyhosts && sudo rm -rf ${DENYHOSTS_INSTALL_DIR} /usr/local/bin/denyhosts-*"
echo ""
echo -e "${YELLOW}提示: DenyHosts会自动监控SSH日志，阻止暴力破解攻击${NC}"
echo -e "${YELLOW}注意: 与Fail2ban功能类似，建议只使用其中一个${NC}"
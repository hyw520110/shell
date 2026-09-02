#!/bin/bash
# OSSEC - 开源主机入侵检测系统(HIDS)
# 功能：实时监控文件完整性、日志分析、恶意行为检测、策略监控
# 官方文档：https://www.ossec.net/
# GitHub: https://github.com/ossec/ossec-hids

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
OSSEC_VERSION="3.7.0"
OSSEC_INSTALL_DIR="/var/ossec"
OSSEC_CONFIG_FILE="/var/ossec/etc/ossec.conf"
OSSEC_URL="https://github.com/ossec/ossec-hids/archive/refs/tags/${OSSEC_VERSION}.tar.gz"

echo -e "${GREEN}=== OSSEC 主机入侵检测系统(HIDS) 安装脚本 ===${NC}"

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

# 根据操作系统选择安装方式
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${YELLOW}使用APT安装OSSEC...${NC}"
    sudo apt-get update
    sudo apt-get install -y ossec-hids-server
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装OSSEC...${NC}"
    sudo yum install -y ossec-hids-server
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Homebrew安装OSSEC...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}错误: 未找到Homebrew，请先安装Homebrew${NC}"
        exit 1
    fi
    
    brew install ossec-hids
    
else
    echo -e "${YELLOW}从源码编译安装OSSEC...${NC}"
    
    # 检查编译依赖
    for cmd in gcc make; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 未找到编译工具 $cmd${NC}"
            exit 1
        fi
    done
    
    # 安装依赖库
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sudo apt-get install -y build-essential libssl-dev libpcre3-dev zlib1g-dev
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        sudo yum install -y gcc make openssl-devel pcre-devel zlib-devel
    fi
    
    # 创建安装目录
    sudo mkdir -p ${OSSEC_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/ossec"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "ossec-${OSSEC_VERSION}.tar.gz" ]; then
        echo -e "${YELLOW}下载OSSEC源码...${NC}"
        curl -fsSL -o ossec-${OSSEC_VERSION}.tar.gz ${OSSEC_URL}
    fi
    
    # 解压
    tar -xzf ossec-${OSSEC_VERSION}.tar.gz
    cd ossec-hids-${OSSEC_VERSION}
    
    # 编译安装（非交互模式）
    echo -e "${YELLOW}编译安装OSSEC...${NC}"
    echo "server
/var/ossec
/var/ossec
/var/ossec/queue/audit
/var/ossec/queue/rids
no
yes
yes
no
localhost
yes
yes
no
no
yes
yes
yes
yes
" | sudo ./install.sh
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
fi

# 创建配置文件（如果不存在）
if [ ! -f "${OSSEC_CONFIG_FILE}" ]; then
    echo -e "${YELLOW}创建OSSEC配置文件...${NC}"
    sudo tee ${OSSEC_CONFIG_FILE} > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<ossec_config>
  <global>
    <email_notification>no</email_notification>
    <email_to>admin@example.com</email_to>
    <smtp_server>smtp.example.com</smtp_server>
    <email_from>ossec@example.com</email_from>
    <white_list>127.0.0.1</white_list>
    <white_list>^192.168.10.</white_list>
  </global>

  <rules>
    <rule id="550" level="0">
      <if_sid>550</if_sid>
      <category>authentication_success</category>
      <match>ssh</match>
      <description>SSH Authentication success.</description>
    </rule>
  </rules>

  <syscheck>
    <directories check_all="yes">/etc,/usr/bin,/usr/sbin</directories>
    <directories check_all="yes">/bin,/sbin</directories>
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/hosts.deny</ignore>
    <ignore>/etc/mail/statistics</ignore>
    <ignore>/etc/random-seed</ignore>
    <ignore>/etc/adjtime</ignore>
    <ignore>/etc/httpd/logs</ignore>
    <frequency>7200</frequency>
  </syscheck>

  <rootcheck>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/secure</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>

  <alerts>
    <log>yes</log>
    <mail>no</mail>
  </alerts>

  <command>
    <name>host-deny</name>
    <executable>host-deny.sh</executable>
    <expect>srcip</expect>
    <timeout_allowed>yes</timeout_allowed>
  </command>

  <active-responses>
    <command>host-deny</command>
    <location>local</location>
    <rules_id>5710,5720</rules_id>
    <timeout>600</timeout>
  </active-responses>
</ossec_config>
EOF
fi

# 创建启动/停止脚本
cat << 'EOF' | sudo tee /usr/local/bin/ossec-control > /dev/null
#!/bin/bash
# OSSEC控制脚本

OSSEC_DIR="/var/ossec"
OSSEC_BIN="${OSSEC_DIR}/bin/ossec-control"

if [ ! -f "${OSSEC_BIN}" ]; then
    echo "错误: OSSEC未安装"
    echo "请运行: install-ossec.sh"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动OSSEC..."
    sudo ${OSSEC_BIN} start
    
elif [ "$1" == "stop" ]; then
    echo "停止OSSEC..."
    sudo ${OSSEC_BIN} stop
    
elif [ "$1" == "restart" ]; then
    echo "重启OSSEC..."
    sudo ${OSSEC_BIN} restart
    
elif [ "$1" == "status" ]; then
    echo "OSSEC状态:"
    sudo ${OSSEC_BIN} status
    
elif [ "$1" == "help" ]; then
    echo "用法: ossec-control {start|stop|restart|status|help}"
    
else
    echo "用法: ossec-control {start|stop|restart|status|help}"
    exit 1
fi
EOF

sudo chmod +x /usr/local/bin/ossec-control

# 创建日志查看脚本
cat << 'EOF' | sudo tee /usr/local/bin/ossec-log > /dev/null
#!/bin/bash
# OSSEC日志查看脚本

OSSEC_LOG="/var/ossec/logs/alerts/alerts.log"

if [ ! -f "${OSSEC_LOG}" ]; then
    echo "错误: OSSEC日志文件不存在: ${OSSEC_LOG}"
    exit 1
fi

if [ "$1" == "--tail" ]; then
    # 实时查看日志
    tail -f ${OSSEC_LOG}
elif [ "$1" == "--today" ]; then
    # 查看今天的日志
    grep "$(date +%b\ %d)" ${OSSEC_LOG} | less
elif [ "$1" == "--alert" ]; then
    # 只查看告警
    grep -E "(level [5-9]|level 1[0-2])" ${OSSEC_LOG} | less
elif [ "$1" == "--high" ]; then
    # 只查看高优先级告警
    grep -E "(level 1[0-2])" ${OSSEC_LOG} | less
else
    # 查看最近100条日志
    tail -n 100 ${OSSEC_LOG}
fi
EOF

sudo chmod +x /usr/local/bin/ossec-log

# 创建管理脚本
cat << 'EOF' | sudo tee /usr/local/bin/ossec-manage > /dev/null
#!/bin/bash
# OSSEC管理脚本

OSSEC_DIR="/var/ossec"
OSSEC_BIN="${OSSEC_DIR}/bin/manage_agents"

if [ "$1" == "list" ]; then
    echo "已注册的代理:"
    sudo ${OSSEC_BIN} -l
    
elif [ "$1" == "add" ]; then
    echo "添加新代理:"
    sudo ${OSSEC_BIN} -a
    
elif [ "$1" == "remove" ]; then
    echo "删除代理:"
    sudo ${OSSEC_BIN} -r
    
elif [ "$1" == "import" ]; then
    echo "导入代理密钥:"
    sudo ${OSSEC_BIN} -i
    
else
    echo "用法: ossec-manage {list|add|remove|import}"
fi
EOF

sudo chmod +x /usr/local/bin/ossec-manage

# 配置开机自启动
if command -v systemctl &> /dev/null; then
    echo -e "${YELLOW}配置systemd开机自启动...${NC}"
    sudo systemctl enable ossec
fi

# 显示安装信息
echo -e "${GREEN}=== OSSEC安装完成 ===${NC}"
echo -e "安装目录: ${OSSEC_INSTALL_DIR}"
echo -e "配置文件: ${OSSEC_CONFIG_FILE}"
echo -e "日志目录: ${OSSEC_INSTALL_DIR}/logs/"
echo ""
echo "常用命令:"
echo "  启动OSSEC: ossec-control start"
echo "  停止OSSEC: ossec-control stop"
echo "  重启OSSEC: ossec-control restart"
echo "  查看状态: ossec-control status"
echo "  查看日志: ossec-log [--tail|--today|--alert|--high]"
echo "  管理代理: ossec-manage {list|add|remove|import}"
echo ""
echo "Web界面(需安装):"
echo "  OSSEC Web UI: https://github.com/ossec/ossec-wui"
echo "  Anaconda: https://github.com/ossec/anaconda"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove ossec-hids-server"
echo "  yum: sudo yum remove ossec-hids-server"
echo "  手动: sudo rm -rf ${OSSEC_INSTALL_DIR} /usr/local/bin/ossec-*"
echo ""
echo -e "${YELLOW}提示: 首次启动后会自动进行文件完整性检查，建议在系统稳定时启动${NC}"
echo -e "${YELLOW}建议: 定期检查日志，关注高优先级告警${NC}"
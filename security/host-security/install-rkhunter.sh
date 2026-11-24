#!/bin/bash
# RKhunter (Rootkit Hunter) - Rootkit检测工具
# 功能：检测系统中的rootkit、后门、本地漏洞
# 官方文档：http://rkhunter.sourceforge.net/
# GitHub: https://github.com/rootkithunter/rkhunter

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
RKHUNTER_VERSION="1.4.6"
RKHUNTER_INSTALL_DIR="/opt/rkhunter"
RKHUNTER_CONFIG_FILE="/etc/rkhunter.conf"
RKHUNTER_URL="https://sourceforge.net/projects/rkhunter/files/rkhunter/${RKHUNTER_VERSION}/rkhunter-${RKHUNTER_VERSION}.tar.gz/download"

echo -e "${GREEN}=== RKhunter Rootkit检测工具 安装脚本 ===${NC}"

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
    echo -e "${YELLOW}使用APT安装RKhunter...${NC}"
    sudo apt-get update
    sudo apt-get install -y rkhunter
    
    RKHUNTER_BIN="/usr/bin/rkhunter"
    RKHUNTER_CONFIG="/etc/rkhunter.conf"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装RKhunter...${NC}"
    sudo yum install -y rkhunter
    
    RKHUNTER_BIN="/usr/bin/rkhunter"
    RKHUNTER_CONFIG="/etc/rkhunter.conf"
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Homebrew安装RKhunter...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}错误: 未找到Homebrew，请先安装Homebrew${NC}"
        exit 1
    fi
    
    brew install rkhunter
    
    RKHUNTER_BIN="/usr/local/bin/rkhunter"
    RKHUNTER_CONFIG="/usr/local/etc/rkhunter.conf"
    
else
    echo -e "${YELLOW}从源码编译安装RKhunter...${NC}"
    
    # 检查必要工具
    for cmd in wget perl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 未找到 $cmd${NC}"
            exit 1
        fi
    done
    
    # 创建安装目录
    sudo mkdir -p ${RKHUNTER_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/rkhunter"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "rkhunter-${RKHUNTER_VERSION}.tar.gz" ]; then
        echo -e "${YELLOW}下载RKhunter源码...${NC}"
        curl -fsSL -L -o rkhunter-${RKHUNTER_VERSION}.tar.gz ${RKHUNTER_URL}
    fi
    
    # 解压
    tar -xzf rkhunter-${RKHUNTER_VERSION}.tar.gz
    cd rkhunter-${RKHUNTER_VERSION}
    
    # 编译安装
    echo -e "${YELLOW}编译安装RKhunter...${NC}"
    sudo ./installer.sh --layout default --install
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
    
    RKHUNTER_BIN="/usr/local/bin/rkhunter"
    RKHUNTER_CONFIG="/etc/rkhunter.conf"
fi

# 更新数据库
echo -e "${YELLOW}更新RKhunter数据库...${NC}"
sudo ${RKHUNTER_BIN} --update
sudo ${RKHUNTER_BIN} --propupd

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/rkhunter-check > /dev/null
#!/bin/bash
# RKhunter检查脚本

RKHUNTER_BIN="/usr/bin/rkhunter"
if [ ! -f "${RKHUNTER_BIN}" ]; then
    RKHUNTER_BIN="/usr/local/bin/rkhunter"
fi

if [ ! -f "${RKHUNTER_BIN}" ]; then
    echo "错误: RKhunter未安装"
    echo "请运行: install-rkhunter.sh"
    exit 1
fi

if [ "$1" == "--full" ]; then
    echo "=== RKhunter完整检查 ==="
    echo "开始时间: $(date)"
    echo ""
    
    # 完整扫描，包含所有测试
    sudo ${RKHUNTER_BIN} --check --skip-keypress --rwo
    
    echo ""
    echo "完成时间: $(date)"
    
elif [ "$1" == "--quick" ]; then
    echo "=== RKhunter快速检查 ==="
    echo "开始时间: $(date)"
    echo ""
    
    # 快速扫描，只进行基本测试
    sudo ${RKHUNTER_BIN} --check --skip-keypress --rwo --report-warnings-only
    
    echo ""
    echo "完成时间: $(date)"
    
elif [ "$1" == "--update" ]; then
    echo "=== 更新RKhunter数据库 ==="
    sudo ${RKHUNTER_BIN} --update
    sudo ${RKHUNTER_BIN} --propupd
    
elif [ "$1" == "--cronjob" ]; then
    # 定时任务模式，生成报告
    REPORT_DIR="/var/log/rkhunter"
    mkdir -p ${REPORT_DIR}
    
    REPORT_FILE="${REPORT_DIR}/report_$(date +%Y%m%d_%H%M%S).log"
    CRON_LOG="${REPORT_DIR}/cron_$(date +%Y%m%d).log"
    
    echo "=== RKhunter定时检查 ===" | tee ${CRON_LOG}
    echo "开始时间: $(date)" | tee -a ${CRON_LOG}
    echo "" | tee -a ${CRON_LOG}
    
    # 更新数据库
    echo "更新数据库..." | tee -a ${CRON_LOG}
    sudo ${RKHUNTER_BIN} --update >> ${CRON_LOG} 2>&1
    sudo ${RKHUNTER_BIN} --propupd >> ${CRON_LOG} 2>&1
    
    # 运行检查
    echo "运行检查..." | tee -a ${CRON_LOG}
    sudo ${RKHUNTER_BIN} --check --skip-keypress --cronjob --report-warnings-only > ${REPORT_FILE} 2>&1
    
    echo "" | tee -a ${CRON_LOG}
    echo "完成时间: $(date)" | tee -a ${CRON_LOG}
    echo "报告文件: ${REPORT_FILE}" | tee -a ${CRON_LOG}
    
    # 如果有警告，发送邮件
    if [ -s ${REPORT_FILE} ]; then
        echo "发现警告，发送报告邮件..."
        mail -s "[RKhunter] 安全检查报告 - $(hostname)" root < ${REPORT_FILE}
    fi
    
else
    echo "用法: rkhunter-check [选项]"
    echo ""
    echo "选项:"
    echo "  --full      完整检查（所有测试）"
    echo "  --quick     快速检查（基本测试）"
    echo "  --update    更新数据库"
    echo "  --cronjob   定时任务模式"
    echo ""
    echo "示例:"
    echo "  rkhunter-check --full"
    echo "  rkhunter-check --quick"
    echo "  rkhunter-check --update"
fi
EOF

sudo chmod +x /usr/local/bin/rkhunter-check

# 创建配置优化脚本
cat << 'EOF' | sudo tee /usr/local/bin/rkhunter-config > /dev/null
#!/bin/bash
# RKhunter配置优化脚本

RKHUNTER_CONFIG="/etc/rkhunter.conf"

if [ ! -f "${RKHUNTER_CONFIG}" ]; then
    echo "错误: RKhunter配置文件不存在: ${RKHUNTER_CONFIG}"
    exit 1
fi

echo "=== RKhunter配置优化 ==="
echo "将根据系统自动配置RKhunter..."
echo ""

# 备份原配置
sudo cp ${RKHUNTER_CONFIG} ${RKHUNTER_CONFIG}.backup.$(date +%Y%m%d)

# 获取系统信息
OS=$(uname -s)
OS_RELEASE=$(cat /etc/os-release 2>/dev/null | grep VERSION_ID | cut -d'"' -f2)

# 优化配置
echo "应用优化配置..."

# 启用邮件通知（如果系统有邮件服务）
if command -v mail &> /dev/null; then
    echo "启用邮件通知..."
    sudo sed -i 's|^#MAIL-ON-WARNING=.*|MAIL-ON-WARNING=root@localhost|' ${RKHUNTER_CONFIG}
fi

# 设置数据库更新服务器
sudo sed -i 's|^#UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' ${RKHUNTER_CONFIG}
sudo sed -i 's|^#MIRRORS_MODE=.*|MIRRORS_MODE=0|' ${RKHUNTER_CONFIG}

# 设置日志文件
sudo sed -i 's|^#LOGFILE=.*|LOGFILE=/var/log/rkhunter.log|' ${RKHUNTER_CONFIG}

# 禁用一些误报较多的检查
sudo sed -i 's|^#DISABLE_TESTS=.*|DISABLE_TESTS="suspscan hidden_procs deleted_files packet_cap_apps"|' ${RKHUNTER_CONFIG}

# 启用白名单模式
sudo sed -i 's|^#ALLOW_SSH_ROOT_USER=.*|ALLOW_SSH_ROOT_USER=no|' ${RKHUNTER_CONFIG}

# 设置扫描间隔
sudo sed -i 's|^#RUN_CHECK_ON_BATTERY=.*|RUN_CHECK_ON_BATTERY=0|' ${RKHUNTER_CONFIG}

echo "配置优化完成"
echo "原配置已备份到: ${RKHUNTER_CONFIG}.backup.$(date +%Y%m%d)"
EOF

sudo chmod +x /usr/local/bin/rkhunter-config

# 创建定时任务模板
cat << 'EOF' > /tmp/rkhunter-cron.sh
#!/bin/bash
# RKhunter定时检查脚本
# 使用方法: 添加到crontab中

# 每天凌晨3点检查: 0 3 * * * /path/to/rkhunter-daily.sh

LOG_DIR="/var/log/rkhunter"
EMAIL="admin@example.com"  # 修改为你的邮箱

# 运行检查
rkhunter-check --cronjob

# 如果检查失败，发送邮件
if [ $? -ne 0 ]; then
    tail -n 50 ${LOG_DIR}/cron_$(date +%Y%m%d).log | mail -s "[RKhunter] 检查失败 - $(hostname)" ${EMAIL}
fi
EOF

# 显示安装信息
echo -e "${GREEN}=== RKhunter安装完成 ===${NC}"
echo -e "可执行文件: ${RKHUNTER_BIN}"
echo -e "配置文件: ${RKHUNTER_CONFIG}"
echo -e "日志目录: /var/log/rkhunter/"
echo ""
echo "常用命令:"
echo "  快速检查: rkhunter-check --quick"
echo "  完整检查: rkhunter-check --full"
echo "  更新数据库: rkhunter-check --update"
echo "  优化配置: rkhunter-config"
echo ""
echo "定时检查:"
echo "  编辑crontab: crontab -e"
echo "  添加: 0 3 * * * rkhunter-check --cronjob"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove rkhunter"
echo "  yum: sudo yum remove rkhunter"
echo "  brew: brew uninstall rkhunter"
echo "  手动: sudo rm -rf ${RKHUNTER_INSTALL_DIR} /usr/local/bin/rkhunter-*"
echo ""
echo -e "${YELLOW}提示: 首次运行 --check 前建议先运行 --update 更新数据库${NC}"
echo -e "${YELLOW}建议: 定期运行检查，特别是系统更新后${NC}"
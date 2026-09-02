#!/bin/bash
# AIDE (Advanced Intrusion Detection Environment) - 文件完整性检查工具
# 功能：监控文件系统变更，检测未授权的文件修改
# 官方文档：http://aide.sourceforge.net/

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
AIDE_VERSION="0.18"
AIDE_INSTALL_DIR="/opt/aide"
AIDE_CONFIG_FILE="/etc/aide.conf"
AIDE_DB_DIR="/var/lib/aide"
AIDE_LOG_DIR="/var/log/aide"
AIDE_URL="https://github.com/aide/aide/releases/download/v${AIDE_VERSION}/aide-${AIDE_VERSION}.tar.gz"

echo -e "${GREEN}=== AIDE 文件完整性检查工具 安装脚本 ===${NC}"

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
    echo -e "${YELLOW}使用APT安装AIDE...${NC}"
    sudo apt-get update
    sudo apt-get install -y aide aide-common
    
    AIDE_BIN="/usr/bin/aide"
    AIDE_CONFIG="/etc/aide/aide.conf"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装AIDE...${NC}"
    sudo yum install -y aide
    
    AIDE_BIN="/usr/bin/aide"
    AIDE_CONFIG="/etc/aide.conf"
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Homebrew安装AIDE...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}错误: 未找到Homebrew，请先安装Homebrew${NC}"
        echo "安装命令: /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    
    brew install aide
    
    AIDE_BIN="/usr/local/bin/aide"
    AIDE_CONFIG="/usr/local/etc/aide.conf"
    
else
    echo -e "${YELLOW}未知系统，从源码编译安装AIDE...${NC}"
    
    # 检查编译依赖
    for cmd in gcc make; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 未找到编译工具 $cmd${NC}"
            exit 1
        fi
    done
    
    # 安装依赖库
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sudo apt-get install -y libpcre3-dev libmhash-dev libconfig-dev
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        sudo yum install -y pcre-devel mhash-devel libconfig-devel
    fi
    
    # 创建安装目录
    sudo mkdir -p ${AIDE_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/aide"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "aide-${AIDE_VERSION}.tar.gz" ]; then
        echo -e "${YELLOW}下载AIDE源码...${NC}"
        curl -fsSL -o aide-${AIDE_VERSION}.tar.gz ${AIDE_URL}
    fi
    
    # 解压
    tar -xzf aide-${AIDE_VERSION}.tar.gz
    cd aide-${AIDE_VERSION}
    
    # 编译安装
    echo -e "${YELLOW}编译安装AIDE...${NC}"
    ./configure --prefix=${AIDE_INSTALL_DIR}
    make
    sudo make install
    
    AIDE_BIN="${AIDE_INSTALL_DIR}/bin/aide"
    AIDE_CONFIG="${AIDE_INSTALL_DIR}/etc/aide.conf"
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
fi

# 创建数据库和日志目录
sudo mkdir -p ${AIDE_DB_DIR}
sudo mkdir -p ${AIDE_LOG_DIR}
sudo chmod 700 ${AIDE_DB_DIR}
sudo chmod 700 ${AIDE_LOG_DIR}

# 创建配置文件
if [ ! -f "${AIDE_CONFIG}" ]; then
    echo -e "${YELLOW}创建AIDE配置文件...${NC}"
    sudo tee ${AIDE_CONFIG} > /dev/null << 'EOF'
# AIDE配置文件
# 参考: http://aide.sourceforge.net/stable/manual.html

# 数据库配置
database=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new

# 日志配置
logfile=/var/log/aide/aide.log
verbose=20
report_url=stdout

# 默认规则
All=p+i+n+u+g+s+m+c+md5+sha1
# 只监控权限和inode
Norm=p+i+n+u+g+s+m+c+md5
# 不监控文件大小
NoSize=p+i+n+u+g+s+c+md5
# 不监控修改时间
NoTime=p+i+n+u+g+s+m+md5

# 重要的系统目录
/bin All
/sbin All
/usr/bin All
/usr/sbin All
/usr/local/bin All
/usr/local/sbin All
/lib All
/usr/lib All
/lib64 All
/usr/lib64 All

# 重要配置文件
/etc Norm
/etc/passwd All
/etc/shadow All
/etc/group All
/etc/gshadow All
/etc/sudoers All

# 系统启动文件
/boot All
/etc/init.d Norm
/etc/systemd/system Norm

# Web服务器配置（如果存在）
!/var/www/html/.*
!/var/log/.*
!/var/tmp/.*
!/tmp/.*
!/proc/.*
!/sys/.*
!/dev/.*

# 排除变化频繁的文件
/var/log Norm
/var/run Norm
/var/lock Norm
EOF
fi

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/aide-init > /dev/null
#!/bin/bash
# AIDE初始化脚本 - 创建初始数据库

AIDE_CONFIG="/etc/aide.conf"
AIDE_DB_DIR="/var/lib/aide"

if [ ! -f "${AIDE_CONFIG}" ]; then
    echo "错误: AIDE配置文件不存在: ${AIDE_CONFIG}"
    exit 1
fi

echo "=== AIDE初始化 - 创建基准数据库 ==="
echo "这将扫描整个文件系统，可能需要较长时间..."
echo ""

# 初始化数据库
sudo aide --init --config ${AIDE_CONFIG}

# 将新数据库移动为当前数据库
if [ -f "${AIDE_DB_DIR}/aide.db.new" ]; then
    sudo mv ${AIDE_DB_DIR}/aide.db.new ${AIDE_DB_DIR}/aide.db
    echo "基准数据库已创建: ${AIDE_DB_DIR}/aide.db"
    echo "现在可以使用 'aide-check' 检查文件变更"
else
    echo "错误: 数据库初始化失败"
    exit 1
fi
EOF

sudo chmod +x /usr/local/bin/aide-init

cat << 'EOF' | sudo tee /usr/local/bin/aide-check > /dev/null
#!/bin/bash
# AIDE检查脚本 - 检测文件变更

AIDE_CONFIG="/etc/aide.conf"
AIDE_LOG_DIR="/var/log/aide"
AIDE_DB_DIR="/var/lib/aide"

if [ ! -f "${AIDE_DB_DIR}/aide.db" ]; then
    echo "错误: AIDE数据库不存在"
    echo "请先运行: aide-init"
    exit 1
fi

echo "=== AIDE文件完整性检查 ==="
echo "检查时间: $(date)"
echo ""

# 运行检查
if [ "$1" == "--update" ]; then
    echo "更新数据库模式..."
    sudo aide --update --config ${AIDE_CONFIG}
    
    if [ -f "${AIDE_DB_DIR}/aide.db.new" ]; then
        sudo mv ${AIDE_DB_DIR}/aide.db.new ${AIDE_DB_DIR}/aide.db
        echo "数据库已更新"
    fi
else
    # 检查并生成报告
    REPORT_FILE="${AIDE_LOG_DIR}/report_$(date +%Y%m%d_%H%M%S).txt"
    sudo aide --check --config ${AIDE_CONFIG} | tee ${REPORT_FILE}
    
    # 检查结果
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo ""
        echo -e "\033[0;31m警告: 检测到文件变更!\033[0m"
        echo "报告已保存: ${REPORT_FILE}"
        echo ""
        echo "如果变更是预期的，请运行: aide-check --update"
    else
        echo ""
        echo -e "\033[0;32m未检测到文件变更\033[0m"
    fi
fi
EOF

sudo chmod +x /usr/local/bin/aide-check

# 创建定时任务模板
cat << 'EOF' > /tmp/aide-cron.sh
#!/bin/bash
# AIDE定时检查脚本
# 使用方法: 将此脚本添加到crontab中
# 每天凌晨2点检查: 0 2 * * * /path/to/aide-daily.sh

REPORT_DIR="/var/log/aide"
EMAIL="admin@example.com"  # 修改为你的邮箱

# 运行检查
if aide-check 2>&1 | tee ${REPORT_DIR}/check_$(date +%Y%m%d).log; then
    # 未检测到变更
    exit 0
else
    # 检测到变更，发送邮件
    mail -s "[AIDE] 文件完整性警告 - $(hostname)" ${EMAIL} < ${REPORT_DIR}/check_$(date +%Y%m%d).log
    exit 1
fi
EOF

# 显示安装信息
echo -e "${GREEN}=== AIDE安装完成 ===${NC}"
echo -e "配置文件: ${AIDE_CONFIG}"
echo -e "数据库目录: ${AIDE_DB_DIR}"
echo -e "日志目录: ${AIDE_LOG_DIR}"
echo ""
echo "使用步骤:"
echo "  1. 初始化数据库: aide-init"
echo "  2. 检查文件变更: aide-check"
echo "  3. 更新数据库: aide-check --update"
echo ""
echo "定时检查:"
echo "  编辑crontab: crontab -e"
echo "  添加: 0 2 * * * aide-check"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove aide"
echo "  yum: sudo yum remove aide"
echo "  brew: brew uninstall aide"
echo "  手动: sudo rm -rf ${AIDE_INSTALL_DIR} ${AIDE_DB_DIR} ${AIDE_LOG_DIR} /usr/local/bin/aide-*"
echo ""
echo -e "${YELLOW}提示: 首次初始化需要扫描整个文件系统，可能需要较长时间${NC}"
echo -e "${YELLOW}建议: 在系统重大变更（如软件安装）后运行 aide-check --update 更新基准数据库${NC}"
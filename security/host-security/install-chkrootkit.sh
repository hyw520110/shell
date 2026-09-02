#!/bin/bash
# Chkrootkit - Linux Rootkit检测工具
# 功能：检测系统中的rootkit和木马
# 官方文档：http://www.chkrootkit.org/

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
CHKROOTKIT_VERSION="0.55"
CHKROOTKIT_INSTALL_DIR="/opt/chkrootkit"
CHKROOTKIT_URL="ftp://ftp.pangeia.com.br/pub/seg/pac/chkrootkit.tar.gz"

echo -e "${GREEN}=== Chkrootkit Rootkit检测工具 安装脚本 ===${NC}"

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

# Chkrootkit主要是Linux工具
if [[ "$OS" != "linux" ]]; then
    echo -e "${YELLOW}警告: Chkrootkit主要用于Linux系统${NC}"
    echo -e "${YELLOW}在${OS}上可能无法正常运行${NC}"
fi

# 根据操作系统选择安装方式
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${YELLOW}使用APT安装Chkrootkit...${NC}"
    sudo apt-get update
    sudo apt-get install -y chkrootkit
    
    CHKROOTKIT_BIN="/usr/sbin/chkrootkit"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装Chkrootkit...${NC}"
    sudo yum install -y chkrootkit
    
    CHKROOTKIT_BIN="/usr/sbin/chkrootkit"
    
else
    echo -e "${YELLOW}从源码编译安装Chkrootkit...${NC}"
    
    # 检查编译依赖
    for cmd in gcc make; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 未找到编译工具 $cmd${NC}"
            exit 1
        fi
    done
    
    # 创建安装目录
    sudo mkdir -p ${CHKROOTKIT_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/chkrootkit"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "chkrootkit.tar.gz" ]; then
        echo -e "${YELLOW}下载Chkrootkit源码...${NC}"
        curl -fsSL -o chkrootkit.tar.gz ${CHKROOTKIT_URL}
    fi
    
    # 解压
    tar -xzf chkrootkit.tar.gz
    cd chkrootkit-*
    
    # 编译
    echo -e "${YELLOW}编译Chkrootkit...${NC}"
    make sense
    
    # 安装
    sudo cp chkrootkit ${CHKROOTKIT_INSTALL_DIR}/
    sudo chmod +x ${CHKROOTKIT_INSTALL_DIR}/chkrootkit
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
    
    CHKROOTKIT_BIN="${CHKROOTKIT_INSTALL_DIR}/chkrootkit"
fi

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/chkrootkit-check > /dev/null
#!/bin/bash
# Chkrootkit检查脚本

CHKROOTKIT_BIN="/usr/sbin/chkrootkit"
if [ ! -f "${CHKROOTKIT_BIN}" ]; then
    CHKROOTKIT_BIN="/opt/chkrootkit/chkrootkit"
fi

if [ ! -f "${CHKROOTKIT_BIN}" ]; then
    echo "错误: Chkrootkit未安装"
    echo "请运行: install-chkrootkit.sh"
    exit 1
fi

echo "=== Chkrootkit Rootkit检测 ==="
echo "检查时间: $(date)"
echo "主机名: $(hostname)"
echo ""

# 运行检查
sudo ${CHKROOTKIT_BIN} 2>&1 | tee /tmp/chkrootkit_$(date +%Y%m%d_%H%M%S).log

# 检查结果
if grep -q "INFECTED" /tmp/chkrootkit_$(date +%Y%m%d_%H%M%S).log; then
    echo ""
    echo -e "\033[0;31m警告: 检测到可能的rootkit感染!\033[0m"
    echo "请检查日志文件中的INFECTED条目"
    echo "建议立即采取安全措施"
else
    echo ""
    echo -e "\033[0;32m未检测到rootkit\033[0m"
fi
EOF

sudo chmod +x /usr/local/bin/chkrootkit-check

# 显示安装信息
echo -e "${GREEN}=== Chkrootkit安装完成 ===${NC}"
echo -e "可执行文件: ${CHKROOTKIT_BIN}"
echo ""
echo "使用方法:"
echo "  运行检查: chkrootkit-check"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove chkrootkit"
echo "  yum: sudo yum remove chkrootkit"
echo "  手动: sudo rm -rf ${CHKROOTKIT_INSTALL_DIR} /usr/local/bin/chkrootkit-check"
echo ""
echo -e "${YELLOW}提示: Chkrootkit与RKhunter功能类似，建议两者配合使用${NC}"
echo -e "${YELLOW}注意: Chkrootkit可能产生误报，请结合其他工具验证结果${NC}"
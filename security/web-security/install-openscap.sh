#!/bin/bash
# OpenSCAP - 安全内容自动化协议工具
# 功能：安全合规检查、漏洞扫描、配置评估
# 官方文档：https://www.open-scap.org/
# GitHub: https://github.com/OpenSCAP/openscap

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
OPENSCAP_VERSION="1.3.8"
OPENSCAP_INSTALL_DIR="/opt/openscap"
OPENSCAP_URL="https://github.com/OpenSCAP/openscap/releases/download/${OPENSCAP_VERSION}/openscap-${OPENSCAP_VERSION}.tar.gz"

echo -e "${GREEN}=== OpenSCAP 安全合规检查工具 安装脚本 ===${NC}"

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
    echo -e "${YELLOW}使用APT安装OpenSCAP...${NC}"
    sudo apt-get update
    sudo apt-get install -y libopenscap8 scap-security-guide openscap-scanner openscap-utils
    
    OPENSCAP_BIN="oscap"
    SCAP_DATA_DIR="/usr/share/xml/scap/ssg/content"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装OpenSCAP...${NC}"
    sudo yum install -y openscap openscap-scanner scap-security-guide
    
    OPENSCAP_BIN="oscap"
    SCAP_DATA_DIR="/usr/share/xml/scap/ssg/content"
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Homebrew安装OpenSCAP...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}错误: 未找到Homebrew，请先安装Homebrew${NC}"
        exit 1
    fi
    
    brew install openscap
    
    OPENSCAP_BIN="/usr/local/bin/oscap"
    SCAP_DATA_DIR="/usr/local/share/xml/scap/ssg/content"
    
else
    echo -e "${YELLOW}从源码编译安装OpenSCAP...${NC}"
    
    # 检查编译依赖
    for cmd in gcc make autoconf automake; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 未找到编译工具 $cmd${NC}"
            exit 1
        fi
    done
    
    # 安装依赖库
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sudo apt-get install -y libxml2-dev libxslt1-dev libpcre3-dev libssl-dev libldap2-dev libcurl4-openssl-dev python3-dev swig
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        sudo yum install -y libxml2-devel libxslt-devel pcre-devel openssl-devel openldap-devel libcurl-devel python3-devel swig
    fi
    
    # 创建安装目录
    sudo mkdir -p ${OPENSCAP_INSTALL_DIR}
    
    # 下载源码
    TEMP_DIR="/tmp/openscap"
    mkdir -p ${TEMP_DIR}
    cd ${TEMP_DIR}
    
    if [ ! -f "openscap-${OPENSCAP_VERSION}.tar.gz" ]; then
        echo -e "${YELLOW}下载OpenSCAP源码...${NC}"
        curl -fsSL -o openscap-${OPENSCAP_VERSION}.tar.gz ${OPENSCAP_URL}
    fi
    
    # 解压
    tar -xzf openscap-${OPENSCAP_VERSION}.tar.gz
    cd openscap-${OPENSCAP_VERSION}
    
    # 编译安装
    echo -e "${YELLOW}编译安装OpenSCAP...${NC}"
    ./configure --prefix=${OPENSCAP_INSTALL_DIR}
    make
    sudo make install
    
    # 清理
    cd /
    rm -rf ${TEMP_DIR}
    
    OPENSCAP_BIN="${OPENSCAP_INSTALL_DIR}/bin/oscap"
    SCAP_DATA_DIR="${OPENSCAP_INSTALL_DIR}/share/openscap/scap"
fi

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/openscap-check > /dev/null
#!/bin/bash
# OpenSCAP安全检查脚本

OSCAP_BIN="/usr/bin/oscap"
if [ ! -f "${OSCAP_BIN}" ]; then
    OSCAP_BIN="/usr/local/bin/oscap"
fi

SCAP_DATA_DIR="/usr/share/xml/scap/ssg/content"
if [ ! -d "${SCAP_DATA_DIR}" ]; then
    SCAP_DATA_DIR="/usr/local/share/xml/scap/ssg/content"
fi

if [ ! -f "${OSCAP_BIN}" ]; then
    echo "错误: OpenSCAP未安装"
    echo "请运行: install-openscap.sh"
    exit 1
fi

OUTPUT_DIR="./openscap-reports"
mkdir -p ${OUTPUT_DIR}

if [ "$1" == "--benchmark" ]; then
    # 基准测试
    echo "=== OpenSCAP基准测试 ==="
    
    if [ -z "$2" ]; then
        echo "用法: openscap-check --benchmark <benchmark.xml> [选项]"
        echo ""
        echo "选项:"
        echo "  --profile PROFILE   使用指定的配置文件"
        echo "  --output FILE       输出文件"
        echo ""
        echo "可用的基准测试:"
        ls ${SCAP_DATA_DIR}/*-ds.xml 2>/dev/null | xargs -n1 basename
        exit 1
    fi
    
    BENCHMARK="$2"
    PROFILE="$3"
    OUTPUT="${4:-openscap-report.html}"
    
    if [[ "$BENCHMARK" != /* ]]; then
        BENCHMARK="${SCAP_DATA_DIR}/${BENCHMARK}"
    fi
    
    if [ ! -f "${BENCHMARK}" ]; then
        echo "错误: 基准测试文件不存在: ${BENCHMARK}"
        exit 1
    fi
    
    echo "基准测试: ${BENCHMARK}"
    echo "配置文件: ${PROFILE}"
    echo "输出文件: ${OUTPUT}"
    echo ""
    
    CMD="${OSCAP_BIN} xccdf eval --results ${OUTPUT_DIR}/results.xml --report ${OUTPUT_DIR}/${OUTPUT} --profile ${PROFILE} ${BENCHMARK}"
    
    if [ -n "$PROFILE" ]; then
        CMD="${OSCAP_BIN} xccdf eval --results ${OUTPUT_DIR}/results.xml --report ${OUTPUT_DIR}/${OUTPUT} --profile ${PROFILE} ${BENCHMARK}"
    else
        CMD="${OSCAP_BIN} xccdf eval --results ${OUTPUT_DIR}/results.xml --report ${OUTPUT_DIR}/${OUTPUT} ${BENCHMARK}"
    fi
    
    sudo ${CMD}
    
    echo ""
    echo "扫描完成，报告: ${OUTPUT_DIR}/${OUTPUT}"
    
elif [ "$1" == "--oval" ]; then
    # OVAL扫描
    echo "=== OpenSCAP OVAL扫描 ==="
    
    if [ -z "$2" ]; then
        echo "用法: openscap-check --oval <oval-file>"
        exit 1
    fi
    
    OVAL_FILE="$2"
    
    if [[ "$OVAL_FILE" != /* ]]; then
        OVAL_FILE="${SCAP_DATA_DIR}/${OVAL_FILE}"
    fi
    
    if [ ! -f "${OVAL_FILE}" ]; then
        echo "错误: OVAL文件不存在: ${OVAL_FILE}"
        exit 1
    fi
    
    echo "OVAL文件: ${OVAL_FILE}"
    echo ""
    
    sudo ${OSCAP_BIN} oval eval --results ${OUTPUT_DIR}/oval-results.xml --report ${OUTPUT_DIR}/oval-report.html ${OVAL_FILE}
    
    echo ""
    echo "扫描完成，报告: ${OUTPUT_DIR}/oval-report.html"
    
elif [ "$1" == "--list-benchmarks" ]; then
    # 列出可用的基准测试
    echo "=== 可用的基准测试 ==="
    echo ""
    ls ${SCAP_DATA_DIR}/*-ds.xml 2>/dev/null | while read file; do
        basename "$file"
    done
    
elif [ "$1" == "--list-profiles" ]; then
    # 列出基准测试的配置文件
    if [ -z "$2" ]; then
        echo "用法: openscap-check --list-profiles <benchmark.xml>"
        exit 1
    fi
    
    BENCHMARK="$2"
    
    if [[ "$BENCHMARK" != /* ]]; then
        BENCHMARK="${SCAP_DATA_DIR}/${BENCHMARK}"
    fi
    
    echo "=== 基准测试配置文件 ==="
    echo ""
    ${OSCAP_BIN} info ${BENCHMARK} | grep -A 100 "Profiles"
    
else
    echo "用法: openscap-check [选项]"
    echo ""
    echo "选项:"
    echo "  --benchmark <file> [profile] [output]  运行基准测试"
    echo "  --oval <file>                         运行OVAL扫描"
    echo "  --list-benchmarks                    列出可用的基准测试"
    echo "  --list-profiles <benchmark>           列出基准测试的配置文件"
    echo ""
    echo "示例:"
    echo "  openscap-check --list-benchmarks"
    echo "  openscap-check --list-profiles ssg-ubuntu2204-ds.xml"
    echo "  openscap-check --benchmark ssg-ubuntu2204-ds.xml xccdf_org.ssgproject.content_profile_stig"
    echo "  openscap-check --oval ssg-ubuntu2204-oval.xml"
fi
EOF

sudo chmod +x /usr/local/bin/openscap-check

# 创建定时检查脚本
cat << 'EOF' | sudo tee /usr/local/bin/openscap-cron > /dev/null
#!/bin/bash
# OpenSCAP定时检查脚本

REPORT_DIR="/var/log/openscap"
EMAIL="admin@example.com"  # 修改为你的邮箱

mkdir -p ${REPORT_DIR}

echo "=== OpenSCAP定时安全检查 ===" | tee ${REPORT_DIR}/check_$(date +%Y%m%d).log
echo "检查时间: $(date)" | tee -a ${REPORT_DIR}/check_$(date +%Y%m%d).log
echo "" | tee -a ${REPORT_DIR}/check_$(date +%Y%m%d).log

# 选择合适的基准测试
if [ -f "/usr/share/xml/scap/ssg/content/ssg-ubuntu2204-ds.xml" ]; then
    BENCHMARK="ssg-ubuntu2204-ds.xml"
    PROFILE="xccdf_org.ssgproject.content_profile_stig"
elif [ -f "/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml" ]; then
    BENCHMARK="ssg-rhel9-ds.xml"
    PROFILE="xccdf_org.ssgproject.content_profile_stig"
else
    echo "未找到合适的基准测试文件" | tee -a ${REPORT_DIR}/check_$(date +%Y%m%d).log
    exit 1
fi

# 运行检查
openscap-check --benchmark ${BENCHMARK} ${PROFILE} report_$(date +%Y%m%d).html 2>&1 | tee -a ${REPORT_DIR}/check_$(date +%Y%m%d).log

# 检查结果
if [ $? -ne 0 ]; then
    echo "检查发现问题，发送报告邮件..."
    mail -s "[OpenSCAP] 安全检查报告 - $(hostname)" ${EMAIL} < ${REPORT_DIR}/check_$(date +%Y%m%d).log
fi

echo "完成时间: $(date)" | tee -a ${REPORT_DIR}/check_$(date +%Y%m%d).log
EOF

sudo chmod +x /usr/local/bin/openscap-cron

# 显示安装信息
echo -e "${GREEN}=== OpenSCAP安装完成 ===${NC}"
echo -e "可执行文件: ${OSCAP_BIN}"
echo -e "数据目录: ${SCAP_DATA_DIR}"
echo ""
echo "常用命令:"
echo "  列出基准测试: openscap-check --list-benchmarks"
echo "  列出配置文件: openscap-check --list-profiles <benchmark>"
echo "  运行基准测试: openscap-check --benchmark <benchmark> [profile]"
echo "  运行OVAL扫描: openscap-check --oval <oval-file>"
echo ""
echo "定时检查:"
echo "  编辑crontab: crontab -e"
echo "  添加: 0 2 * * 0 openscap-cron  # 每周日凌晨检查"
echo ""
echo "卸载:"
echo "  apt: sudo apt-get remove openscap scap-security-guide"
echo "  yum: sudo yum remove openscap scap-security-guide"
echo "  brew: brew uninstall openscap"
echo "  手动: sudo rm -rf ${OPENSCAP_INSTALL_DIR} /usr/local/bin/openscap-*"
echo ""
echo -e "${YELLOW}提示: OpenSCAP主要用于企业级安全合规检查${NC}"
echo -e "${YELLOW}建议: 根据实际需求选择合适的基准测试和配置文件${NC}"
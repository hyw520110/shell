#!/bin/bash
# ==============================================================================
# Nmap 一键脚本 - 安装/配置/执行
# 用法: ./nmap.sh <命令> [参数]
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
NMAP_VERSION="7.95"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/nmap_scan}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# 显示帮助
show_help() {
    echo -e "${BLUE}Nmap 一键脚本${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "安装命令:"
    echo "  install             安装 Nmap"
    echo "  uninstall           卸载 Nmap"
    echo ""
    echo "扫描命令:"
    echo "  quick <target>      快速扫描 (常用100端口)"
    echo "  full <target>       全端口扫描 (1-65535)"
    echo "  vuln <target>       漏洞扫描"
    echo "  stealth <target>    SYN 隐蔽扫描"
    echo "  service <target>    服务版本检测"
    echo "  os <target>         操作系统检测"
    echo "  all <target>        综合扫描 (服务+OS+漏洞)"
    echo ""
    echo "选项:"
    echo "  -p <端口>           指定端口"
    echo "  -o <文件>           输出文件前缀"
    echo "  --no-ping           跳过 Ping 检测"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 quick 192.168.1.1"
    echo "  $0 vuln example.com -o myscan"
    echo "  $0 full 192.168.1.0/24"
}

# 检测系统
detect_os() {
    OS_TYPE=$(uname -s)
    ARCH=$(uname -m)
}

# 检查是否安装
check_installed() {
    command -v nmap &> /dev/null
}

# 安装 - Linux
install_linux() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y nmap
    elif command -v yum &> /dev/null; then
        sudo yum install -y nmap
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y nmap
    else
        install_from_source
    fi
}

# 源码编译安装
install_from_source() {
    echo -e "${YELLOW}[信息] 从源码编译安装...${NC}"
    
    local url="https://nmap.org/dist/nmap-${NMAP_VERSION}.tar.bz2"
    local tar_file="$DOWNLOAD_DIR/nmap-${NMAP_VERSION}.tar.bz2"
    local src_dir="$DOWNLOAD_DIR/nmap-${NMAP_VERSION}"
    
    # 安装依赖
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y build-essential libssl-dev
    elif command -v yum &> /dev/null; then
        sudo yum groupinstall -y "Development Tools"
        sudo yum install -y openssl-devel
    fi
    
    mkdir -p "$DOWNLOAD_DIR"
    [ ! -f "$tar_file" ] && wget -O "$tar_file" "$url"
    
    cd "$DOWNLOAD_DIR"
    tar -xjf "$tar_file"
    cd "$src_dir"
    
    ./configure --prefix=/usr/local
    make -j$(nproc 2>/dev/null || echo 4)
    sudo make install
    
    cd ~
    rm -rf "$src_dir"
}

# 安装 - macOS
install_macos() {
    if command -v brew &> /dev/null; then
        brew install nmap
    else
        echo -e "${RED}[错误] 未找到 Homebrew${NC}"
        exit 1
    fi
}

# 执行安装
cmd_install() {
    if check_installed; then
        local ver=$(nmap --version | head -1)
        echo -e "${GREEN}[信息] Nmap 已安装: $ver${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 开始安装 Nmap ${NMAP_VERSION}...${NC}"
    detect_os
    
    case "$OS_TYPE" in
        Linux) install_linux ;;
        Darwin) install_macos ;;
        *) echo -e "${RED}[错误] 不支持的系统${NC}"; exit 1 ;;
    esac
    
    echo -e "${GREEN}[完成] Nmap 安装成功${NC}"
    nmap --version | head -1
}

# 卸载
cmd_uninstall() {
    echo -e "${YELLOW}[信息] 卸载 Nmap...${NC}"
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get remove -y nmap
    elif command -v yum &> /dev/null; then
        sudo yum remove -y nmap
    elif command -v brew &> /dev/null; then
        brew uninstall nmap
    fi
    
    echo -e "${GREEN}[完成] Nmap 已卸载${NC}"
}

# 扫描函数
do_scan() {
    check_installed || { echo -e "${RED}[错误] Nmap 未安装，请先执行: $0 install${NC}"; exit 1; }
    
    local scan_type="$1"
    local target="$2"
    local output="${3:-${scan_type}_$(date +%Y%m%d_%H%M%S)}"
    
    mkdir -p "$OUTPUT_DIR"
    
    local nmap_opts="-T4"
    
    case "$scan_type" in
        quick)
            nmap_opts="$nmap_opts -F --top-ports 100"
            ;;
        full)
            nmap_opts="$nmap_opts -p-"
            ;;
        vuln)
            nmap_opts="$nmap_opts --script vuln"
            ;;
        stealth)
            nmap_opts="$nmap_opts -sS"
            ;;
        service)
            nmap_opts="$nmap_opts -sV"
            ;;
        os)
            nmap_opts="$nmap_opts -O"
            ;;
        all)
            nmap_opts="$nmap_opts -A --script vuln"
            ;;
    esac
    
    nmap_opts="$nmap_opts -oN $OUTPUT_DIR/${output}.nmap -oX $OUTPUT_DIR/${output}.xml"
    nmap_opts="$nmap_opts ${EXTRA_ARGS[*]}"
    
    echo -e "${GREEN}[信息] ${scan_type} 扫描: $target${NC}"
    
    if [[ "$scan_type" =~ ^(stealth|os|all)$ ]]; then
        sudo nmap $nmap_opts "$target"
    else
        nmap $nmap_opts "$target"
    fi
    
    echo -e "${GREEN}[完成] 结果: $OUTPUT_DIR/${output}.nmap${NC}"
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    shift
    EXTRA_ARGS=()
    OUTPUT_PREFIX=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) OUTPUT_PREFIX="$2"; shift 2 ;;
            -p) EXTRA_ARGS+=("-p" "$2"); shift 2 ;;
            --no-ping) EXTRA_ARGS+=("-Pn"); shift ;;
            -h|--help) show_help; exit 0 ;;
            *) EXTRA_ARGS+=("$1"); shift ;;
        esac
    done
    
    case "$cmd" in
        install) cmd_install ;;
        uninstall) cmd_uninstall ;;
        quick|full|vuln|stealth|service|os|all)
            [ ${#EXTRA_ARGS[@]} -eq 0 ] && { echo -e "${RED}[错误] 请指定目标${NC}"; exit 1; }
            do_scan "$cmd" "${EXTRA_ARGS[0]}" "$OUTPUT_PREFIX"
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

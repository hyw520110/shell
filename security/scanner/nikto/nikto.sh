#!/bin/bash
# ==============================================================================
# Nikto 一键脚本 - 安装/配置/扫描
# 用法: ./nikto.sh <命令> [参数]
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
NIKTO_VERSION="2.5.0"
INSTALL_DIR="${INSTALL_DIR:-/usr/local}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/nikto_scan}"

# 显示帮助
show_help() {
    echo -e "${BLUE}Nikto 一键脚本 - Web 服务器扫描${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  install             安装 Nikto"
    echo "  update              更新数据库"
    echo "  scan <url>          扫描目标"
    echo "  scan-ssl <url>      SSL 扫描"
    echo "  scan-full <url>     全面扫描"
    echo ""
    echo "选项:"
    echo "  -p <端口>           指定端口"
    echo "  -o <文件>           输出文件"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 scan https://example.com"
    echo "  $0 scan-full http://192.168.1.1 -p 8080"
}

# 检查是否安装
check_installed() {
    command -v nikto &> /dev/null
}

# 包管理器安装
install_package() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y nikto
        return 0
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y nikto
        return 0
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y nikto
        return 0
    elif command -v brew &> /dev/null; then
        brew install nikto
        return 0
    fi
    return 1
}

# 源码安装
install_source() {
    local url="https://github.com/sullo/nikto/archive/refs/tags/${NIKTO_VERSION}.tar.gz"
    local tar_file="/tmp/nikto-${NIKTO_VERSION}.tar.gz"
    
    wget -O "$tar_file" "$url"
    
    local tmp_dir=$(mktemp -d)
    tar -xzf "$tar_file" -C "$tmp_dir"
    
    sudo mkdir -p "$INSTALL_DIR/share/nikto"
    sudo cp -r "$tmp_dir"/nikto-*/* "$INSTALL_DIR/share/nikto/"
    sudo ln -sf "$INSTALL_DIR/share/nikto/program/nikto.pl" /usr/local/bin/nikto
    sudo chmod +x "$INSTALL_DIR/share/nikto/program/nikto.pl"
    
    rm -rf "$tmp_dir" "$tar_file"
}

# 安装
cmd_install() {
    if check_installed; then
        echo -e "${GREEN}[信息] Nikto 已安装${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 安装 Nikto ${NIKTO_VERSION}...${NC}"
    
    install_package || install_source
    
    echo -e "${GREEN}[完成] Nikto 安装成功${NC}"
    nikto -Version 2>&1 | head -2
}

# 更新数据库
cmd_update() {
    check_installed || { echo -e "${RED}[错误] Nikto 未安装${NC}"; exit 1; }
    nikto -update
}

# 扫描函数
do_scan() {
    check_installed || { echo -e "${RED}[错误] Nikto 未安装，请先执行: $0 install${NC}"; exit 1; }
    
    local scan_type="$1"
    local url="$2"
    
    mkdir -p "$OUTPUT_DIR"
    local output="${OUTPUT_FILE:-$OUTPUT_DIR/scan-$(date +%Y%m%d-%H%M%S)}"
    
    local nikto_opts="-h $url -Format htm -o ${output}.html"
    
    if [ -n "$PORT" ]; then
        nikto_opts="$nikto_opts -port $PORT"
    fi
    
    case "$scan_type" in
        scan)
            ;;
        scan-ssl)
            nikto_opts="$nikto_opts -ssl"
            ;;
        scan-full)
            nikto_opts="$nikto_opts -Tuning 123456789"
            ;;
    esac
    
    echo -e "${GREEN}[信息] ${scan_type}: $url${NC}"
    nikto $nikto_opts
    
    echo -e "${GREEN}[完成] 报告: ${output}.html${NC}"
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    shift
    PORT=""
    OUTPUT_FILE=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p) PORT="$2"; shift 2 ;;
            -o) OUTPUT_FILE="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) break ;;
        esac
    done
    
    case "$cmd" in
        install) cmd_install ;;
        update) cmd_update ;;
        scan|scan-ssl|scan-full)
            [ -z "${1:-}" ] && { echo -e "${RED}[错误] 请指定 URL${NC}"; exit 1; }
            do_scan "$cmd" "$1"
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

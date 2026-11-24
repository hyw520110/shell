#!/bin/bash
# ==============================================================================
# Lynis 一键脚本 - 安装/配置/审计
# 用法: ./lynis.sh <命令> [参数]
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
LYNIS_VERSION="3.1.4"
INSTALL_DIR="${INSTALL_DIR:-/usr/local}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# 显示帮助
show_help() {
    echo -e "${BLUE}Lynis 一键脚本 - 系统合规审计${NC}"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install             安装 Lynis"
    echo "  audit               执行系统审计"
    echo "  audit-quick         快速审计"
    echo "  update              检查更新"
    echo "  report              查看最近报告"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 audit"
}

# 检查是否安装
check_installed() {
    command -v lynis &> /dev/null
}

# 包管理器安装
install_package() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y lynis
        return 0
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y lynis
        return 0
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y lynis
        return 0
    elif command -v brew &> /dev/null; then
        brew install lynis
        return 0
    fi
    return 1
}

# 源码安装
install_source() {
    local url="https://cisofy.com/files/lynis-${LYNIS_VERSION}.tar.gz"
    local tar_file="$DOWNLOAD_DIR/lynis-${LYNIS_VERSION}.tar.gz"
    
    mkdir -p "$DOWNLOAD_DIR"
    
    [ ! -f "$tar_file" ] && wget -O "$tar_file" "$url"
    
    local tmp_dir=$(mktemp -d)
    tar -xzf "$tar_file" -C "$tmp_dir"
    
    sudo mkdir -p "$INSTALL_DIR/share/lynis"
    sudo cp -r "$tmp_dir"/lynis*/* "$INSTALL_DIR/share/lynis/"
    sudo ln -sf "$INSTALL_DIR/share/lynis/lynis" /usr/local/bin/lynis
    sudo chown -R root:root "$INSTALL_DIR/share/lynis"
    
    rm -rf "$tmp_dir"
}

# 安装
cmd_install() {
    if check_installed; then
        echo -e "${GREEN}[信息] Lynis 已安装: $(lynis show version 2>/dev/null || echo 'installed')${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 安装 Lynis ${LYNIS_VERSION}...${NC}"
    
    install_package || install_source
    
    echo -e "${GREEN}[完成] Lynis 安装成功${NC}"
}

# 审计
cmd_audit() {
    check_installed || { echo -e "${RED}[错误] Lynis 未安装，请先执行: $0 install${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] 执行系统审计 (需要 root 权限)...${NC}"
    sudo lynis audit system
}

# 快速审计
cmd_audit_quick() {
    check_installed || { echo -e "${RED}[错误] Lynis 未安装${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] 执行快速审计...${NC}"
    sudo lynis audit system -Q
}

# 检查更新
cmd_update() {
    check_installed || { echo -e "${RED}[错误] Lynis 未安装${NC}"; exit 1; }
    lynis update info
}

# 查看报告
cmd_report() {
    local log="/var/log/lynis.log"
    local report="/var/log/lynis-report.dat"
    
    if [ -f "$log" ]; then
        echo -e "${GREEN}[信息] 最近审计日志: $log${NC}"
        tail -50 "$log"
    fi
    
    if [ -f "$report" ]; then
        echo ""
        echo -e "${GREEN}[信息] 审计报告数据: $report${NC}"
        grep -E "^(warning|suggestion)=" "$report" | head -20
    fi
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    
    case "$cmd" in
        install) cmd_install ;;
        audit) cmd_audit ;;
        audit-quick) cmd_audit_quick ;;
        update) cmd_update ;;
        report) cmd_report ;;
        -h|--help) show_help ;;
        *)
            echo -e "${RED}[错误] 未知命令: $cmd${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

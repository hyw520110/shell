#!/bin/bash
# ==============================================================================
# ClamAV 一键脚本 - 安装/配置/扫描
# 用法: ./clamav.sh <命令> [参数]
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
OUTPUT_DIR="${OUTPUT_DIR:-/var/log/clamav}"

# 显示帮助
show_help() {
    echo -e "${BLUE}ClamAV 一键脚本 - 开源杀毒软件${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "安装命令:"
    echo "  install             安装 ClamAV"
    echo "  update              更新病毒库"
    echo ""
    echo "扫描命令:"
    echo "  quick               快速扫描 (常用目录)"
    echo "  full                全盘扫描"
    echo "  home                扫描用户目录"
    echo "  web                 扫描 Web 目录"
    echo "  custom <路径>       自定义路径扫描"
    echo ""
    echo "选项:"
    echo "  --remove            删除感染文件"
    echo "  --move              移动到隔离区"
    echo "  -o <文件>           报告文件"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 update"
    echo "  $0 quick"
    echo "  $0 custom /var/www --remove"
}

# 检查是否安装
check_installed() {
    command -v clamscan &> /dev/null
}

# 安装
cmd_install() {
    if check_installed; then
        echo -e "${GREEN}[信息] ClamAV 已安装: $(clamscan --version | head -1)${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 安装 ClamAV...${NC}"
    
    local os=$(uname -s)
    
    if [ "$os" = "Darwin" ]; then
        if command -v brew &> /dev/null; then
            brew install clamav
        else
            echo -e "${RED}[错误] 请先安装 Homebrew${NC}"
            exit 1
        fi
    else
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y clamav clamav-daemon
        elif command -v yum &> /dev/null; then
            sudo yum install -y epel-release
            sudo yum install -y clamav clamd
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y clamav clamd
        fi
    fi
    
    echo -e "${GREEN}[完成] ClamAV 安装成功${NC}"
    
    # 更新病毒库
    echo -e "${GREEN}[信息] 更新病毒库...${NC}"
    sudo freshclam || true
}

# 更新病毒库
cmd_update() {
    check_installed || { echo -e "${RED}[错误] ClamAV 未安装${NC}"; exit 1; }
    
    echo -e "${GREEN}[信息] 更新病毒库...${NC}"
    
    if command -v systemctl &> /dev/null; then
        sudo systemctl stop clamav-freshclam 2>/dev/null || true
    fi
    
    sudo freshclam
    
    if command -v systemctl &> /dev/null; then
        sudo systemctl start clamav-freshclam 2>/dev/null || true
    fi
    
    echo -e "${GREEN}[完成] 病毒库已更新${NC}"
}

# 扫描函数
do_scan() {
    check_installed || { echo -e "${RED}[错误] ClamAV 未安装，请先执行: $0 install${NC}"; exit 1; }
    
    local scan_type="$1"
    local scan_path="${2:-}"
    local report="${REPORT:-$OUTPUT_DIR/scan-$(date +%Y%m%d-%H%M%S).log}"
    
    sudo mkdir -p "$OUTPUT_DIR"
    
    local scan_opts="--infected --recursive --log=$report"
    
    if [ "$REMOVE_INFECTED" = "true" ]; then
        scan_opts="$scan_opts --remove"
        echo -e "${YELLOW}[警告] 将删除感染文件${NC}"
    elif [ "$MOVE_INFECTED" = "true" ]; then
        local quarantine="/tmp/clamav-quarantine"
        sudo mkdir -p "$quarantine"
        scan_opts="$scan_opts --move=$quarantine"
        echo -e "${YELLOW}[警告] 感染文件移动到: $quarantine${NC}"
    fi
    
    # 确定扫描路径
    case "$scan_type" in
        quick)
            scan_path="/tmp /var/tmp /home"
            [ -d /var/www ] && scan_path="$scan_path /var/www"
            ;;
        full)
            scan_path="/"
            ;;
        home)
            scan_path="/home"
            ;;
        web)
            scan_path=""
            for p in /var/www /usr/share/nginx; do
                [ -d "$p" ] && scan_path="$scan_path $p"
            done
            ;;
        custom)
            if [ ! -e "$scan_path" ]; then
                echo -e "${RED}[错误] 路径不存在: $scan_path${NC}"
                exit 1
            fi
            ;;
    esac
    
    echo -e "${GREEN}[信息] ${scan_type} 扫描${NC}"
    echo -e "${GREEN}[信息] 路径: $scan_path${NC}"
    echo -e "${GREEN}[信息] 报告: $report${NC}"
    
    sudo clamscan $scan_opts $scan_path
    
    local infected=$(grep -c "FOUND" "$report" 2>/dev/null || echo 0)
    
    echo ""
    if [ "$infected" -gt 0 ]; then
        echo -e "${RED}[结果] 发现 $infected 个感染文件${NC}"
    else
        echo -e "${GREEN}[结果] 未发现感染文件${NC}"
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
    REMOVE_INFECTED="false"
    MOVE_INFECTED="false"
    REPORT=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove) REMOVE_INFECTED="true"; shift ;;
            --move) MOVE_INFECTED="true"; shift ;;
            -o) REPORT="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) break ;;
        esac
    done
    
    case "$cmd" in
        install) cmd_install ;;
        update) cmd_update ;;
        quick|full|home|web) do_scan "$cmd" ;;
        custom)
            [ -z "${1:-}" ] && { echo -e "${RED}[错误] 请指定路径${NC}"; exit 1; }
            do_scan "custom" "$1"
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

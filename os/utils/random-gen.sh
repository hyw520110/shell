#!/bin/bash

# Filename: random-gen.sh
# 功能: 统一的随机数生成工具（整合 random.sh 和 gen-random-base64.sh）
#       支持生成范围随机数和安全的 Base64 随机字符串

set -eo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1" >&2; }

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 <命令> [参数]

命令:
  number <最小值> <最大值>   生成指定范围内的随机数
  base64 [字节数]             生成安全的 Base64 编码随机字符串
  -h, --help                  显示此帮助信息

示例:
  $0 number 1 100              # 生成 1-100 之间的随机数
  $0 base64 16                # 生成 16 字节的 Base64 随机字符串
  $0 base64                    # 生成 32 字节的 Base64 随机字符串（默认）

说明:
  - number 命令：使用 /dev/urandom 生成简单随机数
  - base64 命令：使用 openssl 或 /dev/urandom 生成密码学安全的随机字符串
EOF
}

# --- 随机数生成函数 ---

# 生成指定范围内的随机数（来自 random.sh）
generate_random_number() {
    local min=$1
    local max=$2
    
    if [ -z "$min" ] || [ -z "$max" ]; then
        log_error "缺少参数。用法: $0 number <最小值> <最大值>"
        exit 1
    fi
    
    if ! [[ "$min" =~ ^-?[0-9]+$ ]] || ! [[ "$max" =~ ^-?[0-9]+$ ]]; then
        log_error "参数必须是数字。"
        exit 1
    fi
    
    if [ "$min" -gt "$max" ]; then
        log_error "最小值不能大于最大值。"
        exit 1
    fi
    
    local range=$((max - min + 1))
    local num=$(cat /dev/urandom | head -n 10 | cksum | awk -F ' ' '{print $1}')
    local result=$((num % range + min))
    
    echo "$result"
}

# 生成 Base64 随机字符串（来自 gen-random-base64.sh）
generate_base64_random() {
    local default_bytes=32
    local num_bytes="${1:-$default_bytes}"
    
    # 验证输入
    if ! [[ "$num_bytes" =~ ^[1-9][0-9]*$ ]]; then
        log_error "字节数必须是一个正整数。"
        exit 1
    fi
    
    # 优先使用 openssl
    if command -v openssl &> /dev/null; then
        openssl rand -base64 "$num_bytes"
    else
        # 使用 /dev/urandom 作为备用方案
        head -c "$num_bytes" /dev/urandom | base64
    fi
}

# --- 交互式菜单 ---
interactive_menu() {
    while true; do
        clear
        echo "###############################################################"
        echo "<================== 随机数生成工具 ==================>"
        echo "###############################################################"
        echo "A -- 生成范围随机数"
        echo "B -- 生成 Base64 随机字符串"
        echo "Q -- 退出"
        echo "------------------------------------------------"
        
        read -n1 -p "请选择一个操作 (A-B, Q): " option
        echo -e "\n您的选择是: $option\n"

        case "$option" in
            A|a)
                read -p "请输入最小值: " min_val
                read -p "请输入最大值: " max_val
                if [ -n "$min_val" ] && [ -n "$max_val" ]; then
                    log_info "生成的随机数: $(generate_random_number "$min_val" "$max_val")"
                else
                    log_warn "输入无效。"
                fi
                ;;
            B|b)
                read -p "请输入字节数（默认 32）: " bytes_val
                if [ -z "$bytes_val" ]; then
                    bytes_val=32
                fi
                if [[ "$bytes_val" =~ ^[1-9][0-9]*$ ]]; then
                    log_info "生成的 Base64 随机字符串:"
                    generate_base64_random "$bytes_val"
                else
                    log_warn "输入无效，请输入正整数。"
                fi
                ;;
            Q|q)
                log_info "退出程序。"
                exit 0
                ;;
            *)
                log_warn "无效选择，请重新输入。"
                sleep 1
                ;;
        esac
        read -p "按回车键返回主菜单..."
    done
}

# --- 主函数 ---
main() {
    # 如果没有参数，显示交互式菜单
    if [ $# -eq 0 ]; then
        interactive_menu
        exit 0
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        number)
            if [ $# -lt 2 ]; then
                log_error "缺少参数。用法: $0 number <最小值> <最大值>"
                exit 1
            fi
            generate_random_number "$1" "$2"
            ;;
        base64)
            generate_base64_random "$1"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "未知命令: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
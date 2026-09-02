#!/bin/bash

# Rancher 停止脚本

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="$HOME/rancher"
readonly DEFAULT_HTTP_PORT=8080
readonly DEFAULT_HTTPS_PORT=8443
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HTTP_PORT="$DEFAULT_HTTP_PORT"
HTTPS_PORT="$DEFAULT_HTTPS_PORT"

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Rancher 停止脚本

用法: ./stop.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: ~/rancher)
    -h, --help          显示此帮助信息

示例:
    ./stop.sh                    # 默认目录停止
    ./stop.sh --dir /opt/rancher   # 指定目录停止
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查是否已安装 ===
check_installed() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_warning "Rancher 未安装"
        exit 0
    fi
    
    if [[ ! -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        print_warning "未找到 docker-compose.yml 文件"
        exit 0
    fi
}

# === 停止服务 ===
stop_service() {
    print_info "停止 Rancher..."
    
    cd "$INSTALL_DIR"
    docker compose down
    
    print_success "Rancher 已停止"
    print_info "重新启动: ./startup.sh"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已安装
    check_installed
    
    # 停止服务
    stop_service
}

# === 执行主函数 ===
main "$@"
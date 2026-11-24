#!/bin/bash

# Rancher 启动脚本

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
Rancher 启动脚本

用法: ./startup.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: ~/rancher)
    -h, --help          显示此帮助信息

示例:
    ./startup.sh                    # 默认目录启动
    ./startup.sh --dir /opt/rancher   # 指定目录启动
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
        print_error "Rancher 未安装，请先运行 install-rancher.sh"
        exit 1
    fi
    
    if [[ ! -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        print_error "未找到 docker-compose.yml 文件"
        exit 1
    fi
}

# === 检查是否已运行 ===
check_running() {
    if docker ps | grep -q rancher; then
        print_warning "Rancher 已在运行"
        print_info "HTTP 访问地址: http://localhost:${HTTP_PORT}"
        print_info "HTTPS 访问地址: https://localhost:${HTTPS_PORT}"
        exit 0
    fi
}

# === 启动服务 ===
start_service() {
    print_info "启动 Rancher..."
    
    cd "$INSTALL_DIR"
    docker compose up -d
    
    # 等待服务启动
    sleep 5
    
    # 检查服务状态
    if docker ps | grep -q rancher; then
        print_success "Rancher 启动成功"
        print_info "HTTP 访问地址: http://localhost:${HTTP_PORT}"
        print_info "HTTPS 访问地址: https://localhost:${HTTPS_PORT}"
        print_info "查看日志: docker compose -f $INSTALL_DIR/$DOCKER_COMPOSE_FILE logs -f"
    else
        print_error "Rancher 启动失败"
        print_info "查看日志: docker compose -f $INSTALL_DIR/$DOCKER_COMPOSE_FILE logs"
        exit 1
    fi
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已安装
    check_installed
    
    # 检查是否已运行
    check_running
    
    # 启动服务
    start_service
}

# === 执行主函数 ===
main "$@"
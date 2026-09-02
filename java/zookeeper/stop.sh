#!/bin/bash

# ZooKeeper 停止脚本

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="$HOME/zookeeper"
readonly DEFAULT_PORT=2181
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
PORT="$DEFAULT_PORT"

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
ZooKeeper 停止脚本

用法: ./stop.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: ~/zookeeper)
    -m, --mode MODE     模式: auto|docker|host (默认: auto)
    -h, --help          显示此帮助信息

示例:
    ./stop.sh                      # 自动模式停止
    ./stop.sh --mode docker        # Docker 模式停止
    ./stop.sh --mode host          # 主机模式停止
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
            -m|--mode)
                MODE="$2"
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
        print_warning "ZooKeeper 未安装"
        exit 0
    fi
}

# === 检测模式 ===
detect_mode() {
    if [[ -n "$MODE" ]]; then
        return 0
    fi
    
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        MODE="docker"
    elif [[ -f "$INSTALL_DIR/stop-host.sh" ]]; then
        MODE="host"
    else
        print_warning "无法确定安装模式"
        exit 0
    fi
}

# === Docker 模式停止 ===
stop_docker_mode() {
    print_info "停止 Docker 模式 ZooKeeper..."
    
    cd "$INSTALL_DIR"
    docker compose down
    
    print_success "ZooKeeper 已停止"
    print_info "重新启动: ./startup.sh"
}

# === 主机模式停止 ===
stop_host_mode() {
    print_info "停止主机模式 ZooKeeper..."
    
    cd "$INSTALL_DIR"
    
    if [[ -f "stop-host.sh" ]]; then
        ./stop-host.sh
    else
        print_info "未找到 stop-host.sh，尝试直接停止进程..."
        killall java 2>/dev/null || true
    fi
    
    print_success "ZooKeeper 已停止"
    print_info "重新启动: ./startup.sh"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已安装
    check_installed
    
    # 检测模式
    detect_mode
    
    # 根据模式停止
    if [[ "$MODE" == "docker" ]]; then
        stop_docker_mode
    elif [[ "$MODE" == "host" ]]; then
        stop_host_mode
    else
        print_warning "未知模式: $MODE"
        exit 0
    fi
}

# === 执行主函数 ===
main "$@"
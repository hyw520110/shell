#!/bin/bash

# ZooKeeper 启动脚本

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
ZooKeeper 启动脚本

用法: ./startup.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: ~/zookeeper)
    -m, --mode MODE     模式: auto|docker|host (默认: auto)
    -h, --help          显示此帮助信息

示例:
    ./startup.sh                      # 自动模式启动
    ./startup.sh --mode docker        # Docker 模式启动
    ./startup.sh --mode host          # 主机模式启动
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
        print_error "ZooKeeper 未安装，请先运行 install-zookeeper.sh"
        exit 1
    fi
}

# === 检测模式 ===
detect_mode() {
    if [[ -n "$MODE" ]]; then
        return 0
    fi
    
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        MODE="docker"
    elif [[ -f "$INSTALL_DIR/start-host.sh" ]]; then
        MODE="host"
    else
        print_error "无法确定安装模式"
        exit 1
    fi
}

# === 检查是否已运行 ===
check_running() {
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        print_warning "ZooKeeper 已在运行"
        print_info "连接信息: zkCli.sh -server localhost:$PORT"
        exit 0
    fi
}

# === Docker 模式启动 ===
start_docker_mode() {
    print_info "启动 Docker 模式 ZooKeeper..."
    
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "ZooKeeper 启动成功"
    print_info "连接信息: zkCli.sh -server localhost:$PORT"
    print_info "查看日志: docker compose -f $INSTALL_DIR/$DOCKER_COMPOSE_FILE logs -f"
}

# === 主机模式启动 ===
start_host_mode() {
    print_info "启动主机模式 ZooKeeper..."
    
    cd "$INSTALL_DIR"
    
    if [[ -f "start-host.sh" ]]; then
        ./start-host.sh
    else
        print_error "未找到 start-host.sh"
        exit 1
    fi
    
    print_success "ZooKeeper 启动成功"
    print_info "连接信息: zkCli.sh -server localhost:$PORT"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已安装
    check_installed
    
    # 检测模式
    detect_mode
    
    # 检查是否已运行
    check_running
    
    # 根据模式启动
    if [[ "$MODE" == "docker" ]]; then
        start_docker_mode
    elif [[ "$MODE" == "host" ]]; then
        start_host_mode
    else
        print_error "未知模式: $MODE"
        exit 1
    fi
}

# === 执行主函数 ===
main "$@"
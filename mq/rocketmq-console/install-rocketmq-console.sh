#!/bin/bash

# RocketMQ Console 一键安装配置脚本
# RocketMQ Web 管理控制台

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly ROCKETMQ_CONSOLE_VERSION="2.0.0"
readonly ROCKETMQ_CONSOLE_IMAGE="apache/rocketmq-dashboard"
readonly DEFAULT_INSTALL_DIR="$HOME/rocketmq-console"
readonly DEFAULT_PORT=8080
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
PORT="$DEFAULT_PORT"
ROCKETMQ_NAME_SERVER="localhost:9876"
DRY_RUN=false
UNINSTALL_MODE=false

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

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

# === 检查命令是否存在 ===
command_exists() {
    command -v "$1" &>/dev/null
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
RocketMQ Console 一键安装配置脚本

用法: ./install-rocketmq-console.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/rocketmq-console)
    -p, --port PORT             Web 端口 (默认: 8080)
    -n, --nameserver ADDR       NameServer 地址 (默认: localhost:9876)
    --dry-run                   试运行模式
    --uninstall                 卸载 RocketMQ Console

示例:
    ./install-rocketmq-console.sh                           # 默认安装
    ./install-rocketmq-console.sh --port 9000               # 指定端口
    ./install-rocketmq-console.sh -n 192.168.1.100:9876     # 指定 NameServer
    ./install-rocketmq-console.sh --uninstall               # 卸载

使用指南:
    1. 安装完成后，访问: http://localhost:8080
    2. 配置 NameServer 地址
    3. 查看消息队列、消费者、生产者等信息

更多信息: https://github.com/apache/rocketmq-dashboard
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -n|--nameserver)
                ROCKETMQ_NAME_SERVER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查依赖 ===
check_dependencies() {
    if ! command_exists docker; then
        print_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    if ! command_exists docker compose; then
        print_error "Docker Compose 未安装，请先安装 Docker Compose"
        exit 1
    fi
    
    print_success "依赖检查通过"
}

# === 检查端口是否被占用 ===
check_port() {
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        print_warning "端口 $PORT 已被占用"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# === 安装 RocketMQ Console ===
install_console() {
    print_header "安装 RocketMQ Console"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将安装 RocketMQ Console"
        print_info "  安装目录: $INSTALL_DIR"
        print_info "  端口: $PORT"
        print_info "  NameServer: $ROCKETMQ_NAME_SERVER"
        return 0
    fi
    
    # 检查端口
    check_port
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 生成 docker-compose.yml
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  rocketmq-console:
    image: ${ROCKETMQ_CONSOLE_IMAGE}
    container_name: rocketmq-console
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    environment:
      - "JAVA_OPTS=-Xms256m -Xmx256m"
      - "rocketmq.config.namesrvAddr=${ROCKETMQ_NAME_SERVER}"
      - "rocketmq.config.isVIPChannel=false"
      - "server.port=8080"
    networks:
      - rocketmq-network

networks:
  rocketmq-network:
    driver: bridge
EOF

    print_success "docker-compose.yml 生成成功"
    
    # 启动服务
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "RocketMQ Console 启动成功"
    print_info "访问地址: http://localhost:${PORT}"
    print_info "NameServer: ${ROCKETMQ_NAME_SERVER}"
}

# === 卸载 RocketMQ Console ===
uninstall_console() {
    print_header "卸载 RocketMQ Console"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 RocketMQ Console"
        return 0
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_warning "RocketMQ Console 未安装"
        exit 0
    fi
    
    # 停止服务
    cd "$INSTALL_DIR"
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        docker compose down
    fi
    
    # 询问是否删除数据
    read -p "是否删除安装目录 $INSTALL_DIR? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "安装目录已删除"
    fi
    
    print_success "RocketMQ Console 卸载完成"
}

# === 主函数 ===
main() {
    print_header "RocketMQ Console 一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_console
        exit 0
    fi
    
    # 安装 Console
    install_console
    
    print_header "安装完成!"
    print_success "RocketMQ Console 已成功安装"
    print_info "安装目录: $INSTALL_DIR"
    print_info "访问地址: http://localhost:${PORT}"
    print_info "NameServer: ${ROCKETMQ_NAME_SERVER}"
    
    print_info "管理命令:"
    print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
    print_info "  停止: cd $INSTALL_DIR && docker compose down"
    print_info "  日志: cd $INSTALL_DIR && docker compose logs -f"
    print_info "  重启: cd $INSTALL_DIR && docker compose restart"
}

# === 执行主函数 ===
main "$@"
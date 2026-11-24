#!/bin/bash

# XXL-JOB 启动脚本

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="$HOME/xxl-job"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"

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
XXL-JOB 启动脚本

用法: ./startup.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: ~/xxl-job)
    -h, --help          显示此帮助信息

示例:
    ./startup.sh                      # 使用默认设置启动
    ./startup.sh --dir /opt/xxl-job   # 指定安装目录
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
        print_error "XXL-JOB 未安装，请先运行 install-xxl-job.sh"
        exit 1
    fi
    
    if [[ ! -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        print_error "未找到 docker-compose.yml，请先运行 install-xxl-job.sh"
        exit 1
    fi
}

# === 检查 Docker ===
check_docker() {
    if ! command -v docker &>/dev/null; then
        print_error "未检测到 Docker"
        exit 1
    fi
    
    if ! command -v docker compose &>/dev/null; then
        print_error "未检测到 Docker Compose"
        exit 1
    fi
}

# === 检查是否已运行 ===
check_running() {
    if docker compose -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ps | grep -q "Up"; then
        print_warning "XXL-JOB 已在运行"
        print_info "如需重启，请先运行: ./stop.sh"
        exit 0
    fi
}

# === 启动 XXL-JOB ===
start_xxl_job() {
    print_info "启动 XXL-JOB..."
    
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "XXL-JOB 启动成功"
    
    # 获取端口
    PORT=$(docker compose -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ps | grep xxl-job-admin | grep -oP '0.0.0.0:\K[0-9]+' | head -1)
    
    print_info "访问地址: http://localhost:${PORT}/xxl-job-admin"
    print_info "默认账号: admin / 123456"
    print_info "查看日志: docker compose -f $INSTALL_DIR/$DOCKER_COMPOSE_FILE logs -f"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已安装
    check_installed
    
    # 检查 Docker
    check_docker
    
    # 检查是否已运行
    check_running
    
    # 启动 XXL-JOB
    start_xxl_job
}

# === 执行主函数 ===
main "$@"
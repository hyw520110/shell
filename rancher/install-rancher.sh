#!/bin/bash

# Rancher 一键安装配置脚本
# Kubernetes 管理平台

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
readonly RANCHER_VERSION="v2.8.5"
readonly RANCHER_IMAGE="rancher/rancher"
readonly DEFAULT_INSTALL_DIR="$HOME/rancher"
readonly DEFAULT_HTTP_PORT=8080
readonly DEFAULT_HTTPS_PORT=8443
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HTTP_PORT="$DEFAULT_HTTP_PORT"
HTTPS_PORT="$DEFAULT_HTTPS_PORT"
DATA_DIR="$INSTALL_DIR/data"
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
Rancher 一键安装配置脚本

用法: ./install-rancher.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/rancher)
    --http-port PORT            HTTP 端口 (默认: 8080)
    --https-port PORT           HTTPS 端口 (默认: 8443)
    --data-dir DIR              数据目录 (默认: ~/rancher/data)
    --dry-run                   试运行模式
    --uninstall                 卸载 Rancher

示例:
    ./install-rancher.sh                           # 默认安装
    ./install-rancher.sh --http-port 9000          # 自定义端口
    ./install-rancher.sh --https-port 9443         # 自定义 HTTPS 端口
    ./install-rancher.sh --uninstall               # 卸载 Rancher

使用指南:
    1. 安装完成后，访问: http://localhost:8080 或 https://localhost:8443
    2. 首次登录需要设置管理员密码
    3. Rancher 用于管理 Kubernetes 集群
    4. 支持导入现有集群或创建新集群

更多信息: https://rancher.com/docs/rancher/
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
            --http-port)
                HTTP_PORT="$2"
                shift 2
                ;;
            --https-port)
                HTTPS_PORT="$2"
                shift 2
                ;;
            --data-dir)
                DATA_DIR="$2"
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
check_ports() {
    local ports=("$HTTP_PORT" "$HTTPS_PORT")
    
    for port in "${ports[@]}"; do
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            print_warning "端口 $port 已被占用"
            read -p "是否继续? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    done
}

# === 安装 Rancher ===
install_rancher() {
    print_header "安装 Rancher"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将安装 Rancher"
        print_info "  安装目录: $INSTALL_DIR"
        print_info "  HTTP 端口: $HTTP_PORT"
        print_info "  HTTPS 端口: $HTTPS_PORT"
        print_info "  数据目录: $DATA_DIR"
        return 0
    fi
    
    # 检查端口
    check_ports
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    
    # 生成 docker-compose.yml
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  rancher:
    image: ${RANCHER_IMAGE}:${RANCHER_VERSION}
    container_name: rancher
    restart: unless-stopped
    privileged: true
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ${DATA_DIR}:/var/lib/rancher
      - ${INSTALL_DIR}/auditlog:/var/log/auditlog
    environment:
      - "CATTLE_SYSTEM_DEFAULT_REGISTRY=docker.io"
      - "CATTLE_SYSTEM_CATALOG=bundled"
      - "AUDIT_LOG_LEVEL=3"
      - "AUDIT_LOG_PATH=/var/log/auditlog/rancher-audit.log"
    networks:
      - rancher-network

networks:
  rancher-network:
    driver: bridge
EOF

    print_success "docker-compose.yml 生成成功"
    
    # 启动服务
    cd "$INSTALL_DIR"
    docker compose up -d
    
    # 等待服务启动
    print_info "等待 Rancher 启动..."
    sleep 10
    
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

# === 卸载 Rancher ===
uninstall_rancher() {
    print_header "卸载 Rancher"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 Rancher"
        return 0
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_warning "Rancher 未安装"
        exit 0
    fi
    
    # 停止服务
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        print_info "停止 Rancher 服务..."
        cd "$INSTALL_DIR"
        docker compose down
    fi
    
    # 询问是否删除数据
    read -p "是否删除数据目录 $DATA_DIR? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR"
        print_success "数据目录已删除"
    fi
    
    # 询问是否删除审计日志
    if [[ -d "$INSTALL_DIR/auditlog" ]]; then
        read -p "是否删除审计日志目录 $INSTALL_DIR/auditlog? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR/auditlog"
            print_success "审计日志目录已删除"
        fi
    fi
    
    # 询问是否删除安装目录
    read -p "是否删除安装目录 $INSTALL_DIR? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "安装目录已删除"
    fi
    
    print_success "Rancher 卸载完成"
}

# === 主函数 ===
main() {
    print_header "Rancher 一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_rancher
        exit 0
    fi
    
    # 安装 Rancher
    install_rancher
    
    print_header "安装完成!"
    print_success "Rancher 已成功安装"
    print_info "安装目录: $INSTALL_DIR"
    print_info "数据目录: $DATA_DIR"
    print_info "HTTP 访问地址: http://localhost:${HTTP_PORT}"
    print_info "HTTPS 访问地址: https://localhost:${HTTPS_PORT}"
    
    print_info "管理命令:"
    print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
    print_info "  停止: cd $INSTALL_DIR && docker compose down"
    print_info "  日志: cd $INSTALL_DIR && docker compose logs -f"
    print_info "  重启: cd $INSTALL_DIR && docker compose restart"
    
    print_info "注意事项:"
    print_info "  1. 首次访问需要设置管理员密码"
    print_info "  2. 建议在生产环境中使用 HTTPS"
    print_info "  3. 定期备份数据目录: $DATA_DIR"
}

# === 执行主函数 ===
main "$@"
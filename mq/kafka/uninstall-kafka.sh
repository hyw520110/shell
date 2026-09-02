#!/bin/bash

# Kafka 卸载脚本
# 完全清理 Kafka 及相关数据

set -e
set -u
set -o pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 默认配置 ===
readonly DEFAULT_INSTALL_DIR="$HOME/kafka"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_MODE=false
KEEP_DATA=false

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

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Kafka 卸载脚本

用法：./uninstall-kafka.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           Kafka 安装目录 (默认：~/kafka)
    -f, --force             强制卸载，不确认提示
    --keep-data             保留数据文件，仅删除配置和容器
    --dry-run               试运行模式（不实际删除）

示例:
    ./uninstall-kafka.sh                    # 交互式卸载
    ./uninstall-kafka.sh --force            # 强制卸载
    ./uninstall-kafka.sh --keep-data        # 保留数据文件
    ./uninstall-kafka.sh -d /opt/kafka      # 指定安装目录

警告:
    此操作将删除 Kafka 容器、配置和数据，请提前备份重要数据！
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
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                print_error "未知选项：$1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 确认卸载 ===
confirm_uninstall() {
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    print_warning "=========================================="
    print_warning "       Kafka 卸载确认"
    print_warning "=========================================="
    echo ""
    echo "安装目录：$INSTALL_DIR"
    echo ""
    
    if [[ "$KEEP_DATA" == "true" ]]; then
        echo "将保留数据文件，仅删除："
        echo "  - Docker 容器和网络"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    else
        echo "将删除以下内容："
        echo "  - Docker 容器和网络"
        echo "  - 所有数据文件"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    fi
    
    echo ""
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[Dry-run] 继续卸载..."
        return 0
    fi
    
    read -p "确定要继续卸载吗？此操作不可逆！(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
}

# === 停止服务 ===
stop_service() {
    print_header "停止 Kafka 服务"
    
    # 检查 systemd 服务
    if [[ -f /etc/systemd/system/kafka.service ]]; then
        print_info "停止 systemd 服务..."
        if command -v systemctl &> /dev/null; then
            systemctl stop kafka 2>/dev/null || print_warning "停止 systemd 服务失败"
            systemctl disable kafka 2>/dev/null || true
        fi
    fi
    
    # 停止 Docker 容器
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        print_info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        
        if command -v docker compose &> /dev/null; then
            docker compose down 2>/dev/null || print_warning "停止容器失败"
        else
            docker-compose down 2>/dev/null || print_warning "停止容器失败"
        fi
    else
        # 尝试直接停止容器
        print_info "尝试直接停止 Docker 容器..."
        docker stop kafka 2>/dev/null || true
        docker stop zookeeper 2>/dev/null || true
    fi
    
    print_success "服务已停止"
}

# === 删除容器和网络 ===
remove_containers() {
    print_header "删除 Docker 资源"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 Docker 容器和网络"
        return
    fi
    
    # 删除容器
    print_info "删除容器..."
    docker rm -f kafka 2>/dev/null || true
    docker rm -f zookeeper 2>/dev/null || true
    
    # 删除网络
    print_info "删除网络..."
    docker network rm kafka_kafka-network 2>/dev/null || true
    
    # 删除卷（如果未保留数据）
    if [[ "$KEEP_DATA" != "true" ]]; then
        print_info "删除数据卷..."
        docker volume ls -q | grep -i kafka | xargs -r docker volume rm -f 2>/dev/null || true
    fi
    
    print_success "Docker 资源已清理"
}

# === 删除文件 ===
remove_files() {
    print_header "删除文件"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除目录：$INSTALL_DIR"
        return
    fi
    
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$KEEP_DATA" == "true" ]]; then
            # 保留数据目录
            print_info "保留数据目录..."
            rm -rf "$INSTALL_DIR/bin"
            rm -rf "$INSTALL_DIR/conf"
            rm -rf "$INSTALL_DIR/logs"
            rm -f "$INSTALL_DIR/docker-compose.yml"
            rm -f "$INSTALL_DIR/.env"
        else
            # 删除所有内容
            print_warning "删除整个安装目录：$INSTALL_DIR"
            rm -rf "$INSTALL_DIR"
        fi
        
        print_success "文件已删除"
    else
        print_info "安装目录不存在：$INSTALL_DIR"
    fi
}

# === 删除 systemd 服务 ===
remove_systemd_service() {
    print_header "删除 systemd 服务"
    
    local SERVICE_FILE="/etc/systemd/system/kafka.service"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 systemd 服务文件"
        return
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_info "停止并禁用服务..."
        systemctl stop kafka 2>/dev/null || true
        systemctl disable kafka 2>/dev/null || true
        
        print_info "删除服务文件..."
        rm -f "$SERVICE_FILE"
        
        print_info "重新加载 systemd 配置..."
        systemctl daemon-reload 2>/dev/null || true
        
        print_success "systemd 服务已删除"
    else
        print_info "Kafka systemd 服务不存在"
    fi
}

# === 清理 Docker 镜像（可选）===
cleanup_images() {
    print_header "清理 Docker 镜像（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 Kafka 和 ZooKeeper 镜像"
        return
    fi
    
    read -p "是否删除 Kafka 和 ZooKeeper Docker 镜像？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除镜像..."
        docker rmi -f apache/kafka:* 2>/dev/null || true
        docker rmi -f apache/zookeeper:* 2>/dev/null || true
        print_success "镜像已删除"
    else
        print_info "保留镜像"
    fi
}

# === 显示卸载摘要 ===
show_summary() {
    print_header "卸载完成"
    
    cat << EOF
${GREEN}Kafka 卸载成功！${NC}

已删除:
  - Docker 容器 (kafka, zookeeper)
  - Docker 网络
  - systemd 服务配置
  - 配置文件和脚本
EOF

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  - 数据文件"
    else
        echo -e "  ${GREEN}保留数据文件${NC}"
    fi

    cat << EOF

如需重新安装，请运行:
  cd /path/to/shell/mq/kafka
  ./install-kafka.sh

EOF
}

# === 主函数 ===
main() {
    print_header "Apache Kafka 卸载脚本"
    
    parse_arguments "$@"
    
    echo ""
    echo "卸载配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  保留数据：$KEEP_DATA"
    echo "  强制模式：$FORCE_MODE"
    echo ""
    
    confirm_uninstall
    stop_service
    remove_containers
    remove_files
    remove_systemd_service
    cleanup_images
    show_summary
}

# 执行主函数
main "$@"

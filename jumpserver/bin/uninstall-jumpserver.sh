#!/bin/bash

# JumpServer 卸载脚本
# 完全清理 JumpServer 及相关数据

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
readonly DEFAULT_INSTALL_DIR="/data/jumpserver"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_MODE=false
KEEP_DATA=false
DRY_RUN=false

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
JumpServer 卸载脚本

用法：./bin/uninstall-jumpserver.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           JumpServer 安装目录 (默认：/data/jumpserver)
    -f, --force             强制卸载，不确认提示
    --keep-data             保留数据文件，仅删除配置和容器
    --dry-run               试运行模式（不实际删除）

示例:
    ./bin/uninstall-jumpserver.sh              # 交互式卸载
    ./bin/uninstall-jumpserver.sh --force      # 强制卸载
    ./bin/uninstall-jumpserver.sh --keep-data  # 保留数据文件
    ./bin/uninstall-jumpserver.sh -d /opt/jms  # 指定安装目录

警告:
    此操作将删除 JumpServer 容器、配置和审计数据，请提前备份重要数据！
    备份命令：docker exec jms_mysql mysqldump -ujumpserver -p jumpserver > backup.sql
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
    print_warning "       JumpServer 卸载确认"
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
        echo "  - 所有审计数据"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    fi
    
    echo ""
    echo "建议在卸载前执行备份："
    echo "  # 备份数据库"
    echo "  docker exec jms_mysql mysqldump -ujumpserver -p${DB_PASSWORD:-jumpserver123} jumpserver > jumpserver_backup.sql"
    echo "  # 备份审计录像"
    echo "  rsync -av $INSTALL_DIR/data/core/ /backup/jumpserver/"
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
    print_header "停止 JumpServer 服务"
    
    # 检查 systemd 服务
    if [[ -f /etc/systemd/system/jumpserver.service ]]; then
        print_info "停止 systemd 服务..."
        if command -v systemctl &> /dev/null; then
            systemctl stop jumpserver 2>/dev/null || print_warning "停止 systemd 服务失败"
            systemctl disable jumpserver 2>/dev/null || true
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
        docker stop jms_core jms_mysql jms_redis jms_koko jms_lion jms_magnus jms_web jms_celery 2>/dev/null || true
    fi
    
    print_success "服务已停止"
}

# === 删除 Docker 资源 ===
remove_docker_resources() {
    print_header "删除 Docker 资源"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 Docker 容器和网络"
        return
    fi
    
    # 删除容器
    print_info "删除容器..."
    docker rm -f jms_core 2>/dev/null || true
    docker rm -f jms_mysql 2>/dev/null || true
    docker rm -f jms_redis 2>/dev/null || true
    docker rm -f jms_koko 2>/dev/null || true
    docker rm -f jms_lion 2>/dev/null || true
    docker rm -f jms_magnus 2>/dev/null || true
    docker rm -f jms_web 2>/dev/null || true
    docker rm -f jms_celery 2>/dev/null || true
    
    # 删除网络
    print_info "删除网络..."
    docker network rm jumpserver_jumpserver-network 2>/dev/null || true
    
    # 删除卷（如果未保留数据）
    if [[ "$KEEP_DATA" != "true" ]]; then
        print_info "删除数据卷..."
        docker volume ls -q | grep -i jumpserver | xargs -r docker volume rm -f 2>/dev/null || true
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
            rm -rf "$INSTALL_DIR/logs"
            rm -rf "$INSTALL_DIR/conf"
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
    
    local SERVICE_FILE="/etc/systemd/system/jumpserver.service"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 systemd 服务文件"
        return
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_info "停止并禁用服务..."
        systemctl stop jumpserver 2>/dev/null || true
        systemctl disable jumpserver 2>/dev/null || true
        
        print_info "删除服务文件..."
        rm -f "$SERVICE_FILE"
        
        print_info "重新加载 systemd 配置..."
        systemctl daemon-reload 2>/dev/null || true
        
        print_success "systemd 服务已删除"
    else
        print_info "JumpServer systemd 服务不存在"
    fi
}

# === 清理 Docker 镜像（可选）===
cleanup_images() {
    print_header "清理 Docker 镜像（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 JumpServer 相关镜像"
        return
    fi
    
    read -p "是否删除 JumpServer 相关 Docker 镜像？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除镜像..."
        docker rmi -f jumpserver/jumpserver:* 2>/dev/null || true
        docker rmi -f mariadb:10.11 2>/dev/null || true
        docker rmi -f redis:7-alpine 2>/dev/null || true
        print_success "镜像已删除"
    else
        print_info "保留镜像"
    fi
}

# === 显示卸载摘要 ===
show_summary() {
    print_header "卸载完成"
    
    cat << EOF
${GREEN}JumpServer 卸载成功！${NC}

已删除:
  - Docker 容器 (jms_core, jms_mysql, jms_redis, etc.)
  - Docker 网络
  - systemd 服务配置
  - 配置文件和脚本
EOF

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  - 审计数据和录像"
    else
        echo -e "  ${GREEN}保留数据文件${NC}"
    fi

    cat << EOF

如需重新安装，请运行:
  cd /path/to/shell/jumpserver
  ./bin/install-jumpserver.sh

EOF
}

# === 主函数 ===
main() {
    print_header "JumpServer 堡垒机卸载脚本"
    
    parse_arguments "$@"
    
    echo ""
    echo "卸载配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  保留数据：$KEEP_DATA"
    echo "  强制模式：$FORCE_MODE"
    echo ""
    
    confirm_uninstall
    stop_service
    remove_docker_resources
    remove_files
    remove_systemd_service
    cleanup_images
    show_summary
}

# 执行主函数
main "$@"

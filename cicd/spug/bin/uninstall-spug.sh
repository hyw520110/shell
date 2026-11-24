#!/bin/bash

# Spug 卸载脚本
# 完全清理 Spug 及相关数据

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
readonly DEFAULT_INSTALL_DIR="$HOME/spug"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_MODE=false
KEEP_DATA=false
DRY_RUN=false
INSTALL_MODE="auto"

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
Spug 卸载脚本

用法：./bin/uninstall-spug.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           Spug 安装目录 (默认：$HOME/spug)
    -f, --force             强制卸载，不确认提示
    --keep-data             保留数据文件，仅删除配置和容器
    --mode MODE             卸载模式 (auto|docker|host，默认：auto)
    --dry-run               试运行模式（不实际删除）

示例:
    ./bin/uninstall-spug.sh              # 交互式卸载
    ./bin/uninstall-spug.sh --force      # 强制卸载
    ./bin/uninstall-spug.sh --keep-data  # 保留数据文件
    ./bin/uninstall-spug.sh -d /opt/spug # 指定安装目录

警告:
    此操作将删除 Spug 容器、配置和数据，请提前备份重要数据！
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
            --mode)
                INSTALL_MODE="$2"
                shift 2
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

# === 检查是否安装 Docker ===
check_docker() {
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

# === 确定卸载模式 ===
detect_install_mode() {
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        # 检测安装模式
        if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            INSTALL_MODE="docker"
        elif [[ -f /etc/systemd/system/spug.service ]] || [[ -f /etc/init.d/spug ]]; then
            INSTALL_MODE="host"
        elif check_docker; then
            # 检查是否有 Spug 容器
            if docker ps -a --format '{{.Names}}' | grep -q "^spug"; then
                INSTALL_MODE="docker"
            else
                INSTALL_MODE="docker"  # 默认使用 Docker 模式
            fi
        else
            INSTALL_MODE="host"
        fi
        print_info "检测到安装模式：$INSTALL_MODE"
    fi
}

# === 确认卸载 ===
confirm_uninstall() {
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    print_warning "=========================================="
    print_warning "       Spug 卸载确认"
    print_warning "=========================================="
    echo ""
    echo "安装目录：$INSTALL_DIR"
    echo "卸载模式：$INSTALL_MODE"
    echo ""
    
    if [[ "$KEEP_DATA" == "true" ]]; then
        echo "将保留数据文件，仅删除："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        fi
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd/init.d 服务配置"
    else
        echo "将删除以下内容："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        fi
        echo "  - 所有数据文件"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd/init.d 服务配置"
    fi
    
    echo ""
    echo "建议在卸载前执行备份："
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  docker exec spug tar czf /data/spug/backup.tar.gz /data/spug"
    else
        echo "  mysqldump -u root -p spug > spug_backup.sql"
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
    print_header "停止 Spug 服务"
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # Docker 模式
        if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            print_info "停止 Docker 容器..."
            cd "$INSTALL_DIR"
            
            if command -v docker compose &> /dev/null; then
                docker compose down 2>/dev/null || print_warning "停止容器失败"
            else
                docker-compose down 2>/dev/null || print_warning "停止容器失败"
            fi
        else
            print_info "尝试直接停止 Docker 容器..."
            docker stop spug 2>/dev/null || true
            docker stop spug-db 2>/dev/null || true
        fi
    else
        # 主机模式
        print_info "停止 systemd/init.d 服务..."
        
        if [[ -f /etc/systemd/system/spug.service ]]; then
            systemctl stop spug 2>/dev/null || true
        elif [[ -f /etc/init.d/spug ]]; then
            /etc/init.d/spug stop 2>/dev/null || true
        else
            pkill -f "manage.py runserver" 2>/dev/null || true
        fi
        
        print_info "停止 Nginx..."
        systemctl stop nginx 2>/dev/null || true
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
    docker rm -f spug 2>/dev/null || true
    docker rm -f spug-db 2>/dev/null || true
    
    # 删除网络
    print_info "删除网络..."
    docker network rm spug_spug-network 2>/dev/null || true
    
    # 删除卷（如果未保留数据）
    if [[ "$KEEP_DATA" != "true" ]]; then
        print_info "删除数据卷..."
        docker volume ls -q | grep -i spug | xargs -r docker volume rm -f 2>/dev/null || true
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

# === 删除服务配置 ===
remove_service_config() {
    print_header "删除服务配置"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除服务配置文件"
        return
    fi
    
    # systemd 服务
    if [[ -f /etc/systemd/system/spug.service ]]; then
        print_info "停止并禁用 systemd 服务..."
        systemctl stop spug 2>/dev/null || true
        systemctl disable spug 2>/dev/null || true
        rm -f /etc/systemd/system/spug.service
        systemctl daemon-reload 2>/dev/null || true
        print_success "systemd 服务已删除"
    fi
    
    # init.d 服务
    if [[ -f /etc/init.d/spug ]]; then
        print_info "删除 init.d 服务..."
        if command -v chkconfig &> /dev/null; then
            chkconfig --del spug 2>/dev/null || true
        fi
        rm -f /etc/init.d/spug
        print_success "init.d 服务已删除"
    fi
    
    # Nginx 配置（主机模式）
    if [[ -f /etc/nginx/conf.d/spug.conf ]]; then
        print_info "删除 Nginx 配置..."
        rm -f /etc/nginx/conf.d/spug.conf
        nginx -s reload 2>/dev/null || true
        print_success "Nginx 配置已删除"
    fi
}

# === 清理数据库（可选）===
cleanup_database() {
    print_header "清理数据库（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 MySQL 数据库"
        return
    fi
    
    if [[ "$KEEP_DATA" == "true" ]]; then
        print_info "保留数据库，跳过清理"
        return
    fi
    
    read -p "是否删除 MySQL 数据库和用户？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除数据库和用户..."
        
        # 尝试使用默认密码
        local passwords=("spug.cc" "" "root" "123456")
        for pwd in "${passwords[@]}"; do
            if mysql -uroot -p"${pwd}" -e "DROP DATABASE IF EXISTS spug;" 2>/dev/null; then
                mysql -uroot -p"${pwd}" -e "DROP USER IF EXISTS 'spug'@'localhost';" 2>/dev/null || true
                print_success "数据库已清理"
                break
            fi
        done
    else
        print_info "保留数据库"
    fi
}

# === 清理 Docker 镜像（可选）===
cleanup_images() {
    print_header "清理 Docker 镜像（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 Spug 相关镜像"
        return
    fi
    
    if [[ "$INSTALL_MODE" != "docker" ]]; then
        print_info "非 Docker 模式，跳过"
        return
    fi
    
    read -p "是否删除 Spug 相关 Docker 镜像？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除镜像..."
        docker rmi -f openspug/spug-service:latest 2>/dev/null || true
        docker rmi -f registry.cn-hangzhou.aliyuncs.com/openspug/spug-service 2>/dev/null || true
        docker rmi -f registry.cn-hangzhou.aliyuncs.com/openspug/mariadb:10.8.2 2>/dev/null || true
        print_success "镜像已删除"
    else
        print_info "保留镜像"
    fi
}

# === 显示卸载摘要 ===
show_summary() {
    print_header "卸载完成"
    
    cat << EOF
${GREEN}Spug 卸载成功！${NC}

已删除:
EOF

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  - Docker 容器 (spug, spug-db)"
        echo "  - Docker 网络"
    else
        echo "  - systemd/init.d 服务配置"
        echo "  - Nginx 配置"
    fi

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  - 数据文件"
    else
        echo -e "  ${GREEN}保留数据文件${NC}"
    fi

    cat << EOF

如需重新安装，请运行:
  cd /path/to/shell/cicd/spug
  ./bin/install-spug.sh

EOF
}

# === 主函数 ===
main() {
    print_header "Spug 自动化运维平台卸载脚本"
    
    parse_arguments "$@"
    
    detect_install_mode
    
    echo ""
    echo "卸载配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  卸载模式：$INSTALL_MODE"
    echo "  保留数据：$KEEP_DATA"
    echo "  强制模式：$FORCE_MODE"
    echo ""
    
    confirm_uninstall
    stop_service
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        remove_docker_resources
    fi
    
    remove_files
    remove_service_config
    cleanup_database
    cleanup_images
    show_summary
}

# 执行主函数
main "$@"

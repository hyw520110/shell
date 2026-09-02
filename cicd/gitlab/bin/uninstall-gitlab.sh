#!/bin/bash

# GitLab 卸载脚本
# 完全清理 GitLab 及相关数据

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
readonly DEFAULT_INSTALL_DIR="$HOME/gitlab"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_MODE=false
KEEP_DATA=false
DRY_RUN=false
INSTALL_MODE="auto"
OS_TYPE=""

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
GitLab 卸载脚本

用法：./bin/uninstall-gitlab.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           GitLab 安装目录 (默认：$HOME/gitlab)
    -f, --force             强制卸载，不确认提示
    --keep-data             保留数据文件，仅删除配置和容器
    --mode MODE             卸载模式 (auto|docker|host，默认：auto)
    --dry-run               试运行模式（不实际删除）

示例:
    ./bin/uninstall-gitlab.sh              # 交互式卸载
    ./bin/uninstall-gitlab.sh --force      # 强制卸载
    ./bin/uninstall-gitlab.sh --keep-data  # 保留数据文件
    ./bin/uninstall-gitlab.sh --mode docker # Docker 模式卸载

警告:
    此操作将删除 GitLab 容器/服务、配置和代码数据，请提前备份重要数据！
    备份命令：
    - Docker: docker exec gitlab gitlab-rake gitlab:backup:create
    - 主机：gitlab-rake gitlab:backup:create
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

# === 检测操作系统 ===
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
    elif [[ -f /etc/debian_version ]]; then
        OS_TYPE="ubuntu"
    else
        OS_TYPE="unknown"
    fi
}

# === 确定安装模式 ===
detect_install_mode() {
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        # 检测安装模式
        if [[ -f /etc/gitlab/gitlab.rb ]]; then
            INSTALL_MODE="host"
            print_info "检测到主机模式安装（Omnibus 包）"
        elif [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker 模式安装"
        else
            # 检查 Docker 容器
            if command -v docker &> /dev/null; then
                if docker ps -a --format '{{.Names}}' | grep -q "^gitlab$"; then
                    INSTALL_MODE="docker"
                    print_info "检测到 Docker 容器"
                else
                    print_error "未检测到 GitLab 安装"
                    exit 1
                fi
            else
                print_error "未检测到 GitLab 安装"
                exit 1
            fi
        fi
    fi
}

# === 确认卸载 ===
confirm_uninstall() {
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    print_warning "=========================================="
    print_warning "       GitLab 卸载确认"
    print_warning "=========================================="
    echo ""
    echo "安装模式：$INSTALL_MODE"
    echo ""
    
    if [[ "$KEEP_DATA" == "true" ]]; then
        echo "将保留数据文件，仅删除："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        else
            echo "  - GitLab 服务"
        fi
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    else
        echo "将删除以下内容："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        else
            echo "  - GitLab 服务"
        fi
        echo "  - 所有代码和仓库数据"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    fi
    
    echo ""
    echo "建议在卸载前执行备份："
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  # 备份 GitLab 数据"
        echo "  docker exec gitlab gitlab-rake gitlab:backup:create"
        echo "  # 备份数据目录"
        echo "  rsync -av $INSTALL_DIR/data/ /backup/gitlab/"
    else
        echo "  # 备份 GitLab 数据"
        echo "  gitlab-rake gitlab:backup:create"
        echo "  # 备份配置"
        echo "  cp -r /etc/gitlab /backup/"
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
    print_header "停止 GitLab 服务"
    
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
            docker stop gitlab 2>/dev/null || true
        fi
    else
        # 主机模式
        print_info "停止 GitLab 服务..."
        if command -v gitlab-ctl &> /dev/null; then
            gitlab-ctl stop 2>/dev/null || print_warning "停止 GitLab 服务失败"
        else
            pkill -f gitlab 2>/dev/null || true
        fi
        
        # 停止 systemd 服务
        if command -v systemctl &> /dev/null; then
            systemctl stop gitlab-runsvdir 2>/dev/null || true
        fi
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
    docker rm -f gitlab 2>/dev/null || true
    
    # 删除网络
    print_info "删除网络..."
    docker network rm gitlab_gitlab-network 2>/dev/null || true
    
    # 删除卷（如果未保留数据）
    if [[ "$KEEP_DATA" != "true" ]]; then
        print_info "删除数据卷..."
        docker volume ls -q | grep -i gitlab | xargs -r docker volume rm -f 2>/dev/null || true
    fi
    
    print_success "Docker 资源已清理"
}

# === 删除文件 ===
remove_files() {
    print_header "删除文件"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除文件"
        return
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # Docker 模式
        if [[ -d "$INSTALL_DIR" ]]; then
            if [[ "$KEEP_DATA" == "true" ]]; then
                # 保留数据目录
                print_info "保留数据目录..."
                rm -rf "$INSTALL_DIR/bin"
                rm -f "$INSTALL_DIR/docker-compose.yml"
                rm -f "$INSTALL_DIR/.env"
            else
                # 删除所有内容
                print_warning "删除安装目录：$INSTALL_DIR"
                rm -rf "$INSTALL_DIR"
            fi
            
            print_success "文件已删除"
        fi
    else
        # 主机模式
        if [[ "$KEEP_DATA" == "true" ]]; then
            # 保留数据目录
            print_info "保留数据目录..."
            rm -rf /etc/gitlab
            rm -rf /var/log/gitlab
            rm -rf /opt/gitlab
        else
            # 删除所有内容
            print_warning "删除 GitLab 数据目录..."
            rm -rf /etc/gitlab
            rm -rf /var/opt/gitlab
            rm -rf /var/log/gitlab
            rm -rf /opt/gitlab
        fi
        
        print_success "文件已删除"
    fi
}

# === 删除服务配置 ===
remove_service_config() {
    print_header "删除服务配置"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除服务配置文件"
        return
    fi
    
    local services_deleted=0
    
    # Docker 模式 systemd 服务
    if [[ -f /etc/systemd/system/gitlab-docker.service ]]; then
        print_info "停止并禁用 gitlab-docker 服务..."
        systemctl stop gitlab-docker 2>/dev/null || true
        systemctl disable gitlab-docker 2>/dev/null || true
        rm -f /etc/systemd/system/gitlab-docker.service
        ((services_deleted++))
    fi
    
    # 主机模式 systemd 服务
    if [[ -f /etc/systemd/system/gitlab-runsvdir.service ]]; then
        print_info "禁用 gitlab-runsvdir 服务..."
        systemctl disable gitlab-runsvdir 2>/dev/null || true
        rm -f /etc/systemd/system/gitlab-runsvdir.service
        ((services_deleted++))
    fi
    
    if [[ $services_deleted -gt 0 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        print_success "已删除 $services_deleted 个 systemd 服务"
    else
        print_info "未发现 systemd 服务配置"
    fi
}

# === 卸载 GitLab 包（主机模式）===
uninstall_package() {
    print_header "卸载 GitLab 包"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 卸载 GitLab 包"
        return
    fi
    
    detect_os
    
    if [[ "$OS_TYPE" == "centos" ]]; then
        if command -v rpm &> /dev/null && rpm -q gitlab-ce &> /dev/null; then
            print_info "卸载 GitLab RPM 包..."
            yum remove -y gitlab-ce 2>/dev/null || true
        fi
    elif [[ "$OS_TYPE" == "ubuntu" ]]; then
        if command -v dpkg &> /dev/null && dpkg -l | grep -q gitlab-ce; then
            print_info "卸载 GitLab DEB 包..."
            apt-get purge -y gitlab-ce 2>/dev/null || true
        fi
    fi
    
    print_success "GitLab 包已卸载"
}

# === 清理 Docker 镜像（可选）===
cleanup_images() {
    print_header "清理 Docker 镜像（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 GitLab 相关镜像"
        return
    fi
    
    if [[ "$INSTALL_MODE" != "docker" ]]; then
        print_info "非 Docker 模式，跳过"
        return
    fi
    
    read -p "是否删除 GitLab Docker 镜像？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除镜像..."
        docker rmi -f gitlab/gitlab-ce:* 2>/dev/null || true
        print_success "镜像已删除"
    else
        print_info "保留镜像"
    fi
}

# === 显示卸载摘要 ===
show_summary() {
    print_header "卸载完成"
    
    cat << EOF
${GREEN}GitLab 卸载成功！${NC}

已删除:
EOF

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  - Docker 容器 (gitlab)"
        echo "  - Docker 网络"
    else
        echo "  - GitLab 服务"
        echo "  - systemd 服务配置"
    fi

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  - 代码和仓库数据"
        echo "  - 配置文件"
        echo "  - 日志文件"
    else
        echo -e "  ${GREEN}保留数据文件${NC}"
    fi

    cat << EOF

如需重新安装，请运行:
  cd /path/to/shell/gitlab
  ./bin/install-gitlab.sh

EOF
}

# === 主函数 ===
main() {
    print_header "GitLab 卸载脚本"
    
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
    
    if [[ "$INSTALL_MODE" == "host" ]]; then
        uninstall_package
    fi
    
    cleanup_images
    show_summary
}

# 执行主函数
main "$@"

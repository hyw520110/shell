#!/bin/bash

# GitLab 一键安装配置脚本
# GitLab 是完整的 DevOps 平台，支持代码管理、CI/CD、代码审查、问题跟踪等功能
# 支持 Docker Compose 和主机两种安装模式（推荐 Omnibus 包安装）

# === 自动 sudo 提权 ===
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

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

# === 常量定义 ===
readonly GITLAB_VERSION="16.6.0"
readonly GITLAB_PACKAGE="gitlab-ce-${GITLAB_VERSION}-ce.0.el7.x86_64.rpm"
readonly GITLAB_DOWNLOAD_URL="https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh"
readonly GITLAB_UBUNTU_URL="https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh"
readonly DEFAULT_GITLAB_DOMAIN="gitlab.local"
readonly DEFAULT_GITLAB_PORT="80"
readonly DEFAULT_GITLAB_SSH_PORT="22"

# === 生成随机密码 ===
generate_random_password() {
    openssl rand -base64 12 2>/dev/null || tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}
readonly DEFAULT_ROOT_PASSWORD=$(generate_random_password)

# === 全局变量 ===
INSTALL_MODE="auto"  # auto, docker, host
GITLAB_DOMAIN="$DEFAULT_GITLAB_DOMAIN"
GITLAB_PORT="$DEFAULT_GITLAB_PORT"
GITLAB_SSH_PORT="$DEFAULT_GITLAB_SSH_PORT"
ROOT_PASSWORD="$DEFAULT_ROOT_PASSWORD"
GITLAB_EMAIL="admin@example.com"
AUTO_START=true
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_DOWNLOAD=false

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

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 获取本机 IP 地址 ===
get_local_ip() {
    local ip=""
    
    # macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ip=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
    else
        # Linux
        ip=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
        
        # 备选方案
        if [[ -z "$ip" ]]; then
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        fi
        if [[ -z "$ip" ]]; then
            ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        fi
    fi
    
    echo "$ip"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
GitLab 一键安装配置脚本

GitLab 是完整的 DevOps 平台，支持：
- 代码管理（Git 仓库）
- CI/CD 流水线
- 代码审查（Merge Request）
- 问题跟踪（Issue）
- 容器 Registry
- 包管理
- Wiki 文档

用法：./bin/install-gitlab.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：$HOME/gitlab)
    --domain DOMAIN             GitLab 访问域名 (默认：gitlab.local)
    --port PORT                 HTTP 端口 (默认：80)
    --ssh-port PORT             SSH 端口 (默认：22)
    --root-password PWD         root 初始密码 (默认：gitlab123)
    --email EMAIL               管理员邮箱 (默认：admin@example.com)
    --mode MODE                 安装模式 (auto|docker|host，默认：auto)
    --auto-start                配置自启动服务
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 GitLab

示例:
    # Docker 模式（推荐，资源占用少）
    sudo ./bin/install-gitlab.sh --mode docker
    
    # 主机模式（Omnibus 包安装，功能完整）
    sudo ./bin/install-gitlab.sh --mode host
    
    # 指定域名和端口
    sudo ./bin/install-gitlab.sh --domain git.example.com --port 8080
    
    # 配置自启动
    sudo ./bin/install-gitlab.sh --auto-start
    
    # 卸载
    sudo ./bin/install-gitlab.sh --uninstall

使用指南:
    1. 访问 GitLab: http://<domain>:<port>
    2. 默认账号：root
    3. 默认密码：安装时设置的密码
    4. 首次登录请修改密码

更多信息：https://about.gitlab.com/
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
            --domain)
                GITLAB_DOMAIN="$2"
                shift 2
                ;;
            --port)
                GITLAB_PORT="$2"
                shift 2
                ;;
            --ssh-port)
                GITLAB_SSH_PORT="$2"
                shift 2
                ;;
            --root-password)
                ROOT_PASSWORD="$2"
                shift 2
                ;;
            --email)
                GITLAB_EMAIL="$2"
                shift 2
                ;;
            --mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --auto-start)
                AUTO_START=true
                shift
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

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"
    
    # 注意：root 权限检查已在脚本开头自动处理
    
    # 确定安装模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if check_docker; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，推荐使用 Docker Compose 模式安装"
        else
            INSTALL_MODE="host"
            print_info "未检测到 Docker，使用主机模式（Omnibus 包）安装"
        fi
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # 检查 Docker
        if ! check_docker; then
            print_error "Docker 未安装或无法运行"
            exit 1
        fi
        
        # 检查 Docker Compose
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            print_error "Docker Compose 未安装"
            exit 1
        fi
        
        # 检查内存（Docker 模式建议至少 4GB）
        if command -v free &> /dev/null; then
            local total_mem
            total_mem=$(free -m | awk '/^Mem:/{print $2}')
            if [[ "$total_mem" -lt 4096 ]]; then
                print_warning "总内存不足 4GB (${total_mem}MB)，可能影响 GitLab 运行"
            fi
        fi
        
        print_success "Docker 环境检查通过"
        
        # 检查端口占用
        if command -v lsof &> /dev/null; then
            if lsof -i :"$GITLAB_PORT" &> /dev/null; then
                print_warning "端口 $GITLAB_PORT 已被占用"
            fi
            if lsof -i :"$GITLAB_SSH_PORT" &> /dev/null; then
                print_warning "端口 $GITLAB_SSH_PORT 已被占用"
            fi
        fi
    else
        # 主机模式检查
        
        # 检查系统类型
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_error "macOS 不支持主机模式（Omnibus 包仅支持 Linux）"
            echo ""
            echo "请先安装 Docker Desktop for Mac："
            echo "  https://www.docker.com/products/docker-desktop"
            echo ""
            echo "安装 Docker 后重新运行此脚本，将自动使用 Docker 模式。"
            exit 1
        elif [[ -f /etc/redhat-release ]]; then
            OS_TYPE="centos"
            print_info "检测到 CentOS/RHEL 系统"
        elif [[ -f /etc/debian_version ]]; then
            OS_TYPE="ubuntu"
            print_info "检测到 Debian/Ubuntu 系统"
        else
            print_error "不支持的操作系统: $OSTYPE"
            echo "支持的系统：CentOS/RHEL, Debian/Ubuntu, macOS (需 Docker)"
            exit 1
        fi
        
        # 检查内存（主机模式建议至少 4GB）
        if command -v free &> /dev/null; then
            local total_mem
            total_mem=$(free -m | awk '/^Mem:/{print $2}')
            if [[ "$total_mem" -lt 4096 ]]; then
                print_warning "总内存不足 4GB (${total_mem}MB)，GitLab 推荐 4GB+ 内存"
            fi
        fi
        
        # 检查磁盘空间（建议至少 10GB）
        local available_disk
        available_disk=$(df -m / | awk 'NR==2 {print $4}')
        if [[ "$available_disk" -lt 10240 ]]; then
            print_warning "可用磁盘空间不足 10GB，建议清理空间"
        fi
        
        print_success "主机模式环境检查通过"
    fi
}

# === Docker Compose 模式安装 ===
docker_install() {
    print_header "Docker Compose 模式安装"
    
    # 创建安装目录
    create_directories
    
    # 创建 docker-compose.yml
    create_docker_compose
    
    # 创建环境变量文件
    create_env_file
    
    # 创建启动脚本
    create_startup_script
    
    # 创建停止脚本
    create_stop_script
    
    # 创建状态脚本
    create_status_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "是否立即启动 GitLab？(y/N)"
        read -r -p "> " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            start_docker_service
            
            if [[ "$AUTO_START" == "true" ]]; then
                configure_docker_autostart
            fi
        fi
    fi
}

# === 创建安装目录 ===
create_directories() {
    print_header "创建安装目录"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建目录"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    mkdir -p "$INSTALL_DIR"/{data/{config,logs,data},bin}
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === 创建 docker-compose.yml ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  gitlab:
    image: gitlab/gitlab-ce:${GITLAB_VERSION}
    container_name: gitlab
    hostname: ${GITLAB_DOMAIN}
    restart: unless-stopped
    ports:
      - "${GITLAB_PORT}:80"
      - "${GITLAB_SSH_PORT}:22"
      - "8443:443"
    environment:
      - GITLAB_OMNIBUS_CONFIG=external_url 'http://${GITLAB_DOMAIN}:${GITLAB_PORT}'
      - GITLAB_ROOT_PASSWORD=${ROOT_PASSWORD}
      - GITLAB_ROOT_EMAIL=${GITLAB_EMAIL}
      - TZ=Asia/Shanghai
    volumes:
      - $INSTALL_DIR/data/config:/etc/gitlab
      - $INSTALL_DIR/data/logs:/var/log/gitlab
      - $INSTALL_DIR/data/data:/var/opt/gitlab
    shm_size: '256m'
    networks:
      - gitlab-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 300s

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: unless-stopped
    volumes:
      - $INSTALL_DIR/data/runner:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      gitlab:
        condition: service_healthy
    networks:
      - gitlab-network

networks:
  gitlab-network:
    driver: bridge
EOF
    
    print_success "Docker Compose 文件创建完成"
}

# === 创建环境变量文件 ===
create_env_file() {
    print_header "创建环境变量配置"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 .env 文件"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    cat > "$INSTALL_DIR/.env" << EOF
GITLAB_VERSION=${GITLAB_VERSION}
GITLAB_DOMAIN=${GITLAB_DOMAIN}
GITLAB_PORT=${GITLAB_PORT}
GITLAB_SSH_PORT=${GITLAB_SSH_PORT}
GITLAB_ROOT_PASSWORD=${ROOT_PASSWORD}
GITLAB_ROOT_EMAIL=${GITLAB_EMAIL}
EOF
    
    print_success "环境变量配置创建完成"
}

# === 主机模式安装（Omnibus 包）===
host_install() {
    print_header "主机模式安装（Omnibus 包）"
    
    # 检查系统类型
    detect_os
    
    # 安装依赖
    install_dependencies
    
    # 下载并安装 GitLab
    install_gitlab_package
    
    # 配置 GitLab
    configure_gitlab
    
    # 创建启动脚本
    create_host_scripts
    
    # 启动 GitLab
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "是否立即启动 GitLab？(y/N)"
        read -r -p "> " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            start_host_service
            
            if [[ "$AUTO_START" == "true" ]]; then
                configure_host_autostart
            fi
        fi
    fi
}

# === 检测操作系统 ===
detect_os() {
    print_info "检测操作系统..."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_error "macOS 不支持主机模式"
        exit 1
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
        OS_VERSION=$(cat /etc/redhat-release | grep -oP '\d+' | head -1)
        print_info "检测到 CentOS/RHEL $OS_VERSION"
    elif [[ -f /etc/debian_version ]]; then
        OS_TYPE="ubuntu"
        if [[ -f /etc/lsb-release ]]; then
            OS_VERSION=$(lsb_release -rs)
        fi
        print_info "检测到 Debian/Ubuntu"
    else
        print_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
}

# === 安装依赖 ===
install_dependencies() {
    print_header "安装依赖"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 安装依赖"
        return
    fi
    
    if [[ "$OS_TYPE" == "centos" ]]; then
        print_info "安装 CentOS 依赖..."
        yum install -y curl policycoreutils openssh-server openssh-clients postfix
        systemctl enable sshd
        systemctl start sshd
        systemctl enable postfix
        systemctl start postfix
    else
        print_info "安装 Debian/Ubuntu 依赖..."
        apt-get update
        apt-get install -y curl openssh-server ca-certificates postfix
    fi
    
    print_success "依赖安装完成"
}

# === 安装 GitLab 包 ===
install_gitlab_package() {
    print_header "下载并安装 GitLab"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载并安装 GitLab $GITLAB_VERSION"
        return
    fi
    
    if [[ "$OS_TYPE" == "centos" ]]; then
        print_info "添加 GitLab YUM 仓库..."
        curl -sS "$GITLAB_DOWNLOAD_URL" | bash
        
        print_info "安装 GitLab CE..."
        yum install -y gitlab-ce
    else
        print_info "添加 GitLab APT 仓库..."
        curl -sS "$GITLAB_UBUNTU_URL" | bash
        
        print_info "安装 GitLab CE..."
        apt-get install -y gitlab-ce
    fi
    
    print_success "GitLab 安装完成"
}

# === 配置 GitLab ===
configure_gitlab() {
    print_header "配置 GitLab"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 GitLab"
        return
    fi
    
    # 备份原配置
    if [[ -f /etc/gitlab/gitlab.rb ]]; then
        cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.bak
    fi
    
    # 生成新配置
    cat > /etc/gitlab/gitlab.rb << EOF
# GitLab 配置文件

# 外部访问 URL
external_url 'http://${GITLAB_DOMAIN}:${GITLAB_PORT}'

# GitLab Root 密码
gitlab_rails['initial_root_password'] = '${ROOT_PASSWORD}'

# 时区设置
gitlab_rails['time_zone'] = 'Asia/Shanghai'

# Git Shell 端口
gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}

# Nginx 配置
nginx['listen_port'] = ${GITLAB_PORT}
nginx['listen_https'] = false

# 邮箱配置
gitlab_rails['gitlab_email_enabled'] = true
gitlab_rails['gitlab_email_from'] = '${GITLAB_EMAIL}'
gitlab_rails['gitlab_email_display_name'] = 'GitLab'

# 备份配置
gitlab_rails['backup_path'] = '/var/opt/gitlab/backups'
gitlab_rails['backup_keep_time'] = 604800

# Prometheus 监控
prometheus_monitoring['enable'] = true
EOF
    
    print_success "GitLab 配置完成"
}

# === 创建主机模式脚本 ===
create_host_scripts() {
    print_header "创建管理脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建管理脚本"
        return
    fi
    
    mkdir -p "$HOME/gitlab/bin"
    
    # 启动脚本
    cat > "$HOME/gitlab/bin/startup.sh" << 'EOF'
#!/bin/bash
echo "正在启动 GitLab..."
gitlab-ctl reconfigure
gitlab-ctl restart
echo ""
echo "GitLab 启动完成！"
echo "访问地址：http://<domain>:<port>"
echo "账号：root"
EOF
    chmod +x "$HOME/gitlab/bin/startup.sh"
    
    # 停止脚本
    cat > "$HOME/gitlab/bin/stop.sh" << 'EOF'
#!/bin/bash
echo "正在停止 GitLab..."
gitlab-ctl stop
echo ""
echo "GitLab 已停止"
EOF
    chmod +x "$HOME/gitlab/bin/stop.sh"
    
    # 状态脚本
    cat > "$HOME/gitlab/bin/status.sh" << 'EOF'
#!/bin/bash
echo "=== GitLab 服务状态 ==="
gitlab-ctl status
echo ""
echo "=== 进程状态 ==="
gitlab-ctl proc-status
echo ""
echo "=== 磁盘使用 ==="
df -h /var/opt/gitlab
EOF
    chmod +x "$HOME/gitlab/bin/status.sh"
    
    print_success "管理脚本创建完成"
}

# === 创建启动脚本（Docker 模式）===
create_startup_script() {
    print_header "创建启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/startup.sh"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    cat > "$INSTALL_DIR/bin/startup.sh" << 'EOF'
#!/bin/bash

# GitLab 启动脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

# 检查 Docker 是否运行
if ! docker info &> /dev/null; then
    echo "错误：Docker 服务未运行"
    exit 1
fi

echo "正在启动 GitLab..."
echo "首次启动可能需要 5-10 分钟，请耐心等待..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "等待服务启动..."
sleep 60

# 检查服务状态
echo "检查服务状态..."
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "GitLab 启动完成！"
echo "访问地址：http://<domain>:<port>"
echo "账号：root"
echo "查看日志：docker-compose logs -f gitlab"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    print_success "启动脚本创建完成"
}

# === 创建停止脚本（Docker 模式）===
create_stop_script() {
    print_header "创建停止脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/stop.sh"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

# GitLab 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 GitLab..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "GitLab 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    print_success "停止脚本创建完成"
}

# === 创建状态检查脚本（Docker 模式）===
create_status_script() {
    print_header "创建状态检查脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/status.sh"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    cat > "$INSTALL_DIR/bin/status.sh" << EOF
#!/bin/bash

# GitLab 状态检查脚本

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="\$(dirname "\$SCRIPT_DIR")"

cd "\$INSTALL_DIR"

echo "=== GitLab 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== GitLab 访问信息 ==="
echo "访问地址：http://${GITLAB_DOMAIN}:${GITLAB_PORT}"
echo "管理员账号：root"
echo ""

echo "=== 资源使用 ==="
docker stats --no-stream gitlab 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 数据目录大小 ==="
du -sh "\$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20 gitlab 2>/dev/null || echo "日志不可用"
else
    docker-compose logs --tail=20 gitlab 2>/dev/null || echo "日志不可用"
fi
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 启动 Docker 服务 ===
start_docker_service() {
    print_header "启动 GitLab 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 GitLab 服务"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    cd "$INSTALL_DIR"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动（首次启动约需 5-10 分钟）..."
    sleep 120
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    print_success "GitLab 服务已启动"
}

# === 启动主机服务 ===
start_host_service() {
    print_header "启动 GitLab 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 GitLab 服务"
        return
    fi
    
    print_info "重新配置 GitLab..."
    gitlab-ctl reconfigure
    
    print_info "重启 GitLab..."
    gitlab-ctl restart
    
    print_info "等待服务启动（首次启动约需 5-10 分钟）..."
    sleep 60
    
    # 检查服务状态
    print_info "检查服务状态..."
    gitlab-ctl status
    
    print_success "GitLab 服务已启动"
}

# === 配置 Docker 自启动 ===
configure_docker_autostart() {
    print_header "配置 Docker 自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    if [[ ! -f /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    local SERVICE_FILE="/etc/systemd/system/gitlab-docker.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "GitLab systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GitLab (Docker)
Documentation=https://about.gitlab.com/
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
TimeoutStartSec=600
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用：systemctl enable gitlab-docker"
        print_info "启动：systemctl start gitlab-docker"
    fi
}

# === 配置主机自启动 ===
configure_host_autostart() {
    print_header "配置主机自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    # GitLab Omnibus 包会自动配置 systemd 服务
    if command -v systemctl &> /dev/null; then
        systemctl enable gitlab-runsvdir
        print_success "GitLab 自启动配置完成"
        print_info "启用：systemctl enable gitlab-runsvdir"
        print_info "启动：systemctl start gitlab-runsvdir"
        print_info "查看状态：systemctl status gitlab-runsvdir"
    fi
}

# === 卸载 Docker 模式 ===
uninstall_docker() {
    print_header "卸载 GitLab（Docker 模式）"
    
    local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
    
    # 停止服务
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        print_info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        
        if command -v docker compose &> /dev/null; then
            docker compose down 2>/dev/null || true
        else
            docker-compose down 2>/dev/null || true
        fi
    fi
    
    # 删除容器
    docker rm -f gitlab 2>/dev/null || true
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/gitlab-docker.service ]]; then
        systemctl stop gitlab-docker 2>/dev/null || true
        systemctl disable gitlab-docker 2>/dev/null || true
        rm -f /etc/systemd/system/gitlab-docker.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

# === 卸载主机模式 ===
uninstall_host() {
    print_header "卸载 GitLab（主机模式）"
    
    # 停止 GitLab
    print_info "停止 GitLab 服务..."
    gitlab-ctl stop 2>/dev/null || true
    
    # 禁用服务
    if command -v systemctl &> /dev/null; then
        systemctl disable gitlab-runsvdir 2>/dev/null || true
    fi
    
    # 卸载 GitLab
    if [[ "$OS_TYPE" == "centos" ]]; then
        print_info "卸载 GitLab 包..."
        yum remove -y gitlab-ce
    else
        print_info "卸载 GitLab 包..."
        apt-get purge -y gitlab-ce
    fi
    
    # 删除配置和数据（可选）
    read -p "是否删除所有配置和数据？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除配置和数据..."
        rm -rf /etc/gitlab
        rm -rf /var/opt/gitlab
        rm -rf /var/log/gitlab
    fi
}

# === 卸载 GitLab ===
uninstall_gitlab() {
    print_header "卸载 GitLab"
    
    print_warning "此操作将删除 GitLab 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    # 检测安装模式
    if [[ -f /etc/gitlab/gitlab.rb ]]; then
        INSTALL_MODE="host"
    elif [[ -d "$HOME/gitlab" ]] && [[ -f "$HOME/gitlab/docker-compose.yml" ]]; then
        INSTALL_MODE="docker"
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        uninstall_docker
    else
        uninstall_host
    fi
    
    print_success "GitLab 卸载完成"
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    # 获取本机 IP
    local local_ip
    local_ip=$(get_local_ip)
    
    cat << EOF
${GREEN}GitLab 安装成功！${NC}

${BOLD}访问地址:${NC} http://${GITLAB_DOMAIN}:${GITLAB_PORT}
${BOLD}管理员账号:${NC} root
${BOLD}管理员密码:${NC} $ROOT_PASSWORD
EOF
    
    # 如果域名不是 IP 地址，提示配置 hosts
    if [[ -n "$local_ip" ]] && [[ ! "$GITLAB_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cat << EOF

${YELLOW}${BOLD}⚠️  hosts 配置提示:${NC}
   由于使用域名 ${GITLAB_DOMAIN} 访问，请在客户端配置 hosts：

   ${CYAN}# macOS / Linux${NC}
   echo "$local_ip $GITLAB_DOMAIN" | sudo tee -a /etc/hosts

   ${CYAN}# Windows (以管理员身份运行 PowerShell)${NC}
   Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "$local_ip $GITLAB_DOMAIN"

   ${CYAN}# 或者手动编辑 hosts 文件添加：${NC}
   $local_ip $GITLAB_DOMAIN
EOF
    fi
    
    cat << EOF

${BOLD}常用命令:${NC}
EOF
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        local INSTALL_DIR="${INSTALL_DIR:-$HOME/gitlab}"
        cat << EOF
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：cd $INSTALL_DIR && docker-compose logs -f gitlab
EOF
    else
        cat << EOF
  启动服务：gitlab-ctl restart
  停止服务：gitlab-ctl stop
  查看状态：gitlab-ctl status
  重新配置：gitlab-ctl reconfigure
  查看日志：gitlab-ctl tail
EOF
    fi
    
    cat << EOF

${BOLD}自启动配置:${NC}
EOF
    
    if [[ "$AUTO_START" == "true" ]]; then
        echo -e "  ${GREEN}已配置自启动服务${NC}"
    else
        echo "  未配置自启动，如需配置请运行：--auto-start"
    fi
    
    echo ""
    echo -e "${CYAN}更多信息请访问：https://about.gitlab.com/${NC}"
    echo ""
    print_warning "首次登录后请立即修改管理员密码！"
}

# === 交互式配置（无参数时触发）===
interactive_config() {
    echo ""
    print_header "GitLab 安装配置（交互模式）"
    echo ""
    
    local input
    
    read -rp "GitLab 访问域名 [$GITLAB_DOMAIN]: " input
    GITLAB_DOMAIN="${input:-$GITLAB_DOMAIN}"
    
    read -rp "HTTP 端口 [$GITLAB_PORT]: " input
    GITLAB_PORT="${input:-$GITLAB_PORT}"
    
    read -rp "SSH 端口 [$GITLAB_SSH_PORT]: " input
    GITLAB_SSH_PORT="${input:-$GITLAB_SSH_PORT}"
    
    read -rp "root 初始密码 [$ROOT_PASSWORD]: " input
    ROOT_PASSWORD="${input:-$ROOT_PASSWORD}"
    
    read -rp "管理员邮箱 [$GITLAB_EMAIL]: " input
    GITLAB_EMAIL="${input:-$GITLAB_EMAIL}"
    
    # 安装模式自动检测，不再询问
    echo ""
}

# === 主函数 ===
main() {
    print_header "GitLab 安装脚本"
    
    # 无参数时进入交互式配置
    if [[ $# -eq 0 ]]; then
        interactive_config
    else
        parse_arguments "$@"
    fi
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_gitlab
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装模式：$INSTALL_MODE"
    echo "  访问域名：$GITLAB_DOMAIN"
    echo "  访问端口：$GITLAB_PORT"
    echo "  SSH 端口：$GITLAB_SSH_PORT"
    echo "  管理员密码：$ROOT_PASSWORD"
    echo "  管理员邮箱：$GITLAB_EMAIL"
    echo "  自动启动：$AUTO_START"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        docker_install
    else
        host_install
    fi
    
    show_post_install_info
}

# 执行主函数
main "$@"

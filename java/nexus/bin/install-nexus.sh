#!/bin/bash

# Nexus Repository 一键安装配置脚本
# Nexus Repository 是强大的仓库管理器，支持 Maven、npm、Docker、PyPI 等多种格式
# 支持 Docker Compose 和主机两种安装模式

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
readonly NEXUS_VERSION="3.69.0-02"
readonly NEXUS_IMAGE="sonatype/nexus3"
readonly DEFAULT_INSTALL_DIR="$HOME/nexus"
readonly DEFAULT_NEXUS_PORT="8081"
readonly DEFAULT_ADMIN_PASSWORD="admin123"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
NEXUS_PORT="$DEFAULT_NEXUS_PORT"
ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD"
INSTALL_MODE="auto"  # auto, docker, host
JAVA_HOME=""
AUTO_START=false
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

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local filename
    local adl_path

    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"
    mkdir -p "$output_dir"

    if adl_path="$(find_adl)"; then
        print_info "检测到可用 adl，优先使用 adl 下载: $filename"
        if "$adl_path" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        print_warning "adl 下载失败，回退 curl/wget: $filename"
    fi

    if command -v curl &> /dev/null; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget &> /dev/null; then
        wget -O "$output" "$url"
    else
        print_error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# === 自动特权提升 ===
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要root权限，正在提权..."
        exec sudo "$0" "$@"
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Nexus Repository 一键安装配置脚本

Nexus Repository 是强大的仓库管理器，支持：
- Maven 中央仓库和私有仓库
- npm 包管理
- Docker Registry
- PyPI Python 包
- NuGet .NET 包
- RubyGems
- Yum
- Apt
- 以及其他多种格式

用法：./bin/install-nexus.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：/data/nexus)
    -p, --port PORT             访问端口 (默认：8081)
    --admin-password PWD        admin 初始密码 (默认：admin123)
    --mode MODE                 安装模式 (auto|docker|host，默认：auto)
    --java-home PATH            Java 安装路径 (主机模式需要)
    --auto-start                配置自启动服务
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 Nexus

示例:
    # Docker 模式（推荐）
    sudo ./bin/install-nexus.sh
    
    # 指定端口和密码
    sudo ./bin/install-nexus.sh --port 8081 --admin-password MyPwd123
    
    # 主机模式
    sudo ./bin/install-nexus.sh --mode host --java-home /usr/lib/jvm/java-11
    
    # 配置自启动
    sudo ./bin/install-nexus.sh --auto-start
    
    # 卸载
    sudo ./bin/install-nexus.sh --uninstall

使用指南:
    1. 访问 Nexus: http://localhost:<port>
    2. 默认账号：admin
    3. 默认密码：安装时设置的密码
    4. 首次登录请修改密码

更多信息：https://www.sonatype.com/products/nexus-repository
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
                NEXUS_PORT="$2"
                shift 2
                ;;
            --admin-password)
                ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --java-home)
                JAVA_HOME="$2"
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

    # 仅当安装目录不在用户目录下时才需要 root 权限
    case "$INSTALL_DIR" in
        "$HOME"/*|/tmp/*) ;;
        *) require_root ;;
    esac

    # 确定安装模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if check_docker; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，使用 Docker Compose 模式安装"
        else
            INSTALL_MODE="host"
            print_info "未检测到 Docker，使用主机模式安装"
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
        
        # 检查内存（建议至少 2GB）
        if command -v free &> /dev/null; then
            local total_mem
            total_mem=$(free -m | awk '/^Mem:/{print $2}')
            if [[ "$total_mem" -lt 2048 ]]; then
                print_warning "总内存不足 2GB (${total_mem}MB)，Nexus 推荐 4GB+ 内存"
            fi
        fi
        
        # 检查端口占用
        if command -v lsof &> /dev/null; then
            if lsof -i :"$NEXUS_PORT" &> /dev/null; then
                print_warning "端口 $NEXUS_PORT 已被占用"
            fi
        fi
        
        print_success "Docker 环境检查通过"
    else
        # 主机模式检查
        
        # 检查 Java
        if [[ -z "${JAVA_HOME:-}" ]]; then
            if [[ "$(uname)" == "Darwin" ]] && [[ -x /usr/libexec/java_home ]]; then
                JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null || true)
            fi
            if [[ -z "${JAVA_HOME:-}" ]]; then
                local _jd
                for _jd in /usr/lib/jvm/java-17 /usr/lib/jvm/java-11 /usr/lib/jvm/java-21; do
                    if [[ -d "$_jd" && -x "$_jd/bin/java" ]]; then
                        JAVA_HOME="$_jd"
                        break
                    fi
                done
            fi
            if [[ -z "${JAVA_HOME:-}" ]] && command -v java &> /dev/null; then
                local java_bin
                java_bin=$(readlink -f "$(which java)" 2>/dev/null || which java 2>/dev/null || true)
                if [[ -n "$java_bin" && "$java_bin" != "/usr/bin/java" ]]; then
                    JAVA_HOME=$(dirname "$(dirname "$java_bin")")
                fi
            fi
            if [[ -z "${JAVA_HOME:-}" ]]; then
                print_error "未找到 Java，请安装 JDK 11+ 或使用 --java-home 指定路径"
                exit 1
            fi
        fi
        
        if [[ ! -d "$JAVA_HOME" ]]; then
            print_error "Java 目录不存在：$JAVA_HOME"
            exit 1
        fi
        
        local java_version
        java_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1) || true
        if [[ -z "$java_version" || "$java_version" -lt 11 ]] 2>/dev/null; then
            print_error "Java 版本过低或无法检测，需要 JDK 11+"
            exit 1
        fi
        
        print_success "主机模式环境检查通过 (Java: $java_version)"
        
        # 检查磁盘空间（建议至少 10GB）
        local available_disk
        local disk_check_dir="$INSTALL_DIR"
        while [[ ! -d "$disk_check_dir" && "$disk_check_dir" != "/" ]]; do
            disk_check_dir="$(dirname "$disk_check_dir")"
        done
        available_disk=$(df -m "$disk_check_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)
        if [[ -n "$available_disk" && "$available_disk" -lt 10240 ]]; then
            print_warning "可用磁盘空间不足 10GB，建议清理空间"
        fi
    fi
}

# === 创建安装目录 ===
create_directories() {
    print_header "创建安装目录"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建目录：$INSTALL_DIR"
        return
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        mkdir -p "$INSTALL_DIR"/{data,nexus-data,bin}
    else
        mkdir -p "$INSTALL_DIR"/{sonatype-work,data,bin,log}
    fi
    
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === Docker Compose 模式安装 ===
docker_install() {
    print_header "Docker Compose 模式安装"
    
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
    
    # 创建备份脚本
    create_backup_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ -t 0 ]]; then
            print_info "是否立即启动 Nexus？(y/N)"
            read -r -p "> " start_now
            if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
                start_docker_service
                
                if [[ "$AUTO_START" == "true" ]]; then
                    configure_docker_autostart
                fi
            fi
        else
            print_info "非交互模式，跳过启动确认"
        fi
    fi
}

# === 创建 docker-compose.yml ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  nexus:
    image: ${NEXUS_IMAGE}:${NEXUS_VERSION}
    container_name: nexus
    hostname: nexus
    restart: unless-stopped
    ports:
      - "${NEXUS_PORT}:8081"
    volumes:
      - $INSTALL_DIR/data:/nexus-data
      - $INSTALL_DIR/nexus-data:/opt/sonatype/nexus
    environment:
      - INSTALL4J_ADD_VM_PARAMS=-Xms512m -Xmx1g -Djava.util.prefs.userRoot=/nexus-data -Duser.dir=/opt/sonatype/nexus
      - TZ=Asia/Shanghai
    networks:
      - nexus-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8081"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 300s

networks:
  nexus-network:
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
    
    cat > "$INSTALL_DIR/.env" << EOF
NEXUS_VERSION=${NEXUS_VERSION}
NEXUS_PORT=${NEXUS_PORT}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
    
    print_success "环境变量配置创建完成"
}

# === 创建启动脚本 ===
create_startup_script() {
    print_header "创建启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/startup.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/startup.sh" << 'EOF'
#!/bin/bash

# Nexus 启动脚本

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

echo "正在启动 Nexus Repository..."
echo "首次启动可能需要 3-5 分钟，请耐心等待..."

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
echo "Nexus 启动完成！"
echo "访问地址：http://localhost:<PORT>"
echo "账号：admin"
echo "查看日志：docker-compose logs -f nexus"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    print_success "启动脚本创建完成"
}

# === 创建停止脚本 ===
create_stop_script() {
    print_header "创建停止脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/stop.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

# Nexus 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 Nexus..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "Nexus 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    print_success "停止脚本创建完成"
}

# === 创建状态检查脚本 ===
create_status_script() {
    print_header "创建状态检查脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/status.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/status.sh" << EOF
#!/bin/bash

# Nexus 状态检查脚本

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="\$(dirname "\$SCRIPT_DIR")"

cd "\$INSTALL_DIR"

echo "=== Nexus 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== Nexus 访问信息 ==="
echo "访问地址：http://localhost:${NEXUS_PORT}"
echo "管理员账号：admin"
echo ""

echo "=== 资源使用 ==="
docker stats --no-stream nexus 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 数据目录大小 ==="
du -sh "\$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20 nexus 2>/dev/null || echo "日志不可用"
else
    docker-compose logs --tail=20 nexus 2>/dev/null || echo "日志不可用"
fi
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 创建备份脚本 ===
create_backup_script() {
    print_header "创建备份脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/backup.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/backup.sh" << 'EOF'
#!/bin/bash

# Nexus 备份脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$INSTALL_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "=== Nexus 数据备份 ==="
echo "备份时间：$TIMESTAMP"
echo ""

# 备份数据目录
echo "备份数据目录..."
tar -czf "$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz" \
    -C "$INSTALL_DIR" \
    data nexus-data

echo "备份完成：$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz"

# 清理 7 天前的备份
echo "清理 7 天前的备份..."
find "$BACKUP_DIR" -name "nexus_data_*.tar.gz" -mtime +7 -delete

echo ""
echo "备份文件大小："
ls -lh "$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz"
EOF
    
    chmod +x "$INSTALL_DIR/bin/backup.sh"
    print_success "备份脚本创建完成"
}

# === 启动 Docker 服务 ===
start_docker_service() {
    print_header "启动 Nexus 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 Nexus 服务"
        return
    fi
    
    cd "$INSTALL_DIR"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动（首次启动约需 3-5 分钟）..."
    sleep 90
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    # 等待 Nexus 就绪
    print_info "等待 Nexus 服务就绪..."
    local max_attempts=20
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$NEXUS_PORT" | grep -q "200\|302"; then
            print_success "Nexus 服务已就绪"
            break
        fi
        sleep 10
        ((attempt++))
        print_info "等待中... ($attempt/$max_attempts)"
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        print_warning "Nexus 服务可能还未完全启动，请稍后查看日志"
    fi
    
    print_success "Nexus 服务已启动"
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
    
    local SERVICE_FILE="/etc/systemd/system/nexus.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "Nexus systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Nexus Repository Manager
Documentation=https://www.sonatype.com/products/nexus-repository
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
        print_info "启用：sudo systemctl enable nexus"
        print_info "启动：sudo systemctl start nexus"
        print_info "查看状态：sudo systemctl status nexus"
    fi
}

# === 主机模式安装 ===
host_install() {
    print_header "主机模式安装"
    
    # 下载 Nexus
    download_nexus
    
    # 配置 Nexus
    configure_nexus
    
    # 创建启动脚本
    create_host_scripts
    
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ -t 0 ]]; then
            print_info "是否立即启动 Nexus？(y/N)"
            read -r -p "> " start_now
            if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
                start_host_service
                
                if [[ "$AUTO_START" == "true" ]]; then
                    configure_host_autostart
                fi
            fi
        else
            print_info "非交互模式，跳过启动确认（请手动执行启动脚本）"
        fi
    fi
}

# === 下载 Nexus ===
download_nexus() {
    print_header "下载 Nexus Repository"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载 Nexus $NEXUS_VERSION"
        return
    fi
    
    local NEXUS_PACKAGE="nexus-${NEXUS_VERSION}-unix.tar.gz"
    local PACKAGE_PATH="$DOWNLOAD_DIR/$NEXUS_PACKAGE"

    mkdir -p "$INSTALL_DIR" "$DOWNLOAD_DIR"

    # 检查是否已存在
    if [[ -f "$PACKAGE_PATH" ]] && [[ -s "$PACKAGE_PATH" ]]; then
        print_info "安装包已存在，跳过下载"
    else
        # 多源下载：指定版本 → latest-unix.tar.gz
        local -a nexus_urls=(
            "https://download.sonatype.com/nexus/3/${NEXUS_PACKAGE}"
            "https://download.sonatype.com/nexus/3/latest-unix.tar.gz"
        )

        local downloaded=false
        for nexus_url in "${nexus_urls[@]}"; do
            # 先用 HEAD 检查 URL 是否有效，避免 adl 对 404 反复重试
            local http_code
            http_code=$(curl -sIL -o /dev/null -w '%{http_code}' --connect-timeout 10 "$nexus_url" 2>/dev/null || echo "000")
            if [[ "$http_code" == "404" ]] || [[ "$http_code" == "403" ]]; then
                print_warning "URL 不可用 ($http_code)，跳过: $nexus_url"
                continue
            fi
            print_info "下载 Nexus: $nexus_url"
            if download_file "$nexus_url" "$PACKAGE_PATH" && [[ -s "$PACKAGE_PATH" ]]; then
                downloaded=true
                break
            fi
            print_warning "源下载失败，尝试下一个: $nexus_url"
            rm -f "$PACKAGE_PATH" 2>/dev/null || true
        done

        if [[ "$downloaded" != "true" ]]; then
            print_error "Nexus 下载失败（所有源均不可用）"
            exit 1
        fi
    fi
    
    # 解压
    print_info "解压安装包..."
    tar -xzf "$PACKAGE_PATH" -C "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 创建符号链接
    local NEXUS_DIR=$(ls -d nexus-* | grep -v "\.tar\.gz" | head -1)
    if [[ -n "$NEXUS_DIR" && ! -L "nexus" ]]; then
        ln -s "$NEXUS_DIR" nexus
    fi
    
    print_success "Nexus 下载完成"
}

# === 配置 Nexus ===
configure_nexus() {
    print_header "配置 Nexus"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 Nexus"
        return
    fi
    
    local NEXUS_HOME="$INSTALL_DIR/nexus"
    
    # 创建 nexus.properties 配置
    mkdir -p "$INSTALL_DIR/data/etc"
    
    cat > "$INSTALL_DIR/data/etc/nexus.properties" << EOF
# Nexus Repository 配置文件

# 端口配置
application-port=${NEXUS_PORT}
application-host=0.0.0.0

# 数据目录
nexus-data=$INSTALL_DIR/data

# JVM 配置
java.net.preferIPv4Stack=true
EOF
    
    # 配置 JVM 参数
    mkdir -p "$INSTALL_DIR/data/etc/jvm"
    cat > "$INSTALL_DIR/data/etc/jvm/java-opts" << EOF
-Xms512m
-Xmx1g
-XX:MaxDirectMemorySize=512m
-Djava.util.prefs.userRoot=$INSTALL_DIR/data
-Duser.dir=$NEXUS_HOME
EOF
    
    # 设置权限。用户目录安装时不要强行改成 root，否则普通用户无法管理。
    if [[ "$INSTALL_DIR" == "$HOME"/* || "$INSTALL_DIR" == /tmp/* ]]; then
        chown -R "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
    else
        chown -R root:root "$INSTALL_DIR" 2>/dev/null || true
    fi
    chmod -R 755 "$INSTALL_DIR"
    
    print_success "Nexus 配置完成"
}

# === 创建主机模式脚本 ===
create_host_scripts() {
    print_header "创建管理脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建管理脚本"
        return
    fi
    
    local NEXUS_HOME="$INSTALL_DIR/nexus"
    
    # 启动脚本
    cat > "$INSTALL_DIR/bin/startup.sh" << EOF
#!/bin/bash

# Nexus 启动脚本（主机模式）

set -e

NEXUS_HOME="$INSTALL_DIR/nexus"
JAVA_HOME="${JAVA_HOME:-$JAVA_HOME}"
NEXUS_PORT=${NEXUS_PORT}

echo "正在启动 Nexus Repository..."

# 设置环境变量
export INSTALL4J_JAVA_HOME="\$JAVA_HOME"
export JAVA_HOME="\$JAVA_HOME"

# 启动 Nexus
\$NEXUS_HOME/bin/nexus start

echo ""
echo "等待服务启动..."
sleep 30

# 检查状态
\$NEXUS_HOME/bin/nexus status

echo ""
echo "Nexus 启动完成！"
echo "访问地址：http://localhost:\$NEXUS_PORT"
echo "账号：admin"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    
    # 停止脚本
    cat > "$INSTALL_DIR/bin/stop.sh" << EOF
#!/bin/bash

# Nexus 停止脚本（主机模式）

NEXUS_HOME="$INSTALL_DIR/nexus"

echo "正在停止 Nexus..."
\$NEXUS_HOME/bin/nexus stop

echo ""
echo "Nexus 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    
    # 状态脚本
    cat > "$INSTALL_DIR/bin/status.sh" << EOF
#!/bin/bash

# Nexus 状态检查脚本（主机模式）

NEXUS_HOME="$INSTALL_DIR/nexus"
NEXUS_PORT=${NEXUS_PORT}

echo "=== Nexus 服务状态 ==="
\$NEXUS_HOME/bin/nexus status

echo ""
echo "=== Nexus 访问信息 ==="
echo "访问地址：http://localhost:\$NEXUS_PORT"
echo "管理员账号：admin"

echo ""
echo "=== 进程信息 ==="
ps aux | grep -i nexus | grep -v grep

echo ""
echo "=== 数据目录大小 ==="
du -sh "$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    
    # 备份脚本
    cat > "$INSTALL_DIR/bin/backup.sh" << 'EOF'
#!/bin/bash

# Nexus 备份脚本（主机模式）

set -e

INSTALL_DIR="/data/nexus"
BACKUP_DIR="$INSTALL_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "=== Nexus 数据备份 ==="
echo "备份时间：$TIMESTAMP"
echo ""

# 停止 Nexus
echo "停止 Nexus..."
$INSTALL_DIR/nexus/bin/nexus stop

# 备份数据目录
echo "备份数据目录..."
tar -czf "$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz" \
    -C "$INSTALL_DIR" \
    data

# 启动 Nexus
echo "启动 Nexus..."
$INSTALL_DIR/nexus/bin/nexus start

echo "备份完成：$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz"

# 清理 7 天前的备份
find "$BACKUP_DIR" -name "nexus_data_*.tar.gz" -mtime +7 -delete

echo ""
echo "备份文件大小："
ls -lh "$BACKUP_DIR/nexus_data_${TIMESTAMP}.tar.gz"
EOF
    
    chmod +x "$INSTALL_DIR/bin/backup.sh"
    
    print_success "管理脚本创建完成"
}

# === 启动主机服务 ===
start_host_service() {
    print_header "启动 Nexus 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 Nexus 服务"
        return
    fi
    
    local NEXUS_HOME="$INSTALL_DIR/nexus"
    
    # 设置环境变量
    export INSTALL4J_JAVA_HOME="$JAVA_HOME"
    export JAVA_HOME="$JAVA_HOME"
    
    print_info "启动 Nexus..."
    "$NEXUS_HOME/bin/nexus" start
    
    print_info "等待服务启动（首次启动约需 3-5 分钟）..."
    sleep 60
    
    # 检查服务状态
    print_info "检查服务状态..."
    "$NEXUS_HOME/bin/nexus" status
    
    # 等待 Nexus 就绪
    print_info "等待 Nexus 服务就绪..."
    local max_attempts=20
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$NEXUS_PORT" | grep -q "200\|302"; then
            print_success "Nexus 服务已就绪"
            break
        fi
        sleep 10
        ((attempt++))
        print_info "等待中... ($attempt/$max_attempts)"
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        print_warning "Nexus 服务可能还未完全启动，请稍后查看日志"
    fi
    
    print_success "Nexus 服务已启动"
}

# === 配置主机自启动 ===
configure_host_autostart() {
    print_header "配置主机自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    if [[ ! -f /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi
    
    local SERVICE_FILE="/etc/systemd/system/nexus.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "Nexus systemd 服务已存在"
        return
    fi
    
    local NEXUS_HOME="$INSTALL_DIR/nexus"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Nexus Repository Manager
Documentation=https://www.sonatype.com/products/nexus-repository
After=network.target
Requires=network.target

[Service]
Type=forking
LimitNOFILE=65536
Environment="INSTALL4J_JAVA_HOME=${JAVA_HOME}"
Environment="JAVA_HOME=${JAVA_HOME}"
ExecStart=${NEXUS_HOME}/bin/nexus start
ExecStop=${NEXUS_HOME}/bin/nexus stop
Restart=on-failure
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
    
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用：systemctl enable nexus"
        print_info "启动：systemctl start nexus"
        print_info "查看状态：systemctl status nexus"
    fi
}

# === 卸载 Nexus ===
uninstall_nexus() {
    print_header "卸载 Nexus"
    
    print_warning "此操作将删除 Nexus 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    # Docker 模式卸载
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        uninstall_docker
    else
        uninstall_host
    fi
    
    print_success "Nexus 卸载完成"
}

# === 卸载 Docker 模式 ===
uninstall_docker() {
    print_info "停止 Docker 容器..."
    cd "$INSTALL_DIR"
    
    if command -v docker compose &> /dev/null; then
        docker compose down 2>/dev/null || true
    else
        docker-compose down 2>/dev/null || true
    fi
    
    # 删除容器
    docker rm -f nexus 2>/dev/null || true
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/nexus.service ]]; then
        systemctl stop nexus 2>/dev/null || true
        systemctl disable nexus 2>/dev/null || true
        rm -f /etc/systemd/system/nexus.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_info "保留数据目录，仅删除程序文件..."
        rm -rf "$INSTALL_DIR/nexus"
        rm -f "$INSTALL_DIR/docker-compose.yml"
        rm -f "$INSTALL_DIR/.env"
        rm -rf "$INSTALL_DIR/bin"
    fi
}

# === 卸载主机模式 ===
uninstall_host() {
    print_info "停止 Nexus 服务..."
    
    # 停止服务
    if [[ -x "$INSTALL_DIR/nexus/bin/nexus" ]]; then
        "$INSTALL_DIR/nexus/bin/nexus" stop 2>/dev/null || true
    fi
    
    # 停止 systemd 服务
    if [[ -f /etc/systemd/system/nexus.service ]]; then
        systemctl stop nexus 2>/dev/null || true
        systemctl disable nexus 2>/dev/null || true
        rm -f /etc/systemd/system/nexus.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_info "保留数据目录，仅删除程序文件..."
        rm -rf "$INSTALL_DIR/nexus"
        rm -rf "$INSTALL_DIR/bin"
    fi
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    cat << EOF
${GREEN}Nexus Repository 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}访问地址:${NC} http://localhost:${NEXUS_PORT}
${BOLD}管理员账号:${NC} admin
${BOLD}管理员密码:${NC} $ADMIN_PASSWORD

${BOLD}常用命令:${NC}
EOF
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cat << EOF
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  备份数据：cd $INSTALL_DIR && ./bin/backup.sh
  查看日志：cd $INSTALL_DIR && docker-compose logs -f nexus
EOF
    else
        cat << EOF
  启动服务：$INSTALL_DIR/bin/startup.sh
  停止服务：$INSTALL_DIR/bin/stop.sh
  查看状态：$INSTALL_DIR/bin/status.sh
  备份数据：$INSTALL_DIR/bin/backup.sh
  查看日志：tail -f $INSTALL_DIR/data/log/nexus.log
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
    echo -e "${CYAN}更多信息请访问：https://www.sonatype.com/products/nexus-repository${NC}"
    echo ""
    print_warning "首次登录后请立即修改管理员密码！"
}

# === 主函数 ===
main() {
    print_header "Nexus Repository 安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_nexus
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  访问端口：$NEXUS_PORT"
    echo "  安装模式：$INSTALL_MODE"
    echo "  管理员密码：$ADMIN_PASSWORD"
    echo "  自动启动：$AUTO_START"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    create_directories
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        docker_install
    else
        host_install
    fi
    
    show_post_install_info
}

# 执行主函数
main "$@"

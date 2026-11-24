#!/bin/bash

# JumpServer 一键安装配置脚本
# JumpServer 是广受欢迎的开源堡垒机，支持资产管理、权限控制、操作审计等功能
# 支持 Docker Compose 安装模式

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
readonly JUMPSERVER_VERSION="v3.10.0"
readonly JUMPSERVER_IMAGE="jumpserver/jumpserver"
readonly DEFAULT_INSTALL_DIR="/data/jumpserver"
readonly DEFAULT_JUMPSERVER_DOMAIN="jumpserver.local"
readonly DEFAULT_SECRET_KEY=$(openssl rand -hex 50)
readonly DEFAULT_BOOTSTRAP_TOKEN=$(openssl rand -hex 16)

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
JUMPSERVER_DOMAIN="$DEFAULT_JUMPSERVER_DOMAIN"
JUMPSERVER_PORT="8080"
DB_PASSWORD="jumpserver123"
REDIS_PASSWORD="jumpserver123"
SECRET_KEY="$DEFAULT_SECRET_KEY"
BOOTSTRAP_TOKEN="$DEFAULT_BOOTSTRAP_TOKEN"
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

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
JumpServer 一键安装配置脚本

JumpServer 是广受欢迎的开源堡垒机，支持：
- 资产管理：服务器、数据库、云资源统一管理
- 权限控制：基于角色的访问控制（RBAC）
- 操作审计：会话录制、命令记录、操作日志
- 多协议支持：SSH、RDP、VNC、Telnet、MySQL、PostgreSQL 等
- 自动化运维：批量命令、文件分发、任务执行

用法：./bin/install-jumpserver.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：/data/jumpserver)
    --domain DOMAIN             JumpServer 访问域名 (默认：jumpserver.local)
    --port PORT                 访问端口 (默认：8080)
    --db-password PWD           数据库密码 (默认：jumpserver123)
    --redis-password PWD        Redis 密码 (默认：jumpserver123)
    --secret-key KEY            SECRET_KEY (默认：随机生成)
    --bootstrap-token TOKEN     BOOTSTRAP_TOKEN (默认：随机生成)
    --auto-start                配置自启动服务
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 JumpServer

示例:
    # 使用默认设置安装
    sudo ./bin/install-jumpserver.sh
    
    # 指定域名和端口
    sudo ./bin/install-jumpserver.sh --domain jump.example.com --port 80
    
    # 配置自启动
    sudo ./bin/install-jumpserver.sh --auto-start
    
    # 卸载
    sudo ./bin/install-jumpserver.sh --uninstall

使用指南:
    1. 访问 JumpServer: http://<domain>:<port>
    2. 默认账号：admin
    3. 默认密码：admin123 (首次登录请修改)
    4. 修改密码后请妥善保管

更多信息：https://www.jumpserver.org/
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
                JUMPSERVER_DOMAIN="$2"
                shift 2
                ;;
            --port)
                JUMPSERVER_PORT="$2"
                shift 2
                ;;
            --db-password)
                DB_PASSWORD="$2"
                shift 2
                ;;
            --redis-password)
                REDIS_PASSWORD="$2"
                shift 2
                ;;
            --secret-key)
                SECRET_KEY="$2"
                shift 2
                ;;
            --bootstrap-token)
                BOOTSTRAP_TOKEN="$2"
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

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限，请使用 sudo 执行"
        exit 1
    fi
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker 服务未运行"
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
            print_warning "总内存不足 2GB (${total_mem}MB)，可能影响 JumpServer 运行"
        fi
    fi
    
    # 检查磁盘空间（建议至少 20GB）
    local available_disk
    available_disk=$(df -m "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$available_disk" && "$available_disk" -lt 20480 ]]; then
        print_warning "可用磁盘空间不足 20GB，建议清理空间"
    fi
    
    # 检查端口占用
    if command -v lsof &> /dev/null; then
        if lsof -i :"$JUMPSERVER_PORT" &> /dev/null; then
            print_warning "端口 $JUMPSERVER_PORT 已被占用"
        fi
    fi
    
    print_success "前置条件检查通过"
}

# === 创建安装目录 ===
create_directories() {
    print_header "创建安装目录"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建目录：$INSTALL_DIR"
        return
    fi
    
    mkdir -p "$INSTALL_DIR"/{data/{core,mysql,redis,mariadb},logs,bin,conf}
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === 生成 .env 文件 ===
generate_env_file() {
    print_header "生成环境变量配置"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 生成 .env 文件"
        return
    fi
    
    cat > "$INSTALL_DIR/.env" << EOF
# JumpServer 环境变量配置

# 版本
DOCKER_BASE_VERSION=${JUMPSERVER_VERSION}

# 核心配置
SECRET_KEY=${SECRET_KEY}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}

# 数据库配置
DB_HOST=mysql
DB_NAME=jumpserver
DB_USER=jumpserver
DB_PASSWORD=${DB_PASSWORD}
DB_PORT=3306

# Redis 配置
REDIS_HOST=redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=6379

# 其他配置
CORE_HOST=http://core:8080
LOG_LEVEL=INFO

# 持久化目录
VOLUME_DIR=${INSTALL_DIR}/data
EOF
    
    print_success "环境变量配置生成完成"
}

# === 创建 docker-compose.yml ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    cat > "$INSTALL_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  core:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_core
    hostname: core
    restart: always
    command: start core
    entrypoint: /entrypoint.sh
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
      - DB_HOST=mysql
      - DB_NAME=jumpserver
      - DB_USER=jumpserver
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_PORT=3306
      - REDIS_HOST=redis
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - REDIS_PORT=6379
      - LOG_LEVEL=INFO
    volumes:
      - ${VOLUME_DIR}/core:/opt/jumpserver/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      - mysql
      - redis
    networks:
      - jumpserver-network

  mysql:
    image: mariadb:10.11
    container_name: jms_mysql
    hostname: mysql
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_PASSWORD}
      - MYSQL_DATABASE=jumpserver
      - MYSQL_USER=jumpserver
      - MYSQL_PASSWORD=${DB_PASSWORD}
      - TZ=Asia/Shanghai
    volumes:
      - ${VOLUME_DIR}/mysql:/var/lib/mysql
    networks:
      - jumpserver-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: jms_redis
    hostname: redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ${VOLUME_DIR}/redis:/data
    networks:
      - jumpserver-network
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  koko:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_koko
    hostname: koko
    restart: always
    command: start koko
    entrypoint: /entrypoint.sh
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
      - CORE_HOST=http://core:8080
      - LOG_LEVEL=INFO
    ports:
      - "2222:2222"
    depends_on:
      - core
    networks:
      - jumpserver-network

  lion:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_lion
    hostname: lion
    restart: always
    command: start lion
    entrypoint: /entrypoint.sh
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
      - CORE_HOST=http://core:8080
      - LOG_LEVEL=INFO
    depends_on:
      - core
    networks:
      - jumpserver-network

  magnus:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_magnus
    hostname: magnus
    restart: always
    command: start magnus
    entrypoint: /entrypoint.sh
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
      - CORE_HOST=http://core:8080
      - LOG_LEVEL=INFO
    ports:
      - "33060:33060"
      - "54320:54320"
    depends_on:
      - core
    networks:
      - jumpserver-network

  web:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_web
    hostname: web
    restart: always
    command: start web
    entrypoint: /entrypoint.sh
    environment:
      - CORE_HOST=http://core:8080
      - LOG_LEVEL=INFO
    ports:
      - "${JUMPSERVER_PORT:-8080}:80"
    depends_on:
      - core
    networks:
      - jumpserver-network

  celery:
    image: ${DOCKER_BASE_IMAGE:-jumpserver/jumpserver}:${DOCKER_BASE_VERSION:-latest}
    container_name: jms_celery
    hostname: celery
    restart: always
    command: start celery
    entrypoint: /entrypoint.sh
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
      - DB_HOST=mysql
      - DB_NAME=jumpserver
      - DB_USER=jumpserver
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_PORT=3306
      - REDIS_HOST=redis
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - REDIS_PORT=6379
      - CORE_HOST=http://core:8080
      - LOG_LEVEL=INFO
    depends_on:
      - core
      - redis
    networks:
      - jumpserver-network

networks:
  jumpserver-network:
    driver: bridge
EOF
    
    print_success "Docker Compose 文件创建完成"
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

# JumpServer 启动脚本

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

# 检查 docker-compose.yml 是否存在
if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
    echo "错误：docker-compose.yml 不存在"
    exit 1
fi

echo "正在启动 JumpServer..."
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
echo "JumpServer 启动完成！"
echo "访问地址：http://localhost:<PORT>"
echo "默认账号：admin"
echo "默认密码：admin123"
echo "查看日志：docker-compose logs -f core"
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

# JumpServer 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 JumpServer..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "JumpServer 已停止"
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

# JumpServer 状态检查脚本

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="\$(dirname "\$SCRIPT_DIR")"

cd "\$INSTALL_DIR"

echo "=== JumpServer 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== JumpServer 访问信息 ==="
echo "访问地址：http://${JUMPSERVER_DOMAIN}:${JUMPSERVER_PORT}"
echo "管理员账号：admin"
echo "管理员密码：admin123"
echo ""

echo "=== 资源使用 ==="
docker stats --no-stream 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 数据目录大小 ==="
du -sh "\$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20 core 2>/dev/null || echo "日志不可用"
else
    docker-compose logs --tail=20 core 2>/dev/null || echo "日志不可用"
fi
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 配置自启动服务 ===
configure_autostart() {
    print_header "配置自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    if [[ ! -f /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi
    
    local SERVICE_FILE="/etc/systemd/system/jumpserver.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "JumpServer systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=JumpServer 堡垒机
Documentation=https://www.jumpserver.org/
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
        print_info "启用：systemctl enable jumpserver"
        print_info "启动：systemctl start jumpserver"
        print_info "查看状态：systemctl status jumpserver"
    fi
}

# === 启动 JumpServer ===
start_jumpserver() {
    print_header "启动 JumpServer 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 JumpServer 服务"
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
    sleep 60
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    print_success "JumpServer 服务已启动"
}

# === 卸载 JumpServer ===
uninstall_jumpserver() {
    print_header "卸载 JumpServer"
    
    print_warning "此操作将删除 JumpServer 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
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
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/jumpserver.service ]]; then
        print_info "删除 systemd 服务..."
        systemctl stop jumpserver 2>/dev/null || true
        systemctl disable jumpserver 2>/dev/null || true
        rm -f /etc/systemd/system/jumpserver.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_info "保留数据目录，仅删除程序文件..."
        rm -rf "$INSTALL_DIR/bin"
        rm -rf "$INSTALL_DIR/logs"
        rm -rf "$INSTALL_DIR/conf"
        rm -f "$INSTALL_DIR/docker-compose.yml"
        rm -f "$INSTALL_DIR/.env"
    fi
    
    print_success "JumpServer 卸载完成"
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    cat << EOF
${GREEN}JumpServer 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}访问地址:${NC} http://${JUMPSERVER_DOMAIN}:${JUMPSERVER_PORT}
${BOLD}管理员账号:${NC} admin
${BOLD}管理员密码:${NC} admin123

${BOLD}常用命令:${NC}
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：cd $INSTALL_DIR && docker-compose logs -f core

${BOLD}端口说明:${NC}
  Web 访问端口：${JUMPSERVER_PORT}
  SSH 代理端口：2222
  数据库代理端口：33060 (MySQL), 54320 (PostgreSQL)

${BOLD}自启动配置:${NC}
EOF
    
    if [[ "$AUTO_START" == "true" ]]; then
        echo -e "  ${GREEN}已配置自启动服务${NC}"
    else
        echo "  未配置自启动，如需配置请运行：--auto-start"
    fi
    
    echo ""
    echo -e "${CYAN}更多信息请访问：https://www.jumpserver.org/${NC}"
    echo ""
    print_warning "首次登录后请立即修改管理员密码！"
}

# === 主函数 ===
main() {
    print_header "JumpServer 堡垒机安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_jumpserver
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  访问域名：$JUMPSERVER_DOMAIN"
    echo "  访问端口：$JUMPSERVER_PORT"
    echo "  数据库密码：$DB_PASSWORD"
    echo "  Redis 密码：$REDIS_PASSWORD"
    echo "  自动启动：$AUTO_START"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    create_directories
    generate_env_file
    create_docker_compose
    create_startup_script
    create_stop_script
    create_status_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "是否立即启动 JumpServer？(y/N)"
        read -r -p "> " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            start_jumpserver
            
            if [[ "$AUTO_START" == "true" ]]; then
                configure_autostart
            fi
        fi
    fi
    
    show_post_install_info
}

# 执行主函数
main "$@"

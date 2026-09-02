#!/bin/bash

# Spug 一键安装配置脚本
# Spug 是轻量级自动化运维平台，支持主机管理、批量执行、任务计划、监控告警、CI/CD 等功能
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
readonly SPUG_VERSION="latest"
readonly SPUG_IMAGE="registry.cn-hangzhou.aliyuncs.com/openspug/spug-service"
readonly DB_IMAGE="registry.cn-hangzhou.aliyuncs.com/openspug/mariadb:10.8.2"
readonly DEFAULT_SPUG_PORT=80
readonly DEFAULT_INSTALL_DIR="$HOME/spug"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
readonly SPUG_INIT_SCRIPT="/etc/init.d/spug"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
SPUG_PORT="$DEFAULT_SPUG_PORT"
ADMIN_PASSWORD="spug.cc"
MYSQL_PASSWORD="spug.cc"
MYSQL_ROOT_PASSWORD="spug.cc"
INSTALL_MODE="auto"  # auto, docker, host
DRY_RUN=false
UNINSTALL_MODE=false
AUTO_START=false

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
Spug 一键安装配置脚本

Spug 是轻量级自动化运维平台，由 Python + Vue3 开发。
功能包括：主机管理、批量执行、任务计划、监控告警、CI/CD、配置中心等。

用法：./bin/install-spug.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：$HOME/spug)
    -p, --port PORT             访问端口 (默认：80，仅 Docker 模式有效)
    --admin-password PWD        管理员初始密码 (默认：spug.cc)
    --mysql-password PWD        MySQL 密码 (默认：spug.cc)
    --mode MODE                 安装模式 (auto|docker|host，默认：auto)
    --auto-start                安装完成后自动启动并配置自启动
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 Spug

示例:
    # Docker 模式（推荐）
    ./bin/install-spug.sh
    
    # 指定端口和密码
    ./bin/install-spug.sh --port 8080 --admin-password MyPwd123
    
    # 主机模式安装
    ./bin/install-spug.sh --mode host
    
    # 配置自启动
    ./bin/install-spug.sh --auto-start
    
    # 卸载
    ./bin/install-spug.sh --uninstall

使用指南:
    Docker 模式:
    1. 启动：cd $INSTALL_DIR && docker compose up -d
    2. 初始化：docker exec spug init_spug admin <password>
    3. 访问：http://localhost:<PORT>
    
    主机模式:
    1. 启动：systemctl start spug 或 /etc/init.d/spug start
    2. 访问：http://localhost:<PORT>

更多信息：https://ops.spug.cc/
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
                SPUG_PORT="$2"
                shift 2
                ;;
            --admin-password)
                ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --mysql-password)
                MYSQL_PASSWORD="$2"
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
            print_info "请安装 Docker 或移除 --mode docker 选项使用主机模式"
            exit 1
        fi
        
        # 检查 Docker Compose
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            print_error "Docker Compose 未安装"
            exit 1
        fi
        
        print_success "Docker 环境检查通过"
        
        # 检查端口占用
        if command -v lsof &> /dev/null; then
            if lsof -i :"$SPUG_PORT" &> /dev/null; then
                print_warning "端口 $SPUG_PORT 已被占用"
                read -p "是否继续安装？(y/N): " confirm
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    print_info "取消安装"
                    exit 0
                fi
            fi
        fi
    else
        # 主机模式检查
        if [[ $EUID -ne 0 ]]; then
            print_error "主机模式需要 root 权限，请使用 sudo 执行"
            exit 1
        fi
        
        # 检查 Python
        if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
            print_error "Python 未安装"
            exit 1
        fi
        
        # 检查 MySQL 客户端
        if ! command -v mysql &> /dev/null; then
            print_warning "MySQL 客户端未安装，建议安装：yum install mysql 或 apt install mysql-client"
        fi
        
        print_success "主机模式环境检查通过"
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
        mkdir -p "$INSTALL_DIR"/{service,repos,mysql,bin,logs}
    else
        mkdir -p "$INSTALL_DIR"/{service,repos,mysql,bin,logs,conf}
    fi
    
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === Docker Compose 模式安装 ===
docker_install() {
    print_header "Docker Compose 模式安装"
    
    # 创建 docker-compose.yml
    create_docker_compose
    
    # 创建启动脚本
    create_startup_script
    
    # 创建停止脚本
    create_stop_script
    
    # 创建状态脚本
    create_status_script
    
    # 创建初始化脚本
    create_init_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "是否立即启动 Spug？(y/N)"
        read -r -p "> " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            start_docker_service
            
            if [[ "$AUTO_START" == "true" ]]; then
                configure_docker_autostart
            fi
        fi
    fi
}

# === 创建 Docker Compose 文件 ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: "3.3"

services:
  db:
    image: ${DB_IMAGE}
    container_name: spug-db
    restart: always
    command: --port 3306 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    volumes:
      - $INSTALL_DIR/data/mysql:/var/lib/mysql
    environment:
      - MYSQL_DATABASE=spug
      - MYSQL_USER=spug
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
    networks:
      - spug-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5

  spug:
    image: ${SPUG_IMAGE}
    container_name: spug
    privileged: true
    restart: always
    volumes:
      - $INSTALL_DIR/data/service:/data/spug
      - $INSTALL_DIR/data/repos:/data/repos
    ports:
      - "${SPUG_PORT}:80"
    environment:
      - MYSQL_DATABASE=spug
      - MYSQL_USER=spug
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_HOST=db
      - MYSQL_PORT=3306
    depends_on:
      db:
        condition: service_healthy
    networks:
      - spug-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

networks:
  spug-network:
    driver: bridge
EOF
    
    # 创建 .env 文件
    cat > "$INSTALL_DIR/.env" << EOF
SPUG_PORT=${SPUG_PORT}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
SPUG_IMAGE=${SPUG_IMAGE}
DB_IMAGE=${DB_IMAGE}
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

# Spug 启动脚本

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

echo "正在启动 Spug..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "等待服务启动（首次启动约需 1-2 分钟）..."
sleep 10

# 检查服务状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "Spug 启动完成！"
echo "首次启动请执行初始化："
echo "  docker exec spug init_spug admin <password>"
echo "查看日志：docker-compose logs -f spug"
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

# Spug 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 Spug..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "Spug 已停止"
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
    
    cat > "$INSTALL_DIR/bin/status.sh" << 'EOF'
#!/bin/bash

# Spug 状态检查脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

cd "$INSTALL_DIR"

echo "=== Spug 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== 资源使用 ==="
docker stats --no-stream spug spug-db 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=30 spug
else
    docker-compose logs --tail=30 spug
fi

echo ""
echo "=== 数据目录大小 ==="
du -sh "$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 创建初始化脚本 ===
create_init_script() {
    print_header "创建初始化脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/init.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/init.sh" << EOF
#!/bin/bash

# Spug 初始化脚本

set -e

ADMIN_USER="\${1:-admin}"
ADMIN_PASS="\${2:-${ADMIN_PASSWORD}}"

echo "=== Spug 初始化 ==="
echo "管理员账号：\$ADMIN_USER"
echo "管理员密码：\$ADMIN_PASS"
echo ""

# 等待 Spug 容器启动
echo "等待 Spug 服务就绪..."
max_attempts=30
attempt=0
while [[ \$attempt -lt \$max_attempts ]]; do
    if docker exec spug curl -s http://localhost:80 &> /dev/null; then
        echo "Spug 服务已就绪"
        break
    fi
    sleep 2
    ((attempt++))
    echo "等待中... (\$attempt/\$max_attempts)"
done

if [[ \$attempt -eq \$max_attempts ]]; then
    echo "错误：Spug 服务未就绪，请查看日志"
    exit 1
fi

# 执行初始化
echo "执行初始化..."
docker exec spug init_spug "\$ADMIN_USER" "\$ADMIN_PASS"

echo ""
echo "初始化完成！"
echo "访问地址：http://localhost:${SPUG_PORT}"
echo "管理员账号：\$ADMIN_USER"
echo "管理员密码：\$ADMIN_PASS"
EOF
    
    chmod +x "$INSTALL_DIR/bin/init.sh"
    print_success "初始化脚本创建完成"
}

# === 启动 Docker 服务 ===
start_docker_service() {
    print_header "启动 Spug 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 Spug 服务"
        return
    fi
    
    cd "$INSTALL_DIR"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动（首次启动约需 1-2 分钟）..."
    sleep 30
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    # 执行初始化
    print_info "执行初始化..."
    if docker exec spug curl -s http://localhost:80 &> /dev/null; then
        docker exec spug init_spug admin "$ADMIN_PASSWORD"
        print_success "初始化完成"
    else
        print_warning "Spug 服务未就绪，请稍后手动执行初始化："
        echo "  docker exec spug init_spug admin $ADMIN_PASSWORD"
    fi
    
    print_success "Spug 服务已启动"
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
    
    local SERVICE_FILE="/etc/systemd/system/spug.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "Spug systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Spug 自动化运维平台
Documentation=https://ops.spug.cc/
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用：sudo systemctl enable spug"
        print_info "启动：sudo systemctl start spug"
    fi
}

# === 主机模式安装 ===
host_install() {
    print_header "主机模式安装"
    
    print_warning "主机模式安装较为复杂，需要手动配置 Python 环境、MySQL、Redis 等依赖"
    print_info "推荐使用 Docker Compose 模式安装"
    print_info "如需继续，请确保已安装：Python3, MySQL, Redis, Nginx"
    
    read -p "是否继续主机模式安装？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消安装"
        exit 0
    fi
    
    # 检查依赖
    check_host_dependencies
    
    # 下载 Spug
    download_spug
    
    # 配置 MySQL
    configure_mysql
    
    # 配置 Redis
    configure_redis
    
    # 配置 Spug
    configure_spug
    
    # 配置 Nginx
    configure_nginx
    
    # 创建启动脚本
    create_host_startup_script
    
    if [[ "$AUTO_START" == "true" ]]; then
        configure_host_autostart
    fi
}

# === 检查主机依赖 ===
check_host_dependencies() {
    print_info "检查主机依赖..."
    
    local missing=()
    
    # 检查 Python
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        missing+=("Python3")
    fi
    
    # 检查 pip
    if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
        missing+=("pip3")
    fi
    
    # 检查 MySQL
    if ! command -v mysql &> /dev/null; then
        missing+=("MySQL")
    fi
    
    # 检查 Redis
    if ! command -v redis-cli &> /dev/null; then
        missing+=("Redis")
    fi
    
    # 检查 Nginx
    if ! command -v nginx &> /dev/null; then
        missing+=("Nginx")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "缺少依赖：${missing[*]}"
        print_info "请先安装上述依赖后重试"
        exit 1
    fi
    
    print_success "依赖检查通过"
}

# === 下载 Spug ===
download_spug() {
    print_info "下载 Spug..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载 Spug 到 $INSTALL_DIR/service"
        return
    fi
    
    local SPUG_REPO="https://github.com/openspug/spug.git"
    
    if [[ -d "$INSTALL_DIR/service" ]]; then
        print_info "更新 Spug..."
        cd "$INSTALL_DIR/service"
        git pull
    else
        print_info "克隆 Spug 仓库..."
        git clone --depth 1 "$SPUG_REPO" "$INSTALL_DIR/service"
    fi
    
    print_success "Spug 下载完成"
}

# === 配置 MySQL ===
configure_mysql() {
    print_info "配置 MySQL..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 MySQL 数据库"
        return
    fi
    
    # 创建数据库和用户
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" << EOF
CREATE DATABASE IF NOT EXISTS spug DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'spug'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON spug.* TO 'spug'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    print_success "MySQL 配置完成"
}

# === 配置 Redis ===
configure_redis() {
    print_info "配置 Redis..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 Redis"
        return
    fi
    
    # Redis 通常无需特殊配置，确保服务运行即可
    if ! systemctl is-active --quiet redis; then
        systemctl start redis
    fi
    
    print_success "Redis 配置完成"
}

# === 配置 Spug ===
configure_spug() {
    print_info "配置 Spug..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 Spug 服务"
        return
    fi
    
    cd "$INSTALL_DIR/service/spug"
    
    # 创建配置文件
    cat > "$INSTALL_DIR/service/spug/spug.conf" << EOF
[mysql]
host = localhost
port = 3306
database = spug
user = spug
password = ${MYSQL_PASSWORD}

[redis]
host = localhost
port = 6379
password = 

[spug]
admin_password = ${ADMIN_PASSWORD}
EOF
    
    # 安装 Python 依赖
    pip3 install -r requirements.txt
    
    # 初始化数据库
    python3 manage.py initdb
    
    # 创建管理员
    python3 manage.py inituser admin "${ADMIN_PASSWORD}"
    
    print_success "Spug 配置完成"
}

# === 配置 Nginx ===
configure_nginx() {
    print_info "配置 Nginx..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置 Nginx"
        return
    fi
    
    cat > "/etc/nginx/conf.d/spug.conf" << EOF
server {
    listen ${SPUG_PORT};
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    
    nginx -t && systemctl reload nginx
    
    print_success "Nginx 配置完成"
}

# === 创建主机模式启动脚本 ===
create_host_startup_script() {
    print_header "创建主机模式启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建启动脚本"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/startup.sh" << 'EOF'
#!/bin/bash

set -e

INSTALL_DIR="$HOME/spug"

echo "启动 Redis..."
systemctl start redis

echo "启动 MySQL..."
systemctl start mysqld

echo "启动 Spug..."
cd "$INSTALL_DIR/service/spug"
python3 manage.py runserver 0.0.0.0:8000 &

echo "启动 Nginx..."
systemctl start nginx

echo ""
echo "Spug 启动完成！"
echo "访问地址：http://localhost:80"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

set -e

echo "停止 Spug..."
pkill -f "manage.py runserver" || true

echo "停止 Nginx..."
systemctl stop nginx

echo "Spug 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    
    print_success "启动脚本创建完成"
}

# === 配置主机模式自启动 ===
configure_host_autostart() {
    print_info "配置主机模式自启动..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动"
        return
    fi
    
    cat > "$SPUG_INIT_SCRIPT" << EOF
#!/bin/bash
# chkconfig: 2345 90 10
# description: Spug 自动化运维平台

case "\$1" in
    start)
        $INSTALL_DIR/bin/startup.sh
        ;;
    stop)
        $INSTALL_DIR/bin/stop.sh
        ;;
    restart)
        $INSTALL_DIR/bin/stop.sh
        sleep 2
        $INSTALL_DIR/bin/startup.sh
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        exit 1
esac
EOF
    
    chmod +x "$SPUG_INIT_SCRIPT"
    
    if command -v systemctl &> /dev/null; then
        # systemd
        cat > "/etc/systemd/system/spug.service" << EOF
[Unit]
Description=Spug 自动化运维平台
After=network.target mysqld.service redis.service nginx.service

[Service]
Type=forking
ExecStart=$INSTALL_DIR/bin/startup.sh
ExecStop=$INSTALL_DIR/bin/stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable spug
    else
        # init.d
        if command -v chkconfig &> /dev/null; then
            chkconfig --add spug
            chkconfig spug on
        fi
    fi
    
    print_success "自启动配置完成"
}

# === 卸载 Spug ===
uninstall_spug() {
    print_header "卸载 Spug"
    
    print_warning "此操作将删除 Spug 所有数据和配置！"
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
    
    print_success "Spug 卸载完成"
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
    docker rm -f spug spug-db 2>/dev/null || true
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/spug.service ]]; then
        systemctl stop spug 2>/dev/null || true
        systemctl disable spug 2>/dev/null || true
        rm -f /etc/systemd/system/spug.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

# === 卸载主机模式 ===
uninstall_host() {
    print_info "停止服务..."
    
    # 停止 Spug
    pkill -f "manage.py runserver" 2>/dev/null || true
    
    # 删除 systemd/init.d 服务
    if [[ -f /etc/systemd/system/spug.service ]]; then
        systemctl stop spug 2>/dev/null || true
        systemctl disable spug 2>/dev/null || true
        rm -f /etc/systemd/system/spug.service
        systemctl daemon-reload
    fi
    
    if [[ -f "$SPUG_INIT_SCRIPT" ]]; then
        if command -v chkconfig &> /dev/null; then
            chkconfig --del spug 2>/dev/null || true
        fi
        rm -f "$SPUG_INIT_SCRIPT"
    fi
    
    # 删除 Nginx 配置
    rm -f /etc/nginx/conf.d/spug.conf
    nginx -s reload 2>/dev/null || true
    
    # 删除 MySQL 数据库（可选）
    read -p "是否删除 MySQL 数据库？(y/N): " confirm_db
    if [[ "$confirm_db" == "y" || "$confirm_db" == "Y" ]]; then
        mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS spug;" 2>/dev/null || true
        mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP USER IF EXISTS 'spug'@'localhost';" 2>/dev/null || true
    fi
    
    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    cat << EOF
${GREEN}Spug 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}访问地址:${NC} http://localhost:${SPUG_PORT}
${BOLD}管理员账号:${NC} admin
${BOLD}管理员密码:${NC} $ADMIN_PASSWORD

${BOLD}常用命令:${NC}
EOF
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cat << EOF
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  重新初始化：docker exec spug init_spug admin <password>
  查看日志：cd $INSTALL_DIR && docker-compose logs -f spug
EOF
    else
        cat << EOF
  启动服务：sudo systemctl start spug
  停止服务：sudo systemctl stop spug
  查看状态：sudo systemctl status spug
  查看日志：journalctl -u spug -f
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
    echo -e "${CYAN}更多信息请访问：https://ops.spug.cc/${NC}"
    echo ""
    print_warning "首次登录后请立即修改管理员密码！"
}

# === 主函数 ===
main() {
    print_header "Spug 自动化运维平台安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_spug
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  访问端口：$SPUG_PORT"
    echo "  安装模式：$INSTALL_MODE"
    echo "  管理员密码：$ADMIN_PASSWORD"
    echo "  MySQL 密码：$MYSQL_PASSWORD"
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

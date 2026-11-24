#!/bin/bash

# Sentinel Dashboard一键安装配置脚本
# 阿里巴巴开源的流量控制组件

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
readonly SENTINEL_VERSION="1.8.8"
readonly SENTINEL_IMAGE="bladex/sentinel-dashboard"
readonly DEFAULT_SENTINEL_PORT=8858
readonly DEFAULT_INSTALL_DIR="$HOME/sentinel"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
SENTINEL_PORT="$DEFAULT_SENTINEL_PORT"
DRY_RUN=false
UNINSTALL_MODE=false
USE_DOCKER=true

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

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        print_error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Sentinel Dashboard一键安装配置脚本

Sentinel是面向分布式服务架构的流量控制组件，主要以流量为切入点，从流量控制、熔断降级、系统负载保护等多个维度来帮助您保障微服务的稳定性。

用法: ./install-sentinel.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/sentinel)
    -p, --port PORT             端口号 (默认: 8858)
    --no-docker                 不使用Docker，直接下载jar包运行
    --dry-run                   试运行模式
    --uninstall                 卸载Sentinel

示例:
    ./install-sentinel.sh                           # 使用默认设置安装
    ./install-sentinel.sh --port 9000              # 指定端口
    ./install-sentinel.sh --no-docker              # 不使用Docker
    ./install-sentinel.sh --uninstall              # 卸载Sentinel

使用指南:
    1. 启动Sentinel: cd $INSTALL_DIR && docker-compose up -d
    2. 访问控制台: http://localhost:8858
    3. 默认账号密码: sentinel / sentinel
    4. 客户端接入: 在应用中引入sentinel依赖

更多信息: https://github.com/alibaba/Sentinel
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
                SENTINEL_PORT="$2"
                shift 2
                ;;
            --no-docker)
                USE_DOCKER=false
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
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查Docker ===
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "未检测到Docker"
        print_info "请先安装Docker，可以使用 docker/install-docker-compose.sh 脚本"
        exit 1
    fi
    
    print_info "检测到Docker: $(docker --version)"
}

# === 检查Docker Compose ===
check_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        print_info "检测到Docker Compose: $(docker-compose --version)"
        return 0
    elif docker compose version &> /dev/null; then
        print_info "检测到Docker Compose Plugin: $(docker compose version)"
        return 0
    else
        print_error "未检测到Docker Compose"
        print_info "请先安装Docker Compose"
        exit 1
    fi
}

# === 创建Docker Compose配置 ===
create_docker_compose() {
    print_header "创建Docker Compose配置..."
    
    mkdir -p "$INSTALL_DIR"
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  sentinel-dashboard:
    image: ${SENTINEL_IMAGE}:${SENTINEL_VERSION}
    container_name: sentinel-dashboard
    restart: always
    ports:
      - "${SENTINEL_PORT}:8858"
    environment:
      - TZ=Asia/Shanghai
      - JAVA_OPTS=-Dserver.port=8858 -Dcsp.sentinel.dashboard.server=localhost:8858 -Dproject.name=sentinel-dashboard -Dcsp.sentinel.api.port=8719 -Dcsp.sentinel.app.type=1
    volumes:
      - ./logs:/root/logs/csp
    networks:
      - sentinel-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8858/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  sentinel-network:
    driver: bridge
EOF
    
    print_success "Docker Compose配置创建完成: $INSTALL_DIR/$DOCKER_COMPOSE_FILE"
}

# === 创建启动脚本 ===
create_launch_script() {
    local launch_script="$INSTALL_DIR/start.sh"
    
    cat > "$launch_script" << 'EOF'
#!/bin/bash

# Sentinel Dashboard启动脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Sentinel Dashboard启动脚本 ==="
echo ""

# 检查Docker Compose配置文件
if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    echo "错误: 找不到docker-compose.yml文件"
    exit 1
fi

# 启动Sentinel
echo "正在启动Sentinel Dashboard..."
cd "$SCRIPT_DIR"

if command -v docker-compose &> /dev/null; then
    docker-compose up -d
else
    docker compose up -d
fi

echo ""
echo "=== 启动完成 ==="
echo "访问地址: http://localhost:$(grep -A 5 "ports:" "$SCRIPT_DIR/docker-compose.yml" | grep -oP '\d+(?=:8858)')"
echo "默认账号: sentinel"
echo "默认密码: sentinel"
echo ""
echo "查看日志: docker logs -f sentinel-dashboard"
echo "停止服务: cd $SCRIPT_DIR && docker-compose down"
EOF
    
    chmod +x "$launch_script"
    print_success "创建启动脚本: $launch_script"
}

# === 创建停止脚本 ===
create_stop_script() {
    local stop_script="$INSTALL_DIR/stop.sh"
    
    cat > "$stop_script" << 'EOF'
#!/bin/bash

# Sentinel Dashboard停止脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Sentinel Dashboard停止脚本 ==="
echo ""

cd "$SCRIPT_DIR"

if command -v docker-compose &> /dev/null; then
    docker-compose down
else
    docker compose down
fi

echo ""
echo "=== 停止完成 ==="
EOF
    
    chmod +x "$stop_script"
    print_success "创建停止脚本: $stop_script"
}

# === 下载Sentinel Jar包（非Docker模式） ===
download_sentinel_jar() {
    print_header "下载Sentinel Jar包..."
    
    mkdir -p "$INSTALL_DIR"
    
    local jar_file="$INSTALL_DIR/sentinel-dashboard-${SENTINEL_VERSION}.jar"
    local download_file_path="$DOWNLOAD_DIR/sentinel-dashboard-${SENTINEL_VERSION}.jar"
    local download_url="https://github.com/alibaba/Sentinel/releases/download/${SENTINEL_VERSION}/sentinel-dashboard-${SENTINEL_VERSION}.jar"
    
    if [ ! -f "$jar_file" ]; then
        print_info "正在下载: $download_url"
        if ! download_file "$download_url" "$download_file_path"; then
            print_error "下载失败"
            print_info "请手动下载Sentinel jar包到: $jar_file"
            exit 1
        fi
        cp "$download_file_path" "$jar_file"
        print_success "下载完成: $jar_file"
    else
        print_info "Sentinel jar包已存在: $jar_file"
    fi
    
    # 创建启动脚本
    create_jar_launch_script "$jar_file"
}

# === 创建Jar包启动脚本 ===
create_jar_launch_script() {
    local jar_file="$1"
    local launch_script="$INSTALL_DIR/start.sh"
    
    cat > "$launch_script" << EOF
#!/bin/bash

# Sentinel Dashboard启动脚本（Jar包模式）

JAR_FILE="${jar_file}"
PORT=${SENTINEL_PORT}

echo "=== Sentinel Dashboard启动脚本 ==="
echo "Jar包: \$JAR_FILE"
echo "端口: \$PORT"
echo ""

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo "错误: 未检测到Java环境"
    exit 1
fi

# 检查jar文件
if [ ! -f "\$JAR_FILE" ]; then
    echo "错误: 找不到jar文件: \$JAR_FILE"
    exit 1
fi

# 检查是否已启动
if pgrep -f "project.name=sentinel-dashboard" > /dev/null; then
    echo "Sentinel Dashboard 已经在运行中!"
    exit 0
fi

# 启动Sentinel
echo "正在后台启动Sentinel Dashboard..."
nohup java -Dserver.port=\$PORT \\
     -Dcsp.sentinel.dashboard.server=localhost:\$PORT \\
     -Dproject.name=sentinel-dashboard \\
     -Dcsp.sentinel.api.port=8719 \\
     -Dcsp.sentinel.app.type=1 \\
     -jar "\$JAR_FILE" > sentinel.log 2>&1 &

echo ""
echo "=== 启动完成 ==="
echo "访问地址: http://localhost:\$PORT"
echo "默认账号: sentinel"
echo "默认密码: sentinel"
echo "日志文件: sentinel.log"
EOF
    
    chmod +x "$launch_script"
    print_success "创建启动脚本: $launch_script"
}

# === 安装Sentinel ===
install_sentinel() {
    print_info "准备安装 Sentinel Dashboard"
    print_info "版本: $SENTINEL_VERSION"
    print_info "安装目录: $INSTALL_DIR"
    print_info "端口: $SENTINEL_PORT"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将安装Sentinel到 $INSTALL_DIR"
        return 0
    fi
    
    if [ "$USE_DOCKER" = true ]; then
        if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
            print_warning "未检测到Docker或Docker未启动，自动切换为主机模式安装(Jar包模式)"
            USE_DOCKER=false
        elif ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            print_warning "未检测到Docker Compose，自动切换为主机模式安装(Jar包模式)"
            USE_DOCKER=false
        fi
    fi

    if [ "$USE_DOCKER" = true ]; then
        # 检查Docker环境
        check_docker
        check_docker_compose
        
        # 创建Docker Compose配置
        create_docker_compose
        create_launch_script
        create_stop_script
    else
        # 下载jar包
        download_sentinel_jar
    fi
    
    print_success "Sentinel安装完成"
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."
    
    if [ "$USE_DOCKER" = true ]; then
        if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
            print_success "Docker Compose配置文件存在"
        else
            print_error "Docker Compose配置文件不存在"
            return 1
        fi
    else
        local jar_file="$INSTALL_DIR/sentinel-dashboard-${SENTINEL_VERSION}.jar"
        if [ -f "$jar_file" ]; then
            print_success "Sentinel jar包存在"
        else
            print_error "Sentinel jar包不存在"
            return 1
        fi
    fi
    
    # 显示使用说明
    print_header "使用说明"
    print_info "1. 启动Sentinel: cd $INSTALL_DIR && ./start.sh"
    print_info "2. 访问控制台: http://localhost:$SENTINEL_PORT"
    print_info "3. 默认账号密码: sentinel / sentinel"
    print_info "4. 查看日志: docker logs -f sentinel-dashboard"
    print_info "5. 停止服务: cd $INSTALL_DIR && ./stop.sh"
    
    return 0
}

# === 卸载Sentinel ===
uninstall_sentinel() {
    print_header "卸载Sentinel..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        return 0
    fi
    
    # 停止并删除容器
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "停止并删除Sentinel容器..."
        cd "$INSTALL_DIR"
        if command -v docker-compose &> /dev/null; then
            docker-compose down -v
        else
            docker compose down -v
        fi
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi
    
    print_success "Sentinel卸载完成"
}

# === 主函数 ===
main() {
    print_header "Sentinel Dashboard一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_sentinel
        return 0
    fi
    
    # 安装Sentinel
    install_sentinel
    
    # 验证安装
    verify_installation
    
    print_header "安装完成!"
    print_success "Sentinel Dashboard已成功安装并配置"
    
    print_header "正在尝试自动启动 Sentinel..."
    cd "$INSTALL_DIR" && ./start.sh
}

# === 执行主函数 ===
main "$@"

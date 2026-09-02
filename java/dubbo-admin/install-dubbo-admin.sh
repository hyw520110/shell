#!/bin/bash

# Dubbo Admin 一键安装配置脚本
# Dubbo 服务治理管理控制台

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
readonly DUBBO_ADMIN_VERSION="0.5.0"
readonly DUBBO_ADMIN_IMAGE="apache/dubbo-admin"
readonly DEFAULT_INSTALL_DIR="$HOME/dubbo-admin"
readonly DEFAULT_PORT="8080"
readonly DEFAULT_REGISTRY="nacos://localhost:8848"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
PORT="$DEFAULT_PORT"
REGISTRY_ADDRESS="$DEFAULT_REGISTRY"
DRY_RUN=false
UNINSTALL_MODE=false
INSTALL_MODE="auto"   # auto|docker|host
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 下载文件通用函数 ===
download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    output_dir="$(dirname "$output")"
    mkdir -p "$output_dir"

    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        print_info "使用 adl 下载: $url"
        if adl "$url" "$output_dir" "$(basename "$output")"; then
            return 0
        fi
        print_warning "adl 下载失败，回退到 curl/wget..."
    fi

    if command -v curl >/dev/null 2>&1; then
        print_info "使用 curl 下载: $url"
        if curl -L -C - --fail --connect-timeout 30 --retry 3 "$url" -o "$output"; then
            return 0
        fi
        print_warning "curl 下载失败"
    fi

    if command -v wget >/dev/null 2>&1; then
        print_info "使用 wget 下载: $url"
        if wget -c --timeout=30 --tries=3 "$url" -O "$output"; then
            return 0
        fi
        print_warning "wget 下载失败"
    fi

    print_error "所有下载工具均失败: $url"
    return 1
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "dubbo-admin" ]; then
        echo "$input"
    else
        echo "$input/dubbo-admin"
    fi
}

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
Dubbo Admin 一键安装配置脚本

用法: ./install-dubbo-admin.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/dubbo-admin)
    -p, --port PORT             Web 端口 (默认: 8080)
    -r, --registry ADDR         注册中心地址 (默认: nacos://localhost:8848)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    --dry-run                   试运行模式
    --uninstall                 卸载 Dubbo Admin

说明:
    - Docker 模式: 使用 Docker Compose 运行 Dubbo Admin
    - 主机模式: Dubbo Admin 需要源码编译，建议使用 Docker 模式
      如需主机安装，请参考: https://github.com/apache/dubbo-admin

注册中心格式:
    Nacos:    nacos://localhost:8848
    ZooKeeper: zookeeper://localhost:2181
    Consul:   consul://localhost:8500

示例:
    ./install-dubbo-admin.sh                              # 默认安装
    ./install-dubbo-admin.sh --port 9000                  # 指定端口
    ./install-dubbo-admin.sh -r zookeeper://localhost:2181  # 指定注册中心
    ./install-dubbo-admin.sh --uninstall                   # 卸载

使用指南:
    1. 安装完成后，访问: http://localhost:8080
    2. 配置注册中心地址
    3. 查看服务提供者、消费者、路由规则等信息

更多信息: https://github.com/apache/dubbo-admin
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
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -r|--registry)
                REGISTRY_ADDRESS="$2"
                shift 2
                ;;
            -m|--mode)
                INSTALL_MODE="$2"
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

# === Docker 检测 ===
docker_available() {
    command_exists docker && docker info &>/dev/null
}

# === 检查依赖 ===
check_dependencies() {
    if ! docker_available; then
        print_error "Docker 未安装或未运行"
        print_info "macOS: https://www.docker.com/products/docker-desktop"
        print_info "Linux: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi

    if ! docker compose version &>/dev/null && ! docker-compose version &>/dev/null; then
        print_error "Docker Compose 未安装，请先安装 Docker Compose"
        exit 1
    fi

    print_success "依赖检查通过"
}

# === 主机模式安装 ===
install_host_dubbo_admin() {
    print_header "主机模式安装 Dubbo Admin"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将下载到 $DOWNLOAD_DIR 并安装到 $INSTALL_DIR"
        return 0
    fi

    # 检查 Java
    if ! command -v java &>/dev/null; then
        print_error "Java 未安装，请先安装 JDK 8+"
        exit 1
    fi
    print_success "Java 环境检查通过：$(java -version 2>&1 | head -1)"

    local package_name="apache-dubbo-admin-${DUBBO_ADMIN_VERSION}-bin-release.tar.gz"
    local archive_path="$DOWNLOAD_DIR/$package_name"

    mkdir -p "$DOWNLOAD_DIR" "$INSTALL_DIR"

    # 检查是否已存在有效安装包
    if [[ -f "$archive_path" ]] && [[ -s "$archive_path" ]]; then
        print_info "检测到已存在安装包: $archive_path"
    else
        local download_url="https://github.com/apache/dubbo-admin/releases/download/${DUBBO_ADMIN_VERSION}/${package_name}"
        print_info "下载 Dubbo Admin: $download_url"
        if ! download_file "$download_url" "$archive_path"; then
            print_error "Dubbo Admin 下载失败"
            exit 1
        fi
    fi

    # 解压
    print_info "解压安装包..."
    local temp_dir
    temp_dir="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$temp_dir"

    local extracted_dir
    extracted_dir="$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)"
    if [[ -z "$extracted_dir" ]]; then
        rm -rf "$temp_dir"
        print_error "解压后未找到 Dubbo Admin 目录"
        exit 1
    fi

    # 复制到安装目录
    rm -rf "$INSTALL_DIR"/*
    cp -R "$extracted_dir"/* "$INSTALL_DIR/"
    rm -rf "$temp_dir"

    # 配置 application.properties
    local config_file="$INSTALL_DIR/conf/application.properties"
    if [[ -f "$config_file" ]]; then
        # 配置注册中心地址
        if [[ "$REGISTRY_ADDRESS" == nacos://* ]]; then
            local nacos_addr="${REGISTRY_ADDRESS#nacos://}"
            sed -i.bak "s|^registry.address=.*|registry.address=nacos://${nacos_addr}|" "$config_file"
            sed -i.bak "s|^config-center=.*|config-center=nacos://${nacos_addr}|" "$config_file"
            sed -i.bak "s|^metadata-report.address=.*|metadata-report.address=nacos://${nacos_addr}|" "$config_file"
        elif [[ "$REGISTRY_ADDRESS" == zookeeper://* ]]; then
            local zk_addr="${REGISTRY_ADDRESS#zookeeper://}"
            sed -i.bak "s|^registry.address=.*|registry.address=zookeeper://${zk_addr}|" "$config_file"
            sed -i.bak "s|^config-center=.*|config-center=zookeeper://${zk_addr}|" "$config_file"
            sed -i.bak "s|^metadata-report.address=.*|metadata-report.address=zookeeper://${zk_addr}|" "$config_file"
        fi
        rm -f "$config_file.bak"
        print_info "配置文件已更新，注册中心: $REGISTRY_ADDRESS"
    fi

    # 创建启动脚本
    cat > "$INSTALL_DIR/bin/startup.sh" << EOF
#!/bin/bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
INSTALL_DIR="\$(dirname "\$SCRIPT_DIR")"

# 启动 Dubbo Admin
if pgrep -f "dubbo-admin" > /dev/null 2>&1; then
    echo "Dubbo Admin 已在运行"
    exit 0
fi

echo "启动 Dubbo Admin..."
nohup java -jar "\$INSTALL_DIR/dubbo-admin-server-*.jar" > "\$INSTALL_DIR/logs/dubbo-admin.log" 2>&1 &
echo "Dubbo Admin 已启动，端口: ${PORT}"
echo "日志: \$INSTALL_DIR/logs/dubbo-admin.log"
EOF
    chmod +x "$INSTALL_DIR/bin/startup.sh"

    # 创建停止脚本
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash
echo "停止 Dubbo Admin..."
pids="$(pgrep -f "dubbo-admin" || true)"
if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 2
    pids="$(pgrep -f "dubbo-admin" || true)"
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null || true
    fi
    echo "Dubbo Admin 已停止"
else
    echo "Dubbo Admin 未运行"
fi
EOF
    chmod +x "$INSTALL_DIR/bin/stop.sh"

    # 创建状态检查脚本
    cat > "$INSTALL_DIR/bin/status.sh" << 'EOF'
#!/bin/bash
echo "=== Dubbo Admin 状态 ==="
if pgrep -f "dubbo-admin" > /dev/null 2>&1; then
    echo "Dubbo Admin: 运行中"
else
    echo "Dubbo Admin: 未运行"
fi
EOF
    chmod +x "$INSTALL_DIR/bin/status.sh"

    # 创建日志目录
    mkdir -p "$INSTALL_DIR/logs"

    print_success "Dubbo Admin 主机模式安装完成"
    print_info "安装目录: $INSTALL_DIR"
    print_info "访问地址: http://localhost:${PORT}"
    print_info "注册中心: ${REGISTRY_ADDRESS}"
    print_info "启动命令: $INSTALL_DIR/bin/startup.sh"
    print_info "停止命令: $INSTALL_DIR/bin/stop.sh"
}

# === 检查端口是否被占用 ===
check_port() {
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        print_warning "端口 $PORT 已被占用"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# === 安装 Dubbo Admin ===
install_admin() {
    print_header "安装 Dubbo Admin"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将安装 Dubbo Admin"
        print_info "  安装目录: $INSTALL_DIR"
        print_info "  端口: $PORT"
        print_info "  注册中心: $REGISTRY_ADDRESS"
        return 0
    fi
    
    # 检查端口
    check_port
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 生成 docker-compose.yml
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  dubbo-admin:
    image: ${DUBBO_ADMIN_IMAGE}
    container_name: dubbo-admin
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    environment:
      - "admin.registry.address=${REGISTRY_ADDRESS}"
      - "admin.config-center=nacos://localhost:8848"
      - "admin.metadata-report.address=nacos://localhost:8848"
      - "JAVA_OPTS=-Xms256m -Xmx256m"
    networks:
      - dubbo-network

networks:
  dubbo-network:
    driver: bridge
EOF

    print_success "docker-compose.yml 生成成功"

    # 启动服务（兼容新旧版 Docker Compose）
    cd "$INSTALL_DIR"
    if docker compose version &>/dev/null; then
        docker compose up -d
    elif command -v docker-compose &>/dev/null; then
        docker-compose up -d
    else
        print_error "未找到可用的 Docker Compose 命令"
        return 1
    fi

    print_success "Dubbo Admin 启动成功"
    print_info "访问地址: http://localhost:${PORT}"
    print_info "注册中心: ${REGISTRY_ADDRESS}"
}

# === 卸载 Dubbo Admin ===
uninstall_admin() {
    print_header "卸载 Dubbo Admin"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 Dubbo Admin"
        return 0
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_warning "Dubbo Admin 未安装"
        exit 0
    fi
    
    # 停止服务
    cd "$INSTALL_DIR"
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        if docker compose version &>/dev/null; then
            docker compose down
        elif command -v docker-compose &>/dev/null; then
            docker-compose down
        fi
    fi
    
    # 询问是否删除数据
    read -p "是否删除安装目录 $INSTALL_DIR? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "安装目录已删除"
    fi
    
    print_success "Dubbo Admin 卸载完成"
}

# === 主函数 ===
main() {
    print_header "Dubbo Admin 一键安装配置脚本"

    # 解析参数
    parse_arguments "$@"

    # 自动选择模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if docker_available; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，使用 Docker 模式"
        else
            INSTALL_MODE="host"
            print_info "Docker 不可用，使用主机模式"
        fi
    fi

    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_admin
        exit 0
    fi

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # 检查依赖
        check_dependencies
        # 安装 Admin
        install_admin

        print_header "安装完成!"
        print_success "Dubbo Admin 已成功安装"
        print_info "安装目录: $INSTALL_DIR"
        print_info "访问地址: http://localhost:${PORT}"
        print_info "注册中心: ${REGISTRY_ADDRESS}"

        print_info "管理命令:"
        print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
        print_info "  停止: cd $INSTALL_DIR && docker compose down"
        print_info "  日志: cd $INSTALL_DIR && docker compose logs -f"
        print_info "  重启: cd $INSTALL_DIR && docker compose restart"
    else
        install_host_dubbo_admin
    fi
}

# === 执行主函数 ===
main "$@"

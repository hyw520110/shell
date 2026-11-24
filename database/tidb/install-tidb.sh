#!/bin/bash

# TiDB 一键安装配置脚本
# 分布式关系型数据库，支持 MySQL 协议

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
readonly TIDB_VERSION="v7.5.0"
readonly TIKV_VERSION="v7.5.0"
readonly PD_VERSION="v7.5.0"
readonly DEFAULT_INSTALL_DIR="/opt/tidb"
readonly DEFAULT_DATA_DIR="/data/tidb"
readonly PD_PORT=2379
readonly TIDB_PORT=4000
readonly TIKV_PORT=20160

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DATA_DIR="$DEFAULT_DATA_DIR"
MODE="auto"  # auto, docker, host
DRY_RUN=false
UNINSTALL_MODE=false
ENABLE_SERVICE=false

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

# === 检测操作系统 ===
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "darwin";;
        *)          echo "unknown";;
    esac
}

# === 检测系统架构 ===
detect_architecture() {
    case "$(uname -m)" in
        x86_64)     echo "amd64";;
        aarch64|arm64) echo "aarch64";;
        *)          echo "unknown";;
    esac
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
TiDB 一键安装配置脚本

用法: ./install-tidb.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: /opt/tidb)
    --data-dir DIR              数据目录 (默认: /data/tidb)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    --enable-service            启用系统服务 (主机模式)
    --dry-run                   试运行模式
    --uninstall                 卸载 TiDB

模式说明:
    auto    - 自动检测，优先使用 Docker，未安装则使用主机模式
    docker  - 强制使用 Docker Compose 模式
    host    - 强制使用主机模式

环境要求:
    Docker 模式: Docker + Docker Compose
    主机模式: Linux 系统，至少 8GB 内存

示例:
    ./install-tidb.sh                           # 自动模式安装
    ./install-tidb.sh --mode docker            # Docker 模式
    ./install-tidb.sh --mode host --enable-service  # 主机模式 + 系统服务
    ./install-tidb.sh --uninstall               # 卸载 TiDB

使用指南:
    1. 安装完成后，使用 MySQL 客户端连接: mysql -h 127.0.0.1 -P 4000 -u root
    2. 默认密码: 空
    3. 兼容 MySQL 5.7 协议

更多信息: https://docs.pingcap.com/tidb/stable
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
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            --enable-service)
                ENABLE_SERVICE=true
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

# === 检查依赖 ===
check_dependencies() {
    local os_type=$(detect_os)
    
    if [[ "$MODE" == "docker" ]] || [[ "$MODE" == "auto" ]]; then
        if command_exists docker && command_exists docker compose; then
            MODE="docker"
            print_success "检测到 Docker 环境，使用 Docker 模式"
        elif [[ "$MODE" == "docker" ]]; then
            print_error "Docker 模式需要 Docker 和 Docker Compose"
            exit 1
        fi
    fi
    
    if [[ "$MODE" == "host" ]] || [[ "$MODE" == "auto" ]]; then
        if [[ "$os_type" == "darwin" ]]; then
            print_warning "主机模式仅支持 Linux 系统"
            if command_exists docker && command_exists docker compose; then
                MODE="docker"
                print_info "自动切换到 Docker 模式"
            else
                print_error "macOS 不支持主机模式，且未检测到 Docker"
                exit 1
            fi
        fi
    fi
    
    if [[ "$MODE" == "host" ]]; then
        # 检查系统资源
        local total_mem=$(free -g | awk '/^Mem:/{print $2}')
        if [[ "$total_mem" -lt 8 ]]; then
            print_warning "系统内存不足 8GB，建议至少 8GB"
        fi
        
        # 检查必要工具
        for cmd in curl wget; do
            if command_exists "$cmd"; then
                DOWNLOAD_CMD="$cmd"
                break
            fi
        done
        
        if [[ -z "$DOWNLOAD_CMD" ]]; then
            print_error "需要 curl 或 wget 来下载安装包"
            exit 1
        fi
        
        print_success "主机模式依赖检查通过"
    fi
}

# === Docker 模式安装 ===
install_docker_mode() {
    print_header "Docker 模式安装 TiDB"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将生成 docker-compose.yml"
        return 0
    fi
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/pd"
    mkdir -p "$DATA_DIR/tikv"
    mkdir -p "$DATA_DIR/tidb"
    
    # 生成 docker-compose.yml
    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  pd:
    image: pingcap/pd:${PD_VERSION}
    container_name: tidb-pd
    restart: unless-stopped
    ports:
      - "${PD_PORT}:2379"
    volumes:
      - $DATA_DIR/pd:/data
    command:
      - --name=pd1
      - --data-dir=/data/pd
      - --client-urls=http://0.0.0.0:2379
      - --peer-urls=http://0.0.0.0:2380
      - --advertise-client-urls=http://pd:2379
      - --advertise-peer-urls=http://pd:2380
      - --initial-cluster=pd1=http://pd:2380
    networks:
      - tidb-network

  tikv:
    image: pingcap/tikv:${TIKV_VERSION}
    container_name: tidb-tikv
    restart: unless-stopped
    ports:
      - "${TIKV_PORT}:20160"
    volumes:
      - $DATA_DIR/tikv:/data
    command:
      - --addr=0.0.0.0:20160
      - --advertise-addr=tikv:20160
      - --data-dir=/data/tikv
      - --pd=http://pd:2379
    depends_on:
      - pd
    networks:
      - tidb-network

  tidb:
    image: pingcap/tidb:${TIDB_VERSION}
    container_name: tidb-server
    restart: unless-stopped
    ports:
      - "${TIDB_PORT}:4000"
      - "10080:10080"
    environment:
      - TZ=Asia/Shanghai
    command:
      - --store=tikv
      - --path=pd:2379
      - --advertise-address=tidb
      - --log-slow-threshold=300
    depends_on:
      - pd
      - tikv
    networks:
      - tidb-network

networks:
  tidb-network:
    driver: bridge
EOF

    print_success "docker-compose.yml 生成成功"
    
    # 启动服务
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "TiDB 启动成功"
    print_info "连接信息: mysql -h 127.0.0.1 -P ${TIDB_PORT} -u root"
}

# === 主机模式安装 ===
install_host_mode() {
    print_header "主机模式安装 TiDB"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将下载并安装 TiDB 组件"
        return 0
    fi
    
    local os_type=$(detect_os)
    local arch_type=$(detect_architecture)
    
    if [[ "$os_type" == "unknown" ]] || [[ "$arch_type" == "unknown" ]]; then
        print_error "不支持的操作系统或架构"
        exit 1
    fi
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/pd"
    mkdir -p "$DATA_DIR/tikv"
    mkdir -p "$DATA_DIR/tidb"
    
    # 下载组件
    print_info "下载 TiDB 组件..."
    
    local pd_url="https://download.pingcap.org/pd-${PD_VERSION}-linux-${arch_type}.tar.gz"
    local tikv_url="https://download.pingcap.org/tikv-${TIKV_VERSION}-linux-${arch_type}.tar.gz"
    local tidb_url="https://download.pingcap.org/tidb-${TIDB_VERSION}-linux-${arch_type}.tar.gz"
    
    cd "$INSTALL_DIR"
    
    if command_exists curl; then
        curl -fsSL "$pd_url" | tar xz
        curl -fsSL "$tikv_url" | tar xz
        curl -fsSL "$tidb_url" | tar xz
    elif command_exists wget; then
        wget -qO- "$pd_url" | tar xz
        wget -qO- "$tikv_url" | tar xz
        wget -qO- "$tidb_url" | tar xz
    fi
    
    # 创建软链接
    ln -sf "pd-${PD_VERSION}-linux-${arch_type}" pd
    ln -sf "tikv-${TIKV_VERSION}-linux-${arch_type}" tikv
    ln -sf "tidb-${TIDB_VERSION}-linux-${arch_type}" tidb
    
    # 生成启动脚本
    cat > "$INSTALL_DIR/start-host.sh" << 'EOF'
#!/bin/bash
# 启动 PD
nohup ./pd/bin/pd-server \
  --name=pd1 \
  --data-dir=$DATA_DIR/pd \
  --client-urls=http://0.0.0.0:2379 \
  --peer-urls=http://0.0.0.0:2380 \
  --advertise-client-urls=http://127.0.0.1:2379 \
  --advertise-peer-urls=http://127.0.0.1:2380 \
  --initial-cluster=pd1=http://127.0.0.1:2380 \
  > logs/pd.log 2>&1 &

sleep 5

# 启动 TiKV
nohup ./tikv/bin/tikv-server \
  --addr=0.0.0.0:20160 \
  --advertise-addr=127.0.0.1:20160 \
  --data-dir=$DATA_DIR/tikv \
  --pd=http://127.0.0.1:2379 \
  > logs/tikv.log 2>&1 &

sleep 10

# 启动 TiDB
nohup ./tidb/bin/tidb-server \
  --store=tikv \
  --path=127.0.0.1:2379 \
  --port=4000 \
  --log-slow-threshold=300 \
  > logs/tidb.log 2>&1 &

echo "TiDB 启动成功"
EOF
    
    # 创建停止脚本
    cat > "$INSTALL_DIR/stop-host.sh" << 'EOF'
#!/bin/bash
killall tidb-server
killall tikv-server
killall pd-server
echo "TiDB 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/start-host.sh"
    chmod +x "$INSTALL_DIR/stop-host.sh"
    
    # 创建日志目录
    mkdir -p "$INSTALL_DIR/logs"
    
    # 启动服务
    print_info "启动 TiDB 服务..."
    cd "$INSTALL_DIR"
    ./start-host.sh
    
    # 配置系统服务（如果启用）
    if [[ "$ENABLE_SERVICE" == true ]]; then
        print_info "配置系统服务..."
        
        # PD 服务
        cat > /etc/systemd/system/tidb-pd.service << EOF
[Unit]
Description=TiDB PD
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/pd/bin/pd-server --name=pd1 --data-dir=$DATA_DIR/pd --client-urls=http://0.0.0.0:2379 --peer-urls=http://0.0.0.0:2380 --advertise-client-urls=http://127.0.0.1:2379 --advertise-peer-urls=http://127.0.0.1:2380 --initial-cluster=pd1=http://127.0.0.1:2380
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        # TiKV 服务
        cat > /etc/systemd/system/tidb-tikv.service << EOF
[Unit]
Description=TiDB TiKV
After=network.target tidb-pd.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/tikv/bin/tikv-server --addr=0.0.0.0:20160 --advertise-addr=127.0.0.1:20160 --data-dir=$DATA_DIR/tikv --pd=http://127.0.0.1:2379
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        # TiDB 服务
        cat > /etc/systemd/system/tidb-server.service << EOF
[Unit]
Description=TiDB Server
After=network.target tidb-pd.service tidb-tikv.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/tidb/bin/tidb-server --store=tikv --path=127.0.0.1:2379 --port=4000 --log-slow-threshold=300
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable tidb-pd tidb-tikv tidb-server
        
        print_success "系统服务已配置并启用自启动"
    fi
    
    print_success "TiDB 安装成功"
    print_info "连接信息: mysql -h 127.0.0.1 -P 4000 -u root"
}

# === 卸载 TiDB ===
uninstall_tidb() {
    print_header "卸载 TiDB"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 TiDB"
        return 0
    fi
    
    # 停止服务
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        print_info "停止 Docker 模式服务..."
        cd "$INSTALL_DIR"
        docker compose down
    fi
    
    if [[ -f "$INSTALL_DIR/stop-host.sh" ]]; then
        print_info "停止主机模式服务..."
        cd "$INSTALL_DIR"
        ./stop-host.sh
    fi
    
    # 禁用系统服务
    if systemctl is-enabled tidb-server &>/dev/null; then
        print_info "禁用系统服务..."
        systemctl disable tidb-pd tidb-tikv tidb-server
        rm -f /etc/systemd/system/tidb-*.service
        systemctl daemon-reload
    fi
    
    # 询问是否删除数据
    read -p "是否删除数据目录 $DATA_DIR? (y/n): " -n 1 -r
echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR"
        print_success "数据目录已删除"
    fi
    
    # 询问是否删除安装目录
    read -p "是否删除安装目录 $INSTALL_DIR? (y/n): " -n 1 -r
echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "安装目录已删除"
    fi
    
    print_success "TiDB 卸载完成"
}

# === 主函数 ===
main() {
    print_header "TiDB 一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_tidb
        exit 0
    fi
    
    # 根据模式安装
    if [[ "$MODE" == "docker" ]]; then
        install_docker_mode
    elif [[ "$MODE" == "host" ]]; then
        install_host_mode
    else
        print_error "未知安装模式: $MODE"
        exit 1
    fi
    
    print_header "安装完成!"
    print_success "TiDB 已成功安装"
    print_info "安装目录: $INSTALL_DIR"
    print_info "数据目录: $DATA_DIR"
    
    if [[ "$MODE" == "docker" ]]; then
        print_info "管理命令:"
        print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
        print_info "  停止: cd $INSTALL_DIR && docker compose down"
        print_info "  日志: cd $INSTALL_DIR && docker compose logs -f"
    else
        print_info "管理命令:"
        print_info "  启动: cd $INSTALL_DIR && ./start-host.sh"
        print_info "  停止: cd $INSTALL_DIR && ./stop-host.sh"
        if [[ "$ENABLE_SERVICE" == true ]]; then
            print_info "  系统服务: systemctl start/stop tidb-server"
        fi
    fi
    
    print_info "连接信息: mysql -h 127.0.0.1 -P 4000 -u root"
}

# === 执行主函数 ===
main "$@"
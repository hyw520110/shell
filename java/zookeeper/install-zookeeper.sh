#!/bin/bash

# ZooKeeper 一键安装配置脚本
# Apache ZooKeeper 分布式协调服务
# 支持单机、分布式集群、单机伪集群三种部署模式

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
readonly ZOOKEEPER_VERSION="3.9.2"
readonly ZOOKEEPER_IMAGE="apache/zookeeper"
readonly DEFAULT_INSTALL_DIR="$HOME/zookeeper"
readonly DEFAULT_DATA_DIR="$HOME/zookeeper/data"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DATA_DIR="$DEFAULT_DATA_DIR"
DEPLOY_MODE="standalone"  # standalone, cluster, pseudo-cluster
NODES=1                  # 集群节点数
HOST_BASE_PORT=2181      # 基础客户端端口
HOST_PEER_PORT=2888       # 基础通信端口
HOST_ELECTION_PORT=3888  # 基础选举端口
DOCKER_MODE=true          # 是否使用 Docker 模式
DRY_RUN=false
UNINSTALL_MODE=false
ENABLE_SERVICE=false
HOST_IP=""                # 集群模式下的主机 IP

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

find_adl() {
    if command_exists adl && adl --help >/dev/null 2>&1; then
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

    if command_exists curl; then
        curl -L --fail -o "$output" "$url"
    elif command_exists wget; then
        wget -O "$output" "$url"
    else
        print_error "需要 adl、curl 或 wget 来下载安装包"
        return 1
    fi
}

verify_tar_gz() {
    local file="$1"
    [ -f "$file" ] && tar -tzf "$file" >/dev/null 2>&1
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
ZooKeeper 一键安装配置脚本

用法: ./install-zookeeper.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/zookeeper)
    --data-dir DIR              数据目录 (默认: ~/zookeeper/data)
    --deploy-mode MODE          部署模式: standalone|cluster|pseudo-cluster (默认: standalone)
    -n, --nodes NUM             集群节点数 (默认: 1)
    --host-ip IP                集群模式下指定本机 IP
    --docker                    使用 Docker 模式
    --host                      使用主机模式
    --enable-service            启用系统服务 (主机模式)
    --dry-run                   试运行模式
    --uninstall                 卸载 ZooKeeper

部署模式说明:
    standalone      - 单机模式，运行一个实例
    cluster         - 分布式集群，多台服务器（每台运行一个实例）
    pseudo-cluster - 单机伪集群，同一台机器运行多个实例

示例:
    # 单机模式
    ./install-zookeeper.sh --deploy-mode standalone

    # 分布式集群（3节点，需要指定主机IP）
    ./install-zookeeper.sh --deploy-mode cluster --nodes 3 --host-ip 192.168.1.100

    # 单机伪集群（3个节点）
    ./install-zookeeper.sh --deploy-mode pseudo-cluster --nodes 3

    # 单机伪集群 + Docker
    ./install-zookeeper.sh --deploy-mode pseudo-cluster --nodes 5 --docker

环境要求:
    Docker 模式: Docker + Docker Compose
    主机模式: Linux 系统，需要 JDK 环境

使用指南:
    1. 安装完成后，使用 ZooKeeper 客户端连接
    2. 单机模式: zkCli.sh -server localhost:2181
    3. 集群模式: zkCli.sh -server localhost:2181,2182,2183

更多信息: https://zookeeper.apache.org/
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
            --deploy-mode)
                DEPLOY_MODE="$2"
                shift 2
                ;;
            -n|--nodes)
                NODES="$2"
                shift 2
                ;;
            --host-ip)
                HOST_IP="$2"
                shift 2
                ;;
            --docker)
                DOCKER_MODE=true
                shift
                ;;
            --host)
                DOCKER_MODE=false
                shift
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
    
    # 验证参数
    if [[ "$DEPLOY_MODE" != "standalone" ]] && [[ "$DEPLOY_MODE" != "cluster" ]] && [[ "$DEPLOY_MODE" != "pseudo-cluster" ]]; then
        print_error "无效的部署模式: $DEPLOY_MODE"
        exit 1
    fi
    
    if [[ "$DEPLOY_MODE" != "standalone" ]]; then
        if [[ "$NODES" -lt 3 ]]; then
            print_warning "集群模式建议至少 3 个节点"
        fi
        
        if [[ "$DEPLOY_MODE" == "cluster" ]] && [[ -z "$HOST_IP" ]]; then
            print_error "分布式集群模式必须指定 --host-ip 参数"
            exit 1
        fi
    fi
}

# === 检查依赖 ===
check_dependencies() {
    local os_type=$(detect_os)
    
    # 检查 Docker
    if [[ "$DOCKER_MODE" == true ]]; then
        if command_exists docker && command_exists docker compose; then
            print_success "检测到 Docker 环境，使用 Docker 模式"
        else
            print_error "Docker 模式需要 Docker 和 Docker Compose"
            exit 1
        fi
    fi
    
    # 检查主机模式依赖
    if [[ "$DOCKER_MODE" == false ]]; then
        if [[ "$os_type" == "darwin" ]]; then
            print_error "主机模式仅支持 Linux 系统"
            exit 1
        fi
        
        # 检查 JDK
        if ! command_exists java; then
            print_error "主机模式需要 JDK 环境"
            exit 1
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

# === 检查端口是否被占用 ===
check_ports() {
    local nodes=${1:-1}
    local start_port=${2:-$HOST_BASE_PORT}
    
    for ((i=0; i<nodes; i++)); do
        local port=$((start_port + i))
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            print_warning "端口 $port 已被占用"
            read -p "是否继续? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    done
}

# === Docker 模式安装 ===
install_docker_mode() {
    print_header "Docker 模式安装 ZooKeeper"
    print_info "部署模式: $DEPLOY_MODE"
    print_info "节点数量: $NODES"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将生成 docker-compose.yml"
        return 0
    fi
    
    # 检查端口
    check_ports $NODES $HOST_BASE_PORT
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    
    # 生成 docker-compose.yml
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << HEADER
version: '3.8'

services:
HEADER

    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        # 单机模式
        cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << STANDALONE
  zookeeper:
    image: ${ZOOKEEPER_IMAGE}:${ZOOKEEPER_VERSION}
    container_name: zookeeper
    hostname: zookeeper
    restart: unless-stopped
    ports:
      - "${HOST_BASE_PORT}:2181"
      - "${HOST_PEER_PORT}:2888"
      - "${HOST_ELECTION_PORT}:3888"
    environment:
      ZOO_MY_ID: 1
      ZOO_PORT: 2181
      ZOO_TICK_TIME: 2000
      ZOO_INIT_LIMIT: 5
      ZOO_SYNC_LIMIT: 2
      ZOO_MAX_CLIENT_CNXNS: 60
      ZOO_STANDALONE_ENABLED: "true"
    volumes:
      - ${DATA_DIR}/standalone:/data
      - ${INSTALL_DIR}/logs/standalone:/datalog
    networks:
      - zookeeper-network

networks:
  zookeeper-network:
    driver: bridge
STANDALONE
    elif [[ "$DEPLOY_MODE" == "pseudo-cluster" ]]; then
        # 单机伪集群
        local servers=""
        for ((i=1; i<=NODES; i++)); do
            servers="${servers}server.${i}=zookeeper${i}:${HOST_PEER_PORT}:3888\n"
        done
        echo -e "$servers" > /tmp/zoo_servers.cfg
        
        for ((i=1; i<=NODES; i++)); do
            local client_port=$((HOST_BASE_PORT + i - 1))
            local peer_port=$((HOST_PEER_PORT + (i - 1) * 100))
            local election_port=$((HOST_ELECTION_PORT + (i - 1) * 100))
            
            cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << NODE
  zookeeper${i}:
    image: ${ZOOKEEPER_IMAGE}:${ZOOKEEPER_VERSION}
    container_name: zookeeper${i}
    hostname: zookeeper${i}
    restart: unless-stopped
    ports:
      - "${client_port}:2181"
      - "${peer_port}:2888"
      - "${election_port}:3888"
    environment:
      ZOO_MY_ID: ${i}
      ZOO_PORT: 2181
      ZOO_TICK_TIME: 2000
      ZOO_INIT_LIMIT: 10
      ZOO_SYNC_LIMIT: 5
      ZOO_MAX_CLIENT_CNXNS: 60
      ZOO_SERVERS: "$(echo -e "$servers" | sed 's/\\n/, /g' | sed 's/, $//')"
    volumes:
      - ${DATA_DIR}/node${i}:/data
      - ${INSTALL_DIR}/logs/node${i}:/datalog
    networks:
      - zookeeper-network

NODE
        done
        
        cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << NETWORK
networks:
  zookeeper-network:
    driver: bridge
NETWORK
    elif [[ "$DEPLOY_MODE" == "cluster" ]]; then
        # 分布式集群（仅配置当前节点）
        local node_id=1
        local client_port=$HOST_BASE_PORT
        local peer_port=$HOST_PEER_PORT
        local election_port=$HOST_ELECTION_PORT
        
        cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << CLUSTER
  zookeeper:
    image: ${ZOOKEEPER_IMAGE}:${ZOOKEEPER_VERSION}
    container_name: zookeeper
    hostname: zookeeper
    restart: unless-stopped
    ports:
      - "${client_port}:2181"
      - "${peer_port}:2888"
      - "${election_port}:3888"
    environment:
      ZOO_MY_ID: ${node_id}
      ZOO_PORT: 2181
      ZOO_TICK_TIME: 2000
      ZOO_INIT_LIMIT: 10
      ZOO_SYNC_LIMIT: 5
      ZOO_MAX_CLIENT_CNXNS: 60
      ZOO_SERVERS: "server.${node_id}=zookeeper:${peer_port}:3888"
    volumes:
      - ${DATA_DIR}/cluster/node${node_id}:/data
      - ${INSTALL_DIR}/logs/cluster/node${node_id}:/datalog
    networks:
      - zookeeper-network

networks:
  zookeeper-network:
    driver: bridge
CLUSTER
        print_warning "分布式集群模式需要在每台服务器上运行此脚本"
        print_info "其他服务器请修改 ZOO_MY_ID 和相应的配置"
    fi
    
    print_success "docker-compose.yml 生成成功"
    
    # 启动服务
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "ZooKeeper 启动成功"
    
    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
    elif [[ "$DEPLOY_MODE" == "pseudo-cluster" ]]; then
        local nodes_list=""
        for ((i=1; i<=NODES; i++)); do
            nodes_list="${nodes_list}$((HOST_BASE_PORT + i - 1)),"
        done
        nodes_list="${nodes_list%,}"
        print_info "连接信息: zkCli.sh -server localhost:${nodes_list}"
    else
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
        print_info "集群节点: $HOST_IP:$HOST_BASE_PORT"
    fi
}

# === 主机模式安装 ===
install_host_mode() {
    print_header "主机模式安装 ZooKeeper"
    print_info "部署模式: $DEPLOY_MODE"
    print_info "节点数量: $NODES"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将下载并安装 ZooKeeper"
        return 0
    fi
    
    local os_type=$(detect_os)
    local arch_type=$(detect_architecture)
    
    if [[ "$os_type" == "unknown" ]] || [[ "$arch_type" == "unknown" ]]; then
        print_error "不支持的操作系统或架构"
        exit 1
    fi
    
    # 检查端口
    check_ports $NODES $HOST_BASE_PORT
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"
    
    # 下载 ZooKeeper
    print_info "下载 ZooKeeper..."
    local download_url="https://downloads.apache.org/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz"
    
    local archive="$DOWNLOAD_DIR/${download_url##*/}"
    if ! verify_tar_gz "$archive"; then
        [ -f "$archive" ] && print_warning "检测到安装包损坏或不完整，尝试重新下载: $archive"
        download_file "$download_url" "$archive"
    fi
    if ! verify_tar_gz "$archive"; then
        print_error "安装包不是有效 tar.gz: $archive"
        exit 1
    fi

    rm -rf "$INSTALL_DIR/apache-zookeeper-${ZOOKEEPER_VERSION}-bin"
    tar -xzf "$archive" -C "$INSTALL_DIR"
    
    # 创建软链接
    ln -sf "apache-zookeeper-${ZOOKEEPER_VERSION}-bin" zookeeper
    
    # 根据部署模式生成配置
    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        # 单机模式配置
        mkdir -p "$DATA_DIR/standalone"
        cat > "$INSTALL_DIR/zookeeper/conf/zoo.cfg" << EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$DATA_DIR/standalone
clientPort=$HOST_BASE_PORT
maxClientCnxns=60
autopurge.snapRetainCount=3
autopurge.purgeInterval=1
EOF
    elif [[ "$DEPLOY_MODE" == "pseudo-cluster" ]]; then
        # 单机伪集群配置
        local servers=""
        for ((i=1; i<=NODES; i++)); do
            servers="${servers}server.${i}=127.0.0.1:$((HOST_PEER_PORT + (i - 1) * 100)):$((HOST_ELECTION_PORT + (i - 1) * 100))\n"
            mkdir -p "$DATA_DIR/node${i}"
            mkdir -p "$INSTALL_DIR/zookeeper/data/node${i}"
            echo "$i" > "$INSTALL_DIR/zookeeper/data/node${i}/myid"
        done
        
        cat > "$INSTALL_DIR/zookeeper/conf/zoo.cfg" << EOF
tickTime=2000
initLimit=10
syncLimit=5
$(echo -e "$servers")
maxClientCnxns=60
EOF
    elif [[ "$DEPLOY_MODE" == "cluster" ]]; then
        # 分布式集群配置
        mkdir -p "$DATA_DIR/cluster/node1"
        mkdir -p "$INSTALL_DIR/zookeeper/data/cluster/node1"
        echo "1" > "$INSTALL_DIR/zookeeper/data/cluster/node1/myid"
        
        cat > "$INSTALL_DIR/zookeeper/conf/zoo.cfg" << EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$DATA_DIR/cluster/node1
clientPort=$HOST_BASE_PORT
maxClientCnxns=60
server.1=$HOST_IP:$HOST_PEER_PORT:3888
EOF
    fi
    
    # 创建启动脚本
    cat > "$INSTALL_DIR/start-host.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/zookeeper"
./bin/zkServer.sh start
echo "ZooKeeper 启动成功"
EOF
    
    # 创建停止脚本
    cat > "$INSTALL_DIR/stop-host.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/zookeeper"
./bin/zkServer.sh stop
echo "ZooKeeper 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/start-host.sh"
    chmod +x "$INSTALL_DIR/stop-host.sh"
    
    # 启动服务
    print_info "启动 ZooKeeper 服务..."
    cd "$INSTALL_DIR"
    ./start-host.sh
    
    # 配置系统服务（如果启用）
    if [[ "$ENABLE_SERVICE" == true ]]; then
        if [[ "$(detect_os)" != "linux" ]] || ! command_exists systemctl || [[ "$EUID" -ne 0 ]]; then
            print_warning "当前环境不支持直接配置 systemd 服务，已跳过"
            print_success "ZooKeeper 安装成功"
            return 0
        fi
        print_info "配置系统服务..."
        
        cat > /etc/systemd/system/zookeeper.service << EOF
[Unit]
Description=ZooKeeper Service
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=$INSTALL_DIR/zookeeper
ExecStart=$INSTALL_DIR/zookeeper/bin/zkServer.sh start
ExecStop=$INSTALL_DIR/zookeeper/bin/zkServer.sh stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable zookeeper
        
        print_success "系统服务已配置并启用自启动"
    fi
    
    print_success "ZooKeeper 安装成功"
    
    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
    elif [[ "$DEPLOY_MODE" == "pseudo-cluster" ]]; then
        local nodes_list=""
        for ((i=1; i<=NODES; i++)); do
            nodes_list="${nodes_list}$((HOST_BASE_PORT + i - 1)),"
        done
        nodes_list="${nodes_list%,}"
        print_info "连接信息: zkCli.sh -server localhost:${nodes_list}"
    else
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
        print_info "集群节点: $HOST_IP:$HOST_BASE_PORT"
    fi
}

# === 卸载 ZooKeeper ===
uninstall_zookeeper() {
    print_header "卸载 ZooKeeper"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 ZooKeeper"
        return 0
    fi
    
    # 停止服务
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
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
    if command_exists systemctl && systemctl is-enabled zookeeper &>/dev/null; then
        print_info "禁用系统服务..."
        systemctl disable zookeeper
        rm -f /etc/systemd/system/zookeeper.service
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
    
    print_success "ZooKeeper 卸载完成"
}

# === 主函数 ===
main() {
    print_header "ZooKeeper 一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_zookeeper
        exit 0
    fi
    
    # 根据模式安装
    if [[ "$DOCKER_MODE" == true ]]; then
        install_docker_mode
    else
        install_host_mode
    fi
    
    print_header "安装完成!"
    print_success "ZooKeeper 已成功安装"
    print_info "部署模式: $DEPLOY_MODE"
    print_info "节点数量: $NODES"
    print_info "安装目录: $INSTALL_DIR"
    print_info "数据目录: $DATA_DIR"
    
    if [[ "$DOCKER_MODE" == true ]]; then
        print_info "管理命令:"
        print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
        print_info "  停止: cd $INSTALL_DIR && docker compose down"
        print_info "  日志: cd $INSTALL_DIR && docker compose logs -f"
    else
        print_info "管理命令:"
        print_info "  启动: cd $INSTALL_DIR && ./start-host.sh"
        print_info "  停止: cd $INSTALL_DIR && ./stop-host.sh"
        if [[ "$ENABLE_SERVICE" == true ]]; then
            print_info "  系统服务: systemctl start/stop zookeeper"
        fi
    fi
    
    if [[ "$DEPLOY_MODE" == "standalone" ]]; then
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
    elif [[ "$DEPLOY_MODE" == "pseudo-cluster" ]]; then
        local nodes_list=""
        for ((i=1; i<=NODES; i++)); do
            nodes_list="${nodes_list}$((HOST_BASE_PORT + i - 1)),"
        done
        nodes_list="${nodes_list%,}"
        print_info "连接信息: zkCli.sh -server localhost:${nodes_list}"
    else
        print_info "连接信息: zkCli.sh -server localhost:$HOST_BASE_PORT"
        print_info "集群节点: $HOST_IP:$HOST_BASE_PORT"
    fi
}

# === 执行主函数 ===
main "$@"

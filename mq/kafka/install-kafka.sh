#!/bin/bash

# Kafka 一键安装配置脚本
# Apache Kafka 是高吞吐量的分布式消息队列系统

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
readonly KAFKA_VERSION="3.7.0"
readonly ZOOKEEPER_VERSION="3.9.2"
readonly KAFKA_IMAGE="apache/kafka"
readonly ZOOKEEPER_IMAGE="apache/zookeeper"
readonly DEFAULT_KAFKA_PORT=9092
readonly DEFAULT_ZOOKEEPER_PORT=2181
readonly DEFAULT_INSTALL_DIR="$HOME/kafka"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
readonly SERVICE_NAME="kafka"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
KAFKA_PORT="$DEFAULT_KAFKA_PORT"
ZOOKEEPER_PORT="$DEFAULT_ZOOKEEPER_PORT"
INSTALL_MODE="docker"  # docker 或 host
DRY_RUN=false
UNINSTALL_MODE=false
AUTO_START=false
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

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

# === 自动特权提升 ===
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要root权限，正在提权..."
        exec sudo "$0" "$@"
    fi
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Kafka 一键安装配置脚本

Apache Kafka 是高吞吐量的分布式消息队列系统，广泛用于日志处理、流式数据处理等场景。

用法：./install-kafka.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：~/kafka)
    -w, --download-dir DIR      下载目录 (默认：~/Downloads)
    -p, --port PORT             Kafka 端口号 (默认：9092)
    -z, --zookeeper-port PORT   ZooKeeper 端口号 (默认：2181)
    -m, --mode MODE             安装模式 (docker|host，默认：docker)
    --auto-start                安装完成后自动启动并配置自启动
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 Kafka

示例:
    ./install-kafka.sh                           # 使用默认设置安装（Docker 模式）
    ./install-kafka.sh --port 9093              # 指定 Kafka 端口
    ./install-kafka.sh --mode host              # 主机模式安装
    ./install-kafka.sh --auto-start             # 安装并配置自启动
    ./install-kafka.sh --uninstall              # 卸载 Kafka

使用指南:
    1. 启动 Kafka: cd $INSTALL_DIR && ./bin/startup.sh
    2. 查看状态：./bin/status.sh
    3. 查看日志：tail -f logs/server.log
    4. 停止服务：./bin/stop.sh

更多信息：https://kafka.apache.org/
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
            -w|--download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            -p|--port)
                KAFKA_PORT="$2"
                shift 2
                ;;
            -z|--zookeeper-port)
                ZOOKEEPER_PORT="$2"
                shift 2
                ;;
            -m|--mode)
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

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"
    
    # 检查 Docker（Docker 模式）
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        if ! command -v docker &> /dev/null; then
            print_warning "Docker 未安装，自动切换到主机模式安装"
            INSTALL_MODE="host"
        elif ! docker info &> /dev/null; then
            print_warning "Docker 服务未运行，自动切换到主机模式安装"
            INSTALL_MODE="host"
        elif ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            print_warning "Docker Compose 未安装，自动切换到主机模式安装"
            INSTALL_MODE="host"
        else
            print_success "Docker 环境检查通过"
        fi
    fi
    
    # 检查 Java（主机模式）
    if [[ "$INSTALL_MODE" == "host" ]]; then
        if ! command -v java &> /dev/null; then
            print_error "Java 未安装，请先安装 JDK 8+"
            exit 1
        fi
        print_success "Java 环境检查通过：$(java -version 2>&1 | head -1)"
    fi
    
    # 检查端口占用
    if command -v lsof &> /dev/null; then
        if lsof -i :"$KAFKA_PORT" &> /dev/null; then
            print_warning "端口 $KAFKA_PORT 已被占用"
        fi
        if lsof -i :"$ZOOKEEPER_PORT" &> /dev/null; then
            print_warning "端口 $ZOOKEEPER_PORT 已被占用"
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
    
    mkdir -p "$INSTALL_DIR"/{data/kafka,data/zookeeper,logs,bin,conf}
    print_success "目录创建完成：$INSTALL_DIR"
}

# === 下载文件通用函数 ===
download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local output_file

    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"

    # 确保下载目录存在且可写
    if [ -d "$output_dir" ]; then
        if [ ! -w "$output_dir" ]; then
            print_warning "下载目录无写入权限，尝试修复: $output_dir"
            if command -v sudo >/dev/null 2>&1; then
                sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
            fi
        fi
    else
        mkdir -p "$output_dir" || {
            print_error "无法创建下载目录: $output_dir"
            return 1
        }
    fi

    # 如果目标文件存在但不可写，删除它
    if [ -f "$output" ] && [ ! -w "$output" ]; then
        print_warning "目标文件存在但无写入权限，尝试删除: $output"
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl >/dev/null 2>&1; then
        print_info "使用 adl 下载: $url"
        if adl "$url" "$output_dir" "$output_file"; then
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

verify_archive() {
    local archive="$1"
    [ -s "$archive" ] && tar -tzf "$archive" >/dev/null 2>&1
}

# === 主机模式安装 Kafka ===
install_host_kafka() {
    print_header "使用主机系统安装模式..."

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将下载到 $DOWNLOAD_DIR 并安装到 $INSTALL_DIR"
        return 0
    fi

    local scala_version="2.13"
    local kafka_tgz="kafka_${scala_version}-${KAFKA_VERSION}.tgz"
    local archive_path="$DOWNLOAD_DIR/$kafka_tgz"

    mkdir -p "$DOWNLOAD_DIR"

    # 检查是否已存在有效安装包
    if [ -f "$archive_path" ] && verify_archive "$archive_path"; then
        print_info "检测到已存在安装包并验证通过: $archive_path"
    else
        # 下载源列表：主源 downloads.apache.org 仅保留最新版本，旧版本需从 archive 获取
        local -a kafka_urls=(
            "https://downloads.apache.org/kafka/${KAFKA_VERSION}/${kafka_tgz}"
            "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${kafka_tgz}"
        )

        local downloaded=false
        for kafka_url in "${kafka_urls[@]}"; do
            print_info "下载 Kafka: $kafka_url"
            if download_file "$kafka_url" "$archive_path" && verify_archive "$archive_path"; then
                downloaded=true
                break
            fi
            print_warning "源下载失败，尝试下一个: $kafka_url"
            rm -f "$archive_path" 2>/dev/null || true
        done

        if [[ "$downloaded" != "true" ]]; then
            print_error "Kafka 下载失败（所有源均不可用）"
            return 1
        fi
    fi

    # 解压到临时目录
    local temp_dir
    temp_dir="$(mktemp -d)"
    print_info "解压 Kafka 到临时目录..."
    tar -xzf "$archive_path" -C "$temp_dir"

    local extracted_dir
    extracted_dir="$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)"
    if [ -z "$extracted_dir" ]; then
        rm -rf "$temp_dir"
        print_error "解压后未找到 Kafka 目录"
        return 1
    fi

    # 安装到目标目录
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR"/*
    cp -R "$extracted_dir"/* "$INSTALL_DIR/"
    rm -rf "$temp_dir"

    # 创建配置
    mkdir -p "$INSTALL_DIR/logs"
    local server_props="$INSTALL_DIR/config/server.properties"

    # 修改配置（使用 | 作为 sed 分隔符，避免路径中的 / 冲突）
    if [ -f "$server_props" ]; then
        sed -i.bak "s|^#\?listeners=.*|listeners=PLAINTEXT://localhost:${KAFKA_PORT}|" "$server_props"
        sed -i.bak "s|^#\?log.dirs=.*|log.dirs=${INSTALL_DIR}/logs|" "$server_props"
        sed -i.bak "s|^#\?zookeeper.connect=.*|zookeeper.connect=localhost:${ZOOKEEPER_PORT}|" "$server_props"
        rm -f "$server_props.bak"
        print_info "Kafka 配置已更新"
    fi

    # 创建主机启动脚本
    cat > "$INSTALL_DIR/bin/startup.sh" << EOF
#!/bin/bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
INSTALL_DIR="\$(dirname "\$SCRIPT_DIR")"

# 先启动 ZooKeeper
if ! pgrep -f "zookeeper" > /dev/null 2>&1; then
    echo "启动 ZooKeeper..."
    nohup "\$INSTALL_DIR/bin/zookeeper-server-start.sh" "\$INSTALL_DIR/config/zookeeper.properties" > "\$INSTALL_DIR/logs/zookeeper.log" 2>&1 &
    sleep 3
fi

# 启动 Kafka
if pgrep -f "kafka-server-start" > /dev/null 2>&1; then
    echo "Kafka 已在运行"
    exit 0
fi

echo "启动 Kafka..."
nohup "\$INSTALL_DIR/bin/kafka-server-start.sh" "\$INSTALL_DIR/config/server.properties" > "\$INSTALL_DIR/logs/server.log" 2>&1 &
echo "Kafka 已启动，端口: ${KAFKA_PORT}"
echo "日志: \$INSTALL_DIR/logs/server.log"
EOF
    chmod +x "$INSTALL_DIR/bin/startup.sh"

    # 创建主机停止脚本
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

echo "停止 Kafka..."
"$INSTALL_DIR/bin/kafka-server-stop.sh" 2>/dev/null || true
sleep 2

echo "停止 ZooKeeper..."
"$INSTALL_DIR/bin/zookeeper-server-stop.sh" 2>/dev/null || true
sleep 1

pids="$(pgrep -f "kafka-server-start" || true)"
if [ -n "$pids" ]; then
    kill -9 $pids 2>/dev/null || true
fi

echo "Kafka 已停止"
EOF
    chmod +x "$INSTALL_DIR/bin/stop.sh"

    # 创建状态检查脚本
    cat > "$INSTALL_DIR/bin/status.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Kafka 服务状态 ==="
if pgrep -f "kafka-server-start" > /dev/null 2>&1; then
    echo "Kafka: 运行中"
else
    echo "Kafka: 未运行"
fi

if pgrep -f "zookeeper" > /dev/null 2>&1; then
    echo "ZooKeeper: 运行中"
else
    echo "ZooKeeper: 未运行"
fi

echo ""
echo "=== 端口监听 ==="
if command -v lsof >/dev/null 2>&1; then
    lsof -i :9092 -sTCP:LISTEN 2>/dev/null || echo "端口 9092: 未监听"
    lsof -i :2181 -sTCP:LISTEN 2>/dev/null || echo "端口 2181: 未监听"
fi

echo ""
echo "=== 最近日志 ==="
tail -n 5 "$INSTALL_DIR/logs/server.log" 2>/dev/null || echo "暂无日志"
EOF
    chmod +x "$INSTALL_DIR/bin/status.sh"

    print_success "Kafka 主机模式安装完成"
}

# === 创建 Docker Compose 文件 ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  zookeeper:
    image: ${ZOOKEEPER_IMAGE}:${ZOOKEEPER_VERSION}
    container_name: zookeeper
    hostname: zookeeper
    ports:
      - "${ZOOKEEPER_PORT}:2181"
    environment:
      ZOOKEEPER_CLIENT_PORT: "2181"
      ZOOKEEPER_TICK_TIME: "2000"
      ZOOKEEPER_INIT_LIMIT: "5"
      ZOOKEEPER_SYNC_LIMIT: "2"
    volumes:
      - ./data/zookeeper:/var/lib/zookeeper/data
      - ./logs/zookeeper:/var/lib/zookeeper/log
    networks:
      - kafka-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "2181"]
      interval: 10s
      timeout: 5s
      retries: 5

  kafka:
    image: ${KAFKA_IMAGE}:${KAFKA_VERSION}
    container_name: kafka
    hostname: kafka
    depends_on:
      zookeeper:
        condition: service_healthy
    ports:
      - "${KAFKA_PORT}:9092"
    environment:
      KAFKA_BROKER_ID: "1"
      KAFKA_ZOOKEEPER_CONNECT: "zookeeper:2181"
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: "PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT"
      KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:29092,PLAINTEXT_HOST://localhost:${KAFKA_PORT}"
      KAFKA_LISTENERS: "PLAINTEXT://0.0.0.0:29092,PLAINTEXT_HOST://0.0.0.0:9092"
      KAFKA_INTER_BROKER_LISTENER_NAME: "PLAINTEXT"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: "1"
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: "1"
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: "1"
      KAFKA_LOG_RETENTION_HOURS: "168"
      KAFKA_LOG_SEGMENT_BYTES: "1073741824"
      KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS: "300000"
      KAFKA_NUM_NETWORK_THREADS: "3"
      KAFKA_NUM_IO_THREADS: "8"
      KAFKA_NUM_PARTITIONS: "1"
      KAFKA_SOCKET_SEND_BUFFER_BYTES: "102400"
      KAFKA_SOCKET_RECEIVE_BUFFER_BYTES: "102400"
      KAFKA_SOCKET_REQUEST_MAX_BYTES: "104857600"
    volumes:
      - ./data/kafka:/var/lib/kafka/data
      - ./logs/kafka:/var/log/kafka
    networks:
      - kafka-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "9092"]
      interval: 30s
      timeout: 10s
      retries: 5

networks:
  kafka-network:
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

# Kafka 启动脚本

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
    echo "错误：docker-compose.yml 不存在，请先运行安装脚本"
    exit 1
fi

echo "正在启动 Kafka..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "等待服务启动..."
sleep 5

# 检查服务状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "Kafka 启动完成！"
echo "访问地址：localhost:<KAFKA_PORT>"
echo "查看日志：docker-compose logs -f"
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

# Kafka 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 Kafka..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "Kafka 已停止"
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

# Kafka 状态检查脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

cd "$INSTALL_DIR"

echo "=== Kafka 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== 资源使用 ==="
if command -v docker compose &> /dev/null; then
    docker compose top 2>/dev/null || echo "top 信息不可用"
else
    docker-compose top 2>/dev/null || echo "top 信息不可用"
fi

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20
else
    docker-compose logs --tail=20
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
    
    # 检测系统类型
    if [[ ! -d /etc/systemd/system ]]; then
        configure_systemd
    else
        print_warning "不支持的初始化系统，跳过自启动配置"
        print_info "请手动执行：cd $INSTALL_DIR && docker-compose up -d"
        return
    fi
}

# === 配置 systemd 服务 ===
configure_systemd() {
    print_info "配置 systemd 服务"
    
    local SERVICE_FILE="/etc/systemd/system/kafka.service"
    
    # 检查是否已存在
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "Kafka systemd 服务已存在"
        return
    fi
    
    # 创建 systemd 服务文件
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Apache Kafka Message Broker
Documentation=https://kafka.apache.org/
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
ExecReload=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml restart
TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd 配置
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用自启动：sudo systemctl enable kafka"
        print_info "启动服务：sudo systemctl start kafka"
        print_info "查看状态：sudo systemctl status kafka"
    else
        print_warning "systemctl 不可用，请手动配置"
    fi
}

# === 启动服务 ===
start_service() {
    print_header "启动 Kafka 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 Kafka 服务"
        return
    fi
    
    cd "$INSTALL_DIR"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动..."
    sleep 10
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    print_success "Kafka 服务已启动"
}

# === 卸载 Kafka ===
uninstall_kafka() {
    print_header "卸载 Kafka"
    
    print_warning "此操作将删除 Kafka 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    # 停止服务
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        print_info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        if command -v docker compose &> /dev/null; then
            docker compose down
        else
            docker-compose down
        fi
    fi
    
    # 删除 systemd 服务
    if command -v systemctl &> /dev/null && [[ -f /etc/systemd/system/kafka.service ]]; then
        print_info "删除 systemd 服务..."
        systemctl stop kafka 2>/dev/null || true
        systemctl disable kafka 2>/dev/null || true
        rm -f /etc/systemd/system/kafka.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    # 删除 Docker 卷（可选）
    print_info "清理未使用的 Docker 卷..."
    docker volume prune -f 2>/dev/null || true
    
    print_success "Kafka 卸载完成"
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"

    cat << EOF
${GREEN}Kafka 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}Kafka 端口:${NC} $KAFKA_PORT
${BOLD}ZooKeeper 端口:${NC} $ZOOKEEPER_PORT
${BOLD}安装模式:${NC} $INSTALL_MODE
EOF

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cat << EOF

${BOLD}常用命令:${NC}
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：cd $INSTALL_DIR && docker-compose logs -f

${BOLD}快速测试:${NC}
  # 创建主题
  docker exec -it kafka kafka-topics.sh --bootstrap-server localhost:$KAFKA_PORT --create --topic test-topic --partitions 1 --replication-factor 1

  # 生产消息
  docker exec -it kafka kafka-console-producer.sh --bootstrap-server localhost:$KAFKA_PORT --topic test-topic

  # 消费消息
  docker exec -it kafka kafka-console-consumer.sh --bootstrap-server localhost:$KAFKA_PORT --topic test-topic --from-beginning
EOF
    else
        cat << EOF

${BOLD}常用命令:${NC}
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：tail -f $INSTALL_DIR/logs/server.log

${BOLD}快速测试:${NC}
  # 创建主题
  $INSTALL_DIR/bin/kafka-topics.sh --bootstrap-server localhost:$KAFKA_PORT --create --topic test-topic --partitions 1 --replication-factor 1

  # 生产消息
  $INSTALL_DIR/bin/kafka-console-producer.sh --bootstrap-server localhost:$KAFKA_PORT --topic test-topic

  # 消费消息
  $INSTALL_DIR/bin/kafka-console-consumer.sh --bootstrap-server localhost:$KAFKA_PORT --topic test-topic --from-beginning
EOF
    fi

    cat << EOF

${BOLD}管理工具:${NC}
  推荐使用 Kafka UI 等图形化管理工具

${BOLD}自启动配置:${NC}
EOF

    if [[ "$AUTO_START" == "true" ]]; then
        echo -e "  ${GREEN}已配置自启动服务${NC}"
        echo "  启用：sudo systemctl enable kafka"
        echo "  启动：sudo systemctl start kafka"
    else
        echo "  未配置自启动，如需配置请运行：./install-kafka.sh --auto-start"
    fi

    echo ""
    echo -e "${CYAN}更多信息请访问：https://kafka.apache.org/${NC}"
}

# === 主函数 ===
main() {
    print_header "Apache Kafka 安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_kafka
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  Kafka 端口：$KAFKA_PORT"
    echo "  ZooKeeper 端口：$ZOOKEEPER_PORT"
    echo "  安装模式：$INSTALL_MODE"
    echo "  自动启动：$AUTO_START"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    create_directories
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        create_docker_compose
        create_startup_script
        create_stop_script
        create_status_script

        if [[ "$DRY_RUN" != "true" ]]; then
            print_info "是否立即启动 Kafka？(y/N)"
            read -r -p "> " start_now
            if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
                start_service

                if [[ "$AUTO_START" == "true" ]]; then
                    configure_autostart
                fi
            fi
        fi
    else
        install_host_kafka
    fi

    show_post_install_info
}

# 执行主函数
main "$@"

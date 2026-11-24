#!/bin/bash

# BanyanDB 一键安装配置脚本
# 支持主机和 docker-compose 两种安装方式
# 当 docker 已安装已启动的情况下优先 docker-compose，否则主机安装

set -euo pipefail

# 脚本版本
SCRIPT_VERSION="1.0.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认配置
DEFAULT_INSTALL_DIR="$HOME/banyandb"
DEFAULT_VERSION="latest"
DEFAULT_USER="banyandb"
DEFAULT_PORT="17912"
DEFAULT_GRPC_PORT="17913"
DEFAULT_HTTP_PORT="17914"

# 全局变量
INSTALL_DIR=""
VERSION=""
USER=""
PORT=""
GRPC_PORT=""
HTTP_PORT=""
USE_DOCKER=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# 显示帮助信息
show_help() {
    cat << EOF
BanyanDB 一键安装配置脚本 v${SCRIPT_VERSION}

用法: $0 [选项]

选项:
  -h, --help                显示此帮助信息
  -d, --install-dir=DIR     指定安装目录 (默认: ${DEFAULT_INSTALL_DIR})
  -v, --version=VERSION     指定版本 (默认: ${DEFAULT_VERSION})
  -u, --user=USER           指定运行用户 (默认: ${DEFAULT_USER})
  -p, --port=PORT           指定服务端口 (默认: ${DEFAULT_PORT})
  -g, --grpc-port=PORT      指定 gRPC 端口 (默认: ${DEFAULT_GRPC_PORT})
  -w, --http-port=PORT      指定 HTTP 端口 (默认: ${DEFAULT_HTTP_PORT})
  --docker                  强制使用 Docker 方式安装
  --host                    强制使用主机方式安装

示例:
  $0                        # 使用默认配置安装
  $0 --install-dir=/usr/local/banyandb  # 安装到指定目录
  $0 --version=v1.0.0       # 安装指定版本
  $0 --docker               # 强制使用 Docker 方式

注意:
  - 脚本会自动检测 Docker 环境，如果 Docker 已安装并启动，则优先使用 Docker Compose 方式
  - 如果未检测到 Docker 环境，则使用主机安装方式
  - 主机安装需要 root 权限或 sudo 权限

EOF
}

# 日志函数
log_info() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查 Docker 环境
check_docker() {
    if command_exists docker && docker info >/dev/null 2>&1; then
        log_info "检测到 Docker 环境"
        return 0
    else
        log_warn "未检测到 Docker 环境"
        return 1
    fi
}

# 检查 Docker Compose
check_docker_compose() {
    if command_exists docker-compose || docker compose version >/dev/null 2>&1; then
        log_info "检测到 Docker Compose 环境"
        return 0
    else
        log_warn "未检测到 Docker Compose 环境"
        return 1
    fi
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --install-dir=*)
                INSTALL_DIR="${1#*=}"
                shift
                ;;
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            --version=*)
                VERSION="${1#*=}"
                shift
                ;;
            -u|--user)
                USER="$2"
                shift 2
                ;;
            --user=*)
                USER="${1#*=}"
                shift
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            --port=*)
                PORT="${1#*=}"
                shift
                ;;
            -g|--grpc-port)
                GRPC_PORT="$2"
                shift 2
                ;;
            --grpc-port=*)
                GRPC_PORT="${1#*=}"
                shift
                ;;
            -w|--http-port)
                HTTP_PORT="$2"
                shift 2
                ;;
            --http-port=*)
                HTTP_PORT="${1#*=}"
                shift
                ;;
            --docker)
                USE_DOCKER=true
                shift
                ;;
            --host)
                USE_DOCKER=false
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 设置默认值
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    VERSION="${VERSION:-$DEFAULT_VERSION}"
    USER="${USER:-$DEFAULT_USER}"
    PORT="${PORT:-$DEFAULT_PORT}"
    GRPC_PORT="${GRPC_PORT:-$DEFAULT_GRPC_PORT}"
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"

    # 如果没有明确指定安装方式，则自动检测
    if [[ "${USE_DOCKER}" == "auto" ]]; then
        if check_docker && check_docker_compose; then
            USE_DOCKER=true
            log_info "自动选择 Docker Compose 安装方式"
        elif [[ "$(uname -s)" == "Darwin" ]]; then
            log_error "macOS 上未检测到 Docker，请先安装 Docker Desktop"
            log_info "下载地址: https://www.docker.com/products/docker-desktop/"
            log_info "安装完成后重新运行此脚本"
            exit 1
        else
            USE_DOCKER=false
            log_info "自动选择主机安装方式"
        fi
    fi

    log_info "安装配置:"
    log_info "  安装目录: $INSTALL_DIR"
    log_info "  版本: $VERSION"
    log_info "  运行用户: $USER"
    log_info "  服务端口: $PORT"
    log_info "  gRPC 端口: $GRPC_PORT"
    log_info "  HTTP 端口: $HTTP_PORT"
    log_info "  安装方式: $([ "$USE_DOCKER" = true ] && echo "Docker Compose" || echo "主机")"
}

# 检查系统依赖
check_dependencies() {
    log_info "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查基础工具
    for cmd in wget curl tar; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ "${#missing_deps[@]}" -gt 0 ]]; then
        log_error "缺少依赖: ${missing_deps[*]}"
        log_info "请安装缺少的依赖后重试"
        
        # 尝试自动安装依赖
        if command_exists apt-get; then
            log_info "尝试使用 apt-get 安装依赖..."
            sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}"
        elif command_exists yum; then
            log_info "尝试使用 yum 安装依赖..."
            sudo yum install -y "${missing_deps[@]}"
        elif command_exists dnf; then
            log_info "尝试使用 dnf 安装依赖..."
            sudo dnf install -y "${missing_deps[@]}"
        else
            log_error "无法自动安装依赖，请手动安装: ${missing_deps[*]}"
            exit 1
        fi
    fi
    
    log_info "系统依赖检查完成"
}

# 创建用户
create_user() {
    if ! id -u "$USER" >/dev/null 2>&1; then
        log_info "创建用户: $USER"
        sudo useradd -r -s /bin/false -d "$INSTALL_DIR" "$USER" || {
            log_error "创建用户失败: $USER"
            exit 1
        }
    else
        log_info "用户已存在: $USER"
    fi
}

# 创建目录
create_directories() {
    log_info "创建目录结构..."
    
    local dirs=(
        "$INSTALL_DIR"
        "$INSTALL_DIR/bin"
        "$INSTALL_DIR/conf"
        "$INSTALL_DIR/data"
        "$INSTALL_DIR/logs"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "创建目录: $dir"
            sudo mkdir -p "$dir" || {
                log_error "创建目录失败: $dir"
                exit 1
            }
        fi
    done
    
    # 设置权限
    sudo chown -R "$USER:$USER" "$INSTALL_DIR" || {
        log_error "设置目录权限失败"
        exit 1
    }
    
    log_info "目录结构创建完成"
}

# 下载 BanyanDB
download_banyandb() {
    log_info "下载 BanyanDB..."
    
    local download_dir="/tmp"
    local archive_name="banyandb-${VERSION}-linux-amd64.tar.gz"
    local download_url="https://github.com/banyandb/banyandb/releases/download/${VERSION}/${archive_name}"
    local archive_path="${download_dir}/${archive_name}"
    
    # 如果文件已存在且大小合理，则跳过下载
    if [[ -f "$archive_path" ]] && [[ $(stat -c%s "$archive_path" 2>/dev/null || echo 0) -gt 1000000 ]]; then
        log_info "使用已下载的文件: $archive_path"
    else
        log_info "从 $download_url 下载..."
        if ! wget -O "$archive_path" "$download_url"; then
            log_error "下载失败，请检查网络连接或版本号"
            exit 1
        fi
    fi
    
    # 解压
    log_info "解压到 $INSTALL_DIR..."
    if ! tar -xzf "$archive_path" -C "$INSTALL_DIR" --strip-components=1; then
        log_error "解压失败"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x "$INSTALL_DIR/bin"/* || {
        log_error "设置执行权限失败"
        exit 1
    }
    
    log_info "BanyanDB 下载完成"
}

# 创建配置文件
create_config() {
    log_info "创建配置文件..."
    
    local config_file="$INSTALL_DIR/conf/banyandb.toml"
    
    # 如果配置文件已存在，则备份
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"
        log_info "已备份原配置文件"
    fi
    
    # 创建新的配置文件
    cat > "$config_file" << EOF
# BanyanDB 配置文件
# 自动生成于 $(date)

[server]
# 服务端口
port = $PORT

# gRPC 端口
grpc-port = $GRPC_PORT

# HTTP 端口
http-port = $HTTP_PORT

# 数据目录
data-dir = "$INSTALL_DIR/data"

# 日志目录
log-dir = "$INSTALL_DIR/logs"

# 日志级别 (debug, info, warn, error)
log-level = "info"

# 运行用户
user = "$USER"

[storage]
# 存储引擎配置
engine = "rocksdb"

# 最大内存使用
max-memory = "2GB"

# 写缓冲区大小
write-buffer-size = "64MB"

# 最大写缓冲区数量
max-write-buffer-number = 3

[replication]
# 副本数量
replica-factor = 1

# 同步超时时间
sync-timeout = "30s"

[monitoring]
# 启用监控
enabled = true

# Prometheus 指标端口
metrics-port = $((HTTP_PORT + 1))

[security]
# 启用认证
auth-enabled = false

# TLS 证书路径 (如果启用 TLS)
# cert-file = ""
# key-file = ""
# ca-file = ""
EOF

    # 设置权限
    chown "$USER:$USER" "$config_file" || {
        log_error "设置配置文件权限失败"
        exit 1
    }
    
    log_info "配置文件创建完成: $config_file"
}

# 创建系统服务
create_service() {
    log_info "创建系统服务..."
    
    local service_file="/etc/systemd/system/banyandb.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=BanyanDB Server
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$INSTALL_DIR/bin/banyandb --config=$INSTALL_DIR/conf/banyandb.toml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=banyandb

# 资源限制
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd
    sudo systemctl daemon-reload || {
        log_error "重新加载 systemd 失败"
        exit 1
    }
    
    # 启用服务
    sudo systemctl enable banyandb || {
        log_error "启用服务失败"
        exit 1
    }
    
    log_info "系统服务创建完成"
}

# 主机安装方式
install_host() {
    log_info "开始主机安装方式..."
    
    # 检查权限
    if [[ $EUID -ne 0 ]]; then
        log_info "需要 root 权限进行主机安装，使用 sudo..."
        if ! sudo -n true 2>/dev/null; then
            log_info "请输入 sudo 密码..."
        fi
    fi
    
    check_dependencies
    create_user
    create_directories
    download_banyandb
    create_config
    create_service
    
    # 启动服务
    log_info "启动 BanyanDB 服务..."
    sudo systemctl start banyandb || {
        log_error "启动服务失败"
        exit 1
    }
    
    # 检查服务状态
    if sudo systemctl is-active --quiet banyandb; then
        log_info "BanyanDB 服务启动成功"
        sudo systemctl status banyandb --no-pager
    else
        log_error "BanyanDB 服务启动失败"
        sudo journalctl -u banyandb -n 20 --no-pager
        exit 1
    fi
    
    log_info "主机安装完成"
}

# 创建 Docker Compose 配置
create_docker_compose() {
    log_info "创建 Docker Compose 配置..."
    
    local compose_file="$BASE_DIR/docker-compose.yml"
    
    cat > "$compose_file" << EOF
version: '3.8'

services:
  banyandb:
    image: banyandb/banyandb:${VERSION}
    container_name: banyandb
    restart: unless-stopped
    ports:
      - "${PORT}:${PORT}"
      - "${GRPC_PORT}:${GRPC_PORT}"
      - "${HTTP_PORT}:${HTTP_PORT}"
      - "$((HTTP_PORT + 1)):$((HTTP_PORT + 1))"
    volumes:
      - ./data:/data
      - ./logs:/logs
      - ./conf:/etc/banyandb
    environment:
      - BANYANDB_DATA_DIR=/data
      - BANYANDB_LOG_DIR=/logs
      - BANYANDB_CONFIG_FILE=/etc/banyandb/banyandb.toml
    command: ["--config=/etc/banyandb/banyandb.toml"]
    networks:
      - banyandb-network

networks:
  banyandb-network:
    driver: bridge
EOF

    log_info "Docker Compose 配置创建完成: $compose_file"
}

# Docker Compose 安装方式
install_docker() {
    log_info "开始 Docker Compose 安装方式..."
    
    # 创建目录
    mkdir -p "$BASE_DIR"/{data,logs,conf}
    
    # 创建配置文件
    create_config
    
    # 创建 Docker Compose 配置
    create_docker_compose
    
    # 启动服务
    log_info "启动 BanyanDB Docker 容器..."
    
    cd "$BASE_DIR"
    if command_exists docker-compose; then
        docker-compose up -d || {
            log_error "Docker Compose 启动失败"
            exit 1
        }
    else
        docker compose up -d || {
            log_error "Docker Compose 启动失败"
            exit 1
        }
    fi
    
    # 检查容器状态
    sleep 5
    if docker ps | grep -q banyandb; then
        log_info "BanyanDB Docker 容器启动成功"
        docker ps | grep banyandb
    else
        log_error "BanyanDB Docker 容器启动失败"
        docker logs banyandb
        exit 1
    fi
    
    log_info "Docker Compose 安装完成"
}

# 显示安装后信息
show_post_install_info() {
    log_info "==================== 安装完成 ===================="
    log_info "BanyanDB 已成功安装并启动"
    log_info ""
    log_info "服务信息:"
    log_info "  服务端口: $PORT"
    log_info "  gRPC 端口: $GRPC_PORT"
    log_info "  HTTP 端口: $HTTP_PORT"
    log_info "  监控端口: $((HTTP_PORT + 1))"
    log_info ""
    log_info "管理命令:"
    if [[ "$USE_DOCKER" == true ]]; then
        log_info "  查看状态: cd $BASE_DIR && docker-compose ps"
        log_info "  查看日志: cd $BASE_DIR && docker-compose logs -f"
        log_info "  停止服务: cd $BASE_DIR && docker-compose down"
        log_info "  重启服务: cd $BASE_DIR && docker-compose restart"
    else
        log_info "  查看状态: sudo systemctl status banyandb"
        log_info "  查看日志: sudo journalctl -u banyandb -f"
        log_info "  停止服务: sudo systemctl stop banyandb"
        log_info "  重启服务: sudo systemctl restart banyandb"
    fi
    log_info ""
    log_info "配置文件: $INSTALL_DIR/conf/banyandb.toml"
    log_info "数据目录: $INSTALL_DIR/data"
    log_info "日志目录: $INSTALL_DIR/logs"
    log_info ""
    log_info "更多使用方法请参考官方文档: https://github.com/banyandb/banyandb"
    log_info "=================================================="
}

# 主函数
main() {
    log_info "BanyanDB 一键安装脚本 v${SCRIPT_VERSION}"
    log_info "======================================"
    
    # 设置默认安装方式为自动检测
    USE_DOCKER="auto"
    
    # 解析参数
    parse_arguments "$@"
    
    # 执行安装
    if [[ "$USE_DOCKER" == true ]]; then
        install_docker
    else
        install_host
    fi
    
    # 显示安装后信息
    show_post_install_info
}

# 执行主函数
main "$@"
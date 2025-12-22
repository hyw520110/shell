#!/bin/bash

# BanyanDB 启动脚本
# 支持主机和 Docker 两种方式

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# 默认配置
DEFAULT_CONFIG_FILE="$BASE_DIR/conf/banyandb.toml"
DEFAULT_INSTALL_DIR="/opt/banyandb"

# 全局变量
CONFIG_FILE=""
INSTALL_DIR=""
USE_DOCKER=false

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
        return 0
    else
        return 1
    fi
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --config=*)
                CONFIG_FILE="${1#*=}"
                shift
                ;;
            -d|--install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --install-dir=*)
                INSTALL_DIR="${1#*=}"
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
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 设置默认值
    CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

    # 如果没有明确指定启动方式，则自动检测
    if [[ -z "${USE_DOCKER:-}" ]]; then
        if check_docker && [[ -f "$BASE_DIR/docker-compose.yml" ]]; then
            USE_DOCKER=true
        else
            USE_DOCKER=false
        fi
    fi

    log_debug "配置文件: $CONFIG_FILE"
    log_debug "安装目录: $INSTALL_DIR"
    log_debug "使用 Docker: $USE_DOCKER"
}

# 显示帮助信息
show_help() {
    cat << EOF
BanyanDB 启动脚本

用法: $0 [选项]

选项:
  -c, --config=FILE       指定配置文件 (默认: $DEFAULT_CONFIG_FILE)
  -d, --install-dir=DIR   指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
  --docker                使用 Docker 方式启动
  --host                  使用主机方式启动
  -h, --help              显示此帮助信息

示例:
  $0                      # 使用默认配置启动
  $0 --config=/path/to/config.toml  # 使用指定配置文件
  $0 --docker             # 强制使用 Docker 方式

EOF
}

# 检查配置文件
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
    
    log_info "使用配置文件: $CONFIG_FILE"
}

# 检查进程是否已运行
is_running() {
    if [[ "$USE_DOCKER" == true ]]; then
        # 检查 Docker 容器
        if docker ps | grep -q banyandb; then
            return 0
        else
            return 1
        fi
    else
        # 检查主进程
        if pgrep -f "banyandb.*--config" >/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

# Docker 方式启动
start_docker() {
    log_info "使用 Docker 方式启动 BanyanDB..."
    
    cd "$BASE_DIR"
    
    # 检查 docker-compose.yml 文件
    if [[ ! -f "docker-compose.yml" ]]; then
        log_error "Docker Compose 配置文件不存在: $BASE_DIR/docker-compose.yml"
        exit 1
    fi
    
    # 启动容器
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
    
    # 等待启动
    log_info "等待 BanyanDB 启动..."
    sleep 5
    
    # 检查状态
    if docker ps | grep -q banyandb; then
        log_info "BanyanDB Docker 容器启动成功"
        docker ps | grep banyandb
    else
        log_error "BanyanDB Docker 容器启动失败"
        docker logs banyandb
        exit 1
    fi
}

# 主机方式启动
start_host() {
    log_info "使用主机方式启动 BanyanDB..."
    
    # 检查二进制文件
    local binary="$INSTALL_DIR/bin/banyandb"
    if [[ ! -x "$binary" ]]; then
        log_error "BanyanDB 二进制文件不存在或不可执行: $binary"
        exit 1
    fi
    
    # 检查权限
    if [[ $EUID -ne 0 ]]; then
        log_info "使用 sudo 启动 BanyanDB 服务..."
        sudo systemctl start banyandb || {
            log_error "启动服务失败"
            exit 1
        }
    else
        # 直接启动
        "$binary" --config="$CONFIG_FILE" &
        local pid=$!
        echo $pid > "$INSTALL_DIR/banyandb.pid"
        log_info "BanyanDB 进程 ID: $pid"
    fi
    
    # 等待启动
    log_info "等待 BanyanDB 启动..."
    sleep 5
    
    # 检查状态
    if [[ $EUID -ne 0 ]]; then
        if sudo systemctl is-active --quiet banyandb; then
            log_info "BanyanDB 服务启动成功"
            sudo systemctl status banyandb --no-pager
        else
            log_error "BanyanDB 服务启动失败"
            sudo journalctl -u banyandb -n 20 --no-pager
            exit 1
        fi
    else
        if pgrep -f "banyandb.*--config" >/dev/null; then
            log_info "BanyanDB 进程启动成功"
            ps -ef | grep banyandb | grep -v grep
        else
            log_error "BanyanDB 进程启动失败"
            exit 1
        fi
    fi
}

# 显示服务信息
show_service_info() {
    log_info "==================== 服务信息 ===================="
    
    if [[ "$USE_DOCKER" == true ]]; then
        log_info "Docker 容器信息:"
        docker ps | grep banyandb || log_warn "未找到运行中的容器"
        
        log_info "容器日志:"
        log_info "  查看日志: cd $BASE_DIR && docker-compose logs -f"
        log_info "  实时日志: docker logs -f banyandb"
    else
        log_info "系统服务信息:"
        if [[ $EUID -ne 0 ]]; then
            sudo systemctl status banyandb --no-pager || log_warn "获取服务状态失败"
        else
            systemctl status banyandb --no-pager || log_warn "获取服务状态失败"
        fi
        
        log_info "服务日志:"
        log_info "  查看日志: sudo journalctl -u banyandb -f"
        log_info "  日志目录: $INSTALL_DIR/logs"
    fi
    
    log_info "配置文件: $CONFIG_FILE"
    log_info "=================================================="
}

# 主函数
main() {
    log_info "BanyanDB 启动脚本"
    log_info "=================="
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否已运行
    if is_running; then
        log_info "BanyanDB 已在运行"
        show_service_info
        exit 0
    fi
    
    # 检查配置文件
    check_config
    
    # 启动服务
    if [[ "$USE_DOCKER" == true ]]; then
        start_docker
    else
        start_host
    fi
    
    # 显示服务信息
    show_service_info
}

# 执行主函数
main "$@"
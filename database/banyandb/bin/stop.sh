#!/bin/bash

# BanyanDB 停止脚本
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
DEFAULT_INSTALL_DIR="/opt/banyandb"

# 全局变量
INSTALL_DIR=""
USE_DOCKER=false
FORCE=false

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
            -f|--force)
                FORCE=true
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
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

    # 如果没有明确指定停止方式，则自动检测
    if [[ -z "${USE_DOCKER:-}" ]]; then
        if check_docker && [[ -f "$BASE_DIR/docker-compose.yml" ]]; then
            USE_DOCKER=true
        else
            USE_DOCKER=false
        fi
    fi

    log_debug "安装目录: $INSTALL_DIR"
    log_debug "使用 Docker: $USE_DOCKER"
    log_debug "强制停止: $FORCE"
}

# 显示帮助信息
show_help() {
    cat << EOF
BanyanDB 停止脚本

用法: $0 [选项]

选项:
  -d, --install-dir=DIR   指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
  --docker                使用 Docker 方式停止
  --host                  使用主机方式停止
  -f, --force             强制停止
  -h, --help              显示此帮助信息

示例:
  $0                      # 使用默认配置停止
  $0 --docker             # 强制使用 Docker 方式
  $0 --force              # 强制停止

EOF
}

# 检查进程是否运行
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

# 等待进程停止
wait_for_stop() {
    local max_wait=30
    local count=0
    
    log_info "等待服务停止..."
    
    while [[ $count -lt $max_wait ]]; do
        if ! is_running; then
            log_info "服务已停止"
            return 0
        fi
        
        sleep 1
        count=$((count + 1))
        echo -n "."
    done
    
    echo
    
    if [[ "$FORCE" == true ]]; then
        log_warn "等待超时，强制停止服务"
        return 1
    else
        log_error "等待超时，服务未能正常停止，请使用 --force 强制停止"
        return 2
    fi
}

# Docker 方式停止
stop_docker() {
    log_info "使用 Docker 方式停止 BanyanDB..."
    
    cd "$BASE_DIR"
    
    # 检查 docker-compose.yml 文件
    if [[ ! -f "docker-compose.yml" ]]; then
        log_error "Docker Compose 配置文件不存在: $BASE_DIR/docker-compose.yml"
        exit 1
    fi
    
    # 停止容器
    if command_exists docker-compose; then
        docker-compose down || {
            if [[ "$FORCE" == true ]]; then
                log_warn "Docker Compose 停止失败，尝试强制停止容器"
                docker stop banyandb || docker kill banyandb || true
                docker rm banyandb || true
            else
                log_error "Docker Compose 停止失败"
                exit 1
            fi
        }
    else
        docker compose down || {
            if [[ "$FORCE" == true ]]; then
                log_warn "Docker Compose 停止失败，尝试强制停止容器"
                docker stop banyandb || docker kill banyandb || true
                docker rm banyandb || true
            else
                log_error "Docker Compose 停止失败"
                exit 1
            fi
        }
    fi
    
    # 等待停止
    if ! wait_for_stop; then
        if [[ "$FORCE" == true ]]; then
            log_warn "强制停止 Docker 容器"
            docker stop banyandb || docker kill banyandb || true
            sleep 2
        else
            exit 1
        fi
    fi
    
    log_info "BanyanDB Docker 容器已停止"
}

# 主机方式停止
stop_host() {
    log_info "使用主机方式停止 BanyanDB..."
    
    # 检查是否以 root 运行
    if [[ $EUID -ne 0 ]]; then
        log_info "使用 sudo 停止 BanyanDB 服务..."
        sudo systemctl stop banyandb || {
            if [[ "$FORCE" == true ]]; then
                log_warn "systemctl 停止失败，尝试强制停止进程"
                sudo pkill -f "banyandb.*--config" || true
                sleep 2
            else
                log_error "停止服务失败"
                exit 1
            fi
        }
        
        # 等待停止
        if ! wait_for_stop; then
            if [[ "$FORCE" == true ]]; then
                log_warn "强制停止 BanyanDB 进程"
                sudo pkill -9 -f "banyandb.*--config" || true
                sleep 2
            else
                exit 1
            fi
        fi
    else
        # 直接停止
        local pid_file="$INSTALL_DIR/banyandb.pid"
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" || {
                    if [[ "$FORCE" == true ]]; then
                        kill -9 "$pid" || true
                    else
                        log_error "停止进程失败"
                        exit 1
                    fi
                }
            fi
            rm -f "$pid_file"
        else
            # 通过进程名停止
            local pids=$(pgrep -f "banyandb.*--config")
            if [[ -n "$pids" ]]; then
                for pid in $pids; do
                    kill "$pid" || {
                        if [[ "$FORCE" == true ]]; then
                            kill -9 "$pid" || true
                        else
                            log_error "停止进程失败: $pid"
                            exit 1
                        fi
                    }
                done
            fi
        fi
        
        # 等待停止
        if ! wait_for_stop; then
            if [[ "$FORCE" == true ]]; then
                log_warn "强制停止所有 BanyanDB 进程"
                pkill -9 -f "banyandb" || true
                sleep 2
            else
                exit 1
            fi
        fi
    fi
    
    log_info "BanyanDB 服务已停止"
}

# 主函数
main() {
    log_info "BanyanDB 停止脚本"
    log_info "=================="
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查是否运行
    if ! is_running; then
        log_info "BanyanDB 未运行"
        exit 0
    fi
    
    # 停止服务
    if [[ "$USE_DOCKER" == true ]]; then
        stop_docker
    else
        stop_host
    fi
    
    log_info "BanyanDB 停止完成"
}

# 执行主函数
main "$@"
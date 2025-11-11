#!/bin/bash

# Seata 公共函数库
# 包含安装、启动、停止脚本中重复使用的函数

set -e

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 获取项目目录的绝对路径
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志级别
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# 默认日志级别
DEFAULT_LOG_LEVEL=$LOG_LEVEL_INFO
SEATA_SERVER_SH="seata-server.sh"
START_SCRIPT_PATH="start.sh"
STOP_SCRIPT_PATH="stop.sh"
SEATA_NAMINGSERVER_SH="seata-namingserver.sh"

HOST="0.0.0.0"
PORT=8091
STORE_MODE="file"
LOG_FILE="$HOME/logs/seata-server.log"
# 获取日志级别（从环境变量或默认值）
get_log_level() {
    case "${LOG_LEVEL:-INFO}" in
        "DEBUG") echo $LOG_LEVEL_DEBUG ;;
        "INFO")  echo $LOG_LEVEL_INFO ;;
        "WARN")  echo $LOG_LEVEL_WARN ;;
        "ERROR") echo $LOG_LEVEL_ERROR ;;
        *)       echo $DEFAULT_LOG_LEVEL ;;
    esac
}

# 检查日志级别是否应该输出
should_log() {
    local message_level=$1
    local current_level=$(get_log_level)
    if [ $message_level -ge $current_level ]; then
        return 0  # 应该输出
    else
        return 1  # 不应该输出
    fi
}

# 带颜色和级别的日志输出函数
log_debug() {
    if should_log $LOG_LEVEL_DEBUG; then
        echo -e "${BLUE}[调试]$1${NC}" >&2
    fi
}

log_info() {
    if should_log $LOG_LEVEL_INFO; then
        echo -e "${GREEN}[信息] $1${NC}" >&2
    fi
}

log_warn() {
    if should_log $LOG_LEVEL_WARN; then
        echo -e "${YELLOW}[警告] $1${NC}" >&2
    fi
}

log_error() {
    if should_log $LOG_LEVEL_ERROR; then
        echo -e "${RED}[错误] $1${NC}" >&2
    fi
}

# 检测操作系统是否为 macOS 或 Linux
get_os_type() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux"
    else
        log_error "不支持的操作系统: $OSTYPE"
        return 1
    fi
}

# 检查Docker是否已启动 - 增强版，兼容Linux和macOS
is_docker_running() {
    # 方法1: 使用docker info命令检测
    if docker info > /dev/null 2>&1; then
        return 0  # Docker is running
    fi

    # 方法2: 检查Docker进程是否存在
    local os_type=$(get_os_type)
    if [[ "$os_type" == "Linux" ]]; then
        # Linux系统，检查docker服务进程
        if pgrep docker > /dev/null 2>&1 || systemctl is-active --quiet docker 2>/dev/null; then
            return 0
        fi
    elif [[ "$os_type" == "macOS" ]]; then
        # macOS系统，检查Docker应用进程
        if pgrep "Docker" > /dev/null 2>&1; then
            return 0
        fi
    fi

    return 1  
}
 
# 检查 docker-compose 是否已安装
check_docker_compose() {
    if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
        log_error "未找到docker-compose或docker compose命令"
        return 1
    fi
    return 0
}

# 检查Docker是否运行，如果没有则尝试启动
check_and_start_docker() {
    if ! is_docker_running; then
        log_info "Docker服务未运行，正在尝试启动Docker..."
        
        # 尝试在不同系统上启动Docker
        if command -v systemctl &> /dev/null; then
            # Linux系统，尝试使用systemctl
            if systemctl is-active --quiet docker; then
                log_info "Docker服务已存在但未响应，尝试重启..."
                sudo systemctl restart docker
            else
                log_info "正在启动Docker服务..."
                sudo systemctl start docker
            fi
        elif command -v brew &> /dev/null; then
            # macOS系统，使用brew services
            log_info "正在启动Docker服务..."
            brew services start docker 2>/dev/null || print_warn "请手动启动Docker应用"
        elif command -v service &> /dev/null; then
            # 传统Linux系统，使用service命令
            if service docker status 2>/dev/null | grep -q running; then
                log_info "Docker服务已存在但未响应，尝试重启..."
                sudo service docker restart
            else
                log_info "正在启动Docker服务..."
                sudo service docker start
            fi
        else
            # 在常见安装目录下查找Docker
            local possible_docker_paths=(
                "/usr/bin/docker"
                "/usr/local/bin/docker"
                "/opt/docker/docker"
                "/Applications/Docker.app/Contents/Resources/bin/docker"  # macOS
            )
            
            local docker_found=false
            for path in "${possible_docker_paths[@]}"; do
                if [ -x "$path" ]; then
                    log_info "找到Docker可执行文件: $path"
                    print_warn "请手动启动Docker服务或应用程序"
                    docker_found=true
                    break
                fi
            done
            
            if [ "$docker_found" = false ]; then
                log_error "无法找到Docker，请确认已安装Docker并手动启动"
                return 1
            fi
        fi
        
        # 等待Docker启动
        log_info "等待Docker服务启动..."
        local timeout=30
        local count=0
        while [ $count -lt $timeout ]; do
            if docker info > /dev/null 2>&1; then
                log_info "Docker服务已启动"
                return 0
            fi
            sleep 1
            ((count++))
        done
        
        if [ $count -eq $timeout ]; then
            log_error "Docker服务启动超时，请手动启动Docker后再运行此脚本"
            return 1
        fi
    fi
    
    return 0
}


# 检查是否存在指定的Docker镜像
has_docker_image() {
    local image_name="$1"
    if [ -z "$image_name" ]; then
        log_error "镜像名称不能为空"
        return 1
    fi
    
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image_name}$"; then
        return 0  # 镜像存在
    elif docker images --format "{{.Repository}}" | grep -q "^${image_name}$"; then
        # 检查是否有标签为 latest 的镜像
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image_name}:latest$"; then
            return 0  # 镜像存在
        fi
    fi
    
    return 1  # 镜像不存在
}

# 检查容器是否存在
has_container() {
    local container_name="$1"
    if [ -z "$container_name" ]; then
        log_error "容器名称不能为空"
        return 1
    fi
    
    if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        return 0  # 容器存在
    fi
    
    return 1  # 容器不存在
}

# 检查容器是否正在运行
is_container_running() {
    local container_name="$1"
    if [ -z "$container_name" ]; then
       container_name=$(grep "container_name" $PROJECT_DIR/docker-compose.yml|awk -F': ' '{print $2}')
    fi
    
    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        return 0  # 容器正在运行
    fi
    
    return 1  # 容器未运行
}

# 获取容器状态
get_container_status() {
    local container_name="$1"
    if [ -z "$container_name" ]; then
        log_error "容器名称不能为空"
        return 1
    fi
    
    local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}" | head -n 1)
    if [ -n "$status" ]; then
        echo "$status"
        return 0
    else
        echo "Not Found"
        return 1
    fi
}

# 检查指定名称或端口的进程是否在运行，运行的话返回进程信息
is_process_running() {
    local process_name="${1:-}"
    if [ -z "$process_name" ]; then
       process_name="$PROJECT_DIR"
    fi

    # 首先尝试使用pgrep查找进程
    if command -v pgrep &> /dev/null; then
        local pids=$(pgrep -f "$process_name" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "$pids"
            return 0
        fi
    fi
    
    # 如果没有pgrep或没有找到，使用ps命令查找
    local pids=$(ps aux | grep -i "$process_name" | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "$pids"
        return 0
    fi
    
    # 最后尝试通过端口查找Seata进程
    local pid=$(lsof -i:$PORT 2>/dev/null | awk 'NR>1 {print $2}' | head -n 1)
    if [ -n "$pid" ]; then
        echo "$pid"
        return 0
    fi
    
    # 没有找到相关进程，返回错误
    return 1
}

# 检查指定PID的进程是否在主机上运行
is_pid_running() {
    local pid="$1"
    if [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_error "PID不能为空且必须为数字"
        return 1
    fi

    # 检查指定PID的进程是否存在
    if kill -0 "$pid" 2>/dev/null; then
        return 0  # 进程正在运行
    else
        return 1  # 进程未运行
    fi
}
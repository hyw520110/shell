#!/bin/bash

# Seata服务停止脚本（优化版）
# 兼容主流Linux和macOS系统
# 支持Docker和主机模式

set -euo pipefail  # 启用严格模式：错误退出、管道失败退出、未声明变量报错
# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "错误: 找不到公共函数库 $SCRIPT_DIR/common.sh" >&2
    exit 1
fi
FORCE_STOP=false
# 获取项目目录的绝对路径
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 定义Docker Compose命令（自动检测兼容性）
DOCKER_COMPOSE_CMD="docker compose"
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
fi
# 显示帮助信息
show_help() {
    echo "用法: $0 [-f]"
    echo "  无参数  - 优雅停止Seata服务（Docker和主机模式）"
    echo "  -f      - 强制停止Seata服务（Docker和主机模式）"
    echo "  help    - 显示此帮助信息"
}

# 执行Docker Compose命令（带错误处理）
run_docker_compose() {
    local cmd="$1"
    echo "执行: $DOCKER_COMPOSE_CMD $cmd"
    if ! $DOCKER_COMPOSE_CMD $cmd; then
        echo "错误: Docker Compose命令失败: $DOCKER_COMPOSE_CMD $cmd" >&2
        return 1
    fi
    return 0
}

# 停止Docker模式下的Seata服务（优雅停止）
stop_seata_docker() {
    # 检查是否有Seata相关的Docker容器正在运行
    local RUNNING_CONTAINERS=$($DOCKER_COMPOSE_CMD ps -q 2>/dev/null)
    if [ -z "$RUNNING_CONTAINERS" ]; then
        return 0
    fi
    # 显示正在运行的容器
    echo "当前正在运行的Seata服务容器:"
    $DOCKER_COMPOSE_CMD ps
    echo "正在优雅停止Docker模式下的Seata服务..."
    # 优雅停止服务
    if ! run_docker_compose "down"; then
        echo "警告: 优雅停止失败..."
    fi
    # 检查是否仍有容器在运行
    RUNNING_CONTAINERS=$($DOCKER_COMPOSE_CMD ps -q 2>/dev/null)
    if [ ! -n "$RUNNING_CONTAINERS" ]; then
        return 0
    fi
    if [ "$FORCE_STOP" == "false" ]; then
	    echo "仍有容器在运行，如需强制停止，请使用 -f 参数"
        return 1
    fi
    echo "正在强制停止Docker模式下的Seata服务..."
    # 强制停止服务
    if ! run_docker_compose "down -v --remove-orphans"; then
        echo "警告: 基础停止失败，尝试强制终止剩余容器..."
    fi
    
    # 检查并强制终止剩余容器
    RUNNING_CONTAINERS=$($DOCKER_COMPOSE_CMD ps -q 2>/dev/null)
    if [ -n "$RUNNING_CONTAINERS" ]; then
        echo "发现 $RUNNING_CONTAINERS 个未停止的容器，强制终止..."
        docker stop $RUNNING_CONTAINERS >/dev/null 2>&1 || true
        docker rm $RUNNING_CONTAINERS >/dev/null 2>&1 || true
    fi
    echo "Docker模式下的Seata服务已停止"
}


# 停止主机模式下的Seata服务
stop_seata_host() {
    echo "正在停止主机模式下的Seata服务..."
    
    # 查找并终止Seata相关的Java进程
    local  SEATA_PROCESSES=$(pgrep -f "java.*seata-server" 2>/dev/null || true)
    
    if [ -n "$SEATA_PROCESSES" ]; then
        echo "找到以下Seata进程: $SEATA_PROCESSES"
        for pid in $SEATA_PROCESSES; do
            echo "  正在终止进程 $pid"
            kill "$pid" >/dev/null 2>&1 || true
        done
        echo "主机模式下的Seata服务已停止"
    else
        echo "未找到主机模式下运行的Seata服务"
    fi
    if [ "$FORCE_STOP"  == "false" ]; then
    	echo "主机模式下的Seata命名服务器停止失败"
        return 1
    fi
    echo "正在强制停止主机模式下的Seata服务..."
    
    if [ -n "$SEATA_PROCESSES" ]; then
        echo "找到以下Seata进程: $SEATA_PROCESSES"
        for pid in $SEATA_PROCESSES; do
            echo "  强制终止进程 $pid"
            kill -9 "$pid" >/dev/null 2>&1 || true
        done
        echo "主机模式下的Seata服务已强制停止"
    else
        echo "未找到主机模式下运行的Seata服务"
    fi
}

# 停止主机模式下的Seata命名服务器
stop_seata_namingserver_host() {
    echo "正在停止主机模式下的Seata命名服务器..."
    
    # 查找并终止Seata命名服务器相关的Java进程
    local NAMING_PROCESSES=$(pgrep -f "java.*seata-namingserver" 2>/dev/null || true)
    
    if [ -n "$NAMING_PROCESSES" ]; then
        echo "找到以下Seata命名服务器进程: $NAMING_PROCESSES"
        for pid in $NAMING_PROCESSES; do
            echo "  正在终止进程 $pid"
            kill "$pid" >/dev/null 2>&1 || true
        done
        echo "主机模式下的Seata命名服务器已停止"
    else
        return 0
    fi
     
    
    NAMING_PROCESSES=$(pgrep -f "java.*seata-namingserver" 2>/dev/null || true)
    
    if [ ! -n "$NAMING_PROCESSES" ]; then
	    return 0
    fi
    if [ "$FORCE_STOP"  == "false" ]; then
    	echo "主机模式下的Seata命名服务器停止失败"
        return 1
    fi
    echo "正在强制停止主机模式下的Seata命名服务器..."
    echo "找到以下Seata命名服务器进程: $NAMING_PROCESSES"
    for pid in $NAMING_PROCESSES; do
        echo "  强制终止进程 $pid"
        kill -9 "$pid" >/dev/null 2>&1 || true
    done
    echo "主机模式下的Seata命名服务器已强制停止"
    return 0
}



# 主程序逻辑

while [[ $# -gt 0 ]]; do
    case $1 in
        -f)
            FORCE_STOP=true
            shift
            ;;
        help|-h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "错误: 不支持的参数 '$1'" >&2
            show_help
            exit 1
            ;;
    esac
done


# 优雅停止Docker模式下的服务
if check_docker_compose; then
    stop_seata_docker
fi

# 停止主机模式下的服务
stop_seata_host
stop_seata_namingserver_host


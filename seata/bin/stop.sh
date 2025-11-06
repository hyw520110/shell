#!/bin/bash

# Seata服务停止脚本
# 兼容主流Linux和macOS系统
# 支持Docker和主机模式

set -e

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
if [ -f "$LIB_DIR/common.sh" ]; then
    source "$LIB_DIR/common.sh"
else
    echo "错误: 找不到公共函数库 $LIB_DIR/common.sh"
    exit 1
fi

# 获取项目目录的绝对路径
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 停止Docker模式下的Seata服务（优雅停止）
stop_seata_docker() {
    echo "正在优雅停止Docker模式下的Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo "警告: 未找到docker-compose.yml文件，跳过Docker模式停止"
        return 1
    fi
    
    # 停止服务（优雅停止）
    if command -v docker-compose &> /dev/null; then
        docker-compose down
    else
        docker compose down
    fi
    
    echo "Docker模式下的Seata服务已优雅停止"
}

# 强制停止Docker模式下的Seata服务
force_stop_seata_docker() {
    echo "正在强制停止Docker模式下的Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo "警告: 未找到docker-compose.yml文件，跳过Docker模式停止"
        return 1
    fi
    
    # 强制停止服务
    if command -v docker-compose &> /dev/null; then
        docker-compose down -v --remove-orphans
        # 如果还有容器在运行，强制删除
        RUNNING_CONTAINERS=$(docker-compose ps -q 2>/dev/null)
        if [ ! -z "$RUNNING_CONTAINERS" ]; then
            docker stop $RUNNING_CONTAINERS > /dev/null 2>&1 || true
            docker rm $RUNNING_CONTAINERS > /dev/null 2>&1 || true
        fi
    else
        docker compose down -v --remove-orphans
        # 如果还有容器在运行，强制删除
        RUNNING_CONTAINERS=$(docker compose ps -q 2>/dev/null)
        if [ ! -z "$RUNNING_CONTAINERS" ]; then
            docker stop $RUNNING_CONTAINERS > /dev/null 2>&1 || true
            docker rm $RUNNING_CONTAINERS > /dev/null 2>&1 || true
        fi
    fi
    
    echo "Docker模式下的Seata服务已强制停止"
}

# 停止主机模式下的Seata服务
stop_seata_host() {
    echo "正在停止主机模式下的Seata服务..."
    
    # 查找并终止Seata相关的Java进程
    SEATA_PROCESSES=$(pgrep -f "java.*seata-server")
    
    if [ -n "$SEATA_PROCESSES" ]; then
        echo "找到以下Seata进程:"
        echo "$SEATA_PROCESSES" | while read -r pid; do
            if [ -n "$pid" ]; then
                echo "  终止进程 $pid"
                kill "$pid" 2>/dev/null || true
            fi
        done
        echo "主机模式下的Seata服务已停止"
    else
        echo "未找到主机模式下运行的Seata服务"
    fi
}

# 强制停止主机模式下的Seata服务
force_stop_seata_host() {
    echo "正在强制停止主机模式下的Seata服务..."
    
    # 查找并强制终止Seata相关的Java进程
    SEATA_PROCESSES=$(pgrep -f "java.*seata-server")
    
    if [ -n "$SEATA_PROCESSES" ]; then
        echo "找到以下Seata进程:"
        echo "$SEATA_PROCESSES" | while read -r pid; do
            if [ -n "$pid" ]; then
                echo "  强制终止进程 $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
        echo "主机模式下的Seata服务已强制停止"
    else
        echo "未找到主机模式下运行的Seata服务"
    fi
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [-f]"
    echo "  无参数  - 优雅停止Seata服务（Docker和主机模式）"
    echo "  -f      - 强制停止Seata服务（Docker和主机模式）"
    echo "  help    - 显示此帮助信息"
}

# 解析命令行参数
FORCE_STOP=false

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
            echo "错误: 不支持的参数 '$1'"
            show_help
            exit 1
            ;;
    esac
done

# 主程序逻辑
if [ "$FORCE_STOP" = true ]; then
    # 强制停止Docker模式下的服务
    if check_docker_compose; then
        force_stop_seata_docker
    fi
    
    # 强制停止主机模式下的服务
    force_stop_seata_host
else
    # 优雅停止Docker模式下的服务
    if check_docker_compose; then
        stop_seata_docker
    fi
    
    # 停止主机模式下的服务
    stop_seata_host
fi
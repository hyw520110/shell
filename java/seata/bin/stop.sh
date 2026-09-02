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
    log_error "找不到公共函数库 $SCRIPT_DIR/common.sh"
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
    log_info "执行: $DOCKER_COMPOSE_CMD $cmd"
    if ! $DOCKER_COMPOSE_CMD $cmd; then
        log_error "Docker Compose命令失败: $DOCKER_COMPOSE_CMD $cmd"
        return 1
    fi
    return 0
}

# 停止Docker模式下的Seata服务（优雅停止）
stop_seata_docker() {
    # 检查是否有Seata相关的Docker容器正在运行
    if ! is_container_running "seata-server" && ! is_container_running "mysql-server"; then
        log_info "没有正在运行的Seata相关容器"
        return 0
    fi
    
    # 显示正在运行的容器
    log_info "当前正在运行的Seata服务容器:"
    $DOCKER_COMPOSE_CMD ps
    
    log_info "正在优雅停止Docker模式下的Seata服务..."
    # 优雅停止服务
    if ! run_docker_compose "down"; then
        log_warn "优雅停止失败..."
    fi
    
    # 检查是否仍有seata-server容器在运行
    if is_container_running "seata-server"; then
        if [ "$FORCE_STOP" == "false" ]; then
            log_error "仍有容器在运行，如需强制停止，请使用 -f 参数"
            return 1
        fi
        
        log_info "正在强制停止Docker模式下的Seata服务..."
        # 强制停止服务
        if ! run_docker_compose "down -v --remove-orphans"; then
            log_warn "基础停止失败，尝试强制终止剩余容器..."
        fi
        
        # 检查并强制终止剩余容器
        if is_container_running "seata-server"; then
            log_info "强制终止seata-server容器..."
            docker stop seata-server >/dev/null 2>&1 || true
            docker rm seata-server >/dev/null 2>&1 || true
        fi
        if is_container_running "mysql-server"; then
            log_info "强制终止mysql-server容器..."
            docker stop mysql-server >/dev/null 2>&1 || true
            docker rm mysql-server >/dev/null 2>&1 || true
        fi
    fi
    
    log_info "Docker模式下的Seata服务已停止"
}


# 停止主机模式下的Seata服务
stop_seata_host() {
    log_debug "正在停止主机模式下的Seata服务..."
    # 查找并终止Seata相关的Java
    local SEATA_PROCESSES=$(is_process_running)
    if [ ! -n "$SEATA_PROCESSES" ]; then
	     log_info "未找到主机模式下运行的Seata服务"
	     return 0
    fi
    log_info "Seata进程: $SEATA_PROCESSES"
    for pid in $SEATA_PROCESSES; do
        log_info "  正在终止进程 $pid"
        kill "$pid" >/dev/null 2>&1 || true
    done
    SEATA_PROCESSES=$(is_process_running)
     # 如果启用了强制停止并且仍有进程在运行，则强制终止
    if [ "$FORCE_STOP" == "true" ]; then
        if [ -n "$SEATA_PROCESSES" ]; then
            log_info "正在强制停止主机模式下的Seata服务..."
            for pid in $SEATA_PROCESSES; do
                log_info "  强制终止进程 $pid"
                kill -9 "$pid" >/dev/null 2>&1 || true
            done
            log_info "主机模式下的Seata服务已强制停止"
        else
            log_info "未找到主机模式下运行的Seata服务"
        fi
    fi
  	if [ -n "$SEATA_PROCESSES" ]; then
        log_error "主机模式下的Seata服务停止失败"
        return 1
    fi
    return 0
}

# 停止主机模式下的Seata命名服务器
stop_seata_namingserver_host() {
    log_debug "正在停止主机模式下的Seata命名服务器..."
    # 查找并终止Seata命名服务器相关的Java进程
    local NAMING_PROCESSES=$(is_process_running "seata-namingserver")
    
    if [ -n "$NAMING_PROCESSES" ]; then
        log_info "找到以下Seata命名服务器进程: $NAMING_PROCESSES"
        for pid in $NAMING_PROCESSES; do
            log_info "  正在终止进程 $pid"
            kill "$pid" >/dev/null 2>&1 || true
        done
        log_info "主机模式下的Seata命名服务器已停止"
    else
        return 0
    fi
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
            log_error "不支持的参数 '$1'"
            show_help
            exit 1
            ;;
    esac
done

# 检测Docker进程是否启动
if is_docker_running; then
    # 优雅停止Docker模式下的服务
    if check_docker_compose; then
        stop_seata_docker
    fi
fi

# 停止主机模式下的服务
stop_seata_host
stop_seata_namingserver_host
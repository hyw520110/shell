#!/bin/bash

# RocketMQ 停止脚本
# 版本: 1.1
# 用途: 停止 RocketMQ 服务

set -euo pipefail  # 严格错误处理模式

# === 引入公共函数库 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# === 配置参数 ===
# 使用common.sh中的默认值

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_STOP=false

# === 帮助信息 ===
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -d, --dir DIR     指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -f, --force       强制终止进程
    -h, --help        显示此帮助信息

示例:
    $0                           # 停止默认安装目录下的 RocketMQ 服务
    $0 -d /opt/rocketmq          # 停止 /opt/rocketmq 目录下的 RocketMQ 服务
    $0 --force                   # 强制停止 RocketMQ 服务
EOF
}

# === 命令行参数解析 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                if [[ -n "${2:-}" ]]; then
                    INSTALL_DIR="$2"
                    shift 2
                else
                    echo "错误: -d|--dir 参数需要提供目录路径" >&2
                    show_help
                    exit 1
                fi
                ;;
            -f|--force)
                FORCE_STOP=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

# === 日志函数 ===
# 使用common.sh中的日志函数

# === 服务控制函数 ===
stop_rocketmq_processes() {
    log_info "停止 NameServer 和 Broker 进程"
    
    if [ "$FORCE_STOP" = true ]; then
        log_info "强制停止模式启用"
        
        # 强制终止所有相关进程
        local namesrv_pids=$(pgrep -f "mqnamesrv")
        if [ -n "$namesrv_pids" ]; then
            log_info "强制停止 NameServer 进程: $namesrv_pids"
            kill -9 $namesrv_pids 2>/dev/null || true
        else
            log_info "未找到运行中的 NameServer 进程"
        fi
        
        local broker_pids=$(pgrep -f "mqbroker")
        if [ -n "$broker_pids" ]; then
            log_info "强制停止 Broker 进程: $broker_pids"
            kill -9 $broker_pids 2>/dev/null || true
        else
            log_info "未找到运行中的 Broker 进程"
        fi
    else
        # 使用常规停止方法
        local namesrv_pids=$(pgrep -f "mqnamesrv")
        if [ -n "$namesrv_pids" ]; then
            log_info "停止 NameServer 进程: $namesrv_pids"
            kill $namesrv_pids 2>/dev/null || true
        else
            log_info "未找到运行中的 NameServer 进程"
        fi
        
        local broker_pids=$(pgrep -f "mqbroker")
        if [ -n "$broker_pids" ]; then
            log_info "停止 Broker 进程: $broker_pids"
            kill $broker_pids 2>/dev/null || true
        else
            log_info "未找到运行中的 Broker 进程"
        fi
        
        # 等待进程终止
        sleep 2
        
        # 如果仍有进程运行，则强制终止
        pgrep -f "mqnamesrv" | xargs -r kill -9 2>/dev/null || true
        pgrep -f "mqbroker" | xargs -r kill -9 2>/dev/null || true
    fi
    
    # 清理PID文件
    local pid_dir="$INSTALL_DIR/run"
    if [ -d "$pid_dir" ]; then
        rm -f "$pid_dir/"*.pid
    fi
    
    log_info "进程停止完成"
}

# 使用common.sh中的check_running_processes函数

# === 主函数 ===
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    log_info "开始停止 RocketMQ 服务"
    log_info "安装目录: $INSTALL_DIR"
    log_info "强制停止模式: $([ "$FORCE_STOP" = true ] && echo "启用" || echo "禁用")"
    
    # 检查是否有运行的进程
    if check_running_processes; then
        echo "正在停止 RocketMQ 服务..."
        stop_rocketmq_processes
        echo "RocketMQ 服务已停止。"
    else
        echo "未检测到运行中的 RocketMQ 服务。"
        exit 0
    fi
}

# === 执行主函数 ===
main "$@"
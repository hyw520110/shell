#!/bin/bash

# 设置严格模式
set -euo pipefail

INSTALL_DIR=$(dirname "$(readlink -f "$0")")

# 获取FRP进程PID
get_frp_pids() {
    pgrep -f "${INSTALL_DIR}/frp[cs]"
}

# 优雅停止服务
stop_service() {
    local pids=$(get_frp_pids)
    
    if [ -z "$pids" ]; then
        echo "未找到运行中的 FRP 进程"
        return 0
    fi
    
    echo "检测到以下 FRP 进程:"
    for pid in $pids; do
        if [[ "$OSTYPE" == "darwin"* ]]; then
            ps -p $pid -o pid,comm 2>/dev/null || echo "  PID $pid"
        else
            ps -p $pid -o pid,cmd 2>/dev/null || echo "  PID $pid"
        fi
    done
    
    echo "正在停止进程..."
    for pid in $pids; do
        # 先发送SIGTERM信号
        kill "$pid" 2>/dev/null || true
        
        # 等待最多10秒
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        
        # 如果进程仍在运行，使用SIGKILL
        if kill -0 "$pid" 2>/dev/null; then
            echo "进程 $pid 未响应 SIGTERM，使用 SIGKILL 强制终止"
            kill -9 "$pid" 2>/dev/null || true
        else
            echo "进程 $pid 已正常停止"
        fi
    done
    
    echo "FRP 服务停止完成"
}

stop_service

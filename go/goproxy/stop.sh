#!/bin/bash

# 获取当前脚本的绝对路径
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
PROXY_LOG="proxy.log"

# 停止 proxy 服务
stop_proxy() {
    # 查找并停止所有名为 proxy 的进程
    pids=$(pgrep -x "proxy")

    if [ -z "$pids" ]; then
        echo "没有找到正在运行的 proxy 进程。"
    else
        for pid in $pids; do
            kill -SIGTERM "$pid" || true
            echo "已发送终止信号给进程 $pid。"
        done

        # 确认进程是否已停止
        sleep 3
        if pgrep -x "proxy" > /dev/null; then
            echo "尝试强制停止 proxy 进程..."
            pids=$(pgrep -x "proxy")
            for pid in $pids; do
                kill -SIGKILL "$pid" || true
                echo "已强制停止进程 $pid。"
            done
        fi

        echo "proxy 服务已停止。"
    fi

    if [ -f "$PROXY_LOG" ]; then
        echo "服务停止时间：$(date)" >> "$PROXY_LOG"
    fi
}

# 调用停止函数
stop_proxy

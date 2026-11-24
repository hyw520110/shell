#!/bin/bash

# 查找所有 Nacos 进程
PIDS=$(ps -efww | grep -i "nacos.nacos" | grep -v grep | awk '{print $2}')
if [ -n "$PIDS" ]; then
    echo "[INFO] 发现运行中的 Nacos 进程 (PID: $PIDS)"
    for pid in $PIDS; do
        echo "  -> 正在强制终止 Nacos (PID: $pid)..."
        kill -9 $pid 1>/dev/null 2>&1
    done
    echo "[SUCCESS] Nacos 已成功停止。"
else
    echo "[INFO] 当前没有正在运行的 Nacos 进程。"
fi
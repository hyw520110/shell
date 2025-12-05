#!/bin/bash

# 脚本功能：一个健壮的CPU压力测试工具，可以安全地启动和停止。

# --- 配置 ---
LOG_FILE="/tmp/eatcpu.log"
PID_FILE="/tmp/eatcpu_pids.log" # 存储所有子进程的PID
# --- 结束配置 ---

# --- 函数定义 ---

# 日志记录函数
log_message() {
    # tee -a 表示同时输出到屏幕和追加到日志文件
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 在后台无限循环，消耗一个CPU核心
cpu_eater_function() {
    # ':' 是一个shell内建的空命令，效率极高，用于无限循环非常合适
    while true; do
        :
    done
}

# 清理函数，此函数会在脚本退出时被trap调用
cleanup() {
    log_message "收到退出信号，开始清理..."
    if [ -f "$PID_FILE" ]; then
        # 读取PID文件中的所有PID，并强制杀死它们
        # xargs -r 确保在PID文件为空时不执行kill
        # || true 确保即使kill失败（比如进程已不存在）脚本也不会因set -e而退出
        cat "$PID_FILE" | xargs -r kill -9 >/dev/null 2>&1 || true
        rm -f "$PID_FILE"
        log_message "所有CPU负载子进程已停止。"
    else
        log_message "未发现PID文件，无需清理。"
    fi
    # 正常退出
    exit 0
}

# --- 主程序 ---

# 设置trap，无论脚本因何种原因（正常退出、Ctrl+C、被kill）退出，都执行cleanup函数
trap cleanup EXIT INT TERM

# 提供一个 'stop' 命令，用于清理任何可能残留的旧进程
if [[ "$1" == "stop" ]]; then
    log_message "收到 'stop' 命令。"
    # cleanup函数会在脚本退出时自动执行，所以这里直接exit即可
    exit 0
fi

# 校验输入参数是否为正整数
if ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "用法: $0 <要加载的CPU核心数>"
    echo "       $0 stop"
    echo
    echo "本机CPU信息:"
    # nproc 是一个方便的工具，直接显示核心数
    echo "  逻辑核心数: $(nproc 2>/dev/null || echo 'N/A')"
    exit 1
fi

# --- 启动负载 ---
num_cores=$1
log_message "将在 ${num_cores} 个核心上启动CPU负载..."

# 启动前，先执行一次清理，以防有上次异常退出的残留进程
if [ -f "$PID_FILE" ]; then
    log_message "发现旧的PID文件，执行清理..."
    cat "$PID_FILE" | xargs -r kill -9 >/dev/null 2>&1 || true
fi
# 清空PID文件，准备写入新的PID
> "$PID_FILE"

# 循环启动指定数量的后台进程
for ((i=0; i<num_cores; i++)); do
    cpu_eater_function &
    # 将新启动的后台进程的PID追加到PID文件中
    echo $! >> "$PID_FILE"
done

log_message "成功启动 $(wc -l < "$PID_FILE") 个负载进程。PID已记录到 $PID_FILE"
log_message "CPU负载已生效。按 Ctrl+C 或执行 '$0 stop' 来停止。"

# 使用 wait 命令让主脚本挂起，等待所有后台子进程（理论上是永远，直到被trap中断）
# 这使得脚本可以保持运行状态，直到用户手动停止
wait
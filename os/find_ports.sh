#!/bin/bash

# 脚本功能：根据一个或多个关键字查找进程，并列出其正在监听的TCP/UDP端口。

set -eo pipefail

# --- 帮助函数 ---
show_help() {
    echo "用法: $0 <关键字1> [关键字2] ..."
    echo "查找包含所有指定关键字的进程，并显示其监听的端口。"
    echo
    echo "示例: $0 java my-app"
}

# --- 主逻辑 ---

# 1. 检查参数
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

# 2. 提示权限问题
if [ "$(id -u)" -ne 0 ]; then
    echo "警告: 当前为非root用户，可能无法查看所有进程的端口信息。" >&2
fi

# 3. 使用 grep 链来查找匹配所有关键字的进程
# 先获取完整的进程列表
process_list=$(ps -ef)
# 然后像筛子一样，用每个关键字过滤一遍
for keyword in "$@"; do
    # grep -F 表示将关键字作为固定字符串处理，而不是正则表达式，更安全
    process_list=$(echo "$process_list" | grep -F -- "$keyword")
done

# 从最终的进程列表中提取PID，并排除grep自身的进程
pids=$(echo "$process_list" | grep -v -F -- "grep -F" | awk '{print $2}')

if [ -z "$pids" ]; then
    echo "未找到匹配所有关键字的正在运行的进程。"
    exit 0
fi

echo "找到匹配的进程 PID: $pids"
echo "--------------------------------------------------"

# 4. 为每个找到的PID查找其监听的端口
echo "$pids" | while read -r pid; do
    echo "正在检查 PID: $pid ..."
    
    # 使用 ss 命令，现代、高效、可靠
    # -l 监听, -t TCP, -u UDP, -p 进程, -n 数字格式
    # grep "pid=$pid," 可以精确匹配，避免PID是其他数字一部分的干扰
    # || true 防止在没找到端口时 grep 返回非0码导致 set -e 退出脚本
    ports_info=$(ss -ltupn | grep "pid=$pid," || true)

    if [ -z "$ports_info" ]; then
        echo "  -> 未发现此PID的监听端口。"
    else
        # 从 ss 的输出中提取端口号 (第5列)，去重并转为一行
        listening_ports=$(echo "$ports_info" | awk '{print $5}' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
        echo "  -> 正在监听端口: $listening_ports"
    fi
done

#!/bin/bash

# 脚本功能：监控并记录与指定目标建立的TCP连接及其关联进程。

# --- 配置 ---
# 要监控的目标主机名或IP地址，用空格隔开
TARGET_HOSTS=("google" "github" "47.110.177.14")

# 日志文件路径，使用/tmp或/var/log更合适
LOG_FILE="/tmp/net_monitor.log"

# 检查周期（秒）
CHECK_INTERVAL=15
# --- 结束配置 ---

set -e

# 检查核心工具ss是否存在
if ! command -v ss &> /dev/null; then
    echo "错误: 'ss' 命令未找到。请安装 'iproute2' 包。" >&2
    exit 1
fi

echo "开始网络监控... 目标: [${TARGET_HOSTS[*]}]"
echo "日志将记录到: $LOG_FILE"

# 将目标数组转换成一个高效的grep正则表达式，例如 "google|github|47.110.177.14"
pattern=$(printf "|%s" "${TARGET_HOSTS[@]}")
pattern=${pattern:1} # 移除第一个'|'

# 无限循环监控
while true; do
    # 使用ss命令获取所有已建立的TCP连接，并显示进程信息
    # -t: TCP, -p: 进程, -n: 数字格式端口, -o: 选项（显示计时器等）
    # 使用grep -E通过正则表达式一次性匹配所有目标
    # 加上 || true 是为了在没有匹配时阻止grep以非0状态码退出，从而避免set -e中断脚本
    connections=$(ss -tpno state established | grep -E "$pattern" || true)

    # 如果找到了匹配的连接
    if [ -n "$connections" ]; then
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "--- [${timestamp}] 发现匹配连接 ---" >> "$LOG_FILE"
        echo "$connections" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE" # 添加空行便于阅读

        echo "[${timestamp}] 发现匹配连接，已记录到日志。"
    fi

    sleep "$CHECK_INTERVAL"
done
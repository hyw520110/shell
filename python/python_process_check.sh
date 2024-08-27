#!/bin/bash

# 定义时间变量
START_HOUR=8
END_HOUR=22
CRON_JOB='*/10 * * * * $(readlink -f "$0")'

# 检查是否以root用户运行，如果不是，则退出
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# 获取当前脚本的绝对路径
SCRIPT_FILE=$(readlink -f "$0")

# 检查是否已经存在定时任务
CURRENT_CRON_JOBS=$(crontab -l)
if [[ "$CURRENT_CRON_JOBS" != *"$CRON_JOB"* ]]; then
    # 如果不存在，则添加定时任务
    (echo "$CURRENT_CRON_JOBS"; echo "$CRON_JOB") | crontab -
    echo "定时任务已成功添加。"
fi

# 获取当前小时
current_hour=$(date +%H)

# 只在晚上10点到早上8点之间执行
if [ "$current_hour" -ge $END_HOUR ] || [ "$current_hour" -lt $START_HOUR ]; then
    # 查找Python进程
    python_process_count=$(ps -ef | grep python | grep -E ".py$" | grep -v grep | wc -l)
    
    # 如果没有找到Python进程，则关闭计算机
    if [ "$python_process_count" -eq 0 ]; then
        echo "没有Python进程在运行，将在1分钟后关机..."
        sudo shutdown -h +1
    fi
fi
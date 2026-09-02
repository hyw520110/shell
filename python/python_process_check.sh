#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
Python 进程检查和监控脚本

监控 Python 进程状态，根据配置自动管理进程和系统资源。

用法: ./python_process_check.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息
    --start-hour <小时>    开始检查时间（默认: 8）
    --end-hour <小时>      结束检查时间（默认: 22）
    --check-only          仅检查进程，不执行操作

说明:
    - 定时检查Python进程状态
    - 在指定时间窗口内监控（默认晚上10点到早上8点）
    - 检测到无Python进程时自动关机
    - 自动配置cron定时任务
    - 每10分钟执行一次检查

配置参数:
    START_HOUR=8           # 开始检查时间（8点）
    END_HOUR=22            # 结束检查时间（22点）
    CRON_INTERVAL=10       # 检查间隔（分钟）

示例:
    sudo ./python_process_check.sh                    # 默认配置运行
    sudo ./python_process_check.sh --start-hour 9     # 修改开始时间
    sudo ./python_process_check.sh --check-only       # 仅检查状态

使用场景:
    - 夜间自动关机节能
    - 监控长时间运行的Python任务
    - 服务器资源管理

注意事项:
    - 必须以root用户运行
    - 会自动添加cron定时任务
    - 在指定时间窗口内执行检查
    - 检测到无Python进程时会关机

查看定时任务:
    sudo crontab -l

删除定时任务:
    sudo crontab -e
    删除包含此脚本的行

EOF
}

# 参数解析
CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Python进程检查脚本版本: 1.0"
            exit 0
            ;;
        --start-hour)
            START_HOUR="$2"
            shift 2
            ;;
        --end-hour)
            END_HOUR="$2"
            shift 2
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 定义时间变量
START_HOUR=${START_HOUR:-8}
END_HOUR=${END_HOUR:-22}
CRON_JOB='*/10 * * * * $(readlink -f "$0")'

# 检查是否以root用户运行，如果不是，则退出
if [ "$(id -u)" != "0" ]; then
   echo "错误: 此脚本必须以root用户运行" 1>&2
   exit 1
fi

# 仅检查模式
if [ "$CHECK_ONLY" = true ]; then
    echo "当前配置:"
    echo "  开始检查时间: ${START_HOUR}点"
    echo "  结束检查时间: ${END_HOUR}点"
    echo "  检查间隔: 10分钟"
    echo ""
    echo "当前Python进程:"
    ps -ef | grep python | grep -E ".py$" | grep -v grep
    echo ""
    echo "当前定时任务:"
    crontab -l | grep python_process_check || echo "未配置定时任务"
    exit 0
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
    else
        echo "检测到 $python_process_count 个Python进程在运行，继续监控。"
    fi
else
    echo "当前时间不在监控窗口内（${START_HOUR}点-${END_HOUR}点），跳过检查。"
fi
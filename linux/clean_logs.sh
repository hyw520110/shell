#!/bin/bash
# 清理模型训练日志文件，首次运行自动添加定时任务定时执行

# 日志保留天数
retention_days=10

# 获取当前脚本的绝对路径
CURRENT_SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")
# 从路径中提取脚本名称（不包含路径）
SCRIPT_NAME=$(basename "$CURRENT_SCRIPT")

# 默认日志目录
DEFAULT_LOG_DIR="./logs"

# 解析命令行参数
while getopts "d:" opt; do
    case $opt in
        d)
            LOG_DIR="$OPTARG"
            ;;
        \?)
            echo "Usage: $0 [-d <directory>]"
            echo "Options:"
            echo "  -d <directory>  Specify the directory containing logs."
            exit 1
            ;;
    esac
done

# 检查当前用户是否有sudo权限
if ! sudo -n true 2>/dev/null; then
    echo "警告：当前用户没有sudo权限，可能无法删除部分文件。"
    echo "建议使用具有sudo权限的用户运行此脚本。"
    read -p "是否继续？(y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        echo "脚本已取消。"
        exit 1
    fi
fi
# 如果没有提供命令行参数，则提示用户输入日志目录
if [ -z "$LOG_DIR" ]; then
    read -t 8 -p "请输入日志目录路径（默认为$DEFAULT_LOG_DIR）: " USER_INPUT
    LOG_DIR=${USER_INPUT:-$DEFAULT_LOG_DIR}
fi

# 检查日志目录是否存在
if [ ! -d "$LOG_DIR" ]; then
    echo "指定的日志目录 '$LOG_DIR' 不存在。自动查找根目录下的所有日志文件"
    LOG_DIR="/"
else
    echo "日志目录：$LOG_DIR"
fi


# 清理日志的逻辑
function clean_logs {
    dir="$1"
    echo "清理目录：$dir"

    # 使用sudo来提升权限
    find "$dir" -type f \( -name "*.log" -o -name "*.log.gz" \) -mtime +$retention_days -print0 |
    while IFS= read -r -d '' file; do
        if [ -w "$file" ]; then
            if sudo rm -f "$file"; then
                echo "$file 已删除"
            else
                echo "$file 删除出错"
            fi
        else
            echo "$file 文件无写权限，跳过"
        fi
    done
}

# 执行清理逻辑
clean_logs "$LOG_DIR"

# 检查是否已有定时任务
cron_job=$(crontab -l 2>/dev/null | grep -F "$CURRENT_SCRIPT $LOG_DIR")

# 如果没有定时任务，则添加定时任务
if [ -z "$cron_job" ]; then
    # 添加定时任务
    (crontab -l 2>/dev/null; echo "0 1 * * * $CURRENT_SCRIPT $LOG_DIR") | crontab -
    if [ $? -eq 0 ]; then
        echo "自动添加清理日志的定时任务成功，频率为每天凌晨1点。"
    else
        echo "自动添加定时任务失败，请手动添加： (crontab -l 2>/dev/null; echo "0 1 * * * $CURRENT_SCRIPT $LOG_DIR") | crontab -"
    fi
else
    echo "已存在的清理日志定时任务: $cron_job"
fi
echo "如果需要删除定时任务，请执行以下命令："
echo "crontab -l | grep -v '$CURRENT_SCRIPT $LOG_DIR' | crontab -"
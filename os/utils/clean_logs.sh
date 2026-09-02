#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
日志清理脚本

自动清理指定目录下的旧日志文件，支持定时任务配置。

用法: ./clean_logs.sh [选项]

选项:
    -d <目录>         指定日志目录（默认: ./logs）
    -r <天数>         日志保留天数（默认: 10）
    -h, --help        显示此帮助信息
    -v, --version     显示版本信息

说明:
    - 自动清理指定天数前的日志文件
    - 支持定时任务配置（首次运行自动添加）
    - 支持多个日志目录
    - 显示清理统计信息
    - 生成清理日志

清理规则:
    - 只删除日志文件（*.log, *.txt）
    - 保留指定天数内的日志
    - 跳过正在使用的文件
    - 递归清理子目录

示例:
    ./clean_logs.sh                           # 使用默认配置
    ./clean_logs.sh -d /var/log              # 指定日志目录
    ./clean_logs.sh -d /var/log -r 7         # 保留7天日志

定时任务:
    脚本会自动添加 cron 定时任务，每天凌晨执行清理
    可通过 crontab -l 查看已配置的任务

注意事项:
    - 需要root权限清理系统日志
    - 删除操作不可逆，请谨慎使用
    - 建议先使用 -r 参数指定较短的保留期测试
    - 清理前建议先查看日志大小和数量

查看定时任务:
    crontab -l | grep clean_logs

删除定时任务:
    crontab -e  # 删除相关行

EOF
}

# 参数解析
while getopts "d:r:hv" opt; do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        v)
            echo "日志清理脚本版本: 1.0"
            exit 0
            ;;
        d)
            LOG_DIR="$OPTARG"
            ;;
        r)
            retention_days="$OPTARG"
            ;;
        \?)
            show_help
            exit 1
            ;;
    esac
done

# 清理模型训练日志文件，首次运行自动添加定时任务定时执行

# 日志保留天数
retention_days=${retention_days:-10}

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
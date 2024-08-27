#!/bin/bash
# 下载并更新 /etc/hosts 文件内容，并设置定时任务

# 获取脚本所在目录的绝对路径
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# 定义脚本名称
SCRIPT_NAME=$(basename "$0")
CURRENT_SCRIPT="$DIR/$SCRIPT_NAME"

# 定义 hosts 文件 URL
HOSTS_URL="https://gitee.com/if-the-wind/github-hosts/raw/main/hosts"

# 获取 hosts 文件内容
function fetch_hosts {
    curl -s "$HOSTS_URL" | grep -v '^#' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# 处理现有 /etc/hosts 文件
function update_hosts {
    existing_hosts=$(cat /etc/hosts)
    new_hosts=$(fetch_hosts)
    new_domains=$(echo "$new_hosts" | cut -d ' ' -f2-)
    cp /etc/hosts /etc/hosts.bak
    for domain in $new_domains; do
        domain=$(echo "$domain" | awk '{$1=$1};1')
        sed -i "/$domain/d" /etc/hosts
    done
    echo "$new_hosts" >> /etc/hosts
    echo "/etc/hosts 文件已更新:"
    cat /etc/hosts
}

# 添加定时任务
function add_cron_job {
    # 检查 crontab 中是否已存在定时任务
    cron_job=$(crontab -l 2>/dev/null | grep -F "$CURRENT_SCRIPT")
    if [ -z "$cron_job" ]; then
        # 添加定时任务，每1个小时执行一次脚本
        echo "0 * * * * $CURRENT_SCRIPT" | crontab -
        if [ $? -eq 0 ]; then
            echo "定时任务添加成功,crontab -l:"
            crontab -l
            echo "如果需要删除定时任务，请执行以下命令："
            echo "sudo crontab -l | grep -v '$CURRENT_SCRIPT' | sudo crontab -"
        else
            echo "定时任务添加失败，请手动添加或检查权限。"
        fi
    else
        echo "已存在的定时任务: $cron_job"
    fi
}

# 检查是否具有sudo权限
if ! sudo -n true 2>/dev/null; then
    echo "警告：当前用户没有sudo权限，无法修改 /etc/hosts 文件，脚本退出。"
    exit 1
fi

update_hosts
# 检查并添加定时任务
add_cron_job
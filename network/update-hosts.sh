#!/bin/bash
# 下载并更新 /etc/hosts 文件内容，并设置定时任务
set -euo pipefail

# 全局变量
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
readonly HOSTS_URL="https://gitee.com/if-the-wind/github-hosts/raw/main/hosts"
readonly MARKER_START="# START GITHUB HOSTS"
readonly MARKER_END="# END GITHUB HOSTS"
readonly TEMP_FILE=$(mktemp)
readonly BACKUP_FILE="/etc/hosts.bak"
readonly CRON_SCHEDULE="0 * * * *"

# 日志函数
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $@"
}

# 检查sudo权限
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log ERROR "需要sudo权限来修改 /etc/hosts 文件"
        exit 1
    fi
}

# 获取hosts文件内容
fetch_hosts() {
    curl -s --fail --connect-timeout 10 "$HOSTS_URL" | awk '/^#/ {next} {print $0}' || {
        log ERROR "无法获取 hosts 文件内容，请检查网络或 URL: $HOSTS_URL"
        exit 1
    }
}

# 更新hosts文件
update_hosts() {
    log INFO "开始更新 /etc/hosts 文件..."
    
    local new_hosts_content
    new_hosts_content=$(fetch_hosts) || exit 1

    # 确保临时文件可写
    touch "$TEMP_FILE" && chmod 644 "$TEMP_FILE" || {
        log ERROR "无法创建临时文件"
        exit 1
    }

    # 处理现有hosts文件
    sudo sed -E "/${MARKER_START//\//\\/}/,/${MARKER_END//\//\\/}/d" /etc/hosts > "$TEMP_FILE" || {
        log ERROR "处理 /etc/hosts 文件失败"
        exit 1
    }

    # 添加新的hosts内容
    {
        echo "$MARKER_START"
        echo "$new_hosts_content"
        echo "$MARKER_END"
    } >> "$TEMP_FILE"

    # 备份并更新hosts文件
    sudo cp /etc/hosts "$BACKUP_FILE" && sudo mv "$TEMP_FILE" /etc/hosts || {
        log ERROR "更新 /etc/hosts 文件失败"
        exit 1
    }

    log INFO "/etc/hosts 文件更新成功"
}

# 添加定时任务
add_cron_job() {
    if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
        log INFO "定时任务已存在，无需重复添加"
        return 0
    fi

    # 添加新定时任务
    (crontab -l 2>/dev/null || true; echo "${CRON_SCHEDULE} ${SCRIPT_PATH}") | crontab - || {
        log ERROR "添加定时任务失败，请检查权限"
        return 1
    }

    log INFO "定时任务添加成功，每小时更新 hosts 文件"
    log INFO "删除命令: crontab -l | grep -v '${SCRIPT_PATH}' | crontab -"
}

# 清理临时文件
cleanup() {
    [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
}

# 主函数
main() {
    trap cleanup EXIT
    check_sudo
    update_hosts
    add_cron_job
}

main "$@"
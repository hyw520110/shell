#!/bin/bash
# 功能：安全地更新 /etc/hosts 文件，将指定的主机名列表指向本机IP。

set -eo pipefail

# --- 配置 ---
HOSTS_TO_ADD=(
    "redis-server" "mq-server" "mysql-server" "oss-server"
    "es-server" "model-server" "sk-server" "nacos-server"
    "task-server" "ssj-show.aipsybot.com" "zk1" "zk2" "zk3"
)
HOSTS_FILE="/etc/hosts"
# --- 结束配置 ---

log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

main() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。"
    fi

    # 使用标准命令获取本机主要IP
    local_ip=$(hostname -I | awk '{print $1}')
    if [ -z "$local_ip" ]; then
        error_exit "无法获取本机IP地址。"
    fi
    log_message "检测到本机IP为: $local_ip"

    # 备份hosts文件
    cp -n "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d)"

    for host in "${HOSTS_TO_ADD[@]}"; do
        # 检查host是否已存在且IP正确
        if grep -q "^${local_ip}\\s.*\\b${host}\\b" "$HOSTS_FILE"; then
            log_message "主机 '$host' 配置正确，跳过。"
        else
            # 如果存在但IP不正确，先删除旧的
            if grep -q "\\b${host}\\b" "$HOSTS_FILE"; then
                log_message "发现 '$host' 的旧记录，正在删除..."
                sed -i "/\\b${host}\\b/d" "$HOSTS_FILE"
            fi
            # 添加新记录
            log_message "正在为 '$host' 添加新记录..."
            echo "${local_ip}    ${host}" >> "$HOSTS_FILE"
        fi
    done
    log_message "Hosts 文件更新完成。"
}

main "$@"

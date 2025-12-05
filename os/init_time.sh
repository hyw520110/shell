#!/bin/bash

# 脚本功能：配置并启用 chronyd 服务来进行稳定、平滑的时间同步。
# 这是在现代Linux系统上替代 ntpdate cron 任务的最佳实践。

set -eo pipefail

# --- 配置 ---
# 使用NTP服务器池，以提高可用性
NTP_SERVERS=(
    "0.pool.ntp.org"
    "1.pool.ntp.org"
    "2.pool.ntp.org"
    "3.pool.ntp.org"
)
CHRONY_CONFIG_FILE="/etc/chrony.conf"
# --- 结束配置 ---

# --- 函数定义 ---
log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# --- 主逻辑 ---
main() {
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    # 2. 检查 chronyd 是否已安装，如未安装则尝试安装
    if ! command -v chronyd &> /dev/null; then
        log_message "'chrony' 未安装，正在尝试自动安装..."
        if command -v yum &> /dev/null; then
            yum install -y chrony
        elif command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony
        else
            error_exit "无法确定包管理器 (yum/apt)。请手动安装 'chrony' 后再运行此脚本。"
        fi
    fi

    # 3. 配置 chrony.conf 文件
    log_message "正在配置 ${CHRONY_CONFIG_FILE}..."
    # 先备份原始文件
    cp -n "$CHRONY_CONFIG_FILE" "${CHRONY_CONFIG_FILE}.bak.$(date +%Y%m%d)"
    
    # 注释掉文件中所有默认的 server/pool 行，避免冲突
    sed -i -e 's/^\(server\|pool\)/#\1/' "$CHRONY_CONFIG_FILE"
    
    # 将我们自己的服务器池配置添加进去
    for server in "${NTP_SERVERS[@]}"; do
        # 仅当配置不存在时才添加，保证幂等性
        if ! grep -q "^pool ${server}" "$CHRONY_CONFIG_FILE"; then
            echo "pool ${server} iburst" >> "$CHRONY_CONFIG_FILE"
        fi
    done
    # 添加 makestep 指令，允许在前三次更新中进行较大的时间步进调整，以快速同步初始时间
    if ! grep -q "^makestep" "$CHRONY_CONFIG_FILE"; then
        echo "makestep 1.0 3" >> "$CHRONY_CONFIG_FILE"
    fi
    log_message "chrony 配置完成。"

    # 4. 启用并重启 chronyd 服务
    log_message "正在启用并重启 chronyd 服务..."
    systemctl enable chronyd
    systemctl restart chronyd

    # 5. 验证服务状态和同步源
    log_message "等待 chronyd 初始化..."
    sleep 5
    log_message "chronyd 服务状态:"
    systemctl status chronyd --no-pager
    log_message "当前NTP同步源:"
    chronyc sources
    
    log_message "时间同步服务配置完成。"
}

# 执行主函数
main "$@"

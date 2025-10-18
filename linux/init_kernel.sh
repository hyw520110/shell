#!/bin/bash

# 脚本功能：应用一组自定义的、用于网络优化的内核参数。

set -eo pipefail

# --- 配置 ---
# 遵循最佳实践，将自定义配置写入 /etc/sysctl.d/ 目录下的一个新文件
CUSTOM_SYSCTL_FILE="/etc/sysctl.d/99-custom-network-tuning.conf"

# 使用 HEREDOC 定义所有要应用的设置
read -r -d '' KERNEL_SETTINGS <<EOF
# --- 由 init_kernel.sh 脚本配置的网络优化参数 ---
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
# --- 结束配置 ---

# --- 函数定义 ---
log_message() {
    echo "[信息] $1"
}

error_exit() {
    echo "[错误] $1" >&2
    exit 1
}

# --- 主逻辑 ---
main() {
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    log_message "准备应用自定义内核参数..."

    # 2. 将配置写入独立的 .conf 文件中
    # 这种覆盖写的方式是幂等的，无论运行多少次，文件内容都保持一致
    if echo "$KERNEL_SETTINGS" > "$CUSTOM_SYSCTL_FILE"; then
        log_message "配置已成功写入到 $CUSTOM_SYSCTL_FILE"
    else
        error_exit "写入配置文件失败！"
    fi

    # 3. 加载刚刚写入的配置使其立即生效
    # sysctl -p <file> 只加载指定文件，比加载全部文件更精确
    log_message "正在加载新的内核参数..."
    if sysctl -p "$CUSTOM_SYSCTL_FILE"; then
        log_message "内核参数已成功应用。"
    else
        error_exit "应用内核参数失败！请检查配置是否存在语法错误。"
    fi

    log_message "内核参数优化完成。"
}

# 执行主函数
main "$@"

#!/bin/bash

# 脚本功能：安全地移除 Debian/Ubuntu 系统上不再需要的旧内核。
# 本脚本是作为 'apt autoremove' 的一个安全、交互式的包装器。

set -eo pipefail

# --- 函数定义 ---
log_message() { echo -e "\033[0;32m[信息] $1\033[0m"; }
warn_message() { echo -e "\033[1;33m[警告] $1\033[0m"; }
error_exit() { echo -e "\033[0;31m[错误] $1\033[0m" >&2; exit 1; }

# --- 主逻辑 ---
main() {
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    # 2. 检查是否为Debian系系统
    if ! command -v apt-get &>/dev/null; then
        error_exit "未找到 'apt-get' 命令。此脚本适用于Debian、Ubuntu等系统。"
    fi

    log_message "正在查找可以被安全移除的旧内核和依赖..."
    
    # 3. 使用 --dry-run 进行演习，并捕获将要被删除的包列表
    # 'apt-get' 的输出比 'apt' 更适合脚本解析
    local packages_to_remove
    packages_to_remove=$(apt-get --dry-run autoremove | grep '^Remv' | awk '{print $2}')

    if [ -z "$packages_to_remove" ]; then
        log_message "未发现任何可以移除的旧内核或依赖。您的系统很干净！"
        exit 0
    fi

    warn_message "以下软件包将被【永久删除】："
    echo "--------------------------------------------------"
    echo "$packages_to_remove"
    echo "--------------------------------------------------"
    warn_message "这通常是安全的操作，但请在确认前仔细检查列表。"
    
    # 4. 请求用户最终确认
    read -p "您确定要继续执行删除操作吗? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "操作已由用户取消。"
        exit 0
    fi

    # 5. 执行真正的删除操作
    log_message "正在执行删除..."
    if apt-get autoremove -y; then
        log_message "旧内核及依赖已成功移除。"
    else
        error_exit "在执行 'apt-get autoremove' 过程中发生错误。"
    fi
}

# 执行主函数
main "$@"
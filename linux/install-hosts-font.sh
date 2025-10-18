#!/bin/bash
# 脚本功能：在CentOS/RHEL系统上，通过包管理器安全地安装中文字体。

set -eo pipefail

log_message() { echo "[信息] $1"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

main() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。"
    fi

    # 1. 检查 fontconfig 是否安装，它是字体管理的基础工具
    if ! command -v fc-list &>/dev/null; then
        log_message "正在安装字体管理工具 'fontconfig'..."
        yum install -y fontconfig
    fi
    
    # 2. 使用 fc-list 检查系统是否已有中文字体
    if fc-list :lang=zh | grep -q "."; then
        log_message "检测到系统已安装中文字体。无需任何操作。"
        exit 0
    fi

    # 3. 安装一个标准的中文字体包（文泉驿微米黑）
    log_message "未发现中文字体，准备从YUM源安装 'wqy-microhei-fonts'..."
    if command -v yum &>/dev/null; then
        yum install -y wqy-microhei-fonts
    elif command -v dnf &>/dev/null; then
        dnf install -y wqy-microhei-fonts
    else
        error_exit "未找到 'yum'或'dnf' 命令，无法安装字体包。"
    fi

    # 4. 重建字体缓存，让新字体生效
    log_message "正在重建字体缓存..."
    fc-cache -f -v

    # 5. 最终验证
    log_message "正在验证安装结果..."
    if fc-list :lang=zh | grep -q "."; then
        log_message "中文字体已成功安装并配置。"
    else
        error_exit "字体安装失败，请检查包管理器安装过程中的错误信息。"
    fi
}

main "$@"

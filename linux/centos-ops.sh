#!/bin/bash

# Filename: centos-ops.sh
# 功能: CentOS 7+ 系统初始化和安全加固的总控脚本。
#       它调用一系列已独立优化和加固的子脚本来执行各项任务。

set -eo pipefail

# --- 配置 ---
# 子脚本所在的目录，通常与此脚本在同一目录
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- 结束配置 ---

# --- 辅助函数 ---
log_message() { echo -e "\n\033[0;32m[信息] $1\033[0m"; }
warn_message() { echo -e "\n\033[1;33m[警告] $1\033[0m"; }
error_exit() { echo -e "\n\033[0;31m[错误] $1\033[0m" >&2; exit 1; }

# 检查子脚本是否存在且可执行
check_script() {
    local script_path="$SCRIPT_LIB_DIR/$1"
    if [ ! -f "$script_path" ]; then
        error_exit "必需的子脚本 '$1' 未找到: '$script_path'. 请确保所有子脚本都在同一目录下。"
    fi
    if [ ! -x "$script_path" ]; then
        error_exit "子脚本 '$1' 没有执行权限。请运行 'chmod +x $script_path'."
    fi
}

# --- 主菜单逻辑 ---
main_menu() {
    # 确保所有可能用到的子脚本都存在且可执行
    check_script "init_yum.sh"
    check_script "init_security.sh"
    check_script "init_user.sh"
    check_script "init_time.sh"
    check_script "init_kernel.sh"
    check_script "init_audit.sh"
    check_script "install-hosts-font.sh"
    check_script "ssh-exec-remote.sh"

    while true; do
        clear # 清屏，使菜单更清晰
        echo "###############################################################"
        echo "<========================@系统初始化@========================>"
        echo "A -- 配置YUM/DNF源 (调用 init_yum.sh)"
        echo "B -- SSH安全设置 (调用 init_security.sh - SSH部分)"
        echo "C -- 添加系统用户和sudo权限 (调用 init_user.sh)"
        echo "D -- 同步系统时间 (调用 init_time.sh)"
        echo "E -- 优化系统内核参数 (调用 init_kernel.sh)"
        echo "F -- 安装Zabbix工具 (功能待实现)"
        echo "G -- 禁用IPV6 (功能待实现)"
        echo "H -- 修改文件打开数 (功能待实现)"
        echo "I -- 安装常用工具 (功能待实现)"
        echo "J -- 安装常用开发库 (功能待实现)"
        echo "K -- Vim编辑器设置 (功能待实现)"
        echo "L -- 一键初始化安装 (执行所有已实现功能)"
        echo "Q -- 退出"
        echo "------------------------------------------------"
        
        read -n1 -p "请选择一个操作 (A-L, Q): " option
        echo -e "\n您的选择是: $option\n"

        case "$option" in
            A|a) log_message "执行: 配置YUM/DNF源"; "$SCRIPT_LIB_DIR/init_yum.sh" ;;
            B|b) log_message "执行: SSH安全设置"; "$SCRIPT_LIB_DIR/init_security.sh" ;;
            C|c) log_message "执行: 添加系统用户和sudo权限"; "$SCRIPT_LIB_DIR/init_user.sh" ;;
            D|d) log_message "执行: 同步系统时间"; "$SCRIPT_LIB_DIR/init_time.sh" ;;
            E|e) log_message "执行: 优化系统内核参数"; "$SCRIPT_LIB_DIR/init_kernel.sh" ;;
            F|f) warn_message "功能 F (安装Zabbix工具) 尚未实现。"; sleep 2 ;;
            G|g) warn_message "功能 G (禁用IPV6) 尚未实现。"; sleep 2 ;;
            H|h) warn_message "功能 H (修改文件打开数) 尚未实现。"; sleep 2 ;;
            I|i) warn_message "功能 I (安装常用工具) 尚未实现。"; sleep 2 ;;
            J|j) warn_message "功能 J (安装常用开发库) 尚未实现。"; sleep 2 ;;
            K|k) warn_message "功能 K (Vim编辑器设置) 尚未实现。"; sleep 2 ;;
            L|l)
                log_message "执行: 一键初始化安装 (所有已实现功能)"
                "$SCRIPT_LIB_DIR/init_yum.sh"
                "$SCRIPT_LIB_DIR/init_security.sh"
                "$SCRIPT_LIB_DIR/init_user.sh"
                "$SCRIPT_LIB_DIR/init_time.sh"
                "$SCRIPT_LIB_DIR/init_kernel.sh"
                "$SCRIPT_LIB_DIR/init_audit.sh"
                log_message "一键初始化安装完成。"
                ;;
            Q|q) log_message "退出程序。"; exit 0 ;;
            *) warn_message "无效选择，请重新输入。"; sleep 1 ;;
        esac
        read -p "按回车键返回主菜单..."
    done
}

# --- 主程序入口 ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。"
    fi
    main_menu
}

main "$@"
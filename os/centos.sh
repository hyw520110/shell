#!/bin/bash

# Filename: centos.sh
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
        clear
        echo "###############################################################"
        echo "<========================@系统初始化@========================>"
        echo "A -- 设置主机名"
        echo "B -- 配置YUM/DNF源 (调用 init_yum.sh)"
        echo "C -- SSH安全设置 (调用 init_security.sh - SSH部分)"
        echo "D -- 添加系统用户和sudo权限 (调用 init_user.sh)"
        echo "E -- 同步系统时间 (调用 init_time.sh)"
        echo "F -- 优化系统内核参数 (调用 init_kernel.sh)"
        echo "G -- 审计规则设置 (调用 init_audit.sh)"
        echo "H -- 安装常用工具 (功能待实现)"
        echo "I -- 安装常用开发库 (功能待实现)"
        echo "J -- Vim编辑器设置 (功能待实现)"
        echo "K -- 一键初始化安装 (执行所有已实现功能)"
        echo "Q -- 退出"
        echo "------------------------------------------------"
        
        read -n1 -p "请选择一个操作 (A-K, Q): " option
        echo -e "\n您的选择是: $option\n"

        case "$option" in
            A|a) log_message "执行: 设置主机名"; init_hostname ;;
            B|b) log_message "执行: 配置YUM/DNF源"; "$SCRIPT_LIB_DIR/init_yum.sh" ;;
            C|c) log_message "执行: SSH安全设置"; "$SCRIPT_LIB_DIR/init_security.sh" ;;
            D|d) log_message "执行: 添加系统用户和sudo权限"; "$SCRIPT_LIB_DIR/init_user.sh" ;;
            E|e) log_message "执行: 同步系统时间"; "$SCRIPT_LIB_DIR/init_time.sh" ;;
            F|f) log_message "执行: 优化系统内核参数"; "$SCRIPT_LIB_DIR/init_kernel.sh" ;;
            G|g) log_message "执行: 审计规则设置"; "$SCRIPT_LIB_DIR/init_audit.sh" ;;
            H|h) warn_message "功能 H (安装常用工具) 尚未实现。"; sleep 2 ;;
            I|i) warn_message "功能 I (安装常用开发库) 尚未实现。"; sleep 2 ;;
            J|j) warn_message "功能 J (Vim编辑器设置) 尚未实现。"; sleep 2 ;;
            K|k)
                log_message "执行: 一键初始化安装 (所有已实现功能)"
                init_hostname
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

# init_hostname 函数 (这个函数是本脚本独有的，所以保留在这里并优化)
init_hostname() {
    local current_hostname=$(hostname)
    log_message "当前主机名: $current_hostname"
    while true; do
        read -p "请输入您想设定的新主机名 (留空则不修改): " new_name
        if [ -z "$new_name" ]; then
            log_message "未输入新主机名，跳过主机名设置。"
            break
        fi
        # 简单的主机名合法性检查
        if [[ "$new_name" =~ [^a-zA-Z0-9.-] ]]; then
            warn_message "主机名包含非法字符。请使用字母、数字、点或连字符。"
            continue
        fi
        read -p "您确认使用主机名 '$new_name' 吗？[y/n]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
            hostnamectl set-hostname "$new_name"
            log_message "主机名已设置为: $new_name"
            break
        else
            log_message "主机名设置已取消。"
        fi
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

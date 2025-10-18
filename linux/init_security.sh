#!/bin/bash

# 脚本功能：交互式地执行常见的Linux安全加固操作。
# 警告：本脚本将修改关键的系统安全配置，请仔细阅读每一个提示。

set -eo pipefail

# --- 函数定义 ---
log_message() { echo -e "\033[0;32m[信息] $1\033[0m"; } # 绿色
warn_message() { echo -e "\033[1;33m[警告] $1\033[0m"; } # 黄色
error_exit() { echo -e "\033[0;31m[错误] $1\033[0m" >&2; exit 1; } # 红色

# --- 主菜单 ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    echo "这是一个Linux安全初始化工具。请选择要执行的操作："
    select task in "加固SSH服务" "禁用防火墙和SELinux" "退出"; do
        case $task in
            "加固SSH服务")
                harden_ssh
                break
                ;;
            "禁用防火墙和SELinux")
                disable_security_features
                break
                ;;
            "退出")
                echo "未执行任何操作。"
                exit 0
                ;;
            *) 
                echo "无效选项，请重新输入。"
                ;;
        esac
    done
}

# --- 功能实现 ---

harden_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    local new_port="1020"

    log_message "开始加固SSH配置..."
    
    # 备份配置文件
    cp -n "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d)"
    
    # 修改端口（仅当需要时）
    if grep -qE "^#*\s*Port\s+22" "$sshd_config"; then
        log_message "准备将SSH端口从 22 修改为 ${new_port}..."
        sed -i "s/^#*\s*Port\s+22/Port ${new_port}/" "$sshd_config"
    else
        log_message "SSH端口似乎已被修改，跳过。"
    fi

    # 禁用root登录（仅当需要时）
    if grep -qE "^#*\s*PermitRootLogin\s+(yes|prohibit-password)" "$sshd_config"; then
        log_message "准备禁用 root 用户SSH登录..."
        sed -i "s/^#*\s*PermitRootLogin\s+.*/PermitRootLogin no/" "$sshd_config"
    else
        log_message "root用户SSH登录似乎已被禁用，跳过。"
    fi

    # 重启前检查配置语法
    log_message "正在验证sshd配置..."
    if ! sshd -t; then
        error_exit "sshd配置语法错误！请手动检查 ${sshd_config} 文件。"
    fi

    warn_message "SSH服务即将重启！"
    warn_message "您的当前SSH会话可能会中断！"
    warn_message "请确保您知道新的端口号(${new_port})，并且防火墙（如果开启）允许此端口！"
    read -p "您确定要重启SSH服务吗? (输入 'yes' 以确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已由用户取消。"
        exit 0
    fi

    log_message "正在重启sshd服务..."
    systemctl restart sshd
    log_message "sshd服务已重启。请尝试使用新端口连接。"
}

disable_security_features() {
    warn_message "您将要【永久性地禁用】系统防火墙(firewalld)和SELinux！"
    warn_message "这是一个巨大的安全风险，除非您完全了解其后果，否则绝不应在生产环境执行！"
    read -p "您确定要继续吗? (输入 'yes' 以确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已由用户取消。"
        exit 0
    fi

    log_message "正在停止并禁用 firewalld..."
    systemctl stop firewalld
    systemctl disable firewalld

    log_message "正在禁用 SELinux (需要重启系统才能完全生效)..."
    setenforce 0 || warn_message "无法将SELinux设置为宽容模式（可能已禁用）。"
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
    sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
    
    log_message "安全功能已禁用。请注意，SELinux的更改需要【重启系统】才能完全生效。"
}

# 执行主函数
main

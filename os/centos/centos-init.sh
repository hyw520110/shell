#!/bin/bash

# Filename: centos-init.sh
# 功能: CentOS 7+ 系统初始化总控脚本（整合 centos.sh、centos-ops.sh、centos7.sh）
#       提供交互式菜单，调用一系列子脚本执行各项初始化任务

set -eo pipefail

# --- 配置 ---
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/centos-init.log"
BACKUP_DIR="/etc/yum.repos.d/backup"
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

# --- 内置功能函数 ---

# 配置YUM源（内置，不依赖子脚本）
config_yum_builtin() {
    log_message "配置YUM源..."
    mkdir -p "$BACKUP_DIR"
    mv /etc/yum.repos.d/* "$BACKUP_DIR" 2>> "$LOG_FILE" || true
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo >> "$LOG_FILE" 2>&1
    yum -y install epel-release >> "$LOG_FILE" 2>&1
    yum clean all >> "$LOG_FILE" 2>&1
    yum makecache >> "$LOG_FILE" 2>&1
    log_message "YUM源配置完成。"
}

# 关闭防火墙和SELinux（内置）
init_firewall_selinux() {
    log_message "关闭防火墙和SELinux..."
    systemctl stop firewalld
    systemctl disable firewalld >> "$LOG_FILE" 2>&1
    setenforce 0
    sed -i '/^SELINUX=/ s/enforcing/disabled/' /etc/selinux/config
    systemctl enable sshd crond >> "$LOG_FILE" 2>&1
    log_message "防火墙和SELinux已关闭。"
}

# 设置主机名
init_hostname() {
    local current_hostname=$(hostname)
    log_message "当前主机名: $current_hostname"
    while true; do
        read -p "请输入您想设定的新主机名 (留空则不修改): " new_name
        if [ -z "$new_name" ]; then
            log_message "未输入新主机名，跳过主机名设置。"
            break
        fi
        # 主机名合法性检查
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

# --- 主菜单逻辑 ---
main_menu() {
    # 检查子脚本
    local has_yum=false has_security=false has_user=false
    local has_time=false has_kernel=false has_audit=false
    
    [ -f "$SCRIPT_LIB_DIR/init_yum.sh" ] && has_yum=true && check_script "init_yum.sh"
    [ -f "$SCRIPT_LIB_DIR/init_security.sh" ] && has_security=true && check_script "init_security.sh"
    [ -f "$SCRIPT_LIB_DIR/init_user.sh" ] && has_user=true && check_script "init_user.sh"
    [ -f "$SCRIPT_LIB_DIR/init_time.sh" ] && has_time=true && check_script "init_time.sh"
    [ -f "$SCRIPT_LIB_DIR/init_kernel.sh" ] && has_kernel=true && check_script "init_kernel.sh"
    [ -f "$SCRIPT_LIB_DIR/init_audit.sh" ] && has_audit=true && check_script "init_audit.sh"

    while true; do
        clear
        echo "###############################################################"
        echo "<==================== CentOS 系统初始化 ===================>"
        echo "###############################################################"
        echo "A -- 设置主机名"
        [ "$has_yum" = true ] && echo "B -- 配置YUM/DNF源 (内置)"
        [ "$has_security" = true ] && echo "C -- SSH安全设置 (调用 init_security.sh)"
        [ "$has_user" = true ] && echo "D -- 添加系统用户和sudo权限 (调用 init_user.sh)"
        [ "$has_time" = true ] && echo "E -- 同步系统时间 (调用 init_time.sh)"
        [ "$has_kernel" = true ] && echo "F -- 优化系统内核参数 (调用 init_kernel.sh)"
        [ "$has_audit" = true ] && echo "G -- 审计规则设置 (调用 init_audit.sh)"
        echo "H -- 关闭防火墙和SELinux (内置)"
        echo "I -- 安装常用工具 (功能待实现)"
        echo "J -- 安装常用开发库 (功能待实现)"
        echo "K -- Vim编辑器设置 (功能待实现)"
        echo "L -- 一键初始化安装 (执行所有已实现功能)"
        echo "Q -- 退出"
        echo "------------------------------------------------"
        
        read -n1 -p "请选择一个操作 (A-L, Q): " option
        echo -e "\n您的选择是: $option\n"

        case "$option" in
            A|a) log_message "执行: 设置主机名"; init_hostname ;;
            B|b) 
                if [ "$has_yum" = true ]; then
                    log_message "执行: 配置YUM/DNF源"; config_yum_builtin
                else
                    warn_message "子脚本 init_yum.sh 不存在，尝试使用内置功能..."; config_yum_builtin
                fi
                ;;
            C|c) 
                if [ "$has_security" = true ]; then
                    log_message "执行: SSH安全设置"; "$SCRIPT_LIB_DIR/init_security.sh"
                else
                    warn_message "子脚本 init_security.sh 不存在，跳过。"
                fi
                ;;
            D|d) 
                if [ "$has_user" = true ]; then
                    log_message "执行: 添加系统用户和sudo权限"; "$SCRIPT_LIB_DIR/init_user.sh"
                else
                    warn_message "子脚本 init_user.sh 不存在，跳过。"
                fi
                ;;
            E|e) 
                if [ "$has_time" = true ]; then
                    log_message "执行: 同步系统时间"; "$SCRIPT_LIB_DIR/init_time.sh"
                else
                    warn_message "子脚本 init_time.sh 不存在，跳过。"
                fi
                ;;
            F|f) 
                if [ "$has_kernel" = true ]; then
                    log_message "执行: 优化系统内核参数"; "$SCRIPT_LIB_DIR/init_kernel.sh"
                else
                    warn_message "子脚本 init_kernel.sh 不存在，跳过。"
                fi
                ;;
            G|g) 
                if [ "$has_audit" = true ]; then
                    log_message "执行: 审计规则设置"; "$SCRIPT_LIB_DIR/init_audit.sh"
                else
                    warn_message "子脚本 init_audit.sh 不存在，跳过。"
                fi
                ;;
            H|h) log_message "执行: 关闭防火墙和SELinux"; init_firewall_selinux ;;
            I|i) warn_message "功能 I (安装常用工具) 尚未实现。"; sleep 2 ;;
            J|j) warn_message "功能 J (安装常用开发库) 尚未实现。"; sleep 2 ;;
            K|k) warn_message "功能 K (Vim编辑器设置) 尚未实现。"; sleep 2 ;;
            L|l)
                log_message "执行: 一键初始化安装 (所有已实现功能)"
                init_hostname
                config_yum_builtin
                init_firewall_selinux
                [ "$has_security" = true ] && "$SCRIPT_LIB_DIR/init_security.sh"
                [ "$has_user" = true ] && "$SCRIPT_LIB_DIR/init_user.sh"
                [ "$has_time" = true ] && "$SCRIPT_LIB_DIR/init_time.sh"
                [ "$has_kernel" = true ] && "$SCRIPT_LIB_DIR/init_kernel.sh"
                [ "$has_audit" = true ] && "$SCRIPT_LIB_DIR/init_audit.sh"
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
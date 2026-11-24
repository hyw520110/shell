#!/bin/bash

# 脚本功能：交互式地执行安全加固操作（Linux / macOS 双平台支持）。

set -eo pipefail

# --- 平台检测 ---
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}
OS_TYPE="$(detect_os)"

# --- 函数定义 ---
log_message() { echo -e "\033[0;32m[信息] $1\033[0m"; } # 绿色
warn_message() { echo -e "\033[1;33m[警告] $1\033[0m"; } # 黄色
error_exit() { echo -e "\033[0;31m[错误] $1\033[0m" >&2; exit 1; } # 红色

# 通用函数：安全地设置 SSH 配置文件中的 key value
set_sshd_config() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$file" 2>/dev/null; then
        if grep -qE "^[[:space:]]*${key}[[:space:]]+${value}" "$file" 2>/dev/null; then
            log_message "  '$key' 已设置为 '$value'。跳过。"
        else
            log_message "  更新 '$key' 的值为 '$value'。"
            sudo sed -i '' -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file" 2>/dev/null || \
            sudo sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
        fi
    else
        log_message "  向 $file 中添加 '$key $value'。"
        echo "${key} ${value}" | sudo tee -a "$file" >/dev/null
    fi
}

# --- SSH 加固（macOS）---
harden_ssh_macos() {
    local sshd_config="/etc/ssh/sshd_config"
    local new_port="1020"

    log_message "开始加固 SSH 配置 (macOS)..."
    sudo cp -n "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d)" 2>/dev/null || true

    # 修改端口
    if grep -qE "^#*[[:space:]]*Port[[:space:]]+22" "$sshd_config"; then
        log_message "准备将 SSH 端口从 22 修改为 ${new_port}..."
        sudo sed -i '' -E "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${new_port}/" "$sshd_config" 2>/dev/null || \
        sudo sed -i -E "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${new_port}/" "$sshd_config"
    else
        log_message "SSH 端口似乎已被修改，跳过。"
    fi

    # 禁用 root 登录
    set_sshd_config "$sshd_config" "PermitRootLogin" "no"

    # 禁用密码认证（仅允许密钥）
    set_sshd_config "$sshd_config" "PasswordAuthentication" "no"

    # 禁用空密码
    set_sshd_config "$sshd_config" "PermitEmptyPasswords" "no"

    # 日志级别
    set_sshd_config "$sshd_config" "LogLevel" "INFO"

    # 最大认证尝试次数
    set_sshd_config "$sshd_config" "MaxAuthTries" "4"

    # 客户端保活
    set_sshd_config "$sshd_config" "ClientAliveInterval" "900"
    set_sshd_config "$sshd_config" "ClientAliveCountMax" "0"

    log_message "正在验证 sshd 配置..."
    if ! sudo sshd -t; then
        error_exit "sshd 配置语法错误！请手动检查 ${sshd_config} 文件。"
    fi

    warn_message "SSH 服务即将重启！"
    warn_message "您的当前 SSH 会话可能会中断！"
    warn_message "请确保您知道新的端口号 (${new_port})，并且防火墙允许此端口！"
    read -p "您确定要重启 SSH 服务吗? (输入 'yes' 以确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已由用户取消。"
        return 0
    fi

    log_message "正在重启 SSH 服务 (macOS)..."
    sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
    # 如果远程登录在系统设置中启用，还需要：
    sudo systemsetup -setremotelogin off 2>/dev/null || true
    sudo systemsetup -setremotelogin on 2>/dev/null || true
    log_message "SSH 服务已重启。请尝试使用新端口连接。"
}

# --- SSH 加固（Linux）---
harden_ssh_linux() {
    local sshd_config="/etc/ssh/sshd_config"
    local new_port="1020"

    log_message "开始加固 SSH 配置 (Linux)..."
    sudo cp -n "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d)" 2>/dev/null || true

    if grep -qE "^#*[[:space:]]*Port[[:space:]]+22" "$sshd_config"; then
        log_message "准备将 SSH 端口从 22 修改为 ${new_port}..."
        sudo sed -i "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${new_port}/" "$sshd_config"
    else
        log_message "SSH 端口似乎已被修改，跳过。"
    fi

    set_sshd_config "$sshd_config" "PermitRootLogin" "no"
    set_sshd_config "$sshd_config" "PasswordAuthentication" "no"
    set_sshd_config "$sshd_config" "PermitEmptyPasswords" "no"
    set_sshd_config "$sshd_config" "LogLevel" "INFO"
    set_sshd_config "$sshd_config" "MaxAuthTries" "4"
    set_sshd_config "$sshd_config" "ClientAliveInterval" "900"
    set_sshd_config "$sshd_config" "ClientAliveCountMax" "0"

    log_message "正在验证 sshd 配置..."
    if ! sudo sshd -t; then
        error_exit "sshd 配置语法错误！请手动检查 ${sshd_config} 文件。"
    fi

    warn_message "SSH 服务即将重启！"
    warn_message "您的当前 SSH 会话可能会中断！"
    read -p "您确定要重启 SSH 服务吗? (输入 'yes' 以确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已由用户取消。"
        return 0
    fi

    log_message "正在重启 sshd 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart sshd
    else
        sudo service sshd restart 2>/dev/null || sudo /etc/init.d/sshd restart
    fi
    log_message "sshd 服务已重启。"
}

# --- 防火墙配置（macOS pf）---
configure_firewall_macos() {
    log_message "正在配置 macOS 应用防火墙 (alf)..."

    # 启用应用防火墙
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null || {
        warn_message "无法启用应用防火墙。请手动在 系统设置 > 网络 > 防火墙 中开启。"
    }

    # 显示当前状态
    log_message "当前防火墙状态:"
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true

    # pf 包过滤防火墙（更底层）
    local pf_conf="/etc/pf.conf"
    if [ -f "$pf_conf" ]; then
        log_message "当前已加载的 PF 锚点:"
        sudo pfctl -s Anchors 2>/dev/null || true
        warn_message "如需自定义 PF 规则，请编辑 $pf_conf 并执行 'sudo pfctl -f /etc/pf.conf'。"
    fi
}

# --- 防火墙配置（Linux firewalld）---
disable_security_features_linux() {
    warn_message "您将要【永久性地禁用】系统防火墙 (firewalld) 和 SELinux！"
    warn_message "这是一个巨大的安全风险，除非您完全了解其后果，否则绝不应在生产环境执行！"
    read -p "您确定要继续吗? (输入 'yes' 以确认): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已由用户取消。"
        return 0
    fi

    log_message "正在停止并禁用 firewalld..."
    sudo systemctl stop firewalld 2>/dev/null || true
    sudo systemctl disable firewalld 2>/dev/null || true

    log_message "正在禁用 SELinux..."
    if [ -f /etc/selinux/config ]; then
        sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        sudo sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
    fi
    sudo setenforce 0 2>/dev/null || true

    log_message "firewalld 和 SELinux 已禁用。"
}

# --- 一键加固（macOS）---
harden_all_macos() {
    log_message "执行: macOS 一键安全加固"
    harden_ssh_macos
    configure_firewall_macos
    log_message "macOS 一键安全加固完成。"
}

# --- 一键加固（Linux）---
harden_all_linux() {
    log_message "执行: Linux 一键安全加固"
    harden_ssh_linux
    disable_security_features_linux
    log_message "Linux 一键安全加固完成。"
}

# --- 主菜单 ---
main() {
    if [[ "$OS_TYPE" == "unknown" ]]; then
        error_exit "不支持的操作系统: $(uname -s)"
    fi

    log_message "检测到操作系统: $(uname -s) ($OS_TYPE)"

    while true; do
        echo ""
        echo "###############################################################"
        echo "<================ 安全初始化工具 ($OS_TYPE) ================>"
        echo "###############################################################"

        if [[ "$OS_TYPE" == "macos" ]]; then
            echo "1 -- 加固 SSH 服务"
            echo "2 -- 配置 PF 防火墙"
            echo "3 -- 一键加固 (执行所有功能)"
            echo "Q -- 退出"
            echo "------------------------------------------------"
            read -n1 -p "请选择一个操作 (1-3, Q): " option
            echo -e "\n您的选择是: $option\n"

            case "$option" in
                1) harden_ssh_macos ;;
                2) configure_firewall_macos ;;
                3) harden_all_macos ;;
                Q|q) log_message "退出程序。"; exit 0 ;;
                *) warn_message "无效选择，请重新输入。" ;;
            esac
        else
            echo "1 -- 加固 SSH 服务"
            echo "2 -- 禁用防火墙和 SELinux"
            echo "3 -- 一键加固 (执行所有功能)"
            echo "Q -- 退出"
            echo "------------------------------------------------"
            read -n1 -p "请选择一个操作 (1-3, Q): " option
            echo -e "\n您的选择是: $option\n"

            case "$option" in
                1) harden_ssh_linux ;;
                2) disable_security_features_linux ;;
                3) harden_all_linux ;;
                Q|q) log_message "退出程序。"; exit 0 ;;
                *) warn_message "无效选择，请重新输入。" ;;
            esac
        fi
        read -p "按回车键返回主菜单..."
    done
}

main "$@"
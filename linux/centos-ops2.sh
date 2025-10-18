#!/bin/bash

# Filename: centos-ops2.sh
# 功能: 对CentOS 7系统进行安全强化配置。
# 本脚本旨在实现幂等性、模块化和安全性。

set -eo pipefail

# --- 配置 ---
# 密码策略
PASS_MIN_LEN=8
PASS_MAX_DAYS=90
PASS_MIN_DAYS=2
PASS_REMEMBER_COUNT=5 # 强制用户不重用最近5个密码

# SSH设置
SSH_PORT=1020
SSH_MAX_AUTH_TRIES=4
SSH_CLIENT_ALIVE_INTERVAL=900
SSH_CLIENT_ALIVE_COUNT_MAX=0

# 配置文件路径
LOGIN_DEFS="/etc/login.defs"
SSHD_CONFIG="/etc/ssh/sshd_config"
PAM_SYSTEM_AUTH="/etc/pam.d/system-auth"
PAM_PASSWORD_AUTH="/etc/pam.d/password-auth"
PWQUALITY_CONF="/etc/security/pwquality.conf"
# --- 结束配置 ---

# --- 辅助函数 ---
log_message() { echo -e "\n\033[0;32m[信息] $1\033[0m"; }
warn_message() { echo -e "\n\033[1;33m[警告] $1\033[0m"; }
error_exit() { echo -e "\n\033[0;31m[错误] $1\033[0m" >&2; exit 1; }

# 通用函数：安全地设置配置文件中的 key = value
# 检查是否存在，如果存在则更新，不存在则添加
# $1: 文件路径, $2: key, $3: value, $4: (可选) 匹配key的正则表达式
set_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local pattern="${4:-^#*\s*${key}\s*=}" # 默认匹配 key = value 或 #key = value
    
    if grep -qE "$pattern" "$file"; then
        # 键已存在，检查值是否正确
        if grep -qE "$pattern\s*${value}" "$file"; then
            log_message "  '$key' 已在 $file 中正确设置为 '$value'。跳过。"
        else
            log_message "  更新 $file 中 '$key' 的值为 '$value'。"
            sed -i -E "s|${pattern}.*|${key} = ${value}|" "$file"
        fi
    else
        log_message "  向 $file 中添加 '$key' = '$value'。"
        echo "${key} = ${value}" >> "$file" # 简单追加，可能需要更精确的插入点
    fi
}

# --- 安全强化功能函数 ---

# 强化密码策略
harden_password_policy() {
    log_message "正在应用密码策略强化..."
    cp -n "$LOGIN_DEFS" "${LOGIN_DEFS}.bak.$(date +%Y%m%d)" # 备份

    # TMOUT (终端超时) - 添加到 /etc/profile
    if ! grep -q "^TMOUT=" /etc/profile; then
        log_message "  向 /etc/profile 添加 TMOUT。"
        echo "TMOUT=${TMOUT}" >> /etc/profile
    fi

    # login.defs
    set_config_value "$LOGIN_DEFS" "PASS_MAX_DAYS" "$PASS_MAX_DAYS"
    set_config_value "$LOGIN_DEFS" "PASS_MIN_LEN" "$PASS_MIN_LEN"
    set_config_value "$LOGIN_DEFS" "PASS_MIN_DAYS" "$PASS_MIN_DAYS"

    # pwquality.conf (密码质量)
    cp -n "$PWQUALITY_CONF" "${PWQUALITY_CONF}.bak.$(date +%Y%m%d)" # 备份
    set_config_value "$PWQUALITY_CONF" "minlen" "10" "^#*\s*minlen\s*="
    set_config_value "$PWQUALITY_CONF" "minclass" "3" "^#*\s*minclass\s*="

    # PAM 密码历史 (remember=5)
    # 检查并添加 pam_unix.so 的 remember 选项
    local pam_remember_rule="password    sufficient pam_unix.so sha512 shadow remember=${PASS_REMEMBER_COUNT}"
    if ! grep -qF "$pam_remember_rule" "$PAM_PASSWORD_AUTH"; then
        log_message "  向 $PAM_PASSWORD_AUTH 添加密码历史规则。"
        sed -i "/^password\s*sufficient\s*pam_unix.so/ s/$/ remember=${PASS_REMEMBER_COUNT}/
" "$PAM_PASSWORD_AUTH"
    fi
    if ! grep -qF "$pam_remember_rule" "$PAM_SYSTEM_AUTH"; then
        log_message "  向 $PAM_SYSTEM_AUTH 添加密码历史规则。"
        sed -i "/^password\s*sufficient\s*pam_unix.so/ s/$/ remember=${PASS_REMEMBER_COUNT}/
" "$PAM_SYSTEM_AUTH"
    fi
    log_message "密码策略强化完成。"
}

# SSH 强化
harden_ssh() {
    log_message "正在应用SSH强化设置..."
    cp -n "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)" # 备份

    # LogLevel
    set_config_value "$SSHD_CONFIG" "LogLevel" "INFO"
    # ClientAliveInterval
    set_config_value "$SSHD_CONFIG" "ClientAliveInterval" "$SSH_CLIENT_ALIVE_INTERVAL"
    # ClientAliveCountMax
    set_config_value "$SSHD_CONFIG" "ClientAliveCountMax" "$SSH_CLIENT_ALIVE_COUNT_MAX"
    # MaxAuthTries
    set_config_value "$SSHD_CONFIG" "MaxAuthTries" "$SSH_MAX_AUTH_TRIES"
    # PermitEmptyPasswords
    set_config_value "$SSHD_CONFIG" "PermitEmptyPasswords" "no"
    # Protocol 2
    set_config_value "$SSHD_CONFIG" "Protocol" "2"

    # 重启 SSHD
    log_message "正在重启sshd服务..."
    systemctl restart sshd
    log_message "SSH强化设置完成。"
}

# 文件权限强化
harden_file_permissions() {
    log_message "正在应用文件权限强化..."
    chmod 644 /etc/group
    chmod 644 /etc/passwd
    chmod 400 /etc/shadow
    chmod 400 /etc/gshadow
    log_message "文件权限强化完成。"
}

# 启用 ASLR (地址空间布局随机化)
enable_aslr() {
    log_message "正在启用地址空间布局随机化 (ASLR)..."
    sysctl -w kernel.randomize_va_space=2
    # 使设置持久化 (添加到 /etc/sysctl.d/，如果不存在)
    local aslr_conf_file="/etc/sysctl.d/99-aslr.conf"
    if ! grep -q "kernel.randomize_va_space=2" "$aslr_conf_file" 2>/dev/null; then
        echo "kernel.randomize_va_space=2" >> "$aslr_conf_file"
        sysctl -p "$aslr_conf_file"
    else
        log_message "  ASLR 已配置。跳过。"
    fi
    log_message "ASLR 启用完成。"
}

# --- 主程序入口 ---
main() {
    # 初始root权限检查
    if [[ "$(whoami)" != "root" ]]; then
        error_exit "请使用root权限执行此脚本。"
    fi

    # 系统版本检查 (简化版，仅检查是否为CentOS 7)
    if ! grep -q "release 7" /etc/redhat-release; then
        error_exit "当前脚本仅支持CentOS 7系统。"
    fi

    # 调用各项强化功能
    harden_password_policy
    harden_ssh
    harden_file_permissions
    enable_aslr
    # 在这里可以添加其他安全强化功能
    
    log_message "CentOS 7 系统安全强化完成。"
}

# 执行主函数
main "$@"
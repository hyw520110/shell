#!/bin/bash

# 脚本功能：配置并加载自定义的Linux审计规则，用于安全加固。

set -eo pipefail

# --- 配置 ---
# 遵循最佳实践，将自定义规则写入 /etc/audit/rules.d/ 目录下的一个新文件
CUSTOM_RULES_FILE="/etc/audit/rules.d/99-custom-security.rules"
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

main(){
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。请使用 'sudo $0'。"
    fi

    # 2. 检查augenrules命令是否存在
    if ! command -v augenrules &> /dev/null; then
        error_exit "未找到 'augenrules' 命令。请先安装 'auditd' 包。"
    fi

    # 3. 定义要添加的审计规则
    # 使用HEREDOC定义规则块
    read -r -d '' CUSTOM_RULES <<EOF
# --- 由init_audit.sh脚本添加的自定义安全规则 ---

# 监控身份和认证文件的修改
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k logins
-w /etc/security/opasswd -p wa -k logins

# 监控使用sudo等提权执行的命令
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k priv_elevation
EOF

    # 4. 将规则写入自定义规则文件
    log_message "正在将自定义规则写入到 ${CUSTOM_RULES_FILE}..."
    # 这会覆盖我们自己的规则文件，但不会影响其他规则文件
    echo "$CUSTOM_RULES" > "$CUSTOM_RULES_FILE"
    log_message "规则文件写入成功。"

    # 5. 使用augenrules重新加载所有规则
    # augenrules 会自动合并 /etc/audit/rules.d/ 目录下的所有规则文件
    log_message "正在使用 augenrules 重新加载审计规则..."
    if augenrules --load; then
        log_message "审计规则已成功加载到内核。"
    else
        error_exit "加载审计规则失败！请检查系统日志获取详细信息。"
    fi

    # 6. 验证规则是否已生效
    log_message "正在验证规则是否已激活..."
    if auditctl -l | grep -q "priv_elevation"; then
        log_message "验证成功！自定义规则已在运行。"
    else
        log_message "警告：验证失败，自定义规则似乎未被激活。"
    fi
}

main "$@"

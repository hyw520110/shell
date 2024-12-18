#!/bin/bash
# centos7_auto_secure_audit.sh
# 自动化配置CentOS 7的安全设置和审计规则

# 检查是否为root用户运行此脚本
if [[ $EUID -ne 0 ]]; then
   echo "必须以root权限运行此脚本"
   exit 1
fi

log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1"
}

check_and_install() {
    local package=$1
    if ! rpm -q "$package" &> /dev/null; then
        log_info "正在安装$package..."
        yum install -y "$package" || { log_error "无法安装$package"; exit 1; }
    else
        log_info "$package已安装。"
    fi
}

configure_service() {
    local service=$1
    if ! systemctl is-enabled "$service" &> /dev/null; then
        log_info "配置$service服务..."
        check_and_install "$service"
        systemctl start "$service"
        systemctl enable "$service"
    else
        log_info "$service服务已经启动并设置开机自启。"
    fi
}

configure_firewall_rules() {
    firewall-cmd --add-service=ssh --permanent || { log_error "无法添加SSH服务到防火墙规则"; exit 1; }
    firewall-cmd --reload || { log_error "无法重新加载防火墙规则"; exit 1; }
}

configure_audit_rules() {
    local rules_file="/etc/audit/audit.rules"
    local temp_rules_file=$(mktemp)

    cat << EOF > "$temp_rules_file"
-D
-b 8192
-m 2

-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k logins
-w /etc/security/opasswd -p wa -k logins
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k sudolog

## 增加系统日志和历史记录审计
-w /var/log/ -p rwxa -k logfiles
-w /home/ -p rwxa -k homedirs
-w /var/spool/cron/ -p rwxa -k cron
-w /etc/sudoers -p rwxa -k sudoers
-w /var/log/wtmp -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

## 监控特定命令
-a always,exit -F path=/usr/bin/su -F perm=x -k sucmds
-a always,exit -F path=/usr/bin/sudo -F perm=x -k sudocmds

## 记录所有命令的历史记录
-w /etc/bashrc -p wa -k bashhistory
-w /etc/profile -p wa -k bashhistory
EOF

    sort -u "$rules_file" "$temp_rules_file" -o "$temp_rules_file"
    mv "$temp_rules_file" "$rules_file"

    augenrules --load || { log_error "无法加载新的审计规则"; exit 1; }
}

secure_ssh() {
    local ssh_config="/etc/ssh/sshd_config"
    local temp_ssh_config=$(mktemp)

    grep -Ev '^(PermitRootLogin|PasswordAuthentication)' "$ssh_config" > "$temp_ssh_config"
    echo "PermitRootLogin no" >> "$temp_ssh_config"
    echo "PasswordAuthentication no" >> "$temp_ssh_config"
    mv "$temp_ssh_config" "$ssh_config"
    systemctl reload sshd || { log_error "无法重载sshd服务"; exit 1; }
}

configure_log_rotation() {
    local logrotate_conf="/etc/logrotate.d/auditd"
    if [ ! -f "$logrotate_conf" ]; then
        log_info "配置审计日志轮换..."
        cat << EOF > "$logrotate_conf"
/var/log/audit/audit.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF
    fi
}

disable_unnecessary_services() {
    for service in bluetooth cups avahi-daemon; do
        if systemctl is-enabled "$service" &> /dev/null; then
            log_info "禁用$service服务..."
            systemctl disable --now "$service"
        else
            log_info "$service服务未启用。"
        fi
    done
}

install_audispd_plugins() {
    # 安装 audispd-plugins 包
    check_and_install "audit-plugins"

    # 配置 audispd 插件（例如 af_unix）
    local plugin_conf="/etc/audisp/plugins.d/af_unix.conf"
    if [ ! -f "$plugin_conf" ]; then
        log_info "配置 audispd 插件..."
        cat << EOF > "$plugin_conf"
active = yes
direction = out
path = /sbin/audispd
type = builtin
args = 
format = string
EOF
    fi

    # 启用并重启 auditd 服务以应用更改
    systemctl restart auditd
}

main() {
    log_info "开始自动化配置..."

    configure_service "yum-cron"
    configure_service "firewalld"
    configure_service "auditd"

    configure_firewall_rules
    configure_audit_rules
    secure_ssh
    configure_log_rotation
    disable_unnecessary_services
    install_audispd_plugins

    log_info "自动化配置完成！"

    # 提示信息：如何查看当前的审计规则和日志
    echo ""
    log_info "提示: 您可以通过以下命令查看当前的审计规则和日志:"
    log_info "查看当前的审计规则: auditctl -l"
    log_info "查看审计日志: ausearch -i 或 aureport -au"
    log_info "如果需要进一步分析，请考虑使用 audispd-plugins 或其他第三方工具。"
}

main
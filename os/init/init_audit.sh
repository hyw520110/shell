#!/bin/bash

# 脚本功能：配置并加载操作系统审计规则（Linux auditd / macOS OpenBSM 双平台支持）。

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
log_message() { echo "[信息] $1"; }
warn_message() { echo -e "\033[1;33m[警告] $1\033[0m"; }
error_exit() { echo "[错误] $1" >&2; exit 1; }

# --- macOS: OpenBSM 审计 ---
configure_audit_macos() {
    local audit_conf="/etc/security/audit_control"
    local audit_event="/etc/security/audit_event"
    local audit_user="/etc/security/audit_user"
    local praudit_cmd="/usr/sbin/praudit"
    local audit_cmd="/usr/sbin/audit"

    log_message "正在配置 macOS OpenBSM 审计..."

    # 检查 audit 工具是否可用
    if [ ! -x "$audit_cmd" ]; then
        error_exit "未找到 audit 命令。macOS 是否完整安装？"
    fi

    # 备份原配置
    sudo cp -n "$audit_conf" "${audit_conf}.bak.$(date +%Y%m%d)" 2>/dev/null || true

    # 配置 audit_control：设置审计日志保留和策略
    # flags: lo=登录/登出, aa=认证, ad=管理操作, pc=进程创建, ex=程序执行
    # naflags: 不可归属事件的审计类（与 flags 相同）
    # minfree: 最小空闲空间百分比，低于此值暂停审计
    cat <<'EOF' | sudo tee "$audit_conf" >/dev/null
#
# 审计控制文件 — 由 init_audit.sh 配置
#
dir:/var/audit
dist:off
flags:lo,aa,ad,pc,ex
minfree:5
naflags:lo,aa,ad
policy:cnt,argv
filesz:2M
expire-after:10d
EOF

    log_message "audit_control 已更新。"

    # 配置 audit_user：为 root 用户设置始终审计
    sudo cp -n "$audit_user" "${audit_user}.bak.$(date +%Y%m%d)" 2>/dev/null || true
    if ! grep -q '^root:' "$audit_user" 2>/dev/null; then
        echo "root:always:lo,aa,ad,pc,ex" | sudo tee -a "$audit_user" >/dev/null
        log_message "已为 root 用户添加始终审计规则。"
    else
        log_message "root 用户审计规则已存在。"
    fi

    # 重启审计服务
    log_message "正在重启审计服务..."
    if sudo audit -t 2>/dev/null; then
        log_message "审计服务已重启。"
    else
        warn_message "审计服务重启失败，请手动执行: sudo audit -s"
    fi

    # 验证
    log_message "当前审计状态:"
    sudo audit -s 2>/dev/null | head -5 || {
        log_message "无法获取审计状态，尝试启动审计..."
        sudo audit -s 2>/dev/null || true
    }

    log_message "macOS OpenBSM 审计配置完成。"
    echo ""
    log_message "查看审计日志: sudo praudit -l /dev/auditpipe"
    log_message "查看已归档日志: ls -la /var/audit/"
    log_message "查询审计记录: sudo auditreduce /var/audit/ | sudo praudit"
}

# --- Linux: auditd 审计 ---
configure_audit_linux() {
    # --- 配置 ---
    CUSTOM_RULES_FILE="/etc/audit/rules.d/99-custom-security.rules"

    log_message "正在配置 Linux auditd 审计..."

    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以 root 权限运行。请使用 'sudo $0'。"
    fi

    if ! command -v augenrules &>/dev/null; then
        error_exit "未找到 'augenrules' 命令。请先安装 'auditd' 包。"
    fi

    # 定义审计规则
    read -r -d '' CUSTOM_RULES <<'EOF'
# --- 由 init_audit.sh 添加的自定义安全规则 ---

# 监控身份和认证文件的修改
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k logins
-w /etc/security/opasswd -p wa -k logins

# 监控使用 sudo 等提权执行的命令
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k priv_elevation

# 监控 sudoers 文件
-w /etc/sudoers -p rwxa -k sudoers

# 监控 cron 作业
-w /var/spool/cron/ -p rwxa -k cron
EOF

    log_message "正在将自定义规则写入到 ${CUSTOM_RULES_FILE}..."
    echo "$CUSTOM_RULES" | sudo tee "$CUSTOM_RULES_FILE" >/dev/null
    log_message "规则文件写入成功。"

    log_message "正在使用 augenrules 重新加载审计规则..."
    if sudo augenrules --load; then
        log_message "审计规则已成功加载到内核。"
    else
        error_exit "加载审计规则失败！请检查系统日志获取详细信息。"
    fi

    log_message "正在验证规则是否已激活..."
    if sudo auditctl -l | grep -q "priv_elevation"; then
        log_message "验证成功！自定义规则已在运行。"
    else
        warn_message "警告：验证失败，自定义规则似乎未被激活。"
    fi

    log_message "Linux auditd 审计配置完成。"
}

# --- 主逻辑 ---
main() {
    log_message "检测到操作系统: $(uname -s) ($OS_TYPE)"

    case "$OS_TYPE" in
        macos)
            configure_audit_macos
            ;;
        linux)
            configure_audit_linux
            ;;
        *)
            error_exit "不支持的操作系统: $(uname -s)。目前仅支持 Linux 和 macOS。"
            ;;
    esac
}

main "$@"
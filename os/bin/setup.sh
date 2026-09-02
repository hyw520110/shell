#!/bin/bash

# ==============================================================================
# setup.sh — 跨平台服务器安全加固与操作审计 (Linux + macOS)
#
# 统一入口脚本，整合以下模块：
#   init_security.sh  — SSH 加固 + 防火墙
#   init_audit.sh     — 系统审计 (auditd / OpenBSM)
#   init_kernel.sh    — 内核参数 (sysctl)
#   init_user.sh      — 用户与组管理
#
# 用法:
#   bash setup.sh              # 交互式菜单
#   bash setup.sh --all        # 一键执行全部模块
#   bash setup.sh --check      # 仅检测环境，不执行任何变更
#   bash setup.sh -h | --help  # 显示帮助
# ==============================================================================

set -eo pipefail

# ========================== 用户配置区 ==========================
# 以下参数可按需修改，修改后直接运行脚本即可生效

# SSH 加固
SSH_CHANGE_PORT=false   # 是否修改 SSH 端口（风险操作，远程服务器建议保持 false）
SSH_NEW_PORT="1020"
SSH_MAX_AUTH_TRIES="4"
SSH_CLIENT_ALIVE_INTERVAL="900"
SSH_CLIENT_ALIVE_COUNT_MAX="0"

# 用户与组
SECURITY_GROUP_NAME="sa"
SECURITY_GROUP_ID="901"
MACOS_USERS=("admin" "deploy")
LINUX_USERS=("user1" "user2")
SUDO_NOPASSWD=true   # 是否为安全组设置免密 sudo

# ========================== 配置结束 ==========================

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 运行时变量（勿手动修改） ---
OS_TYPE=""
HAS_SUDO=false

# ==============================================================
#                       基础工具函数
# ==============================================================

log_info()  { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1" >&2; }
log_ok()    { echo -e "${GREEN}[完成]${NC} $1"; }
log_skip()  { echo -e "${CYAN}[跳过]${NC} $1"; }

# 关键操作确认（用于 SSH 重启、防火墙变更等不可逆操作）
confirm_action() {
    local msg="$1"
    echo ""
    echo -e "${YELLOW}${BOLD}>>> $msg${NC}"
    read -p "    确认执行？(输入 yes 继续): " _ans
    [[ "${_ans}" == "yes" ]]
}

# 普通确认
confirm_yes_no() {
    local msg="$1"
    read -p "  ${msg} [y/N]: " _ans
    [[ "${_ans}" =~ ^[Yy]$ ]]
}

# 安全备份文件（首次备份，幂等）
safe_backup() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 0
    fi

    # 查找最近的备份文件，比较内容避免重复备份
    local latest_bak
    latest_bak=$(ls -t "${file}.bak."* 2>/dev/null | head -1)

    if [ -n "$latest_bak" ] && [ -f "$latest_bak" ]; then
        # 比较当前文件与最近备份的内容
        if sudo cmp -s "$file" "$latest_bak" 2>/dev/null; then
            return 0
        fi
    fi

    local bak="${file}.bak.$(date +%Y%m%d)"
    if [ -f "$bak" ]; then
        # 同日备份已存在，比较内容
        if sudo cmp -s "$file" "$bak" 2>/dev/null; then
            return 0
        fi
    fi

    sudo cp "$file" "$bak" 2>/dev/null && \
        log_info "已备份: ${file} -> ${bak}" || true
}

# 安全写入 sshd_config 的 key value  (quiet=1 时跳过"已正确"日志)
set_sshd_config() {
    local file="$1" key="$2" value="$3" quiet="${4:-0}"
    if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$file" 2>/dev/null; then
        if grep -qE "^[[:space:]]*${key}[[:space:]]+${value}" "$file" 2>/dev/null; then
            [ "$quiet" != "1" ] && log_skip "'${key}' 已正确设置为 '${value}'"
            return 0
        fi
        log_info "更新 '${key}' -> '${value}'"
        if [ "$OS_TYPE" = "macos" ]; then
            sudo sed -i '' -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file" 2>/dev/null || \
            sudo sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
        else
            sudo sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
        fi
        return 1
    else
        log_info "添加 '${key} ${value}'"
        echo "${key} ${value}" | sudo tee -a "$file" >/dev/null
        return 1
    fi
}

# ==============================================================
#                      平台检测与提权
# ==============================================================

detect_platform() {
    case "$(uname -s)" in
        Darwin) OS_TYPE="macos"  ;;
        Linux)  OS_TYPE="linux"  ;;
        *)      OS_TYPE="unknown";;
    esac
}

# 自动提权：仅在需要时请求 sudo，并维持凭据
ensure_privilege() {
    if [ "$(id -u)" -eq 0 ]; then
        HAS_SUDO=true
        return 0
    fi

    if command -v sudo &>/dev/null && sudo -v 2>/dev/null; then
        HAS_SUDO=true
        # 后台维持 sudo 时间戳，避免反复输入密码
        (while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done) &>/dev/null &
        return 0
    fi

    log_error "此脚本需要 sudo 权限，请确认当前用户在 sudoers 中。"
    exit 1
}

# 环境检测摘要
print_env_summary() {
    echo ""
    echo -e "${BOLD}环境检测结果:${NC}"
    echo -e "  操作系统 : $(uname -s) ${OS_TYPE}"
    echo -e "  主机名   : $(hostname)"
    echo -e "  内核版本 : $(uname -r)"
    echo -e "  当前用户 : $(whoami)"
    echo -e "  sudo     : ${HAS_SUDO}"
    if [ "$OS_TYPE" = "linux" ]; then
        echo -e "  发行版   : $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '\"' || echo '未知')"
        echo -e "  init     : $(command -v systemctl &>/dev/null && echo 'systemd' || echo 'SysV')"
        echo -e "  防火墙   : $(command -v firewall-cmd &>/dev/null && echo 'firewalld' || (command -v ufw &>/dev/null && echo 'ufw' || echo '未检测到'))"
        echo -e "  auditd   : $(command -v auditctl &>/dev/null && echo '已安装' || echo '未安装')"
        echo -e "  SELinux  : $(command -v getenforce &>/dev/null && echo "$(getenforce 2>/dev/null)" || echo 'N/A')"
    elif [ "$OS_TYPE" = "macos" ]; then
        echo -e "  版本     : $(sw_vers 2>/dev/null | tr '\n' ' ' || echo '未知')"
        echo -e "  OpenBSM  : $([ -x /usr/sbin/audit ] && echo '可用' || echo '不可用')"
        echo -e "  pf       : $(command -v pfctl &>/dev/null && echo '可用' || echo '不可用')"
    fi
    echo ""
}

# ==============================================================
#              模块 1: SSH 加固 (init_security)
# ==============================================================

# --- macOS SSH ---
security_ssh_macos() {
    local sshd_config="/etc/ssh/sshd_config"
    local _changed=0
    log_info "===== SSH 加固 (macOS) ====="

    safe_backup "$sshd_config"

    # 修改端口（仅当 SSH_CHANGE_PORT=true 时执行）
    if [ "$SSH_CHANGE_PORT" = true ]; then
        if grep -qE "^#*[[:space:]]*Port[[:space:]]+22" "$sshd_config" 2>/dev/null; then
            log_info "将 SSH 端口从 22 改为 ${SSH_NEW_PORT}"
            sudo sed -i '' -E "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${SSH_NEW_PORT}/" "$sshd_config" 2>/dev/null || \
            sudo sed -i -E "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${SSH_NEW_PORT}/" "$sshd_config"
            _changed=1
        fi
    fi

    set_sshd_config "$sshd_config" "PermitRootLogin"          "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "PasswordAuthentication"   "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "PermitEmptyPasswords"     "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "LogLevel"                 "INFO"           1 || _changed=1
    set_sshd_config "$sshd_config" "MaxAuthTries"             "$SSH_MAX_AUTH_TRIES"       1 || _changed=1
    set_sshd_config "$sshd_config" "ClientAliveInterval"      "$SSH_CLIENT_ALIVE_INTERVAL" 1 || _changed=1
    set_sshd_config "$sshd_config" "ClientAliveCountMax"      "$SSH_CLIENT_ALIVE_COUNT_MAX" 1 || _changed=1

    if [ "$_changed" -eq 0 ]; then
        log_skip "SSH 配置无需变更，已是最新状态"
    else
        log_info "验证 sshd 配置语法..."
        if ! sudo sshd -t 2>/dev/null; then
            log_error "sshd 配置语法错误！请手动检查 ${sshd_config}"
            return 1
        fi
        log_ok "sshd 配置语法检查通过"

        local port_msg="当前端口"
        [ "$SSH_CHANGE_PORT" = true ] && port_msg="新端口: ${SSH_NEW_PORT}"
        if confirm_action "SSH 服务即将重启，当前连接可能中断！${port_msg}"; then
            log_info "重启 SSH 服务 (macOS)..."
            if sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null; then
                log_ok "SSH 已通过 kickstart 重启 (${port_msg})"
            else
                sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
                sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
                log_ok "SSH 已通过 launchctl 重启 (${port_msg})"
            fi
        else
            log_warn "SSH 重启已取消，配置已写入但未生效"
        fi
    fi

    echo ""
    log_info "常用命令:"
    echo "  测试 SSH 连接:     ssh -p $([ "$SSH_CHANGE_PORT" = true ] && echo "$SSH_NEW_PORT" || echo 22) user@$(hostname)"
    echo "  查看当前 SSH 配置:  grep -v '^#' ${sshd_config} | grep -v '^$'"
    echo "  验证配置语法:       sudo sshd -t"
    echo "  重启 SSH 服务:      sudo launchctl kickstart -k system/com.openssh.sshd"
}
security_ssh_linux() {
    local sshd_config="/etc/ssh/sshd_config"
    local _changed=0
    log_info "===== SSH 加固 (Linux) ====="

    safe_backup "$sshd_config"

    # 修改端口（仅当 SSH_CHANGE_PORT=true 时执行）
    if [ "$SSH_CHANGE_PORT" = true ]; then
        if grep -qE "^#*[[:space:]]*Port[[:space:]]+22" "$sshd_config" 2>/dev/null; then
            log_info "将 SSH 端口从 22 改为 ${SSH_NEW_PORT}"
            sudo sed -i -E "s/^#*[[:space:]]*Port[[:space:]]+22/Port ${SSH_NEW_PORT}/" "$sshd_config"
            _changed=1
        fi
    fi

    set_sshd_config "$sshd_config" "PermitRootLogin"          "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "PasswordAuthentication"   "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "PermitEmptyPasswords"     "no"             1 || _changed=1
    set_sshd_config "$sshd_config" "LogLevel"                 "INFO"           1 || _changed=1
    set_sshd_config "$sshd_config" "MaxAuthTries"             "$SSH_MAX_AUTH_TRIES"       1 || _changed=1
    set_sshd_config "$sshd_config" "ClientAliveInterval"      "$SSH_CLIENT_ALIVE_INTERVAL" 1 || _changed=1
    set_sshd_config "$sshd_config" "ClientAliveCountMax"      "$SSH_CLIENT_ALIVE_COUNT_MAX" 1 || _changed=1

    if [ "$_changed" -eq 0 ]; then
        log_skip "SSH 配置无需变更，已是最新状态"
    else
        log_info "验证 sshd 配置语法..."
        if ! sudo sshd -t 2>/dev/null; then
            log_error "sshd 配置语法错误！请手动检查 ${sshd_config}"
            return 1
        fi
        log_ok "sshd 配置语法检查通过"

        local port_msg="当前端口"
        [ "$SSH_CHANGE_PORT" = true ] && port_msg="新端口: ${SSH_NEW_PORT}"
        if confirm_action "SSH 服务即将重启，当前连接可能中断！${port_msg}"; then
            log_info "重启 sshd 服务..."
            if command -v systemctl &>/dev/null; then
                sudo systemctl restart sshd
            else
                sudo service sshd restart 2>/dev/null || sudo /etc/init.d/sshd restart
            fi
            log_ok "sshd 已重启 (${port_msg})"
        else
            log_warn "SSH 重启已取消，配置已写入但未生效"
        fi
    fi

    echo ""
    log_info "常用命令:"
    echo "  测试 SSH 连接:     ssh -p $([ "$SSH_CHANGE_PORT" = true ] && echo "$SSH_NEW_PORT" || echo 22) user@$(hostname)"
    echo "  查看当前 SSH 配置:  grep -v '^#' ${sshd_config} | grep -v '^$'"
    echo "  验证配置语法:       sudo sshd -t"
    echo "  重启 sshd:          sudo systemctl restart sshd"
}

# ==============================================================
#             模块 2: 防火墙 (init_security 续)
# ==============================================================

# --- macOS 防火墙 ---
security_firewall_macos() {
    log_info "===== 防火墙配置 (macOS) ====="

    # ALF (Application Layer Firewall)
    log_info "启用 macOS 应用防火墙 (ALF)..."
    local alf_state
    alf_state=$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")

    if echo "$alf_state" | grep -q "enabled"; then
        log_skip "应用防火墙已启用"
    else
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null || {
            log_warn "无法自动启用 ALF，请前往 系统设置 > 网络 > 防火墙 手动开启"
        }
        log_ok "应用防火墙状态: $(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo '未知')"
    fi

    # pf (Packet Filter)
    if [ -f "/etc/pf.conf" ]; then
        log_info "当前 pf 锚点:"
        sudo pfctl -s Anchors 2>/dev/null || true
        log_warn "如需自定义 pf 规则，请编辑 /etc/pf.conf 并执行 'sudo pfctl -f /etc/pf.conf'"
    fi

    echo ""
    log_info "常用命令:"
    echo "  查看防火墙状态:     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"
    echo "  开启/关闭 ALF:      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on|off"
    echo "  列出已阻止的应用:   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps"
    echo "  允许某个应用:       sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /path/to/app"
    echo "  查看 pf 状态:       sudo pfctl -s info"
    echo "  启用/禁用 pf:       sudo pfctl -e | sudo pfctl -d"
    echo "  加载 pf 规则:       sudo pfctl -f /etc/pf.conf"
    echo "  查看 pf 规则:       sudo pfctl -s rules"
}

# --- Linux 防火墙 ---
security_firewall_linux() {
    log_info "===== 防火墙与 SELinux 配置 (Linux) ====="

    if ! confirm_action "您将要修改 firewalld 和 SELinux 配置，这是高权限操作"; then
        log_warn "防火墙配置已跳过"
        return 0
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null; then
        log_warn "即将禁用 firewalld — 仅限开发/测试环境！生产环境请勿禁用！"
        if confirm_yes_no "确认禁用 firewalld？"; then
            sudo systemctl stop    firewalld 2>/dev/null || true
            sudo systemctl disable firewalld 2>/dev/null || true
            log_ok "firewalld 已停止并禁用"
        fi
    else
        log_skip "未安装 firewalld"
    fi

    # SELinux
    if [ -f /etc/selinux/config ]; then
        log_warn "即将禁用 SELinux — 仅限开发/测试环境！"
        if confirm_yes_no "确认禁用 SELinux？"; then
            sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/'  /etc/selinux/config 2>/dev/null || true
            sudo sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
            sudo setenforce 0 2>/dev/null || true
            log_ok "SELinux 已设为 disabled（重启后完全生效）"
        fi
    else
        log_skip "未安装 SELinux"
    fi

    echo ""
    log_info "常用命令:"
    echo "  重新启用 firewalld:  sudo systemctl enable --now firewalld"
    echo "  开放端口:            sudo firewall-cmd --permanent --add-port=8080/tcp && sudo firewall-cmd --reload"
    echo "  关闭端口:            sudo firewall-cmd --permanent --remove-port=8080/tcp && sudo firewall-cmd --reload"
    echo "  查看开放端口:        sudo firewall-cmd --list-ports"
    echo "  查看防火墙状态:      sudo firewall-cmd --state"
    echo "  ufw 管理:            sudo ufw enable | sudo ufw disable | sudo ufw status"
    echo "  ufw 开放端口:        sudo ufw allow 8080/tcp"
    echo "  SELinux 状态:        getenforce"
    echo "  重新启用 SELinux:    sudo setenforce 1  # 或修改 /etc/selinux/config 后重启"
}

# ==============================================================
#             模块 3: 操作审计 (init_audit)
# ==============================================================

# --- macOS OpenBSM ---
audit_macos() {
    local audit_conf="/etc/security/audit_control"
    local audit_user="/etc/security/audit_user"

    log_info "===== 操作审计 (macOS OpenBSM) ====="

    if [ ! -x "/usr/sbin/audit" ]; then
        log_error "未找到 /usr/sbin/audit，macOS 是否完整安装？"
        return 1
    fi

    safe_backup "$audit_conf"

    # 写入 audit_control
    log_info "配置审计控制参数..."
    cat <<'OPENBSM_CTRL' | sudo tee "$audit_conf" >/dev/null
#
# OpenBSM 审计控制 — 由 setup.sh 配置
#
dir:/var/audit
dist:off
flags:lo,aa,ad,pc,ex
minfree:5
naflags:lo,aa,ad
policy:cnt,argv
filesz:2M
expire-after:10d
OPENBSM_CTRL
    log_ok "audit_control 已更新"

    # 配置 audit_user
    safe_backup "$audit_user"
    if ! grep -q '^root:' "$audit_user" 2>/dev/null; then
        echo "root:always:lo,aa,ad,pc,ex" | sudo tee -a "$audit_user" >/dev/null
        log_ok "已为 root 用户添加始终审计规则"
    else
        log_skip "root 用户审计规则已存在"
    fi

    # 重启审计服务
    # macOS audit 命令说明:
    #   -s  启动/重启审计系统（读取 audit_control 并配置）
    #   -t  终止当前审计会话（关闭日志后重新启动）
    #   首次启用时 auditd 可能未加载，需先通过 launchctl 启用
    log_info "启动审计服务..."

    # 确保 auditd 守护进程已加载
    if ! pgrep -x auditd &>/dev/null; then
        log_info "auditd 未运行，尝试加载..."
        sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.auditd.plist 2>/dev/null || true
        sleep 1
    fi

    # 启动/重启审计系统（读取新配置）
    if sudo audit -s 2>&1; then
        log_ok "审计服务已启动并加载新配置"
    elif sudo audit -t 2>&1; then
        log_ok "审计会话已重新初始化"
    else
        log_warn "审计服务启动失败。可能原因:"
        log_warn "  1. SIP 限制了 auditd（macOS Ventura+ 部分版本）"
        log_warn "  2. 审计子系统未启用"
        log_warn "  请手动检查: sudo audit -s && sudo praudit -l /dev/auditpipe | head -10"
    fi

    # 验证
    sleep 1
    if pgrep -x auditd &>/dev/null; then
        log_ok "auditd 进程已运行 (PID: $(pgrep -x auditd))"
        # 优先从归档日志展示（避免 praudit 读 /dev/auditpipe 无数据时阻塞）
        local _latest_log
        _latest_log=$(ls -t /var/audit/* 2>/dev/null | head -1)
        if [ -n "$_latest_log" ] && [ -f "$_latest_log" ]; then
            log_info "最近审计记录:"
            sudo praudit "$_latest_log" 2>/dev/null | tail -3 || true
        else
            log_info "暂无归档日志，可用: sudo praudit -l /dev/auditpipe"
        fi
    else
        log_warn "auditd 进程未检测到"
    fi

    echo ""
    log_info "常用命令:"
    echo "  实时查看审计流:  sudo praudit -l /dev/auditpipe"
    echo "  查看归档日志:    ls -la /var/audit/"
    echo "  查询审计记录:    sudo auditreduce /var/audit/ | sudo praudit"
    echo ""
    log_info "更多命令:"
    echo "  查看审计系统状态: sudo audit -s"
    echo "  重新初始化审计:   sudo audit -t"
    echo "  搜索特定用户:     sudo auditreduce -u root /var/audit/ | sudo praudit"
    echo "  搜索特定事件:     sudo praudit /var/audit/* | grep -i 'login'"
}

# --- Linux auditd ---
audit_linux() {
    local rules_file="/etc/audit/rules.d/99-custom-security.rules"

    log_info "===== 操作审计 (Linux auditd) ====="

    if ! command -v augenrules &>/dev/null; then
        log_error "未找到 augenrules，请先安装 auditd"
        log_info "安装方法: apt install auditd  或  yum install audit"
        return 1
    fi

    log_info "写入自定义审计规则..."
    cat <<'AUDIT_RULES' | sudo tee "$rules_file" >/dev/null
# --- 由 setup.sh 添加的安全审计规则 ---

# 监控身份和认证文件
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k logins
-w /etc/security/opasswd -p wa -k logins

# 监控提权执行 (sudo 等)
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k priv_elevation

# 监控 sudoers 文件
-w /etc/sudoers -p rwxa -k sudoers

# 监控 cron 作业
-w /var/spool/cron/ -p rwxa -k cron

# 监控日志目录
-w /var/log/ -p rwxa -k logfiles

# 监控用户主目录
-w /home/ -p rwxa -k homedirs

# 监控 su/sudo 命令执行
-a always,exit -F path=/usr/bin/su -F perm=x -k su_cmds
-a always,exit -F path=/usr/bin/sudo -F perm=x -k sudo_cmds

# 监控 shell 配置变更
-w /etc/bashrc -p wa -k shell_config
-w /etc/profile -p wa -k shell_config
AUDIT_RULES
    log_ok "规则文件已写入: ${rules_file}"

    log_info "加载审计规则到内核..."
    if sudo augenrules --load; then
        log_ok "审计规则已成功加载"
    else
        log_error "加载审计规则失败"
        return 1
    fi

    # 验证
    if sudo auditctl -l | grep -q "priv_elevation"; then
        log_ok "验证通过 — 自定义规则已在运行"
    else
        log_warn "验证失败 — 自定义规则可能未激活"
    fi

    echo ""
    log_info "常用命令:"
    echo "  查看规则:  sudo auditctl -l"
    echo "  搜索日志:  sudo ausearch -k priv_elevation"
    echo "  生成报告:  sudo aureport -au"
    echo ""
    log_info "更多命令:"
    echo "  查看审计状态:   sudo auditctl -s"
    echo "  搜索特定用户:   sudo ausearch -ua 1000"
    echo "  查看登录日志:   sudo aureport -l"
    echo "  实时监控审计:   sudo auditctl -m 'test message'"
    echo "  删除所有规则:   sudo auditctl -D  # 慎用"
    echo "  查看规则统计:   sudo auditctl -l -v"
}

# ==============================================================
#            模块 4: 内核参数 (init_kernel)
# ==============================================================

# --- macOS sysctl ---
kernel_macos() {
    local sysctl_conf="/etc/sysctl.conf"

    log_info "===== 内核参数 (macOS sysctl) ====="

    safe_backup "$sysctl_conf"

    cat <<'MACOS_SYSCTL' | sudo tee "$sysctl_conf" >/dev/null
# --- 由 setup.sh 配置的 macOS 安全参数 ---

# 内核安全
kern.sugid_coredump=0
kern.coredump=0

# 网络堆栈安全
net.inet.tcp.blackhole=2          # 丢弃 SYN 到未开放端口
net.inet.udp.blackhole=1          # 丢弃 UDP 到未开放端口
net.inet.icmp.drop_redirect=1     # 拒绝 ICMP 重定向

# 端口范围限制
net.inet.ip.portrange.first=32768
net.inet.ip.portrange.last=65535

# 其他安全加固
net.inet.tcp.always_keepalive=0
net.inet.ip.forwarding=0
net.inet6.ip6.forwarding=0
MACOS_SYSCTL
    log_ok "配置已写入 ${sysctl_conf}"

    # 加载参数
    log_info "应用系统参数..."
    if sudo sysctl -f "$sysctl_conf" 2>/dev/null; then
        log_ok "参数已批量应用"
    else
        # macOS sysctl -f 可能不支持某些参数，逐个应用并跳过只读项
        log_warn "批量加载部分失败，逐个应用..."
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if sudo sysctl "${key}=${value}" 2>/dev/null; then
                log_info "  ${key} = ${value}"
            else
                log_warn "  跳过（不支持或只读）: ${key}"
            fi
        done < <(grep -v '^#' "$sysctl_conf" | grep -v '^[[:space:]]*$')
    fi

    echo ""
    log_info "常用命令:"
    echo "  查看网络参数:       sudo sysctl net.inet.tcp.blackhole net.inet.udp.blackhole"
    echo "  查看所有安全参数:   sudo sysctl -a | grep -E 'kern\\.(sugid_|coredump)|net\\.inet\\.(tcp|udp|icmp)|net\\.inet\\.ip\\.(portrange|forwarding)'"
    echo "  验证配置内容:       cat ${sysctl_conf}"
    echo "  重新应用参数:       sudo sysctl -f ${sysctl_conf}"
    echo "  临时修改参数:       sudo sysctl net.inet.tcp.blackhole=0"
}
kernel_linux() {
    local sysctl_file="/etc/sysctl.d/99-custom-security-tuning.conf"

    log_info "===== 内核参数 (Linux sysctl) ====="

    cat <<'LINUX_SYSCTL' | sudo tee "$sysctl_file" >/dev/null
# --- 由 setup.sh 配置的安全与网络参数 ---

# 安全加固
kernel.randomize_va_space = 2             # ASLR
net.ipv4.tcp_syncookies = 1               # SYN flood 防护
net.ipv4.conf.all.rp_filter = 1           # 反向路径过滤
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0    # 拒绝 ICMP 重定向
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0      # 不发送 ICMP 重定向
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1        # 记录可疑包
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# 网络优化
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
LINUX_SYSCTL
    log_ok "配置已写入 ${sysctl_file}"

    log_info "加载内核参数..."
    if sudo sysctl -p "$sysctl_file"; then
        log_ok "内核参数已成功应用"
    else
        log_error "应用内核参数失败，请检查语法"
        return 1
    fi

    echo ""
    log_info "常用命令:"
    echo "  查看安全参数:       sudo sysctl net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter"
    echo "  查看全部自定义:     cat ${sysctl_file}"
    echo "  重新应用参数:       sudo sysctl -p ${sysctl_file}"
    echo "  验证 ASLR:          cat /proc/sys/kernel/randomize_va_space"
    echo "  临时修改参数:       sudo sysctl -w net.ipv4.tcp_syncookies=0"
    echo "  查看所有网络参数:   sudo sysctl -a | grep -E 'net\\.(ipv4|ipv6)\\.'"
}

# ==============================================================
#          模块 5: 用户与组管理 (init_user)
# ==============================================================

# --- macOS dscl ---
user_macos() {
    log_info "===== 用户与组 (macOS dscl) ====="

    # 创建组
    if ! dscl . -read "/Groups/${SECURITY_GROUP_NAME}" &>/dev/null; then
        log_info "创建用户组 '${SECURITY_GROUP_NAME}' (GID: ${SECURITY_GROUP_ID})..."
        sudo dscl . -create "/Groups/${SECURITY_GROUP_NAME}"
        sudo dscl . -create "/Groups/${SECURITY_GROUP_NAME}" PrimaryGroupID "$SECURITY_GROUP_ID"
        sudo dscl . -create "/Groups/${SECURITY_GROUP_NAME}" RealName "System Administrators"
        sudo dscl . -create "/Groups/${SECURITY_GROUP_NAME}" Password "*"
        log_ok "用户组 '${SECURITY_GROUP_NAME}' 已创建"
    else
        log_skip "用户组 '${SECURITY_GROUP_NAME}' 已存在"
    fi

    # 创建用户
    local uid_start=910
    for user in "${MACOS_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            log_skip "用户 '${user}' 已存在"
            continue
        fi

        # 查找下一个可用 UID
        while dscl . -search /Users UniqueID "$uid_start" 2>/dev/null | grep -q "$uid_start"; do
            uid_start=$((uid_start + 1))
        done

        log_info "创建用户 '${user}' (UID: ${uid_start})..."
        sudo dscl . -create "/Users/${user}"
        sudo dscl . -create "/Users/${user}" UserShell "/bin/zsh"
        sudo dscl . -create "/Users/${user}" RealName "${user}"
        sudo dscl . -create "/Users/${user}" UniqueID "$uid_start"
        sudo dscl . -create "/Users/${user}" PrimaryGroupID "$SECURITY_GROUP_ID"
        sudo dscl . -create "/Users/${user}" NFSHomeDirectory "/Users/${user}"

        sudo mkdir -p "/Users/${user}"
        sudo chown "${uid_start}:${SECURITY_GROUP_ID}" "/Users/${user}"

        # 设置临时密码并强制首次登录修改
        local temp_pw
        temp_pw=$(openssl rand -base64 12 2>/dev/null || echo "ChangeMeNow!")
        sudo dscl . -passwd "/Users/${user}" "$temp_pw" 2>/dev/null || \
            log_warn "无法为 ${user} 设置密码，请手动执行: sudo passwd ${user}"
        sudo pwpolicy -u "$user" -setpolicy "newPasswordRequired=1" 2>/dev/null || \
            log_warn "无法设置密码策略，请手动执行: sudo pwpolicy -u ${user} -setpolicy 'newPasswordRequired=1'"

        log_ok "用户 '${user}' 已创建 (UID: ${uid_start})"
        uid_start=$((uid_start + 1))
    done

    # sudo 权限
    _configure_sudo_macos

    echo ""
    log_info "常用命令:"
    echo "  查看组成员:         dscl . -read /Groups/${SECURITY_GROUP_NAME} GroupMembership"
    echo "  查看用户详情:       dscl . -read /Users/admin"
    echo "  列出系统用户:       dscl . -list /Users UniqueID | sort -nk2"
    echo "  查看 sudo 规则:     sudo cat /private/etc/sudoers.d/90-${SECURITY_GROUP_NAME}-privileges"
    echo "  修改用户密码:       sudo passwd admin"
    echo "  删除用户:           sudo dscl . -delete /Users/username"
}

_configure_sudo_macos() {
    local sudo_file="/private/etc/sudoers.d/90-${SECURITY_GROUP_NAME}-privileges"
    if [ "$SUDO_NOPASSWD" = true ]; then
        local sudo_rule="%${SECURITY_GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"
    else
        local sudo_rule="%${SECURITY_GROUP_NAME} ALL=(ALL) ALL"
    fi

    if [ -f "$sudo_file" ] && grep -qFx -- "$sudo_rule" "$sudo_file" 2>/dev/null; then
        log_skip "sudo 规则已存在"
        return 0
    fi

    log_info "配置 sudo 权限 (组: ${SECURITY_GROUP_NAME})..."
    echo "$sudo_rule" | sudo tee "$sudo_file" >/dev/null
    sudo chmod 440 "$sudo_file"
    log_ok "sudo 规则已创建: ${sudo_file}"
}

# --- Linux useradd/groupadd ---
user_linux() {
    log_info "===== 用户与组 (Linux useradd) ====="

    if [ "$(id -u)" -ne 0 ]; then
        # 非 root 时通过 sudo 执行
        log_warn "用户管理需要 root 权限，将使用 sudo"
    fi

    # 创建组
    if ! getent group "$SECURITY_GROUP_NAME" &>/dev/null; then
        log_info "创建用户组 '${SECURITY_GROUP_NAME}' (GID: ${SECURITY_GROUP_ID})..."
        sudo groupadd -g "$SECURITY_GROUP_ID" "$SECURITY_GROUP_NAME"
        log_ok "用户组 '${SECURITY_GROUP_NAME}' 已创建"
    else
        log_skip "用户组 '${SECURITY_GROUP_NAME}' 已存在"
    fi

    # 创建用户
    local uid_start=910
    for user in "${LINUX_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            log_skip "用户 '${user}' 已存在"
            continue
        fi

        log_info "创建用户 '${user}' (UID: ${uid_start})..."
        sudo useradd -g "$SECURITY_GROUP_NAME" -u "$uid_start" -m -s /bin/bash "$user"
        sudo chage -d 0 "$user"
        log_ok "用户 '${user}' 已创建，首次登录需修改密码"
        uid_start=$((uid_start + 1))
    done

    # sudo 权限
    _configure_sudo_linux

    echo ""
    log_info "常用命令:"
    echo "  查看组成员:         getent group ${SECURITY_GROUP_NAME}"
    echo "  查看用户详情:       id user1 && getent passwd user1"
    echo "  查看 sudo 规则:     sudo cat /etc/sudoers.d/90-${SECURITY_GROUP_NAME}-privileges"
    echo "  修改用户密码:       sudo passwd user1"
    echo "  锁定/解锁用户:      sudo usermod -L user1 | sudo usermod -U user1"
    echo "  删除用户(保留目录): sudo userdel user1"
}

_configure_sudo_linux() {
    local sudo_file="/etc/sudoers.d/90-${SECURITY_GROUP_NAME}-privileges"
    if [ "$SUDO_NOPASSWD" = true ]; then
        local sudo_rule="%${SECURITY_GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"
    else
        local sudo_rule="%${SECURITY_GROUP_NAME} ALL=(ALL) ALL"
    fi

    if [ -f "$sudo_file" ] && grep -qFx -- "$sudo_rule" "$sudo_file" 2>/dev/null; then
        log_skip "sudo 规则已存在"
        return 0
    fi

    log_info "配置 sudo 权限 (组: ${SECURITY_GROUP_NAME})..."
    echo "$sudo_rule" | sudo tee "$sudo_file" >/dev/null
    sudo chmod 440 "$sudo_file"
    log_ok "sudo 规则已创建: ${sudo_file}"
}

# ==============================================================
#                    一键执行所有模块
# ==============================================================

run_all_modules() {
    echo ""
    echo -e "${BOLD}${BLUE}==========================================${NC}"
    echo -e "${BOLD}${BLUE}  一键安全加固与审计配置 — ${OS_TYPE}${NC}"
    echo -e "${BOLD}${BLUE}==========================================${NC}"
    echo ""

    # 展示将要执行的步骤
    echo -e "即将执行以下模块:"
    echo -e "  ${CYAN}1.${NC} SSH 服务加固"
    echo -e "  ${CYAN}2.${NC} 防火墙配置"
    echo -e "  ${CYAN}3.${NC} 操作审计配置"
    echo -e "  ${CYAN}4.${NC} 内核安全参数"
    echo -e "  ${CYAN}5.${NC} 用户与组管理"
    echo ""

    if ! confirm_action "确认执行全部模块？（关键操作仍会逐一确认）"; then
        log_warn "已取消"
        return 0
    fi

    echo ""
    echo -e "${BOLD}>>> [1/5] SSH 加固${NC}"
    if [ "$OS_TYPE" = "macos" ]; then security_ssh_macos; else security_ssh_linux; fi
    echo ""

    echo -e "${BOLD}>>> [2/5] 防火墙${NC}"
    if [ "$OS_TYPE" = "macos" ]; then security_firewall_macos; else security_firewall_linux; fi
    echo ""

    echo -e "${BOLD}>>> [3/5] 操作审计${NC}"
    if [ "$OS_TYPE" = "macos" ]; then audit_macos; else audit_linux; fi
    echo ""

    echo -e "${BOLD}>>> [4/5] 内核参数${NC}"
    if [ "$OS_TYPE" = "macos" ]; then kernel_macos; else kernel_linux; fi
    echo ""

    echo -e "${BOLD}>>> [5/5] 用户与组${NC}"
    if confirm_yes_no "是否创建安全管理用户和组？（如不需要可跳过）"; then
        if [ "$OS_TYPE" = "macos" ]; then user_macos; else user_linux; fi
    else
        log_skip "用户管理已跳过"
    fi
    echo ""

    echo -e "${BOLD}${GREEN}==========================================${NC}"
    echo -e "${BOLD}${GREEN}  全部模块执行完毕${NC}"
    echo -e "${BOLD}${GREEN}==========================================${NC}"
    echo ""
    _print_post_checklist
}

# 执行后检查清单
_print_post_checklist() {
    local ssh_port="22"
    [ "$SSH_CHANGE_PORT" = true ] && ssh_port="$SSH_NEW_PORT"
    echo -e "${BOLD}后续检查:${NC}"
    if [ "$OS_TYPE" = "macos" ]; then
        echo "  1. 测试 SSH 连接:  ssh -p ${ssh_port} user@$(hostname)"
        echo "  2. 查看审计事件:   sudo praudit -l /dev/auditpipe | tail -20"
        echo "                     sudo audit -s  # 查看审计系统状态"
        echo "  3. 查看系统参数:   sudo sysctl -a | grep 'net.inet'"
        echo "  4. 确认防火墙:     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"
    else
        echo "  1. 测试 SSH 连接:  ssh -p ${ssh_port} user@$(hostname)"
        echo "  2. 查看审计规则:   sudo auditctl -l"
        echo "  查看审计日志:     sudo ausearch -m ALL -ts recent | head -30"
        echo "  查看内核参数:   sudo sysctl -p /etc/sysctl.d/99-custom-security-tuning.conf"
        echo "  确认防火墙:     sudo firewall-cmd --state 或 sudo ufw status"
        echo "  开放端口示例:   sudo firewall-cmd --permanent --add-port=8080/tcp && sudo firewall-cmd --reload"
    fi
}

# ==============================================================
#                     主菜单 / CLI 入口
# ==============================================================

show_help() {
    echo "用法: bash setup.sh [选项]"
    echo ""
    echo "选项:"
    echo "  (无参数)     交互式菜单"
    echo "  --all        一键执行全部安全模块"
    echo "  --check      仅检测环境，不执行变更"
    echo "  -h, --help   显示此帮助"
    echo ""
    echo "脚本位置: os/setup.sh"
    echo "配置参数: 编辑脚本顶部「用户配置区」"
}

print_banner() {
    echo -e "${GREEN}${BOLD}"
    cat << 'BANNER'
 ╔═══════════════════════════════════════════════════════════╗
 ║         跨平台服务器安全加固与操作审计工具                ║
 ║              Linux + macOS  Unified Setup                ║
 ╚═══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

main() {
    # CLI 参数处理
    case "${1:-}" in
        -h|--help)   show_help; exit 0;;
        --check)
            detect_platform
            if [ "$OS_TYPE" = "unknown" ]; then
                log_error "不支持的操作系统: $(uname -s)"
                exit 1
            fi
            print_env_summary
            echo -e "${BOLD}各模块状态:${NC}"
            if [ "$OS_TYPE" = "macos" ]; then
                echo "  SSH 加固  : $([ -f /etc/ssh/sshd_config ] && echo '可执行' || echo '配置不存在')"
                echo "  防火墙    : $([ -x /usr/libexec/ApplicationFirewall/socketfilterfw ] && echo 'ALF 可用' || echo 'ALF 不可用')"
                echo "  操作审计  : $([ -x /usr/sbin/audit ] && echo 'OpenBSM 可用' || echo 'OpenBSM 不可用')"
                echo "  内核参数  : $(command -v sysctl &>/dev/null && echo '可用' || echo '不可用')"
                echo "  用户管理  : $(command -v dscl &>/dev/null && echo 'dscl 可用' || echo 'dscl 不可用')"
            else
                echo "  SSH 加固  : $([ -f /etc/ssh/sshd_config ] && echo '可执行' || echo '配置不存在')"
                echo "  防火墙    : $(command -v firewall-cmd &>/dev/null && echo 'firewalld' || (command -v ufw &>/dev/null && echo 'ufw' || echo '未安装'))"
                echo "  操作审计  : $(command -v augenrules &>/dev/null && echo 'auditd 已安装' || echo 'auditd 未安装')"
                echo "  内核参数  : $(command -v sysctl &>/dev/null && echo '可用' || echo '不可用')"
                echo "  用户管理  : $(command -v useradd &>/dev/null && echo '可用' || echo '不可用')"
            fi
            exit 0
            ;;
        --all)
            detect_platform
            if [ "$OS_TYPE" = "unknown" ]; then
                log_error "不支持的操作系统: $(uname -s)"
                exit 1
            fi
            ensure_privilege
            print_env_summary
            run_all_modules
            exit 0
            ;;
    esac

    # 交互式模式
    detect_platform
    if [ "$OS_TYPE" = "unknown" ]; then
        log_error "不支持的操作系统: $(uname -s)"
        exit 1
    fi

    ensure_privilege
    print_banner
    print_env_summary

    while true; do
        echo ""
        echo -e "${BOLD}###############################################################${NC}"
        echo -e "${BOLD}  安全加固与审计配置 (${OS_TYPE} — $(hostname))${NC}"
        echo -e "${BOLD}###############################################################${NC}"
        echo ""
        echo -e "  ${CYAN}1${NC} -- SSH 服务加固"
        echo -e "  ${CYAN}2${NC} -- 防火墙配置"
        echo -e "  ${CYAN}3${NC} -- 操作审计配置"
        echo -e "  ${CYAN}4${NC} -- 内核安全参数"
        echo -e "  ${CYAN}5${NC} -- 用户与组管理"
        echo -e "  ${CYAN}6${NC} -- ${BOLD}一键执行全部${NC}"
        echo -e "  ${CYAN}C${NC} -- 仅检测环境 (不变更)"
        echo -e "  ${CYAN}Q${NC} -- 退出"
        echo ""
        echo -e "  ${BOLD}------------------------------------------------${NC}"

        read -n1 -p "  请选择操作 (1-6, C, Q): " option
        echo -e "\n"

        case "$option" in
            1)
                if [ "$OS_TYPE" = "macos" ]; then security_ssh_macos; else security_ssh_linux; fi
                ;;
            2)
                if [ "$OS_TYPE" = "macos" ]; then security_firewall_macos; else security_firewall_linux; fi
                ;;
            3)
                if [ "$OS_TYPE" = "macos" ]; then audit_macos; else audit_linux; fi
                ;;
            4)
                if [ "$OS_TYPE" = "macos" ]; then kernel_macos; else kernel_linux; fi
                ;;
            5)
                if [ "$OS_TYPE" = "macos" ]; then user_macos; else user_linux; fi
                ;;
            6)
                run_all_modules
                ;;
            C|c)
                print_env_summary
                ;;
            Q|q)
                log_info "退出。"
                exit 0
                ;;
            *)
                log_warn "无效选择，请重新输入"
                ;;
        esac

        echo ""
        read -p "按回车键返回主菜单..."
    done
}

main "$@"

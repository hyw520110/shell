#!/bin/bash

# 脚本功能：应用内核/系统参数优化（Linux sysctl / macOS sysctl 双平台支持）。

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

# --- macOS: sysctl 安全参数 ---
configure_kernel_macos() {
    local macos_conf="/etc/sysctl.conf"

    log_message "正在配置 macOS 系统安全参数..."

    # macOS 安全相关的 sysctl 参数
    # 注意：macOS 不使用 /etc/sysctl.d/，而是 /etc/sysctl.conf
    sudo cp -n "$macos_conf" "${macos_conf}.bak.$(date +%Y%m%d)" 2>/dev/null || true

    read -r -d '' MACOS_SETTINGS <<'EOF'
# --- 由 init_kernel.sh 配置的 macOS 安全参数 ---

# 内核安全
kern.sugid_coredump=0
kern.coredump=0

# ASLR (地址空间布局随机化) — macOS 默认已启用
# kern.securelevel=1  # 需要谨慎使用，可能影响某些功能

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
EOF

    log_message "正在将安全参数写入 $macos_conf ..."
    echo "$MACOS_SETTINGS" | sudo tee "$macos_conf" >/dev/null
    log_message "配置文件写入成功。"

    log_message "正在加载新的系统参数..."
    if sudo sysctl -f "$macos_conf" 2>/dev/null; then
        log_message "系统参数已成功应用。"
    else
        # macOS 的 sysctl -f 行为不同于 Linux 的 sysctl -p，逐个加载
        warn_message "批量加载失败，尝试逐个应用参数..."
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if sudo sysctl "$key=$value" 2>/dev/null; then
                log_message "  $key = $value ✓"
            else
                warn_message "  跳过（不支持或只读）: $key"
            fi
        done < <(grep -v '^#' "$macos_conf" | grep -v '^[[:space:]]*$')
    fi

    log_message "macOS 系统参数配置完成。"
}

# --- Linux: sysctl 内核参数 ---
configure_kernel_linux() {
    CUSTOM_SYSCTL_FILE="/etc/sysctl.d/99-custom-network-tuning.conf"

    read -r -d '' KERNEL_SETTINGS <<'EOF'
# --- 由 init_kernel.sh 配置的网络优化参数 ---
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# --- 安全加固 ---
kernel.randomize_va_space = 2           # ASLR
net.ipv4.tcp_syncookies = 1             # SYN flood 防护
net.ipv4.conf.all.rp_filter = 1         # 反向路径过滤
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0  # 拒绝 ICMP 重定向
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0    # 不发送 ICMP 重定向
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1      # 记录可疑包
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF

    log_message "正在配置 Linux 内核参数..."

    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以 root 权限运行。请使用 'sudo $0'。"
    fi

    if echo "$KERNEL_SETTINGS" | sudo tee "$CUSTOM_SYSCTL_FILE" >/dev/null; then
        log_message "配置已成功写入到 $CUSTOM_SYSCTL_FILE"
    else
        error_exit "写入配置文件失败！"
    fi

    log_message "正在加载新的内核参数..."
    if sudo sysctl -p "$CUSTOM_SYSCTL_FILE"; then
        log_message "内核参数已成功应用。"
    else
        error_exit "应用内核参数失败！请检查配置是否存在语法错误。"
    fi

    log_message "Linux 内核参数优化完成。"
}

# --- 主逻辑 ---
main() {
    log_message "检测到操作系统: $(uname -s) ($OS_TYPE)"

    case "$OS_TYPE" in
        macos)
            configure_kernel_macos
            ;;
        linux)
            configure_kernel_linux
            ;;
        *)
            error_exit "不支持的操作系统: $(uname -s)。目前仅支持 Linux 和 macOS。"
            ;;
    esac
}

main "$@"
#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "当前不是 root 用户，尝试使用 sudo 提权..." >&2
    if command -v sudo &> /dev/null; then
        exec sudo "$0" "$@"
        exit
    else
        echo "错误：请使用 root 用户或具有 sudo 权限的用户运行此脚本。" >&2
        exit 1
    fi
fi

readonly TARGET_CONF="/etc/sysctl.d/99-tcp-tune.conf"
readonly TEST_URL="http://speedtest.tele2.net/10MB.zip"
readonly LOG_DIR="/var/log/tcp-tune"
readonly LOG_FILE="${LOG_DIR}/results.log"

show_help() {
    cat << EOF
TCP 参数优化脚本 - Linux 网络参数优化与 BBR 集成工具

用法: $0 [选项]

选项:
    -h, --help          显示帮助信息
    -n, --no-compare    跳过优化前后对比测试
    -f, --force         强制应用配置，不进行对比测试
    --check-bbr         仅检测 BBR 状态
    --install-bbr       仅安装/配置 BBR
    --verify-bbr        仅验证 BBR 是否生效

EOF
}

is_linux() {
    [ "$(uname)" = "Linux" ]
}

check_dependencies() {
    local missing=()
    for cmd in bc curl sysctl; do
        if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺少依赖工具: ${missing[*]}" >&2
        if is_linux; then
            if command -v dnf &>/dev/null; then
                dnf install -y "${missing[@]}"
            elif command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y "${missing[@]}"
            elif command -v yum &>/dev/null; then
                yum install -y "${missing[@]}"
            fi
        fi
        for cmd in "${missing[@]}"; do
            if ! command -v "$cmd" &>/dev/null; then
                echo "安装 $cmd 失败" >&2
                exit 1
            fi
        done
    fi
    echo "✅ 依赖检查通过"
}

check_kernel_bbr_support() {
    echo "【BBR 内核支持检测】"
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    local major
    local minor
    major=$(echo "$kernel_version" | cut -d'.' -f1)
    minor=$(echo "$kernel_version" | cut -d'.' -f2)
    
    echo "  内核版本: $kernel_version"
    
    if [ "$major" -gt 4 ] || ([ "$major" -eq 4 ] && [ "$minor" -ge 9 ]); then
        echo "  ✅ 内核版本满足 BBR 要求 (>= 4.9)"
    else
        echo "  ❌ 内核版本过低，不支持 BBR"
        echo "     建议升级内核到 4.9 或更高版本"
        return 1
    fi
    
    local available_algos
    available_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if echo "$available_algos" | grep -q "bbr"; then
        echo "  ✅ BBR 算法已在内核中可用"
    else
        echo "  ❌ BBR 算法在内核中不可用"
        return 1
    fi
    
    local qdisc_available
    qdisc_available=$(ls /sys/class/net/*/qdisc 2>/dev/null | head -1)
    if [ -n "$qdisc_available" ]; then
        echo "  ✅ 队列规则 (qdisc) 支持"
    else
        echo "  ⚠️ 队列规则检测异常，可能需要检查"
    fi
    
    echo ""
    return 0
}

check_current_bbr_status() {
    echo "【当前 BBR 状态】"
    
    local current_congestion
    current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    local current_qdisc
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    
    printf "  %-40s %s\n" "当前拥塞控制算法:" "$current_congestion"
    printf "  %-40s %s\n" "当前队列规则:" "$current_qdisc"
    
    local bbr_enabled=0
    if [ "$current_congestion" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
        echo ""
        echo "  ✅ BBR 已正确配置并生效"
        bbr_enabled=1
    elif [ "$current_congestion" = "bbr" ]; then
        echo ""
        echo "  ⚠️ BBR 拥塞控制已启用，但队列规则不是 fq"
        echo "     建议设置 net.core.default_qdisc = fq"
    elif [ "$current_qdisc" = "fq" ]; then
        echo ""
        echo "  ⚠️ fq 队列规则已启用，但拥塞控制不是 BBR"
        echo "     建议设置 net.ipv4.tcp_congestion_control = bbr"
    else
        echo ""
        echo "  ❌ BBR 未启用"
    fi
    
    echo ""
    return $bbr_enabled
}

install_bbr() {
    echo "【安装/配置 BBR】"
    
    if ! check_kernel_bbr_support; then
        echo "  ❌ 无法安装 BBR，内核不支持"
        return 1
    fi
    
    if [ -f "$TARGET_CONF" ]; then
        local timestamp
        timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_file="${TARGET_CONF}.bak.${timestamp}"
        cp "$TARGET_CONF" "$backup_file"
        echo "  ✅ 已备份原配置: $backup_file"
    fi
    
    cat > "$TARGET_CONF" << 'EOF'
# TCP 参数优化配置 - 自动生成 (BBR 优化)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    
    echo "  ✅ BBR 配置已写入: $TARGET_CONF"
    
    if sysctl -p "$TARGET_CONF" > /dev/null 2>&1; then
        echo "  ✅ 配置已应用到系统"
    else
        echo "  ⚠️ 配置应用失败，尝试单独设置..."
        sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
        echo "  ✅ BBR 核心参数已设置"
    fi
    
    echo ""
    return 0
}

verify_bbr() {
    echo "【验证 BBR 生效】"
    
    local verify_passed=1
    
    local congestion
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$congestion" = "bbr" ]; then
        echo "  ✅ net.ipv4.tcp_congestion_control = bbr"
    else
        echo "  ❌ net.ipv4.tcp_congestion_control != bbr (当前: $congestion)"
        verify_passed=0
    fi
    
    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$qdisc" = "fq" ]; then
        echo "  ✅ net.core.default_qdisc = fq"
    else
        echo "  ❌ net.core.default_qdisc != fq (当前: $qdisc)"
        verify_passed=0
    fi
    
    local conf_exists=0
    if [ -f "$TARGET_CONF" ]; then
        if grep -q "net.ipv4.tcp_congestion_control = bbr" "$TARGET_CONF" && \
           grep -q "net.core.default_qdisc = fq" "$TARGET_CONF"; then
            echo "  ✅ 配置文件持久化正确"
            conf_exists=1
        else
            echo "  ⚠️ 配置文件内容不完整"
        fi
    else
        echo "  ⚠️ 配置文件不存在，重启后 BBR 可能失效"
    fi
    
    echo ""
    if [ "$verify_passed" -eq 1 ] && [ "$conf_exists" -eq 1 ]; then
        echo "✅ BBR 验证通过，已正确配置并持久化"
        return 0
    elif [ "$verify_passed" -eq 1 ]; then
        echo "⚠️ BBR 当前生效，但重启后可能失效，建议创建配置文件"
        return 1
    else
        echo "❌ BBR 验证失败"
        return 2
    fi
}

check_network_restart_required() {
    echo "【网络服务状态检查】"
    
    local restart_required=0
    
    if command -v systemctl &>/dev/null; then
        local network_services=("NetworkManager" "network" "systemd-networkd")
        for service in "${network_services[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                echo "  检测到网络服务: $service"
            fi
        done
    fi
    
    if [ -f /proc/sys/net/core/default_qdisc ]; then
        local current_qdisc=$(sysctl -n net.core.default_qdisc)
        local conf_qdisc=$(grep "^net.core.default_qdisc" "$TARGET_CONF" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
        if [ "$current_qdisc" != "$conf_qdisc" ] && [ -n "$conf_qdisc" ]; then
            restart_required=1
        fi
    fi
    
    echo ""
    if [ "$restart_required" -eq 1 ]; then
        echo "⚠️ 建议重启网络服务或系统以确保所有参数完全生效"
        echo ""
        read -p "是否现在重启网络服务？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restart_network_services
        fi
    else
        echo "✅ 网络服务状态正常，无需重启"
    fi
    echo ""
}

restart_network_services() {
    echo ""
    echo "【重启网络服务】"
    
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "  重启 NetworkManager..."
            systemctl restart NetworkManager
            echo "  ✅ NetworkManager 已重启"
        elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            echo "  重启 systemd-networkd..."
            systemctl restart systemd-networkd
            echo "  ✅ systemd-networkd 已重启"
        elif systemctl is-active --quiet network 2>/dev/null; then
            echo "  重启 network..."
            systemctl restart network
            echo "  ✅ network 已重启"
        else
            echo "  ⚠️ 未检测到已知的网络服务，建议手动重启或重启系统"
        fi
    elif command -v service &>/dev/null; then
        if service network status &>/dev/null; then
            echo "  重启 network..."
            service network restart
            echo "  ✅ network 已重启"
        else
            echo "  ⚠️ 未检测到已知的网络服务，建议手动重启或重启系统"
        fi
    else
        echo "  ⚠️ 未检测到系统服务管理器，建议手动重启网络或重启系统"
    fi
    echo ""
}

detect_os() {
    echo "=========================================================="
    echo "        Linux 网络参数优化脚本"
    echo "=========================================================="
    echo ""
    echo "【系统环境检测】"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "  操作系统: $NAME $VERSION_ID"
    fi
    echo "  内核版本: $(uname -r)"
    echo "  架构: $(uname -m)"
    echo "  主机名: $(hostname)"
    echo "  运行时间: $(uptime -p 2>/dev/null || uptime)"
    echo ""
}

get_current_config() {
    rmem_max=$(sysctl -n net.core.rmem_max)
    wmem_max=$(sysctl -n net.core.wmem_max)
    tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem)
    tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem)
    qdisc=$(sysctl -n net.core.default_qdisc)
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
}

output_config() {
    echo "【当前网络参数】"
    printf "  %-40s %s\n" "net.core.rmem_max" "$rmem_max"
    printf "  %-40s %s\n" "net.core.wmem_max" "$wmem_max"
    printf "  %-40s %s\n" "net.ipv4.tcp_rmem" "$tcp_rmem"
    printf "  %-40s %s\n" "net.ipv4.tcp_wmem" "$tcp_wmem"
    printf "  %-40s %s\n" "net.core.default_qdisc" "$qdisc"
    printf "  %-40s %s\n" "net.ipv4.tcp_congestion_control" "$congestion"
    echo ""
}

speed_test() {
    local label="$1"
    echo "  正在测速 ($label)..."
    local result
    result=$(curl -o /dev/null -s -w "%{speed_download}" "$TEST_URL" 2>/dev/null)
    
    if [ -n "$result" ] && [ "$result" != "0" ] && [ "$result" != "0.0" ]; then
        local speed_mbps
        speed_mbps=$(echo "scale=2; $result / 1024 / 1024 * 8" | bc)
        echo "  → 下载速度: ${speed_mbps} Mbps"
        echo "$speed_mbps"
    else
        echo "  → 测速失败"
        echo "0"
    fi
}

record_result() {
    local phase="$1"
    local speed="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${timestamp} | ${phase} | ${speed} Mbps" >> "$LOG_FILE"
}

ensure_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/tmp/tcp-tune-results.log"
    fi
}

backup_and_apply() {
    echo "【备份并应用优化配置】"
    if [ -f "$TARGET_CONF" ]; then
        local timestamp
        timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_file="${TARGET_CONF}.bak.${timestamp}"
        cp "$TARGET_CONF" "$backup_file"
        echo "  ✅ 已备份原配置: $backup_file"
    else
        echo "  ℹ️ 目标配置文件不存在，将创建新文件"
    fi

    cat > "$TARGET_CONF" << 'EOF'
# TCP 参数优化配置 - 自动生成
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p "$TARGET_CONF" > /dev/null 2>&1
    echo "  ✅ 优化配置已写入: $TARGET_CONF"
    echo "  ✅ 配置已应用生效"
    echo ""
}

restore_original_config() {
    echo "【恢复原始配置】"
    if [ -f "${TARGET_CONF}.bak"* ]; then
        local latest_backup
        latest_backup=$(ls -t "${TARGET_CONF}.bak"* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$TARGET_CONF"
            sysctl -p "$TARGET_CONF" > /dev/null 2>&1
            echo "  ✅ 已从备份恢复: $latest_backup"
        fi
    else
        sysctl -w net.core.rmem_max=$orig_rmem_max > /dev/null 2>&1
        sysctl -w net.core.wmem_max=$orig_wmem_max > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_rmem="$orig_tcp_rmem" > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_wmem="$orig_tcp_wmem" > /dev/null 2>&1
        sysctl -w net.core.default_qdisc=$orig_qdisc > /dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=$orig_congestion > /dev/null 2>&1
        echo "  ✅ 已手动恢复原始参数"
    fi
    rm -f "$TARGET_CONF"
    echo ""
}

compare_and_report() {
    local speed_before="$1"
    local speed_after="$2"

    echo "=========================================================="
    echo "【优化效果对比】"
    echo "=========================================================="
    printf "  %-20s %s Mbps\n" "优化前速度:" "$speed_before"
    printf "  %-20s %s Mbps\n" "优化后速度:" "$speed_after"

    local improvement="0"
    local is_improved="0"
    
    if [ "$speed_before" != "0" ] && [ "$speed_before" != "0.00" ]; then
        improvement=$(echo "scale=2; ($speed_after - $speed_before) / $speed_before * 100" | bc)
        is_improved=$(echo "$speed_after > $speed_before * 1.05" | bc)
    else
        echo "  ⚠️ 警告：优化前测速失败，无法计算性能变化"
    fi

    printf "  %-20s %s%%\n" "性能变化:" "$improvement"
    echo ""

    if [ "$is_improved" -eq 1 ] && [ "$is_improved" != "" ]; then
        echo "🎉 恭喜！网络参数优化效果显著！"
        echo "   配置已保留生效: $TARGET_CONF"
        echo ""
        echo "=========================================================="
        echo "✅ 优化完成"
        echo "=========================================================="
        exit 0
    else
        echo "⚠️ 警告：优化效果不明显或速度下降"
        echo ""
        read -p "是否恢复原始配置？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restore_original_config
            echo "✅ 已恢复原始配置"
        else
            echo "ℹ️ 已保留优化配置"
            echo ""
            echo "=========================================================="
            echo "⚠️ 优化完成（效果不明显）"
            echo "=========================================================="
            exit 0
        fi
    fi
}

main() {
    local skip_compare=false
    local force_apply=false
    local check_bbr=false
    local install_bbr=false
    local verify_bbr=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -n|--no-compare) skip_compare=true; shift ;;
            -f|--force) force_apply=true; shift ;;
            --check-bbr) check_bbr=true; shift ;;
            --install-bbr) install_bbr=true; shift ;;
            --verify-bbr) verify_bbr=true; shift ;;
            *) shift ;;
        esac
    done

    if ! is_linux; then
        echo "❌ 此脚本仅支持 Linux 系统" >&2
        exit 1
    fi

    detect_os
    check_dependencies
    ensure_log_dir

    if [ "$check_bbr" = true ]; then
        check_kernel_bbr_support
        check_current_bbr_status
        exit 0
    fi

    if [ "$install_bbr" = true ]; then
        check_kernel_bbr_support
        install_bbr
        check_current_bbr_status
        verify_bbr
        check_network_restart_required
        echo "=========================================================="
        echo "✅ BBR 安装/配置完成"
        echo "=========================================================="
        exit 0
    fi

    if [ "$verify_bbr" = true ]; then
        check_current_bbr_status
        verify_bbr
        exit $?
    fi

    get_current_config
    output_config

    orig_rmem_max=$rmem_max
    orig_wmem_max=$wmem_max
    orig_tcp_rmem=$tcp_rmem
    orig_tcp_wmem=$tcp_wmem
    orig_qdisc=$qdisc
    orig_congestion=$congestion

    if [ "$force_apply" = true ]; then
        backup_and_apply
        echo "【优化后参数】"
        get_current_config
        output_config
        verify_bbr
        check_network_restart_required
        echo ""
        echo "=========================================================="
        echo "✅ 优化完成（强制模式）"
        echo "=========================================================="
        exit 0
    fi

    if [ "$skip_compare" = true ]; then
        backup_and_apply
        echo "【优化后参数】"
        get_current_config
        output_config
        verify_bbr
        check_network_restart_required
        exit 0
    fi

    echo "【第1次测速 - 优化前配置】"
    local speed_before
    speed_before=$(speed_test "优化前" | tail -1)
    echo ""
    record_result "优化前" "$speed_before"

    backup_and_apply
    echo "【优化后参数】"
    get_current_config
    output_config

    echo "【第2次测速 - 优化后配置】"
    local speed_after
    speed_after=$(speed_test "优化后" | tail -1)
    echo ""
    record_result "优化后" "$speed_after"

    echo "测试记录已保存: $LOG_FILE"
    echo ""

    verify_bbr
    check_network_restart_required

    compare_and_report "$speed_before" "$speed_after"
}

main "$@"

#!/bin/bash

# 颜色定义 - 使用 $'...' 语法
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m' # No Color

# 变量定义
INSTALL_DIR="/usr/local/x-ui"
CONFIG_DIR="/etc/x-ui"
LOG_DIR="/var/log/x-ui"
BIN_FILE="/usr/local/bin/x-ui"
SCRIPT_ARGS=("$@")
AUTO_CONFIG_3XUI="${AUTO_CONFIG_3XUI:-1}"
AUTO_NODE_NAME="${AUTO_NODE_NAME:-sg-reality}"
AUTO_NODE_PORT="${AUTO_NODE_PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-s0.awsstatic.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_TARGET%%:*}}"
INSTALL_3XUI_MODE="${INSTALL_3XUI_MODE:-system}"
CLASH_NODE_NAME="${CLASH_NODE_NAME:-}"
CLASH_SERVER_IP="${CLASH_SERVER_IP:-}"

# 权限检测函数
is_linux() { [ "$(uname)" = "Linux" ]; }
is_root() { [ "$(id -u)" -eq 0 ]; }

# 脚本入口权限预检
if is_linux && ! is_root; then
    if command -v sudo &>/dev/null; then
        echo -e "${YELLOW}提示: 脚本需要 root 权限，正在尝试通过 sudo 提升...${NC}"
        exec sudo bash "$0" "$@"
    else
        echo -e "${RED}错误: 该脚本需要 root 权限，请以 root 用户运行。${NC}"
        exit 1
    fi
fi

# 实例信息存储文件
INSTANCES_FILE="/etc/3x-ui-instances.txt"

# 主机网络优化配置文件
TUNING_SYSCTL_CONF="/etc/sysctl.d/99-proxy-server-tuning.conf"
TUNING_SYSCTL_BACKUP="/etc/proxy-server-sysctl-backup.conf"
TUNING_MODULES_CONF="/etc/modules-load.d/99-proxy-server-bbr.conf"
TUNING_LIMITS_CONF="/etc/security/limits.d/99-proxy-server-nofile.conf"
TUNING_SYSTEMD_SYSTEM_CONF="/etc/systemd/system.conf.d/99-proxy-server-limits.conf"
TUNING_SYSTEMD_USER_CONF="/etc/systemd/user.conf.d/99-proxy-server-limits.conf"
TUNING_PROFILE_CONF="/etc/profile.d/99-proxy-server-nofile.sh"
TUNING_NOFILE_SOFT="${TUNING_NOFILE_SOFT:-1048576}"
TUNING_NOFILE_HARD="${TUNING_NOFILE_HARD:-1048576}"

# GitHub 镜像列表
GITHUB_MIRRORS=(
    "github.com"
    "gh.api.99988866.xyz"
    "github.moeyy.xyz"
)

ADL_BIN=""

# 显示帮助信息
show_help() {
    cat << 'EOF'
全能代理面板安装脚本

用法: ./proxy_server.sh [选项]

选项:
    --install-3xui              安装 3x-ui (交互式)
    --install-3xui --port PORT  安装 3x-ui 并指定端口
    --install-3xui --name NAME  安装 3x-ui 并指定实例名称
    --install-3xui --docker     使用 Docker 方式安装 3x-ui（默认使用系统版）
    --install-3xui --system     使用系统版安装 3x-ui（默认，支持自动入站配置）
    --install-3xui --auto-config 安装后自动创建 VLESS + Reality 入站（默认开启）
    --install-3xui --no-auto-config 跳过安装后的自动入站配置
    --auto-config               自动检测已安装面板并配置；已有入站会跳过避免刷新参数
      --panel PANEL             指定面板类型，当前支持 3x-ui / 3xui
      --target TARGET           指定目标实例，当前支持 3x-ui-system
      --node-name NAME          节点名称，默认 sg-reality
      --node-port PORT          入站端口，默认 443
      --reality-target HOST:PORT Reality 目标，默认 s0.awsstatic.com:443
      --reality-sni HOST        Reality SNI，默认从 target 提取
    --install-hiddify           安装 Hiddify
    --install-marzban           安装 Marzban
    --tune-host                 开启 BBR 并优化文件句柄/TCP 参数
    --enable-bbr                同 --tune-host
    --check-tuning              检查 BBR、文件句柄和 TCP 优化状态
    --check-bbr                 仅检查 BBR 状态
    --rollback-tuning           回滚本脚本写入的主机优化配置
    --rollback-bbr              同 --rollback-tuning
    --check-network             网络健康一站式诊断（回答「测速快但上网慢」）
    --mtr-to <ip>               MTR 路径分析：探测客户端到服务器的逐跳丢包/延迟
    --generate-clash-config     从 3x-ui 数据库自动生成 Clash.Meta 订阅 YAML
      --node-name NAME          覆盖生成的客户端节点名
      --server-ip IP            覆盖节点 server 地址
    --clients                   全平台代理客户端推荐 (3x-ui / Marzban / Hiddify)
    --uninstall                自动检测并卸载已安装面板；唯一目标自动选择，多个目标交互选择
      --panel PANEL            指定面板类型：3x-ui / hiddify / marzban
      --target TARGET          指定目标实例：3x-ui-system / 容器名
      --name NAME              同 --target，用于 Docker 实例名
    --status                    检查所有面板状态
    --list-instances            列出所有 3x-ui 实例
    --update                    更新所有面板
    --help, -h                  显示此帮助信息

无参数时进入交互式菜单模式

示例:
    ./proxy_server.sh --status                    # 查看状态
    ./proxy_server.sh --install-3xui              # 自动优化系统、安装并创建 Reality 入站
    ./proxy_server.sh --install-3xui --no-auto-config  # 只安装面板，不自动创建入站
    ./proxy_server.sh --auto-config               # 自动发现并配置已安装面板
    ./proxy_server.sh --generate-clash-config --node-name 新加坡节点-02
    ./proxy_server.sh --tune-host                 # 主机网络优化
EOF
}

# 下载函数 - 优先使用 adl
download_file() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-3}"
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if [ -n "$ADL_BIN" ]; then
            echo -e "${BLUE}使用 adl 下载...${NC}"
            "$ADL_BIN" "$url" "$(dirname "$output")" "$(basename "$output")"
            local adl_exit_code=$?
            if [ $adl_exit_code -eq 0 ]; then
                return 0
            fi
            echo -e "${YELLOW}adl 下载失败，尝试其他方式...${NC}"
        fi
        
        if command -v wget &>/dev/null; then
            echo -e "${BLUE}使用 wget 下载...${NC}"
            if wget --timeout=30 -q -O "$output" "$url" 2>/dev/null; then
                return 0
            fi
        elif command -v curl &>/dev/null; then
            echo -e "${BLUE}使用 curl 下载...${NC}"
            if curl -L --fail --connect-timeout 30 -o "$output" "$url" 2>/dev/null; then
                return 0
            fi
        else
            echo -e "${RED}错误: 未找到 adl、wget 或 curl${NC}"
            return 1
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}下载失败，${max_retries}秒后重试 (${retry_count}/${max_retries})...${NC}"
            sleep 2
        fi
    done
    
    echo -e "${RED}下载失败，已达到最大重试次数${NC}"
    return 1
}

# 从 GitHub 下载（带镜像支持）
download_from_github() {
    local repo_path="$1"
    local output="$2"
    local filename="$(basename "$repo_path")"
    
    for mirror in "${GITHUB_MIRRORS[@]}"; do
        local url="https://${mirror}/${repo_path}"
        echo -e "${BLUE}尝试从 ${mirror} 下载 ${filename}...${NC}"
        
        if download_file "$url" "$output" 1; then
            echo -e "${GREEN}✅ 下载成功${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}⚠️ 从 ${mirror} 下载失败，尝试下一个镜像...${NC}"
    done
    
    echo -e "${RED}❌ 所有镜像下载失败${NC}"
    return 1
}

# 生成随机密码
generate_random_password() {
    local length="${1:-16}"
    if command -v openssl &>/dev/null; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip_services=(
        "ifconfig.me"
        "api.ipify.org"
        "ip.sb"
        "icanhazip.com"
        "ident.me"
    )
    
    for service in "${ip_services[@]}"; do
        local ip
        ip=$(curl -s --connect-timeout 5 "https://${service}" 2>/dev/null || \
             wget -qO- --timeout=5 "https://${service}" 2>/dev/null)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    echo "无法获取"
    return 1
}

# 检测系统/环境
is_linux() { [ "$(uname)" = "Linux" ]; }
is_root() { [ "$(id -u)" -eq 0 ]; }
check_docker() {
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker 已安装。${NC}"
        return 0
    else
        echo -e "${YELLOW}Docker 未安装，将使用系统安装方式。${NC}"
        return 1
    fi
}
check_adl() {
    # 增加对常见路径的检测 (针对 sudo 情况)
    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null)
    
    local possible_paths=(
        "/usr/local/bin/adl"
        "/usr/bin/adl"
        "$HOME/.local/bin/adl"
        "${user_home}/.local/bin/adl"
        "/home/ubuntu/.local/bin/adl"
    )
    
    for p in "${possible_paths[@]}"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            ADL_BIN="$p"
            echo -e "${GREEN}✅ 检测到 adl 下载工具: $p${NC}"
            return 0
        fi
    done

    if command -v adl &>/dev/null; then
        ADL_BIN="adl"
        echo -e "${GREEN}✅ 检测到 adl 下载工具${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ 未检测到 adl，将使用 wget/curl 作为备选${NC}"
        return 1
    fi
}
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7*) echo "armv7" ;;
        *) echo "amd64" ;;
    esac
}

# 检测 AWS 实例类型与建议
check_aws_instance() {
    local token
    # 使用 169.254.169.254 (AWS EC2 实例元数据的标准本地链路 IP) 获取实例类型信息
    # 尝试使用 IMDSv2 获取 token (超时 1 秒)
    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 5" -s --max-time 1)
    local instance_type=""
    
    if [ -n "$token" ]; then
        instance_type=$(curl -H "X-aws-ec2-metadata-token: $token" -s --max-time 1 http://169.254.169.254/latest/meta-data/instance-type)
    else
        # 降级尝试 IMDSv1
        instance_type=$(curl -s --max-time 1 http://169.254.169.254/latest/meta-data/instance-type)
    fi

    if [ -n "$instance_type" ] && [[ "$instance_type" == *.* ]]; then
        echo -e "${BLUE}==========================================================${NC}"
        echo -e "${CYAN}☁️  云服务器环境检测 (AWS)${NC}"
        echo -e "${BLUE}==========================================================${NC}"
        echo -e "实例类型: ${GREEN}${instance_type}${NC}"
        
        if [[ "$instance_type" == t* ]]; then
            echo -e "${YELLOW}⚠️ 检测到 T 系列突发性能实例 (如 t2/t3/t4g)。${NC}"
            echo -e "${YELLOW}   特点: 适合突发流量，但 CPU 积分耗尽后会被强制限流，可能导致代理网络突然卡顿。${NC}"
            echo -e "${CYAN}💡 推荐建议: 如果您的代理服务具有长期、高带宽的网络需求，推荐升级为:${NC}"
            echo -e "   - ${GREEN}C 系列 (如 c5/c6g)${NC}: 计算优化型，提供持续且稳定的高网络吞吐量。"
            echo -e "   - ${GREEN}M 系列 (如 m5/m6g)${NC}: 通用型，资源分配均衡，适合中大型代理节点。"
        elif [[ "$instance_type" == c* ]]; then
            echo -e "${GREEN}✅ 检测到 C 系列计算优化型实例。${NC}"
            echo -e "${GREEN}   特点: CPU 性能强劲，网络吞吐量极高，非常适合运行高性能网络代理服务！${NC}"
        elif [[ "$instance_type" == m* ]]; then
            echo -e "${GREEN}✅ 检测到 M 系列通用型实例。${NC}"
            echo -e "${GREEN}   特点: 计算与内存资源均衡，适合作为稳定的大流量代理节点。${NC}"
        else
            echo -e "${GREEN}✅ 检测到其他系列实例 (${instance_type})。${NC}"
        fi
        echo -e "${BLUE}==========================================================${NC}"
    fi
}

# 安全读取 sysctl 参数（失败/空值时返回默认值，避免空变量造成比较错误）
_safe_sysctl() {
    local key="$1" default="${2:-0}" val
    val=$(sysctl -n "$key" 2>/dev/null)
    # 过滤空白/非数字
    if [[ -z "${val// }" ]] || ! [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# 数字→带千位分隔的可读字符串（1234567 → 1,234,567）
_human_num() {
    local num="${1:-0}" sign="" out=""
    [[ "$num" == -* ]] && { sign="-"; num="${num#-}"; }
    while [ ${#num} -gt 3 ]; do
        out=",${num: -3}${out}"
        num="${num:0:${#num}-3}"
    done
    echo "${sign}${num}${out}"
}

_print_threshold_check() {
    local name="$1" val="$2" threshold="$3" hint="$4"
    if [ "$val" -ge "$threshold" ] 2>/dev/null; then
        printf "  ✅ %-38s 当前 = %s  → 满足\n" "$name" "$(_human_num "$val")"
    else
        printf "  ⚠️  %-38s 当前 = %s  → 偏低，%s\n" "$name" "$(_human_num "$val")" "$hint"
    fi
}

# 主机优化状态检查
check_host_tuning() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}                主机网络优化状态检查${NC}"
    echo -e "${BLUE}==========================================================${NC}"

    if ! is_linux; then
        echo -e "${RED}仅支持 Linux 主机${NC}"
        return 1
    fi

    local cc available bbr_conf file_max rmem_max wmem_max somaxconn
    local fastopen notsent_lowat conntrack_max tcp_fin tcp_tw ip_local_range

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    bbr_conf=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    file_max=$(_safe_sysctl fs.file-max 0)
    rmem_max=$(_safe_sysctl net.core.rmem_max 0)
    wmem_max=$(_safe_sysctl net.core.wmem_max 0)
    somaxconn=$(_safe_sysctl net.core.somaxconn 0)
    fastopen=$(_safe_sysctl net.ipv4.tcp_fastopen 0)
    notsent_lowat=$(_safe_sysctl net.ipv4.tcp_notsent_lowat 0)
    conntrack_max=$(_safe_sysctl net.netfilter.nf_conntrack_max 0)
    tcp_fin=$(_safe_sysctl net.ipv4.tcp_fin_timeout 0)
    tcp_tw=$(_safe_sysctl net.ipv4.tcp_tw_reuse 0)
    ip_local_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null)

    echo -e "[核心] 拥塞控制:         ${GREEN}${cc:-未知}${NC}"
    echo -e "[核心] 队列调度器:       ${GREEN}${bbr_conf:-未知}${NC}"
    echo -e "[核心] 可用算法列表:     ${GREEN}${available:-未知}${NC}"

    # BBR 启用判断（bbr 必须出现在可用列表 + 拥塞控制 = bbr + qdisc = fq）
    local bbr_ok=0
    if echo "${available}" | grep -qw bbr 2>/dev/null \
        && [ "${cc}" = "bbr" ] && [ "${bbr_conf}" = "fq" ]; then
        bbr_ok=1
        echo -e "       → ${GREEN}✅ BBR 已启用${NC}"
    else
        echo -e "       → ${YELLOW}⚠️ BBR 未完整启用${NC}"
        [[ "$cc" != "bbr" ]] && echo -e "       → ${YELLOW}   原因: 拥塞控制当前为 ${cc}（建议: bbr）${NC}"
        [[ "$bbr_conf" != "fq" ]] && echo -e "       → ${YELLOW}   原因: 队列调度当前为 ${bbr_conf}（建议: fq）${NC}"
        echo "${available}" | grep -qw bbr 2>/dev/null \
            || echo -e "       → ${YELLOW}   原因: 内核未加载 tcp_bbr 模块（运行: modprobe tcp_bbr）${NC}"
    fi

    echo ""
    echo -e "[句柄] fs.file-max:      ${GREEN}$(_human_num "$file_max")${NC}"
    echo -e "[句柄] shell nofile S/H: ${GREEN}$(ulimit -Sn 2>/dev/null)/$(ulimit -Hn 2>/dev/null)${NC}"

    echo ""
    echo -e "[缓冲] rmem_max:         ${GREEN}$(_human_num "$rmem_max")${NC}"
    echo -e "[缓冲] wmem_max:         ${GREEN}$(_human_num "$wmem_max")${NC}"
    echo -e "[队列] somaxconn:        ${GREEN}$(_human_num "$somaxconn")${NC}"
    echo -e "[TFO]  tcp_fastopen:     ${GREEN}${fastopen}${NC}"
    echo -e "[BBR]  notsent_lowat:    ${GREEN}$(_human_num "$notsent_lowat")${NC}"
    echo -e "[NAT]  conntrack_max:    ${GREEN}$(_human_num "$conntrack_max")${NC}"
    echo -e "[TCP]  fin_timeout:      ${GREEN}${tcp_fin}s${NC}"
    echo -e "[TCP]  tw_reuse:         ${GREEN}${tcp_tw}${NC}"
    echo -e "[端口] local_range:      ${GREEN}${ip_local_range:-未知}${NC}"

    echo ""
    _print_threshold_check "文件句柄 fs.file-max" "$file_max" 65535 "建议 ≥ 65535（代理节点推荐 1048576+）"
    _print_threshold_check "接收缓冲 net.core.rmem_max" "$rmem_max" 4194304 "建议 ≥ 4MB（大带宽节点推荐 6MB+）"
    _print_threshold_check "发送缓冲 net.core.wmem_max" "$wmem_max" 4194304 "建议 ≥ 4MB（大带宽节点推荐 6MB+）"
    _print_threshold_check "连接队列 net.core.somaxconn" "$somaxconn" 4096 "建议 ≥ 4096（高并发节点推荐 65535）"
    _print_threshold_check "连接追踪 net.netfilter.nf_conntrack_max" "$conntrack_max" 65535 "NAT/高并发场景建议 ≥ 65535"

    if [ -f "$TUNING_SYSCTL_CONF" ]; then
        echo ""
        echo -e "${GREEN}✅ 已存在 sysctl 优化配置: $TUNING_SYSCTL_CONF${NC}"
        echo -e "${CYAN}   如需查看配置内容: cat $TUNING_SYSCTL_CONF${NC}"
    else
        echo ""
        echo -e "${YELLOW}⚠️  尚未写入优化配置，可运行: ${0##*/} --tune-host${NC}"
    fi
}

backup_sysctl_if_needed() {
    if [ -f "$TUNING_SYSCTL_BACKUP" ]; then return 0; fi
    {
        echo "# autogenerated backup by proxy_server.sh"
        sysctl -a 2>/dev/null | grep -E '^(fs\.file-max|fs\.nr_open|net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.ipv4\.ip_local_port_range|net\.core\.somaxconn|net\.ipv4\.tcp_fin_timeout|net\.ipv4\.tcp_tw_reuse|net\.ipv4\.tcp_fastopen|net\.ipv4\.tcp_max_syn_backlog|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_mtu_probing|net\.core\.rmem_max|net\.core\.wmem_max|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_notsent_lowat|net\.ipv4\.tcp_syncookies|net\.core\.netdev_budget|net\.netfilter\.nf_conntrack_max|net\.netfilter\.nf_conntrack_tcp_timeout_established) = ' || true
    } > "$TUNING_SYSCTL_BACKUP"
}

restore_sysctl_from_backup() {
    local backup_file="$1"
    [ -f "$backup_file" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
            *=*)
                local key="${line%%=*}"
                local value="${line#*=}"
                key="$(echo "$key" | xargs)"
                value="$(echo "$value" | xargs)"
                if [ -n "$key" ] && [ -n "$value" ]; then
                    sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
                fi
                ;;
        esac
    done < "$backup_file"
}

# 尝试加载内核模块，失败时给出提示但不中断（某些内核可能内置该功能）
_try_modprobe() {
    local mod="$1"
    if ! modprobe "$mod" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠️  模块 ${mod} 未加载成功（可能已内置或内核不支持，可忽略）${NC}"
        return 1
    fi
    return 0
}

apply_host_tuning() {
    local silent=false
    [[ "$1" == "--silent" ]] && silent=true

    if [ "$silent" = false ]; then
        echo -e "${BLUE}==========================================================${NC}"
        echo -e "${BLUE}              开启 BBR 与文件句柄优化${NC}"
        echo -e "${BLUE}==========================================================${NC}"
    fi

    if ! is_linux; then return 1; fi

    # 检测并输出云实例建议（AWS 优先，其他云平台也可同理扩展）
    check_aws_instance

    # 备份（仅在首次运行时备份一次；若已备份则跳过，避免覆盖原备份）
    backup_sysctl_if_needed
    mkdir -p /etc/sysctl.d /etc/security/limits.d /etc/systemd/system.conf.d /etc/systemd/user.conf.d /etc/modules-load.d /etc/profile.d
    # 模块加载：开机 + 当前
    cat > "$TUNING_MODULES_CONF" <<EOF
# managed by proxy_server.sh
tcp_bbr
nf_conntrack
EOF
    _try_modprobe tcp_bbr
    _try_modprobe nf_conntrack

    cat > "$TUNING_SYSCTL_CONF" <<EOF
# managed by proxy_server.sh - 代理服务器专属优化
# 文件句柄
fs.file-max=2097152
fs.nr_open=${TUNING_NOFILE_HARD}
# BBR 拥塞控制 + 队列调度
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# 连接队列（高并发代理必需）
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.core.netdev_max_backlog=16384
net.core.netdev_budget=50000
# TCP 缓冲区（高并发/高带宽长连接必需）
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 87380 67108864
net.ipv4.tcp_adv_win_scale=1
# TCP 窗口扩展 / SACK / DSACK（高带宽时延积 / 高丢包链路必备）
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=0
# ECN（显式拥塞通知，对跨国链路很有用，但部分劣质中间盒会拦截，可按需切换）
net.ipv4.tcp_ecn=1
# 连接复用 / 超时
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
# TCP Fast Open + PMTU 探测（避免 MTU 黑洞导致大文件慢）
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
# Keepalive（代理长连接保活，避免运营商/防火墙静默切断）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
# SYN Flood 防御
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_retries2=8
# 连接追踪（NAT 环境，高并发代理必需）
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
EOF

    cat > "$TUNING_LIMITS_CONF" <<EOF
# managed by proxy_server.sh
* soft nofile ${TUNING_NOFILE_SOFT}
* hard nofile ${TUNING_NOFILE_HARD}
root soft nofile ${TUNING_NOFILE_SOFT}
root hard nofile ${TUNING_NOFILE_HARD}
EOF

    cat > "$TUNING_SYSTEMD_SYSTEM_CONF" <<EOF
[Manager]
DefaultLimitNOFILE=${TUNING_NOFILE_HARD}
EOF
    cp "$TUNING_SYSTEMD_SYSTEM_CONF" "$TUNING_SYSTEMD_USER_CONF"

    cat > "$TUNING_PROFILE_CONF" <<EOF
# managed by proxy_server.sh
ulimit -n ${TUNING_NOFILE_SOFT} >/dev/null 2>&1 || true
EOF

    # 应用 sysctl（仅记录失败项，不中断）
    local failed_keys=""
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
        local key="${line%%=*}"
        # 去掉首尾空白
        key="${key// }"
        [[ -z "$key" ]] && continue
        if ! sysctl -w "$line" >/dev/null 2>&1; then
            failed_keys="${failed_keys} ${key}"
        fi
    done < "$TUNING_SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1  # 确保所有子目录也生效
    systemctl daemon-reexec >/dev/null 2>&1 || true

    if [ "$silent" = false ]; then
        echo -e "${GREEN}✅ 主机优化配置已写入${NC}"
        if [[ -n "${failed_keys// }" ]]; then
            echo -e "${YELLOW}⚠️  以下 sysctl 参数在内核中应用失败（通常是内核不支持，可忽略）:${NC}"
            echo -e "   ${YELLOW}${failed_keys}${NC}"
        fi
        # 必须的提示：已运行进程不会自动继承新的文件句柄/拥塞控制参数
        echo -e ""
        echo -e "${CYAN}ℹ️  重要：已运行的 xray/3x-ui 进程不会自动继承新的句柄/缓冲/BBR 参数，${NC}"
        echo -e "${CYAN}    需要重启进程才能生效。正在检测可能的面板...${NC}"
        restart_proxies_after_tuning
        echo ""
        check_host_tuning
    else
        if [[ -n "${failed_keys// }" ]]; then
            echo -e "${YELLOW}⚠️  已写入主机优化配置，部分内核参数未即时生效:${NC} ${failed_keys}"
        else
            echo -e "${GREEN}✅ 已在安装前应用内核/网络优化: BBR + fq、文件句柄、TCP 缓冲、连接队列${NC}"
        fi
    fi
}

# ── 主机调优后重启 3x-ui/xray 服务（让新参数真正生效） ──
# 原因：进程的 rlimit、tcp_congestion_control 是在 socket 创建时确定的，
# 仅修改 sysctl 对已存在连接没有影响。
restart_proxies_after_tuning() {
    local candidates=()
    # systemd 服务（x-ui / 3x-ui）
    local svc
    for svc in x-ui 3x-ui marzban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            candidates+=("systemd:$svc")
        fi
    done
    # Docker 容器
    if command -v docker >/dev/null 2>&1; then
        local containers
        containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE '3x-ui|marzban|hiddify|xray' || true)
        for c in $containers; do
            candidates+=("docker:$c")
        done
    fi
    # xray 独立二进制进程（未用 systemd 管理）
    if pgrep -x "xray" >/dev/null 2>&1; then
        candidates+=("binary:xray(pid=$(pgrep -x xray | head -1))")
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}未检测到已运行的代理服务，重启跳过。${NC}"
        echo -e "  ${GRAY}（未来安装 3x-ui 后，新进程会自动使用新参数）${NC}"
        return 0
    fi

    echo -e "  检测到以下运行中的代理服务:"
    local i=1
    for item in "${candidates[@]}"; do
        echo -e "    ${i}) ${GREEN}${item}${NC}"
        i=$((i+1))
    done

    local reply
    echo -ne "  ${YELLOW}是否立即重启以上服务（约 5-10 秒）? [Y/n]${NC} "
    read -r reply 2>/dev/null
    [[ -z "$reply" ]] && reply="y"
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo -e "  ${GRAY}已跳过重启。请注意：现有连接仍使用旧参数，直到下次重启。${NC}"
            return 0
            ;;
    esac

    local svc c
    for item in "${candidates[@]}"; do
        case "$item" in
            systemd:*)
                svc="${item#systemd:}"
                echo -e "  → 重启 systemd 服务: ${GREEN}${svc}${NC}"
                systemctl restart "$svc" 2>/dev/null && echo -e "     ${GREEN}✓ ${svc} 已重启${NC}" || echo -e "     ${RED}✗ ${svc} 重启失败${NC}"
                ;;
            docker:*)
                c="${item#docker:}"
                echo -e "  → 重启 Docker 容器: ${GREEN}${c}${NC}"
                docker restart "$c" >/dev/null 2>&1 && echo -e "     ${GREEN}✓ ${c} 已重启${NC}" || echo -e "     ${RED}✗ ${c} 重启失败${NC}"
                ;;
            binary:*)
                echo -e "  → ${YELLOW}检测到 xray 二进制进程（非 systemd/Docker 管理）${NC}"
                echo -e "     ${GRAY}建议手动重启该进程，或改用 3x-ui 面板管理。${NC}"
                ;;
        esac
    done

    # 等待服务健康并回显
    echo -e "  ${CYAN}等待 3 秒让服务稳定...${NC}"
    sleep 3
    echo -e "  ${GREEN}✅ 完成。现在所有新连接都将使用新的 BBR/缓冲/句柄参数。${NC}"
}

rollback_host_tuning() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}                回滚主机优化配置${NC}"
    echo -e "${BLUE}==========================================================${NC}"

    rm -f "$TUNING_SYSCTL_CONF" "$TUNING_MODULES_CONF" "$TUNING_LIMITS_CONF" "$TUNING_SYSTEMD_SYSTEM_CONF" "$TUNING_SYSTEMD_USER_CONF" "$TUNING_PROFILE_CONF"
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reexec >/dev/null 2>&1 || true

    if [ -f "$TUNING_SYSCTL_BACKUP" ]; then
        restore_sysctl_from_backup "$TUNING_SYSCTL_BACKUP"
        rm -f "$TUNING_SYSCTL_BACKUP"
        echo -e "${GREEN}✅ 已回滚配置并清理备份${NC}"
    fi
}

# ── 网络健康一站式诊断：回答「测速快但上网慢」的常见原因 ──
# 覆盖：BBR/拥塞控制、文件句柄、TCP 缓冲、连接追踪、MTU、ECN、DNS、
#       代理节点延迟/带宽、面板监听端口等
diagnose_network() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}         🛰️  代理服务器网络一站式诊断${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${GRAY}本诊断覆盖 8 大类常见问题，运行约 30 秒，会尝试访问公网。${NC}"
    echo ""

    # 1. 核心参数检查
    echo -e "${CYAN}[1/8] 核心参数: 拥塞控制 / 文件句柄${NC}"
    local cc bbr_conf file_max ulimit_soft
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    bbr_conf=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    file_max=$(sysctl -n fs.file-max 2>/dev/null)
    ulimit_soft=$(ulimit -n 2>/dev/null)
    echo -e "  拥塞控制:      ${GREEN}${cc}${NC}   队列调度: ${GREEN}${bbr_conf}${NC}"
    echo -e "  fs.file-max:   ${GREEN}${file_max}${NC}   ulimit -n: ${GREEN}${ulimit_soft}${NC}"
    if [[ "$cc" != "bbr" ]]; then
        echo -e "  ${YELLOW}⚠️  拥塞控制不是 bbr → 跨国链路下吞吐可能偏低 40%-70%${NC}"
        echo -e "     建议: $0 --tune-host（会自动切换为 BBR + fq）"
    else
        echo -e "  ${GREEN}✅ BBR 已启用${NC}"
    fi
    if [[ "$file_max" -lt 65535 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠️  fs.file-max 偏小 → 高并发下会报 \"too many open files\"${NC}"
    fi
    echo ""

    # 2. TCP 缓冲 / 窗口扩展 / SACK
    echo -e "${CYAN}[2/8] TCP 缓冲 & 窗口扩展${NC}"
    local rmem_max wmem_max win_scale sack ecn
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null)
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null)
    win_scale=$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)
    sack=$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)
    ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)
    echo -e "  rmem_max=${rmem_max} wmem_max=${wmem_max} window_scaling=${win_scale} sack=${sack} ecn=${ecn}"
    if [[ "$win_scale" != "1" ]]; then
        echo -e "  ${RED}✗ tcp_window_scaling 未开启 → 长肥管道(高延迟高带宽)下速率被锁死在 ~3 Mbps${NC}"
        echo -e "     这正是典型的『测速快但上网慢』原因之一！请运行: $0 --tune-host"
    fi
    if [[ "$sack" != "1" ]]; then
        echo -e "  ${RED}✗ tcp_sack 未开启 → 丢包链路下载速率严重下降${NC}"
    fi
    if [[ "$rmem_max" -lt 4194304 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠️  rmem_max < 4MB → 长延迟链路窗口不够大，达不到峰值速率${NC}"
    fi
    echo ""

    # 3. 连接追踪状态
    echo -e "${CYAN}[3/8] 连接追踪 conntrack${NC}"
    local conntrack_max conntrack_count
    conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
    conntrack_count=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
    echo -e "  max=${conntrack_max:-未知}  used=${conntrack_count:-未知}"
    if [[ -n "$conntrack_count" && -n "$conntrack_max" ]]; then
        if awk -v used="$conntrack_count" -v max="$conntrack_max" 'BEGIN { exit !(max > 0 && used / max > 0.7) }' 2>/dev/null; then
            echo -e "  ${RED}✗ 连接追踪占用 > 70% → 即将拒绝新建连接！${NC}"
        fi
    fi
    echo ""

    # 4. MTU 检查（对跨境链路非常关键）
    echo -e "${CYAN}[4/8] 网卡 MTU 检查${NC}"
    local iface mtu
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -5); do
        mtu=$(ip link show "$iface" 2>/dev/null | grep -oE 'mtu [0-9]+' | awk '{print $2}')
        echo -e "  ${iface}: MTU ${GREEN}${mtu:-未知}${NC}"
    done
    echo -e "  ${GRAY}提示: 若您的节点有 MTU 问题（ping 大包不通但小包正常），${NC}"
    echo -e "  ${GRAY}通常可在 3x-ui 面板将出站 mtu 设为 1440，或开启 tcp_mtu_probing=1。${NC}"
    echo ""

    # 5. DNS 解析延迟
    echo -e "${CYAN}[5/8] DNS 解析延迟（google.com / cloudflare.com）${NC}"
    local t
    for domain in google.com cloudflare.com github.com; do
        t=$( { time -p getent ahosts "$domain" >/dev/null 2>&1; } 2>&1 | awk '/^real/ {print $2}')
        if [[ -n "$t" ]]; then
            local ms
            ms=$(awk -v t="$t" 'BEGIN { printf "%.0f", t * 1000 }' 2>/dev/null)
            echo -e "  ${domain}: ${GREEN}${ms}ms${NC}"
        fi
    done
    echo ""

    # 6. 代理监听端口
    echo -e "${CYAN}[6/8] 本机监听端口（3x-ui 面板 / 常见代理端口）${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | awk 'NR==1 || /x-ui|:54321|xray/ || NR<=3' | head -8
    fi
    echo ""

    # 7. 出站延迟测试（到节点/Cloudflare/Google）
    echo -e "${CYAN}[7/8] 出站延迟（RTO 相关，直接影响首次连接体验）${NC}"
    local targets=("1.1.1.1" "8.8.8.8" "cloudflare.com" "google.com")
    local ip ttl rtt
    for ip in "${targets[@]}"; do
        local line
        line=$(ping -c 1 -W 2 "$ip" 2>/dev/null | awk -F'time=' '/time=/ {print $2}')
        if [[ -n "$line" ]]; then
            echo -e "  ${ip}: ${GREEN}${line}${NC}"
        else
            echo -e "  ${ip}: ${YELLOW}超时/不通${NC}"
        fi
    done
    echo ""

    # 8. 下载速度测试（直接 HTTP 下载，不依赖 speedtest 服务）
    echo -e "${CYAN}[8/8] 直接下载速度（cloudflare 10MB 测试文件，10s 超时）${NC}"
    local dl_speed
    dl_speed=$(curl -s --max-time 10 -o /dev/null -w '%{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=10485760" 2>/dev/null)
    if [[ -n "$dl_speed" ]]; then
        local mbps
        mbps=$(awk -v s="$dl_speed" 'BEGIN { printf "%.2f", s * 8 / 1000000 }' 2>/dev/null)
        echo -e "  本机直连下载: ${GREEN}${mbps} Mbps${NC}"
    else
        echo -e "  ${YELLOW}下载失败（可能被防火墙拦截，不一定代表带宽不足）${NC}"
    fi

    # 检查同目录的 proxy-speed.sh / net-speed.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo ""
    echo -e "${CYAN}👉 进一步诊断${NC}"
    if [[ -x "$script_dir/proxy-speed.sh" ]]; then
        echo -e "  • 代理节点专用测速（不依赖 speedtest 服务）: $script_dir/proxy-speed.sh"
    fi
    if [[ -x "$script_dir/net-speed.sh" ]]; then
        echo -e "  • Ookla/speedtest-cli 测速（看公网到运营商）: $script_dir/net-speed.sh"
    fi

    echo ""
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}   『测速快但上网慢』常见原因与修复建议${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "  1) TCP 拥塞控制非 BBR —— 解决: ${GREEN}$0 --tune-host${NC}（会切换到 BBR+fq）"
    echo -e "  2) tcp_window_scaling / tcp_sack 未启用 —— 解决: 同上"
    echo -e "  3) TCP 缓冲过小（rmem_max < 4MB）—— 解决: 同上"
    echo -e "  4) MTU 不匹配 —— 解决: 3x-ui 出站 mtu 设为 1440，或开启 tcp_mtu_probing=1"
    echo -e "  5) DNS 解析过慢 —— 解决: 修改 /etc/resolv.conf 为 1.1.1.1 / 8.8.8.8"
    echo -e "  6) 代理节点本身质量差（超卖/晚高峰）—— 解决: 切换其他节点"
    echo -e "  7) xray/3x-ui 未重启 —— 解决: systemctl restart x-ui"
    echo -e "  8) conntrack 耗尽 —— 解决: 调大 net.netfilter.nf_conntrack_max"
}

# =====================================================================
# 扩展功能1: Clash.Meta 订阅一键生成
# 读取 3x-ui SQLite 数据库中的入站节点，生成生产级 Clash 配置
# =====================================================================
generate_clash_config() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}         🚀  Clash.Meta 订阅配置生成器${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo ""

    local db_file="/etc/x-ui/x-ui.db"
    local out_dir="${HOME:-/home/$(whoami)}/clash-config"
    local out_file="${out_dir}/clash-meta.yaml"
    mkdir -p "$out_dir" 2>/dev/null || true

    # ── 第一步：读取节点 ─────────────────────────────────────────
    local nodes=()
    local server_public_ip=""

    # 优先获取公网IP（生成订阅时需要作为节点 host）
    server_public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                       curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
    [ -n "$CLASH_SERVER_IP" ] && server_public_ip="$CLASH_SERVER_IP"

    if [[ -f "$db_file" ]] && command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${CYAN}📦  正在从 3x-ui 数据库读取入站节点...${NC}"
        # 3x-ui 将协议细节存放在 JSON 字段中：
        #   - settings.clients[0].id            → UUID
        #   - stream_settings.security          → "reality" / "tls" / "none"
        #   - stream_settings.network           → "tcp" / "ws" / "grpc" / "http"
        #   - stream_settings.realitySettings.settings.publicKey  → Reality pubkey
        #   - stream_settings.realitySettings.shortIds[0]         → Reality shortId
        #   - stream_settings.realitySettings.serverNames[0]      → SNI
        #   - settings.clients[0].flow                            → VLESS flow (optional)
        local sql
        sql="SELECT
  id,
  remark,
  protocol,
  port,
  COALESCE(json_extract(settings, '\$.clients[0].id'), ''),
  COALESCE(json_extract(stream_settings, '\$.security'), ''),
  COALESCE(json_extract(stream_settings, '\$.network'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.settings.publicKey'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.shortIds[0]'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.serverNames[0]'), ''),
  COALESCE(json_extract(settings, '\$.clients[0].flow'), '')
FROM inbounds
WHERE enable = 1
ORDER BY id;"
        local rows
        rows=$(sqlite3 -separator "|" "$db_file" "$sql" 2>/dev/null || echo "")
        if [[ -n "$rows" ]]; then
            local i=0
            while IFS='|' read -r id remark protocol port uuid security network pubkey short_id sni flow; do
                [[ -z "$id" ]] && continue
                remark="${remark:-节点-${id}}"
                [ -n "$CLASH_NODE_NAME" ] && remark="$CLASH_NODE_NAME"
                i=$((i+1))
                echo -e "  ${GREEN}${i})${NC} ${remark} — ${CYAN}${protocol}/${network}${NC} (${security}) :${port}"
                nodes+=("${remark}|${protocol}|${port}|${uuid}|${pubkey}|${short_id}|${sni}|${network}|${security}|${flow}")
            done <<< "$rows"
        else
            echo -e "  ${YELLOW}⚠️  数据库中未找到启用的入站，请先在 3x-ui 面板添加节点${NC}"
        fi
    elif [[ -f "$db_file" ]]; then
        echo -e "${YELLOW}⚠️  未检测到 sqlite3，正在尝试安装...${NC}"
        if apt-get update -qq >/dev/null 2>&1 && apt-get install -y sqlite3 >/dev/null 2>&1 \
            && command -v sqlite3 >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ sqlite3 安装成功，已重新尝试读取数据库节点...${NC}"
            # 用上面同样的正确 SQL 重新读取
            local sql
            sql="SELECT
  id, remark, protocol, port,
  COALESCE(json_extract(settings, '\$.clients[0].id'), ''),
  COALESCE(json_extract(stream_settings, '\$.security'), ''),
  COALESCE(json_extract(stream_settings, '\$.network'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.settings.publicKey'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.shortIds[0]'), ''),
  COALESCE(json_extract(stream_settings, '\$.realitySettings.serverNames[0]'), ''),
  COALESCE(json_extract(settings, '\$.clients[0].flow'), '')
FROM inbounds WHERE enable = 1 ORDER BY id;"
            rows=$(sqlite3 -separator "|" "$db_file" "$sql" 2>/dev/null || echo "")
            if [[ -n "$rows" ]]; then
                local i=0
                while IFS='|' read -r id remark protocol port uuid security network pubkey short_id sni flow; do
                    [[ -z "$id" ]] && continue
                    remark="${remark:-节点-${id}}"
                    [ -n "$CLASH_NODE_NAME" ] && remark="$CLASH_NODE_NAME"
                    i=$((i+1))
                    echo -e "  ${GREEN}${i})${NC} ${remark} — ${CYAN}${protocol}/${network}${NC} (${security}) :${port}"
                    nodes+=("${remark}|${protocol}|${port}|${uuid}|${pubkey}|${short_id}|${sni}|${network}|${security}|${flow}")
                done <<< "$rows"
            else
                echo -e "  ${YELLOW}⚠️  数据库中未找到启用的入站，请先在 3x-ui 面板添加节点${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠️  sqlite3 安装失败。请手动执行:${NC}"
            echo -e "     sudo apt-get update && sudo apt-get install -y sqlite3"
            echo -e "  或${GREEN}直接使用交互模式输入节点信息${NC} ↓"
        fi
    else
        echo -e "${YELLOW}⚠️  未在 ${db_file} 找到数据库${NC}"
        echo -e "  请确认已安装 3x-ui，或直接使用下方『快速模式』手动输入节点信息 ↓"
    fi

    # ── 第二步：若数据库不可读，则快速模式让用户输入节点 ─────────
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo ""
        echo -e "${CYAN}📝  快速模式：手动输入 vless/reality 节点信息${NC}"
        echo -e "  ${GRAY}（留空即结束输入）${NC}"
        while true; do
            echo ""
            read -rp "  节点名称 (如 新加坡节点-02): " node_name
            [[ -z "$node_name" ]] && break
            read -rp "  端口 (如 443): " node_port
            read -rp "  UUID: " node_uuid
            read -rp "  reality public-key (若无则留空): " node_pubkey
            read -rp "  reality short-id (如 fa9fb0c679aa7b): " node_sid
            read -rp "  serverName / SNI (如 s0.awsstatic.com): " node_sni
            # 10 字段: remark|protocol|port|uuid|pubkey|shortid|sni|network|security|flow
            if [[ -n "$node_pubkey" ]]; then
                nodes+=("${node_name}|vless|${node_port}|${node_uuid}|${node_pubkey}|${node_sid}|${node_sni}|tcp|reality|")
            else
                nodes+=("${node_name}|vless|${node_port}|${node_uuid}|||${node_sni}|tcp|tls|")
            fi
            echo -e "  ✅ 已加入: ${GREEN}${node_name}${NC}"
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        error "未找到任何节点，无法生成订阅"
        return 1
    fi

    # ── 第三步：生成 YAML ─────────────────────────────────────────
    echo ""
    echo -e "${CYAN}📄  正在生成 Clash.Meta 配置文件...${NC}"

    local yaml_content=""
    # 1) 头信息
    cat > "$out_file" <<EOF
# ============================================================
# Clash.Meta 生产级配置 — 由 proxy_server.sh 生成
# 服务器: ${server_public_ip}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 使用方法: 将此文件放入 Clash.Meta / mihomo / Clash Verge Rev 的 config 目录
# 推荐客户端: https://github.com/MetaCubeX/mihomo
# ============================================================

mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true

dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '+.lan'
    - '+.local'
    - '+.internal'
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
    - 1.1.1.1

proxies:
EOF

    # 2) 节点列表
    local node_idx=0
    # 为 proxy-groups 构建 YAML 片段 — 每行 6 空格 + - "节点名"
    local yaml_nodes=""
    for n in "${nodes[@]}"; do
        # 字段顺序: remark|protocol|port|uuid|pubkey|shortid|sni|network|security|flow
        IFS='|' read -r n_name n_protocol n_port n_uuid n_pubkey n_sid n_sni n_network n_security n_flow <<< "$n"
        node_idx=$((node_idx+1))

        # YAML 名字清洗：空格 → 下划线，去掉会破坏 YAML 结构的字符（: " \）
        n_name=$(echo "$n_name" | tr ' ' '_' | sed "s/[\":\\\\]//g")
        [[ -z "$n_name" ]] && n_name="Node-${node_idx}"

        # 默认网络类型为 tcp（兼容旧格式）
        n_network="${n_network:-tcp}"

        # 累积 proxy-groups 使用的节点列表
        yaml_nodes="${yaml_nodes}      - \"${n_name}\"
"

        # 根据 security 和 protocol 决定 Clash 节点类型：
        #   - reality + vless → VLESS + TCP + REALITY
        #   - tls + vless → VLESS + TCP + TLS
        #   - reality/tls + trojan → Trojan
        #   - 其他 → 按 protocol 直出
        if [[ "$n_protocol" == "vless" && ( "$n_security" == "reality" || -n "$n_pubkey" ) ]]; then
            # VLESS + TCP + REALITY
            cat >> "$out_file" <<EOF
  - name: "${n_name}"
    type: vless
    server: ${server_public_ip}
    port: ${n_port}
    uuid: ${n_uuid}
    network: ${n_network}
$( [[ -n "$n_flow" ]] && printf '    flow: %s\n' "$n_flow" )
    udp: true
    tls: true
    client-fingerprint: chrome
    servername: "${n_sni:-s0.awsstatic.com}"
    reality-opts:
      public-key: "${n_pubkey}"
      short-id: "${n_sid}"

EOF
        elif [[ "$n_protocol" == "vless" ]]; then
            # VLESS + TCP + TLS（XTLS 等变种，按普通 TLS 处理）
            cat >> "$out_file" <<EOF
  - name: "${n_name}"
    type: vless
    server: ${server_public_ip}
    port: ${n_port}
    uuid: ${n_uuid}
    network: ${n_network}
$( [[ -n "$n_flow" ]] && printf '    flow: %s\n' "$n_flow" )
    udp: true
    tls: true
    client-fingerprint: chrome
    servername: "${n_sni:-${server_public_ip}}"

EOF
        elif [[ "$n_protocol" == "trojan" ]]; then
            cat >> "$out_file" <<EOF
  - name: "${n_name}"
    type: trojan
    server: ${server_public_ip}
    port: ${n_port}
    password: "${n_uuid}"
    network: ${n_network}
    udp: true
    tls: true
    sni: "${n_sni:-${server_public_ip}}"
EOF
        else
            # 其他协议按原样输出
            cat >> "$out_file" <<EOF
  - name: "${n_name}"
    type: ${n_protocol}
    server: ${server_public_ip}
    port: ${n_port}
    uuid: ${n_uuid}
    tls: true
    servername: "${n_sni:-${server_public_ip}}"
EOF
        fi
    done

    # 3) 策略组 + 规则
    cat >> "$out_file" <<EOF

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "⚡ 自动选择"
${yaml_nodes}      - DIRECT

  - name: "⚡ 自动选择"
    type: url-test
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50
    proxies:
${yaml_nodes}
  - name: "🌍 全球直连"
    type: select
    proxies:
      - DIRECT
      - "🚀 节点选择"

  - name: "🆎 广告拦截"
    type: select
    proxies:
      - REJECT
      - DIRECT

  - name: "🐟 漏网之鱼"
    type: select
    proxies:
      - "🚀 节点选择"
      - "⚡ 自动选择"
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  # 常用国内域名直连（可按需扩展）
  - DOMAIN-SUFFIX,baidu.com,🌍 全球直连
  - DOMAIN-SUFFIX,qq.com,🌍 全球直连
  - DOMAIN-SUFFIX,weibo.com,🌍 全球直连
  - DOMAIN-SUFFIX,163.com,🌍 全球直连
  - DOMAIN-SUFFIX,cn,🌍 全球直连
  # 境外流媒体
  - DOMAIN-SUFFIX,youtube.com,🚀 节点选择
  - DOMAIN-SUFFIX,google.com,🚀 节点选择
  - DOMAIN-SUFFIX,github.com,🚀 节点选择
  - DOMAIN-SUFFIX,githubusercontent.com,🚀 节点选择
  - DOMAIN-SUFFIX,twitter.com,🚀 节点选择
  - DOMAIN-SUFFIX,x.com,🚀 节点选择
  - DOMAIN-SUFFIX,telegram.org,🚀 节点选择
  - DOMAIN-SUFFIX,netflix.com,🚀 节点选择
  - DOMAIN-SUFFIX,githubassets.com,🚀 节点选择
  # GEOIP 兜底
  - GEOIP,CN,🌍 全球直连
  - MATCH,🐟 漏网之鱼
EOF

    # ── 第四步：输出结果与下载方式 ──────────────────────────────
    echo ""
    if [[ -s "$out_file" ]]; then
        # 若脚本通过 sudo 运行（HOME=/root），把文件也复制到原用户目录方便下载
        local user_home="${SUDO_USER:+$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)}"
        if [[ -n "$user_home" && "$user_home" != "$(dirname "$out_dir")" ]]; then
            local user_out_dir="${user_home}/clash-config"
            mkdir -p "$user_out_dir" 2>/dev/null
            cp -f "$out_file" "$user_out_dir/clash-meta.yaml" 2>/dev/null
            chown "${SUDO_USER}:${SUDO_USER:-$(id -g -n "$SUDO_USER" 2>/dev/null)}" "$user_out_dir/clash-meta.yaml" "$user_out_dir" 2>/dev/null || true
            echo -e "${GREEN}✅ Clash.Meta 配置已生成${NC}"
            echo -e "  主文件: ${CYAN}${user_out_dir}/clash-meta.yaml${NC}  （推荐从此处下载）"
            echo -e "  备份:   ${CYAN}${out_file}${NC}"
            out_file="${user_out_dir}/clash-meta.yaml"
            out_dir="${user_out_dir}"
            server_public_ip_display="${SUDO_USER}@${server_public_ip}"
        else
            echo -e "${GREEN}✅ Clash.Meta 配置已生成${NC}"
            echo -e "  目录: ${CYAN}${out_dir}${NC}"
            echo -e "  文件: ${CYAN}${out_file}${NC}"
            server_public_ip_display="${USER}@${server_public_ip}"
        fi

        echo -e "  节点数: ${GREEN}${node_idx}${NC}"
        echo ""
        echo -e "  ${YELLOW}📥  三种下载方式（按推荐度）:${NC}"
        echo -e "  1) SFTP 复制: scp ${server_public_ip_display:-${USER}@${server_public_ip}}:${out_file} ~/Downloads/"
        echo -e "  2) HTTP 下载（可选）: python3 -m http.server 8080 --directory ${out_dir}"
        echo -e "     若无 python3，可用 busybox httpd -f -p 8080 -h ${out_dir}"
        echo -e "     然后浏览器打开: http://${server_public_ip}:8080/clash-meta.yaml"
        echo -e "     （测试完成后记得 Ctrl+C 关闭服务器）"
        echo -e "  3) 直接查看: cat ${out_file}"
        echo ""
        echo -e "  ${YELLOW}🎯  推荐客户端（详见 ./proxy_server.sh --clients）:${NC}"
        echo -e "  macOS  : Clash Verge Rev / mihomo"
        echo -e "  Windows: Clash Verge Rev / mihomo-party"
        echo -e "  Linux  : mihomo / Clash Nyanpasu"
        echo -e "  iOS    : Streisand / Shadowrocket"
        echo -e "  Android: Clash Meta / V2rayNG"
        return 0
    else
        error "生成失败，文件为空"
        return 1
    fi
}

# =====================================================================
# 扩展功能2: MTR 路径分析
# 探测客户端到服务器之间的每一跳延迟和丢包
# =====================================================================
mtr_to() {
    local target="$1"
    local mtr_port="${2:-443}"

    if [[ -z "$target" ]]; then
        read -rp "请输入客户端公网 IP (或域名): " target
    fi
    [[ -z "$target" ]] && { error "未指定目标"; return 1; }

    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}         📍  MTR 路径分析 (目标: ${target}:${mtr_port})${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo ""

    # 安装 mtr
    if ! command -v mtr >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  mtr 未安装，正在安装...${NC}"
        apt-get update -qq && apt-get install -y mtr-tiny >/dev/null 2>&1 \
            || yum install -y mtr >/dev/null 2>&1 \
            || { error "mtr 安装失败，请手动: apt-get install mtr-tiny"; return 1; }
    fi

    echo -e "${CYAN}⏳  正在探测路径（TCP 模式，端口 ${mtr_port}，约 10 秒）...${NC}"
    echo -e "${GRAY}（MTR 会逐跳发送探测包并统计丢包/延迟，用于定位瓶颈所在的 AS）${NC}"
    echo ""

    # 执行 MTR：--tcp 避免 ICMP 被防火墙拦截；--report 生成报告；--report-wide 显示 ASN
    local report
    report=$(mtr --tcp --port "$mtr_port" --report --report-wide --report-cycles 10 "$target" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 || -z "$report" ]]; then
        echo -e "${YELLOW}⚠️  TCP MTR 失败，尝试 ICMP 模式...${NC}"
        report=$(mtr --report --report-wide --report-cycles 10 "$target" 2>&1)
        exit_code=$?
    fi

    if [[ $exit_code -ne 0 || -z "$report" ]]; then
        error "MTR 无法完成探测"
        echo -e "  ${YELLOW}可能原因:${NC}"
        echo -e "  1) ${target} 未回应探测（家用路由器常禁 ICMP）"
        echo -e "  2) 目标不是公网 IP（请提供客户端的出口公网IP）"
        echo -e "  3) 出站防火墙屏蔽了高端口"
        echo ""
        echo -e "  ${CYAN}💡 获取客户端公网IP:${NC}"
        echo -e "     在客户端浏览器打开: https://ifconfig.me  或  https://ipinfo.io"
        echo -e "     在客户端终端执行: curl ifconfig.me"
        return 1
    fi

    echo "$report"
    echo ""

    # 解读关键指标
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}         📊  路径分析摘要${NC}"
    echo -e "${BLUE}==========================================================${NC}"

    local total_loss
    total_loss=$(echo "$report" | awk '/^[0-9]/ {last=$0} END {gsub(/%/, "", last); print last}' | awk '{print $3}')
    local last_avg
    last_avg=$(echo "$report" | awk '/^[0-9]/ {last=$0} END {print last}' | awk '{print $(NF-2)}')

    echo -e "  目标: ${CYAN}${target}:${mtr_port}${NC}"
    echo -e "  总跳数: ${GREEN}$(echo "$report" | grep -cE '^[0-9]')${NC}"
    echo -e "  末端丢包: ${GREEN}${total_loss:-未知}%${NC}"
    echo -e "  末端平均延迟: ${GREEN}${last_avg:-未知} ms${NC}"

    echo ""
    echo -e "${YELLOW}🔍  如何解读:${NC}"
    echo -e "  • 若『跳数 ≤ 3 的某一跳丢包 > 5%』且后续跳数也丢包 —— 问题在运营商/出口链路上"
    echo -e "  • 若『只有最后一跳丢包高』—— 可能是目标机器本身有防探测策略（常见于家用路由器），不代表真实链路质量"
    echo -e "  • 若『中间某跳延迟突然从 20ms 跳到 200ms』—— 该跳数通常是跨境/跨洲海缆，延迟上升属于正常"
    echo -e "  • 若『延迟持续高于 150ms』—— 说明客户端到服务器距离较远，可考虑更换节点区域"
    echo ""
    return 0
}

# =====================================================================
# 扩展功能3: 全平台客户端推荐
# 针对 3x-ui / Marzban / Hiddify 提供 macOS / Linux / Windows / iOS / Android 推荐
# =====================================================================
show_client_recommendations() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}       📱  全平台代理客户端推荐 (针对 3x-ui / Marzban / Hiddify)${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo ""

    echo -e "${CYAN}【3x-ui / Marzban — 通用订阅（Clash / V2ray / Shadowsocks 协议）】${NC}"
    echo ""

    echo -e "${GREEN}🍎  macOS${NC}"
    echo -e "  1) Clash Verge Rev  ⭐ 推荐  ⭐  (https://github.com/clash-verge-rev/clash-verge-rev/releases)"
    echo -e "     — 开源、界面简洁、支持 Clash.Meta 内核；直接导入订阅链接即可"
    echo -e "  2) mihomo-party (https://github.com/mihomo-party-org/mihomo-party/releases)"
    echo -e "     — 由 mihomo 官方维护，功能全面，UI 现代化"
    echo -e "  3) Shadowrocket (App Store 付费购买，$2.99)"
    echo -e "     — 支持 VLESS/Reality/Trojan/Shadowsocks，拖入链接即生效"
    echo ""

    echo -e "${BLUE}🪟  Windows${NC}"
    echo -e "  1) Clash Verge Rev (https://github.com/clash-verge-rev/clash-verge-rev/releases)"
    echo -e "     — 同 macOS 版，Win7/10/11 兼容"
    echo -e "  2) mihomo-party (https://github.com/mihomo-party-org/mihomo-party/releases)"
    echo -e "  3) v2rayN (https://github.com/2dust/v2rayN/releases)"
    echo -e "     — 老牌 V2ray 客户端，适合 VLESS/Trojan/VMess 协议"
    echo ""

    echo -e "${YELLOW}🐧  Linux (Debian/Ubuntu/Fedora/Arch)${NC}"
    echo -e "  1) mihomo (https://github.com/MetaCubeX/mihomo/releases)  ⭐ 推荐"
    echo -e "     — Clash.Meta 的下一代；下载对应架构 .deb 包，或用 systemd 运行"
    echo -e "  2) Clash Nyanpasu (https://github.com/keiko233/clash-nyanpasu/releases)"
    echo -e "     — GUI 版本，基于 Clash Verge 内核重写"
    echo -e "  3) v2rayA (https://github.com/v2rayA/v2rayA)"
    echo -e "     — 纯 Web UI，通过 systemd 管理后端；支持 Docker 一键部署"
    echo ""

    echo -e "${RED}📱  iOS${NC}"
    echo -e "  1) Streisand (国区下架，需切换到外区 App Store 下载，免费)"
    echo -e "  2) Shadowrocket (外区 App Store，$2.99)"
    echo -e "  3) OneClick / Quantumult X (收费，功能更强)"
    echo ""

    echo -e "${GREEN}🤖  Android${NC}"
    echo -e "  1) Clash Meta For Android (https://github.com/MetaCubeX/ClashMetaForAndroid/releases)"
    echo -e "  2) V2rayNG (https://github.com/2dust/v2rayNG/releases)"
    echo -e "  3) NekoBox (https://github.com/MatsuriDayo/NekoBoxForAndroid/releases)"
    echo ""

    echo -e "${CYAN}【Hiddify — Hiddify 自建面板专属客户端】${NC}"
    echo ""

    echo -e "  macOS / Windows / Linux: Hiddify Desktop"
    echo -e "    https://github.com/hiddify/hiddify-next/releases"
    echo -e "    — 官方客户端，支持 Hiddify 面板订阅、自动更新、可视化配置"
    echo ""

    echo -e "  iOS / Android: Hiddify Next"
    echo -e "    https://github.com/hiddify/hiddify-next"
    echo -e "    — 与面板无缝集成，扫描二维码即可导入"
    echo ""

    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}   💡  通用建议（按使用场景排序）${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "  🌐 浏览网页 / 视频 —— Clash Verge Rev / mihomo-party"
    echo -e "  📥 下载大文件 —— 同上 + 确保开启 TCP 并发 (tcp-concurrent: true) 已默认开启"
    echo -e "  📱 手机移动使用 —— Hiddify Next (全平台通用) 或 Shadowrocket"
    echo -e "  🛠️  开发 / 服务器命令行 —— mihomo 纯命令行模式"
    echo ""
    echo -e "${YELLOW}⚠️  安全提示:${NC}"
    echo -e "  1) 切勿使用不知名或付费『加速器』，它们本质上是未知第三方的代理"
    echo -e "  2) 始终从 GitHub 官方 Release 下载客户端；不要用搜索引擎的『中文版』"
    echo -e "  3) Reality/Trojan 协议仅需暴露 443/80 端口，管理面板(54321)请务必限制 IP 访问"
    echo -e "  4) 客户端 DNS 建议开启 fake-ip 模式（proxy_server.sh 生成的配置已开启）"
    echo ""
}

# 验证服务可用性 (本地监听 + 连接测试)
verify_service_access() {
    local port=$1
    local name=$2
    local max_wait=5
    local count=0
    
    echo -e "${BLUE}>>> 正在验证服务端口 ${port} 监听状态...${NC}"
    
    while [ $count -lt $max_wait ]; do
        if command -v ss &>/dev/null; then
            ss -tuln | grep -q ":${port} " && break
        elif command -v lsof &>/dev/null; then
            lsof -i:"$port" >/dev/null 2>&1 && break
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ $count -ge $max_wait ]; then
        if systemctl is-active --quiet "$name" 2>/dev/null || docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            echo -e "${RED}❌ 严重错误: 服务 ${name} 进程虽在线，但端口 ${port} 未监听！${NC}"
            echo -e "${YELLOW}可能原因: 1. 配置文件错误 2. 端口冲突 3. 内部服务仍在初始化${NC}"
        else
            echo -e "${RED}❌ 严重错误: 服务 ${name} 进程已崩溃或未能成功启动！${NC}"
        fi
        echo -e "${CYAN}建议查看日志: journalctl -u ${name} -f (系统版) 或 docker logs ${name}${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ 端口 ${port} 监听正常${NC}"
    
    # 本地连接测试
    if command -v nc &>/dev/null; then
        if nc -z localhost "$port" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 本地连接测试成功${NC}"
        else
            echo -e "${YELLOW}⚠️ 本地 nc 连接失败，请检查服务绑定地址 (是否仅绑定了 IPv6?)${NC}"
        fi
    fi

    # AWS/云服务商提示
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${YELLOW}🔔 云服务器安全组配置提醒:${NC}"
    echo -e "   检测到您可能在云环境运行，请务必在控制台开放以下端口:"
    echo -e "   - 协议: ${GREEN}TCP${NC}"
    echo -e "   - 端口: ${GREEN}${port}${NC}"
    echo -e "   - 来源: ${GREEN}0.0.0.0/0 (或您的 IP)${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    return 0
}

# 防火墙端口管理
manage_firewall() {
    local port=$1
    local proto=${2:-tcp}
    if ! is_linux; then return 0; fi

    echo -e "${BLUE}>>> 检查防火墙状态 (端口: ${port}/${proto})...${NC}"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}检测到 UFW 已开启，自动开放端口 ${port}...${NC}"
        ufw allow "${port}/${proto}" >/dev/null
        echo -e "${GREEN}✅ UFW 端口已开放${NC}"
    fi
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${YELLOW}检测到 Firewalld 已开启，自动开放端口 ${port}...${NC}"
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}✅ Firewalld 端口已开放${NC}"
    fi
    echo -e "${CYAN}提示: 请确保云服务商控制台安全组已开放端口 ${port}${NC}"
}

# 端口与实例管理
check_port() {
    local PORT=$1
    local show_alternative="${2:-true}"
    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${PORT} " && { [ "$show_alternative" = "true" ] && suggest_alternative_ports "$PORT"; return 1; }
    elif command -v lsof &>/dev/null; then
        lsof -i:$PORT > /dev/null 2>&1 && { [ "$show_alternative" = "true" ] && suggest_alternative_ports "$PORT"; return 1; }
    fi
    return 0
}

find_available_port() {
    local port="${1:-54321}"
    local max=100
    while [ $max -gt 0 ]; do
        check_port "$port" false && { echo "$port"; return 0; }
        port=$((port + 1)); max=$((max - 1))
    done
    return 1
}

suggest_alternative_ports() {
    echo -e "${CYAN}建议的替代端口:${NC}"
    local base=$(( $1 + 1000 )), found=0, count=0
    while [ $found -lt 3 ] && [ $count -lt 10 ]; do
        local alt=$((base + count))
        check_port "$alt" false && { echo -e "  ${GREEN}• ${alt}${NC}"; found=$((found + 1)); }
        count=$((count + 1))
    done
}

check_docker_ports() {
    local ports=(80 443 54321 8080 8000), occupied=()
    for p in "${ports[@]}"; do check_port "$p" false || occupied+=("$p"); done
    if [ ${#occupied[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️ 以下端口已被占用: ${occupied[*]}${NC}"
        read -p "继续安装可能导致冲突，是否继续? (y/N) " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
    fi
    return 0
}

# Docker 容器辅助函数
get_container_name() {
    local panel="$1"
    docker ps -a --format '{{.Names}}' | grep "^${panel}" | sort | head -1
}

check_container_exists() {
    local name="$1"
    docker ps -a --format '{{.Names}}' | grep -q "^${name}$"
}

get_container_port() {
    local name="$1"
    local inst_port=$(get_instance_port "$name")
    if [ -z "$inst_port" ]; then
        inst_port=$(docker port "$name" 2>/dev/null | head -1 | cut -d: -f2)
    fi
    echo "$inst_port"
}

ensure_docker_container_running() {
    local name="$1"
    local default_port="$2"
    
    if check_container_exists "$name"; then
        echo -e "${YELLOW}⚠️ 容器 ${name} 已存在，正在检查状态...${NC}"
        if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            echo -e "${YELLOW}检测到容器已停止，正在启动...${NC}"
            docker start "${name}"
        fi
        
        local inst_port=$(get_container_port "$name")
        [ -z "$inst_port" ] && inst_port="${default_port:-未知}"
        
        print_success_info "${name} (Docker)" "$inst_port" "" false
        return 0
    fi
    return 1
}

# 输出新手配置指南
show_post_install_guide() {
    local panel=$1
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${GREEN}🌟 【新手配置指南】 - ${panel}${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    
    if [[ "$panel" == *"3x-ui"* ]]; then
        echo -e "${CYAN}1. 登录面板:${NC}"
        echo -e "   - 在浏览器打开上面提供的面板地址。"
        echo -e "   - 使用生成的随机密码登录 (建议立即在 '面板设置' 中修改)。"
        echo ""
        echo -e "${CYAN}2. 添加入站节点 (推荐: VLESS + TCP + Reality):${NC}"
        echo -e "   - 点击左侧菜单的 ${GREEN}'入站列表'${NC} -> ${GREEN}'添加入站'${NC}。"
        echo -e "   - 基础字段建议这样填:"
        echo -e "     • 备注/Remark: ${GREEN}sg-reality-443${NC}"
        echo -e "     • 启用/Enable: ${GREEN}开启${NC}"
        echo -e "     • 协议/Protocol: ${GREEN}vless${NC}"
        echo -e "     • 监听 IP/Listen: ${GREEN}留空或 0.0.0.0${NC}"
        echo -e "     • 端口/Port: ${GREEN}443${NC}；若 443 已占用可用 8443/2053/2083"
        echo -e "     • 总流量/到期时间: 自用可保持 ${GREEN}0 / 不限制${NC}"
        echo ""
        echo -e "   - 客户端/Client 设置:"
        echo -e "     • 点击添加客户端，Email 例如: ${GREEN}main${NC}"
        echo -e "     • UUID: 使用面板自动生成"
        echo -e "     • Flow: 优先选 ${GREEN}xtls-rprx-vision${NC}；若客户端不支持 Vision，则留空"
        echo -e "     • Limit IP / Total GB / Expiry: 自用可保持 0"
        echo ""
        echo -e "   - 传输/Stream 设置:"
        echo -e "     • Network/传输: ${GREEN}tcp${NC}"
        echo -e "     • TCP Header: ${GREEN}none${NC}"
        echo -e "     • Security/安全: ${GREEN}reality${NC}"
        echo -e "     • uTLS/Fingerprint: ${GREEN}chrome${NC}"
        echo -e "     • Dest/目标网站: ${GREEN}www.microsoft.com:443${NC} 或 ${GREEN}s0.awsstatic.com:443${NC}"
        echo -e "     • Server Names/SNI: 与目标域名一致，例如 ${GREEN}www.microsoft.com${NC}"
        echo -e "     • Private Key/Public Key: 点击面板的 ${GREEN}生成/Generate${NC}"
        echo -e "     • Short IDs: 填 8-16 位十六进制，例如 ${GREEN}$(openssl rand -hex 4 2>/dev/null || echo a1b2c3d4)${NC}"
        echo -e "     • SpiderX: ${GREEN}/${NC}"
        echo ""
        echo -e "   - 保存后确认:"
        echo -e "     • 入站列表显示为启用状态"
        echo -e "     • 服务器上可执行: ${GREEN}ss -tuln | grep ':443 '${NC} 检查监听"
        echo -e "     • AWS 安全组必须放行该节点端口 TCP 443/8443"
        echo -e "     • 管理面板端口 54321 建议只允许自己的公网 IP 访问"
        echo ""
        echo -e "${CYAN}3. 获取客户端连接:${NC}"
        echo -e "   - 入站创建完成后，点击列表中的 ${GREEN}操作/二维码/复制链接${NC}。"
        echo -e "   - 复制 ${GREEN}vless://...${NC} 链接导入客户端。"
        echo -e "   - 推荐客户端:"
        echo -e "     • macOS/Windows: Clash Verge Rev、Hiddify Desktop、v2rayN"
        echo -e "     • Android: v2rayNG、Hiddify Next"
        echo -e "     • iOS: Shadowrocket、Stash、Hiddify Next"
        echo ""
        echo -e "${CYAN}4. 自动配置入口:${NC}"
        echo -e "   - 系统版 3x-ui 安装/更新后默认会自动创建 ${GREEN}sg-reality:443${NC} 入站。"
        echo -e "   - 已存在同名或同端口入站时会跳过，避免刷新 UUID/Reality 密钥。"
        echo -e "   - 只想安装面板、不创建入站时执行:"
        echo -e "     ${GREEN}sudo ./proxy_server.sh --install-3xui --no-auto-config${NC}"
        echo -e "   - 需要指定面板或改端口时执行:"
        echo -e "     ${GREEN}sudo ./proxy_server.sh --auto-config --panel 3x-ui --node-name sg-reality --node-port 443${NC}"
    elif [[ "$panel" == *"Hiddify"* ]]; then
        echo -e "${CYAN}1. 快速初始化:${NC}"
        echo -e "   - 在浏览器打开上面提供的地址，跟随向导设置您的管理员账号和专属域名。"
        echo -e "   - Hiddify 会全自动为您配置好 VLESS, Reality, Hysteria2 等协议！"
        echo ""
        echo -e "${CYAN}2. 连接客户端:${NC}"
        echo -e "   - Hiddify 提供了全平台官方客户端 (Hiddify Next/App)。"
        echo -e "   - 在面板主页即可找到您的专属订阅链接，一键导入即可使用。"
    elif [[ "$panel" == *"Marzban"* ]]; then
        echo -e "${CYAN}1. 登录面板:${NC}"
        echo -e "   - 使用上述显示的随机密码登录 /dashboard/ 后台。"
        echo -e "   - 如果您需要管理多用户和订阅服务，Marzban 是最佳选择。"
        echo ""
        echo -e "${CYAN}2. 配置与分发:${NC}"
        echo -e "   - 在 'Users' 界面创建新用户，面板将自动生成精美的订阅链接网页供用户使用。"
    fi
    echo -e "${BLUE}==========================================================${NC}"
}

print_success_info() {
    local panel_name="$1"
    local port="$2"
    local url_suffix="$3"
    local show_credentials="${4:-true}"
    
    echo -e "${GREEN}✅ ${panel_name} 运行中 / 安装成功!${NC}"
    echo -e "${CYAN}面板地址: http://$(get_public_ip):${port}${url_suffix}${NC}"
    
    if [ "$show_credentials" = true ]; then
        echo -e "${YELLOW}默认账号: admin${NC}"
        echo -e "${YELLOW}建议首次登录后立即修改密码${NC}"
    fi
}

get_next_instance_name() {
    local base="3x-ui", instances=$(docker ps -a --format '{{.Names}}' | grep "^3x-ui" | sort)
    [ -z "$instances" ] && { echo "$base"; return 0; }
    echo "$instances" | grep -q "^${base}$" || { echo "$base"; return 0; }
    local num=2
    while true; do
        echo "$instances" | grep -q "^${base}-${num}$" || { echo "${base}-${num}"; return 0; }
        num=$((num + 1))
    done
}

save_instance_info() {
    touch "$INSTANCES_FILE"
    grep -q "^${1}:" "$INSTANCES_FILE" 2>/dev/null && \
        sed -i "s/^${1}:.*/${1}:${2}:${3}/" "$INSTANCES_FILE" || \
        echo "${1}:${2}:${3}" >> "$INSTANCES_FILE"
}

remove_instance_info() { sed -i "/^${1}:/d" "$INSTANCES_FILE" 2>/dev/null; }
get_instance_port() { grep "^${1}:" "$INSTANCES_FILE" 2>/dev/null | cut -d: -f2; }

# 解析命令行参数
parse_args() {
    local port=""
    local name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) port="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    echo "${port}|${name}"
}

# 3x-ui 安装
install_3xui_docker() {
    local port="${1:-$(find_available_port 54321)}"
    local name="${2:-$(get_next_instance_name)}"
    local version="${3:-latest}"
    
    # 检查容器是否已存在
    ensure_docker_container_running "$name" "$port" && return 0
    
    check_port "$port" true || return 1
    local config_dir="/etc/${name}"
    mkdir -p "$config_dir"
    
    echo -e "${BLUE}>>> 正在以镜像标签 ${version} 启动容器...${NC}"
    docker run -itd -p ${port}:${port} -v ${config_dir}:/etc/x-ui --name ${name} --restart=unless-stopped enwaiax/3x-ui:${version}
    
    if [ $? -eq 0 ]; then
        manage_firewall "$port"
        save_instance_info "$name" "$port" "$config_dir"
        
        local password=$(generate_random_password 12)
        print_success_info "3x-ui (Docker)" "$port" "" true
        echo -e "${YELLOW}随机密码: ${password}${NC}"
        
        verify_service_access "$port" "$name"
    else
        rmdir "$config_dir" 2>/dev/null; return 1
    fi
}

install_3xui_system() {
    local version="${1:-latest}"
    if [ -f "$BIN_FILE" ]; then
        echo -e "${YELLOW}⚠️ 3x-ui (System) 已安装，正在检查状态...${NC}"
        if ! systemctl is-active --quiet x-ui; then
            echo -e "${YELLOW}检测到服务未启动，正在启动...${NC}"
            systemctl start x-ui
        fi
        
        # 尝试提取端口
        local port="54321" # 默认端口
        if [ -f "$CONFIG_DIR/config.json" ]; then
            port=$(grep '"listen":' "$CONFIG_DIR/config.json" | head -1 | tr -dc '0-9')
            [ -z "$port" ] && port="54321"
        fi
        
        echo -e "${GREEN}✅ 3x-ui (System) 运行中${NC}"
        echo -e "${CYAN}面板地址: http://$(get_public_ip):${port}${NC}"
        verify_service_access "$port" "x-ui"
        return 0
    fi
    command -v apt-get &>/dev/null && apt-get update -qq && apt-get install -y wget curl unzip openssl
    command -v yum &>/dev/null && yum install -y wget curl unzip openssl
    local arch=$(detect_arch)
    
    # 构造下载 URL (传递给 download_from_github 的应该是相对路径)
    local download_url
    if [ "$version" == "latest" ]; then
        download_url="MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz"
    else
        download_url="MHSanaei/3x-ui/releases/download/${version}/x-ui-linux-${arch}.tar.gz"
    fi

    if download_from_github "$download_url" "/tmp/x-ui.tar.gz"; then
        mkdir -p "$INSTALL_DIR" && tar -xzf /tmp/x-ui.tar.gz -C "$INSTALL_DIR" --strip-components=1
        chmod +x "$INSTALL_DIR/x-ui" && ln -sf "$INSTALL_DIR/x-ui" "$BIN_FILE"
        mkdir -p "$CONFIG_DIR"
        
        cat > /etc/systemd/system/x-ui.service << 'EOF'
[Unit]
Description=x-ui service
After=network.target
[Service]
User=root
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/bin/x-ui
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable x-ui && systemctl start x-ui
        sleep 3 # 等待服务初始化 SQLite 数据库
        
        if systemctl is-active --quiet x-ui; then
            local admin_password=$(generate_random_password 12)
            # 使用官方命令行工具将端口强制设置为 54321，并初始化账密
            "$BIN_FILE" setting -port 54321 -username admin -password "$admin_password" >/dev/null 2>&1 || true
            systemctl restart x-ui
            sleep 2
            
            manage_firewall 54321
            echo -e "${GREEN}✅ 系统版 3x-ui (${version}) 已启动${NC}\n地址: http://$(get_public_ip):54321"
            echo -e "${YELLOW}默认账号: admin${NC}"
            echo -e "${YELLOW}随机密码: ${admin_password}${NC}"
            verify_service_access "54321" "x-ui"
        else
            echo -e "${RED}❌ x-ui 服务启动失败，请查看: journalctl -u x-ui -n 100${NC}"
            rm -f /tmp/x-ui.tar.gz
            return 1
        fi
        rm -f /tmp/x-ui.tar.gz
        return 0
    else
        echo -e "${RED}❌ 版本 ${version} 下载失败${NC}"
        return 1
    fi
}

auto_config_3xui_reality() {
    local node_name="${1:-${AUTO_NODE_NAME:-自动节点-REALITY}}"
    local inbound_port="${2:-${AUTO_NODE_PORT:-443}}"
    local reality_target="${3:-${REALITY_TARGET:-s0.awsstatic.com:443}}"
    local reality_sni="${4:-${REALITY_SNI:-${reality_target%%:*}}}"
    local db_file="/etc/x-ui/x-ui.db"
    local xray_bin=""
    local key_output private_key public_key client_uuid short_id public_ip

    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}        自动配置 3x-ui VLESS + TCP + Reality 入站${NC}"
    echo -e "${BLUE}==========================================================${NC}"

    if [ ! -f "$BIN_FILE" ] || [ ! -f "$db_file" ]; then
        echo -e "${RED}❌ 未检测到系统版 3x-ui 或数据库，请先运行 --install-3xui${NC}"
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 安装 sqlite3 以写入 3x-ui 数据库...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null && apt-get install -y sqlite3 >/dev/null || return 1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y sqlite >/dev/null || return 1
        else
            echo -e "${RED}❌ 未找到支持的包管理器，无法安装 sqlite3${NC}"
            return 1
        fi
    fi

    xray_bin=$(find "$INSTALL_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' | head -1)
    if [ -z "$xray_bin" ] || [ ! -x "$xray_bin" ]; then
        echo -e "${RED}❌ 未找到 xray 二进制文件: $INSTALL_DIR/bin/xray-linux-*${NC}"
        return 1
    fi

    key_output=$("$xray_bin" x25519 2>/dev/null || true)
    private_key=$(echo "$key_output" | awk -F': *' '$1 == "PrivateKey" {print $2; exit}')
    public_key=$(echo "$key_output" | awk -F': *' '$1 == "Password (PublicKey)" {print $2; exit}')
    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        echo -e "${RED}❌ 生成 Reality x25519 密钥失败${NC}"
        echo "$key_output"
        return 1
    fi

    client_uuid=$(cat /proc/sys/kernel/random/uuid)
    short_id=$(openssl rand -hex 8)

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}❌ 自动写入 3x-ui 数据库需要 python3（用于安全生成 JSON 并写入 SQLite）${NC}"
        echo -e "${YELLOW}提示: 可安装 python3 后重试，或在面板中按下方指南手动创建入站。${NC}"
        return 1
    fi

    AUTO_NODE_NAME="$node_name" \
    AUTO_NODE_PORT="$inbound_port" \
    REALITY_TARGET="$reality_target" \
    REALITY_SNI="$reality_sni" \
    REALITY_PRIVATE_KEY="$private_key" \
    REALITY_PUBLIC_KEY="$public_key" \
    REALITY_CLIENT_UUID="$client_uuid" \
    REALITY_SHORT_ID="$short_id" \
    python3 - <<'PY'
import json
import os
import sqlite3
import time

db_file = "/etc/x-ui/x-ui.db"
node_name = os.environ["AUTO_NODE_NAME"]
port = int(os.environ["AUTO_NODE_PORT"])
target = os.environ["REALITY_TARGET"]
sni = os.environ["REALITY_SNI"]
private_key = os.environ["REALITY_PRIVATE_KEY"]
public_key = os.environ["REALITY_PUBLIC_KEY"]
client_uuid = os.environ["REALITY_CLIENT_UUID"]
short_id = os.environ["REALITY_SHORT_ID"]
email = node_name.lower().replace(" ", "-")
for ch in "/\\:@#?&=%":
    email = email.replace(ch, "-")
if not email:
    email = "auto-reality"
sub_id = ("sub" + short_id)[:32]
now_ms = int(time.time() * 1000)

settings = {
    "clients": [{
        "id": client_uuid,
        "flow": "",
        "email": email,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "tgId": "",
        "subId": sub_id,
        "comment": "",
        "reset": 0,
        "created_at": now_ms,
        "updated_at": now_ms,
    }],
    "decryption": "none",
    "fallbacks": [],
}
stream = {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
        "show": False,
        "xver": 0,
        "target": target,
        "serverNames": [sni],
        "privateKey": private_key,
        "minClientVer": "",
        "maxClientVer": "",
        "maxTimediff": 0,
        "shortIds": [short_id],
        "settings": {
            "publicKey": public_key,
            "fingerprint": "chrome",
            "serverName": "",
            "spiderX": "/",
        },
        "fingerprint": "chrome",
    },
    "tcpSettings": {
        "acceptProxyProtocol": False,
        "header": {"type": "none"},
    },
}
sniffing = {
    "enabled": False,
    "destOverride": ["http", "tls", "quic", "fakedns"],
    "metadataOnly": False,
    "routeOnly": False,
}

con = sqlite3.connect(db_file)
cur = con.cursor()

cur.execute("SELECT id FROM inbounds WHERE port = ? OR remark = ?", (port, node_name))
old_ids = [row[0] for row in cur.fetchall()]
for inbound_id in old_ids:
    cur.execute("DELETE FROM client_inbounds WHERE inbound_id = ?", (inbound_id,))
cur.execute("DELETE FROM inbounds WHERE port = ? OR remark = ?", (port, node_name))
cur.execute("DELETE FROM clients WHERE email = ? OR uuid = ?", (email, client_uuid))

cur.execute(
    """
    INSERT INTO inbounds
      (user_id, up, down, total, remark, sub_sort_index, enable, expiry_time,
       traffic_reset, last_traffic_reset_time, listen, port, protocol,
       settings, stream_settings, tag, sniffing, node_id, share_addr_strategy, share_addr)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
    """,
    (1, 0, 0, 0, node_name, 1, 1, 0, "never", 0, "", port, "vless",
     json.dumps(settings, separators=(",", ":")),
     json.dumps(stream, separators=(",", ":")),
     f"in-{port}-tcp",
     json.dumps(sniffing, separators=(",", ":")),
     "node", ""),
)
inbound_id = cur.lastrowid

cur.execute(
    """
    INSERT INTO clients
      (email, sub_id, uuid, password, auth, flow, security, reverse, limit_ip,
       total_gb, expiry_time, enable, tg_id, group_name, comment, reset, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
    (email, sub_id, client_uuid, "", "", "", "", "", 0, 0, 0, 1, 0, "", "", 0, now_ms, now_ms),
)
client_id = cur.lastrowid
cur.execute(
    "INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at) VALUES (?, ?, ?, ?)",
    (client_id, inbound_id, "", now_ms),
)
con.commit()

print(f"INBOUND_ID={inbound_id}")
print(f"CLIENT_ID={client_id}")
print(f"CLIENT_EMAIL={email}")
PY

    systemctl restart x-ui
    sleep 3
    if ! systemctl is-active --quiet x-ui; then
        echo -e "${RED}❌ x-ui 重启失败，请查看: journalctl -u x-ui -n 100${NC}"
        return 1
    fi

    if ss -tulpn 2>/dev/null | grep -qE "[:.]${inbound_port}\\b"; then
        echo -e "${GREEN}✅ Reality 入站端口 ${inbound_port} 已监听${NC}"
    else
        echo -e "${RED}❌ 端口 ${inbound_port} 未监听，3x-ui 可能未生成该入站到 Xray 配置${NC}"
        echo -e "${YELLOW}提示: 检查 node_id 必须为 NULL，且 clients/client_inbounds 已写入。${NC}"
        return 1
    fi

    manage_firewall "$inbound_port" 2>/dev/null || true
    public_ip=$(get_public_ip)

    echo ""
    echo -e "${GREEN}✅ 自动配置完成${NC}"
    echo -e "节点名称: ${CYAN}${node_name}${NC}"
    echo -e "服务器:   ${CYAN}${public_ip}:${inbound_port}${NC}"
    echo -e "UUID:     ${CYAN}${client_uuid}${NC}"
    echo -e "PublicKey:${CYAN}${public_key}${NC}"
    echo -e "ShortId:  ${CYAN}${short_id}${NC}"
    echo -e "SNI:      ${CYAN}${reality_sni}${NC}"
    echo ""
    echo -e "${CYAN}Clash.Meta 节点片段:${NC}"
    cat <<EOF
- name: ${node_name}
  type: vless
  server: ${public_ip}
  port: ${inbound_port}
  uuid: ${client_uuid}
  network: tcp
  tls: true
  udp: true
  client-fingerprint: chrome
  servername: ${reality_sni}
  reality-opts:
    public-key: "${public_key}"
    short-id: ${short_id}
EOF
    echo ""
    echo -e "${YELLOW}请确保云安全组开放 TCP ${inbound_port}；面板/SSH 端口建议仅允许自己的公网 IP。${NC}"
}

maybe_auto_config_3xui_reality() {
    local node_name="${1:-$AUTO_NODE_NAME}"
    local inbound_port="${2:-$AUTO_NODE_PORT}"
    local reality_target="${3:-$REALITY_TARGET}"
    local reality_sni="${4:-$REALITY_SNI}"
    local db_file="/etc/x-ui/x-ui.db"
    local existing_count=""

    if [ "${AUTO_CONFIG_3XUI:-1}" != "1" ]; then
        echo -e "${YELLOW}已按配置跳过 3x-ui 入站自动配置${NC}"
        return 0
    fi

    if [ ! -f "$BIN_FILE" ] || [ ! -f "$db_file" ]; then
        echo -e "${YELLOW}当前不是系统版 3x-ui，已跳过自动写入 Reality 入站。自动入站配置目前仅支持系统版。${NC}"
        return 0
    fi

    if ! [[ "$inbound_port" =~ ^[0-9]+$ ]] || [ "$inbound_port" -lt 1 ] || [ "$inbound_port" -gt 65535 ]; then
        echo -e "${RED}❌ 自动配置端口无效: ${inbound_port}${NC}"
        return 1
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        local safe_node_name="${node_name//\'/\'\'}"
        existing_count=$(sqlite3 "$db_file" "SELECT COUNT(*) FROM inbounds WHERE port = ${inbound_port} OR remark = '${safe_node_name}';" 2>/dev/null || true)
        if [[ "$existing_count" =~ ^[0-9]+$ ]] && [ "$existing_count" -gt 0 ]; then
            echo -e "${GREEN}✅ 已存在 3x-ui 入站 ${node_name}/${inbound_port}，跳过自动配置，避免刷新客户端参数${NC}"
            return 0
        fi
    fi

    echo -e "${BLUE}>>> 安装完成，自动创建 3x-ui VLESS + TCP + Reality 入站...${NC}"
    auto_config_3xui_reality "$node_name" "$inbound_port" "$reality_target" "$reality_sni"
}

discover_auto_config_targets() {
    local requested_panel="${1:-auto}"
    local include_unsupported="${2:-false}"
    local panel_filter

    panel_filter="$(echo "$requested_panel" | tr '[:upper:]' '[:lower:]')"
    case "$panel_filter" in
        ""|auto|all) panel_filter="auto" ;;
        3x-ui|3xui|x-ui|xui) panel_filter="3x-ui" ;;
        hiddify) panel_filter="hiddify" ;;
        marzban) panel_filter="marzban" ;;
        *)
            echo "unsupported|${requested_panel}|unknown|未知面板类型"
            return 0
            ;;
    esac

    if { [ "$panel_filter" = "auto" ] || [ "$panel_filter" = "3x-ui" ]; } && [ -f "$BIN_FILE" ] && [ -f "/etc/x-ui/x-ui.db" ]; then
        echo "3x-ui|3x-ui-system|system|系统版 3x-ui"
    fi

    if command -v docker >/dev/null 2>&1; then
        local name
        if [ "$panel_filter" = "auto" ] || [ "$panel_filter" = "3x-ui" ]; then
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                if [ "$include_unsupported" = "true" ]; then
                    echo "unsupported|${name}|docker|3x-ui Docker 实例（暂不支持自动写入 Reality 入站）"
                fi
            done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^3x-ui' | sort || true)
        fi

        if [ "$include_unsupported" = "true" ] && { [ "$panel_filter" = "auto" ] || [ "$panel_filter" = "hiddify" ]; } && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^hiddify$'; then
            echo "unsupported|hiddify|docker|Hiddify（面板自带初始化/订阅，暂不写入业务配置）"
        fi

        if [ "$include_unsupported" = "true" ] && { [ "$panel_filter" = "auto" ] || [ "$panel_filter" = "marzban" ]; } && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^marzban$'; then
            echo "unsupported|marzban|docker|Marzban（多用户模型复杂，暂不写入业务配置）"
        fi
    fi
}

auto_config_panel() {
    local requested_panel="${1:-auto}"
    local requested_target="${2:-auto}"
    local node_name="${3:-$AUTO_NODE_NAME}"
    local inbound_port="${4:-$AUTO_NODE_PORT}"
    local reality_target="${5:-$REALITY_TARGET}"
    local reality_sni="${6:-$REALITY_SNI}"
    local targets=()
    local all_targets=()
    local row kind target mode desc
    local selected_row=""
    local requested_panel_norm

    requested_panel_norm="$(echo "${requested_panel:-auto}" | tr '[:upper:]' '[:lower:]')"
    case "$requested_panel_norm" in
        ""|all) requested_panel_norm="auto" ;;
    esac

    while IFS= read -r row; do
        [ -z "$row" ] && continue
        all_targets+=("$row")
        IFS='|' read -r kind target mode desc <<< "$row"
        [ "$kind" = "unsupported" ] && continue
        if [ "$requested_target" != "auto" ] && [ "$requested_target" != "$target" ]; then
            continue
        fi
        targets+=("$row")
    done < <(discover_auto_config_targets "$requested_panel" true)

    if [ "$requested_panel_norm" = "auto" ] && [ "$requested_target" = "auto" ] && [ ${#all_targets[@]} -gt 1 ]; then
        echo -e "${CYAN}检测到多个已安装面板/实例，请选择要自动配置的目标:${NC}"
        local i=1 choice
        for row in "${all_targets[@]}"; do
            IFS='|' read -r kind target mode desc <<< "$row"
            if [ "$kind" = "unsupported" ]; then
                echo -e "  ${i}) ${target} (${mode}) ${YELLOW}${desc}${NC}"
            else
                echo -e "  ${i}) ${target} (${mode}) ${GREEN}${desc}${NC}"
            fi
            i=$((i + 1))
        done
        read -rp "请选择 [1-${#all_targets[@]}]: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#all_targets[@]} ]; then
            echo -e "${RED}❌ 选择无效，已取消自动配置${NC}"
            return 1
        fi
        selected_row="${all_targets[$((choice - 1))]}"
        IFS='|' read -r kind target mode desc <<< "$selected_row"
        if [ "$kind" = "unsupported" ]; then
            echo -e "${RED}❌ ${target} 暂不支持自动写入业务配置${NC}"
            echo -e "${YELLOW}${desc}${NC}"
            return 1
        fi
        targets=("$selected_row")
    fi

    if [ "$requested_target" != "auto" ] && [ ${#targets[@]} -eq 0 ]; then
        echo -e "${RED}❌ 未找到可自动配置的目标: ${requested_target}${NC}"
        if [ ${#all_targets[@]} -gt 0 ]; then
            echo -e "${CYAN}已检测到的面板:${NC}"
            for row in "${all_targets[@]}"; do
                IFS='|' read -r kind target mode desc <<< "$row"
                echo -e "  - ${target} (${mode}) ${desc}"
            done
        fi
        return 1
    fi

    if [ ${#targets[@]} -eq 0 ]; then
        echo -e "${RED}❌ 未检测到可自动配置的面板。当前自动配置仅支持系统版 3x-ui。${NC}"
        if [ ${#all_targets[@]} -gt 0 ]; then
            echo -e "${CYAN}已检测到但暂不支持自动写配置的面板:${NC}"
            for row in "${all_targets[@]}"; do
                IFS='|' read -r kind target mode desc <<< "$row"
                [ "$kind" != "unsupported" ] && continue
                echo -e "  - ${target} (${mode}) ${desc}"
            done
        fi
        return 1
    fi

    if [ ${#targets[@]} -eq 1 ]; then
        IFS='|' read -r kind target mode desc <<< "${targets[0]}"
        if [ ${#all_targets[@]} -eq 1 ]; then
            echo -e "${GREEN}✅ 自动选择唯一已安装目标: ${desc} (${target})${NC}"
        else
            echo -e "${GREEN}✅ 已选择可配置目标: ${desc} (${target})${NC}"
        fi
    else
        echo -e "${CYAN}检测到多个可自动配置目标，请选择:${NC}"
        local i=1 choice
        for row in "${targets[@]}"; do
            IFS='|' read -r kind target mode desc <<< "$row"
            echo -e "  ${i}) ${desc} (${target})"
            i=$((i + 1))
        done
        read -rp "请选择 [1-${#targets[@]}]: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#targets[@]} ]; then
            echo -e "${RED}❌ 选择无效，已取消自动配置${NC}"
            return 1
        fi
        IFS='|' read -r kind target mode desc <<< "${targets[$((choice - 1))]}"
    fi

    case "$target" in
        3x-ui-system)
            maybe_auto_config_3xui_reality "$node_name" "$inbound_port" "$reality_target" "$reality_sni"
            ;;
        *)
            echo -e "${RED}❌ 目标暂不支持自动配置: ${target}${NC}"
            return 1
            ;;
    esac
}

# 带超时的交互提示
prompt_with_timeout() {
    local message="$1"
    local default_val="$2"
    local timeout_sec="$3"
    local user_input
    
    # 提示信息重定向到 stderr，确保 $() 只能捕获到最后的 echo 结果
    echo -ne "${YELLOW}${message} (默认: ${default_val}, ${timeout_sec}s 超时): ${NC}" >&2
    read -t "$timeout_sec" user_input
    
    if [ -z "$user_input" ]; then
        echo -e "\n${BLUE}>>> 超时，使用默认值: ${default_val}${NC}" >&2
        echo "$default_val"
    else
        echo "$user_input"
    fi
}

# 获取远程最新 10 个版本
get_remote_versions_list() {
    local repo="$1"
    # 使用 stderr 输出进度
    echo -e "${BLUE}>>> 正在获取版本列表...${NC}" >&2
    curl -s "https://api.github.com/repos/${repo}/releases?per_page=10" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 10
}

# 提取 x-ui 实际运行端口
get_xui_system_port() {
    local port="54321"
    
    # 尝试 0: 从 x-ui cli 获取 (最准确)
    if [ -f "$BIN_FILE" ]; then
        local cli_port=$("$BIN_FILE" setting -show 2>/dev/null | grep "^port:" | awk '{print $2}' | tr -dc '0-9')
        if [ -n "$cli_port" ]; then
            echo "$cli_port"
            return 0
        fi
    fi
    
    # 尝试 1: 从原 json 配置读取
    if [ -f "$CONFIG_DIR/config.json" ]; then
        local json_port=$(grep '"listen":' "$CONFIG_DIR/config.json" | head -1 | tr -dc '0-9')
        if [ -n "$json_port" ]; then
            port="$json_port"
        fi
    fi
    
    # 尝试 2: 如果进程在线，通过 ss 动态获取
    if command -v ss &>/dev/null; then
        local active_port=$(ss -tulnp | grep "x-ui" | head -1 | awk '{print $5}' | cut -d: -f2)
        if [ -n "$active_port" ] && [[ "$active_port" =~ ^[0-9]+$ ]]; then
            port="$active_port"
        fi
    fi
    
    echo "$port"
}

# 3x-ui 更新流程 (主机系统模式)
update_3xui_system_flow() {
    local selected_version="$1"
    echo -e "${CYAN}>>> 准备更新至版本: ${selected_version} (主机模式)...${NC}"
    local choice=$(prompt_with_timeout "请选择更新策略: [1] Nginx 自动无缝切换面板 (推荐) [2] 极速停机更新 (无 Nginx)" "1" 8)
    
    local arch=$(detect_arch)
    local download_url
    if [ "$selected_version" == "latest" ]; then
        download_url="MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz"
    else
        download_url="MHSanaei/3x-ui/releases/download/${selected_version}/x-ui-linux-${arch}.tar.gz"
    fi

    if [ "$choice" == "1" ]; then
        local old_port=$(get_xui_system_port)
        local new_port=$(find_available_port $((old_port + 1)))
        
        echo -e "${BLUE}>>> 执行 Nginx 无缝切换更新方案...${NC}"
        echo -e "${YELLOW}说明: 由于 Xray 代理节点必须独占端口，核心流量必然会有 ~1 秒闪断。此模式主要实现“管理面板”的零停机自动切换。${NC}"
        echo -e "${YELLOW}1. 正在后台准备新版本 ${selected_version} 的环境...${NC}"
        
        local tmp_file="/tmp/x-ui-blue.tar.gz"
        local blue_dir="/usr/local/x-ui-blue"
        
        if download_file "$download_url" "$tmp_file"; then
            mkdir -p "$blue_dir"
            tar -xzf "$tmp_file" -C "$blue_dir" --strip-components=1
            echo -e "${GREEN}✅ 新版本文件已就绪。${NC}"
            
            # 自动化 Nginx 切换
            echo -e "${BLUE}>>> 尝试自动配置 Nginx 蓝绿切换...${NC}"
            if command -v nginx &>/dev/null; then
                # 寻找包含旧端口的 nginx 配置文件
                local nginx_confs=$(grep -rl "127.0.0.1:${old_port}" /etc/nginx/ 2>/dev/null)
                if [ -n "$nginx_confs" ]; then
                    echo -e "${GREEN}✅ 找到对应的 Nginx 代理配置！${NC}"
                    
                    # 修改 3x-ui 配置文件中的端口
                    sed -i "s/\"listen\": [0-9]*/\"listen\": ${new_port}/g" "$CONFIG_DIR/config.json"
                    
                    # 极速替换：停止旧服务并使用新目录启动
                    echo -e "${YELLOW}>>> 正在极速重启代理内核 (预计中断 < 1 秒)...${NC}"
                    systemctl stop x-ui
                    rm -rf "$INSTALL_DIR"
                    mv "$blue_dir" "$INSTALL_DIR"
                    chmod +x "$INSTALL_DIR/x-ui"
                    chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
                    systemctl start x-ui
                    
                    # 使用 x-ui 自带命令强制修改数据库中的面板端口
                    sleep 2
                    /usr/local/bin/x-ui setting -port "$new_port" >/dev/null 2>&1 || true
                    systemctl restart x-ui
                    
                    # 验证新端口
                    verify_service_access "$new_port" "x-ui"
                    
                    # 修改 Nginx 配置并 reload
                    for conf in $nginx_confs; do
                        sed -i "s/127.0.0.1:${old_port}/127.0.0.1:${new_port}/g" "$conf"
                        echo -e "${GREEN}✅ 已自动更新 Nginx 配置: $conf${NC}"
                    done
                    
                    nginx -t >/dev/null 2>&1 && nginx -s reload
                    echo -e "${GREEN}🚀 自动切换完成！面板已无缝切换至新端口 ${new_port}。${NC}"
                else
                    echo -e "${YELLOW}⚠️ 未在 /etc/nginx/ 找到包含旧端口 (${old_port}) 的配置文件。${NC}"
                    echo -e "${CYAN}回退为极速停机更新模式...${NC}"
                    systemctl stop x-ui
                    rm -rf "$INSTALL_DIR"
                    mv "$blue_dir" "$INSTALL_DIR"
                    chmod +x "$INSTALL_DIR/x-ui"
                    chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
                    systemctl start x-ui
                    verify_service_access "$old_port" "x-ui"
                fi
            else
                echo -e "${YELLOW}⚠️ 系统未检测到 Nginx，回退为极速停机更新模式...${NC}"
                systemctl stop x-ui
                rm -rf "$INSTALL_DIR"
                mv "$blue_dir" "$INSTALL_DIR"
                chmod +x "$INSTALL_DIR/x-ui"
                chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
                systemctl start x-ui
                verify_service_access "$old_port" "x-ui"
            fi
            rm -f "$tmp_file"
        fi
    else
        echo -e "${BLUE}>>> 执行极速停机更新至 ${selected_version}...${NC}"
        echo -e "${YELLOW}1. 正在后台下载新版本 (不影响当前服务)...${NC}"
        local tmp_file="/tmp/x-ui-update.tar.gz"
        local new_dir="/usr/local/x-ui-new"
        
        if download_file "$download_url" "$tmp_file"; then
            mkdir -p "$new_dir"
            tar -xzf "$tmp_file" -C "$new_dir" --strip-components=1
            echo -e "${YELLOW}2. 执行极速替换 (预计中断 < 1 秒)...${NC}"
            
            local current_port=$(get_xui_system_port)
            
            systemctl stop x-ui
            rm -rf "$INSTALL_DIR"
            mv "$new_dir" "$INSTALL_DIR"
            chmod +x "$INSTALL_DIR/x-ui"
            chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
            systemctl start x-ui
            rm -f "$tmp_file"
            echo -e "${GREEN}✅ 3x-ui 系统版极速更新至 ${selected_version} 完成！${NC}"
            
            verify_service_access "$current_port" "x-ui"
        fi
    fi
}

# 卸载逻辑
uninstall_3xui() {
    local target_name="$1"
    if [ -n "$target_name" ]; then
        if command -v docker &>/dev/null; then
            docker stop "$target_name" 2>/dev/null
            docker rm "$target_name" 2>/dev/null
        fi
        remove_instance_info "$target_name"
    else
        local instances=""
        if command -v docker &>/dev/null; then
            instances=$(docker ps -a --format '{{.Names}}' | grep "^3x-ui")
        fi
        if [ -n "$instances" ]; then
            echo -e "${YELLOW}检测到 Docker 版 3x-ui 实例，请使用 --uninstall --panel 3x-ui 选择卸载目标${NC}"
            return 1;
        fi
        echo -e "${BLUE}>>> 正在卸载 3x-ui 系统版...${NC}"
        systemctl stop x-ui 2>/dev/null || true
        systemctl disable x-ui 2>/dev/null || true
        rm -f /etc/systemd/system/x-ui.service
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$BIN_FILE"
        echo -e "${GREEN}✅ 3x-ui 已成功卸载。${NC}"
    fi
}

# 自动卸载面板逻辑
auto_uninstall_panel() {
    local requested_panel="${1:-auto}"
    local requested_target="${2:-auto}"
    local found_targets=()

    echo -e "${BLUE}>>> 正在扫描已安装的面板以执行自动卸载...${NC}"

    # 扫描系统版 3x-ui
    if [ -f "$BIN_FILE" ]; then
        if [[ "$requested_panel" == "auto" || "$requested_panel" == "3x-ui" || "$requested_panel" == "3xui" ]]; then
            if [[ "$requested_target" == "auto" || "$requested_target" == "3x-ui-system" ]]; then
                found_targets+=("3x-ui:system:3x-ui-system")
            fi
        fi
    fi

    # 扫描 Docker 容器
    if command -v docker &>/dev/null; then
        local docker_panels
        docker_panels=$(docker ps -a --format '{{.Names}}' | grep -E "3x-ui|hiddify|marzban" || true)
        for name in $docker_panels; do
            local type=""
            [[ "$name" == 3x-ui* ]] && type="3x-ui"
            [[ "$name" == hiddify* ]] && type="hiddify"
            [[ "$name" == marzban* ]] && type="marzban"

            if [[ "$requested_panel" == "auto" || "$requested_panel" == "$type" ]]; then
                if [[ "$requested_target" == "auto" || "$requested_target" == "$name" ]]; then
                    found_targets+=("${type}:docker:${name}")
                fi
            fi
        done
    fi

    if [ ${#found_targets[@]} -eq 0 ]; then
        echo -e "${YELLOW}未发现匹配的已安装面板。${NC}"
        return 0
    fi

    local target_to_uninstall=""
    if [ ${#found_targets[@]} -eq 1 ]; then
        target_to_uninstall="${found_targets[0]}"
    else
        echo -e "${YELLOW}发现多个安装目标，请选择要卸载的一个:${NC}"
        local i=1
        for t in "${found_targets[@]}"; do
            local ptype=$(echo "$t" | cut -d: -f1)
            local pmode=$(echo "$t" | cut -d: -f2)
            local pname=$(echo "$t" | cut -d: -f3)
            echo -e "  $i) $ptype ($pmode) - $pname"
            i=$((i+1))
        done
        read -rp "请选择 [1-$((i-1))]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            target_to_uninstall="${found_targets[$((choice-1))]}"
        else
            echo -e "${RED}选择无效。${NC}"
            return 1
        fi
    fi

    local ptype=$(echo "$target_to_uninstall" | cut -d: -f1)
    local pmode=$(echo "$target_to_uninstall" | cut -d: -f2)
    local pname=$(echo "$target_to_uninstall" | cut -d: -f3)

    echo -e "${YELLOW}警告: 即将卸载 $ptype ($pmode) 实例: $pname${NC}"

    case "$ptype" in
        3x-ui)
            if [ "$pmode" == "system" ]; then
                uninstall_3xui
            else
                uninstall_3xui "$pname"
            fi
            ;;
        hiddify)
            docker stop "$pname" 2>/dev/null
            docker rm "$pname" 2>/dev/null
            rm -rf /opt/hiddify
            echo -e "${GREEN}✅ Hiddify 已成功卸载。${NC}"
            ;;
        marzban)
            if [ -d /tmp/marzban ]; then
                cd /tmp/marzban && docker compose down
                rm -rf /tmp/marzban
            else
                docker stop "$pname" 2>/dev/null
                docker rm "$pname" 2>/dev/null
            fi
            echo -e "${GREEN}✅ Marzban 已成功卸载。${NC}"
            ;;
    esac
}

uninstall_menu() {
    echo -e "1. 卸载 3x-ui\n2. 卸载 Hiddify\n3. 卸载 Marzban\n0. 返回"
    read -p "选择: " choice
    case $choice in
        1) uninstall_3xui ;;
        2) 
           if command -v docker &>/dev/null; then
               docker stop hiddify 2>/dev/null
               docker rm hiddify 2>/dev/null
           fi
           rm -rf /opt/hiddify
           ;;
        3) 
           if command -v docker &>/dev/null && [ -d /tmp/marzban ]; then
               cd /tmp/marzban && docker compose down
           fi
           rm -rf /tmp/marzban
           ;;
        *) return ;;
    esac
}

# 3x-ui 安装入口
install_3xui() {
    # 无论安装还是更新，首先应用主机优化（其中包含 AWS 实例提示）
    echo -e "${BLUE}>>> 安装前自动应用系统内核/网络优化...${NC}"
    apply_host_tuning --silent
    check_adl

    local is_installed=false
    if [ -f "$BIN_FILE" ] || { command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "3x-ui"; }; then
        is_installed=true
    fi

    local action="C"
    local current_version="未知"
    
    if [ "$is_installed" = true ]; then
        if [ -f "$BIN_FILE" ]; then
            local raw_ver=$("$BIN_FILE" -v 2>/dev/null | head -1)
            local extracted_ver=$(echo "$raw_ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [ -n "$extracted_ver" ]; then
                current_version="v${extracted_ver}"
            else
                current_version="未知"
            fi
        elif command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "3x-ui"; then
            local cname=$(docker ps -a --format '{{.Names}}' | grep "3x-ui" | head -1)
            current_version=$(docker inspect --format '{{.Config.Image}}' "$cname" 2>/dev/null | cut -d: -f2)
            [ -z "$current_version" ] && current_version="未知"
        fi
        
        echo -e "${YELLOW}⚠️ 检测到 3x-ui 已安装 (当前版本: ${current_version})。${NC}"
        action=$(prompt_with_timeout "请选择操作: [U] 卸载并重装 [C] 检测更新" "C" 8)
        
        # 将输入统一转为大写处理
        action=$(echo "$action" | tr '[:lower:]' '[:upper:]')
        
        if [ "$action" == "U" ]; then
            uninstall_3xui
            is_installed=false
            current_version="未知" # 重置当前版本，防止触发防重复更新机制
            echo -e "${GREEN}>>> 卸载完成，准备执行全新安装...${NC}"
            sleep 1
        fi
    fi

    # 如果是更新 (或者是全新安装)，都需要选版本
    local versions=($(get_remote_versions_list "MHSanaei/3x-ui"))
    if [ ${#versions[@]} -eq 0 ]; then
        echo -e "${RED}无法获取版本列表，将使用最新版本进行操作。${NC}"
        versions=("latest")
    fi

    echo -e "${CYAN}--- 最近 10 个版本列表 ---${NC}"
    for i in "${!versions[@]}"; do
        local marker=""
        [ $i -eq 0 ] && marker="${GREEN}(最新推荐)${NC}"
        if [[ "${versions[$i]}" == *"${current_version}"* ]] && [ "$current_version" != "未知" ]; then
            marker="${marker} ${YELLOW}<- (当前安装)${NC}"
        fi
        echo -e "  $((i+1))) ${versions[$i]} ${marker}"
    done

    local v_choice=$(prompt_with_timeout "请选择要安装/更新的版本编号" "1" 8)
    
    # 算术安全检查
    if ! [[ "$v_choice" =~ ^[0-9]+$ ]] || [ "$v_choice" -lt 1 ] || [ "$v_choice" -gt ${#versions[@]} ]; then
        v_choice=1
    fi
    
    local selected_v="${versions[$((v_choice-1))]}"
    [ -z "$selected_v" ] && selected_v="${versions[0]}"

    if [ "$is_installed" = true ]; then
        # 检测是否已经是最新的/所选的
        if [[ "$selected_v" == *"${current_version}"* ]] && [ "$current_version" != "未知" ]; then
            echo -e "${GREEN}✅ 检测到当前已安装版本 (${current_version}) 即为您选择的版本 (${selected_v})。${NC}"
            echo -e "${CYAN}无需重复更新。${NC}"
            
            # 无论是否更新，最后都检测并输出服务状态
            local check_name="x-ui"
            local check_port="54321"
            if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "3x-ui"; then
                check_name=$(docker ps -a --format '{{.Names}}' | grep "3x-ui" | head -1)
                check_port=$(get_container_port "$check_name")
            else
                check_port=$(get_xui_system_port)
            fi
            echo -e "${BLUE}>>> 正在为您检查当前服务状态...${NC}"
            verify_service_access "$check_port" "$check_name"
            echo -e "${CYAN}面板地址: http://$(get_public_ip):${check_port}${NC}"
            maybe_auto_config_3xui_reality "$AUTO_NODE_NAME" "$AUTO_NODE_PORT" "$REALITY_TARGET" "$REALITY_SNI"
            show_post_install_guide "3x-ui"
            return 0
        fi

        if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "3x-ui"; then
            echo -e "${BLUE}>>> Docker 模式：正在拉取版本 ${selected_v}...${NC}"
            # 获取当前容器名
            local cname=$(docker ps -a --format '{{.Names}}' | grep "3x-ui" | head -1)
            local cport=$(get_instance_port "$cname")
            [ -z "$cport" ] && cport=$(docker port "$cname" 2>/dev/null | head -1 | cut -d: -f2)

            # 平滑更新逻辑
            docker pull enwaiax/3x-ui:${selected_v} && \
            docker stop "$cname" && \
            docker rm "$cname" && \
            docker run -itd -p ${cport}:${cport} -v /etc/${cname}:/etc/x-ui --name ${cname} --restart=unless-stopped enwaiax/3x-ui:${selected_v}

            verify_service_access "$cport" "$cname"
            maybe_auto_config_3xui_reality "$AUTO_NODE_NAME" "$AUTO_NODE_PORT" "$REALITY_TARGET" "$REALITY_SNI"
            show_post_install_guide "3x-ui"
        else
            update_3xui_system_flow "$selected_v"
            maybe_auto_config_3xui_reality "$AUTO_NODE_NAME" "$AUTO_NODE_PORT" "$REALITY_TARGET" "$REALITY_SNI"
            show_post_install_guide "3x-ui"
        fi
        return 0
    fi

    # 全新安装流程
    echo -e "${BLUE}>>> 执行全新安装流程 (版本: ${selected_v})...${NC}"
    if [ "${INSTALL_3XUI_MODE:-system}" = "docker" ]; then
        check_docker || return 1
        if install_3xui_docker "" "" "$selected_v"; then
            maybe_auto_config_3xui_reality "$AUTO_NODE_NAME" "$AUTO_NODE_PORT" "$REALITY_TARGET" "$REALITY_SNI"
        else
            echo -e "${RED}❌ 3x-ui Docker 安装失败，已跳过自动入站配置${NC}"
            return 1
        fi
        show_post_install_guide "3x-ui"
    else 
        # 系统安装需要下载特定版本
        echo ">>> 正在系统安装版本: ${selected_v}"
        if install_3xui_system "$selected_v"; then
            maybe_auto_config_3xui_reality "$AUTO_NODE_NAME" "$AUTO_NODE_PORT" "$REALITY_TARGET" "$REALITY_SNI"
        else
            echo -e "${RED}❌ 3x-ui 系统安装失败，已跳过自动入站配置${NC}"
            return 1
        fi
        show_post_install_guide "3x-ui"
    fi
}

# 其他面板安装
install_hiddify() {
    # 检查是否已存在
    ensure_docker_container_running "hiddify" "80" && { show_post_install_guide "Hiddify"; return 0; }

    # 安装前自动优化系统
    echo -e "${BLUE}>>> 安装前自动应用系统内核/网络优化...${NC}"
    apply_host_tuning --silent

    check_docker || return 1
    check_docker_ports || return 1
    docker run -d --name hiddify --restart=unless-stopped -p 80:80 -p 443:443 -p 8080:8080 -v /opt/hiddify:/opt/hiddify hiddify/hiddify-config:latest
    if [ $? -eq 0 ]; then
        for p in 80 443 8080; do manage_firewall $p; done
        print_success_info "Hiddify" "80" "" false
        verify_service_access 443 "hiddify"
        show_post_install_guide "Hiddify"
    fi
}

install_marzban() {
    # 检查是否已存在
    local container_name=$(get_container_name "marzban")
    if [ -n "$container_name" ]; then
        ensure_docker_container_running "$container_name" "8000" && { show_post_install_guide "Marzban"; return 0; }
    fi

    # 安装前自动优化系统
    echo -e "${BLUE}>>> 安装前自动应用系统内核/网络优化...${NC}"
    apply_host_tuning --silent

    check_docker || return 1
    check_docker_ports || return 1
    mkdir -p /tmp/marzban && cd /tmp/marzban
    download_file "https://raw.githubusercontent.com/Gozargah/Marzban-scripts/master/docker-compose.yml" "docker-compose.yml" || return 1
    docker compose up -d
    if [ $? -eq 0 ]; then
        manage_firewall 8000
        local password=$(generate_random_password 12)
        echo -e "${YELLOW}正在创建管理员账号...${NC}"
        sleep 10
        docker exec -it marzban marzban cli admin create --username admin --password "$password" 2>/dev/null || true

        print_success_info "Marzban" "8000" "/dashboard/" true
        echo -e "${YELLOW}随机密码: ${password}${NC}"
        verify_service_access 8000 "marzban"
        show_post_install_guide "Marzban"
    fi
}

# 状态与维护
check_status() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}                   面板运行状态检查${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    local has_panel=false
    local instances=$(docker ps -a --format '{{.Names}}' | grep "^3x-ui" | sort)
    for inst in $instances; do
        local port=$(get_container_port "$inst")
        echo -e "  [3x-ui] ${inst} (端口: ${port:-未知})"
        has_panel=true
    done
    systemctl is-active --quiet x-ui && { echo -e "${GREEN}✅ 3x-ui (System) 运行中${NC}"; has_panel=true; }
    check_container_exists "hiddify" && { echo -e "${GREEN}✅ Hiddify 运行中${NC}"; has_panel=true; }
    check_container_exists "marzban" && { echo -e "${GREEN}✅ Marzban 运行中${NC}"; has_panel=true; }
    [ "$has_panel" = false ] && echo -e "${YELLOW}未检测到任何面板${NC}"
}

# Nginx 安装与配置助手
install_nginx() {
    if command -v nginx &>/dev/null; then
        echo -e "${GREEN}✅ 检测到 Nginx 已安装，版本: $(nginx -v 2>&1 | cut -d/ -f2)${NC}"
        return 0
    fi
    
    echo -e "${BLUE}>>> 正在安装 Nginx...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y nginx
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y nginx
    else
        echo -e "${RED}❌ 不支持的包管理器，请手动安装 Nginx。${NC}"
        return 1
    fi
    systemctl enable nginx && systemctl start nginx
    echo -e "${GREEN}✅ Nginx 安装并启动成功${NC}"
    return 0
}

# 检测并配置 Nginx 反向代理
setup_nginx_proxy() {
    local panel=$1
    local port=$2
    local domain
    local conf_dir="/etc/nginx/conf.d"
    local conf_file=""
    
    # 交互获取域名
    echo -ne "${CYAN}请输入您的面板域名 (例如: panel.example.com): ${NC}"
    read domain
    if [ -z "$domain" ]; then
        echo -e "${RED}域名不能为空！${NC}"
        return 1
    fi
    
    # Debian/Ubuntu 体系通常使用 sites-available
    if [ -d "/etc/nginx/sites-available" ]; then
        conf_dir="/etc/nginx/sites-available"
        conf_file="${conf_dir}/${domain}.conf"
    else
        conf_file="${conf_dir}/${domain}.conf"
    fi
    
    # 检测配置是否已存在且端口正确
    if [ -f "$conf_file" ] || [ -f "/etc/nginx/sites-enabled/${domain}.conf" ]; then
        local target_file="$conf_file"
        [ ! -f "$target_file" ] && target_file="/etc/nginx/sites-enabled/${domain}.conf"
        
        if grep -q "127.0.0.1:${port}" "$target_file"; then
            echo -e "${GREEN}✅ 检测到域名 ${domain} 的 Nginx 配置已存在且端口 (${port}) 正确，无需更新。${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️ 检测到域名 ${domain} 的配置，但端口不匹配，准备更新配置...${NC}"
        fi
    fi
    
    echo -e "${BLUE}>>> 生成 Nginx 反向代理配置 (${panel})...${NC}"
    cat > "$conf_file" << EOF
server {
    listen 80;
    server_name ${domain};
    
    # 建议手动配置 SSL (例如使用 certbot)
    # listen 443 ssl;
    
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    
    # 创建软链接 (Debian/Ubuntu)
    if [ "$conf_dir" == "/etc/nginx/sites-available" ]; then
        ln -sf "$conf_file" "/etc/nginx/sites-enabled/${domain}.conf"
    fi
    
    # 测试并重启 Nginx
    if nginx -t >/dev/null 2>&1; then
        nginx -s reload
        echo -e "${GREEN}✅ Nginx 配置已生效！可以通过 http://${domain} 访问面板。${NC}"
    else
        echo -e "${RED}❌ Nginx 配置测试失败，请检查文件: ${conf_file}${NC}"
        return 1
    fi
}

# 智能更新策略
update_panels() {
    echo -e "${BLUE}>>> 正在执行平滑更新策略...${NC}"
    
    # 1. 处理 Docker 实例 (Hiddify/Marzban/3x-ui Docker)
    local containers=$(docker ps --format '{{.Names}}' | grep -E "3x-ui|hiddify|marzban")
    for name in $containers; do
        local image=$(docker inspect --format '{{.Config.Image}}' "$name")
        echo -e "${BLUE}>>> [${name}] 正在后台拉取最新镜像: ${image}...${NC}"
        if docker pull "$image"; then
            echo -e "${YELLOW}>>> 镜像拉取完成，准备重启实例...${NC}"
            docker restart "$name"
            echo -e "${GREEN}✅ ${name} 已完成平滑更新${NC}"
        else
            echo -e "${RED}❌ ${name} 镜像拉取失败，跳过更新${NC}"
        fi
    done

    # 2. 处理 3x-ui 系统版
    if [ -f "$BIN_FILE" ]; then
        echo -e "${BLUE}>>> [3x-ui System] 正在检测更新...${NC}"
        local arch=$(detect_arch)
        local tmp_file="/tmp/x-ui-new.tar.gz"
        if download_from_github "MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz" "$tmp_file"; then
            echo -e "${YELLOW}>>> 下载完成，执行蓝绿替换...${NC}"
            systemctl stop x-ui
            tar -xzf "$tmp_file" -C "$INSTALL_DIR" --strip-components=1
            systemctl start x-ui
            rm -f "$tmp_file"
            echo -e "${GREEN}✅ 3x-ui 系统版已更新并重启${NC}"
        fi
    fi
    
    echo -e "${GREEN}所有面板更新检查完成${NC}"
}

# 主流程
main() {
    echo "--------------------------------------"
    echo -e "${GREEN}全能代理面板安装脚本 (整合版)${NC}"
    echo "--------------------------------------"
    echo -e "1. 安装 ${GREEN}3x-ui${NC} (自动优化 + 自动 Reality 入站)"
    echo -e "2. 安装 ${CYAN}Hiddify${NC} (推荐：全能、自动化、抗封锁)"
    echo -e "3. 安装 Marzban (进阶：多用户管理、美观)"
    echo -e "4. 检查状态"
    echo -e "5. 主机网络优化 (BBR/文件句柄)"
    echo -e "6. ${YELLOW}Nginx 管理 & 代理配置${NC}"
    echo -e "7. 平滑更新所有面板"
    echo -e "8. 卸载菜单"
    echo "0. 退出"
    echo "--------------------------------------"
    echo -e "${YELLOW}提示: 选 1 会自动完成主机优化、安装/更新和系统版 3x-ui Reality 入站配置。${NC}"
    read -rp "请输入选项 [0-8]: " CHOICE
    case $CHOICE in
        1) install_3xui ;;
        2) install_hiddify ;;
        3) install_marzban ;;
        4) check_status ;;
        5)
            echo -e "1. 开启优化\n2. 检查状态\n3. 回滚配置\n0. 返回"
            read -p "选项: " tc
            case $tc in 1) apply_host_tuning ;; 2) check_host_tuning ;; 3) rollback_host_tuning ;; esac
            ;;
        6)
            echo -e "1. 安装 Nginx\n2. 获取反代配置建议\n0. 返回"
            read -p "选项: " nc
            case $nc in 
                1) install_nginx ;; 
                2) 
                    read -p "请输入面板端口: " pp
                    show_nginx_config_tip "Panel" "$pp" 
                    ;; 
            esac
            ;;
        7) update_panels ;;
        8) uninstall_menu ;;
        0) exit 0 ;;
    esac
}

# 参数解析
if [ $# -gt 0 ]; then
    case "$1" in
        --install-3xui)
            shift
            install_port=""
            install_name=""
            auto_config="${AUTO_CONFIG_3XUI:-1}"
            auto_node_name="$AUTO_NODE_NAME"
            auto_node_port="$AUTO_NODE_PORT"
            auto_reality_target="$REALITY_TARGET"
            auto_reality_sni="$REALITY_SNI"
            install_mode="$INSTALL_3XUI_MODE"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --port) install_port="$2"; shift 2 ;;
                    --name) install_name="$2"; shift 2 ;;
                    --docker) install_mode="docker"; shift ;;
                    --system) install_mode="system"; shift ;;
                    --auto-config) auto_config=1; shift ;;
                    --no-auto-config) auto_config=0; shift ;;
                    --node-name) auto_node_name="$2"; shift 2 ;;
                    --node-port) auto_node_port="$2"; shift 2 ;;
                    --reality-target) auto_reality_target="$2"; auto_reality_sni="${auto_reality_target%%:*}"; shift 2 ;;
                    --reality-sni) auto_reality_sni="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            AUTO_CONFIG_3XUI="$auto_config"
            AUTO_NODE_NAME="$auto_node_name"
            AUTO_NODE_PORT="$auto_node_port"
            REALITY_TARGET="$auto_reality_target"
            REALITY_SNI="$auto_reality_sni"
            INSTALL_3XUI_MODE="$install_mode"
            install_3xui "$install_port" "$install_name"
            ;;
        --auto-config)
            shift
            auto_panel="auto"
            auto_target="auto"
            auto_node_name="$AUTO_NODE_NAME"
            auto_node_port="$AUTO_NODE_PORT"
            auto_reality_target="$REALITY_TARGET"
            auto_reality_sni="$REALITY_SNI"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --panel|--type) auto_panel="$2"; shift 2 ;;
                    --target|--instance) auto_target="$2"; shift 2 ;;
                    --3xui|--3x-ui) auto_panel="3x-ui"; shift ;;
                    --node-name) auto_node_name="$2"; shift 2 ;;
                    --node-port) auto_node_port="$2"; shift 2 ;;
                    --reality-target) auto_reality_target="$2"; auto_reality_sni="${auto_reality_target%%:*}"; shift 2 ;;
                    --reality-sni) auto_reality_sni="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            auto_config_panel "$auto_panel" "$auto_target" "$auto_node_name" "$auto_node_port" "$auto_reality_target" "$auto_reality_sni"
            ;;
        --uninstall)
            shift
            uninstall_panel="auto"
            uninstall_target="auto"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --panel|--type) uninstall_panel="$2"; shift 2 ;;
                    --target|--instance|--name) uninstall_target="$2"; shift 2 ;;
                    --3xui|--3x-ui) uninstall_panel="3x-ui"; shift ;;
                    --hiddify) uninstall_panel="hiddify"; shift ;;
                    --marzban) uninstall_panel="marzban"; shift ;;
                    *) shift ;;
                esac
            done
            auto_uninstall_panel "$uninstall_panel" "$uninstall_target"
            ;;
        --tune-host|--enable-bbr) apply_host_tuning ;;
        --check-tuning|--check-bbr) check_host_tuning ;;
        --rollback-tuning|--rollback-bbr) rollback_host_tuning ;;
        --check-network|--diagnose) diagnose_network ;;
        --mtr-to) shift; mtr_to "$@" ;;
        --generate-clash-config|--gen-clash)
            shift
            CLASH_NODE_NAME=""
            CLASH_SERVER_IP=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --node-name|--name) CLASH_NODE_NAME="$2"; shift 2 ;;
                    --server-ip|--host) CLASH_SERVER_IP="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            generate_clash_config
            ;;
        --clients|--recommend-clients) show_client_recommendations ;;
        --status) check_status ;;
        --help|-h) show_help ;;
        *) main ;;
    esac
else
    main
fi

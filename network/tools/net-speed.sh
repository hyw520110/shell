#!/bin/bash

# net-speed.sh - 综合网络测速工具 (Speedtest + iperf3)
# 支持: macOS / Linux (x86_64, aarch64, armv7l)
# 特性: 本机外网测速、指定节点、历史对比、代理检测、iperf3 压测、自动安装

# ── 颜色定义 ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

# ── 基础设置 ──────────────────────────────────────────────────────────
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/net-speed"
LOG_FILE="${STATE_DIR}/net-speed-results.log"
LAST_SERVER_FILE="${STATE_DIR}/last-server"
SERVERS_CACHE="${STATE_DIR}/servers-list.txt"

# 常见本地代理端口（仅检测监听，不修改配置）
PROXY_PORTS=(7890 7891 7892 1080 1087 10808 8080 6152 8888 10809 33210)

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
AUTO_YES=0
NONINTERACTIVE=0
REMOTE_SSH_TARGET=""
SSH_IDENTITY_FILE=""
# CLI / 环境变量可预设（路径含 ~ 会自动展开）
IPERF_HOST=""
IPERF_PORT="5201"
IPERF_PARALLEL="1"
IPERF_TIME="10"
IPERF_DAEMON=0
SPEEDTEST_SERVER_MODE="auto"
SPEEDTEST_SERVER_ID=""

info()    { echo -e "${BLUE}[信息]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*" >&2; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }

# 展开路径中的 ~ 与首尾引号（避免 ~/foo.pem 被判定为不存在）
# 注意: bash 中 ${var#~/} 里的 ~ 会展开成 $HOME，须用 "${var#\"~/\"}" 或 ${var:2}
_expand_user_path() {
    local p=$1
    p="${p#\"}"; p="${p%\"}"
    p="${p#\'}"; p="${p%\'}"
    if [[ "$p" == "~" ]]; then
        echo "$HOME"
    elif [[ "$p" == "~/"* ]]; then
        echo "$HOME/${p:2}"
    elif [[ "$p" == "~"* ]]; then
        eval echo "$p" 2>/dev/null || echo "$p"
    else
        echo "$p"
    fi
}

# 任意字符串中含 ~ 则展开（用于 SSH 目标外的路径类输入）
_expand_tilde_in_string() {
    local s=$1
    if [[ "$s" == *"~"* ]]; then
        _expand_user_path "$s"
    else
        echo "$s"
    fi
}

_ssh_extra_args() {
    SSH_EXTRA_ARGS=()
    if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
        SSH_IDENTITY_FILE=$(_expand_user_path "$SSH_IDENTITY_FILE")
        [[ -f "$SSH_IDENTITY_FILE" ]] && SSH_EXTRA_ARGS+=(-i "$SSH_IDENTITY_FILE")
    fi
}

get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l) echo "armv7l" ;;
        *) echo "x86_64" ;;
    esac
}

get_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin*) echo "macos" ;;
        linux*) echo "linux" ;;
        *) echo "$os" ;;
    esac
}

OS=$(get_os)
ARCH=$(get_arch)

# ── Phase 2: 代理检测（只读提示，不修改系统）──────────────────────────
_detect_listening_port() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1; exit}'
        return 0
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$port" 2>/dev/null && echo "unknown"
    fi
}

detect_proxy() {
  # 输出多行 PROXY|类型|详情，无代理则无输出
  local v k
  for k in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
    v="${!k:-}"
    [[ -n "$v" ]] && echo "PROXY|环境变量 ${k}|${v}"
  done

  if command -v git >/dev/null 2>&1; then
    v=$(git config --global --get http.proxy 2>/dev/null)
    [[ -n "$v" ]] && echo "PROXY|Git http.proxy|${v}"
    v=$(git config --global --get https.proxy 2>/dev/null)
    [[ -n "$v" ]] && echo "PROXY|Git https.proxy|${v}"
  fi

  if [[ "$OS" == "macos" ]] && command -v networksetup >/dev/null 2>&1; then
    local svc proxy_line
    for svc in "Wi-Fi" "Ethernet"; do
      proxy_line=$(networksetup -getwebproxy "$svc" 2>/dev/null | awk '
        /Enabled: Yes/ { e=1 }
        /Server: / { gsub(/Server: /,""); s=$0 }
        /Port: / { gsub(/Port: /,""); p=$0 }
        END { if (e && p+0>0) print s":"p }
      ')
      [[ -n "$proxy_line" ]] && echo "PROXY|macOS HTTP 代理 (${svc})|${proxy_line}"
      proxy_line=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk '
        /Enabled: Yes/ { e=1 }
        /Server: / { gsub(/Server: /,""); s=$0 }
        /Port: / { gsub(/Port: /,""); p=$0 }
        END { if (e && p+0>0) print s":"p }
      ')
      [[ -n "$proxy_line" ]] && echo "PROXY|macOS SOCKS 代理 (${svc})|${proxy_line}"
    done
  fi
  if [[ "$OS" == "linux" ]] && [[ -f /etc/environment ]]; then
    grep -iE '^[^#]*(http|https|all)_proxy=' /etc/environment 2>/dev/null | while read -r line; do
      echo "PROXY|/etc/environment|${line}"
    done
  fi

  local port proc
  for port in "${PROXY_PORTS[@]}"; do
    proc=$(_detect_listening_port "$port")
    [[ -n "$proc" ]] && echo "PROXY|本地端口 :${port}|进程 ${proc} 正在监听（常见于 Clash/Surge/V2Ray 等）"
  done

  if ifconfig 2>/dev/null | grep -qE '^utun[0-9]+:'; then
    echo "PROXY|VPN 接口|检测到 utun* 隧道（可能为 VPN / 代理 TUN）"
  fi
}

show_proxy_report() {
  local lines=()
  while IFS= read -r line; do lines+=("$line"); done < <(detect_proxy)
  echo -e "\n${BOLD}>>> 代理 / 隧道检测:${NC}"
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}未发现常见代理配置或本地代理端口${NC}"
    return 0
  fi
  echo -e "  ${YELLOW}⚠️  以下项可能影响测速结果（反映代理出口而非纯家宽）:${NC}"
  local item type detail
  for item in "${lines[@]}"; do
    IFS='|' read -r _ type detail <<< "$item"
    echo -e "  ${YELLOW}•${NC} ${type}: ${CYAN}${detail}${NC}"
  done
  echo -e "  ${GRAY}建议：关闭代理/VPN 后重测，或使用菜单中的「国内节点」对比${NC}"
}

# ── 网络信息采集 ──────────────────────────────────────────────────────
get_network_info() {
    local internal_ip
    internal_ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1 || hostname -I 2>/dev/null | awk '{print $1}')
    local external_ip
    external_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 -4 ifconfig.me 2>/dev/null || echo "获取失败")
    local gateway
    gateway=$(netstat -rn 2>/dev/null | grep default | awk '{print $2}' | head -1)

    echo -e "\n${BOLD}>>> 当前网络状态:${NC}"
    echo -e "  内网 IP: ${CYAN}${internal_ip}${NC}"
    echo -e "  外网 IP: ${CYAN}${external_ip}${NC}"
    echo -e "  默认网关: ${CYAN}${gateway}${NC}"
    echo -e "  操作系统: ${CYAN}${OS} (${ARCH})${NC}"
    show_proxy_report
}

# ── SSH 检测 ──────────────────────────────────────────────────────────
check_ssh_github() {
    # 检查是否有 GitHub 的 SSH 密钥
    if [[ -f "$HOME/.ssh/id_rsa" ]] || [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_ecdsa" ]]; then
        # 测试 SSH 连接
        if ssh -T git@github.com -o ConnectTimeout=5 -o StrictHostKeyChecking=no 2>&1 | grep -q "successfully authenticated"; then
            return 0
        fi
    fi
    return 1
}

# ── 自动安装逻辑 ──────────────────────────────────────────────────────
install_iperf3() {
    info "正在尝试安装 iperf3..."
    if [[ "$OS" == "macos" ]]; then
        command -v brew >/dev/null 2>&1 && brew install iperf3 || error "请先安装 Homebrew"
    elif [[ "$OS" == "linux" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y iperf3
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y epel-release && sudo yum install -y iperf3
        fi
    fi
}

# ── iperf3 远端检测与 SSH 部署（不保存密码，走 ssh 交互/密钥）────────
_get_lan_ips() {
    ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}'
}

# 检测目标主机 TCP 端口是否可达
check_iperf_port() {
    local host=$1 port=$2
    if command -v nc >/dev/null 2>&1; then
        nc -z -G 3 -w 3 "$host" "$port" 2>/dev/null
        return $?
    fi
    (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

# 可选：短连接探测 iperf3 协议
probe_iperf_server() {
    local host=$1 port=$2
    command -v iperf3 >/dev/null 2>&1 || return 1
    iperf3 -c "$host" -p "$port" -t 1 -J >/dev/null 2>&1 \
        || iperf3 -c "$host" -p "$port" -t 1 >/dev/null 2>&1
}

# 从 ~/.ssh/config 找 HostName 匹配 IP 的 Host 别名
_ssh_config_aliases_for_ip() {
    local ip=$1
    [[ -f "$HOME/.ssh/config" ]] || return 0
    awk -v ip="$ip" '
        BEGIN { split("", hosts) }
        /^[Hh]ost[ \t]+/ {
            delete hosts
            for (i = 2; i <= NF; i++)
                if ($i !~ /[*?]/) hosts[$i] = 1
        }
        /^[Hh]ost[Nn]ame[ \t]+/ {
            if ($2 == ip)
                for (h in hosts) print h
        }
    ' "$HOME/.ssh/config" 2>/dev/null
}

# 自动发现可用的 SSH 目标（密钥/agent）；失败则返回 1
discover_ssh_target() {
    local ip=$1
    local -a candidates=()
    local alias t

    while IFS= read -r alias; do
        [[ -n "$alias" ]] && candidates+=("$alias")
    done < <(_ssh_config_aliases_for_ip "$ip")

    candidates+=("${USER}@${ip}" "root@${ip}")

    local -a keys=()
    local key
    for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
        [[ -f "$key" ]] && keys+=("$key")
    done
    for key in "$HOME"/Documents/*.pem "$HOME"/.ssh/*.pem "$HOME"/*.pem; do
        [[ -f "$key" ]] && keys+=("$key")
    done

    for key in "${keys[@]}"; do
        [[ "$key" == *.pub ]] && continue
        for t in "${candidates[@]}"; do
            if ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$t" "exit 0" 2>/dev/null; then
                echo "$t"
                DISCOVERED_SSH_KEY="$key"
                return 0
            fi
        done
    done

    for t in "${candidates[@]}"; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$t" "exit 0" 2>/dev/null; then
            echo "$t"
            return 0
        fi
    done
    return 1
}

# 上传本脚本到远端并以非交互方式启动 iperf3 服务端
remote_deploy_iperf_via_script() {
    local ssh_target=$1 port=$2
    _ssh_extra_args

    [[ -f "$SCRIPT_PATH" ]] || { error "找不到脚本: $SCRIPT_PATH"; return 1; }
    command -v scp >/dev/null 2>&1 || { error "未找到 scp"; return 1; }

    local remote_name="net-speed.sh"
    local remote_path="~/${remote_name}"
    info "上传脚本 → ${ssh_target}:${remote_path}"
    if ! scp "${SSH_EXTRA_ARGS[@]}" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "$SCRIPT_PATH" "${ssh_target}:${remote_path}"; then
        error "SCP 上传失败"
        return 1
    fi

    info "远端执行: ~/${remote_name} iperf-server -p ${port} --daemon -y"
    if ! ssh -t "${SSH_EXTRA_ARGS[@]}" -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new \
        "$ssh_target" "chmod +x \"\$HOME/${remote_name}\" && bash \"\$HOME/${remote_name}\" iperf-server -p ${port} --daemon -y"; then
        error "远端执行失败（若需 sudo 安装 iperf3，请使用: ssh -t ${ssh_target})"
        return 1
    fi
    success "远端 iperf3 已启动 (端口 ${port})，脚本保留于: ~/${remote_name}"
    return 0
}

# 检测不通过时引导 SSH 部署
ensure_remote_iperf_server() {
    local host=$1 port=$2

    if check_iperf_port "$host" "$port"; then
        if probe_iperf_server "$host" "$port"; then
            success "远端 iperf3 服务可用 (${host}:${port})"
            return 0
        fi
        warn "端口 ${port} 已开放，但 iperf3 探测异常（可能非 iperf3 服务）"
        if [[ "$AUTO_YES" == "1" ]]; then
            return 0
        fi
        read -p "仍继续压测? (y/N): " cont
        [[ "$cont" == "y" || "$cont" == "Y" ]] && return 0
        return 1
    fi

    warn "无法连接 ${host}:${port} — 远端可能未运行 iperf3 服务端"
    echo -e "  ${GRAY}常见原因: 防火墙拦截、服务未启动、IP 填错、安全组未放行 TCP ${port}${NC}"

    local try_ssh=n
    if [[ "$AUTO_YES" == "1" ]] || [[ -n "$REMOTE_SSH_TARGET" ]]; then
        try_ssh=y
    else
        read -p "是否 SSH 上传本脚本并在远端启动 iperf3 服务? (y/N): " try_ssh_in
        [[ "$try_ssh_in" == "y" || "$try_ssh_in" == "Y" ]] && try_ssh=y
    fi
    [[ "$try_ssh" == "y" ]] || return 1

    command -v ssh >/dev/null 2>&1 || { error "未找到 ssh 客户端"; return 1; }

    local target="$REMOTE_SSH_TARGET"
    DISCOVERED_SSH_KEY=""
    if [[ -z "$target" ]]; then
        if target=$(discover_ssh_target "$host"); then
            info "已自动发现 SSH: ${target}"
            [[ -n "$DISCOVERED_SSH_KEY" ]] && info "匹配私钥: ${DISCOVERED_SSH_KEY}"
            if [[ "$AUTO_YES" != "1" ]]; then
                read -p "使用该目标? (Y/n): " use_auto
                [[ "$use_auto" == "n" || "$use_auto" == "N" ]] && target=""
            fi
        fi
    fi

    if [[ -z "$target" ]]; then
        read -p "请输入 SSH 目标 (如 user@${host}): " target
        [[ -z "$target" ]] && return 1
    fi

    if [[ -n "$DISCOVERED_SSH_KEY" && -z "${SSH_IDENTITY_FILE:-}" ]]; then
        SSH_IDENTITY_FILE="$DISCOVERED_SSH_KEY"
    elif [[ -z "${SSH_IDENTITY_FILE:-}" && "$NONINTERACTIVE" != "1" ]]; then
        read -p "私钥路径 (回车=默认, 支持 ~): " keypath
        if [[ -n "$keypath" ]]; then
            keypath=$(_expand_user_path "$keypath")
            [[ -f "$keypath" ]] || { error "私钥不存在: $keypath"; return 1; }
            SSH_IDENTITY_FILE="$keypath"
        fi
    fi
    _ssh_extra_args

    if [[ "$AUTO_YES" != "1" ]]; then
        info "验证 SSH 连接..."
        if ! ssh "${SSH_EXTRA_ARGS[@]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$target" "exit 0"; then
            error "SSH 登录失败"
            return 1
        fi
    fi

    remote_deploy_iperf_via_script "$target" "$port" || return 1

    sleep 1
    if check_iperf_port "$host" "$port"; then
        success "复检通过: ${host}:${port} 已可达"
        return 0
    fi
    error "部署后仍无法连接 ${host}:${port}（检查防火墙是否放行 TCP ${port}）"
    return 1
}

# Homebrew tap 目录（官方：teamookla/homebrew-speedtest）
_speedtest_tap_dir() {
    echo "$(brew --repo)/Library/Taps/teamookla/homebrew-speedtest"
}

# tap 是否包含 speedtest formula
_speedtest_tap_valid() {
    local tap_dir="$1"
    [[ -f "${tap_dir}/speedtest.rb" || -f "${tap_dir}/Formula/speedtest.rb" ]]
}

# 清理旧版脚本遗留的错误 tap（ookla/speedtest + brew tap-new 空目录）
_cleanup_broken_speedtest_taps() {
    brew untap ookla/speedtest 2>/dev/null || true
    rm -rf "$(brew --repo)/Library/Taps/ookla/homebrew-speedtest" 2>/dev/null || true

    local tap_dir
    tap_dir="$(_speedtest_tap_dir)"
    if [[ -d "$tap_dir" ]] && ! _speedtest_tap_valid "$tap_dir"; then
        warn "检测到不完整的 speedtest tap，正在清理..."
        brew untap teamookla/speedtest 2>/dev/null || true
        rm -rf "$tap_dir"
    fi
}

install_speedtest_macos_brew() {
    _cleanup_broken_speedtest_taps

    local tap_dir
    tap_dir="$(_speedtest_tap_dir)"

    info "通过 Homebrew 安装 (tap: teamookla/speedtest)..."
    if brew tap teamookla/speedtest 2>/dev/null && brew install speedtest --force; then
        return 0
    fi

    # HTTPS tap 失败时，用 SSH 完整克隆官方仓库（勿使用 brew tap-new，会生成空骨架）
    if check_ssh_github; then
        info "HTTPS tap 失败，尝试 SSH 克隆 teamookla/homebrew-speedtest..."
        brew untap teamookla/speedtest 2>/dev/null || true
        rm -rf "$tap_dir"
        mkdir -p "$(brew --repo)/Library/Taps/teamookla"
        if git clone --depth 1 "git@github.com:teamookla/homebrew-speedtest.git" "$tap_dir" \
            && brew install speedtest --force; then
            return 0
        fi
    fi

    return 1
}

install_speedtest() {
    info "正在尝试安装 Ookla Speedtest..."
    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    if [[ "$OS" == "macos" ]]; then
        if command -v brew >/dev/null 2>&1; then
            install_speedtest_macos_brew && return 0
            warn "Homebrew 安装失败，尝试官方二进制..."
        else
            warn "未找到 Homebrew，尝试官方二进制安装..."
        fi
        install_speedtest_direct && command -v speedtest >/dev/null 2>&1 && return 0
        return 1
    elif [[ "$OS" == "linux" ]]; then
        if curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash 2>/dev/null \
            && sudo apt-get install -y speedtest 2>/dev/null; then
            return 0
        fi
        if curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash 2>/dev/null \
            && sudo yum install -y speedtest 2>/dev/null; then
            return 0
        fi
        install_speedtest_direct && command -v speedtest >/dev/null 2>&1 && return 0
        return 1
    fi
    return 1
}

install_speedtest_direct() {
    local temp_dir
    temp_dir=$(mktemp -d)
    local version="1.2.0"
    local dl_os="linux"
    [[ "$OS" == "macos" ]] && dl_os="macosx"
    local url="https://install.speedtest.net/app/cli/ookla-speedtest-${version}-${dl_os}-${ARCH}.tgz"
    local install_dir="/usr/local/bin"
    local bin_path="${install_dir}/speedtest"

    info "正在下载官方 CLI: ${url}"
    if ! curl -fsSL "$url" -o "${temp_dir}/speedtest.tgz"; then
        warn "官方 CLI 下载失败，尝试备用地址..."
        url="https://install.speedtest.net/app/latest/ookla-speedtest-${version}-${dl_os}-${ARCH}.tgz"
        curl -fsSL "$url" -o "${temp_dir}/speedtest.tgz" || { rm -rf "$temp_dir"; return 1; }
    fi

    tar -xzf "${temp_dir}/speedtest.tgz" -C "$temp_dir"
    local extracted="${temp_dir}/speedtest"
    [[ -x "$extracted" ]] || extracted=$(find "$temp_dir" -maxdepth 2 -name speedtest -type f -perm +111 | head -1)
    if [[ ! -x "$extracted" ]]; then
        error "解压后未找到 speedtest 可执行文件"
        rm -rf "$temp_dir"
        return 1
    fi
    chmod +x "$extracted"

    mkdir -p "$HOME/.local/bin"
    if sudo mv "$extracted" "$bin_path" 2>/dev/null; then
        :
    elif mv "$extracted" "$HOME/.local/bin/speedtest" 2>/dev/null; then
        bin_path="$HOME/.local/bin/speedtest"
        [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
    else
        error "无法写入 speedtest 到系统或用户目录"
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"
    success "Speedtest 已安装: ${bin_path}"
    return 0
}

# ── Phase 1: 历史对比 ─────────────────────────────────────────────────
_ensure_state_dir() { mkdir -p "$STATE_DIR"; }

# 写入结构化测速日志
_append_speedtest_log() {
    _ensure_state_dir
    local timestamp=$1 dl=$2 ul=$3 lat=$4 loss=$5 sid=$6 srv=$7 isp=$8
    echo "[$timestamp] ↓${dl}Mbps ↑${ul}Mbps 延迟${lat}ms 丢包${loss}% | id:${sid} | ${srv} | ${isp}" >> "$LOG_FILE"
}

# 解析日志行；成功则设置 REPLY_* 变量
_parse_speedtest_log_line() {
    local line=$1
    REPLY_TS= REPLY_DL= REPLY_UL= REPLY_LAT= REPLY_LOSS= REPLY_SID= REPLY_SRV= REPLY_ISP=
    if [[ "$line" =~ \[(.+)\][[:space:]]+↓([0-9.]+)Mbps[[:space:]]+↑([0-9.]+)Mbps[[:space:]]+延迟([0-9.]+)ms[[:space:]]+丢包([0-9.]+)% ]]; then
        REPLY_TS="${BASH_REMATCH[1]}"
        REPLY_DL="${BASH_REMATCH[2]}"
        REPLY_UL="${BASH_REMATCH[3]}"
        REPLY_LAT="${BASH_REMATCH[4]}"
        REPLY_LOSS="${BASH_REMATCH[5]}"
        if [[ "$line" =~ id:([0-9]+)[[:space:]]*\| ]]; then
            REPLY_SID="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ id:[0-9]+[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*(.+)$ ]]; then
            REPLY_SRV=$(echo "${BASH_REMATCH[1]}" | sed 's/^ *//;s/ *$//')
            REPLY_ISP=$(echo "${BASH_REMATCH[2]}" | sed 's/^ *//;s/ *$//')
        elif [[ "$line" =~ ↓[0-9.]+Mbps[[:space:]]+↑[0-9.]+Mbps[[:space:]]+延迟[0-9.]+ms[[:space:]]+丢包[0-9.]+%[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*(.+)$ ]]; then
            REPLY_SRV=$(echo "${BASH_REMATCH[1]}" | sed 's/^ *//;s/ *$//')
            REPLY_ISP=$(echo "${BASH_REMATCH[2]}" | sed 's/^ *//;s/ *$//')
        fi
        return 0
    fi
    return 1
}

_get_speedtest_log_entries() {
    [[ -f "$LOG_FILE" ]] || return 1
    grep -E '↓[0-9.]+Mbps.*↑[0-9.]+Mbps.*延迟[0-9.]+ms' "$LOG_FILE" 2>/dev/null
}

_format_delta() {
    local name=$1 cur=$2 prev=$3 higher_better=$4 unit=$5
    local d
    d=$(python3 -c "print(round(float('$cur')-float('$prev'),2))")
    local label arrow color
    if [[ "$higher_better" == "true" ]]; then
        if python3 -c "exit(0 if float('$d')>0 else 1)"; then arrow="↑"; color="$GREEN"
        elif python3 -c "exit(0 if float('$d')<0 else 1)"; then arrow="↓"; color="$RED"
        else arrow="→"; color="$GRAY"; fi
    else
        if python3 -c "exit(0 if float('$d')<0 else 1)"; then arrow="↓"; color="$GREEN"
        elif python3 -c "exit(0 if float('$d')>0 else 1)"; then arrow="↑"; color="$RED"
        else arrow="→"; color="$GRAY"; fi
    fi
    local sign=""
    python3 -c "exit(0 if float('$d')>0 else 1)" && sign="+"
    echo -e "  ${name}: ${color}${sign}${d} ${unit} ${arrow}${NC}  (上次 ${prev} → 本次 ${cur})"
}

# 对比最近两次（测速后调用：日志已含本次记录时取末行与次末行）
compare_with_previous() {
    local entries=()
    while IFS= read -r line; do entries+=("$line"); done < <(_get_speedtest_log_entries)
    [[ ${#entries[@]} -ge 2 ]] || return 0

    local cur_line="${entries[$((${#entries[@]}-1))]}"
    local prev_line="${entries[$((${#entries[@]}-2))]}"

    _parse_speedtest_log_line "$cur_line" || return 0
    local c_dl=$REPLY_DL c_ul=$REPLY_UL c_lat=$REPLY_LAT c_loss=$REPLY_LOSS c_sid=$REPLY_SID c_srv=$REPLY_SRV
    _parse_speedtest_log_line "$prev_line" || return 0
    local p_dl=$REPLY_DL p_ul=$REPLY_UL p_lat=$REPLY_LAT p_loss=$REPLY_LOSS p_sid=$REPLY_SID p_srv=$REPLY_SRV

    echo -e "\n${BOLD}>>> 📈 与上次测速对比${NC}"
    echo -e "  上次: ${GRAY}${p_srv}${NC}  |  本次: ${CYAN}${c_srv}${NC}"
    if [[ -n "$p_sid" && -n "$c_sid" && "$p_sid" != "$c_sid" ]]; then
        warn "测速节点不同 (id ${p_sid} → ${c_sid})，数值仅供参考"
    fi
    _format_delta "下载" "$c_dl" "$p_dl" true "Mbps"
    _format_delta "上传" "$c_ul" "$p_ul" true "Mbps"
    _format_delta "延迟" "$c_lat" "$p_lat" false "ms"
    _format_delta "丢包" "$c_loss" "$p_loss" false "%"
    echo ""
}

show_speedtest_history() {
    echo -e "\n${BOLD}>>> 测速历史 (${LOG_FILE/#$HOME/~})${NC}"
    local entries=()
    while IFS= read -r line; do entries+=("$line"); done < <(_get_speedtest_log_entries)
    if [[ ${#entries[@]} -eq 0 ]]; then
        warn "暂无结构化测速记录（请先执行选项 1）"
        [[ -f "$LOG_FILE" ]] && { echo -e "${GRAY}--- 原始日志 ---${NC}"; tail -n 15 "$LOG_FILE"; }
        return 0
    fi

    local i start=$(( ${#entries[@]} > 10 ? ${#entries[@]} - 10 : 0 ))
    for ((i=start; i<${#entries[@]}; i++)); do
        echo -e "  ${GRAY}$((i-start+1)).${NC} ${entries[$i]}"
    done

    if [[ ${#entries[@]} -ge 2 ]]; then
        local cur_line="${entries[$((${#entries[@]}-1))]}"
        local prev_line="${entries[$((${#entries[@]}-2))]}"
        _parse_speedtest_log_line "$cur_line" || return 0
        local c_dl=$REPLY_DL c_ul=$REPLY_UL c_lat=$REPLY_LAT
        _parse_speedtest_log_line "$prev_line" || return 0
        local p_dl=$REPLY_DL p_ul=$REPLY_UL p_lat=$REPLY_LAT
        echo -e "\n${BOLD}>>> 最近两次对比摘要${NC}"
        _format_delta "下载" "$c_dl" "$p_dl" true "Mbps"
        _format_delta "上传" "$c_ul" "$p_ul" true "Mbps"
        _format_delta "延迟" "$c_lat" "$p_lat" false "ms"
    fi
    echo ""
}

# ── Phase 3: 指定测速节点 ─────────────────────────────────────────────
fetch_speedtest_servers() {
    _ensure_state_dir
    info "正在获取附近测速节点列表..."
    speedtest -L 2>/dev/null >"$SERVERS_CACHE" || return 1
    [[ -s "$SERVERS_CACHE" ]]
}

save_last_server() {
    local id=$1 name=$2
    _ensure_state_dir
    echo "${id}|${name}" >"$LAST_SERVER_FILE"
}

# 从缓存解析节点；CHINA_ONLY=1 时筛选国内/同城
_pick_server_from_cache() {
    local mode=$1 # china | first
  python3 - "$SERVERS_CACHE" "$mode" <<'PY'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
china_kw = (
    "china", "中国", "beijing", "shanghai", "guangzhou", "shenzhen",
    "hangzhou", "chengdu", "nanjing", "wuhan", "北京", "上海", "广州",
    "深圳", "杭州", "成都", "南京", "武汉", "telcom", "unicom", "mobile",
    "电信", "联通", "移动", "ctcc", "cmcc"
)
servers = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = re.match(r"\s*(\d+)\s+(.+?)\s{2,}(.+?)\s{2,}(.+?)\s*$", line)
        if m:
            servers.append({"id": m.group(1), "name": m.group(2).strip(),
                            "loc": m.group(3).strip(), "country": m.group(4).strip()})
if not servers:
    sys.exit(1)
if mode == "china":
    picked = [s for s in servers if any(k in (s["loc"]+s["country"]+s["name"]).lower() for k in china_kw)]
    if not picked:
        print("__NONE__")
        sys.exit(0)
    # 优先中国大陆标注
    cn = [s for s in picked if "china" in s["country"].lower() or "中国" in s["country"]]
    s = (cn or picked)[0]
    print(f"{s['id']}\t{s['name']}\t{s['loc']}\t{s['country']}")
else:
    print(f"{servers[0]['id']}\t{servers[0]['name']}")
PY
}

_list_servers_interactive() {
    [[ -f "$SERVERS_CACHE" ]] || fetch_speedtest_servers || return 1
    python3 - "$SERVERS_CACHE" <<'PY'
import re, sys
path = sys.argv[1]
servers = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = re.match(r"\s*(\d+)\s+(.+?)\s{2,}(.+?)\s{2,}(.+?)\s*$", line)
        if m:
            servers.append((m.group(1), m.group(2).strip(), m.group(3).strip(), m.group(4).strip()))
for i, (sid, name, loc, country) in enumerate(servers, 1):
    print(f"{i}\t{sid}\t{name}\t{loc}, {country}")
PY
}

_select_speedtest_server_noninteractive() {
    case "${SPEEDTEST_SERVER_MODE:-auto}" in
        auto) return 0 ;;
        last)
            if [[ -f "$LAST_SERVER_FILE" ]]; then
                IFS='|' read -r SPEEDTEST_SERVER_ID _ <"$LAST_SERVER_FILE"
                info "使用上次节点 id=${SPEEDTEST_SERVER_ID}"
            fi
            return 0
            ;;
        china)
            fetch_speedtest_servers || return 1
            local picked
            picked=$(_pick_server_from_cache china)
            if [[ "$picked" == "__NONE__" ]]; then
                warn "附近无国内节点，改为自动选点"
                return 0
            fi
            IFS=$'\t' read -r SPEEDTEST_SERVER_ID _ _ _ <<<"$picked"
            info "国内优先节点 id=${SPEEDTEST_SERVER_ID}"
            return 0
            ;;
        *)
            if [[ "${SPEEDTEST_SERVER_MODE}" =~ ^[0-9]+$ ]]; then
                SPEEDTEST_SERVER_ID="${SPEEDTEST_SERVER_MODE}"
                info "指定节点 id=${SPEEDTEST_SERVER_ID}"
                return 0
            fi
            warn "未知 --server 值: ${SPEEDTEST_SERVER_MODE}，使用自动选点"
            return 0
            ;;
    esac
}

select_speedtest_server() {
    [[ -n "${SPEEDTEST_SERVER_ID:-}" ]] && return 0

    if [[ "$NONINTERACTIVE" == "1" ]]; then
        _select_speedtest_server_noninteractive
        return $?
    fi

    SPEEDTEST_SERVER_ID=""
    local last_id="" last_name=""
    if [[ -f "$LAST_SERVER_FILE" ]]; then
        IFS='|' read -r last_id last_name <"$LAST_SERVER_FILE"
    fi

    echo -e "\n${BOLD}>>> 选择测速节点${NC}"
    echo "  1. 自动选择（Ookla 推荐）"
    echo "  2. 国内 / 同城优先（从附近列表筛选）"
    echo "  3. 从附近节点列表手动挑选"
    echo "  4. 手动输入 Server ID"
    [[ -n "$last_id" ]] && echo "  5. 使用上次节点: ${last_name} (id=${last_id})"
    read -p "请选择 [1-5，默认 1]: " sel
    sel=${sel:-1}

    case "$sel" in
        1) return 0 ;;
        2)
            fetch_speedtest_servers || { error "无法获取节点列表"; return 1; }
            local picked
            picked=$(_pick_server_from_cache china)
            if [[ "$picked" == "__NONE__" ]]; then
                warn "附近列表中未找到国内/同城节点（Ookla 仅返回距离最近的节点）"
                warn "请改用选项 3/4，或到 https://www.speedtest.net 查找目标 Server ID"
                return 1
            fi
            IFS=$'\t' read -r SPEEDTEST_SERVER_ID pname ploc pcountry <<<"$picked"
            info "已选国内优先: ${pname} (${ploc}, ${pcountry}) id=${SPEEDTEST_SERVER_ID}"
            ;;
        3)
            fetch_speedtest_servers || return 1
            echo -e "${CYAN}附近节点:${NC}"
            local lines=() line n
            while IFS= read -r line; do lines+=("$line"); done < <(_list_servers_interactive)
            for line in "${lines[@]}"; do
                IFS=$'\t' read -r n sid name loc <<<"$line"
                echo "  ${n}) [${sid}] ${name} — ${loc}"
            done
            read -p "请输入序号: " n
            [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#lines[@]} ]] || { error "无效序号"; return 1; }
            IFS=$'\t' read -r _ SPEEDTEST_SERVER_ID _ _ <<<"${lines[$((n-1))]}"
            info "已选节点 id=${SPEEDTEST_SERVER_ID}"
            ;;
        4)
            read -p "请输入 Server ID: " SPEEDTEST_SERVER_ID
            [[ "$SPEEDTEST_SERVER_ID" =~ ^[0-9]+$ ]] || { error "ID 须为数字"; return 1; }
            ;;
        5)
            [[ -n "$last_id" ]] || { error "无上次节点记录"; return 1; }
            SPEEDTEST_SERVER_ID="$last_id"
            info "使用上次节点: ${last_name} (id=${last_id})"
            ;;
        *) error "无效选择"; return 1 ;;
    esac
    return 0
}

# ── Speedtest 结果解读 ────────────────────────────────────────────────
# Ookla JSON 中 bandwidth 单位为 bytes/s，转为 Mbps
print_speedtest_report() {
    local json_file="$1"
    python3 - "$json_file" <<'PY'
import json, sys, os

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = json.load(f)

def mbps(bw_bytes_s):
    return bw_bytes_s * 8 / 1_000_000

def grade_latency(ms):
    if ms < 30: return "优秀", "适合竞技游戏/实时会议"
    if ms < 80: return "良好", "视频会议、云桌面基本流畅"
    if ms < 150: return "一般", "轻度上网可用，实时应用可能卡顿"
    return "偏高", "实时应用易卡顿，建议排查路由/Wi‑Fi/跨网"

def grade_speed(mbps_val, kind):
    if kind == "down":
        if mbps_val >= 100: return "优秀", "4K 流媒体、大文件下载无压力"
        if mbps_val >= 50: return "良好", "1080p 多路串流、日常办公足够"
        if mbps_val >= 20: return "一般", "720p 视频、一般浏览可用"
        if mbps_val >= 5: return "偏低", "仅适合网页/音频，高清视频易缓冲"
        return "较差", "网页加载慢，建议检查带宽/干扰/限速"
    else:
        if mbps_val >= 50: return "优秀", "直播推流、大文件上传无压力"
        if mbps_val >= 20: return "良好", "视频会议开摄像头、云备份足够"
        if mbps_val >= 10: return "一般", "日常上传、会议可用"
        if mbps_val >= 3: return "偏低", "大文件上传较慢"
        return "较差", "上传吃力，可能影响会议/备份"

def grade_jitter(ms):
    if ms < 10: return "稳定"
    if ms < 30: return "尚可"
    if ms < 100: return "波动明显"
    return "很不稳定"

def grade_loss(pct):
    if pct <= 0: return "无丢包", "链路可靠"
    if pct < 1: return "极低", "基本无感"
    if pct < 3: return "轻微", "实时应用偶发卡顿"
    return "偏高", "通话/游戏可能断续"

# 自动检测 JSON 格式: Ookla 官方版 vs speedtest-cli (Python版)
# Ookla: {"ping": {"latency": ..., "jitter": ...}, "download": {"bandwidth": ...}, ...}
# speedtest-cli: {"download": <float>, "upload": <float>, "ping": <float>, "server": {...}, "client": {...}}
is_ookla = isinstance(d.get("download"), dict) and d.get("download", {}).get("bandwidth") is not None

if is_ookla:
    # Ookla 官方版格式
    idle_lat = d.get("ping", {}).get("latency", 0)
    idle_jit = d.get("ping", {}).get("jitter", 0)
    dl_bps = d.get("download", {}).get("bandwidth", 0)
    ul_bps = d.get("upload", {}).get("bandwidth", 0)
    dl_lat = d.get("download", {}).get("latency", {}).get("iqm") or d.get("download", {}).get("latency", {}).get("high", 0)
    ul_lat = d.get("upload", {}).get("latency", {}).get("iqm") or d.get("upload", {}).get("latency", {}).get("high", 0)
    loss = d.get("packetLoss") or 0
    isp = d.get("isp", "—")
    iface = d.get("interface", {})
    ext_ip = iface.get("externalIp", "—")
    is_vpn = iface.get("isVpn", False)
    srv = d.get("server", {})
    srv_id = srv.get("id", "")
    srv_name = srv.get("name", "—")
    srv_loc = srv.get("location", "")
    srv_country = srv.get("country", "")
    result_url = d.get("result", {}).get("url", "")
else:
    # speedtest-cli 格式: download/upload 直接是 bytes/sec 的浮点数
    idle_lat = float(d.get("ping", 0) or 0)
    idle_jit = 0  # speedtest-cli 不提供 jitter
    dl_bps = float(d.get("download", 0) or 0)
    ul_bps = float(d.get("upload", 0) or 0)
    dl_lat = None
    ul_lat = None
    loss = 0
    client = d.get("client", {}) or {}
    isp = client.get("isp", "—")
    ext_ip = client.get("ip", "—")
    is_vpn = False
    srv = d.get("server", {}) or {}
    srv_id = str(srv.get("id", ""))
    srv_name = srv.get("sponsor", "—") or srv.get("name", "—")
    srv_loc = srv.get("name", "")
    srv_country = srv.get("country", "")
    result_url = d.get("share", "") or ""

dl = mbps(dl_bps)
ul = mbps(ul_bps)
lat_g, lat_hint = grade_latency(idle_lat)
dl_g, dl_hint = grade_speed(dl, "down")
ul_g, ul_hint = grade_speed(ul, "up")
jit_g = grade_jitter(idle_jit)
loss_g, loss_hint = grade_loss(loss)

print()
print("┌─────────────────────────────────────────────────────────────┐")
print("│                    📊 测速结果摘要                           │")
print("└─────────────────────────────────────────────────────────────┘")
print(f"  测速节点    : {srv_name} ({srv_loc}, {srv_country})")
print(f"  运营商      : {isp}")
print(f"  出口 IP     : {ext_ip}" + ("  [VPN]" if is_vpn else ""))
print("  ───────────────────────────────────────────────────────────")
print(f"  空闲延迟    : {idle_lat:>8.2f} ms   [{lat_g}]  抖动 {idle_jit:.2f} ms ({jit_g})")
print(f"  下载        : {dl:>8.2f} Mbps  [{dl_g}]")
print(f"  上传        : {ul:>8.2f} Mbps  [{ul_g}]")
print(f"  丢包率      : {loss:>8.2f} %     [{loss_g}]")
if dl_lat or ul_lat:
    print(f"  负载延迟    : 下载 IQM {dl_lat:.0f} ms / 上传 IQM {ul_lat:.0f} ms")
print("  ───────────────────────────────────────────────────────────")
print(f"  💡 延迟      : {lat_hint}")
print(f"  💡 下载      : {dl_hint}")
print(f"  💡 上传      : {ul_hint}")
print(f"  💡 丢包      : {loss_hint}")

tips = []
if ":" in str(ext_ip):
    tips.append("当前为 IPv6 出口，跨境/绕路可能导致延迟偏高，可尝试 IPv4 或换更近节点对比")
if idle_lat >= 150:
    tips.append("空闲延迟很高：优先换有线、靠近路由器，关闭 VPN/代理，或指定国内/同城节点重测")
if idle_jit >= 30:
    tips.append("抖动大：检查 Wi‑Fi 干扰（5GHz/靠近 AP），避免测速时大流量下载")
if dl < 10 and ul >= 20:
    tips.append("上传明显快于下载：可能存在 QoS 限速、拥塞或测速时段干扰，建议不同时段复测")
if dl >= 20 and ul < 5:
    tips.append("下载明显快于上传：常见于家庭宽带不对称套餐，属正常但影响直播推流")
if loss >= 1:
    tips.append("有丢包：检查网线/光猫/路由器，或联系运营商排查线路")
if is_vpn:
    tips.append("检测到 VPN，测速反映的是隧道出口质量，非本地宽带真实速率")

# 综合场景判断
issues = sum([
    idle_lat >= 150,
    dl < 20,
    loss >= 1,
    idle_jit >= 50,
])
if issues == 0:
    overall = "整体可用，日常办公与流媒体基本无压力"
elif issues <= 2:
    overall = "整体一般，上网可用但实时应用/高清视频可能受影响"
else:
    overall = "整体偏弱，建议按上方提示优化后复测"

print(f"  📌 综合评价  : {overall}")
if tips:
    print("  ───────────────────────────────────────────────────────────")
    print("  🔧 优化建议")
    for i, t in enumerate(tips, 1):
        print(f"     {i}. {t}")
if result_url:
    print(f"  🔗 详细报告  : {result_url}")
print()

# 供 shell 写日志：单行 TSV（由 grep 过滤，不展示给用户）
print(f"__LOG__\t{dl:.2f}\t{ul:.2f}\t{idle_lat:.2f}\t{loss:.2f}\t{srv_id}\t{srv_name}\t{isp}")
PY
}

# 检测 speedtest 类型: Ookla 官方版 / speedtest-cli (Python版)
detect_speedtest_type() {
    local ver
    ver=$(speedtest --version 2>&1)
    if echo "$ver" | grep -q "speedtest-cli\|Speedtest\.net"; then
        echo "cli"
    else
        echo "ookla"
    fi
}

run_speedtest() {
    if ! command -v speedtest >/dev/null 2>&1; then
        info "正在安装 speedtest..."
        install_speedtest || {
            error "speedtest 安装失败"
            echo -e "  ${YELLOW}替代方案:${NC}"
            echo -e "  1) 使用代理节点测速: ./proxy-speed.sh（无需 speedtest 服务）"
            echo -e "  2) macOS: brew install speedtest-cli  或  pip3 install speedtest-cli"
            echo -e "  3) Linux: pip3 install speedtest-cli  或  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash"
            return 1
        }
    fi

    local st_type
    st_type=$(detect_speedtest_type)
    info "检测到 speedtest 类型: $st_type"

    # 代理检测提醒（speedtest 在代理下容易失败）
    local proxy_info=""
    if [[ -n "${HTTP_PROXY:-}" || -n "${HTTPS_PROXY:-}" || -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
        proxy_info="YES"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        warn "未找到 python3，将使用原始文本输出（无解读/对比）"
        echo -e "\n${BOLD}>>> 启动 Speedtest...${NC}"
        select_speedtest_server 2>/dev/null || true
        local st_args=()
        [[ -n "${SPEEDTEST_SERVER_ID:-}" ]] && st_args+=(-s "$SPEEDTEST_SERVER_ID")
        if [[ "$st_type" == "ookla" ]]; then
            st_args+=(--accept-license --accept-gdpr)
        else
            st_args+=(--json --secure)
        fi
        speedtest "${st_args[@]}"
        return 0
    fi

    echo -e "\n${BOLD}>>> 启动 Speedtest...${NC}"
    [[ -n "$proxy_info" ]] && warn "检测到系统代理变量（HTTP_PROXY/HTTPS_PROXY），建议在测速前 unset 以反映真实带宽"
    select_speedtest_server || return 1

    # 根据类型设置参数
    local st_args=()
    if [[ "$st_type" == "ookla" ]]; then
        st_args=(--accept-license --accept-gdpr -f json)
    else
        # speedtest-cli 使用 --json --secure
        # speedtest-cli 不支持 -f json, 也不需要 --accept-license
        st_args=(--json --secure --timeout 30)
    fi
    if [[ -n "${SPEEDTEST_SERVER_ID:-}" ]]; then
        st_args+=(-s "$SPEEDTEST_SERVER_ID")
        info "指定节点 id=${SPEEDTEST_SERVER_ID}，正在测速（约 30–60 秒）..."
    else
        info "自动选点，正在测速（约 30–60 秒，请保持网络稳定）..."
    fi

    # Ookla 需要先接受一次协议
    if [[ "$st_type" == "ookla" ]]; then
        speedtest --accept-license --accept-gdpr >/dev/null 2>&1 || true
    fi

    local json_tmp
    json_tmp=$(mktemp "${TMPDIR:-/tmp}/speedtest.XXXXXX.json")
    if ! speedtest "${st_args[@]}" >"$json_tmp" 2>/dev/null; then
        rm -f "$json_tmp"
        error "测速失败（speedtest 返回非零退出码）"
        echo -e "  ${YELLOW}可能原因:${NC}"
        echo -e "  1) 代理/VPN 屏蔽了 speedtest.net（常见）→ 解决: unset HTTP_PROXY HTTPS_PROXY 后重试"
        echo -e "  2) 网络不通或 DNS 解析失败"
        echo -e "  3) speedtest 服务临时性问题 → 解决: 5 分钟后重试"
        echo -e "  ${YELLOW}替代方案:${NC}"
        echo -e "  • 使用代理节点测速: $(dirname "$0")/proxy-speed.sh"
        return 1
    fi

    # 验证 JSON 有效性（修复空输出导致的 JSON decode 错误）
    if [[ ! -s "$json_tmp" ]]; then
        rm -f "$json_tmp"
        error "测速失败: speedtest 返回空输出"
        warn "请尝试关闭代理后运行，或使用: $(dirname "$0")/proxy-speed.sh 测试代理节点"
        return 1
    fi

    # 验证 JSON 格式
    if ! python3 -c "import json,sys; json.load(open('$json_tmp'))" 2>/dev/null; then
        error "测速失败: 返回数据不是有效的 JSON"
        warn "实际输出内容（前 500 字节）:"
        head -c 500 "$json_tmp" 2>/dev/null | head -5
        rm -f "$json_tmp"
        return 1
    fi

    local timestamp report log_line
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    report=$(print_speedtest_report "$json_tmp" 2>&1)
    log_line=$(echo "$report" | grep '^__LOG__' | cut -f2-)
    echo "$report" | grep -v '^__LOG__'

    if [[ -n "$log_line" ]]; then
        local dl_mbps ul_mbps lat_ms loss_pct srv_id srv_name isp_name
        IFS=$'\t' read -r dl_mbps ul_mbps lat_ms loss_pct srv_id srv_name isp_name <<< "$log_line"
        _append_speedtest_log "$timestamp" "$dl_mbps" "$ul_mbps" "$lat_ms" "$loss_pct" "$srv_id" "$srv_name" "$isp_name"
        [[ -n "$srv_id" ]] && save_last_server "$srv_id" "$srv_name"
        compare_with_previous
    else
        _ensure_state_dir
        echo "[$timestamp] 执行了外网测速" >> "$LOG_FILE"
    fi
    rm -f "$json_tmp"
}

run_iperf_client() {
    if ! command -v iperf3 >/dev/null 2>&1; then
        info "正在安装 iperf3..."
        install_iperf3 || { error "iperf3 安装失败"; return 1; }
    fi

    local remote_ip="${IPERF_HOST:-}"
    local remote_port="${IPERF_PORT:-5201}"
    local streams="${IPERF_PARALLEL:-1}"
    local duration="${IPERF_TIME:-10}"

    if [[ -z "$remote_ip" ]]; then
        read -p "请输入远程目标 IP 或主机名: " remote_ip
        [[ -z "$remote_ip" ]] && return 1
    fi
    if [[ "$NONINTERACTIVE" != "1" ]]; then
        read -p "远端 iperf3 端口 (默认 5201): " remote_port_in
        [[ -n "$remote_port_in" ]] && remote_port="$remote_port_in"
        read -p "并发流数量 (默认 1): " streams_in
        [[ -n "$streams_in" ]] && streams="$streams_in"
        read -p "测试时长 (秒, 默认 10): " duration_in
        [[ -n "$duration_in" ]] && duration="$duration_in"
    fi

    echo -e "\n${BOLD}>>> 检测远端 iperf3 服务 (${remote_ip}:${remote_port})...${NC}"
    if ! ensure_remote_iperf_server "$remote_ip" "$remote_port"; then
        error "远端服务不可用，已取消压测"
        echo -e "  ${GRAY}提示: 在远端手动执行本脚本选项 3，或确认 IP/防火墙后再试${NC}"
        return 1
    fi

    echo -e "\n${BOLD}>>> 正在进行点对点压测 (目标: $remote_ip:${remote_port}, 并发: $streams, 时长: ${duration}s)${NC}"

    _ensure_state_dir
    info "1. 下载测试 (从远端拉流, -R)..."
    iperf3 -c "$remote_ip" -p "$remote_port" -P "$streams" -t "$duration" -R | tee -a "$LOG_FILE"

    info "2. 上传测试 (向远端推流)..."
    iperf3 -c "$remote_ip" -p "$remote_port" -P "$streams" -t "$duration" | tee -a "$LOG_FILE"
}

cmd_iperf_server() {
    local port="${IPERF_PORT:-5201}"

    if ! command -v iperf3 >/dev/null 2>&1; then
        info "正在安装 iperf3..."
        install_iperf3 || { error "iperf3 安装失败"; return 1; }
    fi

    if [[ "$NONINTERACTIVE" != "1" ]]; then
        read -p "监听端口 (默认 5201): " port_in
        [[ -n "$port_in" ]] && port="$port_in"
    fi

    if [[ "$IPERF_DAEMON" == "1" ]]; then
        pkill -f "iperf3 -s" 2>/dev/null || true
        sleep 0.5
        iperf3 -s -D -p "$port"
        sleep 1
        if pgrep -f "iperf3 -s" >/dev/null 2>&1; then
            success "iperf3 已在后台监听端口 ${port}"
            local ip
            while IFS= read -r ip; do
                info "  可用地址: ${ip}:${port}"
            done < <(_get_lan_ips)
            return 0
        fi
        error "iperf3 后台启动失败"
        return 1
    fi

    echo -e "\n${BOLD}>>> 本机 iperf3 服务端${NC}"
    echo -e "  监听端口: ${CYAN}${port}${NC}"
    echo -e "  请将以下地址填入 ${BOLD}另一台机器${NC} 的选项 2:"
    local ip
    while IFS= read -r ip; do
        echo -e "    ${GREEN}${ip}:${port}${NC}"
    done < <(_get_lan_ips)
    echo -e "  ${GRAY}防火墙需放行 TCP ${port}；按 Ctrl+C 停止服务${NC}\n"

    info "iperf3 服务端已启动..."
    iperf3 -s -p "$port"
}

run_iperf_server() {
    IPERF_DAEMON=0
    cmd_iperf_server
}

cmd_deploy_iperf_server() {
    local host="${IPERF_HOST:-}"
    [[ -n "$host" ]] || { error "需要指定目标 IP (-H)"; return 1; }
    [[ -n "$REMOTE_SSH_TARGET" ]] || { error "需要指定 SSH (--ssh user@host)"; return 1; }
    _ssh_extra_args
    AUTO_YES=1
    remote_deploy_iperf_via_script "$REMOTE_SSH_TARGET" "${IPERF_PORT:-5201}"
}

# ── 主菜单 ────────────────────────────────────────────────────────────
main_menu() {
    get_network_info
    while true; do
        echo -e "\n${BOLD}=========================================="
        echo -e "      综合网络测速工具"
        echo -e "==========================================${NC}"
        echo -e "  1. 本机外网测速 (Speedtest) — 测到公网服务器的带宽/延迟"
        echo -e "  2. 点对点压测客户端 (iperf3) — 连另一台机器的 iperf3 服务"
        echo -e "  3. 点对点压测服务端 (iperf3) — 在本机等待对方来测"
        echo -e "  4. 安装/更新测速工具"
        echo -e "  5. 历史记录与对比 (${LOG_FILE/#$HOME/~})"
        echo -e "  6. 重新检测代理 / 网络状态"
        echo -e "  0. 退出"
        echo "------------------------------------------"
        read -p "选择功能 [0-6]: " choice

        case "$choice" in
            1) run_speedtest ;;
            2) run_iperf_client ;;
            3) run_iperf_server ;;
            4) install_speedtest; install_iperf3 ;;
            5) show_speedtest_history ;;
            6) get_network_info ;;
            0) exit 0 ;;
            *) error "无效选择" ;;
        esac
    done
}

show_cli_help() {
    cat <<EOF
用法: $(basename "$SCRIPT_PATH") [命令] [选项]

命令:
  menu                 交互式菜单（默认）
  speedtest            本机 Ookla 外网测速
  proxy-speed          当前代理节点测速（转调 proxy-speed.sh）
  iperf-server         启动 iperf3 服务端
  iperf-client         连接远端 iperf3 压测
  deploy-server        SSH 上传脚本并在远端启动 iperf3 服务
  install              安装 speedtest / iperf3
  status               显示网络状态与代理检测
  history              测速历史与对比

常用选项:
  -y, --yes            非交互确认（自动 SSH 部署等）
  -h, --help           显示帮助

speedtest:
  --server MODE        auto | china | last | <server-id>

iperf-server:
  -p, --port PORT      监听端口 (默认 5201)
  --daemon             后台运行 (远端部署时使用)

iperf-client:
  -H, --host IP        远端 IP（必填）
  -p, --port PORT      端口 (默认 5201)
  -P, --parallel N     并发流 (默认 1)
  -t, --time SEC       时长秒 (默认 10)
  --ssh USER@HOST      SSH 目标（检测失败时上传脚本到远端）
  -i, --identity FILE  私钥路径（支持 ~）

deploy-server:
  -H, --host IP        用于复检的远端 IP
  --ssh USER@HOST      SSH 目标（必填）
  -p, --port PORT      端口 (默认 5201)
  -i, --identity FILE  私钥路径（支持 ~）

示例:
  $(basename "$SCRIPT_PATH") speedtest --server auto -y
  $(basename "$SCRIPT_PATH") proxy-speed 127.0.0.1 7890
  $(basename "$SCRIPT_PATH") iperf-server --daemon -p 5201
  $(basename "$SCRIPT_PATH") deploy-server -H 43.212.11.160 --ssh ec2-user@43.212.11.160 -i ~/Documents/key.pem -y
  $(basename "$SCRIPT_PATH") iperf-client -H 43.212.11.160 --ssh ec2-user@43.212.11.160 -i ~/Documents/key.pem -y -P 2 -t 15

日志: ${LOG_FILE/#$HOME/~}
EOF
}

_parse_cli_global_opt() {
    case "$1" in
        -y|--yes) AUTO_YES=1; return 0 ;;
        -h|--help) show_cli_help; exit 0 ;;
        *) return 1 ;;
    esac
}

parse_cli() {
    local cmd="${1:-menu}"
    [[ $# -gt 0 ]] && shift
    NONINTERACTIVE=1

    while [[ $# -gt 0 ]]; do
        if _parse_cli_global_opt "$1"; then shift; continue; fi
        break
    done

    case "$cmd" in
        menu)
            NONINTERACTIVE=0
            [[ -t 0 ]] || { error "menu 需要交互终端"; return 1; }
            main_menu
            ;;
        speedtest)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --server) SPEEDTEST_SERVER_MODE="$2"; shift 2 ;;
                    -y|--yes) AUTO_YES=1; shift ;;
                    *) error "未知参数: $1"; return 1 ;;
                esac
            done
            run_speedtest
            ;;
        proxy-speed|proxy)
            local proxy_script
            proxy_script="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/proxy-speed.sh"
            [[ -x "$proxy_script" || -f "$proxy_script" ]] || { error "未找到 proxy-speed.sh: $proxy_script"; return 1; }
            bash "$proxy_script" "$@"
            ;;
        iperf-server)
            IPERF_DAEMON=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -p|--port) IPERF_PORT="$2"; shift 2 ;;
                    --daemon) IPERF_DAEMON=1; shift ;;
                    -y|--yes) AUTO_YES=1; shift ;;
                    *) error "未知参数: $1"; return 1 ;;
                esac
            done
            cmd_iperf_server
            ;;
        iperf-client)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -H|--host) IPERF_HOST="$2"; shift 2 ;;
                    -p|--port) IPERF_PORT="$2"; shift 2 ;;
                    -P|--parallel) IPERF_PARALLEL="$2"; shift 2 ;;
                    -t|--time) IPERF_TIME="$2"; shift 2 ;;
                    --ssh) REMOTE_SSH_TARGET="$2"; shift 2 ;;
                    -i|--identity) SSH_IDENTITY_FILE="$(_expand_user_path "$2")"; shift 2 ;;
                    -y|--yes) AUTO_YES=1; shift ;;
                    *) error "未知参数: $1"; return 1 ;;
                esac
            done
            [[ -n "$IPERF_HOST" ]] || { error "需要 -H/--host"; return 1; }
            run_iperf_client
            ;;
        deploy-server)
            AUTO_YES=1
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -H|--host) IPERF_HOST="$2"; shift 2 ;;
                    -p|--port) IPERF_PORT="$2"; shift 2 ;;
                    --ssh) REMOTE_SSH_TARGET="$2"; shift 2 ;;
                    -i|--identity) SSH_IDENTITY_FILE="$(_expand_user_path "$2")"; shift 2 ;;
                    -y|--yes) AUTO_YES=1; shift ;;
                    *) error "未知参数: $1"; return 1 ;;
                esac
            done
            cmd_deploy_iperf_server
            ;;
        install)
            install_speedtest
            install_iperf3
            ;;
        status) get_network_info ;;
        history) show_speedtest_history ;;
        help|-h|--help) show_cli_help ;;
        *)
            error "未知命令: $cmd"
            show_cli_help
            return 1
            ;;
    esac
}

main_entry() {
    if [[ $# -eq 0 ]]; then
        if [[ -t 0 ]]; then
            main_menu
        else
            show_cli_help
            exit 1
        fi
        return
    fi

    case "$1" in
        -h|--help|help)
            show_cli_help
            ;;
        *)
            parse_cli "$@"
            ;;
    esac
}

main_entry "$@"

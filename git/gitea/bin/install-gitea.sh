#!/bin/bash

# Gitea 一键安装配置脚本
# Gitea 是轻量级自托管 Git 服务，支持代码管理、CI/CD、代码审查、问题跟踪等功能
# 支持 Docker Compose 和主机系统两种安装模式
# Docker 已安装则优先 Docker Compose，否则主机系统模式

# === 颜色定义（放在最前面，确保 sudo 执行时也能使用）===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 日志函数 ===
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
print_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 自动 sudo 提权（仅 Linux 系统需要）===
# macOS 上 Homebrew 安装在用户目录，不需要 root 权限
if [[ $EUID -ne 0 ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS 不需要提权，让 Homebrew 安装在用户目录
        print_info "检测到 macOS 系统，将以当前用户身份运行..."
    else
        # Linux 系统需要提权
        exec sudo "$0" "$@"
    fi
fi

set -e
set -u
set -o pipefail

# === 常量与路径定义 ===
readonly GITEA_BIN_NAME="gitea"
readonly RECOMMENDED_USER="git"
readonly RECOMMENDED_SSH_PORT="2222"

# 默认基础路径
readonly DEFAULT_HOME_DIR="$HOME/gitea"
readonly DEFAULT_LINUX_ETC="/etc/gitea"
readonly DEFAULT_BREW_VAR="/opt/homebrew/var/gitea"
readonly MACOS_GITEA_LABEL="homebrew.mxcl.gitea"
readonly MACOS_GITEA_DAEMON_PLIST="/Library/LaunchDaemons/org.gitea.service.plist"
readonly MACOS_GITEA_USER_AGENT="$HOME/Library/LaunchAgents/${MACOS_GITEA_LABEL}.plist"

# 可能的配置文件路径列表 (按优先级排序)
get_potential_ini_paths() {
    echo "${INSTALL_DIR:-$DEFAULT_HOME_DIR}/config/app.ini"
    echo "$DEFAULT_BREW_VAR/custom/conf/app.ini"
    echo "$DEFAULT_LINUX_ETC/app.ini"
    echo "$HOME/.gitea/app.ini"
}

# 动态寻找当前生效的配置文件
find_active_app_ini() {
    local p
    for p in $(get_potential_ini_paths); do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# 动态寻找当前生效的安装/数据根目录
find_active_gitea_root() {
    local ini
    ini=$(find_active_app_ini)
    if [[ -n "$ini" ]]; then
        # 尝试从配置文件中提取
        local data_path
        data_path=$(grep "^APP_DATA_PATH" "$ini" | awk -F'=' '{print $2}' | tr -d ' ')
        if [[ -n "$data_path" && -d "$data_path" ]]; then
            dirname "$data_path"
            return 0
        fi
    fi
    # 回退探测
    local d
    for d in "$DEFAULT_HOME_DIR" "$DEFAULT_BREW_VAR" "/data/gitea"; do
        [[ -d "$d" ]] && { echo "$d"; return 0; }
    done
    echo "$DEFAULT_HOME_DIR"
}

# === 基础信息获取 ===
get_latest_gitea_version() {
    local version
    version=$(curl -sL https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | cut -d'"' -f4 | sed 's/^v//')
    if [[ -n "$version" ]]; then
        echo "$version"
    else
        echo "1.24.2" # Fallback version
    fi
}
readonly GITEA_VERSION=$(get_latest_gitea_version)
readonly DEFAULT_GITEA_DOMAIN="gitea.local"
readonly DEFAULT_GITEA_PORT="3000"
readonly DEFAULT_GITEA_SSH_PORT="$RECOMMENDED_SSH_PORT"
readonly DEFAULT_GITEA_DB="sqlite3"
readonly INSTALL_DIR=$(find_active_gitea_root)
readonly GITEA_USER="$RECOMMENDED_USER"

# === 检测配置是否符合推荐标准 ===
# 返回值: 0=健康, 1=需要优化
check_config_health() {
    local ini=$1
    [[ -f "$ini" ]] || return 0
    
    local needs_repair=false
    
    # 1. 检查运行用户
    local cur_user
    cur_user=$(grep "^RUN_USER" "$ini" | awk -F'=' '{print $2}' | tr -d ' ' || echo "")
    if [[ "$cur_user" != "$RECOMMENDED_USER" ]]; then
        print_warn "检测到当前运行用户为: ${cur_user:-未知} (推荐: $RECOMMENDED_USER)"
        needs_repair=true
    fi
    
    # 2. 检查 SSH 端口
    local cur_port
    cur_port=$(grep "^SSH_PORT" "$ini" | awk -F'=' '{print $2}' | tr -d ' ' || echo "22")
    if [[ "$cur_port" != "$RECOMMENDED_SSH_PORT" ]]; then
        print_warn "检测到当前 SSH 端口为: $cur_port (推荐: $RECOMMENDED_SSH_PORT)"
        needs_repair=true
    fi

    # 3. 检查内置服务器开关
    local cur_builtin
    cur_builtin=$(grep "^START_SSH_SERVER" "$ini" | awk -F'=' '{print $2}' | tr -d ' ' | tr '[:upper:]' '[:lower:]' || echo "false")
    if [[ "$cur_builtin" != "true" ]]; then
        print_warn "检测到尚未开启内置 SSH 服务器 (推荐开启以实现环境隔离)"
        needs_repair=true
    fi

    [[ "$needs_repair" == "true" ]] && return 1
    return 0
}

# === 生成随机密码 ===
generate_random_password() {
    openssl rand -base64 12 2>/dev/null || tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}
readonly DEFAULT_ROOT_PASSWORD=$(generate_random_password)

# === 全局变量 ===
INSTALL_MODE="auto"
GITEA_DOMAIN="$DEFAULT_GITEA_DOMAIN"
GITEA_PORT="$DEFAULT_GITEA_PORT"
GITEA_SSH_PORT="$DEFAULT_GITEA_SSH_PORT"
ROOT_PASSWORD="$DEFAULT_ROOT_PASSWORD"
GITEA_EMAIL="admin@example.com"
GITEA_DB="$DEFAULT_GITEA_DB"
AUTO_START=true
# SSH 模式: "builtin"=内置SSH服务器(方案1), "system"=系统SSH(方案2)
GITEA_SSH_MODE="system"

# === 辅助工具函数 ===
sed_i() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# 健壮的 INI 值设置函数
set_ini_val() {
    local file=$1; local section=$2; local key=$3; local value=$4
    # 确保 [section]存在
    grep -q "^\[$section\]" "$file" || echo -e "\n[$section]" | sudo tee -a "$file" > /dev/null
    
    # 构造跨平台脚本
    local script="sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; "
    if grep -q "^$key" "$file"; then
        script="${script} sed_i 's|^$key.*|$key = $value|' '$file'"
    else
        script="${script} sed_i '/\[$section\]/a $key = $value' '$file'"
    fi
    sudo bash -c "$script"
}

# 统一服务重启函数
restart_gitea_service() {
    local mode=$1; local ini=$2
    print_info "正在重启服务 ($mode) 以应用更改..."
    case "$mode" in
        docker) cd "$(dirname "$(dirname "$ini")")" && docker compose restart ;;
        launchd) restart_macos_launchdaemon ;;
        brew)   brew services restart gitea ;;
        *)      systemctl restart gitea ;;
    esac
}

cleanup_macos_user_launchagent() {
    [[ "$(uname -s)" == "Darwin" ]] || return 0

    local uid
    uid="$(id -u)"
    if launchctl print "gui/${uid}/${MACOS_GITEA_LABEL}" >/dev/null 2>&1; then
        print_info "卸载当前用户级 Gitea LaunchAgent，避免与系统 LaunchDaemon 冲突..."
        launchctl bootout "gui/${uid}/${MACOS_GITEA_LABEL}" 2>/dev/null || launchctl unload "$MACOS_GITEA_USER_AGENT" 2>/dev/null || true
    fi

    if [[ -f "$MACOS_GITEA_USER_AGENT" ]]; then
        local backup_dir="$HOME/Library/LaunchAgents/disabled"
        mkdir -p "$backup_dir"
        mv "$MACOS_GITEA_USER_AGENT" "$backup_dir/${MACOS_GITEA_LABEL}.plist.$(date +%Y%m%d_%H%M%S)"
        print_success "已备份并移除用户级 LaunchAgent: $backup_dir"
    fi
}

install_macos_user_launchagent() {
    [[ "$(uname -s)" == "Darwin" ]] || {
        print_error "用户级 LaunchAgent 仅支持 macOS"
        return 1
    }

    local gitea_path="${1:-}"
    local work_path="${2:-$DEFAULT_BREW_VAR}"
    local http_port="3000"
    if [[ -z "$gitea_path" ]]; then
        if [[ -x "/opt/homebrew/opt/gitea/bin/gitea" ]]; then
            gitea_path="/opt/homebrew/opt/gitea/bin/gitea"
        elif command -v gitea >/dev/null 2>&1; then
            gitea_path="$(command -v gitea)"
        else
            print_error "未找到 gitea 可执行文件"
            return 1
        fi
    fi
    if [[ -f "$work_path/custom/conf/app.ini" ]]; then
        http_port="$(awk -F= '
            /^[[:space:]]*HTTP_PORT[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$work_path/custom/conf/app.ini")"
        http_port="${http_port:-3000}"
    fi

    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$MACOS_GITEA_USER_AGENT")" "$HOME/Library/Logs"
    launchctl bootout "gui/$(id -u)/${MACOS_GITEA_LABEL}" >/dev/null 2>&1 || true
    launchctl unload "$MACOS_GITEA_USER_AGENT" >/dev/null 2>&1 || true

    cat > "$MACOS_GITEA_USER_AGENT" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${MACOS_GITEA_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${gitea_path}</string>
        <string>web</string>
        <string>--work-path</string>
        <string>${work_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/gitea-launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/gitea-launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>${work_path}</string>
</dict>
</plist>
EOF

    if pgrep -f "gitea web" >/dev/null 2>&1 && lsof -nP -iTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1; then
        print_info "检测到 Gitea 已在运行，仅刷新 LaunchAgent；下次登录将自动启动"
        print_success "macOS LaunchAgent 已安装: $MACOS_GITEA_USER_AGENT"
        return 0
    fi
    if pgrep -f "gitea web" >/dev/null 2>&1; then
        local stale_pids
        stale_pids="$(pgrep -f "gitea web" 2>/dev/null || true)"
        print_info "检测到 Gitea 进程未监听 ${http_port}，先停止旧进程: $stale_pids"
        kill $stale_pids 2>/dev/null || true
        sleep 2
    fi

    launchctl bootstrap "gui/$(id -u)" "$MACOS_GITEA_USER_AGENT" 2>/dev/null || launchctl load -w "$MACOS_GITEA_USER_AGENT"
    launchctl enable "gui/$(id -u)/${MACOS_GITEA_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/${MACOS_GITEA_LABEL}" 2>/dev/null || true
    print_success "macOS LaunchAgent 已安装: $MACOS_GITEA_USER_AGENT"
}

install_macos_launchdaemon() {
    local gitea_path="${1:-/opt/homebrew/opt/gitea/bin/gitea}"
    local work_path="${2:-$DEFAULT_BREW_VAR}"

    [[ "$(uname -s)" == "Darwin" ]] || return 0
    cleanup_macos_user_launchagent

    print_info "配置 macOS 系统 LaunchDaemon: $MACOS_GITEA_DAEMON_PLIST"
    sudo tee "$MACOS_GITEA_DAEMON_PLIST" >/dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UserName</key>
    <string>${GITEA_USER}</string>
    <key>GroupName</key>
    <string>${GITEA_USER}</string>
    <key>KeepAlive</key>
    <true/>
    <key>Label</key>
    <string>${MACOS_GITEA_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${gitea_path}</string>
        <string>web</string>
        <string>--work-path</string>
        <string>${work_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/opt/homebrew/var/log/gitea.log</string>
    <key>StandardOutPath</key>
    <string>/opt/homebrew/var/log/gitea.log</string>
</dict>
</plist>
EOF

    sudo chown root:wheel "$MACOS_GITEA_DAEMON_PLIST" 2>/dev/null || true
    sudo chmod 644 "$MACOS_GITEA_DAEMON_PLIST"
}

start_macos_launchdaemon() {
    [[ "$(uname -s)" == "Darwin" ]] || return 1
    [[ -f "$MACOS_GITEA_DAEMON_PLIST" ]] || return 1

    cleanup_macos_user_launchagent
    sudo launchctl bootout "system/${MACOS_GITEA_LABEL}" >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "$MACOS_GITEA_DAEMON_PLIST" 2>/dev/null || true
    sudo launchctl enable "system/${MACOS_GITEA_LABEL}" 2>/dev/null || true
    sudo launchctl kickstart -k "system/${MACOS_GITEA_LABEL}"
}

stop_macos_launchdaemon() {
    [[ "$(uname -s)" == "Darwin" ]] || return 1
    sudo launchctl bootout "system/${MACOS_GITEA_LABEL}" >/dev/null 2>&1 || true
}

restart_macos_launchdaemon() {
    stop_macos_launchdaemon || true
    start_macos_launchdaemon
}

# === 获取网络接口信息（macOS）===
get_network_interfaces_macos() {
    local result=""
    # 获取所有网络接口（排除 lo 开头的回环接口）
    local all_interfaces=$(ifconfig -l 2>/dev/null)
    
    for iface in $all_interfaces; do
        # 跳过回环接口
        [[ "$iface" =~ ^lo ]] && continue
        
        local status=$(ifconfig "$iface" 2>/dev/null | grep -E "status:" | awk '{print $2}')
        local ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        
        if [[ -n "$ip" ]]; then
            local status_icon="❓"
            local status_text="未知"
            case "$status" in
                active)
                    status_icon="🟢"
                    status_text="活跃"
                    ;;
                inactive)
                    status_icon="⚫"
                    status_text="未连接"
                    ;;
            esac
            result="${result}${iface}|${ip}|${status_icon} ${status_text}
"
        fi
    done
    
    # 输出结果（不用 echo -e，直接用换行符）
    printf "%s" "$result"
}

# === 获取网络接口信息（Linux）===
get_network_interfaces_linux() {
    local result=""
    local interfaces=""
    
    if command -v ip &>/dev/null; then
        interfaces=$(ip -o link show 2>/dev/null | grep -v "lo:" | awk -F': ' '{print $2}' | cut -d'@' -f1)
        for iface in $interfaces; do
            local state=$(ip link show "$iface" 2>/dev/null | grep -oP '(?<=state )[^ ]+' || echo "UNKNOWN")
            local ip=$(ip addr show "$iface" 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
            
            if [[ -n "$ip" ]]; then
                local status_icon="❓"; local status_text="未知"
                [[ "$state" == "UP" ]] && { status_icon="🟢"; status_text="已连接"; }
                [[ "$state" == "DOWN" ]] && { status_icon="⚫"; status_text="未连接"; }
                result="${result}${iface}|${ip}|${status_icon} ${status_text}\n"
            fi
        done
    elif command -v ifconfig &>/dev/null; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[a-z0-9] ]]; then
                local iface=$(echo "$line" | awk '{print $1}' | sed 's/://')
                [[ "$iface" == "lo" ]] && continue
                local ip=$(ifconfig "$iface" | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}')
                [[ -n "$ip" ]] && result="${result}${iface}|${ip}|🟢 活跃\n"
            fi
        done < <(ifconfig 2>/dev/null)
    fi
    echo -e "$result"
}

# === 获取本地 IP（支持多网卡选择，显示接口名和状态）===
# 注意: 交互式信息输出到 stderr，仅最终 IP 输出到 stdout
get_local_ip() {
    local interfaces_info=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        interfaces_info=$(get_network_interfaces_macos)
    else
        interfaces_info=$(get_network_interfaces_linux)
    fi
    
    # 调试信息（如果接口列表为空）
    if [[ -z "$interfaces_info" ]]; then
        echo -e "${YELLOW}[WARN]${NC} 未检测到网络接口信息，尝试备用方法..." >&2
        # 备用方法：直接解析 ifconfig 输出
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # 更健壮的备用方法
            local iface=""
            local ip=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^[a-z] ]]; then
                    iface=$(echo "$line" | cut -d: -f1)
                elif [[ "$line" =~ "inet " ]] && [[ ! "$line" =~ "127.0.0.1" ]]; then
                    ip=$(echo "$line" | awk '{print $2}')
                    if [[ -n "$ip" ]] && [[ -n "$iface" ]]; then
                        interfaces_info="${interfaces_info}${iface}|${ip}|🟢 活跃
"
                    fi
                fi
            done < <(ifconfig 2>/dev/null)
        fi
    fi
    
    # 过滤掉空行，统计有效接口数量
    local valid_interfaces=$(echo "$interfaces_info" | grep -v "^$" | grep "|")
    local iface_count=$(echo "$valid_interfaces" | grep -c "|" || echo "0")
    
    if [[ "$iface_count" -gt 1 ]]; then
        # 多个接口，让用户选择（所有交互信息输出到 stderr）
        echo "" >&2
        echo -e "${BLUE}[INFO]${NC} 检测到多个网络接口:" >&2
        echo "" >&2
        printf "  %-4s %-12s %-18s %s\n" "序号" "接口名" "IP地址" "状态" >&2
        echo "  --------------------------------------------------" >&2
        
        local i=1
        local iface_array=()
        local ip_array=()
        
        while IFS='|' read -r iface ip status; do
            [[ -z "$iface" ]] && continue
            iface_array+=("$iface")
            ip_array+=("$ip")
            printf "  %-4s %-12s %-18s %s\n" "$i)" "$iface" "$ip" "$status" >&2
            ((i++))
        done <<< "$valid_interfaces"
        
        echo "" >&2
        read -rp "请选择用于 Gitea 的网络接口 [1]: " choice < /dev/tty
        choice=${choice:-1}
        
        local selected_ip="${ip_array[$((choice-1))]}"
        local selected_iface="${iface_array[$((choice-1))]}"
        
        if [[ -n "$selected_ip" ]]; then
            echo -e "${GREEN}[INFO]${NC} 已选择: $selected_iface ($selected_ip)" >&2
            echo "$selected_ip"
            return
        fi
    elif [[ "$iface_count" -eq 1 ]]; then
        # 单个接口
        local ip=$(echo "$valid_interfaces" | cut -d'|' -f2)
        local iface=$(echo "$valid_interfaces" | cut -d'|' -f1)
        echo -e "${BLUE}[INFO]${NC} 使用网络接口: $iface ($ip)" >&2
        echo "$ip"
        return
    fi
    
    # 回退方案
    echo -e "${YELLOW}[WARN]${NC} 无法获取网络接口信息，使用默认方法" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1
    else
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

# === 检测 hosts 文件中是否已配置指定域名 ===
check_hosts_entry() {
    local domain="$1"
    if grep -qE "^[^#]*\s${domain}(\s|$)" /etc/hosts 2>/dev/null; then
        return 0  # 已存在
    fi
    return 1  # 不存在
}

# === 添加 hosts 记录（需要提权）===
add_hosts_entry() {
    local ip="$1"
    local domain="$2"
    
    # 检查是否已有记录
    if check_hosts_entry "$domain"; then
        print_info "hosts 已配置: $domain"
        return 0
    fi
    
    print_info "需要添加 hosts 记录: $ip $domain"
    
    # 尝试添加
    if [[ $EUID -eq 0 ]]; then
        # 已有 root 权限，直接添加
        echo "$ip $domain" >> /etc/hosts
        print_success "hosts 记录已添加: $ip $domain"
    else
        # 需要 sudo 提权
        if echo "$ip $domain" | sudo tee -a /etc/hosts > /dev/null 2>&1; then
            print_success "hosts 记录已添加: $ip $domain"
        else
            print_warn "自动添加 hosts 记录失败，请手动执行:"
            echo "   echo \"$ip $domain\" | sudo tee -a /etc/hosts"
            return 1
        fi
    fi
}

# === 检测操作系统 ===
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}

# === 检测架构 ===
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "$(uname -m)" ;;
    esac
}

# === 检查 Docker ===
check_docker() {
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        return 0
    fi
    return 1
}

# === 检查 docker-compose ===
check_docker_compose() {
    if docker compose version &> /dev/null; then
        return 0
    elif command -v docker-compose &>/dev/null; then
        return 0
    fi
    return 1
}

# === 显示帮助 ===
show_help() {
    cat << 'EOF'
Gitea 一键安装配置脚本

Gitea 是轻量级自托管 Git 服务，类似 GitHub/GitLab，但更轻量。

用法: ./install-gitea.sh [选项]

选项:
    -h, --help          显示此帮助信息
    --uninstall         卸载 Gitea
    --status            查看运行状态
    --start             启动 Gitea
    --stop              停止 Gitea
    --repair            修复/优化现有配置 (迁移至 git 用户和 2222 端口)

说明:
    - 自动检测 Docker，已安装则优先 Docker Compose 模式
    - 未安装 Docker 则使用主机系统模式
    - 支持 Linux (CentOS/Ubuntu) 和 macOS
    - macOS 主机模式需要 Docker (Gitea 无原生 macOS 包)

EOF
}

# === 交互式配置 ===
interactive_config() {
    # 支持非交互模式
    if [[ "${GITEA_NON_INTERACTIVE:-false}" == "true" ]]; then
        print_info "检测到非交互模式，使用默认值或环境变量配置..."
        return 0
    fi

    echo ""
    print_header "Gitea 安装配置（交互模式）"
    echo ""

    local input
    read -rp "Gitea 访问域名 [$GITEA_DOMAIN]: " input
    GITEA_DOMAIN="${input:-$GITEA_DOMAIN}"

    read -rp "HTTP 端口 [$GITEA_PORT]: " input
    GITEA_PORT="${input:-$GITEA_PORT}"

    echo ""
    echo "SSH 模式选择:"
    echo "  1) 内置 SSH 服务器 (推荐) - 使用 Gitea 独立服务，建议端口 2222"
    echo "  2) 系统 SSH 模式 - 复用系统 SSH (22 端口)，配置较复杂"
    read -rp "SSH 模式 [1]: " input
    case "${input:-1}" in
        1)
            GITEA_SSH_MODE="builtin"
            echo -e "已选择: 内置 SSH 服务器"
            read -rp "Gitea SSH 端口 [$GITEA_SSH_PORT]: " input
            GITEA_SSH_PORT="${input:-$GITEA_SSH_PORT}"
            ;;
        2)
            GITEA_SSH_MODE="system"
            GITEA_SSH_PORT="22"
            echo "已选择: 系统 SSH (端口 22)"
            ;;
        *)
            GITEA_SSH_MODE="builtin"
            GITEA_SSH_PORT="2222"
            ;;
    esac

    read -rp "管理员密码 [$ROOT_PASSWORD]: " input
    ROOT_PASSWORD="${input:-$ROOT_PASSWORD}"

    read -rp "管理员邮箱 [$GITEA_EMAIL]: " input
    GITEA_EMAIL="${input:-$GITEA_EMAIL}"

    echo ""
}

# === 显示安装配置 ===
show_config() {
    echo "安装配置:"
    echo "  安装模式：$INSTALL_MODE"
    echo "  访问域名：$GITEA_DOMAIN"
    echo "  HTTP 端口：$GITEA_PORT"
    local ssh_mode_desc=""
    if [[ "$GITEA_SSH_MODE" == "system" ]]; then
        ssh_mode_desc="系统 SSH (端口 $GITEA_SSH_PORT)"
    else
        ssh_mode_desc="内置 SSH 服务器 (端口 $GITEA_SSH_PORT)"
    fi
    echo "  SSH 模式：$ssh_mode_desc"
    echo "  管理员密码：$ROOT_PASSWORD"
    echo "  管理员邮箱：$GITEA_EMAIL"
    echo "  数据库：$GITEA_DB"
    echo "  自动启动：$AUTO_START"
    echo ""
}

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"

    local os=$(detect_os)

    # 确定安装模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if check_docker && check_docker_compose; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，使用 Docker Compose 模式安装"
        else
            INSTALL_MODE="host"
            print_info "未检测到 Docker，使用主机模式安装"
        fi
    fi

    # 主机模式系统检查
    if [[ "$INSTALL_MODE" == "host" ]]; then
        case "$os" in
            centos) print_info "检测到 CentOS/RHEL 系统" ;;
            ubuntu) print_info "检测到 Debian/Ubuntu 系统" ;;
            macos) print_info "检测到 macOS 系统" ;;
            *)
                print_error "不支持的操作系统: $os"
                echo "支持的系统：CentOS/RHEL, Debian/Ubuntu, macOS"
                exit 1
                ;;
        esac
    fi

    # 检查端口占用
    local check_ports=("$GITEA_PORT" "$GITEA_SSH_PORT")
    for port in "${check_ports[@]}"; do
        if command -v ss &>/dev/null; then
            if ss -tln | grep -q ":${port} "; then
                print_warn "警告: 端口 ${port} 已被占用，请确保安装后没有冲突。"
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -tln | grep -q ":${port} "; then
                print_warn "警告: 端口 ${port} 已被占用，请确保安装后没有冲突。"
            fi
        fi
    done
}

# === Docker Compose 安装 ===
install_docker() {
    print_header "Docker Compose 模式安装"

    local install_dir="$INSTALL_DIR"
    mkdir -p "$install_dir"

    # 获取系统用户 UID/GID
    local u_uid=$(id -u "$GITEA_USER" 2>/dev/null || echo "1000")
    local u_gid=$(id -g "$GITEA_USER" 2>/dev/null || echo "1000")

    # 生成 .env 文件用于 Docker Compose
    cat > "$install_dir/.env" << EOF
GITEA_VERSION=${GITEA_VERSION}
GITEA_UID=${u_uid}
GITEA_GID=${u_gid}
GITEA_DOMAIN=${GITEA_DOMAIN}
GITEA_PORT=${GITEA_PORT}
GITEA_SSH_PORT=${GITEA_SSH_PORT}
GITEA_DB=${GITEA_DB}
EOF

    # 复制或生成 docker-compose.yml
    if [[ -f "${SCRIPT_DIR:-.}/../docker-compose.yml" ]]; then
        cp "${SCRIPT_DIR:-.}/../docker-compose.yml" "$install_dir/"
    else
        cat > "$install_dir/docker-compose.yml" << EOF
version: "3.8"
services:
  gitea:
    image: gitea/gitea:\${GITEA_VERSION:-latest}
    container_name: gitea
    environment:
      - USER_UID=\${GITEA_UID:-1000}
      - USER_GID=\${GITEA_GID:-1000}
      - GITEA__server__DOMAIN=\${GITEA_DOMAIN}
      - GITEA__server__HTTP_PORT=\${GITEA_PORT}
      - GITEA__server__SSH_PORT=\${GITEA_SSH_PORT}
      - GITEA__server__ROOT_URL=http://\${GITEA_DOMAIN}:\${GITEA_PORT}
      - GITEA__database__DB_TYPE=\${GITEA_DB}
    ports:
      - "\${GITEA_PORT}:3000"
      - "\${GITEA_SSH_PORT}:22"
    volumes:
      - ./data:/data
      - ./config:/etc/gitea
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/healthz"]
    networks:
      - gitea
networks:
  gitea:
    driver: bridge
EOF
    fi

    # 生成 app.ini（管理员密码）
    mkdir -p "$install_dir/config"
    cat > "$install_dir/config/app.ini" << EOF
[security]
INSTALL_LOCK = true
SECRET_KEY   = $(generate_random_password)
INTERNAL_TOKEN = $(generate_random_password)

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW  = false

[server]
DOMAIN   = ${GITEA_DOMAIN}
HTTP_PORT = ${GITEA_PORT}
ROOT_URL = http://${GITEA_DOMAIN}:${GITEA_PORT}

[database]
DB_TYPE = ${GITEA_DB}
EOF

    # 启动
    print_info "正在启动 Gitea..."
    cd "$install_dir"
    docker compose up -d 2>/dev/null || docker-compose up -d

    # 等待启动
    print_info "等待 Gitea 启动..."
    local retry=0
    while [[ $retry -lt 30 ]]; do
        if curl -s -o /dev/null "http://localhost:${GITEA_PORT}" 2>/dev/null; then
            break
        fi
        sleep 2
        ((retry++))
    done

    print_success "Gitea 启动完成"
}

# === 系统用户管理 ===
setup_system_user() {
    print_info "检测系统用户 $GITEA_USER..."
    
    if ! id "$GITEA_USER" &>/dev/null; then
        print_info "正在创建系统用户 $GITEA_USER..."
        if [[ "$(uname -s)" == "Darwin" ]]; then
            # macOS: 使用 sysadminctl
            sudo sysadminctl -addUser "$GITEA_USER" -fullName "Gitea User" -shell /bin/bash -home "/Users/$GITEA_USER" 2>/dev/null || {
                print_warn "sysadminctl 创建用户失败，尝试常规方式..."
            }
        else
            # Linux: 使用 useradd
            useradd -m -s /bin/bash "$GITEA_USER"
        fi
        print_success "用户 $GITEA_USER 创建成功"
    else
        print_success "用户 $GITEA_USER 已存在"
    fi

    # 初始化 SSH 目录
    local user_home
    if [[ "$(uname -s)" == "Darwin" ]]; then
        user_home="/Users/$GITEA_USER"
    else
        user_home=$(eval echo "~$GITEA_USER")
    fi

    if [[ -d "$user_home" ]]; then
        sudo mkdir -p "$user_home/.ssh"
        sudo touch "$user_home/.ssh/authorized_keys"
        sudo chmod 700 "$user_home/.ssh"
        sudo chmod 600 "$user_home/.ssh/authorized_keys"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sudo chown -R "$GITEA_USER:staff" "$user_home/.ssh" 2>/dev/null || true
        else
            sudo chown -R "$GITEA_USER:$GITEA_USER" "$user_home/.ssh" 2>/dev/null || true
        fi
    fi
}

# === 主机模式安装 ===
install_host() {
    print_header "主机模式安装"

    local os=$(detect_os)
    local arch=$(detect_arch)

    # 1. 设置系统用户
    setup_system_user

    # macOS 优先使用 Homebrew
    if [[ "$os" == "macos" ]] && command -v brew &>/dev/null; then
        install_host_macos_brew
        return 0
    fi

    # 创建目录
    mkdir -p "$INSTALL_DIR"

    # 下载 Gitea (根据系统和架构)
    local gitea_url
    local base_url="https://dl.gitea.com/gitea/${GITEA_VERSION}"
    
    # 镜像支持
    if [[ -n "${GH_PROXY_URL:-}" ]]; then
        base_url="${GH_PROXY_URL}/https://github.com/go-gitea/gitea/releases/download/v${GITEA_VERSION}"
    fi

    if [[ "$os" == "macos" ]]; then
        # macOS 使用 darwin 版本
        if [[ "$arch" == "arm64" ]]; then
            gitea_url="${base_url}/gitea-${GITEA_VERSION}-darwin-10.12-arm64"
        else
            gitea_url="${base_url}/gitea-${GITEA_VERSION}-darwin-10.12-amd64"
        fi
    else
        # Linux 版本
        gitea_url="${base_url}/gitea-${GITEA_VERSION}-linux-${arch}"
    fi

    print_info "正在下载 Gitea ${GITEA_VERSION}..."
    print_info "下载地址: $gitea_url"

    local install_path="/usr/local/bin/gitea"
    curl -f -L -o "$install_path" "$gitea_url"
    chmod +x "$install_path"

    print_success "Gitea 下载完成"

    # 创建配置目录
    mkdir -p /etc/gitea

    # 生成 app.ini
    cat > /etc/gitea/app.ini << EOF
[server]
APP_DATA_PATH    = ${INSTALL_DIR}/data
DOMAIN           = ${GITEA_DOMAIN}
HTTP_PORT        = ${GITEA_PORT}
ROOT_URL         = http://${GITEA_DOMAIN}:${GITEA_PORT}
DISABLE_SSH      = false
SSH_PORT         = ${GITEA_SSH_PORT}

[database]
DB_TYPE  = ${GITEA_DB}
PATH     = ${INSTALL_DIR}/data/gitea.db

[repository]
ROOT = ${INSTALL_DIR}/repos

[security]
INSTALL_LOCK = true
SECRET_KEY   = $(generate_random_password)
INTERNAL_TOKEN = $(generate_random_password)

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW  = false

[log]
ROOT_PATH = ${INSTALL_DIR}/log
MODE      = console
LEVEL     = Info
EOF

    mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/repos" "${INSTALL_DIR}/log"

    # 启动服务 (根据系统)
    if [[ "$os" == "macos" ]]; then
        install_host_macos "$install_path"
    else
        install_host_linux "$install_path"
    fi
}

# === macOS Homebrew 安装 ===
install_host_macos_brew() {
    print_info "使用 Homebrew 安装 Gitea..."

    # 安装 Gitea
    brew install gitea

    # 根据 SSH 模式进行配置
    if [[ "$GITEA_SSH_MODE" == "system" ]]; then
        # 方案2: 系统 SSH 模式
        print_info "配置系统 SSH 模式..."
        setup_system_user
    else
        # 方案1: 内置 SSH 服务器模式
        print_info "配置内置 SSH 服务器模式..."
    fi

    # 检查是否已有配置文件（判断是否首次安装）
    local app_ini="/opt/homebrew/var/gitea/custom/conf/app.ini"
    if [[ -f "$app_ini" ]]; then
        print_info "检测到已有配置文件，将更新配置..."
        # 已有配置，更新关键配置项
        if ! grep -q "^\[server\]" "$app_ini" 2>/dev/null; then
            cat >> "$app_ini" << EOF

[server]
DOMAIN           = ${GITEA_DOMAIN}
HTTP_PORT        = ${GITEA_PORT}
ROOT_URL         = http://${GITEA_DOMAIN}:${GITEA_PORT}
DISABLE_SSH      = false
SSH_PORT         = ${GITEA_SSH_PORT}
START_SSH_SERVER = $( [[ "$GITEA_SSH_MODE" == "builtin" ]] && echo "true" || echo "false" )
SSH_CREATE_AUTHORIZED_KEYS_FILE = false
EOF
        else
            # 更新现有配置
            update_gitea_config_for_ssh_mode "$app_ini"
        fi
    else
        # 首次安装：创建预配置
        print_info "首次安装，配置 ${GITEA_SSH_MODE} SSH 模式..."
        mkdir -p /opt/homebrew/var/gitea/custom/conf
        local start_ssh_server="false"
        [[ "$GITEA_SSH_MODE" == "builtin" ]] && start_ssh_server="true"
        cat > "$app_ini" << EOF
[server]
DOMAIN           = ${GITEA_DOMAIN}
HTTP_PORT        = ${GITEA_PORT}
ROOT_URL         = http://${GITEA_DOMAIN}:${GITEA_PORT}
DISABLE_SSH      = false
SSH_PORT         = ${GITEA_SSH_PORT}
START_SSH_SERVER = ${start_ssh_server}
SSH_CREATE_AUTHORIZED_KEYS_FILE = false

[security]
INSTALL_LOCK = false

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW  = false
EOF
    fi

    # 创建目录并设置权限
    mkdir -p /opt/homebrew/var/gitea/data /opt/homebrew/var/gitea/repos /opt/homebrew/var/gitea/log
    sudo chown -R "$GITEA_USER:$GITEA_USER" /opt/homebrew/var/gitea 2>/dev/null || true
    sudo mkdir -p /opt/homebrew/var/log
    sudo touch /opt/homebrew/var/log/gitea.log
    sudo chown "$GITEA_USER:$GITEA_USER" /opt/homebrew/var/log/gitea.log 2>/dev/null || true

    # 启动服务
    print_info "启动 Gitea 服务..."
    install_macos_launchdaemon "/opt/homebrew/opt/gitea/bin/gitea" "/opt/homebrew/var/gitea"
    start_macos_launchdaemon

    # 等待启动
    local retry=0
    while [[ $retry -lt 30 ]]; do
        if pgrep -f "gitea web" &>/dev/null; then
            break
        fi
        sleep 2
        ((retry++))
    done

    print_success "Gitea 启动完成"
    print_info "Gitea 路径: /opt/homebrew/bin/gitea"
    print_info "数据路径: /opt/homebrew/var/gitea"
    if [[ "$GITEA_SSH_MODE" == "system" ]]; then
        print_info "SSH 模式: 系统 SSH (端口 ${GITEA_SSH_PORT})"
        print_info "Git 用户: /Users/git"
    else
        print_info "SSH 模式: 内置 SSH 服务器 (端口 ${GITEA_SSH_PORT})"
        print_info "注意: 请确保端口 ${GITEA_SSH_PORT} 未被占用"
    fi
}

# === 更新 Gitea 配置为系统 SSH 模式 ===
update_gitea_config_for_system_ssh() {
    local app_ini="$1"
    print_info "更新 Gitea 配置为系统 SSH 模式..."

    # 使用 sed_i 更新配置项
    if grep -q "^SSH_PORT" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^SSH_PORT.*/SSH_PORT = 22/' '$app_ini'"
    else
        echo "SSH_PORT = 22" | sudo tee -a "$app_ini" > /dev/null
    fi

    if grep -q "^START_SSH_SERVER" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^START_SSH_SERVER.*/START_SSH_SERVER = false/' '$app_ini'"
    else
        echo "START_SSH_SERVER = false" | sudo tee -a "$app_ini" > /dev/null
    fi

    if grep -q "^SSH_CREATE_AUTHORIZED_KEYS_FILE" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^SSH_CREATE_AUTHORIZED_KEYS_FILE.*/SSH_CREATE_AUTHORIZED_KEYS_FILE = false/' '$app_ini'"
    else
        echo "SSH_CREATE_AUTHORIZED_KEYS_FILE = false" | sudo tee -a "$app_ini" > /dev/null
    fi

    print_success "Gitea 配置已更新为系统 SSH 模式"
}

# === 根据 SSH 模式更新 Gitea 配置 ===
update_gitea_config_for_ssh_mode() {
    local app_ini="$1"
    local start_ssh_server="false"
    [[ "$GITEA_SSH_MODE" == "builtin" ]] && start_ssh_server="true"

    print_info "更新 Gitea 配置为 ${GITEA_SSH_MODE} SSH 模式..."

    # 使用 sed 更新配置项
    if grep -q "^SSH_PORT" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^SSH_PORT.*/SSH_PORT = ${GITEA_SSH_PORT}/' '$app_ini'"
    else
        echo "SSH_PORT = ${GITEA_SSH_PORT}" | sudo tee -a "$app_ini" > /dev/null
    fi

    if grep -q "^START_SSH_SERVER" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^START_SSH_SERVER.*/START_SSH_SERVER = ${start_ssh_server}/' '$app_ini'"
    else
        echo "START_SSH_SERVER = ${start_ssh_server}" | sudo tee -a "$app_ini" > /dev/null
    fi

    if grep -q "^SSH_CREATE_AUTHORIZED_KEYS_FILE" "$app_ini"; then
        sudo bash -c "sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; sed_i 's/^SSH_CREATE_AUTHORIZED_KEYS_FILE.*/SSH_CREATE_AUTHORIZED_KEYS_FILE = false/' '$app_ini'"
    else
        echo "SSH_CREATE_AUTHORIZED_KEYS_FILE = false" | sudo tee -a "$app_ini" > /dev/null
    fi

    print_success "Gitea 配置已更新为 ${GITEA_SSH_MODE} SSH 模式"
}

# === macOS 手动安装 (无 Homebrew) ===
install_host_macos() {
    local gitea_path="$1"

    print_info "配置 macOS 启动服务..."

    # 创建 LaunchDaemon plist
    cat > /Library/LaunchDaemons/io.gitea.server.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.gitea.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${gitea_path}</string>
        <string>web</string>
        <string>-c</string>
        <string>/etc/gitea/app.ini</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/log/gitea.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/log/gitea-error.log</string>
</dict>
</plist>
EOF

    # 加载并启动服务
    launchctl load /Library/LaunchDaemons/io.gitea.server.plist 2>/dev/null || true
    launchctl start io.gitea.server 2>/dev/null || true

    # 等待启动
    local retry=0
    while [[ $retry -lt 30 ]]; do
        if pgrep -f "gitea web" &>/dev/null; then
            break
        fi
        sleep 2
        ((retry++))
    done

    print_success "Gitea 启动完成"
}

# === Linux 主机安装 ===
install_host_linux() {
    local gitea_path="$1"

    print_info "配置 Linux systemd 服务..."

    chown -R "$GITEA_USER:$GITEA_USER" /etc/gitea
    chown -R "$GITEA_USER:$GITEA_USER" "$INSTALL_DIR"

    # 创建 systemd 服务
    cat > /etc/systemd/system/gitea.service << EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=syslog.target network.target

[Service]
Type=simple
User=${GITEA_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${gitea_path} web -c /etc/gitea/app.ini
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable gitea
    systemctl start gitea

    # 等待启动
    local retry=0
    while [[ $retry -lt 30 ]]; do
        if systemctl is-active gitea &>/dev/null; then
            break
        fi
        sleep 2
        ((retry++))
    done

    print_success "Gitea 启动完成"
}

# === 显示安装完成信息 ===
show_post_install_info() {
    print_header "安装完成"

    local local_ip
    local_ip=$(get_local_ip)
    local os=$(detect_os)

    echo -e "${GREEN}Gitea 安装成功！${NC}"
    echo ""
    echo -e "${BOLD}访问地址:${NC} http://${GITEA_DOMAIN}:${GITEA_PORT}"
    echo ""
    echo -e "${YELLOW}${BOLD}首次访问提示:${NC}"
    echo "  1. 在浏览器中打开上述地址"
    echo "  2. 首次访问会显示安装向导"
    echo "  3. 在安装向导中设置管理员账号和密码"
    echo "  4. 数据库保持默认配置（SQLite3）即可"
    echo ""
    echo -e "${BOLD}建议管理员配置:${NC}"
    echo "  管理员用户名: root"
    echo "  管理员邮箱: $GITEA_EMAIL"
    echo ""
    echo -e "${BOLD}如需使用 MySQL 数据库（需提前创建）:${NC}"
    echo "  安装向导中选择 MySQL，填写以下信息:"
    echo "    主机: 127.0.0.1    端口: 3306"
    echo "    用户名: root       数据库名: gitea"
    echo ""
    echo "  提前执行以下 SQL 创建数据库和授权:"
    echo "    CREATE DATABASE gitea CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    echo "    GRANT ALL PRIVILEGES ON gitea.* TO 'root'@'%';"
    echo "    FLUSH PRIVILEGES;"

    # hosts 配置：自动检测并添加
    if [[ -n "$local_ip" ]] && [[ ! "$GITEA_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo ""
        add_hosts_entry "$local_ip" "$GITEA_DOMAIN"
    fi

    echo ""
    echo -e "${BOLD}常用命令:${NC}"

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  启动服务：cd $INSTALL_DIR && docker compose up -d"
        echo "  停止服务：cd $INSTALL_DIR && docker compose down"
        echo "  查看日志：cd $INSTALL_DIR && docker compose logs -f"
        echo "  查看状态：cd $INSTALL_DIR && docker compose ps"
    elif [[ "$os" == "macos" ]]; then
        echo "  启动服务：brew services start gitea"
        echo "  停止服务：brew services stop gitea"
        echo "  重启服务：brew services restart gitea"
        echo "  查看日志：tail -f /opt/homebrew/var/gitea/log/gitea.log"
        echo "  查看状态：brew services info gitea"
    else
        echo "  启动服务：systemctl start gitea"
        echo "  停止服务：systemctl stop gitea"
        echo "  查看状态：systemctl status gitea"
        echo "  查看日志：journalctl -u gitea -f"
        echo "  重新配置：编辑 /etc/gitea/app.ini 后 systemctl restart gitea"
    fi

    # macOS SSH 模式说明
    if [[ "$os" == "macos" ]] && [[ "$INSTALL_MODE" == "host" ]]; then
        echo ""
        if [[ "$GITEA_SSH_MODE" == "system" ]]; then
            # 系统 SSH 模式说明
            echo -e "${CYAN}${BOLD}SSH 访问配置（系统 SSH 模式）:${NC}"
            echo "  Gitea 使用系统 SSH 服务（端口 ${GITEA_SSH_PORT}），通过 git 用户访问"
            echo ""
            echo "  1. 在 Gitea Web 界面添加 SSH 公钥："
            echo "     用户设置 -> SSH 密钥 -> 添加密钥"
            echo ""
            local keys_path
            if [[ "$(uname -s)" == "Darwin" ]]; then keys_path="/Users/$GITEA_USER/.ssh/authorized_keys"; else keys_path="~$GITEA_USER/.ssh/authorized_keys"; fi
            echo "  2. 公钥将自动同步到: $keys_path"
            echo ""
            echo "  3. 克隆仓库命令:"
            echo "     git clone $GITEA_USER@${local_ip}:用户名/仓库名.git"
            echo "     或"
            echo "     git clone ssh://$GITEA_USER@${local_ip}:${GITEA_SSH_PORT}/用户名/仓库名.git"
            echo ""
            echo "  4. 首次连接测试:"
            echo "     ssh -T $GITEA_USER@${local_ip}"
            echo ""
            echo -e "${YELLOW}注意: 如果 SSH 连接失败，请检查:${NC}"
            echo "  - 系统偏好设置 -> 共享 -> 远程登录（已启用）"
            echo "  - Gitea 中已添加 SSH 公钥"
            echo "  - 用户 $GITEA_USER 已创建: id $GITEA_USER"
        else
            # 内置 SSH 服务器模式说明
            echo -e "${CYAN}${BOLD}SSH 访问配置（内置 SSH 服务器模式）:${NC}"
            echo "  Gitea 使用内置 SSH 服务器（端口 ${GITEA_SSH_PORT}）"
            echo ""
            echo "  1. 在 Gitea Web 界面添加 SSH 公钥："
            echo "     用户设置 -> SSH 密钥 -> 添加密钥"
            echo ""
            echo "  2. 克隆仓库命令:"
            echo "     git clone ssh://$GITEA_USER@${local_ip}:${GITEA_SSH_PORT}/用户名/仓库名.git"
            echo ""
            echo "  3. 首次连接测试:"
            echo "     ssh -T $GITEA_USER@${local_ip} -p ${GITEA_SSH_PORT}"
            echo ""
            echo -e "${YELLOW}注意: 如果 SSH 连接失败，请检查:${NC}"
            echo "  - 端口 ${GITEA_SSH_PORT} 未被防火墙阻止"
            echo "  - Gitea 内置 SSH 服务器已启动"
            echo "  - Gitea 中已添加 SSH 公钥"
        fi
    fi

    echo ""
    echo -e "${BOLD}更多信息:${NC}"
    echo "  https://docs.gitea.com/"
}

# === 卸载 ===
uninstall_gitea() {
    print_header "卸载 Gitea"

    local input
    read -rp "确认卸载 Gitea？所有数据将被删除 (y/N): " input
    if [[ ! "$input" =~ ^[Yy]$ ]]; then
        print_info "取消卸载"
        return 0
    fi

    # Docker 模式
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        print_info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null
        rm -rf "$INSTALL_DIR"
        print_success "Gitea (Docker) 已卸载"
        return 0
    fi

    # 主机模式
    if systemctl is-active gitea &>/dev/null; then
        print_info "停止服务..."
        systemctl stop gitea
        systemctl disable gitea
        rm -f /etc/systemd/system/gitea.service
        systemctl daemon-reload
    fi

    rm -rf /usr/local/bin/gitea /etc/gitea "$INSTALL_DIR"
    print_success "Gitea 已卸载"
}

# === 辅助工具函数 ===
sed_i() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# 健壮的 INI 值设置函数
set_ini_val() {
    local file=$1; local section=$2; local key=$3; local value=$4
    # 确保 [section] 存在
    grep -q "^\[$section\]" "$file" || echo -e "\n[$section]" | sudo tee -a "$file" > /dev/null
    
    # 构造跨平台脚本
    local script="sed_i() { if [[ \"\$(uname -s)\" == \"Darwin\" ]]; then sed -i '' \"\$@\"; else sed -i \"\$@\"; fi; }; "
    if grep -q "^$key" "$file"; then
        script="${script} sed_i 's|^$key.*|$key = $value|' '$file'"
    else
        script="${script} sed_i '/\[$section\]/a $key = $value' '$file'"
    fi
    sudo bash -c "$script"
}

# 统一服务重启函数
restart_gitea_service() {
    local mode=$1; local ini=$2
    print_info "正在重启服务 ($mode) 以应用更改..."
    case "$mode" in
        docker) cd "$(dirname "$(dirname "$ini")")" && docker compose restart ;;
        launchd) restart_macos_launchdaemon ;;
        brew)   brew services restart gitea ;;
        *)      systemctl restart gitea ;;
    esac
}

# === 检测服务是否运行 ===
is_running() {
    local ini
    ini=$(find_active_app_ini)
    [[ -z "$ini" ]] && return 1

    if [[ "$ini" == *"/config/app.ini" ]]; then
        local compose_dir
        compose_dir="$(dirname "$(dirname "$ini")")"
        if command -v docker &>/dev/null && cd "$compose_dir" 2>/dev/null; then
            if docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "gitea"; then
                return 0
            fi
            if docker-compose ps --services --filter "status=running" 2>/dev/null | grep -q "gitea"; then
                return 0
            fi
        fi
    elif [[ "$(uname -s)" == "Darwin" ]] && launchctl print "system/${MACOS_GITEA_LABEL}" >/dev/null 2>&1; then
        return 0
    elif command -v systemctl &>/dev/null && systemctl list-unit-files gitea.service &>/dev/null; then
        if systemctl is-active gitea &>/dev/null; then
            return 0
        fi
    elif command -v brew &>/dev/null; then
        if brew services list 2>/dev/null | grep -q "^gitea.*started"; then
            return 0
        elif pgrep -f "gitea web" &>/dev/null; then
            return 0
        fi
    else
        if pgrep -f "gitea web" &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# === 启动服务 ===
start_gitea() {
    local ini
    ini=$(find_active_app_ini)
    [[ -z "$ini" ]] && { print_error "未找到 Gitea 配置文件，无法启动。"; return 1; }

    print_info "正在启动 Gitea..."
    if [[ "$ini" == *"/config/app.ini" ]]; then
        local compose_dir="$(dirname "$(dirname "$ini")")"
        if cd "$compose_dir"; then
            docker compose up -d 2>/dev/null || docker-compose up -d
        fi
    elif [[ "$(uname -s)" == "Darwin" ]] && [[ -f "$MACOS_GITEA_DAEMON_PLIST" ]]; then
        start_macos_launchdaemon
    elif command -v systemctl &>/dev/null && systemctl list-unit-files gitea.service &>/dev/null; then
        systemctl start gitea
    elif command -v brew &>/dev/null; then
        brew services start gitea
    else
        launchctl start io.gitea.server 2>/dev/null || true
    fi
    print_success "Gitea 启动命令已发出"
}

# === 停止服务 ===
stop_gitea() {
    local ini
    ini=$(find_active_app_ini)
    [[ -z "$ini" ]] && { print_error "未找到 Gitea 配置文件，无法停止。"; return 1; }

    print_info "正在停止 Gitea..."
    if [[ "$ini" == *"/config/app.ini" ]]; then
        local compose_dir="$(dirname "$(dirname "$ini")")"
        if cd "$compose_dir"; then
            docker compose stop 2>/dev/null || docker-compose stop
        fi
    elif [[ "$(uname -s)" == "Darwin" ]] && launchctl print "system/${MACOS_GITEA_LABEL}" >/dev/null 2>&1; then
        stop_macos_launchdaemon
    elif command -v systemctl &>/dev/null && systemctl list-unit-files gitea.service &>/dev/null; then
        systemctl stop gitea
    elif command -v brew &>/dev/null; then
        brew services stop gitea
    else
        launchctl stop io.gitea.server 2>/dev/null || true
    fi
    print_success "Gitea 已停止"
}

# === 查看状态 ===
show_status() {
    print_header "Gitea 状态"
    local ini=$(find_active_app_ini)
    if [[ -n "$ini" ]]; then
        if [[ "$ini" == *"/config/app.ini" ]]; then
            echo "安装模式: Docker Compose"
            cd "$(dirname "$(dirname "$ini")")" && docker compose ps 2>/dev/null
        elif [[ "$(uname -s)" == "Darwin" ]] && launchctl print "system/${MACOS_GITEA_LABEL}" >/dev/null 2>&1; then
            echo "安装模式: macOS LaunchDaemon"
            launchctl print "system/${MACOS_GITEA_LABEL}" 2>/dev/null | sed -n '1,80p'
        elif command -v systemctl &>/dev/null && systemctl list-unit-files gitea.service &>/dev/null; then
            echo "安装模式: Linux Systemd"
            systemctl status gitea --no-pager 2>/dev/null
        else
            echo "安装模式: macOS Homebrew"
            brew services info gitea 2>/dev/null
        fi
    else
        echo "Gitea 未安装"
    fi
}

# === 修复/优化现有配置 ===
repair_config() {
    print_header "修复/优化现有配置"
    
    local app_ini=$(find_active_app_ini)
    [[ -z "$app_ini" ]] && { print_error "未找到现有的 Gitea 配置文件。"; return 1; }

    # 识别模式 (仅用于重启)
    local mode="systemd"
    [[ "$app_ini" == *"/config/app.ini" ]] && mode="docker"
    [[ "$app_ini" == *"$DEFAULT_BREW_VAR"* ]] && mode="brew"
    if [[ "$(uname -s)" == "Darwin" ]] && [[ "$app_ini" == *"$DEFAULT_BREW_VAR"* ]]; then
        mode="launchd"
    fi

    print_info "发现配置文件: $app_ini (自动识别模式: $mode)"
    
    # 1. 准备系统用户
    setup_system_user

    # 2. 更新配置文件
    print_info "正在应用最佳实践配置..."
    set_ini_val "$app_ini" "server" "RUN_USER" "$GITEA_USER"
    set_ini_val "$app_ini" "server" "SSH_PORT" "$RECOMMENDED_SSH_PORT"
    set_ini_val "$app_ini" "server" "START_SSH_SERVER" "true"
    set_ini_val "$app_ini" "server" "SSH_CREATE_AUTHORIZED_KEYS_FILE" "false"

    # 3. 修复权限
    print_info "正在修复目录权限..."
    local d root=$(find_active_gitea_root)
    local data_dirs=("$root" "$DEFAULT_BREW_VAR" "$DEFAULT_LINUX_ETC" "/var/lib/gitea")
    for d in "${data_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sudo chown -R "$GITEA_USER:staff" "$d" 2>/dev/null || true
            else
                sudo chown -R "$GITEA_USER:$GITEA_USER" "$d" 2>/dev/null || true
            fi
        fi
    done

    if [[ "$(uname -s)" == "Darwin" ]] && [[ "$mode" == "launchd" ]]; then
        cleanup_macos_user_launchagent
        install_macos_launchdaemon "/opt/homebrew/opt/gitea/bin/gitea" "$DEFAULT_BREW_VAR"
    fi

    # 4. 重启服务
    restart_gitea_service "$mode" "$app_ini"
    print_success "配置修复与优化完成！"
}

# === 主函数 ===
main() {
    echo -e "${CYAN}${BOLD}>>> Gitea 安装脚本${NC}"

    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        --uninstall)
            uninstall_gitea
            exit 0
            ;;
        --install-service)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                install_macos_user_launchagent
            else
                install_systemd_service
            fi
            exit $?
            ;;
        --uninstall-service)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                launchctl bootout "gui/$(id -u)/${MACOS_GITEA_LABEL}" >/dev/null 2>&1 || true
                launchctl unload "$MACOS_GITEA_USER_AGENT" >/dev/null 2>&1 || true
                rm -f "$MACOS_GITEA_USER_AGENT"
                print_success "macOS LaunchAgent 已卸载: ${MACOS_GITEA_LABEL}"
            elif command -v systemctl >/dev/null 2>&1; then
                systemctl disable --now gitea.service >/dev/null 2>&1 || true
            fi
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --start)
            start_gitea
            exit 0
            ;;
        --stop)
            stop_gitea
            exit 0
            ;;
        --repair)
            repair_config
            exit 0
            ;;
    esac

    # 检测是否已安装
    local active_ini
    active_ini=$(find_active_app_ini || echo "")
    if [[ -n "$active_ini" ]]; then
        print_info "检测到 Gitea 已安装。配置文件: $active_ini"
        
        # 启动检测
        if is_running; then
            print_success "检测到 Gitea 服务正在运行中。"
        else
            print_info "检测到 Gitea 服务未运行，正在尝试启动..."
            start_gitea
        fi
        if ! check_config_health "$active_ini"; then
            echo ""
            print_warn "当前配置不符合推荐的最佳实践 (建议使用 git 用户及 2222 端口)。"
            if [[ -t 0 ]]; then
                read -rp "是否立即修复并优化现有配置？ (y/N): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    repair_config
                    exit 0
                fi
            else
                print_info "非交互模式，跳过修复。"
                exit 0
            fi
        else
            print_success "当前配置已是最佳实践。"
            if [[ -t 0 ]]; then
                read -rp "是否仍要继续全新的安装流程？ (y/N): " choice
                [[ "$choice" =~ ^[Yy]$ ]] || exit 0
            else
                print_info "非交互模式，自动跳过全新安装流程。"
                exit 0
            fi
        fi
    fi

    # 交互式配置
    interactive_config

    # 检查前置条件
    check_prerequisites

    # 显示配置
    show_config

    # 安装
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        install_docker
    else
        install_host
    fi

    # 显示完成信息
    show_post_install_info
}

main "$@"

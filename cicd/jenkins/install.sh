#!/usr/bin/env bash
###############################################################################
# Jenkins 安装脚本
# 支持 Docker 模式和主机模式，支持 macOS 和 Linux
# 功能：安装、卸载、升级、状态检查、重启、用户管理
###############################################################################

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

confirm_action() {
    local msg="$1"
    read -r -p "  ${msg} [y/N]: " _ans
    [[ "${_ans}" =~ ^[Yy]$ ]]
}

# === 常量 ===
JENKINS_VERSION="${JENKINS_VERSION:-2.555.3}"
DEFAULT_INSTALL_DIR="$HOME/jenkins"
DEFAULT_DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
DEFAULT_HTTP_PORT=8080
DEFAULT_AGENT_PORT=50000
DEFAULT_HTTP_LISTEN_ADDRESS="${JENKINS_LISTEN_ADDRESS:-0.0.0.0}"
DEFAULT_JENKINS_USER="${JENKINS_USER:-jenkins}"
MIN_JAVA_VERSION=17

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
HTTP_PORT="$DEFAULT_HTTP_PORT"
AGENT_PORT="$DEFAULT_AGENT_PORT"
HTTP_LISTEN_ADDRESS="$DEFAULT_HTTP_LISTEN_ADDRESS"
INSTALL_MODE="auto"   # auto|docker|host
JENKINS_USER="$DEFAULT_JENKINS_USER"
UNINSTALL_MODE=false
BACKUP_MODE=false
DRY_RUN=false
AUTO_START=false
AUTO_INSTALL=false
STATUS_MODE=false
RESTART_MODE=false
UPGRADE_MODE=false
FIX_PERMISSIONS=false
CREATE_USER=false
LAST_BACKUP_DIR=""

# === 帮助 ===
show_usage() {
    cat <<EOF
Jenkins 安装脚本

用法: $0 [选项]

安装选项:
    -h, --help                  显示此帮助
    -d, --dir DIR               安装目录 (默认: ~/jenkins)
    -w, --download-dir DIR      下载目录 (默认: ~/Downloads)
    -p, --port PORT             HTTP 端口 (默认: 8080)
    -b, --bind ADDRESS          HTTP 监听地址 (默认: $HTTP_LISTEN_ADDRESS)
    -a, --agent-port PORT      Agent 端口 (默认: 50000)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    -u, --user USER             Jenkins 运行用户 (默认: $JENKINS_USER)
    --create-user               创建 Jenkins 用户（如果不存在）
    --fix-permissions           修复安装目录权限
    --auto-start                安装完成后自动启动
    --auto                      非交互模式（自动解决端口冲突）
    --dry-run                   试运行

管理命令:
    --status                    显示 Jenkins 状态
    --restart                   重启 Jenkins
    --upgrade                   升级 Jenkins 到新版本
    --jenkins-version VERSION   指定安装/升级版本 (默认: $JENKINS_VERSION)
    --uninstall                 卸载 Jenkins
    --backup                    卸载前备份

环境变量:
    JENKINS_VERSION            Jenkins 版本 (默认: $JENKINS_VERSION)
    DOWNLOAD_DIR               下载目录
    JENKINS_LISTEN_ADDRESS     HTTP 监听地址 (默认: $HTTP_LISTEN_ADDRESS)
    JENKINS_USER               Jenkins 运行用户 (默认: $JENKINS_USER)

示例:
    $0                          # 自动模式安装
    $0 --mode docker            # 强制 Docker 模式
    $0 --port 8090             # 指定 HTTP 端口
    $0 --user myjenkins        # 使用指定用户运行
    $0 --create-user           # 创建 jenkins 用户
    $0 --fix-permissions       # 修复权限
    $0 --status                # 查看状态
    $0 --restart               # 重启
    $0 --upgrade               # 升级
    $0 --upgrade --jenkins-version 2.555.3 --port 8081
    $0 --uninstall --backup    # 卸载并备份
EOF
}

# === 参数解析 ===
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_usage; exit 0 ;;
            -d|--dir)
                INSTALL_DIR="${2/#\~/$HOME}"
                shift 2 ;;
            -w|--download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2 ;;
            -p|--port)
                HTTP_PORT="$2"
                shift 2 ;;
            -b|--bind)
                HTTP_LISTEN_ADDRESS="$2"
                shift 2 ;;
            -a|--agent-port)
                AGENT_PORT="$2"
                shift 2 ;;
            -m|--mode)
                INSTALL_MODE="$2"
                shift 2 ;;
            -u|--user)
                JENKINS_USER="$2"
                shift 2 ;;
            --create-user) CREATE_USER=true; shift ;;
            --fix-permissions) FIX_PERMISSIONS=true; shift ;;
            --auto-start) AUTO_START=true; shift ;;
            --auto) AUTO_INSTALL=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --status) STATUS_MODE=true; shift ;;
            --restart) RESTART_MODE=true; shift ;;
            --upgrade) UPGRADE_MODE=true; shift ;;
            --jenkins-version)
                [[ -n "${2:-}" ]] || { error "--jenkins-version 需要版本号"; exit 1; }
                JENKINS_VERSION="$2"
                shift 2 ;;
            --jenkins-version=*) JENKINS_VERSION="${1#*=}"; shift ;;
            --uninstall) UNINSTALL_MODE=true; shift ;;
            --backup) BACKUP_MODE=true; shift ;;
            *) error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done
}

# === Docker 检测 ===
docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

# === Java 检测 ===
get_java_version() {
    local java_cmd="${1:-java}"
    if ! command -v "$java_cmd" &>/dev/null; then
        echo "0"
        return 1
    fi
    
    local version_output
    version_output=$("$java_cmd" -version 2>&1 | head -1)
    
    # 解析版本号 (支持 "1.8.0_xxx" 和 "11.0.x" 和 "17.0.x" 格式)
    if echo "$version_output" | grep -q '"1\.[0-9]\.'; then
        # 旧格式: 1.8.0_xxx
        echo "$version_output" | sed -E 's/.*"1\.([0-9]+)\..*/\1/'
    else
        # 新格式: 11.0.x, 17.0.x
        echo "$version_output" | sed -E 's/.*"([0-9]+)\..*/\1/'
    fi
}

check_java_version() {
    local java_cmd="${1:-java}"
    local version
    version=$(get_java_version "$java_cmd")
    
    if [[ "$version" -lt "$MIN_JAVA_VERSION" ]]; then
        error "Java 版本过低: $version (需要 $MIN_JAVA_VERSION+)"
        return 1
    fi
    
    ok "Java 版本: $version"
    return 0
}

find_java_cmd() {
    local candidates=(
        "/opt/homebrew/opt/openjdk@21/bin/java"
        "/usr/local/opt/openjdk@21/bin/java"
        "/opt/homebrew/opt/openjdk@17/bin/java"
        "/usr/local/opt/openjdk@17/bin/java"
        "/opt/homebrew/bin/java"
        "/usr/local/bin/java"
        "java"
    )
    
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]] || command -v "$candidate" &>/dev/null; then
            if check_java_version "$candidate" &>/dev/null; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    
    return 1
}

# === 用户管理 ===
user_exists() {
    local user="$1"
    id "$user" &>/dev/null
}

group_exists() {
    local group="$1"
    getent group "$group" &>/dev/null
}

create_jenkins_user() {
    local user="$1"
    local group="$user"
    
    if user_exists "$user"; then
        info "用户 $user 已存在"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将创建用户: $user"
        return 0
    fi
    
    info "创建 Jenkins 用户: $user"
    
    # 创建组（如果不存在）
    if ! group_exists "$group"; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            # macOS
            sudo dscl . -create "/Groups/$group"
            sudo dscl . -create "/Groups/$group" PrimaryGroupID 0
        else
            # Linux
            sudo groupadd "$group"
        fi
    fi
    
    # 创建用户
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS
        local max_uid
        max_uid=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
        local new_uid=$((max_uid + 1))
        
        sudo dscl . -create "/Users/$user"
        sudo dscl . -create "/Users/$user" UniqueID "$new_uid"
        sudo dscl . -create "/Users/$user" PrimaryGroupID "$(dscl . -read "/Groups/$group" PrimaryGroupID | awk '{print $2}')"
        sudo dscl . -create "/Users/$user" UserShell /bin/bash
        sudo dscl . -create "/Users/$user" RealName "Jenkins CI"
        sudo dscl . -create "/Users/$user" NFSHomeDirectory "/Users/$user"
        
        # 创建 home 目录
        sudo createhomedir -c -u "$user" 2>/dev/null || sudo mkdir -p "/Users/$user"
        sudo chown "$user:$group" "/Users/$user"
    else
        # Linux
        sudo useradd -r -m -s /bin/bash -g "$group" "$user"
    fi
    
    ok "用户 $user 创建完成"
}

fix_permissions() {
    local dir="$1"
    local user="$2"
    local group="$user"
    
    if [[ ! -d "$dir" ]]; then
        warn "目录不存在: $dir"
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将修复权限: $dir -> $user:$group"
        return 0
    fi
    
    info "修复权限: $dir -> $user:$group"
    
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sudo chown -R "$user:$group" "$dir"
    else
        sudo chown -R "$user:$group" "$dir"
    fi
    
    # 确保目录可执行
    sudo chmod -R u+rwX,g+rwX,o+rX "$dir"
    
    ok "权限修复完成"
}

# ============================================================
#                      端口占用检测
# ============================================================

# 检测端口是否被占用（兼容 Linux + macOS）
port_in_use() {
    local port="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: lsof 最可靠（当前用户的进程无需 sudo）
        lsof -iTCP:"$port" -sTCP:LISTEN -n -P &>/dev/null && return 0
        return 1
    else
        # Linux: 优先 ss（无需权限），fallback lsof → netstat
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
        elif command -v lsof &>/dev/null; then
            lsof -iTCP:"$port" -sTCP:LISTEN -n -P &>/dev/null && return 0
        elif command -v netstat &>/dev/null; then
            netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
        fi
        return 1
    fi
}

# 获取占用端口的进程信息  每行输出: PID|COMMAND_LINE
get_port_owners() {
    local port="$1" pids="" pid="" cmdline=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P -t 2>/dev/null | sort -u)
    else
        if command -v ss &>/dev/null; then
            pids=$(ss -tlnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p {while (match($0,/pid=([0-9]+)/)) {print substr($0,RSTART+4,RLENGTH-4); $0=substr($0,RSTART+RLENGTH)}}' | sort -u)
        fi
        if [[ -z "$pids" ]] && command -v lsof &>/dev/null; then
            pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P -t 2>/dev/null | sort -u)
        fi
    fi

    [[ -z "$pids" ]] && return 0
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if [[ "$(uname -s)" == "Darwin" ]]; then
            cmdline=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
        elif [[ -r "/proc/$pid/cmdline" ]]; then
            cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        else
            cmdline=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
        fi
        echo "${pid}|${cmdline}"
    done <<< "$pids"
}

# 获取占用端口的第一个进程信息（兼容旧调用）
get_port_owner() {
    get_port_owners "$1" | head -1
}

port_has_jenkins_docker_binding() {
    local port="$1"
    docker_available || return 1
    docker inspect jenkins --format='{{range $p,$c := .NetworkSettings.Ports}}{{$p}} {{end}}' 2>/dev/null | grep -q "$port"
}

owner_is_jenkins() {
    local port="$1" cmdline="$2"

    # 主机模式: 进程命令行包含 jenkins
    if echo "$cmdline" | grep -qi "jenkins"; then
        return 0
    fi

    # Docker 模式: Docker 代理进程占用，且 jenkins 容器绑定了该端口
    if echo "$cmdline" | grep -Eqi "docker|com\.docker" && port_has_jenkins_docker_binding "$port"; then
        return 0
    fi

    return 1
}

port_only_has_jenkins_owners() {
    local port="$1" owners="$2" line pid cmdline
    [[ -z "$owners" ]] && return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="${line%%|*}"
        cmdline="${line#*|}"
        if ! owner_is_jenkins "$port" "$cmdline"; then
            return 1
        fi
    done <<< "$owners"

    return 0
}

print_port_owners() {
    local owners="$1" line pid cmdline short_cmd
    if [[ -z "$owners" ]]; then
        warn "  无法获取进程详情"
        return
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="${line%%|*}"
        cmdline="${line#*|}"
        short_cmd=$(echo "$cmdline" | cut -c1-100)
        warn "  PID: ${pid}  进程: ${short_cmd}"
    done <<< "$owners"
}

get_pid_port_endpoints() {
    local pid="$1" port="$2"
    if command -v lsof &>/dev/null; then
        lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u
    elif command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | awk -v pid="$pid" -v p=":${port}" '$0 ~ "pid=" pid && $4 ~ p "$" {print $4}' | sort -u
    fi
}

print_port_owners_with_endpoints() {
    local port="$1" owners="$2" line pid cmdline short_cmd endpoints endpoint label
    if [[ -z "$owners" ]]; then
        warn "  无法获取进程详情"
        return
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid="${line%%|*}"
        cmdline="${line#*|}"
        short_cmd=$(echo "$cmdline" | cut -c1-100)
        endpoints=$(get_pid_port_endpoints "$pid" "$port")

        if [[ -z "$endpoints" ]]; then
            warn "  PID: ${pid}  监听: :${port}  进程: ${short_cmd}"
            continue
        fi

        while IFS= read -r endpoint; do
            [[ -z "$endpoint" ]] && continue
            label=$(endpoint_scope "$endpoint")
            warn "  PID: ${pid}  监听: ${endpoint} (${label})  进程: ${short_cmd}"
        done <<< "$endpoints"
    done <<< "$owners"
}

endpoint_to_url() {
    local endpoint="$1" host port
    host="${endpoint%:*}"
    port="${endpoint##*:}"

    case "$host" in
        "*"|"0.0.0.0"|"::"|"[::]")
            host="127.0.0.1"
            ;;
    esac

    echo "http://${host}:${port}"
}

listen_url() {
    local bind="$1" port="$2" host
    host="$bind"
    case "$host" in
        "*"|"0.0.0.0"|"::"|"[::]")
            host="127.0.0.1"
            ;;
    esac
    echo "http://${host}:${port}"
}

endpoint_scope() {
    local endpoint="$1" host
    host="${endpoint%:*}"

    case "$host" in
        "127.0.0.1"|"::1"|"[::1]"|"localhost")
            echo "仅本机访问"
            ;;
        "*"|"0.0.0.0"|"::"|"[::]")
            echo "本机和局域网可访问"
            ;;
        *)
            echo "绑定到 ${host}"
            ;;
    esac
}

get_process_cmdline() {
    local pid="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ps -p "$pid" -o command= 2>/dev/null || echo ""
    elif [[ -r "/proc/$pid/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo ""
    else
        ps -p "$pid" -o command= 2>/dev/null || echo ""
    fi
}

find_existing_jenkins_war() {
    local pids pid cmdline token candidate
    pids=$(pgrep -f "jenkins.war" 2>/dev/null | sort -u || true)
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        cmdline=$(get_process_cmdline "$pid")
        for token in $cmdline; do
            if [[ "$token" == *jenkins.war && -f "$token" ]]; then
                echo "$token"
                return 0
            fi
        done
    done <<< "$pids"

    for candidate in \
        "$INSTALL_DIR/jenkins.war" \
        "/opt/homebrew/opt/jenkins-lts/libexec/jenkins.war" \
        "/usr/local/opt/jenkins-lts/libexec/jenkins.war" \
        "/opt/homebrew/opt/jenkins/libexec/jenkins.war" \
        "/usr/local/opt/jenkins/libexec/jenkins.war"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
}

find_existing_java_cmd() {
    local pids pid cmdline java_cmd candidate
    pids=$(pgrep -f "jenkins.war" 2>/dev/null | sort -u || true)
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        cmdline=$(get_process_cmdline "$pid")
        java_cmd="${cmdline%% *}"
        if [[ -x "$java_cmd" ]]; then
            echo "$java_cmd"
            return 0
        fi
    done <<< "$pids"

    # 查找符合版本要求的 Java
    if java_cmd=$(find_java_cmd); then
        echo "$java_cmd"
        return 0
    fi

    echo "java"
}

stop_homebrew_jenkins_launch_agent() {
    [[ "$(uname -s)" == "Darwin" ]] || return 0

    local uid launch_dir plist
    uid="$(id -u)"
    launch_dir="$HOME/Library/LaunchAgents"
    for plist in \
        "$launch_dir/homebrew.mxcl.jenkins-lts.plist" \
        "$launch_dir/homebrew.mxcl.jenkins.plist"; do
        if [[ -f "$plist" ]]; then
            launchctl bootout "gui/${uid}" "$plist" 2>/dev/null || true
        fi
    done

    launchctl remove homebrew.mxcl.jenkins-lts 2>/dev/null || true
    launchctl remove homebrew.mxcl.jenkins 2>/dev/null || true
}

# 输出正在运行的 Jenkins 监听地址。每行: PID|ENDPOINT|COMMAND_LINE
get_running_jenkins_listeners() {
    local pids pid cmdline endpoints endpoint
    pids=$(pgrep -f "jenkins.war" 2>/dev/null | sort -u || true)
    [[ -z "$pids" ]] && return 0

    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        cmdline=$(get_process_cmdline "$pid")
        echo "$cmdline" | grep -qi "jenkins\.war" || continue

        endpoints=""
        if command -v lsof &>/dev/null; then
            endpoints=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u)
        elif command -v ss &>/dev/null; then
            endpoints=$(ss -tlnp 2>/dev/null | awk -v pid="$pid" '$0 ~ "pid=" pid {print $4}' | sort -u)
        fi

        while IFS= read -r endpoint; do
            [[ -z "$endpoint" ]] && continue
            echo "${pid}|${endpoint}|${cmdline}"
        done <<< "$endpoints"
    done <<< "$pids"
}

print_jenkins_status() {
    local listeners line pid endpoint cmdline short_cmd url scope found=false
    listeners=$(get_running_jenkins_listeners)

    if [[ -z "$listeners" ]]; then
        info "Jenkins 当前未运行"
        return 1
    fi

    info "检测到 Jenkins 已运行:"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        found=true
        IFS='|' read -r pid endpoint cmdline <<< "$line"
        short_cmd=$(echo "$cmdline" | cut -c1-100)
        url=$(endpoint_to_url "$endpoint")
        scope=$(endpoint_scope "$endpoint")
        info "  PID: ${pid}  监听: ${endpoint}  访问: ${url} (${scope})"
        info "  进程: ${short_cmd}"
    done <<< "$listeners"

    [[ "$found" == true ]]
}

jenkins_has_port_listener() {
    local port="$1" listeners line endpoint _pid _cmdline
    listeners=$(get_running_jenkins_listeners)
    [[ -z "$listeners" ]] && return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r _pid endpoint _cmdline <<< "$line"
        if [[ "${endpoint##*:}" == "$port" ]]; then
            return 0
        fi
    done <<< "$listeners"

    return 1
}

jenkins_is_running() {
    [[ -n "$(get_running_jenkins_listeners)" ]]
}

get_jenkins_pids_on_port() {
    local port="$1" listeners line pid endpoint _cmdline
    listeners=$(get_running_jenkins_listeners)
    [[ -z "$listeners" ]] && return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r pid endpoint _cmdline <<< "$line"
        if [[ "${endpoint##*:}" == "$port" ]]; then
            echo "$pid"
        fi
    done <<< "$listeners" | sort -u
}

stop_jenkins_pids() {
    local pids="$1" pid
    [[ -z "$pids" ]] && return 0

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将停止 Jenkins PID: $(echo "$pids" | tr '\n' ' ')"
        return 0
    fi

    stop_homebrew_jenkins_launch_agent

    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        info "停止 Jenkins PID ${pid}"
        kill "$pid" 2>/dev/null || true
    done <<< "$pids"

    sleep 2

    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            warn "Jenkins PID ${pid} 未响应 SIGTERM，发送 SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    done <<< "$pids"
}

stop_jenkins_on_port() {
    local port="$1" pids
    pids=$(get_jenkins_pids_on_port "$port")
    if [[ -z "$pids" ]]; then
        warn "未找到监听 ${port} 的 Jenkins 进程"
        return 0
    fi

    stop_jenkins_pids "$pids"
}

# 判断占用端口的进程是否为 Jenkins
is_jenkins_process() {
    local port="$1"
    local owner_info
    owner_info=$(get_port_owner "$port")
    [[ -z "$owner_info" ]] && return 1

    local cmdline="${owner_info#*|}"

    owner_is_jenkins "$port" "$cmdline"
}

# 查找指定端口之后的第一个空闲端口
find_free_port() {
    local port="$1"
    local try="$port"
    for ((i=0; i<20; i++)); do
        try=$((port + i))
        if ! port_in_use "$try"; then
            echo "$try"
            return 0
        fi
    done
    return 1
}

assign_alternate_port() {
    local port="$1" alt
    alt=$(find_free_port "$((port + 1))")
    if [[ -z "$alt" ]]; then
        error "无法找到空闲端口"
        return 1
    fi

    info "将使用端口 ${alt}"
    if [[ "$port" == "$HTTP_PORT" ]]; then
        HTTP_PORT="$alt"
    elif [[ "$port" == "$AGENT_PORT" ]]; then
        AGENT_PORT="$alt"
    fi
    return 0
}

stop_jenkins_and_assign_alternate_port() {
    local port="$1"
    assign_alternate_port "$port" || return 1
    stop_jenkins_on_port "$port"
    AUTO_START=true
    return 0
}

# ----------------------------------------------------------
# 处理端口冲突  参数: 端口号  用途描述
# 返回值: 0=继续  1=应跳过安装
# 副作用: 可能修改全局 HTTP_PORT / AGENT_PORT
# ----------------------------------------------------------
handle_port_conflict() {
    local port="$1"
    local desc="${2:-端口}"

    if ! port_in_use "$port"; then
        return 0
    fi

    # --- 端口被占用 ---
    local owner_infos
    owner_infos=$(get_port_owners "$port")
    local first_owner="${owner_infos%%$'\n'*}"
    local pid="${first_owner%%|*}"
    local cmdline="${first_owner#*|}"

    if port_only_has_jenkins_owners "$port" "$owner_infos"; then
        # ======= 策略 A: Jenkins 自身占用 =======
        warn "${desc} ${port} 已被 Jenkins 占用"
        print_port_owners "$owner_infos"
        echo ""
        if [[ ! -t 0 ]] || [[ "$AUTO_INSTALL" == true ]]; then
            info "非交互或自动模式，跳过安装（Jenkins 已在运行）"
            return 1
        fi
        echo "  1) 停止旧 Jenkins，改用其他端口安装并启动"
        echo "  2) 跳过安装（保持现有 Jenkins 运行）"
        echo "  3) 取消安装"
        echo ""
        read -r -p "请选择 [1/2/3]: " opt
        case "$opt" in
            1)
                stop_jenkins_and_assign_alternate_port "$port"
                return $?
                ;;
            2)
                info "跳过安装（Jenkins 已在端口 ${port} 运行）"
                print_jenkins_status || true
                return 1
                ;;
            *)
                info "取消安装"
                return 1
                ;;
        esac
    else
        # ======= 策略 B: 非 Jenkins 进程占用 =======
        warn "${desc} ${port} 被其他服务占用，或同端口存在不同监听地址:"
        print_port_owners_with_endpoints "$port" "$owner_infos"
        if jenkins_has_port_listener "$port"; then
            warn "检测到 Jenkins 也在监听 ${port}，但不是对外监听；建议停止旧 Jenkins 后改用其他端口安装并启动。"
            if [[ ! -t 0 ]] || [[ "$AUTO_INSTALL" == true ]]; then
                info "非交互或自动模式：停止旧 Jenkins 并自动分配其他空闲端口"
                stop_jenkins_and_assign_alternate_port "$port"
                return $?
            fi
            echo ""
            echo "  1) 停止旧 Jenkins，改用其他端口安装并启动"
            echo "  2) 跳过安装（保持现有 Jenkins 运行）"
            echo "  3) 取消安装"
            echo ""
            read -r -p "请选择 [1/2/3]: " opt
            case "$opt" in
                1)
                    stop_jenkins_and_assign_alternate_port "$port"
                    return $?
                    ;;
                2)
                    info "跳过安装（Jenkins 已在目标端口运行）"
                    print_jenkins_status || true
                    return 1
                    ;;
                *)
                    info "取消安装"
                    return 1
                    ;;
            esac
        fi

        if jenkins_is_running; then
            warn "检测到 Jenkins 已在其他端口运行，保持现有实例。"
            print_jenkins_status || true
            if [[ ! -t 0 ]] || [[ "$AUTO_INSTALL" == true ]]; then
                info "非交互或自动模式，跳过安装（Jenkins 已运行）"
                return 1
            fi
            echo ""
            echo "  1) 跳过安装（保持现有 Jenkins 运行）"
            echo "  2) 使用其他端口安装新实例"
            echo "  3) 取消安装"
            echo ""
            read -r -p "请选择 [1/2/3]: " opt
            case "$opt" in
                2)
                    assign_alternate_port "$port"
                    return $?
                    ;;
                1|*)
                    info "跳过安装（Jenkins 已运行）"
                    return 1
                    ;;
            esac
        fi

        echo ""
        if [[ ! -t 0 ]] || [[ "$AUTO_INSTALL" == true ]]; then
            info "非交互或自动模式：自动分配其他空闲端口"
            assign_alternate_port "$port"
            return $?
        fi
        echo "  1) 使用其他端口"
        echo "  2) 尝试停止占用进程（需谨慎）"
        echo "  3) 取消安装"
        echo ""
        read -r -p "请选择 [1/2/3]: " opt
        case "$opt" in
            1)
                assign_alternate_port "$port"
                return $?
                ;;
            2)
                if ! confirm_action "确认停止以上非 Jenkins 进程？"; then
                    info "取消停止，退出安装"
                    return 1
                fi
                while IFS= read -r owner_line; do
                    [[ -z "$owner_line" ]] && continue
                    pid="${owner_line%%|*}"
                    cmdline="${owner_line#*|}"
                    if ! owner_is_jenkins "$port" "$cmdline"; then
                        kill "$pid" 2>/dev/null || true
                    fi
                done <<< "$owner_infos"
                sleep 2
                while IFS= read -r owner_line; do
                    [[ -z "$owner_line" ]] && continue
                    pid="${owner_line%%|*}"
                    cmdline="${owner_line#*|}"
                    if ! owner_is_jenkins "$port" "$cmdline" && kill -0 "$pid" 2>/dev/null; then
                        warn "进程 PID ${pid} 未响应 SIGTERM，发送 SIGKILL..."
                        kill -9 "$pid" 2>/dev/null || true
                    fi
                done <<< "$owner_infos"
                sleep 1
                if port_in_use "$port"; then
                    warn "非 Jenkins 进程已处理，端口 ${port} 仍被占用，重新检查..."
                    handle_port_conflict "$port" "$desc"
                    return $?
                fi
                ok "进程已停止，端口 ${port} 已释放"
                return 0
                ;;
            *)
                info "取消安装"
                return 1
                ;;
        esac
    fi
}

# === 下载函数 ===
download_file() {
    local url="$1" output="$2"
    local output_dir="$(dirname "$output")"
    local output_file="$(basename "$output")"

    if [ -d "$output_dir" ] && [ ! -w "$output_dir" ]; then
        warn "下载目录无写入权限，尝试修复"
        if command -v sudo &>/dev/null; then
            sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
        fi
    fi
    mkdir -p "$output_dir"

    if [ -f "$output" ] && [ ! -w "$output" ]; then
        if command -v sudo &>/dev/null; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl &>/dev/null; then
        info "使用 adl 下载"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi
    if command -v curl &>/dev/null; then
        info "使用 curl 下载"
        curl -L -C - -o "$output" "$url"
        return $?
    fi
    if command -v wget &>/dev/null; then
        info "使用 wget 下载"
        wget -c -O "$output" "$url"
        return $?
    fi
    error "未找到可用下载工具"
    return 1
}

# === 健康检查 ===
health_check() {
    local url="$1"
    local max_wait="${2:-60}"
    local wait_interval=3
    local elapsed=0

    info "等待 Jenkins 启动..."
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -s -f "$url/login" &>/dev/null; then
            ok "Jenkins 已就绪"
            return 0
        fi
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
        info "等待中... (${elapsed}s/${max_wait}s)"
    done

    warn "Jenkins 启动超时，请检查日志"
    return 1
}

# === Docker 模式安装 ===
install_docker() {
    info "使用 Docker 模式安装 Jenkins"

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将创建 Docker Compose 配置到 $INSTALL_DIR"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"

    # 注意：移除了废弃的 version 字段
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  jenkins:
    image: jenkins/jenkins:${JENKINS_VERSION}-lts
    container_name: jenkins
    restart: unless-stopped
    ports:
      - "${HTTP_PORT}:8080"
      - "${AGENT_PORT}:50000"
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=false
    volumes:
      - jenkins-data:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - jenkins-network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  jenkins-data:

networks:
  jenkins-network:
    driver: bridge
EOF

    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$SCRIPT_DIR"

# 端口检测
if command -v lsof &>/dev/null; then
    _pids=\$(lsof -iTCP:${HTTP_PORT} -sTCP:LISTEN -n -P -t 2>/dev/null | sort -u)
    if [ -n "\$_pids" ]; then
        echo "[WARN] 端口 ${HTTP_PORT} 已被占用:"
        while IFS= read -r _pid; do
            [ -z "\$_pid" ] && continue
            _cmd=\$(ps -p "\$_pid" -o command= 2>/dev/null || echo "unknown")
            echo "  PID: \$_pid  进程: \$_cmd"
        done <<< "\$_pids"
        echo "  停止: \$SCRIPT_DIR/stop.sh"
        exit 1
    fi
elif command -v ss &>/dev/null; then
    _pids=\$(ss -tlnp 2>/dev/null | awk -v p=":${HTTP_PORT} " '\$0 ~ p {while (match(\$0,/pid=([0-9]+)/)) {print substr(\$0,RSTART+4,RLENGTH-4); \$0=substr(\$0,RSTART+RLENGTH)}}' | sort -u)
    if [ -n "\$_pids" ]; then
        echo "[WARN] 端口 ${HTTP_PORT} 已被占用:"
        while IFS= read -r _pid; do
            [ -z "\$_pid" ] && continue
            _cmd=\$(ps -p "\$_pid" -o command= 2>/dev/null || cat /proc/\$_pid/cmdline 2>/dev/null | tr '\\0' ' ' || echo "unknown")
            echo "  PID: \$_pid  进程: \$_cmd"
        done <<< "\$_pids"
        echo "  停止: \$SCRIPT_DIR/stop.sh"
        exit 1
    fi
fi

if docker compose version &>/dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi
echo "Jenkins 已启动"
echo "初始管理员密码:"
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "请查看容器日志"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    cat > "$INSTALL_DIR/stop.sh" <<'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if docker compose version &>/dev/null; then
    docker compose down
else
    docker-compose down
fi
echo "Jenkins 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    cat > "$INSTALL_DIR/logs.sh" <<'EOF'
#!/bin/bash
docker logs -f jenkins
EOF
    chmod +x "$INSTALL_DIR/logs.sh"

    ok "Jenkins Docker 配置创建完成"
    info "启动: $INSTALL_DIR/start.sh"
    info "访问: http://localhost:${HTTP_PORT}"
}

# === 主机模式安装 ===
install_host() {
    info "使用主机模式安装 Jenkins"

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将安装到 $INSTALL_DIR"
        return 0
    fi

    local war_name="jenkins.war"
    local war_path="$DOWNLOAD_DIR/$war_name"
    local java_cmd="java"

    # 检测或下载 jenkins.war
    local existing_war=""
    existing_war="$(find_existing_jenkins_war)"
    
    if [[ -n "$existing_war" ]]; then
        info "复用已安装 Jenkins WAR: $existing_war"
        mkdir -p "$INSTALL_DIR/home"
        cp "$existing_war" "$INSTALL_DIR/$war_name"
    elif [[ -f "$war_path" ]] && [[ -s "$war_path" ]]; then
        info "检测到已存在 jenkins.war: $war_path"
        mkdir -p "$INSTALL_DIR/home"
        cp "$war_path" "$INSTALL_DIR/"
    else
        # 自动下载
        local url="https://get.jenkins.io/war-stable/${JENKINS_VERSION}/${war_name}"
        info "下载 Jenkins WAR: $url"
        
        mkdir -p "$DOWNLOAD_DIR"
        if ! download_file "$url" "$war_path"; then
            error "下载失败"
            exit 1
        fi
        
        mkdir -p "$INSTALL_DIR/home"
        cp "$war_path" "$INSTALL_DIR/"
    fi

    # 检测 Java
    java_cmd="$(find_existing_java_cmd)"
    if ! check_java_version "$java_cmd"; then
        error "Java 版本不满足要求 (需要 $MIN_JAVA_VERSION+)"
        exit 1
    fi

    # 创建用户（如果需要）
    if [[ "$CREATE_USER" == true ]]; then
        create_jenkins_user "$JENKINS_USER"
    fi

    # 修复权限
    if [[ "$FIX_PERMISSIONS" == true ]] && user_exists "$JENKINS_USER"; then
        fix_permissions "$INSTALL_DIR" "$JENKINS_USER"
    fi

    # 生成启动脚本
    local run_as=""
    if user_exists "$JENKINS_USER"; then
        run_as="sudo -u $JENKINS_USER"
    fi

    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash
export JENKINS_HOME="${INSTALL_DIR}/home"
mkdir -p "\$JENKINS_HOME"
cd "${INSTALL_DIR}"

# 端口检测
_port=${HTTP_PORT}
_bind="${HTTP_LISTEN_ADDRESS}"
_pids=""
if command -v lsof &>/dev/null; then
    _pids=\$(lsof -iTCP:\$_port -sTCP:LISTEN -n -P -t 2>/dev/null | sort -u)
elif command -v ss &>/dev/null; then
    _pids=\$(ss -tlnp 2>/dev/null | awk -v p=":\${_port} " '\$0 ~ p {while (match(\$0,/pid=([0-9]+)/)) {print substr(\$0,RSTART+4,RLENGTH-4); \$0=substr(\$0,RSTART+RLENGTH)}}' | sort -u)
fi
if [ -n "\$_pids" ]; then
    _only_jenkins=true
    _owners=""
    while IFS= read -r _pid; do
        [ -z "\$_pid" ] && continue
        _cmd=\$(ps -p "\$_pid" -o command= 2>/dev/null || cat /proc/\$_pid/cmdline 2>/dev/null | tr '\\0' ' ' || echo "unknown")
        _owners="\${_owners}  PID: \$_pid  进程: \$_cmd
"
        if ! echo "\$_cmd" | grep -qi "jenkins"; then
            _only_jenkins=false
        fi
    done <<< "\$_pids"

    if [ "\$_only_jenkins" = true ]; then
        echo "[INFO] Jenkins 已在端口 \$_port 运行"
        printf "%s" "\$_owners"
        echo "  停止: ${INSTALL_DIR}/stop.sh"
        echo "  日志: ${INSTALL_DIR}/jenkins.log"
        exit 0
    else
        echo "[ERROR] 端口 \$_port 被非 Jenkins 进程占用或混合占用:"
        printf "%s" "\$_owners"
        echo "  请先释放端口或使用其他端口启动"
        exit 1
    fi
fi

# 日志轮转
_log_file="${INSTALL_DIR}/jenkins.log"
if [ -f "\$_log_file" ]; then
    _log_size=\$(stat -f%z "\$_log_file" 2>/dev/null || stat -c%s "\$_log_file" 2>/dev/null || echo 0)
    if [ "\$_log_size" -gt 10485760 ]; then  # 10MB
        mv "\$_log_file" "\$_log_file.\$(date +%Y%m%d%H%M%S)"
        # 只保留最近 3 个日志文件
        ls -t "\$_log_file".* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi
fi

${run_as} nohup "${java_cmd}" -jar jenkins.war --httpListenAddress="${HTTP_LISTEN_ADDRESS}" --httpPort=${HTTP_PORT} > "\$_log_file" 2>&1 &
echo "Jenkins 已启动，监听: ${HTTP_LISTEN_ADDRESS}:${HTTP_PORT}"
echo "日志: \$_log_file"
echo "初始管理员密码:"
sleep 5
cat "\$JENKINS_HOME/secrets/initialAdminPassword" 2>/dev/null || echo "等待生成中..."
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    cat > "$INSTALL_DIR/stop.sh" <<EOF
#!/bin/bash
pids="\$(pgrep -f "jenkins.war.*--httpPort=${HTTP_PORT}" || true)"
if [ -n "\$pids" ]; then
    kill \$pids 2>/dev/null || true
    sleep 2
    pids="\$(pgrep -f "jenkins.war.*--httpPort=${HTTP_PORT}" || true)"
    [ -n "\$pids" ] && kill -9 \$pids 2>/dev/null || true
fi
echo "Jenkins 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    cat > "$INSTALL_DIR/status.sh" <<EOF
#!/bin/bash
if pgrep -f "jenkins.war.*--httpPort=${HTTP_PORT}" > /dev/null 2>&1; then
    echo "Jenkins: 运行中"
    echo "监听: ${HTTP_LISTEN_ADDRESS}:${HTTP_PORT}"
    echo "访问: http://127.0.0.1:${HTTP_PORT}"
else
    echo "Jenkins: 未运行"
fi
EOF
    chmod +x "$INSTALL_DIR/status.sh"

    ok "Jenkins 主机模式安装完成"
}

# === 备份 ===
backup_jenkins() {
    local backup_dir="$INSTALL_DIR.backup.$(date +%Y%m%d%H%M%S)"
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        warn "安装目录不存在，无需备份"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将备份到: $backup_dir"
        return 0
    fi
    
    info "备份 Jenkins 数据到: $backup_dir"
    cp -r "$INSTALL_DIR" "$backup_dir"
    LAST_BACKUP_DIR="$backup_dir"
    ok "备份完成: $backup_dir"
}

# === 卸载 ===
uninstall_jenkins() {
    info "卸载 Jenkins..."

    if [[ "$BACKUP_MODE" == true ]]; then
        backup_jenkins
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将卸载 Jenkins"
        return 0
    fi

    # 停止 Homebrew 服务
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
        brew services stop jenkins-lts 2>/dev/null || true
        brew uninstall jenkins-lts 2>/dev/null || true
    fi

    # 停止主机进程
    local pids
    pids="$(pgrep -f "jenkins.war" || true)"
    if [ -n "$pids" ]; then
        info "停止 Jenkins 进程..."
        kill $pids 2>/dev/null || true
        sleep 2
        pids="$(pgrep -f "jenkins.war" || true)"
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi

    # 停止 Docker 容器
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        if docker compose version &>/dev/null; then
            docker compose down -v 2>/dev/null || true
        elif command -v docker-compose &>/dev/null; then
            docker-compose down -v 2>/dev/null || true
        fi
    fi

    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    ok "Jenkins 卸载完成"
}

# === 状态检查 ===
show_status() {
    info "Jenkins 状态检查"
    echo ""
    
    # 检查进程
    print_jenkins_status || true
    echo ""
    
    # 检查安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        ok "安装目录存在: $INSTALL_DIR"
        
        # 检查 war 文件
        if [[ -f "$INSTALL_DIR/jenkins.war" ]]; then
            ok "jenkins.war 存在"
        else
            warn "jenkins.war 不存在"
        fi
        
        # 检查 home 目录
        if [[ -d "$INSTALL_DIR/home" ]]; then
            ok "JENKINS_HOME 存在: $INSTALL_DIR/home"
        else
            warn "JENKINS_HOME 不存在"
        fi
    else
        warn "安装目录不存在: $INSTALL_DIR"
    fi
    echo ""
    
    # 检查用户
    if user_exists "$JENKINS_USER"; then
        ok "Jenkins 用户存在: $JENKINS_USER"
    else
        warn "Jenkins 用户不存在: $JENKINS_USER"
    fi
    echo ""
    
    # 检查 Docker 容器
    if docker_available && docker ps -a --format '{{.Names}}' | grep -q "^jenkins$"; then
        ok "Docker 容器存在: jenkins"
        if docker ps --format '{{.Names}}' | grep -q "^jenkins$"; then
            ok "Docker 容器运行中"
        else
            warn "Docker 容器未运行"
        fi
    fi
}

# === 重启 ===
restart_jenkins() {
    info "重启 Jenkins..."
    
    if [[ -f "$INSTALL_DIR/stop.sh" ]]; then
        bash "$INSTALL_DIR/stop.sh"
    else
        warn "未找到 stop.sh，尝试直接停止进程"
        local pids
        pids="$(pgrep -f "jenkins.war" || true)"
        if [ -n "$pids" ]; then
            kill $pids 2>/dev/null || true
            sleep 2
        fi
    fi
    
    sleep 2
    
    if [[ -f "$INSTALL_DIR/start.sh" ]]; then
        bash "$INSTALL_DIR/start.sh"
        
        # 健康检查
        local url
        url=$(listen_url "$HTTP_LISTEN_ADDRESS" "$HTTP_PORT")
        health_check "$url" 60
    else
        error "未找到 start.sh"
        exit 1
    fi
}

# === 升级 ===
upgrade_jenkins() {
    info "升级 Jenkins 到版本: $JENKINS_VERSION"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] 将升级 Jenkins"
        return 0
    fi
    
    local current_version=""
    if [[ -f "$INSTALL_DIR/jenkins.war" ]]; then
        # 不在 awk 中提前 exit，避免 set -o pipefail 将 unzip 的 SIGPIPE(141)
        # 误判为 WAR 读取失败。
        current_version=$(unzip -p "$INSTALL_DIR/jenkins.war" META-INF/MANIFEST.MF 2>/dev/null \
            | awk -F': ' '/^Jenkins-Version:/{gsub(/\r/,"",$2); version=$2} END{print version}')
    fi
    if [[ -n "$current_version" ]] && [[ "$(printf '%s\n%s\n' "$current_version" "$JENKINS_VERSION" | sort -V | sed -n '1p')" != "$current_version" ]]; then
        error "拒绝降级 Jenkins: $current_version -> $JENKINS_VERSION"
        exit 1
    fi
    if [[ "$current_version" == "$JENKINS_VERSION" ]]; then
        ok "Jenkins 已是目标版本: $JENKINS_VERSION"
        return 0
    fi

    # 备份
    backup_jenkins
    
    # 停止
    if [[ -f "$INSTALL_DIR/stop.sh" ]]; then
        bash "$INSTALL_DIR/stop.sh"
    fi
    
    # 下载新版本
    local war_name="jenkins.war"
    local war_path="$DOWNLOAD_DIR/$war_name"
    local url="https://get.jenkins.io/war-stable/${JENKINS_VERSION}/${war_name}"
    
    info "下载新版本: $url"
    rm -f "$war_path"
    if ! download_file "$url" "$war_path"; then
        error "下载失败"
        exit 1
    fi

    local downloaded_version
    downloaded_version=$(unzip -p "$war_path" META-INF/MANIFEST.MF 2>/dev/null \
        | awk -F': ' '/^Jenkins-Version:/{gsub(/\r/,"",$2); version=$2} END{print version}')
    if [[ "$downloaded_version" != "$JENKINS_VERSION" ]]; then
        error "Jenkins WAR 版本校验失败: 期望 $JENKINS_VERSION，实际 ${downloaded_version:-未知}"
        exit 1
    fi
    
    # 替换 war 文件
    cp "$war_path" "$INSTALL_DIR/$war_name"

    # 旧安装脚本内端口是生成时固化的；升级时同步本次指定端口和监听地址。
    if [[ -f "$INSTALL_DIR/start.sh" ]]; then
        sed -i -E "s/_port=[0-9]+/_port=${HTTP_PORT}/g; s/--httpPort=[0-9]+/--httpPort=${HTTP_PORT}/g; s/_bind=\"[^\"]*\"/_bind=\"${HTTP_LISTEN_ADDRESS}\"/g; s/--httpListenAddress=\"[^\"]*\"/--httpListenAddress=\"${HTTP_LISTEN_ADDRESS}\"/g" "$INSTALL_DIR/start.sh"
    fi
    if [[ -f "$INSTALL_DIR/stop.sh" ]]; then
        sed -i -E "s/--httpPort=[0-9]+/--httpPort=${HTTP_PORT}/g" "$INSTALL_DIR/stop.sh"
    fi
    if [[ -f "$INSTALL_DIR/status.sh" ]]; then
        sed -i -E "s/--httpPort=[0-9]+/--httpPort=${HTTP_PORT}/g; s/:[0-9]+/:${HTTP_PORT}/g" "$INSTALL_DIR/status.sh"
    fi
    
    # 启动
    if [[ -f "$INSTALL_DIR/start.sh" ]]; then
        bash "$INSTALL_DIR/start.sh"
        
        # 健康检查
        local url
        url=$(listen_url "$HTTP_LISTEN_ADDRESS" "$HTTP_PORT")
        if ! health_check "$url" 120; then
            warn "Jenkins 新版本启动失败，恢复升级前版本"
            if [[ -n "$LAST_BACKUP_DIR" && -d "$LAST_BACKUP_DIR" ]]; then
                bash "$INSTALL_DIR/stop.sh" >/dev/null 2>&1 || true
                cp "$LAST_BACKUP_DIR/jenkins.war" "$INSTALL_DIR/jenkins.war"
                cp "$LAST_BACKUP_DIR/start.sh" "$INSTALL_DIR/start.sh" 2>/dev/null || true
                cp "$LAST_BACKUP_DIR/stop.sh" "$INSTALL_DIR/stop.sh" 2>/dev/null || true
                cp "$LAST_BACKUP_DIR/status.sh" "$INSTALL_DIR/status.sh" 2>/dev/null || true
            fi
            return 1
        fi
    fi
    
    ok "升级完成"
}

# === 主函数 ===
main() {
    parse_args "$@"

    # 管理命令
    if [[ "$STATUS_MODE" == true ]]; then
        show_status
        exit 0
    fi

    if [[ "$RESTART_MODE" == true ]]; then
        restart_jenkins
        exit 0
    fi

    if [[ "$UPGRADE_MODE" == true ]]; then
        upgrade_jenkins
        exit 0
    fi

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_jenkins
        exit 0
    fi

    # 安装模式
    info "Jenkins 安装"
    info "版本: $JENKINS_VERSION"
    info "安装目录: $INSTALL_DIR"
    info "HTTP 端口: $HTTP_PORT"
    info "运行用户: $JENKINS_USER"

    # 自动选择模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if docker_available; then
            INSTALL_MODE="docker"
            info "检测到 Docker，使用 Docker 模式"
        else
            INSTALL_MODE="host"
            info "Docker 不可用，使用主机模式"
        fi
    fi

    print_jenkins_status || true

    # 端口占用检测（可能修改 HTTP_PORT / AGENT_PORT）
    handle_port_conflict "$HTTP_PORT" "HTTP 端口" || exit 0
    handle_port_conflict "$AGENT_PORT" "Agent 端口" || exit 0

    # 显示最终端口（可能已被冲突处理修改）
    info "最终端口: HTTP=${HTTP_PORT}  Agent=${AGENT_PORT}"

    case "$INSTALL_MODE" in
        docker)
            if ! docker_available; then
                error "Docker 不可用"
                exit 1
            fi
            install_docker ;;
        host)
            install_host ;;
        *)
            error "未知安装模式: $INSTALL_MODE"
            exit 1 ;;
    esac

    ok "Jenkins 安装完成"
    info "访问地址: $(listen_url "$HTTP_LISTEN_ADDRESS" "$HTTP_PORT")"
    if [[ "$HTTP_LISTEN_ADDRESS" == "0.0.0.0" || "$HTTP_LISTEN_ADDRESS" == "*" || "$HTTP_LISTEN_ADDRESS" == "::" || "$HTTP_LISTEN_ADDRESS" == "[::]" ]]; then
        info "局域网访问: http://<studio-ip>:${HTTP_PORT}"
    fi
    
    if [[ "$AUTO_START" == true ]]; then
        if [ -f "$INSTALL_DIR/start.sh" ]; then
            info "自动启动 Jenkins..."
            bash "$INSTALL_DIR/start.sh"
            
            # 健康检查
            local url
            url=$(listen_url "$HTTP_LISTEN_ADDRESS" "$HTTP_PORT")
            health_check "$url" 60
        fi
    else
        if [ -f "$INSTALL_DIR/start.sh" ]; then
            info "启动: $INSTALL_DIR/start.sh"
            info "停止: $INSTALL_DIR/stop.sh"
            info "状态: $INSTALL_DIR/status.sh"
        fi
    fi
}

main "$@"

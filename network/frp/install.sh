#!/bin/bash

# 设置严格模式
set -euo pipefail
ORIGINAL_ARGS=("$@")

get_script_dir() {
    local source="${BASH_SOURCE[0]:-$0}"
    local dir
    if command -v readlink >/dev/null 2>&1; then
        local resolved
        resolved=$(readlink -f "$source" 2>/dev/null || true)
        if [ -n "$resolved" ]; then
            dirname "$resolved"
            return
        fi
    fi
    dir=$(cd "$(dirname "$source")" && pwd)
    echo "$dir"
}

FRP_ORIGINAL_HOME="${FRP_ORIGINAL_HOME:-$HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    FRP_ORIGINAL_HOME=$(eval echo "~${SUDO_USER}")
fi
SCRIPT_DIR=$(get_script_dir)

# 定义公共变量
FRP_VERSION="0.63.0"
# 根据操作系统和架构选择对应的二进制文件
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
        FRP_ARCH="darwin_arm64"
    else
        FRP_ARCH="darwin_amd64"
    fi
else
    # Linux
    FRP_ARCH="linux_amd64"
fi

# 支持国内镜像加速下载
FRP_ARCHIVE_NAME="frp_${FRP_VERSION}_${FRP_ARCH}.tar.gz"
FRP_ORIGINAL_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_ARCHIVE_NAME}"
FRP_MIRROR_URL="${FRP_MIRROR_URL:-https://ghproxy.com/}"
FRP_DOWNLOAD_URL="${FRP_MIRROR_URL}${FRP_ORIGINAL_URL}"
# 若安装目录不是当前目录，则拷贝当前目录下所有文件到安装目录
DEFAULT_INSTALL_DIR="$SCRIPT_DIR"
DEFAULT_DOWNLOAD_DIR="${FRP_ORIGINAL_HOME}/Downloads"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
FRPS_NAME="frps"
FRPS_CONF_NAME="${FRPS_NAME}.toml"
FRPC_NAME="frpc"
FRPC_CONF_NAME="${FRPC_NAME}.toml"
SERVICE_DIR="/usr/lib/systemd/system"
FRPS_SERVICE_FILE="$SERVICE_DIR/${FRPS_NAME}.service"
FRPC_SERVICE_FILE="$SERVICE_DIR/${FRPC_NAME}.service"
LOG_FILE="$DEFAULT_INSTALL_DIR/frp.log"

# 全局错误处理函数
error_exit() {
    echo "错误: $1" >&2
    exit "${2:-1}"
}

# 封装sudo操作
run_as_root() {
    if [ "${USE_SUDO:-false}" = true ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# 日志级别定义
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3
CURRENT_LOG_LEVEL=${LOG_LEVEL_INFO}

# 全局日志函数（带级别）
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level_num

    case "$level" in
        DEBUG|debug) level_num=$LOG_LEVEL_DEBUG ;;
        INFO|info)   level_num=$LOG_LEVEL_INFO ;;
        WARN|warn)   level_num=$LOG_LEVEL_WARN ;;
        ERROR|error) level_num=$LOG_LEVEL_ERROR ;;
        *)           level_num=$level ;;
    esac

    if ! [[ "$level_num" =~ ^[0-9]+$ ]]; then
        level_num=$LOG_LEVEL_INFO
    fi

    if [ "$level_num" -ge "$CURRENT_LOG_LEVEL" ]; then
        local level_name
        case $level_num in
            $LOG_LEVEL_DEBUG) level_name="DEBUG" ;;
            $LOG_LEVEL_INFO)  level_name="INFO" ;;
            $LOG_LEVEL_WARN)  level_name="WARN" ;;
            $LOG_LEVEL_ERROR) level_name="ERROR" ;;
            *) level_name="UNKNOWN" ;;
        esac
        # 将日志输出到 stderr，以免干扰 stdout 的数据输出
        echo "[$timestamp] [$level_name] $message" >&2
        # 同时写入日志文件
        if [ -d "$(dirname "$LOG_FILE")" ]; then
            echo "[$timestamp] [$level_name] $message" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# 便捷的日志级别函数
log_debug() { log_message $LOG_LEVEL_DEBUG "$@"; }
log_info()  { log_message $LOG_LEVEL_INFO  "$@"; }
log_warn()  { log_message $LOG_LEVEL_WARN  "$@"; }
log_error() { log_message $LOG_LEVEL_ERROR "$@"; }

# 帮助信息函数
show_help() {
    echo "FRP 安装脚本"
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help                    显示此帮助信息"
    echo "  -s, --server                  安装服务端 (frps)"
    echo "  -c, --client                  安装客户端 (frpc)"
    echo "  -d, --install-dir DIR         指定安装目录 (默认: 脚本目录 $DEFAULT_INSTALL_DIR)"
    echo "  -D, --download-dir DIR        指定下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)"
    echo "  -u, --uninstall               执行卸载操作"
    echo "      --service                 仅安装自启动服务 (不重新下载/配置，用于已安装的 frp)"
    echo "      --server-ip IP            指定服务端 IP 地址 (仅用于客户端安装，默认: $DEFAULT_PUBLIC_IP)"
    echo "      --server-port PORT        指定服务端端口 (仅用于客户端安装，默认: 7000)"
    echo "      --skip-connection-check   跳过服务端连接检测"
    echo ""
    echo "示例:"
    echo "  $0                                      # 交互式安装 (服务端或客户端)"
    echo "  $0 -s                                   # 直接安装服务端"
    echo "  $0 --client --server-ip 1.2.3.4         # 安装客户端并指定服务端公网 IP"
    echo "  $0 -c --server-ip 1.2.3.4 --server-port 7000"
    echo "  $0 --server --install-dir /opt/frp      # 安装服务端到指定目录"
    echo "  $0 -c -d /opt/frp -D /tmp/downloads     # 指定安装目录和下载目录"
    echo "  $0 -u                                   # 卸载 FRP"
    echo "  $0 --service -c                         # 仅安装 frpc 自启动服务"
    echo "  $0 --service -s                         # 仅安装 frps 自启动服务"
    exit 0
}

# 通用卸载函数
uninstall_frp() {
    local service_name=$1
    local service_file=$2

    echo "正在卸载 $service_name..."

    # macOS: 卸载 launchd 服务
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local plist_file="$MAC_LAUNCH_DIR/com.${service_name}.plist"
        if [ -f "$plist_file" ]; then
            launchctl unload -w "$plist_file" 2>/dev/null || true
            rm -f "$plist_file" 2>/dev/null || true
            echo "$service_name launchd 服务已卸载"
        fi
        # 停止进程
        pkill -f "$service_name" 2>/dev/null || true
        # 删除相关文件
        rm -rf "$DEFAULT_INSTALL_DIR/${service_name}"* 2>/dev/null || true
        echo "$service_name 卸载完成。"
        return
    fi

    # 停止服务
    if systemctl is-active --quiet "${service_name}.service"; then
        echo "正在停止 $service_name 服务..."
        run_as_root systemctl stop "${service_name}.service"
    fi

    # 禁用服务
    run_as_root systemctl disable "${service_name}.service" 2>/dev/null || true
    run_as_root rm -f "${service_file}" 2>/dev/null || true

    # 删除相关文件
    local install_path=$(systemctl show -p FragmentPath "${service_name}.service" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$install_path" ] && [ -f "$install_path" ]; then
        install_path=$(dirname "$install_path")
        run_as_root rm -rf "$install_path/${service_name}"* 2>/dev/null || true
    fi

    # 尝试从默认目录删除
    run_as_root rm -rf "$DEFAULT_INSTALL_DIR/${service_name}"* 2>/dev/null || true

    echo "$service_name 卸载完成。"
}

# 执行完整卸载
uninstall_all() {
    uninstall_frp "${FRPS_NAME}" "${FRPS_SERVICE_FILE}"
    uninstall_frp "${FRPC_NAME}" "${FRPC_SERVICE_FILE}"

    # 停止任何可能正在运行的进程
    run_as_root pkill -f frps 2>/dev/null || true
    run_as_root pkill -f frpc 2>/dev/null || true

    # 删除日志文件
    run_as_root rm -f "$LOG_FILE" 2>/dev/null || true
    echo "卸载完成。"
}

# 初始化变量
USE_SUDO=false
UNINSTALL_MODE=""
SERVICE_ONLY=false
SERVER_IP=""
SERVER_PORT=""
SKIP_CONNECTION_CHECK=false
DEFAULT_PUBLIC_IP=""

# 解析命令行参数
INSTALL_MODE=""
CUSTOM_INSTALL_DIR=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -s|--server)
            INSTALL_MODE="s"
            shift
            ;;
        -c|--client)
            INSTALL_MODE="c"
            shift
            ;;
        -u|--uninstall)
            UNINSTALL_MODE="true"
            shift
            ;;
        --service)
            SERVICE_ONLY=true
            shift
            ;;
        -d|--dir|--install-dir)
            if [ $# -lt 2 ] || [[ "${2:-}" == -* ]]; then
                echo "错误: $1 参数需要指定目录路径"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
            fi
            CUSTOM_INSTALL_DIR="$2"
            shift 2
            ;;
        --dir=*|--install-dir=*)
            CUSTOM_INSTALL_DIR="${1#*=}"
            shift
            ;;
        -D|--download-dir)
            if [ $# -lt 2 ] || [[ "${2:-}" == -* ]]; then
                echo "错误: $1 参数需要指定下载目录"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
            fi
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        --download-dir=*)
            DOWNLOAD_DIR="${1#*=}"
            shift
            ;;
        --server-ip)
            if [ $# -lt 2 ] || [[ "${2:-}" == -* ]]; then
                echo "错误: --server-ip 参数需要指定 IP 地址"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
            fi
            SERVER_IP="$2"
            shift 2
            ;;
        --server-ip=*)
            SERVER_IP="${1#*=}"
            shift
            ;;
        --server-port)
            if [ $# -lt 2 ] || [[ "${2:-}" == -* ]]; then
                echo "错误: --server-port 参数需要指定端口号"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
            fi
            SERVER_PORT="$2"
            shift 2
            ;;
        --server-port=*)
            SERVER_PORT="${1#*=}"
            shift
            ;;
        --skip-connection-check)
            SKIP_CONNECTION_CHECK=true
            shift
            ;;
        -*)
            echo "未知参数: $1"
            echo "使用 -h 或 --help 查看帮助信息"
            exit 1
            ;;
        *)
            echo "未知参数: $1"
            echo "安装目录请使用 -d 或 --install-dir 指定"
            echo "使用 -h 或 --help 查看帮助信息"
            exit 1
            ;;
    esac
done

expand_path() {
    local path="$1"
    path="${path/#\~/$FRP_ORIGINAL_HOME}"
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    printf '%s\n' "${path%/}"
}

# 确定安装目录
if [ -n "${CUSTOM_INSTALL_DIR:-}" ]; then
    INSTALL_DIR=$(expand_path "$CUSTOM_INSTALL_DIR")
else
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
fi
DOWNLOAD_DIR=$(expand_path "$DOWNLOAD_DIR")
LOG_FILE="$INSTALL_DIR/frp.log"

# 自动检测并提升权限（兼容 CentOS 和 Ubuntu）。放在参数解析之后，避免 --help 也要求 sudo。
# macOS 下 --service 模式不需要 sudo (LaunchAgent 是用户级的)
if [ "$(id -u)" -ne 0 ]; then
    if [[ "$OSTYPE" == "darwin"* && "$SERVICE_ONLY" = true ]]; then
        : # macOS 仅安装服务模式，跳过提权
    elif command -v sudo &> /dev/null; then
        echo "[INFO] 当前不是 root 用户，尝试使用 sudo 提权..."
        exec sudo env "FRP_ORIGINAL_HOME=$FRP_ORIGINAL_HOME" "$0" "${ORIGINAL_ARGS[@]}"
        exit
    else
        echo "错误：请使用 root 用户或具有 sudo 权限的用户运行此脚本。"
        exit 1
    fi
fi

# 如果是卸载模式，直接执行卸载
if [ "$UNINSTALL_MODE" = "true" ]; then
    uninstall_all
    exit 0
fi

# 仅安装自启动服务模式 (用于已安装的 frp 补装自启动)
if [ "$SERVICE_ONLY" = true ]; then
    # 确定要为哪个服务创建自启动
    if [ -z "$INSTALL_MODE" ]; then
        read -p "请选择要安装自启动的服务 (s服务端/c客户端，默认c): " CHOICE
        CHOICE=${CHOICE:-c}
    else
        CHOICE=$INSTALL_MODE
    fi

    case $CHOICE in
        s)
            if [ ! -x "${INSTALL_DIR}/frps" ]; then
                echo "错误: 未找到 frps 二进制文件: ${INSTALL_DIR}/frps"
                echo "请先运行完整安装: $0 -s"
                exit 1
            fi
            if [ ! -f "${INSTALL_DIR}/${FRPS_CONF_NAME}" ]; then
                echo "错误: 未找到 frps 配置文件: ${INSTALL_DIR}/${FRPS_CONF_NAME}"
                echo "请先运行完整安装: $0 -s"
                exit 1
            fi
            echo "仅为已安装的 frps 创建自启动服务..."
            create_systemd_service
            # 启动服务
            if [ -f "${INSTALL_DIR}/startup.sh" ]; then
                echo "正在启动 frps 服务..."
                if [ "$USE_SUDO" = true ]; then
                    sudo "${INSTALL_DIR}/startup.sh" --server --install-dir "${INSTALL_DIR}"
                else
                    "${INSTALL_DIR}/startup.sh" --server --install-dir "${INSTALL_DIR}"
                fi
            fi
            print_server_install_summary
            exit 0
            ;;
        c)
            if [ ! -x "${INSTALL_DIR}/frpc" ]; then
                echo "错误: 未找到 frpc 二进制文件: ${INSTALL_DIR}/frpc"
                echo "请先运行完整安装: $0 -c"
                exit 1
            fi
            if [ ! -f "${INSTALL_DIR}/${FRPC_CONF_NAME}" ]; then
                echo "错误: 未找到 frpc 配置文件: ${INSTALL_DIR}/${FRPC_CONF_NAME}"
                echo "请先运行完整安装: $0 -c"
                exit 1
            fi
            echo "仅为已安装的 frpc 创建自启动服务..."
            create_systemd_client_service
            # 启动服务
            if [ -f "${INSTALL_DIR}/startup.sh" ]; then
                echo "正在启动 frpc 服务..."
                if [ "$USE_SUDO" = true ]; then
                    sudo "${INSTALL_DIR}/startup.sh" --client --install-dir "${INSTALL_DIR}"
                else
                    "${INSTALL_DIR}/startup.sh" --client --install-dir "${INSTALL_DIR}"
                fi
            fi
            print_client_install_summary
            exit 0
            ;;
        *)
            echo "无效的选择，退出。"
            exit 1
            ;;
    esac
fi


# 检查安装目录权限
if [ ! -d "$INSTALL_DIR" ]; then
    # 目录不存在，尝试创建
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        echo "错误: 没有权限创建目录 $INSTALL_DIR"
        read -p "是否使用用户目录 $HOME/frp? (Y/n) " USE_HOME_DIR
        USE_HOME_DIR=${USE_HOME_DIR:-y}
        
        if [[ $USE_HOME_DIR =~ ^[Yy]$ ]]; then
            INSTALL_DIR="$HOME/frp"
            echo "安装目录更改为: $INSTALL_DIR"
            mkdir -p "$INSTALL_DIR"
        else
            echo "正在使用sudo权限创建目录..."
            sudo mkdir -p "$INSTALL_DIR"
            USE_SUDO=true
        fi
    fi
else
    # 目录已存在，检查是否有写权限
    if [ ! -w "$INSTALL_DIR" ]; then
        echo "错误: 没有写权限访问目录 $INSTALL_DIR"
        read -p "是否使用用户目录 $HOME/frp? (Y/n) " USE_HOME_DIR
        USE_HOME_DIR=${USE_HOME_DIR:-y}
        
        if [[ $USE_HOME_DIR =~ ^[Yy]$ ]]; then
            INSTALL_DIR="$HOME/frp"
            echo "安装目录更改为: $INSTALL_DIR"
        else
            echo "正在使用sudo权限..."
            USE_SUDO=true
        fi
    fi
fi

if [ "$INSTALL_DIR" != "$SCRIPT_DIR" ]; then
    echo "安装目录为: $INSTALL_DIR"
    if [ "$USE_SUDO" = true ]; then
        sudo cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR"/
        # 设置脚本执行权限
        sudo chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR"/
        # 设置脚本执行权限
        chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    fi
    SCRIPT_DIR="$INSTALL_DIR"
    cd "$INSTALL_DIR"
else
    # 即使SCRIPT_DIR等于INSTALL_DIR，仍然确保脚本有执行权限
    if [ "$USE_SUDO" = true ]; then
        sudo chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        sudo chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        chmod +x "$INSTALL_DIR/startup.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/stop.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    fi
fi

# 检查并安装必要工具
check_dependencies() {
    local missing_deps=()
    local optional_missing=()

    # 检查必要命令
    for cmd in tar perl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if ! command -v adl >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi

    # 检查可选命令
    for cmd in openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            optional_missing+=("$cmd")
        fi
    done

    # 安装必要依赖
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warn "缺少必要依赖: ${missing_deps[*]}"
        log_info "正在尝试安装依赖..."

        for dep in "${missing_deps[@]}"; do
            log_info "正在安装 $dep..."
            # 检测操作系统并使用相应的包管理器
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS 使用 Homebrew
                if command -v brew &> /dev/null; then
                    if brew install "$dep" 2>/dev/null; then
                        log_info "$dep 安装成功"
                    else
                        error_exit "无法安装必要依赖: $dep，请手动安装后重试"
                    fi
                else
                    error_exit "macOS 上需要 Homebrew 来安装依赖，请先安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                fi
            elif run_as_root yum install -y "$dep" 2>/dev/null || run_as_root apt-get install -y "$dep" 2>/dev/null; then
                log_info "$dep 安装成功"
            else
                error_exit "无法安装必要依赖: $dep，请手动安装后重试"
            fi
        done
    fi

    # 警告可选依赖缺失
    if [ ${#optional_missing[@]} -gt 0 ]; then
        log_warn "缺少可选依赖: ${optional_missing[*]}"
        log_info "某些功能可能不可用，建议手动安装这些依赖"
    fi

    log_info "依赖检查完成"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

find_adl() {
    local candidate
    for candidate in \
        "${SCRIPT_DIR}/../tools/adl" \
        "${SCRIPT_DIR}/../../network/tools/adl" \
        "${SCRIPT_DIR}/adl" \
        "/opt/homebrew/bin/adl" \
        "/usr/local/bin/adl"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    if command_exists adl && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi

    return 1
}

download_single_url() {
    local url=$1
    local output=$2
    local status=0
    local output_dir
    local output_name
    local adl_path

    output_dir=$(dirname "$output")
    output_name=$(basename "$output")

    if adl_path=$(find_adl); then
        log_info "检测到 adl，优先使用 adl 下载: $url"
        if "$adl_path" "$url" "$output_dir" "$output_name"; then
            [ -s "$output" ] && return 0
        fi
        log_warn "adl 下载失败，回退 curl/wget"
        rm -f "$output"
    fi

    if command_exists curl; then
        curl -L --fail --progress-bar -o "$output" "$url" || status=$?
    elif command_exists wget; then
        wget --show-progress -O "$output" "$url" || status=$?
    else
        log_error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi

    [ $status -eq 0 ] && [ -s "$output" ]
}

# 具体的下载实现（支持原地址和镜像回退）
download_file_with_fallback() {
    local output=$1
    local url

    for url in "$FRP_ORIGINAL_URL" "$FRP_DOWNLOAD_URL"; do
        log_info "尝试下载: $url"
        rm -f "$output"
        if download_single_url "$url" "$output"; then
            log_info "下载成功: $url"
            return 0
        fi
        log_warn "下载失败: $url"
    done

    rm -f "$output"
    return 1
}

# 下载并验证文件
download_and_verify() {
    local download_dir="$DOWNLOAD_DIR"
    # 确保下载目录存在
    if ! mkdir -p "$download_dir" 2>/dev/null; then
        download_dir="/tmp"
        mkdir -p "$download_dir"
    fi
    local temp_file="${download_dir}/${FRP_ARCHIVE_NAME}"

    # 1. 检查本地是否存在且不为空
    if [ -s "${temp_file}" ]; then
        log_info "发现本地已有文件: ${temp_file}，跳过下载"
        echo "${temp_file}"
        return 0
    fi

    log_info "正在下载: ${FRP_ARCHIVE_NAME}"
    log_info "下载目录: ${download_dir}"

    if ! download_file_with_fallback "${temp_file}"; then
        error_exit "下载失败: 无法从原地址或镜像下载 ${FRP_ARCHIVE_NAME}"
    fi

    log_info "下载完成，文件: ${temp_file}"
    # 只输出文件路径到 stdout
    echo "${temp_file}"
}

# 复制或下载 frp 二进制文件（通用函数）
copy_or_download_frp_binary() {
    local binary_name=$1  # frps 或 frpc
    local conf_name="${binary_name}.toml"
    local source_dir=$2

    if [ -n "$source_dir" ] && [ -f "$source_dir/$binary_name" ]; then
        log_info "发现现有 $binary_name 二进制文件，正在复制..."
        run_as_root cp "$source_dir/$binary_name" "${INSTALL_DIR}/"
        log_info "$binary_name 已从 $source_dir 复制到 ${INSTALL_DIR}"
    else
        log_info "正在下载 $binary_name..."
        local temp_archive=$(download_and_verify)
        run_as_root tar -xzf "$temp_archive" -C "${INSTALL_DIR}" --strip-components=1 "frp_${FRP_VERSION}_${FRP_ARCH}/$binary_name" "frp_${FRP_VERSION}_${FRP_ARCH}/$conf_name" || error_exit "解压失败"
        # 不再删除压缩包，以便下次重复使用
        log_info "压缩包保留在: $temp_archive"
    fi
}

# 更安全的随机字符串生成
generate_secure_token() {
    openssl rand -base64 32 | tr -d '/+' | cut -c1-16
}

# 跨平台 sed 命令封装
sed_in_place() {
    local pattern="$1"
    local file="$2"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi

    if [ $? -ne 0 ]; then
        log_error "sed 命令执行失败"
        return 1
    fi

    return 0
}

replace_literal_placeholder() {
    local file="$1"
    local placeholder="$2"
    local replacement="$3"
    local temp_file

    temp_file=$(mktemp)
    awk -v placeholder="$placeholder" -v replacement="$replacement" '
        {
            while ((idx = index($0, placeholder)) > 0) {
                $0 = substr($0, 1, idx - 1) replacement substr($0, idx + length(placeholder))
            }
            print
        }
    ' "$file" > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    mv "$temp_file" "$file"
}

# 从模板生成配置文件
generate_config_from_template() {
    local template_file="$1"
    local output_file="$2"
    local replacements="$3"  # 格式: "KEY1=VALUE1|KEY2=VALUE2|KEY3=VALUE3"

    if [ ! -f "$template_file" ]; then
        error_exit "模板文件不存在: $template_file"
    fi

    log_info "正在从模板生成配置文件: $template_file -> $output_file"

    # 验证模板文件存在
    if [ ! -f "$template_file" ]; then
        error_exit "模板文件不存在: $template_file"
    fi

    # 仅在当前替换集需要 SSH_PORT 时验证，避免服务端模板产生误导性警告。
    if [[ "$replacements" == *"SSH_PORT="* ]] && ! grep -q "{{SSH_PORT}}" "$template_file" 2>/dev/null; then
        log_warn "模板文件中可能缺少 SSH_PORT 占位符"
        log_warn "模板文件内容:"
        cat "$template_file" >&2
    fi

    # 记录替换参数（不包含敏感值）
    log_debug "替换参数: ${replacements}"

    # 检查模板中的占位符格式
    log_debug "模板文件中的占位符:"
    grep -n '{{' "$template_file" 2>/dev/null || log_debug "未找到占位符"

    # 复制模板到输出文件
    cp "$template_file" "$output_file"

    if [ $? -ne 0 ]; then
        error_exit "复制模板文件失败"
    fi

    # 处理每个替换项
    IFS='|' read -ra REPLACEMENT_ARRAY <<< "$replacements"

    if [ ${#REPLACEMENT_ARRAY[@]} -eq 0 ]; then
        error_exit "替换参数为空"
    fi

    for replacement in "${REPLACEMENT_ARRAY[@]}"; do
        local key="${replacement%%=*}"
        local value="${replacement#*=}"

        log_debug "正在替换占位符 {{${key}}} -> $value"

        # 转义特殊字符
        local escaped_value
        escaped_value=$(echo "$value" | sed 's/[&/\]/\\&/g')

        # 使用 perl 进行替换，跨平台兼容性更好
        perl -i -pe "s/\Q{{${key}}}\E/${escaped_value}/g" "$output_file"

        if [ $? -ne 0 ]; then
            error_exit "替换占位符 {{${key}}} 失败"
        fi

        # 验证替换是否成功
        if grep -q "{{${key}}}" "$output_file" 2>/dev/null; then
            error_exit "替换占位符 {{${key}}} 失败"
        fi
    done

    # 检查是否还有未替换的占位符
    local remaining_placeholders
    remaining_placeholders=$(grep "{{" "$output_file" 2>/dev/null | grep -v "{{WEB_SERVER_CONFIG}}" || true)
    if [ -n "$remaining_placeholders" ]; then
        log_warn "配置文件中有未替换的占位符:"
        echo "$remaining_placeholders"
    fi

    # 设置安全权限
    chmod 600 "$output_file" 2>/dev/null || log_warn "无法设置配置文件权限为 600"

    log_info "配置文件生成完成: $output_file"
}

# 验证 IP 地址格式
validate_ip_address() {
    local ip=$1
    local ip_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"

    if [[ $ip =~ $ip_regex ]]; then
        return 0
    else
        return 1
    fi
}

# 检测 IP 地址是否可达
check_ip_reachable() {
    local ip=$1
    local timeout=3
    local count=2

    log_info "正在检测 IP 地址 ${ip} 的可达性..."

    # 使用 ping 命令检测 IP 是否可达
    if command -v ping &> /dev/null; then
        if ping -c ${count} -W ${timeout} "${ip}" &> /dev/null; then
            log_info "IP 地址 ${ip} 可达"
            return 0
        else
            log_warn "IP 地址 ${ip} 不可达"
            return 1
        fi
    else
        log_warn "ping 命令不可用，跳过 IP 可达性检测"
        return 0
    fi
}

# 检测端口是否连通
check_port_connectivity() {
    local ip=$1
    local port=$2
    local timeout=5

    log_info "正在检测端口 $ip:$port 的连通性..."

    # 使用 nc (netcat) 检测端口
    if command -v nc &> /dev/null; then
        if nc -z -w $timeout $ip $port 2>/dev/null; then
            log_info "端口 $ip:$port 可连接"
            return 0
        else
            log_warn "端口 $ip:$port 不可连接"
            return 1
        fi
    # 使用 bash 内置的 /dev/tcp 检测端口（备用方案）
    elif (echo > /dev/tcp/$ip/$port) >/dev/null 2>&1; then
        log_info "端口 $ip:$port 可连接"
        return 0
    else
        log_warn "端口 $ip:$port 不可连接"
        return 1
    fi
}

# 综合验证 IP 和端口
validate_server_connection() {
    local ip=$1
    local port=$2
    local skip_check=${3:-false}

    # 验证 IP 格式
    if ! validate_ip_address "$ip"; then
        log_error "无效的 IP 地址格式: $ip"
        return 1
    fi

    # 验证端口范围
    if ! [[ $port =~ ^[0-9]+$ ]] || [ $port -lt 1 ] || [ $port -gt 65535 ]; then
        log_error "无效的端口号: $port（必须在 1-65535 之间）"
        return 1
    fi

    # 如果跳过连通性检测，直接返回成功
    if [ "$skip_check" = true ]; then
        log_info "跳过连通性检测"
        return 0
    fi

    # 检测 IP 可达性
    if ! check_ip_reachable "$ip"; then
        log_warn "IP 地址 $ip 不可达，但将继续安装"
        # 不强制返回失败，因为某些网络可能禁用 ping
    fi

    # 检测端口连通性
    if ! check_port_connectivity "$ip" "$port"; then
        log_error "端口 $ip:$port 不可连接，请检查服务端是否已启动"
        return 1
    fi

    return 0
}

# 避免在脚本输出中显示敏感信息
mask_sensitive_info() {
    local info=$1
    if [ ${#info} -le 4 ]; then
        echo "****"
    else
        echo "${info:0:4}$(printf '%*s' $((${#info}-4)) | tr ' ' '*')"
    fi
}

read_toml_value() {
    local config_file="$1"
    local key="$2"

    [ -f "$config_file" ] || return 0
    awk -F'=' -v key="$key" '
        /^[[:space:]]*#/ { next }
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            value=$2
            sub(/#.*/, "", value)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
            print value
            exit
        }
    ' "$config_file"
}

read_first_proxy_value() {
    local config_file="$1"
    local key="$2"

    [ -f "$config_file" ] || return 0
    awk -F'=' -v key="$key" '
        /^\[\[proxies\]\]/ { in_proxy=1; next }
        in_proxy && /^\[/ { exit }
        in_proxy && /^[[:space:]]*#/ { next }
        in_proxy {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        in_proxy && lhs == key {
            value=$2
            sub(/#.*/, "", value)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
            print value
            exit
        }
    ' "$config_file"
}

append_unique_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local item="${port}/${proto}"
    local existing

    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    for existing in "${FIREWALL_PORTS[@]:-}"; do
        [ "$existing" = "$item" ] && return 0
    done
    FIREWALL_PORTS+=("$item")
}

get_server_firewall_ports() {
    local config_file="${1:-${INSTALL_DIR}/${FRPS_CONF_NAME}}"
    local bind_port vhost_http_port vhost_https_port web_port
    FIREWALL_PORTS=()

    bind_port=$(read_toml_value "$config_file" "bindPort")
    vhost_http_port=$(read_toml_value "$config_file" "vhostHTTPPort")
    vhost_https_port=$(read_toml_value "$config_file" "vhostHTTPSPort")
    web_port=$(read_toml_value "$config_file" "webServer.port")

    append_unique_port "${bind_port:-7000}"
    append_unique_port "$vhost_http_port"
    append_unique_port "$vhost_https_port"
    append_unique_port "$web_port"
    # 默认 frpc 模板使用 remotePort=6000 暴露 SSH；服务端需放行该端口。
    append_unique_port "6000"

    printf '%s\n' "${FIREWALL_PORTS[@]}"
}

print_server_install_summary() {
    local config_file="${INSTALL_DIR}/${FRPS_CONF_NAME}"
    local bind_port vhost_http_port vhost_https_port web_port token ports port

    bind_port=$(read_toml_value "$config_file" "bindPort")
    vhost_http_port=$(read_toml_value "$config_file" "vhostHTTPPort")
    vhost_https_port=$(read_toml_value "$config_file" "vhostHTTPSPort")
    web_port=$(read_toml_value "$config_file" "webServer.port")
    token=$(read_toml_value "$config_file" "auth.token")
    ports=""
    while IFS= read -r port; do
        [ -n "$port" ] && ports="${ports:+$ports }$port"
    done < <(get_server_firewall_ports "$config_file")

    local service_control=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        service_control=$(cat <<EOF2
  launchctl list | grep frps                      # 查看状态
  launchctl unload $FRPS_PLIST_FILE && launchctl load -w $FRPS_PLIST_FILE  # 重启
  tail -f ${INSTALL_DIR}/frps.log                 # 查看日志
EOF2
)
    else
        service_control=$(cat <<EOF2
  systemctl status ${FRPS_NAME}
  systemctl restart ${FRPS_NAME}
EOF2
)
    fi

    cat <<EOF

================ FRP 服务端安装完成 ================
安装目录: ${INSTALL_DIR}
配置文件: ${config_file}
服务控制:
${service_control}

服务端需要开放的端口:
  ${ports}

端口用途:
  ${bind_port:-7000}/tcp  frpc 连接 frps 的控制端口
  ${vhost_http_port:-7800}/tcp  HTTP vhost 访问端口
  ${vhost_https_port:-7443}/tcp HTTPS vhost 访问端口
  ${web_port:-7500}/tcp  Dashboard 管理端口（建议仅限可信来源访问）
  6000/tcp  默认 SSH TCP 隧道 remotePort（按客户端 remotePort 调整）

客户端关键配置:
  serverAddr = "<服务端公网IP或域名>"
  serverPort = ${bind_port:-7000}
  auth.method = "token"
  auth.token = "$(mask_sensitive_info "${token:-}")"

客户端 SSH 隧道示例:
  [[proxies]]
  name = "ssh-client"
  type = "tcp"
  localIP = "127.0.0.1"
  localPort = 22
  remotePort = 6000
====================================================

EOF
}

print_client_install_summary() {
    local config_file="${INSTALL_DIR}/${FRPC_CONF_NAME}"
    local server_addr server_port token proxy_name proxy_type local_ip local_port remote_port

    server_addr=$(read_toml_value "$config_file" "serverAddr")
    server_port=$(read_toml_value "$config_file" "serverPort")
    token=$(read_toml_value "$config_file" "auth.token")
    proxy_name=$(read_first_proxy_value "$config_file" "name")
    proxy_type=$(read_first_proxy_value "$config_file" "type")
    local_ip=$(read_first_proxy_value "$config_file" "localIP")
    local_port=$(read_first_proxy_value "$config_file" "localPort")
    remote_port=$(read_first_proxy_value "$config_file" "remotePort")

    cat <<EOF

================ FRP 客户端安装完成 ================
安装目录: ${INSTALL_DIR}
配置文件: ${config_file}
服务控制:
  launchctl list | grep frpc                       # 查看状态 (macOS)
  launchctl unload $FRPC_PLIST_FILE && launchctl load -w $FRPC_PLIST_FILE  # 重启 (macOS)
  tail -f ${INSTALL_DIR}/frpc.log                  # 查看日志 (macOS)
  systemctl status ${FRPC_NAME}                    # 查看状态 (Linux)
  systemctl restart ${FRPC_NAME}                   # 重启 (Linux)

客户端关键配置:
  serverAddr = "${server_addr}"
  serverPort = ${server_port}
  auth.token = "$(mask_sensitive_info "${token:-}")"

默认代理:
  name = "${proxy_name}"
  type = "${proxy_type}"
  localIP = "${local_ip}"
  localPort = ${local_port}
  remotePort = ${remote_port}

服务端需要开放的端口:
  ${server_port}/tcp  frpc 连接 frps 的控制端口
  ${remote_port}/tcp  当前客户端代理暴露端口

访问示例:
  ssh -p ${remote_port} <user>@${server_addr}

说明:
  frpc 主动连接 frps，客户端机器通常不需要开放入站防火墙端口。
  macOS 自启动通过 LaunchAgent 实现 (开机自动运行 + 崩溃自动重启)。
====================================================

EOF
}

# 生成frps 配置文件
generate_default_config() {
    log_info "正在生成 ${FRPS_CONF_NAME} 配置文件..."

    AUTH_TOKEN=$(generate_secure_token)
    echo "生成的 auth.token: $(mask_sensitive_info "$AUTH_TOKEN")"

    read -p "是否需要启用 dashboard？(Y/n) " DASHBOARD_CHOICE
    DASHBOARD_CHOICE=${DASHBOARD_CHOICE:-y}

    local template_file="${SCRIPT_DIR}/frps.toml.template"

    # 检查模板文件是否存在
    if [ ! -f "$template_file" ]; then
        error_exit "无法找到 frps 配置模板文件: $template_file"
    fi

    # 构建替换参数
    local web_server_config=""
    if [[ $DASHBOARD_CHOICE =~ ^[Yy]$ ]]; then
        WEB_SERVER_PASSWORD=$(generate_secure_token)
        echo "生成的 webServer.password: $(mask_sensitive_info "$WEB_SERVER_PASSWORD")"
        # 使用单行配置，避免 sed 多行替换问题
        web_server_config="webServer.user = \"webuser\""$'\n'"webServer.password = \"${WEB_SERVER_PASSWORD}\""
    fi

    # 替换占位符（注意：WEB_SERVER_CONFIG 需要特殊处理多行）
    local replacements="AUTH_TOKEN=${AUTH_TOKEN}|LOG_FILE=${LOG_FILE}"

    # 先替换单行占位符
    generate_config_from_template "$template_file" "${INSTALL_DIR}/${FRPS_CONF_NAME}" "$replacements"

    # 手动处理多行的 WEB_SERVER_CONFIG
    if [ -n "$web_server_config" ]; then
        replace_literal_placeholder "${INSTALL_DIR}/${FRPS_CONF_NAME}" "{{WEB_SERVER_CONFIG}}" "$web_server_config" || error_exit "替换 WEB_SERVER_CONFIG 占位符失败"
    else
        # 删除占位符行
        sed_in_place "/{{WEB_SERVER_CONFIG}}/d" "${INSTALL_DIR}/${FRPS_CONF_NAME}"
    fi

    if grep -q "{{" "${INSTALL_DIR}/${FRPS_CONF_NAME}" 2>/dev/null; then
        log_warn "${FRPS_CONF_NAME} 中仍有未替换的占位符:"
        grep "{{" "${INSTALL_DIR}/${FRPS_CONF_NAME}" || true
    fi

    log_info "${FRPS_CONF_NAME} 配置文件生成完成"
}
# 获取当前IP地址
function get_current_ip() {
    local ip_tool=$(command -v ip)  # 检查ip工具是否存在
    local ifconfig_tool=$(command -v ifconfig)  # 检查ifconfig工具是否存在

    if [ -n "$ip_tool" ]; then
        # 使用ip工具获取IP地址
        ip_addr=$($ip_tool addr show up | grep inet | grep -Ev "inet6|127|172" | grep -v "\.250\." | awk '{print $2}' | awk -F'/' '{print $1}')
    elif [ -n "$ifconfig_tool" ]; then
        # 使用ifconfig工具获取IP地址
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS 的 ifconfig 输出格式不同
            ip_addr=$($ifconfig_tool -a | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}')
        else
            # Linux 的 ifconfig 输出格式
            ip_addr=$($ifconfig_tool -a | grep inet | grep -v 127.0.0.1 | grep -v "\.250\." | grep -v inet6 | awk '{print $2}')
        fi
    else
        log_warn "ip或ifconfig命令未找到." >&2
        return 1
    fi

    echo "$ip_addr"
}

# 从 sshd 配置文件中提取 SSH 端口号（兼容注释和未注释的情况）
get_ssh_port() {
    local sshd_config="/etc/ssh/sshd_config"
    local port=""
    
    if [ ! -f "$sshd_config" ]; then
        echo "22"
        return
    fi
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: 优先匹配未注释的 Port 行，如果没有则匹配注释行
        port=$(grep -v '^[[:space:]]*#' "$sshd_config" 2>/dev/null | grep -m1 '^[[:space:]]*Port[[:space:]]' | awk '{print $2}' || echo "")
        if [ -z "$port" ]; then
            port=$(grep '^[[:space:]]*#[[:space:]]*Port[[:space:]]' "$sshd_config" 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's/#//' || echo "")
        fi
    else
        # Linux: 优先匹配未注释行，如果没有则匹配注释行
        port=$(grep -oP '^\s*Port\s+\K\d+' "$sshd_config" 2>/dev/null | head -n 1 || echo "")
        if [ -z "$port" ]; then
            port=$(grep -oP '^\s*#\s*Port\s+\K\d+' "$sshd_config" 2>/dev/null | head -n 1 || echo "")
        fi
    fi
    
    if [ -z "$port" ]; then
        port="22"
    fi
    
    echo "$port"
}

# 从现有配置文件读取配置值
read_existing_config() {
    local config_file=$1
    local key=$2
    
    if [ ! -f "$config_file" ]; then
        echo ""
        return
    fi
    
    local value=""
    case "$key" in
        serverAddr)
            value=$(grep '^serverAddr' "$config_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "\t')
            ;;
        serverPort)
            value=$(grep '^serverPort' "$config_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "\t')
            ;;
        auth.token)
            value=$(grep 'auth.token' "$config_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "\t')
            ;;
    esac
    
    echo "$value"
}

# 生成默认的 frpc 配置文件
generate_default_client_config() {
    log_info "正在生成 ${FRPC_CONF_NAME} 配置文件..."

    # 从现有配置文件读取默认值
    local existing_config_file="${INSTALL_DIR}/${FRPC_CONF_NAME}"
    local default_server_ip=$(read_existing_config "$existing_config_file" "serverAddr")
    local default_server_port=$(read_existing_config "$existing_config_file" "serverPort")
    local default_auth_token=$(read_existing_config "$existing_config_file" "auth.token")

    # 如果没有通过命令行参数指定，则交互式输入
    if [ -z "${SERVER_IP:-}" ]; then
        local prompt_msg="请输入 frps 服务端的公网 IP 地址: "
        if [ -n "$default_server_ip" ] && [ "$default_server_ip" != "127.0.0.1" ]; then
            prompt_msg="请输入 frps 服务端的 IP 地址 (默认: $default_server_ip): "
        elif [ -n "$DEFAULT_PUBLIC_IP" ]; then
            prompt_msg="请输入 frps 服务端的 IP 地址 (默认: $DEFAULT_PUBLIC_IP): "
        fi
        read -p "$prompt_msg" input_ip
        SERVER_IP=${input_ip:-$default_server_ip}
        SERVER_IP=${SERVER_IP:-${DEFAULT_PUBLIC_IP:-}}
        if [ -z "$SERVER_IP" ]; then
            error_exit "服务端 IP 地址不能为空，请指定 frps 服务端的公网 IP"
        fi
    else
        log_info "使用命令行指定的服务端 IP: $SERVER_IP"
    fi

    # 验证 IP 地址格式
    if ! validate_ip_address "$SERVER_IP"; then
        error_exit "无效的 IP 地址格式: $SERVER_IP"
    fi

    # 如果没有通过命令行参数指定，则交互式输入
    if [ -z "${SERVER_PORT:-}" ]; then
        local port_default=${default_server_port:-7000}
        read -p "请输入 frps 服务端的端口号 (默认 $port_default): " input_port
        SERVER_PORT=${input_port:-$port_default}
    else
        log_info "使用命令行指定的服务端端口: $SERVER_PORT"
    fi

    # 确保 SERVER_PORT 有值
    SERVER_PORT=${SERVER_PORT:-7000}

    # 验证端口范围
    if ! [[ $SERVER_PORT =~ ^[0-9]+$ ]] || [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
        error_exit "无效的端口号: $SERVER_PORT（必须在 1-65535 之间）"
    fi

    # 检测服务端连接
    log_info "正在验证服务端连接..."
    if ! validate_server_connection "$SERVER_IP" "$SERVER_PORT" "$SKIP_CONNECTION_CHECK"; then
        read -p "服务端连接验证失败，是否继续安装？(y/N): " CONTINUE_INSTALL
        CONTINUE_INSTALL=${CONTINUE_INSTALL:-n}
        if [[ ! $CONTINUE_INSTALL =~ ^[Yy]$ ]]; then
            log_info "用户取消安装"
            exit 1
        fi
        log_warn "用户选择继续安装，连接问题可能导致客户端无法正常工作"
    fi

    # 读取现有token作为默认值
    local token_prompt="请输入frps服务端的认证 token: "
    if [ -n "$default_auth_token" ]; then
        token_prompt="请输入frps服务端的认证 token (默认: $default_auth_token): "
    fi
    read -p "$token_prompt" SERVER_TOKEN
    SERVER_TOKEN=${SERVER_TOKEN:-$default_auth_token}
    if [ -z "$SERVER_TOKEN" ]; then
        error_exit "认证 token 不能为空"
    fi

    # 获取当前主机的 IP 地址
    CURRENT_IP=$(get_current_ip | head -n 1)
    if [ -z "${CURRENT_IP}" ]; then
        log_warn "无法获取当前主机 IP，使用默认值"
        CURRENT_IP="unknown"
    fi
    TUNNEL_NAME="ssh$(echo ${CURRENT_IP} | tr '.' '-' | cut -c1-20)"

    temp_sshd_port=$(get_ssh_port)

    local_ip=$(get_current_ip | head -n 1)
    if [ -z "$local_ip" ]; then
        log_warn "无法获取本地 IP，使用 127.0.0.1"
        local_ip="127.0.0.1"
    fi

    local template_file="${SCRIPT_DIR}/frpc.toml.template"

    # 检查模板文件是否存在
    if [ ! -f "$template_file" ]; then
        error_exit "无法找到 frpc 配置模板文件: $template_file"
    fi

    # 构建替换参数
    local replacements="SERVER_IP=${SERVER_IP}|SERVER_PORT=${SERVER_PORT}|SERVER_TOKEN=${SERVER_TOKEN}|LOG_FILE=${LOG_FILE}|TUNNEL_NAME=${TUNNEL_NAME}|LOCAL_IP=${local_ip}|SSH_PORT=${temp_sshd_port}"

    # 生成配置文件
    generate_config_from_template "$template_file" "${INSTALL_DIR}/${FRPC_CONF_NAME}" "$replacements"

    log_info "${FRPC_CONF_NAME} 配置文件生成完成"
}

# macOS LaunchAgent plist 文件路径
MAC_LAUNCH_DIR="${FRP_ORIGINAL_HOME}/Library/LaunchAgents"
FRPS_PLIST_FILE="$MAC_LAUNCH_DIR/com.frps.plist"
FRPC_PLIST_FILE="$MAC_LAUNCH_DIR/com.frpc.plist"

# 创建 macOS LaunchAgent plist 文件
create_macos_launchd_service() {
    local service_name=$1      # frps 或 frpc
    local plist_file=$2
    local start_args=$3        # 启动参数，如 "--server --install-dir /path"

    mkdir -p "$MAC_LAUNCH_DIR"

    # 如已加载先卸载，避免重复 load 报错
    launchctl unload "$plist_file" 2>/dev/null || true

    local bin_path="${INSTALL_DIR}/${service_name}"
    local log_path="${INSTALL_DIR}/${service_name}.log"

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.${service_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/startup.sh</string>
        <string>--install-dir</string>
        <string>${INSTALL_DIR}</string>
EOF
    # 追加额外参数（如 --server / --client）
    local arg
    for arg in $start_args; do
        echo "        <string>${arg}</string>" >> "$plist_file"
    done

    cat >> "$plist_file" <<EOF
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${log_path}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

    # 加载服务
    if launchctl load -w "$plist_file" 2>/dev/null; then
        log_info "macOS LaunchAgent 已加载: $service_name"
    else
        log_warn "launchctl load 失败，请手动执行: launchctl load -w $plist_file"
    fi
}

# 创建 Systemd 服务文件
create_systemd_service() {
    # macOS 使用 launchd
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "macOS 检测到，使用 launchd 创建自启动服务"
        create_macos_launchd_service "frps" "$FRPS_PLIST_FILE" "--server"
        return 0
    fi

    if systemctl list-unit-files | grep -q "${FRPS_NAME}.service"; then
        # 系统服务文件操作始终需要sudo权限
        sudo systemctl disable "${FRPS_NAME}.service" 2>/dev/null || true
        sudo rm -f "${FRPS_SERVICE_FILE}" 2>/dev/null || true
    fi

    # 系统服务文件始终需要sudo权限写入
    cat << EOF | sudo tee "${FRPS_SERVICE_FILE}" > /dev/null
[Unit]
Description=frps daemon
After = network.target syslog.target
Wants = network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/startup.sh --server --install-dir ${INSTALL_DIR}
ExecStop=${INSTALL_DIR}/stop.sh
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -ne 0 ]; then
        error_exit "创建 Systemd 服务文件失败。"
    fi

    sudo systemctl daemon-reload
}

create_systemd_client_service() {
    # macOS 使用 launchd
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "macOS 检测到，使用 launchd 创建自启动服务"
        create_macos_launchd_service "frpc" "$FRPC_PLIST_FILE" "--client"
        return 0
    fi

    if systemctl list-unit-files | grep -q "${FRPC_NAME}.service"; then
        sudo systemctl disable "${FRPC_NAME}.service" 2>/dev/null || true
        sudo rm -f "${FRPC_SERVICE_FILE}" 2>/dev/null || true
    fi

    # 系统服务文件始终需要sudo权限写入
    cat << EOF | sudo tee "${FRPC_SERVICE_FILE}" > /dev/null
[Unit]
Description=frpc client
After = network.target syslog.target
Wants = network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/startup.sh --client --install-dir ${INSTALL_DIR}
ExecStop=${INSTALL_DIR}/stop.sh
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -ne 0 ]; then
        error_exit "创建 Systemd 服务文件失败。"
    fi

    sudo systemctl daemon-reload
}
# 检测防火墙类型并自动开放端口（仅在防火墙服务处于 active 时操作）
# 使用方法：setup_firewall_ports "7000/tcp" "7800/tcp" "22/tcp"
firewalld_is_active() {
    command -v firewall-cmd >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet firewalld
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    run_as_root ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'
}

setup_firewall_ports() {
    local confirm_firewall=${CONFIRM_FIREWALL:-true}

    if [ "$confirm_firewall" = false ]; then
        log_info "跳过防火墙配置"
        return 0
    fi

    log_info "正在检测系统防火墙状态..."

    # 检查是否传入了端口
    if [ $# -eq 0 ]; then
        log_warn "未指定要开放的端口"
        return 1
    fi

    local ports=("$@")

    # 检测 firewalld
    if firewalld_is_active; then
        log_info "检测到 firewalld 防火墙正在运行，正在检查并开放端口..."
        local added_ports=0
        for port in "${ports[@]}"; do
            if ! run_as_root firewall-cmd --permanent --query-port="$port" 2>/dev/null; then
                log_info "正在添加端口 $port..."
                if run_as_root firewall-cmd --permanent --add-port="$port"; then
                    added_ports=$((added_ports + 1))
                else
                    log_error "添加端口 $port 失败"
                fi
            else
                log_debug "端口 $port 已开放"
            fi
        done

        if [ $added_ports -gt 0 ]; then
            if run_as_root firewall-cmd --reload; then
                log_info "firewalld 防火墙端口设置完成，共添加 $added_ports 个端口"
            else
                log_error "firewalld 重载失败"
            fi
        else
            log_info "所有端口已开放，无需更新"
        fi

    # 检测 ufw
    elif ufw_is_active; then
        log_info "检测到 ufw 防火墙正在运行，正在检查并开放端口..."
        local added_ports=0
        for port in "${ports[@]}"; do
            local port_num=$(echo "$port" | cut -d'/' -f1)
            local proto=$(echo "$port" | cut -d'/' -f2)
            # 检查端口是否已开放
            local ufw_status=$(run_as_root ufw status numbered 2>/dev/null || echo "")
            if ! echo "$ufw_status" | grep -q "$port_num/$proto"; then
                log_info "正在添加端口 $port..."
                if run_as_root ufw allow "$port"; then
                    added_ports=$((added_ports + 1))
                else
                    log_error "添加端口 $port 失败"
                fi
            else
                log_debug "端口 $port 已开放"
            fi
        done

        if [ $added_ports -gt 0 ]; then
            if run_as_root ufw reload; then
                log_info "ufw 防火墙端口设置完成，共添加 $added_ports 个端口"
            else
                log_error "ufw 重载失败"
            fi
        else
            log_info "所有端口已开放，无需更新"
        fi

    else
        log_info "未检测到已开启的 firewalld/ufw，跳过自动防火墙配置"
        log_info "如云厂商安全组或外部防火墙启用，请手动开放: ${ports[*]}"
    fi
}
# 主逻辑
# 检查并安装必要工具
check_dependencies

# 保存运行进程的配置文件
save_running_config() {
    local service_type=$1
    local source_dir=$2
    local config_file

    if [ "$service_type" = "frps" ]; then
        config_file="${FRPS_CONF_NAME}"
    else
        config_file="${FRPC_CONF_NAME}"
    fi

    # 检查源配置文件是否存在
    if [ -f "$source_dir/$config_file" ]; then
        log_message "INFO" "发现运行进程的配置文件: $source_dir/$config_file"

        # 拷贝配置文件到新安装目录
        if [ "$USE_SUDO" = true ]; then
            sudo cp "$source_dir/$config_file" "$INSTALL_DIR/"
        else
            cp "$source_dir/$config_file" "$INSTALL_DIR/"
        fi

        # 设置安全权限
        chmod 600 "$INSTALL_DIR/$config_file"

        log_message "INFO" "已将配置文件从 $source_dir 复制到 $INSTALL_DIR"
    else
        log_message "WARN" "警告: 未找到 $service_type 的配置文件在 $source_dir"
        log_message "INFO" "将使用默认配置创建新配置文件"
    fi
}

# 确保日志文件和目录存在
if [ ! -d "$(dirname "$LOG_FILE")" ]; then
    if [ "$USE_SUDO" = true ]; then
        sudo mkdir -p "$(dirname "$LOG_FILE")"
    else
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
fi
if [ ! -f "${LOG_FILE}" ]; then
    if [ "$USE_SUDO" = true ]; then
        sudo touch "${LOG_FILE}"
        sudo chown root:root "${LOG_FILE}"
        sudo chmod 644 "${LOG_FILE}"
    else
        touch "${LOG_FILE}"
        chown root:root "${LOG_FILE}" 2>/dev/null || true  # 尝试更改所有者，如果失败则忽略
        chmod 644 "${LOG_FILE}"
    fi
fi

# 检测是否有运行中的 frp 进程
check_running_processes() {
    local running_processes=()
    local has_frps_running=false
    local has_frpc_running=false
    local frps_process_dir=""
    local frpc_process_dir=""
    
    # 检查 frps 进程
    if pgrep -f frps > /dev/null; then
        local frps_pids=$(pgrep -f frps)
        for pid in $frps_pids; do
            local cmd=$(ps -p $pid -o args= 2>/dev/null)
            running_processes+=("PID: $pid, Command: $cmd")
            # 获取进程所在目录
            local process_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
            if [ -n "$process_path" ]; then
                frps_process_dir=$(dirname "$process_path")
            fi
        done
        has_frps_running=true
    fi
    
    # 检查 frpc 进程
    if pgrep -f frpc > /dev/null; then
        local frpc_pids=$(pgrep -f frpc)
        for pid in $frpc_pids; do
            local cmd=$(ps -p $pid -o args= 2>/dev/null)
            running_processes+=("PID: $pid, Command: $cmd")
            # 获取进程所在目录
            local process_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
            if [ -n "$process_path" ]; then
                frpc_process_dir=$(dirname "$process_path")
            fi
        done
        has_frpc_running=true
    fi
    
    # 将当前运行进程的目录保存到全局变量，用于后续复制二进制文件
    if [ -n "$frps_process_dir" ]; then
        CURRENT_FRPS_DIR="$frps_process_dir"
    fi
    if [ -n "$frpc_process_dir" ]; then
        CURRENT_FRPC_DIR="$frpc_process_dir"
    fi
    
    if [ ${#running_processes[@]} -gt 0 ]; then
        echo "检测到以下运行中的 FRP 进程："
        for process in "${running_processes[@]}"; do
            echo "  $process"
        done
        echo ""
        
        # 检查是否与安装路径冲突
        local has_conflict=false
        if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ] && [ "$frps_process_dir" != "$INSTALL_DIR" ] && [ "$frps_process_dir" != "$DEFAULT_INSTALL_DIR" ]; then
            has_conflict=true
        elif [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ] && [ "$frpc_process_dir" != "$INSTALL_DIR" ] && [ "$frpc_process_dir" != "$DEFAULT_INSTALL_DIR" ]; then
            has_conflict=true
        fi
        
        if [ "$has_conflict" = true ]; then
            echo "警告: 检测到运行中的 FRP 进程路径与安装路径不一致:"
            if [ -n "$frps_process_dir" ]; then
                echo "  frps 进程路径: $frps_process_dir"
            fi
            if [ -n "$frpc_process_dir" ]; then
                echo "  frpc 进程路径: $frpc_process_dir"
            fi
            echo "  当前安装路径: $INSTALL_DIR"
            
            if [ "$has_frps_running" = true ] && [ "$has_frpc_running" = true ]; then
                # 同时有frps和frpc运行
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 按q退出 [1/2/q]: " action
            elif [ "$has_frps_running" = true ]; then
                # 只有frps运行，询问是否安装frpc
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 继续安装frpc(进程是frps) 4) 按q退出 [1/2/3/q]: " action
            elif [ "$has_frpc_running" = true ]; then
                # 只有frpc运行，询问是否安装frps
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 继续安装frps(进程是frpc) 4) 按q退出 [1/2/3/q]: " action
            else
                read -p "请选择操作 - 1) 停止进程并卸载继续安装 2) 继续安装并迁移复用配置 3) 按q退出 [1/2/q]: " action
            fi
            
            case $action in
                1)
                    echo "正在停止运行中的 FRP 进程..."
                    sudo pkill -f frps 2>/dev/null
                    sudo pkill -f frpc 2>/dev/null
                    sleep 2  # 等待进程结束
                    
                    # 备份并迁移配置文件
                    if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ]; then
                        save_running_config "frps" "$frps_process_dir"
                    fi
                    if [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ]; then
                        save_running_config "frpc" "$frpc_process_dir"
                    fi
                    ;;
                2)
                    # 备份并迁移配置文件
                    if [ "$has_frps_running" = true ] && [ -n "$frps_process_dir" ]; then
                        save_running_config "frps" "$frps_process_dir"
                    fi
                    if [ "$has_frpc_running" = true ] && [ -n "$frpc_process_dir" ]; then
                        save_running_config "frpc" "$frpc_process_dir"
                    fi
                    ;;
                3)
                    # 如果运行的是frpc，提示安装frps；如果运行的是frps，提示安装frpc
                    if [ "$has_frpc_running" = true ]; then
                        echo "检测到当前运行的是frpc，将安装frps服务端..."
                        INSTALL_MODE="s"  # 设置为安装服务端
                    elif [ "$has_frps_running" = true ]; then
                        echo "检测到当前运行的是frps，将安装frpc客户端..."
                        INSTALL_MODE="c"  # 设置为安装客户端
                    else
                        # 如果都有或都没有，按原计划执行
                        echo "继续按原计划安装..."
                    fi
                    ;;
                q|Q)
                    echo "用户选择退出安装。"
                    exit 1
                    ;;
                *)
                    echo "用户选择退出安装。"
                    exit 1
                    ;;
            esac
        else
            echo "运行中的 FRP 进程路径与安装路径一致或为默认路径，继续安装..."
        fi
    fi
}

# 保存当前运行进程目录的全局变量
CURRENT_FRPS_DIR=""
CURRENT_FRPC_DIR=""

# 检查运行中的进程
check_running_processes

# 如果指定了安装模式则跳过交互，否则提示用户选择
if [ -z "$INSTALL_MODE" ]; then
    read -p "请选择要安装的服务 (s服务端/c客户端，默认c): " CHOICE
    CHOICE=${CHOICE:-c}
else
    CHOICE=$INSTALL_MODE
fi

case $CHOICE in
    s)
        FRP_BIN_NAME="frps"

        if [ ! -f "${INSTALL_DIR}/${FRP_BIN_NAME}" ]; then
            echo "正在下载并安装$FRP_BIN_NAME ..."
            copy_or_download_frp_binary "$FRP_BIN_NAME" "$CURRENT_FRPS_DIR"
            echo "$FRP_BIN_NAME 已安装到 ${INSTALL_DIR}"
        fi

        # 检查是否有已备份的配置文件，如果有则询问是否重新生成
        if [ -f "${INSTALL_DIR}/${FRPS_CONF_NAME}" ]; then
            echo "${FRPS_CONF_NAME} 配置文件已存在。"
            read -p "是否重新配置服务端？(y/N): " RECONFIG
            RECONFIG=${RECONFIG:-n}
            if [[ $RECONFIG =~ ^[Yy]$ ]]; then
                generate_default_config
            else
                echo "使用现有配置文件。"
            fi
        else
            echo "生成${FRPS_CONF_NAME}配置文件..."
            generate_default_config
        fi

        echo "正在创建或更新 $FRP_BIN_NAME Systemd 服务..."
        create_systemd_service

        # 启动服务（明确指定启动 frps）
        if [ -f "${INSTALL_DIR}/startup.sh" ]; then
            echo "正在启动 $FRP_BIN_NAME 服务..."
            if [ "$USE_SUDO" = true ]; then
                sudo "${INSTALL_DIR}/startup.sh" --server --install-dir "${INSTALL_DIR}"
            else
                "${INSTALL_DIR}/startup.sh" --server --install-dir "${INSTALL_DIR}"
            fi
        else
            echo "警告: 启动脚本 ${INSTALL_DIR}/startup.sh 不存在"
        fi

        echo "安装并启动 frps 完成。"
        SERVER_FIREWALL_PORTS=()
        while IFS= read -r port; do
            [ -n "$port" ] && SERVER_FIREWALL_PORTS+=("$port")
        done < <(get_server_firewall_ports "${INSTALL_DIR}/${FRPS_CONF_NAME}")
        setup_firewall_ports "${SERVER_FIREWALL_PORTS[@]}"
        print_server_install_summary
        ;;
    c)
        if [ ! -f "${INSTALL_DIR}/${FRPC_NAME}" ]; then
            echo "正在下载并安装 frpc..."
            copy_or_download_frp_binary "$FRPC_NAME" "$CURRENT_FRPC_DIR"
            echo "frpc 已安装到 ${INSTALL_DIR}"
        fi

        # 检查是否有已备份的配置文件，如果有则询问是否重新生成
        if [ -f "${INSTALL_DIR}/${FRPC_CONF_NAME}" ]; then
            echo "${FRPC_CONF_NAME} 配置文件已存在。"
            read -p "是否重新配置客户端？(y/N): " RECONFIG
            RECONFIG=${RECONFIG:-n}
            if [[ $RECONFIG =~ ^[Yy]$ ]]; then
                generate_default_client_config
            else
                echo "使用现有配置文件。"
            fi
        else
            echo "生成${FRPC_CONF_NAME}配置文件..."
            generate_default_client_config
        fi

        echo "正在创建或更新 frpc Systemd 服务..."
        create_systemd_client_service

        # 启动服务（明确指定启动 frpc）
        if [ -f "${INSTALL_DIR}/startup.sh" ]; then
            echo "正在启动 frpc 服务..."
            if [ "$USE_SUDO" = true ]; then
                sudo "${INSTALL_DIR}/startup.sh" --client --install-dir "${INSTALL_DIR}"
            else
                "${INSTALL_DIR}/startup.sh" --client --install-dir "${INSTALL_DIR}"
            fi
        else
            echo "警告: 启动脚本 ${INSTALL_DIR}/startup.sh 不存在"
        fi

        echo "安装并启动 frpc 完成。"
        print_client_install_summary
        ;;
    *)
        echo "无效的选择，退出安装。"
        exit 1
        ;;
esac

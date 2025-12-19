#!/bin/bash
# skywalking自动安装、配置

#=============================================================================
# 全局变量定义
#=============================================================================

# 脚本信息
SCRIPT_VERSION="1.0"
SCRIPT_NAME="$(basename "$0")"

# 路径变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skywalking.conf"

# 用户信息
CURRENT_USER="$(whoami)"
ORIGINAL_USER="$CURRENT_USER"
ORIGINAL_HOME="$HOME"

# 默认目录
DEFAULT_INSTALL_DIR="$HOME/skywalking"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_TMP_DIR="/tmp"

# 运行时变量（将在参数解析后设置）
INSTALL_DIR=""
DOWNLOAD_DIR=""
TMP_DIR="$DEFAULT_TMP_DIR"

# 默认版本配置
DEFAULT_SW_VERSION="10.3.0"
# 版本信息
SW_VERSION="$DEFAULT_SW_VERSION"
SW_AGENT_VERSION="9.5.0"
SPECIFIED_VERSION=""

# URL配置
SW_BASE_URL=""
SW_AGENT_BASE_URL=""
MIRROR_BASE_URL="https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking"

# 备用镜像源列表
BACKUP_MIRRORS=(
    "https://archive.apache.org/dist/skywalking"
    "https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking"
    "https://mirrors.cloud.tencent.com/apache/skywalking"
)

# 文件路径
SW_URL=""
SW_TGZ=""
SKYWALKING_AGENT_DOWNLOAD_URL=""
SKYWALKING_AGENT_TGZ=""

# Agent配置
SW_HOME=""
SKYWALKING_AGENT_BASE_DIR=""

# 服务端口
OAP_PORT=""
UI_SERVER_PORT=""

# 服务配置
COLLECTOR_BACKEND_SERVICE=""

# 应用目录
APP_BASE_DIR=""

# Java安装相关
AUTO_INSTALL_JAVA=false
JAVA_INSTALL_DIR="$HOME/java"
JDK_VERSION="17"
JDK_DOWNLOAD_URL=""


# 功能开关
UNINSTALL=false
FORCE=false
KEEP_DATA=false
AUTO_JAVA_INSTALL=false

# 自定义参数
CUSTOM_INSTALL_DIR=""
CUSTOM_DOWNLOAD_DIR=""

# 卸载相关
UNINSTALL_DIR=""

# 显示帮助信息
show_help() {
    cat << EOF
SkyWalking 安装/卸载脚本

用法: $0 [选项]

安装选项:
    -d, --dir DIR         指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    --download-dir DIR    指定下载目录 (默认: $HOME/Downloads)
    -f, --force           强制模式（强制安装/卸载）

卸载选项:
    -u, --uninstall       卸载 SkyWalking
    -k, --keep-data       卸载时保留数据目录

其他选项:
    -h, --help            显示此帮助信息
    -v, --version [VER]   显示版本信息或指定安装版本

示例:
    $0                                    # 使用默认目录安装最新版本
    $0 -d /opt/skywalking                 # 安装到指定目录
    $0 --dir ~/my-skywalking              # 安装到用户主目录
    $0 --download-dir /tmp/downloads      # 指定下载目录
    $0 -v 10.1.0                          # 安装指定版本
    $0 -f                                 # 强制模式安装
    $0 -u                                 # 卸载 SkyWalking
    $0 -u -d /opt/skywalking              # 卸载指定目录
    $0 -u --keep-data                     # 卸载但保留数据
    $0 -u -f                              # 强制完全删除

注意：
    - 默认安装最新可用版本
    - 指定版本不存在时自动使用最新版本

EOF
}

# 显示版本信息
show_version() {
    echo "SkyWalking 安装脚本 v$SCRIPT_VERSION"
}

# 初始化全局变量
init_global_variables() {
    # 从配置文件加载默认值
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 设置安装版本（自动检测最新版本）
    set_install_version
    
    # 设置端口配置
    OAP_PORT="${OAP_PORT:-11800}"
    UI_SERVER_PORT="${UI_SERVER_PORT:-8080}"
    
    # 设置服务配置
    COLLECTOR_BACKEND_SERVICE="${COLLECTOR_BACKEND_SERVICE:-127.0.0.1:11800}"
    
    # 设置应用目录
    APP_BASE_DIR="${APP_BASE_DIR:-/opt/apps}"
    
    # 设置临时目录
    TMP_DIR="${TMP_DIR:-$DEFAULT_TMP_DIR}"
}

# 缓存原始用户信息（用于提权后恢复）
cache_original_user() {
    ORIGINAL_USER="$(whoami)"
    ORIGINAL_HOME="$(eval echo ~$ORIGINAL_USER)"
    
    # 如果是 sudo 执行，获取原始用户
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
        ORIGINAL_HOME="$(eval echo ~$SUDO_USER)"
    fi
    
    log_debug "原始用户: $ORIGINAL_USER"
    log_debug "原始主目录: $ORIGINAL_HOME"
}

# 设置用户相关路径
set_user_paths() {
    # 如果是普通用户，使用用户主目录
    if [ "$EUID" -ne 0 ]; then
        DEFAULT_INSTALL_DIR="$HOME/skywalking"
        DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
    else
        # 如果是 root 用户，但原始用户不是 root，使用原始用户的目录
        if [ "$ORIGINAL_USER" != "root" ]; then
            DEFAULT_INSTALL_DIR="$ORIGINAL_HOME/skywalking"
            DEFAULT_DOWNLOAD_DIR="$ORIGINAL_HOME/Downloads"
        else
            DEFAULT_INSTALL_DIR="/opt/skywalking"
            DEFAULT_DOWNLOAD_DIR="/root/Downloads"
        fi
    fi
    
    log_debug "默认安装目录: $DEFAULT_INSTALL_DIR"
    log_debug "默认下载目录: $DEFAULT_DOWNLOAD_DIR"
}

# 调试日志函数
log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
    fi
}

# 清理版本号，移除多余的字符
clean_version() {
    local version="$1"
    # 移除引号、斜杠等特殊字符
    echo "$version" | sed 's/["\/]//g' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# 获取可用版本列表
get_available_versions() {
    local mirror_url="$1"
    local versions=""
    local temp_file=$(mktemp)
    
    log_debug "正在从镜像源获取可用版本列表..."
    
    # 使用通用HTTP请求函数获取页面内容
    if http_request "GET" "$mirror_url/" "$temp_file"; then
        # 提取版本号（假设版本号是目录名）
        # 更精确的正则，避免匹配到引号
        versions=$(grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/' "$temp_file" | sed 's/href="//g; s/"\/$//g' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r)
    fi
    
    rm -f "$temp_file"
    
    if [ -z "$versions" ]; then
        log_debug "无法从镜像源获取版本列表，使用默认版本"
        echo "10.2.0"
        return 1
    fi
    
    echo "$versions"
    return 0
}

# 通用HTTP请求函数
http_request() {
    local method="$1"
    local url="$2"
    local output_file="$3"
    
    if command -v curl >/dev/null 2>&1; then
        case "$method" in
            "HEAD")
                curl -s -f -I "$url" >/dev/null 2>&1
                ;;
            "GET")
                if [ -n "$output_file" ]; then
                    curl -s "$url" -o "$output_file"
                else
                    curl -s "$url"
                fi
                ;;
        esac
    elif command -v wget >/dev/null 2>&1; then
        case "$method" in
            "HEAD")
                wget -q --spider "$url" 2>/dev/null
                ;;
            "GET")
                if [ -n "$output_file" ]; then
                    wget -q -O "$output_file" "$url"
                else
                    wget -q -O - "$url"
                fi
                ;;
        esac
    else
        return 1
    fi
}

# 验证指定版本是否存在
verify_version_exists() {
    local version="$1"
    local mirror_url="$2"
    
    log_debug "验证版本 $version 是否存在..."
    
    if http_request "HEAD" "$mirror_url/$version/"; then
        return 0
    fi
    
    return 1
}

# 获取最新版本
get_latest_version() {
    local mirror_url="$1"
    local versions
    
    versions=$(get_available_versions "$mirror_url")
    if [ $? -ne 0 ] || [ -z "$versions" ]; then
        log_debug "无法获取版本列表，使用默认版本: $DEFAULT_SW_VERSION"
        echo "$DEFAULT_SW_VERSION"
        return 0
    fi
    
    # 返回最新版本（已排序）
    local latest_version=$(echo "$versions" | head -1)
    latest_version=$(clean_version "$latest_version")
    log_debug "检测到最新版本: $latest_version"
    echo "$latest_version"
}

# 设置安装版本
set_install_version() {
    local mirror_url="$MIRROR_BASE_URL"
    local version_found=false
    
    # 如果指定了版本
    if [ -n "$SPECIFIED_VERSION" ]; then
        SPECIFIED_VERSION=$(clean_version "$SPECIFIED_VERSION")
        log_info "检查指定版本: $SPECIFIED_VERSION"
        
        # 尝试从主镜像获取
        if verify_version_exists "$SPECIFIED_VERSION" "$mirror_url"; then
            SW_VERSION="$SPECIFIED_VERSION"
            SW_AGENT_VERSION="$SPECIFIED_VERSION"
            log_info "使用指定版本: $SW_VERSION"
            version_found=true
        else
            # 尝试从备用镜像获取
            for backup_mirror in "${BACKUP_MIRRORS[@]}"; do
                log_debug "尝试备用镜像: $backup_mirror"
                if verify_version_exists "$SPECIFIED_VERSION" "$backup_mirror"; then
                    SW_VERSION="$SPECIFIED_VERSION"
                    SW_AGENT_VERSION="$SPECIFIED_VERSION"
                    mirror_url="$backup_mirror"
                    log_info "使用指定版本: $SW_VERSION (镜像: $backup_mirror)"
                    version_found=true
                    break
                fi
            done
            
            if [ "$version_found" = false ]; then
                log_warn "指定版本 $SPECIFIED_VERSION 不存在，将使用最新版本"
                # 尝试从所有镜像获取最新版本
                for try_mirror in "$mirror_url" "${BACKUP_MIRRORS[@]}"; do
                    SW_VERSION=$(get_latest_version "$try_mirror")
                    if [ -n "$SW_VERSION" ]; then
                        SW_AGENT_VERSION="$SW_VERSION"
                        mirror_url="$try_mirror"
                        log_info "使用最新版本: $SW_VERSION (镜像: $mirror_url)"
                        version_found=true
                        break
                    fi
                done
                
                if [ "$version_found" = false ]; then
                    log_error "无法从任何镜像获取版本信息"
                    exit 1
                fi
            fi
        fi
    else
        # 获取最新版本
        log_info "正在获取最新版本信息..."
        
        # 尝试从所有镜像获取最新版本
        for try_mirror in "$mirror_url" "${BACKUP_MIRRORS[@]}"; do
            SW_VERSION=$(get_latest_version "$try_mirror")
            if [ -n "$SW_VERSION" ]; then
                SW_AGENT_VERSION="$SW_VERSION"
                mirror_url="$try_mirror"
                log_info "使用最新版本: $SW_VERSION (镜像: $mirror_url)"
                version_found=true
                break
            fi
        done
        
        if [ "$version_found" = false ]; then
            log_error "无法从任何镜像获取版本信息"
            exit 1
        fi
    fi
    
    # 再次清理版本号，确保格式正确
    SW_VERSION=$(clean_version "$SW_VERSION")
    SW_AGENT_VERSION=$(clean_version "$SW_AGENT_VERSION")
    
    # 设置URL配置
    SW_BASE_URL="$mirror_url"
    SW_AGENT_BASE_URL="$mirror_url/java-agent"
}

# 验证安装目录
validate_install_dir() {
    # 检查目录是否为空
    if [ -z "$SW_HOME" ]; then
        log_error "安装目录不能为空"
        return 1
    fi
    
    # 检查路径中的非法字符
    if [[ "$SW_HOME" =~ [^a-zA-Z0-9_\-/\.~] ]]; then
        log_error "安装目录包含非法字符: $SW_HOME"
        return 1
    fi
    
    # 检查是否为绝对路径
    if [[ ! "$SW_HOME" = /* ]] && [[ ! "$SW_HOME" = ~* ]]; then
        log_warn "建议使用绝对路径: $SW_HOME"
    fi
    
    # 检查目录是否已存在且非空
    if [ -d "$SW_HOME" ] && [ "$(ls -A "$SW_HOME/webapp/*.jar" 2>/dev/null)" ]; then
        if [ "$FORCE" = true ]; then
            log_warn "强制模式：将覆盖现有安装目录: $SW_HOME"
        else
            read -p "安装目录已存在且非空: $SW_HOME 可能会覆盖现有文件,是否继续?(y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "安装已取消"
                exit 0
            fi
        fi
    fi
    
    return 0
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定目录"
                    exit 1
                fi
                CUSTOM_INSTALL_DIR="$2"
                shift 2
                ;;
            --download-dir)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定目录"
                    exit 1
                fi
                CUSTOM_DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                    SPECIFIED_VERSION="$2"
                    shift 2
                else
                    show_version
                    exit 0
                fi
                ;;
            -u|--uninstall)
                UNINSTALL=true
                shift
                ;;
            -k|--keep-data)
                KEEP_DATA=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检查是否需要提权
check_privileges() {
    local target_dir="$1"
    local parent_dir="$(dirname "$target_dir")"
    
    # 如果已经是 root 用户，不需要提权
    if [ "$EUID" -eq 0 ]; then
        log_debug "已是 root 用户，无需提权"
        return 0
    fi
    
    # 检查父目录是否存在
    if [ ! -d "$parent_dir" ]; then
        # 检查能否创建父目录
        if ! mkdir -p "$parent_dir" 2>/dev/null; then
            log_warn "无法创建目录 $parent_dir，需要提权"
            return 1
        fi
        # 创建成功后删除，避免留下空目录
        rmdir "$parent_dir" 2>/dev/null
        return 0
    fi
    
    # 检查父目录写权限
    if [ ! -w "$parent_dir" ]; then
        log_warn "目录 $parent_dir 无写权限，需要提权"
        return 1
    fi
    
    log_debug "权限检查通过，无需提权"
    return 0
}

# 自动提权重新执行脚本
auto_sudo() {
    local install_dir="$1"
    
    log_info "需要管理员权限，正在自动提权..."
    
    # 构建新的命令行参数
    local sudo_args=()
    
    # 安装目录参数
    if [ -n "$CUSTOM_INSTALL_DIR" ]; then
        sudo_args+=("-d" "$CUSTOM_INSTALL_DIR")
    fi
    
    # 下载目录参数（确保传递给提权后的脚本）
    if [ -n "$CUSTOM_DOWNLOAD_DIR" ]; then
        sudo_args+=("--download-dir" "$CUSTOM_DOWNLOAD_DIR")
    fi
    
    # 其他参数
    if [ "$FORCE" = true ]; then
        sudo_args+=("-f")
    fi
    
    # 如果是卸载模式
    if [ "$UNINSTALL" = true ]; then
        sudo_args+=("-u")
    fi
    
    if [ "$KEEP_DATA" = true ]; then
        sudo_args+=("-k")
    fi
    
    # 环境变量保持
    local sudo_env=(
        "ORIGINAL_USER=$ORIGINAL_USER"
        "ORIGINAL_HOME=$ORIGINAL_HOME"
        "DEBUG=${DEBUG:-false}"
    )
    
    # 使用 sudo 重新执行脚本
    if command -v sudo >/dev/null 2>&1; then
        log_debug "执行命令: sudo -E ${sudo_env[*]} $0 ${sudo_args[*]}"
        exec sudo -E "${sudo_env[@]}" "$0" "${sudo_args[@]}"
    else
        log_error "sudo 命令不可用，请手动使用 root 权限运行"
        exit 1
    fi
}

# 设置路径和URL
setup_paths_and_urls() {
    # 设置安装目录
    if [ -n "$CUSTOM_INSTALL_DIR" ]; then
        INSTALL_DIR=$(eval echo "$CUSTOM_INSTALL_DIR")
    else
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    fi
    
    # 设置下载目录（优先使用原始用户的下载目录）
    if [ -n "$CUSTOM_DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR=$(eval echo "$CUSTOM_DOWNLOAD_DIR")
    else
        # 如果是提权执行，优先使用原始用户的下载目录
        if [ "$EUID" -eq 0 ] && [ "$ORIGINAL_USER" != "root" ]; then
            DOWNLOAD_DIR="$ORIGINAL_HOME/Downloads"
        else
            DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
        fi
    fi
    
    # 转换为绝对路径
    INSTALL_DIR=$(realpath "$INSTALL_DIR" 2>/dev/null || echo "$INSTALL_DIR")
    DOWNLOAD_DIR=$(realpath "$DOWNLOAD_DIR" 2>/dev/null || echo "$DOWNLOAD_DIR")
    
    # 设置SkyWalking安装目录
    SW_HOME="$INSTALL_DIR"
    SKYWALKING_AGENT_BASE_DIR="$SW_HOME/skywalking-agent"
    
    # 设置下载URL（阿里云镜像使用-bin.tar.gz格式）
    #https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking/10.3.0/apache-skywalking-apm-10.3.0-bin.tar.gz
    SW_URL="$SW_BASE_URL/$SW_VERSION/apache-skywalking-apm-$SW_VERSION-bin.tar.gz"
    # 从SW_URL中提取文件名
    SW_TGZ="$DOWNLOAD_DIR/$(basename "$SW_URL")"
    # https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking/java-agent/9.5.0/apache-skywalking-java-agent-9.5.0.tgz
    SKYWALKING_AGENT_DOWNLOAD_URL="$SW_AGENT_BASE_URL/$SW_AGENT_VERSION/apache-skywalking-java-agent-$SW_AGENT_VERSION.tgz"
    # 从SKYWALKING_AGENT_DOWNLOAD_URL中提取文件名
    SKYWALKING_AGENT_TGZ="$DOWNLOAD_DIR/$(basename "$SKYWALKING_AGENT_DOWNLOAD_URL")"
    
    log_debug "安装目录: $SW_HOME"
    log_debug "下载目录: $DOWNLOAD_DIR"
    log_debug "SkyWalking URL: $SW_URL"
    log_debug "Agent URL: $SKYWALKING_AGENT_DOWNLOAD_URL"
}

# 初始化脚本
init_script() {
    # 初始化全局变量
    init_global_variables
    
    # 缓存原始用户信息
    cache_original_user
    
    # 设置用户相关路径
    set_user_paths
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 设置路径和URL
    setup_paths_and_urls
    
    # 检查是否需要提权
    if ! check_privileges "$SW_HOME"; then
        auto_sudo "$SW_HOME"
    fi
}

# 定义日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# 验证配置
validate_config() {
    if [ -z "$SW_VERSION" ] || [ -z "$SW_AGENT_VERSION" ]; then
        log_error "版本配置缺失"
        exit 1
    fi
    
    if [ "$SW_VERSION" != "$SW_AGENT_VERSION" ]; then
        log_warn "SkyWalking版本($SW_VERSION)与Agent版本($SW_AGENT_VERSION)不一致"
    fi
}

# 检查操作系统
function check_os () {
  if [ -f /etc/redhat-release ]; then
    OS="CentOS"
  elif [ -f /etc/debian_version ]; then
    OS="Deepin"
  elif [ "$(uname -s)" = "Darwin" ]; then
    OS="Darwin"
  else
    echo "不支持的操作系统"
    exit 1
  fi
}

# 检查网络连接
check_network() {
    if ! ping -c 1 archive.apache.org >/dev/null 2>&1; then
        log_error "无法连接到下载服务器"
        exit 1
    fi
}

# 检测可用的下载工具
detect_download_tool() {
    if command -v aria2c >/dev/null 2>&1; then
        echo "aria2c"
    elif command -v axel >/dev/null 2>&1; then
        echo "axel"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        echo "curl"
    fi
}

# 使用 aria2c 多线程下载
download_with_aria2c() {
    local url="$1"
    local output="$2"
    local max_connections=${3:-16}
    
    log_info "使用 aria2c 多线程下载..."
    
    # 确保使用绝对路径
    output=$(realpath "$output" 2>/dev/null || echo "$output")
    local output_dir=$(dirname "$output")
    local output_file=$(basename "$output")
    
    # 创建目录（如果不存在）
    mkdir -p "$output_dir"
    
    # 断点续传参数
    local aria2c_opts=(
        "-c"  # 断点续传
        "-x $max_connections"  # 最大连接数
        "-s $max_connections"  # 分片数
        "-k 1M"  # 分片大小
        "--file-allocation=none"  # 不预分配空间
        "--max-tries=5"  # 最大重试次数
        "--retry-wait=10"  # 重试等待时间
        "--timeout=60"  # 超时时间
        "--show-console-readout=true"  # 显示进度
        "--summary-interval=5"  # 进度更新间隔
        "-d" "$output_dir"  # 指定下载目录
        "-o" "$output_file"  # 指定文件名
    )
    
    if aria2c "${aria2c_opts[@]}" "$url"; then
        return 0
    else
        return 1
    fi
}

# 使用 axel 多线程下载
download_with_axel() {
    local url="$1"
    local output="$2"
    local num_connections=${3:-16}
    
    log_info "使用 axel 多线程下载..."
    
    # 确保使用绝对路径
    output=$(realpath "$output" 2>/dev/null || echo "$output")
    local output_dir=$(dirname "$output")
    
    # 创建目录（如果不存在）
    mkdir -p "$output_dir"
    
    if axel -n "$num_connections" -a "$url" -o "$output"; then
        return 0
    else
        return 1
    fi
}

# 使用 wget 下载（支持断点续传）
download_with_wget() {
    local url="$1"
    local output="$2"
    
    log_info "使用 wget 下载..."
    
    # 确保目录存在
    local output_dir=$(dirname "$output")
    mkdir -p "$output_dir"
    
    local wget_opts=(
        "-c"  # 断点续传
        "--progress=bar:force"  # 显示进度条
        "--tries=5"  # 重试次数
        "--timeout=60"  # 超时时间
        "--retry-connrefused"  # 连接拒绝时重试
        "--waitretry=10"  # 重试等待时间
    )
    
    if wget "${wget_opts[@]}" "$url" -O "$output"; then
        return 0
    else
        return 1
    fi
}

# 使用 curl 下载（支持断点续传）
download_with_curl() {
    local url="$1"
    local output="$2"
    
    log_info "使用 curl 下载..."
    
    # 确保目录存在
    local output_dir=$(dirname "$output")
    mkdir -p "$output_dir"
    
    local curl_opts=(
        "-L"  # 跟随重定向
        "-C" "-"  # 断点续传
        "--progress-bar"  # 进度条
        "--retry" "5"  # 重试次数
        "--retry-delay" "10"  # 重试延迟
        "--connect-timeout" "60"  # 连接超时
        "--max-time" "3600"  # 总超时时间
    )
    
    if curl "${curl_opts[@]}" "$url" -o "$output"; then
        return 0
    else
        return 1
    fi
}

# 通用下载函数
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=${3:-3}
    local retry_count=0
    
    # 检测下载工具
    local download_tool=$(detect_download_tool)
    log_info "检测到下载工具: $download_tool"
    
    while [ $retry_count -lt $max_retries ]; do
        log_info "尝试下载 (第 $((retry_count + 1))/$max_retries 次)..."
        
        case "$download_tool" in
            "aria2c")
                if download_with_aria2c "$url" "$output"; then
                    return 0
                fi
                ;;
            "axel")
                if download_with_axel "$url" "$output"; then
                    return 0
                fi
                ;;
            "wget")
                if download_with_wget "$url" "$output"; then
                    return 0
                fi
                ;;
            "curl")
                if download_with_curl "$url" "$output"; then
                    return 0
                fi
                ;;
        esac
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_warn "下载失败，等待 $((retry_count * 10)) 秒后重试..."
            sleep $((retry_count * 10))
        fi
    done
    
    log_error "下载失败，已重试 $max_retries 次"
    return 1
}

# 通用镜像源切换函数
try_download_from_mirrors() {
    local url_pattern="$1"
    local output="$2"
    local version="$3"
    local update_globals="$4"
    
    # 先尝试主镜像
    if download_file "$url_pattern" "$output"; then
        return 0
    fi
    
    log_warn "主镜像下载失败，尝试备用镜像..."
    
    # 尝试备用镜像
    for backup_mirror in "${BACKUP_MIRRORS[@]}"; do
        local backup_url
        case "$url_pattern" in
            *apache-skywalking-apm*)
                if [[ "$backup_mirror" == *"archive.apache.org"* ]] || [[ "$backup_mirror" == *"aliyuncs"* ]]; then
                    backup_url="$backup_mirror/$version/apache-skywalking-apm-$version-bin.tar.gz"
                else
                    backup_url="$backup_mirror/$version/apache-skywalking-apm-$version-bin.tar.gz"
                fi
                ;;
            *apache-skywalking-java-agent*)
                backup_url="$backup_mirror/java-agent/$version/apache-skywalking-java-agent-$version.tgz"
                ;;
            *)
                backup_url="$backup_mirror/$version/$(basename "$url_pattern")"
                ;;
        esac
        
        log_info "尝试备用镜像: $backup_mirror"
        if download_file "$backup_url" "$output"; then
            log_info "使用备用镜像下载成功: $backup_mirror"
            
            # 更新全局URL变量（如果需要）
            if [ "$update_globals" = "true" ]; then
                SW_BASE_URL="$backup_mirror"
                SW_AGENT_BASE_URL="$backup_mirror/java-agent"
            fi
            
            return 0
        fi
    done
    
    log_error "所有镜像都无法下载"
    return 1
}

# 带镜像源切换的下载函数（保持向后兼容）
download_with_mirror_fallback() {
    try_download_from_mirrors "$1" "$2" "$3" "true"
}

# 验证下载文件完整性
verify_download() {
    local file="$1"
    local expected_pattern="$2"
    
    if [ ! -f "$file" ]; then
        log_error "下载文件不存在: $file"
        return 1
    fi
    
    if [ ! -s "$file" ]; then
        log_error "下载文件为空: $file"
        return 1
    fi
    
    # 对于 tar.gz 文件，尝试解压测试
    if [[ "$file" == *.tar.gz ]] || [[ "$file" == *.tgz ]]; then
        log_info "验证压缩文件完整性..."
        if tar -tzf "$file" >/dev/null 2>&1; then
            log_info "压缩文件验证通过"
            return 0
        else
            log_error "压缩文件损坏或格式错误"
            return 1
        fi
    fi
    
    # 检查文件大小（至少 1MB）
    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    if [ "$file_size" -lt 1048576 ]; then
        log_error "文件大小异常: $file_size 字节"
        return 1
    fi
    
    log_info "文件验证通过 (大小: $file_size 字节)"
    return 0
}

# 下载 SkyWalking
function download_sw () {
    log_info "开始下载 SkyWalking..."
    
    # 创建下载目录
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p "$DOWNLOAD_DIR" || {
            log_error "创建下载目录失败: $DOWNLOAD_DIR"
            exit 1
        }
    fi
    
    # 检查文件是否已存在且完整
    if [ -f "$SW_TGZ" ]; then
        if verify_download "$SW_TGZ"; then
            log_info "SkyWalking 压缩包已存在且完整，跳过下载"
            return 0
        else
            log_warn "现有压缩包损坏，重新下载"
            rm -f "$SW_TGZ"
        fi
    fi
    
    # 下载文件
    log_info "正在下载 SkyWalking $SW_VERSION..."
    log_info "下载地址: $SW_URL"
    log_info "保存位置: $SW_TGZ"
    
    if ! try_download_from_mirrors "$SW_URL" "$SW_TGZ" "$SW_VERSION" "true"; then
        log_error "下载 SkyWalking 失败"
        exit 1
    fi
    
    # 验证下载文件
    if ! verify_download "$SW_TGZ"; then
        log_error "下载文件验证失败"
        rm -f "$SW_TGZ"
        exit 1
    fi
    
    log_info "SkyWalking 下载完成"
}

# 解压 SkyWalking
function extract_sw () {
    log_info "开始解压 SkyWalking..."
    
    # 创建安装目录
    if [ ! -d "$SW_HOME" ]; then
        mkdir -p "$SW_HOME" || {
            log_error "创建安装目录失败: $SW_HOME"
            exit 1
        }
    fi
    
    # 检查是否已经解压
    if [ -d "$SW_HOME/bin" ] && [ -f "$SW_HOME/bin/oapService.sh" ]; then
        log_info "SkyWalking 已解压，跳过解压步骤"
        return 0
    fi
    
    # 备份现有目录（如果存在）
    if [ -d "$SW_HOME" ] && [ "$(ls -A $SW_HOME 2>/dev/null)" ]; then
        backup_dir="${SW_HOME}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "备份现有安装到: $backup_dir"
        mv "$SW_HOME" "$backup_dir" || {
            log_error "备份现有安装失败"
            exit 1
        }
        mkdir -p "$SW_HOME"
    fi
    
    # 解压文件
    log_info "正在解压 SkyWalking..."
    if ! tar -xzf "$SW_TGZ" -C "$SW_HOME" --strip-components=1; then
        log_error "解压失败"
        exit 1
    fi
    
    # 验证解压结果
    if [ ! -d "$SW_HOME/bin" ] || [ ! -f "$SW_HOME/bin/oapService.sh" ]; then
        log_error "解压失败，未找到关键文件"
        exit 1
    fi
    
    # 设置权限
    chmod +x "$SW_HOME/bin"/*.sh
    
    log_info "SkyWalking 解压完成"
}

# 备份配置文件
backup_config() {
    local config_file=$1
    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "已备份配置文件: $config_file"
    fi
}

# 配置 SkyWalking
function configure_sw () {
    log_info "开始配置 SkyWalking..."
    
    # 创建 webapp 目录（如果不存在）
    mkdir -p "$SW_HOME/webapp"
    
    # 配置 collector
    collector_config="$SW_HOME/config/application.yml"
    if [ -f "$collector_config" ]; then
        backup_config "$collector_config"
        
        # 使用兼容的sed命令格式
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i "" "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
        else
            sed -i "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
        fi
        log_info "已配置 collector 后端服务: $COLLECTOR_BACKEND_SERVICE"
    else
        log_warn "collector 配置文件不存在: $collector_config"
    fi

    # 配置 UI
    ui_config="$SW_HOME/webapp/application.yml"
    if [ -f "$ui_config" ]; then
        backup_config "$ui_config"
        
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i "" "s/serverPort:.*/serverPort: $UI_SERVER_PORT/" "$ui_config"
        else
            sed -i "s/serverPort:.*/serverPort: $UI_SERVER_PORT/" "$ui_config"
        fi
        log_info "已配置 UI 端口: $UI_SERVER_PORT"
    else
        log_warn "UI 配置文件不存在: $ui_config"
    fi

    # 配置 agent
    agent_config="$SW_HOME/agent/config/agent.config"
    if [ -f "$agent_config" ]; then
        backup_config "$agent_config"
        
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i "" "s/collector.backend_service=.*/collector.backend_service=$COLLECTOR_BACKEND_SERVICE/" "$agent_config"
        else
            sed -i "s/collector.backend_service=.*/collector.backend_service=$COLLECTOR_BACKEND_SERVICE/" "$agent_config"
        fi
        log_info "已配置 agent collector: $COLLECTOR_BACKEND_SERVICE"
    else
        log_warn "agent 配置文件不存在: $agent_config"
    fi
    
    log_info "SkyWalking 配置完成"
}

# 自动检测安装SkyWalking Agent
configure_skywalking_agent() {
    # 检查skywalking-agent目录是否存在且非空
    if [ -d "$SKYWALKING_AGENT_BASE_DIR" ]; then
      if [ "$(ls -A $SKYWALKING_AGENT_BASE_DIR)" ]; then
        log_info "SkyWalking Agent已存在且非空，跳过下载和安装"
        
        # 配置应用的SkyWalking Agent
        if [ -d "$APP_BASE_DIR" ]; then
          # 排除backup目录
          for app_dir in $(find $APP_BASE_DIR -mindepth 1 -maxdepth 1 -type d ! -name "backup"); do
            app_name=$(basename $app_dir)
            target_agent_dir="$SW_HOME/$app_name"
            
            # 如果目标目录已存在，则跳过
            if [ -d "$target_agent_dir" ]; then
              log_warn "应用 $app_name 的 agent 目录已存在，跳过创建"
              continue
            fi
            
            # 创建符号链接
            echo "为应用 $app_name 创建SkyWalking Agent链接..."
            ln -s $SKYWALKING_AGENT_BASE_DIR $target_agent_dir
            
            # 创建agent配置文件
            agent_config_dir="$target_agent_dir/config"
            mkdir -p $agent_config_dir
            agent_config_file="$agent_config_dir/agent.config"
            
            # 拷贝默认配置
            if [ ! -f "$agent_config_file" ]; then
              log_info "创建agent配置文件: $agent_config_file"
              cp $SKYWALKING_AGENT_BASE_DIR/config/agent.config $agent_config_file
            fi
            
            # 修改 agent.config
            if [ -f "$agent_config_file" ]; then
              # 使用兼容的sed命令格式
              if [[ "$(uname -s)" == "Darwin" ]]; then
                # macOS需要额外参数
                sed -i "" "s/agent.service_name=.*/agent.service_name=${app_name}/" "$agent_config_file"
              else
                sed -i "s/agent.service_name=.*/agent.service_name=${app_name}/" "$agent_config_file"
              fi
              log_info "已设置 agent.service_name=$app_name"
            else
              log_warn "配置文件不存在: $agent_config_file"
            fi
            
            # 输出JVM参数
            jvm_param="-javaagent:$target_agent_dir/skywalking-agent.jar -Dskywalking.agent.service_name=$app_name -Dskywalking.collector.backend_service=localhost:11800"
            echo "📌 JVM 参数（$app_name）:"
            echo "$jvm_param"
          done
        fi
        
        return 0
      fi
    fi
    
    echo "正在下载并安装SkyWalking Agent..."
    # 确保目标目录存在
    mkdir -p "$SKYWALKING_AGENT_BASE_DIR"
    
    if [ ! -f "$SKYWALKING_AGENT_TGZ" ]; then
      log_info "正在下载 SkyWalking Agent..."
      log_info "下载地址: $SKYWALKING_AGENT_DOWNLOAD_URL"
      log_info "保存位置: $SKYWALKING_AGENT_TGZ"
      
      if ! try_download_from_mirrors "$SKYWALKING_AGENT_DOWNLOAD_URL" "$SKYWALKING_AGENT_TGZ" "$SKYWALKING_AGENT_VERSION" "false"; then
        log_error "下载 SkyWalking Agent 失败"
        exit 1
      fi
      
      # 验证下载文件
      if ! verify_download "$SKYWALKING_AGENT_TGZ"; then
        log_error "Agent 下载文件验证失败"
        rm -f "$SKYWALKING_AGENT_TGZ"
        exit 1
      fi
    fi
    
    # 检查是否已经解压
    if [ ! -d "$SKYWALKING_AGENT_BASE_DIR/apache-skywalking-java-agent-$SKYWALKING_AGENT_VERSION" ]; then
      tar -xzf $SKYWALKING_AGENT_TGZ -C $SKYWALKING_AGENT_BASE_DIR --strip-components=1
    fi
    
    # 删除压缩包
    rm -f $SKYWALKING_AGENT_TGZ
}

# 检查服务状态
check_service_status() {
    local service_name=$1
    local port=$2
    local max_attempts=30
    local attempt=1
    
    log_info "检查 $service_name 服务状态..."
    
    while [ $attempt -le $max_attempts ]; do
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            log_info "$service_name 服务已启动 (端口: $port)"
            return 0
        fi
        
        if [ $attempt -eq 1 ]; then
            log_info "等待 $service_name 服务启动..."
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log_error "$service_name 服务启动超时"
    return 1
}

# 启动 SkyWalking
function start_sw () {
    log_info "开始启动 SkyWalking 服务..."
    
    # 检查目录是否存在
    if [ ! -d "$SW_HOME/bin" ]; then
        log_error "SkyWalking安装目录不存在: $SW_HOME/bin"
        exit 1
    fi
    
    # 检查脚本文件是否存在且可执行
    if [ ! -f "$SW_HOME/bin/oapService.sh" ] || [ ! -x "$SW_HOME/bin/oapService.sh" ]; then
        log_error "oapService.sh 不存在或不可执行"
        exit 1
    fi
    
    if [ ! -f "$SW_HOME/bin/webappService.sh" ] || [ ! -x "$SW_HOME/bin/webappService.sh" ]; then
        log_error "webappService.sh 不存在或不可执行"
        exit 1
    fi
    
    # 进入bin目录
    cd "$SW_HOME/bin" || {
        log_error "无法进入目录: $SW_HOME/bin"
        exit 1
    }
    
    # 检查端口是否已被占用
    if netstat -tlnp 2>/dev/null | grep -q ":$OAP_PORT "; then
        log_warn "端口 $OAP_PORT 已被占用，停止现有服务..."
        "$SCRIPT_DIR/stop.sh"
        sleep 3
    fi
    
    # 启动 OAP 服务
    log_info "启动 SkyWalking OAP 服务..."
    nohup ./oapService.sh > "$SW_HOME/logs/oap-startup.log" 2>&1 &
    OAP_PID=$!
    
    # 等待 OAP 服务启动
    if ! check_service_status "OAP" "$OAP_PORT"; then
        log_error "OAP 服务启动失败"
        tail -20 "$SW_HOME/logs/oap-startup.log"
        exit 1
    fi
    
    # 启动 UI 服务
    log_info "启动 SkyWalking UI 服务..."
    nohup ./webappService.sh > "$SW_HOME/logs/webapp-startup.log" 2>&1 &
    UI_PID=$!
    
    # 等待 UI 服务启动
    if ! check_service_status "UI" "$UI_SERVER_PORT"; then
        log_error "UI 服务启动失败"
        tail -20 "$SW_HOME/logs/webapp-startup.log"
        exit 1
    fi
    
    log_info "SkyWalking 服务启动成功"
    log_info "OAP 服务: http://localhost:$OAP_PORT"
    log_info "UI 服务: http://localhost:$UI_SERVER_PORT"
}

# 检查日志文件
function check_logs() {
    log_info "检查日志文件..."
    
    # 创建日志目录（如果不存在）
    mkdir -p "$SW_HOME/logs"
    
    # 等待日志文件生成
    sleep 5
    
    # 检查OAP日志
    local oap_log="$SW_HOME/logs/skywalking-oap-server.log"
    if [ -f "$oap_log" ]; then
        log_info "SkyWalking OAP日志路径: $oap_log"
        
        # 显示最近的日志
        if [ -s "$oap_log" ]; then
            log_info "最近的 OAP 日志:"
            tail -10 "$oap_log"
        fi
    else
        log_warn "SkyWalking OAP日志文件未找到"
    fi
    
    # 检查WebApp日志
    local webapp_log="$SW_HOME/logs/skywalking-webapp.log"
    if [ -f "$webapp_log" ]; then
        log_info "SkyWalking WebApp日志路径: $webapp_log"
        
        # 显示最近的日志
        if [ -s "$webapp_log" ]; then
            log_info "最近的 WebApp 日志:"
            tail -10 "$webapp_log"
        fi
    else
        log_warn "SkyWalking WebApp日志文件未找到"
    fi
}

# 检查权限
check_permissions() {
    local install_dir="$1"
    local parent_dir="$(dirname "$install_dir")"
    
    # 检查临时目录权限
    if [ ! -w "$TMP_DIR" ]; then
        log_error "没有权限在临时目录 $TMP_DIR 中写入文件"
        exit 1
    fi
    
    # 如果已经是 root 用户，跳过权限检查
    if [ "$EUID" -eq 0 ]; then
        log_info "以 root 权限运行"
        return 0
    fi
    
    # 检查安装目录权限
    if [ -d "$install_dir" ]; then
        if [ ! -w "$install_dir" ]; then
            log_error "没有权限写入安装目录: $install_dir"
            exit 1
        fi
    else
        if [ ! -w "$parent_dir" ]; then
            log_error "没有权限在 $parent_dir 目录下创建文件夹"
            exit 1
        fi
    fi
    
    log_info "权限检查通过"
}

# 检查系统资源
check_system_resources() {
    # 检查可用磁盘空间（至少需要 2GB）
    local available_space=$(df "$(dirname "$SW_HOME")" | awk 'NR==2 {print $4}')
    local required_space=2097152  # 2GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_error "磁盘空间不足，至少需要 2GB 可用空间"
        exit 1
    fi
    
    # 检查可用内存（至少需要 1GB）
    if command -v free >/dev/null 2>&1; then
        local available_memory=$(free -m | awk 'NR==2{print $7}')
        if [ "$available_memory" -lt 1024 ]; then
            log_warn "可用内存不足 1GB，可能影响 SkyWalking 运行性能"
        fi
    fi
    
    # 检查 CPU 核心数
    if command -v nproc >/dev/null 2>&1; then
        local cpu_cores=$(nproc)
        log_info "系统 CPU 核心数: $cpu_cores"
        if [ "$cpu_cores" -lt 2 ]; then
            log_warn "CPU 核心数较少，可能影响 SkyWalking 性能"
        fi
    fi
}

# 检查端口占用
check_port_availability() {
    local ports=("$OAP_PORT" "$UI_SERVER_PORT")
    
    for port in "${ports[@]}"; do
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            local pid=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1)
            log_warn "端口 $port 已被占用 (PID: $pid)"
            read -p "是否停止占用进程并继续? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    kill -15 "$pid"
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid"
                    fi
                    log_info "已停止占用端口的进程"
                fi
            else
                log_info "安装已取消"
                exit 0
            fi
        fi
    done
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION="$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        OS_VERSION="$(cat /etc/debian_version)"
    elif [ "$(uname -s)" = "Darwin" ]; then
        OS="macos"
        OS_VERSION="$(sw_vers -productVersion)"
    else
        OS="unknown"
        OS_VERSION=""
    fi
    
    log_debug "检测到操作系统: $OS $OS_VERSION"
}

# 安装 JDK 17
install_jdk17() {
    log_info "开始安装 JDK 17..."
    
    detect_os
    
    case "$OS" in
        ubuntu|debian)
            log_info "使用 apt 安装 OpenJDK 17..."
            if command -v sudo >/dev/null 2>&1 && [ "$EUID" -ne 0 ]; then
                sudo apt-get update
                sudo apt-get install -y openjdk-17-jdk
            else
                apt-get update
                apt-get install -y openjdk-17-jdk
            fi
            ;;
        centos|rhel|fedora)
            if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
                if command -v dnf >/dev/null 2>&1; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
            else
                PKG_MANAGER="dnf"
            fi
            
            log_info "使用 $PKG_MANAGER 安装 OpenJDK 17..."
            if command -v sudo >/dev/null 2>&1 && [ "$EUID" -ne 0 ]; then
                sudo $PKG_MANAGER install -y java-17-openjdk-devel
            else
                $PKG_MANAGER install -y java-17-openjdk-devel
            fi
            ;;
        macos)
            log_info "macOS 系统建议使用 Homebrew 安装: brew install openjdk@17"
            log_error "请手动安装 JDK 17 后重新运行脚本"
            return 1
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            log_info "请手动安装 JDK 17 后重新运行脚本"
            return 1
            ;;
    esac
    
    # 验证安装
    if command -v java >/dev/null 2>&1; then
        local java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | sed 's/^1\.//' | cut -d'.' -f1)
        if [ "$java_version" -ge 17 ]; then
            log_info "JDK 17 安装成功: $(java -version 2>&1 | head -1)"
            return 0
        fi
    fi
    
    log_error "JDK 17 安装失败"
    return 1
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    # 检查基本命令
    for cmd in wget tar sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 检查网络工具（任选其一）
    local net_tool_found=false
    for cmd in netstat ss lsof; do
        if command -v "$cmd" >/dev/null 2>&1; then
            net_tool_found=true
            break
        fi
    done
    
    if [ "$net_tool_found" = false ]; then
        missing_deps+=("netstat 或 ss 或 lsof")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "缺少依赖命令: ${missing_deps[*]}"
        
        # 提供安装建议
        if command -v apt-get >/dev/null 2>&1; then
            log_info "Ubuntu/Debian 系统，请运行: sudo apt-get install ${missing_deps[*]}"
        elif command -v yum >/dev/null 2>&1; then
            log_info "CentOS/RHEL 系统，请运行: sudo yum install ${missing_deps[*]}"
        elif command -v dnf >/dev/null 2>&1; then
            log_info "Fedora 系统，请运行: sudo dnf install ${missing_deps[*]}"
        fi
        
        exit 1
    fi
    
    # 检查 Java
    if ! command -v java >/dev/null 2>&1; then
        if [ "$FORCE" = true ]; then
            log_error "强制模式但未找到 Java，SkyWalking 需要 Java 11 或更高版本"
            exit 1
        fi
        
        log_warn "未找到 Java，SkyWalking 需要 Java 11 或更高版本"
        echo
        read -p "是否自动安装 OpenJDK 17? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if install_jdk17; then
                AUTO_JAVA_INSTALL=true
                log_info "Java 安装成功，继续安装 SkyWalking..."
            else
                log_error "Java 安装失败，请手动安装后重试"
                exit 1
            fi
        else
            log_info "请手动安装 Java 11 或更高版本后重新运行脚本"
            log_info "Ubuntu/Debian: sudo apt-get install openjdk-11-jdk"
            log_info "CentOS/RHEL: sudo yum install java-11-openjdk-devel"
            exit 1
        fi
    else
        # 检查 Java 版本
        local java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | sed 's/^1\.//' | cut -d'.' -f1)
        if [ "$java_version" -lt 11 ]; then
            if [ "$FORCE" = true ]; then
                log_error "Java 版本过低 ($java_version)，需要 Java 11 或更高版本"
                exit 1
            fi
            
            log_warn "Java 版本过低 ($java_version)，需要 Java 11 或更高版本"
            echo
            read -p "是否升级到 OpenJDK 17? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if install_jdk17; then
                    AUTO_JAVA_INSTALL=true
                    log_info "Java 升级成功，继续安装 SkyWalking..."
                else
                    log_error "Java 升级失败，请手动升级后重试"
                    exit 1
                fi
            else
                log_error "请升级到 Java 11 或更高版本后重新运行脚本"
                exit 1
            fi
        fi
    fi
    
    log_info "Java 版本检查通过: $(java -version 2>&1 | head -1)"
}

# 清理函数
cleanup() {
    if [ -f "$SW_TGZ" ]; then
        log_info "清理临时文件: $SW_TGZ"
        rm -f "$SW_TGZ"
    fi
    
    if [ -f "$SKYWALKING_AGENT_TGZ" ]; then
        log_info "清理临时文件: $SKYWALKING_AGENT_TGZ"
        rm -f "$SKYWALKING_AGENT_TGZ"
    fi
}

# 生成启动脚本
generate_startup_scripts() {
    local startup_dir="$SW_HOME/bin"
    
    # 生成启动脚本
    cat > "$startup_dir/start-all.sh" << EOF
#!/bin/bash
# SkyWalking 服务启动脚本

SW_HOME="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"

echo "启动 SkyWalking 服务..."

# 启动 OAP 服务
cd "\$SW_HOME/bin"
nohup ./oapService.sh > "\$SW_HOME/logs/oap-startup.log" 2>&1 &
echo "OAP 服务已启动"

# 等待 OAP 服务启动
sleep 10

# 启动 UI 服务
nohup ./webappService.sh > "\$SW_HOME/logs/webapp-startup.log" 2>&1 &
echo "UI 服务已启动"

echo "SkyWalking 服务启动完成"
echo "访问地址: http://localhost:$UI_SERVER_PORT"
EOF

    # 生成停止脚本
    cat > "$startup_dir/stop-all.sh" << EOF
#!/bin/bash
# SkyWalking 服务停止脚本

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/../../stop.sh"
EOF

    # 设置执行权限
    chmod +x "$startup_dir/start-all.sh" "$startup_dir/stop-all.sh"
    
    log_info "已生成启动/停止脚本"
}

# 生成 systemd 服务文件（仅限 root 用户）
generate_systemd_service() {
    if [ "$EUID" -ne 0 ]; then
        return 0
    fi
    
    local service_file="/etc/systemd/system/skywalking.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=SkyWalking APM
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=$SW_HOME
ExecStart=$SW_HOME/bin/oapService.sh
ExecStartPost=$SW_HOME/bin/webappService.sh
ExecStop=$SW_HOME/bin/stop.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "已生成 systemd 服务文件: $service_file"
    log_info "使用 systemctl enable skywalking 设置开机自启"
}

# 保存安装信息
save_install_info() {
    local info_file="$SW_HOME/.install-info"
    
    cat > "$info_file" << EOF
# SkyWalking 安装信息
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_USER=$(whoami)
INSTALL_DIR=$SW_HOME
SW_VERSION=$SW_VERSION
SW_AGENT_VERSION=$SW_AGENT_VERSION
OAP_PORT=$OAP_PORT
UI_PORT=$UI_SERVER_PORT
CONFIG_FILE=$CONFIG_FILE
EOF

    log_info "已保存安装信息到: $info_file"
}

# 停止服务
stop_services() {
    log_info "停止 SkyWalking 服务..."
    
    # 使用 stop.sh 脚本
    if [ -f "$SCRIPT_DIR/stop.sh" ]; then
        "$SCRIPT_DIR/stop.sh"
    fi
    
    # 停止 systemd 服务（如果存在）
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active skywalking >/dev/null 2>&1; then
            systemctl stop skywalking
            log_info "已停止 systemd 服务"
        fi
        
        if systemctl is-enabled skywalking >/dev/null 2>&1; then
            systemctl disable skywalking
            log_info "已禁用 systemd 服务"
        fi
    fi
    
    # 强制停止残留进程
    local pids=$(ps -ef | grep skywalking | grep java | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
        log_warn "发现残留进程，正在强制停止..."
        echo "$pids" | xargs kill -15 2>/dev/null
        sleep 2
        echo "$pids" | xargs kill -9 2>/dev/null
    fi
}

# 备份配置
backup_configs() {
    if [ "$FORCE" = true ]; then
        return 0
    fi
    
    local backup_dir="${UNINSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    log_info "备份配置到: $backup_dir"
    
    mkdir -p "$backup_dir"
    
    # 备份配置文件
    if [ -d "$UNINSTALL_DIR/config" ]; then
        cp -r "$UNINSTALL_DIR/config" "$backup_dir/"
    fi
    
    if [ -d "$UNINSTALL_DIR/webapp" ]; then
        cp -r "$UNINSTALL_DIR/webapp" "$backup_dir/"
    fi
    
    # 备份安装信息
    if [ -f "$UNINSTALL_DIR/.install-info" ]; then
        cp "$UNINSTALL_DIR/.install-info" "$backup_dir/"
    fi
    
    log_info "配置备份完成"
}

# 删除文件
remove_files() {
    log_info "删除 SkyWalking 文件..."
    
    if [ ! -d "$UNINSTALL_DIR" ]; then
        log_error "安装目录不存在: $UNINSTALL_DIR"
        exit 1
    fi
    
    # 保留数据目录（如果指定）
    if [ "$KEEP_DATA" = true ]; then
        local data_dirs=("data" "logs")
        for dir in "${data_dirs[@]}"; do
            if [ -d "$UNINSTALL_DIR/$dir" ]; then
                mv "$UNINSTALL_DIR/$dir" "/tmp/skywalking-$dir-$(date +%Y%m%d_%H%M%S)"
                log_info "已保留 $dir 目录"
            fi
        done
    fi
    
    # 删除安装目录
    rm -rf "$UNINSTALL_DIR"
    log_info "已删除安装目录: $UNINSTALL_DIR"
}

# 清理系统配置
cleanup_system() {
    # 删除 systemd 服务文件
    if [ "$FORCE" = true ] && [ "$EUID" -eq 0 ]; then
        local service_file="/etc/systemd/system/skywalking.service"
        if [ -f "$service_file" ]; then
            rm -f "$service_file"
            systemctl daemon-reload
            log_info "已删除 systemd 服务文件"
        fi
    fi
    
    # 删除软链接
    local links=$(find /opt -name "skywalking*" -type l 2>/dev/null)
    if [ -n "$links" ]; then
        echo "$links" | xargs rm -f
        log_info "已删除相关软链接"
    fi
}

# 卸载 SkyWalking
uninstall_skywalking() {
    log_info "开始卸载 SkyWalking..."
    
    # 确定卸载目录
    if [ -z "$UNINSTALL_DIR" ]; then
        if [ -n "$CUSTOM_INSTALL_DIR" ]; then
            UNINSTALL_DIR=$(eval echo "$CUSTOM_INSTALL_DIR")
        elif [ -n "$SW_HOME" ] && [ -d "$SW_HOME" ]; then
            UNINSTALL_DIR="$SW_HOME"
        else
            UNINSTALL_DIR="/opt/skywalking"
        fi
    fi
    
    # 检查目录是否存在
    if [ ! -d "$UNINSTALL_DIR" ]; then
        log_error "SkyWalking 安装目录不存在: $UNINSTALL_DIR"
        exit 1
    fi
    
    # 确认卸载
    if [ "$FORCE" = true ]; then
        log_info "强制模式：跳过确认直接卸载"
    else
        echo "即将卸载 SkyWalking 从目录: $UNINSTALL_DIR"
        read -p "确认继续? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "卸载已取消"
            exit 0
        fi
    fi
    
    # 执行卸载步骤
    stop_services
    backup_configs
    remove_files
    cleanup_system
    
    log_info "SkyWalking 卸载完成"
    
    if [ "$FORCE" != true ]; then
        log_info "配置文件已备份，如需完全删除请使用 -f/--force 参数"
    fi
}

# 主函数
function main () {
    # 初始化脚本
    init_script "$@"
    
    # 如果是卸载模式
    if [ "$UNINSTALL" = true ]; then
        uninstall_skywalking
        exit 0
    fi
    
    log_info "开始安装 SkyWalking 到目录: $SW_HOME"
    
    # 验证安装目录
    validate_install_dir 
    
    # 设置错误处理
    set -e
    trap cleanup EXIT
    
    # 初始化检查
    check_os
    check_permissions "$SW_HOME"
    check_system_resources
    check_dependencies
    validate_config
    check_network
    check_port_availability
    
    # 安装步骤
    download_sw
    extract_sw
    configure_sw
    start_sw
    configure_skywalking_agent
    check_logs
    
    # 生成辅助文件
    generate_startup_scripts
    generate_systemd_service
    save_install_info
    
    log_info "SkyWalking 安装完成！"
    log_info "安装目录: $SW_HOME"
    log_info "访问地址: http://localhost:$UI_SERVER_PORT"
    log_info "OAP 服务端口: $OAP_PORT"
    log_info "UI 服务端口: $UI_SERVER_PORT"
    
    # 显示使用说明
    echo
    echo "使用说明:"
    echo "  启动服务: $SW_HOME/bin/start-all.sh"
    echo "  停止服务: $SW_HOME/bin/stop-all.sh"
    echo "  查看日志: $SW_HOME/logs/"
    echo "  卸载程序: $0 -u -d $SW_HOME"
    echo "  强制卸载: $0 -u -d $SW_HOME -f"
    
    # 如果是 root 用户，显示 systemd 提示
    if [ "$EUID" -eq 0 ]; then
        echo "  设置开机自启: systemctl enable skywalking"
        echo "  查看服务状态: systemctl status skywalking"
    fi
    
    # 如果是普通用户安装，显示启动提示
    if [ "$EUID" -ne 0 ]; then
        log_info "提示：如需开机自启，请手动配置 systemd 服务或添加到启动脚本"
    fi
}

# 执行主函数
main "$@"

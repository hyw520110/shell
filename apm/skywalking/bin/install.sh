#!/bin/bash
# skywalking自动安装、配置

# 全局变量定义

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
DEFAULT_TMP_DIR="/tmp"

# 运行时变量（将在参数解析后设置）
INSTALL_DIR=""
DOWNLOAD_DIR=""
TMP_DIR="$DEFAULT_TMP_DIR"

# 默认版本配置
DEFAULT_SW_VERSION="10.3.0"
DEFAULT_SW_AGENT_VERSION="9.5.0"
# 版本信息
SW_VERSION="$DEFAULT_SW_VERSION"
SW_AGENT_VERSION="$DEFAULT_SW_AGENT_VERSION"
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
OAP_PORT="${OAP_PORT:-$DEFAULT_OAP_PORT}"
UI_SERVER_PORT=""
WEB_PORT=""

# 服务配置
COLLECTOR_BACKEND_SERVICE="${COLLECTOR_BACKEND_SERVICE:-127.0.0.1:11800}"

# 应用目录
APP_BASE_DIR="${APP_BASE_DIR:-/opt/apps}"

# Java安装相关
AUTO_INSTALL_JAVA=false
JAVA_INSTALL_DIR="$HOME/java"
JDK_VERSION="17"
JDK_DOWNLOAD_URL=""

# 存储配置
STORAGE_TYPE=""
STORAGE_HOST=""
STORAGE_PORT=""
STORAGE_USER=""
STORAGE_PASSWORD=""
STORAGE_DATABASE=""
STORAGE_NAMESPACE=""

# 功能开关
UNINSTALL=false
FORCE=false
KEEP_DATA=false
KEEP_PACKAGE=true
AUTO_JAVA_INSTALL=false

# 安装模式
INSTALL_MODE="all"  # all, server, agent

# 自定义参数
CUSTOM_INSTALL_DIR=""
CUSTOM_DOWNLOAD_DIR=""

# 卸载相关
UNINSTALL_DIR=""

# JDBC驱动版本配置
MYSQL_DRIVER_VERSION="8.0.30"
POSTGRESQL_DRIVER_VERSION="42.6.0"

# JDBC驱动下载URL配置
MYSQL_DRIVER_BASE_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java"
POSTGRESQL_DRIVER_BASE_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql"

# 默认端口配置
DEFAULT_OAP_PORT="11800"
DEFAULT_UI_PORT="8080"
DEFAULT_MYSQL_PORT="3306"
DEFAULT_POSTGRESQL_PORT="5432"
DEFAULT_ELASTICSEARCH_PORT="9200"
DEFAULT_BANYANDB_PORT="17912"

# 超时和重试配置
DEFAULT_SERVICE_TIMEOUT=60  # 服务启动超时时间（秒）
DEFAULT_SERVICE_CHECK_ATTEMPTS=30  # 服务检查次数
DEFAULT_DOWNLOAD_RETRIES=3  # 下载重试次数

# 下载配置
DEFAULT_DOWNLOAD_CONNECTIONS=16  # 下载线程数
DEFAULT_MIN_FILE_SIZE=1048576  # 最小文件大小（1MB）

# 显示帮助信息
show_help() {
    cat << EOF
SkyWalking 安装/卸载脚本

用法: $0 [选项]

安装选项:
    -d, --dir DIR         指定安装目录 (默认: $DEFAULT_INSTALL_DIR)
    --download-dir DIR    指定下载目录 (默认: $HOME/Downloads)
    -s, --storage TYPE    指定存储类型 (mysql|elasticsearch|postgresql|banyandb)
    --storage-host HOST   存储服务主机地址 (默认: 根据存储类型)
    --storage-port PORT   存储服务端口 (默认: 根据存储类型)
    --storage-user USER   存储服务用户名 (默认: 根据存储类型)
    --storage-pass PASS   存储服务密码 (默认: 根据存储类型)
    --storage-db DB       存储数据库名 (默认: 根据存储类型)
    --storage-namespace NS 存储命名空间 (仅Elasticsearch)
    --web-port PORT       Web UI端口 (默认: 8080)
    --mode MODE           安装模式: all(默认), server, agent
    -f, --force           强制模式（强制安装/卸载）

卸载选项:
    -u, --uninstall       卸载 SkyWalking
    -k, --keep-data       卸载时保留数据目录

其他选项:
    -h, --help            显示此帮助信息
    -v, --version [VER]   显示版本信息或指定安装版本
    --keep-package        保留下载的安装包

存储类型说明:
    mysql         MySQL数据库存储 (端口: 3306, 数据库: swtest)
    elasticsearch Elasticsearch搜索引擎存储 (端口: 9200)
    postgresql    PostgreSQL数据库存储 (端口: 5432, 数据库: skywalking)
    banyandb      BanyanDB时序数据库存储 (默认存储)

安装模式说明:
    all           安装服务端和客户端 (默认)
    server        仅安装服务端 (OAP服务器和Web UI)
    agent         仅安装客户端 (Java Agent)

示例:
    $0                                    # 使用默认配置安装最新版本
    $0 -s mysql                           # 使用MySQL存储
    $0 -s elasticsearch --storage-host 192.168.1.100  # 使用远程ES
    $0 -s postgresql --storage-user admin --storage-pass secret  # PostgreSQL
    $0 -s banyandb                        # 使用BanyanDB存储
    $0 -d /opt/skywalking -s mysql        # 安装到指定目录并使用MySQL
    $0 -f -s elasticsearch                # 强制模式安装使用ES存储

注意：
    - 默认存储类型为 banyandb
    - 指定版本不存在时自动使用最新版本
    - 存储配置可在安装后修改 config/application.yml

EOF
}
# 公共变量
SUDO_CMD=""
if command -v sudo >/dev/null 2>&1 && [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

# 调试日志函数
log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
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
# 工具函数
# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查并执行命令（自动处理sudo）
execute_with_sudo() {
    if [ -n "$SUDO_CMD" ]; then
        $SUDO_CMD "$@"
    else
        "$@"
    fi
}

# 检测可用的包管理器
detect_package_manager() {
    if command_exists apt-get; then
        echo "apt-get"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists yum; then
        echo "yum"
    elif command_exists brew; then
        echo "brew"
    else
        echo ""
    fi
}

# 使用包管理器安装软件包
install_package() {
    local package="$1"
    local pkg_manager=$(detect_package_manager)
    
    if [ -z "$pkg_manager" ]; then
        log_error "未找到支持的包管理器"
        return 1
    fi
    
    case "$pkg_manager" in
        "apt-get")
            execute_with_sudo apt-get update
            execute_with_sudo apt-get install -y "$package"
            ;;
        "dnf")
            execute_with_sudo dnf install -y "$package"
            ;;
        "yum")
            execute_with_sudo yum install -y "$package"
            ;;
        "brew")
            execute_with_sudo brew install "$package"
            ;;
    esac
}

# 用户确认函数
confirm_action() {
    local message="$1"
    local default_yes="${2:-false}"
    
    if [ "$default_yes" = true ]; then
        read -p "$message (Y/n): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        read -p "$message (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# 下载驱动函数
download_driver() {
    local driver_name="$1"
    local driver_url="$2"
    local driver_file="$3"
    
    log_info "检查${driver_name} JDBC驱动..."
    
    # 创建目录（如果不存在）
    mkdir -p "$(dirname "$driver_file")"
    
    # 检查驱动是否已存在
    if [ -f "$driver_file" ]; then
        log_info "${driver_name} JDBC驱动已存在"
        return 0
    fi
    
    log_info "下载${driver_name} JDBC驱动..."
    
    # 下载驱动
    if ! download_file "$driver_url" "$driver_file"; then
        log_error "下载${driver_name} JDBC驱动失败"
        return 1
    fi
    
    log_info "${driver_name} JDBC驱动下载完成"
    return 0
}

# 创建备份文件
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "已备份文件: $backup"
    fi
}

# 等待服务启动
wait_for_service() {
    local service_name="$1"
    local port="$2"
    local max_attempts="${3:-$DEFAULT_SERVICE_CHECK_ATTEMPTS}"
    local attempt=1
    
    log_info "等待 $service_name 服务启动..."
    
    while [ $attempt -le $max_attempts ]; do
        # 方法1: 使用netstat检查端口
        if command_exists netstat && netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            log_info "$service_name 服务已启动 (端口: $port)"
            return 0
        fi
        
        # 方法2: 使用ss检查端口
        if command_exists ss && ss -tlnp 2>/dev/null | grep -q ":$port "; then
            log_info "$service_name 服务已启动 (端口: $port)"
            return 0
        fi
        
        # 方法3: 使用lsof检查端口
        if command_exists lsof && lsof -i ":$port" >/dev/null 2>&1; then
            log_info "$service_name 服务已启动 (端口: $port)"
            return 0
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log_error "$service_name 服务启动超时"
    return 1
}


# 显示版本信息
show_version() {
    echo "SkyWalking 安装脚本 v$SCRIPT_VERSION"
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
    
    if command_exists curl; then
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
    elif command_exists wget; then
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
                        # Agent版本保持为默认值，不与服务端同步
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
                # Agent版本保持为默认值，不与服务端同步
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
            if ! confirm_action "安装目录已存在且非空: $SW_HOME 可能会覆盖现有文件,是否继续?"; then
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
            -s|--storage)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储类型"
                    exit 1
                fi
                STORAGE_TYPE="$2"
                shift 2
                ;;
            --storage-host)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储主机"
                    exit 1
                fi
                STORAGE_HOST="$2"
                shift 2
                ;;
            --storage-port)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储端口"
                    exit 1
                fi
                STORAGE_PORT="$2"
                shift 2
                ;;
            --storage-user)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储用户名"
                    exit 1
                fi
                STORAGE_USER="$2"
                shift 2
                ;;
            --storage-pass)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储密码"
                    exit 1
                fi
                STORAGE_PASSWORD="$2"
                shift 2
                ;;
            --storage-db)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储数据库"
                    exit 1
                fi
                STORAGE_DATABASE="$2"
                shift 2
                ;;
            --storage-namespace)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储命名空间"
                    exit 1
                fi
                STORAGE_NAMESPACE="$2"
                shift 2
                ;;
            --web-port)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定Web端口"
                    exit 1
                fi
                WEB_PORT="$2"
                shift 2
                ;;
            --mode)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定安装模式"
                    exit 1
                fi
                case "$2" in
                    "all"|"server"|"agent")
                        INSTALL_MODE="$2"
                        ;;
                    *)
                        log_error "无效的安装模式: $2 (支持: all, server, agent)"
                        exit 1
                        ;;
                esac
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
            --keep-package)
                KEEP_PACKAGE=true
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
    
    # 存储类型参数
    if [ -n "$STORAGE_TYPE" ]; then
        sudo_args+=("-s" "$STORAGE_TYPE")
    fi
    
    if [ -n "$STORAGE_HOST" ]; then
        sudo_args+=("--storage-host" "$STORAGE_HOST")
    fi
    
    if [ -n "$STORAGE_PORT" ]; then
        sudo_args+=("--storage-port" "$STORAGE_PORT")
    fi
    
    if [ -n "$STORAGE_USER" ]; then
        sudo_args+=("--storage-user" "$STORAGE_USER")
    fi
    
    if [ -n "$STORAGE_PASSWORD" ]; then
        sudo_args+=("--storage-pass" "$STORAGE_PASSWORD")
    fi
    
    if [ -n "$STORAGE_DATABASE" ]; then
        sudo_args+=("--storage-db" "$STORAGE_DATABASE")
    fi
    
    if [ -n "$STORAGE_NAMESPACE" ]; then
        sudo_args+=("--storage-namespace" "$STORAGE_NAMESPACE")
    fi
    
    if [ -n "$WEB_PORT" ]; then
        sudo_args+=("--web-port" "$WEB_PORT")
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
    
    if [ "$KEEP_PACKAGE" = true ]; then
        sudo_args+=("--keep-package")
    fi
    
    # 添加安装模式参数（如果不是默认值）
    if [ "$INSTALL_MODE" != "all" ]; then
        sudo_args+=("--mode" "$INSTALL_MODE")
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
    # 从配置文件加载默认值（原init_global_variables功能）
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 设置安装版本（原init_global_variables功能）
    set_install_version
    
    # 缓存原始用户信息
    cache_original_user
    
    # 调试日志（原set_user_paths功能）
    log_debug "默认安装目录: $DEFAULT_INSTALL_DIR"
    log_debug "默认下载目录: $DEFAULT_DOWNLOAD_DIR"
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 设置端口配置（在参数解析后）
    UI_SERVER_PORT="${WEB_PORT:-$DEFAULT_UI_PORT}"
    
    # 设置路径和URL
    setup_paths_and_urls
    
    # 检查是否需要提权
    if ! check_privileges "$SW_HOME"; then
        auto_sudo "$SW_HOME"
    fi
}


# 验证存储类型
validate_storage_type() {
    local valid_types=("mysql" "elasticsearch" "postgresql" "banyandb")
    
    if [ -z "$STORAGE_TYPE" ]; then
        STORAGE_TYPE="banyandb"
        log_info "未指定存储类型，使用默认值: $STORAGE_TYPE"
    fi
    
    # 检查存储类型是否有效
    local valid=false
    for type in "${valid_types[@]}"; do
        if [ "$STORAGE_TYPE" = "$type" ]; then
            valid=true
            break
        fi
    done
    
    if [ "$valid" = false ]; then
        log_error "无效的存储类型: $STORAGE_TYPE"
        log_error "支持的存储类型: ${valid_types[*]}"
        exit 1
    fi
    
    log_info "使用存储类型: $STORAGE_TYPE"
}

# 设置存储默认配置
setup_storage_defaults() {
    case "$STORAGE_TYPE" in
        "mysql")
            STORAGE_HOST="${STORAGE_HOST:-localhost}"
            STORAGE_PORT="${STORAGE_PORT:-$DEFAULT_MYSQL_PORT}"
            STORAGE_USER="${STORAGE_USER:-root}"
            STORAGE_PASSWORD="${STORAGE_PASSWORD:-root@1234}"
            STORAGE_DATABASE="${STORAGE_DATABASE:-swtest}"
            ;;
        "elasticsearch")
            STORAGE_HOST="${STORAGE_HOST:-localhost}"
            STORAGE_PORT="${STORAGE_PORT:-$DEFAULT_ELASTICSEARCH_PORT}"
            STORAGE_USER="${STORAGE_USER:-}"
            STORAGE_PASSWORD="${STORAGE_PASSWORD:-}"
            STORAGE_DATABASE="${STORAGE_DATABASE:-}"
            STORAGE_NAMESPACE="${STORAGE_NAMESPACE:-}"
            ;;
        "postgresql")
            STORAGE_HOST="${STORAGE_HOST:-localhost}"
            STORAGE_PORT="${STORAGE_PORT:-$DEFAULT_POSTGRESQL_PORT}"
            STORAGE_USER="${STORAGE_USER:-postgres}"
            STORAGE_PASSWORD="${STORAGE_PASSWORD:-123456}"
            STORAGE_DATABASE="${STORAGE_DATABASE:-skywalking}"
            ;;
        "banyandb")
            # BanyanDB 使用独立配置文件，这里设置基本参数
            STORAGE_HOST="${STORAGE_HOST:-localhost}"
            STORAGE_PORT="${STORAGE_PORT:-$DEFAULT_BANYANDB_PORT}"
            ;;
    esac
    
    log_debug "存储配置 - 主机: $STORAGE_HOST, 端口: $STORAGE_PORT"
}

# 生成存储配置
generate_storage_config() {
    local config_file="$SW_HOME/config/application.yml"
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi
    
    # 备份原配置文件
    cp "$config_file" "$backup_file"
    log_info "已备份配置文件: $backup_file"
    
    case "$STORAGE_TYPE" in
        "mysql")
            configure_mysql_storage "$config_file"
            ;;
        "elasticsearch")
            configure_elasticsearch_storage "$config_file"
            ;;
        "postgresql")
            configure_postgresql_storage "$config_file"
            ;;
        "banyandb")
            configure_banyandb_storage "$config_file"
            ;;
    esac
    
    return 0
}

# 下载MySQL JDBC驱动
download_mysql_driver() {
    local mysql_driver_url="${MYSQL_DRIVER_BASE_URL}/${MYSQL_DRIVER_VERSION}/mysql-connector-java-${MYSQL_DRIVER_VERSION}.jar"
    local driver_dir="$SW_HOME/oap-libs"
    local driver_file="$driver_dir/mysql-connector-java-${MYSQL_DRIVER_VERSION}.jar"
    
    download_driver "MySQL" "$mysql_driver_url" "$driver_file"
}

# 配置 MySQL 存储
configure_mysql_storage() {
    local config_file="$1"
    
    log_info "配置 MySQL 存储..."
    
    # 下载MySQL JDBC驱动
    if ! download_mysql_driver; then
        log_error "MySQL驱动配置失败"
        return 1
    fi
    
    # 生成MySQL存储配置片段
    local mysql_config="storage:
  selector: \${SW_STORAGE:mysql}
  mysql:
    properties:
      jdbcUrl: \"\${SW_JDBC_URL:jdbc:mysql://$STORAGE_HOST:$STORAGE_PORT/$STORAGE_DATABASE?rewriteBatchedStatements=true&allowMultiQueries=true}\"
      dataSource.user: \${SW_DATA_SOURCE_USER:$STORAGE_USER}
      dataSource.password: \${SW_DATA_SOURCE_PASSWORD:$STORAGE_PASSWORD}"
    
    # 创建临时配置文件
    local temp_config="${config_file}.tmp"
    
    # 使用awk替换storage配置部分
    awk -v mysql="$mysql_config" '
    /^storage:/ {
        in_storage = 1
        print mysql
        # 跳过原有的storage配置直到下一个顶级配置
        while (getline) {
            if (/^[^ ]/ && !/^storage/) {
                in_storage = 0
                print $0
                break
            }
        }
        next
    }
    !in_storage { print $0 }
    ' "$config_file" > "$temp_config"
    
    # 替换原配置文件
    mv "$temp_config" "$config_file"
    
    log_info "MySQL 存储配置完成"
}

# 配置 Elasticsearch 存储
configure_elasticsearch_storage() {
    local config_file="$1"
    
    log_info "配置 Elasticsearch 存储..."
    
    # 更新存储选择器
    sed -i "s/selector: \${SW_STORAGE:banyandb}/selector: \${SW_STORAGE:elasticsearch}/" "$config_file"
    
    # 更新 Elasticsearch 连接配置
    local cluster_nodes="$STORAGE_HOST:$STORAGE_PORT"
    
    sed -i "s/clusterNodes: \${SW_STORAGE_ES_CLUSTER_NODES:.*}/clusterNodes: \${SW_STORAGE_ES_CLUSTER_NODES:$cluster_nodes}/" "$config_file"
    
    if [ -n "$STORAGE_USER" ]; then
        sed -i "s/user: \${SW_ES_USER:.*}/user: \${SW_ES_USER:$STORAGE_USER}/" "$config_file"
    fi
    
    if [ -n "$STORAGE_PASSWORD" ]; then
        sed -i "s/password: \${SW_ES_PASSWORD:.*}/password: \${SW_ES_PASSWORD:$STORAGE_PASSWORD}/" "$config_file"
    fi
    
    if [ -n "$STORAGE_NAMESPACE" ]; then
        sed -i "s/namespace: \${SW_NAMESPACE:.*}/namespace: \${SW_NAMESPACE:$STORAGE_NAMESPACE}/" "$config_file"
    fi
    
    log_info "Elasticsearch 存储配置完成"
}

# 下载PostgreSQL JDBC驱动
download_postgresql_driver() {
    local postgresql_driver_url="${POSTGRESQL_DRIVER_BASE_URL}/${POSTGRESQL_DRIVER_VERSION}/postgresql-${POSTGRESQL_DRIVER_VERSION}.jar"
    local driver_dir="$SW_HOME/oap-libs"
    local driver_file="$driver_dir/postgresql-${POSTGRESQL_DRIVER_VERSION}.jar"
    
    download_driver "PostgreSQL" "$postgresql_driver_url" "$driver_file"
}

# 配置 PostgreSQL 存储
configure_postgresql_storage() {
    local config_file="$1"
    
    log_info "配置 PostgreSQL 存储..."
    
    # 下载PostgreSQL JDBC驱动
    if ! download_postgresql_driver; then
        log_error "PostgreSQL驱动配置失败"
        return 1
    fi
    
    # 生成PostgreSQL存储配置片段
    local postgresql_config="storage:
  selector: \${SW_STORAGE:postgresql}
  postgresql:
    properties:
      jdbcUrl: \"\${SW_JDBC_URL:jdbc:postgresql://$STORAGE_HOST:$STORAGE_PORT/$STORAGE_DATABASE}\"
      dataSource.user: \${SW_DATA_SOURCE_USER:$STORAGE_USER}
      dataSource.password: \${SW_DATA_SOURCE_PASSWORD:$STORAGE_PASSWORD}"
    
    # 创建临时配置文件
    local temp_config="${config_file}.tmp"
    
    # 使用awk替换storage配置部分
    awk -v postgresql="$postgresql_config" '
    /^storage:/ {
        in_storage = 1
        print postgresql
        # 跳过原有的storage配置直到下一个顶级配置
        while (getline) {
            if (/^[^ ]/ && !/^storage/) {
                in_storage = 0
                print $0
                break
            }
        }
        next
    }
    !in_storage { print $0 }
    ' "$config_file" > "$temp_config"
    
    # 替换原配置文件
    mv "$temp_config" "$config_file"
    
    log_info "PostgreSQL 存储配置完成"
}

# 配置 BanyanDB 存储
configure_banyandb_storage() {
    local config_file="$1"
    
    log_info "配置 BanyanDB 存储..."
    
    # BanyanDB 是默认配置，只需要确保选择器正确
    sed -i "s/selector: \${SW_STORAGE:.*}/selector: \${SW_STORAGE:banyandb}/" "$config_file"
    
    # 检查是否存在 bydb.yaml 配置文件
    local bydb_config="$SW_HOME/config/bydb.yaml"
    if [ -f "$bydb_config" ]; then
        log_info "BanyanDB 配置文件存在: $bydb_config"
    else
        log_warn "BanyanDB 配置文件不存在，将使用默认配置"
    fi
    
    log_info "BanyanDB 存储配置完成"
}

# 验证配置文件完整性
validate_config_integrity() {
    local config_file="$1"
    
    # 检查必要的配置项
    local required_configs=(
        "storage:"
        "selector:"
    )
    
    for config in "${required_configs[@]}"; do
        if ! grep -q "$config" "$config_file"; then
            log_error "配置文件缺少必要的配置项: $config"
            return 1
        fi
    done
    
    # 检查YAML语法
    validate_yaml_config "$config_file"
    
    return $?
}

# 验证YAML配置文件格式
validate_yaml_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi
    
    # 使用python验证（如果可用）
    if command_exists python3 && python3 -c "import yaml" >/dev/null 2>&1; then
        if python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
            return 0
        else
            log_error "YAML配置文件格式有错误"
            return 1
        fi
    else
        # 如果没有python，进行基本检查
        if grep -q "^[^ ]*:" "$config_file"; then
            log_warn "未安装python，跳过YAML格式验证"
        fi
        return 0
    fi
}

# 验证存储配置
validate_storage_config() {
    log_info "验证存储配置..."
    
    case "$STORAGE_TYPE" in
        "mysql")
            validate_mysql_connection
            ;;
        "elasticsearch")
            validate_elasticsearch_connection
            ;;
        "postgresql")
            validate_postgresql_connection
            ;;
        "banyandb")
            validate_banyandb_connection
            ;;
    esac
}

# 验证 MySQL 连接
validate_mysql_connection() {
    log_info "验证 MySQL 连接..."
    
    if command -v mysql >/dev/null 2>&1; then
        if mysql -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" -e "USE $STORAGE_DATABASE;" >/dev/null 2>&1; then
            log_info "MySQL 连接验证成功"
        else
            log_warn "MySQL 连接验证失败，请检查配置"
        fi
    else
        log_warn "MySQL 客户端未安装，跳过连接验证"
    fi
}

# 验证 Elasticsearch 连接
validate_elasticsearch_connection() {
    log_info "验证 Elasticsearch 连接..."
    
    if command -v curl >/dev/null 2>&1; then
        local es_url="http://$STORAGE_HOST:$STORAGE_PORT"
        if [ -n "$STORAGE_USER" ] && [ -n "$STORAGE_PASSWORD" ]; then
            es_url="http://$STORAGE_USER:$STORAGE_PASSWORD@$STORAGE_HOST:$STORAGE_PORT"
        fi
        
        if curl -s "$es_url" >/dev/null 2>&1; then
            log_info "Elasticsearch 连接验证成功"
        else
            log_warn "Elasticsearch 连接验证失败，请检查配置"
        fi
    else
        log_warn "curl 命令未安装，跳过连接验证"
    fi
}

# 验证 PostgreSQL 连接
validate_postgresql_connection() {
    log_info "验证 PostgreSQL 连接..."
    
    if command -v psql >/dev/null 2>&1; then
        if PGPASSWORD="$STORAGE_PASSWORD" psql -h"$STORAGE_HOST" -p"$STORAGE_PORT" -U"$STORAGE_USER" -d"$STORAGE_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
            log_info "PostgreSQL 连接验证成功"
        else
            log_warn "PostgreSQL 连接验证失败，请检查配置"
        fi
    else
        log_warn "PostgreSQL 客户端未安装，跳过连接验证"
    fi
}

# 验证 BanyanDB 连接
validate_banyandb_connection() {
    log_info "BanyanDB 连接验证需要手动检查"
    log_info "请确保 BanyanDB 服务正在运行并且可访问"
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
    
    # 验证存储配置
    validate_storage_type
    setup_storage_defaults
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
    local max_connections=${3:-$DEFAULT_DOWNLOAD_CONNECTIONS}
    
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
    local num_connections=${3:-$DEFAULT_DOWNLOAD_CONNECTIONS}
    
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
        "--timeout=$DEFAULT_SERVICE_TIMEOUT"  # 超时时间
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
        "--connect-timeout" "$DEFAULT_SERVICE_TIMEOUT"  # 连接超时
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
    local max_retries=${3:-$DEFAULT_DOWNLOAD_RETRIES}
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
    if [ "$file_size" -lt $DEFAULT_MIN_FILE_SIZE ]; then
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
    backup_file "$1" >/dev/null 2>&1
}

# 配置 SkyWalking
function configure_sw () {
    log_info "开始配置 SkyWalking..."
    
    # 创建 webapp 目录（如果不存在）
    mkdir -p "$SW_HOME/webapp"
    
    # 配置存储类型
    if ! generate_storage_config; then
        log_error "存储配置失败"
        exit 1
    fi
    
    # 验证配置文件完整性和YAML格式
    if ! validate_config_integrity "$SW_HOME/config/application.yml"; then
        log_error "配置文件验证失败"
        exit 1
    fi
    
    # 验证存储配置
    validate_storage_config
    
    # 配置 collector
    collector_config="$SW_HOME/config/application.yml"
    if [ -f "$collector_config" ]; then
        # 使用兼容的sed命令格式
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i "" "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
        else
            sed -i "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
        fi
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
    else
        log_warn "agent 配置文件不存在: $agent_config"
    fi
    
    log_info "SkyWalking 配置完成 (存储类型: $STORAGE_TYPE, 地址: $STORAGE_HOST:$STORAGE_PORT)"
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
    #rm -f $SKYWALKING_AGENT_TGZ
}

# 检查服务状态
check_service_status() {
    local service_name=$1
    local port=$2
    local max_attempts=$DEFAULT_SERVICE_CHECK_ATTEMPTS
    
    log_info "检查 $service_name 服务状态..."
    
    # 检查进程是否在运行（对于OAP服务）
    if [ "$service_name" = "OAP" ]; then
        # 检查是否有SkyWalking OAP进程在运行
        if pgrep -f "oapService.sh" >/dev/null 2>&1 || pgrep -f "OAPServerStartUp" >/dev/null 2>&1; then
            log_info "$service_name 服务进程已运行"
            return 0
        fi
    fi
    
    # 使用curl检查HTTP端点（适用于UI服务）
    if [ "$service_name" = "UI" ] && command_exists curl; then
        if curl -s "http://localhost:$port" >/dev/null 2>&1; then
            log_info "$service_name 服务HTTP端点可访问 (端口: $port)"
            return 0
        fi
    fi
    
    # 等待端口监听
    wait_for_service "$service_name" "$port" "$max_attempts"
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
    
    # 创建日志目录
    mkdir -p "$SW_HOME/logs"
    
    # 启动 OAP 服务
    log_info "启动 SkyWalking OAP 服务..."
    nohup ./oapService.sh > "$SW_HOME/logs/oap-startup.log" 2>&1 &
    OAP_PID=$!
    
    # 等待 OAP 服务启动
    if ! check_service_status "OAP" "$OAP_PORT"; then
        log_error "OAP 服务启动失败"
        
        # 检查日志文件是否存在
        if [ -f "$SW_HOME/logs/oap-startup.log" ]; then
            log_error "OAP 启动日志内容:"
            tail -20 "$SW_HOME/logs/oap-startup.log"
        else
            log_error "OAP 启动日志文件不存在: $SW_HOME/logs/oap-startup.log"
        fi
        
        # 检查SkyWalking OAP日志
        if [ -f "$SW_HOME/logs/skywalking-oap-server.log" ]; then
            log_error "SkyWalking OAP 服务器日志内容:"
            tail -20 "$SW_HOME/logs/skywalking-oap-server.log"
        fi
        
        # 检查进程
        log_error "当前Java进程:"
        ps aux | grep java | grep -v grep || log_error "没有找到Java进程"
        
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
        local port_in_use=false
        local pid=""
        local process_name=""
        
        # 使用多种方法检查端口是否被占用
        if command_exists netstat && netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            port_in_use=true
            pid=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1)
        elif command_exists ss && ss -tlnp 2>/dev/null | grep -q ":$port "; then
            port_in_use=true
            pid=$(ss -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1)
        elif command_exists lsof && lsof -i ":$port" >/dev/null 2>&1; then
            port_in_use=true
            pid=$(lsof -i ":$port" | awk 'NR>1 {print $2}' | head -1)
        fi
        
        if [ "$port_in_use" = true ]; then
            # 获取进程名称
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
            fi
            
            # 检查是否是SkyWalking相关进程
            local is_skywalking=false
            if [ -n "$process_name" ]; then
                case "$process_name" in
                    *skywalking*|*oap*|*webapp*)
                        is_skywalking=true
                        ;;
                    java)
                        # 对于Java进程，检查命令行参数
                        local java_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
                        if [[ "$java_cmd" == *"skywalking"* ]] || [[ "$java_cmd" == *"oap"* ]] || [[ "$java_cmd" == *"webapp"* ]]; then
                            is_skywalking=true
                        fi
                        ;;
                esac
            fi
            
            # 特殊处理8080端口
            if [ "$port" = "$DEFAULT_UI_PORT" ] && [ "$is_skywalking" = false ]; then
                log_error "端口 $DEFAULT_UI_PORT 已被非SkyWalking进程占用 (PID: $pid, 进程: $process_name)"
                read -p "请输入新的UI端口 (建议使用8081-8090): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                    UI_SERVER_PORT="$new_port"
                    WEB_PORT="$new_port"
                    log_info "已将UI端口更改为: $UI_SERVER_PORT"
                else
                    log_error "无效的端口号: $new_port 安装已取消"
                    exit 0
                fi
            elif [ "$port_in_use" = true ]; then
                # 其他端口的处理逻辑
                if [ "$is_skywalking" = true ]; then
                    log_warn "端口 $port 已被SkyWalking进程占用 (PID: $pid)"
                    read -p "是否停止现有SkyWalking进程并重新安装? (y/N): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                            kill -15 "$pid"
                            sleep 2
                            if kill -0 "$pid" 2>/dev/null; then
                                kill -9 "$pid"
                            fi
                            log_info "已停止现有SkyWalking进程"
                        else
                            log_warn "无法找到占用端口的进程"
                        fi
                    else
                        log_info "安装已取消"
                        exit 0
                    fi
                else
                    log_warn "端口 $port 已被占用 (PID: $pid, 进程: $process_name)"
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
                        else
                            log_warn "无法找到占用端口的进程"
                        fi
                    else
                        log_info "安装已取消"
                        exit 0
                    fi
                fi
            fi
        fi
    done
}



# 安装 JDK 17
install_jdk17() {
    log_info "开始安装 JDK 17..."
    
    local pkg_manager=$(detect_package_manager)
    
    if [ -n "$pkg_manager" ]; then
        log_info "使用 $pkg_manager 安装 OpenJDK 17..."
        case "$pkg_manager" in
            "apt-get")
                install_package "openjdk-17-jdk"
                ;;
            "dnf"|"yum")
                install_package "java-17-openjdk-devel"
                ;;
            "brew")
                install_package "openjdk@17"
                ;;
        esac
    elif [ "$(uname -s)" = "Darwin" ]; then
        log_info "macOS 系统建议使用 Homebrew 安装: brew install openjdk@17"
        log_error "请手动安装 JDK 17 后重新运行脚本"
        return 1
    else
        log_error "未找到支持的包管理器 (apt-get/dnf/yum/brew)"
        log_info "请手动安装 JDK 17 后重新运行脚本"
        return 1
    fi
    
    # 验证安装
    if command_exists java; then
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
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 检查网络工具（任选其一）
    local net_tool_found=false
    for cmd in netstat ss lsof; do
        if command_exists "$cmd"; then
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
        local pkg_manager=$(detect_package_manager)
        case "$pkg_manager" in
            "apt-get")
                log_info "Ubuntu/Debian 系统，请运行: sudo apt-get install ${missing_deps[*]}"
                ;;
            "yum")
                log_info "CentOS/RHEL 系统，请运行: sudo yum install ${missing_deps[*]}"
                ;;
            "dnf")
                log_info "Fedora 系统，请运行: sudo dnf install ${missing_deps[*]}"
                ;;
        esac
        
        exit 1
    fi
    
    # 检查 Java
    if ! command_exists java; then
        if [ "$FORCE" = true ]; then
            log_error "强制模式但未找到 Java，SkyWalking 需要 Java 11 或更高版本"
            exit 1
        fi
        
        log_warn "未找到 Java，SkyWalking 需要 Java 11 或更高版本"
        echo
        if confirm_action "是否自动安装 OpenJDK 17?"; then
            if install_jdk17; then
                AUTO_JAVA_INSTALL=true
                log_info "Java 安装成功，继续安装 SkyWalking..."
            else
                log_error "Java 安装失败，请手动安装后重试"
                exit 1
            fi
        else
            log_info "请手动安装 Java 11 或更高版本后重新运行脚本"
            log_info "sudo $pkg_manager install java-11-openjdk-devel"
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
            if confirm_action "是否升级到 OpenJDK 17?"; then
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
        if [ "$KEEP_PACKAGE" = true ]; then
            log_info "保留安装包: $SW_TGZ"
        else
            log_info "清理临时文件: $SW_TGZ"
            rm -f "$SW_TGZ"
        fi
    fi
    
    if [ -f "$SKYWALKING_AGENT_TGZ" ]; then
        if [ "$KEEP_PACKAGE" = true ]; then
            log_info "保留安装包: $SKYWALKING_AGENT_TGZ"
        else
            log_info "清理临时文件: $SKYWALKING_AGENT_TGZ"
            rm -f "$SKYWALKING_AGENT_TGZ"
        fi
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

    # 设置执行权限
    chmod +x "$startup_dir/start-all.sh"
    
    log_info "已生成启动脚本"
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
            if ! confirm_action "确认继续?"; then
                log_info "卸载已取消"
                exit 0
            fi    fi
    
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
    log_info "安装模式: $INSTALL_MODE"
    
    # 验证安装目录
    validate_install_dir 
    
    # 设置错误处理
    set -e
    trap cleanup EXIT
    
    # 初始化检查
    check_permissions "$SW_HOME"
    check_system_resources
    check_dependencies
    
    # 根据安装模式进行不同的验证
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        validate_config
        check_network
        check_port_availability
    fi
    
    # 下载和安装步骤
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        # 服务端安装
        download_sw
        extract_sw
        configure_sw
        start_sw
    fi
    
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "agent" ]; then
        # 客户端安装
        if [ "$INSTALL_MODE" = "agent" ] && [ ! -d "$SW_HOME" ]; then
            # 仅安装agent时，创建基本目录结构
            mkdir -p "$SW_HOME"
        fi
        configure_skywalking_agent
    fi
    
    # 根据安装模式执行不同的检查和生成步骤
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        generate_startup_scripts
        generate_systemd_service
    fi
    
    log_info "SkyWalking 安装完成！"
    log_info "安装目录: $SW_HOME"
    log_info "安装模式: $INSTALL_MODE"
    
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        log_info "访问地址: http://localhost:$UI_SERVER_PORT"
        log_info "OAP 服务端口: $OAP_PORT"
        log_info "UI 服务端口: $UI_SERVER_PORT"
    fi
    
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "agent" ]; then
        log_info "Agent 配置目录: $SKYWALKING_AGENT_BASE_DIR"
    fi
    
    if [ "$KEEP_PACKAGE" = true ]; then
        log_info "安装包已保留: $SW_TGZ"
        if [ -f "$SKYWALKING_AGENT_TGZ" ]; then
            log_info "Agent包已保留: $SKYWALKING_AGENT_TGZ"
        fi
    fi
    
    # 显示使用说明
    echo
    echo "使用说明:"
    
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        echo "  启动服务: $SW_HOME/bin/start-all.sh"
        echo "  停止服务: $SCRIPT_DIR/stop.sh"
        echo "  查看日志: $SW_HOME/logs/"
    fi
    
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "agent" ]; then
        echo "  Agent目录: $SKYWALKING_AGENT_BASE_DIR"
        echo "  Agent配置: $SKYWALKING_AGENT_BASE_DIR/config/agent.config"
    fi
    
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

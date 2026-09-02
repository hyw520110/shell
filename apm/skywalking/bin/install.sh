#!/bin/bash
# skywalking自动安装、配置

# 提前检查--version参数
if [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
    # 检查第二个参数是否存在且不是选项
    if [[ -n "$2" && ! "$2" =~ ^- ]]; then
        # 如果有第二个参数，将其作为版本号
        SPECIFIED_VERSION="$2"
    else
        # 没有版本号参数，检测已安装的版本
        # 定义show_version函数
        show_version() {
            # 检测SkyWalking是否已安装
            local skywalking_dir=""
            
            # 尝试多个可能的安装目录
            for dir in "/opt/skywalking" "$HOME/skywalking"; do
                if [ -d "$dir" ] && [ -f "$dir/bin/oapService.sh" ]; then
                    skywalking_dir="$dir"
                    break
                fi
            done
            
            if [ -n "$skywalking_dir" ]; then
                # 从oap-libs目录读取版本（使用core jar文件）
                VERSION=$(find "$skywalking_dir/oap-libs" -name "skywalking-server-*.jar" 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/skywalking-server-//' | sed 's/\.jar//')
                if [ -z "$VERSION" ]; then
                    # 备用方法：从其他jar文件提取版本
                    VERSION=$(find "$skywalking_dir/oap-libs" -name "skywalking-*receiver-plugin-*.jar" 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/.*receiver-plugin-\([0-9.]*\)\.jar/\1/')
                fi
                if [ -n "$VERSION" ]; then
                    echo "$VERSION"
                else
                    echo "已安装"
                fi
            elif pgrep -f "skywalking" > /dev/null 2>&1; then
                echo "运行中"
            else
                echo ""
            fi
        }
        show_version
        exit 0
    fi
fi

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
MIRROR_BASE_URL="https://downloads.apache.org/skywalking"
AGENT_MIRROR_BASE_URL="https://archive.apache.org/dist/skywalking/java-agent"

# 备用镜像源列表
BACKUP_MIRRORS=(
    "https://downloads.apache.org/skywalking"
    "https://archive.apache.org/dist/skywalking"
    "https://mirrors.cloud.tencent.com/apache/skywalking"
    "https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking"
)

# Java agent 与服务端发布目录不同；旧 agent 通常只在 archive 中保留
BACKUP_AGENT_MIRRORS=(
    "https://archive.apache.org/dist/skywalking/java-agent"
    "https://downloads.apache.org/skywalking/java-agent"
    "https://dlcdn.apache.org/skywalking/java-agent"
    "https://mirrors.cloud.tencent.com/apache/skywalking/java-agent"
    "https://mirrors.tuna.tsinghua.edu.cn/apache/skywalking/java-agent"
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
OAP_HTTP_PORT="${OAP_HTTP_PORT:-$DEFAULT_OAP_HTTP_PORT}"
PROMQL_PORT="${PROMQL_PORT:-$DEFAULT_PROMQL_PORT}"
UI_SERVER_PORT=""
WEB_PORT=""
WEB_PORT_EXPLICIT=false

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
STORAGE_TYPE_EXPLICIT=false
STORAGE_HOST_EXPLICIT=false
STORAGE_PORT_EXPLICIT=false
STORAGE_USER_EXPLICIT=false
STORAGE_PASSWORD_EXPLICIT=false
STORAGE_DATABASE_EXPLICIT=false
STORAGE_NAMESPACE_EXPLICIT=false

# 功能开关
UNINSTALL=false
FORCE=false
KEEP_DATA=false
KEEP_PACKAGE=true
AUTO_JAVA_INSTALL=false
INSTALL_SUCCEEDED=false
DETECTED_JAVA_HOME=""
ENABLE_MYSQL_MONITORING=false
MYSQL_MONITOR_SCRIPT="$SCRIPT_DIR/setup-mysql-monitoring.sh"
MYSQL_EXPORTER_TARGET="${MYSQL_EXPORTER_TARGET:-127.0.0.1:9104}"
MYSQL_MONITOR_HOST_NAME="${MYSQL_MONITOR_HOST_NAME:-$(hostname)}"
MYSQL_MONITOR_SERVICE_NAME="${MYSQL_MONITOR_SERVICE_NAME:-mysql-server}"
MYSQL_MONITOR_SCRAPE_INTERVAL="${MYSQL_MONITOR_SCRAPE_INTERVAL:-15s}"
ENABLE_VM_MONITORING=false
VM_MONITOR_SCRIPT="$SCRIPT_DIR/setup-vm-monitoring.sh"
NODE_EXPORTER_TARGET="${NODE_EXPORTER_TARGET:-127.0.0.1:9100}"
VM_MONITOR_HOST_NAME="${VM_MONITOR_HOST_NAME:-$(hostname)}"
VM_MONITOR_SERVICE_NAME="${VM_MONITOR_SERVICE_NAME:-$VM_MONITOR_HOST_NAME}"
VM_MONITOR_SCRAPE_INTERVAL="${VM_MONITOR_SCRAPE_INTERVAL:-15s}"
VM_MONITOR_START_NODE_EXPORTER=false

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
DEFAULT_OAP_HTTP_PORT="12800"
DEFAULT_PROMQL_PORT="19090"
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
    --enable-mysql-monitoring
                          启用 MySQL Server 指标接入（需先启动 mysqld_exporter）
    --mysql-exporter-target HOST:PORT
                          mysqld_exporter 地址 (默认: 127.0.0.1:9104)
    --mysql-monitor-host-name NAME
                          SkyWalking 展示用 MySQL 主机名 (默认: 当前 hostname)
    --mysql-monitor-service-name NAME
                          MySQL 指标服务名标签 (默认: mysql-server)
    --mysql-monitor-scrape-interval DURATION
                          MySQL 指标抓取间隔 (默认: 15s)
    --enable-vm-monitoring
                          启用 Linux 主机指标接入（需先启动 node_exporter）
    --node-exporter-target HOST:PORT
                          node_exporter 地址 (默认: 127.0.0.1:9100)
    --vm-monitor-host-name NAME
                          SkyWalking 展示用主机名 (默认: 当前 hostname)
    --vm-monitor-service-name NAME
                          Linux VM 服务名 (默认: vm-monitor-host-name)
    --vm-monitor-scrape-interval DURATION
                          Linux VM 指标抓取间隔 (默认: 15s)
    --start-node-exporter
                          启用 VM 监控时，先尝试运行 monitor/prometheus 的 node_exporter 脚本
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
    $0 --enable-mysql-monitoring          # 启用 MySQL Server 指标接入
    $0 --enable-vm-monitoring --start-node-exporter  # 启用 Linux 主机指标接入

注意：
    - 默认存储类型为 banyandb
    - 指定版本不存在时自动使用最新版本
    - 存储配置可在安装后修改 config/application.yml
    - MySQL Server 自身指标链路为 mysqld_exporter -> OpenTelemetry Collector -> SkyWalking OAP
      可先运行 database/mysql/bin/install.sh --enable-exporter 或 monitor/prometheus/bin/start_mysql_exporter.sh
    - Linux 主机指标链路为 node_exporter -> OpenTelemetry Collector -> SkyWalking OAP
      可先运行 monitor/prometheus/bin/start_node_exporter.sh，或加 --start-node-exporter

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

mask_secret() {
    local secret="${1:-}"
    local len=${#secret}

    if [ "$len" -eq 0 ]; then
        echo "(empty)"
    elif [ "$len" -le 4 ]; then
        echo "****"
    else
        echo "${secret:0:2}****${secret: -2}"
    fi
}

# 工具函数
# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_java_home() {
    local candidates=(
        "${JAVA_HOME:-}"
        "$HOME/jdk/current"
        "$HOME/jdk/jdk-21"
        "$HOME/jdk/jdk-17"
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home"
    )
    local java_home

    for java_home in "${candidates[@]}"; do
        if [ -n "$java_home" ] && [ -x "$java_home/bin/java" ] && "$java_home/bin/java" -version >/dev/null 2>&1; then
            echo "$java_home"
            return 0
        fi
    done

    if command_exists /usr/libexec/java_home; then
        java_home=$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home -v 17 2>/dev/null || true)
        if [ -n "$java_home" ] && [ -x "$java_home/bin/java" ]; then
            echo "$java_home"
            return 0
        fi
    fi

    if command_exists java && java -version >/dev/null 2>&1; then
        local java_bin
        java_bin=$(command -v java)
        java_home="$(cd "$(dirname "$java_bin")/.." >/dev/null 2>&1 && pwd)"
        if [ -x "$java_home/bin/java" ]; then
            echo "$java_home"
            return 0
        fi
    fi

    return 1
}

configure_java_env() {
    if DETECTED_JAVA_HOME="$(detect_java_home)"; then
        export JAVA_HOME="$DETECTED_JAVA_HOME"
        export PATH="$JAVA_HOME/bin:$PATH"
        return 0
    fi

    return 1
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
    # 检测SkyWalking是否已安装
    local skywalking_dir=""
    
    # 尝试多个可能的安装目录
    for dir in "/opt/skywalking" "$HOME/skywalking"; do
        if [ -d "$dir" ] && [ -f "$dir/bin/oapService.sh" ]; then
            skywalking_dir="$dir"
            break
        fi
    done
    
    if [ -n "$skywalking_dir" ]; then
        # 从安装目录读取版本
        VERSION=$(find "$skywalking_dir" -name "skywalking-*.jar" 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/skywalking-//' | sed 's/\.jar//')
        if [ -n "$VERSION" ]; then
            echo "$VERSION"
        else
            echo "已安装"
        fi
    elif pgrep -f "skywalking" > /dev/null 2>&1; then
        echo "运行中"
    else
        echo ""
    fi
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
    SW_AGENT_BASE_URL="$AGENT_MIRROR_BASE_URL"
}

# 验证安装目录
validate_install_dir() {
    # 检查目录是否为空
    if [ -z "$SW_HOME" ]; then
        log_error "安装目录不能为空"
        return 1
    fi
    
    # 检查路径中的非法字符
    if [[ "$SW_HOME" =~ [^a-zA-Z0-9_/\.~-] ]]; then
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
                STORAGE_TYPE_EXPLICIT=true
                shift 2
                ;;
            --storage-host)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储主机"
                    exit 1
                fi
                STORAGE_HOST="$2"
                STORAGE_HOST_EXPLICIT=true
                shift 2
                ;;
            --storage-port)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储端口"
                    exit 1
                fi
                STORAGE_PORT="$2"
                STORAGE_PORT_EXPLICIT=true
                shift 2
                ;;
            --storage-user)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储用户名"
                    exit 1
                fi
                STORAGE_USER="$2"
                STORAGE_USER_EXPLICIT=true
                shift 2
                ;;
            --storage-pass)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储密码"
                    exit 1
                fi
                STORAGE_PASSWORD="$2"
                STORAGE_PASSWORD_EXPLICIT=true
                shift 2
                ;;
            --storage-db)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储数据库"
                    exit 1
                fi
                STORAGE_DATABASE="$2"
                STORAGE_DATABASE_EXPLICIT=true
                shift 2
                ;;
            --storage-namespace)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定存储命名空间"
                    exit 1
                fi
                STORAGE_NAMESPACE="$2"
                STORAGE_NAMESPACE_EXPLICIT=true
                shift 2
                ;;
            --web-port)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定Web端口"
                    exit 1
                fi
                WEB_PORT="$2"
                WEB_PORT_EXPLICIT=true
                shift 2
                ;;
            --enable-mysql-monitoring)
                ENABLE_MYSQL_MONITORING=true
                shift
                ;;
            --mysql-exporter-target)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定 mysqld_exporter 地址"
                    exit 1
                fi
                MYSQL_EXPORTER_TARGET="$2"
                shift 2
                ;;
            --mysql-monitor-host-name)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定主机名"
                    exit 1
                fi
                MYSQL_MONITOR_HOST_NAME="$2"
                shift 2
                ;;
            --mysql-monitor-service-name)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定服务名"
                    exit 1
                fi
                MYSQL_MONITOR_SERVICE_NAME="$2"
                shift 2
                ;;
            --mysql-monitor-scrape-interval)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定抓取间隔"
                    exit 1
                fi
                MYSQL_MONITOR_SCRAPE_INTERVAL="$2"
                shift 2
                ;;
            --enable-vm-monitoring)
                ENABLE_VM_MONITORING=true
                shift
                ;;
            --node-exporter-target)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定 node_exporter 地址"
                    exit 1
                fi
                NODE_EXPORTER_TARGET="$2"
                shift 2
                ;;
            --vm-monitor-host-name)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定主机名"
                    exit 1
                fi
                VM_MONITOR_HOST_NAME="$2"
                if [ "$VM_MONITOR_SERVICE_NAME" = "$(hostname)" ]; then
                    VM_MONITOR_SERVICE_NAME="$2"
                fi
                shift 2
                ;;
            --vm-monitor-service-name)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定服务名"
                    exit 1
                fi
                VM_MONITOR_SERVICE_NAME="$2"
                shift 2
                ;;
            --vm-monitor-scrape-interval)
                if [ -z "$2" ]; then
                    log_error "选项 $1 需要指定抓取间隔"
                    exit 1
                fi
                VM_MONITOR_SCRAPE_INTERVAL="$2"
                shift 2
                ;;
            --start-node-exporter)
                VM_MONITOR_START_NODE_EXPORTER=true
                shift
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

    if [ "$ENABLE_MYSQL_MONITORING" = true ]; then
        sudo_args+=("--enable-mysql-monitoring")
        sudo_args+=("--mysql-exporter-target" "$MYSQL_EXPORTER_TARGET")
        sudo_args+=("--mysql-monitor-host-name" "$MYSQL_MONITOR_HOST_NAME")
        sudo_args+=("--mysql-monitor-service-name" "$MYSQL_MONITOR_SERVICE_NAME")
        sudo_args+=("--mysql-monitor-scrape-interval" "$MYSQL_MONITOR_SCRAPE_INTERVAL")
    fi

    if [ "$ENABLE_VM_MONITORING" = true ]; then
        sudo_args+=("--enable-vm-monitoring")
        sudo_args+=("--node-exporter-target" "$NODE_EXPORTER_TARGET")
        sudo_args+=("--vm-monitor-host-name" "$VM_MONITOR_HOST_NAME")
        sudo_args+=("--vm-monitor-service-name" "$VM_MONITOR_SERVICE_NAME")
        sudo_args+=("--vm-monitor-scrape-interval" "$VM_MONITOR_SCRAPE_INTERVAL")
        if [ "$VM_MONITOR_START_NODE_EXPORTER" = true ]; then
            sudo_args+=("--start-node-exporter")
        fi
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
    OAP_PORT="${OAP_PORT:-$DEFAULT_OAP_PORT}"
    OAP_HTTP_PORT="${OAP_HTTP_PORT:-$DEFAULT_OAP_HTTP_PORT}"
    PROMQL_PORT="${PROMQL_PORT:-$DEFAULT_PROMQL_PORT}"

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
    
    # 确保 SW_BASE_URL 不为空（如果 set_install_version 未执行）
    if [ -z "$SW_BASE_URL" ]; then
        SW_BASE_URL="$MIRROR_BASE_URL"
    fi
    if [ -z "$SW_AGENT_BASE_URL" ]; then
        SW_AGENT_BASE_URL="$AGENT_MIRROR_BASE_URL"
    fi

    # 设置下载URL
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
    
    # 解析命令行参数（提前解析以检查是否是--version模式）
    parse_arguments "$@"
    
    # 如果不是--version模式，才设置安装版本
    if [ -z "$SPECIFIED_VERSION" ] && [ -z "$SW_VERSION" ]; then
        # 设置安装版本（原init_global_variables功能）
        set_install_version
    fi
    
    # 缓存原始用户信息
    cache_original_user
    
    # 调试日志（原set_user_paths功能）
    log_debug "默认安装目录: $DEFAULT_INSTALL_DIR"
    log_debug "默认下载目录: $DEFAULT_DOWNLOAD_DIR"
    
    # 设置端口配置（在参数解析后）
    UI_SERVER_PORT="${WEB_PORT:-$DEFAULT_UI_PORT}"
    
    # 设置路径和URL
    setup_paths_and_urls
    
    # 检查是否需要提权
    if ! check_privileges "$SW_HOME"; then
        auto_sudo "$SW_HOME"
    fi
}

# macOS/Linux 兼容的 sed -i 函数
sed_i() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i "" "$@"
    else
        sed -i "$@"
    fi
}

# 检测是否有 TTY（交互式终端）
has_tty() {
    [[ -t 0 ]]
}

read_existing_ui_port() {
    local ui_config="$SW_HOME/webapp/application.yml"
    local port=""

    if [ -f "$ui_config" ]; then
        port=$(awk -F: '/^[[:space:]]*serverPort[[:space:]]*:/ {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }' "$ui_config")
    fi

    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        echo "$port"
        return 0
    fi

    return 1
}

reuse_existing_ui_port() {
    if [ "$WEB_PORT_EXPLICIT" = true ]; then
        return 0
    fi

    local existing_port
    existing_port=$(read_existing_ui_port || true)
    if [ -n "$existing_port" ]; then
        UI_SERVER_PORT="$existing_port"
        WEB_PORT="$existing_port"
        log_info "复用已有 SkyWalking UI 配置（端口: $UI_SERVER_PORT）"
    fi
}

extract_menu_choice() {
    local input="${1:-}"
    local min="${2:-1}"
    local max="${3:-9}"
    local choice

    choice=$(printf '%s\n' "$input" | tr -cd '0-9' | cut -c1)
    if [[ "$choice" =~ ^[0-9]$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
        echo "$choice"
        return 0
    fi

    return 1
}

# 交互式存储类型选择
prompt_storage_type() {
    echo ""
    echo "请选择 SkyWalking 存储类型："
    echo ""
    echo "  1) banyandb      (默认, 推荐)  - SkyWalking 自研时序数据库，专为 APM 优化，无需额外部署"
    echo "  2) elasticsearch                 成熟稳定，适合已有 ES 集群的环境"
    echo "  3) mysql                         适合已有 MySQL 的环境"
    echo "  4) postgresql                    适合已有 PostgreSQL 的环境"
    echo ""
    read -p "请选择 (1-4, 默认 1): " choice
    choice=$(extract_menu_choice "$choice" 1 4 || echo "1")

    case "${choice:-1}" in
        1) STORAGE_TYPE="banyandb" ;;
        2) STORAGE_TYPE="elasticsearch" ;;
        3) STORAGE_TYPE="mysql" ;;
        4) STORAGE_TYPE="postgresql" ;;
        *) STORAGE_TYPE="banyandb" ;;
    esac
    echo ""
    log_info "已选择存储类型: $STORAGE_TYPE"
}

# 验证存储类型
validate_storage_type() {
    local valid_types=("mysql" "elasticsearch" "postgresql" "banyandb")

    if [ -z "$STORAGE_TYPE" ]; then
        if has_tty; then
            prompt_storage_type
        else
            STORAGE_TYPE="banyandb"
            log_info "未指定存储类型，使用默认值: $STORAGE_TYPE"
        fi
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

load_existing_storage_config() {
    local config_file="$SW_HOME/config/application.yml"

    [ -f "$config_file" ] || return 0

    if command_exists python3; then
        local parsed
        parsed=$(python3 - "$config_file" <<'PY' 2>/dev/null || true
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

def emit(key, value):
    if value is not None and value != "":
        print(f"{key}={value}")

def yaml_block(source, key, parent_indent=-1):
    lines = source.splitlines()
    start = None
    key_indent = None
    pattern = re.compile(rf"^(\s*){re.escape(key)}:\s*(?:#.*)?$")
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match and len(match.group(1).expandtabs(2)) > parent_indent:
            start = index + 1
            key_indent = len(match.group(1).expandtabs(2))
            break
    if start is None:
        return ""
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= key_indent:
            end = index
            break
    return "\n".join(lines[start:end])

storage = yaml_block(text, "storage")
m = re.search(r"(?m)^\s*selector:\s*\$\{SW_STORAGE:([^}]+)\}", storage)
storage_type = m.group(1).strip() if m else None
emit("type", storage_type)

# 只解析 selector 选中的存储节点，避免 mysql 配置被后面的
# elasticsearch.clusterNodes（通常是 localhost:9200）覆盖。
backend = yaml_block(storage, storage_type, -1) if storage_type else ""

if storage_type == "mysql":
    m = re.search(r'jdbc:mysql://([^:/}"\s]+):([0-9]+)/([^?}"\s]+)', backend)
    if m:
        emit("host", m.group(1))
        emit("port", m.group(2))
        emit("database", m.group(3))

    m = re.search(r"dataSource\.user:\s*\$\{SW_DATA_SOURCE_USER:([^}]+)\}", backend)
    emit("user", m.group(1).strip() if m else None)

    m = re.search(r"dataSource\.password:\s*\$\{SW_DATA_SOURCE_PASSWORD:([^}]+)\}", backend)
    emit("password", m.group(1) if m else None)
elif storage_type in ("elasticsearch", "elasticsearch7", "banyandb"):
    m = re.search(r"clusterNodes:\s*\$\{[^:}]+:([^}]+)\}", backend)
    if m:
        nodes = m.group(1).strip().split(",", 1)[0]
        if ":" in nodes:
            host, port = nodes.rsplit(":", 1)
            emit("host", host)
            emit("port", port)

m = re.search(r"namespace:\s*\$\{SW_NAMESPACE:([^}]+)\}", backend)
emit("namespace", m.group(1).strip() if m else None)
PY
)
        local key value
        while IFS='=' read -r key value; do
            case "$key" in
                type)
                    if [ "$STORAGE_TYPE_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_TYPE="$value"; fi ;;
                host)
                    if [ "$STORAGE_HOST_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_HOST="$value"; fi ;;
                port)
                    if [ "$STORAGE_PORT_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_PORT="$value"; fi ;;
                database)
                    if [ "$STORAGE_DATABASE_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_DATABASE="$value"; fi ;;
                user)
                    if [ "$STORAGE_USER_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_USER="$value"; fi ;;
                password)
                    if [ "$STORAGE_PASSWORD_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_PASSWORD="$value"; fi ;;
                namespace)
                    if [ "$STORAGE_NAMESPACE_EXPLICIT" != true ] && [ -n "$value" ]; then STORAGE_NAMESPACE="$value"; fi ;;
            esac
        done <<< "$parsed"
    fi

    if [ -n "$STORAGE_TYPE" ]; then
        if [ "$STORAGE_TYPE" = "mysql" ]; then
            log_info "读取已有 MySQL 配置: ${STORAGE_USER:-未设置}@${STORAGE_HOST:-未设置}:${STORAGE_PORT:-未设置}/${STORAGE_DATABASE:-未设置}"
        else
            log_info "读取已有 SkyWalking 存储配置: type=$STORAGE_TYPE host=${STORAGE_HOST:-未设置} port=${STORAGE_PORT:-未设置}"
        fi
    fi
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
            configure_mysql_storage "$config_file" || return 1
            ;;
        "elasticsearch")
            configure_elasticsearch_storage "$config_file" || return 1
            ;;
        "postgresql")
            configure_postgresql_storage "$config_file" || return 1
            ;;
        "banyandb")
            configure_banyandb_storage "$config_file" || return 1
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

rewrite_jdbc_storage_config() {
    local config_file="$1"
    local backend="$2"
    local selector="$3"
    local jdbc_url="$4"
    local user="$5"
    local password="$6"
    local temp_config="${config_file}.tmp"

    if ! grep -q "^storage:" "$config_file" || ! grep -q "^[[:space:]]*$backend:" "$config_file"; then
        log_error "配置文件缺少 storage/$backend 小节，无法安全写入存储配置: $config_file"
        return 1
    fi

    awk -v backend="$backend" -v selector="$selector" -v jdbc_url="$jdbc_url" -v user="$user" -v password="$password" '
        function leading_spaces(s) {
            match(s, /^[ ]*/)
            return RLENGTH
        }
        /^storage:/ {
            in_storage = 1
            storage_indent = leading_spaces($0)
            print
            next
        }
        in_storage && /^[^ ]/ && leading_spaces($0) <= storage_indent {
            in_storage = 0
            in_backend = 0
        }
        in_storage && $0 ~ /^[ ]*selector:[ ]/ {
            print "  selector: ${SW_STORAGE:" selector "}"
            next
        }
        in_storage && $0 ~ "^  " backend ":" {
            in_backend = 1
            backend_indent = leading_spaces($0)
            print
            next
        }
        in_backend && $0 ~ /^  [^ ]/ && leading_spaces($0) <= backend_indent {
            in_backend = 0
        }
        in_backend && $0 ~ /^[ ]*jdbcUrl:[ ]/ {
            print "      jdbcUrl: ${SW_JDBC_URL:\"" jdbc_url "\"}"
            next
        }
        in_backend && $0 ~ /^[ ]*dataSource.user:[ ]/ {
            print "      dataSource.user: ${SW_DATA_SOURCE_USER:" user "}"
            next
        }
        in_backend && $0 ~ /^[ ]*dataSource.password:[ ]/ {
            print "      dataSource.password: ${SW_DATA_SOURCE_PASSWORD:" password "}"
            next
        }
        { print }
    ' "$config_file" > "$temp_config"

    if [ ! -s "$temp_config" ] || ! grep -q "^storage:" "$temp_config"; then
        rm -f "$temp_config"
        log_error "生成配置文件失败，已保留原配置: $config_file"
        return 1
    fi

    mv "$temp_config" "$config_file"
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
    
    local jdbc_url="jdbc:mysql://$STORAGE_HOST:$STORAGE_PORT/$STORAGE_DATABASE?rewriteBatchedStatements=true&allowMultiQueries=true"
    if ! rewrite_jdbc_storage_config "$config_file" "mysql" "mysql" "$jdbc_url" "$STORAGE_USER" "$STORAGE_PASSWORD"; then
        return 1
    fi
    
    log_info "MySQL 存储配置完成"
}

# 配置 Elasticsearch 存储
configure_elasticsearch_storage() {
    local config_file="$1"
    
    log_info "配置 Elasticsearch 存储..."
    
    # 更新存储选择器
    sed_i "s/selector: \${SW_STORAGE:banyandb}/selector: \${SW_STORAGE:elasticsearch}/" "$config_file"

    # 更新 Elasticsearch 连接配置
    local cluster_nodes="$STORAGE_HOST:$STORAGE_PORT"

    sed_i "s/clusterNodes: \${SW_STORAGE_ES_CLUSTER_NODES:.*}/clusterNodes: \${SW_STORAGE_ES_CLUSTER_NODES:$cluster_nodes}/" "$config_file"

    if [ -n "$STORAGE_USER" ]; then
        sed_i "s/user: \${SW_ES_USER:.*}/user: \${SW_ES_USER:$STORAGE_USER}/" "$config_file"
    fi

    if [ -n "$STORAGE_PASSWORD" ]; then
        sed_i "s/password: \${SW_ES_PASSWORD:.*}/password: \${SW_ES_PASSWORD:$STORAGE_PASSWORD}/" "$config_file"
    fi

    if [ -n "$STORAGE_NAMESPACE" ]; then
        sed_i "s/namespace: \${SW_NAMESPACE:.*}/namespace: \${SW_NAMESPACE:$STORAGE_NAMESPACE}/" "$config_file"
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
    
    if ! rewrite_jdbc_storage_config "$config_file" "postgresql" "postgresql" "jdbc:postgresql://$STORAGE_HOST:$STORAGE_PORT/$STORAGE_DATABASE" "$STORAGE_USER" "$STORAGE_PASSWORD"; then
        return 1
    fi
    
    log_info "PostgreSQL 存储配置完成"
}

# 配置 BanyanDB 存储
configure_banyandb_storage() {
    local config_file="$1"
    
    log_info "配置 BanyanDB 存储..."
    
    # BanyanDB 是默认配置，只需要确保选择器正确
    sed_i "s/selector: \${SW_STORAGE:.*}/selector: \${SW_STORAGE:banyandb}/" "$config_file"
    
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

show_mysql_config() {
    log_info "MySQL 配置: host=$STORAGE_HOST port=$STORAGE_PORT database=$STORAGE_DATABASE user=$STORAGE_USER password=$(mask_secret "$STORAGE_PASSWORD")"
}

find_mysql_client() {
    local candidates=(
        "mysql"
        "mariadb"
        "/opt/homebrew/bin/mysql"
        "/usr/local/bin/mysql"
        "/opt/homebrew/bin/mariadb"
        "/usr/local/bin/mariadb"
    )
    local cmd

    for cmd in "${candidates[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        elif [ -x "$cmd" ]; then
            echo "$cmd"
            return 0
        fi
    done

    return 1
}

mysql_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

mysql_database_name_is_safe() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

create_mysql_database() {
    local mysql_cmd="$1"
    local database="$2"

    if ! mysql_database_name_is_safe "$database"; then
        log_error "数据库名包含特殊字符，脚本不会自动创建: $database"
        return 1
    fi

    log_info "正在创建 MySQL 数据库: $database"
    if "$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" \
        -e "CREATE DATABASE IF NOT EXISTS \`$database\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1; then
        log_info "MySQL 数据库已创建或已存在: $database"
        log_info "无需导入 SkyWalking SQL；OAP 首次启动会自动初始化所需表结构"
        return 0
    fi

    log_error "创建 MySQL 数据库失败，请确认用户 $STORAGE_USER 具备 CREATE 权限"
    return 1
}

validate_mysql_ddl_permission() {
    local mysql_cmd="$1"
    local table_name="sw_install_check_$$"

    if "$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" "$STORAGE_DATABASE" \
        -e "CREATE TABLE \`$table_name\` (id BIGINT PRIMARY KEY, name VARCHAR(32)); ALTER TABLE \`$table_name\` ADD INDEX idx_name(name); DROP TABLE \`$table_name\`;" >/dev/null 2>&1; then
        log_info "MySQL DDL 权限验证成功，OAP 可自动创建/更新表结构"
        return 0
    fi

    log_error "MySQL DDL 权限验证失败；SkyWalking 不需要手动导入 SQL，但用户 $STORAGE_USER 需要 CREATE/ALTER/INDEX/DROP 等表结构权限"
    return 1
}

prompt_mysql_config() {
    local input=""

    read -r -p "MySQL Host [$STORAGE_HOST]: " input
    STORAGE_HOST="${input:-$STORAGE_HOST}"

    read -r -p "MySQL Port [$STORAGE_PORT]: " input
    STORAGE_PORT="${input:-$STORAGE_PORT}"

    read -r -p "MySQL Database [$STORAGE_DATABASE]: " input
    STORAGE_DATABASE="${input:-$STORAGE_DATABASE}"

    read -r -p "MySQL User [$STORAGE_USER]: " input
    STORAGE_USER="${input:-$STORAGE_USER}"

    read -r -s -p "MySQL Password [保留当前值直接回车]: " input
    echo
    STORAGE_PASSWORD="${input:-$STORAGE_PASSWORD}"
}

# 验证 MySQL 连接
validate_mysql_connection() {
    log_info "验证 MySQL 连接..."
    show_mysql_config

    local mysql_cmd
    if ! mysql_cmd="$(find_mysql_client)"; then
        log_error "MySQL 客户端未安装，无法在启动前验证连接；请先安装 mysql 客户端，或改用其他存储类型"
        return 2
    fi

    if ! "$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
        log_warn "MySQL 服务连接或账号认证失败"
        return 1
    fi

    local escaped_db exists
    escaped_db=$(mysql_sql_escape "$STORAGE_DATABASE")
    exists=$("$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" -N -B \
        -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$escaped_db';" 2>/dev/null | head -1 || true)

    if [ -z "$exists" ]; then
        log_warn "MySQL 连接成功，但数据库不存在: $STORAGE_DATABASE"
        MYSQL_CLIENT_CMD="$mysql_cmd"
        return 3
    fi

    if "$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" "$STORAGE_DATABASE" -e "SELECT 1;" >/dev/null 2>&1; then
        log_info "MySQL 连接验证成功"
        MYSQL_CLIENT_CMD="$mysql_cmd"
        validate_mysql_ddl_permission "$mysql_cmd"
        return $?
    fi

    log_warn "MySQL 数据库存在，但当前用户无法使用: $STORAGE_DATABASE"
    return 1
}

ensure_mysql_connection() {
    local attempts=0

    while true; do
        validate_mysql_connection
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        attempts=$((attempts + 1))
        if [ "$rc" -eq 2 ]; then
            return 1
        fi

        if [ "$rc" -eq 3 ]; then
            if has_tty && confirm_action "是否自动创建数据库 $STORAGE_DATABASE?" true; then
                if create_mysql_database "$MYSQL_CLIENT_CMD" "$STORAGE_DATABASE"; then
                    continue
                fi
            else
                log_error "数据库不存在，已终止安装；请先创建数据库或重新输入 MySQL 配置"
                return 1
            fi
        fi

        if ! has_tty; then
            log_error "MySQL 连接验证失败，非交互模式下终止安装；请通过 --storage-host/--storage-port/--storage-db/--storage-user/--storage-pass 指定正确配置"
            return 1
        fi

        if [ "$attempts" -ge 3 ]; then
            log_error "MySQL 连接连续失败 $attempts 次，终止安装"
            return 1
        fi

        log_warn "请重新输入 MySQL 配置"
        prompt_mysql_config
        if ! configure_mysql_storage "$SW_HOME/config/application.yml"; then
            return 1
        fi
    done
}

repair_mysql_ui_templates() {
    [ "$STORAGE_TYPE" = "mysql" ] || return 0

    local mysql_cmd="${MYSQL_CLIENT_CMD:-}"
    if [ -z "$mysql_cmd" ]; then
        mysql_cmd="$(find_mysql_client || true)"
    fi
    if [ -z "$mysql_cmd" ]; then
        log_warn "MySQL 客户端未安装，跳过 SkyWalking UI 模板存储自愈"
        return 0
    fi

    local table_exists
    table_exists=$("$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" -N -B "$STORAGE_DATABASE" \
        -e "SHOW TABLES LIKE 'ui_template';" 2>/dev/null | head -1 || true)
    [ "$table_exists" = "ui_template" ] || return 0

    local invalid_expr="configuration IS NULL OR JSON_VALID(configuration) = 0 OR JSON_TYPE(configuration) <> 'OBJECT' OR JSON_EXTRACT(configuration, '$.layer') IS NULL OR JSON_EXTRACT(configuration, '$.entity') IS NULL OR JSON_EXTRACT(configuration, '$.name') IS NULL"
    local invalid_count
    invalid_count=$("$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" -N -B "$STORAGE_DATABASE" \
        -e "SELECT COUNT(*) FROM ui_template WHERE ${invalid_expr};" 2>/dev/null | head -1 || true)

    if ! [[ "$invalid_count" =~ ^[0-9]+$ ]] || [ "$invalid_count" -eq 0 ]; then
        return 0
    fi

    local backup_table="ui_template_invalid_backup_$(date +%Y%m%d_%H%M%S)"
    log_warn "检测到 $invalid_count 条不兼容的 SkyWalking UI 模板记录，将备份后删除，启动时由 OAP 重新初始化"

    "$mysql_cmd" -h"$STORAGE_HOST" -P"$STORAGE_PORT" -u"$STORAGE_USER" -p"$STORAGE_PASSWORD" "$STORAGE_DATABASE" \
        2> >(grep -v '^mysql: \[Warning\] Using a password on the command line interface can be insecure\.$' >&2) <<SQL
CREATE TABLE \`${backup_table}\` LIKE ui_template;
INSERT INTO \`${backup_table}\` SELECT * FROM ui_template WHERE ${invalid_expr};
DELETE FROM ui_template WHERE ${invalid_expr};
SQL
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log_info "已备份并删除无效 UI 模板记录: $backup_table"
        return 0
    fi

    log_error "SkyWalking UI 模板存储自愈失败，请手动检查 MySQL 表 ui_template"
    return "$rc"
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
            return 0
        else
            log_warn "Elasticsearch 连接验证失败，请检查配置"
            return 1
        fi
    else
        log_warn "curl 命令未安装，跳过连接验证"
        return 0
    fi
}

# 验证 PostgreSQL 连接
validate_postgresql_connection() {
    log_info "验证 PostgreSQL 连接..."
    
    if command -v psql >/dev/null 2>&1; then
        if PGPASSWORD="$STORAGE_PASSWORD" psql -h"$STORAGE_HOST" -p"$STORAGE_PORT" -U"$STORAGE_USER" -d"$STORAGE_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
            log_info "PostgreSQL 连接验证成功"
            return 0
        else
            log_warn "PostgreSQL 连接验证失败，请检查配置"
            return 1
        fi
    else
        log_warn "PostgreSQL 客户端未安装，跳过连接验证"
        return 0
    fi
}

# 验证 BanyanDB 连接
validate_banyandb_connection() {
    log_info "BanyanDB 连接验证需要手动检查"
    log_info "请确保 BanyanDB 服务正在运行并且可访问"
    return 0
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
    load_existing_storage_config
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
find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi

    local repo_adl="$SCRIPT_DIR/../../../network/tools/adl"
    if [ -x "$repo_adl" ] && "$repo_adl" --help >/dev/null 2>&1; then
        echo "$repo_adl"
        return 0
    fi

    return 1
}

detect_download_tool() {
    if find_adl >/dev/null 2>&1; then
        echo "adl"
    elif command -v aria2c >/dev/null 2>&1; then
        echo "aria2c"
    elif command -v axel >/dev/null 2>&1; then
        echo "axel"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        echo "curl"
    fi
}

# 使用 adl 下载（支持断点续传）
download_with_adl() {
    local url="$1"
    local output="$2"

    log_info "使用 adl 下载..."

    output=$(realpath "$output" 2>/dev/null || echo "$output")
    local output_dir=$(dirname "$output")
    local output_file=$(basename "$output")

    mkdir -p "$output_dir"

    local adl_cmd
    if ! adl_cmd="$(find_adl)"; then
        return 1
    fi

    if "$adl_cmd" "$url" "$output_dir" "$output_file"; then
        return 0
    else
        return 1
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
            "adl")
                if download_with_adl "$url" "$output"; then
                    return 0
                fi
                ;;
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
    
    # 尝试备用镜像。Java agent 使用独立目录集合。
    local mirror_candidates=("${BACKUP_MIRRORS[@]}")
    if [[ "$url_pattern" == *apache-skywalking-java-agent* ]]; then
        mirror_candidates=("${BACKUP_AGENT_MIRRORS[@]}")
    fi

    for backup_mirror in "${mirror_candidates[@]}"; do
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
                backup_url="$backup_mirror/$version/apache-skywalking-java-agent-$version.tgz"
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
                SW_AGENT_BASE_URL="$AGENT_MIRROR_BASE_URL"
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
    local quiet="${3:-false}"
    
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
        if [ "$quiet" = true ]; then
            log_debug "验证压缩文件完整性: $file"
        else
            log_info "验证压缩文件完整性..."
        fi
        if tar -tzf "$file" >/dev/null 2>&1; then
            [ "$quiet" = true ] || log_info "压缩文件验证通过"
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

restore_application_config_from_package() {
    local config_file="$SW_HOME/config/application.yml"

    if [ -s "$config_file" ] && grep -q "^storage:" "$config_file"; then
        return 0
    fi

    if [ ! -f "$SW_TGZ" ]; then
        log_error "配置文件无效，且安装包不存在，无法恢复: $config_file"
        return 1
    fi

    log_warn "检测到 SkyWalking 核心配置为空或缺少 storage，将从安装包恢复: $config_file"
    mkdir -p "$(dirname "$config_file")"
    if tar -xOf "$SW_TGZ" "apache-skywalking-apm-bin/config/application.yml" > "$config_file"; then
        if [ -s "$config_file" ] && grep -q "^storage:" "$config_file"; then
            log_info "已从安装包恢复核心配置文件"
            return 0
        fi
    fi

    log_error "从安装包恢复核心配置失败: $config_file"
    return 1
}

validate_ui_templates() {
    local template_dir="$SW_HOME/config/ui-initialized-templates"

    [ -d "$template_dir" ] || return 1

    if ! command_exists python3; then
        log_warn "未安装 python3，跳过 SkyWalking UI 模板结构校验"
        return 0
    fi

    python3 - "$template_dir" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
bad = []

checked = 0
for path in root.rglob("*.json"):
    # SkyWalking 发布包中的 custom/placeholder.json 只是用于保留目录，
    # 并非 UI 模板，内容可能为空或不是 JSON。
    if path.name == "placeholder.json":
        continue
    checked += 1
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        bad.append(f"{path}: invalid json: {exc}")
        continue

    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
        bad.append(f"{path}: expected a one-element JSON array")
        continue

    item = data[0]
    config = item.get("configuration")
    if not item.get("id") or not isinstance(config, dict):
        bad.append(f"{path}: missing id/configuration")
        continue

    missing = [key for key in ("layer", "entity", "name") if not config.get(key)]
    if missing:
        bad.append(f"{path}: configuration missing {','.join(missing)}")

if checked == 0:
    bad.append(f"{root}: no UI template JSON files found")

if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
}

restore_ui_templates_from_package() {
    local template_dir="$SW_HOME/config/ui-initialized-templates"
    local backup_dir="${template_dir}.backup.$(date +%Y%m%d_%H%M%S)"

    if [ ! -f "$SW_TGZ" ]; then
        log_error "UI 模板无效，且安装包不存在，无法恢复: $template_dir"
        return 1
    fi

    if [ -d "$template_dir" ]; then
        log_warn "检测到 SkyWalking UI 模板缺失或结构异常，将备份并从安装包恢复: $template_dir"
        mv "$template_dir" "$backup_dir" || {
            log_error "备份 UI 模板目录失败: $template_dir"
            return 1
        }
        log_info "已备份 UI 模板目录: $backup_dir"
    else
        log_warn "检测到 SkyWalking UI 模板目录不存在，将从安装包恢复: $template_dir"
    fi

    if tar -xzf "$SW_TGZ" -C "$SW_HOME/config" --strip-components=2 "apache-skywalking-apm-bin/config/ui-initialized-templates"; then
        local validation_details
        if validation_details=$(validate_ui_templates); then
            log_info "已从安装包恢复 SkyWalking UI 模板"
            return 0
        fi
        [ -z "$validation_details" ] || log_debug "恢复后的 UI 模板校验详情: $validation_details"
    fi

    log_error "从安装包恢复 SkyWalking UI 模板失败: $template_dir"
    return 1
}

ensure_valid_ui_templates() {
    local validation_details
    if validation_details=$(validate_ui_templates); then
        log_debug "SkyWalking UI 模板校验通过"
        return 0
    fi

    log_warn "SkyWalking UI 模板校验失败，将从安装包自动恢复"
    [ -z "$validation_details" ] || log_debug "UI 模板校验详情: $validation_details"
    restore_ui_templates_from_package
}

# 下载 SkyWalking
function download_sw () {
    # 创建下载目录
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p "$DOWNLOAD_DIR" || {
            log_error "创建下载目录失败: $DOWNLOAD_DIR"
            exit 1
        }
    fi
    
    # 检查文件是否已存在且完整
    if [ -f "$SW_TGZ" ]; then
        if verify_download "$SW_TGZ" "" true; then
            log_info "复用已有 SkyWalking 安装包（完整性校验通过）"
            return 0
        else
            log_warn "现有压缩包损坏，重新下载"
            rm -f "$SW_TGZ"
        fi
    fi
    
    # 下载文件
    log_info "下载 SkyWalking $SW_VERSION..."
    
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
    # 创建安装目录
    if [ ! -d "$SW_HOME" ]; then
        mkdir -p "$SW_HOME" || {
            log_error "创建安装目录失败: $SW_HOME"
            exit 1
        }
    fi
    
    # 检查是否已经解压
    if [ -d "$SW_HOME/bin" ] && [ -f "$SW_HOME/bin/oapService.sh" ]; then
        log_info "复用已有 SkyWalking 安装目录: $SW_HOME"
        if ! restore_application_config_from_package; then
            exit 1
        fi
        if ! ensure_valid_ui_templates; then
            exit 1
        fi
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

    if ! restore_application_config_from_package; then
        exit 1
    fi

    if ! ensure_valid_ui_templates; then
        exit 1
    fi
    
    log_info "SkyWalking 解压完成"
}

# 备份配置文件
backup_config() {
    backup_file "$1" >/dev/null 2>&1
}

# 配置 SkyWalking
configure_agent_collector() {
    local agent_config="$SKYWALKING_AGENT_BASE_DIR/config/agent.config"

    if [ ! -f "$agent_config" ]; then
        return 1
    fi

    backup_config "$agent_config"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i "" "s/collector.backend_service=.*/collector.backend_service=$COLLECTOR_BACKEND_SERVICE/" "$agent_config"
    else
        sed -i "s/collector.backend_service=.*/collector.backend_service=$COLLECTOR_BACKEND_SERVICE/" "$agent_config"
    fi

    log_info "Agent collector 配置完成: $agent_config"
}

function configure_sw () {
    log_info "开始配置 SkyWalking..."

    # 创建 webapp 目录（如果不存在）
    mkdir -p "$SW_HOME/webapp"

    # 如果选择 BanyanDB，检测并自动安装
    if [ "$STORAGE_TYPE" = "banyandb" ]; then
        local banyandb_script="$SCRIPT_DIR/../../../database/banyandb/bin/install.sh"
        if [ -f "$banyandb_script" ]; then
            # 检测 banyandb 是否已运行
            if ! (command -v lsof &>/dev/null && lsof -i :"${STORAGE_PORT:-17912}" &>/dev/null) && \
               ! (command -v pgrep &>/dev/null && pgrep -f banyandb &>/dev/null) && \
               ! (docker ps --format '{{.Names}}' 2>/dev/null | grep -q banyandb); then
                log_info "BanyanDB 未检测到运行中实例"
                if has_tty; then
                    read -p "是否安装并启动 BanyanDB? [Y/n]: " install_banyandb
                    install_banyandb="${install_banyandb:-Y}"
                else
                    install_banyandb="Y"
                    log_info "将自动安装 BanyanDB..."
                fi
                if [[ "$install_banyandb" =~ ^[Yy]$ ]]; then
                    log_info "开始安装 BanyanDB..."
                    if bash "$banyandb_script" --port "${STORAGE_PORT:-17912}"; then
                        log_info "BanyanDB 安装完成"
                    else
                        log_warn "BanyanDB 安装失败，将继续配置 SkyWalking（请手动安装 BanyanDB）"
                    fi
                fi
            else
                log_info "检测到 BanyanDB 实例已运行"
            fi
        else
            log_warn "BanyanDB 安装脚本不存在: $banyandb_script"
            log_info "请手动安装 BanyanDB 或使用其他存储类型"
        fi
    fi

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
    
    # 验证存储配置。MySQL 必须在启动 OAP 前确认可连接，否则 OAP 会启动失败。
    if [ "$STORAGE_TYPE" = "mysql" ]; then
        if ! ensure_mysql_connection; then
            log_error "MySQL 存储配置验证失败"
            exit 1
        fi
        if ! repair_mysql_ui_templates; then
            log_error "MySQL UI 模板自愈失败"
            exit 1
        fi
    elif ! validate_storage_config; then
        log_error "存储配置验证失败"
        exit 1
    fi
    
    # 配置 collector
    collector_config="$SW_HOME/config/application.yml"
    if [ -f "$collector_config" ]; then
        # 使用兼容的sed命令格式
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i "" "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
            sed -i "" "s/restPort: \${SW_PROMQL_REST_PORT:.*}/restPort: \${SW_PROMQL_REST_PORT:$PROMQL_PORT}/" "$collector_config"
        else
            sed -i "s/collector.backend_service:.*/collector.backend_service: $COLLECTOR_BACKEND_SERVICE/" "$collector_config"
            sed -i "s/restPort: \${SW_PROMQL_REST_PORT:.*}/restPort: \${SW_PROMQL_REST_PORT:$PROMQL_PORT}/" "$collector_config"
        fi
        log_info "PromQL API 端口: $PROMQL_PORT"
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

    # 配置 agent；all 模式下 Agent 可能在后续步骤才安装。
    configure_agent_collector || log_info "Agent 配置文件暂不存在，后续 Agent 安装完成后会配置: $SKYWALKING_AGENT_BASE_DIR/config/agent.config"
    
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
        wait_for_service "OAP gRPC" "$OAP_PORT" "$max_attempts" || return 1
        wait_for_service "OAP HTTP/GraphQL" "$OAP_HTTP_PORT" "$max_attempts" || return 1
        wait_for_service "PromQL API" "$PROMQL_PORT" "$max_attempts" || return 1
        log_info "$service_name 服务端口检查通过 (gRPC: $OAP_PORT, HTTP: $OAP_HTTP_PORT, PromQL: $PROMQL_PORT)"
        return 0
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
show_log_error_summary() {
    local title="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        log_error "$title 不存在: $file"
        return 0
    fi

    log_error "$title 关键内容:"
    local summary
    summary=$(grep -Ei "ERROR|Exception|Caused by|Access denied|Unknown database|Communications link failure|Connection refused|timed out|Address already in use|BindException" "$file" | tail -20 || true)
    if [ -n "$summary" ]; then
        echo "$summary" >&2
    else
        tail -20 "$file" >&2
    fi
}

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
    
    # 检查 OAP 端口是否已被当前安装目录的旧服务占用
    local owner_info=""
    local oap_check_port=""
    for oap_check_port in "$OAP_PORT" "$OAP_HTTP_PORT"; do
        if owner_info=$(get_port_owner "$oap_check_port"); then
            local owner_pid="${owner_info%%$'\t'*}"
            if is_current_skywalking_server_process "$owner_pid"; then
                log_warn "OAP 端口已被当前 SkyWalking 实例占用（端口: $oap_check_port），将停止旧实例后重新启动"
                stop_existing_skywalking_server
            else
                log_error "OAP 端口已被其他进程占用（端口: $oap_check_port），无法启动"
                exit 1
            fi
        fi
    done
    
    # 创建日志目录
    mkdir -p "$SW_HOME/logs"
    
    # 启动 OAP 服务
    log_info "启动 SkyWalking OAP 服务..."
    SW_CORE_GRPC_PORT="$OAP_PORT" \
    SW_CORE_REST_PORT="$OAP_HTTP_PORT" \
    SW_PROMQL_REST_PORT="$PROMQL_PORT" \
    nohup ./oapService.sh > "$SW_HOME/logs/oap-startup.log" 2>&1 &
    OAP_PID=$!
    
    # 等待 OAP 服务启动
    if ! check_service_status "OAP" "$OAP_PORT"; then
        log_error "OAP 服务启动失败"
        show_log_error_summary "OAP 启动日志" "$SW_HOME/logs/oap-startup.log"
        show_log_error_summary "SkyWalking OAP 服务器日志" "$SW_HOME/logs/skywalking-oap-server.log"
        exit 1
    fi
    
    # 启动 UI 服务
    log_info "启动 SkyWalking UI 服务..."
    nohup ./webappService.sh > "$SW_HOME/logs/webapp-startup.log" 2>&1 &
    UI_PID=$!
    
    # 等待 UI 服务启动
    if ! check_service_status "UI" "$UI_SERVER_PORT"; then
        log_error "UI 服务启动失败"
        show_log_error_summary "UI 启动日志" "$SW_HOME/logs/webapp-startup.log"
        show_log_error_summary "SkyWalking UI 日志" "$SW_HOME/logs/skywalking-webapp.log"
        exit 1
    fi
    
    log_info "SkyWalking 服务启动成功"
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
get_port_owner() {
    local port="$1"
    local pid=""
    local process_name=""

    if command_exists netstat && netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        pid=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1 | head -1)
    elif command_exists ss && ss -tlnp 2>/dev/null | grep -q ":$port "; then
        pid=$(ss -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1 | head -1)
    elif command_exists lsof && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR>1 {print $2}' | head -1)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
    fi

    if [ -n "$pid" ]; then
        printf '%s\t%s\n' "$pid" "$process_name"
        return 0
    fi

    return 1
}

is_port_in_use() {
    get_port_owner "$1" >/dev/null 2>&1
}

is_skywalking_process() {
    local pid="$1"
    local process_name="$2"

    case "$process_name" in
        *skywalking*|*oap*|*webapp*) return 0 ;;
    esac

    local process_args
    process_args=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
    [[ "$process_args" == *"skywalking"* || "$process_args" == *"oap"* || "$process_args" == *"webapp"* ]]
}

is_current_skywalking_server_process() {
    local pid="$1"
    local process_args
    process_args=$(ps -p "$pid" -o args= 2>/dev/null || echo "")

    [[ "$process_args" == *"$SW_HOME"* ]] && \
        [[ "$process_args" == *"OAPServerStartUp"* || "$process_args" == *"ApplicationStartUp"* || "$process_args" == *"skywalking-oap-server"* || "$process_args" == *"skywalking-webapp"* ]]
}

stop_existing_skywalking_server() {
    local pids=()
    local pid

    while read -r pid; do
        [ -n "$pid" ] || continue
        if is_current_skywalking_server_process "$pid"; then
            pids+=("$pid")
        fi
    done < <(pgrep -f "$SW_HOME" 2>/dev/null || true)

    if [ "${#pids[@]}" -eq 0 ]; then
        return 0
    fi

    local pid_list
    printf -v pid_list '%s, ' "${pids[@]}"
    pid_list="${pid_list%, }"
    log_warn "检测到正在运行的 SkyWalking 服务（PID: $pid_list），将先停止旧进程，再重新启动"
    for pid in "${pids[@]}"; do
        kill -15 "$pid" 2>/dev/null || true
    done

    sleep 3

    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}

find_available_port() {
    local start_port="${1:-8081}"
    local end_port="${2:-8090}"
    local port

    for port in $(seq "$start_port" "$end_port"); do
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    for port in $(seq 8091 8999); do
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    return 1
}

set_ui_port() {
    local port="$1"
    UI_SERVER_PORT="$port"
    WEB_PORT="$port"
    log_info "SkyWalking UI 端口已设置（端口: $UI_SERVER_PORT）"
}

choose_available_ui_port() {
    local default_port
    default_port=$(find_available_port 8081 8090 || true)

    if [ -z "$default_port" ]; then
        log_error "未找到可用UI端口，请使用 --web-port 指定可用端口"
        exit 1
    fi

    if has_tty; then
        local new_port=""
        while true; do
            read -r -p "请输入新的UI端口 (默认自动使用 $default_port，直接回车确认): " new_port
            new_port="${new_port:-$default_port}"

            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
                log_warn "无效的端口号: $new_port，请输入 1024-65535"
                continue
            fi

            if is_port_in_use "$new_port"; then
                local owner_info owner_pid owner_name
                owner_info=$(get_port_owner "$new_port" || true)
                owner_pid="${owner_info%%$'\t'*}"
                owner_name="${owner_info#*$'\t'}"
                log_warn "端口 $new_port 已被占用 (PID: $owner_pid, 进程: $owner_name)，请换一个端口"
                continue
            fi

            set_ui_port "$new_port"
            return 0
        done
    fi

    log_warn "默认 SkyWalking UI 端口已被占用（端口: $UI_SERVER_PORT），自动改用端口: $default_port"
    set_ui_port "$default_port"
}

handle_occupied_port() {
    local port="$1"
    local owner_info="$2"
    local pid="${owner_info%%$'\t'*}"
    local process_name="${owner_info#*$'\t'}"

    if is_skywalking_process "$pid" "$process_name"; then
        log_warn "端口已被 SkyWalking 进程占用（端口: $port，PID: $pid）"
        if has_tty; then
            read -p "是否停止现有SkyWalking进程并重新安装? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if kill -0 "$pid" 2>/dev/null; then
                    kill -15 "$pid"
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid"
                    fi
                    log_info "已停止现有SkyWalking进程"
                    return 0
                fi
            fi
        fi
        log_info "安装已取消"
        exit 0
    fi

    log_warn "端口 $port 已被占用 (PID: $pid, 进程: $process_name)"
    if has_tty; then
        read -p "是否停止占用进程并继续? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                kill -15 "$pid"
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid"
                fi
                log_info "已停止占用端口的进程"
                return 0
            fi
        fi
    fi

    log_info "安装已取消"
    exit 0
}

check_port_availability() {
    local owner_info=""

    if owner_info=$(get_port_owner "$OAP_PORT"); then
        handle_occupied_port "$OAP_PORT" "$owner_info"
    fi

    if owner_info=$(get_port_owner "$OAP_HTTP_PORT"); then
        handle_occupied_port "$OAP_HTTP_PORT" "$owner_info"
    fi

    if owner_info=$(get_port_owner "$PROMQL_PORT"); then
        handle_occupied_port "$PROMQL_PORT" "$owner_info"
    fi

    if owner_info=$(get_port_owner "$UI_SERVER_PORT"); then
        local pid="${owner_info%%$'\t'*}"
        local process_name="${owner_info#*$'\t'}"
        if is_current_skywalking_server_process "$pid"; then
            log_warn "SkyWalking UI 端口已被当前实例占用（端口: $UI_SERVER_PORT），将停止旧实例并复用该端口"
            stop_existing_skywalking_server
            return 0
        fi

        if [ "$WEB_PORT_EXPLICIT" = true ]; then
            log_error "指定的 SkyWalking UI 端口已被占用（端口: $UI_SERVER_PORT，PID: $pid，进程: $process_name），请更换 --web-port"
            exit 1
        fi

        choose_available_ui_port
    fi
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
    
    # 检查 Java。macOS 非交互/launchd 环境可能只有 /usr/bin/java 占位符，必须解析真实 JDK。
    if ! configure_java_env; then
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
    fi

    # 检查 Java 版本
    local java_version
    java_version=$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F '"' '/version/ {print $2}' | sed 's/^1\.//' | cut -d'.' -f1)
    if [ -z "$java_version" ] || [ "$java_version" -lt 11 ]; then
        if [ "$FORCE" = true ]; then
            log_error "Java 版本过低 (${java_version:-unknown})，需要 Java 11 或更高版本"
            exit 1
        fi
        
        log_warn "Java 版本过低 (${java_version:-unknown})，需要 Java 11 或更高版本"
        echo
        if confirm_action "是否升级到 OpenJDK 17?"; then
            if install_jdk17 && configure_java_env; then
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
    
    log_info "Java 版本检查通过: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
    log_info "JAVA_HOME: $JAVA_HOME"
}

# 清理函数
cleanup() {
    if [ -f "$SW_TGZ" ]; then
        if [ "$KEEP_PACKAGE" = true ]; then
            :
        else
            log_info "清理临时文件: $SW_TGZ"
            rm -f "$SW_TGZ"
        fi
    fi
    
    if [ -f "$SKYWALKING_AGENT_TGZ" ]; then
        if [ "$KEEP_PACKAGE" = true ]; then
            :
        else
            log_info "清理临时文件: $SKYWALKING_AGENT_TGZ"
            rm -f "$SKYWALKING_AGENT_TGZ"
        fi
    fi
}

# 生成启动脚本
generate_startup_scripts() {
    local startup_dir="$SW_HOME/bin"
    configure_java_env || {
        log_error "无法生成启动脚本：未找到可用 Java"
        return 1
    }
    
    # 生成启动脚本
cat > "$startup_dir/start-all.sh" << EOF
#!/bin/bash
# SkyWalking 服务启动脚本

SW_HOME="$SW_HOME"
export JAVA_HOME="$JAVA_HOME"
export PATH="\$JAVA_HOME/bin:\$PATH"

echo "启动 SkyWalking 服务..."

while read -r pid; do
  [ -n "\$pid" ] || continue
  args=\$(ps -p "\$pid" -o args= 2>/dev/null || true)
  if [[ "\$args" == *"\$SW_HOME"* ]] && [[ "\$args" == *"OAPServerStartUp"* || "\$args" == *"ApplicationStartUp"* || "\$args" == *"skywalking-oap-server"* || "\$args" == *"skywalking-webapp"* ]]; then
    echo "停止已有 SkyWalking 进程: \$pid"
    kill -15 "\$pid" 2>/dev/null || true
  fi
done < <(pgrep -f "\$SW_HOME" 2>/dev/null || true)

sleep 3

# 启动 OAP 服务
cd "\$SW_HOME/bin"
nohup ./oapService.sh > "\$SW_HOME/logs/oap-startup.log" 2>&1 &
echo "OAP 服务已启动"

# 等待 OAP 服务启动
for i in {1..60}; do
  if lsof -nP -iTCP:$OAP_HTTP_PORT -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$PROMQL_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

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
    local service_file="/etc/systemd/system/skywalking.service"
    local stop_script="$SCRIPT_DIR/stop.sh"
    
    cat > "$service_file" << EOF
[Unit]
Description=SkyWalking APM
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=$SW_HOME
ExecStart=$SW_HOME/bin/start-all.sh
ExecStop=$stop_script
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "已生成 systemd 服务文件: $service_file"
}

generate_launchd_service() {
    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/org.apache.skywalking.plist"
    local stop_script="$SCRIPT_DIR/stop.sh"

    configure_java_env || {
        log_error "无法生成 launchd 服务：未找到可用 Java"
        return 1
    }

    mkdir -p "$plist_dir"
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>org.apache.skywalking</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SW_HOME/bin/start-all.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$SW_HOME</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>JAVA_HOME</key>
    <string>$JAVA_HOME</string>
    <key>PATH</key>
    <string>$JAVA_HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$SW_HOME/logs/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$SW_HOME/logs/launchd.err.log</string>
</dict>
</plist>
EOF

    log_info "已生成 launchd 服务文件: $plist_file"
    log_info "停止脚本: $stop_script"
}

install_autostart_service() {
    if [ "$INSTALL_MODE" != "all" ] && [ "$INSTALL_MODE" != "server" ]; then
        return 0
    fi

    local os_name
    os_name="$(uname -s)"

    if [ "$os_name" = "Linux" ] && command_exists systemctl; then
        if [ "$EUID" -ne 0 ]; then
            log_info "自启动服务: Linux/systemd 需要 root 权限，可稍后使用 sudo 重新运行或手动配置"
            return 0
        fi

        if has_tty; then
            if confirm_action "是否安装并启用 SkyWalking systemd 自启动服务?"; then
                generate_systemd_service
                systemctl enable skywalking
                log_info "已启用 systemd 自启动服务: skywalking"
            else
                log_info "已跳过自启动服务安装；如需启用，可运行: systemctl enable skywalking"
            fi
        else
            log_info "非交互模式跳过自启动服务安装；如需启用，可运行: systemctl enable skywalking"
        fi
        return 0
    fi

    if [ "$os_name" = "Darwin" ] && command_exists launchctl; then
        if has_tty; then
            if confirm_action "是否安装 SkyWalking macOS LaunchAgent 自启动服务?"; then
                generate_launchd_service
                log_info "已安装 launchd 自启动服务: org.apache.skywalking（下次登录自动启动）"
                log_info "如需立即重新加载服务，可先停止当前服务后运行: launchctl load -w ~/Library/LaunchAgents/org.apache.skywalking.plist"
            else
                log_info "已跳过自启动服务安装；如需启用，可运行: launchctl load -w ~/Library/LaunchAgents/org.apache.skywalking.plist"
            fi
        else
            log_info "非交互模式跳过自启动服务安装；如需启用，可运行: launchctl load -w ~/Library/LaunchAgents/org.apache.skywalking.plist"
        fi
        return 0
    fi

    log_info "当前系统暂未自动配置自启动服务，可使用启动脚本: $SW_HOME/bin/start-all.sh"
}

configure_mysql_monitoring_if_requested() {
    if [ "$ENABLE_MYSQL_MONITORING" != true ]; then
        return 0
    fi

    if [ "$INSTALL_MODE" = "agent" ]; then
        log_warn "仅 agent 模式不启动 OAP，跳过 MySQL Server 指标接入"
        return 0
    fi

    if [ ! -f "$MYSQL_MONITOR_SCRIPT" ]; then
        log_warn "MySQL 指标接入脚本不存在，跳过: $MYSQL_MONITOR_SCRIPT"
        return 0
    fi

    log_info "开始配置 MySQL Server 指标接入 SkyWalking..."
    if bash "$MYSQL_MONITOR_SCRIPT" \
        --mysql-exporter-target "$MYSQL_EXPORTER_TARGET" \
        --oap-endpoint "127.0.0.1:$OAP_PORT" \
        --host-name "$MYSQL_MONITOR_HOST_NAME" \
        --service-name "$MYSQL_MONITOR_SERVICE_NAME" \
        --scrape-interval "$MYSQL_MONITOR_SCRAPE_INTERVAL" \
        --force; then
        log_info "MySQL Server 指标接入配置完成"
    else
        log_warn "MySQL Server 指标接入配置失败；请确认 mysqld_exporter 已启动: http://$MYSQL_EXPORTER_TARGET/metrics"
    fi
}

configure_vm_monitoring_if_requested() {
    if [ "$ENABLE_VM_MONITORING" != true ]; then
        return 0
    fi

    if [ "$INSTALL_MODE" = "agent" ]; then
        log_warn "仅 agent 模式不启动 OAP，跳过 Linux 主机指标接入"
        return 0
    fi

    if [ ! -f "$VM_MONITOR_SCRIPT" ]; then
        log_warn "Linux 主机指标接入脚本不存在，跳过: $VM_MONITOR_SCRIPT"
        return 0
    fi

    local vm_args=(
        --node-exporter-target "$NODE_EXPORTER_TARGET"
        --oap-endpoint "127.0.0.1:$OAP_PORT"
        --host-name "$VM_MONITOR_HOST_NAME"
        --service-name "$VM_MONITOR_SERVICE_NAME"
        --scrape-interval "$VM_MONITOR_SCRAPE_INTERVAL"
        --force
    )

    if [ "$VM_MONITOR_START_NODE_EXPORTER" = true ]; then
        vm_args+=(--start-node-exporter)
    fi

    log_info "开始配置 Linux 主机指标接入 SkyWalking..."
    if bash "$VM_MONITOR_SCRIPT" "${vm_args[@]}"; then
        log_info "Linux 主机指标接入配置完成"
    else
        log_warn "Linux 主机指标接入配置失败；请确认 node_exporter 已启动: http://$NODE_EXPORTER_TARGET/metrics"
    fi
}

show_install_summary() {
    echo
    log_info "SkyWalking 安装完成"
    log_info "安装目录: $SW_HOME"
    log_info "安装模式: $INSTALL_MODE"

    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        log_info "OAP gRPC: localhost:$OAP_PORT"
        log_info "OAP HTTP/GraphQL: http://localhost:$OAP_HTTP_PORT"
        log_info "PromQL API: http://localhost:$PROMQL_PORT"
        log_info "UI 访问地址: http://localhost:$UI_SERVER_PORT"
        log_info "启动脚本: $SW_HOME/bin/start-all.sh"
        log_info "停止脚本: $SCRIPT_DIR/stop.sh"
        log_info "日志目录: $SW_HOME/logs"
        if [ "$ENABLE_MYSQL_MONITORING" = true ]; then
            log_info "MySQL Server 指标: mysqld_exporter $MYSQL_EXPORTER_TARGET -> OTel Collector -> OAP localhost:$OAP_PORT"
        else
            log_info "MySQL Server 指标接入: 可运行 $0 --enable-mysql-monitoring（需先启动 mysqld_exporter）"
        fi
        if [ "$ENABLE_VM_MONITORING" = true ]; then
            log_info "Linux 主机指标: node_exporter $NODE_EXPORTER_TARGET -> OTel Collector -> OAP localhost:$OAP_PORT"
        else
            log_info "Linux 主机指标接入: 可运行 $0 --enable-vm-monitoring（需先启动 node_exporter）"
        fi
    fi

    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "agent" ]; then
        log_info "Agent 配置: $SKYWALKING_AGENT_BASE_DIR/config/agent.config"
    fi

    if [ "$KEEP_PACKAGE" = true ]; then
        log_info "已保留安装包: $SW_TGZ"
        if [ -f "$SKYWALKING_AGENT_TGZ" ]; then
            log_info "已保留 Agent 包: $SKYWALKING_AGENT_TGZ"
        fi
    fi

    log_info "卸载命令: $0 -u -d $SW_HOME"
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
        reuse_existing_ui_port
        stop_existing_skywalking_server
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
        configure_agent_collector || log_warn "Agent collector 配置未更新，请检查: $SKYWALKING_AGENT_BASE_DIR/config/agent.config"
    fi
    
    # 根据安装模式执行不同的检查和生成步骤
    if [ "$INSTALL_MODE" = "all" ] || [ "$INSTALL_MODE" = "server" ]; then
        configure_vm_monitoring_if_requested
        configure_mysql_monitoring_if_requested
        generate_startup_scripts
        install_autostart_service
    fi

    INSTALL_SUCCEEDED=true
    show_install_summary
}

# 执行主函数
main "$@"

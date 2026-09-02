#!/bin/bash
# common.sh - RocketMQ 脚本公共函数库

# === 公共配置参数 ===
readonly DEFAULT_INSTALL_DIR="$HOME/rocketmq"
readonly DEFAULT_VERSION="5.3.3"
readonly DEFAULT_DOWNLOAD_URL="https://dist.apache.org/repos/dist/release/rocketmq/${DEFAULT_VERSION}/rocketmq-all-${DEFAULT_VERSION}-bin-release.zip"
readonly DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
readonly TEMP_EXTRACT_DIR="/tmp"

# === 日志函数 ===
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_FILE:-/tmp/rocketmq_common.log}"
    echo "[$timestamp] [$level] $message" | tee -a "$log_file"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

# === 工具函数 ===
get_os() {
    uname -s | tr '[:upper:]' '[:lower:]'
}

get_ip() {
    # Linux
    if command -v hostname >/dev/null 2>&1 && [ "$(get_os)" != "darwin" ]; then
        hostname -I | awk '{print $1}' 2>/dev/null
    # macOS
    elif [ "$(get_os)" = "darwin" ]; then
        ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1
    # 通用方式
    else
        hostname -f 2>/dev/null || echo "127.0.0.1"
    fi
}

validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra parts <<< "$ip"
        for part in "${parts[@]}"; do
            if (( part < 0 || part > 255 )); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# === 进程管理函数 ===
check_running_processes() {
    local namesrv_running broker_running
    namesrv_running=$(pgrep -f 'mqnamesrv|org\.apache\.rocketmq\.namesrv\.NamesrvStartup' || true)
    broker_running=$(pgrep -f 'mqbroker|org\.apache\.rocketmq\.broker\.BrokerStartup' || true)
    
    if [ -n "$namesrv_running" ] || [ -n "$broker_running" ]; then
        log_info "检测到 RocketMQ 进程正在运行"
        if [ -n "$namesrv_running" ]; then
            echo "NameServer 进程: $namesrv_running"
        fi
        if [ -n "$broker_running" ]; then
            echo "Broker 进程: $broker_running"
        fi
        return 0
    else
        log_info "未检测到运行中的 RocketMQ 进程"
        return 1
    fi
}

# === 配置管理函数 ===
validate_config() {
    local config_file="$1"
    
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi
    
    # 检查是否可读
    if [ ! -r "$config_file" ]; then
        log_error "配置文件不可读: $config_file"
        return 1
    fi
    
    log_info "配置文件验证通过: $config_file"
    return 0
}

create_pid_file() {
    local service_type="$1"
    local pid="$2"
    local install_dir="${3:-$DEFAULT_INSTALL_DIR}"
    local pid_dir="$install_dir/run"
    
    mkdir -p "$pid_dir"
    local pid_file="$pid_dir/${service_type}.pid"
    echo $pid > "$pid_file"
}

get_pid_from_file() {
    local service_type="$1"
    local install_dir="${2:-$DEFAULT_INSTALL_DIR}"
    local pid_file="$install_dir/run/${service_type}.pid"
    
    if [ -f "$pid_file" ]; then
        cat "$pid_file"
    fi
}

remove_pid_file() {
    local service_type="$1"
    local install_dir="${2:-$DEFAULT_INSTALL_DIR}"
    local pid_file="$install_dir/run/${service_type}.pid"
    
    if [ -f "$pid_file" ]; then
        rm -f "$pid_file"
    fi
}

# === 环境设置函数 ===
setup_jdk_env() {
    local file="$1"
    local os="${2:-$(get_os)}"
    
    # 检查文件是否存在
    if [ ! -f "$file" ]; then
        log_warn "文件不存在: $file"
        return
    fi
    
    # 检查是否已经设置了JAVA_HOME
    if grep -q "JAVA_HOME" "$file"; then
        log_info "文件 $file 已包含 JAVA_HOME 配置"
        return
    fi
    
    # 尝试查找可用的JDK
    local java_home_found=false
    if command -v update-alternatives &>/dev/null && update-alternatives --list java &>/dev/null; then
        local possible_jdk_paths=$(update-alternatives --list java | grep -E "(jdk-11|java-1.11|jdk-8|java-1.8)" || update-alternatives --list java | head -n1)
        local jdk_path=$(echo "$possible_jdk_paths" | head -n1)
        if [ -n "$jdk_path" ]; then
            local calculated_java_home=$(dirname "$(dirname "$(readlink -f "$jdk_path")")")
            local sed_opt=""
            if [ "$os" = "darwin" ]; then
                sed_opt="''"
            fi
            sed -i "$sed_opt" '2iexport JAVA_HOME='"$calculated_java_home" "$file" 2>/dev/null || true
            java_home_found=true
            log_info "为 $file 设置 JAVA_HOME=$calculated_java_home"
        fi
    fi
    
    if [ "$java_home_found" = false ]; then
        log_warn "未找到 JDK，使用系统默认 Java 环境"
    fi
}

# === 服务健康检查函数 ===
check_namesrv_health() {
    local namesrv_addr="$1"
    local timeout="${2:-10}"
    
    # 尝试连接到NameServer端口
    if command -v nc >/dev/null 2>&1; then
        # 使用nc检查端口是否开放
        if nc -z -w$timeout ${namesrv_addr%:*} ${namesrv_addr#*:}; then
            log_info "NameServer $namesrv_addr 服务正常"
            return 0
        else
            log_error "NameServer $namesrv_addr 服务异常"
            return 1
        fi
    else
        log_warn "未安装netcat，跳过健康检查"
        return 0
    fi
}

check_broker_health() {
    local broker_addr="$1"
    local timeout="${2:-10}"
    
    # 尝试连接到Broker端口
    if command -v nc >/dev/null 2>&1; then
        # 使用nc检查端口是否开放
        if nc -z -w$timeout ${broker_addr%:*} ${broker_addr#*:}; then
            log_info "Broker $broker_addr 服务正常"
            return 0
        else
            log_error "Broker $broker_addr 服务异常"
            return 1
        fi
    else
        log_warn "未安装netcat，跳过健康检查"
        return 0
    fi
}

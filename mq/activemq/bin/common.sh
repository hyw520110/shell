#!/bin/bash

# ActiveMQ/Artemis 公共函数库
# 包含所有脚本共享的函数

# 公共变量
DEFAULT_INSTALL_DIR="$HOME/activemq"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_ARTEMIS_VERSION="2.41.0"
DEFAULT_CLASSIC_VERSION="6.1.7"
DEFAULT_LOG_LEVEL="INFO"

# 默认端口
DEFAULT_BROKER_PORT="61616"
DEFAULT_JETTY_PORT="8161"
DEFAULT_AMQP_PORT="5672"
DEFAULT_STOMP_PORT="61613"
DEFAULT_MQTT_PORT="1883"
DEFAULT_WS_PORT="61614"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 下载链接数组（按优先级排序）
declare -a CLASSIC_DOWNLOAD_MIRRORS=(
    "https://archive.apache.org/dist/activemq/$DEFAULT_CLASSIC_VERSION/apache-activemq-$DEFAULT_CLASSIC_VERSION-bin.tar.gz"
    "https://downloads.apache.org/activemq/$DEFAULT_CLASSIC_VERSION/apache-activemq-$DEFAULT_CLASSIC_VERSION-bin.tar.gz"
)
declare -a ARTEMIS_DOWNLOAD_MIRRORS=(
    "https://archive.apache.org/dist/activemq/activemq-artemis/$DEFAULT_ARTEMIS_VERSION/apache-artemis-$DEFAULT_ARTEMIS_VERSION-bin.tar.gz"
    "https://downloads.apache.org/activemq/activemq-artemis/$DEFAULT_ARTEMIS_VERSION/apache-artemis-$DEFAULT_ARTEMIS_VERSION-bin.tar.gz"
)

# 通用日志函数
log_message() {
    local level=$1
    local message=$2
    local color=""
    
    # 检查是否应该记录此级别的日志
    case "$LOG_LEVEL" in
        DEBUG)
            # DEBUG级别显示所有日志
            ;;
        INFO)
            # INFO级别显示INFO、WARN、ERROR
            [[ "$level" != "DEBUG" ]] || return 0
            ;;
        WARN)
            # WARN级别显示WARN、ERROR
            [[ "$level" == "WARN" || "$level" == "ERROR" ]] || return 0
            ;;
        ERROR)
            # ERROR级别只显示ERROR
            [[ "$level" == "ERROR" ]] || return 0
            ;;
        *)
            # 默认显示所有日志
            ;;
    esac
    
    # 设置颜色
    case "$level" in
        DEBUG|INFO)
            color="$GREEN"
            ;;
        WARN)
            color="$YELLOW"
            ;;
        ERROR)
            color="$RED"
            ;;
    esac
    
    # 输出日志
    if [[ -t 1 ]]; then
        echo -e "${color}[$level]${NC} $message" >&2
    else
        echo "[$level] $message" >&2
    fi
}

# 简化版验证安装目录有效性，不输出日志
validate_install_dir() {
    local install_dir="$1"
    if [[ -z "$install_dir" ]]; then
        echo "错误: 安装目录未指定"
        return 1
    fi
    
    if [[ ! -d "$install_dir" ]]; then
        echo "错误: 安装目录不存在: $install_dir"
        return 1
    fi
    
    if [[ ! -r "$install_dir" ]]; then
        echo "错误: 安装目录无读取权限: $install_dir"
        return 1
    fi
    
    return 0
}

# 检测并设置MQ类型
detect_mq_type_by_path() {
    local install_dir="$1"
    local silent="${2:-false}"  # 添加静默参数
    
    # 首先检查安装目录中是否存在可执行文件
    if [[ -x "$install_dir/bin/artemis" ]]; then
        [[ "$silent" != "true" ]] && log_debug "检测到Artemis MQ"
        echo "artemis"
        return
    elif [[ -x "$install_dir/bin/activemq" ]]; then
        [[ "$silent" != "true" ]] && log_debug "检测到Classic MQ"
        echo "classic"
        return
    fi
    
    # 如果安装目录中没有可执行文件，尝试通过进程检测MQ类型
    if pgrep -f "artemis.*run|org.apache.activemq.artemis|Artemis" > /dev/null 2>&1; then
        [[ "$silent" != "true" ]] && log_debug "通过进程检测到Artemis MQ"
        echo "artemis"
        return
    elif pgrep -f "activemq.jar|org.apache.activemq|ActiveMQ" > /dev/null 2>&1; then
        [[ "$silent" != "true" ]] && log_debug "通过进程检测到Classic MQ"
        echo "classic"
        return
    fi
    
    # 如果都没有检测到，返回默认类型
    # 不记录警告日志，因为这是正常情况
    echo "artemis"  # 默认使用artemis而不是classic
}

# 获取MQ名称的文本描述
get_mq_display_name() {
    local mq_type="$1"
    case "$mq_type" in
        "artemis") echo "ActiveMQ Artemis" ;;
        "classic") echo "ActiveMQ Classic" ;;
        *) echo "Unknown MQ" ;;
    esac
}

# 检查Java 17兼容性并设置参数
setup_java17_compatibility_by_type() {
    local install_dir="$1"
    local mq_type="$2"
    
    log_info "检查并设置Java 17兼容性参数..."
    
    # 检查Java版本
    if command -v java &> /dev/null; then
        if java -version 2>&1 | grep -q "17"; then
            log_info "检测到Java 17，设置兼容性参数: -XX:-UseContainerSupport"
            
            local conf_dir="$install_dir/conf"
            
            # 为ActiveMQ Classic设置参数
            if [[ "$mq_type" == "classic" ]]; then
                local setenv_file="$conf_dir/setenv"
                if [[ -d "$conf_dir" ]]; then
                    log_debug "更新setenv文件: $setenv_file"
                    if [[ ! -f "$setenv_file" ]]; then
                        touch "$setenv_file"
                    fi
                    
                    # 检查是否已经包含Java 17参数
                    if ! grep -q "XX:-UseContainerSupport" "$setenv_file"; then
                        log_info "在 $setenv_file 头部添加Java 17兼容性参数"
                        local temp_file=$(mktemp)
                        {
                            echo '# Added by install script for Java 17 compatibility'
                            echo 'export ACTIVEMQ_OPTS="-XX:-UseContainerSupport $ACTIVEMQ_OPTS"'
                            echo ''
                        } > "$temp_file"
                        cat "$setenv_file" >> "$temp_file"
                        # 使用mv替换，并处理权限问题
                        mv "$temp_file" "$setenv_file" || sudo mv "$temp_file" "$setenv_file"
                    else
                        log_debug "Java 17兼容性参数已存在于 $setenv_file"
                    fi
                fi
            fi
            
            # 为ActiveMQ Artemis设置参数
            if [[ "$mq_type" == "artemis" ]]; then
                # Artemis使用环境变量
                export ARTEMIS_OPTS="${ARTEMIS_OPTS} -XX:-UseContainerSupport"
                log_debug "设置ARTEMIS_OPTS环境变量: $ARTEMIS_OPTS"
            fi
        else
            log_debug "Java版本不是17，跳过兼容性参数设置"
        fi
    else
        log_warn "未找到Java命令，跳过兼容性参数设置"
    fi
}

# 简化日志函数
log_debug() {
    log_message "DEBUG" "$1"
}

log_info() {
    log_message "INFO" "$1"
}

log_warn() {
    log_message "WARN" "$1"
}

log_error() {
    log_message "ERROR" "$1"
}

# MQ类型检测函数
# 参数: $1 = MQ类型 (artemis|classic)，可选
is_artemis() {
    local mq_type="$1"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="${MQ_TYPE:-classic}"
    fi
    
    [[ "$mq_type" == "artemis" ]]
}

# 参数: $1 = MQ类型 (artemis|classic)，可选
is_classic() {
    local mq_type="$1"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="${MQ_TYPE:-classic}"
    fi
    
    [[ "$mq_type" == "classic" ]]
}

# 设置目录权限的封装函数
set_directory_permissions() {
    local dir_path="$1"
    local owner="${2:-$(whoami):$(whoami)}"
    
    log_debug "设置目录权限: $dir_path, 所有者: $owner"
    sudo chown -R "$owner" "$dir_path/" 2>/dev/null || chown -R "$owner" "$dir_path/" 2>/dev/null || true
    sudo chmod -R 755 "$dir_path/" 2>/dev/null || chmod -R 755 "$dir_path/" 2>/dev/null || true
}

# 设置目录权限并记录日志
set_directory_permissions_with_logging() {
    local dir_path="$1"
    local owner="${2:-$(whoami):$(whoami)}"
    local context="${3:-目录}"
    
    log_debug "修复${context}权限: $dir_path"
    set_directory_permissions "$dir_path" "$owner"
}

# 封装命令执行函数，支持自动提权执行
execute_command() {
    local command="$1"
    local description="${2:-执行命令}"
    
    log_debug "$description: $command"
    
    # 首先尝试普通执行
    if eval "$command"; then
        return 0
    else
        log_debug "普通执行失败，尝试提权执行"
        # 如果普通执行失败，尝试使用sudo提权执行
        if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
            if eval "sudo $command"; then
                return 0
            else
                log_warn "提权执行也失败: $command"
                return 1
            fi
        else
            log_warn "无法提权执行（没有sudo权限或sudo需要密码）: $command"
            return 1
        fi
    fi
}

# 为Java 17设置兼容参数
setup_java17_compatibility() {
    local mq_home=$(get_mq_home)
    local mq_conf=$(get_mq_conf)
    
    log_info "检查并设置Java 17兼容性参数..."
    
    # 检查Java版本
    if command -v java &> /dev/null; then
        if java -version 2>&1 | grep -q "17"; then
            log_info "检测到Java 17，设置兼容性参数: -XX:-UseContainerSupport"
            
            # 为ActiveMQ Classic设置参数
            if is_classic; then
                local setenv_file="$mq_conf/setenv"
                if [[ -d "$mq_conf" ]]; then
                    log_debug "更新setenv文件: $setenv_file"
                    # 修复 TODO: 修改setenv_file 在文件头部添加JAVA17兼容参数
                    if [[ ! -f "$setenv_file" ]]; then
                        touch "$setenv_file"
                    fi
                    
                    # 检查是否已经包含Java 17参数
                    if ! grep -q "XX:-UseContainerSupport" "$setenv_file"; then
                        {
                            echo '# Added by install script for Java 17 compatibility'
                            echo 'export ACTIVEMQ_OPTS="-XX:-UseContainerSupport $ACTIVEMQ_OPTS"'
                        } >> "$setenv_file"
                    fi
                fi
            fi
            
            # 为ActiveMQ Artemis设置参数
            if is_artemis; then
                # Artemis使用环境变量
                export ARTEMIS_OPTS="${ARTEMIS_OPTS} -XX:-UseContainerSupport"
                log_debug "设置ARTEMIS_OPTS环境变量: $ARTEMIS_OPTS"
            fi
        else
            log_debug "Java版本不是17，跳过兼容性参数设置"
        fi
    else
        log_warn "未找到Java命令，跳过兼容性参数设置"
    fi
}

# 获取MQ HOME路径
get_mq_home() {
    echo "${MQ_HOME:-$INSTALL_DIR}"
}

# 获取MQ BIN路径
get_mq_bin() {
    echo "${MQ_HOME:-$INSTALL_DIR}/bin"
}

# 获取MQ配置路径
get_mq_conf() {
    echo "${MQ_CONF:-${MQ_HOME:-$INSTALL_DIR}/conf}"
}

# 获取MQ数据路径
get_mq_data() {
    echo "${MQ_DATA:-${MQ_HOME:-$INSTALL_DIR}/data}"
}

# 获取MQ PID文件路径
get_mq_pid_file() {
    if is_artemis; then
        echo "$(get_mq_data)/artemis.pid"
    else
        echo "$(get_mq_data)/activemq.pid"
    fi
}

# 获取MQ启动脚本路径
get_mq_start_script() {
    if is_artemis; then
        echo "$(get_mq_bin)/artemis"
    else
        echo "$(get_mq_bin)/activemq"
    fi
}

# 获取MQ停止脚本路径
get_mq_stop_script() {
    if is_artemis; then
        echo "$(get_mq_bin)/artemis"
    else
        echo "$(get_mq_bin)/activemq"
    fi
}

# 获取MQ服务名称
get_mq_service_name() {
    if is_artemis; then
        echo "artemis"
    else
        echo "activemq"
    fi
}

# 获取MQ名称
# 参数: $1 = MQ类型 (artemis|classic)，可选
get_mq_name() {
    local mq_type="$1"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="${MQ_TYPE:-classic}"
    fi
    
    if [[ "$mq_type" == "artemis" ]]; then
        echo "ActiveMQ Artemis"
    else
        echo "ActiveMQ Classic"
    fi
}

# 检测操作系统类型
detect_os() {
    case "$(uname -s)" in
        Linux*)
            echo "Linux"
            ;;
        Darwin*)
            echo "MacOS"
            ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            return 1
            ;;
    esac
}

# 收集可能的ActiveMQ相关进程PID（通过命令行和端口）
collect_pids() {
    local pids_cmd=""
    local pids_ports=""
    
    if is_artemis; then
        pids_cmd=$(pgrep -f "artemis.*run|org.apache.activemq.artemis|Artemis" 2>/dev/null || true)
    else
        pids_cmd=$(pgrep -f "activemq.jar|org.apache.activemq|ActiveMQ" 2>/dev/null || true)
    fi
    
    if command -v ss &> /dev/null; then
        pids_ports=$(ss -tlnp 2>/dev/null | grep -E ":$DEFAULT_BROKER_PORT|:$DEFAULT_JETTY_PORT" | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | tr '\n' ' ')
    elif command -v lsof &> /dev/null; then
        pids_ports=$( (lsof -i:$DEFAULT_BROKER_PORT -t 2>/dev/null; lsof -i:$DEFAULT_JETTY_PORT -t 2>/dev/null) | tr '\n' ' ')
    fi
    
    echo "$pids_cmd $pids_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' '
}

# 检查Java环境
check_java() {
    if ! command -v java &> /dev/null; then
        log_error "Java未安装，请先安装Java"
        return 1
    fi
    
    java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log_info "检测到Java版本: $java_version"
    return 0
}

# 验证安装
verify_installation() {
    log_info "验证$(get_mq_name)安装..."
    
    # 获取日志文件路径
    local log_file_path=$(get_log_file_path)
    
    # 验证MQ启动状态
    if verify_mq_startup; then
        log_info "$(get_mq_name)启动成功"
        
        # 显示进程信息
        show_process_info
        
        # 显示端口信息
        show_port_info
        
        # 显示日志信息
        show_log_info
    else
        log_warn "$(get_mq_name)启动失败，请检查日志文件"
        if [[ -n "$log_file_path" ]]; then
            tail -n 20 "$log_file_path" 2>/dev/null || echo "无法读取日志文件: $log_file_path"
        fi
        # 即使启动失败，也显示进程、端口和日志信息以帮助诊断
        show_process_info
        show_port_info
        show_log_info
        return 1
    fi
    
    # 尝试连接管理端口
    if command -v curl &> /dev/null; then
        if curl -s --connect-timeout 10 http://localhost:$DEFAULT_JETTY_PORT > /dev/null; then
            log_info "$(get_mq_name)管理界面可访问: http://localhost:$DEFAULT_JETTY_PORT"
            log_info "默认用户名/密码: admin/admin (请在生产环境中修改)"
        else
            log_warn "无法连接到管理界面，请检查配置"
        fi
    fi
    
    return 0
}

# 获取并显示进程信息
show_process_info() {
    log_info "正在获取$(get_mq_name)进程信息..."
    
    # 使用官方status命令获取进程信息
    local mq_home=$(get_mq_home)
    local mq_bin=$(get_mq_bin)
    
    if [[ -x "$(get_mq_start_script)" ]]; then
        log_info "使用官方status命令获取进程信息..."
        
        if is_artemis; then
            # 对于Artemis，使用status命令
            if [[ -x "$mq_bin/artemis" ]]; then
                local status_output=$("$mq_bin/artemis" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "ActiveMQ Artemis服务正在运行"
                    log_debug "Status输出: $status_output"
                    # 尝试提取PID信息
                    local pid_from_status=$(echo "$status_output" | grep -o "pid '[0-9]*'" | grep -o "[0-9]*")
                    if [[ -n "$pid_from_status" ]]; then
                        log_info "ActiveMQ Artemis进程PID: $pid_from_status"
                        if command -v ps &> /dev/null; then
                            log_info "ActiveMQ Artemis进程详情:"
                            ps -p "$pid_from_status" -f 2>/dev/null || log_warn "无法获取进程详情"
                        fi
                    fi
                else
                    log_warn "ActiveMQ Artemis服务未运行"
                    log_debug "Status输出: $status_output"
                fi
            fi
        else
            # 对于Classic，使用status命令
            if [[ -x "$mq_bin/activemq" ]]; then
                local status_output=$("$mq_bin/activemq" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "ActiveMQ Classic服务正在运行"
                    log_debug "Status输出: $status_output"
                    # 尝试提取PID信息
                    local pid_from_status=$(echo "$status_output" | grep -o "pid '[0-9]*'" | grep -o "[0-9]*")
                    if [[ -n "$pid_from_status" ]]; then
                        log_info "ActiveMQ Classic进程PID: $pid_from_status"
                        if command -v ps &> /dev/null; then
                            log_info "ActiveMQ Classic进程详情:"
                            ps -p "$pid_from_status" -f 2>/dev/null || log_warn "无法获取进程详情"
                        fi
                    fi
                else
                    log_warn "ActiveMQ Classic服务未运行"
                    log_debug "Status输出: $status_output"
                fi
            fi
        fi
        return 0
    fi
    
    # 如果status命令不可用，回退到进程检查
    log_info "Status命令不可用，回退到进程检查..."
    
    # 通过关键词查找进程
    local PID=$(collect_pids)
    if [[ -n "$PID" ]]; then
        if is_artemis; then
            log_info "通过进程名找到ActiveMQ Artemis进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Artemis进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
        else
            log_info "通过进程名找到ActiveMQ Classic进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Classic进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
        fi
        return 0
    else
        log_warn "未找到$(get_mq_name)进程"
        return 1
    fi
}

# 获取并显示端口信息
show_port_info() {
    log_info "正在获取$(get_mq_name)端口信息..."
    
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    local stomp_port=${STOMP_PORT:-61613}
    local mqtt_port=${MQTT_PORT:-1883}
    local ws_port=${WS_PORT:-61614}
    
    # 检查$(get_mq_name)常用端口
    local ACTIVE_PORTS=()
    
    # 优先使用ss命令，如果不存在则使用lsof，最后使用netstat
    if command -v ss &> /dev/null; then
        log_info "使用ss命令检查端口..."
        # 查找与$(get_mq_name)相关的监听端口
        ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -i activemq | awk '{print $4}' | sed 's/.*://' | sort -u) )
        ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -i artemis | awk '{print $4}' | sed 's/.*://' | sort -u) )
        # 如果没有找到特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        fi
    elif command -v lsof &> /dev/null; then
        log_info "使用lsof命令检查端口..."
        # 查找与$(get_mq_name)相关的监听端口
        ACTIVE_PORTS+=( $(lsof -i -P -n 2>/dev/null | grep -i activemq | grep LISTEN | awk '{print $9}' | sed 's/.*://' | sort -u) )
        ACTIVE_PORTS+=( $(lsof -i -P -n 2>/dev/null | grep -i artemis | grep LISTEN | awk '{print $9}' | sed 's/.*://' | sort -u) )
        # 如果没有找到特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(lsof -i :$broker_port,:$jetty_port,:$amqp_port,:$stomp_port,:$mqtt_port,:$ws_port -sTCP:LISTEN -n 2>/dev/null | awk '{print $9}' | sed 's/.*://' | sort -u) )
        fi
    elif command -v netstat &> /dev/null; then
        log_info "使用netstat命令检查端口..."
        # 查找与$(get_mq_name)相关的监听端口
        ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -i activemq | awk '{print $4}' | sed 's/.*://' | sort -u) )
        ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -i artemis | awk '{print $4}' | sed 's/.*://' | sort -u) )
        # 如果没有找到特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        fi
    else
        log_warn "系统中未找到ss、lsof或netstat命令，无法检测端口"
        return 1
    fi
    
    # 如果还是没有找到端口，等待几秒再检查一次
    if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
        log_info "等待5秒后再次检查端口..."
        sleep 5
        if command -v ss &> /dev/null; then
            ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        elif command -v lsof &> /dev/null; then
            ACTIVE_PORTS+=( $(lsof -i :$broker_port,:$jetty_port,:$amqp_port,:$stomp_port,:$mqtt_port,:$ws_port -sTCP:LISTEN -n 2>/dev/null | awk '{print $9}' | sed 's/.*://' | sort -u) )
        elif command -v netstat &> /dev/null; then
            ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        fi
    fi
    
    if [[ ${#ACTIVE_PORTS[@]} -gt 0 ]]; then
        log_info "$(get_mq_name)端口信息:"
        for port in "${ACTIVE_PORTS[@]}"; do
            case $port in
                $broker_port)    desc="OpenWire (消息传输)" ;;
                $jetty_port)     desc="Web Console" ;;
                $amqp_port)      desc="AMQP" ;;
                $stomp_port)     desc="STOMP" ;;
                $mqtt_port)      desc="MQTT" ;;
                $ws_port)        desc="WebSocket" ;;
                *)               desc="未知协议" ;;
            esac
            log_info "  $port: $desc"
        done
    else
        log_warn "未找到$(get_mq_name)监听的端口"
        log_info "可能的原因:"
        log_info "  1. $(get_mq_name)服务未启动"
        log_info "  2. 端口配置有误"
        log_info "  3. 防火墙阻止了端口"
    fi
}

# 验证$(get_mq_name)是否成功启动
verify_mq_startup() {
    log_info "验证$(get_mq_name)启动状态..."
    
    # 等待一段时间让服务完全启动
    log_debug "等待5秒让服务完全启动..."
    sleep 5
    
    # 使用官方status命令检查服务状态
    local mq_home=$(get_mq_home)
    local mq_bin=$(get_mq_bin)
    
    if [[ -x "$(get_mq_start_script)" ]]; then
        log_info "使用官方status命令检查服务状态..."
        
        if is_artemis; then
            # 对于Artemis，使用status命令
            if [[ -x "$mq_bin/artemis" ]]; then
                local status_output=$("$mq_bin/artemis" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "$(get_mq_name)服务正在运行"
                    log_debug "Status输出: $status_output"
                    return 0
                else
                    log_warn "$(get_mq_name)服务未运行"
                    log_debug "Status输出: $status_output"
                    # 等待更长时间再次检查
                    sleep 10
                    status_output=$("$mq_bin/artemis" status 2>&1)
                    if echo "$status_output" | grep -q "is running"; then
                        log_info "$(get_mq_name)服务正在运行（延迟检测）"
                        return 0
                    fi
                fi
            fi
        else
            # 对于Classic，使用status命令
            if [[ -x "$mq_bin/activemq" ]]; then
                local status_output=$("$mq_bin/activemq" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "$(get_mq_name)服务正在运行"
                    log_debug "Status输出: $status_output"
                    return 0
                else
                    log_warn "$(get_mq_name)服务未运行"
                    log_debug "Status输出: $status_output"
                    return 1
                fi
            fi
        fi
    fi
    
    # 如果status命令不可用，回退到进程检查
    log_info "Status命令不可用，回退到进程检查..."
    
    # 通过关键词查找进程
    local PID=$(collect_pids)
    if [[ -n "$PID" ]]; then
        if is_artemis; then
            log_info "通过进程名找到ActiveMQ Artemis进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Artemis进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
            return 0
        else
            log_info "通过进程名找到ActiveMQ Classic进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Classic进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
            return 0
        fi
    else
        log_warn "未找到$(get_mq_name)进程"
        return 1
    fi
}

# 从配置文件提取日志文件路径
get_log_file_path() {
    log_debug "正在提取日志文件路径..."
    
    # 根据MQ类型设置HOME变量
    local mq_home=$(get_mq_home)
    
    # 优先检查log4j2配置文件
    local log_file_path=""
    if [[ -f "$mq_home/conf/log4j2.properties" ]]; then
        log_file_path=$(grep -E "^appender\\.file\\.fileName\\s*=" "$mq_home/conf/log4j2.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j2.properties找到日志路径: $log_file_path"
    fi
    
    # 如果log4j2未找到，检查log4j配置文件
    if [[ -z "$log_file_path" && -f "$mq_home/conf/log4j.properties" ]]; then
        log_file_path=$(grep -E "^log4j\\.appender\\.file\\.File\\s*=" "$mq_home/conf/log4j.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j.properties找到日志路径: $log_file_path"
    fi
    
    # 处理变量替换和路径转换
    if [[ -n "$log_file_path" ]]; then
        if is_artemis; then
            log_file_path=$(echo "$log_file_path" | sed "s|\\\${artemis.home}|$mq_home|g" | sed "s|\\\${artemis.instance}|$INSTALL_DIR|g" | sed "s|\\\${artemis.instance.dir}|$INSTALL_DIR|g")
        else
            log_file_path=$(echo "$log_file_path" | sed "s|\\\${activemq\\.base}|$mq_home|g" | sed "s|\\\${activemq\\.data}|$INSTALL_DIR/data|g" | sed "s|\\\${karaf\\.data}|$INSTALL_DIR/data|g")
        fi
        [[ "$log_file_path" =~ ^[^/] ]] && log_file_path="$mq_home/$log_file_path"
        log_debug "处理后的日志路径: $log_file_path"
    else
        if is_artemis; then
            log_file_path="$INSTALL_DIR/log/artemis.log"
        else
            log_file_path="$INSTALL_DIR/data/activemq.log"
        fi
        log_debug "使用默认日志路径: $log_file_path"
    fi
    
    log_debug "$(get_mq_name)日志文件路径: $log_file_path"
    echo "$log_file_path"
    return 0
}

# 显示日志文件路径和内容
show_log_info() {
    log_info "正在获取日志信息..."
    
    # 从配置文件提取日志文件路径
    local LOG_FILE_PATH=$(get_log_file_path)
    
    if [[ -n "$LOG_FILE_PATH" ]]; then
        log_info "$(get_mq_name)日志文件路径: $LOG_FILE_PATH"
        if [[ -f "$LOG_FILE_PATH" ]]; then
            local LOG_SIZE=$(stat -c%s "$LOG_FILE_PATH" 2>/dev/null || stat -f%z "$LOG_FILE_PATH" 2>/dev/null)
            if [[ "$LOG_SIZE" =~ ^[0-9]+$ ]]; then
                log_info "日志文件大小: $LOG_SIZE 字节"
            else
                log_info "日志文件大小: 无法确定"
            fi
        else
            log_warn "日志文件不存在: $LOG_FILE_PATH"
        fi
    else
        log_warn "无法确定日志文件路径"
    fi
    
    # 检查data目录中的其他日志文件
    if [[ -d "$INSTALL_DIR/data" ]]; then
        local OTHER_LOGS=$(find "$INSTALL_DIR/data" -name "*.log" -type f 2>/dev/null | grep -v "$LOG_FILE_PATH")
        if [[ -n "$OTHER_LOGS" ]]; then
            log_info "其他日志文件:"
            echo "$OTHER_LOGS" | while read log_file; do
                log_info "  - $log_file"
                # 显示其他日志文件的部分内容
                if [[ -f "$log_file" ]]; then
                    local FILE_SIZE=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file" 2>/dev/null)
                    log_debug "    文件大小: $FILE_SIZE 字节"
                    if [[ "$FILE_SIZE" -gt 0 ]] && [[ "$FILE_SIZE" -lt 1048576 ]]; then  # 只处理小于1MB的文件
                        # 检查是否为文本文件
                        if file "$log_file" 2>/dev/null | grep -q "text"; then
                            log_debug "    文件内容预览:"
                            head -n 5 "$log_file" 2>/dev/null | sed 's/^/      /' || log_debug "    无法读取文件内容"
                        else
                            log_debug "    文件不是文本格式，跳过内容显示"
                        fi
                    fi
                fi
            done
        fi
    fi
}

# 通用函数：使用xmlstarlet替换host配置
replace_host_config() {
    local to_value="$1"
    local description="$2"
    local jetty_xml_path="$(get_mq_conf)/jetty.xml"

    if ! command -v xmlstarlet &> /dev/null; then
        log_error "xmlstarlet 命令未找到，无法修改XML配置文件。"
        log_error "请先安装 xmlstarlet (例如: brew install xmlstarlet 或 sudo apt-get install xmlstarlet)"
        return 1
    fi

    # 备份配置文件
    cp "$jetty_xml_path" "$jetty_xml_path.bak" 2>/dev/null || true

    log_info "$description"
    # 使用xmlstarlet更新所有已知连接器bean中的host属性
    # 通常是 'jettyPort' bean, 但也可能在其他自定义的bean中
    if xmlstarlet ed -L -u "//bean[contains(@class, 'org.eclipse.jetty.server.ServerConnector')]/property[@name='host']/@value" -v "$to_value" "$jetty_xml_path" 2>/dev/null && \
       xmlstarlet ed -L -u "//bean[@id='jettyPort']/property[@name='host']/@value" -v "$to_value" "$jetty_xml_path" 2>/dev/null; then
        log_info "成功更新主机配置为 '$to_value' 在 $jetty_xml_path"
        return 0
    else
        log_warn "使用xmlstarlet更新主机配置失败。 $jetty_xml_path 的结构可能已更改或文件不存在。"
        return 1
    fi
}

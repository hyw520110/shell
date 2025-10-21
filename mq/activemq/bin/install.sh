#!/bin/bash

# ActiveMQ/Artemis一键安装配置脚本
# 支持Linux和MacOS系统



# 公共变量
DEFAULT_INSTALL_DIR="$HOME/activemq"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_ARTEMIS_VERSION="2.41.0"
DEFAULT_CLASSIC_VERSION="6.1.7"
DEFAULT_LOG_LEVEL="INFO"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQ_TYPE="artemis"  # 默认安装Artemis

# 默认端口
DEFAULT_BROKER_PORT="61616"
DEFAULT_JETTY_PORT="8161"
DEFAULT_AMQP_PORT="5672"
DEFAULT_STOMP_PORT="61613"
DEFAULT_MQTT_PORT="1883"
DEFAULT_WS_PORT="61614"

# 下载链接数组（按优先级排序）
declare -a CLASSIC_DOWNLOAD_MIRRORS=(
    "https://archive.apache.org/dist/activemq/$VERSION/apache-activemq-$VERSION-bin.tar.gz"
    "https://downloads.apache.org/activemq/$VERSION/apache-activemq-$VERSION-bin.tar.gz"
)
declare -a ARTEMIS_DOWNLOAD_MIRRORS=(
    "https://archive.apache.org/dist/activemq/activemq-artemis/$VERSION/apache-artemis-$VERSION-bin.tar.gz"
    "https://downloads.apache.org/activemq/activemq-artemis/$VERSION/apache-artemis-$VERSION-bin.tar.gz"
)

# 运行时变量
INSTALL_DIR=""
DOWNLOAD_DIR=""
FORCE_REINSTALL=false
UNINSTALL_MODE=false
REMOVE_DATA=false
MQ_VERSION=""
MQ_FILE_NAME=""
MQ_DIR_NAME=""
MQ_NAME=""
ENABLE_EXTERNAL_ACCESS=true  # 默认开启外部访问
DISABLE_EXTERNAL_ACCESS=false
GENERATE_RANDOM_PASSWORD=false
LOG_LEVEL="$DEFAULT_LOG_LEVEL"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印使用说明
print_usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -d, --dir PATH     指定安装目录（默认Linux: $DEFAULT_INSTALL_DIR, MacOS: $DEFAULT_INSTALL_DIR）"
    echo "  -D, --download-dir PATH  指定下载目录（默认: $HOME/Downloads）"
    echo "  -v, --version VER  指定MQ版本（默认: Artemis $DEFAULT_ARTEMIS_VERSION, Classic $DEFAULT_CLASSIC_VERSION）"
    echo "  --artemis          安装ActiveMQ Artemis（默认）"
    echo "  --classic          安装ActiveMQ Classic"
    echo "  -f, --force        强制重新安装（不会删除持久化数据）"
    echo "  -u, --uninstall    卸载MQ"
    echo "  --remove-data      与-u一起使用时，删除数据目录"
    echo "  --disable-external-access  禁止Web控制台外部访问（默认允许外部访问）"
    echo "  --generate-random-password  生成并修改随机密码（默认使用admin/admin）"
    echo "  --log-level LEVEL  设置日志级别 (DEBUG, INFO, WARN, ERROR)（默认: $DEFAULT_LOG_LEVEL）"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                                  # 安装默认的Artemis版本"
    echo "  $0 --classic                        # 安装默认的Classic版本"
    echo "  $0 -d $DEFAULT_INSTALL_DIR          # 指定安装目录"
    echo "  $0 -D /tmp                          # 指定下载目录"
    echo "  $0 -v $DEFAULT_ARTEMIS_VERSION      # 指定Artemis版本"
    echo "  $0 --classic -v $DEFAULT_CLASSIC_VERSION # 指定Classic版本"
    echo "  $0 -f                               # 强制重新安装"
    echo "  $0 -u                               # 卸载MQ（保留数据）"
    echo "  $0 -u --remove-data                 # 卸载MQ并删除数据"
    echo "  $0 -d $DEFAULT_INSTALL_DIR -f       # 指定目录并强制安装"
    echo "  $0 --disable-external-access        # 禁止Web控制台外部访问"
    echo "  $0 --generate-random-password       # 生成并修改随机密码"
    echo "  $0 --log-level DEBUG                # 设置日志级别为DEBUG"
}

# MQ类型检测函数
# 参数: $1 = MQ类型 (artemis|classic)，可选
is_artemis() {
    local mq_type="$1"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="$MQ_TYPE"
    fi
    
    [[ "$mq_type" == "artemis" ]]
}

# 参数: $1 = MQ类型 (artemis|classic)，可选
is_classic() {
    local mq_type="$1"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="$MQ_TYPE"
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
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        log_debug "检测到Java版本: $JAVA_VERSION"
        
        if [[ "$JAVA_VERSION" == 17* ]]; then
            log_info "检测到Java 17，设置兼容性参数"
            
            # 为ActiveMQ Classic设置参数
            if is_classic; then
                local setenv_file="$mq_conf/setenv"
                if [[ -d "$mq_conf" ]]; then
                    # 检查是否已经包含Java 17参数
                    if ! grep -q "XX:-UseContainerSupport" "$setenv_file"; then
	                    log_debug "更新setenv文件: $setenv_file"
	                    # TODO 修改setenv_file 在文件头部添加JAVA17兼容参数
                        echo 'export ACTIVEMQ_OPTS="-XX:-UseContainerSupport $ACTIVEMQ_OPTS"'  
                    fi
                fi
            fi
            
            # 为ActiveMQ Artemis设置参数
            if is_artemis; then
                # Artemis使用环境变量
                export ARTEMIS_OPTS="-XX:-UseContainerSupport"
                log_debug "设置ARTEMIS_OPTS环境变量: $ARTEMIS_OPTS"
            fi
        else
            log_debug "Java版本不是17，跳过兼容性参数设置"
        fi
    else
        log_warn "未找到Java命令，跳过兼容性参数设置"
    fi
}

# 设置环境变量
set_mq_env() {
    export MQ_HOME="$INSTALL_DIR"
    export MQ_BASE="$INSTALL_DIR"
    export MQ_CONF="$INSTALL_DIR/conf"
    export MQ_DATA="$INSTALL_DIR/data"
}

# 获取MQ HOME路径
get_mq_home() {
    echo "$MQ_HOME"
}

# 获取MQ BIN路径
get_mq_bin() {
    echo "$MQ_HOME/bin"
}

# 获取MQ配置路径
get_mq_conf() {
    echo "$MQ_CONF"
}

# 获取MQ数据路径
get_mq_data() {
    echo "$MQ_DATA"
}

# 获取MQ PID文件路径
get_mq_pid_file() {
    if is_artemis; then
        echo "$MQ_DATA/artemis.pid"
    else
        echo "$MQ_DATA/activemq.pid"
    fi
}

# 获取MQ启动脚本路径
get_mq_start_script() {
    if is_artemis; then
        echo "$MQ_HOME/bin/artemis"
    else
        echo "$MQ_HOME/bin/activemq"
    fi
}

# 获取MQ停止脚本路径
get_mq_stop_script() {
    if is_artemis; then
        echo "$MQ_HOME/bin/artemis"
    else
        echo "$MQ_HOME/bin/activemq"
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
        mq_type="$MQ_TYPE"
    fi
    
    if [[ "$mq_type" == "artemis" ]]; then
        echo "ActiveMQ Artemis"
    else
        echo "ActiveMQ Classic"
    fi
}

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
            [[ "$level" != "DEBUG" ]] || return
            ;;
        WARN)
            # WARN级别显示WARN、ERROR
            [[ "$level" == "WARN" || "$level" == "ERROR" ]] || return
            ;;
        ERROR)
            # ERROR级别只显示ERROR
            [[ "$level" == "ERROR" ]] || return
            ;;
        *)
            # 默认显示所有日志
            ;;
    esac
    
    # 设置颜色
    case "$level" in
        DEBUG)
            color="$GREEN"
            ;;
        INFO)
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

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -D|--download-dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -v|--version)
                MQ_VERSION="$2"
                shift 2
                ;;
            --artemis)
                MQ_TYPE="artemis"
                shift
                ;;
            --classic)
                MQ_TYPE="classic"
                shift
                ;;
            -f|--force)
                FORCE_REINSTALL=true
                shift
                ;;
            -u|--uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --remove-data)
                REMOVE_DATA=true
                shift
                ;;
            --enable-external-access)
                ENABLE_EXTERNAL_ACCESS=true
                DISABLE_EXTERNAL_ACCESS=false
                shift
                ;;
            --disable-external-access)
                DISABLE_EXTERNAL_ACCESS=true
                ENABLE_EXTERNAL_ACCESS=false
                shift
                ;;
            --generate-random-password)
                GENERATE_RANDOM_PASSWORD=true
                shift
                ;;
            --log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # 如果未指定下载目录，则使用默认下载目录
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
        log_debug "使用默认下载目录: $DOWNLOAD_DIR"
    fi
    
    # 如果未指定版本，则使用默认版本
    if [[ -z "$MQ_VERSION" ]]; then
        if [[ "$MQ_TYPE" == "artemis" ]]; then
            MQ_VERSION="$DEFAULT_ARTEMIS_VERSION"
            log_debug "使用默认Artemis版本: $MQ_VERSION"
        else
            MQ_VERSION="$DEFAULT_CLASSIC_VERSION"
            log_debug "使用默认Classic版本: $MQ_VERSION"
        fi
    fi
    
    # 验证日志级别
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR)
            ;;
        *)
            log_error "无效的日志级别: $LOG_LEVEL (有效值: DEBUG, INFO, WARN, ERROR)"
            exit 1
            ;;
    esac
}

# 卸载MQ
uninstall_mq() {
    MQ_NAME=$(get_mq_name)
    log_info "开始卸载${MQ_NAME}..."
    
    # 检查是否已安装
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "未在 $INSTALL_DIR 找到MQ安装"
        exit 0
    fi
    
    # 如果服务正在运行，则先停止
    log_info "正在停止MQ服务..."
    "$INSTALL_DIR/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" --${MQ_TYPE} || true
    
    if [[ "$REMOVE_DATA" == true ]]; then
        log_info "删除安装目录及所有内容: $INSTALL_DIR"
        execute_command "rm -rf \"$INSTALL_DIR\""
    else
        log_info "删除安装目录除数据目录外的所有文件: $INSTALL_DIR"
        # 移除除data目录外的所有文件
        execute_command "find \"$INSTALL_DIR\" -mindepth 1 -maxdepth 1 ! -name \"data\" -exec rm -rf {} +"
        
        # 检查是否还有其他内容，如果没有则删除整个目录
        if [[ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            log_info "安装目录为空，删除目录: $INSTALL_DIR"
            execute_command "rmdir \"$INSTALL_DIR\""
        else
            log_info "安装目录 $INSTALL_DIR 仍有内容（数据目录可能保留）"
        fi
    fi
    
    # 从shell配置文件中移除环境变量（如果存在）
    remove_env_vars
    
    # 移除systemd服务（如果存在）
    remove_systemd_service
    
    log_info "${MQ_NAME}卸载完成"
}

# 从shell配置文件中移除环境变量
remove_env_vars() {
    log_info "移除环境变量配置..."
    
    local SHELL_CONFIG
    if [[ -n "$ZSH_VERSION" ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    else
        SHELL_CONFIG="$HOME/.bash_profile"
    fi
    
    if [[ -f "$SHELL_CONFIG" ]]; then
        if grep -q "ACTIVEMQ_HOME" "$SHELL_CONFIG"; then
            log_info "从 $SHELL_CONFIG 中移除ActiveMQ环境变量配置"
            # 移除包含ACTIVEMQ_HOME的整行和注释行
            execute_command "sed -i '/# ActiveMQ Environment Variables/,/^export ACTIVEMQ_HOME/d' \"$SHELL_CONFIG\"" || \
            execute_command "sed -i '/ACTIVEMQ_HOME/d' \"$SHELL_CONFIG\"" || true
        else
            log_info "未找到ActiveMQ环境变量配置"
        fi
    fi
}

# 移除systemd服务
remove_systemd_service() {
    if [[ "$OS" == "Linux" ]]; then
        if is_artemis; then
            log_info "移除ActiveMQ Artemis systemd服务..."
            execute_command "systemctl stop artemis" || true
            execute_command "systemctl disable artemis" || true
            execute_command "rm -f /etc/systemd/system/artemis.service" || true
        else
            log_info "移除ActiveMQ Classic systemd服务..."
            execute_command "systemctl stop activemq" || true
            execute_command "systemctl disable activemq" || true
            execute_command "rm -f /etc/systemd/system/activemq.service" || true
        fi
        execute_command "systemctl daemon-reload" || true
    fi
}

# 检查是否以root权限运行（Linux下可选）
check_root() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ $EUID -eq 0 ]]; then
            log_warn "建议不要以root用户运行此脚本"
        fi
    fi
}

# 检查Java环境
check_java() {
    if ! command -v java &> /dev/null; then
        log_error "Java未安装，请先安装Java"
        return 1
    fi
    
    java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log_info "检测到Java版本: $java_version"
    
}

# 检测操作系统类型
detect_os() {
    case "$(uname -s)" in
        Linux*)
            OS=Linux
            if [[ -z "$INSTALL_DIR" ]]; then
                INSTALL_DIR="$DEFAULT_INSTALL_DIR"
            fi
            ;;
        Darwin*)
            OS=MacOS
            if [[ -z "$INSTALL_DIR" ]]; then
                INSTALL_DIR="$DEFAULT_INSTALL_DIR"
            fi
            ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac
    
    log_info "检测到操作系统: $OS"
    log_info "安装目录: $INSTALL_DIR"
}

# 检查是否已安装ActiveMQ
check_installed() {
    if [[ -d "$INSTALL_DIR/bin" && -d "$INSTALL_DIR/conf" ]]; then
        log_info "检测到ActiveMQ已安装在: $INSTALL_DIR"
        
        if [[ "$FORCE_REINSTALL" == true ]]; then
            log_warn "强制重新安装模式启用，跳过确认"
        else
            # 先尝试停止可能正在运行的服务
            log_info "正在停止ActiveMQ服务..."
            if [[ -f "$INSTALL_DIR/bin/stop.sh" ]]; then
                "$INSTALL_DIR/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
            else
                log_warn "未找到stop.sh脚本，跳过停止服务步骤"
            fi
            
            read -p "ActiveMQ已在 $INSTALL_DIR 安装，是否继续安装? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "安装已取消"
                exit 0
            fi
        fi
    else
        log_info "未检测到已安装的ActiveMQ，开始安装..."
    fi
}

# 设置版本相关的文件名
# 参数: $1 = MQ类型 (artemis|classic)
#       $2 = 版本号
set_version_variables() {
    local mq_type="$1"
    local version="$2"
    
    # 如果未提供参数，则使用全局变量
    if [[ -z "$mq_type" ]]; then
        mq_type="$MQ_TYPE"
    fi
    if [[ -z "$version" ]]; then
        version="$MQ_VERSION"
    fi
    
    # 选择合适的镜像列表
    local mirrors
    if [[ "$mq_type" == "artemis" ]]; then
        mirrors=("${ARTEMIS_DOWNLOAD_MIRRORS[@]}")
    else
        mirrors=("${CLASSIC_DOWNLOAD_MIRRORS[@]}")
    fi
    
    # 使用第一个镜像链接来提取文件名
    local mirror_template="${mirrors[0]}"
    local mirror_url="${mirror_template/\$VERSION/$version}"
    MQ_FILE_NAME=$(basename "$mirror_url")
    # 从文件名中提取目录名（去掉.tar.gz后缀）
    MQ_DIR_NAME="${MQ_FILE_NAME%.tar.gz}"
}

# 下载MQ（支持断点续传）
# 参数: $1 = MQ类型 (artemis|classic)
#       $2 = 版本号
#       $3 = 下载目录
download_mq() {
    local mq_type="$1"
    local version="$2"
    local download_dir="$3"
    
    # 设置版本相关的文件名
    set_version_variables "$mq_type" "$version"
    
    # 确保下载目录存在
    execute_command "mkdir -p \"$download_dir\"" "创建下载目录"
    
    # 切换到下载目录
    cd "$download_dir"
    
    # 检查是否已下载安装包
    if [[ -f "$MQ_FILE_NAME" ]]; then
        log_info "检测到已存在的安装包: $download_dir/$MQ_FILE_NAME，验证完整性..."
        
        # 检查文件大小和有效性
        local FILE_SIZE=$(stat -f%z "$MQ_FILE_NAME" 2>/dev/null || stat -c%s "$MQ_FILE_NAME" 2>/dev/null)
        if [[ -z "$FILE_SIZE" ]]; then
            log_warn "无法获取文件大小，重新下载..."
            execute_command "rm -f \"$MQ_FILE_NAME\"" "删除损坏的文件"
        elif [[ "$FILE_SIZE" -lt 100000 ]]; then
            log_warn "安装包文件大小异常($FILE_SIZE bytes)，重新下载..."
            execute_command "rm -f \"$MQ_FILE_NAME\"" "删除损坏的文件"
        else
            # 尝试验证tar文件是否有效
            if tar -tzf "$MQ_FILE_NAME" > /dev/null 2>&1; then
                log_info "已存在的安装包验证通过，跳过下载"
                return 0
            else
                log_warn "安装包文件损坏或不完整，尝试断点续传..."
                # 不删除文件，留待断点续传
            fi
        fi
    fi
    
    local mq_name=$(get_mq_name "$mq_type")
    log_info "开始下载${mq_name}版本 ${version}..."
    log_info "下载目录: $download_dir"
    
    # 尝试从多个源下载
    local download_success=false
    
    # 选择合适的镜像列表
    local mirrors
    if [[ "$mq_type" == "artemis" ]]; then
        mirrors=("${ARTEMIS_DOWNLOAD_MIRRORS[@]}")
    else
        mirrors=("${CLASSIC_DOWNLOAD_MIRRORS[@]}")
    fi
    
    # 遍历镜像列表进行下载
    for mirror_template in "${mirrors[@]}"; do
        # 替换模板中的版本号
        local mirror_url="${mirror_template/\$VERSION/$version}"
        # 从URL中提取文件名
        local remote_file_name=$(basename "$mirror_url")
        
        log_info "尝试从镜像下载: $mirror_url"
        
        # 如果aria2c可用，使用多线程下载
        if command -v aria2c &> /dev/null; then
            log_info "使用aria2c多线程下载..."
            if execute_command "aria2c -x 4 -s 4 --continue=true --allow-overwrite=true --auto-file-renaming=false \"$mirror_url\" -d \"$download_dir\" -o \"$MQ_FILE_NAME\""; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$MQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror_url"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    execute_command "rm -f \"$MQ_FILE_NAME\"" "删除损坏的文件"
                fi
            else
                log_warn "使用aria2c下载失败: $mirror_url"
                # 清理可能部分下载的文件
                execute_command "rm -f \"$MQ_FILE_NAME\"" "清理部分下载的文件"
            fi
        elif command -v wget &> /dev/null; then
            # 使用wget进行断点续传下载
            if execute_command "wget -c \"$mirror_url\" -O \"$MQ_FILE_NAME\""; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$MQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror_url"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    execute_command "rm -f \"$MQ_FILE_NAME\"" "删除损坏的文件"
                fi
            else
                log_warn "从镜像下载失败: $mirror_url"
                # 清理可能部分下载的文件
                execute_command "rm -f \"$MQ_FILE_NAME\"" "清理部分下载的文件"
            fi
        elif command -v curl &> /dev/null; then
            # 使用curl进行断点续传下载
            if execute_command "curl -L -C - \"$mirror_url\" -o \"$MQ_FILE_NAME\""; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$MQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror_url"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    execute_command "rm -f \"$MQ_FILE_NAME\"" "删除损坏的文件"
                fi
            else
                log_warn "从镜像下载失败: $mirror_url"
                # 清理可能部分下载的文件
                execute_command "rm -f \"$MQ_FILE_NAME\"" "清理部分下载的文件"
            fi
        else
            log_error "系统中未找到aria2c、wget或curl命令"
            exit 1
        fi
    done
    
    # 如果下载失败，检查是否是版本不存在的问题
    if [[ "$download_success" == false ]]; then
        log_warn "从所有镜像下载失败，可能是版本 ${version} 不存在"
        local default_version
        if [[ "$mq_type" == "artemis" ]] && [[ "$version" != "$DEFAULT_ARTEMIS_VERSION" ]]; then
            read -p "是否下载默认Artemis版本 $DEFAULT_ARTEMIS_VERSION? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "切换到默认Artemis版本 $DEFAULT_ARTEMIS_VERSION"
                # 调用自身下载默认版本
                download_mq "$mq_type" "$DEFAULT_ARTEMIS_VERSION" "$download_dir"
                return $?
            else
                log_info "下载已取消"
                return 0
            fi
        elif [[ "$mq_type" == "classic" ]] && [[ "$version" != "$DEFAULT_CLASSIC_VERSION" ]]; then
            read -p "是否下载默认Classic版本 $DEFAULT_CLASSIC_VERSION? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "切换到默认Classic版本 $DEFAULT_CLASSIC_VERSION"
                # 调用自身下载默认版本
                download_mq "$mq_type" "$DEFAULT_CLASSIC_VERSION" "$download_dir"
                return $?
            else
                log_info "下载已取消"
                return 0
            fi
        else
            log_warn "下载默认版本失败，请检查网络连接"
            return 0
        fi
    fi
    
    if [[ "$download_success" == false ]]; then
        log_warn "所有下载尝试均失败"
        return 0
    fi
    
    if [[ "$mq_type" == "artemis" ]]; then
        log_info "ActiveMQ Artemis下载完成，文件位置: $download_dir/$MQ_FILE_NAME"
    else
        log_info "ActiveMQ Classic下载完成，文件位置: $download_dir/$MQ_FILE_NAME"
    fi
}

# 安装MQ
# 参数: $1 = MQ类型 (artemis|classic)
#       $2 = 版本号
#       $3 = 安装目录
#       $4 = 下载目录
install_mq() {
    local mq_type="$1"
    local version="$2"
    local install_dir="$3"
    local download_dir="$4"
    
    local mq_name=$(get_mq_name "$mq_type")
    log_info "开始安装${mq_name}..."
    
    # 创建临时解压目录
    local TEMP_EXTRACT_DIR=$(mktemp -d)
    log_debug "使用临时解压目录: $TEMP_EXTRACT_DIR"
    
    # 记录当前工作目录
    local original_dir=$(pwd)
    
    # 在临时目录中解压文件
    cd "$TEMP_EXTRACT_DIR"
    log_debug "在临时目录中解压文件: $download_dir/$MQ_FILE_NAME"
    if ! execute_command "tar -xzf \"$download_dir/$MQ_FILE_NAME\""; then
        log_error "解压失败"
        execute_command "rm -rf \"$TEMP_EXTRACT_DIR\""
        return 0
    fi
    
    # 获取解压后的目录名
    local EXTRACTED_DIR
    if [[ "$mq_type" == "artemis" ]]; then
        EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "apache-artemis-*" | head -n 1)
    else
        EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "apache-activemq-*" | head -n 1)
    fi
    
    # 如果找不到标准目录名，则使用第一个目录
    if [[ -z "$EXTRACTED_DIR" ]]; then
        EXTRACTED_DIR=$(ls -d */ | head -n 1)
    fi
    
    # 检查是否找到了解压后的目录
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "无法找到解压后的目录"
        execute_command "rm -rf \"$TEMP_EXTRACT_DIR\""
        exit 1
    fi
    
    log_debug "找到解压目录: $EXTRACTED_DIR"
    
    # 确定安装目录
    execute_command "mkdir -p $install_dir"
    
    # 如果强制重装且安装目录已存在，则保存配置和数据目录
    if [[ "$FORCE_REINSTALL" == true ]] && [[ -d "$install_dir/conf" ]]; then
        log_info "强制重装模式，备份配置和数据目录..."
        
        # 创建临时备份目录
        local TEMP_BACKUP_DIR=$(mktemp -d)
        log_debug "备份到临时目录: $TEMP_BACKUP_DIR"
        
        # 先尝试停止可能正在运行的服务
        log_info "正在停止MQ服务..."
        "$install_dir/bin/stop.sh" -d "$install_dir" --log-level "$LOG_LEVEL" --${mq_type} || true
        
        # 修复目录权限以便能够访问
        log_debug "尝试修复安装目录权限以进行备份..."
        execute_command "chown -R $(whoami):$(whoami) \"$install_dir/\"" || true
        execute_command "chmod -R 755 \"$install_dir/\"" || true
        
        # 备份配置目录（如果存在）
        if [[ -d "$install_dir/conf" ]]; then
            log_info "备份配置目录..."
            # 尝试使用sudo权限备份配置目录
            if command -v rsync &> /dev/null; then
                if ! execute_command "rsync -a \"$install_dir/conf/\" \"$TEMP_BACKUP_DIR/conf/\""; then
                    if ! execute_command "cp -r \"$install_dir/conf\" \"$TEMP_BACKUP_DIR/\""; then
                        log_warn "备份配置目录失败，跳过配置目录备份"
                    fi
                fi
            else
                if ! execute_command "cp -r \"$install_dir/conf\" \"$TEMP_BACKUP_DIR/\""; then
                    log_warn "备份配置目录失败，跳过配置目录备份"
                fi
            fi
        fi
        
        # 备份数据目录（如果存在）
        if [[ -d "$install_dir/data" ]]; then
            log_info "备份数据目录..."
            if command -v rsync &> /dev/null; then
                if ! execute_command "rsync -a \"$install_dir/data/\" \"$TEMP_BACKUP_DIR/data/\""; then
                    if ! execute_command "cp -r \"$install_dir/data\" \"$TEMP_BACKUP_DIR/\""; then
                        log_warn "备份数据目录失败，跳过数据目录备份"
                    fi
                fi
            else
                if ! execute_command "cp -r \"$install_dir/data\" \"$TEMP_BACKUP_DIR/\""; then
                    log_warn "备份数据目录失败，跳过数据目录备份"
                fi
            fi
        fi
        
        # 删除安装目录中的内容（但保留目录本身）
        log_debug "清理安装目录内容..."
        if ! execute_command "rm -rf \"$install_dir\"/*"; then
            log_warn "无法删除 $install_dir 中的内容，尝试逐个删除..."
            # 逐个删除文件和目录
            if [[ -d "$install_dir" ]]; then
                for item in "$install_dir"/*; do
                    if [[ -e "$item" ]]; then
                        local item_name=$(basename "$item")
                        log_debug "删除 $item_name..."
                        execute_command "rm -rf \"$item\"" || true
                    fi
                done
            fi
        fi
    fi
    
    # 预先将当前源目录的启动/停止脚本复制到安装目录bin，以便后续停止/启动调用
    execute_command "mkdir -p \"$install_dir/bin\"" || true
    if [[ -f "$SOURCE_DIR/start.sh" ]]; then
        if execute_command "cp \"$SOURCE_DIR/start.sh\" \"$install_dir/bin/start.sh\""; then
            execute_command "chmod +x \"$install_dir/bin/start.sh\"" || true
        else
            log_warn "复制自定义脚本失败: $SOURCE_DIR/start.sh"
        fi
    fi
    if [[ -f "$SOURCE_DIR/stop.sh" ]]; then
        if execute_command "cp \"$SOURCE_DIR/stop.sh\" \"$install_dir/bin/stop.sh\""; then
            execute_command "chmod +x \"$install_dir/bin/stop.sh\"" || true
        else
            log_warn "复制自定义脚本失败: $SOURCE_DIR/stop.sh"
        fi
    fi

    # 先尝试停止可能正在运行的服务（现在已有stop.sh可用）
    log_info "正在停止MQ服务..."
    if [[ -f "$install_dir/bin/stop.sh" ]]; then
        "$install_dir/bin/stop.sh" -d "$install_dir" --log-level "$LOG_LEVEL" --${mq_type} || true
    elif [[ -f "$SRC_DIR/stop.sh" ]]; then
        "$SRC_DIR/stop.sh" -d "$install_dir" --log-level "$LOG_LEVEL" --${mq_type} || true
    else
        log_warn "未找到stop.sh脚本，跳过停止服务步骤"
    fi
    
    # 等待一段时间让服务完全停止
    sleep 5
    
    # 确保安装目录存在
    log_debug "确保安装目录存在..."
    if ! execute_command "mkdir -p \"$install_dir\""; then
        log_error "无法创建安装目录"
        execute_command "rm -rf \"$TEMP_BACKUP_DIR\"" || true
        execute_command "rm -rf \"$TEMP_EXTRACT_DIR\""
        cd "$original_dir"
        return 0
    fi
    
    # 设置目录权限
    log_debug "设置安装目录权限..."
    set_directory_permissions "$install_dir"
    
    # 尝试逐个复制目录和文件
    log_info "开始逐个复制文件到安装目录..."
    for item in "$EXTRACTED_DIR"/*; do
        local item_name=$(basename "$item")
        log_debug "复制 $item_name..."
        # 确保目标目录存在
        execute_command "mkdir -p \"$install_dir\"" || true
        
        # 尝试多种复制方法
        if ! execute_command "cp -r \"$item\" \"$install_dir/\""; then
            if ! execute_command "cp -r \"$item\" \"$install_dir/\""; then
                if command -v rsync &> /dev/null; then
                    if ! execute_command "rsync -av \"$item\" \"$install_dir/\""; then
                        log_error "无法复制 $item_name，跳过..."
                        continue
                    fi
                else
                    log_error "无法复制 $item_name，跳过..."
                    continue
                fi
            fi
        fi
        log_debug "成功复制 $item_name"
    done
    
    log_info "文件复制完成"

    # 将当前源目录的启动/停止脚本复制到安装目录bin
    local SRC_DIR="$(dirname "${BASH_SOURCE[0]}")"
    execute_command "mkdir -p $install_dir/bin" || true
    if [[ -f "$SRC_DIR/start.sh" ]]; then
        execute_command "cp $SRC_DIR/*.sh $install_dir/bin/" || true
        execute_command "chmod +x $install_dir/bin/*.sh" || true
    fi
    
    # 恢复备份的配置和数据目录
    if [[ -n "$TEMP_BACKUP_DIR" ]] && [[ -d "$TEMP_BACKUP_DIR" ]]; then
        # 确保目标目录存在
        execute_command "mkdir -p \"$install_dir/conf\"" || true
        execute_command "mkdir -p \"$install_dir/data\"" || true
        
        # 修复目标目录权限
        execute_command "chown -R $(whoami):$(whoami) \"$install_dir/conf/\"" || true
        execute_command "chmod -R 755 \"$install_dir/conf/\"" || true
        execute_command "chown -R $(whoami):$(whoami) \"$install_dir/data/\"" || true
        execute_command "chmod -R 755 \"$install_dir/data/\"" || true
        # 确保data目录下的文件有正确的权限
        execute_command "find \"$install_dir/data/\" -type f -exec chmod 664 {} \;" || true
        
        if [[ -d "$TEMP_BACKUP_DIR/conf" ]]; then
            log_info "恢复配置目录..."
            # 先清空目标目录
            if [[ -d "$install_dir/conf" ]]; then
                execute_command "rm -rf \"$install_dir/conf\"/*" || true
            fi
            
            if command -v rsync &> /dev/null; then
                if ! execute_command "rsync -a \"$TEMP_BACKUP_DIR/conf/\" \"$install_dir/conf/\""; then
                    # 逐个复制文件
                    cd "$TEMP_BACKUP_DIR/conf"
                    for item in * .*; do
                        if [[ "$item" != "." && "$item" != ".." ]]; then
                            execute_command "cp -r \"$item\" \"$install_dir/conf/\"" || true
                        fi
                    done
                    cd - > /dev/null
                fi
            else
                # 逐个复制文件
                cd "$TEMP_BACKUP_DIR/conf"
                for item in * .*; do
                    if [[ "$item" != "." && "$item" != ".." ]]; then
                        execute_command "cp -r \"$item\" \"$install_dir/conf/\"" || true
                    fi
                done
                cd - > /dev/null
            fi
        fi
        
        if [[ -d "$TEMP_BACKUP_DIR/data" ]]; then
            log_info "恢复数据目录..."
            # 先清空目标目录
            if [[ -d "$install_dir/data" ]]; then
                execute_command "rm -rf \"$install_dir/data\"/*" || true
            fi
            
            if command -v rsync &> /dev/null; then
                if ! execute_command "rsync -a \"$TEMP_BACKUP_DIR/data/\" \"$install_dir/data/\""; then
                    # 逐个复制文件
                    cd "$TEMP_BACKUP_DIR/data"
                    for item in * .*; do
                        if [[ "$item" != "." && "$item" != ".." ]]; then
                            execute_command "cp -r \"$item\" \"$install_dir/data/\"" || true
                        fi
                    done
                    cd - > /dev/null
                fi
            else
                # 逐个复制文件
                cd "$TEMP_BACKUP_DIR/data"
                for item in * .*; do
                    if [[ "$item" != "." && "$item" != ".." ]]; then
                        execute_command "cp -r \"$item\" \"$install_dir/data/\"" || true
                    fi
                done
                cd - > /dev/null
            fi
        fi
        
        # 清理备份目录
        execute_command "rm -rf \"$TEMP_BACKUP_DIR\""
    fi
    
    # 清理解压目录
    execute_command "rm -rf \"$TEMP_EXTRACT_DIR\""
    
    # 确保安装目录中的文件具有正确的权限
    log_debug "设置安装目录文件权限..."
    execute_command "chmod +x \"$install_dir/bin/\"*.sh" || true
    execute_command "chmod +x \"$install_dir/bin/\"*" || true
    
    # 设置环境变量
    set_mq_env
    export PATH="$PATH:$(get_mq_bin)"
    
    # 返回原始工作目录
    cd "$original_dir"
    
    log_info "${mq_name}安装完成，安装目录: $install_dir"
}

# 配置MQ
configure_mq() {
    if is_artemis; then
        log_info "开始配置ActiveMQ Artemis..."
    else
        log_info "开始配置ActiveMQ Classic..."
    fi
    
    # 修复安装目录权限
    log_debug "修复安装目录权限..."
    execute_command "chown -R $(whoami):$(whoami) \"$INSTALL_DIR/\"" || true
    execute_command "chmod -R 755 \"$INSTALL_DIR/\"" || true
    
    # 设置环境变量
    if [[ -n "$ZSH_VERSION" ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    else
        SHELL_CONFIG="$HOME/.bash_profile"
    fi
    
    # 检查shell配置文件是否存在，不存在则创建
    if [[ ! -f "$SHELL_CONFIG" ]]; then
        log_info "创建shell配置文件: $SHELL_CONFIG"
        touch "$SHELL_CONFIG" 2>/dev/null || sudo touch "$SHELL_CONFIG" 2>/dev/null || true
    fi
    
    # 检查是否有写入权限
    if [[ ! -w "$SHELL_CONFIG" ]]; then
        log_warn "没有写入权限到 $SHELL_CONFIG，跳过环境变量配置"
    else
        # 检查是否已存在相关配置，避免重复添加
        if is_artemis; then
            if ! grep -q "ARTEMIS_HOME" "$SHELL_CONFIG"; then
                log_info "添加环境变量到 $SHELL_CONFIG"
                {
                    echo '# ActiveMQ Artemis Environment Variables'
                    echo 'export ARTEMIS_HOME'="$INSTALL_DIR"
                    echo 'export PATH=$PATH:$ARTEMIS_HOME/bin'
                } >> "$SHELL_CONFIG" 2>/dev/null || \
                sudo tee -a "$SHELL_CONFIG" > /dev/null <<EOF
# ActiveMQ Artemis Environment Variables
export ARTEMIS_HOME=$INSTALL_DIR
export PATH=\$PATH:\$ARTEMIS_HOME/bin
EOF
            else
                log_info "环境变量已存在，跳过添加"
            fi
        else
            if ! grep -q "ACTIVEMQ_HOME" "$SHELL_CONFIG"; then
                log_info "添加环境变量到 $SHELL_CONFIG"
                {
                    echo '# ActiveMQ Environment Variables'
                    echo 'export ACTIVEMQ_HOME'="$INSTALL_DIR"
                    echo 'export PATH=$PATH:$ACTIVEMQ_HOME/bin'
                } >> "$SHELL_CONFIG" 2>/dev/null || \
                sudo tee -a "$SHELL_CONFIG" > /dev/null <<EOF
# ActiveMQ Environment Variables
export ACTIVEMQ_HOME=$INSTALL_DIR
export PATH=\$PATH:\$ACTIVEMQ_HOME/bin
EOF
            else
                log_info "环境变量已存在，跳过添加"
            fi
        fi
    fi
    
    # 加载环境变量
    if is_artemis; then
        export ARTEMIS_HOME="$INSTALL_DIR"
        export PATH=$PATH:$ARTEMIS_HOME/bin
    else
        export ACTIVEMQ_HOME="$INSTALL_DIR"
        export PATH=$PATH:$ACTIVEMQ_HOME/bin
    fi
    
    # 设置默认端口
    log_info "使用默认端口..."
    BROKER_PORT="$DEFAULT_BROKER_PORT"
    JETTY_PORT="$DEFAULT_JETTY_PORT"
    AMQP_PORT="$DEFAULT_AMQP_PORT"
    STOMP_PORT="$DEFAULT_STOMP_PORT"
    MQTT_PORT="$DEFAULT_MQTT_PORT"
    WS_PORT="$DEFAULT_WS_PORT"
    
    log_info "使用端口: Broker=$BROKER_PORT, Jetty=$JETTY_PORT, AMQP=$AMQP_PORT, STOMP=$STOMP_PORT, MQTT=$MQTT_PORT, WebSocket=$WS_PORT"
    
    # 配置端口
    configure_ports
    
    # 根据参数配置认证和外部访问
    if [[ "$DISABLE_EXTERNAL_ACCESS" == true ]]; then
        # 禁用外部访问并禁用认证
        disable_authentication
    else
        # 启用外部访问并配置认证
        configure_security
    fi
    
    # 配置Web控制台允许外部访问（无论是否禁用认证都应该允许外部访问，除非明确禁用）
    configure_web_console
    
    # 配置持久化存储
    configure_persistence
    
    # 配置防火墙
    configure_firewall
    
    # 为Linux创建systemd服务
    create_systemd_service
    
    if is_artemis; then
        log_info "ActiveMQ Artemis配置完成"
    else
        log_info "ActiveMQ Classic配置完成"
    fi
}

# 生成随机密码
generate_random_password() {
    local length=${1:-12}
    # 使用多种字符类型生成强密码
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    local password=""
    
    for ((i=0; i<length; i++)); do
        password+="${chars:RANDOM%${#chars}:1}"
    done
    
    echo "$password"
}

# 默认禁用认证：设置Jetty authenticate=false
disable_authentication() {
    log_info "禁用Web控制台登录认证(默认)"
    # 确保jetty.xml存在
    if [[ ! -f "$ACTIVEMQ_HOME/conf/jetty.xml" ]]; then
        log_warn "未找到jetty.xml，跳过认证禁用"
        return 0
    fi
    cp "$ACTIVEMQ_HOME/conf/jetty.xml" "$ACTIVEMQ_HOME/conf/jetty.xml.bak" 2>/dev/null || true
    
    # 设置authenticate属性为false
    sed -i.bak 's/<property name="authenticate" value="true" \/>/<property name="authenticate" value="false" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    sed -i.bak 's/<property name="authenticate" value="false" \/>/<property name="authenticate" value="false" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    
    # 如果没有找到authenticate属性，则添加一个
    if ! grep -q "<property name=\"authenticate\"" "$ACTIVEMQ_HOME/conf/jetty.xml"; then
        sed -i.bak '/<bean id="securityConstraint"/,/<\/bean>/ {/class="org.eclipse.jetty.util.security.Constraint"/a\        <property name="authenticate" value="false" \/>\n}' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    fi
    
    log_info "已设置Web控制台无需登录"
}

# 配置安全认证和权限管理（可选开启）
configure_security() {
    log_info "配置ActiveMQ安全认证..."
    
    # 修复配置目录权限
    log_debug "修复配置目录权限..."
    execute_command "chown -R $(whoami):$(whoami) \"$ACTIVEMQ_HOME/conf/\"" || true
    execute_command "chmod -R 755 \"$ACTIVEMQ_HOME/conf/\"" || true
    
    # 备份原始配置文件
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak" 2>/dev/null || 
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak"
    
    # 生成随机密码（如果需要）
    local admin_password="admin"
    local user_password="user"
    local guest_password="password"
    
    if [[ "$GENERATE_RANDOM_PASSWORD" == true ]]; then
        admin_password=$(generate_random_password 16)
        user_password=$(generate_random_password 12)
        guest_password=$(generate_random_password 10)
        log_info "生成随机密码: admin/$admin_password, user/$user_password, guest/$guest_password"
    fi
    
    # 查找broker标签的行号
    local broker_line=$(grep -n "<broker " "$ACTIVEMQ_HOME/conf/activemq.xml" | head -n1 | cut -d: -f1)
    
    if [[ -n "$broker_line" ]]; then
        # 查找broker标签下一行的行号（通常是空白行或注释行）
        local next_line=$((broker_line + 1))
        
        # 检查是否已存在plugins配置
        if grep -q "<plugins>" "$ACTIVEMQ_HOME/conf/activemq.xml"; then
            log_debug "已存在plugins配置，跳过添加"
        else
            # 从conf目录下的plugins模板文件读取配置并替换密码
            local plugins_config=$(cat "$ACTIVEMQ_HOME/conf/plugins.xml.template" | sed "s/manager/$admin_password/g" | sed "s/admin/$user_password/g" | sed "s/password/$guest_password/g")
            
            # 在broker标签后插入plugins配置
            local temp_file=$(mktemp)
            head -n "$broker_line" "$ACTIVEMQ_HOME/conf/activemq.xml" > "$temp_file"
            echo "$plugins_config" >> "$temp_file"
            tail -n +$((broker_line + 1)) "$ACTIVEMQ_HOME/conf/activemq.xml" >> "$temp_file"
            mv "$temp_file" "$ACTIVEMQ_HOME/conf/activemq.xml"
            log_debug "成功添加plugins配置到broker标签后"
        fi
    else
        log_warn "未找到broker标签，使用默认配置方法"
        # 如果找不到broker标签，直接使用ActiveMQ安装包中的默认配置文件
        log_info "使用ActiveMQ安装包中的默认activemq.xml配置文件"
    fi
    
    # 配置Jetty认证
    configure_jetty_auth "$admin_password" "$user_password" "$guest_password"
    
    # 配置Jetty以允许外部访问Web控制台
    configure_web_console
    
    log_info "安全认证配置完成"
}

# 配置Jetty认证
configure_jetty_auth() {
    local admin_password="$1"
    local user_password="$2"
    local guest_password="$3"
    
    log_info "配置Jetty认证..."
    
    # 确保jetty.xml存在
    if [[ ! -f "$ACTIVEMQ_HOME/conf/jetty.xml" ]]; then
        log_warn "未找到jetty.xml，跳过认证配置"
        return 0
    fi
    
    # 设置authenticate属性为true
    sed -i.bak 's/<property name="authenticate" value="false" \/>/<property name="authenticate" value="true" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    sed -i.bak 's/<property name="authenticate" value="true" \/>/<property name="authenticate" value="true" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    
    # 如果没有找到authenticate属性，则添加一个
    if ! grep -q "<property name=\"authenticate\"" "$ACTIVEMQ_HOME/conf/jetty.xml"; then
        sed -i.bak '/<bean id="securityConstraint"/,/<\/bean>/ {/class="org.eclipse.jetty.util.security.Constraint"/a\        <property name="authenticate" value="true" \/>\n}' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    fi
    
    # 创建或更新jetty-realm.properties文件
    local realm_file="$ACTIVEMQ_HOME/conf/jetty-realm.properties"
    log_info "创建或更新 $realm_file"
    
    cat > "$realm_file" <<EOF
# Jetty Realm Configuration
# Format: username: password[,rolename ...]
admin: $admin_password, admin
user: $user_password, user
guest: $guest_password, guest
EOF
    
    # 设置文件权限
    chmod 600 "$realm_file" 2>/dev/null || true
    chown $(whoami):$(whoami) "$realm_file" 2>/dev/null || true
    
    log_info "Jetty认证配置完成"
}

# 通用函数：替换host配置
replace_host_config() {
    local from_value="$1"
    local to_value="$2"
    local description="$3"
    
    # 尝试查找并替换host配置
    sed -i.bak "s|<property name=\"host\" value=\"$from_value\"/>|<property name=\"host\" value=\"$to_value\"/>|g" "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    sed -i.bak "s|value=\"$from_value\"|value=\"$to_value\"|g" "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    
    # 检查是否替换了host配置
    if grep -q "$to_value" "$ACTIVEMQ_HOME/conf/jetty.xml"; then
        log_info "$description"
        return 0
    fi
    return 1
}



# 配置Web控制台允许外部访问
configure_web_console() {
    log_info "配置Web控制台访问权限..."
    
    # 修复配置目录权限
    log_debug "修复配置目录权限..."
    execute_command "chown -R $(whoami):$(whoami) \"$ACTIVEMQ_HOME/conf/\"" || true
    execute_command "chmod -R 755 \"$ACTIVEMQ_HOME/conf/\"" || true
    
    # 检查jetty.xml是否存在（在conf目录下）
    if [[ ! -f "$ACTIVEMQ_HOME/conf/jetty.xml" ]]; then
        log_warn "jetty.xml配置文件不存在，无法配置Web控制台绑定地址"
        # 检查jetty.xml是否在根目录（某些版本的ActiveMQ会将jetty.xml放在根目录）
        if [[ -f "$ACTIVEMQ_HOME/jetty.xml" ]]; then
            log_info "在根目录找到jetty.xml，将移动到conf目录"
            mkdir -p "$ACTIVEMQ_HOME/conf" 2>/dev/null || mkdir -p "$ACTIVEMQ_HOME/conf"
            cp "$ACTIVEMQ_HOME/jetty.xml" "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || 
            cp "$ACTIVEMQ_HOME/jetty.xml" "$ACTIVEMQ_HOME/conf/jetty.xml"
            rm "$ACTIVEMQ_HOME/jetty.xml" 2>/dev/null || rm "$ACTIVEMQ_HOME/jetty.xml"
        else
            log_error "无法找到jetty.xml配置文件，Web控制台可能无法正常工作"
            return 1
        fi
    fi
    
    # 备份原始jetty.xml文件
    cp "$ACTIVEMQ_HOME/conf/jetty.xml" "$ACTIVEMQ_HOME/conf/jetty.xml.bak" 2>/dev/null || 
    cp "$ACTIVEMQ_HOME/conf/jetty.xml" "$ACTIVEMQ_HOME/conf/jetty.xml.bak"
    
    # 根据参数配置Web控制台访问权限
    if [[ "$DISABLE_EXTERNAL_ACCESS" == true ]]; then
        log_info "配置Web控制台仅允许本地访问..."
        
        # 尝试多种方式配置Web控制台仅允许本地访问
        if ! replace_host_config "0.0.0.0" "localhost" "Web控制台配置为仅允许本地访问"; then
            log_info "未找到标准的0.0.0.0配置，正在查找其他可能的配置项..."
            
            # 尝试替换其他可能的host配置
            replace_host_config "127.0.0.1" "localhost" "Web控制台配置为仅允许本地访问" || \
            replace_host_config "127.0.0.1:8161" "localhost:8161" "Web控制台配置为仅允许本地访问" || \
            replace_host_config "0.0.0.0:8161" "localhost:8161" "Web控制台配置为仅允许本地访问" || \
            log_warn "未能自动配置Web控制台绑定地址，可能需要手动编辑jetty.xml文件"
        fi
    else
        log_info "配置Web控制台允许外部访问..."
        
        # 尝试多种方式配置Web控制台允许外部访问
        if ! replace_host_config "localhost" "0.0.0.0" "Web控制台配置为允许外部访问"; then
            log_info "未找到标准的localhost配置，正在查找其他可能的配置项..."
            
            # 尝试替换其他可能的host配置
            replace_host_config "127.0.0.1" "0.0.0.0" "Web控制台配置为允许外部访问" || \
            replace_host_config "127.0.0.1:8161" "0.0.0.0:8161" "Web控制台配置为允许外部访问" || \
            log_warn "未能自动配置Web控制台绑定地址，可能需要手动编辑jetty.xml文件" && \
            log_info "请检查 $ACTIVEMQ_HOME/conf/jetty.xml 文件中是否有类似 <property name=\"host\" value=\"localhost\"/> 或 <value>127.0.0.1:8161</value> 的配置项" && \
            log_info "请将其修改为 <property name=\"host\" value=\"0.0.0.0\"/> 或 <value>0.0.0.0:8161</value> 以允许外部访问"
        fi
    fi
    
    # 确保端口8161在jetty配置中已启用
    if ! grep -q "8161" "$ACTIVEMQ_HOME/conf/jetty.xml"; then
        log_warn "警告: 未在jetty.xml中找到8161端口配置，请检查Web控制台是否正常工作"
    fi
}

# 配置端口
configure_ports() {
    log_info "配置ActiveMQ端口..."
    
    # 修复配置目录权限
    log_debug "修复配置目录权限..."
    execute_command "chown -R $(whoami):$(whoami) \"$ACTIVEMQ_HOME/conf/\"" || true
    execute_command "chmod -R 755 \"$ACTIVEMQ_HOME/conf/\"" || true
    
    # 备份原始配置文件
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak" 2>/dev/null || 
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak"
    
    # 配置所有端口（端口已在configure_activemq函数中查找）
    log_info "使用端口: Broker=$BROKER_PORT, Jetty=$JETTY_PORT, AMQP=$AMQP_PORT, STOMP=$STOMP_PORT, MQTT=$MQTT_PORT, WebSocket=$WS_PORT"
    
    # 配置Broker端口
    if [[ -n "$BROKER_PORT" && "$BROKER_PORT" != "$DEFAULT_BROKER_PORT" ]]; then
        log_info "将Broker端口从$DEFAULT_BROKER_PORT修改为$BROKER_PORT"
        # 查找并替换Broker端口配置
        sed -i.bak "s|tcp://0.0.0.0:$DEFAULT_BROKER_PORT|tcp://0.0.0.0:$BROKER_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:$DEFAULT_BROKER_PORT|:$BROKER_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置Jetty端口
    if [[ -n "$JETTY_PORT" && "$JETTY_PORT" != "$DEFAULT_JETTY_PORT" ]]; then
        log_info "将Jetty端口从$DEFAULT_JETTY_PORT修改为$JETTY_PORT"
        # 查找并替换Jetty端口配置
        sed -i.bak "s|$DEFAULT_JETTY_PORT|$JETTY_PORT|g" "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    fi
    
    # 配置AMQP端口
    if [[ -n "$AMQP_PORT" && "$AMQP_PORT" != "$DEFAULT_AMQP_PORT" ]]; then
        log_info "将AMQP端口从$DEFAULT_AMQP_PORT修改为$AMQP_PORT"
        # 查找并替换AMQP端口配置
        sed -i.bak "s|amqp://0.0.0.0:$DEFAULT_AMQP_PORT|amqp://0.0.0.0:$AMQP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:$DEFAULT_AMQP_PORT|:$AMQP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置STOMP端口
    if [[ -n "$STOMP_PORT" && "$STOMP_PORT" != "$DEFAULT_STOMP_PORT" ]]; then
        log_info "将STOMP端口从$DEFAULT_STOMP_PORT修改为$STOMP_PORT"
        # 查找并替换STOMP端口配置
        sed -i.bak "s|stomp://0.0.0.0:$DEFAULT_STOMP_PORT|stomp://0.0.0.0:$STOMP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:$DEFAULT_STOMP_PORT|:$STOMP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置MQTT端口
    if [[ -n "$MQTT_PORT" && "$MQTT_PORT" != "$DEFAULT_MQTT_PORT" ]]; then
        log_info "将MQTT端口从$DEFAULT_MQTT_PORT修改为$MQTT_PORT"
        # 查找并替换MQTT端口配置
        sed -i.bak "s|mqtt://0.0.0.0:$DEFAULT_MQTT_PORT|mqtt://0.0.0.0:$MQTT_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:$DEFAULT_MQTT_PORT|:$MQTT_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置WebSocket端口
    if [[ -n "$WS_PORT" && "$WS_PORT" != "$DEFAULT_WS_PORT" ]]; then
        log_info "将WebSocket端口从$DEFAULT_WS_PORT修改为$WS_PORT"
        # 查找并替换WebSocket端口配置
        sed -i.bak "s|ws://0.0.0.0:$DEFAULT_WS_PORT|ws://0.0.0.0:$WS_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:$DEFAULT_WS_PORT|:$WS_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    log_info "端口配置完成"
}

# 提供网络连接故障排除信息
show_network_troubleshooting_info() {
    log_info ""
    log_info "网络连接故障排除:"
    log_info "如果Web管理界面无法从外部访问，请检查以下几点:"
    log_info "1. 防火墙设置 - 确保$JETTY_PORT端口已开放"
    log_info "   - 对于iptables: sudo iptables -A INPUT -p tcp --dport $JETTY_PORT -j ACCEPT"
    log_info "   - 对于firewalld: sudo firewall-cmd --add-port=$JETTY_PORT/tcp --permanent && sudo firewall-cmd --reload"
    log_info "2. 检查 $ACTIVEMQ_HOME/conf/jetty.xml 文件中的绑定配置"
    log_info "3. 确认本机IP地址: $(hostname -I | awk '{print $1}')"
    log_info "4. 可以通过以下命令检查端口是否监听: netstat -tlnp | grep $JETTY_PORT 或 ss -tlnp | grep $JETTY_PORT"
    log_info "5. 如需修改jetty.xml，请将host值设为0.0.0.0而非localhost"
}

# 配置持久化存储
configure_persistence() {
    log_info "配置ActiveMQ持久化存储..."
    
    # 为持久化数据创建目录（在安装目录下创建data目录）
    # 注意：在强制重装模式下，我们会保留此目录以保护用户数据
    local PERSISTENCE_DIR="$INSTALL_DIR/data"
    execute_command "mkdir -p \"$PERSISTENCE_DIR\""
    
    # 修复data目录权限
    log_debug "修复data目录权限..."
    set_directory_permissions_with_logging "$PERSISTENCE_DIR" "$(whoami):$(whoami)" "持久化数据目录"
    # 确保data目录下的文件有正确的权限
    execute_command "find \"$PERSISTENCE_DIR/\" -type f -exec chmod 664 {} \;" || true
    # 在activemq.xml中配置持久化存储路径
    sed -i.bak "s|dataDirectory=\"\${activemq.data}\"|dataDirectory=\"$PERSISTENCE_DIR\"|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || \
    sed -i.bak "s|dataDirectory=\"\${activemq.data}\"|dataDirectory=\"$PERSISTENCE_DIR\"|g" "$ACTIVEMQ_HOME/conf/activemq.xml"
    
    log_info "持久化存储配置完成，数据将保存在: $PERSISTENCE_DIR"
    log_info "注意：持久化数据已保留，如需清理请手动删除此目录"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙..."
    
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    local stomp_port=${STOMP_PORT:-61613}
    local mqtt_port=${MQTT_PORT:-1883}
    local ws_port=${WS_PORT:-61614}
    
    if [[ "$OS" == "Linux" ]]; then
        # 检测防火墙类型 (firewalld 或 iptables)
        if command -v firewall-cmd &> /dev/null; then
            # 使用firewalld
            if systemctl is-active --quiet firewalld; then
                log_info "检测到firewalld，配置防火墙规则..."
                
                # 开放ActiveMQ端口
                execute_command "firewall-cmd --zone=public --add-port=$broker_port/tcp --permanent" || true
                execute_command "firewall-cmd --zone=public --add-port=$jetty_port/tcp --permanent" || true
                execute_command "firewall-cmd --zone=public --add-port=$amqp_port/tcp --permanent" || true
                execute_command "firewall-cmd --zone=public --add-port=$stomp_port/tcp --permanent" || true
                execute_command "firewall-cmd --zone=public --add-port=$mqtt_port/tcp --permanent" || true
                execute_command "firewall-cmd --zone=public --add-port=$ws_port/tcp --permanent" || true
                
                # 重新加载防火墙配置
                execute_command "firewall-cmd --reload" || true
                
                log_info "firewalld防火墙配置完成"
            else
                log_warn "firewalld未运行，跳过防火墙配置"
            fi
        elif command -v iptables &> /dev/null; then
            # 使用iptables
            log_info "检测到iptables，配置防火墙规则..."
            
            # 添加ActiveMQ端口规则
            execute_command "iptables -A INPUT -p tcp --dport $broker_port -j ACCEPT" || true
            execute_command "iptables -A INPUT -p tcp --dport $jetty_port -j ACCEPT" || true
            execute_command "iptables -A INPUT -p tcp --dport $amqp_port -j ACCEPT" || true
            execute_command "iptables -A INPUT -p tcp --dport $stomp_port -j ACCEPT" || true
            execute_command "iptables -A INPUT -p tcp --dport $mqtt_port -j ACCEPT" || true
            execute_command "iptables -A INPUT -p tcp --dport $ws_port -j ACCEPT" || true
            
            log_info "iptables防火墙配置完成，注意重启后规则可能丢失，请保存配置"
        else
            log_warn "未检测到firewalld或iptables，跳过防火墙配置"
        fi
    else  # MacOS
        # MacOS通常使用内置防火墙，这里不做特殊配置
        log_info "MacOS防火墙配置请使用系统偏好设置 -> 安全性与隐私进行配置"
    fi
    
    log_info "防火墙配置完成"
}

# 启动MQ服务
start_mq() {
    if is_artemis; then
        log_info "启动ActiveMQ Artemis服务..."
    else
        log_info "启动ActiveMQ Classic服务..."
    fi
    
    # 修复安装目录权限
    log_debug "修复安装目录权限..."
    execute_command "chown -R $(whoami):$(whoami) \"$INSTALL_DIR/\"" || true
    execute_command "chmod -R 755 \"$INSTALL_DIR/\"" || true
    
    # 确保data目录存在且权限正确
    log_debug "确保data目录存在: $INSTALL_DIR/data"
    execute_command "mkdir -p \"$INSTALL_DIR/data\""
    if [[ "$OS" == "Linux" ]]; then
        # 设置data目录权限，确保当前用户有权限
        log_debug "设置data目录权限: $INSTALL_DIR/data"
        execute_command "chown -R $(whoami):$(whoami) \"$INSTALL_DIR/data\"" || true
        execute_command "chmod 755 \"$INSTALL_DIR/data\"" || true
        # 确保data目录下的文件也有正确的权限
        execute_command "find \"$INSTALL_DIR/data/\" -type f -exec chmod 664 {} \;" || true
    fi

    
    # 为Java 17设置兼容参数
    setup_java17_compatibility
    
    # 切换到安装目录启动，避免getcwd错误
    cd "$INSTALL_DIR"
    
    # 优先使用安装目录中的封装启动脚本
    if [[ -f "$INSTALL_DIR/bin/start.sh" ]]; then
        log_info "调用封装启动脚本: $INSTALL_DIR/bin/start.sh"
        if is_artemis; then
            START_OUTPUT=$($INSTALL_DIR/bin/start.sh -d "$INSTALL_DIR" --artemis --log-level "$LOG_LEVEL" 2>&1)
        else
            START_OUTPUT=$($INSTALL_DIR/bin/start.sh -d "$INSTALL_DIR" --classic --log-level "$LOG_LEVEL" 2>&1)
        fi
        echo "$START_OUTPUT"
    else
        log_debug "执行启动命令"
        if is_artemis; then
            log_info "执行启动命令: $INSTALL_DIR/bin/artemis run"
            START_OUTPUT=$($INSTALL_DIR/bin/artemis run 2>&1)
        else
            log_info "执行启动命令: $INSTALL_DIR/bin/activemq start"
            START_OUTPUT=$($INSTALL_DIR/bin/activemq start 2>&1)
        fi
        echo "$START_OUTPUT"
    fi
    
    # 等待一小段时间让PID文件创建完成
    sleep 3
    
    if is_artemis; then
        log_info "ActiveMQ Artemis服务已启动"
    else
        log_info "ActiveMQ Classic服务已启动"
    fi
}

# 重启ActiveMQ服务
restart_activemq() {
    log_info "重启ActiveMQ服务以应用配置更改..."
    
    if [[ -f "$ACTIVEMQ_HOME/bin/stop.sh" ]]; then
        "$ACTIVEMQ_HOME/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
    fi
    if [[ -f "$ACTIVEMQ_HOME/bin/start.sh" ]]; then
        "$ACTIVEMQ_HOME/bin/start.sh" -d "$INSTALL_DIR" || "$ACTIVEMQ_HOME/bin/activemq" start
    else
        $ACTIVEMQ_HOME/bin/activemq restart
    fi
    
    log_info "ActiveMQ服务已重启"
}

# 从配置文件提取日志文件路径
get_log_file_path() {
    log_debug "正在提取日志文件路径..."
    
    # 根据MQ类型设置HOME变量
    local mq_home=$(get_mq_home)
    
    # 优先检查log4j2配置文件
    local log_file_path=""
    if [[ -f "$mq_home/conf/log4j2.properties" ]]; then
        log_file_path=$(grep -E "^appender\.file\.fileName\s*=" "$mq_home/conf/log4j2.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j2.properties找到日志路径: $log_file_path"
    fi
    
    # 如果log4j2未找到，检查log4j配置文件
    if [[ -z "$log_file_path" && -f "$mq_home/conf/log4j.properties" ]]; then
        log_file_path=$(grep -E "^log4j\.appender\.file\.File\s*=" "$mq_home/conf/log4j.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j.properties找到日志路径: $log_file_path"
    fi
    
    # 处理变量替换和路径转换
    if [[ -n "$log_file_path" ]]; then
        if is_artemis; then
            log_file_path=$(echo "$log_file_path" | sed "s|\${artemis.home}|$mq_home|g" | sed "s|\${artemis.instance}|$INSTALL_DIR|g" | sed "s|\${artemis.instance.dir}|$INSTALL_DIR|g")
        else
            log_file_path=$(echo "$log_file_path" | sed "s|\${activemq\.base}|$mq_home|g" | sed "s|\${activemq\.data}|$INSTALL_DIR/data|g" | sed "s|\${karaf\.data}|$INSTALL_DIR/data|g")
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
    
    log_debug "${MQ_NAME}日志文件路径: $log_file_path"
    
    echo "$log_file_path"
    return 0
}

# 获取并显示进程信息
show_process_info() {
    log_info "正在获取ActiveMQ进程信息..."
    
    # 使用官方status命令获取进程信息
    local mq_home=$(get_mq_home)
    local mq_bin=$(get_mq_bin)
    
    if [[ -x "$mq_bin/activemq" ]] || [[ -x "$mq_bin/artemis" ]]; then
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
    local PID=""
    if is_artemis; then
        PID=$(pgrep -f "artemis.*run" 2>/dev/null || pgrep -f "java.*artemis" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            log_info "通过进程名找到ActiveMQ Artemis进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Artemis进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
        else
            log_warn "未找到ActiveMQ Artemis进程"
        fi
    else
        PID=$(pgrep -f "activemq.*start" 2>/dev/null || pgrep -f "java.*activemq" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            log_info "通过进程名找到ActiveMQ Classic进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Classic进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
        else
            log_warn "未找到ActiveMQ Classic进程"
        fi
    fi
}

# 获取并显示端口信息
show_port_info() {
    log_info "正在获取ActiveMQ端口信息..."
    
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    local stomp_port=${STOMP_PORT:-61613}
    local mqtt_port=${MQTT_PORT:-1883}
    local ws_port=${WS_PORT:-61614}
    
    # 检查ActiveMQ常用端口
    ACTIVE_PORTS=()
    
    # 尝试使用多种工具检查端口
    if command -v ss &> /dev/null; then
        log_info "使用ss命令检查端口..."
        # 查找与ActiveMQ相关的监听端口
        ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -i activemq | awk '{print $4}' | sed 's/.*://' | sort -u) )
        # 如果没有找到ActiveMQ特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(ss -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        fi
    fi
    
    if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]] && command -v netstat &> /dev/null; then
        log_info "使用netstat命令检查端口..."
        # 查找与ActiveMQ相关的监听端口
        ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -i activemq | awk '{print $4}' | sed 's/.*://' | sort -u) )
        # 如果没有找到ActiveMQ特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(netstat -tlnp 2>/dev/null | grep -E ":$broker_port|:$jetty_port|:$amqp_port|:$stomp_port|:$mqtt_port|:$ws_port" | awk '{print $4}' | sed 's/.*://' | sort -u) )
        fi
    fi
    
    if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]] && command -v lsof &> /dev/null; then
        log_info "使用lsof命令检查端口..."
        # 查找与ActiveMQ相关的监听端口
        ACTIVE_PORTS+=( $(lsof -i -P -n 2>/dev/null | grep -i activemq | grep LISTEN | awk '{print $9}' | sed 's/.*://' | sort -u) )
        # 如果没有找到ActiveMQ特定端口，则查找常用端口
        if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
            ACTIVE_PORTS+=( $(lsof -i :$broker_port,:$jetty_port,:$amqp_port,:$stomp_port,:$mqtt_port,:$ws_port -sTCP:LISTEN -n 2>/dev/null | awk '{print $9}' | sed 's/.*://' | sort -u) )
        fi
    fi
    
    if [[ ${#ACTIVE_PORTS[@]} -gt 0 ]]; then
        log_info "ActiveMQ端口信息:"
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
        log_warn "未找到ActiveMQ监听的端口"
        log_info "可能的原因:"
        log_info "  1. ActiveMQ服务未启动"
        log_info "  2. 端口配置有误"
        log_info "  3. 防火墙阻止了端口"
    fi
}

# 显示日志文件路径和内容
show_log_info() {
    log_info "正在获取日志信息..."
    
    # 从配置文件提取日志文件路径
    local LOG_FILE_PATH=$(get_log_file_path)
    
    if [[ -n "$LOG_FILE_PATH" ]]; then
        log_info "ActiveMQ日志文件路径: $LOG_FILE_PATH"
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

# 验证MQ是否成功启动
verify_mq_startup() {
    log_info "验证${MQ_NAME}启动状态..."
    
    # 等待一段时间让服务完全启动
    log_debug "等待5秒让服务完全启动..."
    sleep 5
    
    # 使用官方status命令检查服务状态
    local mq_home=$(get_mq_home)
    local mq_bin=$(get_mq_bin)
    
    if [[ -x "$mq_bin/activemq" ]] || [[ -x "$mq_bin/artemis" ]]; then
        log_info "使用官方status命令检查服务状态..."
        
        if is_artemis; then
            # 对于Artemis，使用status命令
            if [[ -x "$mq_bin/artemis" ]]; then
                local status_output=$("$mq_bin/artemis" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "${MQ_NAME}服务正在运行"
                    log_debug "Status输出: $status_output"
                    return 0
                else
                    log_warn "${MQ_NAME}服务未运行"
                    log_debug "Status输出: $status_output"
                    return 1
                fi
            fi
        else
            # 对于Classic，使用status命令
            if [[ -x "$mq_bin/activemq" ]]; then
                local status_output=$("$mq_bin/activemq" status 2>&1)
                local exit_code=$?
                
                if [[ $exit_code -eq 0 ]] || echo "$status_output" | grep -q "is running"; then
                    log_info "${MQ_NAME}服务正在运行"
                    log_debug "Status输出: $status_output"
                    return 0
                else
                    log_warn "${MQ_NAME}服务未运行"
                    log_debug "Status输出: $status_output"
                    return 1
                fi
            fi
        fi
    fi
    
    # 如果status命令不可用，回退到进程检查
    log_info "Status命令不可用，回退到进程检查..."
    
    # 通过关键词查找进程
    local PID=""
    if is_artemis; then
        PID=$(pgrep -f "artemis.*run" 2>/dev/null || pgrep -f "java.*artemis" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            log_info "通过进程名找到ActiveMQ Artemis进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Artemis进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
            return 0
        else
            log_warn "未找到ActiveMQ Artemis进程"
            return 1
        fi
    else
        PID=$(pgrep -f "activemq.*start" 2>/dev/null || pgrep -f "java.*activemq" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            log_info "通过进程名找到ActiveMQ Classic进程 (PID: $PID)"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ Classic进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
            return 0
        else
            log_warn "未找到ActiveMQ Classic进程"
            return 1
        fi
    fi
}

# 验证安装
verify_installation() {
    log_info "验证${MQ_NAME}安装..."
    
    # 获取日志文件路径
    local LOG_FILE_PATH=$(get_log_file_path)
    
    # 验证MQ启动状态
    if verify_mq_startup; then
        log_info "${MQ_NAME}启动成功"
        
        # 显示进程信息
        show_process_info
        
        # 显示端口信息
        show_port_info
        
        # 显示日志信息
        show_log_info
    else
        log_warn "${MQ_NAME}启动失败，请检查日志文件"
        if [[ -n "$LOG_FILE_PATH" ]]; then
            tail -n 20 "$LOG_FILE_PATH" 2>/dev/null || echo "无法读取日志文件: $LOG_FILE_PATH"
        fi
        # 即使启动失败，也显示进程、端口和日志信息以帮助诊断
        show_process_info
        show_port_info
        show_log_info
        return 1
    fi
    
    # 尝试连接管理端口
    if command -v curl &> /dev/null; then
        if curl -s --connect-timeout 10 http://localhost:8161 > /dev/null; then
            log_info "${MQ_NAME}管理界面可访问: http://localhost:8161"
            log_info "默认用户名/密码: admin/admin (请在生产环境中修改)"
        else
            log_warn "无法连接到管理界面，请检查配置"
        fi
    fi
}

# 为Linux创建systemd服务
create_systemd_service() {
    if [[ "$OS" == "Linux" ]]; then
        local mq_name=$(get_mq_name)
        log_info "创建${mq_name} systemd服务..."
        
        # 创建mq用户和组（如果不存在）
        if ! id "mq" &>/dev/null; then
            execute_command "useradd -r -s /bin/false mq" || true
        fi
        
        # 修复安装目录权限
        set_directory_permissions_with_logging "$INSTALL_DIR" "$(whoami):$(whoami)" "安装目录"
        execute_command "chmod 755 \"$INSTALL_DIR/bin/\"" || execute_command "chmod 755 \"$INSTALL_DIR/bin/\"" || true
        execute_command "chmod 644 \"$INSTALL_DIR/conf/\"" || execute_command "chmod 644 \"$INSTALL_DIR/conf/\"" || true
        
        # 确保data目录存在且权限正确
        execute_command "mkdir -p \"$INSTALL_DIR/data\""
        # 如果mq用户存在，使用该用户；否则使用当前用户
        if id "mq" &>/dev/null; then
            set_directory_permissions "$INSTALL_DIR/data" "mq:mq"
        else
            set_directory_permissions "$INSTALL_DIR/data"
        fi
        
        # 确定服务运行用户
        local SERVICE_USER="mq"
        if ! id "mq" &>/dev/null; then
            SERVICE_USER="$(whoami)"
        fi
        
        # 统一的环境变量
        local service_env_home="MQ_HOME=$INSTALL_DIR"
        local service_env_conf="MQ_CONF=$INSTALL_DIR/conf"
        local service_env_data="MQ_DATA=$INSTALL_DIR/data"
        
        # 使用自定义启动脚本
        local service_exec_start="$INSTALL_DIR/bin/start.sh -d $INSTALL_DIR"
        local service_exec_stop="$INSTALL_DIR/bin/stop.sh -d $INSTALL_DIR --log-level $LOG_LEVEL"
        
        # 创建systemd服务文件内容
        local SERVICE_FILE_CONTENT="[Unit]
Description=${mq_name} Message Broker
After=network.target

[Service]
Type=forking
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=$service_env_home
Environment=$service_env_conf
Environment=$service_env_data
ExecStart=$service_exec_start
ExecStop=$service_exec_stop
Restart=always
RestartSec=9
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=mq
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=multi-user.target"
        
        # 服务文件名
        local service_file_name="mq.service"
        
        # 尝试写入服务文件
        if echo "$SERVICE_FILE_CONTENT" | execute_command "tee /etc/systemd/system/$service_file_name" > /dev/null 2>/dev/null; then
            log_info "${mq_name} systemd服务文件创建成功"
            # 重新加载systemd配置
            execute_command "systemctl daemon-reload" || true
        else
            log_warn "无法创建${mq_name} systemd服务文件，可能没有足够权限"
            log_info "您可以手动创建服务文件，内容如下："
            log_info "----------------------------------------"
            echo "$SERVICE_FILE_CONTENT"
            log_info "----------------------------------------"
        fi
    fi
}

# 清理临时文件（默认不删除安装包）
cleanup() {
    # 默认保留下载的压缩包，用户可以手动清理
    log_info "保留下载的安装包: $DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME"
}

# 安全提示
security_recommendations() {
    log_info "安全建议："
    log_info "1. 生产环境中不要使用默认的admin/admin账户"
    log_info "2. 定期更新密码"
    log_info "3. 限制网络访问权限"
    log_info "4. 启用SSL/TLS加密连接"
    log_info "5. 定期备份数据"
}

# 主函数
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    # 检查是否为卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        log_info "执行卸载模式"
        detect_os  # 确定默认安装目录
        if [[ -z "$INSTALL_DIR" ]]; then
            if [[ "$OS" == "Linux" ]]; then
                INSTALL_DIR="$DEFAULT_INSTALL_DIR"
            else
                INSTALL_DIR="$DEFAULT_INSTALL_DIR"
            fi
        fi
        uninstall_mq
        exit 0
    fi
    
    MQ_NAME=$(get_mq_name)
    log_info "开始安装${MQ_NAME} $MQ_VERSION..."
    
    check_root
    detect_os
    check_installed
    if ! check_java; then
        log_warn "Java未安装或版本不满足，退出但返回码为0"
        exit 0
    fi
    download_mq || log_warn "下载失败或取消，跳过安装并返回码0"
    install_mq
    configure_mq
    
    # 如果配置了Web控制台，则重启服务以应用更改
    start_mq
    
    # 等待一段时间让服务完全启动
    sleep 5
    
    verify_installation
    cleanup
    
    log_info "${MQ_NAME}安装配置完成！"
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    local stomp_port=${STOMP_PORT:-61613}
    local mqtt_port=${MQTT_PORT:-1883}
    local ws_port=${WS_PORT:-61614}
    
    log_info "访问 http://localhost:$jetty_port 或 http://$(hostname -I | awk '{print $1}'):$jetty_port 查看管理界面"
    log_info "默认用户名/密码: admin/admin (请在生产环境中修改)"
    
    log_info ""
    log_info "客户端连接信息："
    log_info "  OpenWire连接URL: tcp://localhost:$broker_port"
    log_info "  AMQP连接URL: amqp://localhost:$amqp_port"
    log_info "  STOMP连接URL: stomp://localhost:$stomp_port"
    log_info "  MQTT连接URL: mqtt://localhost:$mqtt_port"
    log_info "  WebSocket连接URL: ws://localhost:$ws_port"
    if [[ "$GENERATE_RANDOM_PASSWORD" == true ]]; then
        log_info "  用户名: admin (或创建的其他用户)"
        log_info "  密码: 请查看上面生成的随机密码"
    else
        log_info "  用户名: admin (或创建的其他用户)"
        log_info "  密码: admin (或设置的密码)"
    fi
}

# 执行主函数
main "$@"
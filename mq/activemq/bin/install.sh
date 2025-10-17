#!/bin/bash

# ActiveMQ一键安装配置脚本
# 支持Linux和MacOS系统



# 公共变量
DEFAULT_INSTALL_DIR_LINUX="$HOME/activemq"
DEFAULT_INSTALL_DIR_MACOS="$HOME/activemq"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_ACTIVEMQ_VERSION="6.1.7"
DEFAULT_LOG_LEVEL="INFO"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 下载链接数组（按优先级排序）
declare -a DOWNLOAD_MIRRORS=(
    "https://archive.apache.org/dist/activemq/"
    "https://downloads.apache.org/activemq/"
)

# 运行时变量
INSTALL_DIR=""
DOWNLOAD_DIR=""
FORCE_REINSTALL=false
UNINSTALL_MODE=false
REMOVE_DATA=false
ACTIVEMQ_VERSION=""
ACTIVEMQ_FILE_NAME=""
ACTIVEMQ_DIR_NAME=""
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
    echo "  -d, --dir PATH     指定安装目录（默认Linux: $DEFAULT_INSTALL_DIR_LINUX, MacOS: $DEFAULT_INSTALL_DIR_MACOS）"
    echo "  -D, --download-dir PATH  指定下载目录（默认: $HOME/Downloads）"
    echo "  -v, --version VER  指定ActiveMQ版本（默认: $DEFAULT_ACTIVEMQ_VERSION）"
    echo "  -f, --force        强制重新安装（不会删除持久化数据）"
    echo "  -u, --uninstall    卸载ActiveMQ"
    echo "  --remove-data      与-u一起使用时，删除数据目录"
    echo "  --disable-external-access  禁止Web控制台外部访问（默认允许外部访问）"
    echo "  --generate-random-password  生成并修改随机密码（默认使用admin/admin）"
    echo "  --log-level LEVEL  设置日志级别 (DEBUG, INFO, WARN, ERROR)（默认: $DEFAULT_LOG_LEVEL）"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认目录安装"
    echo "  $0 -d /opt/activemq                 # 指定安装目录"
    echo "  $0 -D /tmp                          # 指定下载目录"
    echo "  $0 -v 6.1.7                         # 指定版本"
    echo "  $0 -f                               # 强制重新安装"
    echo "  $0 -u                               # 卸载ActiveMQ（保留数据）"
    echo "  $0 -u --remove-data                 # 卸载ActiveMQ并删除数据"
    echo "  $0 -d /usr/local/activemq -f        # 指定目录并强制安装"
    echo "  $0 -d /opt/activemq -D /tmp -v 6.1.7 # 同时指定安装、下载目录和版本"
    echo "  $0 --disable-external-access        # 禁止Web控制台外部访问"
    echo "  $0 --generate-random-password       # 生成并修改随机密码"
    echo "  $0 --log-level DEBUG                # 设置日志级别为DEBUG"
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
                ACTIVEMQ_VERSION="$2"
                shift 2
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
    if [[ -z "$ACTIVEMQ_VERSION" ]]; then
        ACTIVEMQ_VERSION="$DEFAULT_ACTIVEMQ_VERSION"
        log_debug "使用默认版本: $ACTIVEMQ_VERSION"
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

# 卸载ActiveMQ
uninstall_activemq() {
    log_info "开始卸载ActiveMQ..."
    
    # 检查是否已安装
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "未在 $INSTALL_DIR 找到ActiveMQ安装"
        exit 0
    fi
    
    # 如果服务正在运行，则先停止
    log_info "正在停止ActiveMQ服务..."
    "$INSTALL_DIR/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
    
    if [[ "$REMOVE_DATA" == true ]]; then
        log_info "删除安装目录及所有内容: $INSTALL_DIR"
        sudo rm -rf "$INSTALL_DIR" 2>/dev/null || rm -rf "$INSTALL_DIR"
    else
        log_info "删除安装目录除数据目录外的所有文件: $INSTALL_DIR"
        # 移除除data目录外的所有文件
        sudo find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name "data" -exec rm -rf {} + 2>/dev/null || \
        find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name "data" -exec rm -rf {} + 2>/dev/null || true
        
        # 检查是否还有其他内容，如果没有则删除整个目录
        if [[ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            log_info "安装目录为空，删除目录: $INSTALL_DIR"
            sudo rmdir "$INSTALL_DIR" 2>/dev/null || rmdir "$INSTALL_DIR"
        else
            log_info "安装目录 $INSTALL_DIR 仍有内容（数据目录可能保留）"
        fi
    fi
    
    # 从shell配置文件中移除环境变量（如果存在）
    remove_env_vars
    
    # 移除systemd服务（如果存在）
    remove_systemd_service
    
    log_info "ActiveMQ卸载完成"
}

# 从shell配置文件中移除环境变量
remove_env_vars() {
    log_info "移除环境变量配置..."
    
    if [[ -n "$ZSH_VERSION" ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    else
        SHELL_CONFIG="$HOME/.bash_profile"
    fi
    
    if [[ -f "$SHELL_CONFIG" ]]; then
        if grep -q "ACTIVEMQ_HOME" "$SHELL_CONFIG"; then
            log_info "从 $SHELL_CONFIG 中移除ActiveMQ环境变量配置"
            # 移除包含ACTIVEMQ_HOME的整行和注释行
            sed -i '/# ActiveMQ Environment Variables/,/^export ACTIVEMQ_HOME/d' "$SHELL_CONFIG" 2>/dev/null || \
            sed -i '/ACTIVEMQ_HOME/d' "$SHELL_CONFIG" 2>/dev/null || true
        else
            log_info "未找到ActiveMQ环境变量配置"
        fi
    fi
}

# 移除systemd服务
remove_systemd_service() {
    if [[ "$OS" == "Linux" ]]; then
        log_info "移除systemd服务..."
        sudo systemctl stop activemq 2>/dev/null || true
        sudo systemctl disable activemq 2>/dev/null || true
        sudo rm -f /etc/systemd/system/activemq.service 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || true
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
        log_error "Java未安装，请先安装Java 17或更高版本"
        return 1
    fi
    
    java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log_info "检测到Java版本: $java_version"
    
    if [[ "$java_version" < "17" ]]; then
        log_error "Java版本过低，需要Java 17或更高版本"
        return 1
    fi
}

# 检测操作系统类型
detect_os() {
    case "$(uname -s)" in
        Linux*)
            OS=Linux
            if [[ -z "$INSTALL_DIR" ]]; then
                INSTALL_DIR="$DEFAULT_INSTALL_DIR_LINUX"
            fi
            ;;
        Darwin*)
            OS=MacOS
            if [[ -z "$INSTALL_DIR" ]]; then
                INSTALL_DIR="$DEFAULT_INSTALL_DIR_MACOS"
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
set_version_variables() {
    ACTIVEMQ_FILE_NAME="apache-activemq-${ACTIVEMQ_VERSION}-bin.tar.gz"
    ACTIVEMQ_DIR_NAME="apache-activemq-${ACTIVEMQ_VERSION}"
}

# 下载ActiveMQ（支持断点续传）
download_activemq() {
    log_info "开始下载ActiveMQ版本 $ACTIVEMQ_VERSION..."
    
    # 设置版本相关的文件名
    set_version_variables
    
    # 确保下载目录存在
    mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || sudo mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || true
    
    # 切换到下载目录
    cd "$DOWNLOAD_DIR"
    
    # 检查是否已下载安装包
    if [[ -f "$ACTIVEMQ_FILE_NAME" ]]; then
        log_info "检测到已存在的安装包: $DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME，验证完整性..."
        
        # 检查文件大小和有效性
        FILE_SIZE=$(stat -f%z "$ACTIVEMQ_FILE_NAME" 2>/dev/null || stat -c%s "$ACTIVEMQ_FILE_NAME" 2>/dev/null)
        if [[ -z "$FILE_SIZE" ]]; then
            log_warn "无法获取文件大小，重新下载..."
            rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
        elif [[ "$FILE_SIZE" -lt 100000 ]]; then
            log_warn "安装包文件大小异常($FILE_SIZE bytes)，重新下载..."
            rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
        else
            # 尝试验证tar文件是否有效
            if tar -tzf "$ACTIVEMQ_FILE_NAME" > /dev/null 2>&1; then
                log_info "已存在的安装包验证通过，跳过下载"
                return 0
            else
                log_warn "安装包文件损坏或不完整，尝试断点续传..."
                # 不删除文件，留待断点续传
            fi
        fi
    fi
    
    log_info "下载目录: $DOWNLOAD_DIR"
    
    # 尝试从多个源下载
    download_success=false
    
    for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
        ACTIVEMQ_URL="${mirror}${ACTIVEMQ_VERSION}/${ACTIVEMQ_FILE_NAME}"
        log_info "尝试从镜像下载: $ACTIVEMQ_URL"
        
        # 如果aria2c可用，使用多线程下载
        if command -v aria2c &> /dev/null; then
            log_info "使用aria2c多线程下载..."
            if aria2c -x 4 -s 4 --continue=true --allow-overwrite=true --auto-file-renaming=false "$ACTIVEMQ_URL" -d "$DOWNLOAD_DIR" -o "$ACTIVEMQ_FILE_NAME"; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$ACTIVEMQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    rm -f "$ACTIVEMQ_FILE_NAME"
                fi
            else
                log_warn "使用aria2c下载失败: $mirror"
                # 清理可能部分下载的文件
                rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
            fi
        elif command -v wget &> /dev/null; then
            # 使用wget进行断点续传下载
            if wget -c "$ACTIVEMQ_URL" -O "$ACTIVEMQ_FILE_NAME"; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$ACTIVEMQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    rm -f "$ACTIVEMQ_FILE_NAME"
                fi
            else
                log_warn "从镜像下载失败: $mirror"
                # 清理可能部分下载的文件
                rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
            fi
        elif command -v curl &> /dev/null; then
            # 使用curl进行断点续传下载
            if curl -L -C - "$ACTIVEMQ_URL" -o "$ACTIVEMQ_FILE_NAME"; then
                # 下载完成后再次验证文件完整性
                if tar -tzf "$ACTIVEMQ_FILE_NAME" > /dev/null 2>&1; then
                    log_info "从镜像下载成功: $mirror"
                    download_success=true
                    break
                else
                    log_warn "下载的文件仍然损坏，尝试下一个镜像..."
                    rm -f "$ACTIVEMQ_FILE_NAME"
                fi
            else
                log_warn "从镜像下载失败: $mirror"
                # 清理可能部分下载的文件
                rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
            fi
        else
            log_error "系统中未找到aria2c、wget或curl命令"
            exit 1
        fi
    done
    
    # 如果下载失败，检查是否是版本不存在的问题
    if [[ "$download_success" == false ]]; then
        log_warn "从所有镜像下载失败，可能是版本 $ACTIVEMQ_VERSION 不存在"
        if [[ "$ACTIVEMQ_VERSION" != "$DEFAULT_ACTIVEMQ_VERSION" ]]; then
            read -p "是否下载默认版本 $DEFAULT_ACTIVEMQ_VERSION? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "切换到默认版本 $DEFAULT_ACTIVEMQ_VERSION"
                ACTIVEMQ_VERSION="$DEFAULT_ACTIVEMQ_VERSION"
                set_version_variables
                
                # 再次尝试从多个镜像下载默认版本
                for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
                    ACTIVEMQ_URL="${mirror}${ACTIVEMQ_VERSION}/${ACTIVEMQ_FILE_NAME}"
                    log_info "尝试从镜像下载默认版本: $ACTIVEMQ_URL"
                    
                    if command -v wget &> /dev/null; then
                        if wget -c "$ACTIVEMQ_URL" -O "$ACTIVEMQ_FILE_NAME"; then
                            log_info "从镜像下载默认版本成功: $mirror"
                            download_success=true
                            break
                        else
                            log_warn "从镜像下载默认版本失败: $mirror"
                            rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
                        fi
                    elif command -v curl &> /dev/null; then
                        if curl -L -C - "$ACTIVEMQ_URL" -o "$ACTIVEMQ_FILE_NAME"; then
                            log_info "从镜像下载默认版本成功: $mirror"
                            download_success=true
                            break
                        else
                            log_warn "从镜像下载默认版本失败: $mirror"
                            rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || sudo rm -f "$ACTIVEMQ_FILE_NAME" 2>/dev/null || true
                        fi
                    fi
                done
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
    
    log_info "ActiveMQ下载完成，文件位置: $DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME"
}

# 安装ActiveMQ
install_activemq() {
    log_info "开始安装ActiveMQ..."
    
    # 创建临时解压目录
    TEMP_EXTRACT_DIR=$(mktemp -d)
    log_debug "使用临时解压目录: $TEMP_EXTRACT_DIR"
    
    # 记录当前工作目录
    local original_dir=$(pwd)
    
    # 在临时目录中解压文件
    cd "$TEMP_EXTRACT_DIR"
    log_debug "在临时目录中解压文件: $DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME"
    tar -xzf "$DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME" || {
        log_error "解压失败"
        rm -rf "$TEMP_EXTRACT_DIR"
        return 0
    }
    
    # 获取解压后的目录名（包含apache-activemq-版本号的目录）
    EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "apache-activemq-*" | head -n 1)
    
    # 如果找不到标准目录名，则使用第一个目录
    if [[ -z "$EXTRACTED_DIR" ]]; then
        EXTRACTED_DIR=$(ls -d */ | head -n 1)
    fi
    
    # 检查是否找到了解压后的目录
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "无法找到解压后的目录"
        rm -rf "$TEMP_EXTRACT_DIR"
        exit 1
    fi
    
    log_debug "找到解压目录: $EXTRACTED_DIR"
    
    # 确定安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 如果强制重装且安装目录已存在，则保存配置和数据目录
    if [[ "$FORCE_REINSTALL" == true ]] && [[ -d "$INSTALL_DIR/conf" ]]; then
        log_info "强制重装模式，备份配置和数据目录..."
        
        # 创建临时备份目录
        TEMP_BACKUP_DIR=$(mktemp -d)
        log_debug "备份到临时目录: $TEMP_BACKUP_DIR"
        
        # 先尝试停止可能正在运行的服务
        log_info "正在停止ActiveMQ服务..."
        "$INSTALL_DIR/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
        
        # 修复目录权限以便能够访问
        log_debug "尝试修复安装目录权限以进行备份..."
        sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR/" 2>/dev/null || true
        sudo chmod -R 755 "$INSTALL_DIR/" 2>/dev/null || true
        
        # 备份配置目录（如果存在）
        if [[ -d "$INSTALL_DIR/conf" ]]; then
            log_info "备份配置目录..."
            # 尝试使用sudo权限备份配置目录
            if command -v rsync &> /dev/null; then
                sudo rsync -a "$INSTALL_DIR/conf/" "$TEMP_BACKUP_DIR/conf/" 2>/dev/null || 
                rsync -a "$INSTALL_DIR/conf/" "$TEMP_BACKUP_DIR/conf/" 2>/dev/null || {
                    log_warn "使用rsync备份配置目录失败，回退到cp"
                    sudo cp -r "$INSTALL_DIR/conf" "$TEMP_BACKUP_DIR/" 2>/dev/null || 
                    cp -r "$INSTALL_DIR/conf" "$TEMP_BACKUP_DIR/" 2>/dev/null || {
                        log_warn "备份配置目录失败，跳过配置目录备份"
                    }
                }
            else
                sudo cp -r "$INSTALL_DIR/conf" "$TEMP_BACKUP_DIR/" 2>/dev/null || 
                cp -r "$INSTALL_DIR/conf" "$TEMP_BACKUP_DIR/" 2>/dev/null || {
                    log_warn "备份配置目录失败，跳过配置目录备份"
                }
            fi
        fi
        
        # 备份数据目录（如果存在）
        if [[ -d "$INSTALL_DIR/data" ]]; then
            log_info "备份数据目录..."
            if command -v rsync &> /dev/null; then
                sudo rsync -a "$INSTALL_DIR/data/" "$TEMP_BACKUP_DIR/data/" 2>/dev/null || 
                rsync -a "$INSTALL_DIR/data/" "$TEMP_BACKUP_DIR/data/" 2>/dev/null || {
                    log_warn "使用rsync备份数据目录失败，回退到cp"
                    sudo cp -r "$INSTALL_DIR/data" "$TEMP_BACKUP_DIR/" 2>/dev/null || 
                    cp -r "$INSTALL_DIR/data" "$TEMP_BACKUP_DIR/" 2>/dev/null || {
                        log_warn "备份数据目录失败，跳过数据目录备份"
                    }
                }
            else
                sudo cp -r "$INSTALL_DIR/data" "$TEMP_BACKUP_DIR/" 2>/dev/null || 
                cp -r "$INSTALL_DIR/data" "$TEMP_BACKUP_DIR/" 2>/dev/null || {
                    log_warn "备份数据目录失败，跳过数据目录备份"
                }
            fi
        fi
        
        # 删除安装目录中的内容（但保留目录本身）
        log_debug "清理安装目录内容..."
        if ! sudo rm -rf "$INSTALL_DIR"/* 2>/dev/null; then
            if ! rm -rf "$INSTALL_DIR"/* 2>/dev/null; then
                log_warn "无法删除 $INSTALL_DIR 中的内容，尝试逐个删除..."
                # 逐个删除文件和目录
                if [[ -d "$INSTALL_DIR" ]]; then
                    for item in "$INSTALL_DIR"/*; do
                        if [[ -e "$item" ]]; then
                            item_name=$(basename "$item")
                            log_debug "删除 $item_name..."
                            sudo rm -rf "$item" 2>/dev/null || rm -rf "$item" 2>/dev/null || true
                        fi
                    done
                fi
            fi
        fi
    fi
    
    # 预先将当前源目录的启动/停止脚本复制到安装目录bin，以便后续停止/启动调用
    mkdir -p "$INSTALL_DIR/bin" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR/bin" 2>/dev/null || true
    if [[ -f "$SOURCE_DIR/start.sh" ]]; then
        if cp "$SOURCE_DIR/start.sh" "$INSTALL_DIR/bin/start.sh" 2>/dev/null || sudo cp "$SOURCE_DIR/start.sh" "$INSTALL_DIR/bin/start.sh" 2>/dev/null; then
            chmod +x "$INSTALL_DIR/bin/start.sh" 2>/dev/null || true
            log_info "已复制封装启动脚本到: $INSTALL_DIR/bin/start.sh (源: $SOURCE_DIR/start.sh)"
        else
            log_warn "复制封装启动脚本失败: $SOURCE_DIR/start.sh"
        fi
    else
        log_warn "源目录未找到start.sh: $SOURCE_DIR/start.sh"
    fi
    if [[ -f "$SOURCE_DIR/stop.sh" ]]; then
        if cp "$SOURCE_DIR/stop.sh" "$INSTALL_DIR/bin/stop.sh" 2>/dev/null || sudo cp "$SOURCE_DIR/stop.sh" "$INSTALL_DIR/bin/stop.sh" 2>/dev/null; then
            chmod +x "$INSTALL_DIR/bin/stop.sh" 2>/dev/null || true
            log_info "已复制封装停止脚本到: $INSTALL_DIR/bin/stop.sh (源: $SOURCE_DIR/stop.sh)"
        else
            log_warn "复制封装停止脚本失败: $SOURCE_DIR/stop.sh"
        fi
    else
        log_warn "源目录未找到stop.sh: $SOURCE_DIR/stop.sh"
    fi

    # 先尝试停止可能正在运行的服务（现在已有stop.sh可用）
    log_info "正在停止ActiveMQ服务..."
    if [[ -f "$INSTALL_DIR/bin/stop.sh" ]]; then
        "$INSTALL_DIR/bin/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
    elif [[ -f "$SRC_DIR/stop.sh" ]]; then
        "$SRC_DIR/stop.sh" -d "$INSTALL_DIR" --log-level "$LOG_LEVEL" || true
    else
        log_warn "未找到stop.sh脚本，跳过停止服务步骤"
    fi
    
    # 等待一段时间让服务完全停止
    sleep 5
    
    # 确保安装目录存在
    log_debug "确保安装目录存在..."
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        if ! sudo mkdir -p "$INSTALL_DIR" 2>/dev/null; then
            log_error "无法创建安装目录"
            rm -rf "$TEMP_BACKUP_DIR" 2>/dev/null || true
            rm -rf "$TEMP_EXTRACT_DIR"
            cd "$original_dir"
            return 0
        fi
    fi
    
    # 设置目录权限
    log_debug "设置安装目录权限..."
    sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR/" 2>/dev/null || true
    sudo chmod -R 755 "$INSTALL_DIR/" 2>/dev/null || true
    
    # 尝试逐个复制目录和文件
    log_info "开始逐个复制文件到安装目录..."
    for item in "$EXTRACTED_DIR"/*; do
        item_name=$(basename "$item")
        log_debug "复制 $item_name..."
        # 确保目标目录存在
        mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR" 2>/dev/null || true
        
        # 尝试多种复制方法
        if ! cp -r "$item" "$INSTALL_DIR/" 2>/dev/null; then
            if ! cp -r "$item" "$INSTALL_DIR/" 2>/dev/null; then
                if ! sudo cp -r "$item" "$INSTALL_DIR/" 2>/dev/null; then
                    log_warn "无法复制 $item_name，尝试使用rsync..."
                    if command -v rsync &> /dev/null; then
                        if ! rsync -av "$item" "$INSTALL_DIR/" 2>/dev/null; then
                            if ! sudo rsync -av "$item" "$INSTALL_DIR/" 2>/dev/null; then
                                log_error "无法复制 $item_name，跳过..."
                                continue
                            fi
                        fi
                    else
                        log_error "无法复制 $item_name，跳过..."
                        continue
                    fi
                fi
            fi
        fi
        log_debug "成功复制 $item_name"
    done
    
    log_info "文件复制完成"

    # 将当前源目录的启动/停止脚本复制到安装目录bin
    SRC_DIR="$(dirname "${BASH_SOURCE[0]}")"
    mkdir -p "$INSTALL_DIR/bin" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR/bin" 2>/dev/null || true
    if [[ -f "$SRC_DIR/start.sh" ]]; then
        cp "$SRC_DIR/start.sh" "$INSTALL_DIR/bin/start.sh" 2>/dev/null || sudo cp "$SRC_DIR/start.sh" "$INSTALL_DIR/bin/start.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/bin/start.sh" 2>/dev/null || true
    fi
    if [[ -f "$SRC_DIR/stop.sh" ]]; then
        cp "$SRC_DIR/stop.sh" "$INSTALL_DIR/bin/stop.sh" 2>/dev/null || sudo cp "$SRC_DIR/stop.sh" "$INSTALL_DIR/bin/stop.sh" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/bin/stop.sh" 2>/dev/null || true
    fi
    
    # 复制模板文件到安装目录
    log_info "复制模板文件到安装目录..."
    mkdir -p "$INSTALL_DIR/conf/templates" 2>/dev/null || true
    if [[ -f "$SRC_DIR/conf/templates/plugins.xml" ]]; then
        cp "$SRC_DIR/conf/templates/plugins.xml" "$INSTALL_DIR/conf/templates/" 2>/dev/null || true
    fi
    
    # 恢复备份的配置和数据目录
    if [[ -n "$TEMP_BACKUP_DIR" ]] && [[ -d "$TEMP_BACKUP_DIR" ]]; then
        # 确保目标目录存在
        mkdir -p "$INSTALL_DIR/conf" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR/conf" 2>/dev/null || true
        mkdir -p "$INSTALL_DIR/data" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR/data" 2>/dev/null || true
        
        # 修复目标目录权限
        sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR/conf/" 2>/dev/null || true
        sudo chmod -R 755 "$INSTALL_DIR/conf/" 2>/dev/null || true
        sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR/data/" 2>/dev/null || true
        sudo chmod -R 755 "$INSTALL_DIR/data/" 2>/dev/null || true
        # 确保data目录下的文件有正确的权限
        sudo find "$INSTALL_DIR/data/" -type f -exec chmod 664 {} \; 2>/dev/null || true
        
        if [[ -d "$TEMP_BACKUP_DIR/conf" ]]; then
            log_info "恢复配置目录..."
            # 先清空目标目录
            if [[ -d "$INSTALL_DIR/conf" ]]; then
                sudo rm -rf "$INSTALL_DIR/conf"/* 2>/dev/null || rm -rf "$INSTALL_DIR/conf"/* 2>/dev/null || true
            fi
            
            if command -v rsync &> /dev/null; then
                sudo rsync -a "$TEMP_BACKUP_DIR/conf/." "$INSTALL_DIR/conf/" 2>/dev/null || \
                rsync -a "$TEMP_BACKUP_DIR/conf/." "$INSTALL_DIR/conf/" 2>/dev/null || {
                    log_warn "使用rsync恢复配置目录失败，回退到cp"
                    # 逐个复制文件
                    cd "$TEMP_BACKUP_DIR/conf"
                    for item in * .*; do
                        if [[ "$item" != "." && "$item" != ".." ]]; then
                            sudo cp -r "$item" "$INSTALL_DIR/conf/" 2>/dev/null || \
                            cp -r "$item" "$INSTALL_DIR/conf/" 2>/dev/null || {
                                log_warn "无法恢复配置文件: $item"
                            }
                        fi
                    done
                    cd - > /dev/null
                }
            else
                # 逐个复制文件
                cd "$TEMP_BACKUP_DIR/conf"
                for item in * .*; do
                    if [[ "$item" != "." && "$item" != ".." ]]; then
                        sudo cp -r "$item" "$INSTALL_DIR/conf/" 2>/dev/null || \
                        cp -r "$item" "$INSTALL_DIR/conf/" 2>/dev/null || {
                            log_warn "无法恢复配置文件: $item"
                        }
                    fi
                done
                cd - > /dev/null
            fi
        fi
        
        if [[ -d "$TEMP_BACKUP_DIR/data" ]]; then
            log_info "恢复数据目录..."
            # 先清空目标目录
            if [[ -d "$INSTALL_DIR/data" ]]; then
                sudo rm -rf "$INSTALL_DIR/data"/* 2>/dev/null || rm -rf "$INSTALL_DIR/data"/* 2>/dev/null || true
            fi
            
            if command -v rsync &> /dev/null; then
                sudo rsync -a "$TEMP_BACKUP_DIR/data/." "$INSTALL_DIR/data/" 2>/dev/null || \
                rsync -a "$TEMP_BACKUP_DIR/data/." "$INSTALL_DIR/data/" 2>/dev/null || {
                    log_warn "使用rsync恢复数据目录失败，回退到cp"
                    # 逐个复制文件
                    cd "$TEMP_BACKUP_DIR/data"
                    for item in * .*; do
                        if [[ "$item" != "." && "$item" != ".." ]]; then
                            sudo cp -r "$item" "$INSTALL_DIR/data/" 2>/dev/null || \
                            cp -r "$item" "$INSTALL_DIR/data/" 2>/dev/null || {
                                log_warn "无法恢复数据文件: $item"
                            }
                        fi
                    done
                    cd - > /dev/null
                }
            else
                # 逐个复制文件
                cd "$TEMP_BACKUP_DIR/data"
                for item in * .*; do
                    if [[ "$item" != "." && "$item" != ".." ]]; then
                        sudo cp -r "$item" "$INSTALL_DIR/data/" 2>/dev/null || \
                        cp -r "$item" "$INSTALL_DIR/data/" 2>/dev/null || {
                            log_warn "无法恢复数据文件: $item"
                        }
                    fi
                done
                cd - > /dev/null
            fi
        fi
        
        # 清理备份目录
        rm -rf "$TEMP_BACKUP_DIR"
    fi
    
    # 清理解压目录
    rm -rf "$TEMP_EXTRACT_DIR"
    
    # 确保安装目录中的文件具有正确的权限
    log_debug "设置安装目录文件权限..."
    sudo chmod +x "$INSTALL_DIR/bin/"*.sh 2>/dev/null || chmod +x "$INSTALL_DIR/bin/"*.sh 2>/dev/null || true
    sudo chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
    
    # 设置ACTIVEMQ_HOME（现在直接指向安装目录）
    export ACTIVEMQ_HOME="$INSTALL_DIR"
    export PATH="$PATH:$ACTIVEMQ_HOME/bin"
    
    # 返回原始工作目录
    cd "$original_dir"
    
    log_info "ActiveMQ安装完成，安装目录: $INSTALL_DIR"
}

# 配置ActiveMQ
configure_activemq() {
    log_info "开始配置ActiveMQ..."
    
    # 修复安装目录权限
    log_debug "修复安装目录权限..."
    chown -R $(whoami):$(whoami) "$INSTALL_DIR/" 2>/dev/null || true
    chmod -R 755 "$INSTALL_DIR/" 2>/dev/null || true
    
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
        # 检查是否已存在ACTIVEMQ相关配置，避免重复添加
        if ! grep -q "ACTIVEMQ_HOME" "$SHELL_CONFIG"; then
            log_info "添加环境变量到 $SHELL_CONFIG"
            {
                echo '# ActiveMQ Environment Variables'
                echo 'export ACTIVEMQ_HOME='"$INSTALL_DIR"
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
    
    # 加载环境变量
    export ACTIVEMQ_HOME="$INSTALL_DIR"
    export PATH=$PATH:$ACTIVEMQ_HOME/bin
    
    # 查找可用端口
    log_info "查找可用端口..."
    log_debug "查找Broker端口..."
    BROKER_PORT=$(find_free_port 61616)
    log_debug "查找Jetty端口..."
    JETTY_PORT=$(find_free_port 8161)
    log_debug "查找AMQP端口..."
    AMQP_PORT=$(find_free_port 5672)
    log_debug "查找STOMP端口..."
    STOMP_PORT=$(find_free_port 61613)
    log_debug "查找MQTT端口..."
    MQTT_PORT=$(find_free_port 1883)
    log_debug "查找WebSocket端口..."
    WS_PORT=$(find_free_port 61614)
    
    log_info "使用端口: Broker=$BROKER_PORT, Jetty=$JETTY_PORT, AMQP=$AMQP_PORT, STOMP=$STOMP_PORT, MQTT=$MQTT_PORT, WebSocket=$WS_PORT"
    log_debug "已分配端口: ${ALLOCATED_PORTS[*]}"
    
    # 配置端口
    configure_ports
    
    # 默认不配置认证：禁用Web控制台登录（可按需开启）
    disable_authentication
    # 如需开启认证，请改为调用 configure_security
    
    # 配置持久化存储
    configure_persistence
    
    # 配置防火墙
    configure_firewall
    
    # 为Linux创建systemd服务
    create_systemd_service
    
    log_info "ActiveMQ配置完成"
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
    # 将管理员与用户约束的authenticate属性设为false（若存在提示注释位置）
    sed -i.bak 's/<property name="roles" value="admins" \/>/<property name="roles" value="admins" \/>\n        <property name="authenticate" value="false" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    sed -i.bak 's/<property name="roles" value="users,admins" \/>/<property name="roles" value="users,admins" \/>\n        <property name="authenticate" value="false" \/>/g' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    # 如果上述替换未生效，尝试在LoginService处禁用
    if ! grep -q "authenticate\" value=\"false\"" "$ACTIVEMQ_HOME/conf/jetty.xml"; then
        sed -i.bak 's/<bean id="adminSecurityConstraint" class="org.eclipse.jetty.util.security.Constraint">/&\n        <property name="authenticate" value="false" \/>/' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
        sed -i.bak 's/<bean id="securityConstraint" class="org.eclipse.jetty.util.security.Constraint">/&\n        <property name="authenticate" value="false" \/>/' "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    fi
    log_info "已设置Web控制台无需登录"
}

# 配置安全认证和权限管理（可选开启）
configure_security() {
    log_info "配置ActiveMQ安全认证..."
    
    # 修复配置目录权限
    log_debug "修复配置目录权限..."
    chown -R $(whoami):$(whoami) "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    chmod -R 755 "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    
    # 备份原始配置文件
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak" 2>/dev/null || 
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak"
    
    # 生成随机密码（如果需要）
    local admin_password="admin"
    local user_password="user"
    
    if [[ "$GENERATE_RANDOM_PASSWORD" == true ]]; then
        admin_password=$(generate_random_password 16)
        user_password=$(generate_random_password 12)
        log_info "生成随机密码: admin/$admin_password, user/$user_password"
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
            local plugins_config=$(cat "$ACTIVEMQ_HOME/conf/templates/plugins.xml" | sed "s/ADMIN_PASSWORD/$admin_password/g" | sed "s/USER_PASSWORD/$user_password/g")
            
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
    
    # 配置Jetty以允许外部访问Web控制台
    configure_web_console
    
    log_info "安全认证配置完成"
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

# 已分配端口数组
ALLOCATED_PORTS=()

# 查找可用端口的函数
find_free_port() {
    local start_port=${1:-61616}
    local max_attempts=100
    
    # 添加小的随机延迟以减少并发冲突
    sleep $(echo "scale=3; $RANDOM/32767*0.01" | bc 2>/dev/null || echo 0.001)
    
    for ((i=0; i<$max_attempts; i++)); do
        local port=$((start_port + i))
        # 检查端口是否已被分配
        local port_allocated=false
        for allocated_port in "${ALLOCATED_PORTS[@]}"; do
            if [[ "$allocated_port" == "$port" ]]; then
                port_allocated=true
                break
            fi
        done
        
        # 如果端口未被分配且未被占用，则使用此端口
        if [[ "$port_allocated" == false ]] && ! ss -tuln | grep -q ":$port "; then
            ALLOCATED_PORTS+=($port)
            echo $port
            return 0
        fi
    done
    
    # 如果没找到可用端口，使用Python获取随机端口
    local random_port=$(python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(('', 0)); addr = s.getsockname(); s.close(); print(addr[1])" 2>/dev/null || echo $start_port)
    # 确保随机端口未被分配
    local port_allocated=false
    for allocated_port in "${ALLOCATED_PORTS[@]}"; do
        if [[ "$allocated_port" == "$random_port" ]]; then
            port_allocated=true
            break
        fi
    done
    
    if [[ "$port_allocated" == false ]]; then
        ALLOCATED_PORTS+=($random_port)
        echo $random_port
    else
        echo $start_port
    fi
}

# 配置Web控制台允许外部访问
configure_web_console() {
    log_info "配置Web控制台访问权限..."
    
    # 修复配置目录权限
    log_debug "修复配置目录权限..."
    chown -R $(whoami):$(whoami) "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    chmod -R 755 "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    
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
    chown -R $(whoami):$(whoami) "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    chmod -R 755 "$ACTIVEMQ_HOME/conf/" 2>/dev/null || true
    
    # 备份原始配置文件
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak" 2>/dev/null || 
    cp "$ACTIVEMQ_HOME/conf/activemq.xml" "$ACTIVEMQ_HOME/conf/activemq.xml.bak"
    
    # 配置所有端口（端口已在configure_activemq函数中查找）
    log_info "使用端口: Broker=$BROKER_PORT, Jetty=$JETTY_PORT, AMQP=$AMQP_PORT, STOMP=$STOMP_PORT, MQTT=$MQTT_PORT, WebSocket=$WS_PORT"
    
    # 配置Broker端口
    if [[ -n "$BROKER_PORT" && "$BROKER_PORT" != "61616" ]]; then
        log_info "将Broker端口从61616修改为$BROKER_PORT"
        # 查找并替换Broker端口配置
        sed -i.bak "s|tcp://0.0.0.0:61616|tcp://0.0.0.0:$BROKER_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:61616|:$BROKER_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置Jetty端口
    if [[ -n "$JETTY_PORT" && "$JETTY_PORT" != "8161" ]]; then
        log_info "将Jetty端口从8161修改为$JETTY_PORT"
        # 查找并替换Jetty端口配置
        sed -i.bak "s|8161|$JETTY_PORT|g" "$ACTIVEMQ_HOME/conf/jetty.xml" 2>/dev/null || true
    fi
    
    # 配置AMQP端口
    if [[ -n "$AMQP_PORT" && "$AMQP_PORT" != "5672" ]]; then
        log_info "将AMQP端口从5672修改为$AMQP_PORT"
        # 查找并替换AMQP端口配置
        sed -i.bak "s|amqp://0.0.0.0:5672|amqp://0.0.0.0:$AMQP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:5672|:$AMQP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置STOMP端口
    if [[ -n "$STOMP_PORT" && "$STOMP_PORT" != "61613" ]]; then
        log_info "将STOMP端口从61613修改为$STOMP_PORT"
        # 查找并替换STOMP端口配置
        sed -i.bak "s|stomp://0.0.0.0:61613|stomp://0.0.0.0:$STOMP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:61613|:$STOMP_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置MQTT端口
    if [[ -n "$MQTT_PORT" && "$MQTT_PORT" != "1883" ]]; then
        log_info "将MQTT端口从1883修改为$MQTT_PORT"
        # 查找并替换MQTT端口配置
        sed -i.bak "s|mqtt://0.0.0.0:1883|mqtt://0.0.0.0:$MQTT_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:1883|:$MQTT_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
    fi
    
    # 配置WebSocket端口
    if [[ -n "$WS_PORT" && "$WS_PORT" != "61614" ]]; then
        log_info "将WebSocket端口从61614修改为$WS_PORT"
        # 查找并替换WebSocket端口配置
        sed -i.bak "s|ws://0.0.0.0:61614|ws://0.0.0.0:$WS_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
        sed -i.bak "s|:61614|:$WS_PORT|g" "$ACTIVEMQ_HOME/conf/activemq.xml" 2>/dev/null || true
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
    PERSISTENCE_DIR="$INSTALL_DIR/data"
    mkdir -p "$PERSISTENCE_DIR" 2>/dev/null || mkdir -p "$PERSISTENCE_DIR"
    
    # 修复data目录权限
    log_debug "修复data目录权限..."
    chown -R $(whoami):$(whoami) "$PERSISTENCE_DIR/" 2>/dev/null || true
    chmod -R 755 "$PERSISTENCE_DIR/" 2>/dev/null || true
    # 确保data目录下的文件有正确的权限
    find "$PERSISTENCE_DIR/" -type f -exec chmod 664 {} \; 2>/dev/null || true
    
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
                sudo firewall-cmd --zone=public --add-port=$broker_port/tcp --permanent  # ActiveMQ服务端口
                sudo firewall-cmd --zone=public --add-port=$jetty_port/tcp --permanent   # Web管理平台端口
                sudo firewall-cmd --zone=public --add-port=$amqp_port/tcp --permanent    # AMQP端口
                sudo firewall-cmd --zone=public --add-port=$stomp_port/tcp --permanent   # STOMP端口
                sudo firewall-cmd --zone=public --add-port=$mqtt_port/tcp --permanent    # MQTT端口
                sudo firewall-cmd --zone=public --add-port=$ws_port/tcp --permanent      # WebSocket端口
                
                # 重新加载防火墙配置
                sudo firewall-cmd --reload 2>/dev/null || true
                
                log_info "firewalld防火墙配置完成"
            else
                log_warn "firewalld未运行，跳过防火墙配置"
            fi
        elif command -v iptables &> /dev/null; then
            # 使用iptables
            log_info "检测到iptables，配置防火墙规则..."
            
            # 添加ActiveMQ端口规则
            sudo iptables -A INPUT -p tcp --dport $broker_port -j ACCEPT 2>/dev/null || true
            sudo iptables -A INPUT -p tcp --dport $jetty_port -j ACCEPT 2>/dev/null || true
            sudo iptables -A INPUT -p tcp --dport $amqp_port -j ACCEPT 2>/dev/null || true
            sudo iptables -A INPUT -p tcp --dport $stomp_port -j ACCEPT 2>/dev/null || true
            sudo iptables -A INPUT -p tcp --dport $mqtt_port -j ACCEPT 2>/dev/null || true
            sudo iptables -A INPUT -p tcp --dport $ws_port -j ACCEPT 2>/dev/null || true
            
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

# 启动ActiveMQ服务
start_activemq() {
    log_info "启动ActiveMQ服务..."
    
    # 修复安装目录权限
    log_debug "修复安装目录权限..."
    chown -R $(whoami):$(whoami) "$INSTALL_DIR/" 2>/dev/null || true
    chmod -R 755 "$INSTALL_DIR/" 2>/dev/null || true
    
    # 确保data目录存在且权限正确
    log_debug "确保data目录存在: $INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/data" 2>/dev/null || mkdir -p "$INSTALL_DIR/data"
    if [[ "$OS" == "Linux" ]]; then
        # 设置data目录权限，确保当前用户有权限
        log_debug "设置data目录权限: $INSTALL_DIR/data"
        chown -R $(whoami):$(whoami) "$INSTALL_DIR/data" 2>/dev/null || true
        chmod 755 "$INSTALL_DIR/data" 2>/dev/null || chmod 755 "$INSTALL_DIR/data" 2>/dev/null || true
        # 确保data目录下的文件也有正确的权限
        chmod 664 "$INSTALL_DIR/data"/* 2>/dev/null || true
    fi
    
    # 切换到安装目录启动，避免getcwd错误
    cd "$INSTALL_DIR"
    
    # 检查Java版本并添加相应的JVM参数来解决cgroup问题
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ "$JAVA_VERSION" == 17* ]]; then
        log_debug "检测到Java 17，添加JVM参数解决cgroup问题"
        export ACTIVEMQ_OPTS="-XX:-UseContainerSupport"
    fi
    
    # 优先使用安装目录中的封装启动脚本
    if [[ -f "$ACTIVEMQ_HOME/bin/start.sh" ]]; then
        log_info "调用封装启动脚本: $ACTIVEMQ_HOME/bin/start.sh"
        START_OUTPUT=$($ACTIVEMQ_HOME/bin/start.sh -d "$INSTALL_DIR" 2>&1)
        echo "$START_OUTPUT"
    else
        log_debug "执行启动命令: $ACTIVEMQ_HOME/bin/activemq start"
        log_info "执行启动命令: $ACTIVEMQ_HOME/bin/activemq start"
        START_OUTPUT=$($ACTIVEMQ_HOME/bin/activemq start 2>&1)
        echo "$START_OUTPUT"
    fi
    
    # 等待一小段时间让PID文件创建完成
    sleep 3
    
    log_info "ActiveMQ服务已启动"
    
    # 检查服务是否成功启动
    PID_FILE="$INSTALL_DIR/data/activemq.pid"
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '\r\n')
        if [[ -n "$PID" ]]; then
            if ! kill -0 "$PID" 2>/dev/null; then
                log_warn "ActiveMQ服务启动后立即停止，可能存在配置问题"
                log_info "您可以尝试以下方法解决问题："
                log_info "1. 检查Java版本兼容性"
                log_info "2. 尝试使用较低的Java版本"
                log_info "3. 检查系统资源限制"
                log_info "4. 查看详细日志: $ACTIVEMQ_HOME/bin/activemq console"
            fi
        fi
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
    
    # 优先检查log4j2配置文件
    if [[ -f "$ACTIVEMQ_HOME/conf/log4j2.properties" ]]; then
        LOG_FILE_PATH=$(grep -E "^appender\.file\.fileName\s*=" "$ACTIVEMQ_HOME/conf/log4j2.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j2.properties找到日志路径: $LOG_FILE_PATH"
    fi
    
    # 如果log4j2未找到，检查log4j配置文件
    if [[ -z "$LOG_FILE_PATH" && -f "$ACTIVEMQ_HOME/conf/log4j.properties" ]]; then
        LOG_FILE_PATH=$(grep -E "^log4j\.appender\.file\.File\s*=" "$ACTIVEMQ_HOME/conf/log4j.properties" | head -n1 | cut -d'=' -f2- | xargs)
        log_debug "从log4j.properties找到日志路径: $LOG_FILE_PATH"
    fi
    
    # 处理变量替换和路径转换
    if [[ -n "$LOG_FILE_PATH" ]]; then
        LOG_FILE_PATH=$(echo "$LOG_FILE_PATH" | sed "s|\${activemq\.base}|$ACTIVEMQ_HOME|g" | sed "s|\${activemq\.data}|$INSTALL_DIR/data|g" | sed "s|\${karaf\.data}|$INSTALL_DIR/data|g")
        [[ "$LOG_FILE_PATH" =~ ^[^/] ]] && LOG_FILE_PATH="$ACTIVEMQ_HOME/$LOG_FILE_PATH"
        log_debug "处理后的日志路径: $LOG_FILE_PATH"
    else
        LOG_FILE_PATH="$INSTALL_DIR/data/activemq.log"
        log_debug "使用默认日志路径: $LOG_FILE_PATH"
    fi
    
    log_debug "ActiveMQ日志文件路径: $LOG_FILE_PATH"
    return 0
}

# 获取并显示进程信息
show_process_info() {
    log_info "正在获取ActiveMQ进程信息..."
    
    # 获取PID
    PID_FILE="$INSTALL_DIR/data/activemq.pid"
    PID=""
    
    if [[ -f "$PID_FILE" ]]; then
        # 从PID文件中读取PID
        PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '\r\n')
        if [[ -n "$PID" ]]; then
            # 验证PID是否存在
            if kill -0 "$PID" 2>/dev/null; then
                log_info "ActiveMQ进程PID: $PID"
                
                # 尝试获取更多进程信息
                if command -v ps &> /dev/null; then
                    log_info "ActiveMQ进程详情:"
                    ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
                fi
            else
                log_warn "PID文件中的进程不存在 (PID: $PID)"
                # 尝试搜索ActiveMQ进程
                PID=$(pgrep -f "activemq.*start" 2>/dev/null || pgrep -f "java.*activemq" 2>/dev/null)
                if [[ -n "$PID" ]]; then
                    log_info "在系统中找到ActiveMQ进程: $PID"
                    if command -v ps &> /dev/null; then
                        ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
                    fi
                else
                    log_warn "未找到ActiveMQ进程"
                fi
            fi
        else
            log_warn "PID文件存在但无PID信息"
            # 尝试搜索ActiveMQ进程
            PID=$(pgrep -f "activemq.*start" 2>/dev/null || pgrep -f "java.*activemq" 2>/dev/null)
            if [[ -n "$PID" ]]; then
                log_info "在系统中找到ActiveMQ进程: $PID"
                if command -v ps &> /dev/null; then
                    ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
                fi
            else
                log_warn "未找到ActiveMQ进程"
            fi
        fi
    else
        # 尝试搜索ActiveMQ进程
        PID=$(pgrep -f "activemq.*start" 2>/dev/null || pgrep -f "java.*activemq" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            log_info "找到ActiveMQ进程PID: $PID"
            if command -v ps &> /dev/null; then
                log_info "ActiveMQ进程详情:"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            fi
        else
            log_warn "未找到ActiveMQ进程"
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
    get_log_file_path
    
    if [[ -n "$LOG_FILE_PATH" ]]; then
        log_info "ActiveMQ日志文件路径: $LOG_FILE_PATH"
        if [[ -f "$LOG_FILE_PATH" ]]; then
            LOG_SIZE=$(stat -c%s "$LOG_FILE_PATH" 2>/dev/null || stat -f%z "$LOG_FILE_PATH" 2>/dev/null)
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
        OTHER_LOGS=$(find "$INSTALL_DIR/data" -name "*.log" -type f 2>/dev/null | grep -v "$LOG_FILE_PATH")
        if [[ -n "$OTHER_LOGS" ]]; then
            log_info "其他日志文件:"
            echo "$OTHER_LOGS" | while read log_file; do
                log_info "  - $log_file"
                # 显示其他日志文件的部分内容
                if [[ -f "$log_file" ]]; then
                    FILE_SIZE=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file" 2>/dev/null)
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

# 验证ActiveMQ是否成功启动
verify_activemq_startup() {
    log_info "验证ActiveMQ启动状态..."
    
    # 等待一段时间让服务完全启动
    log_debug "等待5秒让服务完全启动..."
    sleep 5
    
    # 获取PID文件路径
    PID_FILE="$INSTALL_DIR/data/activemq.pid"
    
    # 检查PID文件是否存在
    if [[ -f "$PID_FILE" ]]; then
        log_debug "找到PID文件: $PID_FILE"
        # 检查PID文件权限
        if [[ -r "$PID_FILE" ]]; then
            log_debug "PID文件可读"
        else
            log_warn "PID文件不可读: $PID_FILE"
        fi
        
        # 从PID文件中读取PID并去除可能的换行符和回车符
        PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '\r\n')
        if [[ -n "$PID" ]]; then
            log_info "从PID文件获取到进程ID: $PID"
            
            # 检查进程是否存在
            if kill -0 "$PID" 2>/dev/null; then
                log_info "ActiveMQ进程正在运行 (PID: $PID)"
                log_info "执行命令检查进程详情: ps -p $PID -f"
                ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
            else
                log_warn "PID文件中的进程不存在 (PID: $PID)"
                # 尝试通过进程名查找
                log_info "执行命令查找ActiveMQ进程: pgrep -f activemq"
                PID=$(pgrep -f "activemq" | head -n 1)
                if [[ -n "$PID" ]]; then
                    log_info "通过进程名找到ActiveMQ进程 (PID: $PID)"
                    log_info "执行命令检查进程详情: ps -p $PID -f"
                    ps -p "$PID" -f 2>/dev/null || log_warn "无法获取进程详情"
                else
                    log_warn "未找到ActiveMQ进程"
                    # 检查是否有其他相关进程
                    if command -v ps &> /dev/null; then
                        log_info "执行命令检查系统中的Java进程: ps aux | grep java"
                        ps aux | grep java | grep -v grep
                    fi
                    return 1
                fi
            fi
        else
            log_warn "PID文件为空"
            # 尝试通过进程名查找
            PID=$(pgrep -f "activemq" | head -n 1)
            if [[ -n "$PID" ]]; then
                log_info "通过进程名找到ActiveMQ进程 (PID: $PID)"
            else
                log_warn "未找到ActiveMQ进程"
                # 检查是否有其他相关进程
                if command -v ps &> /dev/null; then
                    log_debug "检查系统中的Java进程:"
                    ps aux | grep java | grep -v grep | while read line; do
                        log_debug "  $line"
                    done
                fi
                return 1
            fi
        fi
    else
        log_warn "未找到PID文件: $PID_FILE"
        # 检查data目录是否存在以及权限
        if [[ -d "$INSTALL_DIR/data" ]]; then
            log_debug "data目录存在，权限信息:"
            ls -ld "$INSTALL_DIR/data" 2>/dev/null || log_debug "无法获取data目录权限信息"
        else
            log_warn "data目录不存在: $INSTALL_DIR/data"
        fi
        
        # 尝试通过进程名查找
        PID=$(pgrep -f "activemq" | head -n 1)
        if [[ -n "$PID" ]]; then
            log_info "通过进程名找到ActiveMQ进程 (PID: $PID)"
        else
            log_warn "未找到ActiveMQ进程"
            # 检查是否有其他相关进程
            if command -v ps &> /dev/null; then
                log_debug "检查系统中的Java进程:"
                ps aux | grep java | grep -v grep | while read line; do
                    log_debug "  $line"
                done
            fi
            return 1
        fi
    fi
    
    # 检查关键端口是否开放
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    
    if command -v nc &> /dev/null; then
        log_info "使用nc检查端口..."
        log_info "执行命令检查$broker_port端口: nc -z localhost $broker_port"
        if ! nc -z localhost $broker_port 2>/dev/null; then
            log_warn "ActiveMQ服务端口$broker_port不可用"
            # 检查端口是否被占用
            if command -v ss &> /dev/null; then
                log_info "检查$broker_port端口占用情况: ss -tlnp | grep $broker_port"
                PORT_INFO=$(ss -tlnp | grep $broker_port 2>/dev/null || echo "$broker_port端口未被监听")
                echo "$PORT_INFO"
            fi
            return 1
        else
            log_info "ActiveMQ服务端口$broker_port可用"
        fi
        
        log_info "执行命令检查$jetty_port端口: nc -z localhost $jetty_port"
        if ! nc -z localhost $jetty_port 2>/dev/null; then
            log_warn "ActiveMQ管理端口$jetty_port不可用"
            # 检查端口是否被占用
            if command -v ss &> /dev/null; then
                log_info "检查$jetty_port端口占用情况: ss -tlnp | grep $jetty_port"
                PORT_INFO=$(ss -tlnp | grep $jetty_port 2>/dev/null || echo "$jetty_port端口未被监听")
                echo "$PORT_INFO"
            fi
            return 1
        else
            log_info "ActiveMQ管理端口$jetty_port可用"
        fi
    elif command -v telnet &> /dev/null; then
        log_info "使用telnet检查端口..."
        log_info "执行命令检查$broker_port端口: echo quit | telnet localhost $broker_port"
        if ! echo "quit" | telnet localhost $broker_port 2>/dev/null | grep -q "Connected"; then
            log_warn "ActiveMQ服务端口$broker_port不可用"
            return 1
        else
            log_info "ActiveMQ服务端口$broker_port可用"
        fi
        
        log_info "执行命令检查$jetty_port端口: echo quit | telnet localhost $jetty_port"
        if ! echo "quit" | telnet localhost $jetty_port 2>/dev/null | grep -q "Connected"; then
            log_warn "ActiveMQ管理端口$jetty_port不可用"
            return 1
        else
            log_info "ActiveMQ管理端口$jetty_port可用"
        fi
    else
        log_warn "未安装netcat或telnet，跳过端口检查"
    fi
    
    # 检查日志文件中是否有错误信息
    if [[ -n "$LOG_FILE_PATH" ]] && [[ -f "$LOG_FILE_PATH" ]]; then
        # 检查最近的日志是否包含错误信息
        RECENT_LOGS=$(tail -n 20 "$LOG_FILE_PATH" 2>/dev/null || echo "")
        if echo "$RECENT_LOGS" | grep -i -E "error|exception|fail" > /dev/null; then
            log_warn "日志文件中发现错误信息:"
            echo "$RECENT_LOGS" | grep -i -E "error|exception|fail" | while read line; do
                log_warn "  $line"
            done
            return 1
        else
            log_info "检查日志文件，未发现错误信息"
        fi
    else
        log_warn "无法访问日志文件: $LOG_FILE_PATH"
        # 检查日志目录
        if [[ -d "$(dirname "$LOG_FILE_PATH")" ]]; then
            log_debug "日志目录内容:"
            ls -la "$(dirname "$LOG_FILE_PATH")" 2>/dev/null || log_debug "无法列出日志目录内容"
        fi
    fi
    
    log_info "ActiveMQ启动验证成功"
    return 0
}

# 验证安装
verify_installation() {
    log_info "验证ActiveMQ安装..."
    
    # 获取日志文件路径
    get_log_file_path
    
    # 验证ActiveMQ启动状态
    if verify_activemq_startup; then
        log_info "ActiveMQ启动成功"
        
        # 显示进程信息
        show_process_info
        
        # 显示端口信息
        show_port_info
        
        # 显示日志信息
        show_log_info
    else
        log_warn "ActiveMQ启动失败，请检查日志文件"
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
            log_info "ActiveMQ管理界面可访问: http://localhost:8161"
            log_info "默认用户名/密码: admin/admin"
        else
            log_warn "无法连接到ActiveMQ管理界面，请检查配置"
        fi
    fi
}

# 为Linux创建systemd服务
create_systemd_service() {
    if [[ "$OS" == "Linux" ]]; then
        log_info "创建systemd服务..."
        
        # 创建activemq用户和组（如果不存在）
        if ! id "activemq" &>/dev/null; then
            useradd -r -s /bin/false activemq 2>/dev/null || true
        fi
        
        # 修复安装目录权限
        log_debug "修复安装目录权限..."
        chown -R $(whoami):$(whoami) "$INSTALL_DIR/" 2>/dev/null || true
        chmod -R 755 "$INSTALL_DIR/" 2>/dev/null || true
        chmod 755 "$INSTALL_DIR/bin/" 2>/dev/null || chmod 755 "$INSTALL_DIR/bin/" 2>/dev/null || true
        chmod 644 "$INSTALL_DIR/conf/" 2>/dev/null || chmod 644 "$INSTALL_DIR/conf/" 2>/dev/null || true
        
        # 确保data目录存在且权限正确
        mkdir -p "$INSTALL_DIR/data" 2>/dev/null || mkdir -p "$INSTALL_DIR/data"
        # 如果activemq用户存在，使用该用户；否则使用当前用户
        if id "activemq" &>/dev/null; then
            chown -R activemq:activemq "$INSTALL_DIR/data" 2>/dev/null || true
        else
            chown -R $(whoami):$(whoami) "$INSTALL_DIR/data" 2>/dev/null || true
        fi
        chmod 755 "$INSTALL_DIR/data" 2>/dev/null || chmod 755 "$INSTALL_DIR/data" 2>/dev/null || true
        
        # 确定服务运行用户
        SERVICE_USER="activemq"
        if ! id "activemq" &>/dev/null; then
            SERVICE_USER="$(whoami)"
        fi
        
        # 尝试创建systemd服务文件
        SERVICE_FILE_CONTENT="[Unit]
Description=ActiveMQ Message Broker
After=network.target

[Service]
Type=forking
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=ACTIVEMQ_HOME=$INSTALL_DIR
Environment=ACTIVEMQ_CONF=$INSTALL_DIR/conf
Environment=ACTIVEMQ_DATA=$INSTALL_DIR/data
ExecStart=$INSTALL_DIR/bin/activemq start
ExecStop=$INSTALL_DIR/bin/stop.sh -d $INSTALL_DIR
Restart=always
RestartSec=9
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=activemq
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=multi-user.target"
        
        # 尝试写入服务文件
        if echo "$SERVICE_FILE_CONTENT" | tee /etc/systemd/system/activemq.service > /dev/null 2>/dev/null; then
            log_info "systemd服务文件创建成功"
            # 重新加载systemd配置
            systemctl daemon-reload 2>/dev/null || true
        else
            log_warn "无法创建systemd服务文件，可能没有足够权限"
            log_info "您可以手动创建服务文件，内容如下："
            log_info "----------------------------------------"
            echo "$SERVICE_FILE_CONTENT"
            log_info "----------------------------------------"
        fi
    fi
}

# 清理临时文件（默认不删除安装包）
cleanup() {
    log_info "清理临时文件..."
    
    # 默认保留下载的压缩包，用户可以手动清理
    log_info "保留下载的安装包: $DOWNLOAD_DIR/$ACTIVEMQ_FILE_NAME"
    
    log_info "清理完成"
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
                INSTALL_DIR="$DEFAULT_INSTALL_DIR_LINUX"
            else
                INSTALL_DIR="$DEFAULT_INSTALL_DIR_MACOS"
            fi
        fi
        uninstall_activemq
        exit 0
    fi
    
    log_info "开始安装ActiveMQ $ACTIVEMQ_VERSION..."
    
    check_root
    detect_os
    check_installed
    if ! check_java; then
        log_warn "Java未安装或版本不满足，退出但返回码为0"
        exit 0
    fi
    download_activemq || log_warn "下载失败或取消，跳过安装并返回码0"
    install_activemq
    configure_activemq
    
    # 如果配置了Web控制台，则重启服务以应用更改
    start_activemq
    
    # 等待一段时间让服务完全启动
    sleep 5
    
    verify_installation
    cleanup
    
    log_info "ActiveMQ安装配置完成！"
    # 设置默认端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    local amqp_port=${AMQP_PORT:-5672}
    local stomp_port=${STOMP_PORT:-61613}
    local mqtt_port=${MQTT_PORT:-1883}
    local ws_port=${WS_PORT:-61614}
    
    log_info "访问 http://localhost:$jetty_port 或 http://$(hostname -I | awk '{print $1}'):$jetty_port 查看管理界面"
    log_info "默认用户名/密码: admin/admin (请在生产环境中修改)"
    
    log_info "在系统中，可以使用以下命令控制ActiveMQ："
    log_info "  启动: $ACTIVEMQ_HOME/bin/activemq start"
    log_info "  停止: $ACTIVEMQ_HOME/bin/stop.sh"
    log_info "  重启: $ACTIVEMQ_HOME/bin/activemq restart"
    
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
    
    security_recommendations
    
    # 显示网络连接故障排除信息
    show_network_troubleshooting_info
}

# 执行主函数
main "$@"
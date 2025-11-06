#!/bin/bash

# Seata 自动化安装脚本
# 兼容主流 Linux 和 macOS 系统
# 支持指定安装目录、卸载、自动启动服务和下载目录

set -e  # 退出立即如果命令退出状态为非零

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "错误: 找不到公共函数库 $SCRIPT_DIR/common.sh"
    exit 1
fi

# 公共变量
DEFAULT_INSTALL_DIR="$HOME/seata"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_VERSION=""  # 空值表示自动检测最新版本
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
VERSION="$DEFAULT_VERSION"
UNINSTALL=false
INSTALL_SERVICE=false
FORCE_INSTALL=false
CURRENT_USER=$(whoami)
DEFAULT_VERSION="2.5.0" 
VERSION=${DEFAULT_VERSION}
SUDO_CMD="sudo"
USE_SUDO=false
OS=""

# 下载URL
SEATA_URL="https://www.apache.org/dyn/closer.lua/incubator/seata/${DEFAULT_VERSION}/apache-seata-${DEFAULT_VERSION}-incubating-bin.tar.gz?action=download"
BACKUP_URL="https://github.com/seata/seata/releases/download/v${DEFAULT_VERSION}/seata-server-${DEFAULT_VERSION}.tar.gz"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 带颜色的输出函数
print_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 显示使用帮助
print_usage() {
    cat << EOF
用法: $0 [选项]

Seata 自动安装脚本。

选项:
    -d, --dir PATH          安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -w, --download-dir PATH 下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)
    -v, --version VERSION   安装版本 (默认: 最新稳定版)
    -u, --uninstall         卸载 Seata
    -s, --service           安装自启动服务 (默认: false)
    -f                      强制安装 (如果目录已存在则覆盖)
    -h, --help              显示此帮助消息

示例:
    $0                                    # 安装到默认目录
    $0 -d /opt/seata                     # 安装到 /opt/seata
    $0 --uninstall                       # 卸载 Seata
    $0 -d /opt/seata -s                  # 安装到 /opt/seata 并安装服务
    $0 -w /tmp/downloads                 # 使用自定义下载目录
    $0 -v 1.7.1 -f                       # 安装指定版本并强制覆盖
EOF
}

# 检测操作系统是否为 macOS 或 Linux
detect_os() {
    local os_type
    os_type=$(get_os_type 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    OS="$os_type"
    SUDO_CMD="sudo"
}

# 检查 sudo 是否可用
check_sudo() {
    if ! command -v sudo &> /dev/null; then
        SUDO_CMD=""
        print_warn "未找到 sudo 命令，将不使用权限提升"
    fi
}

# 需要时请求权限提升
sudoexec() {
    local target_dir="$1"
    
    # 检查是否可以写入目录
    if [[ ! -w "$(dirname "$target_dir")" ]]; then
        if [[ -n "$SUDO_CMD" ]]; then
            print_info "为目录请求权限提升: $target_dir"
            $SUDO_CMD -v || {
                print_error "获取 root 权限失败"
                exit 1
            }
            USE_SUDO=true
        else
            print_error "目录无写入权限: $target_dir 且 sudo 不可用"
            exit 1
        fi
    else
        USE_SUDO=false
    fi
}

# 执行命令函数，内部使用USE_SUDO变量判断是否需要提权执行
execute_command() {
    local cmd="$1"
    shift
    local args=("$@")
    
    if [[ "$USE_SUDO" == "true" ]]; then
        $SUDO_CMD "$cmd" "${args[@]}"
    else
        "$cmd" "${args[@]}"
    fi
}




# 验证归档文件完整性
verify_archive() {
    local archive_path="$1"
    
    if command -v tar &> /dev/null; then
        # 尝试列出归档内容以验证完整性
        if tar -tf "$archive_path" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # 如果没有 tar 命令，则简单检查文件大小
        if [[ -s "$archive_path" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

# 从官方版本下载 Seata
download_seata() {
    local url=$1
    
    # 指定版本不是默认版本则下载指定版本
    if [ "$VERSION" != "$DEFAULT_VERSION" ]; then
        # 替换URL中的DEFAULT_VERSION为VERSION
        url="${url//DEFAULT_VERSION/$VERSION}"
    fi
    
    # 从URL中获取tar文件名
    local tar_file=$(basename "$url" | sed 's/action=download//g' | sed 's/\&.*//g')
    path="$DOWNLOAD_DIR/$tar_file"
    
    # 确保下载目录存在
    [ ! -d $DOWNLOAD_DIR ] && mkdir -p "$DOWNLOAD_DIR"
    
    print_info "下载目录: $DOWNLOAD_DIR"
    print_info "从以下地址下载 Seata: $url"
    
    # 检查文件是否已存在（仅当指定了版本时）
    if [ -f "$path" ]; then
        print_info "指定版本的 Seata 安装包已存在: $path"
        # 尝试解压以验证文件完整性
        if verify_archive "$path"; then
            print_info "安装包验证成功，跳过下载"
            return 0
        fi
    fi
    
    # 尝试多线程并行下载（如果 aria2c 可用）
    if command -v aria2c &> /dev/null; then
        print_info "使用 aria2c 进行多线程并行下载"
        aria2c -x 4 -s 4 -c -d "$DOWNLOAD_DIR" -o "$tar_file" "$url" && return 0
    # 如果 axel 可用
    elif command -v axel &> /dev/null; then
        print_info "使用 axel 进行多线程并行下载"
        axel -n 4 -o "$path" "$url" && return 0
    # 使用 curl 断点续传
    elif command -v curl &> /dev/null; then
        print_info "使用 curl 断点续传下载"
        # 如果文件已存在部分，使用 -C - 进行断点续传
        if [[ -f "$path" ]]; then
            curl -L --fail --continue-at - -o "$path" "$url" && return 0
        else
            curl -L --fail -o "$path" "$url" && return 0
        fi
    # 使用 wget 断点续传
    elif command -v wget &> /dev/null; then
        print_info "使用 wget 断点续传下载"
        # 使用 -c 进行断点续传
        wget -c -O "$path" "$url" && return 0
    else
        print_error "无可用下载工具 (aria2c, axel, curl, wget)"
        return 1
    fi
    
    # 判断指定版本不是默认版本且下载文件不存在则下载默认版本  
    if [ "$VERSION" != "$DEFAULT_VERSION" ] && [ ! -f "$path" ]; then
        # 重新构建使用默认版本的URL
        local default_url="${SEATA_URL//VERSION/$DEFAULT_VERSION}"
        print_warn "指定版本下载失败，尝试下载默认版本 $DEFAULT_VERSION"
        download_seata "$default_url"
    fi
    
    # 如还是下载失败则判断是否不是BACKUP_URL，如果不是则使用BACKUP_URL
    if [ ! -f "$path" ] && [[ "$url" != "$BACKUP_URL" ]]; then
        print_warn "主下载链接失败，尝试备用链接 $BACKUP_URL"
        download_seata "$BACKUP_URL"
    fi
    
    # 验证文件完整性
    if ! verify_archive "$path"; then
        print_error "下载的文件验证失败，可能是不完整的文件"
        rm -f "$path"
        exit 1
    fi
    
    print_info "Seata 下载成功: $path"
}
 
# 解压并安装 Seata
install_seata() {
    local install_dir="$1"
    
    print_info "安装 Seata 到: $install_dir"
    
    # 如果目录不存在则创建
    execute_command mkdir -p "$install_dir"
    
    # 解压下载的归档文件 (使用 global 'path' variable from download_seata function)
    if ! tar -xzf "$path" -C "$install_dir" --strip-components=1; then
        print_error "解压失败，重新下载安装包"
        rm -f "$path"
        download_seata
        if ! tar -xzf "$path" -C "$install_dir" --strip-components=1; then
            print_error "多次尝试后解压仍然失败"
            exit 1
        fi
    fi
    
    # 获取项目根目录（相对于安装脚本）
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    # 复制自定义脚本到安装目录
    print_info "复制文件..."
    execute_command rsync -av "$SCRIPT_DIR/" "$install_dir/"
    # 设置适当的权限
    execute_command chown -R "$CURRENT_USER:$(id -gn)" "$install_dir"
    execute_command chmod +x "$install_dir/bin/*.sh"
    
    print_info "Seata 成功安装到: $install_dir"
    print_info "使用以下命令管理 Seata 服务:"
    print_info "  启动服务: $install_dir/bin/start.sh"
    print_info "  停止服务: $install_dir/bin/stop.sh"
    print_info "  查看状态: $install_dir/bin/start.sh -s"
}

# 为自动启动创建系统服务
create_service() {
    local install_dir="$1"
    
    print_info "为 Seata 创建自动启动服务..."
    
    if [[ "$OS" == "Linux" ]]; then
        # 创建 systemd 服务
        SERVICE_FILE="/etc/systemd/system/seata.service"
        
        if [[ "$USE_SUDO" != "true" ]]; then
            print_warn "创建系统服务需要 root 权限"
            $SUDO_CMD -v || {
                print_error "获取 root 权限失败"
                exit 1
            }
        fi
        
        # 检查是否自定义了start.sh脚本，如果存在则优先使用
        START_SCRIPT_PATH="$install_dir/bin/start.sh"
        if [[ ! -f "$START_SCRIPT_PATH" ]]; then
            START_SCRIPT_PATH="$install_dir/bin/seata-server.sh"
        fi
        
        # Create the service file using execute_command
        cat > /tmp/seata.service << EOF
[Unit]
Description=Seata Server
After=network.target

[Service]
Type=forking
User=$CURRENT_USER
ExecStart=$START_SCRIPT_PATH
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF
        execute_command cp /tmp/seata.service "$SERVICE_FILE"
        rm -f /tmp/seata.service
        
        execute_command systemctl daemon-reload
        print_info "Seata 服务已创建。启用命令: sudo systemctl enable seata"
        print_info "启动命令: sudo systemctl start seata"
        
    elif [[ "$OS" == "macOS" ]]; then
        # 创建 launchd 服务
        LAUNCHD_FILE="/Library/LaunchDaemons/io.seata.server.plist"
        
        if [[ "$USE_SUDO" != "true" ]]; then
            print_warn "创建系统服务需要 root 权限"
            $SUDO_CMD -v || {
                print_error "获取 root 权限失败"
                exit 1
            }
        fi
        
        # 检查是否自定义了start.sh脚本，如果存在则优先使用
        START_SCRIPT_PATH="$install_dir/bin/start.sh"
        if [[ ! -f "$START_SCRIPT_PATH" ]]; then
            START_SCRIPT_PATH="$install_dir/bin/seata-server.sh"
        fi
        
        # Create the plist file using execute_command
        cat > /tmp/io.seata.server.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.seata.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$START_SCRIPT_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$install_dir</string>
    <key>StandardOutPath</key>
    <string>$install_dir/logs/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$install_dir/logs/stderr.log</string>
</dict>
</plist>
EOF
        execute_command cp /tmp/io.seata.server.plist "$LAUNCHD_FILE"
        rm -f /tmp/io.seata.server.plist
        
        print_info "Seata 服务已创建。加载命令: sudo launchctl load $LAUNCHD_FILE"
        print_info "启动命令: sudo launchctl start io.seata.server"
    fi
}

# 卸载 Seata
uninstall_seata() {
    local install_dir="$1"
    
    print_info "从以下位置卸载 Seata: $install_dir"
    
    if [[ -d "$install_dir" ]]; then
        # 如果有自定义停止脚本，优先使用它停止服务
        STOP_SCRIPT_PATH="$install_dir/bin/stop.sh"
        if [[ -f "$STOP_SCRIPT_PATH" ]]; then
            print_info "使用自定义停止脚本停止 Seata 服务..."
            execute_command "$STOP_SCRIPT_PATH" -f
        else
            # 如果服务正在运行则停止
            if [[ "$OS" == "Linux" ]]; then
                if systemctl is-active --quiet seata; then
                    print_info "正在停止 Seata 服务..."
                    execute_command systemctl stop seata
                fi
            elif [[ "$OS" == "macOS" ]]; then
                if sudo launchctl list | grep -q io.seata.server; then
                    print_info "正在停止 Seata 服务..."
                    execute_command launchctl stop io.seata.server
                fi
            fi
        fi
        
        # 停止系统服务（如果存在）
        if [[ "$OS" == "Linux" ]]; then
            if systemctl is-enabled --quiet seata; then
                print_info "正在禁用 Seata 服务..."
                execute_command systemctl disable seata
            fi
            # 移除服务文件
            if [[ -f "/etc/systemd/system/seata.service" ]]; then
                print_info "正在移除 Seata 服务文件..."
                execute_command rm -f /etc/systemd/system/seata.service
                execute_command systemctl daemon-reload
            fi
        elif [[ "$OS" == "macOS" ]]; then
            # 移除服务文件
            if [[ -f "/Library/LaunchDaemons/io.seata.server.plist" ]]; then
                print_info "正在移除 Seata 服务文件..."
                execute_command rm -f /Library/LaunchDaemons/io.seata.server.plist
            fi
        fi
        
        # 移除安装目录
        execute_command rm -rf "$install_dir"
        
        print_info "Seata 卸载成功"
    else
        print_warn "安装目录不存在: $install_dir"
    fi
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        -w|--download-dir)
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -u|--uninstall)
            UNINSTALL=true
            shift
            ;;
        -s|--service)
            INSTALL_SERVICE=true
            shift
            ;;
        -f)
            FORCE_INSTALL=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            print_error "未知选项: $1"
            print_usage
            exit 1
            ;;
    esac
done

# 检查安装目录是否已存在
check_install_dir_exists() {
    local install_dir="$1"
    
    if [[ -d "$install_dir" ]]; then
        if [[ "$FORCE_INSTALL" == true ]]; then
            print_info "强制安装模式：安装目录 $install_dir 已存在，将被覆盖"
            return 0
        else
            print_warn "安装目录 $install_dir 已存在"
            read -p "是否继续安装？[Y/n] " -n 1 -r REPLY
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
                print_info "安装已取消"
                exit 0
            fi
            return 0
        fi
    fi
    
    return 1
}
 

# 主执行函数
main() {
    detect_os
    check_sudo
    
    if [[ "$UNINSTALL" == true ]]; then
        sudoexec "$INSTALL_DIR"
        uninstall_seata "$INSTALL_DIR"
    else
        sudoexec "$INSTALL_DIR"
        
        # 检查安装目录是否已存在
        check_install_dir_exists "$INSTALL_DIR"
        
        # 下载并安装 Seata
        download_seata "$SEATA_URL"
        install_seata "$INSTALL_DIR"
        
        # 如有请求则创建服务
        if [[ "$INSTALL_SERVICE" == true ]]; then
            create_service "$INSTALL_DIR"
        fi
        
        print_info "安装成功完成!"
        print_info "Seata 安装到: $INSTALL_DIR"
        print_info "使用以下命令管理 Seata 服务:"
        print_info "  启动服务: $INSTALL_DIR/bin/start.sh"
        print_info "  停止服务: $INSTALL_DIR/bin/stop.sh"
        print_info "  查看状态: $INSTALL_DIR/bin/start.sh -s"
        
        # 自动启动服务
        print_info "正在自动启动 Seata 服务..."
        START_SCRIPT_PATH="$INSTALL_DIR/bin/start.sh"
        if [[ -f "$START_SCRIPT_PATH" ]]; then
            execute_command "$START_SCRIPT_PATH"
        else
            print_warn "启动脚本未找到: $START_SCRIPT_PATH"
            print_info "请手动启动服务: $INSTALL_DIR/bin/seata-server.sh"
        fi
    fi
}

# 运行主函数
main "$@"
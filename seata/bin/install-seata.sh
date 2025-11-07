#!/bin/bash

# Seata 自动化安装脚本
# 兼容主流 Linux 和 macOS 系统
# 支持指定安装目录、卸载、自动启动服务和下载目录

# 默认启用错误退出，但在调试模式下禁用
DEBUG_MODE=false
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
DEFAULT_VERSION="2.5.0"  # 固定版本号避免重复定义
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
VERSION="$DEFAULT_VERSION"
UNINSTALL=false
INSTALL_SERVICE=false
FORCE_INSTALL=false
CURRENT_USER=$(whoami)
SUDO_CMD="sudo"
USE_SUDO=false
OS=""

# 下载URL - 按优先级合并的URL列表
DOWNLOAD_URLS=(
    "https://mirrors.tuna.tsinghua.edu.cn/apache/incubator/seata/${DEFAULT_VERSION}/apache-seata-${DEFAULT_VERSION}-incubating-bin.tar.gz"  # 国内镜像URL
    "https://archive.apache.org/dist/incubator/seata/${DEFAULT_VERSION}/apache-seata-${DEFAULT_VERSION}-incubating-bin.tar.gz"  # 官方URL
    "https://github.com/seata/seata/releases/download/v${DEFAULT_VERSION}/seata-server-${DEFAULT_VERSION}.tar.gz"  # 备用URL
)
SEATA_SERVER_SH="seata-server.sh"
START_SCRIPT_PATH="start.sh"
STOP_SCRIPT_PATH="stop.sh"
# 下载文件路径
GZ_FILE_PATH=""

# 有错误时也输出调试信息
if [[ "$DEBUG_MODE" == true ]]; then
    set +e  # 在调试模式下禁用立即退出
    print_info "调试模式已启用，禁用set -e选项"
else
    set -e  # 在非调试模式下启用立即退出
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 带颜色的输出函数
print_info() {
    echo -e "${GREEN}[信息]${NC} $1" >&2
}

print_warn() {
    echo -e "${YELLOW}[警告]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
}

# 显示使用帮助
print_usage() {
    cat << EOF
用法: $0 [选项]

Seata 自动安装脚本。

选项:
    -d, --dir PATH          安装目录 (默认: $DEFAULT_INSTALL_DIR)
    -w, --download-dir PATH 下载目录 (默认: $DEFAULT_DOWNLOAD_DIR)
    -v, --version VERSION   安装版本 (默认: $DEFAULT_VERSION)
    -u, --uninstall         卸载 Seata
    -s, --service           安装自启动服务 (默认: false)
    -f                      强制安装 (如果目录已存在则覆盖)
    -x, --debug             调试模式 (不使用 set -e，显示详细输出)
    -h, --help              显示此帮助消息

示例:
    $0                                    # 安装到默认目录
    $0 -d /opt/seata                     # 安装到 /opt/seata
    $0 --uninstall                       # 卸载 Seata
    $0 -d /opt/seata -s                  # 安装到 /opt/seata 并安装服务
    $0 -w /tmp/downloads                 # 使用自定义下载目录
    $0 -v 1.7.1 -f                       # 安装指定版本并强制覆盖
    $0 -x                                  # 以调试模式运行
EOF
}

# 检测操作系统是否为 macOS 或 Linux
detect_os() {
    local os_type
    os_type=$(get_os_type 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        print_error "无法检测操作系统类型"
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

# 执行命令函数，内部使用USE_SUDO变量判断是否需要提权执行
exec() {
    local cmd="$1"
    shift
    local args=("$@")
    local cmd_string="$cmd ${args[*]}"  # 保存原始命令用于显示
    # 检查是否需要使用sudo
    if [[ "$USE_SUDO" == "true" ]]; then
        "$SUDO_CMD" "$cmd" "${args[@]}"
    else
        "$cmd" "${args[@]}" || {
            # 如果命令执行失败，尝试使用sudo执行并设置USE_SUDO为true
            if [[ -n "$SUDO_CMD" ]]; then
                print_warn "命令执行失败，尝试使用sudo执行: $cmd_string"
                "$SUDO_CMD" "$cmd" "${args[@]}"
                USE_SUDO=true
            else
                return 1  # 如果没有sudo命令可用，直接返回错误
            fi
        }
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
        # 也替换可能的其他版本占位符
        url="${url//${DEFAULT_VERSION}/$VERSION}"
    fi
    # 从URL中获取tar文件名
    local tar_file=$(basename "$url" | sed 's/action=download//g' | sed 's/\&.*//g' | sed 's/\?//g')
   GZ_FILE_PATH="$DOWNLOAD_DIR/$tar_file"
    
    # 确保下载目录存在
    [ ! -d "$DOWNLOAD_DIR" ] && mkdir -p "$DOWNLOAD_DIR"
    
    # 检查文件是否已存在（仅当指定了版本时）
    if [ -f "$GZ_FILE_PATH" ]; then
        print_info "指定版本的 Seata 安装包已存在: $GZ_FILE_PATH"
        # 尝试解压以验证文件完整性
        if verify_archive "$GZ_FILE_PATH"; then
            print_info "安装包验证成功，跳过下载"
            return 0
        fi
    fi
    
    print_info "下载 Seata: $url"
    print_info "下载目录: $DOWNLOAD_DIR"
    
    # 尝试多线程并行下载（如果 aria2c 可用）- 优先使用性能最高的工具
    if command -v aria2c &> /dev/null; then
        print_info "使用 aria2c 进行多线程并行下载 (4线程)"
        aria2c -x 8 -s 8 -c --max-connection-per-server=8 --split=8 --continue=true -d "$DOWNLOAD_DIR" -o "$tar_file" "$url" && return 0
        print_warn "aria2c 下载失败，尝试其他下载方式"
    # 如果 axel 可用
    elif command -v axel &> /dev/null; then
        print_info "使用 axel 进行多线程并行下载 (8线程)"
        axel -n 8 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        print_warn "axel 下载失败，尝试其他下载方式"
    # 使用 wget 断点续传
    elif command -v wget &> /dev/null; then
        print_info "使用 wget 断点续传下载"
        # 使用 -c 进行断点续传，添加更多重试和超时设置
        wget -c --tries=5 --timeout=30 --continue -O "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        print_warn "wget 下载失败，尝试其他下载方式"
    # 使用 curl 断点续传
    elif command -v curl &> /dev/null; then
        print_info "使用 curl 断点续传下载"
        # 如果文件已存在部分，使用 -C - 进行断点续传
        if [[ -f "$DOWNLOAD_DIR/$tar_file" ]]; then
            curl -L --fail --continue-at - --connect-timeout 10 --max-time 3600 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        else
            curl -L --fail --connect-timeout 10 --max-time 3600 -o "$DOWNLOAD_DIR/$tar_file" "$url" && return 0
        fi
        print_warn "curl 下载失败"
    else
        print_error "无可用下载工具 (aria2c, axel, curl, wget)"
        return 1
    fi
    
    # 验证文件完整性
    if ! verify_archive "$GZ_FILE_PATH"; then
        print_error "下载的文件验证失败，可能是不完整的文件"
        rm -f "$GZ_FILE_PATH"
        return 1
    fi
    print_info "Seata 下载成功: $GZ_FILE_PATH"
    return 0
}

# 解压并安装 Seata
install_seata() {
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$FORCE_INSTALL" == true ]]; then
            print_info "强制安装模式：安装目录 $INSTALL_DIR 已存在，将被覆盖"
        else
            read -p "安装目录 $INSTALL_DIR 已存在,是否继续安装？[Y/n] " -n 1 -r REPLY
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
                print_info "安装已取消"
                exit 0
            fi
        fi
    else
    	exec mkdir -p "$INSTALL_DIR"
    fi
    
    print_info "安装 Seata 到: $INSTALL_DIR"
    # 解压下载的归档文件
    # 首先解压到临时目录以检查目录结构
    TEMP_DIR=$(mktemp -d)
    
    if ! tar -xzf "$GZ_FILE_PATH" -C "$TEMP_DIR"; then
        print_error "解压失败，重新下载安装包"
        exit 1
    fi
    
    # 检查解压后的目录结构
    EXTRACTED_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    
    if [ -z "$EXTRACTED_DIR" ]; then
        print_error "解压后没有找到有效目录"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 检查解压目录中的内容是否是一个单独的目录（通常是seata-server-版本号格式）
    INNER_DIR=$(find "$EXTRACTED_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    
    if [ -n "$INNER_DIR" ] && [ "$(find "$EXTRACTED_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]; then
        # 如果解压后只包含一个目录，将其内容直接移动到安装目录
        mv "$INNER_DIR"/* "$INSTALL_DIR"/ 2>/dev/null || {
            # 如果移动失败，可能是由于目录为空或权限问题，复制整个目录
            cp -r "$INNER_DIR" "$INSTALL_DIR"
        }
    else
        # 如果解压后包含多个文件/目录，直接移动解压目录的内容
        mv "$EXTRACTED_DIR"/* "$INSTALL_DIR"/
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    # 获取项目根目录（相对于安装脚本）
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    print_info "复制文件..."
    exec rsync -av "$SCRIPT_DIR/" "$INSTALL_DIR/"
    # 设置适当的权限
    exec chown -R "$CURRENT_USER:$(id -gn)" "$INSTALL_DIR"
    exec chmod +x "$INSTALL_DIR/"*.sh
}

# 为自动启动创建系统服务
create_service() {
    local INSTALL_DIR="$1"
    
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
        
        # Create the service file using exec
        cat > /tmp/seata.service << EOF
[Unit]
Description=Seata Server
After=network.target

[Service]
Type=forking
User=$CURRENT_USER
ExecStart=$START_SCRIPT_PATH
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF
        exec cp /tmp/seata.service "$SERVICE_FILE"
        exec rm -f /tmp/seata.service
        
        exec systemctl daemon-reload
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
        
        # Create the plist file using exec
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
    <string>$INSTALL_DIR</string>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/logs/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/logs/stderr.log</string>
</dict>
</plist>
EOF
        exec cp /tmp/io.seata.server.plist "$LAUNCHD_FILE"
        exec rm -f /tmp/io.seata.server.plist
        
        print_info "Seata 服务已创建。加载命令: sudo launchctl load $LAUNCHD_FILE"
        print_info "启动命令: sudo launchctl start io.seata.server"
    fi
}

# 卸载 Seata
uninstall_seata() {
    print_info "卸载 Seata服务..."
    
    # 停止系统服务（如果存在）
    if [[ "$OS" == "Linux" ]]; then
        if systemctl is-enabled --quiet seata; then
            print_info "正在禁用 Seata 服务..."
            exec systemctl disable seata
        fi
        
        # 移除服务文件
        if [[ -f "/etc/systemd/system/seata.service" ]]; then
            print_info "正在移除 Seata 服务文件..."
            exec rm -f /etc/systemd/system/seata.service
            exec systemctl daemon-reload
        fi
    elif [[ "$OS" == "macOS" ]]; then
        # 移除服务文件
        if [[ -f "/Library/LaunchDaemons/io.seata.server.plist" ]]; then
            print_info "正在移除 Seata 服务文件..."
            exec rm -f /Library/LaunchDaemons/io.seata.server.plist
        fi
    fi
    
    # 停止Seata服务
    if [[ -f "$STOP_SCRIPT_PATH" ]]; then
        print_info "使用自定义停止脚本停止 Seata 服务..."
        exec "$STOP_SCRIPT_PATH" -f
    fi
    
    # 移除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        exec rm -rf "$INSTALL_DIR"
        print_info "Seata 卸载成功"
    else
        print_warn "安装目录不存在: $INSTALL_DIR"
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
        -x|--debug)
            DEBUG_MODE=true
            # 在调试模式下禁用set -e
            set +e
            print_info "调试模式已启用，禁用set -e选项"
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

# 主执行函数
main() {
    detect_os
    check_sudo
    
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_seata 
        exit 0
    fi
    
    for url in "${DOWNLOAD_URLS[@]}"; do
        # 下载指定版本
        local download_url="${url//DEFAULT_VERSION/$VERSION}"
        download_url="${download_url//${DEFAULT_VERSION}/$VERSION}"
        if download_seata "$download_url"; then
            break
        fi
    done
    
    if [[ -z "$GZ_FILE_PATH" || ! -f "$GZ_FILE_PATH" ]]; then
        print_error "下载文件不存在: $GZ_FILE_PATH"
        exit 1
    fi
    
    install_seata
    
    # 如有请求则创建服务
    if [[ "$INSTALL_SERVICE" == true ]]; then
        create_service "$INSTALL_DIR"
    fi
    START_SCRIPT_PATH="$INSTALL_DIR/$START_SCRIPT_PATH"
    STOP_SCRIPT_PATH="$INSTALL_DIR/$STOP_SCRIPT_PATH"
    print_info "Seata 安装到: $INSTALL_DIR"
    print_info "使用以下命令管理 Seata 服务:"
    print_info "  启动服务: $START_SCRIPT_PATH"
    print_info "  停止服务: $STOP_SCRIPT_PATH"
    print_info "  查看状态: $START_SCRIPT_PATH -s"
    
    # 自动启动服务
    print_info "正在自动启动 Seata 服务..."
    
    if [[ -f "$START_SCRIPT_PATH" ]]; then
        exec "$START_SCRIPT_PATH"
    else
        print_info "请手动启动服务: $(find  $INSTALL_DIR -name $SEATA_SERVER_SH)"
    fi
    
    # 检查并启动 seata-namingserver（如果存在）
    NAMING_SERVER_SCRIPT="$INSTALL_DIR/seata-namingserver/bin/seata-namingserver.sh"
    if [[ -f "$NAMING_SERVER_SCRIPT" ]]; then
        print_info "检测到 seata-namingserver，正在启动命名服务..."
        if [[ -x "$NAMING_SERVER_SCRIPT" ]]; then
            exec "$NAMING_SERVER_SCRIPT"
            print_info "seata-namingserver 已启动"
        else
            print_warn "seata-namingserver 启动脚本无执行权限，正在设置权限..."
            exec chmod +x "$NAMING_SERVER_SCRIPT"
            exec "$NAMING_SERVER_SCRIPT"
            print_info "seata-namingserver 已启动"
        fi
    else
        print_warn "seata-namingserver 启动脚本未找到，跳过启动"
    fi
}

# 运行主函数
if [[ "$DEBUG_MODE" == true ]]; then
    set +e  # 调试模式下保持禁用
    main "$@"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_warn "脚本在调试模式下完成，退出码: $exit_code"
    fi
    exit $exit_code
else
    set -e  # 非调试模式下启用
    main "$@"
fi
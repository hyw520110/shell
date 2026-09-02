#!/bin/bash
# Caddy 自动安装、配置脚本
# Caddy是一款现代化、自动化的Web服务器，默认启用HTTPS

set -euo pipefail
IFS=$'\n\t'

# 脚本调试模式
DEBUG=${DEBUG:-false}
if [ "$DEBUG" = true ]; then
    set -x
fi

# 常量定义
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEFAULT_CADDY_HOME="$HOME/caddy"
readonly DEFAULT_USER="caddy"
readonly DEFAULT_URL="https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.tar.gz"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 默认值
caddy_home=$DEFAULT_CADDY_HOME
usr=$DEFAULT_USER
group=$usr
url=$DEFAULT_URL
download_dir=$DEFAULT_DOWNLOAD_DIR
user_mode=false

# 全局变量定义
PKG_INSTALLER=""
PKG_UPDATE=""

show_help(){
    cat << EOF
Caddy 一键安装、配置脚本

用法: $0 [选项]

选项:
    --dir DIR            指定安装目录，默认: $DEFAULT_CADDY_HOME
    --user USER          指定运行用户，默认: $DEFAULT_USER
    --url URL            指定Caddy下载URL
    --download-dir DIR   指定下载目录，默认: $DEFAULT_DOWNLOAD_DIR
    --user-mode          启用用户模式，不使用系统级安装 (无需sudo)
    --help, -h           显示此帮助信息

功能特性:
    - 自动下载并安装Caddy
    - 默认启用HTTPS，自动获取和更新SSL证书
    - 现代化配置文件格式
    - 自动HTTP/2支持
    - 丰富的插件支持
    - 实时配置重载

示例:
    $0                              # 使用默认设置安装
    $0 --dir /opt/caddy            # 指定安装目录
    $0 --user caddy                # 指定运行用户
    $0 --user-mode                 # 用户模式安装（无需sudo）

更多信息: https://caddyserver.com/
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            caddy_home="$2"
            shift 2
            ;;
        --user)
            usr="$2"
            group="$2"
            shift 2
            ;;
        --url)
            url="$2"
            shift 2
            ;;
        --download-dir)
            download_dir="$2"
            shift 2
            ;;
        --user-mode)
            user_mode=true
            shift 1
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            echo "使用 --help 查看帮助信息"
            exit 1
            ;;
    esac
done

# Caddy压缩文件名
gz_file_name=${url##*/}
tmp_dir="$download_dir/${gz_file_name%.tar*}"
gz_file="$download_dir/$gz_file_name"

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    log "ERROR: $*"
    exit 1
}

debug() {
    if [[ ${DEBUG:-false} == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
    fi
}

# 清理函数
cleanup() {
    local exit_code=$?
    if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
        rm -rf "$tmp_dir" 2>/dev/null || true
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# 日志文件
LOG_FILE="/tmp/caddy_install_$(date +%Y%m%d_%H%M%S).log"

# 检测操作系统类型和包管理器
detect_os() {
    if [ "$(uname)" = "Darwin" ]; then
        PKG_INSTALLER="brew install"
        PKG_UPDATE="brew update"
        OS_TYPE="macos"
        return
    fi
    OS_TYPE="linux"
    local pkg_managers="apt-get dnf yum zypper apk"
    for pm in $pkg_managers; do
        if command -v "$pm" > /dev/null 2>&1; then
            PKG_INSTALLER="$pm install -y"
            PKG_UPDATE="$pm update"
            break
        fi
    done
    debug "OS type: $OS_TYPE, Package installer: $PKG_INSTALLER"
}

# 检查目录是否具有写权限
has_write_permission() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        local parent_dir=$(dirname "$dir")
        if [ -w "$parent_dir" ] && [ -x "$parent_dir" ]; then
            return 0
        else
            return 1
        fi
    else
        [ -w "$dir" ]
        return $?
    fi
}

# 检查是否有sudo权限
has_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        sudo -n true 2>/dev/null
        return $?
    else
        return 1
    fi
}

# 获取sudo权限
ensure_sudo() {
    if ! has_sudo; then
        echo "需要管理员权限来执行此操作..."
        echo "请输入密码以继续:"
        if ! sudo -v; then
            echo "无法获取sudo权限，退出..."
            exit 1
        fi
    fi
}

# 智能执行命令
smart_exec() {
    local cmd="$1"
    local target_dir="$2"
    local force_sudo="${3:-false}"
    
    if [ "$user_mode" = "true" ]; then
        debug "用户模式: 不使用sudo，执行: $cmd"
        sh -c "$cmd"
        return $?
    fi
    
    if [ "$force_sudo" = "true" ] || ! has_write_permission "$target_dir"; then
        debug "对 $target_dir 需要sudo权限，执行: sudo $cmd"
        ensure_sudo
        sudo sh -c "$cmd"
        return $?
    else
        debug "对 $target_dir 有权限，执行: $cmd"
        sh -c "$cmd"
        return $?
    fi
}

# 智能目录创建
create_dir_with_permission() {
    local dir_path
    for dir_path in "$@"; do
        if [ ! -d "$dir_path" ]; then
            echo "创建目录: $dir_path"
            local parent_dir=$(dirname "$dir_path")
            if smart_exec "mkdir -p '$dir_path'" "$parent_dir"; then
                echo "✓ 成功创建目录: $dir_path"
            else
                echo "✗ 无法创建目录 $dir_path"
                return 1
            fi
        fi
    done
}

# 安装依赖
install_dependencies() {
    local packages="$1"
    local package_name="$2"

    if [ "$user_mode" = "true" ]; then
        echo "用户模式: 跳过系统级依赖安装"
        echo "请确保已安装以下依赖: wget等"
        return 0
    fi

    if [ -n "$PKG_INSTALLER" ]; then
        echo "安装 $package_name..."
        
        if [ "$OS_TYPE" != "macos" ] && [ -n "$PKG_UPDATE" ]; then
            echo "更新包管理器缓存..."
            smart_exec "$PKG_UPDATE" "/var/lib/apt" true
        fi

        smart_exec "$PKG_INSTALLER $packages" "/usr/local" true || {
            echo "✗ 安装 $package_name 失败"
            return 1
        }
        echo "✓ 成功安装 $package_name"
    else
        echo "警告: 未找到支持的包管理器，跳过依赖安装"
        echo "请手动安装依赖: wget等"
    fi
}

# 下载Caddy
download_caddy() {
    mkdir -p "$download_dir"
    
    if [ ! -f "$gz_file" ]; then
        log "正在下载: $url"
        if ! wget --timeout=30 --tries=3 "$url" -O "$gz_file"; then
            error "下载失败，请检查网络连接或URL: $url"
        fi
    else
        log "Caddy压缩包已存在: $gz_file"
    fi
    
    log "正在解压: $gz_file"
    if ! tar -zxf "$gz_file" -C "$download_dir"; then
        error "解压失败，请检查压缩包完整性: $gz_file"
    fi
    log "解压完成"
}

# 安装Caddy
install_caddy() {
    download_caddy
    
    if [ ! -d "$tmp_dir" ]; then
        echo "✗ 解压目录不存在: $tmp_dir"
        exit 1
    fi
    
    cd "$tmp_dir" || exit 1
    
    # 创建安装目录
    create_dir_with_permission "$caddy_home" "$caddy_home/bin" "$caddy_home/conf" "$caddy_home/logs" "$caddy_home/www"
    
    # 复制Caddy可执行文件
    log "正在安装Caddy..."
    if [ -f "caddy" ]; then
        cp caddy "$caddy_home/bin/caddy"
        chmod +x "$caddy_home/bin/caddy"
        echo "✓ Caddy: 安装成功"
    else
        error "Caddy可执行文件不存在"
    fi
    
    cd /tmp
    rm -rf "$tmp_dir"
}

# 启动Caddy
start_caddy() {
    # 创建软链接
    local bin_dir="$HOME/bin"
    if [ ! -d "$bin_dir" ]; then
        mkdir -p "$bin_dir"
    fi
    
    ln -sf "$caddy_home/bin/caddy" "$bin_dir/caddy" 2>/dev/null || {
        echo "警告: 无法创建软链接到$bin_dir/caddy"
    }
    
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        echo "提示: 如需全局访问caddy，请将 $bin_dir 添加到PATH环境变量"
        echo "临时运行: export PATH=\"$bin_dir:\$PATH\""
    fi
    
    # 检查配置文件
    if [ ! -f "$caddy_home/conf/Caddyfile" ]; then
        log "创建默认配置文件..."
        cat > "$caddy_home/conf/Caddyfile" << 'EOF'
{
    # 全局配置
    auto_https off
    http_port 8080
    https_port 8443
}

:8080 {
    # 静态文件服务
    root * /home/caddy/www
    file_server

    # 日志
    log {
        output file /home/caddy/logs/access.log
    }

    # 健康检查端点
    handle /health {
        respond "OK" 200
    }
}
EOF
        log "✓ 默认配置文件创建成功"
    fi
    
    # 测试配置
    log "测试Caddy配置文件..."
    if ! "$caddy_home/bin/caddy" validate --config "$caddy_home/conf/Caddyfile"; then
        error "Caddy配置测试失败，请检查配置文件"
    fi
    
    log "✓ Caddy配置测试通过"
    
    # 启动Caddy
    log "正在启动Caddy..."
    "$caddy_home/bin/caddy" run --config "$caddy_home/conf/Caddyfile" > "$caddy_home/logs/caddy.log" 2>&1 &
    caddy_pid=$!
    
    log "✓ Caddy启动成功"
    
    # 等待进程启动
    sleep 2
    
    # 显示进程信息
    caddy_ps=$(ps -ef | grep "caddy.*run" | grep -v grep)
    if [ -n "$caddy_ps" ]; then
        log "Caddy进程信息："
        echo "$caddy_ps"
    fi
    
    echo ""
    echo "=========================================="
    echo "Caddy 安装完成！"
    echo "=========================================="
    echo "安装目录: $caddy_home"
    echo "配置文件: $caddy_home/conf/Caddyfile"
    echo "日志目录: $caddy_home/logs"
    echo "网站目录: $caddy_home/www"
    echo ""
    echo "常用命令："
    echo "  启动: $caddy_home/bin/caddy run --config $caddy_home/conf/Caddyfile"
    echo "  测试: $caddy_home/bin/caddy validate --config $caddy_home/conf/Caddyfile"
    echo "  版本: $caddy_home/bin/caddy version"
    echo ""
    echo "访问地址: http://localhost:8080"
    echo "健康检查: http://localhost:8080/health"
    echo "=========================================="
}

# 主程序
main() {
    echo "=========================================="
    echo "Caddy 一键安装、配置脚本"
    echo "=========================================="
    echo ""
    
    # 检测操作系统
    detect_os
    
    # 检查是否已安装
    if [ -f "$caddy_home/bin/caddy" ]; then
        echo "Caddy 已安装在: $caddy_home"
        echo "版本信息:"
        "$caddy_home/bin/caddy" version
        echo ""
        read -p "是否重新配置Caddy? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            start_caddy
        fi
        exit 0
    fi
    
    # 安装依赖
    if [ "$OS_TYPE" = "macos" ]; then
        install_dependencies "wget" "macOS依赖"
    else
        install_dependencies "wget" "Linux依赖"
    fi
    
    # 安装Caddy
    install_caddy
    
    # 启动Caddy
    start_caddy
}

# 执行主程序
main

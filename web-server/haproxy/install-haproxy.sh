#!/bin/bash
# HAProxy 自动安装、配置脚本
# HAProxy是一款高性能的负载均衡器，支持TCP和HTTP应用

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
readonly DEFAULT_HAPROXY_HOME="$HOME/haproxy"
readonly DEFAULT_USER="haproxy"
readonly DEFAULT_URL="https://www.haproxy.org/download/3.0/src/haproxy-3.0.2.tar.gz"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 默认值
haproxy_home=$DEFAULT_HAPROXY_HOME
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
HAProxy 一键安装、配置脚本

用法: $0 [选项]

选项:
    --dir DIR            指定安装目录，默认: $DEFAULT_HAPROXY_HOME
    --user USER          指定运行用户，默认: $DEFAULT_USER
    --url URL            指定HAProxy源码下载URL
    --download-dir DIR   指定下载目录，默认: $DEFAULT_DOWNLOAD_DIR
    --user-mode          启用用户模式，不使用系统级安装 (无需sudo)
    --help, -h           显示此帮助信息

功能特性:
    - 自动下载并编译安装HAProxy
    - 支持TCP和HTTP负载均衡
    - 支持SSL/TLS
    - 支持健康检查
    - 支持会话保持
    - 支持多种负载均衡算法
    - 支持实时监控页面

示例:
    $0                              # 使用默认设置安装
    $0 --dir /opt/haproxy          # 指定安装目录
    $0 --user haproxy              # 指定运行用户
    $0 --user-mode                 # 用户模式安装（无需sudo）

更多信息: https://www.haproxy.org/
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            haproxy_home="$2"
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

# HAProxy压缩文件名
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
LOG_FILE="/tmp/haproxy_install_$(date +%Y%m%d_%H%M%S).log"

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
        echo "请确保已安装以下依赖: PCRE库、OpenSSL开发库、zlib开发库等"
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
        echo "请手动安装依赖: PCRE库、OpenSSL开发库、zlib开发库等"
    fi
}

# 验证依赖
validate_dependencies() {
    log "验证必需的依赖库..."
    
    local missing_deps=()
    
    # 检查PCRE库
    if ! command -v pcre-config > /dev/null 2>&1 && [ ! -f "/usr/include/pcre.h" ] && [ ! -f "/usr/include/pcre/pcre.h" ]; then
        missing_deps+=("PCRE库")
    fi
    
    # 检查OpenSSL
    if [ ! -f "/usr/include/openssl/ssl.h" ] && [ ! -f "/usr/local/include/openssl/ssl.h" ]; then
        missing_deps+=("OpenSSL开发库")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "缺少以下依赖库:"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        error "请先安装缺少的依赖库"
    fi
    
    log "✓ 所有依赖库检查通过"
}

# 下载HAProxy
download_haproxy() {
    mkdir -p "$download_dir"
    
    if [ ! -f "$gz_file" ]; then
        log "正在下载: $url"
        if ! wget --timeout=30 --tries=3 "$url" -O "$gz_file"; then
            error "下载失败，请检查网络连接或URL: $url"
        fi
    else
        log "HAProxy压缩包已存在: $gz_file"
    fi
    
    log "正在解压: $gz_file"
    if ! tar -zxf "$gz_file" -C "$download_dir"; then
        error "解压失败，请检查压缩包完整性: $gz_file"
    fi
    log "解压完成"
}

# 安装HAProxy
install_haproxy() {
    download_haproxy
    
    if [ ! -d "$tmp_dir" ]; then
        echo "✗ 源码目录不存在: $tmp_dir"
        exit 1
    fi
    
    cd "$tmp_dir" || exit 1
    
    log "正在配置HAProxy编译选项..."
    
    # 配置编译参数
    local make_cmd="make TARGET=linux-glibc USE_PCRE=1 USE_OPENSSL=1 USE_ZLIB=1 USE_SYSTEMD=1 USE_LUA=1 LUA_INC=$HOME/luajit/include/luajit-2.1 LUA_LIB=$HOME/luajit/lib PREFIX=$haproxy_home"
    
    if ! eval "$make_cmd"; then
        echo "✗ HAProxy: 编译失败"
        echo "请检查错误信息并确保已安装必需的依赖库"
        exit 1
    fi
    
    echo "✓ HAProxy: 编译成功"
    
    # 安装
    log "正在安装HAProxy..."
    if ! make install PREFIX=$haproxy_home; then
        echo "✗ HAProxy: 安装失败"
        make clean
        exit 1
    fi
    
    echo "✓ HAProxy: 安装成功"
    
    cd /tmp
    rm -rf "$tmp_dir"
}

# 启动HAProxy
start_haproxy() {
    # 创建必要目录
    create_dir_with_permission "$haproxy_home" "$haproxy_home/conf"
    
    # 创建软链接
    local bin_dir="$HOME/bin"
    if [ ! -d "$bin_dir" ]; then
        mkdir -p "$bin_dir"
    fi
    
    ln -sf "$haproxy_home/sbin/haproxy" "$bin_dir/haproxy" 2>/dev/null || {
        echo "警告: 无法创建软链接到$bin_dir/haproxy"
    }
    
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        echo "提示: 如需全局访问haproxy，请将 $bin_dir 添加到PATH环境变量"
        echo "临时运行: export PATH=\"$bin_dir:\$PATH\""
    fi
    
    # 检查配置文件
    if [ ! -f "$haproxy_home/conf/haproxy.cfg" ]; then
        log "创建默认配置文件..."
        cat > "$haproxy_home/conf/haproxy.cfg" << 'EOF'
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon

    stats socket /var/lib/haproxy/stats

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:admin

frontend main
    bind *:80
    default             app

backend app
    balance     roundrobin
    server      app1 127.0.0.1:8081 check
    server      app2 127.0.0.1:8082 check
EOF
        log "✓ 默认配置文件创建成功"
    fi
    
    # 测试配置
    log "测试HAProxy配置文件..."
    if ! "$haproxy_home/sbin/haproxy" -c -f "$haproxy_home/conf/haproxy.cfg"; then
        error "HAProxy配置测试失败，请检查配置文件"
    fi
    
    log "✓ HAProxy配置测试通过"
    
    # 启动HAProxy
    log "正在启动HAProxy..."
    if ! "$haproxy_home/sbin/haproxy" -f "$haproxy_home/conf/haproxy.cfg"; then
        error "HAProxy启动失败，请检查错误日志"
    fi
    
    log "✓ HAProxy启动成功"
    
    # 等待进程启动
    sleep 1
    
    # 显示进程信息
    haproxy_ps=$(ps -ef | grep "haproxy.*-f $haproxy_home" | grep -v grep)
    if [ -n "$haproxy_ps" ]; then
        log "HAProxy进程信息："
        echo "$haproxy_ps"
    fi
    
    echo ""
    echo "=========================================="
    echo "HAProxy 安装完成！"
    echo "=========================================="
    echo "安装目录: $haproxy_home"
    echo "配置文件: $haproxy_home/conf/haproxy.cfg"
    echo ""
    echo "常用命令："
    echo "  启动: $haproxy_home/sbin/haproxy -f $haproxy_home/conf/haproxy.cfg"
    echo "  停止: $haproxy_home/sbin/haproxy -f $haproxy_home/conf/haproxy.cfg -sf \$(cat /var/run/haproxy.pid)"
    echo "  测试: $haproxy_home/sbin/haproxy -c -f $haproxy_home/conf/haproxy.cfg"
    echo "  版本: $haproxy_home/sbin/haproxy -v"
    echo ""
    echo "访问地址: http://localhost:80"
    echo "监控地址: http://localhost:8404/stats (admin/admin)"
    echo "=========================================="
}

# 主程序
main() {
    echo "=========================================="
    echo "HAProxy 一键安装、配置脚本"
    echo "=========================================="
    echo ""
    
    # 检测操作系统
    detect_os
    
    # 检查是否已安装
    if [ -f "$haproxy_home/sbin/haproxy" ]; then
        echo "HAProxy 已安装在: $haproxy_home"
        echo "版本信息:"
        "$haproxy_home/sbin/haproxy" -v
        echo ""
        read -p "是否重新配置HAProxy? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            start_haproxy
        fi
        exit 0
    fi
    
    # 安装依赖
    if [ "$OS_TYPE" = "macos" ]; then
        install_dependencies "wget pcre openssl" "macOS依赖"
    else
        install_dependencies "wget build-essential libpcre3-dev libssl-dev zlib1g-dev" "Linux编译依赖"
    fi
    
    # 验证依赖
    validate_dependencies
    
    # 安装HAProxy
    install_haproxy
    
    # 启动HAProxy
    start_haproxy
}

# 执行主程序
main
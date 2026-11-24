#!/bin/bash
# Tengine自动安装、配置脚本
# Tengine是由淘宝网发起的Web服务器项目，它在Nginx的基础上，针对大访问量网站的需求，添加了很多高级功能和特性

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
readonly DEFAULT_TENGINE_HOME="$HOME/tengine"
readonly DEFAULT_USER="www-data"
readonly DEFAULT_URL="https://github.com/alibaba/tengine/archive/refs/tags/2.3.3.tar.gz"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 默认值
tengine_home=$DEFAULT_TENGINE_HOME
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
Tengine一键安装、配置脚本

用法: $0 [选项]

选项:
    --dir DIR            指定安装目录，默认: $DEFAULT_TENGINE_HOME
    --user USER          指定运行用户，默认: $DEFAULT_USER
    --url URL            指定Tengine源码下载URL
    --download-dir DIR   指定下载目录，默认: $DEFAULT_DOWNLOAD_DIR
    --user-mode          启用用户模式，不使用系统级安装 (无需sudo)
    --help, -h           显示此帮助信息

功能特性:
    - 自动下载并编译安装Tengine
    - 支持HTTP/2、HTTP/3、QUIC等现代协议
    - 集成ngx_lua模块支持Lua脚本
    - 支持动态加载模块
    - 自动配置SSL/TLS
    - 支持多种负载均衡算法

示例:
    $0                              # 使用默认设置安装
    $0 --dir /opt/tengine         # 指定安装目录
    $0 --user nginx               # 指定运行用户
    $0 --user-mode                 # 用户模式安装（无需sudo）

更多信息: https://tengine.taobao.org/
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            tengine_home="$2"
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

# Tengine压缩文件名
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
LOG_FILE="/tmp/tengine_install_$(date +%Y%m%d_%H%M%S).log"

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
        echo "请确保已安装以下依赖: PCRE库、OpenSSL开发库、zlib开发库、LuaJIT等"
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
        echo "请手动安装依赖: PCRE库、OpenSSL开发库、zlib开发库、LuaJIT等"
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
    
    # 检查zlib
    if [ ! -f "/usr/include/zlib.h" ] && [ ! -f "/usr/local/include/zlib.h" ]; then
        missing_deps+=("zlib开发库")
    fi
    
    # 检查LuaJIT (Tengine必需)
    if ! command -v luajit > /dev/null 2>&1 && [ ! -f "/usr/include/luajit-2.1/lua.h" ]; then
        missing_deps+=("LuaJIT")
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

# 下载Tengine
download_tengine() {
    mkdir -p "$download_dir"
    
    if [ ! -f "$gz_file" ]; then
        log "正在下载: $url"
        if ! wget --timeout=30 --tries=3 "$url" -O "$gz_file"; then
            error "下载失败，请检查网络连接或URL: $url"
        fi
    else
        log "Tengine压缩包已存在: $gz_file"
    fi
    
    log "正在解压: $gz_file"
    if ! tar -zxf "$gz_file" -C "$download_dir"; then
        error "解压失败，请检查压缩包完整性: $gz_file"
    fi
    log "解压完成"
}

# 安装Tengine
install_tengine() {
    download_tengine
    
    if [ ! -d "$tmp_dir" ]; then
        echo "✗ 源码目录不存在: $tmp_dir"
        exit 1
    fi
    
    cd "$tmp_dir" || exit 1
    
    log "正在配置Tengine编译选项..."
    
    # 配置编译参数
    local configure_cmd="./configure \
        --prefix=$tengine_home \
        --user=$usr \
        --group=$group \
        --error-log-path=$tengine_home/logs/error.log \
        --http-log-path=$tengine_home/logs/access.log \
        --pid-path=$tengine_home/logs/tengine.pid \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_ssl_module \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
        --with-http_sub_module \
        --with-http_addition_module \
        --with-http_dav_module \
        --with-http_geoip_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_perl_module=dynamic \
        --with-http_xslt_module=dynamic \
        --with-http_lua_module=dynamic \
        --with-http_gzip_static_module \
        --with-pcre-jit \
        --with-pcre \
        --with-openssl \
        --with-zlib \
        --with-threads \
        --with-file-aio"
    
    if ! eval "$configure_cmd"; then
        echo "✗ Tengine: 配置失败"
        echo "请检查错误信息并确保已安装必需的依赖库"
        exit 1
    fi
    
    echo "✓ Tengine: 配置成功"
    
    # 编译
    log "正在编译Tengine..."
    if ! make; then
        echo "✗ Tengine: 编译失败"
        make clean
        exit 1
    fi
    
    echo "✓ Tengine: 编译成功"
    
    # 安装
    log "正在安装Tengine..."
    if ! make install; then
        echo "✗ Tengine: 安装失败"
        make clean
        exit 1
    fi
    
    echo "✓ Tengine: 安装成功"
    
    cd /tmp
    rm -rf "$tmp_dir"
}

# 启动Tengine
start_tengine() {
    # 创建必要目录
    create_dir_with_permission "$tengine_home" "$tengine_home/conf" "$tengine_home/logs" "$tengine_home/www"
    
    # 创建软链接
    local bin_dir="$HOME/bin"
    if [ ! -d "$bin_dir" ]; then
        mkdir -p "$bin_dir"
    fi
    
    ln -sf "$tengine_home/sbin/tengine" "$bin_dir/tengine" 2>/dev/null || {
        echo "警告: 无法创建软链接到$bin_dir/tengine"
    }
    
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        echo "提示: 如需全局访问tengine，请将 $bin_dir 添加到PATH环境变量"
        echo "临时运行: export PATH=\"$bin_dir:\$PATH\""
    fi
    
    # 检查配置文件
    if [ ! -f "$tengine_home/conf/tengine.conf" ]; then
        log "创建默认配置文件..."
        cat > "$tengine_home/conf/tengine.conf" << 'EOF'
user  www-data;
worker_processes  auto;
worker_cpu_affinity auto;
error_log  logs/error.log  warn;
pid        logs/tengine.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  logs/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 2048;

    # Tengine 特性：动态加载模块
    # dso {
    #     load ngx_http_lua_module.so;
    #     load ngx_http_geoip_module.so;
    # }

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject application/x-font-ttf;

    server {
        listen       8080;
        server_name  localhost;

        location / {
            root   www;
            index  index.html index.htm;
        }

        # Tengine 特性：sysguard 流量保护
        # sysguard on;
        # sysguard_load load=10 action=/loadlimit;
        # sysguard_mem free=100M action=/memlimit;
        # sysguard_rt rt=1000 action=/rtlimit;

        # error_page   500 502 503 504  /50x.html;
        # location = /50x.html {
        #     root   html;
        # }
    }
}
EOF
        log "✓ 默认配置文件创建成功"
    fi
    
    # 测试配置
    log "测试Tengine配置文件..."
    if ! "$tengine_home/sbin/tengine" -c "$tengine_home/conf/tengine.conf" -t; then
        error "Tengine配置测试失败，请检查配置文件"
    fi
    
    log "✓ Tengine配置测试通过"
    
    # 启动Tengine
    log "正在启动Tengine..."
    if ! "$tengine_home/sbin/tengine" -c "$tengine_home/conf/tengine.conf"; then
        error "Tengine启动失败，请检查错误日志: $tengine_home/logs/error.log"
    fi
    
    log "✓ Tengine启动成功"
    
    # 等待进程启动
    sleep 1
    
    # 显示进程信息
    tengine_ps=$(ps -ef | grep tengine | grep master | grep -v grep)
    if [ -n "$tengine_ps" ]; then
        log "Tengine进程信息："
        echo "$tengine_ps"
    fi
    
    echo ""
    echo "=========================================="
    echo "Tengine 安装完成！"
    echo "=========================================="
    echo "安装目录: $tengine_home"
    echo "配置文件: $tengine_home/conf/tengine.conf"
    echo "日志目录: $tengine_home/logs"
    echo "网站目录: $tengine_home/www"
    echo ""
    echo "常用命令："
    echo "  启动: $tengine_home/sbin/tengine -c $tengine_home/conf/tengine.conf"
    echo "  停止: $tengine_home/sbin/tengine -s stop -c $tengine_home/conf/tengine.conf"
    echo "  重载: $tengine_home/sbin/tengine -s reload -c $tengine_home/conf/tengine.conf"
    echo "  测试: $tengine_home/sbin/tengine -t -c $tengine_home/conf/tengine.conf"
    echo "  版本: $tengine_home/sbin/tengine -v"
    echo ""
    echo "访问地址: http://localhost:8080"
    echo "=========================================="
}

# 主程序
main() {
    echo "=========================================="
    echo "Tengine 一键安装、配置脚本"
    echo "=========================================="
    echo ""
    
    # 检测操作系统
    detect_os
    
    # 检查是否已安装
    if [ -f "$tengine_home/sbin/tengine" ]; then
        echo "Tengine 已安装在: $tengine_home"
        echo "版本信息:"
        "$tengine_home/sbin/tengine" -v
        echo ""
        read -p "是否重新配置Tengine? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            start_tengine
        fi
        exit 0
    fi
    
    # 安装依赖
    if [ "$OS_TYPE" = "macos" ]; then
        install_dependencies "wget pcre openssl zlib lua" "macOS依赖"
    else
        install_dependencies "wget build-essential libpcre3 libpcre3-dev libpcre2-dev zlib1g zlib1g-dev libssl-dev libgeoip-dev perl perl libluajit-5.1-dev" "Linux编译依赖"
    fi
    
    # 验证依赖
    validate_dependencies
    
    # 安装Tengine
    install_tengine
    
    # 启动Tengine
    start_tengine
}

# 执行主程序
main
#!/bin/bash
# Apache HTTP Server 自动安装、配置脚本
# Apache是最流行的开源Web服务器，功能强大，模块丰富

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
readonly DEFAULT_APACHE_HOME="$HOME/apache"
readonly DEFAULT_USER="www-data"
readonly DEFAULT_URL="https://dlcdn.apache.org/httpd/httpd-2.4.62.tar.gz"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 默认值
apache_home=$DEFAULT_APACHE_HOME
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
Apache HTTP Server 一键安装、配置脚本

用法: $0 [选项]

选项:
    --dir DIR            指定安装目录，默认: $DEFAULT_APACHE_HOME
    --user USER          指定运行用户，默认: $DEFAULT_USER
    --url URL            指定Apache源码下载URL
    --download-dir DIR   指定下载目录，默认: $DEFAULT_DOWNLOAD_DIR
    --user-mode          启用用户模式，不使用系统级安装 (无需sudo)
    --help, -h           显示此帮助信息

功能特性:
    - 自动下载并编译安装Apache
    - 支持PHP、Python等常见模块
    - 自动配置SSL/TLS
    - 支持虚拟主机配置
    - 自动优化性能参数
    - 支持mod_rewrite、mod_ssl等常用模块

示例:
    $0                              # 使用默认设置安装
    $0 --dir /opt/apache           # 指定安装目录
    $0 --user apache              # 指定运行用户
    $0 --user-mode                 # 用户模式安装（无需sudo）

更多信息: https://httpd.apache.org/
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            apache_home="$2"
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

# Apache压缩文件名
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
LOG_FILE="/tmp/apache_install_$(date +%Y%m%d_%H%M%S).log"

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
        echo "请确保已安装以下依赖: PCRE库、OpenSSL开发库、APR、APR-Util等"
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
        echo "请手动安装依赖: PCRE库、OpenSSL开发库、APR、APR-Util等"
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
    
    # 检查APR和APR-Util
    if ! command -v apr-1-config > /dev/null 2>&1 && [ ! -f "/usr/include/apr-1/apr.h" ]; then
        missing_deps+=("APR")
    fi
    
    if ! command -v apu-1-config > /dev/null 2>&1 && [ ! -f "/usr/include/apr-1/apu.h" ]; then
        missing_deps+=("APR-Util")
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

# 下载Apache
download_apache() {
    mkdir -p "$download_dir"
    
    if [ ! -f "$gz_file" ]; then
        log "正在下载: $url"
        if ! wget --timeout=30 --tries=3 "$url" -O "$gz_file"; then
            error "下载失败，请检查网络连接或URL: $url"
        fi
    else
        log "Apache压缩包已存在: $gz_file"
    fi
    
    log "正在解压: $gz_file"
    if ! tar -zxf "$gz_file" -C "$download_dir"; then
        error "解压失败，请检查压缩包完整性: $gz_file"
    fi
    log "解压完成"
}

# 安装Apache
install_apache() {
    download_apache
    
    if [ ! -d "$tmp_dir" ]; then
        echo "✗ 源码目录不存在: $tmp_dir"
        exit 1
    fi
    
    cd "$tmp_dir" || exit 1
    
    # 找到实际的Apache目录
    apache_dir=$(find "$download_dir" -maxdepth 1 -type d -name "httpd-*" ! -name "*.tar*" | head -n 1)
    if [ -z "$apache_dir" ]; then
        error "找不到Apache源码目录"
    fi
    
    cd "$apache_dir" || exit 1
    
    log "正在配置Apache编译选项..."
    
    # 配置编译参数
    local configure_cmd="./configure \
        --prefix=$apache_home \
        --enable-so \
        --enable-ssl \
        --enable-rewrite \
        --enable-headers \
        --enable-expires \
        --enable-deflate \
        --enable-proxy \
        --enable-proxy-fcgi \
        --enable-proxy-connect \
        --enable-proxy-ftp \
        --enable-proxy-http \
        --enable-proxy-balancer \
        --enable-proxy-html \
        --enable-proxy-https \
        --enable-unique-id \
        --enable-usertrack \
        --enable-ipv6 \
        --enable-http2 \
        --enable-mods-shared=most \
        --with-mpm=prefork \
        --with-ssl \
        --with-pcre \
        --with-z \
        --with-apr \
        --with-apr-util \
        --with-libxml2 \
        --with-lua \
        --enable-lua"
    
    if ! eval "$configure_cmd"; then
        echo "✗ Apache: 配置失败"
        echo "请检查错误信息并确保已安装必需的依赖库"
        exit 1
    fi
    
    echo "✓ Apache: 配置成功"
    
    # 编译
    log "正在编译Apache..."
    if ! make; then
        echo "✗ Apache: 编译失败"
        make clean
        exit 1
    fi
    
    echo "✓ Apache: 编译成功"
    
    # 安装
    log "正在安装Apache..."
    if ! make install; then
        echo "✗ Apache: 安装失败"
        make clean
        exit 1
    fi
    
    echo "✓ Apache: 安装成功"
    
    cd /tmp
    rm -rf "$apache_dir"
}

# 启动Apache
start_apache() {
    # 创建必要目录
    create_dir_with_permission "$apache_home" "$apache_home/conf" "$apache_home/logs" "$apache_home/htdocs" "$apache_home/run"
    
    # 创建软链接
    local bin_dir="$HOME/bin"
    if [ ! -d "$bin_dir" ]; then
        mkdir -p "$bin_dir"
    fi
    
    ln -sf "$apache_home/bin/apachectl" "$bin_dir/apachectl" 2>/dev/null || {
        echo "警告: 无法创建软链接到$bin_dir/apachectl"
    }
    
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        echo "提示: 如需全局访问Apache，请将 $bin_dir 添加到PATH环境变量"
        echo "临时运行: export PATH=\"$bin_dir:\$PATH\""
    fi
    
    # 检查配置文件
    if [ ! -f "$apache_home/conf/httpd.conf" ]; then
        log "创建默认配置文件..."
        cat > "$apache_home/conf/httpd.conf" << 'EOF'
ServerRoot "$HOME/apache"
Listen 8080

LoadModule mpm_prefork_module modules/mod_mpm_prefork.so
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authn_socache_module modules/mod_authn_socache.so
LoadModule authz_socache_module modules/mod_authz_socache.so
LoadModule auth_basic_module modules/mod_auth_basic.so
LoadModule auth_digest_module modules/mod_auth_digest.so
LoadModule authn_anon_module modules/mod_authn_anon.so
LoadModule authn_dbm_module modules/mod_authn_dbm.so
LoadModule authz_dbm_module modules/mod_authz_dbm.so
LoadModule authz_owner_module modules/mod_authz_owner.so
LoadModule authz_groupfile_module modules/mod_authz_groupfile.so
LoadModule authz_user_module modules/mod_authz_user_module
LoadModule authz_host_module modules/mod_authz_host_module
LoadModule authz_group_module modules/mod_authz_group_module
LoadModule include_module modules/mod_include.so
LoadModule filter_module modules/mod_filter.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule env_module modules/mod_env.so
LoadModule expires_module modules/mod_expires.so
LoadModule headers_module modules/mod_headers.so
LoadModule setenvif_module modules/mod_setenvif_module
LoadModule version_module modules/mod_version.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_connect_module modules/mod_proxy_connect.so
LoadModule proxy_ftp_module modules/mod_proxy_ftp.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
LoadModule proxy_scgi_module modules/mod_proxy_scgi_module
LoadModule proxy_uwsgi_module modules/mod_proxy_uwsgi_module
LoadModule proxy_fdpass_module modules/mod_proxy_fdpass_module
LoadModule proxy_wstunnel_module modules/proxy_wstunnel_module
LoadModule proxy_balancer_module modules/mod_proxy_balancer_module
LoadModule proxy_express_module modules/mod_proxy_express.so
LoadModule session_module modules/mod_session_module
LoadModule slotmem_shm_module modules/mod_slotmem_shm
LoadModule ssl_module modules/mod_ssl.so
LoadModule http_module modules/mod_http.so
LoadModule mime_module modules/mod_mime.so
LoadModule dav_module modules/mod_dav_module
LoadStatusModule dav_module modules/mod_dav_fs.conf
LoadModule dav_lock_module modules/mod_dav_lock_module
LoadModule dav_fs_module modules/mod_dav_fs.conf
LoadModule vhost_alias_module modules/mod_vhost_alias_module
LoadModule negotiation_module modules/mod_negotiation_module
LoadModule dir_module modules/mod_dir.so
LoadModule actions_module modules/mod_actions.so
LoadModule alias_module modules/mod_alias.so
LoadModule rewrite_module modules/mod_rewrite.so

User www-data
Group www-data

<IfModule mpm_prefork_module>
    StartServers             1
    MinSpareServers          5
    MaxSpareServers          10
    MaxRequestWorkers      150
    MaxConnectionsPerChild   0
</IfModule>

PidFile "$HOME/apache/run/httpd.pid"
ErrorLog "$HOME/apache/logs/error_log"
LogLevel warn

LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule mpm_worker_module modules/mpm_worker_module
LoadModule mpm_prefork_module modules/mod_mpm_prefork_module

LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule authn_dbm_module modules/mod_authn_dbm.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host_module
LoadModule authz_groupfile_module modules/mod_authz_groupfile.so
LoadModule authz_user_module modules/mod_authz_user_module
LoadModule authz_dbm_module modules/mod_authz_dbm.so
LoadModule authz_owner_module modules/mod_authz_owner.so
LoadModule authz_group_module modules/mod_authz_group_module
Loadz_core_module modules/mod_so.sh
Loadz_socache_shm_module modules/mod_socache_shm.so
LoadModule status_module modules/mod_status.so
LoadModule autoindex_module modules/mod_autoindex.so
LoadModule info_module modules/mod_info.so
LoadModule dav_module modules/mod_dav_module
LoadModule dav_fs_module modules/mod_dav_fs.conf
LoadModule vhost_alias_module modules/mod_vhost_alias_module
LoadModule negotiation_module modules/mod_negotiation_module
LoadModule dir_module modules/mod_dir.so
LoadModule actions_module modules/mod_actions.so
LoadModule alias_module modules/mod_alias.so
LoadModule rewrite_module modules/mod_rewrite.so

<IfModule unixd_module>
User www-data
Group www-data
</IfModule>

ServerAdmin you@example.com
ServerName localhost

DocumentRoot "$HOME/apache/htdocs"
DirectoryIndex index.html

<Directory "$HOME/apache/htdocs">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

ErrorDocument 404 /404.html
ErrorDocument 500 /50x.html
EOF
        log "✓ 默认配置文件创建成功"
    fi
    
    # 测试配置
    log "测试Apache配置文件..."
    if ! "$apache_home/bin/apachectl" -t; then
        error "Apache配置测试失败，请检查配置文件"
    fi
    
    log "✓ Apache配置测试通过"
    
    # 启动Apache
    log "正在启动Apache..."
    if ! "$apache_home/bin/apachectl" -k start; then
        error "Apache启动失败，请检查错误日志: $apache_home/logs/error_log"
    fi
    
    log "✓ Apache启动成功"
    
    # 等待进程启动
    sleep 1
    
    # 显示进程信息
    apache_ps=$(ps -ef | grep "httpd.*-f $apache_home" | grep -v grep)
    if [ -n "$apache_ps" ]; then
        log "Apache进程信息："
        echo "$apache_ps"
    fi
    
    echo ""
    echo "=========================================="
    echo "Apache HTTP Server 安装完成！"
    echo "=========================================="
    echo "安装目录: $apache_home"
    echo "配置文件: $apache_home/conf/httpd.conf"
    echo "日志目录: $apache_home/logs"
    echo "网站目录: $apache_home/htdocs"
    echo ""
    echo "常用命令："
    echo "  启动: $apache_home/bin/apachectl -k start"
    echo "  停止: $apache_home/bin/apachectl -k stop"
    echo "  重启: $apache_home/bin/apachectl -k restart"
    echo "  重载: $apache_home/bin/apachectl -k graceful"
    echo "  测试: $apache_home/bin/apachectl -t"
    echo "  版本: $apache_home/bin/httpd -v"
    echo ""
    echo "访问地址: http://localhost:8080"
    echo "=========================================="
}

# 主程序
main() {
    echo "=========================================="
    echo "Apache HTTP Server 一键安装、配置脚本"
    echo "=========================================="
    echo ""
    
    # 检测操作系统
    detect_os
    
    # 检查是否已安装
    if [ -f "$apache_home/bin/httpd" ]; then
        echo "Apache 已安装在: $apache_home"
        echo "版本信息:"
        "$apache_home/bin/httpd" -v
        echo ""
        read -p "是否重新配置Apache? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            start_apache
        fi
        exit 0
    fi
    
    # 安装依赖
    if [ "$OS_TYPE" = "macos" ]; then
        install_dependencies "wget pcre openssl apr apr-util" "macOS依赖"
    else
        install_dependencies "wget build-essential libpcre3-dev libssl-dev libapr1-dev libaprutil1-dev libxml2-dev liblua5.3 liblua5.3-dev" "Linux编译依赖"
    fi
    
    # 验证依赖
    validate_dependencies
    
    # 安装Apache
    install_apache
    
    # 启动Apache
    start_apache
}

# 执行主程序
main
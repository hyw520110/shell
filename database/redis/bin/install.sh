#!/usr/bin/env bash
# Redis一键安装配置脚本
# 功能：自动下载、编译、安装、配置Redis缓存数据库
# 用法：./install.sh [INSTALL_DIR] [节点数] [端口] [REDIS_VERSION]

set -e

# 下载目录
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
DEFAULT_INSTALL_DIR="$HOME/redis"
INSTALL_SERVICE_ONLY=false
UNINSTALL_SERVICE_ONLY=false
REDIS_PASSWORD_MODE="${REDIS_PASSWORD_MODE:-auto}"
REDIS_REQUIREPASS="${REDIS_REQUIREPASS:-}"

POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --install-service)
            INSTALL_SERVICE_ONLY=true
            shift
            ;;
        --uninstall-service)
            UNINSTALL_SERVICE_ONLY=true
            shift
            ;;
        --no-password)
            REDIS_PASSWORD_MODE="none"
            REDIS_REQUIREPASS=""
            shift
            ;;
        --requirepass)
            [ -n "${2:-}" ] || { echo "错误: --requirepass 需要密码参数"; exit 1; }
            REDIS_PASSWORD_MODE="explicit"
            REDIS_REQUIREPASS="$2"
            shift 2
            ;;
        --requirepass=*)
            REDIS_PASSWORD_MODE="explicit"
            REDIS_REQUIREPASS="${1#*=}"
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检测 PATH 中可用的 adl
find_adl() {
    if command_exists adl && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

# 下载函数：优先使用可用的 adl，失败后回退到 curl/wget
download_with_adl() {
    local url="$1"
    local output="$2"
    local output_dir
    local filename
    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"

    mkdir -p "$output_dir"

    local adl_path
    if adl_path=$(find_adl); then
        echo "检测到可用 adl，优先使用 adl 下载..."
        if "$adl_path" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        echo "adl 下载失败，尝试使用 curl/wget 回退下载..."
    fi

    if command_exists curl; then
        curl -L --fail -o "$output" "$url"
    elif command_exists wget; then
        wget -O "$output" "$url"
    else
        echo "错误: 未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# Check file integrity
check_file_valid() {
    local file="$1"
    local min_size="${2:-1000}"
    [[ -f "$file" ]] && [[ -s "$file" ]] && [[ $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null) -gt $min_size ]]
}

# Auto privilege escalation
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要root权限，正在提权..."
        exec sudo "$0" "$@"
    fi
}

# 显示帮助信息
show_usage() {
    cat << EOF
Redis一键安装配置脚本

Redis是开源的内存数据结构存储，用作数据库、缓存和消息中间件。

用法: ./install.sh [INSTALL_DIR] [节点数] [端口] [REDIS_VERSION]

参数:
    INSTALL_DIR      安装目录 (默认: ~/redis)
    节点数           单机模式1(默认); 集群模式大于1
    端口             集群模式为起始端口 (默认: 6379)
    REDIS_VERSION    Redis版本 (默认: 8.0.3)

选项:
    -h, --help                  显示此帮助信息
    -v, --version               检测Redis是否已安装
    --install-service           只安装/刷新自启动服务，不重新初始化配置
    --uninstall-service         卸载自启动服务
    --no-password               不配置 Redis requirepass，适合内网或已有应用未配置密码
    --requirepass PASSWORD      指定 Redis requirepass，适合新环境统一加固

说明:
    - 支持单机模式和集群模式安装
    - 自动编译安装Redis服务
    - Linux 配置 systemd 服务；macOS 配置用户级 LaunchAgent
    - 用户目录安装不需要 root 权限
    - 默认自动生成 Redis 密码；迁移已有无密码环境时使用 --no-password

更多信息: https://redis.io/
EOF
}

# 解析参数
if [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
    # 检测Redis是否已安装
    if command -v redis-server >/dev/null 2>&1; then
        VERSION=$(redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' | head -1)
        if [ -n "$VERSION" ]; then
            echo "$VERSION"
        else
            echo "已安装"
        fi
        exit 0
    elif pgrep -f "redis-server" > /dev/null 2>&1; then
        echo "运行中"
        exit 0
    else
        echo ""
        exit 1
    fi
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# 当前脚本父目录
BASE_DIR=$(cd "$SCRIPT_DIR/.."; pwd)
# Redis版本
redis_version=${4:-"8.0.3"}
# 下载地址和压缩包名
url="https://github.com/redis/redis/archive/refs/tags/${redis_version}.tar.gz"
gz_file_name=${url##*/}
# 使用 DOWNLOAD_DIR 作为下载目录
gz_file=$DOWNLOAD_DIR/$gz_file_name
# 安装目录
INSTALL_DIR="${1:-$DEFAULT_INSTALL_DIR}"
# 节点数，单机模式1(默认);集群模式大于1为集群
num=${2:-1}
# 端口，集群模式为起始端口
port=${3:-6379}
# 系统服务目录
service_dir=/usr/lib/systemd/system
# 系统日志目录
system_log_dir=/var/log/redis
launchagent_label=org.redis.server
launchagent_file="$HOME/Library/LaunchAgents/$launchagent_label.plist"

# 检测操作系统类型
OS_TYPE=$(uname)

# 定义sed的in-place编辑函数，解决macOS和Linux的兼容性问题
if [[ "$OS_TYPE" == "Darwin" ]]; then
    sed_i() { sed -i '' "$@"; }
else
    sed_i() { sed -i "$@"; }
fi

redis_install_macos_launchagent() {
    local redis_home="$1"
    local source_conf="$2"
    local runtime_root="$HOME/Library/LaunchAgents/runtime/$launchagent_label"
    local runtime_bin="$runtime_root/bin"
    local runtime_conf="$runtime_root/conf"
    local runtime_data="$runtime_root/data"
    local runtime_logs="$runtime_root/logs"
    local runtime_run="$runtime_root/run"
    local real_home

    real_home="$(cd "$redis_home" && pwd -P)"
    mkdir -p "$runtime_bin" "$runtime_conf" "$runtime_data" "$runtime_logs" "$runtime_run" "$HOME/Library/LaunchAgents"
    cp "$real_home/bin/redis-server" "$runtime_bin/redis-server"
    chmod +x "$runtime_bin/redis-server"

    if [ ! -d "$runtime_data/appendonlydir" ] && [ -d "$real_home/appendonlydir" ]; then
        cp -R "$real_home/appendonlydir" "$runtime_data/appendonlydir"
    fi
    if [ ! -f "$runtime_data/dump.rdb" ] && [ -f "$real_home/dump.rdb" ]; then
        cp "$real_home/dump.rdb" "$runtime_data/dump.rdb"
    fi

    awk -v redis_dir="$runtime_data" -v pidfile="$runtime_run/redis-6379.pid" -v logfile="$runtime_logs/redis.log" '
        /^daemonize[[:space:]]+/ { print "daemonize no"; next }
        /^supervised[[:space:]]+/ { print "supervised no"; next }
        /^pidfile[[:space:]]+/ { print "pidfile " pidfile; next }
        /^logfile[[:space:]]+/ { print "logfile " logfile; next }
        /^dir[[:space:]]+/ { print "dir " redis_dir; next }
        { print }
    ' "$source_conf" > "$runtime_conf/redis.conf"

    if [[ "$OS_TYPE" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
        xattr -cr "$runtime_data" "$runtime_conf" 2>/dev/null || true
    fi

    launchctl bootout "gui/$(id -u)/$launchagent_label" >/dev/null 2>&1 || true
    launchctl unload "$launchagent_file" >/dev/null 2>&1 || true
    cat > "$launchagent_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$launchagent_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runtime_bin/redis-server</string>
        <string>$runtime_conf/redis.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$launchagent_file" 2>/dev/null || launchctl load -w "$launchagent_file"
    launchctl enable "gui/$(id -u)/$launchagent_label" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/$launchagent_label" 2>/dev/null || true
    echo "macOS LaunchAgent 已安装: $launchagent_file"
    echo "运行缓存目录: $runtime_root"
    echo "运行数据目录: $runtime_data"
}

install_existing_service_only() {
    local conf_file="$INSTALL_DIR/conf/redis.conf"
    local escaped_password
    [ -f "$conf_file" ] || { echo "错误: 配置文件不存在: $conf_file"; exit 1; }

    if [ "$REDIS_PASSWORD_MODE" != "auto" ]; then
        sed_i '/^[[:space:]]*requirepass[[:space:]]/d' "$conf_file"
        sed_i '/^[[:space:]]*masterauth[[:space:]]/d' "$conf_file"
        if [ "$REDIS_PASSWORD_MODE" = "explicit" ] && [ -n "$REDIS_REQUIREPASS" ]; then
            escaped_password=$(printf '%s\n' "$REDIS_REQUIREPASS" | sed -e 's/[\/&]/\\&/g')
            if grep -q "# requirepass foobared" "$conf_file"; then
                sed_i "/# requirepass foobared/a\\
requirepass $escaped_password" "$conf_file"
            else
                printf '\nrequirepass %s\n' "$REDIS_REQUIREPASS" >> "$conf_file"
            fi
            if grep -q "# masterauth foobared" "$conf_file"; then
                sed_i "s/# masterauth foobared/masterauth $escaped_password/" "$conf_file"
            fi
        fi
    fi

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        redis_install_macos_launchagent "$INSTALL_DIR" "$conf_file"
        exit 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        sudo mkdir -p "$service_dir" 2>/dev/null || mkdir -p "$service_dir" 2>/dev/null || true
        sudo tee "$service_dir/redis.service" > /dev/null << EOF
[Unit]
Description=redis
After=network.target

[Service]
Type=forking
ExecStart=$INSTALL_DIR/bin/redis-server $conf_file
ExecStop=$INSTALL_DIR/bin/stop.sh $port
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload 2>/dev/null || systemctl daemon-reload 2>/dev/null || true
        sudo systemctl enable redis.service 2>/dev/null || systemctl enable redis.service 2>/dev/null || true
        echo "systemd 服务已安装: redis"
        exit 0
    fi
    echo "错误: 当前系统不支持自动安装 Redis 自启动服务" >&2
    exit 1
}

uninstall_existing_service_only() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        launchctl bootout "gui/$(id -u)/$launchagent_label" >/dev/null 2>&1 || true
        launchctl unload "$launchagent_file" >/dev/null 2>&1 || true
        rm -f "$launchagent_file"
        rm -rf "$HOME/Library/LaunchAgents/runtime/$launchagent_label"
        echo "macOS LaunchAgent 已卸载: $launchagent_label"
        exit 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl disable --now redis.service 2>/dev/null || systemctl disable --now redis.service 2>/dev/null || true
        sudo rm -f "$service_dir/redis.service" 2>/dev/null || rm -f "$service_dir/redis.service" 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || systemctl daemon-reload 2>/dev/null || true
        echo "systemd 服务已卸载: redis"
        exit 0
    fi
    exit 0
}

if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    uninstall_existing_service_only
fi

if [ "$INSTALL_SERVICE_ONLY" = true ]; then
    install_existing_service_only
fi

# 检查并安装编译依赖
install_dependencies() {
    echo "检查系统依赖..."

    # 按包管理器定义包名映射（同一名在不同发行版下包名不同）
    # gcc: apt=gcc, yum/dnf=gcc
    # g++: apt=g++, yum/dnf=gcc-c++
    # jemalloc: apt=libjemalloc-dev, yum/dnf=jemalloc-devel
    # openssl: apt=libssl-dev, yum/dnf=openssl-devel
    local pkg_manager=""
    if command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    fi

    # 包名映射函数：传入逻辑名，返回当前系统的实际包名
    map_pkg_name() {
        case "$pkg_manager" in
            apt) echo "$1" ;;
            yum|dnf)
                case "$1" in
                    g++)             echo "gcc-c++" ;;
                    libjemalloc-dev) echo "jemalloc-devel" ;;
                    libssl-dev)      echo "openssl-devel" ;;
                    *)               echo "$1" ;;
                esac
                ;;
            *) echo "$1" ;;
        esac
    }

    local missing_logical=()   # 逻辑名（用于显示）
    local missing_pkgs=()      # 实际包名（用于安装）

    # 检查基础编译工具
    if ! command -v gcc >/dev/null 2>&1; then
        missing_logical+=("gcc")
        missing_pkgs+=("$(map_pkg_name gcc)")
    fi

    if ! command -v g++ >/dev/null 2>&1; then
        missing_logical+=("g++")
        missing_pkgs+=("$(map_pkg_name g++)")
    fi

    if ! command -v make >/dev/null 2>&1; then
        missing_logical+=("make")
        missing_pkgs+=("$(map_pkg_name make)")
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing_logical+=("curl")
        missing_pkgs+=("$(map_pkg_name curl)")
    fi

    # 检查开发库
    if ! ldconfig -p 2>/dev/null | grep -q "libjemalloc"; then
        missing_logical+=("jemalloc-dev")
        missing_pkgs+=("$(map_pkg_name libjemalloc-dev)")
    fi

    # Redis 8.x 默认启用 TLS 编译，需要 OpenSSL 开发头文件
    if [ ! -f /usr/include/openssl/ssl.h ] && [ ! -f /usr/local/include/openssl/ssl.h ]; then
        missing_logical+=("libssl-dev")
        missing_pkgs+=("$(map_pkg_name libssl-dev)")
    fi

    # 如果有缺失的依赖，则安装
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "检测到缺失的依赖: ${missing_logical[*]}"
        echo "实际安装包: ${missing_pkgs[*]}"
        echo "正在安装缺失的依赖..."

        case "$pkg_manager" in
            apt)
                echo "检测到 Debian/Ubuntu 系统"
                sudo apt-get update
                sudo apt-get install -y "${missing_pkgs[@]}"
                ;;
            yum)
                echo "检测到 CentOS/RHEL 系统"
                sudo yum install -y "${missing_pkgs[@]}"
                ;;
            dnf)
                echo "检测到 Fedora 系统"
                sudo dnf install -y "${missing_pkgs[@]}"
                ;;
            *)
                echo "警告: 无法识别的包管理器，请手动安装以下依赖：${missing_pkgs[*]}"
                read -p "按回车键继续，或 Ctrl+C 退出..." dummy
                ;;
        esac
    else
        echo "所有依赖已安装"
    fi
}

# 验证tar.gz文件完整性
verify_tar_gz() {
    local file="$1"
    if ! tar -tzf "$file" >/dev/null 2>&1; then
        echo "错误: 压缩文件损坏或不完整"
        return 1
    fi
    return 0
}

# 检查是否已安装
if [ -x "$INSTALL_DIR/bin/redis-server" ]; then
  echo "检测到 $INSTALL_DIR 已存在且已编译安装，跳过源码下载和编译。"
else
  # 检查安装目录权限
  if [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
    echo "错误: 没有对安装目录父目录的写权限: $(dirname "$INSTALL_DIR")"
    read -p "是否要更改安装目录到用户目录下? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      # 更改安装目录到用户目录下
      INSTALL_DIR="$HOME/redis"
      echo "安装目录已更改为: $INSTALL_DIR"
    else
        echo "将使用sudo权限安装到 $INSTALL_DIR"
        # 设置目录所属和权限
        [ ! -d $INSTALL_DIR ] && sudo mkdir -p $INSTALL_DIR/{conf,data}
        sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
        sudo chmod -R 755 "$INSTALL_DIR"
    fi
  fi
  
  # 安装编译依赖
  install_dependencies
  
  # 创建下载目录
  mkdir -p "$DOWNLOAD_DIR"
  
  # 下载源码包
  if [ ! -f "$gz_file" ]; then
    echo "正在下载 Redis 源码包..."
    download_with_adl "$url" "$gz_file"
  fi
  
  # 验证文件完整性
  if ! check_file_valid "$gz_file" 1000000; then
    echo "错误: 下载文件损坏或不完整，删除并重新下载..."
    rm -f "$gz_file"
    download_with_adl "$url" "$gz_file"
    if ! check_file_valid "$gz_file" 1000000; then
        echo "错误: 无法下载有效的源码包"
        exit 1
    fi
  fi
  
  # 验证tar.gz文件完整性
  if ! verify_tar_gz "$gz_file"; then
    echo "错误: 压缩文件已损坏，删除并重新下载..."
    rm -f "$gz_file"
    download_with_adl "$url" "$gz_file"
    if ! verify_tar_gz "$gz_file"; then
        echo "错误: 无法获取有效的压缩文件"
        exit 1
    fi
  fi

  # 使用 DOWNLOAD_DIR 作为临时解压目录
  cd "$DOWNLOAD_DIR"
  # 获取解压目录名
  extra_dir_name=$(tar -tzf "$gz_file" | head -1 | cut -f1 -d"/")
  if [ ! -d "$DOWNLOAD_DIR/$extra_dir_name" ]; then
    echo "正在解压..."
    tar -xzf "$gz_file" -C "$DOWNLOAD_DIR"
  fi

  # 进入源码目录
  cd "$DOWNLOAD_DIR/$extra_dir_name"
  echo "正在编译..."
  
  # 设置环境变量以正确链接jemalloc
  export USE_JEMALLOC=yes
  export MALLOC=jemalloc
  
  # 编译源码
  make BUILD_TLS=yes STD=-std=gnu99

  # 安装
  echo "正在安装到 $INSTALL_DIR..."
  make PREFIX="$INSTALL_DIR" install
fi

echo "复制配置文件和脚本..." 
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' "$BASE_DIR/" "$INSTALL_DIR/"
else
    cp -rp "$BASE_DIR"/* "$INSTALL_DIR/"
fi
chmod +x $INSTALL_DIR/bin/*.sh 2>/dev/null 

# 安装自启动服务
install-service(){
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        local BASE_DIR=$1
        local conf_file=$2
        redis_install_macos_launchagent "$BASE_DIR" "$conf_file"
        return 0
    fi
    
    local BASE_DIR=$1
    local conf_file=$2
    local service_name=$3
    local p=$4
    
    # 确保service目录存在
    if [ ! -d "$service_dir" ]; then
        if ! sudo mkdir -p "$service_dir" 2>/dev/null && ! mkdir -p "$service_dir" 2>/dev/null; then
            echo "警告: 无法创建服务目录 $service_dir"
            return 1
        fi
    fi
    
    if [ ! -f $service_dir/$service_name.service ];then
        # 使用sudo tee命令创建服务文件，避免直接写入系统目录的权限问题
        sudo tee "$service_dir/$service_name.service" > /dev/null << EOF
[Unit]
Description=redis
After=network.target

[Service]
Type=forking
ExecStart=$BASE_DIR/bin/redis-server $conf_file
ExecStop=$BASE_DIR/bin/stop.sh $p
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        
        # 检查服务文件是否创建成功
        if [ $? -ne 0 ]; then
            echo "警告: 无法创建systemd服务文件 $service_dir/$service_name.service"
            return 1
        else
            echo "systemd服务文件已创建到 $service_dir/$service_name.service"
        fi
        
        # 重新加载systemd
        if ! sudo systemctl daemon-reload 2>/dev/null && ! systemctl daemon-reload 2>/dev/null; then
            echo "警告: 无法重新加载systemd守护进程"
            return 1
        else
            echo "systemd守护进程已重新加载"
        fi
            
        # 启用服务
        if ! sudo systemctl enable "$service_name.service" 2>/dev/null && ! systemctl enable "$service_name.service" 2>/dev/null; then
            echo "警告: 无法启用服务 $service_name"
            return 1
        else
            echo "服务 $service_name 已启用"
        fi
    fi
}

uninstall-service(){
    local service_name="${1:-redis}"

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        launchctl bootout "gui/$(id -u)/$launchagent_label" >/dev/null 2>&1 || true
        launchctl unload "$launchagent_file" >/dev/null 2>&1 || true
        rm -f "$launchagent_file"
        echo "macOS LaunchAgent 已卸载: $launchagent_label"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl disable --now "$service_name.service" 2>/dev/null || systemctl disable --now "$service_name.service" 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || systemctl daemon-reload 2>/dev/null || true
    fi
    sudo rm -f "$service_dir/$service_name.service" 2>/dev/null || rm -f "$service_dir/$service_name.service" 2>/dev/null || true
    echo "systemd 服务已卸载: $service_name"
}

if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    uninstall-service "redis"
    exit 0
fi

apply_password_policy() {
    local conf_file="$1"
    local password="$2"
    local escaped_password

    [ -f "$conf_file" ] || { echo "错误: 配置文件不存在: $conf_file"; return 1; }

    sed_i '/^[[:space:]]*requirepass[[:space:]]/d' "$conf_file"
    sed_i '/^[[:space:]]*masterauth[[:space:]]/d' "$conf_file"

    if [ -n "$password" ]; then
        escaped_password=$(printf '%s\n' "$password" | sed -e 's/[\/&]/\\&/g')
        if grep -q "# requirepass foobared" "$conf_file"; then
            sed_i "/# requirepass foobared/a\\
requirepass $escaped_password" "$conf_file"
        else
            printf '\nrequirepass %s\n' "$password" >> "$conf_file"
        fi
        if grep -q "# masterauth foobared" "$conf_file"; then
            sed_i "s/# masterauth foobared/masterauth $escaped_password/" "$conf_file"
        fi
    fi
}

select_redis_password() {
    case "$REDIS_PASSWORD_MODE" in
        none)
            printf ''
            ;;
        explicit)
            printf '%s' "$REDIS_REQUIREPASS"
            ;;
        auto)
            generate_password
            ;;
        *)
            echo "错误: 未知 Redis 密码模式: $REDIS_PASSWORD_MODE" >&2
            exit 1
            ;;
    esac
}

if [ "$INSTALL_SERVICE_ONLY" = true ]; then
    conf_file="$INSTALL_DIR/conf/redis.conf"
    [ -f "$conf_file" ] || { echo "错误: 配置文件不存在: $conf_file"; exit 1; }
    if [ "$REDIS_PASSWORD_MODE" != "auto" ]; then
        apply_password_policy "$conf_file" "$REDIS_REQUIREPASS"
    fi
    install-service "$INSTALL_DIR" "$conf_file" "redis" "$port"
    exit 0
fi

# 创建密码函数
generate_password() {
    # 生成随机密码
    password=$(openssl rand -base64 12)
    echo "$password"
}

# 处理配置文件函数
handle_config() {
    local conf_file=$1
    local port=$2
    local is_cluster=$3
    local password=$4
    
    # 创建配置文件目录（如果需要）
    local conf_dir=$(dirname "$conf_file")
    if [ ! -d "$conf_dir" ]; then
       mkdir -p "$conf_dir"
    fi
    
    # 如果是集群模式，先复制模板文件
    if [ "$is_cluster" = "yes" ]; then
        if [ -f "$INSTALL_DIR/conf/redis.conf" ]; then
           cp "$INSTALL_DIR/conf/redis.conf" "$conf_file"
        fi
    fi
    #echo "conf_file:$conf_file"
    
    # 检查配置文件是否存在
    if [ ! -f "$conf_file" ]; then
        echo "错误: 配置文件 $conf_file 不存在"
        return 1
    fi
    
    # 转义可能引起sed命令错误的特殊字符（仅对密码等文本字段）
    local escaped_password=$(printf '%s\n' "$password" | sed -e 's/[\/&]/\\&/g')
    
    # 使用正确的sed语法处理配置文件，确保路径中的特殊字符被正确处理
    sed_i "s/^port .*/port $port/" "$conf_file"

    apply_password_policy "$conf_file" "$password"

    sed_i "s/appendonly no/appendonly yes/" "$conf_file"
    sed_i "s/bind 127.0.0.1/bind 0.0.0.0/" "$conf_file"
    # 保持副本为只读，更安全
    #sed_i "s/# replica-read-only yes/replica-read-only no/" "$conf_file"
    
    # --- 日志目录处理开始 ---
    # 从配置文件中读取当前的日志路径（忽略前导空格）
    current_logfile=$(grep -E '^[[:space:]]*logfile' "$conf_file" | awk '{print $2}')

    # 判断是否安装在用户目录下
    local use_user_log=false
    case "$INSTALL_DIR" in
        "$HOME"/*|/Users/*|/home/*) use_user_log=true ;;
    esac

    if [ "$use_user_log" = true ]; then
        # 用户目录安装：日志直接放在安装目录下
        logfile_to_set="$INSTALL_DIR/logs/redis-$port.log"
        mkdir -p "$INSTALL_DIR/logs"
    elif [ -z "$current_logfile" ] || [[ ! "$current_logfile" =~ ^/var/log/ ]]; then
        system_logfile_path="$system_log_dir/redis-$port.log"
        read -t 10 -p "建议修改为系统日志目录: $system_logfile_path 是否修改? (Y/n): " confirm_modify || true
        echo
        if [[ "$confirm_modify" != [nN] ]]; then
            logfile_to_set="$system_logfile_path"
            # 优先使用sudo创建目录和文件，并设置正确的所有者
            if sudo mkdir -p "$system_log_dir" && sudo touch "$logfile_to_set" && sudo chown "$(id -u):$(id -g)" "$logfile_to_set"; then
                sudo chown "$(id -u):$(id -g)" "$system_log_dir"
                echo "日志文件已在 $logfile_to_set 创建并设置好权限。"
            else
                echo "警告: 无法创建系统日志目录，使用安装目录下的logs/作为备用。"
                logfile_to_set="$INSTALL_DIR/logs/redis-$port.log"
            fi
        else
            logfile_to_set="$INSTALL_DIR/logs/redis-$port.log"
        fi
    else
        echo "日志文件已配置为系统路径: $current_logfile，无需修改。"
        logfile_to_set="$current_logfile"
    fi

    # 确保日志目录存在
    logdir_to_set=$(dirname "$logfile_to_set")
    if [[ ! "$logfile_to_set" =~ ^/var/log/ ]]; then
        mkdir -p "$logdir_to_set"
    fi

    # 更新配置文件中的日志路径
    if grep -q -E '^[[:space:]]*logfile' "$conf_file"; then
        sed_i "s#^[[:space:]]*logfile .*#logfile $logfile_to_set#" "$conf_file"
    else
        echo "logfile $logfile_to_set" >> "$conf_file"
    fi
    # --- 日志目录处理结束 ---
    # 使用正则表达式替换pid文件路径，提高通用性
    sed_i "s#pidfile .*\.pid#pidfile $INSTALL_DIR/redis-$port.pid#" "$conf_file"
    
    # 集群模式特有配置
    if [ "$is_cluster" = "yes" ]; then
        sed_i "s/# cluster-enabled yes/cluster-enabled yes/" "$conf_file"
        sed_i "s/# cluster-config-file nodes.conf/cluster-config-file nodes-$port.conf/" "$conf_file"
        sed_i "s/# cluster-node-timeout 15000/cluster-node-timeout 15000/" "$conf_file"
        sed_i "s/protected-mode yes/protected-mode no/" "$conf_file"
        if [ -n "$password" ] && grep -q "# masterauth foobared" "$conf_file"; then
            sed_i "s/# masterauth foobared/masterauth $escaped_password/" "$conf_file"
        fi
    else
        # 单机模式下，如果bind 0.0.0.0，也禁用保护模式
        sed_i "s/protected-mode yes/protected-mode no/" "$conf_file"    
    fi
}

# 设置环境变量
setup_environment() {
    echo "正在配置环境变量..."

    # 优先尝试在 /etc/profile.d 中进行系统级配置
    if [ -d "/etc/profile.d" ]; then
        if [ -w "/etc/profile.d" ] || sudo -n true 2>/dev/null; then
            echo "检测到 sudo 权限或 /etc/profile.d 写权限，将进行系统级配置。"
            local profile_script="/etc/profile.d/redis.sh"
            # 使用 sudo tee 写入文件，以处理权限问题
            sudo tee "$profile_script" > /dev/null << EOF
#!/bin/sh
export REDIS_HOME=${INSTALL_DIR}
export PATH=$REDIS_HOME/bin:$PATH
EOF
            sudo chmod +x "$profile_script"
            echo "环境变量已配置,加载配置执行: source $profile_script"
            echo -e "\033[33m或启动新 shell 以使配置生效。\033[0m"
            return
        fi
    fi

    # 如果系统级配置失败，则回退到用户级配置
    echo "警告: 无 sudo 权限或无法写入 /etc/profile.d。"
    echo "将回退到用户级别配置 (~/.bashrc, ~/.zshrc)..."
    
    local shell_type
    shell_type=$(basename "$SHELL")
    local rc_file

    if [ "$shell_type" = "bash" ]; then
        rc_file="$HOME/.bashrc"
    elif [ "$shell_type" = "zsh" ]; then
        rc_file="$HOME/.zshrc"
    else
        echo "不支持的 shell 类型: $shell_type"
        echo "请手动将以下内容添加到您的 shell 配置文件中:"
        echo "export REDIS_HOME=$INSTALL_DIR"
        echo 'export PATH=$REDIS_HOME/bin:$PATH'
        return
    fi

    # 检查并设置 REDIS_HOME
    if grep -q "export REDIS_HOME=" "$rc_file"; then
        # 如果存在，则更新
        sed -i.bak "s|export REDIS_HOME=.*|export REDIS_HOME=$INSTALL_DIR|g" "$rc_file"
        echo "已更新 $rc_file 中的 REDIS_HOME"
    else
        # 如果不存在，则添加
        echo "" >> "$rc_file"
        echo "export REDIS_HOME=$INSTALL_DIR" >> "$rc_file"
        echo "已将 REDIS_HOME 添加到 $rc_file"
    fi
    
    # 检查并设置 PATH
    # 使用更健壮的方式检查 $REDIS_HOME/bin 是否已在 PATH 中
    if ! grep -q 'export PATH=.*$REDIS_HOME/bin' "$rc_file"; then
        echo 'export PATH=$REDIS_HOME/bin:$PATH' >> "$rc_file"
        echo "已将 Redis bin 目录添加到 $rc_file 的 PATH 中"
    else
        echo "PATH 配置已包含 Redis bin 目录，无需修改。"
    fi
	
    echo -e "\033[33m请运行 source $rc_file 或重新启动终端使配置生效。\033[0m"
}


# 初始化集群或单机配置
cd "$INSTALL_DIR"

# 生成或选择密码
password=$(select_redis_password)

if [ $num -gt 1 ]; then
	# 集群参数校验
	[ $num -lt 3 ] && num=3
	[ $((num % 2)) -eq 0 ] && echo "集群模式节点数必须为奇数，当前为 $num,+1变更为奇数节点数。" &&  num=$((num+1))
	# 集群模式
	echo "初始化 Redis 集群模式 ($num 个节点，起始端口 $port)..."
	
	# 生成集群节点配置
	for (( p=port; p<port+num; p++ )); do
        conf_file="$INSTALL_DIR/conf/redis-$p.conf"
        
        # 如果配置文件不存在，则创建
        if [ ! -f "$conf_file" ]; then
            handle_config "$conf_file" "$p" "yes" "$password"
            # 安装服务
            install-service "$INSTALL_DIR" "$conf_file" "redis-$p" "$p"
        fi
    done
    
    echo "✅ Redis 集群模式已初始化，节点数: $num，起始端口: $port"
    if [ -n "$password" ]; then
        echo "生成/使用的密码: $password"
        echo "提示: 可以使用以下命令修改密码 (将 NEW_PASSWORD 替换为新密码):"
        echo "  redis-cli -a '$password' -p $port config set requirepass NEW_PASSWORD"
    else
        echo "Redis 未配置 requirepass"
    fi
    
    echo "正在启动所有集群节点..."
    $INSTALL_DIR/bin/startup.sh "$num" "$port"
    
    echo "等待节点启动..."
    sleep 8 # 等待几秒钟确保所有进程已启动

    echo "正在创建集群..."
    # 使用 expect 来处理 redis-cli 的交互式输入
    if command -v expect >/dev/null 2>&1; then
        cluster_auth_args=""
        [ -n "$password" ] && cluster_auth_args="-a \"$password\""
        expect <<EOF
spawn $INSTALL_DIR/bin/redis-cli --cluster create $cluster_nodes --cluster-replicas 1 $cluster_auth_args
expect "Type 'yes' to accept):"
send "yes\r"
expect eof
EOF
    else
        echo "警告: 'expect' 命令未安装。请手动执行以下命令创建集群:"
        if [ -n "$password" ]; then
            echo "$INSTALL_DIR/bin/redis-cli --cluster create $cluster_nodes --cluster-replicas 1 -a \"$password\""
        else
            echo "$INSTALL_DIR/bin/redis-cli --cluster create $cluster_nodes --cluster-replicas 1"
        fi
        echo "并在提示时输入 'yes'"
    fi

    echo "✅ Redis 集群已创建成功！"
    
else
    # 单机模式
    conf_file=$INSTALL_DIR/conf/redis.conf
    # 处理配置文件
    handle_config "$conf_file" "$port" "no" "$password"
    # 安装服务
    install-service "$INSTALL_DIR" "$conf_file" "redis" "$port"
    
    echo "✅ Redis 单机模式已初始化，端口: $port"
    if [ -n "$password" ]; then
        echo "生成/使用的密码: $password"
        echo "提示: 您可以使用以下命令修改密码 (将 NEW_PASSWORD 替换为您的新密码):"
        echo "  $INSTALL_DIR/bin/redis-cli -a '$password' -p $port config set requirepass NEW_PASSWORD"
    else
        echo "Redis 未配置 requirepass"
    fi
	  
	# 动态安装配置完成后调用安装目录下的启动脚本
	if [ -f "$INSTALL_DIR/bin/startup.sh" ] && [ -x "$INSTALL_DIR/bin/startup.sh" ]; then
	  echo "正在停止任何可能在运行的旧 Redis 实例..."
	  # 允许停止失败（例如，如果服务本来就没在运行），并等待2秒确保端口释放
	  $INSTALL_DIR/bin/stop.sh || true
	  sleep 2

	  echo "正在启动 Redis..."
	  # 将配置文件路径作为第3个参数传递给 startup.sh
	  $INSTALL_DIR/bin/startup.sh "$num" "$port" "$conf_file"
	else
	  echo "提示: 您可以手动执行以下命令启动 Redis:"
	  echo "  $INSTALL_DIR/bin/startup.sh"
	fi
fi

# 设置环境变量
setup_environment

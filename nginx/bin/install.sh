#!/bin/bash
# nginx自动安装、配置

# 设置更严格的错误处理
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
readonly DEFAULT_NGINX_HOME="$HOME/nginx"
readonly DEFAULT_USER="www-data"
readonly DEFAULT_URL="http://nginx.org/download/nginx-1.29.0.tar.gz"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"

# 默认值
nginx_home=$DEFAULT_NGINX_HOME
usr=$DEFAULT_USER
group=$usr
url=$DEFAULT_URL
download_dir=$DEFAULT_DOWNLOAD_DIR
user_mode=false  # 用户模式标志，默认为false
cd $BASE_DIR
OS_TYPE=""
# 全局变量定义
PKG_INSTALLER=""
PKG_UPDATE=""

show_help(){
	cat << EOF
    用法: $0 [选项]
    选项:
      --dir DIR            指定安装目录，默认: $DEFAULT_NGINX_HOME
      --user USER          指定运行用户，默认: $DEFAULT_USER
      --url URL            指定Nginx源码下载URL
      --download-dir DIR   指定下载目录，默认: $DEFAULT_DOWNLOAD_DIR
      --user-mode          启用用户模式，不使用系统级安装 (无需sudo)
      --help, -h           显示此帮助信息
    
EOF
}
# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            nginx_home="$2"
            shift 2
            ;;
        --user)
            usr="$2"
            group="$2"  # 默认组与用户相同
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

# nginx压缩文件名
gz_file_name=${url##*/}
# 解压临时目录 - 使用用户指定的下载目录
mkdir -p "$download_dir"
tmp_dir="$download_dir/${gz_file_name%%.tar*}"
gz_file="$download_dir/$gz_file_name"

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

# 获取本机IP
get_script_ip() {
    if command -v ip > /dev/null 2>&1; then
        ip addr | awk '/inet / && !/127.0.0.1/ {sub("/.*", "", $2); print $2; exit}'
    elif command -v ifconfig > /dev/null 2>&1; then
        ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
    else
        echo "127.0.0.1"
    fi
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
    # 清理临时文件 - 只清理以nginx-开头的目录
    if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ] && [[ "$tmp_dir" == *"/nginx-"* ]]; then
        rm -rf "$tmp_dir" 2>/dev/null || true
    fi
    exit $exit_code
}

# 设置退出时清理
trap cleanup EXIT INT TERM

# 日志文件
LOG_FILE="/tmp/nginx_install_$(date +%Y%m%d_%H%M%S).log"

usage(){
	echo "用法: $1 --dir [安装目录] --user [安装用户] --download-dir [下载目录]"
    echo "示例: $1 --dir $nginx_home --user $usr --download-dir $download_dir"
}

# 检测操作系统类型和包管理器
detect_os() {
    # 检测是否为 macOS
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

# 检查目录是否具有写权限的函数
has_write_permission() {
    local dir="$1"
    # 检查目录是否存在
    if [ ! -d "$dir" ]; then
        # 目录不存在，需要检查父目录的写权限
        local parent_dir=$(dirname "$dir")
        if [ -w "$parent_dir" ] && [ -x "$parent_dir" ]; then
            return 0  # 有权限在父目录中创建子目录
        else
            return 1  # 没有权限在父目录中创建子目录
        fi
    else
        # 目录存在，直接检查写权限
        [ -w "$dir" ]
        return $?
    fi
}

# 检查是否有sudo权限
has_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        # 测试sudo权限但不实际执行任何操作
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

# 智能执行命令，根据权限决定是否使用sudo
smart_exec() {
    local cmd="$1"
    local target_dir="$2"  # 用于判断是否需要sudo的目标目录
    local force_sudo="${3:-false}"  # 强制使用sudo的标志
    
    # 如果是用户模式，不使用sudo
    if [ "$user_mode" = "true" ]; then
        debug "用户模式: 不使用sudo，执行: $cmd"
        sh -c "$cmd"
        return $?
    fi
    
    # 如果强制使用sudo或目标目录需要sudo权限
    if [ "$force_sudo" = "true" ] || ! has_write_permission "$target_dir"; then
        debug "对 $target_dir 需要sudo权限，执行: sudo $cmd"
        ensure_sudo  # 确保有sudo权限
        sudo sh -c "$cmd"
        return $?
    else
        debug "对 $target_dir 有权限，执行: $cmd"
        sh -c "$cmd"
        return $?
    fi
}

# 通用文件操作权限检查
ensure_write_permission() {
    local path="$1"
    local path_type="$2"
    
    if [ ! -w "$path" ]; then
        echo "$path_type $path 无写权限，正在修复..."
        if [ "$OS_TYPE" = "macos" ]; then
            smart_exec "chown $(whoami):staff '$path'" "$path"
        else
            smart_exec "chown ${usr}:${group} '$path'" "$path"
        fi
        echo "✓ 已修复 $path_type 权限: $path"
    fi
}

# 智能目录创建函数，自动处理权限（简化版）
create_dir_with_permission() {
    local dir_path
    for dir_path in "$@"; do
        if [ ! -d "$dir_path" ]; then
            echo "创建目录: $dir_path"
            
            # 使用智能执行函数判断是否需要sudo
            local parent_dir=$(dirname "$dir_path")
            if smart_exec "mkdir -p '$dir_path'" "$parent_dir"; then
                echo "✓ 成功创建目录: $dir_path"
            else
                echo "✗ 无法创建目录 $dir_path"
                return 1
            fi
        fi
        ensure_write_permission "$dir_path" "目录"
    done
}

check () {
  #检查nginx是否已经安装，已安装检测配置是否正确，配置正确就启动nginx
  if [ -f $nginx_home/sbin/nginx ];then
    start_nginx && exit 0
  fi
  #未安装执行安装前的检查
  if [ "$OS_TYPE" != "macos" ]; then
    # 用户模式下跳过系统用户和组创建
    if [ "$user_mode" = "true" ]; then
      echo "用户模式: 跳过系统用户和组创建"
      # 在用户模式下使用当前用户
      usr=$(whoami)
      group=$(id -gn)
      echo "使用当前用户: $usr:$group"
    else
      # 检测添加用户
      if ! id -u $usr > /dev/null 2>&1; then
        if command -v useradd > /dev/null 2>&1; then
          smart_exec "useradd -M -s /sbin/nologin $usr" "/etc" true
          echo "已创建用户: $usr"
        elif command -v adduser > /dev/null 2>&1; then
          smart_exec "adduser --system --group --no-create-home --shell /sbin/nologin $usr" "/etc" true
          echo "已创建用户: $usr"
        else
          echo "错误: 未找到创建用户的有效命令 (useradd 或 adduser)"
          exit 1
        fi
      else
        echo "用户 $usr 已存在"
      fi

      # 检查组是否存在，如果不存在则创建
      if ! getent group $group > /dev/null 2>&1; then
        if command -v groupadd > /dev/null 2>&1; then
          smart_exec "groupadd $group" "/etc" true
          echo "已创建组: $group"
        else
          echo "错误: 未找到创建组的有效命令 (groupadd)"
          exit 1
        fi
      else
        echo "组 $group 已存在"
      fi
    fi

    # 确保配置文件存在再进行替换
    if [ -f "$BASE_DIR/conf/nginx.conf" ]; then
      sed -i "s#^user .*;#user $usr;#" $BASE_DIR/conf/nginx.conf
    else
      echo "警告: 配置文件不存在: $BASE_DIR/conf/nginx.conf"
    fi
  else
  	# macOS下注释掉user配置，使用当前用户
    if [ -f "$BASE_DIR/conf/nginx.conf" ]; then
      sed -i '' 's/^user/#user/' $BASE_DIR/conf/nginx.conf 2>/dev/null || sed -i.bak 's/^user/#user/' $BASE_DIR/conf/nginx.conf
    fi
  fi


  # 根据操作系统安装依赖
  if [ "$OS_TYPE" = "linux" ]; then
    # 检查是否已检测到包管理器，如果没有，再次尝试检查基于dpkg的系统
    if [ -z "$PKG_INSTALLER" ] && command -v dpkg > /dev/null 2>&1; then
        # 这是一个基于 Debian 的系统，尝试配置 apt 或 apt-get
        if command -v apt-get > /dev/null 2>&1; then
            PKG_INSTALLER="apt-get install -y"
            PKG_UPDATE="apt-get update"
            echo "检测到 apt-get，已配置包管理器"
        elif command -v apt > /dev/null 2>&1; then
            PKG_INSTALLER="apt install -y"
            PKG_UPDATE="apt update"
            echo "检测到 apt，已配置包管理器"
        fi
    fi

    # Linux依赖 - 直接使用全局变量中检测到的包管理器
    if [ -n "$PKG_INSTALLER" ]; then
      echo "检测到包管理器: $PKG_INSTALLER"
      # 根据已检测到的包管理器安装对应的依赖
      if [[ "$PKG_INSTALLER" == *"apt-get"* ]] || [[ "$PKG_INSTALLER" == *"apt"* ]]; then
        install_dependencies "wget build-essential libpcre3 libpcre3-dev libpcre2-dev zlib1g zlib1g-dev libssl-dev libgeoip-dev libperl-dev" "Linux编译依赖"
      elif [[ "$PKG_INSTALLER" == *"yum"* ]]; then
        install_dependencies "wget epel-release gcc pcre pcre-devel zlib zlib-devel openssl openssl-devel geoip-devel perl-ExtUtils-Embed" "Linux编译依赖"
      elif [[ "$PKG_INSTALLER" == *"dnf"* ]]; then
        install_dependencies "wget gcc pcre pcre-devel zlib zlib-devel openssl openssl-devel libperl-devel perl-IO-Socket-SSL perl-Net-SSLeay GeoIP-devel" "Linux编译依赖"
      elif [[ "$PKG_INSTALLER" == *"zypper"* ]]; then
        install_dependencies "wget gcc pcre pcre-devel zlib zlib-devel libopenssl-devel perl-IO-Socket-SSL perl-Net-SSLeay GeoIP-devel" "Linux编译依赖"
      fi
    else
      echo "无法自动检测到包管理器，跳过自动依赖安装"
      echo "请手动安装必需的依赖库"
      validate_dependencies  # 立即验证依赖，让用户知道具体缺少什么
    fi
  elif [ "$OS_TYPE" = "macos" ]; then
    # macOS依赖
    install_dependencies "wget pcre openssl zlib perl" "macOS编译依赖"
  fi

  validate_dependencies
}

# 验证URL格式
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
        error "无效的URL: $url"
    fi
}

# 下载、解压nginx
download_nginx () {
  # 验证URL
  validate_url "$url"

  # 使用通用函数批量创建目录
  create_dir_with_permission "$nginx_home" "$tmp_dir"
  if [ ! -f $gz_file ];then
    log "正在下载: $url"
    if ! wget --timeout=30 --tries=3 "$url" -O "$gz_file"; then
      error "下载失败，请检查网络连接或URL: $url"
    fi
  else
    log "Nginx压缩包已存在: $gz_file"
  fi

  log "正在解压: $gz_file"
  if ! tar -zxf "$gz_file" -C "${tmp_dir%/*}/"; then
    error "解压失败，请检查压缩包完整性: $gz_file"
  fi
  log "解压完成: $tmp_dir"
}

# 安装nginx
install_nginx () {
  download_nginx
  if [ ! -d "$tmp_dir" ]; then
    echo "✗ 源码目录不存在: $tmp_dir"
    exit 1
  fi
  cd $tmp_dir || exit 1

  # 验证配置文件是否存在
  if [ ! -f "$BASE_DIR/conf/nginx.conf" ]; then
    echo "✗ 配置文件不存在: $BASE_DIR/conf/nginx.conf"
    exit 1
  fi

  # 提取日志和PID路径
  err_log=$(grep error_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';' | head -n 1)
  access_log=$(grep access_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';' | head -n 1)
  pid_path=$(grep pid $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';' | head -n 1)
  pid_dir=$(dirname "$pid_path")
  log_dir=${access_log%/*}

  echo "pid_dir: $pid_dir"
  echo "log_dir: $log_dir"
  echo "err_log: $err_log"
  echo "access_log: $access_log"

  # 用户模式下使用用户目录
  if [ "$user_mode" = "true" ]; then
    log_dir="$nginx_home/logs"
    pid_dir="$nginx_home/logs"
    err_log="$nginx_home/logs/error.log"
    access_log="$nginx_home/logs/access.log"
    pid_path="$nginx_home/logs/nginx.pid"
    echo "用户模式: 使用用户目录"
    echo "pid_dir: $pid_dir"
    echo "log_dir: $log_dir"
    echo "err_log: $err_log"
    echo "access_log: $access_log"
  fi

  # 创建日志目录
  echo "正在创建日志目录..."
  create_dir_with_permission "$log_dir" "$pid_dir"

  # 确保日志文件存在
  if [ -n "$err_log" ]; then
    local err_log_dir=$(dirname "$err_log")
    [ ! -f "$err_log" ] && smart_exec "touch '$err_log'" "$err_log_dir" 2>/dev/null || true
  fi
  if [ -n "$access_log" ]; then
    local access_log_dir=$(dirname "$access_log")
    [ ! -f "$access_log" ] && smart_exec "touch '$access_log'" "$access_log_dir" 2>/dev/null || true
  fi

  # 设置系统目录权限
  log "正在设置系统目录权限..."
  if [ "$OS_TYPE" != "macos" ]; then
    if [ -n "$log_dir" ]; then
      if ! smart_exec "chown -R '${usr}:${group}' '${log_dir}'" "$log_dir" 2>/dev/null; then
        log "警告: 无法设置日志目录所有者: $log_dir"
      fi
    fi
    if [ -n "$pid_dir" ]; then
      if ! smart_exec "chown -R '${usr}:${group}' '${pid_dir}'" "$pid_dir" 2>/dev/null; then
        log "警告: 无法设置PID目录所有者: $pid_dir"
      fi
    fi
  else
    # macOS下使用当前用户权限
    if [ -n "$log_dir" ]; then
      if ! smart_exec "chown -R '$(whoami):admin' '${log_dir}'" "$log_dir" 2>/dev/null; then
        log "警告: 无法设置日志目录所有者: $log_dir"
      fi
    fi
    if [ -n "$pid_dir" ]; then
      if ! smart_exec "chown -R '$(whoami):admin' '${pid_dir}'" "$pid_dir" 2>/dev/null; then
        log "警告: 无法设置PID目录所有者: $pid_dir"
      fi
    fi
  fi

  # 确保nginx有权限写入
  if [ -n "$log_dir" ]; then
    if ! smart_exec "chmod 755 '${log_dir}'" "$log_dir" 2>/dev/null; then
      log "警告: 无法设置日志目录权限: $log_dir"
    fi
  fi
  if [ -n "$pid_dir" ]; then
    if ! smart_exec "chmod 755 '${pid_dir}'" "$pid_dir" 2>/dev/null; then
      log "警告: 无法设置PID目录权限: $pid_dir"
    fi
  fi

  # 根据操作系统调整configure参数
  if [ "$OS_TYPE" = "macos" ]; then
    # macOS不支持file-aio和GeoIP，移除相关参数
    configure_command="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=$pid_path --with-threads --with-http_stub_status_module --with-compat --with-debug --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module"
  else
    # 用户模式下禁用需要系统权限的模块
    if [ "$user_mode" = "true" ]; then
      essential_modules="--with-threads --with-http_stub_status_module --with-compat --with-debug --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module"
      optional_modules=""  # 用户模式下不添加可选模块
      echo "用户模式: 禁用需要系统权限的模块 (Perl模块等)"
      
      # 确保不会尝试安装Perl模块
      export NGX_PERL=no
      export PERL5LIB=""
    else
      # 定义模块配置变量
      essential_modules="--with-threads --with-http_stub_status_module --with-compat --with-debug --with-file-aio --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_perl_module=dynamic --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module"
      recommended_modules="" # 预留推荐模块位置
      optional_modules=""

      # 检测并处理可选模块
      check_and_add_optional_module() {
          local module_name="$1"
          local library_check="$2"  # 检查库的命令，如 "GeoIP"
          local apt_package="$3"    # apt系统对应的包名
          local yum_package="$4"    # yum/dnf系统对应的包名
          local module_config="$5"  # 模块的配置参数

          echo "检查 $module_name 模块依赖..."
          if command -v pkg-config > /dev/null 2>&1 && pkg-config --exists $library_check; then
              echo "$module_name 库已找到，启用 $module_name 模块"
              optional_modules="$optional_modules $module_config"
          else
              echo "警告: 未找到 $module_name 库"
              if [ -n "$PKG_INSTALLER" ]; then
                  echo "正在尝试自动安装 $module_name 库..."
                  local package_name=""
                  if [[ "$PKG_INSTALLER" == *"apt-get"* ]] || [[ "$PKG_INSTALLER" == *"apt"* ]]; then
                      package_name=$apt_package
                  elif [[ "$PKG_INSTALLER" == *"yum"* ]] || [[ "$PKG_INSTALLER" == *"dnf"* ]]; then
                      package_name=$yum_package
                  fi

                  if [ -n "$package_name" ]; then
                      # 使用智能执行函数处理包安装
                      if smart_exec "$PKG_INSTALLER $package_name" "/usr/local" true; then
                          echo "✓ $module_name 库安装成功"
                          # 重新检查库是否存在
                          if command -v pkg-config > /dev/null 2>&1 && pkg-config --exists $library_check; then
                              optional_modules="$optional_modules $module_config"
                              echo "启用 $module_name 模块"
                          else
                              echo "✗ 安装后仍无法找到 $module_name 库"
                          fi
                      else
                          echo "✗ $module_name 库安装失败"
                      fi
                  else
                      echo "✗ $module_name 库安装失败 - 未找到对应包名"
                  fi
              else
                  echo "未找到包管理器，无法自动安装 $module_name 库"
              fi
          fi
      }

      # 检查可选模块
      check_and_add_optional_module "GeoIP" "GeoIP" "libgeoip-dev" "geoip-devel" "--with-http_geoip_module=dynamic"
    fi

    # 组合所有模块参数
    configure_command="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=$pid_path $essential_modules $optional_modules"
  fi
  if ! eval "$configure_command"; then
    echo "✗ nginx: 配置失败"
    echo "请检查错误信息并确保已安装必需的依赖库"
    exit 1
  fi

  echo "nginx: 配置成功"

  # 编译
  if ! make; then
    echo "✗ nginx: 编译失败"
    make clean
    exit 1
  fi

  # 安装前处理Perl模块问题
  if [ -f "objs/Makefile" ]; then
    # 检查是否有Perl模块需要安装
    if grep -q "install_perl_modules" objs/Makefile; then
      echo "检测到Perl模块，尝试处理安装权限问题..."
      
      # 尝试创建Perl模块安装目录
      perl_install_dir="/usr/local/lib/x86_64-linux-gnu/perl/5.36.0"
      if [ ! -d "$perl_install_dir" ]; then
        echo "尝试创建Perl模块安装目录: $perl_install_dir"
        smart_exec "mkdir -p '$perl_install_dir'" "$perl_install_dir" true || {
          echo "无法创建Perl模块安装目录，将跳过Perl模块安装"
          # 修改Makefile，跳过Perl模块安装
          sed -i 's/install_perl_modules/#install_perl_modules/g' objs/Makefile
        }
      fi
      
      # 如果目录创建成功，确保有写权限
      if [ -d "$perl_install_dir" ]; then
        smart_exec "chmod 755 '$perl_install_dir'" "$perl_install_dir" true || {
          echo "无法设置Perl模块目录权限，将跳过Perl模块安装"
          sed -i 's/install_perl_modules/#install_perl_modules/g' objs/Makefile
        }
      fi
    fi
  fi
  
  if ! make install; then
    echo "✗ nginx: 安装失败"
    
    # 如果安装失败是因为Perl模块权限问题，尝试跳过Perl模块重新安装
    if grep -q "install_perl_modules" objs/Makefile 2>/dev/null; then
      echo "尝试跳过Perl模块重新安装..."
      sed -i 's/install_perl_modules/#install_perl_modules/g' objs/Makefile
      if ! make install; then
        echo "✗ nginx: 安装仍然失败"
        make clean
        exit 1
      else
        echo "✓ nginx: 跳过Perl模块安装成功"
      fi
    else
      make clean
      exit 1
    fi
  else
    echo "✓ nginx: 安装成功"
  fi

  echo "nginx: 安装成功"
  cd /tmp  # 先切换到安全目录，避免后续删除当前目录导致 getcwd 报错
  rm -rf $tmp_dir
}

# 启动nginx
start_nginx () {
  # 创建软链接 - 避免使用系统目录，改为用户可访问的路径
  local bin_dir="$HOME/bin"
  if [ ! -d "$bin_dir" ]; then
    mkdir -p "$bin_dir"
  fi
  
  # 尝试创建软链接到用户bin目录
  ln -sf "$nginx_home/sbin/nginx" "$bin_dir/nginx" 2>/dev/null || {
    echo "警告: 无法创建软链接到$bin_dir/nginx"
  }
  
  # 如果PATH包含用户bin目录，添加到PATH
  if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
    echo "提示: 如需全局访问nginx，请将 $bin_dir 添加到PATH环境变量"
    echo "临时运行: export PATH=\"$bin_dir:\$PATH\""
  fi
  #检测nginx是否已经启动
  ps_count=$(ps -ef | grep nginx | grep master | grep -v grep | wc -l)
  # 获取本机IP
  get_script_ip() {
    if command -v ip > /dev/null 2>&1; then
      ip addr | awk '/inet / && !/127.0.0.1/ {sub("/.*", "", $2); print $2; exit}'
    elif command -v ifconfig > /dev/null 2>&1; then
      ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
    else
      echo "127.0.0.1"
    fi
  }

    # 批量创建所有需要的目录
  create_dir_with_permission "$nginx_home/www" "$nginx_home/conf" "$nginx_home/bin" "$nginx_home/logs"
  
  # 使用权限检查函数复制文件
  ensure_write_permission "$nginx_home/conf" "nginx配置目录权限"
  if ! cp -r "$BASE_DIR/conf" "$nginx_home/"; then
    log "✗ 复制配置文件失败"
    return 1
  fi
  log "✓ 配置文件复制成功"

  ensure_write_permission "$nginx_home/bin" "nginx脚本目录权限"
  # 强制拷贝脚本文件
  if ! cp -rf "$BASE_DIR/bin/"*.sh "$nginx_home/bin/"; then
    log "✗ 复制脚本文件失败"
    return 1
  fi
  chmod +x "$nginx_home/bin/"*.sh
  log "✓ 脚本文件复制成功"
  
  # 使用rsync同步配置文件，保留模板文件
  if command -v rsync >/dev/null 2>&1; then
    log "正在同步配置文件到 $nginx_home/conf/..."
    rsync -a --quiet --exclude='*.template' "$BASE_DIR/conf/" "$nginx_home/conf/"
    log "✓ 配置文件已同步"
  else
    log "正在拷贝配置文件到 $nginx_home/conf/..."
    cp -r "$BASE_DIR/conf/"* "$nginx_home/conf/"
  fi

  # 模板文件处理
  process_template_files() {
    local conf_dir="$1"
    local current_ip=$(get_script_ip)
    
    echo "处理模板文件..."
    
    # 查找所有模板文件
    find "$conf_dir" -name "*.template" -type f | while read -r template_file; do
      local conf_file="${template_file%.template}"
      echo "处理模板文件: $template_file"
      sed "s/{{SERVER_IP}}/$current_ip/g" "$template_file" > "$conf_file"
      echo "✓ 模板文件已应用: $conf_file"
    done
  }
  
  # 验证IP地址格式
  validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      while IFS='.' read -r i1 i2 i3 i4; do
        [[ $i1 -le 255 && $i2 -le 255 && $i3 -le 255 && $i4 -le 255 ]]
      done <<< "$ip"
      return $?
    else
      return 1
    fi
  }

  # 配置文件IP替换
  replace_ip_in_configs() {
    local conf_dir="$1"
    local current_ip=$(get_script_ip)

    # 验证IP格式
    if ! validate_ip "$current_ip"; then
        log "警告: 无法获取有效的IP地址: $current_ip"
        return 1
    fi

    log "替换配置文件中的IP地址..."

    # 查找所有配置文件（排除模板文件）
    find "$conf_dir" -name "*.conf" -type f ! -name "*.template" | while read -r conf_file; do
      # 只替换包含占位符的配置文件
      if grep -q "{{SERVER_IP}}" "$conf_file" 2>/dev/null; then
        if [[ "$OS_TYPE" == "darwin"* ]]; then
          sed -i '' "s/{{SERVER_IP}}/$current_ip/g" "$conf_file"
        else
          sed -i.bak "s/{{SERVER_IP}}/$current_ip/g" "$conf_file"
        fi
        log "已替换配置文件中的占位符: $conf_file"
        # 清理备份文件
        [ -f "${conf_file}.bak" ] && rm "${conf_file}.bak"
      fi
    done
  }
  
  # 智能IP检测和替换
  smart_ip_replacement() {
    local conf_dir="$1"
    process_template_files "$conf_dir"
    replace_ip_in_configs "$conf_dir"
  }
  
  # 执行智能IP替换
  
    smart_ip_replacement "$nginx_home/conf"
  
  
  
    # 修复配置文件中的系统路径
  
    log "修复配置文件中的系统路径..."
  
    if [ -f "$nginx_home/conf/nginx.conf" ]; then
  
      # 替换日志路径
  
      sed -i "s|/var/log/nginx/|$nginx_home/logs/|g" "$nginx_home/conf/nginx.conf"
  
      sed -i "s|/var/run/nginx.pid|$nginx_home/logs/nginx.pid|g" "$nginx_home/conf/nginx.conf"
  
      
  
      # 替换conf.d目录中的路径
  
      
  
          find "$nginx_home/conf/conf.d" -name "*.conf" -type f -exec sed -i "s|/var/log/nginx/|$nginx_home/logs/|g" {} \;
  
    fi
  
  
  
    # 检查并修改端口配置（避免特权端口）
  
  
  
      # 使用find的-exec命令而不是管道，避免子shell问题
  
  
  
      find "$nginx_home/conf/conf.d" -name "*.conf" -type f -exec sed -i 's|listen 80;|listen 8080;|g' {} \;
  
  
  
      find "$nginx_home/conf/conf.d" -name "*.conf" -type f -exec sed -i 's|listen 899;|listen 8999;|g' {} \;
  
  
  
    # 执行黑名单脚本（如果存在）
  
    if [ -f "$nginx_home/bin/ngx-black-ip.sh" ]; then
  
      $nginx_home/bin/ngx-black-ip.sh
  
    fi
  
  [ $ps_count -gt 0 ] && log "nginx已经启动" && exit 0
  
  # 测试配置文件
  log "测试nginx配置文件..."
  if ! config_output=$("$nginx_home/sbin/nginx" -c "$nginx_home/conf/nginx.conf" -t 2>&1); then
    echo "配置测试失败，错误信息："
    echo "$config_output"
    error "Nginx配置测试失败，请检查配置文件"
  fi
  echo "配置测试输出：$config_output"
  
  log "Nginx配置测试通过，开始启动nginx..."
  # 启动nginx并捕获错误
  if ! nginx_output=$("$nginx_home/sbin/nginx" -c "$nginx_home/conf/nginx.conf" 2>&1); then
    echo "Nginx启动失败，错误信息："
    echo "$nginx_output"
    # 尝试查看错误日志
    if [ -f "$nginx_home/logs/error.log" ]; then
      echo "错误日志内容："
      tail -20 "$nginx_home/logs/error.log"
    fi
    error "Nginx: 启动失败"
  fi
  
  echo "Nginx启动输出：$nginx_output"
  
  log "Nginx: 启动成功"
  
  # 等待一下让进程启动
  sleep 1
  
  # 检查Nginx进程
  nginx_ps=$(ps -ef | grep nginx | grep -v grep)
  if [ -n "$nginx_ps" ]; then
    log "Nginx进程信息："
    echo "$nginx_ps"
  else
    log "警告: 未找到nginx进程，可能启动失败"
    # 尝试查看错误日志
    if [ -f "$nginx_home/logs/error.log" ]; then
      log "错误日志最后10行："
      tail -10 "$nginx_home/logs/error.log"
    fi
  fi
}

# 从配置文件中提取 web root 路径
extract_web_root_from_conf() {
  local conf_dir="$1"
  local base_dir="$2"
  # 确保配置目录存在
  if [ ! -d "$conf_dir" ]; then
    mkdir -p "$conf_dir"
    return
  fi
  
    # 提取所有 root 和 alias 路径
  local conf_files=("$conf_dir"/*.conf)
  if [ -f "${conf_files[0]}" ]; then
    # 使用grep的输出到临时文件来避免管道问题
    local temp_grep_output="/tmp/nginx_conf_grep_$$"
    grep -Eh '^[\s]*(root|alias) ' "$conf_dir"/*.conf 2>/dev/null | awk '{print $2}' | tr -d ';' | sort -u > "$temp_grep_output" || true
    while IFS= read -r path; do
      if [ -n "$path" ]; then  # 确保路径不为空
        if [[ "$path" == /* ]]; then
          echo "$path"
        else
          echo "$base_dir/$path"
        fi
      fi
    done < "$temp_grep_output"
    rm -f "$temp_grep_output" || true
  fi
}

# 获取所有 web 根目录
web_roots=$(extract_web_root_from_conf "$nginx_home/conf/conf.d" "$nginx_home")

# 创建目录并设置权限
for web_root in $web_roots; do
  if [ ! -d "$web_root" ]; then
    log "创建 web 根目录: $web_root"
    # 使用智能执行函数处理目录创建
    local web_root_parent=$(dirname "$web_root")
    if smart_exec "mkdir -p '$web_root'" "$web_root_parent"; then
        log "成功创建 web 根目录: $web_root"
    else
        log "无法创建 web 根目录: $web_root"
    fi

    if [ "$OS_TYPE" != "macos" ]; then
        # 使用智能执行函数修改所有者
        smart_exec "chown -R '$usr:$group' '$web_root'" "$web_root" 2>/dev/null || \
            log "无法修改 web 根目录所有者: $web_root"
    fi

    # 使用智能执行函数修改目录权限
    smart_exec "chmod -R 755 '$web_root'" "$web_root" 2>/dev/null || \
        log "无法修改 web 目录权限: $web_root"

    # 创建默认index.html文件
    if ! echo "<h1>Welcome to Nginx</h1>" > "$web_root/index.html" 2>/dev/null; then
        # 如果普通方式失败，使用智能权限执行
        echo "<h1>Welcome to Nginx</h1>" | smart_exec "tee '$web_root/index.html'" "$web_root" > /dev/null
    fi
  else
    log "web 根目录已存在: $web_root"
    if [ "$OS_TYPE" != "macos" ]; then
        # 使用智能执行函数修改所有者
        smart_exec "chown -R '$usr:$group' '$web_root'" "$web_root" 2>/dev/null || \
            log "无法修改 web 根目录所有者: $web_root"
    fi

    # 使用智能执行函数修改目录权限
    smart_exec "chmod -R 755 '$web_root'" "$web_root" 2>/dev/null || \
        log "无法修改 web 目录权限: $web_root"
  fi
done

# 检测并创建上传目录
setup_upload_directories() {
  local conf_dir="$1"
  local usr="$2"
  local group="$3"
  local os_type="$4"

  log "检测配置文件中的上传目录配置..."

  # 在所有配置文件中搜索上传目录配置
  if find "$conf_dir" -name "*.conf" -type f -exec grep -l "location /uploads/" {} \; >/dev/null 2>&1; then
    log "检测到上传目录配置"

    # 动态获取当前用户的主目录
    local user_home=$(eval echo ~$usr)
    local upload_dir="$user_home/uploads"

    log "创建上传目录: $upload_dir"
    # 如果无法创建在用户目录下，则在nginx目录下创建
    local upload_dir_parent=$(dirname "$upload_dir")
    if ! smart_exec "mkdir -p '$upload_dir'" "$upload_dir_parent" 2>/dev/null; then
        upload_dir="$nginx_home/uploads"
        log "在用户目录创建失败，尝试在nginx目录: $upload_dir"
        upload_dir_parent=$(dirname "$upload_dir")
        smart_exec "mkdir -p '$upload_dir'" "$upload_dir_parent" 2>/dev/null || \
            log "无法创建上传目录: $upload_dir"
    fi

    if [ "$os_type" != "macos" ]; then
        # 使用智能执行函数修改所有者
        smart_exec "chown -R '$usr:$group' '$upload_dir'" "$upload_dir" 2>/dev/null || \
            log "无法修改上传目录所有者: $upload_dir"
    fi

    # 使用智能执行函数修改目录权限
    smart_exec "chmod -R 755 '$upload_dir'" "$upload_dir" 2>/dev/null || \
        log "无法修改上传目录权限: $upload_dir"
    log "上传目录创建完成: $upload_dir"
  else
    log "未检测到上传目录配置，跳过上传目录创建"
  fi
}

# 检测并创建上传目录
setup_upload_directories "$nginx_home/conf/conf.d" "$usr" "$group" "$OS_TYPE"

# 开放服务器防火墙80端口给外界
# 动态安装依赖
install_dependencies() {
  local packages="$1"
  local package_name="$2"

  # 用户模式下跳过系统级依赖安装
  if [ "$user_mode" = "true" ]; then
    echo "用户模式: 跳过系统级依赖安装"
    echo "请确保已安装以下依赖: PCRE库、OpenSSL开发库、zlib开发库等"
    echo "例如在Debian/Ubuntu系统: sudo apt-get install libpcre3-dev libssl-dev zlib1g-dev"
    echo "例如在CentOS/RHEL系统: sudo yum install pcre-devel openssl-devel zlib-devel"
    return 0
  fi

  if [ -n "$PKG_INSTALLER" ]; then
    echo "安装 $package_name..."

    # 更新包管理器缓存（仅Linux）
    if [ "$OS_TYPE" != "macos" ] && [ -n "$PKG_UPDATE" ]; then
      echo "更新包管理器缓存..."
      smart_exec "$PKG_UPDATE" "/var/lib/apt" true
    fi

    # 安装依赖包 - 包管理器操作通常需要root权限
    smart_exec "$PKG_INSTALLER $packages" "/usr/local" true || {
      echo "✗ 安装 $package_name 失败"
      return 1
    }
    echo "✓ 成功安装 $package_name"
  else
    echo "警告: 未找到支持的包管理器，跳过依赖安装"
    echo "请手动安装依赖: PCRE库、OpenSSL开发库、zlib开发库等"
    echo "例如在Debian/Ubuntu系统: sudo apt-get install libpcre3-dev libssl-dev zlib1g-dev"
    echo "例如在CentOS/RHEL系统: sudo yum install pcre-devel openssl-devel zlib-devel"
    # 不退出，继续执行，用户可以手动安装依赖
  fi
}

# 验证必需的库是否存在
validate_dependencies() {
  log "验证必需的依赖库..."

  # 检查PCRE库
  local pcre_found=0
  if command -v pcre-config > /dev/null 2>&1; then
      log "找到 pcre-config: $(command -v pcre-config)"
      pcre_found=1
  fi
  if [ -f "/usr/include/pcre.h" ]; then
      log "找到 /usr/include/pcre.h"
      pcre_found=1
  fi
  if [ -f "/usr/include/pcre/pcre.h" ]; then
      log "找到 /usr/include/pcre/pcre.h"
      pcre_found=1
  fi
  if [ -f "/usr/include/pcre2/pcre2.h" ]; then
      log "找到 /usr/include/pcre2/pcre2.h"
      pcre_found=1
  fi

  if [ $pcre_found -eq 0 ]; then
    error "错误: PCRE库未正确安装，Nginx配置需要此库"
  else
    log "✓ PCRE库已找到"
  fi

  # 检查OpenSSL库
  local ssl_found=0
  if [ -d "/usr/include/openssl" ]; then
      log "找到 OpenSSL 开发库: /usr/include/openssl"
      ssl_found=1
  fi
  if [ -d "/usr/local/include/openssl" ]; then
      log "找到 OpenSSL 开发库: /usr/local/include/openssl"
      ssl_found=1
  fi
  if [ -d "/opt/homebrew/include/openssl" ]; then
      log "找到 OpenSSL 开发库: /opt/homebrew/include/openssl"
      ssl_found=1
  fi

  if [ $ssl_found -eq 0 ]; then
      log "警告: OpenSSL开发库可能未正确安装"
  else
      log "✓ OpenSSL开发库已找到"
  fi

  # 检查zlib库
  local zlib_found=0
  if [ -f "/usr/include/zlib.h" ]; then
      log "找到 zlib.h: /usr/include/zlib.h"
      zlib_found=1
  fi
  if [ -f "/usr/local/include/zlib.h" ]; then
      log "找到 zlib.h: /usr/local/include/zlib.h"
      zlib_found=1
  fi

  if [ $zlib_found -eq 0 ]; then
      log "警告: zlib库可能未正确安装"
  else
      log "✓ zlib库已找到"
  fi

  log "依赖验证完成"
}

open_firewalld_port () {
  # 用户模式下跳过防火墙配置
  if [ "$user_mode" = "true" ]; then
    echo "用户模式: 跳过防火墙配置"
    echo "如需开放80端口，请手动执行:"
    echo "  sudo firewall-cmd --permanent --add-port=80/tcp && sudo firewall-cmd --reload"
    echo "或"
    echo "  sudo ufw allow 80/tcp && sudo ufw reload"
    return 0
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    # macOS防火墙配置
    if command -v /usr/libexec/ApplicationFirewall/socketfilterfw > /dev/null 2>&1; then
      echo "macOS防火墙配置：请手动在系统偏好设置 > 安全性与隐私 > 防火墙中添加nginx端口80的例外"
    fi
  else
    # Linux防火墙配置
    if command -v firewall-cmd > /dev/null 2>&1; then
      if firewall-cmd --state | grep 'running' > /dev/null 2>&1; then
        smart_exec "firewall-cmd --permanent --add-port=80/tcp" "/etc" true
        smart_exec "firewall-cmd --reload" "/etc" true
        echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
      fi
    elif command -v ufw > /dev/null 2>&1; then
      smart_exec "ufw allow 80/tcp" "/etc" true
      smart_exec "ufw reload" "/etc" true
      echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
    fi
  fi
}

# 添加自启动脚本
add_systemd_service() {
  # 用户模式下跳过系统服务配置
  if [ "$user_mode" = "true" ]; then
    echo "用户模式: 跳过系统服务配置"
    echo "如需配置自启动服务，请手动执行:"
    echo "  sudo systemctl enable nginx"
    echo "  sudo systemctl start nginx"
    return 0
  fi

  if [ "$OS_TYPE" = "linux" ]; then
    local service_content=$(cat <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=$nginx_home/sbin/nginx -t -c $nginx_home/conf/nginx.conf
ExecStart=$nginx_home/sbin/nginx -c $nginx_home/conf/nginx.conf
ExecReload=$nginx_home/sbin/nginx -s reload
ExecStop=$nginx_home/sbin/nginx -s stop
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
)
    smart_exec "echo '$service_content' > /usr/lib/systemd/system/nginx.service" "/usr/lib/systemd/system" true
    smart_exec "systemctl daemon-reload" "/etc" true
    smart_exec "systemctl enable nginx" "/etc" true
    smart_exec "systemctl start nginx" "/etc" true
  elif [ "$OS_TYPE" = "macos" ]; then
    echo "macOS下不安装自启动服务"
  fi
}

log "开始检测操作系统..."
detect_os
log "开始检查环境..."
check
log "开始安装nginx..."
install_nginx
log "添加systemd服务..."
add_systemd_service
log "配置防火墙..."
open_firewalld_port

#log "使用startup.sh启动nginx..."
if [ -f "$nginx_home/bin/startup.sh" ]; then
  chmod +x "$nginx_home/bin/startup.sh"
  cd "$nginx_home/bin"
  if ./startup.sh; then
    log "nginx启动成功！"
    log "访问地址: http://$(get_script_ip):8080"
    log "管理命令:"
    log "  停止: $nginx_home/bin/stop.sh"
    log "  重启: $nginx_home/bin/startup.sh"
    log "  重载: $nginx_home/sbin/nginx -s reload -c $nginx_home/conf/nginx.conf"
  else
    log "nginx启动失败，请手动执行: $nginx_home/bin/startup.sh"
  fi
else
  log "未找到startup.sh脚本，请手动启动nginx"
fi

log "安装完成！"

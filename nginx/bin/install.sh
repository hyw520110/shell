#!/bin/bash
# nginx自动安装、配置

# 支持参数指定安装目录和用户
nginx_home=${1:-/opt/nginx}
usr=${2:-www-data}
group=${usr}
url=http://nginx.org/download/nginx-1.29.0.tar.gz
# nginx压缩文件名
gz_file_name=${url##*/}
#解压临时目录
tmp_dir=/tmp/${gz_file_name%%.tar*}
gz_file=$tmp_dir/$gz_file_name
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

# 全局变量定义
PKG_INSTALLER=""
PKG_UPDATE=""
PKG_PREFIX=""

# 检测操作系统类型和包管理器
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get > /dev/null 2>&1; then
            PKG_INSTALLER="apt-get install -y"
            PKG_UPDATE="apt-get update"
        elif command -v yum > /dev/null 2>&1; then
            PKG_INSTALLER="yum -y install"
        fi
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        PKG_INSTALLER="brew install"
        PKG_UPDATE="brew update"
        echo "macos"
    else
        echo "unknown"
    fi
}

# 通用文件操作权限检查
ensure_write_permission() {
    local path="$1"
    local path_type="$2"
    
    if [ ! -w "$path" ]; then
        echo "$path_type $path 无写权限，正在修复..."
        if [ "$OS_TYPE" = "macos" ]; then
            sudo chown $(whoami):staff "$path"
        else
            sudo chown ${usr}:${group} "$path"
        fi
        echo "✓ 已修复 $path_type 权限: $path"
    fi
}

# 通用目录创建函数，自动处理权限（简化版）
create_dir_with_permission() {
    local dir_path
    for dir_path in "$@"; do
        if [ ! -d "$dir_path" ]; then
            echo "创建目录: $dir_path"
            
            # 尝试直接创建目录
            if mkdir -p "$dir_path" 2>/dev/null; then
                echo "✓ 成功创建目录: $dir_path"
            else
                # 无权限，尝试使用sudo
                echo "需要sudo权限创建目录: $dir_path"
                if sudo mkdir -p "$dir_path" 2>/dev/null; then
                    echo "✓ 使用sudo成功创建目录: $dir_path"
                else
                    echo "✗ 无法创建目录 $dir_path，即使有sudo权限"
                    return 1
                fi
            fi
        fi
        ensure_write_permission "$dir_path" "目录"
    done
}

usage(){
	echo "用法: $1 [安装目录] [安装用户]"
    echo "示例: $1 $nginx_home $usr"
}
OS_TYPE=$(detect_os)

# 检查是否是root用户,不是则退出程序；检查是否有wget应用,没有则帮其装上
check () {
  # 检查root权限 - macOS不需要root，Linux需要
  if [ "$OS_TYPE" != "macos" ] && [ "$(id -u)" != "0" ]; then
    echo "请使用sudo或root权限运行本脚本！"
    usage "sudo $0"
    exit 1
  elif [ "$OS_TYPE" = "macos" ] && [ "$(id -u)" = "0" ]; then
    echo "macOS下请不要使用root权限运行，Homebrew不允许root运行"
    usage "$0"
    exit 1
  fi
  #检查nginx是否已经安装，已安装检测配置是否正确，配置正确就启动nginx
  if [ -f $nginx_home/sbin/nginx ];then
    start_nginx && exit 0
  fi
  #未安装执行安装前的检查
  if [ "$OS_TYPE" != "macos" ]; then
  	# 检测添加用户
    if ! id -u $usr > /dev/null 2>&1; then
      useradd -M -s /sbin/nologin $usr
    fi
    if ! getent group $group > /dev/null 2>&1; then
      groupadd $group
    fi
    sed -i "s#^user .*;#user $usr;#" $BASE_DIR/conf/nginx.conf
  else
  	# macOS下注释掉user配置，使用当前用户
    sed -i '' 's/^user/#user/' $BASE_DIR/conf/nginx.conf 2>/dev/null || sed -i.bak 's/^user/#user/' $BASE_DIR/conf/nginx.conf  
  fi

  # 动态安装依赖
  install_dependencies() {
    local packages="$1"
    local package_name="$2"
    
    if [ -n "$PKG_INSTALLER" ]; then
      echo "安装 $package_name..."
      
      # 更新包管理器缓存（仅Linux）
      if [ "$OS_TYPE" != "macos" ] && [ -n "$PKG_UPDATE" ]; then
        eval "$PKG_UPDATE"
      fi
      
      # 安装依赖包
      eval "$PKG_INSTALLER $packages" || {
        echo "✗ 安装 $package_name 失败"
        return 1
      }
      echo "✓ 成功安装 $package_name"
    else
      echo "✗ 未找到支持的包管理器"
      return 1
    fi
  }

  # 根据操作系统安装依赖
  if [ "$OS_TYPE" = "linux" ]; then
    # Linux依赖
    if command -v apt-get > /dev/null 2>&1; then
      install_dependencies "wget build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev libgeoip-dev libperl-dev" "Linux编译依赖"
    elif command -v yum > /dev/null 2>&1; then
      install_dependencies "wget epel-release gcc pcre pcre-devel zlib zlib-devel openssl openssl-devel geoip-devel perl-ExtUtils-Embed" "Linux编译依赖"
    fi
  elif [ "$OS_TYPE" = "macos" ]; then
    # macOS依赖
    install_dependencies "wget pcre openssl zlib perl" "macOS编译依赖"
  fi
}

# 下载、解压nginx
download_nginx () {
  # 使用通用函数批量创建目录
  create_dir_with_permission "$nginx_home" "$tmp_dir"
  if [ ! -f $gz_file ];then
    echo "wget $url -O $gz_file"
    wget $url -O $gz_file
  fi
  echo "tar -zxf $gz_file -C ${tmp_dir%/*}/" && tar -zxf $gz_file -C ${tmp_dir%/*}/
}

# 安装nginx
install_nginx () {
  download_nginx
  [ -d $tmp_dir ] && cd $tmp_dir
  err_log=$(grep error_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';')
  access_log=$(grep access_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';')
  pid_dir=$(grep pid $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';'|xargs dirname)
  log_dir=${access_log%/*}
  echo "pid_dir:$pid_dir"
  # 保持使用系统日志目录，处理权限问题
  echo "正在创建系统日志目录..."
  create_dir_with_permission "$log_dir" "$pid_dir"
  
  # 确保日志文件存在
  [ ! -f "$err_log" ] && sudo touch "$err_log" 2>/dev/null || true
  [ ! -f "$access_log" ] && sudo touch "$access_log" 2>/dev/null || true
  
  # 设置系统目录权限
  echo "正在设置系统目录权限..."
  if [ "$OS_TYPE" != "macos" ]; then
    sudo chown -R ${usr}:${group} "${log_dir}" "${pid_dir}" 2>/dev/null || true
  else
    # macOS下使用当前用户权限
    sudo chown -R $(whoami):admin "${log_dir}" "${pid_dir}" 2>/dev/null || true
  fi
  
  # 确保nginx有权限写入
  sudo chmod 755 "${log_dir}" "${pid_dir}" 2>/dev/null || true
  # 根据操作系统调整configure参数
  if [ "$OS_TYPE" = "macos" ]; then
    # macOS不支持file-aio和GeoIP，移除相关参数
    configure_command="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=/var/run/nginx.pid --with-threads --with-http_stub_status_module --with-compat --with-debug --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_perl_module=dynamic --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module"
  else
    # Linux支持所有参数
    configure_command="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=/var/run/nginx.pid --with-threads --with-http_stub_status_module --with-compat --with-debug --with-file-aio --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_perl_module=dynamic --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module --with-http_geoip_module=dynamic"
  fi
  echo $configure_command
  if $configure_command; then
    echo "nginx: 配置成功"
    if make && make install; then
       #首次安装make install；升级执行make upgrade
       echo "nginx: 安装成功"
       cd /tmp  # 先切换到安全目录，避免后续删除当前目录导致 getcwd 报错
       rm -rf $tmp_dir
    else
       echo "nginx: 编译失败"
       make clean
       exit 1
    fi
  else
    echo "nginx: 配置失败"
    exit 1
  fi
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
  if ! cp -r $BASE_DIR/conf $nginx_home/; then
    echo "✗ 复制配置文件失败"
    return 1
  fi
  echo "✓ 配置文件复制成功"
  
  ensure_write_permission "$nginx_home/bin" "nginx脚本目录权限"
  # 强制拷贝脚本文件
  if ! cp -rf $BASE_DIR/bin/*.sh $nginx_home/bin/; then
    echo "✗ 复制脚本文件失败"
    return 1
  fi
  chmod +x $nginx_home/bin/*.sh
  echo "✓ 脚本文件复制成功"
  
  # 使用rsync同步配置文件，保留模板文件
  if command -v rsync >/dev/null 2>&1; then
    echo "正在同步配置文件到 $nginx_home/conf/..."
    rsync -a --quiet --exclude='*.template' "$BASE_DIR/conf/" "$nginx_home/conf/"
    echo "✓ 配置文件已同步"
  else
    echo "正在拷贝配置文件到 $nginx_home/conf/..."
    cp -r "$BASE_DIR/conf"/* "$nginx_home/conf/"
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
  
  # 配置文件IP替换
  replace_ip_in_configs() {
    local conf_dir="$1"
    local current_ip=$(get_script_ip)
    
    echo "替换配置文件中的IP地址..."
    
    # 查找所有配置文件（排除模板文件）
    find "$conf_dir" -name "*.conf" -type f ! -name "*.template" | while read -r conf_file; do
      # 只替换包含占位符的配置文件
      if grep -q "{{SERVER_IP}}" "$conf_file" 2>/dev/null; then
        sed -i.bak "s/{{SERVER_IP}}/$current_ip/g" "$conf_file"
        echo "已替换配置文件中的占位符: $conf_file"
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
  $nginx_home/bin/ngx-black-ip.sh
  [ $ps_count -gt 0 ] && echo "nginx已经启动" && exit 0
  "$nginx_home/sbin/nginx" -c "$nginx_home/conf/nginx.conf" -t && echo "start nginx..."
  if "$nginx_home/sbin/nginx" -c "$nginx_home/conf/nginx.conf"; then
    echo "Nginx: 启动成功"
    # 访问80端口，查看是否是nginx页面
    ps -ef | grep nginx
  else
    echo "Nginx: 启动失败"
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
  if ls "$conf_dir"/*.conf 1> /dev/null 2>&1; then
    grep -Eh '^[\s]*(root|alias) ' "$conf_dir"/*.conf 2>/dev/null | awk '{print $2}' | tr -d ';' | sort -u | while read path; do
      if [[ "$path" == /* ]]; then
        echo "$path"
      else
        echo "$base_dir/$path"
      fi
    done
  fi
}

# 获取所有 web 根目录
web_roots=$(extract_web_root_from_conf "$nginx_home/conf/conf.d" "$nginx_home")

# 创建目录并设置权限
for web_root in $web_roots; do
  if [ ! -d "$web_root" ]; then
    echo "创建 web 根目录: $web_root"
    mkdir -p "$web_root"
    if [ "$OS_TYPE" != "macos" ]; then
      chown -R $usr:$group "$web_root"
    fi
    chmod -R 755 "$web_root"
    echo "<h1>Welcome to Nginx</h1>" > "$web_root/index.html"
  else
    echo "web 根目录已存在: $web_root"
    if [ "$OS_TYPE" != "macos" ]; then
      chown -R $usr:$group "$web_root" || true
    fi
    chmod -R 755 "$web_root" || true
  fi
done

# 检测并创建上传目录
setup_upload_directories() {
  local conf_dir="$1"
  local usr="$2"
  local group="$3"
  local os_type="$4"
  
  echo "检测配置文件中的上传目录配置..."
  
  # 在所有配置文件中搜索上传目录配置
  if find "$conf_dir" -name "*.conf" -type f -exec grep -l "location /uploads/" {} \; >/dev/null 2>&1; then
    echo "检测到上传目录配置"
    
    # 动态获取当前用户的主目录
    local user_home=$(eval echo ~$usr)
    local upload_dir="$user_home/uploads"
    
    echo "创建上传目录: $upload_dir"
    mkdir -p "$upload_dir"
    if [ "$os_type" != "macos" ]; then
      chown -R $usr:$group "$upload_dir"
    fi
    chmod -R 755 "$upload_dir"
    echo "上传目录创建完成: $upload_dir"
  else
    echo "未检测到上传目录配置，跳过上传目录创建"
  fi
}

# 检测并创建上传目录
setup_upload_directories "$nginx_home/conf/conf.d" "$usr" "$group" "$OS_TYPE"

# 开放服务器防火墙80端口给外界
open_firewalld_port () {
  if [ "$OS_TYPE" = "macos" ]; then
    # macOS防火墙配置
    if command -v /usr/libexec/ApplicationFirewall/socketfilterfw > /dev/null 2>&1; then
      echo "macOS防火墙配置：请手动在系统偏好设置 > 安全性与隐私 > 防火墙中添加nginx端口80的例外"
    fi
  else
    # Linux防火墙配置
    if command -v firewall-cmd > /dev/null 2>&1; then
      if firewall-cmd --state | grep 'running' > /dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --reload
        echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
      fi
    elif command -v ufw > /dev/null 2>&1; then
      ufw allow 80/tcp
      ufw reload
      echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
    fi
  fi
}

# 添加自启动脚本
add_systemd_service() {
  if [ "$OS_TYPE" = "linux" ]; then
    cat <<EOF >/usr/lib/systemd/system/nginx.service
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

    systemctl daemon-reload
    systemctl enable nginx
    systemctl start nginx
  elif [ "$OS_TYPE" = "macos" ]; then
    echo "macOS下不安装自启动服务"
  fi
}

check
install_nginx
start_nginx
add_systemd_service
open_firewalld_port

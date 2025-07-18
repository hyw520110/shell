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

# 检查是否是root用户,不是则退出程序；检查是否有wget应用,没有则帮其装上
check () {
  # 检查root权限
  if [ "$(id -u)" != "0" ]; then
    echo "请使用sudo或root权限运行本脚本！"
    echo "用法: sudo $0 [安装目录] [安装用户]"
    echo "示例: sudo $0 /opt/nginx nginxuser"
    exit 1
  fi
  #检查nginx是否已经安装，已安装检测配置是否正确，配置正确就启动nginx
  if [ -f $nginx_home/sbin/nginx ];then
    start_nginx && exit 0
  fi
  #未安装执行安装前的检查
  # 检查用户和组
  if ! id -u $usr > /dev/null 2>&1; then
    useradd -M -s /sbin/nologin $usr
  fi
  if ! getent group $group > /dev/null 2>&1; then
    groupadd $group
  fi
  # 检测并修改配置文件用户配置
  if [ "`grep '^user ' $BASE_DIR/conf/nginx.conf | awk '{print $2}'`" != "${usr};" ]; then
    sed -i "s#^user .*;#user $usr;#" $BASE_DIR/conf/nginx.conf
  fi
  if [ ! -e /usr/bin/wget ]; then
    # 检查包管理器
    if command -v apt-get > /dev/null 2>&1; then
      apt-get update
      apt-get install -y wget build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev libgeoip-dev
    elif command -v yum > /dev/null 2>&1; then
      yum -y install wget epel-release gcc pcre pcre-devel zlib zlib-devel openssl openssl-devel geoip-devel
    else
      echo "未知的包管理器，无法继续"
      exit 1
    fi
  else
    # 即使wget已装，也要确保PCRE、GeoIP等依赖已装
    if command -v apt-get > /dev/null 2>&1; then
      apt-get update
      apt-get install -y build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev libgeoip-dev
    elif command -v yum > /dev/null 2>&1; then
      yum -y install gcc pcre pcre-devel zlib zlib-devel openssl openssl-devel geoip-devel
    fi
  fi

  # 安装 Perl 开发库
  if command -v apt-get > /dev/null 2>&1; then
    apt-get update && apt-get install -y libperl-dev
  elif command -v yum > /dev/null 2>&1; then
    yum -y install perl-ExtUtils-Embed
  else
    echo "未知的包管理器，无法安装Perl开发库"
    exit 1
  fi
}

# 下载、解压nginx
download_nginx () {
  if [ ! -d ${nginx_home} ]; then
    mkdir -p ${nginx_home}
  fi
  # 解压临时目录
  echo "tmp:$tmp_dir"
  if [ ! -d $tmp_dir ];then
    mkdir -p $tmp_dir
  fi
  [ ! -d ${gz_file%/*} ] && mkdir ${gz_file%/*}
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
  err_log=$(grep error_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';'
)
  access_log=$(grep access_log $BASE_DIR/conf/nginx.conf | awk '{print $2}' | tr -d ';'
)
  log_dir=${access_log%/*}
  [ ! -d $log_dir ] && mkdir -p $log_dir && touch $err_log $access_log
  # 设置日志目录权限
  echo "chown -R ${usr}:${group} ${log_dir}" && chown -R ${usr}:${group} ${log_dir}
  configure_command="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=$log_dir/nginx.pid --with-threads --with-http_stub_status_module --with-compat --with-debug --with-file-aio --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_perl_module=dynamic --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module --with-http_geoip_module=dynamic"
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
  # 将nginx设为全局命令
  [ ! -f /usr/bin/nginx ] && ln -s $nginx_home/sbin/nginx /usr/bin/nginx
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

  # 拷贝bin和conf目录到安装目录
  if [ ! -d $nginx_home/conf/conf.d ]; then
    mkdir -p $nginx_home/conf/conf.d
  fi
  cp -r $BASE_DIR/conf $nginx_home/
  # 强制拷贝脚本文件
  cp -rf $BASE_DIR/bin/*.sh $nginx_home/bin/
  # 只有当配置文件不存在时才拷贝
  for conf_file in $BASE_DIR/conf/conf.d/*; do
    filename=$(basename $conf_file)
    if [ ! -f $nginx_home/conf/conf.d/$filename ]; then
      # 检查是否存在模板文件
      if [ -f $conf_file.template ]; then
        SERVER_IP=$(get_script_ip)
        echo "使用IP $SERVER_IP 替换配置文件中的 {{SERVER_IP}} 占位符。"
        sed "s/{{SERVER_IP}}/$SERVER_IP/g" $conf_file.template > $nginx_home/conf/conf.d/$filename
      else
        cp $conf_file $nginx_home/conf/conf.d/
      fi
      echo "配置文件 $filename 已拷贝至安装目录。"
    fi
  done
  $nginx_home/bin/ngx-black-ip.sh
  [ $ps_count -gt 0 ] && echo "nginx已经启动" && exit 0
  nginx -c $nginx_home/conf/nginx.conf -t && echo "start nginx..."
  if $nginx_home/sbin/nginx -c $nginx_home/conf/nginx.conf; then
    echo "Nginx: 启动成功"
    # 访问80端口，查看是否是nginx页面
    ps -ef | grep nginx
  else
    echo "Nginx: 启动失败"
  fi
}

# 开放服务器防火墙80端口给外界
open_firewalld_port () {
  if command -v firewall-cmd > /dev/null 2>&1; then
    if firewall-cmd --state | grep 'running' > /dev/null 2>&1; then
      firewall-cmd --permanent --add-port=80/tcp
      firewall-cmd --reload
      echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
    else
      echo '防火墙未运行，80端口可能未开放'
    fi
  elif command -v ufw > /dev/null 2>&1; then
    ufw allow 80/tcp
    ufw reload
    echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
  else
    echo '未找到防火墙管理工具，80端口可能未开放'
  fi
}

# 添加自启动脚本
add_systemd_service() {
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
}

check
install_nginx
add_systemd_service
start_nginx
open_firewalld_port

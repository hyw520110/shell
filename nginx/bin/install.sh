#!/bin/bash
# nginx自动安装、配置

usr=nginx
group=nginx

url=http://nginx.org/download/nginx-1.23.1.tar.gz
# nginx压缩文件名
gz_file_name=${url##*/}
gz_file=/opt/softs/$gz_file_name
#解压临时目录
tmp_dir=/tmp/${gz_file_name%%.tar*}


CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
#nginx安装目录默认为当前目录父目录
nginx_home=$BASE_DIR

# 检查是否是root用户,不是则退出程序；检查是否有wget应用,没有则帮其装上
check () {
  #检查nginx是否已经安装，已安装检测配置是否正确，配置正确就启动nginx  
  if [ -f $nginx_home/sbin/nginx ];then
    start_nginx &&  exit 0
  fi
  #未安装执行安装前的检查
  test $USER == 'root' || (echo '必须是root用户，请检查' ; exit 1)
  [ -e /usr/bin/wget ] || yum -y install wget &>/dev/null 
  usr_count=`grep "${usr}:" /etc/passwd|wc -l`
  group_count=`grep "${group}:" /etc/group|wc -l`
  #给nginx用户和组设置变量
  if [ $usr_count -ne 0 ] && [ $group_count -ne 0 ];then
    #判断nginx用户和组是否存在，不存在则创建
    echo "$usr用户$group组已存在"
  else
    useradd -M -s /sbin/nologin $usr
  fi
  #检测并修改配置文件用户配置
  [ "${usr};" != "`cat $BASE_DIR/conf/nginx.conf|grep "^user "|awk '{print $2}'`" ] && sed -i "s/^user .*;/user $usr;" $BASE_DIR/conf/nginx.conf
}

# 依赖安装
install_dependencies () {
  if ! ( yum -y install elinks gcc-* pcre-devel zlib zlib-devel openssl openssl-devel geoip-devel gd gd-devel perl-ExtUtils-Embed gperftools 1>/dev/null ); then
    echo "nginx相关的依赖安装失败，请检查"
    exit 1
  fi
#  [ -f /usr/share/GeoIP/GeoIP.dat_bak ] && mv /usr/share/GeoIP/GeoIP.dat /usr/share/GeoIP/GeoIP.dat_bak && wget -P /usr/share/GeoIP/ http://geolite.maxmind.com/download/geoip/database/GeoLiteCountry/GeoIP.dat.gz
}

# 下载、解压nginx
download_nginx () {
  if [ ! -d ${nginx_home} ]; then
    mkdir -p ${nginx_home}
  fi
  # 解压临时目录
  if [ ! -d $tmp_dir ];then
    [ ! -d ${gz_file%/*} ] && mkdir ${gz_file%/*}
    [ ! -f $gz_file ] && echo "$gz_file not found! download $url ..." && wget $url -o $gz_file
    [  -f $gz_file ] && echo "tar -zxf $gz_file -C ${tmp_dir%/*}/" && tar -zxf $gz_file -C ${tmp_dir%/*}/
  fi
  [ ! -d $tmp_dir ] && echo "$tmp_dir not exists!" && exit 1
}

# 安装nginx
install_nginx () {
  download_nginx
  [ -d $tmp_dir ] && cd $tmp_dir 
  err_log=`cat $BASE_DIR/conf/nginx.conf|grep error_log|awk '{print $2}'|tr -d "\n"`
  access_log=`cat $BASE_DIR/conf/nginx.conf|grep access_log|awk '{print $2}'`
  log_dir=${access_log%/*}
  [ ! -d $log_dir ] && mkdir -p $log_dir && touch $err_log $access_log
  # 设置日志目录权限
  echo "chown -R ${usr}:${group} ${log_dir}" && chown -R ${usr}:${group} ${log_dir}
  #echo "usr:$usr,group:$group,log_path:[${log_path}],err_log:[$err_log]"
  shell="./configure --prefix=${nginx_home} --user=$usr --group=$group --error-log-path=$err_log --http-log-path=$access_log --pid-path=$log_dir/nginx.pid --with-threads --with-http_stub_status_module  --with-compat --with-debug --with-file-aio --with-google_perftools_module --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_degradation_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_image_filter_module=dynamic --with-http_mp4_module --with-http_perl_module=dynamic --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module  --with-http_sub_module --with-http_v2_module --with-http_geoip_module=dynamic"
  echo $shell
  ng_conf=`exec $shell 1>/dev/null`
  if $ng_conf; then
    echo "nginx: 配置成功"
    #[ ! -d /etc/nginx/ ] && mkdir /etc/nginx/ 
    #[ ! -f /etc/nginx/mime.types ] && [ -f $nginx_home/conf/mime.types ] && ln -s $nginx_home/conf/mime.types /etc/nginx/mime.types
    if make && make install 1>/dev/null; then
       #首次安装make install；升级执行make upgrade
       echo "nginx: 安装成功"
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
 ps_count=`ps -ef|grep nginx|grep master|grep -v grep |wc -l`
 [ $ps_count -gt 0 ] && echo "nginx已经启动" && exit 0

 nginx -c $nginx_home/conf/nginx.conf -t && echo "start nginx..." 
 if $nginx_home/sbin/nginx -c $nginx_home/conf/nginx.conf ; then 
   echo "Nginx: 启动成功"
   # 访问80端口，查看是否是nginx页面
   ps -ef|grep nginx
   cd $BASE_DIR && $CURRENT_DIR/ngx-black-ip.sh
 else
   echo "Nginx: 启动失败"
 fi
}

# 开放服务器防火墙80端口给外界
open_firewalld_port () {
  echo -n "firewall state: "
  # 查看Linux防火墙是否开启，开启则开放80端口，否则不做处理
  if firewall-cmd --state | grep 'running' ; then
    firewall-cmd --permanent --add-port=80/tcp   
    firewall-cmd --reload
    echo '80端口已经开启，可通过浏览器进行访问服务器80端口'
  fi
}

check
install_dependencies
install_nginx
start_nginx
open_firewalld_port


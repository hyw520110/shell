#!/bin/bash

# mysql安装脚本

usr=mysql
usr_group=mysql
port=3306
# 修改密码输入超时
input_time=30
default_passwd=123456
# 默认mysql版本
version=${1:-8}
# 安装目录
base_dir=${2:-/opt}

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
log_dir=/var/log/mysql
tmp_dir=/tmp

if which rpm > /dev/null 2>&1 && which yum > /dev/null 2>&1; then
    if [ "$version" = "5" ]; then
      mysql_url=https://mirrors.aliyun.com/mysql/MySQL-5.7/mysql-5.7.36-el7-x86_64.tar.gz
    else
      mysql_url=https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.27-el7-x86_64.tar.gz
	fi
elif which apt > /dev/null 2>&1; then
    mysql_url=https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.28-linux-glibc2.17-x86_64-minimal.tar.xz
else
    echo "不支持的操作系统"
    exit 1
fi
gz_file_name=${mysql_url##*/}
gz_file=$tmp_dir/$gz_file_name
      
print() {
  echo "$(date +"%Y%m%d %H:%M:%S"): $1"
}

wfile() {
  [ -f $2 ] && [ ! -n "`grep \"$1\" $2`" ] && echo "$1" >> $2 && [ -n "$3" ] && exec $3
}

mkdirs() {
  for dir in "$@"; do
    if [ ! -d "$dir" ]; then
      echo "创建目录: $dir"
      mkdir -p "$dir"
    fi
  done
}


check_dns() {
    local domain=$1
    echo "检查域名解析: $domain"
    if ! nslookup $domain &> /dev/null; then
        echo "警告：无法解析域名 $domain，建议检查DNS配置"
        return 1
    fi
    return 0
}

safe_download() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0
    local domain=$(echo $url | awk -F[/:] '{for(i=1;i<=NF;i++) if($i ~ "com|org|cn") {print $i; exit}}')
    if [ -n "$domain" ]; then
        check_dns $domain || return 1
    fi
    while [ $retry -lt $max_retries ]; do
        echo "尝试下载: $url (尝试次数: $((retry+1)))"
        wget --tries=2 --timeout=10 -O "$output" "$url" && return 0 || {
            echo "下载失败: $url"
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                echo "等待5秒后重试..."
                sleep 5
            fi
        }
    done
    return 1
}

check_file_integrity() {
  local file=$1
  if ! tar -tf $file > /dev/null 2>&1; then
    print "文件 $file 损坏或不完整，删除并重新下载"
    rm -f $file
    return 1
  fi
  return 0
}


pre_check() {
  # 端口占用检测
  if [ "$(netstat -anp | grep $port | grep LISTEN | grep -v grep | wc -l)" -gt 0 ]; then
    echo "$port 端口已占用"
    netstat -anp | grep $port | grep LISTEN
    exit 0
  fi
  # 查找base_dir下mysqld文件，存在则提取安装目录
  mysqld_path=$(find "$base_dir" -type f -name mysqld 2>/dev/null | head -n 1)
  if [ -n "$mysqld_path" ]; then
    install_dir=$(dirname $(dirname "$mysqld_path"))
    data_dir="$install_dir/data"
    if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir")" ]; then
      [ ! -f $install_dir/bin/startup.sh ] && cp -r $SOURCE_DIR/{bin,conf} $install_dir/
      echo "mysql已安装未启动，开始启动..." &&  $install_dir/bin/startup.sh && exit 0
    fi
  fi
  # root权限检测
  if [ $(id -u) != "0" ]; then
      echo "使用root运行此脚本安装mysql!"
      echo "Usage: sudo $0 <version> [install_base_dir]"
      echo "支持版本: 5或8(默认)"
      exit 1
  fi
}

copy_files() {
  if [ "$SOURCE_DIR" != "$install_dir" ]; then
    echo "拷贝配置文件从 $SOURCE_DIR 到 $install_dir"
    mkdir -p $install_dir
    cp -r $SOURCE_DIR/{bin,conf} $install_dir/
    chown -R ${usr}:${usr_group} $install_dir
  fi

  # 动态替换my.cnf中的路径，日志目录始终为/var/log/mysql
  local cnf_file="$install_dir/conf/my.cnf"
  if [ -f "$cnf_file" ]; then
    # 先替换最长路径，防止部分路径被提前替换
    sed -i "s#datadir=.*#datadir=$data_dir#g" "$cnf_file"
    sed -i "s#basedir=.*#basedir=$install_dir#g" "$cnf_file"
    sed -i "s#log-error=.*#log-error=/var/log/mysql/error.log#g" "$cnf_file"
    sed -i "s#/opt/mysql/data#$data_dir#g" "$cnf_file"
    sed -i "s#/opt/mysql#$install_dir#g" "$cnf_file"
    sed -i "s#/opt/mysql/logs#/var/log/mysql#g" "$cnf_file"
    sed -i "s#${SOURCE_DIR}#$install_dir#g" "$cnf_file"
    sed -i "s#/home/dev/work/shell/mysql#$install_dir#g" "$cnf_file"
  fi
}

download_and_extract() {
  # 软件包不存在时下载
  if [ ! -f $gz_file ] || ! check_file_integrity $gz_file; then
    print "开始下载mysql安装包..."
    if ! safe_download "$mysql_url" "$gz_file"; then
      print "无法下载MySQL安装包，请检查网络连接或手动下载后放置在/opt/softs目录"
      exit 1
    fi
    if ! check_file_integrity $gz_file; then
      print "下载的文件损坏或不完整，安装失败"
      exit 1
    fi
  fi
  # 解压
  if [ -f $gz_file ]; then
    tar -xf $gz_file -C ${base_dir}
    if [ $? -ne 0 ]; then
      print "解压文件失败，删除并重新下载"
      rm -f $gz_file
      exit 1
    fi
    # 提取解压目录名
    extract_dir=$(tar -tf $gz_file | head -1 | cut -d/ -f1)
    install_dir=$base_dir/$extract_dir
    data_dir=$install_dir/data
  fi
}

install_dependencies() {
  print "开始检查 ..."
  if which rpm > /dev/null 2>&1 && which yum > /dev/null 2>&1; then
    [ `rpm -qa | grep -i libaio | grep -v grep | wc -l` -eq 0 ] && yum install -y libaio
  elif which apt > /dev/null 2>&1; then
    [ `dpkg -l | grep -i libaio1 | grep -v grep | wc -l` -eq 0 ] && apt-get update && apt-get install -y libaio1
    [ `dpkg -l | grep -i libncurses5 | grep -v grep | wc -l` -eq 0 ] && apt-get update && apt-get install libncurses5
  fi
}

setup_user_and_system() {
  if ! id -u $usr > /dev/null 2>&1; then
    useradd -M -s /sbin/nologin $usr
  fi
  if ! getent group $usr_group > /dev/null 2>&1; then
    groupadd $usr_group
  fi	
  limits=/etc/security/limits.conf
  wfile "mysql    soft    nproc    16384" $limits
  wfile "mysql    hard    nproc    16384" $limits
  wfile "mysql    soft    nofile    65536" $limits
  wfile "mysql    hard    nofile    65536" $limits
  wfile "mysql    soft    stack    1024000" $limits
  wfile "mysql    hard    stack    1024000" $limits
  wfile "vm.swappiness = 5" /etc/sysctl.conf "sysctl -p"
}

prepare_dirs() {
  # 清理旧的日志目录和数据目录
  if [ -d "$log_dir" ]; then
    print "清理旧的日志目录: $log_dir"
    rm -rf "$log_dir"
  fi
  mkdirs $log_dir $log_dir/binlog $log_dir/redolog $log_dir/undolog $install_dir
}

create_default_cnf() {
  cnf=$install_dir/conf/my.cnf
  if [ ! -f "$cnf" ]; then
    print "配置文件 $cnf 不存在，创建默认配置"
    mkdir -p $(dirname "$cnf")
    cat > "$cnf" << EOF
[mysqld]
port=3306
basedir=$install_dir
datadir=$data_dir
socket=/tmp/mysql.sock
log-error=$log_dir/error.log
pid-file=$install_dir/data/mysqld.pid
lower-case-table-names=1
explicit_defaults_for_timestamp=true

# 日志配置
log_bin=mysql-bin
binlog_format=mixed
server-id=1
EOF
  fi
  sed -i "s#datadir=.*#datadir=$data_dir#g" "$cnf"
  sed -i "s#log-error=.*#log-error=$log_dir/error.log#g" "$cnf"
  chown -R ${usr}:${usr_group} "$log_dir"
  mkdirs "$data_dir"
  chown -R ${usr}:${usr_group} "$base_dir/softs" "$install_dir" "$data_dir" "$log_dir"
  chmod -R 755 "$data_dir" "$log_dir"
}

initialize() {
  if [ "`ls -A $install_dir/data`" == "" ];then
    mkdir -p $install_dir/data
    chown -R ${usr}:${usr_group} $install_dir/data
    chmod -R 755 $install_dir/data
    shell="$install_dir/bin/mysqld  --initialize --user=$usr --basedir=$install_dir --datadir=$install_dir/data --console --lower-case-table-names=1 --explicit_defaults_for_timestamp=true"
    print "mysql初始化:$shell"
    eval $shell > $log_dir/init.log 2>&1
    if [ $? -ne 0 ]; then
      print "mysql初始化失败!错误日志:"
      cat $log_dir/init.log
      exit 1
    fi
    pass=$(grep "password" $log_dir/init.log| awk -F ': ' '{print $2}')
    echo -en "mysql临时密码:\033[31m $pass \033[0m \n"
    rm -rf $log_dir/init.log
    chown -R ${usr}:${usr_group} $log_dir
  fi
  chmod 644 $cnf
}

startup() {
  $install_dir/bin/startup.sh
  [ $? -gt 0 ] && print "启动失败，查看错误日志:$err_file" && exit 1
  ps -ef | grep mysql
}

setup_service() {
  if [ `ls /usr/lib/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ] && [ `ls /etc/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ]; then
    print "安装mysqld服务:/usr/lib/systemd/system/mysqld.service"
    cat >> /usr/lib/systemd/system/mysqld.service << EOF
[Unit]
Description=mysql service
[Service]
Type=forking
ExecStart=$install_dir/bin/startup.sh
ExecStop=$install_dir/bin/stop.sh
User=$usr
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mysqld.service
  fi
}

set_root_password_and_remote() {
  if [ -n "$pass" ];then
    read -t $input_time -p "输入新密码(超时时间$input_time 秒):" password
    [ ! -n "$password" ] && echo -en "\n密码输入超时, 默认密码:\033[31m $default_passwd \033[0m \n" && password="$default_passwd"
  fi
  if [ -n "$password" ]; then
    $install_dir/bin/mysql -uroot -p${pass} --connect-expired-password <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$password';
flush privileges;
exit
EOF
    pass=$password
    print "修改密码为:$pass"
  fi
  if [ -n "$pass" ];then
    # 检查MySQL版本
    mysql_version=$($install_dir/bin/mysql -uroot -p${pass} -e 'select version();' 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+')
    major_version=$(echo $mysql_version | cut -d. -f1)
    if [ "$major_version" = "8" ]; then
      # MySQL 8 远程授权
      $install_dir/bin/mysql -uroot -p${pass} <<EOF
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$pass';
ALTER USER 'root'@'%' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
exit
EOF
    else
      # MySQL 5 远程授权
      $install_dir/bin/mysql -uroot -p${pass} <<EOF
use mysql;
update user set host = '%' where user = 'root';
grant all privileges on *.* to 'root'@'%' with grant option;
flush privileges;
exit
EOF
    fi
  fi
}

main() {
  pre_check
  download_and_extract
  copy_files
  install_dependencies
  setup_user_and_system
  prepare_dirs
  create_default_cnf
  initialize
  startup
  setup_service
  sleep 3
  set_root_password_and_remote
  print "MySQL安装完成"
}

main "$@"

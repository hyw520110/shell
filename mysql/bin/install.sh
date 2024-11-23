#!/bin/bash
# mysql安装脚本
# 用户
usr=mysql
# 用户组
usr_group=mysql
# 日志目录 放在系统日志目录，方便整包打包拷贝，快速迁移到其他服务器
log_dir=/var/log/mysql
# 默认端口
port=3306
# 密码输入超时时间，修改默认随机密码，如超时未输入使用默认随机密码
input_time=10
# mysql下载地址
mysql5_centos_url=https://mirrors.aliyun.com/mysql/MySQL-5.7/mysql-5.7.36-el7-x86_64.tar.gz
mysql8_centos_url=https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.27-el7-x86_64.tar.gz
mysql8_debian_url=https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.27-linux-glibc2.17-x86_64-minimal.tar.xz

# 根据操作系统类型选择下载URL
if which rpm > /dev/null 2>&1 && which yum > /dev/null 2>&1; then
  url=$mysql8_centos_url
elif which apt > /dev/null 2>&1; then
  url=$mysql8_debian_url
else
  echo "Unsupported operating system"
  exit 1
fi

# 从url中提取压缩文件名
gz_file_name=${url##*/}
# 下载文件路径，文件名从下载url提取
gz_file=/opt/softs/$gz_file_name
# 解压临时目录
tmp_dir=/tmp/${gz_file_name%*.tar.*}

# 当前目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# 当前应用根目录
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
# 配置文件
cnf=$BASE_DIR/conf/my.cnf

# 检测是否安装：如已启动退出，如已安装(数据目录不为空)未启动则启动
# 3306端口被占用时 提示退出
[ `netstat -anp | grep $port | grep LISTEN | grep -v grep | wc -l` -gt 0 ] && print "port $port is already in use" && netstat -anp | grep $port | grep LISTEN && exit 0

# 数据目录不为空时，提示数据目录不为空后，执行启动脚本退出
[ -d $BASE_DIR/data ] && [ "`ls -A $BASE_DIR/data`" ] && echo "$BASE_DIR/data is not empty!" && $CURRENT_DIR/startup.sh && exit 0

# 检查安装用户是否是root
if [ $(id -u) != "0" ]; then
    echo "使用root运行此脚本安装mysql!"
    exit 1
fi
# 检查用户和组
if ! id -u $usr > /dev/null 2>&1; then
  useradd -M -s /sbin/nologin $usr
fi
if ! getent group $usr_group > /dev/null 2>&1; then
  groupadd $usr_group
fi
# 打印日志
function print(){
  echo "$(date +"%Y%m%d %H:%M:%S"):$1"
}
# 判断文本在文件中不存在时，写入文本到文件,参数1：文本；参数2：文件路径;参数3可选：执行命令,文本写入后的加载命令
function wfile {
 # 当文件存在时，查找文件内容是否存在，不存在时追加文本到文件中,如有加载命令则执行加载命令
 [ -f $2 ] && [ ! -n "`grep "$1" $2`" ] && echo "$1" >> $2 && [ -n "$3" ] && exec $3
}
# 目录不存在时创建目录
function mkdirs {
  for dir in "$@"; do
    if [ ! -d "$dir" ]; then
      echo "创建目录: $dir"
      mkdir -p "$dir"
    fi
  done
}
print "开始检查 ..."
# mysql如已安装提示退出,如需卸载执行:rpm -ev 包名,如卸载依赖报错，加参数--nodeps
if which rpm > /dev/null 2>&1 && which yum > /dev/null 2>&1; then
  #rpm -qa | grep -i mysql > /dev/null 2>&1 && print "mysql已安装:" && rpm -qa | grep -i mysql && exit 0
  # 依赖未安装时安装依赖
  [ `rpm -qa | grep -i libaio | grep -v grep | wc -l` -eq 0 ] && yum install -y libaio
elif which apt > /dev/null 2>&1; then
  [ `dpkg -l | grep -i libaio1 | grep -v grep | wc -l` -eq 0 ] && apt-get update && apt-get install -y libaio1
  [ `dpkg -l | grep -i libncurses5 | grep -v grep | wc -l` -eq 0 ] && apt-get update && apt-get install libncurses5
fi
# 检查用户和组
if ! id -u $usr > /dev/null 2>&1; then
  useradd -M -s /sbin/nologin $usr
fi
if ! getent group $usr_group > /dev/null 2>&1; then
  groupadd $usr_group
fi
# 检测并写入系统内核相关参数
limits=/etc/security/limits.conf
wfile "mysql    soft    nproc    16384" $limits
wfile "mysql    hard    nproc    16384" $limits
wfile "mysql    soft    nofile    65536" $limits
wfile "mysql    hard    nofile    65536" $limits
wfile "mysql    soft    stack    1024000" $limits
wfile "mysql    hard    stack    1024000" $limits
wfile "vm.swappiness = 5" /etc/sysctl.conf "sysctl -p"

# 检查软件安装包目录不存在时创建
mkdirs ${gz_file%/*}
# 日志目录不存在时 创建
mkdirs $log_dir $log_dir/binlog $log_dir/redolog $log_dir/undolog
sed -i "s#/opt/mysql/logs#$log_dir#g" $cnf
chown -R ${usr}:${usr_group} $log_dir
mkdirs $BASE_DIR/data

# 软件包不存在时(软件包目录和用户目录),下载
[ ! -f $gz_file ] && [ `find ~/ -maxdepth 1 -name 'mysql-*.tar.*' -type f | wc -l` -eq 0 ] && print "开始下载mysql安装包..." && wget $url -O $gz_file

# 解压
[ ! -d $tmp_dir ] && tar -xf $gz_file -C ${tmp_dir%/*}

# 同步文件
[ -d $tmp_dir ] && rsync -au $tmp_dir/* $BASE_DIR/
# 设置权限
chown -R ${usr}:${usr_group} $BASE_DIR
chmod -R 755 $BASE_DIR/data
err_file=$(grep log-error $cnf | awk -F'=' '{print $2}' | awk '$1=$1')
# 初始化
if [ "`ls -A $BASE_DIR/data`" == "" ];then
  shell="$BASE_DIR/bin/mysqld  --initialize --user=$usr --basedir=$BASE_DIR --datadir=$BASE_DIR/data --console --lower-case-table-names=1 --explicit_defaults_for_timestamp=true"
  print "mysql初始化:$shell"
  # 获取初始化
  eval $shell > $log_dir/init.log 2>&1
  [ $? -ne 0 ] && print "mysql初始化失败!错误日志:$init_output" && exit 1

  #从初始化输出中获取随机密码
  pass=$(grep "password" $log_dir/init.log| awk -F ': ' '{print $2}')
  echo -en "mysql临时密码:\033[31m $pass \033[0m \n"
  rm -rf $log_dir/init.log
  chown -R ${usr}:${usr_group} $log_dir
fi
chmod 644 $cnf
# 启动
$CURRENT_DIR/startup.sh
[ $? -gt 0 ] && print "启动失败，查看错误日志:$err_file" && exit 1
ps -ef | grep mysql

# 启动成功后安装自启动服务
if [ `ls /usr/lib/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ] && [ `ls /etc/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ]; then
  print "install mysqld service:/usr/lib/systemd/system/mysqld.service"
  cat >> /usr/lib/systemd/system/mysqld.service << EOF
[Unit]
Description=mysql service
[Service]
Type=forking
ExecStart=$CURRENT_DIR/startup.sh
ExecStop=$CURRENT_DIR/stop.sh
User=$usr
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mysqld.service
fi

# 等待几秒 显示启动日志
sleep 3
if [ -n "$pass" ];then
  # 提示输入新密码，超时未输入则跳过密码修改，使用初始化时生成的随机密码
  read -t $input_time -p "输入新密码(超时时间$input_time 秒):" password
  # 提示超时未输入密码，再次输出随机密码
  [ ! -n "$password" ] && echo -en "\n密码输入超时, 默认密码:\033[31m $pass \033[0m \n"
fi
if [ -n "$password" ]; then
  # 修改密码
  #ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourNewPassword';
  $CURRENT_DIR/mysql -uroot -p${pass} --connect-expired-password <<EOF
  SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$password');
  flush privileges;
  exit
EOF
  pass=$password
  print "修改密码为:$pass"
fi
if [ -n "$pass" ];then
# 开启root远程登录权限
$CURRENT_DIR/mysql -uroot -p${pass} <<EOF
use mysql;
update user set host = '%' where user = 'root';
grant all privileges on *.* to 'root'@'%' with grant option;
flush privileges;
exit
EOF
fi
print "MySQL安装完成"
# systemctl stop firewalld

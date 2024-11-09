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
url=https://mirrors.aliyun.com/mysql/MySQL-5.7/mysql-5.7.36-el7-x86_64.tar.gz
# 从url中提取压缩文件名
gz_file_name=${url##*/}
# 下载文件路径，文件名从下载url提取
gz_file=/opt/softs/$gz_file_name
# 解压临时目录
tmp_dir=/tmp/${gz_file_name%*.tar.gz}

# 当前目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# 当前应用根目录
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
# 配置文件
cnf=$BASE_DIR/conf/my.cnf

# 检测是否安装：如已启动退出，如已安装(数据目录不为空)未启动则启动
# 已启动时退出
[ `ps -ef | grep mysqld | grep -v grep | grep -v install.sh | wc -l` -gt 0 ] && echo "mysql has been started :" && ps -ef | grep mysqld | grep -v grep && exit 0
# 数据目录不为空时，提示数据目录不为空后，执行启动脚本退出
[ -d $BASE_DIR/data ] && [ "`ls -A $BASE_DIR/data`" ] && echo "$BASE_DIR/data is not empty!" && $CURRENT_DIR/startup.sh && exit 0

# 检查安装用户是否是root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, please use root to install"
    exit 1
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
function mdir {
  [ ! -d $1 ] && echo "mkdir -p $1" && mkdir -p $1
}

print " start to check mysql ..."
# mysql如已安装提示退出,如需卸载执行:rpm -ev 包名,如卸载依赖报错，加参数--nodeps
[ `rpm -qa | grep -i mysql | grep -v grep | wc -l` -gt 0 ] && print "mysql has been installed:" && rpm -qa | grep -i mysql && exit 0
# 3306端口被占用时 提示退出
[ `netstat -anp | grep $port | grep LISTEN | grep -v grep | wc -l` -gt 0 ] && print "port $port is already in use" && netstat -anp | grep $port | grep LISTEN && exit 0
# 依赖未安装时安装依赖
[ `rpm -qa | grep -i libaio | grep -v grep | wc -l` -eq 0 ] && yum install -y libaio

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
mdir ${gz_file%/*}
# 日志目录不存在时 创建
mdir $log_dir
mkdir -p $log_dir/binlog $log_dir/redolog $log_dir/undolog
chown -R ${usr}:${usr_group} $log_dir
mdir $BASE_DIR/data

# 软件包不存在时(软件包目录和用户目录),下载
[ ! -f $gz_file ] && [ `find ~/ -maxdepth 1 -name 'mysql-*.tar.gz' -type f | wc -l` -eq 0 ] && print "MySQL installation package not found! start downloading ..." && wget $url -O $gz_file

# mysql全局配置文件存在时 提示 TODO 选择配置文件
[ -f /etc/my.cnf ] && ls $cnf /etc/my.cnf
# 配置文件存在时备份
[ -f $cnf ] && [ ! -f $cnf.bak ] && print "backup $cnf" && cp $cnf $cnf.bak
# 检测配置中的路径和当前应用路径不一致时，批量替换成当前应用路径
dir=`cat $cnf | grep datadir | awk -F'=' '{print $2}' | awk '$1=$1'`
[ "$BASE_DIR" != "${dir%/*}" ] && sed -i "s#${dir%/*}#$BASE_DIR#g" $cnf

# 日志目录和配置文件不一致时 修改替换日志路径
# 查找配置文件中所有日志路径配置
for filePath in `cat $cnf | grep "\.log" | grep "=" | grep "/" | awk -F'=' '{print $2}' | awk '$1=$1'`
do
  # 配置文件中的路径和当前脚本定义的日志路径不匹配时 批量替换配置文件中的日志目录
  [ "$log_dir" != "${filePath%/*}" ] && sed -i "s#${filePath%/*}#$log_dir#g" $cnf
done
# 检测配置文件中的用户和当前脚本定义的用户不一致时，修改配置文件中的用户
[ "`cat $cnf | grep user | awk -F'=' '{print $2}' | awk '$1=$1'`" != "$usr" ] && sed -i "s/user=.*/user=$usr/" $cnf

# 检测用户
if [ `id $usr | grep $usr | grep -v grep | wc -l` -eq 0 ]; then
  groupadd $usr_group && useradd -r -g $usr -s /bin/false $usr
  # 设置用户密码
  if [ -f /opt/shell/pwd.sh ]; then
    pwd=`/opt/shell/pwd.sh | grep "pwd:" | awk -F':' '{print $2}'`
    echo "$usr pwd:$pwd" && echo $pwd | passwd --stdin "$usr"
  fi
fi

print " start to install mysql ..."
[ ! -d $tmp_dir ] && tar -zxf $gz_file -C ${tmp_dir%/*}
rsync -aWPu $tmp_dir/* $BASE_DIR/
# 设置权限
chown -R ${usr}:${usr_group} $BASE_DIR
# 初始化
[ "`ls -A $BASE_DIR/data`" == "" ] && print "mysql init..." && $BASE_DIR/bin/mysqld --defaults-file=$cnf --initialize --user=root --explicit_defaults_for_timestamp=true && [ $? -ne 0 ] && print "mysql initialize failed, please check the error log!" && exit 1

# 错误日志文件
err_file=`cat $BASE_DIR/conf/my.cnf | grep error.log | head -n 1 | awk -F'=' '{print $2}' | awk '$1=$1'`
# 获取初始化随机密码
pass=`grep "A temporary password" $err_file | awk -F ': ' '{print $2}'` && echo -en "mysql db user root initial password is:\033[31m $pass \033[0m \n"

# 启动
$CURRENT_DIR/startup.sh && [ $? -gt 0 ] && print "startup failed, see:$err_file" && exit 1
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

# 提示输入新密码，超时未输入则跳过密码修改，使用初始化时生成的随机密码
read -t $input_time -p "Please enter your password (timeout $input_time seconds):" password
# 提示超时未输入密码，再次输出随机密码
[ ! -n "$password" ] && echo -en "\nPassword input timeout, default password is:\033[31m $pass \033[0m \n"

if [ -n "$password" ]; then
  # 修改密码
  $CURRENT_DIR/mysql -uroot -p${pass} --connect-expired-password <<EOF
  SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$password');
  flush privileges;
  exit
EOF
  pass=$password
  print "reset password:$pass"
fi

# 开启root远程登录权限
$CURRENT_DIR/mysql -uroot -p${pass} <<EOF
use mysql;
update user set host = '%' where user = 'root';
grant all privileges on *.* to 'root'@'%' with grant option;
flush privileges;
exit
EOF

print "MySQL installation completed"

#!/bin/bash
# mysql启动脚本
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
cnf=$BASE_DIR/conf/my.cnf


#  进程已启动时 提示退出
[ `ps -ef|grep $BASE_DIR|grep mysqld|grep -v grep|grep -v install.sh|wc -l` -gt 0 ] && echo "mysql has bean started!" && exit 0
# 端口占用时 提示退出
[ `netstat -tlnp |grep 3306|grep -v grep|wc -l` -gt 0 ] && echo "port 3306 is already in use" && exit 0

# TODO 提取所有路径检测是否存在、是否和当前目录匹配
sed -i "s#/opt/mysql#$BASE_DIR#g" $cnf

if [ -f $BASE_DIR/docker-compose.yml ];then
	name="`cat $BASE_DIR/docker-compose.yml|grep container_name|awk -F': ' '{print $2}'`"
	if [ `docker ps -a|grep "$name"|wc -l` -gt 0 ];then
		docker-compose up -d && exit 0
	fi
fi

# 数据目录为空或启动命令不存在时 执行安装,否则执行启动
if [[ ( ! -d $BASE_DIR/data ) || ( "`ls -A $BASE_DIR/data`" == "" ) || ( ! -f $BASE_DIR/bin/mysqld_safe ) ]];then
  $CURRENT_DIR/install.sh 
else
  usr=`cat $cnf|grep user|awk -F'=' '{print $2}'|awk '$1=$1'`
  $BASE_DIR/bin/mysqld_safe --defaults-file=$cnf --user=$usr 2>&1 & 
  [ $? -ne 0 ] && echo "mysql start failed, please check the error log!" && exit 1
  jobs -l
  #$BASE_DIR/bin/mysqladmin --defaults-file=$cnf -u$usr -p$pass version
fi

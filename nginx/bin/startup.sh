#!/bin/bash
# nginx自动安装、启动脚本

#CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
ip=`find ${BASE_DIR%/*} -type f -name ip.sh 2>/dev/null | xargs -i readlink -f {}|xargs sh`
# 软件安装包目录
sft_dir=/opt/softs
url=`grep "url=" $CURRENT_DIR/install.sh|awk -F'=' '{print $2}'`

if [ -n "$ip" ];then
  exists=`find $BASE_DIR/conf/conf.d/ -type f|xargs grep "$ip"`
  if [ "$exists" == "" ];then
    echo "当前服务器ip:$ip"
  	read -p "Do you want to replace the IP?(n/y)：" replace
  	if [ "y" == "$replace" ];then
  		echo "开始替换配置文件中的ip为当前服务器ip:$ip"
	    # 替换配置文件中的ip为当前服务器ip
	    for f in `find $BASE_DIR/conf/conf.d/* |grep -Ev "*.bak|*.txt|ip-black.conf"`
	    do
	      sed -i "s#[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}#$ip#g"  $f 
	    done
  	fi
  fi
fi


# 判断docker-compose中的volumes主机路径是否存在，不存在则创建
for dir in `awk '/volumes:/,/^$/' docker-compose.yml | grep '\- ' |grep -v "#"| awk '{print $2}'|awk -F':' '{print $1}'`
do
    # 相对路径转换绝对路径
    [[ "$dir" =~ ^\..* ]] && dir=${dir#.} && dir=$BASE_DIR/$dir
    # 非文件路径，目录不存在时创建
 	[ ! -f $dir ] && [ ! -d $dir ] && echo "mkdir -p $dir " && mkdir -p $dir
done
# 检查用户组、用户不存在时则创建
user_group=$(cat docker-compose.yml |grep user|awk -F': ' '{print $2}')
if [ -n "$user_group" ];then
	group_name=$(echo $user_group | awk -F':' '{print $2}')
	user_name=$(echo $user_group | awk -F':' '{print $1}')
	#if ! grep -q "^$GROUP_NAME:" /etc/group; then
	if ! getent group "$group_name" > /dev/null;then
	    echo "groupadd $group_name" && sudo groupadd $group_name
	fi
	if ! id -u "$user_name" > /dev/null 2>&1; then
	    echo "useradd -g $group_name $user_name" && sudo useradd -g "$group_name" "$user_name"
	fi
fi


# 提取配置文件中的所有文件路径(^\S+|\S+\/\S+)，确认文件路径是否存在,不存在的路径替换为当前路径
#for f in `grep -oP '(\/\w+)+\/\w+\.\w+'  $BASE_DIR/conf/nginx.conf`
#do
#	if [ ! -f $f ];then
#	  if [[ $f == */conf/* ]];then
#	    newPath=`echo $f | sed "s#^/.*/conf/#$BASE_DIR/conf/#"` 
#		if [ -f $newPath ];then
#			echo "$f --> $newPath" && sed -i "s#$f#$newPath#" $BASE_DIR/conf/nginx.conf
#		else
#			[ ! -d $newPath ] && echo "mkdir -p $newPath" && mkdir -p $newPath 	
#		fi	
#	  else
#	  	dir=$(dirname "$f")
#	  	[ ! -d $dir ] && echo "mkdir -p $dir" && mkdir -p $dir 2>/dev/null
#	  	echo "not exists:$f" && touch $f 2>/dev/null
#	  fi
#	fi 
#done

#已启动 退出
[ `ps -ef|grep nginx|grep -v grep |wc -l` -gt 0 ] && ps -ef|grep nginx |grep process && exit 0

if [ -f /usr/bin/nginx ];then
  nginx -c $BASE_DIR/conf/nginx.conf && ps -ef|grep nginx |grep process && exit 0
fi



# nginx安装包存在时编译安装，否则docker-compose方式启动
if [ ! -f $sft_dir/${url##*/} ]; then
  #docker-compose没安装则安装
  find ${BASE_DIR%/*} -type f -name install-docker-compose.sh  2>/dev/null | xargs -i readlink -f {}|xargs sh
  name=`cat $BASE_DIR/docker-compose.yml |grep "container_name:"|grep -v grep|awk '{print $2}'`
  [ `docker-compose ps |grep -v NAME|grep $name|grep -Ev "exited|restarting"|wc -l` -eq 0 ] && docker-compose up -d
  docker-compose ps 
else
   # 编译安装
  $CURRENT_DIR/install.sh
fi

#!/bin/bash
# 应用自动化部署脚本，按照应用依赖顺序自动部署
#调用参数：参数1:环境如：dev/test;参数2:单个或多个应用模块名(多个逗号分割),可不传(按应用依赖顺序查找/opt/tmp自动部署),如base-app或base或"./lianxin-base/base-app,./lianxin-bigdata/bigdata-app"

#应用顺序
APPS=(bigdata-app base-app order-app contents-app model-app misc-app bot-app scale-app sso-server lianxin-facade file-proxy gserver task-admin task-job mngserver)
PROFILE=`cat ~/.profile 2>/dev/null`
[ ! -n "$PROFILE" ] && PROFILE="dev" && echo $PROFILE >~/.profile

echo "usage:$0 [\$profile] [\$appName]"
# TODO 应用包未改变，且检测应用进程不存在时，开启应用进程；
WEB_APP_DIR=/opt/webapps
WEB_APP_BACKUP_DIR=/opt/backups
TMP_DIR=/opt/tmp
BUILD_LOG_FILE=$TMP_DIR/build.log


CURRENT_DIR=`cd $(dirname $0); pwd -P`
cd $CURRENT_DIR


if [[ -n "$1" ]] && [[ ! "$1" == "$PROFILE" ]];then 
  echo "profile:$1 does not match:$PROFILE"
  exit 0
fi
[ ! -d "$WEB_APP_DIR" ] && mkdir $WEB_APP_DIR

[ ! -d "$WEB_APP_BACKUP_DIR" ] && mkdir $WEB_APP_BACKUP_DIR

buildLog(){
	echo "`date "+%Y-%m-%d %H:%M:%S"`:$1" && echo "`date "+%Y-%m-%d %H:%M:%S"`:$1" >>$BUILD_LOG_FILE
}

getAppName(){
   [ `echo "$1"|tr -cd '/'|wc -c` -gt 0 ] && echo ${1##*/}|| echo $1
}

findAndDeploy(){
	name=$(getAppName $1) 
    if [ -f $TMP_DIR/$name ];then
    	deployApp $TMP_DIR/$name
    	return 
    fi		
 	files=`find $TMP_DIR -name "${name}*.tar.gz"`
 	if [  -n "$files" ];then
		eachDeploy $files
		return 
 	fi
 	names=(${name//-/ })
	for name in ${names[@]}
	do
		[ ! -n "$files" ] && name=${name#*-}  && files=`find $TMP_DIR -name "${name}*.tar.gz"` 
		if [  -n "$files" ];then
			eachDeploy $files
			break
		fi
	done
}
eachDeploy(){
	if [ -n "$1" ];then
		for file in $1
		do
	  		deployApp $file
		done
	fi
}
# 发布应用 参数1 gzip文件
deployApp(){
  file=$1
  fileName=${file##*/}
  name=${fileName%-bin.tar.gz*}
  #echo "file:$file,$fileName" 
  if [ -f $file ];then
	  ls -lth $file
	  if [ -f "$TMP_DIR/${fileName}.md5" ];then
		buildLog "$fileName:$(sha1sum $file|awk '{print $1}'):$(cat $TMP_DIR/${fileName}.md5)"
		if [ "$(cat $TMP_DIR/${fileName}.md5)" == "$(sha1sum $file|awk '{print $1}')" ];then
		 buildLog "$file not change"
		 [ `ps -ef|grep $WEB_APP_DIR/$name|grep -v grep|wc -l` -eq 0 ] && buildLog "$name startup ..." && $WEB_APP_DIR/$name/bin/startup.sh 
		 return 0 
		fi
	  fi
	  sha1sum $file|awk '{print $1}' >$TMP_DIR/${fileName}.md5
	  
	  [ -f $WEB_APP_DIR/$name/bin/stop.sh ] && buildLog "$name shutdown ..." && $WEB_APP_DIR/$name/bin/stop.sh
	  dt=`date "+%Y%m%d%H%M%S"` 
	  [ -d "$WEB_APP_DIR/$name" ] && buildLog "backup app :mv $WEB_APP_DIR/$name $WEB_APP_BACKUP_DIR/$name.$dt" && mv $WEB_APP_DIR/$name $WEB_APP_BACKUP_DIR/$name.$dt
	  tar zxf $file -C $WEB_APP_DIR/
	  buildLog "$name startup ..." && $WEB_APP_DIR/$name/bin/startup.sh 
	  rm -rf $file
  else
  	echo "$file not exist"
  fi
}


buildLog "build start:$1 $2"
[ ! -d $TMP_DIR ] && mkdir -p $TMP_DIR

if [ `find $TMP_DIR -mindepth 1 -type d |wc -l` -gt 0 ];then
  find $TMP_DIR -mindepth 2 -type f -name "*.tar.gz" | xargs -I {}  mv {} $TMP_DIR
  find $TMP_DIR -mindepth 1  -type d |xargs -I {} rm -rf {};
fi
# 参数3 远程ip或主机名 是否当前服务器
isCurrent=false;
if [[ (-n "$3") && (`echo $3|grep "\."|wc -l` -eq 0) && ( "$3" == "`/opt/shell/ip.sh`" ) ]];then
	isCurrent=true
elseif [ "$3" == "`hostname`" ]
	isCurrent=true
fi
# 参数3 远程ip或主机名 远程部署
if [[ ( -n "$3") && ("$isCurrent" == "false") ]];then
   [ -f /opt/shell/ssh_login.sh ] && /opt/shell/ssh_login.sh $3
   rsync -aWPu /opt/shell/*.sh root@$3:/opt/shell/
   #TODO 传送部署多个服务
   file=`find $TMP_DIR -type f -name ${2}*.tar.gz|head -n 1`
   [ -f $file ] && ls -h $file && rsync -aWPu $file root@$3:$TMP_DIR/ && ssh root@$3 > /dev/null 2>&1 << EOF
/opt/shell/${0##*/} $1 $2 $3
exit 
EOF
   exit 0
fi
# 参数2缺失未指定发布应用时，查找部署临时目录下的包全部部署(按预先定义的应用依赖顺序)
if [ ! -n "$2" ];then
	files=`find $TMP_DIR -name *.tar.gz` && [ ! -n "$files" ] && buildLog "*.tar.gz file not found! in dir:$TMP_DIR" && exit 2
	for app in ${APPS[@]};do
	  findAndDeploy $app
	done
	exit 0
fi
# 指定应用名称时
if [ -f "$TMP_DIR/$2" ];then
	files=$TMP_DIR/$2 
elif [ `echo $2|grep ,|grep -v grep|wc -l` -eq 0 ];then
   	[ `echo "$2"|tr -cd '/'|wc -c` -eq 0 ] && files=`find $TMP_DIR/ -name $2*.tar.gz`
    [ ! -n "$files" ] && name=${2#*-}  && files=`find $TMP_DIR -name "${name}*.tar.gz"` 
	[ ! -n "$files" ] && name=${name%%-*} && files=`find $TMP_DIR -name "${name}*.tar.gz"`
	[ ! -n "$files" ] && files=$2
fi
if [ -n "$files" ];then
	for file in $files
	do
	  findAndDeploy $file
	done
	exit 0
fi
# 发布应用(按依赖顺序)
apps=(${2//,/ })
for app in ${APPS[@]};do
 for name in ${apps[@]};do
    appName=$(getAppName $name)
	[ "$app" == "$appName" ] &&	findAndDeploy $appName
 done
done

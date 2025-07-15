#!/bin/sh

WEB_APP_DIR=/opt/webapps
WEB_APP_BACKUP_DIR=/opt/backups
TMP_DIR=/opt/tmp
BUILD_LOG_FILE=$TMP_DIR/build.log

CURRENT_DIR=`cd $(dirname $0); pwd -P`
cd $CURRENT_DIR



PROFILE="dev"
[ -n "$1" ] && PROFILE=$1

if [ ! "$PROFILE" == "dev" ];then 
 exit 0
fi

[ ! -d "$WEB_APP_BACKUP_DIR" ] && mkdir $WEB_APP_BACKUP_DIR

buildLog(){
	echo "`date "+%Y-%m-%d %H:%M:%S"`:$1" >>$BUILD_LOG_FILE
}

deployApp(){
  file=$1
  fileName=${file##*/}
  name=${fileName%-bin.tar.gz*}
  
  [ -f $WEB_APP_DIR/$name/bin/stop.sh ] && buildLog "$name shutdown ..." && $WEB_APP_DIR/$name/bin/stop.sh
  dt=`date "+%Y%m%d%H%M%S"` 
  buildLog "backup app :mv $WEB_APP_DIR/$name $WEB_APP_BACKUP_DIR/$name.$dt"
  mv $WEB_APP_DIR/$name $WEB_APP_BACKUP_DIR/$name.$dt
  tar zxf $file -C $WEB_APP_DIR/
  buildLog "$name startup ..."
  $WEB_APP_DIR/$name/bin/startup.sh 
  rm -rf $file
}


buildLog "build start:$1 $2"

if [ -n "$2" ];then
 if [ -f "$TMP_DIR/$2" ];then
   files=$TMP_DIR/$2 
 else
	app=$2
	apps=(${app//,/ })
	for a in ${apps[@]}
	do
	files=`find $TMP_DIR/ -name "${a}*.tar.gz"`
	[ ! -n "$files" ] && buildLog "${a}*.tar.gz not found! in dir:$TMP_DIR"
	if [ -n "$files" ];then
		for file in $files
		do
		  echo "2:$file"
		  deployApp $file
		done  
	fi
	done
	exit 0   
 fi
fi

[ ! -n "$files" ] && files=`find $TMP_DIR/ -name *.tar.gz`

[ ! -n "$files" ] && echo ".tar.gz file not found! in dir:$TMP_DIR" && exit 2


 
for file in $files
do
  deployApp $file
done


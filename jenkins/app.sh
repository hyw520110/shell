#!/bin/bash
APPS="bigdata-app,user-app,scale-app,content-app,bot-app,mng-app,lianxin-facade,lianxin-task";
DIR=/opt/webapps
[ -n "$1" ] && name=$1 || name=restart
echo $name
IFS=","
ARRAY=($APPS)
for app in ${ARRAY[@]};do
    if [ -d $DIR/$app ];then
	[ -f "$DIR/$app/bin/$1.sh" ] && $DIR/$app/bin/$1.sh 
	[ ! -f "$DIR/$app/bin/$1.sh" ] &&  $DIR/$app/bin/stop.sh && $DIR/$app/bin/startup.sh
    fi
done

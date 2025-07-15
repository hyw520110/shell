#!/bin/bash
# 批量启动应用服务
CURRENT_DIR=`cd $(dirname $0); pwd -P`
APPS=`cat $CURRENT_DIR/deploy.sh |grep APPS|head -n 1|awk -F'=' '{print $2}'|sed -r 's/^\(((.*))\)/\1/'`
APP_DIR=/opt/webapps
for app in ${APPS[@]};
do
  if [ ! -d $APP_DIR/$app ];then
     echo $APP_DIR/$app not exist!
     continue
  fi
  if [ `ps -ef|grep $APP_DIR/$app|grep -v grep |wc -l` -gt 0 ];then
     if [ "$1" == "-f" ];then
       $APP_DIR/$app/bin/stop.sh 
       wait $!
     else
        echo "$app is running..."
        continue
     fi
  fi
  $APP_DIR/$app/bin/startup.sh 
  wait $!
done 

#for dir in `ls $APP_DIR`
#do
#  echo "$dir"
#done

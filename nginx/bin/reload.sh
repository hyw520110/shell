#!/bin/bash
#nginx加载配置

BASE_DIR=`cd $(dirname $0)/..; pwd`
conf_file=$BASE_DIR/conf/nginx.conf

if [ -n "`docker ps -a|grep nginx|grep Up`" ];then
 isOk=`docker exec -it nginx nginx -t |grep ok `
 [ -n "$isOk" ] && echo $isOk && docker exec -it nginx nginx -s reload
else
 isOk=`nginx -c $conf_file -t|grep ok`
 [ -n "$isOk" ] && echo $isOk && nginx -c $conf_file -s reload
fi



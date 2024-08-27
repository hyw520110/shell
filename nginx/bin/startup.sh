#!/bin/bash
# nginx自动安装、启动脚本
#初始第一次启动时,是否替换配置文件ip为当前服务器ip
repleace=true

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
ip=`/opt/shell/ip.sh`
# 软件安装包目录
sft_dir=/opt/softs

if [ "true" == "$repleace" ];then
  if [ ! -f ~/.nginx ];then
    echo "开始替换配置文件中的ip为当前服务器ip:$ip"
    # 替换配置文件中的ip为当前服务器ip
    for f in `find $BASE_DIR/conf/conf.d/* |grep -Ev "*.bak|*.txt"`
    do
      sed -ri "s#([0-9]{1,3}\.){3}[0-9]{1,3}#$ip#g"  $f 
    done
    echo "$date" >> ~/.nginx
  fi
fi
#已启动 退出
[ `ps -ef|grep nginx|grep -v grep |wc -l` -gt 0 ] && ps -ef|grep nginx |grep process && exit 0

if [ -f /usr/bin/nginx ];then
  nginx -c $BASE_DIR/conf/nginx.conf && ps -ef|grep nginx |grep process && exit 0
fi

url=`grep "url=" $CURRENT_DIR/install.sh|awk -F'=' '{print $2}'`

# nginx安装包存在时编译安装，否则docker-compose方式启动
if [ ! -f $sft_dir/${url##*/} ]; then
  #docker-compose没安装则安装
  /opt/shell/install-docker-compose.sh -v
  [ `docker-compose ps |grep -v NAME|wc -l` -eq 0 ] && docker-compose up -d
  docker-compose ps 
else
   # 编译安装
  $CURRENT_DIR/install.sh
fi

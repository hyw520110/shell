#!/bin/bash
URL="https://github.com/prometheus/node_exporter/releases/download/v1.5.0/node_exporter-1.5.0.linux-amd64.tar.gz"
#REPO="https://copr.fedorainfracloud.org/coprs/ibotty/prometheus-exporters/repo/epel-7/ibotty-prometheus-exporters-epel-7.repo"
# https://blog.csdn.net/qq_36595568/article/details/124285925
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
# gz文件名
FILE_NAME=${URL##*/}
# gz文件
GZ_FILE=$BASE_DIR/$FILE_NAME

# 检查创建目录
for dir in `cat $BASE_DIR/docker-compose.yml |grep -A 4 volumes|grep "-"|awk -F':' '{print $1}'|awk '{print $2}'`
do
	if [[ "$dir" == "."* || "$dir" == "/"* ]];then
		[[ "$dir" =~ ^\..* ]] && dir=`echo $dir|sed 's/^\.\///'` && dir=$BASE_DIR/$dir && [ ! -d "$dir" ] && echo "mkdir -p $dir" && mkdir -p $dir && chmod -R 777 $dir
	fi
done
# 配置文件ip替换
[ `grep "localhost" $BASE_DIR/conf/prometheus.yml|wc -l` -gt 0 ] && ip=`/usr/sbin/ip addr |grep -A 2 "state UP"|grep inet|grep -Ev "inet6|127|172"|grep -v "\.250\."|head -n 1|awk '{print $2}'|awk -F'/' '{print $1}'`&& sed -i "s/localhost/$ip/g" $BASE_DIR/conf/prometheus.yml
cd $BASE_DIR
docker-compose up -d
docker-compose logs -f







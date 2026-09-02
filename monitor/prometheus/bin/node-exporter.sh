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

# 监控主机，检测安装Node_Export(3种安装方式：1解压版主机安装；2、yum安装；3、docker/docker-compose安装) https://copr.fedorainfracloud.org/coprs/ibotty/prometheus-exporters/
# 在promethues中添加该监控job https://www.cnblogs.com/zydev/p/16768810.html
# 配置Grafana:创建Prometheus数据源、导入Node-Export仪表板(官方模板查询地址: https://grafana.com/grafana/dashboards)找到模板编号8919或下载json文件导入
#二进制文件安装https://prometheus.io/download/ 下载解压./node_exporter --web.listen-address=:9100 访问地址： http://localhost:9100/metrics
[ ! -f $GZ_FILE ] && wget $URL -o $GZ_FILE
[ ! -d "$BASE_DIR/${FILE_NAME%%\.tar*}" ] && tar zxvf $GZ_FILE -C $BASE_DIR/ 
# TODO 判断是否已启动(进程和端口)
[  -d "$BASE_DIR/${FILE_NAME%%\.tar*}" ]&& (cd $BASE_DIR/${FILE_NAME%%\.tar*};nohup ./node_exporter 2>&1 &) || echo "dir : $BASE_DIR/${FILE_NAME%%\.tar*} not exists!"
# yum方式安装
#if [ ! -f /etc/yum.repos.d/${REPO##*/} ];then
	#curl -Lo /etc/yum.repos.d/${REPO##*/} $REPO
	#yum -y install node_exporter
	#systemctl start node_exporter
	#systemctl enable node_exporter.service
#fi
# docker/docker-compose方式启动
#docker run -d  --name node_exporter -p 9100:9100 -v "/proc:/host/proc:ro" -v "/sys:/host/sys:ro" -v "/:/rootfs:ro" prom/node-exporter






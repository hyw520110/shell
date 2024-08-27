#!/bin/bash
# sonarqube 自动安装启动脚本

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

# 系统参数 
sysctl -w vm.max_map_count=524288
sysctl -w fs.file-max=131072
ulimit -n 131072
ulimit -u 8192
# 重启生效
#echo "sonar   -   nofile   65536
#sonar   -   nproc    4096" > /etc/security/limits.d/99-sonarqube.conf
#echo "vm.max_map_count=262144
#fs.file-max=65536" > /etc/sysctl.d/99-sonarqube.conf

# 创建容器映射路径
for dir in `cat $BASE_DIR/docker-compose.yml|grep -A 100 volumes|grep -E "\- (\.|/)"|awk '{print $2}'|awk -F':' '{print $1}' `
do
	[[ $dir == ./* ]] && dir=$BASE_DIR/${dir#./*} 
	[ ! -f $dir ] && [ ! -d $dir ] && echo "mkdir $dir" && mkdir -p $dir && chmod -R 777 $dir
done
if [ `docker-compose ps|grep -v NAME|grep running|grep -v grep|wc -l` -gt 0 ];then
	[ "-f" == "$1" ] && docker-compose down || echo "has been started!" && docker-compose ps && exit 1
fi
docker-compose up -d
# 初始创建db
#docker exec -it postgres createdb sonar​
#docker-compose restart
docker-compose ps -a && docker-compose logs -f

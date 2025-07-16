#!/usr/bin/env bash
# redis安装、配置、启动脚本，主机模式(单机模式、伪集群、TODO分布式集群)和docker-compose模式(单机模式、TODO 集群模式)

# 节点数，单机模式1(默认);集群模式大于6的单数(大于2即可，集群节点数为3时，1个节点停服整个集群不可用，一般节点数推荐7)
num=${1:-1}
# 端口，集群模式为起始端口
port=${2:-6379}

#  下载url，默认离线安装,如当前目录不完整且离线安装包不存在时 执行下载 进行离线安装
url=https://github.com/redis/redis/archive/7.0.5.tar.gz
# 从url中提取压缩文件名
gz_file_name=${url##*/}
# 下载文件路径，文件名从下载url提取
gz_file=/opt/softs/$gz_file_name
# 解压临时目录
tmp_dir=/tmp/redis-${gz_file_name%*.tar.gz}
# 自启动服务脚本
service_dir=/usr/lib/systemd/system
CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}

cnf=$BASE_DIR/conf/redis.conf
log_dir=/var/log/redis
# 密码
password=`cat $cnf|grep requirepass|grep -Ev "^#"|awk '{print $2}'`
password=${password:-123456}

cd $BASE_DIR

# 已启动则打印进程退出
[ `ps -ef|grep $BASE_DIR|grep -v grep|wc -l` -gt 0 ] && ps -ef|grep $BASE_DIR|grep -v grep &&  exit 0
[ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ] && [ `docker-compose ps |grep -Ev "NAME|exited"|grep running|grep -v grep|wc -l` -gt 0 ] &&  docker-compose ps && exit 0
[ `netstat -tunlp | grep $port |grep -v grep| wc -l` -gt 0 ] && echo "port $port is already in used"&& exit 0

# 参数检查
[ $num -lt 6 ] && [ $num -ne 1 ] && echo "Number of nodes must be: 1 (stand-alone mode), or odd number greater than 6 (cluster mode)" && exit 1 

# 检查目录不存在则创建
mDir(){
  [ ! -d $1 ] && mkdir -p $1 
}
# 启动
startup(){
	$CURRENT_DIR/redis-server $1 
	[ `ps -ef|grep $BASE_DIR|grep -v grep|wc -l` -gt 0 ] && echo "redis started:" && ps -ef|grep $BASE_DIR|grep -v grep
}
# 编译安装
install(){
	# wget $url -o $gz_file 下载大小有问题
	[ ! -d $tmp_dir ] && mkdir -p $tmp_dir && [ ! -f $gz_file ] && wget $url -o $gz_file 
	#&& cd $tmp_dir && wget $url 
	[ "`ls -A $tmp_dir`" ] || tar -zxvf $gz_file -C ${tmp_dir%/*} >/dev/null 2>&1 &
	cd $tmp_dir
	make && make install PREFIX=$BASE_DIR
	sleep 1s 
	cd $BASE_DIR
}
# 安装自启动服务，参数1：服务名；参数2：配置文件全路径
install-service(){
    [ "$1" == "redis" ] && p=6379 || p=${1#*-}
    echo "port:$p"
	if [ ! -f $service_dir/$1.service ];then
cat >> $service_dir/$1.service << EOF
[Unit]
Description=redis
After=network.target

[Service]
Type=forking
ExecStart=$BASE_DIR/bin/redis-server $2 
ExecStop=$BASE_DIR/bin/stop.sh $p 
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload 
		systemctl enable redis.service
	fi
}
# 检查日志目录
mDir $log_dir
mDir $BASE_DIR/data && chmod -R 775 $BASE_DIR/data
#sed -i "/^\# requirepass .*/requirepass $password/"  $cnf
#sed -i "/^\# masterauth .*/masterauth $password/" $cnf
if [  ! -f $CURRENT_DIR/redis-server ];then
	install	
fi
# 集群模式
if [ $num -gt 6 ];then
  	# 主机伪集群(在一台主机上部署集群) TODO 1、判断集群是否已经启动ok；2、分布式集群 https://www.cnblogs.com/wangjunjiehome/p/16086925.html
	host=""
	for p in `seq $(($port+1)) $(($port+$num))`
	do
		#dir=`echo $i | awk '{printf("%02d\n",$0)}'`
		# 检测端口 是否已被占用，TODO 递增检测空闲端口
		[ `netstat -tunlp | grep $p | wc -l` -gt 0 ] && echo "port $port is already in use" && continue
		[ ! -f $BASE_DIR/conf/redis-$p.conf ] && cp $cnf $BASE_DIR/conf/redis-$p.conf
		sed -i -e "s#logfile .*.log#logfile $log_dir/redis-$p.log#" $BASE_DIR/conf/redis-$p.conf
		sed -i  "s#dir ./#dir $BASE_DIR/data/$p#" $BASE_DIR/conf/redis-$p.conf && mDir $BASE_DIR/data/$p
		#修改端口号
		sed -i "s#$port#$p#g" $BASE_DIR/conf/redis-$p.conf
		sed -i "s#daemonize no#daemonize yes#" $BASE_DIR/conf/redis-$p.conf
		sed -i "s/# cluster-enabled yes/cluster-enabled yes/" $BASE_DIR/conf/redis-$p.conf
		sed -i "s/# cluster-node-timeout/cluster-node-timeout/" $BASE_DIR/conf/redis-$p.conf
		sed -i "s/# cluster-config-file/cluster-config-file/" $BASE_DIR/conf/redis-$p.conf
		#启动
		$CURRENT_DIR/redis-server $BASE_DIR/conf/redis-$p.conf
		# 安装自启动服务
		install-service redis-$p $BASE_DIR/conf/redis-$p.conf
		host+="127.0.0.1:$p "
	done
	#创建集群
	$CURRENT_DIR/redis-cli --cluster create $host --cluster-replicas 1 -a $password 
	$CURRENT_DIR/redis-cli --cluster info -a $password
	exit 0
fi

# 单机模式
# docker未安装
if [ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -eq  0 ];then
    # 主机模式
	# 日志目录不存在则创建
	logfile=`cat $cnf |grep "logfile "|awk '{print $2}'`
	[ ! -d ${logfile%/*} ] && mkdir ${logfile%/*}
	sed -i "s#dir ./#dir $BASE_DIR/data#" $cnf
	startup $BASE_DIR/conf/redis.conf
	#启动失败 执行安装 在启动
	[ `ps -ef|grep $BASE_DIR|grep -v grep|wc -l` -eq 0 ] && install && startup $BASE_DIR/conf/redis.conf 
	install-service redis $BASE_DIR/conf/redis.conf
else
	#docker-compose模式启动
	[ `docker-compose ps |grep -Ev "NAME|exited"|grep running|wc -l` -eq 0 ] && docker-compose up -d && docker-compose ps 
fi

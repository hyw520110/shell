#!/bin/bash
# 默认端口
port=${1:-6379}
CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

#强制结束进程 参数1，端口/关键字
stop(){
 	 key=${1:-redis}
	 pid=`ps -ef|grep $BASE_DIR|grep $key|grep -v grep |awk '{print $2}'`
	 [ -n "$pid" ] && echo "kill $key process:$pid" && kill -9 $pid
}
isNum(){
	echo "$1"|[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ]
}

# 参数1不是数字时，端口默认6379
isNum $port|| port=6379

echo "usage:$0 or $0 -f or $0 \$port"
# 强制停止
[ "-f" == "$1" ]  && stop  &&  exit 0
# 检查docker进程
[ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ] && [ `docker ps -a 2>/dev/null|grep redis|grep -v Exited|grep -v grep|wc -l` -gt 0 ] && docker-compose stop 
# 检查主机进程
[ `ps -ef|grep $BASE_DIR|grep $port|grep -v grep|wc -l` -eq 0 ] && exit 0
[ `netstat -tunlp |grep $port |grep -v grep| wc -l` -eq 0 ] && exit 0


[  ! -f $BASE_DIR/bin/redis-cli ]  && stop $1 &&  exit 0
# 强制停止端口
stop $port && exit 0

# TODO 优雅停服
# 查找端口对应配置文件
cnf=`find $BASE_DIR/conf/ -name *.conf |xargs grep -E "^port "|grep $port|grep -v grep|awk -F':' '{print $1}'`
pwd=`cat $cnf|grep requirepass|grep -Ev "^#"|awk '{print $2}'`
$BASE_DIR/bin/redis-cli -p $port -a $pwd shutdown
pid=`ps -ef|grep $BASE_DIR|grep $port|grep -v grep|awk '{print $2}'`
echo "pid:$pid"
while [ -x /proc/${pid} ]
do
    echo "Waiting for Redis to shutdown ..."
    sleep 1
done


#!/bin/bash
conf=../conf/broker.conf
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ip=`/opt/shell/ip.sh`

echo "选择模式："
echo "1、2m-noslave"
echo "2、2m-2s-async"
echo "3、2m-2s-sync"
read -n 1 -p "输入数字选择模式 > " mode
#namesrv启动
nohup $DIR/mqnamesrv ‐n $ip:9876 &

//修改配置文件
function modify_conf {
  [ `grep "namesrvAddr=$1:9876;" $2/$3|wc -l` -eq 0 ] &&  echo "namesrvAddr=$1" >> $2/$3
  [ `grep "brokerIP1=$1:9876;" $2/$3|wc -l` -eq 0 ] &&  echo "brokerIP1=$1" >> $2/$3
}
function modify_namesrv {
 [ -n "$1" ] && [ `grep "namesrvAddr=$1:9876;" $2|wc -l` -eq 0 ] && sed -i "s/namesrvAddr=.*/namesrvAddr=$3:9876;$1:9876/g" $2
}

if [ $mode -eq 1 ];then
  conf_dir=../conf/2m-noslave/
  modify_conf $ip $conf_dir broker-a.properties
  modify_conf $ip $conf_dir broker-b.properties
  read  -p "输入另外一台namesrv的ip > " namesrv
  modify_namesrv $namesrv $conf_dir/broker-a.properties $ip
  modify_namesrv $namesrv $conf_dir/broker-b.properties $ip
  nohup $DIR/mqnamesrv -n $ip:9876 &
  nohup sh $DIR/mqbroker -c $conf_dir/broker-a.conf autoCreateTopicEnable=true &
  nohup sh $DIR/mqbroker -c $conf_dir/broker-b.conf autoCreateTopicEnable=true & 
fi

if [ $mode -gt 1 ];then
  [ $mode -eq 2 ] &&  conf_dir=../conf/2m-2s-async || conf_dir=../conf/2m-2s-sync
  read  -p "输入a或b选择broker > " broker
  modify_conf $ip $conf_dir broker-$broker.properties
  modify_conf $ip $conf_dir broker-$broker-s.properties
  read  -p "输入另外一台namesrv的ip > " namesrv
  modify_namesrv $namesrv $conf_dir/broker-$broker.properties $ip
  modify_namesrv $namesrv $conf_dir/broker-$broker-s.properties $ip
  nohup $DIR/mqnamesrv -n $ip:9876 &
  nohup sh $DIR/mqbroker -c $conf_dir/broker-$broker.conf autoCreateTopicEnable=true &
  nohup sh $DIR/mqbroker -c $conf_dir/broker-$broker-s.conf autoCreateTopicEnable=true &
fi



ps -ef|grep -E "namesrv|broker"
#firewall-cmd --state
#firewall-cmd --zone=public --add-port=9876/tcp --permanent  
#firewall-cmd --reload

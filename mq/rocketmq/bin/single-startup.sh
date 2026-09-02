#!/bin/bash
conf=../conf/broker.conf
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ip=`/opt/shell/ip.sh`
nohup $DIR/mqnamesrv ‐n $ip:9876 &
if [ `grep "brokerIP1" $conf|wc -l` -eq 0 ];then
  echo "brokerIP1=$ip" >> $conf
else
  sed -i "s/brokerIP1=[0-9\.]\+/brokerIP1=$ip/g" $conf
  echo "`grep brokerIP1  $conf`"  
fi

nohup $DIR/mqbroker ‐n $ip:9876 ‐c $conf autoCreateTopicEnable=true &


ps -ef|grep -E "namesrv|broker"
#firewall-cmd --state
#firewall-cmd --zone=public --add-port=9876/tcp --permanent  
#firewall-cmd --reload

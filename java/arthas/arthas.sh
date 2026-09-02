#!/bin/bash

dir=/opt/arthas
url=https://arthas.aliyun.com/arthas-boot.jar
#[ ! -f $dir/arthas-boot.jar ] && curl -o $dir/${url##*/} --create-dirs $url 
[ ! -f $dir/${url##*/} ] && wget -P $dir $url
java -jar $dir/${url##*/}
#ip=`ip addr |grep -A 2 "state UP"|grep inet|grep -Ev "inet6|127|172"|awk '{print $2}'|awk -F'/' '{print $1}'` && echo "ip:$ip" && java -jar $dir/${url##*/} --target-ip $ip

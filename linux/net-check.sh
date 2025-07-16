#!/bin/bash
keys=(google github 47.110.177.14)
log=/home/iftop.log
f=/home/pid.log

#查看TCP连接状态  
#netstat -nat |awk '{print $6}'|sort|uniq -c|sort -rn 
#连接的IP按连接数量进行排序
#netstat -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -n  
#查看80端口连接数最多的20个IP   
#netstat -anlp|grep 80|grep tcp|awk '{print $5}'|awk -F: '{print $1}'|sort|uniq -c|sort -nr|head -n20  
#查找较多time_wait连接  	
#netstat -n|grep TIME_WAIT|awk '{print $5}'|sort|uniq -c|sort -rn|head -n20  
#查找较多的SYN连接  
#netstat -an | grep SYN | awk '{print $5}' | awk -F: '{print $1}' | sort | uniq -c | sort -nr | more 
#查看当前并发访问数：
#netstat -an | grep ESTABLISHED | wc -l
#查看所有连接请求
#netstat -tn 2>/dev/null 
#查看访问某一ip的所有外部连接IP(数量从多到少)
#netstat -nt | grep 47.96.32.255 | awk '{print $5}' | awk -F: '{print ($1>$4?$1:$4)}' | sort | uniq -c | sort -nr | head

iftop --help &>/dev/null
[ $? == 1 ] &&  echo "iftop is not installed:yum install -y iftop"

while [ true ];do
 
  iftop -t -P -s 1 > $log
  for key in ${keys[@]}
  do
    e=`grep -C 1 "google" $log`     
    if [ -n "$e" ];then
      echo $e >> $f
      port=`echo $e | awk -F":" '{print $2}'|awk -F"=>" '{print $1}'`
      if [ -n "$port" ];then
	    echo "port:$port" >>$f
	    port_info=`netstat -tulp|grep ":$port "`
	    echo $port_info >>$f
	    pid=`netstat -tulp|grep ":$port "|awk '{print $7}'|awk -F'/' '{print $1}'`
	    [ -n "$pid" ] && echo "pid:$pid" >> $f && ps -ef|grep $pid|xargs echo  >> $f && ls /porc/$pid/exe >> $f
      fi
    fi
  done
  sleep 1
done

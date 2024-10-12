#!/bin/bash

# crontab -e  编辑对应规则定时加入黑名: 1 */1 * * * 
#nginx访问日志
ngx_log=/var/log/nginx/access.log
#nginx ip 黑名单
black_file=/opt/nginx/conf/conf.d/ip-black.conf
# 1分钟,前N分钟之内请求多少次自动屏蔽
last_minutes=1
# 访问次数
count=8


[ ! -f $ngx_log ] && exit 0
[ ! -f $black_file ] && touch $black_file

ip=`/opt/shell/ip.sh`


#屏蔽所有php请求ip
#grep php $ngx_log |grep -v "$ip" |grep -E "40[0-9]|50[1-9]" |awk -F ' ' '{print "deny",$1, ";"}' |sort -u >> $black_file
for h in `grep php $ngx_log |grep -v "$ip" |grep -E "40[0-9]|50[1-9]"|awk -F ' ' '{print $1}'|sort -u`
do
  [ -z "`grep " $h" $black_file`" ] && echo "deny $h;" >> $black_file
done

# N分钟之前
start_time=`date -d"$last_minutes minutes ago" +"%d/%b/%Y":"%H:%M:%S"`
# 结束时间 当前时间
stop_time=`date +"%d/%b/%Y":"%H:%M:%S"`
# 过滤出单位之间内的日志并统计ip及请求数
ips=`tac $ngx_log | awk -v st=$start_time -v et=$stop_time '{t=substr($4,2);if(t>=st && t<=et){print $1}}' |sort | uniq -c | sort -nr| awk '{if($1>$count)print $2}'`
for line in $ips
do
    result=$(grep $line $black_file)
    #判断ip是否已经被屏蔽
    if [ -z "$result" ]; then
        #未屏蔽的ip进行屏蔽
        echo "deny $line;" >> $black_file
    fi
done


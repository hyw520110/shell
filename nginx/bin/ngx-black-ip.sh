#!/bin/bash
# 检测nginx日志 自动屏蔽ip黑名单：1、php请求ip；2、单位时间内过于频繁的请求ip

# TODO 记录屏蔽日志；定时检测任务和nginx定时加载配置crontab -e: 1 */1 * * * 
#nginx访问日志
ngx_log=/var/log/nginx/access.log
log_file=/var/log/nginx/ip-black.log
# 1分钟,前N分钟之内请求多少次自动屏蔽
last_minutes=1
# 访问次数
count=8
# 服务器ip
# 获取脚本所在目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
CONF_DIR="$BASE_DIR/conf"
CONF_FILE="$CONF_DIR/nginx.conf"
#nginx ip 黑名单
black_file=$CONF_DIR/conf.d/ip-black.conf

# 从 nginx.conf 提取日志路径
ngx_log=$(grep -E '^\s*access_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';')
[ -z "$ngx_log" ] && ngx_log="/var/log/nginx/access.log"
log_file=$(grep -E '^\s*error_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';')
[ -z "$log_file" ] && log_file="/var/log/nginx/ip-black.log"

# ip.sh 路径自动查找
ip_sh="$(find "$BASE_DIR" -type f -name ip.sh 2>/dev/null | head -n 1)"
if [ -n "$ip_sh" ]; then
  ip=$(bash "$ip_sh")
else
  # 兼容 Linux 和 macOS 获取本机 IP
  if command -v ip > /dev/null 2>&1; then
    ip=$(ip addr | awk '/inet / && !/127.0.0.1/ {sub("/.*", "", $2); print $2; exit}')
  elif command -v ifconfig > /dev/null 2>&1; then
    ip=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
  else
    ip=""
  fi
fi

# 其余逻辑用 $BASE_DIR、$CONF_DIR 变量拼接路径
# 拒绝计数，大于0时，nginx重新加载配置文件
deny_count=0


# 当前脚本全路径
f=$CURRENT_DIR/${0##*/}
cron_job="*/1 * * * * bash $f"
# 定时任务不存在时添加，使用 crontab -l 检查，避免直接操作 /var/spool/cron/root
if ! crontab -l 2>/dev/null | grep -q "$cron_job"; then
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
fi
#删除job
#( crontab -l | grep -v"$cron_job" ) | crontab - 
#crontab -r -u USERNAME

[ ! -f $ngx_log ] && exit 0
[ ! -f $black_file ] && touch $black_file

function denyIp () {
  [ -z "`grep " $1" $black_file`" ] && deny_count=$(( $deny_count + 1 )) && echo "`date "+%Y-%m-%d %H:%M:%S"` deny $1;" >> $log_file  && echo "deny $1;" >> $black_file
}
#屏蔽所有php请求ip
#grep php $ngx_log |grep -v "$ip" |grep -E "40[0-9]|50[1-9]" |awk -F ' ' '{print "deny",$1, ";"}' |sort -u >> $black_file
for h in `grep php $ngx_log |grep -v "$ip" |grep -E "40[0-9]|50[1-9]"|awk -F ' ' '{print $1}'|sort -u`
do
  denyIp $h
done

# N分钟之前
start_time=`date -d"$last_minutes minutes ago" +"%d/%b/%Y":"%H:%M:%S"`
# 结束时间 当前时间
stop_time=`date +"%d/%b/%Y":"%H:%M:%S"`
# 统计ip访问次数
# awk '{print $1}' $ngx_log |sort |uniq -c|sort -n
#tail -n50000 $ngx_log |awk '{print $1,$12}'|grep -i -v -E "google|yahoo|baidu|msnbot|FeedSky|sogou"|awk '{print $1}'|sort|uniq -c|sort -rn|awk '{if($1>1000)print "deny "$2";"}'
# 过滤出单位之间内的日志并统计ip及请求数
ips=`tac $ngx_log | awk -v st=$start_time -v et=$stop_time '{t=substr($4,2);if(t>=st && t<=et){print $1}}' |sort | uniq -c | sort -nr| awk '{if($1>$count)print $2}'`
for line in $ips
do
    result=$(grep $line $black_file)
    #判断ip是否已经被屏蔽
    if [ -z "$result" ]; then
        #未屏蔽的ip进行屏蔽
        denyIp $line
    fi
done

# deny_count大于0时，nginx重新加载配置文件
[ $deny_count -gt 0 ] && echo "`date "+%Y-%m-%d %H:%M:%S"` deny count: $deny_count" >> $log_file && nginx -c ${CURRENT_DIR%/*}/conf/nginx -s reload


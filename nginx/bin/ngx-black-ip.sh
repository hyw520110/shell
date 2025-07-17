#!/bin/bash
# 检测nginx日志，自动屏蔽ip黑名单：
# 1. 屏蔽php请求ip（出现40x/50x状态码）
# 2. 单位时间内过于频繁的请求ip

# TODO: 记录屏蔽日志；定时检测任务和nginx定时加载配置crontab -e: 1 */1 * * * 

# ================= 参数默认值 =================
interval="${1:-5}"      # 定时检测间隔（分钟），默认5
last_minutes="${2:-5}"  # 检测的时间窗口（分钟），默认5
count="${3:-600}"       # 单位时间内最大允许请求次数，默认600

# ===== 黑名单检测开关 =====
ENABLE_BLACKLIST=${ENABLE_BLACKLIST:-1}
if [[ "$ENABLE_BLACKLIST" != "1" || "$1" == "off" || "$1" == "--disable" ]]; then
  echo "黑名单检测功能已禁用。"
  exit 0
fi

# 获取脚本所在目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
CONF_DIR="$BASE_DIR/conf"
CONF_FILE="$CONF_DIR/nginx.conf"

# nginx ip 黑名单文件路径
black_file=$CONF_DIR/conf.d/ip-black.conf

# 从 nginx.conf 提取日志路径（优先使用配置文件中的路径，否则用默认路径）
ngx_log=$(grep -E '^\s*access_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';')
[ -z "$ngx_log" ] && ngx_log="/var/log/nginx/access.log"
log_file=$(grep -E '^\s*error_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';')
[ -z "$log_file" ] && log_file="/var/log/nginx/ip-black.log"

# 获取本机IP（优先用ip.sh，否则自动检测，兼容Linux和macOS）
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

# 拒绝计数，大于0时，nginx重新加载配置文件
deny_count=0

# 当前脚本全路径，用于crontab定时任务
f=$CURRENT_DIR/${0##*/}
cron_job="*/$interval * * * * bash $f --interval $interval --window $last_minutes --count $count"
# 先清理所有与本脚本相关的定时任务，再添加一条最新的
(crontab -l 2>/dev/null | grep -v "$f"; echo "$cron_job") | crontab -
# 删除job示例：#( crontab -l | grep -v"$cron_job" ) | crontab - 
#crontab -r -u USERNAME

# 日志文件和黑名单文件不存在时自动创建
[ ! -f $ngx_log ] && exit 0
[ ! -f $black_file ] && touch $black_file

# 封装屏蔽IP的函数，避免重复添加
function denyIp () {
  # 如果IP未被屏蔽，则追加到黑名单并记录日志
  [ -z "`grep " $1" $black_file`" ] && deny_count=$(( $deny_count + 1 )) && echo "`date "+%Y-%m-%d %H:%M:%S"` deny $1;" >> $log_file  && echo "deny $1;" >> $black_file
}

# 1. 屏蔽所有php请求ip（出现40x/50x状态码，且不是本机IP）
for h in `grep php $ngx_log |grep -v "$ip" |grep -E "40[0-9]|50[1-9]"|awk -F ' ' '{print $1}'|sort -u`
do
  denyIp $h
done

# 2. 统计单位时间内请求次数过多的IP并屏蔽
# N分钟前的时间
start_time=`date -d"$last_minutes minutes ago" +"%d/%b/%Y":"%H:%M:%S"`
# 当前时间
stop_time=`date +"%d/%b/%Y":"%H:%M:%S"`
# 过滤出单位时间内的日志并统计ip及请求数，超过阈值的IP加入黑名单
ips=`tac $ngx_log | awk -v st=$start_time -v et=$stop_time '{t=substr($4,2);if(t>=st && t<=et){print $1}}' |sort | uniq -c | sort -nr| awk '{if($1>$count)print $2}'`
for line in $ips
do
    result=$(grep $line $black_file)
    # 判断ip是否已经被屏蔽
    if [ -z "$result" ]; then
        # 未屏蔽的ip进行屏蔽
        denyIp $line
    fi
done

# deny_count大于0时，nginx重新加载配置文件（动态生效黑名单）
[ $deny_count -gt 0 ] && echo "`date "+%Y-%m-%d %H:%M:%S"` deny count: $deny_count" >> $log_file && nginx -c ${CURRENT_DIR%/*}/conf/nginx -s reload


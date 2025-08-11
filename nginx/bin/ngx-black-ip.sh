#!/bin/bash
# 检测nginx日志，自动屏蔽ip黑名单，默认不启用(推荐Nginx+Lua+Redis的动态黑名单方案或结合 fail2ban 实现强大的防御)：
# 1. 屏蔽php请求ip（出现40x/50x状态码）
# 2. 单位时间内过于频繁的请求ip

# ================= 参数默认值 =================
interval="${1:-5}"      # 定时检测间隔（分钟），默认5
last_minutes="${2:-5}"  # 检测的时间窗口（分钟），默认5
count="${3:-600}"       # 单位时间内最大允许请求次数，默认600

# 获取脚本所在目录
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=${CURRENT_DIR%/*}
CONF_DIR="$BASE_DIR/conf"
CONF_FILE="$CONF_DIR/nginx.conf"

# nginx ip 黑名单文件路径
black_file="$CONF_DIR/conf.d/ip-black.conf"
log_file=$(grep -E '^\s*error_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';' | head -n1)
[ -z "$log_file" ] && log_file="/var/log/nginx/ip-black.log"

# 黑名单检测 默认关闭
ENABLE_BLACKLIST=${ENABLE_BLACKLIST:-0}

# 封装定时任务清理函数
remove_cron_job() {
  echo "正在清理可能存在的定时任务..."
  # 使用更精确的匹配删除当前脚本的定时任务
  (crontab -l 2>/dev/null | grep -v "$(basename "$f")") | crontab - 2>/dev/null || true
  sudo sh -c '(crontab -l 2>/dev/null | grep -v "$(basename "$f")") | crontab -' 2>/dev/null || true
}

if [[ "$ENABLE_BLACKLIST" != "1" || "$1" == "off" || "$1" == "--disable" ]]; then
  echo "黑名单检测功能已禁用。"
  remove_cron_job
  exit 0
fi

# 屏蔽IP函数
defineIp () {
  [ -z "`grep \" $1\" $black_file`" ] && deny_count=$((deny_count + 1)) && echo "`date "+%Y-%m-%d %H:%M:%S"` deny $1;" >> $log_file && echo "deny $1;" >> $black_file
}

# 获取日志路径
ngx_log=$(grep -E '^\s*access_log' "$CONF_FILE" | awk '{print $2}' | tr -d ';' | head -n1)
[ -z "$ngx_log" ] && ngx_log="/var/log/nginx/access.log"

# 获取本机IP
ip_sh="$(find "$BASE_DIR" -type f -name ip.sh 2>/dev/null | head -n 1)"
if [ -n "$ip_sh" ]; then
  ip=$(bash "$ip_sh")
else
  if command -v ip > /dev/null 2>&1; then
    ip=$(ip addr | awk '/inet / && !/127.0.0.1/ {sub("/.*", "", $2); print $2; exit}')
  elif command -v ifconfig > /dev/null 2>&1; then
    ip=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
  else
    ip=""
  fi
fi

deny_count=0
f=$CURRENT_DIR/${0##*/}
cron_job="*/$interval * * * * bash $f --interval $interval --window $last_minutes --count $count"

user_crontab=$(crontab -l 2>/dev/null | grep -v "$f" || true)
root_crontab=$(sudo crontab -l 2>/dev/null | grep -v "$f" || true)

# 添加定时任务
if [ "$(id -u)" -eq 0 ] || [ "$USER" == "root" ]; then
  if [[ -z "$root_crontab" || ! "$root_crontab" == *"$f"* ]]; then
    echo "$cron_job" | sudo tee >(crontab -) > /dev/null
    echo "定时任务已添加到root用户的crontab。"
  else
    echo "定时任务已存在于root用户的crontab中。"
  fi
else
  if [[ -z "$user_crontab" || ! "$user_crontab" == *"$f"* ]]; then
    (echo "$user_crontab"; echo "$cron_job") | crontab -
    echo "定时任务已添加到当前用户的crontab。"
  else
    echo "定时任务已存在于当前用户的crontab中。"
  fi
fi

[ ! -f "$ngx_log" ] && exit 0
[ ! -f "$black_file" ] && touch "$black_file"

# 1. 屏蔽所有php请求ip（出现40x/50x状态码，且不是本机IP）
for h in $(grep php "$ngx_log" | grep -v "$ip" | grep -E "40[0-9]|50[1-9]" | awk '{print $1}' | sort -u); do
  defineIp "$h"
done

# 2. 统计单位时间内请求次数过多的IP并屏蔽
start_time=$(date -d "${last_minutes} minutes ago" +"%d/%b/%Y:%H:%M:%S")
end_time=$(date +"%d/%b/%Y:%H:%M:%S")

ips=$(awk -v st="$start_time" -v et="$end_time" -v ip="$ip" '
    substr($4,2) >= st && substr($4,2) <= et {
        if ($1 != ip) count[$1]++
    }
    END {
        for (i in count) if (count[i] > ENVIRON["count"]) print i
    }' "$ngx_log")

for ip_to_block in $ips; do
  [ -z "$(grep "$ip_to_block" "$black_file")" ] && defineIp "$ip_to_block"
done

# 重载 Nginx
[ $deny_count -gt 0 ] && echo "`date "+%Y-%m-%d %H:%M:%S"` deny count: $deny_count" >> "$log_file" && nginx -c "$CONF_FILE" -s reload
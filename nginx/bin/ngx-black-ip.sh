#!/bin/bash
# 检测nginx日志，自动屏蔽ip黑名单：
# 1. 屏蔽php请求ip（出现40x/50x状态码）
# 2. 单位时间内过于频繁的请求ip

# TODO: 记录屏蔽日志；定时检测任务和nginx定时加载配置crontab -e: 1 */1 * * * 

# ================= 参数默认值 =================
# 从命令行参数获取或使用默认值
while [[ $# -gt 0 ]]; do
    case $1 in
        --enable)
            ENABLE_BLACKLIST=1
            shift
            ;;
        --disable)
            ENABLE_BLACKLIST=0
            shift
            ;;
        --interval)
            interval="$2"
            shift 2
            ;;
        --window)
            last_minutes="$2"
            shift 2
            ;;
        --count)
            count="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --enable          启用黑名单检测功能"
            echo "  --disable         禁用黑名单检测功能"
            echo "  --interval MINUTES 定时检测间隔（分钟），默认5"
            echo "  --window MINUTES  检测的时间窗口（分钟），默认5"
            echo "  --count NUMBER    单位时间内最大允许请求次数，默认600"
            echo "  --help, -h        显示此帮助信息"
            echo ""
            echo "默认情况下功能是禁用的，可以通过设置环境变量ENABLE_BLACKLIST=1启用"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# 设置默认值
interval="${interval:-5}"      # 定时检测间隔（分钟），默认5
last_minutes="${last_minutes:-5}"  # 检测的时间窗口（分钟），默认5
count="${count:-600}"       # 单位时间内最大允许请求次数，默认600

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
  local script_name=$(basename "$f")
  (crontab -l 2>/dev/null | grep -v "$script_name") | crontab - 2>/dev/null || true
  sudo sh -c '(crontab -l 2>/dev/null | grep -v "$script_name") | crontab -' 2>/dev/null || true
}

# 检查是否启用功能
if [[ "$ENABLE_BLACKLIST" != "1" ]]; then
  echo "黑名单检测功能已禁用。"
  echo "可以通过以下方式启用："
  echo "1. 设置环境变量：export ENABLE_BLACKLIST=1"
  echo "2. 命令行参数：$0 --enable"
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
# 使用唯一标识符来避免重复添加定时任务
cron_job_id="#nginx-blacklist-$(basename "$f")"
cron_job="*/$interval * * * * bash $f --enable --interval $interval --window $last_minutes --count $count $cron_job_id"

# 检查是否已存在定时任务
user_crontab=$(crontab -l 2>/dev/null | grep -v "$cron_job_id" || true)
root_crontab=$(sudo crontab -l 2>/dev/null | grep -v "$cron_job_id" || true)

# 添加定时任务
if [ "$(id -u)" -eq 0 ] || [ "$USER" == "root" ]; then
  if crontab -l 2>/dev/null | grep -q "$cron_job_id"; then
    echo "定时任务已存在于root用户的crontab中。"
  else
    # 添加新的定时任务
    (echo "$user_crontab"; echo "$cron_job") | sudo crontab -
    echo "定时任务已添加到root用户的crontab。"
  fi
else
  if crontab -l 2>/dev/null | grep -q "$cron_job_id"; then
    echo "定时任务已存在于当前用户的crontab中。"
  else
    # 添加新的定时任务
    (echo "$user_crontab"; echo "$cron_job") | crontab -
    echo "定时任务已添加到当前用户的crontab。"
  fi
fi

[ ! -f "$ngx_log" ] && exit 0
[ ! -f "$black_file" ] && touch "$black_file"

# 读取自定义配置文件（如果存在）
config_file="$CONF_DIR/blacklist.conf"
if [ -f "$config_file" ]; then
  echo "加载自定义配置文件: $config_file"
  source "$config_file"
fi

# 设置默认检测规则（如果配置文件中未定义）
block_php_requests=${block_php_requests:-1}
detect_frequent_requests=${detect_frequent_requests:-1}
blocked_status_codes=${blocked_status_codes:-"40[0-9]|50[1-9]"}

# 1. 屏蔽所有php请求ip（出现40x/50x状态码，且不是本机IP）
if [ "$block_php_requests" = "1" ]; then
  for h in $(grep php "$ngx_log" | grep -v "$ip" | grep -E "$blocked_status_codes" | awk '{print $1}' | sort -u); do
    defineIp "$h"
  done
fi

# 2. 统计单位时间内请求次数过多的IP并屏蔽
if [ "$detect_frequent_requests" = "1" ]; then
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
fi

# 重载 Nginx
[ $deny_count -gt 0 ] && echo "`date "+%Y-%m-%d %H:%M:%S"` deny count: $deny_count" >> "$log_file" && nginx -c "$CONF_FILE" -s reload
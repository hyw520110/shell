#!/bin/bash
# 设置更严格的错误处理
set -euo pipefail
IFS=$'\n\t'

# 脚本调试模式
DEBUG=${DEBUG:-false}
if [ "$DEBUG" = true ]; then
    set -x
fi

# 常量定义
readonly SCRIPT_NAME=$(basename "$0")
readonly CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR=${CURRENT_DIR%/*}
readonly DEFAULT_INTERVAL=5
readonly DEFAULT_WINDOW=5
readonly DEFAULT_COUNT=600

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*" >&2
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    exit 1
}

debug() {
    if [[ ${DEBUG:-false} == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
    fi
}

# IP验证函数
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        while IFS='.' read -r i1 i2 i3 i4; do
            [[ $i1 -le 255 && $i2 -le 255 && $i3 -le 255 && $i4 -le 255 ]]
        done <<< "$ip"
        return $?
    else
        return 1
    fi
}

# 检查数字参数
validate_number() {
    local num="$1"
    if [[ $num =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

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
            if validate_number "$2"; then
                interval="$2"
                shift 2
            else
                error "无效的定时检测间隔: $2"
            fi
            ;;
        --window)
            if validate_number "$2"; then
                last_minutes="$2"
                shift 2
            else
                error "无效的时间窗口: $2"
            fi
            ;;
        --count)
            if validate_number "$2"; then
                count="$2"
                shift 2
            else
                error "无效的请求次数: $2"
            fi
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --enable          启用黑名单检测功能"
            echo "  --disable         禁用黑名单检测功能"
            echo "  --interval MINUTES 定时检测间隔（分钟），默认$DEFAULT_INTERVAL"
            echo "  --window MINUTES  检测的时间窗口（分钟），默认$DEFAULT_WINDOW"
            echo "  --count NUMBER    单位时间内最大允许请求次数，默认$DEFAULT_COUNT"
            echo "  --help, -h        显示此帮助信息"
            echo ""
            echo "默认情况下功能是禁用的，可以通过设置环境变量ENABLE_BLACKLIST=1启用"
            exit 0
            ;;
        *)
            error "未知参数: $1"
            ;;
    esac
done

# 设置默认值
interval="${interval:-$DEFAULT_INTERVAL}"      # 定时检测间隔（分钟），默认5
last_minutes="${last_minutes:-$DEFAULT_WINDOW}"  # 检测的时间窗口（分钟），默认5
count="${count:-$DEFAULT_COUNT}"       # 单位时间内最大允许请求次数，默认600

# 获取脚本所在目录
CONF_DIR="$BASE_DIR/conf"
CONF_FILE="$CONF_DIR/nginx.conf"

# nginx ip 黑名单文件路径
black_file="$CONF_DIR/conf.d/ip-black.conf"

# 安全地获取日志文件路径，避免命令注入
log_file=$(grep -E '^\s*error_log' "$CONF_FILE" | head -n1 | awk '{print $2}' | tr -d ';')
[ -z "$log_file" ] && log_file="/var/log/nginx/ip-black.log"

# 黑名单检测 默认关闭
ENABLE_BLACKLIST=${ENABLE_BLACKLIST:-0}

# 封装定时任务清理函数
remove_cron_job() {
  echo "正在清理可能存在的定时任务..."
  # 使用更精确的匹配删除当前脚本的定时任务
  local script_name=$(basename "$0")
  (crontab -l 2>/dev/null | grep -v "$script_name") | crontab - 2>/dev/null || true
  sudo sh -c '(crontab -l 2>/dev/null | grep -v "$script_name") | crontab -' 2>/dev/null || true
}

# 检查是否启用功能
if [[ "$ENABLE_BLACKLIST" != "1" ]]; then
  log "黑名单检测功能已禁用。"
  log "可以通过以下方式启用："
  log "1. 设置环境变量：export ENABLE_BLACKLIST=1"
  log "2. 命令行参数：$0 --enable"
  remove_cron_job
  exit 0
fi

# 封装定时任务清理函数
remove_cron_job() {
  log "正在清理可能存在的定时任务..."
  # 使用更精确的匹配删除当前脚本的定时任务
  local script_name=$(basename "$0")
  (crontab -l 2>/dev/null | grep -v "$script_name" | grep -v "nginx-blacklist") | crontab - 2>/dev/null || true
  sudo sh -c '(crontab -l 2>/dev/null | grep -v "$script_name" | grep -v "nginx-blacklist") | crontab -' 2>/dev/null || true
}

# 屏蔽IP函数
defineIp () {
    local ip="$1"

    # 验证IP格式
    if ! validate_ip "$ip"; then
        debug "无效IP地址，跳过: $ip"
        return 1
    fi

    # 检查IP是否已存在于黑名单中
    if ! grep -q "^deny $ip;" "$black_file" 2>/dev/null; then
        echo "$(date "+%Y-%m-%d %H:%M:%S") deny $ip;" >> "$log_file"
        echo "deny $ip;" >> "$black_file"
        deny_count=$((deny_count + 1))
        log "已添加IP到黑名单: $ip"
    fi
}

# 获取日志路径
ngx_log=$(grep -E '^\s*access_log' "$CONF_FILE" | head -n1 | awk '{print $2}' | tr -d ';')
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

# 验证本机IP格式
if [ -n "$ip" ] && ! validate_ip "$ip"; then
    log "警告: 无法获取有效的本机IP地址"
    ip=""
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
    log "定时任务已存在于root用户的crontab中。"
  else
    # 添加新的定时任务
    (echo "$user_crontab"; echo "$cron_job") | sudo crontab -
    log "定时任务已添加到root用户的crontab。"
  fi
else
  if crontab -l 2>/dev/null | grep -q "$cron_job_id"; then
    log "定时任务已存在于当前用户的crontab中。"
  else
    # 添加新的定时任务
    (echo "$user_crontab"; echo "$cron_job") | crontab -
    log "定时任务已添加到当前用户的crontab。"
  fi
fi

if [ ! -f "$ngx_log" ]; then
    log "日志文件不存在: $ngx_log"
    exit 0
fi

if [ ! -f "$black_file" ]; then
    # 确保目录存在
    mkdir -p "$(dirname "$black_file")"
    touch "$black_file"
    log "创建黑名单文件: $black_file"
fi

# 读取自定义配置文件（如果存在）
config_file="$CONF_DIR/blacklist.conf"
if [ -f "$config_file" ]; then
  log "加载自定义配置文件: $config_file"
  # 验证配置文件安全性
  if [ -r "$config_file" ]; then
    source "$config_file"
  else
    log "配置文件无读取权限: $config_file"
  fi
fi

# 设置默认检测规则（如果配置文件中未定义）
block_php_requests=${block_php_requests:-1}
detect_frequent_requests=${detect_frequent_requests:-1}
blocked_status_codes=${blocked_status_codes:-"40[0-9]|50[1-9]"}

log "开始分析日志: $ngx_log"

# 1. 屏蔽所有php请求ip（出现40x/50x状态码，且不是本机IP）
if [ "$block_php_requests" = "1" ]; then
  log "检查PHP请求的异常状态码..."
  while IFS= read -r line; do
    # 提取IP地址
    local ip_addr=$(echo "$line" | awk '{print $1}')
    if [ -n "$ip_addr" ] && [ "$ip_addr" != "$ip" ] && validate_ip "$ip_addr"; then
        defineIp "$ip_addr"
    fi
  done < <(grep "php" "$ngx_log" 2>/dev/null | grep -v "$ip" | grep -E "$blocked_status_codes" | awk '{print $0}' | sort -u)
fi

# 2. 统计单位时间内请求次数过多的IP并屏蔽
if [ "$detect_frequent_requests" = "1" ]; then
  log "检查频繁请求的IP地址..."
  start_time=$(date -d "${last_minutes} minutes ago" +"%d/%b/%Y:%H:%M:%S")
  end_time=$(date +"%d/%b/%Y:%H:%M:%S")

  # 使用awk处理日志，找出频繁请求的IP
  ips=$(awk -v st="$start_time" -v et="$end_time" -v local_ip="$ip" '
      substr($4,2) >= st && substr($4,2) <= et {
          if ($1 != local_ip) count[$1]++
      }
      END {
          for (i in count) if (count[i] > ENVIRON["count"]) print i
      }' "$ngx_log" 2>/dev/null)

  if [ -n "$ips" ]; then
    for ip_to_block in $ips; do
        if validate_ip "$ip_to_block"; then
            defineIp "$ip_to_block"
        fi
    done
  fi
fi

# 重载 Nginx
if [ $deny_count -gt 0 ]; then
    log "共有 $deny_count 个IP被添加到黑名单中"
    echo "$(date "+%Y-%m-%d %H:%M:%S") deny count: $deny_count" >> "$log_file"

    # 测试配置语法
    if nginx -t -c "$CONF_FILE" 2>/dev/null; then
        nginx -c "$CONF_FILE" -s reload
        log "Nginx配置重载成功"
    else
        error "Nginx配置测试失败，未重载配置"
    fi
else
    log "没有新的IP被添加到黑名单"
fi

log "IP黑名单检查完成"
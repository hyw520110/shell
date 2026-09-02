#!/bin/bash

# 脚本功能：监控系统核心资源（CPU、内存、磁盘），并在超限时发送邮件报警。

# --- 配置 ---
CPU_THRESHOLD=80
MEM_THRESHOLD=80
DISK_THRESHOLD=80
# 要检查的磁盘挂载点，例如 "/" 或 "/data"
DISK_MOUNT_POINT="/"
# 报警接收邮箱
ALERT_EMAIL="1135960569@qq.com"
# 用于发送邮件的日志文件
ALERT_LOG_FILE="/tmp/system_monitor_alert.log"
# --- 结束配置 ---

# --- 函数定义 ---

# 函数：获取CPU使用率
# 通过对比/proc/stat在一秒前后的快照来精确计算
get_cpu_usage() {
    read -r cpu user nice system idle iowait irq softirq steal < /proc/stat
    local prev_idle=$idle
    local prev_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    sleep 1
    read -r cpu user nice system idle iowait irq softirq steal < /proc/stat
    local current_idle=$idle
    local current_total=$((user + nice + system + idle + iowait + irq + softirq + steal))

    local total_diff=$((current_total - prev_total))
    local idle_diff=$((current_idle - prev_idle))
    
    # 避免除以0
    if [ $total_diff -eq 0 ]; then
        echo 0
    else
        echo $((100 * (total_diff - idle_diff) / total_diff))
    fi
}

# 函数：获取内存使用率
# 通过/proc/meminfo计算，MemAvailable是内核认为真正可用的内存
get_mem_usage() {
    awk '
        /MemTotal/ {total=$2}
        /MemAvailable/ {avail=$2}
        END {
            used = total - avail
            printf "%.0f\n", (used/total)*100
        }
    ' /proc/meminfo
}

# 函数：获取指定挂载点的磁盘使用率
get_disk_usage() {
    local mount_point="$1"
    # 使用df的--output选项，直接、可靠地获取纯数字百分比
    df --output=pcent "$mount_point" | tail -n 1 | tr -d ' %'
}

# --- 主逻辑 ---
main() {
    # 获取各项资源的使用率
    cpu_usage=$(get_cpu_usage)
    mem_usage=$(get_mem_usage)
    disk_usage=$(get_disk_usage "$DISK_MOUNT_POINT")
    now_time=$(date '+%F %T')
    
    alert_needed=false
    alert_message=""

    # 使用正确的数字比较操作符 -gt
    if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
        alert_needed=true
        alert_message+="CPU 报警: 使用率 ${cpu_usage}% (阈值: ${CPU_THRESHOLD}%)\n"
    fi

    if [ "$mem_usage" -gt "$MEM_THRESHOLD" ]; then
        alert_needed=true
        alert_message+="内存 报警: 使用率 ${mem_usage}% (阈值: ${MEM_THRESHOLD}%)\n"
    fi

    if [ "$disk_usage" -gt "$DISK_THRESHOLD" ]; then
        alert_needed=true
        alert_message+="磁盘 [${DISK_MOUNT_POINT}] 报警: 使用率 ${disk_usage}% (阈值: ${DISK_THRESHOLD}%)\n"
    fi

    # 如果需要报警，则准备日志并发送邮件
    if [ "$alert_needed" = true ]; then
        echo "--- 系统监控报警 [${now_time}] ---" > "$ALERT_LOG_FILE"
        echo -e "$alert_message" >> "$ALERT_LOG_FILE"
        
        echo "检测到资源超限，发送报警邮件至 ${ALERT_EMAIL}..."
        mail -s "【系统监控报警】" "$ALERT_EMAIL" < "$ALERT_LOG_FILE"
        echo "报警邮件已发送。"
    else
        echo "状态正常: CPU=${cpu_usage}%, 内存=${mem_usage}%, 磁盘(${DISK_MOUNT_POINT})=${disk_usage}%"
    fi
}

# 执行主函数
main
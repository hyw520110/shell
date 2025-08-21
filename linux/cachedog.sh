#!/bin/bash

# 脚本功能：持续监控可用内存，当低于指定阈值时自动清理系统缓存。

set -eo pipefail

# --- 配置 ---
# 可用内存阈值（MB）。当可用内存低于此值时，将触发缓存清理。
MEM_AVAILABLE_THRESHOLD_MB=512 

# 要清理的缓存类型：
# 1: 只清理页缓存
# 2: 只清理dentries和inodes
# 3: 清理页缓存、dentries和inodes (最彻底)
DROP_CACHES_TYPE=3

# 检查间隔（秒）
CHECK_INTERVAL_SECONDS=5

# --- 结束配置 ---

# --- 辅助函数 ---
log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [信息] $1"; }
warn_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [警告] $1"; }
error_exit() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [错误] $1" >&2; exit 1; }

# --- 主逻辑 ---
main() {
    # 1. 检查是否为root用户
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "此脚本必须以root权限运行。"
    fi

    # 2. 检查 sysctl 命令是否存在
    if ! command -v sysctl &>/dev/null; then
        error_exit "'sysctl' 命令未找到。"
    fi

    log_message "启动 cachedog 监控。每 ${CHECK_INTERVAL_SECONDS} 秒检查一次。"
    log_message "当可用内存低于 ${MEM_AVAILABLE_THRESHOLD_MB} MB 时，将清理缓存 (类型 ${DROP_CACHES_TYPE})。"

    while true; do
        # 从 /proc/meminfo 获取 MemAvailable (单位KB)
        local mem_available_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        local mem_available_mb=$((mem_available_kb / 1024))

        if [ "$mem_available_mb" -le "$MEM_AVAILABLE_THRESHOLD_MB" ]; then
            log_message "检测到内存压力！可用内存: ${mem_available_mb} MB (阈值: ${MEM_AVAILABLE_THRESHOLD_MB} MB)。"
            log_message "正在清理缓存 (vm.drop_caches=${DROP_CACHES_TYPE})..."
            
            # 执行缓存清理
            if sysctl -w vm.drop_caches="$DROP_CACHES_TYPE" > /dev/null; then
                log_message "缓存清理成功。"
                # 清理后再次获取可用内存
                local mem_available_new_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
                local mem_available_new_mb=$((mem_available_new_kb / 1024))
                log_message "清理后可用内存: ${mem_available_new_mb} MB。"
            else
                warn_message "清理缓存失败。请检查权限或系统状态。"
            fi
        else
            log_message "内存状态良好。可用内存: ${mem_available_mb} MB (阈值: ${MEM_AVAILABLE_THRESHOLD_MB} MB)。"
        fi

        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

# 执行主函数
main "$@"
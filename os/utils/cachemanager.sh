#!/bin/bash

# 缓存管理工具 - 整合了多个缓存清理和配置脚本
# 功能：
#   monitor - 持续监控内存并自动清理缓存
#   clean   - 手动清理系统缓存
#   config  - 设置内核缓存保留参数
#   status  - 查看当前缓存状态

set -eo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 配置 ---
# 默认可用内存阈值（MB）
DEFAULT_MEM_AVAILABLE_THRESHOLD_MB=512
# 默认检查间隔（秒）
DEFAULT_CHECK_INTERVAL_SECONDS=5
# 默认清理类型：1=页缓存，2=dentries和inodes，3=全部
DEFAULT_DROP_CACHES_TYPE=3
# --- 结束配置 ---

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} [$1] $2"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} [$1] $2"; }
log_error() { echo -e "${RED}[错误]${NC} [$1] $2" >&2; }

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# 全局变量：操作系统类型
OS_TYPE=$(detect_os)

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "此脚本必须以root权限运行。请使用 'sudo $0 $@'"
        exit 1
    fi
}

# 检查sysctl命令
check_sysctl() {
    if ! command -v sysctl &>/dev/null; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "'sysctl' 命令未找到。"
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 <命令> [参数]

命令:
  monitor [阈值] [间隔]  持续监控内存并自动清理缓存
                         - 阈值：可用内存阈值（MB），默认 ${DEFAULT_MEM_AVAILABLE_THRESHOLD_MB}
                         - 间隔：检查间隔（秒），默认 ${DEFAULT_CHECK_INTERVAL_SECONDS}
                         - 示例: $0 monitor 512 5

  clean                  手动清理系统缓存
                         - 清理类型：3（页缓存、dentries和inodes）
                         - 示例: $0 clean

  config [GB]             设置内核缓存保留参数
                         - GB：保留的空闲内存大小（GB）
                         - 示例: $0 config 15

  status                 查看当前缓存状态
                         - 示例: $0 status

  -h, --help             显示此帮助信息

EOF
}

# 清理缓存的通用函数
# 参数: 清理类型 (1, 2, 或 3)
drop_caches() {
    local cache_type=$1
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "正在清理缓存 (vm.drop_caches=${cache_type})..."
    
    if sysctl -w vm.drop_caches="$cache_type" > /dev/null; then
        log_info "$(date '+%Y-%m-%d %H:%M:%S')" "缓存清理成功。"
        return 0
    else
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "清理缓存失败。请检查权限或系统状态。"
        return 1
    fi
}

# --- 命令: status ---
cmd_status() {
    echo "=== 当前系统内存状态 ==="
    if [ "$OS_TYPE" == "linux" ]; then
        free -h
    elif [ "$OS_TYPE" == "macos" ]; then
        # macOS 使用 vm_stat
        vm_stat | perl -ne '/page size of (\d+)/ and $ps=$1; /Pages free:\s+(\d+)/ and printf "可用内存: %.2f GB\n", $1*$ps/1024/1024/1024; /Pages active:\s+(\d+)/ and printf "活跃内存: %.2f GB\n", $1*$ps/1024/1024/1024; /Pages inactive:\s+(\d+)/ and printf "非活跃内存: %.2f GB\n", $1*$ps/1024/1024/1024; /Pages wired:\s+(\d+)/ and printf " wired 内存: %.2f GB\n", $1*$ps/1024/1024/1024; /Pages speculative:\s+(\d+)/ and printf "推测内存: %.2f GB\n", $1*$ps/1024/1024/1024;'
        total_memory=$(sysctl -n hw.memsize)
        printf "总内存: %.2f GB\n" $(echo "$total_memory/1024/1024/1024" | bc -l)
    else
        echo "不支持的操作系统: $OS_TYPE"
    fi
    echo
    
    if [ "$OS_TYPE" == "linux" ]; then
        echo "=== 详细内存信息 ==="
        if [ -f /proc/meminfo ]; then
            echo "MemAvailable: $(awk '/MemAvailable/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
            echo "MemFree:      $(awk '/MemFree/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
            echo "Buffers:      $(awk '/Buffers/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
            echo "Cached:       $(awk '/^Cached/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
            echo "Slab:         $(awk '/Slab/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
        fi
        echo
        
        echo "=== 内核缓存参数 ==="
        sysctl vm.min_free_kbytes 2>/dev/null || echo "vm.min_free_kbytes: (未设置)"
        sysctl vm.extra_free_kbytes 2>/dev/null || echo "vm.extra_free_kbytes: (未设置)"
        sysctl vm.drop_caches 2>/dev/null || echo "vm.drop_caches: (未设置)"
        echo
        
        if [ -f /proc/zoneinfo ]; then
            echo "=== Zone 内存状态 (Normal) ==="
            nr_free_pages=$(fgrep -A 10 Normal /proc/zoneinfo 2>/dev/null | grep nr_free_pages | awk -F ' ' '{print $2}')
            high=$(fgrep -A 10 Normal /proc/zoneinfo 2>/dev/null | grep high | awk -F ' ' '{print $2}')
            if [ -n "$nr_free_pages" ] && [ -n "$high" ]; then
                echo "nr_free_pages: $nr_free_pages"
                echo "high:          $high"
                if [ "$nr_free_pages" -le "$high" ]; then
                    echo "状态: ${RED}内存不足${NC}"
                else
                    echo "状态: ${GREEN}内存充足${NC}"
                fi
            fi
        fi
    else
        echo "=== 注意 ==="
        echo "此脚本主要针对 Linux 系统设计。"
        echo "在 macOS 上，monitor、clean 和 config 命令可能无法正常工作。"
        echo "只有 status 命令在 macOS 上可用。"
    fi
}

# --- 命令: clean ---
cmd_clean() {
    if [ "$OS_TYPE" == "macos" ]; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "macOS 不支持直接清理缓存。"
        echo
        echo "=== 当前内存状态 ==="
        echo "可用内存: $(vm_stat | perl -ne '/page size of (\d+)/ and $ps=$1; /Pages free:\s+(\d+)/ and printf "%.2f MB\n", $1*$ps/1024/1024')"
        echo
        echo "macOS 会自动管理内存，不需要手动清理缓存。"
        echo "如果内存不足，macOS 会自动压缩不活跃的内存页面。"
        echo
        echo "提示：可以尝试关闭不需要的应用程序来释放内存。"
        exit 1
    fi
    
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "开始手动清理缓存..."
    
    echo "=== 清理前内存状态 ==="
    free -h
    echo
    
    # 同步文件系统，确保所有待写数据落盘
    sync
    
    # 执行清理
    if drop_caches 3; then
        echo
        echo "=== 清理后内存状态 ==="
        free -h
        log_info "$(date '+%Y-%m-%d %H:%M:%S')" "缓存清理完成。"
    else
        exit 1
    fi
}

# --- 命令: config ---
cmd_config() {
    if [ "$OS_TYPE" == "macos" ]; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "macOS 不支持设置 Linux 内核缓存参数。"
        echo
        echo "此功能仅适用于 Linux 系统。"
        echo "macOS 有自己的内存管理机制，无需手动配置缓存参数。"
        exit 1
    fi
    
    local gb=${1:-15}
    
    if ! [[ "$gb" =~ ^[0-9]+$ ]]; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "参数必须是数字。"
        exit 1
    fi
    
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "设置内核缓存保留参数：${gb}GB"
    
    # 设置 vm.extra_free_kbytes 和 vm.min_free_kbytes
    sysctl -w vm.extra_free_kbytes=$((3 * gb * 1024 * 1024))
    sysctl -w vm.min_free_kbytes=$((1 * gb * 1024 * 1024))
    
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "配置完成。"
    echo "当前配置："
    sysctl vm.extra_free_kbytes vm.min_free_kbytes
}

# --- 命令: monitor (使用 MemAvailable 指标) ---
cmd_monitor_memavailable() {
    local threshold=${1:-$DEFAULT_MEM_AVAILABLE_THRESHOLD_MB}
    local interval=${2:-$DEFAULT_CHECK_INTERVAL_SECONDS}
    local cache_type=${3:-$DEFAULT_DROP_CACHES_TYPE}
    
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "启动缓存监控 (MemAvailable 模式)"
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "检查间隔: ${interval}秒, 阈值: ${threshold}MB, 清理类型: ${cache_type}"
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "按 Ctrl+C 停止监控"
    echo
    
    while true; do
        # 从 /proc/meminfo 获取 MemAvailable (单位KB)
        local mem_available_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        local mem_available_mb=$((mem_available_kb / 1024))
        
        if [ "$mem_available_mb" -le "$threshold" ]; then
            log_info "$(date '+%Y-%m-%d %H:%M:%S')" "检测到内存压力！可用内存: ${mem_available_mb}MB (阈值: ${threshold}MB)"
            
            # 执行清理
            if drop_caches "$cache_type"; then
                # 清理后再次获取可用内存
                local mem_available_new_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
                local mem_available_new_mb=$((mem_available_new_kb / 1024))
                log_info "$(date '+%Y-%m-%d %H:%M:%S')" "清理后可用内存: ${mem_available_new_mb}MB"
            fi
        else
            log_info "$(date '+%Y-%m-%d %H:%M:%S')" "内存状态良好。可用内存: ${mem_available_mb}MB (阈值: ${threshold}MB)"
        fi
        
        sleep "$interval"
    done
}

# --- 命令: monitor (使用 nr_free_pages 指标，RocketMQ 模式) ---
cmd_monitor_zone() {
    local interval=${1:-1}
    
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "启动缓存监控 (Zone 模式，兼容 RocketMQ)"
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "检查间隔: ${interval}秒"
    log_info "$(date '+%Y-%m-%d %H:%M:%S')" "按 Ctrl+C 停止监控"
    echo
    
    while true; do
        nr_free_pages=$(fgrep -A 10 Normal /proc/zoneinfo 2>/dev/null | grep nr_free_pages | awk -F ' ' '{print $2}')
        high=$(fgrep -A 10 Normal /proc/zoneinfo 2>/dev/null | grep high | awk -F ' ' '{print $2}')
        
        NOW_DATE=$(date +%D)
        NOW_TIME=$(date +%T)
        
        if [ -z "$nr_free_pages" ] || [ -z "$high" ]; then
            log_error "$NOW_DATE $NOW_TIME" "无法获取 zone 信息"
            sleep "$interval"
            continue
        fi
        
        if [ "$nr_free_pages" -le "$high" ]; then
            log_info "$NOW_DATE $NOW_TIME" "nr_free_pages < high, 清理缓存。nr_free_pages=$nr_free_pages ====> "
            
            # 先清理类型3，再清理类型1（RocketMQ 的策略）
            if drop_caches 3; then
                nr_free_pages_new=$(fgrep -A 10 Normal /proc/zoneinfo 2>/dev/null | grep nr_free_pages | awk -F ' ' '{print $2}')
                log_info "$NOW_DATE $NOW_TIME" "清理后 nr_free_pages=$nr_free_pages_new"
                
                # 再次清理类型1
                drop_caches 1
            fi
            echo
        else
            log_info "$NOW_DATE $NOW_TIME" "nr_free_pages=$nr_free_pages high=$high"
        fi
        
        sleep "$interval"
    done
}

# --- 命令: monitor (统一入口) ---
cmd_monitor() {
    if [ "$OS_TYPE" == "macos" ]; then
        log_error "$(date '+%Y-%m-%d %H:%M:%S')" "macOS 不支持缓存监控和清理功能。"
        echo
        echo "=== 当前内存状态 ==="
        echo "可用内存: $(vm_stat | perl -ne '/page size of (\d+)/ and $ps=$1; /Pages free:\s+(\d+)/ and printf "%.2f MB\n", $1*$ps/1024/1024')"
        echo
        echo "macOS 会自动管理内存，不需要手动清理或监控缓存。"
        echo "此工具主要针对 Linux 系统设计。"
        exit 1
    fi
    
    local threshold=${1:-$DEFAULT_MEM_AVAILABLE_THRESHOLD_MB}
    local interval=${2:-$DEFAULT_CHECK_INTERVAL_SECONDS}
    
    # 如果只提供一个参数且是数字，判断是阈值还是间隔
    # 如果第一个参数大于 1000，可能是间隔（秒），但这里我们简化处理
    # 默认使用 MemAvailable 模式，这是更现代的做法
    
    cmd_monitor_memavailable "$threshold" "$interval"
}

# --- 主函数 ---
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local command=$1
    shift
    
    case "$command" in
        monitor)
            check_root
            check_sysctl
            cmd_monitor "$@"
            ;;
        clean)
            check_root
            check_sysctl
            cmd_clean
            ;;
        config)
            check_root
            check_sysctl
            cmd_config "$@"
            ;;
        status)
            cmd_status
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "$(date '+%Y-%m-%d %H:%M:%S')" "未知命令: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
#!/bin/bash
# ==================== 通用工具函数模块 ====================
# 提供日志、错误处理、超时执行等基础功能
# 兼容 Bash 3.2+

# ==================== 全局常量定义 ====================

# 日志级别定义
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_QUIET=4

# 默认日志级别
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# 魔法数字常量
readonly MAX_LOG_LINES=500
readonly TRUNCATE_LOG_LINES=200
readonly MAX_TEMP_LOG_SIZE=1048576  # 1MB
readonly CACHE_TTL_DEFAULT=3600     # 1小时
readonly COMMAND_TIMEOUT_DEFAULT=30 # 30秒
readonly MAX_RETRY_ATTEMPTS=3

# 临时文件路径（统一管理）
TEMP_CMD_LOG=""
TEMP_ERROR_LOG=""

# 初始化临时文件
_init_temp_files() {
    if [[ -z "$TEMP_CMD_LOG" ]]; then
        TEMP_CMD_LOG=$(mktemp "${TMPDIR:-/tmp}/ai-cli-cmd.XXXXXX")
        chmod 600 "$TEMP_CMD_LOG" 2>/dev/null || true
    fi
    if [[ -z "$TEMP_ERROR_LOG" ]]; then
        TEMP_ERROR_LOG=$(mktemp "${TMPDIR:-/tmp}/ai-cli-error.XXXXXX")
        chmod 600 "$TEMP_ERROR_LOG" 2>/dev/null || true
    fi
}

# 立即初始化
_init_temp_files

# ==================== 颜色定义 ====================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
# 文本样式：菜单标签栏（一级分类 Tabs）依赖以下变量进行高亮/置灰
readonly BOLD='\033[1m'
readonly REVERSE='\033[7m'
readonly GRAY='\033[0;90m'








# ==================== 日志函数 ====================

# 获取格式化时间戳（带缓存，1秒内重复调用返回相同结果）
_timestamp_cache_sec=""
_timestamp_cache=""

get_timestamp() {
    local now
    # 优先使用 Bash 5.0+ 内置变量，避免调用 date
    if [[ -n "${EPOCHSECONDS:-}" ]]; then
        now="$EPOCHSECONDS"
    else
        now=$(date +%s 2>/dev/null)
    fi
    
    if [[ "$_timestamp_cache_sec" != "$now" ]]; then
        _timestamp_cache_sec="$now"
        # 优先使用 Bash 4.2+ 内置 printf，避免子进程
        if printf -v _timestamp_cache "%(%Y-%m-%d %H:%M:%S)T" "$now" 2>/dev/null; then
            :
        else
            _timestamp_cache=$(date '+%Y-%m-%d %H:%M:%S' -r "$now" 2>/dev/null || date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        fi
    fi
    echo "${_timestamp_cache}"
}

# 通用路径展开函数
expand_path() {
    local path="$1"
    [[ -z "$path" ]] && return 0
    # 只做显式、安全的常见路径展开；不要 eval，避免命令替换执行。
    if [[ "$path" == "~" ]]; then
        path="$HOME"
    elif [[ "$path" == "~/"* ]]; then
        path="${HOME}/${path:2}"
    fi
    local home_var="\$HOME"
    local braced_home_var="\${HOME}"
    path="${path//$home_var/$HOME}"
    path="${path//$braced_home_var/$HOME}"
    echo "$path"
}

# 统一日志记录函数
log() {
    local level_val=$1; shift
    [[ $LOG_LEVEL -gt $level_val ]] && return 0
    local colors=($BLUE $CYAN $YELLOW $RED)
    local labels=("DEBUG" "INFO" "WARN" "ERROR")
    local timestamp=$(get_timestamp)
    printf "${colors[$level_val]}[$timestamp ${labels[$level_val]}] %b${NC}\n" "$*" >&2
}

debug_log() { log $LOG_LEVEL_DEBUG "$@"; }
info_log()  { log $LOG_LEVEL_INFO "$@"; }
warn_log()  { log $LOG_LEVEL_WARN "$@"; }

# 成功日志与消息
success_log() {
    local timestamp=$(get_timestamp)
    printf "${GREEN}[$timestamp SUCCESS] %b${NC}\n" "$*" >&2
}

success_msg() {
    echo -e "${GREEN}✅ $*${NC}"
}

# 错误日志函数
error_log() {
    local timestamp=$(get_timestamp)
    printf "${RED}[$timestamp ERROR] %b${NC}\n" "$*" >&2
    # 写入临时错误日志
    echo "[$timestamp] $*" >> "${TEMP_ERROR_LOG}" 2>/dev/null || true
}

set_log_level() {
    case $1 in
        "debug") LOG_LEVEL=$LOG_LEVEL_DEBUG ;;
        "info")  LOG_LEVEL=$LOG_LEVEL_INFO ;;
        "warn")  LOG_LEVEL=$LOG_LEVEL_WARN ;;
        "error") LOG_LEVEL=$LOG_LEVEL_ERROR ;;
        "quiet") LOG_LEVEL=$LOG_LEVEL_QUIET ;;
        *) warn_log "未知日志级别: $1, 使用默认级别";;
    esac
}




# ==================== 超时函数 ====================

# 带超时的命令执行函数（兼容 macOS/Linux）
run_with_timeout() {
    local timeout_sec=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout $timeout_sec "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout $timeout_sec "$@"
    else
        # 后备方案：后台运行 + 等待
        local pid
        "$@" &
        pid=$!

        local count=0
        local max_ticks=$((timeout_sec * 20))
        while kill -0 $pid 2>/dev/null; do
            if [[ $count -ge $max_ticks ]]; then
                kill -9 $pid 2>/dev/null
                wait $pid 2>/dev/null
                return 124
            fi
            # 50ms 轮询，快速命令不再固定等待整整一秒。
            sleep 0.05
            ((count++))
        done

        wait $pid
        return $?
    fi
}


# ==================== UI 辅助函数 ====================

spinner_pid=""



# ==================== 文件操作封装 ====================

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查文件是否存在
file_exists() {
    [[ -f "$1" ]]
}






# ==================== 清理函数 ====================

original_tty_settings=""

cleanup() {
    rm -f "$TEMP_CMD_LOG"
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" >/dev/null 2>&1
        wait "$spinner_pid" >/dev/null 2>&1
    fi
}

handle_interrupt() {
    echo -e "\n${YELLOW}⚠️ 操作已取消${NC}"
    cleanup
    [[ -n "$original_tty_settings" ]] && stty "$original_tty_settings" 2>/dev/null
    exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

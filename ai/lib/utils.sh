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

# ==================== 颜色输出封装函数 ====================

print_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

print_error() {
    echo -e "${RED}❌ $*${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️ $*${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $*${NC}"
}

print_title() {
    echo -e "\n${CYAN}=== $* ===${NC}"
}

print_subtitle() {
    echo -e "\n${CYAN}--- $* ---${NC}"
}

print_menu_item() {
    local key="$1"
    local desc="$2"
    local status="${3:-}"
    if [[ -n "$status" ]]; then
        echo -e "$key. $desc $status"
    else
        echo -e "$key. $desc"
    fi
}

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

# ==================== 错误处理 ====================

# 通用错误处理函数
handle_error() {
    local code=$1; local msg=$2; local ctx=$3
    error_log "错误 [$code]: $msg ${ctx:+(上下文: $ctx)}"
    echo "[$(get_timestamp)] ERROR $code: $msg ($ctx)" >> "${TEMP_ERROR_LOG}" 2>/dev/null
    # 日志轮转：检查文件大小
    if [[ -f "$TEMP_ERROR_LOG" ]]; then
        local size=$(stat -f%z "$TEMP_ERROR_LOG" 2>/dev/null || stat -c%s "$TEMP_ERROR_LOG" 2>/dev/null || echo 0)
        if [[ $size -gt $MAX_TEMP_LOG_SIZE ]]; then
            tail -n 100 "$TEMP_ERROR_LOG" > "${TEMP_ERROR_LOG}.tmp" && mv "${TEMP_ERROR_LOG}.tmp" "$TEMP_ERROR_LOG" 2>/dev/null
        fi
    fi
    return $code
}

# 输入验证函数（防止命令注入）
validate_command_input() {
    local input="$1"
    local name="${2:-输入}"

    # 检查空输入
    if [[ -z "$input" ]]; then
        error_log "安全验证失败: $name 不能为空"
        return 1
    fi

    # 检查危险字符和模式
    if [[ "$input" =~ [\;\|\&\$\`\(\)\{\}] ]]; then
        error_log "安全验证失败: $name 包含危险字符"
        return 1
    fi

    # 检查路径遍历
    if [[ "$input" =~ \.\./ ]]; then
        error_log "安全验证失败: $name 包含路径遍历"
        return 1
    fi

    # 检查危险命令模式
    local dangerous_patterns=(
        "rm -rf /"
        "rm -rf \$"
        "chmod 777 /"
        "chmod 666 /"
        "dd if="
        "mkfs"
        "fdisk"
        "parted"
    )

    for pattern in "${dangerous_patterns[@]}"; do
        if [[ "$input" == *"$pattern"* ]]; then
            error_log "安全验证失败: $name 包含危险命令模式"
            return 1
        fi
    done

    return 0
}

# 增强版命令执行函数（带安全验证）
run_command_safe() {
    local command="$1"
    local timeout_sec="${2:-$COMMAND_TIMEOUT_DEFAULT}"
    local description="${3:-命令}"

    # 安全验证
    if ! validate_command_input "$command" "$description"; then
        return 1
    fi

    # 执行命令
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_sec" bash -c "$command"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$timeout_sec" bash -c "$command"
    else
        bash -c "$command"
    fi
    return $?
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
        while kill -0 $pid 2>/dev/null; do
            if [[ $count -ge $timeout_sec ]]; then
                kill -9 $pid 2>/dev/null
                wait $pid 2>/dev/null
                return 124
            fi
            sleep 1
            ((count++))
        done

        wait $pid
        return $?
    fi
}

# 带重试的命令执行函数（增强安全性）
run_with_retry() {
    local command="$1"
    local max_attempts=${2:-$MAX_RETRY_ATTEMPTS}
    local timeout=${3:-$COMMAND_TIMEOUT_DEFAULT}
    local attempt=1
    local exit_code=0

    # 验证输入
    if [[ -z "$command" ]]; then
        error_log "命令不能为空"
        return 1
    fi

    # 安全检查：禁止危险命令
    if [[ "$command" =~ rm\ -rf\ +/[[:space:]] ]] || \
       [[ "$command" =~ rm\ -rf\ +\$\{?HOME\}? ]] || \
       [[ "$command" =~ \>\ /etc/(passwd|shadow|sudoers) ]] || \
       [[ "$command" =~ chmod\ +(777|666)\ +/ ]] || \
       [[ "$command" =~ dd\ if= ]] || \
       [[ "$command" =~ \:\(\)\{[[:space:]]*:[[:space:]]*\|\;[[:space:]]*\& ]]; then
        error_log "安全拒绝: 命令包含危险操作"
        return 1
    fi

    # 确定使用的timeout命令
    local timeout_cmd="timeout"
    if ! command -v timeout >/dev/null 2>&1; then
        if command -v gtimeout >/dev/null 2>&1; then
            timeout_cmd="gtimeout"
        else
            timeout_cmd=""
        fi
    fi

    while [ $attempt -le $max_attempts ]; do
        echo -e "${YELLOW}尝试第 $attempt/$max_attempts...${NC}"

        # 使用 stdbuf 强制刷新输出缓冲区
        local stdbuf_cmd=""
        command -v stdbuf >/dev/null 2>&1 && stdbuf_cmd="stdbuf -oL -eL"

        if [[ -n "$timeout_cmd" ]]; then
            $timeout_cmd $timeout bash -c "$command" 2>&1 | $stdbuf_cmd tee -a "$TEMP_CMD_LOG"
        else
            bash -c "$command" 2>&1 | $stdbuf_cmd tee -a "$TEMP_CMD_LOG"
        fi
        exit_code=${PIPESTATUS[0]}

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✅ 命令执行成功${NC}"
            return 0
        else
            echo -e "${RED}❌ 命令执行失败，退出码: $exit_code${NC}"

            if [ $attempt -lt $max_attempts ]; then
                echo -e "${CYAN}等待 2 秒后重试...${NC}"
                sleep 2
            fi
        fi

        attempt=$((attempt + 1))
    done

    echo -e "${RED}❌ 命令执行失败，已达到最大重试次数 $max_attempts${NC}"
    echo -e "${CYAN}--- 失败日志 ---${NC}"
    cat "$TEMP_CMD_LOG"
    echo -e "${CYAN}----------------${NC}"
    return $exit_code
}

# ==================== UI 辅助函数 ====================

spinner_pid=""

start_spinner() {
    local msg="$1"
    if [[ ! -t 1 ]]; then
        echo -e "${CYAN}${msg}...${NC}"
        return
    fi

    printf "\033[?25l" >&2

    set +m
    {
        local -a marks=("|" "/" "-" "\\")
        while :; do
            for mark in "${marks[@]}"; do
                printf "\r${CYAN}%s %s${NC}" "$mark" "$msg" >&2
                sleep 0.1
            done
        done
    } &
    _SPINNER_PID=$!
    set -m
}

stop_spinner() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
        unset _SPINNER_PID
    fi
    printf "\r\033[K" >&2
    printf "\033[?25h" >&2
}

# ==================== 文件操作封装 ====================

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查文件是否存在
file_exists() {
    [[ -f "$1" ]]
}

# 检查目录是否存在
dir_exists() {
    [[ -d "$1" ]]
}

# 检查并创建目录
ensure_dir_exists() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        return $?
    fi
    return 0
}

# 安全删除文件
safe_remove_file() {
    local file=$1
    if file_exists "$file"; then
        rm -f "$file"
        return $?
    fi
    return 0
}

# 安全移动文件
safe_move_file() {
    local src=$1
    local dest=$2
    if file_exists "$src" || dir_exists "$src"; then
        mv "$src" "$dest"
        return $?
    fi
    return 1
}

# 跨平台 sed -i 封装
safe_sed() {
    if [[ "$OS" == "macOS" ]]; then
        sed -i.bak "$@"
        local last_arg="${!#}"
        rm -f "${last_arg}.bak"
    else
        sed -i "$@"
    fi
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

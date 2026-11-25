#!/bin/bash

# 跨平台磁盘清理脚本
# 安全清理用户缓存、临时文件和下载内容
# 支持Linux和macOS系统
# 不会删除系统文件或重要数据
#
# 用法:
#   交互模式:    ./disk-clean.sh
#   安全自动:    ./disk-clean.sh --auto          (执行所有默认选中的安全清理项)
#   仅安全清理:  ./disk-clean.sh --safe          (仅安全清理区, 纯缓存无风险)
#   全部清理:    ./disk-clean.sh --all           (执行所有项, 含高风险)
#   自定义编号:  ./disk-clean.sh --run 1,2,6     (按编号执行)
#   预演不删:    ./disk-clean.sh --dry-run --safe
#   安装定时:    ./disk-clean.sh --install-cron [--schedule "0 3 * * 0"] [--mode safe|auto]
#   移除定时:    ./disk-clean.sh --remove-cron
#   查看定时:    ./disk-clean.sh --list-cron
#   查看帮助:    ./disk-clean.sh --help

set -o pipefail  # 只对管道的返回值进行严格检查，不因单个命令失败退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 系统检测函数
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macOS"
            ;;
        Linux*)
            echo "Linux"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# 系统详细检测函数（用于检测不同Linux发行版）
detect_distro() {
    if [[ "$OS_TYPE" != "Linux" ]]; then
        return 1
    fi
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)
DISTRO=$(detect_distro || echo "unknown")  # 确保即使函数返回非零值也不会导致脚本退出
SCRIPT_NAME="磁盘清理工具"
if [[ "$OS_TYPE" == "macOS" ]]; then
    SCRIPT_NAME="macOS 磁盘清理工具"
fi

# 早期 CLI 分流: 纯信息/管理类参数 (help/list/list-cron/install/remove) 跳过 banner/df
EARLY_ACTION=""
EARLY_MODE=""
EARLY_QUIET=0
EARLY_SCHEDULE="0 3 * * 0"
EARLY_CRON_MODE="safe"
{
    _early_args=("$@")
    _i=0
    while (( _i < ${#_early_args[@]} )); do
        _a="${_early_args[_i]}"
        case "$_a" in
            -h|--help)                EARLY_ACTION="help" ;;
            --list|--list-menu)       EARLY_ACTION="list-menu" ;;
            --list-cron)              EARLY_ACTION="list-cron" ;;
            --install-cron)           EARLY_ACTION="install-cron" ;;
            --remove-cron|--uninstall-cron) EARLY_ACTION="remove-cron" ;;
            --auto|--default)         EARLY_MODE="default" ;;
            --safe)                   EARLY_MODE="safe" ;;
            --all)                    EARLY_MODE="all" ;;
            --run)                    EARLY_MODE="${_early_args[_i+1]}"; ((_i++)) ;;
            --dry-run)                : ;;
            --quiet|-q)               EARLY_QUIET=1 ;;
            --schedule)               EARLY_SCHEDULE="${_early_args[_i+1]}"; ((_i++)) ;;
            --mode)                   EARLY_CRON_MODE="${_early_args[_i+1]}"; ((_i++)) ;;
        esac
        ((_i++))
    done
}

# 对于纯管理/信息 ACTION, 不打 banner，直接跳到完整解析
case "$EARLY_ACTION" in
    help|list-menu|list-cron|remove-cron|install-cron) ;;
    *)
        if [[ "$EARLY_QUIET" -eq 1 ]]; then
            # quiet 模式仍需提供函数，避免后续 run_non_interactive 调用未定义
            show_disk_usage() { :; }
        else
            # 交互/非交互清理: 显示 banner + df
            echo -e "${BLUE}==================================================${NC}"
            echo -e "${BLUE}          ${SCRIPT_NAME} (安全版)${NC}"
            if [[ "$OS_TYPE" == "Linux" ]]; then
                echo -e "${BLUE}       仅清理用户可安全删除的缓存和临时文件${NC}"
            else
                echo -e "${BLUE}      仅清理用户可安全删除的缓存和临时文件${NC}"
            fi
            echo -e "${BLUE}      不会删除系统关键文件${NC}"
            echo -e "${BLUE}==================================================${NC}"

            # 显示当前磁盘使用情况
            show_disk_usage() {
                echo -e "\\n${YELLOW}当前磁盘使用情况:${NC}"
                df -h /
                echo -e "\\n${YELLOW}当前可用磁盘空间:${NC}"
                df -h / | awk 'NR==2 {print $4 "B (" $5 " 已使用)"}'
            }

            show_disk_usage

            # CLI 快速提示 (仅交互模式显示, 引导用户了解非交互/定时功能)
            if [[ -t 0 && -t 1 ]]; then
                echo -e "\n${BLUE}快速命令 (无需进入菜单即可执行):${NC}"
                echo -e "  ${GREEN}推荐 (纯缓存, 无风险):${NC}  ${0##*/} --safe        安全清理区 (所有默认选中项)"
                echo -e "  ${GREEN}推荐 (默认选中):${NC}        ${0##*/} --auto        所有默认选中项"
                echo -e "  自定义编号:                    ${0##*/} --run 1,2,6   按编号执行"
                echo -e "  预演不删:                      ${0##*/} --dry-run --safe"
                echo -e "  定时清理:                      ${0##*/} --install-cron (每周日 03:00)"
                echo -e "  查看帮助:                      ${0##*/} --help"
            fi
        fi
        ;;
esac

# 检查是否有足够权限执行某些操作
check_permissions() {
    # 检查是否可以访问用户目录
    if [[ ! -r "$HOME" ]]; then
        echo -e "${RED}错误: 没有权限访问 $HOME 目录${NC}"
        exit 1
    fi
}

check_permissions

# ============================================
# 单次提权机制 - 避免多次输入 sudo 密码
# ============================================

# 是否已完成一次管理员授权
SUDO_READY=0

# 确保已获得一次管理员授权（仅首次请求密码，之后复用 sudo 时间戳缓存）
# 并在后台定时刷新时间戳，保证长时间清理过程中不再提示密码
# 用法: ensure_sudo [hint_command]  — 非交互模式下如传入 hint 命令则只输出不执行
ensure_sudo() {
    if [[ $SUDO_READY -eq 1 ]]; then
        return 0
    fi
    # 已以 root 运行则无需提权
    if [[ $EUID -eq 0 ]]; then
        SUDO_READY=1
        return 0
    fi
    # 已有缓存授权或配置了无密码 sudo，直接标记就绪
    if sudo -n true 2>/dev/null; then
        SUDO_READY=1
        return 0
    fi
    # 非交互模式不能安全读取密码，避免 sudo -v 阻塞或输出误导性提示
    # 策略: 不执行提权命令, 仅输出需要手动运行的命令
    if [[ ! -t 0 || ! -t 1 ]]; then
        if [[ -n "${1:-}" ]]; then
            echo -e "  ${YELLOW}⏭ 需要提权 (非交互模式已跳过)，请手动执行:${NC}"
            echo -e "    ${GREEN}sudo ${1}${NC}"
        else
            echo -e "  ${YELLOW}-${NC} 非交互模式未检测到可用 sudo 授权，跳过需要提权的操作"
        fi
        return 1
    fi
    echo -e "\n${YELLOW}以下操作需要管理员权限，请输入密码 (仅需一次):${NC}"
    if ! sudo -v; then
        echo -e "  ${RED}✗${NC} 管理员授权失败，跳过需要提权的操作"
        return 1
    fi
    SUDO_READY=1
    # 后台每 60 秒刷新一次 sudo 时间戳，避免长时间清理时再次提示密码
    ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
}

# ============================================
# 大小缓存机制 - 提升扫描性能
# ============================================

# 缓存有效时间（秒）
CACHE_TTL=30

# 简单缓存机制（兼容 bash 3.x）
# 不能放在 /tmp：清理临时文件时会把缓存目录自身删掉，导致后续 get_dir_size
# 写入缓存时报“没有那个文件或目录”。放到用户缓存区并加隐藏前缀，避免被
# “清理用户应用缓存”的 -not -name '.*' 规则扫到。
CACHE_DIR="${HOME}/.cache/.disk_cleanup_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR="${TMPDIR:-/tmp}/.disk_cleanup_cache_$$"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# 获取当前时间戳（兼容 macOS/BSD）
get_timestamp() {
    date +%s
}

format_size_kb() {
    local size_kb="${1:-0}"
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    awk -v k="$size_kb" 'BEGIN {
        if (k >= 1048576) printf "%.1fGB", k/1048576;
        else if (k >= 1024) printf "%.1fMB", k/1024;
        else printf "%dKB", k;
    }'
}

is_estimated_size() {
    [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?(KB|MB|GB)$ ]]
}

normalize_scan_size() {
    local size="${1:-}"
    case "$size" in
        ""|"N/A"|"unknown"|"Unknown"|"未知") echo "未估算" ;;
        *) echo "$size" ;;
    esac
}

is_selectable_scan_size() {
    local size
    size=$(normalize_scan_size "${1:-}")
    case "$size" in
        ""|"0KB"|"未估算"|"工具"|"批量") return 1 ;;
        *) return 0 ;;
    esac
}

app_cleanup_label() {
    local sub_path="$1"
    case "$sub_path" in
        logs|Logs|*/logs|*/Logs) echo "日志目录 ($sub_path)" ;;
        vm/images|*/vm/images|*/ai-agent/vm/images|ModularData/ai-agent/vm/images) echo "虚拟机镜像目录 ($sub_path)" ;;
        Caches|*/Caches|cache|Cache|*/cache|*/Cache) echo "缓存目录 ($sub_path)" ;;
        *) echo "规则匹配目录 ($sub_path)" ;;
    esac
}

# 获取文件修改时间（秒）。注意 GNU stat 的 -f 是 --file-system，
# 在 Linux 上会输出整段文件系统信息而非时间戳；BSD/macOS 的 -f 才是取时间戳。
stat_mtime() {
    local file="$1"
    if [[ "$OS_TYPE" == "Linux" ]]; then
        stat -c %Y "$file" 2>/dev/null
    else
        stat -f %m "$file" 2>/dev/null
    fi
}

# 清理过期缓存
clean_expired_cache() {
    local current_time=$(get_timestamp)
    find "$CACHE_DIR" -type f -name "*.cache" 2>/dev/null | while read -r cache_file; do
        local cache_time=$(stat_mtime "$cache_file")
        [[ "$cache_time" =~ ^[0-9]+$ ]] || continue
        if (( current_time - cache_time > CACHE_TTL )); then
            rm -f "$cache_file" 2>/dev/null
        fi
    done
}

# 获取目录大小的函数，兼容不同系统的 du 命令行为
# 支持缓存以提升性能
get_dir_size() {
    local dir="$1"
    local use_cache="${2:-true}"
    
    [[ -e "$dir" ]] || { echo "0KB"; return; }
    
    # 生成缓存键（目录路径的哈希）
    local cache_key
    if command -v md5sum >/dev/null 2>&1; then
        cache_key=$(echo "$dir" | md5sum 2>/dev/null | cut -d' ' -f1)
    elif command -v md5 >/dev/null 2>&1; then
        cache_key=$(echo "$dir" | md5 -q 2>/dev/null)
    else
        cache_key=$(echo "$dir" | tr '/' '_')
    fi
    local cache_file="$CACHE_DIR/${cache_key}.cache"
    
    # 检查缓存
    if [[ "$use_cache" == "true" && -f "$cache_file" ]]; then
        local cache_time=$(stat_mtime "$cache_file")
        local current_time=$(get_timestamp)
        if [[ "$cache_time" =~ ^[0-9]+$ ]] && (( current_time - cache_time <= CACHE_TTL )); then
            normalize_scan_size "$(cat "$cache_file" 2>/dev/null)"
            return
        fi
    fi
    
    # 获取 KB 大小（比字节更精确，避免大数溢出）
    local size_kb
    size_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
    [[ "$size_kb" =~ ^[0-9]+$ ]] || { echo "0KB"; return; }
    
    # 使用 awk 进行单位转换（比 bc 更快且无需外部依赖）
    local result
    result=$(format_size_kb "$size_kb")
    
    # 存入缓存
    echo "$result" > "$cache_file"
    
    echo "$result"
}

# 获取目录大小（KB 数值，用于排序比较）
get_dir_size_kb() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "0"; return; }
    du -sk "$dir" 2>/dev/null | cut -f1 || echo "0"
}

# ============================================
# 辅助函数 - 减少代码重复
# ============================================

# 统一的确认函数
confirm_action() {
    local message="$1"
    local size="${2:-}"
    
    # 先显示带颜色的消息
    if [[ -n "$size" ]]; then
        echo -ne "  - 确认${message} (大小: ${YELLOW}${size}${NC})"
    else
        echo -ne "  - 确认${message}"
    fi
    
    # 再读取输入
    read -r -p "? [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# 清理项内部的细粒度确认：批量执行（主循环已整体验证过一次）时自动通过，
# 避免每个子项再问一遍 y/N；单独运行某菜单项时仍保留询问。
confirm_internal() {
    local message="$1"
    if [[ $BATCH_MODE -eq 1 ]]; then
        return 0
    fi
    local response
    read -r -p "  - 确认${message}? [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# ============================================
# 进度条函数
# ============================================

# 显示进度条
# 参数: current(当前进度) total(总数) width(宽度,默认50)
show_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    
    # 边界检查
    [[ $total -eq 0 ]] && return
    [[ $current -gt $total ]] && current=$total
    
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    # 构建进度条
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    printf "\r  ${BLUE}进度:${NC} [%s] %3d%% (%d/%d)" "$bar" "$percent" "$current" "$total"
}

# 带进度显示的目录清理
cleanup_with_progress() {
    local dir="$1"
    local name="$2"
    
    # 统计文件数量
    local total_files
    total_files=$(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
    local total_dirs
    total_dirs=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    local total=$((total_files + total_dirs))
    
    if [[ $total -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} $name 为空，已跳过"
        return 0
    fi
    
    local current=0
    local deleted=0
    local failed=0
    
    # 清理文件
    while IFS= read -r -d '' item; do
        ((current++))
        show_progress "$current" "$total"
        
        if rm -rf "$item" 2>/dev/null; then
            ((deleted++))
        else
            ((failed++))
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -not -name ".*" -print0 2>/dev/null)
    
    echo ""  # 换行
    echo -e "  ${GREEN}✓${NC} $name: 已删除 $deleted 项" $([[ $failed -gt 0 ]] && echo -e "${RED}(失败 $failed 项)${NC}")
    
    return $failed
}

# ============================================
# 跨平台超时执行函数
# ============================================

# @description 带超时执行命令（macOS 无 timeout 命令，用后台进程+kill 替代）
# @param timeout_sec 超时秒数
# @param ... 要执行的命令及参数
# @return 0=成功, 124=超时, 其他=命令自身退出码
run_with_timeout() {
    local timeout_sec="$1"
    shift
    local cmd="$*"
    
    # 优先使用系统 timeout（Linux）或 gtimeout（macOS + coreutils）
    if command -v timeout &> /dev/null; then
        timeout "$timeout_sec" "$@"
        return $?
    elif command -v gtimeout &> /dev/null; then
        gtimeout "$timeout_sec" "$@"
        return $?
    fi
    
    # 回退方案：后台执行 + sleep + kill 整个进程组
    local pid_file="/tmp/.disk_clean_timeout_$$.pid"
    eval "$cmd" &
    local pid=$!
    echo "$pid" > "$pid_file"
    
    local i=0
    while [ $i -lt "$timeout_sec" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
            local rc=$?
            rm -f "$pid_file"
            return $rc
        fi
        sleep 1
        ((i++))
    done
    
    # 超时：先 SIGTERM 再 SIGKILL，杀整个进程组
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    # 清理可能残留的子进程
    pkill -9 -P "$pid" 2>/dev/null || true
    rm -f "$pid_file"
    return 124
}

# ============================================
# 通用清理模板函数 - 减少重复代码
# ============================================

# @description 通用的目录清理函数模板
# @param dir 目标目录
# @param name 显示名称
# @param find_pattern find 命令的额外参数（可选）
# @param need_sudo 是否需要 sudo 权限（可选，默认 false）
cleanup_generic() {
    local dir="$1"
    local name="$2"
    local find_pattern="${3:- -mindepth 1 -maxdepth 1 -not -name '.*'}"
    local need_sudo="${4:-false}"
    
    # 验证目录
    if [[ ! -d "$dir" ]]; then
        echo -e "  ${YELLOW}-${NC} $name 目录不存在，跳过 ($dir)"
        return 1
    fi
    
    # 获取大小
    local size
    size=$(get_dir_size "$dir")
    local count
    count=$(eval "find \"$dir\" $find_pattern 2>/dev/null" | wc -l)
    
    echo -e "  - 检测到 ${GREEN}$name${NC}，大小: ${YELLOW}$size${NC}，项目数: $count"
    
    # 跳过空目录
    if [[ "$size" == "N/A" || "$size" == "0KB" || $count -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} $name 为空，已跳过"
        return 0
    fi
    
    # 批量模式跳过确认
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理 $name" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 $name"
            log_action "SKIP" "跳过清理: $name ($dir)"
            return 0
        fi
    fi
    
    # 执行清理（带进度显示）
    local size_before="$size"
    
    if [[ "$need_sudo" == "true" ]]; then
        ensure_sudo "find \"$dir\" -mindepth 1 -maxdepth 1 -not -name '.*' -exec rm -rf {} +" || return 1
        if sudo find "$dir" -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
            local size_after
            size_after=$(get_dir_size "$dir")
            echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before → $size_after"
            log_action "SUCCESS" "清理 $name: $size_before → $size_after"
            return 0
        else
            echo -e "  ${RED}✗${NC} 清理 $name 失败"
            log_action "ERROR" "清理 $name 失败"
            return 1
        fi
    else
        # 使用进度条清理
        cleanup_with_progress "$dir" "$name"
        local ret=$?
        local size_after
        size_after=$(get_dir_size "$dir")
        log_action "SUCCESS" "清理 $name: $size_before → $size_after"
        return $ret
    fi
}

# @description 通用文件清理函数（按文件名模式）
# @param dir 目标目录
# @param name 显示名称
# @param pattern 文件匹配模式（如 "*.log"）
cleanup_by_pattern() {
    local dir="$1"
    local name="$2"
    local pattern="$3"
    
    if [[ ! -d "$dir" ]]; then
        echo -e "  ${YELLOW}-${NC} $name 目录不存在，跳过"
        return 1
    fi
    
    local count
    count=$(find "$dir" -name "$pattern" 2>/dev/null | wc -l)
    
    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} $name 无匹配文件，已跳过"
        return 0
    fi
    
    local size
    size=$(get_dir_size "$dir")
    echo -e "  - 检测到 $name: 匹配文件 $count 个"
    
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理 $name 匹配的文件"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 $name"
            return 0
        fi
    fi
    
    local deleted=0
    while IFS= read -r -d '' file; do
        if rm -f "$file" 2>/dev/null; then
            ((deleted++))
        fi
        show_progress "$deleted" "$count"
    done < <(find "$dir" -name "$pattern" -print0 2>/dev/null)
    
    echo ""
    echo -e "  ${GREEN}✓${NC} 已清理 $name: 删除 $deleted 个文件"
    log_action "SUCCESS" "清理 $name: 删除 $deleted 个文件"
}

# 目录安全验证
validate_dir() {
    local dir="$1"
    local name="$2"
    
    # 基本检查
    [[ -z "$dir" ]] && { echo -e "${RED}错误: 目录路径为空${NC}"; return 1; }
    [[ "$dir" == "/" ]] && { echo -e "${RED}错误: 不能删除根目录${NC}"; return 1; }
    [[ "$dir" == "$HOME" ]] && { echo -e "${RED}错误: 不能删除用户主目录${NC}"; return 1; }
    [[ "$dir" =~ \.\./ || "$dir" =~ \.\.\\ ]] && { echo -e "${RED}错误: 路径包含 '..' 可能导致路径穿越${NC}"; return 1; }
    
    # 存在性检查
    if [[ ! -d "$dir" ]]; then
        echo -e "  ${YELLOW}-${NC} ${name:-目录} 不存在 ($dir)"
        return 1
    fi
    
    return 0
}

# 日志记录函数 (日志不可写时自动降级，避免污染输出)
LOG_FILE="${DISK_CLEAN_LOG_FILE:-${HOME}/.disk_cleanup.log}"
LOG_ENABLED=1
log_action() {
    local level="$1"
    local message="$2"
    [[ "$LOG_ENABLED" -eq 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE" 2>/dev/null || {
        LOG_ENABLED=0
        echo "  - 日志文件不可写，已关闭日志记录: $LOG_FILE" >&2
    }
}

# 初始化日志
init_log() {
    [[ "$LOG_ENABLED" -eq 1 ]] || return 0
    {
        echo "========================================"
        echo "磁盘清理工具启动 - $(date)"
        echo "系统: $OS_TYPE"
        echo "========================================"
    } >> "$LOG_FILE" 2>/dev/null || {
        LOG_ENABLED=0
        echo "  - 日志文件不可写，已关闭日志记录: $LOG_FILE" >&2
    }
}

# ============================================
# 安全清理函数
# ============================================

# 核心清理函数 - 使用辅助函数减少重复
# @param dir 目标目录
# @param name 显示名称
# @param need_sudo 是否需要 sudo 权限（可选，默认 false）
cleanup() {
    local dir="$1"
    local name="$2"
    local need_sudo="${3:-false}"
    
    # 使用辅助函数验证目录
    validate_dir "$dir" "$name" || return
    
    # 需要提权时先完成单次授权
    if [[ "$need_sudo" == "true" ]]; then
        ensure_sudo "find \"$dir\" -mindepth 1 -maxdepth 1 -not -name '.*' -exec rm -rf {} +" || return 1
    fi
    
    local size_before size_after count
    if [[ "$need_sudo" == "true" ]]; then
        size_before=$(sudo du -sh "$dir" 2>/dev/null | awk '{print $1}')
        count=$(sudo find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    else
        size_before=$(get_dir_size "$dir")
        count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    fi
    
    echo -e "  - ${GREEN}$name${NC} ($dir)"
    echo -e "  - 大小: ${YELLOW}$size_before${NC}, 项目数: $count"
    
    # 自动跳过空目录、0KB 或 N/A
    if [[ "$size_before" == "N/A" || "$size_before" == "0KB" || "$size_before" == "0B" || $count -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} $name 为空或无需清理，已跳过"
        return
    fi
    
    # 批量模式下跳过确认
    if [[ $BATCH_MODE -eq 0 ]]; then
        confirm_action "清理 $name" "$size_before" || {
            echo -e "  ${YELLOW}-${NC} 已跳过 $name"
            log_action "SKIP" "跳过清理: $name ($dir)"
            return
        }
    fi
    
    if [[ "$need_sudo" == "true" ]]; then
        if sudo find "$dir" -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
            size_after=$(sudo du -sh "$dir" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before → $size_after (删除了 $count 个项目)"
            log_action "SUCCESS" "清理 $name: $size_before → $size_after"
        else
            echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
            log_action "ERROR" "清理 $name 失败"
            return 1
        fi
    else
        if find "$dir" -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
            size_after=$(get_dir_size "$dir")
            echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before → $size_after (删除了 $count 个项目)"
            log_action "SUCCESS" "清理 $name: $size_before → $size_after"
        else
            echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
            log_action "ERROR" "清理 $name 失败"
            return 1
        fi
    fi
}

# 清理用户缓存（安全版本）
cleanup_user_cache() {
    local cache_dir="$1"
    local name="$2"
    
    if [[ -d "$cache_dir" ]]; then
        echo -e "  - 扫描 ${GREEN}$name${NC} ($cache_dir)..."
        local size_before
        size_before=$(get_dir_size "$cache_dir")
        echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
        
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            read -r -p "  - 确认清理 $name? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo -e "  ${YELLOW}-${NC} 已跳过 $name"
                return
            fi
        fi
        
        # 只删除非隐藏目录/文件以避免删除重要的缓存结构
        if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
            local size_after
            size_after=$(get_dir_size "$cache_dir")
            echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before -> $size_after"
        else
            echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
        fi
    else
        echo -e "  ${YELLOW}-${NC} 警告: $name 目录不存在，跳过 ($cache_dir)"
    fi
}

# 清理 macOS 专用文件
cleanup_macos_specific() {
    if [[ "$OS_TYPE" == "macOS" ]]; then
        echo -e "\\n正在清理 macOS 专用缓存..."
        
        # 清理 Safari 下载历史
        local safari_file="$HOME/Library/Safari/Downloads.plist"
        if [[ -f "$safari_file" ]]; then
            echo -e "  - 找到 Safari 下载历史: $safari_file"
            read -r -p "  - 确认清理 Safari 下载历史? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -f "$safari_file" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Safari 下载历史"
                else
                    echo -e "  ${RED}✗${NC} 清理 Safari 下载历史时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Safari 下载历史清理"
            fi
        else
            echo -e "  - Safari 下载历史文件不存在，跳过"
        fi
        
        # 清理系统诊断报告
        echo -e "\\n正在清理系统诊断报告 (/Library/Logs/DiagnosticReports)..."
        cleanup "/Library/Logs/DiagnosticReports" "系统诊断报告" "true"
        
        # 清理软件更新缓存
        echo -e "\\n正在清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)..."
        if [[ -d "/Library/Caches/com.apple.SoftwareUpdate" ]]; then
            echo -e "  - 检测到软件更新缓存，需要管理员权限"
            ensure_sudo "rm -rf /Library/Caches/com.apple.SoftwareUpdate/*" || return 1
            read -r -p "  - 确认清理软件更新缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf /Library/Caches/com.apple.SoftwareUpdate/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理软件更新缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理软件更新缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过软件更新缓存清理"
            fi
        else
            echo -e "  - 软件更新缓存目录不存在，跳过"
        fi
        
        # 清理 Trash（macOS 回收站）
        local trash_dir="$HOME/.Trash"
        if [[ -d "$trash_dir" ]]; then
            echo -e "\\n正在清理用户回收站..."
            local trash_size
            trash_size=$(get_dir_size "$trash_dir")
            echo -e "  - 当前回收站大小: ${YELLOW}$trash_size${NC}"
            read -r -p "  - 确认清空回收站? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$trash_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清空回收站"
                    # 重建目录
                    mkdir -p "$trash_dir" 2>/dev/null
                else
                    echo -e "  ${RED}✗${NC} 清空回收站时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过回收站清理"
            fi
        fi
        
        # 清理系统临时文件
        echo -e "\\n正在清理系统临时文件..."
        if [[ -d "/private/tmp" ]]; then
            read -r -p "  - 确认清理 /private/tmp? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                cleanup "/private/tmp" "系统临时文件"
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 /private/tmp 清理"
            fi
        fi
        
        # 清理系统缓存 (/System/Volumes/Data/Volumes/Data/com.apple.MachineLearning 等)
        echo -e "\\n正在清理系统缓存..."
        if [[ -d "/System/Volumes/Data/com.apple.MachineLearning" ]]; then
            local ml_cache="/System/Volumes/Data/com.apple.MachineLearning"
            local ml_cache_size
            ml_cache_size=$(get_dir_size "$ml_cache")
            echo -e "  - 检测到机器学习模型缓存，大小: ${YELLOW}$ml_cache_size${NC}"
            read -r -p "  - 确认清理机器学习模型缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf "$ml_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理机器学习模型缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理机器学习模型缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过机器学习模型缓存清理"
            fi
        fi
        
        # 清理用户日志文件
        echo -e "\\n正在清理用户日志文件..."
        if [[ -d "$HOME/Library/Logs" ]]; then
            local logs_dir="$HOME/Library/Logs"
            local logs_size
            logs_size=$(get_dir_size "$logs_dir")
            echo -e "  - 检测到用户日志目录，大小: ${YELLOW}$logs_size${NC}"
            read -r -p "  - 确认清理用户日志文件? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if find "$logs_dir" -mindepth 1 -maxdepth 2 -name "*.log" -not -path "*/Containers/*" -exec rm -f {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理用户日志文件"
                else
                    echo -e "  ${RED}✗${NC} 清理用户日志文件时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过用户日志文件清理"
            fi
        fi
        
        # 清理自动保存信息
        echo -e "\\n正在清理自动保存文件..."
        if [[ -d "$HOME/Library/Autosave Information" ]]; then
            local autosave_dir="$HOME/Library/Autosave Information"
            local autosave_size
            autosave_size=$(get_dir_size "$autosave_dir")
            echo -e "  - 检测到自动保存目录，大小: ${YELLOW}$autosave_size${NC}"
            read -r -p "  - 确认清理自动保存文件? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$autosave_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理自动保存文件"
                else
                    echo -e "  ${RED}✗${NC} 清理自动保存文件时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过自动保存文件清理"
            fi
        fi
        
        # 清理保存的应用状态
        echo -e "\\n正在清理保存的应用状态..."
        if [[ -d "$HOME/Library/Saved Application State" ]]; then
            local saved_state_dir="$HOME/Library/Saved Application State"
            local saved_state_size
            saved_state_size=$(get_dir_size "$saved_state_dir")
            echo -e "  - 检测到保存应用状态目录，大小: ${YELLOW}$saved_state_size${NC}"
            read -r -p "  - 确认清理保存的应用状态? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$saved_state_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理保存的应用状态"
                else
                    echo -e "  ${RED}✗${NC} 清理保存的应用状态时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过保存应用状态清理"
            fi
        fi
        
        # 清理容器缓存（应用程序沙盒缓存）
        echo -e "\\n正在清理应用容器缓存..."
        if [[ -d "$HOME/Library/Containers" ]]; then
            local containers_dir="$HOME/Library/Containers"
            local containers_size
            containers_size=$(get_dir_size "$containers_dir")
            echo -e "  - 检测到应用容器目录，大小: ${YELLOW}$containers_size${NC}"
            read -r -p "  - 确认清理部分应用容器缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 只清理缓存文件，而不是整个应用数据
                if find "$containers_dir" -name "Cache.db" -exec rm -f {} + 2>/dev/null && 
                   find "$containers_dir" -name "Caches" -type d -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理应用容器缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理应用容器缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过应用容器缓存清理"
            fi
        fi
        
        # 清理邮件缓存
        echo -e "\\n正在清理邮件缓存..."
        local mail_cache_dirs=("$HOME/Library/Mail" "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches")
        for mail_cache_dir in "${mail_cache_dirs[@]}"; do
            if [[ -d "$mail_cache_dir" ]]; then
                local mail_cache_size
                mail_cache_size=$(get_dir_size "$mail_cache_dir")
                echo -e "  - 检测到邮件缓存目录: $mail_cache_dir, 大小: ${YELLOW}$mail_cache_size${NC}"
                read -r -p "  - 确认清理邮件缓存? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if find "$mail_cache_dir" -name "Cache" -type d -exec rm -rf {} + 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理邮件缓存"
                    else
                        echo -e "  ${RED}✗${NC} 清理邮件缓存时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过邮件缓存清理"
                fi
                break  # 只处理找到的第一个邮件缓存目录
            fi
        done
        
        # 清理 QuickLook 缓存
        echo -e "\\n正在清理 QuickLook 缓存..."
        if [[ -d "$HOME/Library/Caches/com.apple.quicklook" ]]; then
            local quicklook_cache="$HOME/Library/Caches/com.apple.quicklook"
            local quicklook_size
            quicklook_size=$(get_dir_size "$quicklook_cache")
            echo -e "  - 检测到 QuickLook 缓存，大小: ${YELLOW}$quicklook_size${NC}"
            read -r -p "  - 确认清理 QuickLook 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf "$quicklook_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 QuickLook 缓存"
                    # 重启 QuickLook 服务
                    sudo qlmanage -r 2>/dev/null
                    echo -e "  - 已重启 QuickLook 服务"
                else
                    echo -e "  ${RED}✗${NC} 清理 QuickLook 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 QuickLook 缓存清理"
            fi
        fi
        
        # 清理 Xcode 缓存（如果安装了开发工具）
        if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
            echo -e "\\n正在清理 Xcode 编译缓存..."
            local xcode_cache="$HOME/Library/Developer/Xcode/DerivedData"
            local xcode_cache_size
            xcode_cache_size=$(get_dir_size "$xcode_cache")
            echo -e "  - 检测到 Xcode 编译缓存，大小: ${YELLOW}$xcode_cache_size${NC}"
            read -r -p "  - 确认清理 Xcode 编译缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$xcode_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Xcode 编译缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Xcode 编译缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Xcode 缓存清理"
            fi
        fi
        
        # 清理 iOS 模拟器缓存（如果存在 Xcode）
        if [[ -d "$HOME/Library/Developer/CoreSimulator" ]]; then
            echo -e "\\n正在清理 iOS 模拟器缓存..."
            local simulator_cache="$HOME/Library/Developer/CoreSimulator"
            local simulator_size
            simulator_size=$(get_dir_size "$simulator_cache")
            echo -e "  - 检测到 iOS 模拟器缓存，大小: ${YELLOW}$simulator_size${NC}"
            read -r -p "  - 确认清理 iOS 模拟器缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 只删除缓存和临时文件，保留设备配置
                if find "$simulator_cache" -name "data" -type d -path "*/Caches/*" -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 iOS 模拟器缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 iOS 模拟器缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 iOS 模拟器缓存清理"
            fi
        fi
        
        # 清理系统范围内的垃圾邮件缓存
        if [[ -d "/Library/Caches" ]]; then
            echo -e "\\n正在清理系统缓存..."
            local system_caches="/Library/Caches"
            local cache_dirs=($(find "$system_caches" -mindepth 1 -maxdepth 1 -type d | head -10))  # 限制显示前10个目录
            for dir in "${cache_dirs[@]}"; do
                local dir_name=$(basename "$dir")
                local dir_size
                dir_size=$(get_dir_size "$dir")
                echo -e "  - 检测到系统缓存: $dir_name, 大小: ${YELLOW}$dir_size${NC}"
                read -r -p "  - 确认清理 $dir_name 缓存? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if sudo rm -rf "$dir"/* 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理 $dir_name 缓存"
                    else
                        echo -e "  ${RED}✗${NC} 清理 $dir_name 缓存时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过 $dir_name 缓存清理"
                fi
            done
        fi

        # 清理浏览器缓存
        echo -e "\\n正在清理浏览器缓存..."
        
        # Safari 缓存
        if [[ -d "$HOME/Library/Caches/com.apple.Safari" ]]; then
            local safari_cache="$HOME/Library/Caches/com.apple.Safari"
            local safari_cache_size
            safari_cache_size=$(get_dir_size "$safari_cache")
            echo -e "  - 检测到 Safari 缓存，大小: ${YELLOW}$safari_cache_size${NC}"
            read -r -p "  - 确认清理 Safari 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$safari_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Safari 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Safari 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Safari 缓存清理"
            fi
        fi

        # Chrome 缓存
        if [[ -d "$HOME/Library/Caches/Google/Chrome" ]]; then
            local chrome_cache="$HOME/Library/Caches/Google/Chrome"
            local chrome_cache_size
            chrome_cache_size=$(get_dir_size "$chrome_cache")
            echo -e "  - 检测到 Chrome 缓存，大小: ${YELLOW}$chrome_cache_size${NC}"
            read -r -p "  - 确认清理 Chrome 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$chrome_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Chrome 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Chrome 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Chrome 缓存清理"
            fi
        fi

        # Firefox 缓存
        if [[ -d "$HOME/Library/Caches/Firefox" ]]; then
            local firefox_cache="$HOME/Library/Caches/Firefox"
            local firefox_cache_size
            firefox_cache_size=$(get_dir_size "$firefox_cache")
            echo -e "  - 检测到 Firefox 缓存，大小: ${YELLOW}$firefox_cache_size${NC}"
            read -r -p "  - 确认清理 Firefox 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$firefox_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Firefox 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Firefox 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Firefox 缓存清理"
            fi
        fi

        # 清理 Homebrew 缓存
        if command -v brew &> /dev/null; then
            echo -e "\\n正在清理 Homebrew 缓存..."
            read -r -p "  - 确认清理 Homebrew 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if brew cleanup --prune=all 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Homebrew 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Homebrew 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Homebrew 缓存清理"
            fi
        fi

        # 清理 Docker 容器和镜像缓存
        if command -v docker &> /dev/null; then
            echo -e "\\n正在清理 Docker 缓存..."
            read -r -p "  - 确认清理 Docker 容器和镜像缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if docker system prune -f 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Docker 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Docker 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Docker 缓存清理"
            fi
        fi

        # 清理 pip 缓存
        if command -v pip3 &> /dev/null; then
            echo -e "\\n正在清理 pip 缓存..."
            local pip_cache_dir="$HOME/Library/Caches/pip"
            if [[ -d "$pip_cache_dir" ]]; then
                local pip_cache_size
                pip_cache_size=$(get_dir_size "$pip_cache_dir")
                echo -e "  - 检测到 pip 缓存，大小: ${YELLOW}$pip_cache_size${NC}"
                read -r -p "  - 确认清理 pip 缓存? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if rm -rf "$pip_cache_dir"/* 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理 pip 缓存"
                    else
                        echo -e "  ${RED}✗${NC} 清理 pip 缓存时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过 pip 缓存清理"
                fi
            fi
        fi

        # 清理 npm 缓存
        if command -v npm &> /dev/null; then
            echo -e "\\n正在清理 npm 缓存..."
            read -r -p "  - 确认清理 npm 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if npm cache clean --force 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 npm 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 npm 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 npm 缓存清理"
            fi
        fi

        # 清理 yarn 缓存
        if command -v yarn &> /dev/null; then
            echo -e "\\n正在清理 yarn 缓存..."
            read -r -p "  - 确认清理 yarn 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if yarn cache clean 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 yarn 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 yarn 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 yarn 缓存清理"
            fi
        fi

        # 清理系统字体缓存
        echo -e "\\n正在清理系统字体缓存..."
        if [[ -d "/Library/Caches/com.apple.ats" ]]; then
            local font_cache="/Library/Caches/com.apple.ats"
            local font_cache_size
            font_cache_size=$(get_dir_size "$font_cache")
            echo -e "  - 检测到字体缓存，大小: ${YELLOW}$font_cache_size${NC}"
            read -r -p "  - 确认清理字体缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf "$font_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理字体缓存"
                    sudo atsutil databases -remove 2>/dev/null
                    echo -e "  - 已重建字体数据库"
                else
                    echo -e "  ${RED}✗${NC} 清理字体缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过字体缓存清理"
            fi
        fi

        # 清理 iCloud Drive 缓存
        if [[ -d "$HOME/Library/Mobile Documents" ]]; then
            local icloud_dir="$HOME/Library/Mobile Documents"
            local icloud_size
            icloud_size=$(get_dir_size "$icloud_dir")
            echo -e "  - 检测到 iCloud Drive 目录，大小: ${YELLOW}$icloud_size${NC}"
            read -r -p "  - 确认清理 iCloud Drive 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if find "$icloud_dir" -name ".cache" -type d -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 iCloud Drive 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 iCloud Drive 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 iCloud Drive 缓存清理"
            fi
        fi

        # 清理 Photos 缓存
        if [[ -d "$HOME/Pictures/Photos Library.photoslibrary" ]]; then
            local photos_dir="$HOME/Pictures/Photos Library.photoslibrary"
            local photos_size
            photos_size=$(get_dir_size "$photos_dir")
            echo -e "  - 检测到 Photos 库，大小: ${YELLOW}$photos_size${NC}"
            read -r -p "  - 确认清理 Photos 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if find "$photos_dir" -name "iCloud Photo Cache" -type d -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Photos 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Photos 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Photos 缓存清理"
            fi
        fi

        # 清理 Time Machine 本地快照
        echo -e "\\n正在检查 Time Machine 本地快照..."
        if command -v tmutil &> /dev/null; then
            local snapshots
            snapshots=$(tmutil listlocalsnapshots / 2>/dev/null | grep -v "No local snapshots" || echo "")
            if [[ -n "$snapshots" ]]; then
                echo -e "  - 检测到 Time Machine 本地快照:"
                echo "$snapshots"
                read -r -p "  - 确认删除所有本地快照? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if tmutil deletelocalsnapshots / 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已删除 Time Machine 本地快照"
                    else
                        echo -e "  ${RED}✗${NC} 删除 Time Machine 本地快照时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过 Time Machine 本地快照清理"
                fi
            else
                echo -e "  - 未检测到 Time Machine 本地快照"
            fi
        fi

        # 清理 Spotlight 索引缓存
        echo -e "\\n正在清理 Spotlight 索引缓存..."
        if [[ -d "/.Spotlight-V100" ]]; then
            read -r -p "  - 确认清理 Spotlight 索引缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf /.Spotlight-V100 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Spotlight 索引缓存"
                    sudo mdutil -E / 2>/dev/null
                    echo -e "  - 已重建 Spotlight 索引"
                else
                    echo -e "  ${RED}✗${NC} 清理 Spotlight 索引缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Spotlight 索引缓存清理"
            fi
        fi

        # 通用应用数据清理已迁移至 cleanup_app_data_cache
    fi
}

# 清理应用数据 (日志/缓存/VM镜像)
cleanup_app_data_cache() {
    echo -e "\n正在基于通用规则扫描应用缓存、日志和虚拟机镜像..."
    local rule_based_dirs=()
    
    # 启用扩展的 glob 匹配
    shopt -s nullglob
    
    # 定义要扫描的规则模式 (相对于 Application Support/<AppName>/ 的子路径)
    local sub_patterns=(
        "logs"
        "Logs"
        "*/logs"
        "*/Logs"
        "vm/images"
        "*/vm/images"
        "*/ai-agent/vm/images"
        "ModularData/ai-agent/vm/images"
    )
    
    for app_dir in "$HOME/Library/Application Support/"*; do
        if [[ -d "$app_dir" ]]; then
            for pattern in "${sub_patterns[@]}"; do
                for target_dir in "$app_dir"/$pattern; do
                    if [[ -d "$target_dir" ]]; then
                        # 去重
                        local is_duplicate=0
                        for existing in "${rule_based_dirs[@]}"; do
                            if [[ "$existing" == "$target_dir" ]]; then
                                is_duplicate=1
                                break
                            fi
                        done
                        if [[ $is_duplicate -eq 0 ]]; then
                            rule_based_dirs+=("$target_dir")
                        fi
                    fi
                done
            done
        fi
    done
    shopt -u nullglob
    
    local found_items=0
    for target_dir in "${rule_based_dirs[@]}"; do
        local target_size
        target_size=$(get_dir_size "$target_dir")
        
        # 只处理有大小的目录
        if [[ "$target_size" != "0KB" ]]; then
            found_items=1
            local app_name
            app_name=$(echo "$target_dir" | awk -F'/Application Support/' '{print $2}' | awk -F'/' '{print $1}')
            local sub_path
            sub_path=$(echo "$target_dir" | awk -F"/Application Support/$app_name/" '{print $2}')
            local target_label
            target_label=$(app_cleanup_label "$sub_path")
            
            local do_clean=0
            if [[ $BATCH_MODE -eq 0 ]]; then
                if confirm_action "清理 [$app_name] 的 $target_label" "$target_size"; then
                    do_clean=1
                fi
            else
                echo -e "  - 检测到应用 [$app_name] 的 $target_label: 大小 ${YELLOW}$target_size${NC}"
                do_clean=1
            fi
            
            if [[ $do_clean -eq 1 ]]; then
                if rm -rf "$target_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 [$app_name] $target_label"
                else
                    echo -e "  ${RED}✗${NC} 清理 [$app_name] $target_label 时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过清理"
            fi
        fi
    done
    
    if [[ $found_items -eq 0 ]]; then
        echo -e "  - 未检测到需要清理的规则匹配目录"
    fi
}


# 清理 Linux 专用文件
cleanup_linux_specific() {
    if [[ "$OS_TYPE" == "Linux" ]]; then
        echo -e "\\n正在清理 Linux 专用缓存..."
        ensure_sudo || return 1
        
        # 清理系统缓存目录
        if [[ -d "/var/cache" ]]; then
            echo -e "  - 检测到系统缓存目录 /var/cache"
            if confirm_internal "确认清理系统缓存(/var/cache)"; then
                if sudo find /var/cache -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理系统缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理系统缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过系统缓存清理"
            fi
        fi
        
        # 清理用户应用缓存
        if [[ -d "$HOME/.cache" ]]; then
            echo -e "\\n正在清理用户应用缓存 ($HOME/.cache)..."
            local cache_dir="$HOME/.cache"
            local size_before
            size_before=$(get_dir_size "$cache_dir")
            echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
            if confirm_internal "确认清理用户应用缓存"; then
                if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                    local size_after
                    size_after=$(get_dir_size "$cache_dir")
                    echo -e "  ${GREEN}✓${NC} 已清理用户应用缓存: $size_before -> $size_after"
                else
                    echo -e "  ${RED}✗${NC} 清理用户应用缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过用户应用缓存清理"
            fi
        else
            echo -e "  - 用户应用缓存目录不存在，跳过 ($HOME/.cache)"
        fi
        
        # 检测并清理不同 Linux 发行版的包管理器缓存
        case "$DISTRO" in
            ubuntu|debian)
                # 清理 APT 缓存 (Ubuntu/Debian)
                if command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
                    echo -e "\\n检测到 APT 包管理器"
                    if confirm_internal "确认清理 APT 缓存"; then
                        if sudo apt-get clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 APT 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 APT 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 APT 缓存清理"
                    fi
                fi
                ;;
            centos|rhel|fedora)
                # 清理 YUM/DNF 缓存 (CentOS/RHEL/Fedora)
                if command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                    echo -e "\\n检测到 YUM/DNF 包管理器"
                    if confirm_internal "确认清理 YUM/DNF 缓存"; then
                        if command -v dnf &> /dev/null; then
                            if sudo dnf clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 DNF 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 DNF 缓存时出现错误"
                            fi
                        elif command -v yum &> /dev/null; then
                            if sudo yum clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 YUM 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 YUM 缓存时出现错误"
                            fi
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 YUM/DNF 缓存清理"
                    fi
                fi
                ;;
            arch|manjaro)
                # 清理 Pacman 缓存 (Arch Linux/Manjaro)
                if command -v pacman &> /dev/null; then
                    echo -e "\\n检测到 Pacman 包管理器"
                    if confirm_internal "确认清理 Pacman 缓存"; then
                        if sudo pacman -Sc 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Pacman 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Pacman 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Pacman 缓存清理"
                    fi
                fi
                ;;
            opensuse)
                # 清理 Zypper 缓存 (openSUSE)
                if command -v zypper &> /dev/null; then
                    echo -e "\\n检测到 Zypper 包管理器"
                    if confirm_internal "确认清理 Zypper 缓存"; then
                        if sudo zypper clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Zypper 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Zypper 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Zypper 缓存清理"
                    fi
                fi
                ;;
            *)
                # 检查是否有其他包管理器
                if command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
                    echo -e "\\n检测到 APT 包管理器"
                    if confirm_internal "确认清理 APT 缓存"; then
                        if sudo apt-get clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 APT 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 APT 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 APT 缓存清理"
                    fi
                elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                    echo -e "\\n检测到 YUM/DNF 包管理器"
                    if confirm_internal "确认清理 YUM/DNF 缓存"; then
                        if command -v dnf &> /dev/null; then
                            if sudo dnf clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 DNF 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 DNF 缓存时出现错误"
                            fi
                        elif command -v yum &> /dev/null; then
                            if sudo yum clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 YUM 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 YUM 缓存时出现错误"
                            fi
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 YUM/DNF 缓存清理"
                    fi
                elif command -v pacman &> /dev/null; then
                    echo -e "\\n检测到 Pacman 包管理器"
                    if confirm_internal "确认清理 Pacman 缓存"; then
                        if sudo pacman -Sc 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Pacman 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Pacman 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Pacman 缓存清理"
                    fi
                elif command -v zypper &> /dev/null; then
                    echo -e "\\n检测到 Zypper 包管理器"
                    if confirm_internal "确认清理 Zypper 缓存"; then
                        if sudo zypper clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Zypper 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Zypper 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Zypper 缓存清理"
                    fi
                fi
                ;;
        esac

        # 清理 Docker 容器和镜像缓存
        if command -v docker &> /dev/null; then
            echo -e "\\n正在清理 Docker 缓存..."
            if confirm_internal "确认清理 Docker 容器和镜像缓存"; then
                if docker system prune -f 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Docker 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Docker 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Docker 缓存清理"
            fi
        fi

        # 清理系统日志文件
        echo -e "\\n正在清理系统日志文件..."
        if [[ -d "/var/log" ]]; then
            local log_size
            log_size=$(get_dir_size "/var/log")
            echo -e "  - 检测到系统日志目录，大小: ${YELLOW}$log_size${NC}"
            if confirm_internal "确认清理旧日志文件 (保留最近)"; then
                if sudo find /var/log -type f -name "*.log" -mtime +30 -delete 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理旧日志文件"
                else
                    echo -e "  ${RED}✗${NC} 清理日志文件时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过日志文件清理"
            fi
        fi

        # 清理旧的内核文件 (仅适用于 Debian/Ubuntu)
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            echo -e "\\n正在检查旧内核..."
            if command -v dpkg &> /dev/null; then
                local old_kernels
                old_kernels=$(dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1)
                if [[ -n "$old_kernels" ]]; then
                    echo -e "  - 检测到旧内核:"
                    echo "$old_kernels"
                    if confirm_internal "确认删除旧内核"; then
                        if echo "$old_kernels" | xargs sudo apt-get purge -y 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已删除旧内核"
                        else
                            echo -e "  ${RED}✗${NC} 删除旧内核时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过旧内核删除"
                    fi
                else
                    echo -e "  - 未检测到旧内核"
                fi
            fi
        fi

        # 清理 Snap 缓存
        if command -v snap &> /dev/null; then
            echo -e "\\n正在清理 Snap 缓存..."
            if confirm_internal "确认清理 Snap 缓存"; then
                if snap set system refresh.retain=2 2>/dev/null && snap run --shell snap-store -c 'rm -rf /var/lib/snapd/cache/*' 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Snap 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Snap 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Snap 缓存清理"
            fi
        fi

        # 清理 Flatpak 缓存
        if command -v flatpak &> /dev/null; then
            echo -e "\\n正在清理 Flatpak 缓存..."
            if confirm_internal "确认清理 Flatpak 缓存"; then
                if flatpak uninstall --unused 2>/dev/null && flatpak cache cleanup 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Flatpak 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Flatpak 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Flatpak 缓存清理"
            fi
        fi
    fi
}

# 清理 Homebrew 缓存（在 Linux 和 macOS 上都可用）
cleanup_homebrew() {
    if command -v brew &> /dev/null; then
        echo -e "  - ${GREEN}检测到 Homebrew${NC}，扫描缓存..."
        # 显示将要清理的内容但不执行，除非确认
        local brew_cache_dir
        brew_cache_dir=$(brew --cache 2>/dev/null)
        if [[ -z "$brew_cache_dir" || ! -e "$brew_cache_dir" ]]; then
            echo -e "  ${YELLOW}-${NC} Homebrew 缓存目录不可用，已跳过"
            return
        fi
        local cache_size
        cache_size=$(get_dir_size "$brew_cache_dir")
        echo -e "  - 当前 Homebrew 缓存大小: ${YELLOW}$cache_size${NC}"
        
        # 自动跳过空缓存
        if [[ "$cache_size" == "0KB" ]]; then
            echo -e "  ${YELLOW}-${NC} Homebrew 缓存为空，已跳过"
            return
        fi
        
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Homebrew 缓存" "$cache_size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Homebrew 缓存清理"
                return
            fi
        fi
        
        echo -e "  - 正在执行 brew cleanup（最多等待 60 秒）..."
        if run_with_timeout 60 brew cleanup --prune=all -s 2>&1; then
            local cache_size_after
            cache_size_after=$(get_dir_size "$brew_cache_dir")
            echo -e "  ${GREEN}✓${NC} 已清理 Homebrew 缓存: $cache_size -> $cache_size_after"
            log_action "SUCCESS" "清理 Homebrew 缓存: $cache_size -> $cache_size_after"
        else
            local rc=$?
            if [[ $rc -eq 124 ]]; then
                echo -e "  ${YELLOW}⚠${NC} Homebrew cleanup 超时（60s），已跳过"
                echo -e "     可手动执行: brew cleanup --prune=all"
            else
                echo -e "  ${RED}✗${NC} 清理 Homebrew 缓存时出现错误 (exit=$rc)"
                log_action "ERROR" "清理 Homebrew 缓存失败 (exit=$rc)"
            fi
        fi
    else
        echo -e "  ${YELLOW}-${NC} 未检测到 Homebrew，跳过"
    fi
}

# 扫描大文件
scan_large_files() {
    echo -e "\n${YELLOW}正在扫描大文件 (>100MB)...${NC}"
    local min_size_mb=100
    local max_files=20
    local count=0
    
    echo -e "\n${YELLOW}找到的大文件:${NC}"
    find "$HOME" -type f -size +"${min_size_mb}M" -not -path "*/\.*" -not -path "*/Library/*" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | while read -r file; do
        if [[ $count -lt $max_files ]]; then
            local file_size
            file_size=$(du -h "$file" 2>/dev/null | cut -f1)
            echo -e "  ${YELLOW}$file_size${NC} - $file"
            ((count++))
        fi
    done
    
    echo -e "\n${YELLOW}提示: 手动删除不需要的大文件可以释放大量空间${NC}"
}

# 检测重复文件
detect_duplicate_files() {
    echo -e "\n${YELLOW}正在检测重复文件...${NC}"
    
    if command -v fdupes &> /dev/null; then
        echo -e "  - 使用 fdupes 扫描重复文件..."
        fdupes -r "$HOME" 2>/dev/null | head -n 50
    else
        echo -e "  ${YELLOW}未安装 fdupes，跳过重复文件检测${NC}"
        echo -e "  安装: brew install fdupes (macOS) 或 apt install fdupes (Linux)"
    fi
}

# 清理空目录
cleanup_empty_dirs() {
    echo -e "\n${YELLOW}正在清理空目录...${NC}"
    
    local empty_count=0
    find "$HOME" -type d -empty -not -path "*/\.*" 2>/dev/null | while read -r dir; do
        if [[ $BATCH_MODE -eq 0 ]]; then
            read -r -p "  - 删除空目录: $dir? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                rmdir "$dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除: $dir" && ((empty_count++))
            fi
        else
            rmdir "$dir" 2>/dev/null && ((empty_count++))
        fi
    done
    
    echo -e "  ${GREEN}✓${NC} 已清理 $empty_count 个空目录"
}

# 清理 Git 仓库
cleanup_git_repos() {
    echo -e "\n${YELLOW}正在清理 Git 仓库...${NC}"
    
    local git_count=0
    find "$HOME" -name ".git" -type d 2>/dev/null | while read -r git_dir; do
        local repo_dir=$(dirname "$git_dir")
        echo -e "  - 扫描: $repo_dir"
        
        if [[ $BATCH_MODE -eq 0 ]]; then
            read -r -p "  - 清理 Git 垃圾: $repo_dir? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if (cd "$repo_dir" && git gc --prune=now 2>/dev/null); then
                    echo -e "  ${GREEN}✓${NC} 已清理: $repo_dir"
                    ((git_count++))
                fi
            fi
        else
            if (cd "$repo_dir" && git gc --prune=now 2>/dev/null); then
                echo -e "  ${GREEN}✓${NC} 已清理: $repo_dir"
                ((git_count++))
            fi
        fi
    done
    
    echo -e "  ${GREEN}✓${NC} 已清理 $git_count 个 Git 仓库"
}

# 清理 NPM 缓存
cleanup_npm() {
    if command -v npm &> /dev/null; then
        echo -e "  - ${GREEN}检测到 NPM${NC}，扫描缓存..."
        local cache_dir
        cache_dir=$(npm config get cache 2>/dev/null)
        if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
            local cache_size
            cache_size=$(get_dir_size "$cache_dir")
            echo -e "  - 当前 NPM 缓存大小: ${YELLOW}$cache_size${NC}"
            
            # 自动跳过空缓存
            if [[ "$cache_size" == "N/A" || "$cache_size" == "0KB" ]]; then
                echo -e "  ${YELLOW}-${NC} NPM 缓存为空，已跳过"
                return
            fi
            
            # 批量模式下跳过确认
            if [[ $BATCH_MODE -eq 0 ]]; then
                read -r -p "  - 确认清理 NPM 缓存? [y/N] " response
                if [[ ! "$response" =~ ^[Yy]$ ]]; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 NPM 缓存清理"
                    return
                fi
            fi
            
            if npm cache clean --force 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 NPM 缓存"
            else
                echo -e "  ${RED}✗${NC} 清理 NPM 缓存时出现错误"
            fi
        else
            echo -e "  - NPM 缓存目录不存在或未配置"
        fi
    else
        echo -e "  - 未检测到 NPM，跳过"
    fi
}

# 清理 PNPM 缓存
cleanup_pnpm() {
    if ! command -v pnpm &> /dev/null; then
        echo -e "  - 未检测到 PNPM，跳过"
        return 0
    fi
    echo -e "  - ${GREEN}检测到 PNPM${NC}，准备清理 Store..."

    # 批量模式下跳过确认
    if [[ $BATCH_MODE -eq 0 ]]; then
        read -r -p "  - 确认清理 PNPM 无效包 (store prune)? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo -e "  ${YELLOW}-${NC} 已跳过 PNPM 缓存清理"
            return
        fi
    fi

    # pnpm 常由 corepack 代理；离线/网络受限时 corepack 会直接抛 Node 堆栈。
    # 这里把输出重定向到临时文件，失败时只给简洁提示，避免刷屏。
    local out rc
    out=$(mktemp 2>/dev/null || echo "/tmp/pnpm_prune.$$")
    echo -e "  - 正在执行 pnpm store prune（最多等待 30 秒）..."
    run_with_timeout 30 env COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm store prune >"$out" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} 已清理 PNPM 孤儿包"
    elif [[ $rc -eq 124 ]]; then
        echo -e "  ${YELLOW}⚠${NC} PNPM store prune 超时（30s），已跳过"
        echo -e "     可手动执行: pnpm store prune"
    elif grep -qiE 'corepack|registry\.npmjs|fetch failed|ECONN|ENOTFOUND|ETIMEDOUT|ConnectTimeout' "$out" 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC} pnpm 由 corepack 代理且无法访问网络，已跳过"
        echo -e "     可安装独立 pnpm 或联网后手动执行: pnpm store prune"
    else
        echo -e "  ${RED}✗${NC} 清理 PNPM 时出现错误 (exit=$rc)"
        tail -n 1 "$out" 2>/dev/null | sed 's/^/     /'
    fi
    rm -f "$out"
}

# 清理 Docker 缓存
cleanup_docker() {
    if command -v docker &> /dev/null; then
        echo -e "  - ${GREEN}检测到 Docker${NC}"
        
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            read -r -p "  - 确认清理 Docker 缓存（镜像、容器、网络）? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Docker 缓存清理"
                return
            fi
        fi
        
        # 检查 Docker 是否正在运行
        if docker info > /dev/null 2>&1; then
            echo -e "  - Docker 系统信息:"
            docker system df 2>/dev/null || true
            echo -e "  - 正在执行 docker system prune（最多等待 120 秒）..."
            if run_with_timeout 120 docker system prune -a --volumes --force 2>&1; then
                echo -e "  ${GREEN}✓${NC} 已清理 Docker 缓存"
            else
                local rc=$?
                if [[ $rc -eq 124 ]]; then
                    echo -e "  ${YELLOW}⚠${NC} Docker prune 超时（120s），已跳过"
                    echo -e "     可手动执行: docker system prune -a --volumes --force"
                else
                    echo -e "  ${RED}✗${NC} 清理 Docker 缓存时出现错误 (exit=$rc)"
                fi
            fi
        else
            echo -e "  ${YELLOW}!${NC} Docker 服务未运行，无法执行常规瘦身清理(prune)。"
            if [[ $BATCH_MODE -eq 0 ]]; then
                read -r -p "  - 是否要彻底删除所有 Docker 虚拟机数据(将清空所有镜像和容器!)? [y/N] " wipe_resp
                if [[ "$wipe_resp" =~ ^[Yy]$ ]]; then
                    echo -e "  - 正在清空 Docker 虚拟机数据..."
                    rm -rf "$HOME/Library/Containers/com.docker.docker/Data/vms"/* 2>/dev/null
                    rm -rf "$HOME/.docker/machine"/* 2>/dev/null
                    echo -e "  ${GREEN}✓${NC} 已彻底清空 Docker 数据"
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过 Docker 清理"
                fi
            else
                echo -e "  ${YELLOW}-${NC} Docker 未运行且处于非交互模式，已跳过清理"
            fi
        fi
    else
        echo -e "  - 未检测到 Docker，跳过"
    fi
}

# ============================================
# 可配置清理目标 (新增目录/文件只需在 CLEAN_RULES 追加一行)
# ============================================
# 字段(用 | 分隔): 名称|路径|类型|递归|确认|保留天数|说明
#   类型: dir  = 清理目录内容(保留目录本身)
#         path = 删除整个目录/路径
#         file = 删除单个文件
#         glob = 按通配符删除匹配文件
#   递归: 1 = 包含子目录, 0 = 仅当前层 (file/glob 忽略此字段)
#   确认: 1 = 交互执行时删除前询问, 0 = 直接删除 (非交互/cron 始终不询问)
#   保留天数: 0 = 不按时间过滤; N = 只清理 N 天前未修改的内容
#   说明: 展示给用户的补充信息, 可留空
# 说明: 路径中的 $HOME 在加载时展开; 路径不要加引号; 用 43 号菜单统一执行本配置
declare -a CLEAN_RULES=(
    "npx 缓存|$HOME/.npm/_npx|dir|1|0|0|npx 临时安装的包，下次执行会自动重新下载"
    "/opt/tmp 过期部署包|/opt/tmp|dir|0|0|90|仅清理 90 天前的部署包"
    "pnpm store|$HOME/Library/pnpm/store|dir|1|1|0|清空后首次安装依赖会重新下载"
    # ---- 追加示例 (取消注释即可生效) ----
    # "旧下载安装包|$HOME/Downloads/*.dmg|glob|0|1|30|只清理 30 天前的 dmg"
    # "单个缓存文件|$HOME/.cache/foo.bin|file|0|0|7|7 天前的单文件缓存"
    # "整个缓存目录|$HOME/.foo/cache|path|1|1|30|目录内 30 天无更新时整体删除"
)

# ============================================
# 卸载残留清理规则 (按标准 macOS 位置通用匹配, 无需硬编码具体路径)
# ============================================
# 格式: 名称::路径名匹配(ERE)::BundleID 匹配(ERE)::说明
#   - 使用 :: 分隔，正则中可安全使用 |
#   - 路径名匹配作用于各标准残留位置下的条目名 (自动去掉 .plist/.savedState 后缀)
#   - BundleID 匹配用于识别属于已安装应用的条目; 命中已安装应用时自动跳过
#   - 只有在系统中找不到对应应用时才会清理
# 新增规则只需追加一行; 示例:
#   "旧版某某::^OldApp( Data)?$::^com\.example\.oldapp$::应用已卸载时清理"
declare -a APP_RESIDUE_RULES=(
    "TRAE Work/SOLO::^(TRAE SOLO CN|\.trae-aicc)$::^(cn\.trae\.solo\.app|com\.trae\.app$)::TRAE Work/SOLO 已合并到 TRAE，清理旧客户端残留"
)

# 标准残留位置 (用户级, 不涉及 sudo)
APP_RESIDUE_ROOTS=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/WebKit"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/Preferences"
    "$HOME/Library/Preferences/ByHost"
    "$HOME/Library/LaunchAgents"
    "$HOME"
)

# ============================================
# 办公 / 协作软件缓存规则
# ============================================
# Electron 类办公/协作软件根目录 (存在才处理), 只清运行时缓存
OFFICE_ELECTRON_ROOTS=(
    "$HOME/Library/Application Support/Xmind/Electron v3"
    "$HOME/Library/Application Support/Notion"
    "$HOME/Library/Application Support/obsidian"
)

OFFICE_ELECTRON_SUBS=("Cache" "CachedData" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" "GrShaderCache" "GraphiteDawnCache" "ShaderCache" "Crashpad" "logs" "Logs")

# ============================================
# 即时通讯 / 协作软件缓存规则
# ============================================
# 沙盒容器缓存: bundle-id::名称 (只清 Data/Library/Caches 与 ~/Library/Caches/<id>)
IM_CONTAINER_APPS=(
    "com.tencent.xinWeChat::微信"
    "com.tencent.qq::QQ"
    "com.alibaba.DingTalkMac::钉钉"
    "com.bytedance.feishu::飞书"
    "com.tencent.WeWorkMac::企业微信"
    "ru.keepcoder.Telegram::Telegram"
    "net.whatsapp.WhatsApp::WhatsApp"
    "com.hnc.Discord::Discord"
    "com.tinyspeck.slackmacgap::Slack"
    "com.microsoft.teams2::Microsoft Teams"
    "jp.naver.line.mac::LINE"
)

# Electron 类 IM 的应用名 (~/Library/Application Support/<name> 下的运行时缓存)
IM_ELECTRON_APPS=("DingTalkMac" "Feishu" "Lark" "com.tencent.WeWorkMac" "Discord" "discord" "Slack" "Microsoft Teams" "com.tencent.meeting")

# 应用专属缓存规则: 名称::路径::确认(0/1)::说明
# 只允许放可重建缓存; 严禁放 Documents/备份/聊天记录
OFFICE_CACHE_RULES=(
    "WPS 运行缓存::$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/office6/cache::0::可自动重建"
    "WPS 云字体缓存::$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/office6/data/fonts::1::使用云字体的文档会重新下载字体"
    "WPS 插件包缓存::$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/addons/pool::1::插件会按需重新下载"
    "Office 文件缓存::$HOME/Library/Group Containers/UBF8T346G9.Office/OfficeFileCache::0::可重新下载"
    "Office 协作临时文件::$HOME/Library/Group Containers/UBF8T346G9.Office/Meeting Temp::0::可重新生成"
)

# 用户数据保护: 命中这些路径一律不删 (聊天记录/文档/图片视频等)
PROTECTED_DATA_PATTERNS=("/Data/Documents" "/Documents/" "/Desktop/" "/Downloads/" "/Pictures/" "/Movies/" "/data/backup" "/kccsdkbak")

# ============================================
# 菜单系统 - 支持多选和默认选中
# ============================================

# 定义菜单项数组（编号 名称 默认选中 适用系统 执行函数）
# 适用系统: both/macos/linux
declare -a MENU_ITEMS=(
    "1|清理用户缓存|true|both|cleanup_user_cache_menu"
            "2|清理临时文件 (/tmp)|true|both|cleanup_temp_menu"    "3|清理下载文件夹 ($HOME/Downloads)|false|both|cleanup_downloads"
)

# macOS 专用菜单项
if [[ "$OS_TYPE" == "macOS" ]]; then
    MENU_ITEMS=(
        # ========== 一、安全缓存区 (纯缓存/临时文件, 默认全选) ==========
        "1|清理 IDE 缓存 (JetBrains/VS Code/Cursor/TRAE/Sublime)|true|macos|cleanup_ide_caches"
        "2|清理应用缓存与容器 (Caches/Containers)|true|macos|cleanup_all_app_caches_macos"
        "3|清理日志、诊断与审计 (应用/系统日志 + diag/audit)|true|macos|cleanup_logs_diagnostics_audit"
        "4|清理系统临时与部署残留 (/tmp + var/folders + /opt/tmp)|true|macos|cleanup_temp_all"
        "5|清理开发环境缓存 (Brew/NPM/npx/Docker/VM + ~/.cache)|true|macos|cleanup_dev_caches_all"
        "6|清理构建工具缓存 (Gradle/Maven/Cargo/Go/NuGet/Composer/Bazel/pnpm)|true|macos|cleanup_build_tool_caches"
        "7|清理 AI 客户端缓存 (Codex/opencode/Qoder/TRAE/Hermes/Claude/Gemini)|true|macos|cleanup_ai_clients"
        "8|清理过期备份与残留应用数据 (僵尸文件)|true|macos|cleanup_orphans_backups"
        "9|清理壁纸缓存|true|macos|cleanup_wallpaper_cache"
        "10|清理浏览器缓存 (Chrome/Edge/Safari/Firefox/Brave/Arc)|true|macos|cleanup_browsers"
        "11|按配置清理扩展目录/文件 (CLEAN_RULES)|false|macos|cleanup_custom_rules"
        # ========== 二、应用专项 ==========
        "12|清理办公软件缓存 (WPS/Xmind/Office/Notion/Obsidian)|true|macos|cleanup_office_apps"
        "13|清理即时通讯软件缓存 (微信/QQ/钉钉/飞书/企业微信等)|true|macos|cleanup_im_apps"
        "14|清理 Xcode 缓存与组件 (衍生数据/模拟器 + CommandLineTools)|false|macos|cleanup_xcode_all"
        # ========== 三、维护与高风险 ==========
        "15|清理 Git 仓库垃圾 (gc/prune)|false|both|cleanup_git_repos"
        "16|清理下载目录及浏览历史|false|both|cleanup_downloads_history"
        "17|清理空目录|false|both|cleanup_empty_dirs"
        "18|清理音乐创作软件资源库 (GarageBand/Logic)|false|macos|cleanup_garageband_logic"
        # ========== 四、分析工具 (不删除, 仅扫描) ==========
        "19|扫描大文件 (>100MB)|false|both|scan_large_files"
        "20|检测重复文件|false|both|detect_duplicate_files"
        # ========== 组合操作 ==========
        "21|清理所有 (执行所有清理项目)|false|both|cleanup_all_macos"
        "0|退出|false|both|exit_script"
    )
else
    # Linux 专用菜单项
    MENU_ITEMS+=(
        "4|清理 Linux 系统缓存 (/var/cache)|true|linux|cleanup_linux_system_cache"
        "5|清理包管理器缓存|true|linux|cleanup_package_manager_cache"
        "6|清理 Homebrew 缓存|true|both|cleanup_homebrew"
        "7|清理其他缓存 (NPM, Docker)|true|both|cleanup_npm_docker"
        "8|清理应用数据 (日志/缓存/VM镜像)|true|both|cleanup_app_data_cache"
        "9|扫描大文件 (>100MB)|false|both|scan_large_files"
        "10|检测重复文件|false|both|detect_duplicate_files"
        "11|清理空目录|false|both|cleanup_empty_dirs"
        "12|清理 Git 仓库|false|both|cleanup_git_repos"
        "13|清理所有 (执行所有清理项目)|false|both|cleanup_all_linux"
        "0|退出|false|both|exit_script"
    )
fi

# 显示菜单
show_menu() {
    echo -e "\\n${YELLOW}请选择要清理的项目 (多选用逗号或空格分隔, 如: 1,2,3 或 1 2 3):${NC}"
    echo -e "${YELLOW}带 * 的为默认选中项目，直接回车将执行所有带 * 的项目${NC}\\n"
    
    local idx=0
    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        
        # 只显示适用于当前系统的选项
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        
        # 显示默认选中标记
        local marker=" "
        [[ "$default" == "true" ]] && marker="*"
        
        printf " [%s] %-2s %s\\n" "$marker" "$num" "$name"
        ((idx++))
    done
    
    echo ""
    echo -e "${BLUE}提示: 输入 'a' 或 'all' 执行所有项目，输入 'q' 或 '0' 退出${NC}"
}

# 全局数组用于存储解析后的选择
SELECTED_ITEMS=()

# 解析用户输入的选择
parse_selection() {
    local input="$1"
    
    # 清空全局数组
    SELECTED_ITEMS=()
    
    # 处理特殊输入
    if [[ -z "$input" ]]; then
        # 空输入，返回所有默认选中的项目
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$default" == "true" ]] && SELECTED_ITEMS+=("$num")
        done
        return
    fi
    
    # 处理 all
    if [[ "$input" == "a" || "$input" == "all" ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$num" != "0" ]] && SELECTED_ITEMS+=("$num")
        done
        return
    fi
    
    # 处理逗号或空格分隔的输入
    local IFS=', '
    for choice in $input; do
        # 验证是否为有效数字
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            SELECTED_ITEMS+=("$choice")
        fi
    done
}

# ============================================
# 菜单项执行函数
# ============================================

# 1. 清理用户缓存
cleanup_user_cache_menu() {
    echo -e "\n${YELLOW}正在清理用户缓存...${NC}"
    if [[ "$OS_TYPE" == "macOS" ]]; then
        cleanup_user_cache "$HOME/Library/Caches" "用户缓存"
    else
        cleanup_user_cache "$HOME/.cache" "用户应用缓存"
    fi
}

# 2. 清理临时文件
cleanup_temp_menu() {
    echo -e "\n${YELLOW}正在清理临时文件...${NC}"
    cleanup "/tmp" "系统临时文件"
}

# 3. 清理下载文件夹
cleanup_downloads() {
    echo -e "\n${YELLOW}正在清理下载文件夹...${NC}"
    local downloads_dir="$HOME/Downloads"
    
    if [[ -d "$downloads_dir" ]]; then
        local size_before size_after
        size_before=$(get_dir_size "$downloads_dir")
        echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
        
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清空下载文件夹（保留安装包）"; then
                echo -e "  ${YELLOW}-${NC} 已跳过下载文件夹清理"
                return
            fi
        fi
        
        # 构建 find 命令，排除安装包
        local find_cmd="find \"$downloads_dir\" -maxdepth 1 -type f -not -name \".*\""
        if [[ "$OS_TYPE" == "macOS" ]]; then
            find_cmd="$find_cmd -not -name \"*.dmg\" -not -name \"*.pkg\" -not -name \"*.iso\" -not -name \"*.mpkg\""
        else
            find_cmd="$find_cmd -not -name \"*.deb\" -not -name \"*.rpm\" -not -name \"*.AppImage\" -not -name \"*.flatpak\" -not -name \"*.snap\""
        fi
        find_cmd="$find_cmd -delete 2>/dev/null"
        
        if eval $find_cmd; then
            find "$downloads_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
            size_after=$(get_dir_size "$downloads_dir")
            echo -e "  ${GREEN}✓${NC} 已清理下载文件夹: $size_before → $size_after (保留安装包)"
            log_action "SUCCESS" "清理下载文件夹: $size_before → $size_after"
        else
            echo -e "  ${RED}✗${NC} 清理下载文件夹失败"
            log_action "ERROR" "清理下载文件夹失败"
        fi
    else
        echo -e "  ${YELLOW}-${NC} 下载文件夹不存在"
    fi
}

# 4. macOS: Safari 历史 / Linux: 系统缓存
cleanup_safari_history() {
    echo -e "\n${YELLOW}正在清理 Safari 下载历史...${NC}"
    local safari_file="$HOME/Library/Safari/Downloads.plist"
    if [[ -f "$safari_file" ]]; then
        echo -e "  - 找到 Safari 下载历史: $safari_file"
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Safari 下载历史"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Safari 下载历史清理"
                return
            fi
        fi
        if rm -f "$safari_file" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 Safari 下载历史"
            log_action "SUCCESS" "清理 Safari 下载历史"
        else
            echo -e "  ${RED}✗${NC} 清理 Safari 下载历史失败"
            log_action "ERROR" "清理 Safari 下载历史失败"
        fi
    else
        echo -e "  - Safari 下载历史文件不存在，跳过"
    fi
}

cleanup_linux_system_cache() {
    echo -e "\n${YELLOW}正在清理 Linux 系统缓存...${NC}"
    cleanup_linux_specific
}

# 只清理包管理器缓存；菜单项 4 已覆盖整个 cleanup_linux_specific，
# 若第 5 项继续指向同一函数会导致 /var/cache、用户缓存、Docker、日志等重复清理。
cleanup_package_manager_cache() {
    echo -e "\n${YELLOW}正在清理包管理器缓存...${NC}"
    ensure_sudo || return 1
    case "$DISTRO" in
        ubuntu|debian)
            if command -v apt-get >/dev/null 2>&1; then
                if confirm_internal "确认清理 APT 缓存"; then
                    sudo apt-get clean 2>/dev/null && \
                        echo -e "  ${GREEN}✓${NC} 已清理 APT 缓存" || \
                        echo -e "  ${RED}✗${NC} 清理 APT 缓存时出现错误"
                fi
            fi
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                confirm_internal "确认清理 DNF 缓存" && sudo dnf clean all 2>/dev/null
            elif command -v yum >/dev/null 2>&1; then
                confirm_internal "确认清理 YUM 缓存" && sudo yum clean all 2>/dev/null
            fi
            ;;
        arch|manjaro)
            if command -v pacman >/dev/null 2>&1; then
                confirm_internal "确认清理 Pacman 缓存" && sudo pacman -Sc 2>/dev/null
            fi
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                confirm_internal "确认清理 APT 缓存" && sudo apt-get clean 2>/dev/null
            fi
            ;;
    esac
}

# 5. macOS: 诊断报告 / Linux: 包管理器缓存
cleanup_diagnostic_reports() {
    echo -e "\n${YELLOW}正在清理系统诊断报告...${NC}"
    cleanup "/Library/Logs/DiagnosticReports" "系统诊断报告" "true"
}

# 6. macOS: 软件更新缓存 / Linux: (同 5)
cleanup_software_update_cache() {
    echo -e "\n${YELLOW}正在清理软件更新缓存...${NC}"
    if [[ -d "/Library/Caches/com.apple.SoftwareUpdate" ]]; then
        echo -e "  - 检测到软件更新缓存，需要管理员权限"
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理软件更新缓存"; then
                echo -e "  ${YELLOW}-${NC} 已跳过软件更新缓存清理"
                return
            fi
        fi
        ensure_sudo || return 1
        if sudo rm -rf /Library/Caches/com.apple.SoftwareUpdate/* 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理软件更新缓存"
            log_action "SUCCESS" "清理软件更新缓存"
        else
            echo -e "  ${RED}✗${NC} 清理软件更新缓存失败"
            log_action "ERROR" "清理软件更新缓存失败"
        fi
    else
        echo -e "  - 软件更新缓存目录不存在，跳过"
    fi
}

# 7. 清理 Homebrew 缓存
cleanup_homebrew_menu() {
    cleanup_homebrew
}

# 8. 清理 NPM 和 Docker 缓存
cleanup_npm_docker() {
    echo -e "\n${YELLOW}正在清理其他缓存 (NPM, PNPM, Docker)...${NC}"
    cleanup_npm
    cleanup_pnpm
    cleanup_docker
}

# 9. macOS: 日志和自动保存 / Linux: 启动 ncdu 主目录
cleanup_logs_autosave() {
    echo -e "\n${YELLOW}正在清理日志和自动保存文件...${NC}"
    
    # 清理用户日志文件（使用通用函数）
    cleanup_by_pattern "$HOME/Library/Logs" "用户日志文件" "*.log"
    
    # 清理自动保存信息（使用通用函数）
    cleanup_generic "$HOME/Library/Autosave Information" "自动保存文件"
    
    # 清理保存的应用状态（使用通用函数）
    cleanup_generic "$HOME/Library/Saved Application State" "保存的应用状态"
    
    # 清理 XDG 状态日志（通用，不硬编码具体应用名）
    local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
    if [[ -d "$xdg_state" ]]; then
        echo -e "  - ${GREEN}XDG 状态日志${NC} ($xdg_state)"
        # 清理 7 天前的通用日志文件（保留近期运行中的日志）
        find "$xdg_state" -type f \( -name "*.log" -o -name "*.out" -o -name "*.err" -o -name "*.trace" \) -mtime +7 -delete 2>/dev/null
        # 兜底：清理超大未轮转日志（>= 200MB 且 1 天前未更新）
        find "$xdg_state" -type f \( -name "*.log" -o -name "*.out" -o -name "*.err" \) -size +200M -mtime +1 -delete 2>/dev/null
    fi
    
    # 清理 XDG 本地日志（通用）
    local xdg_log="${XDG_LOG_HOME:-$HOME/.local/log}"
    if [[ -d "$xdg_log" ]]; then
        cleanup_by_pattern "$xdg_log" "XDG 本地日志" "*.log"
        # 同时清理其他常用日志后缀
        find "$xdg_log" -type f \( -name "*.out" -o -name "*.err" -o -name "*.trace" \) -mtime +7 -delete 2>/dev/null
    fi
}

# 清理可再生的 XDG 数据目录（通用：snapshot/snapshots/tmp/.tmp 等）
cleanup_regenerable_xdg() {
    echo -e "\n${YELLOW}正在清理可再生的 XDG 数据文件...${NC}"
    
    local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
    local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
    local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    local found=0
    
    # 1) ~/.local/share 下的 snapshot/snapshots
    if [[ -d "$xdg_data" ]]; then
        echo -e "  - ${GREEN}XDG 数据缓存${NC} ($xdg_data)"
        local snap_dir
        while IFS= read -r -d '' snap_dir; do
            [[ -z "$snap_dir" || ! -d "$snap_dir" ]] && continue
            # 跳过 node_modules 等明显非本地快照目录
            [[ "$snap_dir" == */node_modules/* ]] && continue
            # 仅清理 >=1 天前的文件，尽量避免清理运行中刚生成的快照
            local cnt
            cnt=$(find "$snap_dir" -type f -mtime +1 -print -delete 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$cnt" -gt 0 ]]; then
                ((found += cnt))
                echo -e "    已清理 $(basename "$snap_dir") 中 $cnt 个过期文件"
            fi
            # 若目录已为空则移除空目录
            if [[ -d "$snap_dir" ]] && [[ -z "$(ls -A "$snap_dir" 2>/dev/null)" ]]; then
                rmdir "$snap_dir" 2>/dev/null && echo -e "    已移除空目录: $snap_dir"
            fi
        done < <(find "$xdg_data" -type d \( -name "snapshot" -o -name "snapshots" \) -print0 2>/dev/null)
        
        # 2) 通用临时目录（tmp/.tmp），仅清理 >=2 天前的文件
        while IFS= read -r -d '' tmp_dir; do
            [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]] && continue
            [[ "$tmp_dir" == */node_modules/* ]] && continue
            local tcnt
            tcnt=$(find "$tmp_dir" -type f -mtime +2 -print -delete 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$tcnt" -gt 0 ]]; then
                ((found += tcnt))
                echo -e "    已清理临时目录 $(basename "$(dirname "$tmp_dir")")/$(basename "$tmp_dir") 中 $tcnt 个过期文件"
            fi
            if [[ -d "$tmp_dir" ]] && [[ -z "$(ls -A "$tmp_dir" 2>/dev/null)" ]]; then
                rmdir "$tmp_dir" 2>/dev/null
            fi
        done < <(find "$xdg_data" -type d \( -name "tmp" -o -name ".tmp" \) -print0 2>/dev/null)
    fi
    
    # 3) ~/.local/state 下的可再生临时目录（通用）
    if [[ -d "$xdg_state" ]]; then
        while IFS= read -r -d '' s_tmp; do
            [[ -z "$s_tmp" || ! -d "$s_tmp" ]] && continue
            [[ "$s_tmp" == */node_modules/* ]] && continue
            local scnt
            scnt=$(find "$s_tmp" -type f -mtime +2 -print -delete 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$scnt" -gt 0 ]]; then
                ((found += scnt))
                echo -e "    已清理状态临时目录中 $scnt 个过期文件"
            fi
            if [[ -d "$s_tmp" ]] && [[ -z "$(ls -A "$s_tmp" 2>/dev/null)" ]]; then
                rmdir "$s_tmp" 2>/dev/null
            fi
        done < <(find "$xdg_state" -type d \( -name "tmp" -o -name ".tmp" -o -name "temp" \) -print0 2>/dev/null)
    fi
    
    # 4) ~/.cache 下的可再生子目录（通用兜底，保守：>=3 天前）
    if [[ -d "$xdg_cache" ]]; then
        while IFS= read -r -d '' c_tmp; do
            [[ -z "$c_tmp" || ! -d "$c_tmp" ]] && continue
            [[ "$c_tmp" == */node_modules/* ]] && continue
            # 只处理名为 tmp/temp 的子目录，避免误删整个缓存
            local base
            base="$(basename "$c_tmp")"
            [[ "$base" != "tmp" && "$base" != "temp" && "$base" != ".tmp" ]] && continue
            local ccnt
            ccnt=$(find "$c_tmp" -type f -mtime +3 -print -delete 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$ccnt" -gt 0 ]]; then
                ((found += ccnt))
                echo -e "    已清理缓存临时目录中 $ccnt 个过期文件"
            fi
            if [[ -d "$c_tmp" ]] && [[ -z "$(ls -A "$c_tmp" 2>/dev/null)" ]]; then
                rmdir "$c_tmp" 2>/dev/null
            fi
        done < <(find "$xdg_cache" -type d \( -name "tmp" -o -name "temp" -o -name ".tmp" \) -print0 2>/dev/null)
    fi
    
    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 未发现可清理的可再生文件或空目录"
    else
        echo -e "  ${GREEN}✓${NC} 共清理 $found 个可再生文件"
    fi
}

# 10. macOS: 应用容器缓存 / Linux: 清理所有
cleanup_containers_cache() {
    echo -e "\n${YELLOW}正在清理应用容器缓存...${NC}"
    
    local containers_dir="$HOME/Library/Containers"
    if [[ ! -d "$containers_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 应用容器目录不存在，跳过"
        return 1
    fi
    
    local containers_size
    containers_size=$(get_dir_size "$containers_dir")
    echo -e "  - 检测到应用容器目录，大小: ${YELLOW}$containers_size${NC}"
    
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理部分应用容器缓存"; then
            echo -e "  ${YELLOW}-${NC} 已跳过应用容器缓存清理"
            return 0
        fi
    fi
    
    # 清理 Cache.db 和 Caches 目录（带进度显示）
    local cache_db_count cache_dir_count total
    cache_db_count=$(find "$containers_dir" -name "Cache.db" 2>/dev/null | wc -l)
    cache_dir_count=$(find "$containers_dir" -name "Caches" -type d 2>/dev/null | wc -l)
    total=$((cache_db_count + cache_dir_count))
    
    if [[ $total -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无缓存文件，已跳过"
        return 0
    fi
    
    local current=0 deleted=0
    echo -e "  - 找到 $cache_db_count 个 Cache.db 和 $cache_dir_count 个 Caches 目录"
    
    # 清理 Cache.db
    while IFS= read -r -d '' file; do
        ((current++))
        show_progress "$current" "$total"
        rm -f "$file" 2>/dev/null && ((deleted++))
    done < <(find "$containers_dir" -name "Cache.db" -print0 2>/dev/null)
    
    # 清理 Caches 目录
    while IFS= read -r -d '' dir; do
        ((current++))
        show_progress "$current" "$total"
        rm -rf "$dir" 2>/dev/null && ((deleted++))
    done < <(find "$containers_dir" -name "Caches" -type d -print0 2>/dev/null)
    
    echo ""
    echo -e "  ${GREEN}✓${NC} 已清理应用容器缓存: 删除 $deleted 项"
    log_action "SUCCESS" "清理应用容器缓存: 删除 $deleted 项"
}

cleanup_all_linux() {
    echo -e "\n${YELLOW}正在执行全部 Linux 清理...${NC}"
    echo -e "这将依次执行以下清理:"
    echo "  1. 清理 Linux 系统缓存"
    echo "  2. 清理包管理器缓存"
    echo "  3. 清理 Homebrew 缓存"
    echo "  4. 清理 NPM 缓存"
    echo "  5. 清理 Docker 缓存"
    if confirm_action "执行全部清理"; then
        cleanup_linux_specific
        cleanup_homebrew
        cleanup_npm
        cleanup_docker
        echo -e "${GREEN}✓ 全部 Linux 清理完成${NC}"
    else
        echo -e "${YELLOW}已取消全部清理${NC}"
    fi
}

# 11. macOS: 邮件和 QuickLook 缓存 / Linux: 退出
cleanup_mail_quicklook() {
    echo -e "\n${YELLOW}正在清理邮件和 QuickLook 缓存...${NC}"
    
    # 清理邮件缓存
    local mail_cache_dirs=("$HOME/Library/Mail" "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches")
    for mail_cache_dir in "${mail_cache_dirs[@]}"; do
        if [[ -d "$mail_cache_dir" ]]; then
            cleanup_by_pattern "$mail_cache_dir" "邮件缓存" "Cache"
            break
        fi
    done
    
    # 清理 QuickLook 缓存（需要 sudo）
    local quicklook_cache="$HOME/Library/Caches/com.apple.quicklook"
    if [[ -d "$quicklook_cache" ]]; then
        ensure_sudo || return 1
        local quicklook_size
        quicklook_size=$(get_dir_size "$quicklook_cache")
        echo -e "  - 检测到 QuickLook 缓存，大小: ${YELLOW}$quicklook_size${NC}"
        
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 QuickLook 缓存"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 QuickLook 缓存清理"
            else
                if sudo rm -rf "$quicklook_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 QuickLook 缓存"
                    sudo qlmanage -r 2>/dev/null
                    echo -e "  - 已重启 QuickLook 服务"
                    log_action "SUCCESS" "清理 QuickLook 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 QuickLook 缓存失败"
                fi
            fi
        else
            if sudo rm -rf "$quicklook_cache"/* 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 QuickLook 缓存"
                sudo qlmanage -r 2>/dev/null
                echo -e "  - 已重启 QuickLook 服务"
            else
                echo -e "  ${RED}✗${NC} 清理 QuickLook 缓存失败"
            fi
        fi
    fi
}

# ==================== 新增组合清理逻辑 ====================

cleanup_all_app_caches_macos() {
    cleanup_user_cache_menu
    cleanup_containers_cache
    cleanup_mail_quicklook
}

cleanup_all_logs_states_macos() {
    cleanup_diagnostic_reports
    cleanup_logs_autosave
    cleanup_regenerable_xdg
    cleanup_app_data_cache
}

cleanup_sys_tmp_update() {
    cleanup_temp_menu
    cleanup_software_update_cache
}

cleanup_dev_caches() {
    cleanup_homebrew
    cleanup_npm_docker
    cleanup_by_pattern "$HOME/Library/Application Support" "VM 镜像" "vm/images"
    cleanup_by_pattern "$HOME/Library/Application Support" "AI Agent VM 镜像" "ModularData/ai-agent/vm/images"
}

# 清理开发工具缓存 (~/.cache: uv/codex-runtimes/puppeteer 等，均可自动重新下载)
cleanup_dot_cache_dev() {
    echo -e "\n${YELLOW}正在清理开发工具缓存 (~/.cache)...${NC}"
    local cache_root="$HOME/.cache"
    if [[ ! -d "$cache_root" ]]; then
        echo -e "  ${YELLOW}-${NC} ~/.cache 目录不存在，跳过"
        return 0
    fi
    local subdirs=(uv codex-runtimes puppeteer chrome-devtools-mcp node opencode vscode-ripgrep netscan)
    local cleaned=0
    for sub in "${subdirs[@]}"; do
        local d="$cache_root/$sub"
        [[ -d "$d" ]] || continue
        local size
        size=$(get_dir_size "$d")
        if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
            continue
        fi
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 ~/.cache/$sub" "$size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 ~/.cache/$sub"
                continue
            fi
        fi
        if [[ "$sub" == "uv" ]] && command -v uv > /dev/null 2>&1; then
            if uv cache clean > /dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} 已清理 uv 缓存 ($size)"
            else
                find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 uv 缓存 ($size)" || echo -e "  ${RED}✗${NC} 清理 uv 缓存失败"
            fi
        else
            if find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 ~/.cache/$sub ($size)"
            else
                # 回退：直接 rm -rf 目录内容（处理 find -exec 失败的特殊文件/权限问题）
                rm -rf "$d"/* "$d"/.[!.]* 2>/dev/null
                local size_after
                size_after=$(get_dir_size "$d")
                if [[ "$size_after" == "0KB" || "$size_after" == "N/A" ]]; then
                    echo -e "  ${GREEN}✓${NC} 已清理 ~/.cache/$sub ($size)"
                else
                    echo -e "  ${RED}✗${NC} 清理 ~/.cache/$sub 失败 (剩余 $size_after，可能有文件被占用)"
                fi
            fi
        fi
        ((cleaned++))
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 ~/.cache 子目录"
    fi
}

# 清理 Chrome 的 macOS code-sign 临时副本。
# Chrome 会在系统临时目录的 X/com.google.Chrome.code_sign_clone 下创建副本；
# 这里只处理超过 1 天的副本，且 Chrome 运行时直接跳过，避免影响更新或启动。
chrome_code_sign_clone_dir() {
    [[ "$OS_TYPE" == "macOS" ]] || return 1
    local tmp_dir
    # macOS 上 Chrome 使用每用户临时目录 (DARWIN_USER_TEMP_DIR)，TMPDIR 可能被 IDE 改写
    tmp_dir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
    [[ -n "$tmp_dir" && -d "$tmp_dir" ]] || tmp_dir="${TMPDIR:-}"
    [[ -n "$tmp_dir" && -d "$tmp_dir" ]] || return 1
    tmp_dir="${tmp_dir%/}"
    printf '%s/X/com.google.Chrome.code_sign_clone\n' "$(dirname "$tmp_dir")"
}

cleanup_chrome_code_sign_clones() {
    [[ "$OS_TYPE" == "macOS" ]] || return 0
    echo -e "\n${YELLOW}正在清理 Chrome 临时签名副本...${NC}"

    if pgrep -x "Google Chrome" >/dev/null 2>&1 || pgrep -f "Google Chrome Helper" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}-${NC} 检测到 Chrome 正在运行，请完全退出 Chrome 后重试"
        return 0
    fi

    local clone_root
    clone_root="$(chrome_code_sign_clone_dir || true)"
    if [[ -z "$clone_root" || "$clone_root" != */X/com.google.Chrome.code_sign_clone ]]; then
        echo -e "  ${YELLOW}-${NC} 未找到 Chrome 临时签名目录，跳过"
        return 0
    fi
    if [[ ! -d "$clone_root" ]]; then
        echo -e "  ${YELLOW}-${NC} Chrome 临时签名目录不存在，跳过"
        return 0
    fi

    local candidates=()
    local candidate
    local total_kb=0
    shopt -s nullglob
    for candidate in "$clone_root"/code_sign_clone.*; do
        [[ -d "$candidate" ]] || continue
        # 保留最近一天内创建/修改的目录，避免碰到正在进行的 Chrome 更新。
        if find "$candidate" -prune -type d -mtime +1 -print >/dev/null 2>&1; then
            candidates+=("$candidate")
            local size_kb
            size_kb=$(du -sk "$candidate" 2>/dev/null | cut -f1)
            [[ "$size_kb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + size_kb))
        fi
    done
    shopt -u nullglob

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 未发现超过 1 天的 Chrome 临时签名副本"
        return 0
    fi

    local total_size
    total_size=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
    echo -e "  - 检测到旧副本: ${YELLOW}${total_size}${NC}，目录数: ${#candidates[@]}"
    if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome 临时签名副本" "$total_size"; then
        echo -e "  ${YELLOW}-${NC} 已跳过 Chrome 临时签名副本清理"
        return 0
    fi

    local deleted=0
    for candidate in "${candidates[@]}"; do
        if rm -rf -- "$candidate" 2>/dev/null; then
            ((deleted++))
        fi
    done
    echo -e "  ${GREEN}✓${NC} 已清理 Chrome 临时签名副本: 删除 ${deleted} 个目录，释放约 ${total_size}"
    log_action "SUCCESS" "清理 Chrome 临时签名副本: ${total_size}"
}

# 清理 Gradle 缓存 (~/.gradle/caches 与 wrapper/dists，均可自动重新下载)
cleanup_gradle_cache() {
    echo -e "\n${YELLOW}正在清理 Gradle 缓存...${NC}"
    local gradle_dir="$HOME/.gradle"
    local cleaned=0
    if [[ ! -d "$gradle_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} ~/.gradle 目录不存在，跳过"
        return 0
    fi
    for sub in caches wrapper/dists; do
        local d="$gradle_dir/$sub"
        [[ -d "$d" ]] || continue
        local size
        size=$(get_dir_size "$d")
        if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
            continue
        fi
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Gradle $sub" "$size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Gradle $sub"
                continue
            fi
        fi
        if find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 Gradle $sub ($size)"
        else
            echo -e "  ${RED}✗${NC} 清理 Gradle $sub 失败"
        fi
        ((cleaned++))
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Gradle 缓存"
    fi
}

# 清理 Cargo (Rust) 缓存 (~/.cargo/registry/cache 与 src)
cleanup_cargo_cache() {
    echo -e "\n${YELLOW}正在清理 Cargo (Rust) 缓存...${NC}"
    local registry="$HOME/.cargo/registry"
    local cleaned=0
    if [[ ! -d "$registry" ]]; then
        echo -e "  ${YELLOW}-${NC} ~/.cargo/registry 目录不存在，跳过"
        return 0
    fi
    for sub in cache src; do
        local d="$registry/$sub"
        [[ -d "$d" ]] || continue
        local size
        size=$(get_dir_size "$d")
        if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
            continue
        fi
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Cargo registry/$sub" "$size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Cargo registry/$sub"
                continue
            fi
        fi
        if find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 Cargo registry/$sub ($size)"
        else
            echo -e "  ${RED}✗${NC} 清理 Cargo registry/$sub 失败"
        fi
        ((cleaned++))
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Cargo 缓存"
    fi
}

# 清理 Go 缓存 (~/.cache/go-build, ~/go/pkg/mod, ~/go/bin)
# 优先使用 go clean 命令（更安全），回退到直接删除
cleanup_go_cache() {
    echo -e "\n${YELLOW}正在清理 Go 缓存...${NC}"
    local go_dir="$HOME/go"
    if [[ ! -d "$go_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} ~/go 目录不存在，跳过"
        return 0
    fi
    local cleaned=0

    # 优先使用 go clean 命令（处理 ~/.cache/go-build + ~/go/pkg/mod）
    if command -v go &>/dev/null; then
        local build_size
        build_size=$(get_dir_size "$HOME/.cache/go-build")
        if [[ "$build_size" != "0KB" && "$build_size" != "N/A" ]]; then
            if [[ $BATCH_MODE -eq 0 ]]; then
                if ! confirm_action "清理 Go build 缓存 (~/.cache/go-build)" "$build_size"; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 Go build 缓存"
                else
                    if go clean -cache 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理 Go build 缓存 ($build_size)"
                        ((cleaned++))
                    else
                        echo -e "  ${RED}✗${NC} 清理 Go build 缓存失败"
                    fi
                fi
            else
                if go clean -cache 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Go build 缓存 ($build_size)"
                    ((cleaned++))
                fi
            fi
        fi
        local mod_size
        mod_size=$(get_dir_size "$HOME/go/pkg")
        if [[ "$mod_size" != "0KB" && "$mod_size" != "N/A" ]]; then
            if [[ $BATCH_MODE -eq 0 ]]; then
                if ! confirm_action "清理 Go 模块缓存 (~/go/pkg)" "$mod_size"; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 Go 模块缓存"
                else
                    if go clean -modcache 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理 Go 模块缓存 ($mod_size)"
                        ((cleaned++))
                    else
                        echo -e "  ${RED}✗${NC} 清理 Go 模块缓存失败"
                    fi
                fi
            else
                if go clean -modcache 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Go 模块缓存 ($mod_size)"
                    ((cleaned++))
                fi
            fi
        fi
    else
        # Go 未安装，直接删除 pkg 和 go-build 缓存目录
        for sub in pkg; do
            local d="$go_dir/$sub"
            [[ -d "$d" ]] || continue
            local size
            size=$(get_dir_size "$d")
            if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
                continue
            fi
            if [[ $BATCH_MODE -eq 0 ]]; then
                if ! confirm_action "清理 Go $sub" "$size"; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 Go $sub"
                    continue
                fi
            fi
            if find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 Go $sub ($size)"
            else
                echo -e "  ${RED}✗${NC} 清理 Go $sub 失败"
            fi
            ((cleaned++))
        done
        local gocache="$HOME/.cache/go-build"
        if [[ -d "$gocache" ]]; then
            local size
            size=$(get_dir_size "$gocache")
            if [[ "$size" != "0KB" && "$size" != "N/A" ]]; then
                if [[ $BATCH_MODE -eq 0 ]]; then
                    if confirm_action "清理 Go build 缓存" "$size"; then
                        rm -rf "$gocache"/* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Go build 缓存 ($size)" || echo -e "  ${RED}✗${NC} 清理 Go build 缓存失败"
                        ((cleaned++))
                    fi
                else
                    rm -rf "$gocache"/* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Go build 缓存 ($size)"
                    ((cleaned++))
                fi
            fi
        fi
    fi

    # 清理 ~/go/bin（已安装的二进制，可重新 go install）
    local bin_dir="$go_dir/bin"
    if [[ -d "$bin_dir" ]]; then
        local bin_size
        bin_size=$(get_dir_size "$bin_dir")
        if [[ "$bin_size" != "0KB" && "$bin_size" != "N/A" ]]; then
            if [[ $BATCH_MODE -eq 0 ]]; then
                if ! confirm_action "清理 Go 已安装的二进制 (~/go/bin)" "$bin_size"; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 Go bin"
                else
                    rm -rf "$bin_dir"/* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Go bin ($bin_size)" || echo -e "  ${RED}✗${NC} 清理 Go bin 失败"
                    ((cleaned++))
                fi
            else
                rm -rf "$bin_dir"/* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Go bin ($bin_size)"
                ((cleaned++))
            fi
        fi
    fi

    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Cargo 缓存"
    fi
}

# 清理 Go 缓存 (~/.go/pkg 与 ~/.go/bin，均可 go install/go mod 自动恢复)
cleanup_go_cache() {
    echo -e "\n${YELLOW}正在清理 Go 缓存...${NC}"
    local go_root="${GOPATH:-$HOME/go}"
    local cleaned=0
    if [[ ! -d "$go_root" ]]; then
        echo -e "  ${YELLOW}-${NC} $go_root 目录不存在，跳过"
        return 0
    fi
    # 优先使用 go clean 命令（最安全）
    if command -v go &>/dev/null; then
        echo -e "  - 使用 go clean 清理缓存..."
        if go clean -cache -modcache 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 Go 构建缓存和模块缓存 (go clean -cache -modcache)"
            ((cleaned++))
        else
            echo -e "  ${YELLOW}-${NC} go clean 部分失败，回退到 rm 清理"
        fi
    fi
    # 回退: 直接清理 pkg/bin 目录内容
    for sub in pkg/mod pkg/sumdb bin; do
        local d="$go_root/$sub"
        [[ -d "$d" ]] || continue
        local size
        size=$(get_dir_size "$d")
        if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
            continue
        fi
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Go $sub" "$size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Go $sub"
                continue
            fi
        fi
        if find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 Go $sub ($size)"
        else
            echo -e "  ${RED}✗${NC} 清理 Go $sub 失败"
        fi
        ((cleaned++))
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Go 缓存"
    fi
}

# 清理 VS Code 扩展安装包缓存
cleanup_vscode_extension_cache() {
    echo -e "\n${YELLOW}正在清理 VS Code 扩展安装包缓存...${NC}"
    cleanup_generic "$HOME/Library/Application Support/Code/CachedExtensionVSIXs" "VS Code 扩展安装包缓存"
}

# Electron 类应用的运行时缓存子目录白名单 (均为引擎缓存, 删除后自动重建)
ELECTRON_SAFE_SUBS=("Cache" "CachedData" "CachedExtensions" "CachedExtensionVSIXs" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" "GrShaderCache" "GraphiteDawnCache" "ShaderCache" "logs" "Logs" "Crashpad")
# IDE 类 (VS Code 系 / Cursor / TRAE 等)
IDE_ELECTRON_APPS=("TRAE SOLO CN" "Trae CN" "Code" "Code - Insiders" "Windsurf" "Cursor" "VSCodium")
# AI 客户端类 (Codex/Comate/ChatGPT/豆包等)
AI_ELECTRON_APPS=("Codex" "cloud-code" "Comate" "CodeBuddy" "chatglm" "ChatGPT" "Doubao")

# 清理指定 Electron 应用的运行时缓存子目录
# 参数: 标签 IDE/AI 以及应用名列表
cleanup_electron_app_cache_subs() {
    local label="$1"; shift
    local apps=("$@")
    local cleaned=0 app sub d size
    for app in "${apps[@]}"; do
        local app_dir="$HOME/Library/Application Support/$app"
        [[ -d "$app_dir" ]] || continue
        for sub in "${ELECTRON_SAFE_SUBS[@]}"; do
            d="$app_dir/$sub"
            [[ -d "$d" ]] || continue
            size=$(get_dir_size "$d")
            if [[ "$size" == "0KB" || "$size" == "N/A" || "$size" == "0B" ]]; then
                continue
            fi
            if [[ $BATCH_MODE -eq 0 ]]; then
                if ! confirm_action "清理 [$app] 运行时缓存: $sub" "$size"; then
                    echo -e "  ${YELLOW}-${NC} 已跳过 [$app] $sub"
                    continue
                fi
            fi
            # 删除目录内容但保留目录本身 (部分应用要求目录存在)
            if rm -rf "${d:?}/"* 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 [$app] $sub ($size)"
                ((cleaned++))
            else
                echo -e "  ${RED}✗${NC} 清理 [$app] $sub 失败"
            fi
        done
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 ${label} 运行时缓存"
    fi
}

# 清理 Electron 类 IDE 应用的运行时缓存 (TRAE/Code/Cursor 等)
# 仅清理浏览器引擎运行时缓存子目录 (删除后自动重建, 不含用户数据)
# 绝不触碰: User/ModularData/Local Storage/Session Storage/IndexedDB/Cookies/Preferences/Partitions
cleanup_electron_app_caches() {
    echo -e "\n${YELLOW}正在清理 Electron 类 IDE 应用运行时缓存...${NC}"
    echo -e "  ${BLUE}仅清理运行时缓存 (Cache/CachedData/GPUCache/logs 等), 不触碰会话/配置/登录态${NC}"
    cleanup_electron_app_cache_subs "IDE" "${IDE_ELECTRON_APPS[@]}"
}

# 清理 AI 客户端 (Codex/Comate/ChatGPT/豆包等) 的运行时缓存
cleanup_ai_app_caches() {
    echo -e "\n${YELLOW}正在清理 AI 客户端运行时缓存...${NC}"
    echo -e "  ${BLUE}仅清理引擎缓存/日志, 不触碰会话、模型与登录态${NC}"
    cleanup_electron_app_cache_subs "AI" "${AI_ELECTRON_APPS[@]}"
}

# 清理豆包 (Doubao) 电脑版缓存与日志
# 安全范围: gecko 引擎缓存 / SDK 日志 / 旧热修复包 / 沙箱运行时 / 旧版本安装文件
# 绝不触碰: Default (用户数据/会话/登录态)
cleanup_doubao_cache() {
    echo -e "\n${YELLOW}正在清理豆包 (Doubao) 缓存与日志...${NC}"
    local app_dir="$HOME/Library/Application Support/Doubao"
    if [[ ! -d "$app_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 豆包数据目录不存在，跳过"
        return 0
    fi
    local cleaned=0

    # 1. Gecko 浏览器引擎缓存 (删除后自动重建)
    local gecko="$app_dir/gecko_cache"
    if [[ -d "$gecko" ]]; then
        local sz
        sz=$(get_dir_size "$gecko")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理豆包 Gecko 引擎缓存" "$sz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 Gecko 引擎缓存"
        else
            rm -rf "${gecko:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Gecko 引擎缓存 ($sz)" && ((cleaned++))
        fi
    fi

    # 2. SDK 日志 (sdk_storage/log, 日志可安全删除)
    local sdk_log="$app_dir/sdk_storage/log"
    if [[ -d "$sdk_log" ]]; then
        local lsz
        lsz=$(get_dir_size "$sdk_log")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理豆包 SDK 日志" "$lsz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 SDK 日志"
        else
            rm -rf "${sdk_log:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 SDK 日志 ($lsz)" && ((cleaned++))
        fi
    fi

    # 3. 旧热修复包 (hot_fix, 保留最新版本)
    local hotfix="$app_dir/hot_fix"
    if [[ -d "$hotfix" ]]; then
        local versions=() v
        while IFS= read -r v; do [[ -n "$v" ]] && versions+=("$v"); done < <(ls -1 "$hotfix" 2>/dev/null)
        if [[ ${#versions[@]} -gt 1 ]]; then
            local kept="${versions[${#versions[@]}-1]}"
            for v in "${versions[@]}"; do
                [[ "$v" == "$kept" ]] && continue
                local vsz
                vsz=$(get_dir_size "$hotfix/$v")
                if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "删除旧热修复包 $v" "$vsz"; then
                    continue
                fi
                rm -rf "$hotfix/$v" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理旧热修复包 $v ($vsz)" && ((cleaned++))
            done
            [[ $cleaned -gt 0 ]] && echo -e "  ${BLUE}  保留最新热修复包: $kept${NC}"
        else
            echo -e "  ${YELLOW}-${NC} 无旧热修复包，跳过"
        fi
    fi

    # 4. 沙箱运行时 (sandbox_runtime, 删除后自动重建)
    local sandbox="$app_dir/sandbox_runtime"
    if [[ -d "$sandbox" ]]; then
        local ssz
        ssz=$(get_dir_size "$sandbox")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理豆包沙箱运行时 (将自动重建)" "$ssz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过沙箱运行时"
        else
            rm -rf "${sandbox:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理沙箱运行时 ($ssz)" && ((cleaned++))
        fi
    fi

    # 5. 旧版本安装文件 (installed_versions, 保留当前版本)
    local iv="$app_dir/installed_versions"
    if [[ -d "$iv" ]]; then
        local ivs=() ivd
        while IFS= read -r ivd; do [[ -n "$ivd" ]] && ivs+=("$ivd"); done < <(ls -1 "$iv" 2>/dev/null)
        if [[ ${#ivs[@]} -gt 1 ]]; then
            local iv_kept="${ivs[${#ivs[@]}-1]}"
            for ivd in "${ivs[@]}"; do
                [[ "$ivd" == "$iv_kept" ]] && continue
                local vsz2
                vsz2=$(get_dir_size "$iv/$ivd")
                if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "删除豆包旧版本 $ivd" "$vsz2"; then
                    continue
                fi
                rm -rf "$iv/$ivd" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理旧版本 $ivd ($vsz2)" && ((cleaned++))
            done
            [[ $cleaned -gt 0 ]] && echo -e "  ${BLUE}  保留当前版本: $iv_kept${NC}"
        else
            echo -e "  ${YELLOW}-${NC} 无旧版本安装文件，跳过"
        fi
    fi

    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的豆包缓存"
    fi
}

# 清理 Chrome 应用数据目录内的缓存 (组件/AI 模型/Service Worker 缓存)
# 安全范围: component_crx_cache / screen_ai / optimization_guide_model_store /
#           Default 下 Service Worker 缓存 / WasmTtsEngine / GPUCache 等引擎缓存
# 绝不触碰: 书签/历史/密码/扩展配置/登录态 (Default 下除上述目录外均保留)
cleanup_chrome_appdata_cache() {
    echo -e "\n${YELLOW}正在清理 Chrome 应用数据缓存...${NC}"
    local chrome_dir="$HOME/Library/Application Support/Google/Chrome"
    if [[ ! -d "$chrome_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} Chrome 数据目录不存在，跳过"
        return 0
    fi

    # 检查 Chrome 是否在运行（运行时清理 Service Worker 可能引发异常）
    local chrome_running=false
    if pgrep -x "Google Chrome" >/dev/null 2>&1 || pgrep -f "Google Chrome Helper" >/dev/null 2>&1; then
        chrome_running=true
        echo -e "  ${YELLOW}提示: Chrome 正在运行，Service Worker 缓存将跳过（其余项仍可清理）${NC}"
    fi

    local cleaned=0
    # 1. 组件缓存 (component_crx_cache) — 自动重新下载
    local comp="$chrome_dir/component_crx_cache"
    if [[ -d "$comp" ]]; then
        local csz
        csz=$(get_dir_size "$comp")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome 组件缓存" "$csz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过组件缓存"
        else
            rm -rf "${comp:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理组件缓存 ($csz)" && ((cleaned++))
        fi
    fi

    # 2. screen_ai (AI 屏幕理解模型缓存) — 自动重新下载
    local sai="$chrome_dir/screen_ai"
    if [[ -d "$sai" ]]; then
        local ssz
        ssz=$(get_dir_size "$sai")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome screen_ai 模型缓存" "$ssz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 screen_ai"
        else
            rm -rf "${sai:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 screen_ai 模型缓存 ($ssz)" && ((cleaned++))
        fi
    fi

    # 3. optimization_guide_model_store (优化指南模型) — 自动重新下载
    for mstore in "$chrome_dir/optimization_guide_model_store" "$chrome_dir/Default/optimization_guide_model_store"; do
        if [[ -d "$mstore" ]]; then
            local msz
            msz=$(get_dir_size "$mstore")
            if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome 优化模型缓存" "$msz"; then
                continue
            fi
            rm -rf "${mstore:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理优化模型缓存 ($msz)" && ((cleaned++))
        fi
    done

    # 4. WasmTtsEngine (TTS 引擎缓存)
    local tts="$chrome_dir/WasmTtsEngine"
    if [[ -d "$tts" ]]; then
        local tsz
        tsz=$(get_dir_size "$tts")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome TTS 引擎缓存" "$tsz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 TTS 引擎缓存"
        else
            rm -rf "${tts:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 TTS 引擎缓存 ($tsz)" && ((cleaned++))
        fi
    fi

    # 5. 各 Profile 下的引擎缓存 (GPUCache/ShaderCache 等)
    local profiles=("Default" "Profile 2" "Profile 3" "Taobao")
    local engine_subs=("GPUCache" "GrShaderCache" "DawnGraphiteCache" "DawnWebGPUCache" "ShaderCache" "GraphiteDawnCache")
    for prof in "${profiles[@]}"; do
        local pdir="$chrome_dir/$prof"
        [[ -d "$pdir" ]] || continue
        for sub in "${engine_subs[@]}"; do
            local ed="$pdir/$sub"
            [[ -d "$ed" ]] || continue
            local esz
            esz=$(get_dir_size "$ed")
            if [[ "$esz" == "0KB" || "$esz" == "N/A" ]]; then
                continue
            fi
            if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 [$prof] $sub" "$esz"; then
                continue
            fi
            rm -rf "${ed:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 [$prof] $sub ($esz)" && ((cleaned++))
        done
    done

    # 6. Service Worker 缓存 (站点缓存, 重新访问自动重建; Chrome 运行时跳过)
    if [[ "$chrome_running" == false ]]; then
        local sw_root="$chrome_dir/Default/Service Worker/CacheStorage"
        if [[ -d "$sw_root" ]]; then
            local wsz
            wsz=$(get_dir_size "$sw_root")
            if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Chrome Service Worker 缓存" "$wsz"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 Service Worker 缓存"
            else
                rm -rf "${sw_root:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Service Worker 缓存 ($wsz)" && ((cleaned++))
            fi
        fi
    fi

    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Chrome 应用数据缓存"
    fi
}

# =======================================================
# 浏览器缓存 (Chrome/Edge/Brave/Arc/Vivaldi/Chromium/Opera/Safari/Firefox)
# 只清理缓存与临时副本, 不触碰历史记录/书签/Cookie/登录态
# =======================================================
CHROMIUM_ROOT_CACHE_SUBS=("component_crx_cache" "extensions_crx_cache" "optimization_guide_model_store" "screen_ai" "WasmTtsEngine" "ShaderCache" "GrShaderCache" "GraphiteDawnCache" "DawnGraphiteCache" "DawnWebGPUCache")
CHROMIUM_PROFILE_CACHE_SUBS=("Cache" "Code Cache" "GPUCache" "Media Cache" "Service Worker/CacheStorage" "Service Worker/ScriptCache" "DawnGraphiteCache" "DawnWebGPUCache" "GrShaderCache" "ShaderCache")

# 列出 Chromium 系浏览器的 profile 目录
chromium_browser_profiles() {
    local root="$1"
    local profiles=("$root/Default" "$root/Guest Profile" "$root/System Profile")
    shopt -s nullglob
    profiles+=("$root"/Profile*)
    shopt -u nullglob
    printf '%s\n' "${profiles[@]}"
}

# 统计 Chromium 系浏览器缓存 (KB)
chromium_browser_cache_kb() {
    local root="$1" kb=0 d sub k p
    [[ -d "$root" ]] || { echo 0; return; }
    for sub in "${CHROMIUM_ROOT_CACHE_SUBS[@]}"; do
        d="$root/$sub"; [[ -d "$d" ]] || continue
        k=$(du -sk "$d" 2>/dev/null | cut -f1)
        [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
    done
    while IFS= read -r p; do
        [[ -n "$p" && -d "$p" ]] || continue
        for sub in "${CHROMIUM_PROFILE_CACHE_SUBS[@]}"; do
            d="$p/$sub"; [[ -d "$d" ]] || continue
            k=$(du -sk "$d" 2>/dev/null | cut -f1)
            [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
        done
    done < <(chromium_browser_profiles "$root")
    echo "$kb"
}

# 清理 Chromium 系浏览器缓存
cleanup_chromium_browser_caches() {
    local name="$1" root="$2" d sub p cleaned=0
    [[ -d "$root" ]] || return 0
    echo -e "\n${YELLOW}正在清理 ${name} 缓存...${NC}"
    for sub in "${CHROMIUM_ROOT_CACHE_SUBS[@]}"; do
        d="$root/$sub"; [[ -d "$d" ]] || continue
        clear_dir_contents "$d" "$name/$sub" && ((cleaned++))
    done
    while IFS= read -r p; do
        [[ -n "$p" && -d "$p" ]] || continue
        for sub in "${CHROMIUM_PROFILE_CACHE_SUBS[@]}"; do
            d="$p/$sub"; [[ -d "$d" ]] || continue
            clear_dir_contents "$d" "$name/${p##*/}/$sub" && ((cleaned++))
        done
    done < <(chromium_browser_profiles "$root")
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到 ${name} 可清理缓存"
    return 0
}

# Safari / WebKit 缓存目录
safari_cache_dirs() {
    printf '%s\n' \
        "$HOME/Library/Caches/com.apple.Safari" \
        "$HOME/Library/Containers/com.apple.Safari/Data/Library/Caches" \
        "$HOME/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari" \
        "$HOME/Library/Caches/com.apple.Safari.SafeBrowsing" \
        "$HOME/Library/Caches/com.apple.WebKit.Networking" \
        "$HOME/Library/Caches/com.apple.WebKit.WebContent"
}

safari_cache_kb() {
    local kb=0 d k
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        k=$(du -sk "$d" 2>/dev/null | cut -f1)
        [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
    done < <(safari_cache_dirs)
    echo "$kb"
}

cleanup_safari_caches() {
    echo -e "\n${YELLOW}正在清理 Safari / WebKit 缓存...${NC}"
    local d cleaned=0
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        clear_dir_contents "$d" "${d/#$HOME/~}" && ((cleaned++))
    done < <(safari_cache_dirs)
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到 Safari 可清理缓存"
    return 0
}

# Firefox 缓存目录 (cache2 / startupCache)
firefox_cache_dirs() {
    local p
    shopt -s nullglob
    for p in "$HOME/Library/Caches/Firefox/Profiles"/*; do
        [[ -d "$p" ]] || continue
        printf '%s\n' "$p/cache2" "$p/startupCache"
    done
    for p in "$HOME/Library/Application Support/Firefox/Profiles"/*; do
        [[ -d "$p" ]] || continue
        printf '%s\n' "$p/startupCache"
    done
    shopt -u nullglob
}

firefox_cache_kb() {
    local kb=0 d k
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        k=$(du -sk "$d" 2>/dev/null | cut -f1)
        [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
    done < <(firefox_cache_dirs)
    echo "$kb"
}

cleanup_firefox_caches() {
    echo -e "\n${YELLOW}正在清理 Firefox 缓存...${NC}"
    local d cleaned=0
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        clear_dir_contents "$d" "${d/#$HOME/~}" && ((cleaned++))
    done < <(firefox_cache_dirs)
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到 Firefox 可清理缓存"
    return 0
}

# 浏览器统一入口
cleanup_browsers() {
    echo -e "\n${YELLOW}正在清理浏览器缓存...${NC}"
    echo -e "  ${BLUE}只清缓存/临时副本, 不触碰历史、书签、Cookie 与登录态${NC}"
    cleanup_chromium_browser_caches "Chrome" "$HOME/Library/Application Support/Google/Chrome"
    cleanup_chromium_browser_caches "Edge" "$HOME/Library/Application Support/Microsoft Edge"
    cleanup_chromium_browser_caches "Brave" "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
    cleanup_chromium_browser_caches "Arc" "$HOME/Library/Application Support/Arc/User Data"
    cleanup_chromium_browser_caches "Vivaldi" "$HOME/Library/Application Support/Vivaldi"
    cleanup_chromium_browser_caches "Chromium" "$HOME/Library/Application Support/Chromium"
    cleanup_chromium_browser_caches "Opera" "$HOME/Library/Application Support/com.operasoftware.Opera"
    cleanup_firefox_caches
    cleanup_safari_caches
    cleanup_chrome_code_sign_clones
}

# =======================================================
# 办公 / 协作软件缓存 (规则见 OFFICE_* 配置)
# =======================================================

# 路径是否属于受保护的用户数据 (聊天记录/文档/图片视频/备份)
is_protected_data_path() {
    local p="$1" pat
    for pat in "${PROTECTED_DATA_PATTERNS[@]}"; do
        [[ "$p" == *"$pat"* ]] && return 0
    done
    return 1
}

# 解析办公缓存规则: 名称::路径::确认::说明
parse_office_rule() {
    local rest
    OFF_LABEL="${1%%::*}"
    rest="${1#*::}"
    OFF_PATH="${rest%%::*}"
    rest="${rest#*::}"
    OFF_CONFIRM="${rest%%::*}"
    OFF_NOTE="${rest#*::}"
}

# 通用 Electron 办公软件缓存
cleanup_office_electron_roots() {
    local root sub d upd
    for root in "${OFFICE_ELECTRON_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        for sub in "${OFFICE_ELECTRON_SUBS[@]}"; do
            d="$root/$sub"
            [[ -d "$d" ]] || continue
            is_protected_data_path "$d" && continue
            clear_dir_contents "$d" "${d/#$HOME/~}"
        done
        # 自动更新包通常位于二级目录 (如 Xmind/vana/auto-updater)
        while IFS= read -r upd; do
            [[ -n "$upd" && -d "$upd" ]] || continue
            is_protected_data_path "$upd" && continue
            clear_dir_contents "$upd" "${upd/#$HOME/~}"
        done < <(find "$root" -maxdepth 2 -type d -name "auto-updater" 2>/dev/null)
    done
}

# 办公/协作软件统一入口
cleanup_office_apps() {
    echo -e "\n${YELLOW}正在清理办公与协作软件缓存...${NC}"
    echo -e "  ${BLUE}只清可重建缓存, 不触碰文档、聊天记录、图片视频与备份${NC}"
    cleanup_office_electron_roots

    local rule label path confirm note any=0
    for rule in "${OFFICE_CACHE_RULES[@]}"; do
        parse_office_rule "$rule"
        label="$OFF_LABEL"; path="$OFF_PATH"; confirm="$OFF_CONFIRM"; note="$OFF_NOTE"
        [[ -d "$path" ]] || continue
        if is_protected_data_path "$path"; then
            echo -e "  ${YELLOW}-${NC} 跳过受保护路径: ${path/#$HOME/~}"
            continue
        fi
        any=1
        local kb size
        kb=$(du -sk "$path" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        size=$(format_size_kb "$kb")
        echo -e "\n  ${YELLOW}${label}${NC} (${size})"
        [[ -n "$note" ]] && echo -e "    ${BLUE}${note}${NC}"
        if [[ "$confirm" == "1" ]]; then
            if [[ ! -t 0 ]]; then
                echo -e "    ${YELLOW}-${NC} 非交互模式，跳过需确认项"
                continue
            fi
            if ! confirm_action "清理 ${label}" "$size"; then
                echo -e "    ${YELLOW}-${NC} 已跳过"
                continue
            fi
        fi
        clear_dir_contents "$path" "$label"
    done
    [[ $any -eq 0 ]] && echo -e "  - 未检测到可清理的办公软件缓存"
    return 0
}

# 通用沙盒容器缓存 (只清 Caches, 不含 Documents/消息库)
cleanup_im_container_caches() {
    local entry bid name cache
    for entry in "${IM_CONTAINER_APPS[@]}"; do
        bid="${entry%%::*}"
        name="${entry#*::}"
        for cache in \
            "$HOME/Library/Containers/$bid/Data/Library/Caches" \
            "$HOME/Library/Caches/$bid"; do
            [[ -d "$cache" ]] || continue
            if is_protected_data_path "$cache"; then
                echo -e "  ${YELLOW}-${NC} 跳过受保护路径: ${cache/#$HOME/~}"
                continue
            fi
            clear_dir_contents "$cache" "$name 缓存"
        done
    done
}

# 即时通讯软件统一入口
# 只清表情/资源缓存与引擎缓存, 绝不触碰聊天记录、图片、视频、文件
cleanup_im_apps() {
    echo -e "\n${YELLOW}正在清理即时通讯软件缓存...${NC}"
    echo -e "  ${BLUE}只清缓存, 绝不触碰聊天记录、图片、视频、文件与账号数据${NC}"
    cleanup_wechat_cache
    cleanup_im_container_caches
    cleanup_electron_app_cache_subs "IM" "${IM_ELECTRON_APPS[@]}"
    return 0
}

# 清理微信 (WeChat) 表情与资源缓存
# 安全范围: Stickers (表情包缓存, 重新发送会重新下载) / MMResourceMgr / 容器 Caches
# 绝不触碰: Data/Documents (聊天记录、图片、视频、文件) / 收藏 / 账号数据
# 注意: 即使文件时间很久, 也不代表用户不需要, 因此聊天数据一律不按时间清理
cleanup_wechat_cache() {
    echo -e "\n${YELLOW}正在清理微信表情与资源缓存...${NC}"
    local wx_root="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
    if [[ ! -d "$wx_root" ]]; then
        echo -e "  ${YELLOW}-${NC} 微信数据目录不存在，跳过"
        return 0
    fi
    local cleaned=0

    # 1. 表情包缓存 (Stickers)
    local stickers=""
    stickers=$(find "$wx_root/Library/Application Support/com.tencent.xinWeChat" -type d -name "Stickers" 2>/dev/null | head -1)
    if [[ -n "$stickers" && -d "$stickers" ]] && ! is_protected_data_path "$stickers"; then
        local sz
        sz=$(get_dir_size "$stickers")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理微信表情缓存" "$sz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过表情缓存"
        else
            rm -rf "${stickers:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理表情缓存 ($sz)" && ((cleaned++))
        fi
    fi

    # 2. 资源管理器缓存 (MMResourceMgr)
    local resmgr=""
    resmgr=$(find "$wx_root/Library/Application Support/com.tencent.xinWeChat" -type d -name "MMResourceMgr" 2>/dev/null | head -1)
    if [[ -n "$resmgr" && -d "$resmgr" ]] && ! is_protected_data_path "$resmgr"; then
        local rsz
        rsz=$(get_dir_size "$resmgr")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理微信资源管理器缓存" "$rsz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过资源管理器缓存"
        else
            rm -rf "${resmgr:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理资源管理器缓存 ($rsz)" && ((cleaned++))
        fi
    fi

    # 3. 微信容器 Caches
    local wx_caches="$wx_root/Library/Caches"
    if [[ -d "$wx_caches" ]] && ! is_protected_data_path "$wx_caches"; then
        local csz
        csz=$(get_dir_size "$wx_caches")
        if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理微信容器缓存" "$csz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过容器缓存"
        else
            rm -rf "${wx_caches:?}/"* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理容器缓存 ($csz)" && ((cleaned++))
        fi
    fi

    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的微信缓存"
    fi
}

# 清理 TRAE AI Agent 沙箱工具链 (谨慎项, 默认不选)
# 说明: ModularData/ai-agent/vm/tools 是 TRAE AI Agent 内置的沙箱工具链
#       (opt/share/npm-global, 约 3GB)。删除后 TRAE 会在下次使用时重新初始化下载,
#       期间 AI Agent 功能暂不可用。不影响编辑器的其他功能。
cleanup_trae_agent_sandbox() {
    echo -e "\n${YELLOW}正在清理 TRAE AI Agent 沙箱工具链...${NC}"
    local tools_dir="$HOME/Library/Application Support/TRAE SOLO CN/ModularData/ai-agent/vm/tools"
    if [[ ! -d "$tools_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} TRAE AI Agent 工具链目录不存在，跳过"
        return 0
    fi
    local sz
    sz=$(get_dir_size "$tools_dir")
    echo -e "  ${YELLOW}警告: 此操作将删除 TRAE AI Agent 的沙箱工具链 ($sz)，${NC}"
    echo -e "  ${YELLOW}      下次使用 AI Agent 时会重新初始化下载 (需联网)。${NC}"
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "删除 TRAE AI Agent 沙箱工具链 (将重新初始化)" "$sz"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    rm -rf "${tools_dir:?}/"* 2>/dev/null
    echo -e "  ${GREEN}✓${NC} 已清理 TRAE AI Agent 沙箱工具链 ($sz)"
    log_action "SUCCESS" "清理 TRAE AI Agent 沙箱工具链: $sz"
}

# 智能清理 Maven 本地仓库（复用 clean-maven.sh，保留活跃依赖，只删超期未用依赖）
cleanup_maven_repo() {
    echo -e "\n${YELLOW}正在智能清理 Maven 本地仓库 (clean-maven.sh)...${NC}"
    local script_path="${BASH_SOURCE[0]}"
    local script_dir
    script_dir=$(cd "$(dirname "$script_path")" && pwd)
    local clean_script="$script_dir/../../java/build-tools/maven/clean-maven.sh"
    if [[ ! -f "$clean_script" ]]; then
        echo -e "  ${RED}✗${NC} 未找到 clean-maven.sh ($clean_script)"
        return 1
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "执行 Maven 仓库智能清理（保留活跃依赖，删除超期未用依赖）"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    if bash "$clean_script" --skip-upgrade --workspace="$HOME/workspace"; then
        echo -e "  ${GREEN}✓${NC} Maven 仓库智能清理完成"
        log_action "SUCCESS" "Maven 仓库智能清理"
    else
        echo -e "  ${RED}✗${NC} Maven 仓库智能清理失败"
        log_action "ERROR" "Maven 仓库智能清理失败"
    fi
}

cleanup_downloads_history() {
    cleanup_downloads
    cleanup_safari_history
}

cleanup_xcode_derived_data() {
    echo -e "\n${YELLOW}正在清理 Xcode 衍生数据及归档...${NC}"
    cleanup_generic "$HOME/Library/Developer/Xcode/DerivedData" "Xcode DerivedData"
    cleanup_generic "$HOME/Library/Developer/Xcode/Archives" "Xcode Archives"
}

# 清理系统诊断数据库 (macOS)
cleanup_system_diagnostics() {
    echo -e "\n${YELLOW}正在清理系统诊断数据库...${NC}"
    local diag_dir="/private/var/db/diagnostics"
    if [[ ! -d "$diag_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 诊断数据库目录不存在，跳过"
        return
    fi
    ensure_sudo "find \"$diag_dir\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +" || return 1
    local size
    size=$(sudo du -sh "$diag_dir" 2>/dev/null | awk '{print $1}')
    echo -e "  - 系统诊断数据库大小: ${YELLOW}$size${NC}"
    if [[ "$size" == "0KB" || "$size" == "0B" || "$size" == "N/A" || -z "$size" ]]; then
        echo -e "  ${YELLOW}-${NC} 诊断数据库为空，已跳过"
        return
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理系统诊断数据库" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过系统诊断数据库清理"
            return
        fi
    fi
    if sudo find "$diag_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 已清理系统诊断数据库"
        log_action "SUCCESS" "清理系统诊断数据库: $size"
    else
        echo -e "  ${RED}✗${NC} 清理系统诊断数据库失败 (可能需要授权 Full Disk Access)"
        log_action "ERROR" "清理系统诊断数据库失败"
    fi
}

# 清理过期备份目录
cleanup_expired_backups() {
    echo -e "\n${YELLOW}正在扫描过期备份目录...${NC}"
    local found=0
    shopt -s nullglob
    for backup_dir in "$HOME"/open-webui.backup.*; do
        if [[ -d "$backup_dir" ]]; then
            local size
            size=$(get_dir_size "$backup_dir")
            echo -e "  - 发现过期备份: $(basename "$backup_dir")，大小: ${YELLOW}$size${NC}"
            found=1
            if [[ $BATCH_MODE -eq 0 ]]; then
                if confirm_action "删除过期备份 $(basename "$backup_dir")" "$size"; then
                    rm -rf "$backup_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除" || echo -e "  ${RED}✗${NC} 删除失败"
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过"
                fi
            else
                rm -rf "$backup_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除" || echo -e "  ${RED}✗${NC} 删除失败"
            fi
        fi
    done
    shopt -u nullglob
    if [[ $found -eq 0 ]]; then
        echo -e "  - 未检测到过期备份目录"
    fi
}

# 清理 Qoder 缓存 (仅 cache/tmp 与 30 天前的会话历史；保留 .auth 凭证、settings、plugins 和近期会话)
cleanup_qoder_cache() {
    echo -e "\n${YELLOW}正在清理 Qoder 工具缓存...${NC}"
    local qoder_dir="$HOME/.qoder"
    if [[ ! -d "$qoder_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} Qoder 目录不存在，跳过"
        return
    fi
    local size total_kb=0
    for cd in "$qoder_dir/cache" "$qoder_dir/tmp"; do
        [[ -d "$cd" ]] || continue
        local kb
        kb=$(du -sk "$cd" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + kb))
    done
    local old_sessions
    old_sessions=$(find "$qoder_dir/projects" -type f -name '*.jsonl' -mtime +30 2>/dev/null)
    local skb
    skb=$(echo "$old_sessions" | grep -v '^$' | xargs -I{} du -k "{}" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    [[ "$skb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + skb))
    size=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
    echo -e "  - 可清理大小 (缓存 + 30天前会话历史): ${YELLOW}$size${NC}"
    if [[ "$total_kb" -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无可清理内容，已跳过"
        return
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理 Qoder 缓存与过期会话历史" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return
        fi
    fi
    local done_ok=1
    for cd in "$qoder_dir/cache" "$qoder_dir/tmp"; do
        if [[ -d "$cd" ]]; then
            rm -rf "$cd" 2>/dev/null || done_ok=0
        fi
    done
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        [[ -f "$s" ]] || continue
        rm -f "$s" 2>/dev/null || done_ok=0
    done <<< "$old_sessions"
    if [[ $done_ok -eq 1 ]]; then
        echo -e "  ${GREEN}✓${NC} 已清理 Qoder 缓存与过期会话历史"
        log_action "SUCCESS" "清理 Qoder 缓存: $qoder_dir/cache,$qoder_dir/tmp,过期会话历史"
    else
        echo -e "  ${RED}✗${NC} 清理 Qoder 缓存部分失败"
        log_action "ERROR" "清理 Qoder 缓存部分失败: $qoder_dir"
    fi
}

# 清理 GarageBand / Logic 资源库 (macOS 系统级)
cleanup_garageband_logic() {
    echo -e "\n${YELLOW}正在检查音乐创作软件资源库...${NC}"
    local garageband_dir="/Library/Application Support/GarageBand"
    local logic_dir="/Library/Application Support/Logic"
    local found=0
    
    if [[ -d "$garageband_dir" ]]; then
        ensure_sudo || return 1
        local size
        size=$(get_dir_size "$garageband_dir")
        echo -e "  - GarageBand 资源库大小: ${YELLOW}$size${NC}"
        found=1
        if confirm_action "删除 GarageBand 资源库 (如不使用)" "$size"; then
            sudo rm -rf "$garageband_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除" || echo -e "  ${RED}✗${NC} 删除失败 (需要管理员权限)"
        else
            echo -e "  ${YELLOW}-${NC} 已跳过"
        fi
    fi
    
    if [[ -d "$logic_dir" ]]; then
        ensure_sudo "rm -rf \"$logic_dir\"" || return 1
        local size
        size=$(get_dir_size "$logic_dir")
        echo -e "  - Logic Pro 资源库大小: ${YELLOW}$size${NC}"
        found=1
        if confirm_action "删除 Logic Pro 资源库 (如不使用)" "$size"; then
            sudo rm -rf "$logic_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除" || echo -e "  ${RED}✗${NC} 删除失败 (需要管理员权限)"
        else
            echo -e "  ${YELLOW}-${NC} 已跳过"
        fi
    fi
    
    if [[ $found -eq 0 ]]; then
        echo -e "  - 未检测到 GarageBand 或 Logic Pro 资源库"
    fi
}

# 清理 Xcode CommandLineTools
cleanup_xcode_clt() {
    echo -e "\n${YELLOW}正在检查 Xcode CommandLineTools...${NC}"
    local clt_dir="/Library/Developer/CommandLineTools"
    if [[ ! -d "$clt_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} CommandLineTools 未安装，跳过"
        return
    fi
    ensure_sudo "rm -rf \"$clt_dir\"" || return 1
    local size
    size=$(get_dir_size "$clt_dir")
    echo -e "  - CommandLineTools 大小: ${YELLOW}$size${NC}"
    echo -e "  ${YELLOW}注意: 删除后如需使用 git/make/clang 等工具需重新安装${NC}"
    # 危险操作：无论是否批量模式都强制逐项确认
    if ! confirm_action "删除 Xcode CommandLineTools (如不使用)" "$size"; then
        echo -e "  ${YELLOW}-${NC} 已跳过"
        return
    fi
    sudo rm -rf "$clt_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除 CommandLineTools" || echo -e "  ${RED}✗${NC} 删除失败 (需要管理员权限)"
}

# 清理壁纸缓存
cleanup_wallpaper_cache() {
    echo -e "\n${YELLOW}正在清理壁纸缓存...${NC}"
    local wallpaper_dir="$HOME/Library/Application Support/com.apple.wallpaper"
    if [[ ! -d "$wallpaper_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 壁纸缓存目录不存在，跳过"
        return
    fi
    local size
    size=$(get_dir_size "$wallpaper_dir")
    echo -e "  - 壁纸缓存大小: ${YELLOW}$size${NC}"
    if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
        echo -e "  ${YELLOW}-${NC} 壁纸缓存为空，已跳过"
        return
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理壁纸缓存" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return
        fi
    fi
    rm -rf "$wallpaper_dir"/* 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理壁纸缓存" || echo -e "  ${RED}✗${NC} 清理失败"
}

cleanup_orphan_appdata() {
    echo -e "\n${YELLOW}正在扫描残留的卸载应用数据 (僵尸文件)...${NC}"
    if [[ ! -d "$HOME/Library/Application Support" ]]; then
        echo -e "  ${YELLOW}-${NC} 未找到 Application Support 目录，跳过"
        return
    fi
    local min_kb=$(( ${UNINSTALLED_RESIDUE_MIN_MB:-100} * 1024 ))
    local found=0 total_freed=0
    local -a candidates=()
    local app_dir=""
    for app_dir in "$HOME/Library/Application Support/"*; do
        [[ -d "$app_dir" ]] || continue
        local app_name=$(basename "$app_dir")
        # 系统/共享目录黑名单（绝不建议删除）
        case "$app_name" in
            Apple|CloudDocs|Knowledge|MobileSync|CrashReporter|SyncServices|AddressBook|CallHistoryDB|com.apple.*)
                continue ;;
        esac
        # 判断对应 App 是否仍安装（精确匹配 + 通配匹配 + bundle-id 精确比对）
        local exists=0
        if [[ -d "/Applications/${app_name}.app" || -d "/System/Applications/${app_name}.app" || -d "$HOME/Applications/${app_name}.app" ]]; then
            exists=1
        elif ls /Applications/*"${app_name}"*.app >/dev/null 2>&1; then
            exists=1
        else
            # 目录名可能是 bundle id（如 com.metacubex.ClashX.meta），比对 /Applications 下 App 的 CFBundleIdentifier
            local app_path bundle_id
            for app_path in /Applications/*.app /System/Applications/*.app "$HOME/Applications"/*.app; do
                [[ -e "$app_path" ]] || continue
                bundle_id=$(defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
                if [[ -n "$bundle_id" && "$bundle_id" == "$app_name" ]]; then
                    exists=1
                    break
                fi
            done
        fi
        [[ $exists -eq 0 ]] || continue
        # 大小阈值：仅处理超过阈值的残留
        local size_kb; size_kb=$(get_dir_size_kb "$app_dir" 2>/dev/null || echo 0)
        [[ $size_kb -ge $min_kb ]] || continue
        candidates+=("$app_dir|$size_kb")
        found=1
    done
    if [[ $found -eq 0 ]]; then
        echo -e "  ${GREEN}未发现明显的大型残留应用数据 (阈值: ${UNINSTALLED_RESIDUE_MIN_MB:-100}MB)${NC}"
        return
    fi
    echo -e "  - 发现 ${YELLOW}${#candidates[@]}${NC} 个已卸载应用的残留数据 (>${UNINSTALLED_RESIDUE_MIN_MB:-100}MB):"
    local entry app_name size_kb human
    for entry in "${candidates[@]}"; do
        app_dir="${entry%%|*}"; size_kb="${entry##*|}"
        human=$(format_size_kb "$size_kb")
        echo -e "    • ${BLUE}$(basename "$app_dir")${NC} (${human})"
        echo -e "      路径: $app_dir"
    done
    # 交互模式：确认后删除（默认删除）；非交互模式（--auto/--run）：直接删除
    if [[ $BATCH_MODE -eq 0 ]]; then
        read -r -p "  - 确认删除以上 ${#candidates[@]} 个残留目录? [Y/n] " response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            echo -e "  ${YELLOW}-${NC} 已跳过残留清理"
            return
        fi
    else
        echo -e "  ${YELLOW}-${NC} 非交互模式，直接删除已确认残留"
    fi
    for entry in "${candidates[@]}"; do
        app_dir="${entry%%|*}"; size_kb="${entry##*|}"
        if rm -rf "$app_dir" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已删除残留: $(basename "$app_dir") (${size_kb}KB)"
            log_action "SUCCESS" "删除已卸载应用残留: $(basename "$app_dir")"
            total_freed=$(( total_freed + size_kb ))
        else
            echo -e "  ${RED}✗${NC} 删除失败: $(basename "$app_dir")（可能被占用或权限不足）"
            log_action "ERROR" "删除已卸载应用残留失败: $(basename "$app_dir")"
        fi
    done
    echo -e "  ${GREEN}残留清理完成，预计释放: ${YELLOW}$(format_size_kb "$total_freed")${NC}"
}

# =======================================================
# 按规则清理卸载残留 (APP_RESIDUE_RULES, 见文件顶部)
# =======================================================

# 获取当前已安装应用的 BundleID 列表
installed_app_bundle_ids() {
    local app id
    for app in /Applications/*.app /System/Applications/*.app "$HOME"/Applications/*.app; do
        [[ -d "$app" ]] || continue
        id=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
        [[ -n "$id" ]] && printf '%s\n' "$id"
    done
}

# 判断某个残留条目是否命中规则且对应应用未安装
app_residue_match() {
    local base="$1" path_re="$2" id_re="$3" installed="$4"
    local stem="${base%.plist}"
    stem="${stem%.savedState}"
    if [[ "$base" =~ $path_re || "$stem" =~ $path_re ]]; then
        [[ -d "/Applications/${stem}.app" || -d "$HOME/Applications/${stem}.app" ]] && return 1
        return 0
    fi
    if [[ -n "$id_re" && "$stem" =~ $id_re ]]; then
        printf '%s\n' "$installed" | grep -qxF "$stem" && return 1
        return 0
    fi
    return 1
}

# 列出命中规则的残留条目
app_residue_matches() {
    local path_re="$1" id_re="$2" installed="$3"
    local root entry base
    for root in "${APP_RESIDUE_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            base="${entry##*/}"
            app_residue_match "$base" "$path_re" "$id_re" "$installed" && printf '%s\n' "$entry"
        done < <(find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
    done
}

# 某条规则的残留总大小 (KB)
app_residue_rule_kb() {
    local path_re="$1" id_re="$2" installed="$3"
    local entry k kb=0
    while IFS= read -r entry; do
        k=$(du -sk "$entry" 2>/dev/null | cut -f1)
        [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
    done < <(app_residue_matches "$path_re" "$id_re" "$installed")
    echo "$kb"
}

# 解析一条残留规则到 RES_* 变量
parse_residue_rule() {
    local rest
    RES_LABEL="${1%%::*}"
    rest="${1#*::}"
    RES_PATH_RE="${rest%%::*}"
    rest="${rest#*::}"
    RES_ID_RE="${rest%%::*}"
    RES_NOTE="${rest#*::}"
}

# 按规则清理已卸载应用的残留
# 只匹配标准 macOS 位置, 且仅当对应应用未安装时才删除
cleanup_app_residue() {
    [[ "$OS_TYPE" == "macOS" ]] || return 0
    echo -e "\n${YELLOW}正在按规则清理已卸载应用的残留...${NC}"
    if [[ ${#APP_RESIDUE_RULES[@]} -eq 0 ]]; then
        echo -e "  - 未配置残留清理规则"
        return 0
    fi
    local installed
    installed=$(installed_app_bundle_ids)
    local rule label path_re id_re note entry
    for rule in "${APP_RESIDUE_RULES[@]}"; do
        parse_residue_rule "$rule"
        label="$RES_LABEL"; path_re="$RES_PATH_RE"; id_re="$RES_ID_RE"; note="$RES_NOTE"
        local matches=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && matches+=("$entry")
        done < <(app_residue_matches "$path_re" "$id_re" "$installed")
        if [[ ${#matches[@]} -eq 0 ]]; then
            echo -e "  ${YELLOW}-${NC} ${label}: 未发现残留"
            continue
        fi
        local total_kb total_entry
        total_kb=$(app_residue_rule_kb "$path_re" "$id_re" "$installed")
        total_entry=$(format_size_kb "$total_kb")
        echo -e "  - ${label}: 发现 ${#matches[@]} 项残留 (${total_entry})"
        [[ -n "$note" ]] && echo -e "    ${BLUE}${note}${NC}"
        for entry in "${matches[@]}"; do
            echo -e "    • ${entry/#$HOME/~}"
        done
        if [[ -t 0 ]] && ! confirm_action "删除 ${label} 残留" "$total_entry"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 ${label}"
            continue
        fi
        local deleted=0
        for entry in "${matches[@]}"; do
            rm -rf -- "$entry" 2>/dev/null && deleted=$((deleted + 1))
        done
        echo -e "  ${GREEN}✓${NC} ${label}: 已删除 ${deleted}/${#matches[@]} 项"
        log_action "SUCCESS" "清理卸载残留 ${label}: ${deleted} 项 (${total_entry})"
    done
}

# 清理审计日志 (/private/var/audit)
cleanup_audit_logs() {
    echo -e "\n${YELLOW}正在清理审计日志 (${BLUE}/private/var/audit${NC})...${NC}"
    local audit_dir="/private/var/audit"
    if [[ ! -d "$audit_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 审计日志目录不存在，跳过"
        return
    fi
    ensure_sudo "find \"$audit_dir\" -name '[0-9]*' -not -name '*.not_terminated' -delete" || return 1
    local size_before size_after count
    size_before=$(sudo du -sh "$audit_dir" 2>/dev/null | awk '{print $1}')
    count=$(sudo find "$audit_dir" -name "[0-9]*" -not -name "*.not_terminated" 2>/dev/null | wc -l)
    echo -e "  - 审计日志大小: ${YELLOW}${size_before}${NC}，文件数: $count"
    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无可清理的审计日志，已跳过"
        return
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理审计日志" "$size_before"; then
            echo -e "  ${YELLOW}-${NC} 已跳过审计日志清理"
            return
        fi
    fi
    if sudo find "$audit_dir" -name "[0-9]*" -not -name "*.not_terminated" -delete 2>/dev/null; then
        size_after=$(sudo du -sh "$audit_dir" 2>/dev/null | awk '{print $1}')
        echo -e "  ${GREEN}✓${NC} 已清理审计日志: ${size_before} → ${size_after}"
        log_action "SUCCESS" "清理审计日志: ${size_before} → ${size_after}"
    else
        echo -e "  ${RED}✗${NC} 清理审计日志失败 (可能需要管理员权限)"
        log_action "ERROR" "清理审计日志失败"
    fi
}

# =======================================================

# 清理 Hermes AI 助手缓存与 git 历史 (~/.hermes/cache + hermes-agent/.git)
cleanup_hermes_cache() {
    echo -e "\n${YELLOW}正在清理 Hermes 缓存与 git 历史...${NC}"
    local targets=(
        "$HOME/.hermes/cache"
        "$HOME/.hermes/hermes-agent/.git"
    )
    local cleaned=0 t
    for t in "${targets[@]}"; do
        [[ -e "$t" ]] || continue
        local size
        size=$(get_dir_size "$t")
        if [[ $BATCH_MODE -eq 0 ]]; then
            if ! confirm_action "清理 Hermes 数据: ${t#$HOME/}" "$size"; then
                echo -e "  ${YELLOW}-${NC} 已跳过 ${t#$HOME/}"
                continue
            fi
        fi
        if rm -rf "$t" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 ${t#$HOME/} ($size)"
            log_action "SUCCESS" "清理 Hermes 数据: $t"
            ((cleaned++))
        else
            echo -e "  ${RED}✗${NC} 清理 ${t#$HOME/} 失败 (可能被占用)"
            log_action "ERROR" "清理 Hermes 数据失败: $t"
        fi
    done
    if [[ $cleaned -eq 0 ]]; then
        echo -e "  - 未检测到可清理的 Hermes 缓存/git 历史"
    fi
}

# 清理系统临时目录残留 (/private/var/folders 中 7 天前的临时文件, 需 sudo)
cleanup_var_folders_tmp() {
    echo -e "\n${YELLOW}正在清理系统临时目录残留 (/private/var/folders, 7天前)...${NC}"
    if [[ ! -d "/private/var/folders" ]]; then
        echo -e "  ${YELLOW}-${NC} 目录不存在，跳过"
        return 0
    fi
    local size_before size_after count
    size_before=$(sudo du -sh /private/var/folders 2>/dev/null | awk '{print $1}')
    count=$(sudo find /private/var/folders -type f -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  - 临时目录当前大小: ${YELLOW}${size_before}${NC}，7天前的文件数: $count"
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无可清理的过期临时文件，已跳过"
        return 0
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "删除 7 天前的系统临时文件 (需要管理员权限)" "$size_before"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    ensure_sudo "find /private/var/folders -type f -mtime +7 -delete" || return 1
    size_after=$(sudo du -sh /private/var/folders 2>/dev/null | awk '{print $1}')
    echo -e "  ${GREEN}✓${NC} 已清理系统临时文件: ${size_before} → ${size_after}"
    log_action "SUCCESS" "清理系统临时文件: ${size_before} → ${size_after}"
}

# 清理 Eclipse P2 残留 (~/.p2 插件池/仓库, 需确认不使用 Eclipse/Java IDE)
cleanup_eclipse_p2() {
    echo -e "\n${YELLOW}正在扫描 Eclipse P2 残留数据...${NC}"
    local p2="$HOME/.p2"
    [[ -d "$p2" ]] || { echo -e "  - 未发现 ~/.p2 (Eclipse 已卸载或无残留)"; return 0; }
    local size
    size=$(get_dir_size "$p2")
    echo -e "  - 检测到 Eclipse P2 数据: ${BLUE}~/.p2${NC} ($size)"
    echo -e "    说明: Eclipse IDE 插件池/仓库缓存，删除后 Eclipse 需要重新安装插件"
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "删除整个 ~/.p2" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    if rm -rf "$p2" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 已删除 ~/.p2 ($size)"
        log_action "SUCCESS" "删除 Eclipse P2 残留: $p2"
    else
        echo -e "  ${RED}✗${NC} 删除 ~/.p2 失败"
        log_action "ERROR" "删除 Eclipse P2 残留失败: $p2"
    fi
}

# 清理 Codex 历史会话 (删除 30 天前的 session 目录, 不可恢复)
cleanup_codex_sessions() {
    echo -e "\n${YELLOW}正在清理 Codex 历史会话 (30天前)...${NC}"
    local sess="$HOME/.codex/sessions"
    [[ -d "$sess" ]] || { echo -e "  - 未发现 Codex 会话目录"; return 0; }
    local count size
    count=$(find "$sess" -mindepth 2 -maxdepth 2 -type d -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    size=$(get_dir_size "$sess")
    echo -e "  - 会话目录: $size，30天前的会话数: $count"
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无 30 天前的会话，已跳过"
        return 0
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "删除 30 天前的 Codex 会话 (不可恢复)" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    if find "$sess" -mindepth 2 -maxdepth 2 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 已删除 30 天前的 Codex 会话"
        log_action "SUCCESS" "清理 Codex 历史会话: $sess"
    else
        echo -e "  ${RED}✗${NC} 清理 Codex 会话失败"
        log_action "ERROR" "清理 Codex 会话失败: $sess"
    fi
}

# 清理 Agent/后台服务的会话库与运行日志膨胀项
# 日志只截断不删除 (保留文件与 inode)，快照目录可重建，会话库只做 VACUUM 回收碎片不删数据
cleanup_agent_session_caches() {
    echo -e "\n${YELLOW}正在清理 Agent 会话库与运行日志膨胀项...${NC}"
    local state_root="$HOME/.local/state"
    local snap_dir="$HOME/.local/share/opencode/snapshot"
    local dbs=("$HOME/.codex/thread_history_1.sqlite" "$HOME/.local/share/opencode/opencode.db")

    local big_logs=() f kb
    while IFS= read -r f; do
        [[ -n "$f" ]] && big_logs+=("$f")
    done < <(find "$state_root" -type f -name '*.log' -size +100M 2>/dev/null)

    local log_kb=0 snap_kb=0 db_kb=0
    for f in "${big_logs[@]}"; do
        kb=$(du -k "$f" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] && log_kb=$((log_kb + kb))
    done
    if [[ -d "$snap_dir" ]]; then
        kb=$(du -sk "$snap_dir" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] && snap_kb=$kb
    fi
    local vacuum_dbs=()
    for f in "${dbs[@]}"; do
        [[ -f "$f" ]] || continue
        kb=$(du -k "$f" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] || continue
        if lsof "$f" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}-${NC} $(basename "$f") 正被进程占用，跳过 VACUUM"
            continue
        fi
        db_kb=$((db_kb + kb))
        vacuum_dbs+=("$f")
    done

    local total_kb=$((log_kb + snap_kb))
    echo -e "  - 可截断日志: ${#big_logs[@]} 个 ($((log_kb / 1024))MB)"
    echo -e "  - 可删快照目录: $snap_dir ($((snap_kb / 1024))MB)"
    echo -e "  - 可 VACUUM 会话库: ${#vacuum_dbs[@]} 个 ($((db_kb / 1024))MB, 回收量取决于碎片率)"
    if [[ $total_kb -eq 0 && ${#vacuum_dbs[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无膨胀项，已跳过"
        return 0
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "截断大日志/删快照/VACUUM 会话库" "$((total_kb / 1024))MB"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    local ok=1
    for f in "${big_logs[@]}"; do
        if lsof "$f" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}-${NC} 日志被占用，跳过: $f"
            continue
        fi
        : > "$f" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已截断 $f" || ok=0
    done
    if [[ -d "$snap_dir" ]]; then
        rm -rf "$snap_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已删除 opencode 自动快照 (可重建)" || ok=0
    fi
    if command -v sqlite3 >/dev/null 2>&1; then
        for f in "${vacuum_dbs[@]}"; do
            sqlite3 "$f" "VACUUM;" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已 VACUUM $(basename "$f")" || ok=0
        done
    else
        echo -e "  ${YELLOW}-${NC} 未安装 sqlite3，跳过 VACUUM"
    fi
    if [[ $ok -eq 1 ]]; then
        log_action "SUCCESS" "清理 Agent 会话库与日志膨胀项: $state_root,$snap_dir"
    else
        log_action "ERROR" "清理 Agent 会话库与日志膨胀项部分失败"
    fi
}

# 清理 uv tool 安装的工具 (~/.local/share/uv/tools)
# 仅删除 CLI/MCP 工具，保留 uv 管理的 Python (~/.local/share/uv/python) 与项目 .venv
cleanup_uv_tool_data() {
    echo -e "\n${YELLOW}正在扫描 uv 工具数据...${NC}"
    local uv_dir="$HOME/.local/share/uv"
    local tools_dir="$uv_dir/tools"
    local python_dir="$uv_dir/python"
    # 只处理 uv tool 安装的工具，绝不删除 uv 管理的 Python 解释器与项目 .venv
    if [[ ! -d "$tools_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 未发现 uv tool 数据 (~/.local/share/uv/tools)，跳过"
        return 0
    fi
    local size
    size=$(get_dir_size "$tools_dir")
    echo -e "  - uv tool 工具: ${BLUE}~/.local/share/uv/tools${NC} ($size)"
    echo -e "    说明: 仅删除 uv tool 安装的 CLI/MCP 工具，之后需重新 uv tool install"
    echo -e "    保留: ~/.local/share/uv/python 与各项目 .venv"
    if [[ -d "$python_dir" ]]; then
        echo -e "    ${BLUE}检测到 uv 管理的 Python: $(get_dir_size "$python_dir") (不会删除)${NC}"
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "删除 uv tool 工具 (保留 Python 解释器)" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return 0
        fi
    fi
    if rm -rf "${tools_dir:?}/"* 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 已清理 uv tool 工具 ($size)"
        log_action "SUCCESS" "清理 uv tool 工具: $size"
    else
        echo -e "  ${RED}✗${NC} 清理 uv tool 工具失败"
        log_action "ERROR" "清理 uv tool 工具失败: $tools_dir"
    fi
}

# ============================================
# 配置化清理引擎 (CLEAN_RULES 在文件顶部定义)
# ============================================

# 当前是否交互执行 (CLI/cron/管道场景不弹确认)
custom_rule_is_interactive() {
    [[ -t 0 && -t 1 && -z "${CLI_MODE:-}" ]]
}

# 文件是否满足保留天数条件 (age=0 恒为真)
custom_rule_age_match() {
    local f="$1" age="$2"
    [[ "$age" -eq 0 ]] && return 0
    [[ -e "$f" ]] || return 1
    [[ -n "$(find "$f" -maxdepth 0 -mtime +"$age" 2>/dev/null)" ]]
}

# 目录内是否存在 N 天内修改过的文件 (用于 path 类型避免删除活跃目录)
custom_rule_has_recent_file() {
    local path="$1" age="$2"
    [[ -n "$(find "$path" -type f -mtime -"$age" -print -quit 2>/dev/null)" ]]
}

# 列出目录中满足保留天数的文件
custom_rule_find_files() {
    local path="$1" recursive="$2" age="$3"
    local depth=()
    [[ "$recursive" != "1" ]] && depth=(-maxdepth 1)
    if [[ "$age" -eq 0 ]]; then
        find "$path" "${depth[@]}" -type f 2>/dev/null
    else
        find "$path" "${depth[@]}" -type f -mtime +"$age" 2>/dev/null
    fi
}

# 计算单条规则可清理大小 (KB)
custom_rule_size_kb() {
    local path="$1" type="$2" recursive="$3" age="$4"
    local kb=0 f skb
    case "$type" in
        file)
            if [[ -f "$path" ]] && custom_rule_age_match "$path" "$age"; then
                kb=$(du -k "$path" 2>/dev/null | cut -f1)
            fi
            ;;
        glob)
            shopt -s nullglob
            for f in $path; do
                [[ -f "$f" ]] || continue
                custom_rule_age_match "$f" "$age" || continue
                skb=$(du -k "$f" 2>/dev/null | cut -f1)
                [[ "$skb" =~ ^[0-9]+$ ]] && kb=$((kb + skb))
            done
            shopt -u nullglob
            ;;
        path)
            if [[ -e "$path" ]]; then
                if [[ "$age" -eq 0 ]] || ! custom_rule_has_recent_file "$path" "$age"; then
                    kb=$(du -sk "$path" 2>/dev/null | cut -f1)
                fi
            fi
            ;;
        dir|*)
            if [[ -d "$path" ]]; then
                if [[ "$age" -eq 0 ]]; then
                    kb=$(du -sk "$path" 2>/dev/null | cut -f1)
                else
                    while IFS= read -r f; do
                        [[ -n "$f" ]] || continue
                        skb=$(du -k "$f" 2>/dev/null | cut -f1)
                        [[ "$skb" =~ ^[0-9]+$ ]] && kb=$((kb + skb))
                    done < <(custom_rule_find_files "$path" "$recursive" "$age")
                fi
            fi
            ;;
    esac
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# 执行单条配置规则
# 参数: name path type recursive confirm age note
custom_rule_cleanup() {
    local name="$1" path="$2" type="$3" recursive="$4" confirm="$5" age="$6" note="$7"
    local kb size
    kb=$(custom_rule_size_kb "$path" "$type" "$recursive" "$age")
    size=$(format_size_kb "$kb")

    echo -e "\n${YELLOW}正在清理: ${name}${NC}"
    [[ -n "$note" ]] && echo -e "  ${BLUE}${note}${NC}"
    echo -e "  - 路径: ${path}"

    if [[ "$kb" -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无可清理内容，已跳过"
        return 0
    fi
    echo -e "  - 可清理大小: ${YELLOW}${size}${NC}"
    if [[ "$confirm" == "1" ]] && custom_rule_is_interactive; then
        if ! confirm_action "清理 ${name}" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过 ${name}"
            return 0
        fi
    fi

    local ok=1 entry f
    case "$type" in
        file)
            rm -f -- "$path" 2>/dev/null || ok=0
            ;;
        glob)
            shopt -s nullglob
            for f in $path; do
                [[ -f "$f" ]] || continue
                custom_rule_age_match "$f" "$age" || continue
                rm -f -- "$f" 2>/dev/null || ok=0
            done
            shopt -u nullglob
            ;;
        path)
            rm -rf -- "$path" 2>/dev/null || ok=0
            ;;
        dir|*)
            if [[ "$age" -eq 0 ]]; then
                while IFS= read -r -d '' entry; do
                    rm -rf -- "$entry" 2>/dev/null || ok=0
                done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
            else
                while IFS= read -r f; do
                    [[ -n "$f" ]] || continue
                    rm -f -- "$f" 2>/dev/null || ok=0
                done < <(custom_rule_find_files "$path" "$recursive" "$age")
                # 递归模式下顺带移除清理后产生的空目录
                [[ "$recursive" == "1" ]] && find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null
            fi
            ;;
    esac

    # 以清理前后的实际大小校验结果，避免"删除 0 个仍报成功"
    local after_kb after_size
    after_kb=$(custom_rule_size_kb "$path" "$type" "$recursive" "$age")
    after_size=$(format_size_kb "$after_kb")
    if [[ "$ok" -eq 1 && "$after_kb" -lt "$kb" ]]; then
        echo -e "  ${GREEN}✓${NC} 已清理 ${name}: ${size} → ${after_size}"
        log_action "SUCCESS" "配置清理 ${name}: ${size} → ${after_size}"
        return 0
    fi
    echo -e "  ${RED}✗${NC} 清理 ${name} 失败 (剩余 ${after_size}，可能需要权限)"
    log_action "ERROR" "配置清理失败: ${name} (${path})"
    return 1
}

# 按名称执行单条规则
custom_rule_by_name() {
    local target="$1" item name path type recursive confirm age note
    for item in "${CLEAN_RULES[@]}"; do
        IFS='|' read -r name path type recursive confirm age note <<< "$item"
        [[ "$name" == "$target" ]] || continue
        custom_rule_cleanup "$name" "$path" "$type" "$recursive" "$confirm" "$age" "$note"
        return $?
    done
    echo -e "  ${YELLOW}-${NC} 未找到配置规则: ${target}"
    return 1
}

# 按名称获取单条规则大小 (用于扫描预估)
custom_rule_size_by_name() {
    local target="$1" item name path type recursive confirm age note
    for item in "${CLEAN_RULES[@]}"; do
        IFS='|' read -r name path type recursive confirm age note <<< "$item"
        [[ "$name" == "$target" ]] || continue
        format_size_kb "$(custom_rule_size_kb "$path" "$type" "$recursive" "$age")"
        return 0
    done
    echo "0KB"
}

# 所有配置规则合计大小 (KB)
custom_rules_total_kb() {
    local item name path type recursive confirm age note kb total=0
    for item in "${CLEAN_RULES[@]}"; do
        IFS='|' read -r name path type recursive confirm age note <<< "$item"
        kb=$(custom_rule_size_kb "$path" "$type" "$recursive" "$age")
        [[ "$kb" =~ ^[0-9]+$ ]] && total=$((total + kb))
    done
    echo "$total"
}

# 统一执行 CLEAN_RULES 中的全部规则 (新增目标只需改配置)
cleanup_custom_rules() {
    echo -e "\n${YELLOW}正在按配置清理自定义目录/文件...${NC}"
    echo -e "  ${BLUE}规则来源: 脚本顶部 CLEAN_RULES 配置区${NC}"
    if [[ ${#CLEAN_RULES[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 未配置清理规则"
        return 0
    fi
    local item name path type recursive confirm age note
    local failed=0
    for item in "${CLEAN_RULES[@]}"; do
        IFS='|' read -r name path type recursive confirm age note <<< "$item"
        custom_rule_cleanup "$name" "$path" "$type" "$recursive" "$confirm" "$age" "$note" || failed=$((failed + 1))
    done
    if [[ $failed -eq 0 ]]; then
        echo -e "\n  ${GREEN}✓${NC} 配置规则全部执行完成"
        log_action "SUCCESS" "配置规则清理完成: ${#CLEAN_RULES[@]} 条"
        return 0
    fi
    echo -e "\n  ${RED}✗${NC} 配置规则执行完成，失败 ${failed} 条"
    log_action "ERROR" "配置规则清理失败 ${failed} 条"
    return 1
}

# 38: npx 缓存 (规则见 CLEAN_RULES)
cleanup_npx_cache() {
    custom_rule_by_name "npx 缓存"
}

# 获取当前用户可用的临时目录
# TMPDIR 可能被 IDE/自动化工具改写为不存在的路径，因此需要回退到系统临时目录
user_temp_root() {
    local d=""
    # macOS 上应用实际使用每用户临时目录；TMPDIR 可能被 IDE/自动化工具改写
    if [[ "$OS_TYPE" == "macOS" ]]; then
        d=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
    fi
    d="${d%/}"
    if [[ -z "$d" || ! -d "$d" ]]; then
        d="${TMPDIR:-}"
        d="${d%/}"
    fi
    [[ -n "$d" && -d "$d" ]] || d="/tmp"
    printf '%s\n' "$d"
}

# 列出可清理的 Qoder CLI 任务目录 (3 天前创建且近 1 天无写入)
qoder_cli_old_task_dirs() {
    local tmp_root
    tmp_root=$(user_temp_root)
    [[ -n "$tmp_root" && -d "$tmp_root" ]] || return 0
    local dir t
    shopt -s nullglob
    for dir in "$tmp_root"/qoder-cli-*; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r t; do
            [[ -n "$t" ]] || continue
            # 目录内仍有近 1 天写入的文件时视为活跃任务，跳过
            [[ -n "$(find "$t" -type f -mtime -1 -print -quit 2>/dev/null)" ]] && continue
            printf '%s\n' "$t"
        done < <(find "$dir" -mindepth 2 -maxdepth 2 -type d -mtime +3 2>/dev/null)
    done
    shopt -u nullglob
}

# 清理 Qoder CLI 任务临时目录 ($TMPDIR/qoder-cli-*/<项目>/<任务>)
# 这些目录保存每次 CLI 任务的工作副本，只删除 3 天前且近 1 天无写入的任务目录，
# 并顺手移除清空后的项目占位目录；不触碰 ~/.qoder 的配置、会话历史与 file-history。
cleanup_qoder_cli_temp() {
    echo -e "\n${YELLOW}正在清理 Qoder CLI 临时任务目录...${NC}"
    local tmp_root
    tmp_root=$(user_temp_root)
    if [[ -z "$tmp_root" || ! -d "$tmp_root" ]]; then
        echo -e "  ${YELLOW}-${NC} 无法定位用户临时目录，跳过"
        return 0
    fi

    local task_dirs=() t kb total_kb=0
    while IFS= read -r t; do
        [[ -n "$t" ]] && task_dirs+=("$t")
    done < <(qoder_cli_old_task_dirs)
    if [[ ${#task_dirs[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 未发现 3 天前且无近期写入的 Qoder CLI 任务目录"
        return 0
    fi
    for t in "${task_dirs[@]}"; do
        kb=$(du -sk "$t" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + kb))
    done
    local total_size
    total_size=$(format_size_kb "$total_kb")
    echo -e "  - 可清理任务目录: ${#task_dirs[@]} 个，共 ${YELLOW}${total_size}${NC}"
    if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "清理 Qoder CLI 临时任务目录" "$total_size"; then
        echo -e "  ${YELLOW}-${NC} 已跳过 Qoder CLI 临时任务目录"
        return 0
    fi
    local deleted=0
    for t in "${task_dirs[@]}"; do
        rm -rf -- "$t" 2>/dev/null && ((deleted++))
    done
    local roots=() dir
    shopt -s nullglob
    for dir in "$tmp_root"/qoder-cli-*; do
        [[ -d "$dir" ]] && roots+=("$dir")
    done
    shopt -u nullglob
    for dir in "${roots[@]}"; do
        find "$dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
        rmdir "$dir" 2>/dev/null || true
    done
    echo -e "  ${GREEN}✓${NC} 已清理 Qoder CLI 临时任务目录: ${deleted} 个，释放约 ${total_size}"
    log_action "SUCCESS" "清理 Qoder CLI 临时任务目录: ${total_size}"
}

# 清理系统日志 (/private/var/log)
# 持续写入的日志只截断不删除 (保留文件与 inode)，轮转日志/无线日志按 7 天前删除。
cleanup_system_var_logs() {
    echo -e "\n${YELLOW}正在清理系统日志 (/private/var/log)...${NC}"
    if [[ ! -d /private/var/log ]]; then
        echo -e "  ${YELLOW}-${NC} /private/var/log 不存在，跳过"
        return 0
    fi
    ensure_sudo "truncate -s 0 /private/var/log/install.log" || return 0

    local truncate_files=(/private/var/log/install.log /private/var/log/system.log /private/var/log/daily.out)
    local f kb total_kb=0
    for f in "${truncate_files[@]}"; do
        [[ -f "$f" ]] || continue
        kb=$(sudo du -k "$f" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + kb))
    done
    local old_count
    old_count=$(sudo find /private/var/log -type f \( -name '*.log.[0-9]*' -o -name '*.gz' -o -name 'wifi-*.log' \) -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    local total_size
    total_size=$(format_size_kb "$total_kb")
    echo -e "  - 可截断日志: ${#truncate_files[@]} 个 ($total_size)，7 天前轮转日志: $old_count 个"
    if [[ $total_kb -eq 0 && "$old_count" -eq 0 ]]; then
        echo -e "  ${YELLOW}-${NC} 无可清理的日志，已跳过"
        return 0
    fi
    if [[ $BATCH_MODE -eq 0 ]] && ! confirm_action "截断系统日志并删除过期轮转日志" "$total_size"; then
        echo -e "  ${YELLOW}-${NC} 已跳过系统日志清理"
        return 0
    fi
    for f in "${truncate_files[@]}"; do
        [[ -f "$f" ]] || continue
        sudo truncate -s 0 "$f" 2>/dev/null
    done
    sudo find /private/var/log -type f \( -name '*.log.[0-9]*' -o -name '*.gz' -o -name 'wifi-*.log' \) -mtime +7 -delete 2>/dev/null
    echo -e "  ${GREEN}✓${NC} 已截断系统日志并删除过期轮转日志"
    log_action "SUCCESS" "清理系统日志: $total_size, 轮转日志 $old_count 个"
}

# 41: /opt/tmp 过期部署包 (规则见 CLEAN_RULES)
cleanup_opt_tmp() {
    custom_rule_by_name "/opt/tmp 过期部署包"
}

# 42: pnpm store (规则见 CLEAN_RULES，交互执行时会二次确认)
cleanup_pnpm_store_full() {
    custom_rule_by_name "pnpm store"
}

# =======================================================
# 菜单组合项: 把同类清理合并为一个入口, 减少菜单项数量
# 单项函数仍然保留, 组合项只做编排, 便于按需拆分/复用
# =======================================================
cleanup_ide_caches() {
    cleanup_electron_app_caches
    cleanup_vscode_extension_cache
    cleanup_jetbrains_caches
    cleanup_sublime_caches
    # Eclipse P2 插件池体积大且删除后需重装插件，交互时单独确认
    if [[ -t 0 && -d "$HOME/.p2" ]]; then
        if confirm_action "同时清理 Eclipse P2 插件池 (~/.p2, 需重装插件)" "$(get_dir_size "$HOME/.p2")"; then
            cleanup_eclipse_p2
        fi
    fi
}

cleanup_logs_diagnostics_audit() {
    cleanup_all_logs_states_macos
    cleanup_system_diagnostics
    cleanup_audit_logs
    cleanup_system_var_logs
}

cleanup_temp_all() {
    cleanup_sys_tmp_update
    cleanup_var_folders_tmp
    cleanup_opt_tmp
}

cleanup_dev_caches_all() {
    cleanup_dev_caches
    cleanup_dot_cache_dev
    cleanup_npx_cache
}

# 构建工具缓存: 安全项直接清理, 依赖仓库类交互式二次确认
cleanup_build_tool_caches() {
    cleanup_gradle_cache
    cleanup_cargo_cache
    cleanup_go_cache

    # 其他常见包管理器/构建工具缓存 (存在才处理, 删除后可重新下载)
    local dirs=(
        "$HOME/.nuget/packages"
        "$HOME/Library/Caches/composer" "$HOME/.composer/cache"
        "$HOME/Library/Caches/bazel" "$HOME/.cache/bazel"
        "$HOME/Library/Caches/Yarn" "$HOME/.cache/yarn"
    )
    echo -e "\n${YELLOW}正在清理其他构建/包管理器缓存...${NC}"
    local d kb cleaned=0
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        kb=$(du -sk "$d" 2>/dev/null | cut -f1)
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        [[ "$kb" -eq 0 ]] && continue
        if rm -rf "${d:?}/"* 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 ${d/#$HOME/~} ($(format_size_kb "$kb"))"
            ((cleaned++))
        else
            echo -e "  ${RED}✗${NC} 清理失败: ${d/#$HOME/~}"
        fi
    done
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到其他构建工具缓存"

    # 体积大、需要重新下载的依赖仓库，交互时单独确认
    if [[ -t 0 ]]; then
        if [[ -d "$HOME/.m2/repository" ]]; then
            local m2_size
            m2_size=$(get_dir_size "$HOME/.m2/repository")
            if confirm_action "同时智能清理 Maven 本地仓库 (~/.m2, 保留活跃依赖)" "$m2_size"; then
                cleanup_maven_repo
            fi
        fi
        if [[ -d "$HOME/Library/pnpm/store" ]]; then
            local pnpm_size
            pnpm_size=$(get_dir_size "$HOME/Library/pnpm/store")
            if confirm_action "同时清空 pnpm store (依赖将重新下载)" "$pnpm_size"; then
                cleanup_pnpm_store_full
            fi
        fi
    fi
}

cleanup_qoder_all() {
    cleanup_qoder_cache
    cleanup_qoder_cli_temp
}

cleanup_agent_data() {
    cleanup_codex_sessions
    cleanup_agent_session_caches
}

cleanup_orphans_backups() {
    cleanup_expired_backups
    cleanup_orphan_appdata
    cleanup_app_residue
}

# =======================================================
# 扩展缓存: IDE / 构建工具 / AI 客户端
# =======================================================

# JetBrains 系 IDE (IDEA/PyCharm/WebStorm/GoLand/CLion/Android Studio)
# 只清理索引/缓存/日志/临时目录, 不触碰配置、插件与项目文件
cleanup_jetbrains_caches() {
    echo -e "\n${YELLOW}正在清理 JetBrains 系 IDE 缓存...${NC}"
    local subs=(caches index log tmp compile-server)
    local roots=("$HOME/Library/Caches/JetBrains" "$HOME/Library/Caches/Google")
    local root product sub d kb cleaned=0
    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        local products=()
        if [[ "$root" == */JetBrains ]]; then
            shopt -s nullglob
            products=("$root"/*/)
            shopt -u nullglob
        else
            shopt -s nullglob
            products=("$root"/AndroidStudio*/)
            shopt -u nullglob
        fi
        for product in "${products[@]}"; do
            [[ -d "$product" ]] || continue
            for sub in "${subs[@]}"; do
                d="${product%/}/$sub"
                [[ -d "$d" ]] || continue
                kb=$(du -sk "$d" 2>/dev/null | cut -f1)
                [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
                [[ "$kb" -eq 0 ]] && continue
                if rm -rf "${d:?}/"* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 ${d/#$HOME/~} ($(format_size_kb "$kb"))"
                    ((cleaned++))
                else
                    echo -e "  ${RED}✗${NC} 清理失败: ${d/#$HOME/~}"
                fi
            done
        done
    done
    local jb_logs="$HOME/Library/Logs/JetBrains"
    if [[ -d "$jb_logs" ]]; then
        local lkb
        lkb=$(du -sk "$jb_logs" 2>/dev/null | cut -f1)
        [[ "$lkb" =~ ^[0-9]+$ ]] || lkb=0
        if [[ $lkb -gt 0 ]] && rm -rf "${jb_logs:?}/"* 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 ~/Library/Logs/JetBrains ($(format_size_kb "$lkb"))"
            ((cleaned++))
        fi
    fi
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到 JetBrains 缓存"
}

# Sublime Text 缓存
cleanup_sublime_caches() {
    local d cleaned=0
    shopt -s nullglob
    for d in "$HOME/Library/Caches/com.sublimetext."*; do
        [[ -d "$d" ]] || continue
        if rm -rf "${d:?}/"* 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已清理 ${d/#$HOME/~}"
            ((cleaned++))
        fi
    done
    shopt -u nullglob
    [[ $cleaned -eq 0 ]] && echo -e "  - 未检测到 Sublime Text 缓存"
}

# 清空目录内容 (保留目录本身), 供扩展缓存复用
clear_dir_contents() {
    local d="$1" name="$2" kb
    [[ -d "$d" ]] || return 0
    kb=$(du -sk "$d" 2>/dev/null | cut -f1)
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    [[ "$kb" -eq 0 ]] && return 0
    if rm -rf "${d:?}/"* 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 已清理 ${name} ($(format_size_kb "$kb"))"
        return 0
    fi
    echo -e "  ${RED}✗${NC} 清理失败: ${name}"
    return 1
}

# Codex CLI 缓存 (不包含会话历史)
cleanup_codex_cli_cache() {
    echo -e "\n${YELLOW}正在清理 Codex CLI 缓存...${NC}"
    clear_dir_contents "$HOME/.codex/cache" "Codex cache"
}

# Claude Code 缓存 (不包含会话与项目记录)
cleanup_claude_cache() {
    echo -e "\n${YELLOW}正在清理 Claude Code 缓存...${NC}"
    clear_dir_contents "$HOME/.claude/cache" "Claude cache"
    clear_dir_contents "$HOME/.claude/shell-snapshots" "Claude shell snapshots"
    if [[ -d "$HOME/.claude/backups" ]]; then
        find "$HOME/.claude/backups" -type f -mtime +30 -delete 2>/dev/null
    fi
}

# Gemini CLI 临时文件
cleanup_gemini_cache() {
    echo -e "\n${YELLOW}正在清理 Gemini CLI 临时文件...${NC}"
    clear_dir_contents "$HOME/.gemini/tmp" "Gemini tmp"
}

# TRAE CN 客户端缓存 (不包含插件、技能与会话)
cleanup_trae_cn_cache() {
    echo -e "\n${YELLOW}正在清理 TRAE CN 客户端缓存...${NC}"
    clear_dir_contents "$HOME/.trae-cn/hub_event_cache" "TRAE 事件缓存"
    clear_dir_contents "$HOME/.trae-cn/trae-browser-screenshots" "TRAE 浏览器截图缓存"
}

# AI 客户端统一入口: Codex/opencode/Qoder/TRAE/Hermes/Claude/Gemini/Comate 等
# 默认只清缓存/日志/临时文件; 体积大或含历史数据的项在交互时单独确认
cleanup_ai_clients() {
    cleanup_qoder_all
    # 仅截断日志/删快照/VACUUM，不删除会话历史
    cleanup_agent_session_caches
    [[ -d "$HOME/.codex" ]] && cleanup_codex_cli_cache
    [[ -d "$HOME/.claude" ]] && cleanup_claude_cache
    [[ -d "$HOME/.gemini" ]] && cleanup_gemini_cache
    [[ -d "$HOME/.trae-cn" ]] && cleanup_trae_cn_cache
    [[ -d "$HOME/.hermes" ]] && cleanup_hermes_cache
    cleanup_ai_app_caches
    if [[ -d "$HOME/Library/Application Support/Doubao" ]]; then
        cleanup_doubao_cache
    fi

    if [[ -t 0 ]]; then
        local trae_tools="$HOME/Library/Application Support/TRAE SOLO CN/ModularData/ai-agent/vm/tools"
        if [[ -d "$trae_tools" ]]; then
            if confirm_action "同时清理 TRAE AI Agent 沙箱工具链 (需重新下载)" "$(get_dir_size "$trae_tools")"; then
                cleanup_trae_agent_sandbox
            fi
        fi
        if [[ -d "$HOME/.local/share/uv/tools" ]]; then
            if confirm_action "同时清理 uv tool 工具 (保留 Python 解释器与项目 .venv)" "$(get_dir_size "$HOME/.local/share/uv/tools")"; then
                cleanup_uv_tool_data
            fi
        fi
        if [[ -d "$HOME/.codex/sessions" ]]; then
            if confirm_action "同时删除 30 天前的 Codex 会话历史" "$(get_dir_size "$HOME/.codex/sessions")"; then
                cleanup_codex_sessions
            fi
        fi
    fi
}

# Xcode 统一入口: 衍生数据/归档/设备支持/模拟器缓存 + CommandLineTools
# 注意: CommandLineTools 删除属于高风险操作, cleanup_xcode_clt 内部会强制确认
cleanup_xcode_all() {
    echo -e "\n${YELLOW}正在清理 Xcode 缓存与组件...${NC}"
    cleanup_xcode_derived_data
    local d
    for d in \
        "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
        "$HOME/Library/Developer/Xcode/watchOS DeviceSupport" \
        "$HOME/Library/Developer/Xcode/tvOS DeviceSupport" \
        "$HOME/Library/Developer/CoreSimulator/Caches" \
        "$HOME/Library/Caches/com.apple.dt.Xcode"; do
        [[ -d "$d" ]] || continue
        clear_dir_contents "$d" "${d/#$HOME/~}"
    done
    cleanup_xcode_clt
}

# 统计指定 Electron 应用列表的运行时缓存大小 (KB)
scan_electron_apps_kb() {
    local kb=0 app sub d k
    for app in "$@"; do
        d="$HOME/Library/Application Support/$app"
        [[ -d "$d" ]] || continue
        for sub in "${ELECTRON_SAFE_SUBS[@]}"; do
            [[ -d "$d/$sub" ]] || continue
            k=$(du -sk "$d/$sub" 2>/dev/null | cut -f1)
            [[ "$k" =~ ^[0-9]+$ ]] && kb=$((kb + k))
        done
    done
    echo "$kb"
}

# 组合项扫描: 在子 shell 中复用单项 scan_item 的预估逻辑, 避免重复实现
scan_component_size() {    local f="$1"
    (
        scan_item "" "$f" ""
        printf '%s\n' "${SCAN_RESULT_SIZES[0]}"
    )
}

# 汇总多个大小文本 (1.2GB/300MB/4KB), 忽略"未估算/执行时扫描"
sum_scan_sizes() {
    printf '%s\n' "$@" | awk '
        {
            if ($0 ~ /^[0-9]+(\.[0-9]+)?(KB|MB|GB)$/) {
                unit = substr($0, length($0) - 1)
                num = substr($0, 1, length($0) - 2) + 0
                if (unit == "GB") kb += num * 1048576
                else if (unit == "MB") kb += num * 1024
                else kb += num
            }
        }
        END {
            if (kb >= 1048576) printf "%.1fGB", kb / 1048576
            else if (kb >= 1024) printf "%.1fMB", kb / 1024
            else printf "%dKB", kb
        }'
}

composite_scan_size() {
    local comp sizes=()
    for comp in "$@"; do
        sizes+=("$(scan_component_size "$comp")")
    done
    sum_scan_sizes "${sizes[@]}"
}

# =======================================================

# 12. macOS: 清理所有 / Linux: (同 10)
cleanup_all_macos() {
    echo -e "\n${YELLOW}正在执行全部 macOS 清理...${NC}"
    if confirm_action "执行所有清理项目"; then
        cleanup_ide_caches
        cleanup_all_app_caches_macos
        cleanup_logs_diagnostics_audit
        cleanup_sys_tmp_update
        cleanup_var_folders_tmp
        cleanup_dev_caches_all
        cleanup_build_tool_caches
        cleanup_ai_clients
        cleanup_office_apps
        cleanup_im_apps
        cleanup_orphans_backups
        cleanup_browsers
        cleanup_downloads_history
        cleanup_empty_dirs
        cleanup_wallpaper_cache
        cleanup_garageband_logic
        cleanup_xcode_all
        echo -e "${GREEN}✓ 全部 macOS 清理完成${NC}"
    else
        echo -e "${YELLOW}已取消全部清理${NC}"
    fi
}

# ncdu 子菜单 - 选择扫描用户目录还是根目录
launch_ncdu_menu() {
    echo -e "\n${YELLOW}启动磁盘分析工具 (ncdu)${NC}"
    echo "请选择要扫描的目录:"
    echo "  1. 分析主目录 ($HOME) - 不需要管理员权限"
    echo "  2. 分析根目录 (/) - 需要管理员权限"
    echo "  0. 取消"
    
    read -p "请选择 (0-2): " ncdu_choice
    
    case "$ncdu_choice" in
        1)
            launch_ncdu_home
            ;;
        2)
            launch_ncdu_root
            ;;
        0)
            echo -e "${YELLOW}已取消${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# 启动 ncdu 分析主目录
launch_ncdu_home() {
    echo -e "\n${YELLOW}正在启动磁盘使用情况分析工具...${NC}"
    if command -v ncdu &> /dev/null; then
        if [[ -t 1 ]]; then
            echo -e "${YELLOW}启动 ncdu 分析主目录...${NC}"
            echo -e "${YELLOW}提示: 按 ? 键查看帮助，q 键退出${NC}"
            ncdu "$HOME"
        else
            echo -e "${RED}错误: 无法在当前环境中启动 ncdu，需要终端支持${NC}"
        fi
    else
        echo -e "${YELLOW}ncdu 未安装${NC}"
        echo "安装命令:"
        if [[ "$OS_TYPE" == "macOS" ]]; then
            echo "  brew install ncdu"
        else
            echo "  sudo apt install ncdu  (Ubuntu/Debian)"
            echo "  sudo dnf install ncdu  (CentOS/RHEL/Fedora)"
            echo "  sudo pacman -S ncdu    (Arch Linux)"
        fi
    fi
}

# 14/9. 启动 ncdu 分析根目录
launch_ncdu_root() {
    echo -e "\n${YELLOW}正在启动系统级磁盘使用情况分析...${NC}"
    if command -v ncdu &> /dev/null; then
        if [[ -t 1 ]]; then
            echo -e "${YELLOW}启动 ncdu 分析根目录 (需要管理员权限)...${NC}"
            echo -e "${YELLOW}提示: 按 ? 键查看帮助，q 键退出${NC}"
            ensure_sudo "ncdu /" || return 1
            sudo ncdu /
        else
            echo -e "${RED}错误: 无法在当前环境中启动 ncdu，需要终端支持${NC}"
        fi
    else
        echo -e "${YELLOW}ncdu 未安装${NC}"
        echo "安装命令:"
        if [[ "$OS_TYPE" == "macOS" ]]; then
            echo "  brew install ncdu"
        else
            echo "  sudo apt install ncdu  (Ubuntu/Debian)"
            echo "  sudo dnf install ncdu  (CentOS/RHEL/Fedora)"
            echo "  sudo pacman -S ncdu    (Arch Linux)"
        fi
    fi
}

# 0. 退出
exit_script() {
    echo -e "\n${GREEN}感谢使用磁盘清理工具！${NC}"
    echo -e "${GREEN}安全提示: 保持至少 10% 的磁盘空间可用有助于系统性能。${NC}"
    exit 0
}

# 扫描功能 - 获取所有可清理项目的大小
# ============================================

# 使用普通数组存储扫描结果（兼容 macOS 旧版 bash）
# 索引对应菜单编号，值对应大小
declare -a SCAN_RESULT_NAMES
declare -a SCAN_RESULT_SIZES

# 获取数组索引（将菜单编号映射到数组索引）
get_scan_index() {
    local num="$1"
    echo "$((num))"
}

# 扫描单个项目
scan_item() {
    local num="$1"
    local func="$2"
    local name="$3"
    local idx=$(get_scan_index "$num")
    
    SCAN_RESULT_NAMES[$idx]="$name"
    
    case "$func" in

        "cleanup_all_app_caches_macos")
            # ~/Library/Caches: 清理函数会删除所有内容，报告完整大小
            local size1=$(get_dir_size "$HOME/Library/Caches")
            # ~/Library/Containers: 只删 Cache.db 和 Caches 子目录，只统计这些的大小
            local containers_cache_kb=0
            if [[ -d "$HOME/Library/Containers" ]]; then
                while IFS= read -r -d '' f; do
                    local skb
                    skb=$(du -sk "$f" 2>/dev/null | cut -f1)
                    [[ "$skb" =~ ^[0-9]+$ ]] && containers_cache_kb=$((containers_cache_kb + skb))
                done < <(find "$HOME/Library/Containers" \( -name "Cache.db" -o -name "Caches" -type d \) -print0 2>/dev/null)
            fi
            local size2
            if [[ $containers_cache_kb -gt 0 ]]; then
                size2=$(awk -v k="$containers_cache_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                size2="0KB"
            fi
            # ~/Library/Mail: 只清理 V 目录下的 Envelope Index 等缓存
            local mail_cache_kb=0
            if [[ -d "$HOME/Library/Mail" ]]; then
                while IFS= read -r -d '' f; do
                    local skb
                    skb=$(du -sk "$f" 2>/dev/null | cut -f1)
                    [[ "$skb" =~ ^[0-9]+$ ]] && mail_cache_kb=$((mail_cache_kb + skb))
                done < <(find "$HOME/Library/Mail" \( -name "Envelope Index" -o -name "Envelope Index-shm" -o -name "Envelope Index-wal" \) -print0 2>/dev/null)
            fi
            local size3
            if [[ $mail_cache_kb -gt 0 ]]; then
                size3=$(awk -v k="$mail_cache_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                size3="0KB"
            fi
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2 $size3" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_all_logs_states_macos")
            local size1=$(get_dir_size "/Library/Logs/DiagnosticReports")
            local size2=$(get_dir_size "$HOME/Library/Logs")
            local size3=$(get_dir_size "$HOME/Library/Autosave Information")
            local size4=$(get_dir_size "$HOME/Library/Saved Application State")
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2 $size3 $size4" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_sys_tmp_update")
            local size1=$(get_dir_size "/tmp")
            local size2=$(get_dir_size "/Library/Caches/com.apple.SoftwareUpdate")
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_dev_caches")
            local brew_size="0KB"
            if command -v brew &> /dev/null; then
                local brew_cache
                brew_cache=$(brew --cache 2>/dev/null)
                [[ -n "$brew_cache" && -e "$brew_cache" ]] && brew_size=$(get_dir_size "$brew_cache")
            fi
            
            local npm_size="0KB"
            if command -v npm &> /dev/null; then
                local npm_cache=$(npm config get cache 2>/dev/null)
                [[ -n "$npm_cache" && -d "$npm_cache" ]] && npm_size=$(get_dir_size "$npm_cache")
            fi
            
            local docker_size="0KB"
            if command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
                docker_size=$(docker system df 2>/dev/null | awk 'NR>1 {print $4}' | awk '{val=$1; if(match(val,/[0-9]+(\.[0-9]+)?(KB|MB|GB|B)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; else if(u=="B") sum+=n/1024/1024}} END{if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            fi
            
            SCAN_RESULT_SIZES[$idx]=$(echo "$brew_size $npm_size $docker_size" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_dot_cache_dev")
            local total_kb=0
            local dot_subs=(uv codex-runtimes puppeteer chrome-devtools-mcp node opencode vscode-ripgrep netscan)
            for sub in "${dot_subs[@]}"; do
                local sd="$HOME/.cache/$sub"
                [[ -d "$sd" ]] || continue
                local skb
                skb=$(du -sk "$sd" 2>/dev/null | cut -f1)
                [[ "$skb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + skb))
            done
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_chrome_code_sign_clones")
            local chrome_clone_dir
            chrome_clone_dir="$(chrome_code_sign_clone_dir || true)"
            if [[ -n "$chrome_clone_dir" && -d "$chrome_clone_dir" ]]; then
                SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$chrome_clone_dir")
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_gradle_cache")
            local total_kb=0
            for gsub in caches wrapper/dists; do
                local gd="$HOME/.gradle/$gsub"
                [[ -d "$gd" ]] || continue
                local gkb
                gkb=$(du -sk "$gd" 2>/dev/null | cut -f1)
                [[ "$gkb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + gkb))
            done
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_cargo_cache")
            local total_kb=0
            for csub in cache src; do
                local cd="$HOME/.cargo/registry/$csub"
                [[ -d "$cd" ]] || continue
                local ckb
                ckb=$(du -sk "$cd" 2>/dev/null | cut -f1)
                [[ "$ckb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + ckb))
            done
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_go_cache")
            local total_kb=0
            local go_root="${GOPATH:-$HOME/go}"
            for gsub in pkg/mod pkg/sumdb bin; do
                local gd="$go_root/$gsub"
                [[ -d "$gd" ]] || continue
                local gkb
                gkb=$(du -sk "$gd" 2>/dev/null | cut -f1)
                [[ "$gkb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + gkb))
            done
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_vscode_extension_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Application Support/Code/CachedExtensionVSIXs")
            ;;
        "cleanup_maven_repo")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.m2/repository")
            ;;
        "cleanup_xcode_derived_data")
            local size1=$(get_dir_size "$HOME/Library/Developer/Xcode/DerivedData")
            local size2=$(get_dir_size "$HOME/Library/Developer/Xcode/Archives")
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_downloads_history")
            local size1=$(get_dir_size "$HOME/Downloads")
            local size2="0KB"
            if [[ -f "$HOME/Library/Safari/Downloads.plist" ]]; then size2=$(get_dir_size "$HOME/Library/Safari/Downloads.plist"); fi
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_orphan_appdata")
            SCAN_RESULT_SIZES[$idx]="执行时扫描"
            ;;
        "cleanup_audit_logs")
            SCAN_RESULT_SIZES[$idx]=$(sudo du -sh /private/var/audit 2>/dev/null | awk '{print $1}')
            ;;
        "cleanup_system_diagnostics")
            SCAN_RESULT_SIZES[$idx]=$(sudo du -sh /private/var/db/diagnostics 2>/dev/null | awk '{print $1}')
            ;;
        "cleanup_expired_backups")
            local total_kb=0
            shopt -s nullglob
            for bd in "$HOME"/open-webui.backup.*; do
                [[ -d "$bd" ]] || continue
                local bkb
                bkb=$(du -sk "$bd" 2>/dev/null | cut -f1)
                [[ "$bkb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + bkb))
            done
            shopt -u nullglob
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_qoder_cache")
            local qkb=0
            for qd in "$HOME/.qoder/cache" "$HOME/.qoder/tmp"; do
                [[ -d "$qd" ]] || continue
                local q
                q=$(du -sk "$qd" 2>/dev/null | cut -f1)
                [[ "$q" =~ ^[0-9]+$ ]] && qkb=$((qkb + q))
            done
            local qs
            qs=$(find "$HOME/.qoder/projects" -type f -name '*.jsonl' -mtime +30 2>/dev/null | xargs -I{} du -k "{}" 2>/dev/null | awk '{sum+=$1} END {print int(sum)}')
            [[ "$qs" =~ ^[0-9]+$ ]] && qkb=$((qkb + qs))
            if [[ $qkb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$qkb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_hermes_cache")
            local total_kb=0
            for hd in "$HOME/.hermes/cache" "$HOME/.hermes/hermes-agent/.git"; do
                [[ -e "$hd" ]] || continue
                local hkb
                hkb=$(du -sk "$hd" 2>/dev/null | cut -f1)
                [[ "$hkb" =~ ^[0-9]+$ ]] && total_kb=$((total_kb + hkb))
            done
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_var_folders_tmp")
            SCAN_RESULT_SIZES[$idx]=$(sudo du -sh /private/var/folders 2>/dev/null | awk '{print $1}')
            ;;
        "cleanup_eclipse_p2")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.p2")
            ;;
        "cleanup_codex_sessions")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.codex/sessions")
            ;;
        "cleanup_uv_tool_data")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.local/share/uv/tools")
            ;;
        "cleanup_agent_session_caches")
            local akb=0
            local ak
            ak=$(find "$HOME/.local/state" -type f -name '*.log' -size +100M -exec du -k {} + 2>/dev/null | awk '{sum+=$1} END {print int(sum)}')
            [[ "$ak" =~ ^[0-9]+$ ]] && akb=$((akb + ak))
            if [[ -d "$HOME/.local/share/opencode/snapshot" ]]; then
                ak=$(du -sk "$HOME/.local/share/opencode/snapshot" 2>/dev/null | cut -f1)
                [[ "$ak" =~ ^[0-9]+$ ]] && akb=$((akb + ak))
            fi
            if [[ $akb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$akb" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_garageband_logic")
            local size1=$(get_dir_size "/Library/Application Support/GarageBand")
            local size2=$(get_dir_size "/Library/Application Support/Logic")
            SCAN_RESULT_SIZES[$idx]=$(echo "$size1 $size2" | awk '{sum=0; for(i=1;i<=NF;i++){val=$i; while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)){m=substr(val,RSTART,RLENGTH); u=substr(m,match(m,/[A-Z]/)); n=substr(m,1,match(m,/[A-Z]/)-1)+0; if(u=="GB") sum+=n*1024; else if(u=="MB") sum+=n; else if(u=="KB") sum+=n/1024; val=substr(val,RSTART+RLENGTH)}} if(sum>=1024) printf "%.1fGB", sum/1024; else if(sum>0) printf "%.1fMB", sum; else print "0KB"}')
            ;;
        "cleanup_xcode_clt")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "/Library/Developer/CommandLineTools")
            ;;
        "cleanup_wallpaper_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Application Support/com.apple.wallpaper")
            ;;
        "cleanup_user_cache_menu")
            if [[ "$OS_TYPE" == "macOS" ]]; then
                SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Caches")
            else
                SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.cache")
            fi
            ;;
        "cleanup_temp_menu")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "/tmp")
            ;;
        "cleanup_downloads")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Downloads")
            ;;
        "cleanup_safari_history")
            if [[ -f "$HOME/Library/Safari/Downloads.plist" ]]; then
                SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Safari/Downloads.plist")
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_diagnostic_reports")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "/Library/Logs/DiagnosticReports")
            ;;
        "cleanup_software_update_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "/Library/Caches/com.apple.SoftwareUpdate")
            ;;
        "cleanup_homebrew")
            if command -v brew &> /dev/null; then
                local brew_cache
                brew_cache=$(brew --cache 2>/dev/null)
                if [[ -n "$brew_cache" && -e "$brew_cache" ]]; then
                    SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$brew_cache")
                else
                    SCAN_RESULT_SIZES[$idx]="0KB"
                fi
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_npm_docker")
            local npm_size="0KB"
            local docker_size="0KB"
            if command -v npm &> /dev/null; then
                local npm_cache
                npm_cache=$(npm config get cache 2>/dev/null)
                [[ -n "$npm_cache" && -d "$npm_cache" ]] && npm_size=$(get_dir_size "$npm_cache")
            fi
            if command -v docker &> /dev/null; then
                if docker info >/dev/null 2>&1; then
                    docker_size=$(docker system df 2>/dev/null | awk 'NR>1 {print $4}' | awk '{
                        val=$1;
                        if(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB|B)/)) {
                            match_str = substr(val, RSTART, RLENGTH);
                            unit = substr(match_str, match(match_str, /[A-Z]/));
                            num = substr(match_str, 1, match(match_str, /[A-Z]/)-1) + 0;
                            if(unit == "GB") sum += num * 1024;
                            else if(unit == "MB") sum += num;
                            else if(unit == "KB") sum += num / 1024;
                            else if(unit == "B") sum += num / 1024 / 1024;
                        }
                    } END {
                        if (sum >= 1024) printf "%.1fGB", sum/1024;
                        else if (sum > 0) printf "%.1fMB", sum;
                        else print "0KB"
                    }')
                fi
            fi
            SCAN_RESULT_SIZES[$idx]=$(echo "$npm_size $docker_size" | awk '{
                sum = 0;
                for(i=1; i<=NF; i++) {
                    val = $i;
                    while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)) {
                        match_str = substr(val, RSTART, RLENGTH);
                        num = substr(match_str, 1, match(match_str, /[A-Z]/)-1) + 0;
                        unit = substr(match_str, match(match_str, /[A-Z]/));
                        if(unit == "GB") sum += num * 1024;
                        else if(unit == "MB") sum += num;
                        else if(unit == "KB") sum += num / 1024;
                        val = substr(val, RSTART + RLENGTH);
                    }
                }
                if (sum >= 1024) printf "%.1fGB", sum/1024;
                else if (sum > 0) printf "%.1fMB", sum;
                else printf "0KB";
            }')
            ;;
        "cleanup_logs_autosave")
            local total_size=0
            local logs_size="0KB"
            local autosave_size="0KB"
            local saved_state_size="0KB"
            
            [[ -d "$HOME/Library/Logs" ]] && logs_size=$(get_dir_size "$HOME/Library/Logs")
            [[ -d "$HOME/Library/Autosave Information" ]] && autosave_size=$(get_dir_size "$HOME/Library/Autosave Information")
            [[ -d "$HOME/Library/Saved Application State" ]] && saved_state_size=$(get_dir_size "$HOME/Library/Saved Application State")
            
            # 取第一个非 0KB/N/A 的值
            if [[ "$logs_size" != "0KB" && "$logs_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$logs_size"
            elif [[ "$autosave_size" != "0KB" && "$autosave_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$autosave_size"
            elif [[ "$saved_state_size" != "0KB" && "$saved_state_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$saved_state_size"
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_containers_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Containers")
            ;;
        "cleanup_mail_quicklook")
            local mail_size="0KB"
            local ql_size="0KB"
            [[ -d "$HOME/Library/Mail" ]] && mail_size=$(get_dir_size "$HOME/Library/Mail")
            [[ -d "$HOME/Library/Caches/com.apple.quicklook" ]] && ql_size=$(get_dir_size "$HOME/Library/Caches/com.apple.quicklook")
            
            if [[ "$mail_size" != "0KB" && "$mail_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$mail_size"
            elif [[ "$ql_size" != "0KB" && "$ql_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$ql_size"
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_linux_system_cache"|"cleanup_linux_specific"|"cleanup_package_manager_cache")
            local var_size=$(get_dir_size "/var/cache")
            local cache_size=$(get_dir_size "$HOME/.cache")
            if [[ "$var_size" != "0KB" && "$var_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$var_size"
            elif [[ "$cache_size" != "0KB" && "$cache_size" != "N/A" ]]; then
                SCAN_RESULT_SIZES[$idx]="$cache_size"
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "launch_ncdu_menu")
            SCAN_RESULT_SIZES[$idx]="工具"
            ;;
        "cleanup_all_macos"|"cleanup_all_linux")
            SCAN_RESULT_SIZES[$idx]="批量"
            ;;
        "cleanup_app_data_cache")
            local total_kb=0
            shopt -s nullglob
            local sub_patterns=("logs" "Logs" "*/logs" "*/Logs" "vm/images" "*/vm/images" "*/ai-agent/vm/images" "ModularData/ai-agent/vm/images")
            local dirs_to_scan=()
            for app_dir in "$HOME/Library/Application Support/"*; do
                if [[ -d "$app_dir" ]]; then
                    for pattern in "${sub_patterns[@]}"; do
                        for target_dir in "$app_dir"/$pattern; do
                            if [[ -d "$target_dir" ]]; then
                                local is_dup=0
                                for existing in "${dirs_to_scan[@]}"; do
                                    if [[ "$existing" == "$target_dir" ]]; then
                                        is_dup=1
                                        break
                                    fi
                                done
                                if [[ $is_dup -eq 0 ]]; then
                                    dirs_to_scan+=("$target_dir")
                                fi
                            fi
                        done
                    done
                fi
            done
            shopt -u nullglob
            if [[ ${#dirs_to_scan[@]} -gt 0 ]]; then
                for d in "${dirs_to_scan[@]}"; do
                    local size_kb
                    size_kb=$(du -sk "$d" 2>/dev/null | cut -f1)
                    if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                        total_kb=$((total_kb + size_kb))
                    fi
                done
            fi
            if [[ $total_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$total_kb" 'BEGIN {
                    if (k >= 1048576) printf "%.1fGB", k/1048576;
                    else if (k >= 1024) printf "%.1fMB", k/1024;
                    else printf "%dKB", k;
                }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_doubao_cache")
            local db_size=0
            local db_root="$HOME/Library/Application Support/Doubao"
            if [[ -d "$db_root" ]]; then
                for dsub in gecko_cache sdk_storage/log hot_fix sandbox_runtime installed_versions; do
                    local ddir="$db_root/$dsub"
                    [[ -d "$ddir" ]] || continue
                    local dkb
                    dkb=$(du -sk "$ddir" 2>/dev/null | cut -f1)
                    [[ "$dkb" =~ ^[0-9]+$ ]] && db_size=$((db_size + dkb))
                done
            fi
            if [[ $db_size -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$db_size" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_chrome_appdata_cache")
            local ch_size=0
            local ch_root="$HOME/Library/Application Support/Google/Chrome"
            if [[ -d "$ch_root" ]]; then
                for csub in component_crx_cache screen_ai optimization_guide_model_store WasmTtsEngine; do
                    local cdir="$ch_root/$csub"
                    [[ -d "$cdir" ]] || continue
                    local ckb
                    ckb=$(du -sk "$cdir" 2>/dev/null | cut -f1)
                    [[ "$ckb" =~ ^[0-9]+$ ]] && ch_size=$((ch_size + ckb))
                done
                local swd="$ch_root/Default/Service Worker/CacheStorage"
                if [[ -d "$swd" ]]; then
                    local swkb
                    swkb=$(du -sk "$swd" 2>/dev/null | cut -f1)
                    [[ "$swkb" =~ ^[0-9]+$ ]] && ch_size=$((ch_size + swkb))
                fi
            fi
            if [[ $ch_size -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$ch_size" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_wechat_cache")
            local wx_size=0
            local wx_root="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
            if [[ -d "$wx_root" ]]; then
                local swx
                swx=$(find "$wx_root/Library/Application Support/com.tencent.xinWeChat" -type d -name "Stickers" 2>/dev/null | head -1)
                [[ -n "$swx" && -d "$swx" ]] && wx_size=$((wx_size + $(du -sk "$swx" 2>/dev/null | cut -f1)))
                local rwx
                rwx=$(find "$wx_root/Library/Application Support/com.tencent.xinWeChat" -type d -name "MMResourceMgr" 2>/dev/null | head -1)
                [[ -n "$rwx" && -d "$rwx" ]] && wx_size=$((wx_size + $(du -sk "$rwx" 2>/dev/null | cut -f1)))
                [[ -d "$wx_root/Library/Caches" ]] && wx_size=$((wx_size + $(du -sk "$wx_root/Library/Caches" 2>/dev/null | cut -f1)))
            fi
            if [[ $wx_size -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(awk -v k="$wx_size" 'BEGIN { if (k>=1048576) printf "%.1fGB", k/1048576; else if (k>=1024) printf "%.1fMB", k/1024; else printf "%dKB", k }')
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_trae_agent_sandbox")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/Library/Application Support/TRAE SOLO CN/ModularData/ai-agent/vm/tools")
            ;;
        "cleanup_electron_app_caches")
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$(scan_electron_apps_kb "${IDE_ELECTRON_APPS[@]}")")
            ;;
        "cleanup_ai_app_caches")
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$(scan_electron_apps_kb "${AI_ELECTRON_APPS[@]}")")
            ;;
        "cleanup_jetbrains_caches")
            local jb_kb=0 jb_root jb_prod jb_sub jb_d jb_k jb_prods
            for jb_root in "$HOME/Library/Caches/JetBrains" "$HOME/Library/Caches/Google"; do
                [[ -d "$jb_root" ]] || continue
                shopt -s nullglob
                if [[ "$jb_root" == */JetBrains ]]; then
                    jb_prods=("$jb_root"/*/)
                else
                    jb_prods=("$jb_root"/AndroidStudio*/)
                fi
                shopt -u nullglob
                for jb_prod in "${jb_prods[@]}"; do
                    for jb_sub in caches index log tmp compile-server; do
                        jb_d="${jb_prod%/}/$jb_sub"
                        [[ -d "$jb_d" ]] || continue
                        jb_k=$(du -sk "$jb_d" 2>/dev/null | cut -f1)
                        [[ "$jb_k" =~ ^[0-9]+$ ]] && jb_kb=$((jb_kb + jb_k))
                    done
                done
            done
            if [[ -d "$HOME/Library/Logs/JetBrains" ]]; then
                jb_k=$(du -sk "$HOME/Library/Logs/JetBrains" 2>/dev/null | cut -f1)
                [[ "$jb_k" =~ ^[0-9]+$ ]] && jb_kb=$((jb_kb + jb_k))
            fi
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$jb_kb")
            ;;
        "cleanup_sublime_caches")
            local sb_kb=0 sb_d sb_k
            shopt -s nullglob
            for sb_d in "$HOME/Library/Caches/com.sublimetext."*; do
                [[ -d "$sb_d" ]] || continue
                sb_k=$(du -sk "$sb_d" 2>/dev/null | cut -f1)
                [[ "$sb_k" =~ ^[0-9]+$ ]] && sb_kb=$((sb_kb + sb_k))
            done
            shopt -u nullglob
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$sb_kb")
            ;;
        "cleanup_codex_cli_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.codex/cache")
            ;;
        "cleanup_claude_cache")
            local cl_kb=0 cl_d cl_k
            for cl_d in "$HOME/.claude/cache" "$HOME/.claude/shell-snapshots"; do
                [[ -d "$cl_d" ]] || continue
                cl_k=$(du -sk "$cl_d" 2>/dev/null | cut -f1)
                [[ "$cl_k" =~ ^[0-9]+$ ]] && cl_kb=$((cl_kb + cl_k))
            done
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$cl_kb")
            ;;
        "cleanup_gemini_cache")
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.gemini/tmp")
            ;;
        "cleanup_trae_cn_cache")
            local tc_kb=0 tc_d tc_k
            for tc_d in "$HOME/.trae-cn/hub_event_cache" "$HOME/.trae-cn/trae-browser-screenshots"; do
                [[ -d "$tc_d" ]] || continue
                tc_k=$(du -sk "$tc_d" 2>/dev/null | cut -f1)
                [[ "$tc_k" =~ ^[0-9]+$ ]] && tc_kb=$((tc_kb + tc_k))
            done
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$tc_kb")
            ;;
        "cleanup_im_apps")
            local im_sizes=() im_kb=0 im_entry im_bid im_cache im_k
            im_sizes+=("$(composite_scan_size cleanup_wechat_cache)")
            for im_entry in "${IM_CONTAINER_APPS[@]}"; do
                im_bid="${im_entry%%::*}"
                for im_cache in "$HOME/Library/Containers/$im_bid/Data/Library/Caches" "$HOME/Library/Caches/$im_bid"; do
                    [[ -d "$im_cache" ]] || continue
                    im_k=$(du -sk "$im_cache" 2>/dev/null | cut -f1)
                    [[ "$im_k" =~ ^[0-9]+$ ]] && im_kb=$((im_kb + im_k))
                done
            done
            im_sizes+=("$(format_size_kb "$im_kb")")
            im_sizes+=("$(format_size_kb "$(scan_electron_apps_kb "${IM_ELECTRON_APPS[@]}")")")
            SCAN_RESULT_SIZES[$idx]=$(sum_scan_sizes "${im_sizes[@]}")
            ;;
        "cleanup_office_apps")
            local of_kb=0 of_root of_sub of_d of_k of_upd of_rule
            for of_root in "${OFFICE_ELECTRON_ROOTS[@]}"; do
                [[ -d "$of_root" ]] || continue
                for of_sub in "${OFFICE_ELECTRON_SUBS[@]}"; do
                    of_d="$of_root/$of_sub"
                    [[ -d "$of_d" ]] || continue
                    of_k=$(du -sk "$of_d" 2>/dev/null | cut -f1)
                    [[ "$of_k" =~ ^[0-9]+$ ]] && of_kb=$((of_kb + of_k))
                done
                while IFS= read -r of_upd; do
                    [[ -n "$of_upd" && -d "$of_upd" ]] || continue
                    of_k=$(du -sk "$of_upd" 2>/dev/null | cut -f1)
                    [[ "$of_k" =~ ^[0-9]+$ ]] && of_kb=$((of_kb + of_k))
                done < <(find "$of_root" -maxdepth 2 -type d -name "auto-updater" 2>/dev/null)
            done
            for of_rule in "${OFFICE_CACHE_RULES[@]}"; do
                parse_office_rule "$of_rule"
                [[ -d "$OFF_PATH" ]] || continue
                of_k=$(du -sk "$OFF_PATH" 2>/dev/null | cut -f1)
                [[ "$of_k" =~ ^[0-9]+$ ]] && of_kb=$((of_kb + of_k))
            done
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$of_kb")
            ;;
        "cleanup_browsers")
            local br_kb=0 br_root br_sizes=()
            for br_root in \
                "$HOME/Library/Application Support/Google/Chrome" \
                "$HOME/Library/Application Support/Microsoft Edge" \
                "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" \
                "$HOME/Library/Application Support/Arc/User Data" \
                "$HOME/Library/Application Support/Vivaldi" \
                "$HOME/Library/Application Support/Chromium" \
                "$HOME/Library/Application Support/com.operasoftware.Opera"; do
                br_kb=$((br_kb + $(chromium_browser_cache_kb "$br_root")))
            done
            br_kb=$((br_kb + $(firefox_cache_kb) + $(safari_cache_kb)))
            br_sizes=("$(format_size_kb "$br_kb")" "$(composite_scan_size cleanup_chrome_code_sign_clones)")
            SCAN_RESULT_SIZES[$idx]=$(sum_scan_sizes "${br_sizes[@]}")
            ;;
        "cleanup_ide_caches")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_electron_app_caches cleanup_vscode_extension_cache cleanup_jetbrains_caches cleanup_sublime_caches)
            ;;
        "cleanup_logs_diagnostics_audit")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_all_logs_states_macos cleanup_system_diagnostics cleanup_audit_logs cleanup_system_var_logs)
            ;;
        "cleanup_temp_all")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_sys_tmp_update cleanup_var_folders_tmp cleanup_opt_tmp)
            ;;
        "cleanup_dev_caches_all")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_dev_caches cleanup_dot_cache_dev cleanup_npx_cache)
            ;;
        "cleanup_build_tool_caches")
            local bt_sizes=() bt_kb=0 bt_d bt_k
            bt_sizes+=("$(composite_scan_size cleanup_gradle_cache cleanup_cargo_cache cleanup_go_cache)")
            for bt_d in "$HOME/.nuget/packages" "$HOME/Library/Caches/composer" "$HOME/.composer/cache" "$HOME/Library/Caches/bazel" "$HOME/.cache/bazel" "$HOME/Library/Caches/Yarn" "$HOME/.cache/yarn"; do
                [[ -d "$bt_d" ]] || continue
                bt_k=$(du -sk "$bt_d" 2>/dev/null | cut -f1)
                [[ "$bt_k" =~ ^[0-9]+$ ]] && bt_kb=$((bt_kb + bt_k))
            done
            bt_sizes+=("$(format_size_kb "$bt_kb")")
            SCAN_RESULT_SIZES[$idx]=$(sum_scan_sizes "${bt_sizes[@]}")
            ;;
        "cleanup_qoder_all")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_qoder_cache cleanup_qoder_cli_temp)
            ;;
        "cleanup_agent_data")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_codex_sessions cleanup_agent_session_caches)
            ;;
        "cleanup_ai_clients")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_qoder_all cleanup_agent_session_caches cleanup_codex_cli_cache cleanup_claude_cache cleanup_gemini_cache cleanup_trae_cn_cache cleanup_hermes_cache cleanup_ai_app_caches cleanup_doubao_cache)
            ;;
        "cleanup_xcode_all")
            local xc_kb=0 xc_d xc_k
            for xc_d in \
                "$HOME/Library/Developer/Xcode/DerivedData" \
                "$HOME/Library/Developer/Xcode/Archives" \
                "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
                "$HOME/Library/Developer/Xcode/watchOS DeviceSupport" \
                "$HOME/Library/Developer/Xcode/tvOS DeviceSupport" \
                "$HOME/Library/Developer/CoreSimulator/Caches" \
                "$HOME/Library/Caches/com.apple.dt.Xcode"; do
                [[ -d "$xc_d" ]] || continue
                xc_k=$(du -sk "$xc_d" 2>/dev/null | cut -f1)
                [[ "$xc_k" =~ ^[0-9]+$ ]] && xc_kb=$((xc_kb + xc_k))
            done
            if [[ -d /Library/Developer/CommandLineTools ]]; then
                xc_k=$(du -sk /Library/Developer/CommandLineTools 2>/dev/null | cut -f1)
                [[ "$xc_k" =~ ^[0-9]+$ ]] && xc_kb=$((xc_kb + xc_k))
            fi
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$xc_kb")
            ;;
        "cleanup_orphans_backups")
            SCAN_RESULT_SIZES[$idx]=$(composite_scan_size cleanup_expired_backups cleanup_orphan_appdata cleanup_app_residue)
            ;;
        "cleanup_app_residue")
            local ar_kb=0 ar_installed ar_rule
            ar_installed=$(installed_app_bundle_ids)
            for ar_rule in "${APP_RESIDUE_RULES[@]}"; do
                parse_residue_rule "$ar_rule"
                ar_kb=$((ar_kb + $(app_residue_rule_kb "$RES_PATH_RE" "$RES_ID_RE" "$ar_installed")))
            done
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$ar_kb")
            ;;
        "cleanup_npx_cache")
            SCAN_RESULT_SIZES[$idx]=$(custom_rule_size_by_name "npx 缓存")
            ;;
        "cleanup_qoder_cli_temp")
            local qoder_kb=0 qoder_t k
            while IFS= read -r qoder_t; do
                [[ -n "$qoder_t" ]] || continue
                k=$(du -sk "$qoder_t" 2>/dev/null | cut -f1)
                [[ "$k" =~ ^[0-9]+$ ]] && qoder_kb=$((qoder_kb + k))
            done < <(qoder_cli_old_task_dirs)
            if [[ $qoder_kb -gt 0 ]]; then
                SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$qoder_kb")
            else
                SCAN_RESULT_SIZES[$idx]="0KB"
            fi
            ;;
        "cleanup_system_var_logs")
            local varlog_kb=0 vf vk
            for vf in /private/var/log/install.log /private/var/log/system.log /private/var/log/daily.out; do
                [[ -f "$vf" ]] || continue
                vk=$(du -k "$vf" 2>/dev/null | cut -f1)
                [[ "$vk" =~ ^[0-9]+$ ]] && varlog_kb=$((varlog_kb + vk))
            done
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$varlog_kb")
            ;;
        "cleanup_opt_tmp")
            SCAN_RESULT_SIZES[$idx]=$(custom_rule_size_by_name "/opt/tmp 过期部署包")
            ;;
        "cleanup_pnpm_store_full")
            SCAN_RESULT_SIZES[$idx]=$(custom_rule_size_by_name "pnpm store")
            ;;
        "cleanup_custom_rules")
            SCAN_RESULT_SIZES[$idx]=$(format_size_kb "$(custom_rules_total_kb)")
            ;;
        "scan_large_files"|"detect_duplicate_files"|"cleanup_empty_dirs"|"cleanup_git_repos")
            SCAN_RESULT_SIZES[$idx]="执行时扫描"
            ;;
        *)
            SCAN_RESULT_SIZES[$idx]="未估算"
            ;;
    esac
}

# 扫描所有项目
scan_all_items() {
    echo -e "${YELLOW}正在扫描可清理项目...${NC}"
    SCAN_RESULT_NAMES=()
    SCAN_RESULT_SIZES=()
    
    # 清理过期缓存
    clean_expired_cache
    
    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        [[ "$num" == "0" ]] && continue  # 跳过退出选项
        
        echo -n "."
        scan_item "$num" "$func" "$name"
    done
    echo ""
    echo -e "${GREEN}扫描完成!${NC}\n"
}

# ============================================
# 并行扫描功能 - 提升扫描速度
# ============================================

# 并行扫描项目（使用后台进程）
scan_items_parallel() {
    local items=("$@")
    local pids=()
    local tmp_dir="/tmp/disk_cleanup_scan_$$"
    
    mkdir -p "$tmp_dir"
    
    # 启动并行扫描
    for item in "${items[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        [[ "$num" == "0" ]] && continue
        
        (
            local idx=$(get_scan_index "$num")
            local size="0KB"
            
            # 根据函数获取大小
            case "$func" in
                "cleanup_user_cache_menu")
                    if [[ "$OS_TYPE" == "macOS" ]]; then
                        size=$(get_dir_size "$HOME/Library/Caches")
                    else
                        size=$(get_dir_size "$HOME/.cache")
                    fi
                    ;;
                "cleanup_temp_menu")
                    size=$(get_dir_size "/tmp")
                    ;;
                "cleanup_downloads")
                    size=$(get_dir_size "$HOME/Downloads")
                    ;;
                *)
                    size=$(scan_item_and_get_size "$num" "$func")
                    ;;
            esac
            
            echo "$num|$size" > "$tmp_dir/$num"
        ) &
        pids+=($!)
    done
    
    # 等待所有扫描完成
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done
    
    # 收集结果
    for item in "${items[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ -f "$tmp_dir/$num" ]] || continue
        
        local result=$(cat "$tmp_dir/$num")
        local result_num="${result%%|*}"
        local result_size="${result##*|}"
        
        local idx=$(get_scan_index "$num")
        SCAN_RESULT_NAMES[$idx]="$name"
        SCAN_RESULT_SIZES[$idx]="$result_size"
    done
    
    # 清理临时文件
    rm -rf "$tmp_dir"
}

# 扫描单项并返回大小
scan_item_and_get_size() {
    local num="$1"
    local func="$2"
    
    case "$func" in
        "cleanup_user_cache_menu")
            if [[ "$OS_TYPE" == "macOS" ]]; then
                get_dir_size "$HOME/Library/Caches"
            else
                get_dir_size "$HOME/.cache"
            fi
            ;;
        "cleanup_temp_menu")
            get_dir_size "/tmp"
            ;;
        "cleanup_downloads")
            get_dir_size "$HOME/Downloads"
            ;;
        "cleanup_homebrew")
            if command -v brew &> /dev/null; then
                local brew_cache
                brew_cache=$(brew --cache 2>/dev/null)
                if [[ -n "$brew_cache" && -e "$brew_cache" ]]; then
                    get_dir_size "$brew_cache"
                else
                    echo "0KB"
                fi
            else
                echo "0KB"
            fi
            ;;
        *)
            echo "0KB"
            ;;
    esac
}

# ============================================
# 智能排序功能 - 优先显示大文件
# ============================================

# 按大小排序扫描结果（从大到小）
sort_scan_results_by_size() {
    local sorted_indices=()
    
    # 创建临时数组用于排序
    declare -a size_values
    declare -a item_indices
    
    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        [[ "$num" == "0" ]] && continue
        
        local idx=$(get_scan_index "$num")
        local size="${SCAN_RESULT_SIZES[$idx]:-0KB}"
        
        # 转换为 KB 数值用于排序
        local size_kb=0
        if [[ "$size" =~ ^([0-9.]+)(GB|MB|KB)$ ]]; then
            local num_part="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case "$unit" in
                GB) size_kb=$(awk -v n="$num_part" 'BEGIN {printf "%.0f", n*1048576}') ;;
                MB) size_kb=$(awk -v n="$num_part" 'BEGIN {printf "%.0f", n*1024}') ;;
                KB) size_kb=$(awk -v n="$num_part" 'BEGIN {printf "%.0f", n}') ;;
            esac
        fi
        
        size_values+=("$size_kb")
        item_indices+=("$num")
    done
    
    # 冒泡排序（从大到小）
    local n=${#size_values[@]}
    for ((i=0; i<n-1; i++)); do
        for ((j=0; j<n-i-1; j++)); do
            if (( size_values[j] < size_values[j+1] )); then
                # 交换
                local tmp="${size_values[j]}"
                size_values[j]="${size_values[j+1]}"
                size_values[j+1]="$tmp"
                
                tmp="${item_indices[j]}"
                item_indices[j]="${item_indices[j+1]}"
                item_indices[j+1]="$tmp"
            fi
        done
    done
    
    # 返回排序后的索引
    SORTED_ITEM_INDICES=("${item_indices[@]}")
}

# 显示排序后的扫描结果
display_sorted_scan_results() {
    sort_scan_results_by_size
    
    echo -e "${YELLOW}扫描结果 (按大小排序，大文件优先):${NC}\n"
    
    SELECTED_ITEMS=()
    
    for num in "${SORTED_ITEM_INDICES[@]}"; do
        local idx=$(get_scan_index "$num")
        local name="${SCAN_RESULT_NAMES[$idx]}"
        local size="${SCAN_RESULT_SIZES[$idx]}"
        local marker=" "
        
        # 有内容的默认勾选
        if is_selectable_scan_size "$size"; then
            # 查找对应的 func
            for item in "${MENU_ITEMS[@]}"; do
                IFS='|' read -r item_num item_name item_default item_system item_func <<< "$item"
                if [[ "$item_num" == "$num" ]]; then
                    case "$item_func" in
                        "cleanup_all_macos"|"cleanup_all_linux"|"launch_ncdu_menu")
                            ;;
                        *)
                            marker="*"
                            SELECTED_ITEMS+=($num)
                            ;;
                    esac
                    break
                fi
            done
        fi
        
        printf " [%s] %-2s %-40s " "$marker" "$num" "$name"
        echo -e "${YELLOW}${size}${NC}"
    done
    
    echo ""
    echo -e "${BLUE}提示:${NC}"
    echo "  • 输入数字切换勾选状态 (如: 1,3,5 或 1 3 5)"
    echo "  • 输入 a 全选, 输入 n 取消全选"
    echo "  • 直接回车开始清理已勾选项目"
    echo "  • 输入 q 退出"
}

# 显示扫描结果并让用户选择
display_scan_results() {
    echo -e "${YELLOW}扫描结果 (带 * 的将被清理):${NC}\n"
    
    # 清空之前的选择
    SELECTED_ITEMS=()
    
    local idx=0
    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        [[ "$num" == "0" ]] && continue
        
        local idx2=$(get_scan_index "$num")
        local size="${SCAN_RESULT_SIZES[$idx2]}"
        local marker=" "
        
        # 有内容的默认勾选，但排除特殊选项（清理所有、ncdu工具等）
        local should_select=0
        if is_selectable_scan_size "$size"; then
            # 排除"清理所有"和"ncdu"等特殊选项
            case "$func" in
                "cleanup_all_macos"|"cleanup_all_linux"|"launch_ncdu_menu")
                    should_select=0
                    ;;
                *)
                    should_select=1
                    ;;
            esac
        fi
        
        if [[ $should_select -eq 1 ]]; then
            marker="*"
            SELECTED_ITEMS+=($num)
        fi
        
        # 先打印基本信息，再单独打印带颜色的大小
        printf " [%s] %-2s %-40s " "$marker" "$num" "$name"
        echo -e "${YELLOW}${size}${NC}"
        ((idx++))
    done
    
    echo ""
    echo -e "${BLUE}提示:${NC}"
    echo "  • 输入数字切换勾选状态 (如: 1,3,5 或 1 3 5)"
    echo "  • 输入 a 全选, 输入 n 取消全选"
    echo "  • 直接回车开始清理已勾选项目"
    echo "  • 输入 q 退出"
}

# 切换项目的勾选状态
toggle_selection() {
    local num="$1"
    local found=0
    local new_selection=()
    
    # 检查是否已在选择列表中
    for item in "${SELECTED_ITEMS[@]}"; do
        if [[ "$item" == "$num" ]]; then
            found=1
        else
            new_selection+=($item)
        fi
    done
    
    # 如果未找到，添加；如果找到，移除（上面已处理）
    if [[ $found -eq 0 ]]; then
        new_selection+=($num)
    fi
    
    SELECTED_ITEMS=(${new_selection[@]})
}

# ============================================
# TUI 交互式菜单系统
# ============================================

# 扫描选中的项目
scan_selected_items() {
    echo -e "\n${YELLOW}正在扫描选中的项目...${NC}"
    SCAN_RESULT_NAMES=()
    SCAN_RESULT_SIZES=()
    
    for item_num in "${SELECTED_ITEMS[@]}"; do
        # 查找对应的项目信息
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            if [[ "$num" == "$item_num" ]]; then
                echo -n "."
                scan_item "$num" "$func" "$name"
                break
            fi
        done
    done
    echo ""
    echo -e "${GREEN}扫描完成!${NC}\n"
}
# 批量执行模式标志
BATCH_MODE=0
# 预演模式（只扫描不删除）
DRY_RUN=0
# cron 任务唯一标识（用于 install/remove/list 匹配）
CRON_MARKER="disk-clean.sh-auto"

# 显示帮助
show_help() {
    cat <<'EOF'
磁盘清理工具 - 用法

交互模式:
  ./disk-clean.sh                  启动交互式 TUI 菜单 (默认)

非交互模式 (按推荐执行, 适合定时/自动化):
  ./disk-clean.sh --auto           执行所有"默认选中"的菜单项 (推荐, 最常用)
  ./disk-clean.sh --safe           仅执行"安全清理区" (所有 default=true 的项, 纯缓存无风险)
  ./disk-clean.sh --all            执行所有菜单项 (含高风险/需提权操作, 不推荐定时使用)
  ./disk-clean.sh --run 1,2,6      按菜单编号执行, 逗号/空格分隔
  ./disk-clean.sh --list           列出所有菜单项及编号/风险等级

通用选项:
  ./disk-clean.sh --dry-run ...    预演模式: 只扫描不删除, 显示预计释放空间
  ./disk-clean.sh --quiet          静默模式: 减少输出, 仅输出摘要 (配合非交互)
  ./disk-clean.sh --help           显示此帮助

定时任务管理 (使用 crontab):
  ./disk-clean.sh --install-cron                    安装默认定时任务 (每周日凌晨3点, --safe)
  ./disk-clean.sh --install-cron --schedule "0 2 * * *"   自定义 cron 表达式
  ./disk-clean.sh --install-cron --mode auto             使用 --auto 代替 --safe
  ./disk-clean.sh --list-cron                      查看当前已安装的 disk-clean 定时任务
  ./disk-clean.sh --remove-cron                    移除所有 disk-clean 相关定时任务

退出码: 0=成功  1=部分失败  2=参数/环境错误
EOF
}

# 列出所有菜单项 (非交互可见)
list_menu_items() {
    echo "菜单项 (${OS_TYPE}):"
    echo "------------------------------------------------------------------"
    printf " %-3s %-8s %-55s %s\n" "编号" "默认" "名称" "执行函数"
    echo "------------------------------------------------------------------"
    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
        local marker=" "
        [[ "$default" == "true" ]] && marker="*"
        printf " %-3s %-8s %-55s %s\n" "$num" "$marker" "$name" "$func"
    done
    echo "------------------------------------------------------------------"
    echo "带 * 为默认选中项 (--auto 模式执行)"
}

# 按预设模式收集 SELECTED_ITEMS
collect_selected_items() {
    local mode="$1"  # default | safe | all | "1,2,6"
    SELECTED_ITEMS=()
    if [[ "$mode" == "default" ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$num" == "0" ]] && continue
            [[ "$default" == "true" ]] && SELECTED_ITEMS+=("$num")
        done
    elif [[ "$mode" == "safe" ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            # 安全区: default=true 的项 (无论哪个区)
            [[ "$num" == "0" ]] && continue
            [[ "$default" == "true" ]] && SELECTED_ITEMS+=("$num")
        done
    elif [[ "$mode" == "all" ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$num" == "0" ]] && continue
            # 组合项已包含全部单项，避免 --all 时重复执行
            [[ "$func" == "cleanup_all_macos" ]] && continue
            SELECTED_ITEMS+=("$num")
        done
    else
        # 自定义编号: "1,2,6" 或 "1 2 6"
        local IFS=', '
        for n in $mode; do
            [[ "$n" =~ ^[0-9]+$ ]] && SELECTED_ITEMS+=("$n")
        done
    fi
}

# 非交互执行核心 (BATCH_MODE=1, 逐项执行, 不进 TUI)
run_non_interactive() {
    if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
        echo -e "${RED}错误: 没有可执行的清理项${NC}" >&2
        return 2
    fi
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE} 非交互模式开始 (模式: $CLI_MODE)${NC}"
    echo -e "${BLUE}================================================${NC}"
    show_disk_usage

    # 扫描 (无论是否 dry-run 都显示预计)
    echo -e "\n${YELLOW}扫描可清理项目...${NC}"
    if [[ "$CLI_QUIET" -eq 1 ]]; then
        scan_selected_items >/dev/null 2>&1
    else
        scan_selected_items
    fi
    local total_size_str="0 MB"
    local sizes_to_sum=""
    local has_real=0
    for item_num in "${SELECTED_ITEMS[@]}"; do
        local idx=$(get_scan_index "$item_num")
        local name="${SCAN_RESULT_NAMES[$idx]}"
        local size="${SCAN_RESULT_SIZES[$idx]}"
        printf "  %-3s %-55s %s\n" "[$item_num]" "$name" "${size}"
        sizes_to_sum+="${size} "
        if [[ "$size" != "0KB" && "$size" != "N/A" && "$size" != "0B" ]]; then
            has_real=1
        fi
    done
    if [[ -n "$sizes_to_sum" ]]; then
        total_size_str=$(echo "$sizes_to_sum" | awk '{
            sum = 0;
            for(i=1; i<=NF; i++) {
                val = $i;
                while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)) {
                    match_str = substr(val, RSTART, RLENGTH);
                    num = substr(match_str, 1, match(match_str, /[A-Z]/)-1) + 0;
                    unit = substr(match_str, match(match_str, /[A-Z]/));
                    if(unit == "GB") sum += num * 1024;
                    else if(unit == "MB") sum += num;
                    else if(unit == "KB") sum += num / 1024;
                    val = substr(val, RSTART + RLENGTH);
                }
            }
            if (sum >= 1024) printf "%.2f GB", sum/1024;
            else if (sum > 0) printf "%.2f MB", sum;
            else printf "0 MB";
        }')
    fi
    echo -e "\n${YELLOW}预计可释放: ${total_size_str}${NC}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "\n${GREEN}✓ 预演模式, 未执行任何删除操作${NC}"
        return 0
    fi

    echo -e "\n${YELLOW}开始执行清理 (BATCH 模式, 无二次确认)...${NC}"
    BATCH_MODE=1
    local success_count=0 fail_count=0
    local avail_before
    avail_before=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    for item_num in "${SELECTED_ITEMS[@]}"; do
        if [[ "$CLI_QUIET" -eq 1 ]]; then
            execute_single_item "$item_num" >/dev/null 2>&1
            local item_ret=$?
        else
            echo -e "\n${BLUE}--- [${item_num}] ---${NC}"
            execute_single_item "$item_num"
            local item_ret=$?
        fi
        if [[ "$item_ret" -eq 0 ]]; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    BATCH_MODE=0

    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${GREEN}执行完成${NC}: 成功=${success_count}, 失败=${fail_count}"
    # 计算实际释放空间
    local avail_after
    avail_after=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$avail_before" && -n "$avail_after" ]]; then
        local freed_kb=$((avail_after - avail_before))
        if [[ $freed_kb -gt 0 ]]; then
            local freed_str
            freed_str=$(format_size_kb "$freed_kb")
            echo -e "${GREEN}实际释放空间: ${YELLOW}${freed_str}${NC}"
        elif [[ $freed_kb -eq 0 ]]; then
            echo -e "${YELLOW}实际释放空间: 0 (磁盘可用空间无变化)${NC}"
        else
            echo -e "${YELLOW}注意: 清理后磁盘可用空间减少 ${freed_kb}KB (其他进程可能正在写入)${NC}"
        fi
        [[ "$total_size_str" != "0 MB" ]] && echo -e "${BLUE}扫描预计可清理: ${total_size_str} (含部分清理的目录)${NC}"
    elif [[ "$total_size_str" != "0 MB" ]]; then
        echo -e "${GREEN}预计可清理: ${YELLOW}${total_size_str}${NC}"
    fi
    show_disk_usage
    log_action "INFO" "[非交互] mode=$CLI_MODE success=$success_count fail=$fail_count expected=$total_size_str"
    [[ "$fail_count" -eq 0 ]] && return 0 || return 1
}

# ===== cron 定时任务管理 =====
CRON_SCHEDULE_DEFAULT="0 3 * * 0"   # 默认: 每周日 03:00
CRON_MODE_DEFAULT="safe"            # 默认: --safe 模式 (最保守)

_install_cron_comment() {
    echo "# disk-clean.sh-auto (managed by disk-clean.sh --install-cron / --remove-cron, DO NOT EDIT MANUALLY)"
}

# 检查 cron 条目是否已存在 (避免重复安装)
cron_has_entry() {
    crontab -l 2>/dev/null | grep -Fq "$CRON_MARKER"
}

list_cron() {
    echo -e "${BLUE}当前 disk-clean.sh 相关 cron 任务:${NC}"
    local entries
    entries=$(crontab -l 2>/dev/null | grep -F "$CRON_MARKER")
    if [[ -z "$entries" ]]; then
        echo "  (未安装)"
    else
        echo "$entries" | awk '{print "  " $0}'
    fi
}

install_cron() {
    local schedule="$1"
    local mode="$2"
    local script_abs
    script_abs=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
    local log_dir="$HOME/.cache/disk-clean-logs"
    mkdir -p "$log_dir"
    local log_file="$log_dir/clean-$(date '+%Y%m').log"

    if [[ ! -x "$script_abs" ]]; then
        chmod +x "$script_abs" 2>/dev/null || true
    fi

    if cron_has_entry; then
        echo -e "${YELLOW}检测到已存在的 disk-clean cron 任务, 先移除再安装${NC}"
        remove_cron --silent
    fi

    local comment="$(_install_cron_comment)"
    local entry="${schedule} /bin/bash '${script_abs}' --${mode} --quiet >> '${log_file}' 2>&1  # ${CRON_MARKER}"

    # 合并: 现有 crontab (非 disk-clean 的行) + 注释 + 新条目
    {
        crontab -l 2>/dev/null | grep -v -F "$CRON_MARKER" | grep -v -F "$(echo "$comment" | sed 's/# //')" || true
        echo ""
        echo "$comment"
        echo "$entry"
    } | crontab - 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ cron 定时任务已安装${NC}"
        echo -e "  调度:    ${YELLOW}${schedule}${NC}"
        echo -e "  模式:    ${YELLOW}--${mode}${NC}"
        echo -e "  脚本:    ${script_abs}"
        echo -e "  日志:    ${log_file}"
        echo ""
        echo -e "${BLUE}安装后的 crontab 条目:${NC}"
        list_cron
        echo ""
        echo -e "${YELLOW}提示: 使用 '${0} --list-cron' 查看, '${0} --remove-cron' 可随时移除${NC}"
        return 0
    else
        echo -e "${RED}✗ crontab 写入失败, 请检查权限或手动安装:${NC}"
        echo "  crontab -e  # 添加以下行:"
        echo "  $entry"
        return 1
    fi
}

remove_cron() {
    local silent="$1"
    if ! cron_has_entry; then
        if [[ "$silent" != "--silent" ]]; then
            echo -e "${YELLOW}- 未发现 disk-clean.sh 相关定时任务, 无需移除${NC}"
        fi
        return 0
    fi
    local before_count
    before_count=$(crontab -l 2>/dev/null | grep -c -F "$CRON_MARKER" || true)
    crontab -l 2>/dev/null | grep -v -F "$CRON_MARKER" | crontab - 2>/dev/null
    if [[ $? -eq 0 ]]; then
        if [[ "$silent" != "--silent" ]]; then
            echo -e "${GREEN}✓ 已移除 ${before_count} 条 disk-clean 定时任务${NC}"
        fi
        return 0
    else
        echo -e "${RED}✗ crontab 写入失败${NC}"
        return 1
    fi
}

# ===== CLI 参数解析 =====
CLI_MODE=""        # auto | safe | all | <编号列表> | "" (交互)
CLI_QUIET=0
ACTION=""          # "" | install-cron | remove-cron | list-cron | list-menu | help
CRON_SCHEDULE="$CRON_SCHEDULE_DEFAULT"
CRON_MODE="$CRON_MODE_DEFAULT"

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto|--default)
                CLI_MODE="default" ;;
            --safe)
                CLI_MODE="safe" ;;
            --all)
                CLI_MODE="all" ;;
            --run)
                [[ $# -lt 2 ]] && { echo -e "${RED}--run 需要参数, 如: --run 1,2,6${NC}" >&2; return 2; }
                CLI_MODE="$2"; shift ;;
            --dry-run)
                DRY_RUN=1 ;;
            --quiet|-q)
                CLI_QUIET=1 ;;
            --install-cron)
                ACTION="install-cron" ;;
            --remove-cron|--uninstall-cron)
                ACTION="remove-cron" ;;
            --list-cron)
                ACTION="list-cron" ;;
            --schedule)
                [[ $# -lt 2 ]] && { echo -e "${RED}--schedule 需要参数, 如: --schedule '0 2 * * *'${NC}" >&2; return 2; }
                CRON_SCHEDULE="$2"; shift ;;
            --mode)
                [[ $# -lt 2 ]] && { echo -e "${RED}--mode 需要参数: safe|auto${NC}" >&2; return 2; }
                case "$2" in
                    safe|auto) CRON_MODE="$2" ;;
                    *) echo -e "${RED}--mode 仅支持 safe|auto${NC}" >&2; return 2 ;;
                esac
                shift ;;
            --list|--list-menu)
                ACTION="list-menu" ;;
            -h|--help)
                ACTION="help" ;;
            *)
                echo -e "${RED}未知参数: $1${NC}" >&2
                echo "使用 --help 查看帮助" >&2
                return 2
                ;;
        esac
        shift
    done
    return 0
}

# 静默模式下减少颜色 (重定向到文件时自动降级)
if [[ "$CLI_QUIET" -eq 1 || ! -t 1 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

if [[ "$CLI_QUIET" -eq 1 ]]; then
    show_disk_usage() { :; }
fi

parse_cli_args "$@"
cli_ret=$?
if [[ "$cli_ret" -ne 0 ]]; then
    exit "$cli_ret"
fi

# 按 ACTION 分派: cron 管理 / help / list 等在交互菜单前执行
case "$ACTION" in
    help)
        show_help
        exit 0 ;;
    list-menu)
        list_menu_items
        exit 0 ;;
    list-cron)
        list_cron
        exit 0 ;;
    remove-cron)
        remove_cron
        exit $? ;;
    install-cron)
        install_cron "$CRON_SCHEDULE" "$CRON_MODE"
        exit $? ;;
esac

# 执行单个清理项（必须在非交互分支调用前定义）
execute_single_item() {
    local choice="$1"

    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r num name default system func <<< "$item"
        if [[ "$num" == "$choice" ]]; then
            if [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]]; then
                echo -e "${RED}错误: 选项 $choice 不适用于当前系统${NC}"
                return 1
            fi
            "$func"
            return $?
        fi
    done

    echo -e "${RED}无效选择: $choice${NC}"
    return 1
}

# 非交互清理
if [[ -n "$CLI_MODE" ]]; then
    collect_selected_items "$CLI_MODE"
    init_log
    run_non_interactive
    exit $?
fi

# 无参数/非终端时: 若有终端进交互; 若 cron/管道触发但未指定模式, 自动退化为 --safe
if [[ ! -t 0 || ! -t 1 ]]; then
    echo -e "${YELLOW}未在终端中运行, 自动使用 --safe 模式${NC}"
    collect_selected_items "safe"
    init_log
    run_non_interactive
    exit $?
fi

# 初始化日志（函数已定义后调用）
init_log

# ============================================

# 交互式 TUI 菜单
interactive_tui_menu() {
    local prompt="$1"
    local mode="${2:-initial}" # initial 或 scan_result
    
    local opt_nums=()
    local opt_names=()
    local opt_selected=()
    local opt_sizes=()
    
    if [[ "$mode" == "initial" ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$num" == "0" ]] && continue
            # 退出/清理所有属于控制项，不作为可勾选的清理项混在列表里
            [[ "$func" == "exit_script" || "$func" == "cleanup_all_macos" ]] && continue
            
            opt_nums+=("$num")
            opt_names+=("$name")
            opt_sizes+=("")
            
            local is_sel=0
            for sel in "${SELECTED_ITEMS[@]}"; do
                if [[ "$sel" == "$num" ]]; then
                    is_sel=1
                    break
                fi
            done
            opt_selected+=($is_sel)
        done
    else
        # mode == scan_result
        for item_num in "${SELECTED_ITEMS[@]}"; do
            idx=$(get_scan_index "$item_num")
            local size="${SCAN_RESULT_SIZES[$idx]}"
            
            if is_selectable_scan_size "$size"; then
                opt_nums+=("$item_num")
                opt_names+=("${SCAN_RESULT_NAMES[$idx]}")
                opt_sizes+=("$size")
                opt_selected+=("1") # 默认都选中准备清理
            fi
        done
        if [[ ${#opt_nums[@]} -eq 0 ]]; then
            return 1 # 没有内容
        fi
    fi
    
    local num_options=${#opt_nums[@]}
    local current_idx=0
    
    tput civis
    cleanup_tui() {
        tput cnorm
    }
    trap cleanup_tui EXIT INT TERM
    
    echo -e "${YELLOW}${prompt}${NC}"
    echo ""
    
    local key
    local redraw=1
    while true; do
        if [[ $redraw -eq 1 ]]; then
            for ((i=0; i<num_options; i++)); do
                local marker=" "
                [[ ${opt_selected[$i]} -eq 1 ]] && marker="*"
                
                local display_name="${opt_names[$i]}"
                local display_size="${opt_sizes[$i]}"
                local size_str=""
                if [[ -n "$display_size" ]]; then
                    size_str=" (${display_size})"
                fi
                
                if [[ $i -eq $current_idx ]]; then
                    echo -e "\r\033[K${BLUE}> [${marker}] ${display_name}${size_str}${NC}"
                else
                    echo -e "\r\033[K  [${marker}] ${display_name}${YELLOW}${size_str}${NC}"
                fi
            done
            
            if [[ "$mode" == "scan_result" ]]; then
                local sizes_to_sum=""
                for ((i=0; i<num_options; i++)); do
                    if [[ ${opt_selected[$i]} -eq 1 && "${opt_nums[$i]}" != "q" ]]; then
                        sizes_to_sum+="${opt_sizes[$i]} "
                    fi
                done
                local sum_str="0MB"
                if [[ -n "$sizes_to_sum" ]]; then
                    sum_str=$(echo "$sizes_to_sum" | awk '{
                        sum = 0;
                        for(i=1; i<=NF; i++) {
                            val = $i;
                            while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)) {
                                match_str = substr(val, RSTART, RLENGTH);
                                num = substr(match_str, 1, match(match_str, /[A-Z]/)-1) + 0;
                                unit = substr(match_str, match(match_str, /[A-Z]/));
                                if(unit == "GB") sum += num * 1024;
                                else if(unit == "MB") sum += num;
                                else if(unit == "KB") sum += num / 1024;
                                val = substr(val, RSTART + RLENGTH);
                            }
                        }
                        if (sum >= 1024) printf "%.2f GB", sum/1024;
                        else if (sum > 0) printf "%.2f MB", sum;
                        else printf "0 MB";
                    }')
                fi
                echo -e "\r\033[K----------------------------------------"
                echo -e "\r\033[K当前已勾选项目总计可清理: ${GREEN}${sum_str}${NC}"
            fi
            # 菜单项下方固定显示操作提示，避免列表过长时上方的提示滚出屏幕
            echo -e "\r\033[K${BLUE}操作: ↑/↓ 移动 · 空格 勾选 · a 全选 · n 全不选 · 回车 ${mode:+确认} · q 退出${NC}"
            redraw=0
        fi
        
        local up_lines=$((num_options + 1))
        if [[ "$mode" == "scan_result" ]]; then
            up_lines=$((num_options + 3))
        fi
        
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            if [[ "$key" == "[A" ]]; then
                ((current_idx--))
                [[ $current_idx -lt 0 ]] && current_idx=$((num_options - 1))
                redraw=1
                tput cuu $up_lines
            elif [[ "$key" == "[B" ]]; then
                ((current_idx++))
                [[ $current_idx -ge $num_options ]] && current_idx=0
                redraw=1
                tput cuu $up_lines
            fi
        elif [[ "$key" == " " ]]; then
            if [[ ${opt_selected[$current_idx]} -eq 1 ]]; then
                opt_selected[$current_idx]=0
            else
                opt_selected[$current_idx]=1
            fi
            redraw=1
            tput cuu $up_lines
        elif [[ "$key" == "a" || "$key" == "A" ]]; then
            for ((i=0; i<num_options; i++)); do
                opt_selected[$i]=1
            done
            redraw=1
            tput cuu $up_lines
        elif [[ "$key" == "n" || "$key" == "N" ]]; then
            for ((i=0; i<num_options; i++)); do
                opt_selected[$i]=0
            done
            redraw=1
            tput cuu $up_lines
        elif [[ "$key" == "" ]]; then
            break
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            if [[ "$mode" == "initial" ]]; then
                cleanup_tui
                exit 0
            else
                break # 在 scan_result 模式按 q 返回
            fi
        fi
    done
    
    cleanup_tui
    trap - EXIT INT TERM
    echo ""
    
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
        if [[ "$mode" == "initial" ]]; then
            exit_script
        else
            return 2 # 返回主菜单
        fi
    fi
    
    SELECTED_ITEMS=()
    for ((i=0; i<num_options; i++)); do
        if [[ ${opt_selected[$i]} -eq 1 && "${opt_nums[$i]}" != "q" ]]; then
            SELECTED_ITEMS+=("${opt_nums[$i]}")
        fi
    done
    return 0
}

# ============================================
# 主循环
# ============================================
while true; do
    # 初始化推荐选择
    if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
        for item in "${MENU_ITEMS[@]}"; do
            IFS='|' read -r num name default system func <<< "$item"
            [[ "$system" != "both" && "$system" != "$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')" ]] && continue
            [[ "$num" == "0" ]] && continue
            # 使用 default 字段判断是否默认选中（true=安全自动选中）
            [[ "$default" == "true" ]] && SELECTED_ITEMS+=($num)
        done
    fi

    # 步骤1: 显示初始菜单
    interactive_tui_menu "请选择要扫描的项目 (带 * 为推荐清理项):" "initial"
    if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
        echo -e "${RED}未选择任何项目，请至少选择一个${NC}"
        sleep 1
        continue
    fi
    
    # 步骤2: 扫描选中的项目
    scan_selected_items
    
    # 步骤3: 直接过滤掉空/不可清理项（原 scan_result 菜单会做这件事，
    # 现在去掉二次勾选菜单，但保留过滤，避免对空目录执行无效清理）
    local filtered_items=()
    for item_num in "${SELECTED_ITEMS[@]}"; do
        idx=$(get_scan_index "$item_num")
        if is_selectable_scan_size "${SCAN_RESULT_SIZES[$idx]:-}"; then
            filtered_items+=("$item_num")
        fi
    done
    if [[ ${#filtered_items[@]} -eq 0 ]]; then
        echo -e "${YELLOW}所有选中的项目均为空，无需清理${NC}"
        sleep 1
        continue
    fi
    SELECTED_ITEMS=("${filtered_items[@]}")

    # 步骤4: 显示将要清理的项目清单
    echo -e "\n${YELLOW}扫描完成，以下项目将被清理:${NC}\n"
    
    items_to_clean=("${SELECTED_ITEMS[@]}")
    
    # 显示将要清理的项目
    for item_num in "${items_to_clean[@]}"; do
        idx=$(get_scan_index "$item_num")
        name="${SCAN_RESULT_NAMES[$idx]}"
        size="${SCAN_RESULT_SIZES[$idx]}"
        printf "  ✓ %-2s %-40s " "$item_num" "$name"
        echo -e "${YELLOW}${size}${NC}"
    done
    echo ""
    
    # 计算清理前的总大小
    sizes_to_sum=""
    for item_num in "${items_to_clean[@]}"; do
        idx=$(get_scan_index "$item_num")
        sizes_to_sum+="${SCAN_RESULT_SIZES[$idx]} "
    done
    total_size_str="0 MB"
    if [[ -n "$sizes_to_sum" ]]; then
        total_size_str=$(echo "$sizes_to_sum" | awk '{
            sum = 0;
            for(i=1; i<=NF; i++) {
                val = $i;
                while(match(val, /[0-9]+(\.[0-9]+)?(KB|MB|GB)/)) {
                    match_str = substr(val, RSTART, RLENGTH);
                    num = substr(match_str, 1, match(match_str, /[A-Z]/)-1) + 0;
                    unit = substr(match_str, match(match_str, /[A-Z]/));
                    if(unit == "GB") sum += num * 1024;
                    else if(unit == "MB") sum += num;
                    else if(unit == "KB") sum += num / 1024;
                    val = substr(val, RSTART + RLENGTH);
                }
            }
            if (sum >= 1024) printf "%.2f GB", sum/1024;
            else if (sum > 0) printf "%.2f MB", sum;
            else printf "0 MB";
        }')
    fi
    
    # 步骤3.5: 执行前确认。清单已列出，提示合并为一行：回车执行、q 取消。
    echo ""
    echo -ne "  - 共 ${#items_to_clean[@]} 项，预计释放 ${GREEN}${total_size_str}${NC}，按 ${GREEN}回车${NC} 执行，按 ${YELLOW}q${NC} 取消: "
    read -r confirm_input
    if [[ "$confirm_input" == "q" || "$confirm_input" == "Q" ]]; then
        echo -e "${YELLOW}已取消执行，返回主菜单${NC}"
        sleep 1
        continue
    fi
    # 只认空回车执行，其它输入一律视为取消，避免误触直接删除
    if [[ -n "$confirm_input" ]]; then
        echo -e "${YELLOW}已取消执行，返回主菜单${NC}"
        sleep 1
        continue
    fi

    BATCH_MODE=1
    success_count=0
    fail_count=0
    
    # 记录清理前的磁盘可用空间（用于计算实际释放）
    avail_before=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    
    for item_num in "${items_to_clean[@]}"; do
        if execute_single_item "$item_num"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    BATCH_MODE=0
    
    echo -e "\n${GREEN}执行完成!${NC} 成功: $success_count, 失败: $fail_count"
    
    # 计算实际释放空间（清理前后的 df 可用空间差值）
    avail_after=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$avail_before" && -n "$avail_after" ]]; then
        freed_kb=$((avail_after - avail_before))
        if [[ $freed_kb -gt 0 ]]; then
            freed_str=$(format_size_kb "$freed_kb")
            echo -e "${GREEN}实际释放空间: ${YELLOW}${freed_str}${NC}"
        elif [[ $freed_kb -eq 0 ]]; then
            echo -e "${YELLOW}实际释放空间: 0 (磁盘可用空间无变化)${NC}"
        else
            echo -e "${YELLOW}注意: 清理后磁盘可用空间减少 ${freed_kb}KB${NC}"
            echo -e "       (可能因其他进程写入数据，或 APSS 快照占用)"
        fi
        # 同时显示扫描预计值供参考
        if [[ "$total_size_str" != "0 MB" ]]; then
            echo -e "${BLUE}扫描预计可清理: ${total_size_str} (含未删除/部分清理的目录)${NC}"
        fi
    elif [[ "$total_size_str" != "0 MB" ]]; then
        echo -e "${GREEN}预计可清理: ${YELLOW}${total_size_str}${NC}"
    fi
    
    show_disk_usage
    
    echo -e "\n${YELLOW}=================================${NC}"
    echo -e "${YELLOW}本次执行的操作:${NC}"
    for item_num in "${items_to_clean[@]}"; do
        idx=$(get_scan_index "$item_num")
        echo "  ✓ ${SCAN_RESULT_NAMES[$idx]}"
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 成功: $success_count, 失败: $fail_count"
    echo ""
    echo "注意：此脚本不会删除系统关键文件，仅清理可安全删除的缓存和临时文件。"
    echo -e "${BLUE}提示: 扫描预计值为目录总大小，实际仅清理其中的缓存/临时文件，"
    echo -e "       因此实际释放空间通常小于预计值。${NC}"
    
    echo ""
    read -p "按回车键返回主菜单，或输入 q 退出: " exit_input
    if [[ "$exit_input" == "q" || "$exit_input" == "Q" ]]; then
        exit_script
    fi
done

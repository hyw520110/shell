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
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo -e "  ${YELLOW}-${NC} 非交互模式未检测到可用 sudo 授权，跳过需要提权的操作"
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
# 使用临时文件存储缓存
CACHE_DIR="/tmp/disk_cleanup_cache"
mkdir -p "$CACHE_DIR"

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

# 清理过期缓存
clean_expired_cache() {
    local current_time=$(get_timestamp)
    find "$CACHE_DIR" -type f -name "*.cache" 2>/dev/null | while read -r cache_file; do
        local cache_time=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
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
        local cache_time=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
        local current_time=$(get_timestamp)
        if (( current_time - cache_time <= CACHE_TTL )); then
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
        ensure_sudo || return 1
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

# 日志记录函数
LOG_FILE="${DISK_CLEAN_LOG_FILE:-${HOME}/.disk_cleanup.log}"
log_action() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

# 初始化日志
init_log() {
    echo "========================================" >> "$LOG_FILE"
    echo "磁盘清理工具启动 - $(date)" >> "$LOG_FILE"
    echo "系统: $OS_TYPE" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
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
        ensure_sudo || return 1
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
            ensure_sudo || return 1
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
            read -r -p "  - 确认清理系统缓存(/var/cache)? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
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
            read -r -p "  - 确认清理用户应用缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 APT 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 YUM/DNF 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 Pacman 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 Zypper 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 APT 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 YUM/DNF 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 Pacman 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认清理 Zypper 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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

        # 清理系统日志文件
        echo -e "\\n正在清理系统日志文件..."
        if [[ -d "/var/log" ]]; then
            local log_size
            log_size=$(get_dir_size "/var/log")
            echo -e "  - 检测到系统日志目录，大小: ${YELLOW}$log_size${NC}"
            read -r -p "  - 确认清理旧日志文件 (保留最近)? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
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
                    read -r -p "  - 确认删除旧内核? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
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
            read -r -p "  - 确认清理 Snap 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
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
            read -r -p "  - 确认清理 Flatpak 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
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
        if run_with_timeout 60 brew cleanup --prune=all 2>&1; then
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
    if command -v pnpm &> /dev/null; then
        echo -e "  - ${GREEN}检测到 PNPM${NC}，准备清理 Store..."
        
        # 批量模式下跳过确认
        if [[ $BATCH_MODE -eq 0 ]]; then
            read -r -p "  - 确认清理 PNPM 无效包 (store prune)? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo -e "  ${YELLOW}-${NC} 已跳过 PNPM 缓存清理"
                return
            fi
        fi
        
        # pnpm store path / pnpm store prune 都可能 hang（网络访问）
        # 直接用超时执行 prune，不做前置探测
        # COREPACK_ENABLE_DOWNLOAD_PROMPT=0 跳过 corepack 的交互式下载确认
        echo -e "  - 正在执行 pnpm store prune（最多等待 30 秒）..."
        if COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout 30 pnpm store prune 2>&1; then
            echo -e "  ${GREEN}✓${NC} 已清理 PNPM 孤儿包"
        else
            local rc=$?
            if [[ $rc -eq 124 ]]; then
                echo -e "  ${YELLOW}⚠${NC} PNPM store prune 超时（60s），已跳过"
                echo -e "     可手动执行: pnpm store prune"
            else
                echo -e "  ${RED}✗${NC} 清理 PNPM 时出现错误 (exit=$rc)"
            fi
        fi
    fi
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
        # ========== 安全清理区 (纯缓存/临时文件, 删除后自动重建, 不丢用户数据) ==========
        "1|清理 IDE 运行时缓存 (TRAE/Code/Windsurf 等安全缓存)|true|macos|cleanup_electron_app_caches"
        "2|清理各类应用缓存 (Caches/Containers)|true|macos|cleanup_all_app_caches_macos"
        "3|清理系统与应用日志及状态 (Logs/State)|true|macos|cleanup_all_logs_states_macos"
        "4|清理系统级临时及更新缓存 (/tmp/系统更新)|true|macos|cleanup_sys_tmp_update"
        "5|清理开发者环境缓存 (Brew/NPM/Docker/VM)|true|macos|cleanup_dev_caches"
        "6|清理开发工具缓存 (~/.cache: uv/codex/puppeteer)|true|macos|cleanup_dot_cache_dev"
        "7|清理 Gradle 缓存|true|macos|cleanup_gradle_cache"
        "8|清理 Cargo (Rust) 缓存|true|macos|cleanup_cargo_cache"
        "9|清理 VS Code 扩展安装包缓存|true|macos|cleanup_vscode_extension_cache"
        "10|清理 Qoder 工具缓存|true|macos|cleanup_qoder_cache"
        "11|清理壁纸缓存|true|macos|cleanup_wallpaper_cache"
        "12|清理过期备份目录 (open-webui)|true|macos|cleanup_expired_backups"
        "13|清理系统诊断数据库 (diag)|true|macos|cleanup_system_diagnostics"
        "14|清理审计日志 (/private/var/audit)|true|macos|cleanup_audit_logs"
        "15|清理残留的卸载应用数据 (僵尸文件)|true|macos|cleanup_orphan_appdata"
        "16|清理 Chrome 临时签名副本 (旧文件)|true|macos|cleanup_chrome_code_sign_clones"
        # ========== 谨慎清理区 (需判断/可能影响构建或含用户数据, 默认不选) ==========
        "17|智能清理 Maven 本地仓库 (保留活跃依赖)|false|macos|cleanup_maven_repo"
        "18|清理 Xcode 衍生数据及归档|false|macos|cleanup_xcode_derived_data"
        "19|清理 Git 仓库垃圾 (gc/prune)|false|both|cleanup_git_repos"
        "20|清理下载目录及浏览历史|false|both|cleanup_downloads_history"
        "21|清理空目录|false|both|cleanup_empty_dirs"
        "22|清理音乐创作软件资源库 (GarageBand/Logic)|false|macos|cleanup_garageband_logic"
        # ========== 分析工具 (不删除, 仅扫描) ==========
        "23|扫描大文件 (>100MB)|false|both|scan_large_files"
        "24|检测重复文件|false|both|detect_duplicate_files"
        # ========== 高风险区 (需提权或不可逆, 默认不选) ==========
        "25|删除 Xcode CommandLineTools|false|macos|cleanup_xcode_clt"
        # ========== 组合操作 ==========
        "26|清理所有 (执行所有清理项目)|false|both|cleanup_all_macos"
        "0|退出|false|both|exit_script"
    )
else
    # Linux 专用菜单项
    MENU_ITEMS+=(
        "4|清理 Linux 系统缓存 (/var/cache)|true|linux|cleanup_linux_system_cache"
        "5|清理包管理器缓存|true|linux|cleanup_linux_specific"
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
    local tmp_dir="${TMPDIR:-}"
    [[ -n "$tmp_dir" ]] || tmp_dir="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    [[ -n "$tmp_dir" ]] || return 1
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

# 清理 VS Code 扩展安装包缓存
cleanup_vscode_extension_cache() {
    echo -e "\n${YELLOW}正在清理 VS Code 扩展安装包缓存...${NC}"
    cleanup_generic "$HOME/Library/Application Support/Code/CachedExtensionVSIXs" "VS Code 扩展安装包缓存"
}

# 清理 Electron 类 IDE 应用的运行时缓存 (TRAE/Code/Windsurf/Codex 等)
# 仅清理浏览器引擎运行时缓存子目录 (删除后自动重建, 不含用户数据)
# 绝不触碰: User/ModularData/Local Storage/Session Storage/IndexedDB/Cookies/Preferences/Partitions
cleanup_electron_app_caches() {
    echo -e "\n${YELLOW}正在清理 Electron 类 IDE 应用运行时缓存...${NC}"
    echo -e "  ${BLUE}仅清理运行时缓存 (Cache/CachedData/GPUCache/logs 等), 不触碰会话/配置/登录态${NC}"
    # 已知 Electron 类 IDE 应用白名单 (~/Library/Application Support/<name>)
    local apps=("TRAE SOLO CN" "Code" "Code - Insiders" "Windsurf" "Codex" "cloud-code" "Cursor" "VSCodium")
    # 安全的运行时缓存子目录白名单 (均为引擎缓存, 删除后自动重建)
    local safe_subs=("Cache" "CachedData" "CachedExtensions" "CachedExtensionVSIXs" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" "GrShaderCache" "GraphiteDawnCache" "ShaderCache" "logs" "Logs" "Crashpad")
    local cleaned=0
    for app in "${apps[@]}"; do
        local app_dir="$HOME/Library/Application Support/$app"
        [[ -d "$app_dir" ]] || continue
        for sub in "${safe_subs[@]}"; do
            local d="$app_dir/$sub"
            [[ -d "$d" ]] || continue
            local size
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
        echo -e "  - 未检测到可清理的 IDE 运行时缓存"
    fi
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
    ensure_sudo || return 1
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

# 清理 Qoder 缓存
cleanup_qoder_cache() {
    echo -e "\n${YELLOW}正在清理 Qoder 工具缓存...${NC}"
    local qoder_dir="$HOME/.qoder"
    if [[ ! -d "$qoder_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} Qoder 目录不存在，跳过"
        return
    fi
    local size
    size=$(get_dir_size "$qoder_dir")
    echo -e "  - Qoder 缓存大小: ${YELLOW}$size${NC}"
    if [[ "$size" == "0KB" || "$size" == "N/A" ]]; then
        echo -e "  ${YELLOW}-${NC} Qoder 缓存为空，已跳过"
        return
    fi
    if [[ $BATCH_MODE -eq 0 ]]; then
        if ! confirm_action "清理 Qoder 缓存" "$size"; then
            echo -e "  ${YELLOW}-${NC} 已跳过"
            return
        fi
    fi
    rm -rf "$qoder_dir" 2>/dev/null && echo -e "  ${GREEN}✓${NC} 已清理 Qoder 缓存" || echo -e "  ${RED}✗${NC} 清理失败"
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
        ensure_sudo || return 1
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
    ensure_sudo || return 1
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
        return
    fi
    local found=0
    for app_dir in "$HOME/Library/Application Support/"*; do
        if [[ -d "$app_dir" ]]; then
            local app_name=$(basename "$app_dir")
            if [[ "$app_name" == "Apple" || "$app_name" == "CloudDocs" || "$app_name" == "Knowledge" || "$app_name" == "MobileSync" || "$app_name" == "CrashReporter" || "$app_name" == "SyncServices" ]]; then
                continue
            fi
            local exists=0
            if [[ -d "/Applications/${app_name}.app" ]] || [[ -d "/System/Applications/${app_name}.app" ]] || [[ -d "$HOME/Applications/${app_name}.app" ]]; then
                exists=1
            else
                if ls /Applications/*"${app_name}"*.app >/dev/null 2>&1; then
                    exists=1
                fi
            fi
            if [[ $exists -eq 0 ]]; then
                local size=$(get_dir_size "$app_dir")
                if [[ "$size" != "0KB" && "$size" != "0B" && "$size" != "" ]]; then
                    echo -e "  - 发现潜在残留数据: ${BLUE}${app_name}${NC} ($size)"
                    echo -e "    路径: ${app_dir}"
                    found=1
                fi
            fi
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo -e "  ${GREEN}未发现明显的大型残留应用数据${NC}"
    else
        echo -e "  ${YELLOW}提示: 残留数据可能有误判，建议手动确认后删除：${NC}"
        echo -e "  ${YELLOW}  rm -rf \"~/Library/Application Support/<应用名>\"${NC}"
    fi
}
# 清理审计日志 (/private/var/audit)
cleanup_audit_logs() {
    echo -e "\n${YELLOW}正在清理审计日志 (${BLUE}/private/var/audit${NC})...${NC}"
    local audit_dir="/private/var/audit"
    if [[ ! -d "$audit_dir" ]]; then
        echo -e "  ${YELLOW}-${NC} 审计日志目录不存在，跳过"
        return
    fi
    ensure_sudo || return 1
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

# 12. macOS: 清理所有 / Linux: (同 10)
cleanup_all_macos() {
    echo -e "\n${YELLOW}正在执行全部 macOS 清理...${NC}"
    if confirm_action "执行所有清理项目"; then
        cleanup_electron_app_caches
        cleanup_all_app_caches_macos
        cleanup_all_logs_states_macos
        cleanup_sys_tmp_update
        cleanup_dev_caches
        cleanup_dot_cache_dev
        cleanup_gradle_cache
        cleanup_cargo_cache
        cleanup_vscode_extension_cache
        cleanup_maven_repo
        cleanup_xcode_derived_data
        cleanup_downloads_history
        cleanup_empty_dirs
        cleanup_system_diagnostics
        cleanup_expired_backups
        cleanup_qoder_cache
        cleanup_chrome_code_sign_clones
        cleanup_garageband_logic
        cleanup_xcode_clt
        cleanup_wallpaper_cache
        cleanup_orphan_appdata
        cleanup_audit_logs
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
            ensure_sudo || return 1
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
            SCAN_RESULT_SIZES[$idx]=$(get_dir_size "$HOME/.qoder")
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
        "cleanup_linux_system_cache"|"cleanup_linux_specific")
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
    
    opt_nums+=("q")
    if [[ "$mode" == "initial" ]]; then
        opt_names+=("退出脚本")
    else
        opt_names+=("返回主菜单")
    fi
    opt_sizes+=("")
    opt_selected+=("0")
    
    local num_options=${#opt_nums[@]}
    local current_idx=0
    
    tput civis
    cleanup_tui() {
        tput cnorm
    }
    trap cleanup_tui EXIT INT TERM
    
    echo -e "${YELLOW}${prompt}${NC}"
    echo -e "${BLUE}提示: [↑/↓] 移动，[空格] 切换选中，[回车] 确认${NC}"
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
                
                if [[ "${opt_nums[$i]}" == "q" ]]; then
                    if [[ $i -eq $current_idx ]]; then
                        echo -e "\r\033[K${BLUE}> [q] ${display_name}${size_str}${NC}"
                    else
                        echo -e "\r\033[K  [q] ${display_name}${YELLOW}${size_str}${NC}"
                    fi
                else
                    if [[ $i -eq $current_idx ]]; then
                        echo -e "\r\033[K${BLUE}> [${marker}] ${display_name}${size_str}${NC}"
                    else
                        echo -e "\r\033[K  [${marker}] ${display_name}${YELLOW}${size_str}${NC}"
                    fi
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
            redraw=0
        fi
        
        local up_lines=$num_options
        if [[ "$mode" == "scan_result" ]]; then
            up_lines=$((num_options + 2))
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
            if [[ "${opt_nums[$current_idx]}" != "q" ]]; then
                if [[ ${opt_selected[$current_idx]} -eq 1 ]]; then
                    opt_selected[$current_idx]=0
                else
                    opt_selected[$current_idx]=1
                fi
                redraw=1
                tput cuu $up_lines
            fi
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
    
    if [[ "${opt_nums[$current_idx]}" == "q" || "$key" == "q" || "$key" == "Q" ]]; then
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
    
    # 步骤3: 显示扫描结果，允许用户取消部分勾选
    interactive_tui_menu "扫描完成！请确认要清理的项目:" "scan_result"
    ret=$?
    if [[ $ret -eq 1 ]]; then
        echo -e "${YELLOW}所有选中的项目均为空，无需清理${NC}"
        sleep 1
        continue
    elif [[ $ret -eq 2 ]]; then
        continue # 返回主菜单
    fi
    
    if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
        echo -e "${RED}未选择任何要清理的项目${NC}"
        sleep 1
        continue
    fi

    # 步骤4: 过滤掉0KB/N/A的项目，直接执行清理
    echo -e "\n${YELLOW}开始执行清理...${NC}\n"
    
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
    
    BATCH_MODE=1
    success_count=0
    fail_count=0
    
    # 记录清理前的磁盘可用空间（用于计算实际释放）
    avail_before=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    
    for item_num in "${items_to_clean[@]}"; do
        echo -e "\n${BLUE}========================================${NC}"
        if execute_single_item "$item_num"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    BATCH_MODE=0
    
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${GREEN}执行完成!${NC} 成功: $success_count, 失败: $fail_count"
    
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

#!/bin/bash

# 脚本功能：监控并记录与指定目标建立的TCP连接及其关联进程。

# --- 默认配置 ---
# 要监控的目标主机名或IP地址，用空格隔开
DEFAULT_TARGET_HOSTS=("google" "github" "47.110.177.14")

# 日志文件路径，使用/tmp或/var/log更合适
DEFAULT_LOG_FILE="/tmp/net_monitor.log"

# 检查周期（秒）
DEFAULT_CHECK_INTERVAL=15

# PID 文件路径
DEFAULT_PID_FILE="/tmp/net_monitor.pid"
# --- 结束默认配置 ---

# --- 全局变量 ---
TARGET_HOSTS=("${DEFAULT_TARGET_HOSTS[@]}")
LOG_FILE="$DEFAULT_LOG_FILE"
CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
ONCE_MODE=false
VERBOSE_MODE=false
PID_FILE="$DEFAULT_PID_FILE"
# --- 结束全局变量 ---

# 显示帮助信息
show_help() {
    cat << EOF
网络连接监控工具 - 监控并记录与指定目标建立的TCP连接

用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -t, --targets       指定目标主机（多个用空格分隔，如 "google github"）
  -l, --log-file      指定日志文件路径（默认: /tmp/net_monitor.log）
  -i, --interval      检查间隔时间（秒，默认: 15）
  -o, --once          执行一次检查后退出（不循环监控）
  -v, --verbose       显示详细信息（包括所有TCP连接）
  -s, --stop          停止后台运行的服务
  -S, --status        查看服务运行状态

示例:
  $0                           # 后台运行监控（默认）
  $0 -o                        # 执行一次检查
  $0 -s                        # 停止后台服务
  $0 -S                        # 查看服务状态
  $0 -t "google baidu"         # 监控 google 和 baidu
  $0 -v -o                     # 执行一次检查并显示详细信息

EOF
}

# 检查后台进程是否在运行
check_daemon_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "服务正在运行 (PID: $pid)"
            return 0
        else
            # PID 文件存在但进程不存在，清理 PID 文件
            rm -f "$PID_FILE"
            echo "服务未运行"
            return 1
        fi
    else
        echo "服务未运行"
        return 1
    fi
}

# 停止后台进程
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "正在停止服务 (PID: $pid)..."
            kill "$pid"
            sleep 1

            # 检查进程是否已停止
            if kill -0 "$pid" 2>/dev/null; then
                echo "强制停止服务..."
                kill -9 "$pid"
            fi

            rm -f "$PID_FILE"
            echo "服务已停止"
        else
            echo "服务未运行"
            rm -f "$PID_FILE"
        fi
    else
        echo "服务未运行"
    fi
    exit 0
}

# 查看服务状态
show_status() {
    check_daemon_status
    if [ $? -eq 0 ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        echo ""
        echo "详细信息:"
        echo "  PID: $pid"
        echo "  日志文件: $LOG_FILE"
        echo "  目标主机: [${TARGET_HOSTS[*]}]"
        echo "  检查间隔: ${CHECK_INTERVAL}秒"
    fi
    exit 0
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -t|--targets)
                shift
                # 收集所有目标主机，直到遇到下一个选项或参数结束
                TARGET_HOSTS=()
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    TARGET_HOSTS+=("$1")
                    shift
                done
                ;;
            -l|--log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -o|--once)
                ONCE_MODE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -s|--stop)
                stop_daemon
                ;;
            -S|--status)
                show_status
                ;;
            *)
                echo "错误: 未知参数 '$1'" >&2
                echo "使用 -h 或 --help 查看帮助信息" >&2
                exit 1
                ;;
        esac
    done

    # 验证参数
    if [ ${#TARGET_HOSTS[@]} -eq 0 ]; then
        echo "错误: 至少需要指定一个目标主机" >&2
        exit 1
    fi

    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$CHECK_INTERVAL" -lt 1 ]; then
        echo "错误: 检查间隔必须是正整数" >&2
        exit 1
    fi
}

set -e

# 解析命令行参数
parse_arguments "$@"

# 检测操作系统
OS_TYPE=$(uname)

# 根据操作系统选择合适的命令
if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS: 使用 lsof
    if ! command -v lsof &> /dev/null; then
        echo "错误: 'lsof' 命令未找到。" >&2
        exit 1
    fi
    echo "使用 lsof 命令 (macOS)"
else
    # Linux: 使用 ss
    if ! command -v ss &> /dev/null; then
        echo "错误: 'ss' 命令未找到。请安装 'iproute2' 包。" >&2
        exit 1
    fi
    echo "使用 ss 命令 (Linux)"
fi

# 将目标数组转换成一个高效的grep正则表达式，例如 "google|github|47.110.177.14"
pattern=$(printf "|%s" "${TARGET_HOSTS[@]}")
pattern=${pattern:1} # 移除第一个'|'

# 显示配置信息
echo "==================== 网络连接监控 ===================="
echo "目标主机: [${TARGET_HOSTS[*]}]"
echo "日志文件: $LOG_FILE"
echo "检查间隔: ${CHECK_INTERVAL}秒"

if [ "$ONCE_MODE" = true ]; then
    echo "运行模式: 一次性检查"
else
    echo "运行模式: 后台运行"
fi

echo "操作系统: $OS_TYPE"
echo "===================================================="
echo ""

# 后台模式处理（默认，非一次性模式）
if [ "$ONCE_MODE" = false ]; then
    # 检查是否已有后台进程在运行
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "错误: 服务已在运行 (PID: $pid)"
            echo "如需重新启动，请先使用: $0 -s"
            exit 1
        else
            # PID 文件存在但进程不存在，清理 PID 文件
            rm -f "$PID_FILE"
        fi
    fi

    # 启动后台进程
    echo "启动后台服务..."

    # 保存当前 PID
    echo $$ > "$PID_FILE"

    # 重定向输出到日志文件
    exec >> "$LOG_FILE" 2>&1

    # 设置陷阱，确保退出时清理 PID 文件
    trap 'rm -f "$PID_FILE"; exit 0' EXIT TERM INT
fi

# 检查连接函数
check_connections() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local connections=""
    local all_connections=""

    # 根据操作系统获取TCP连接
    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: 使用 lsof
        all_connections=$(lsof -iTCP -sTCP:ESTABLISHED -n -P 2>/dev/null || true)
    else
        # Linux: 使用 ss
        all_connections=$(ss -tpno state established || true)
    fi

    # 筛选匹配的连接
    connections=$(echo "$all_connections" | grep -E "$pattern" || true)

    # 处理匹配的连接
    if [ -n "$connections" ]; then
        if [ "$ONCE_MODE" = true ] || [ "$VERBOSE_MODE" = true ]; then
            echo "--- [${timestamp}] 发现匹配连接 ---"
            echo "$connections"
            echo ""
        fi

        # 写入日志
        {
            echo "--- [${timestamp}] 发现匹配连接 ---"
            echo "$connections"
            echo ""
        } >> "$LOG_FILE"

        if [ "$ONCE_MODE" = false ] && [ "$VERBOSE_MODE" != true ]; then
            echo "[${timestamp}] 发现匹配连接，已记录到日志。"
        fi
    else
        if [ "$VERBOSE_MODE" = true ]; then
            echo "[${timestamp}] 未发现匹配连接"
        fi
    fi

    # 详细模式：显示所有TCP连接
    if [ "$VERBOSE_MODE" = true ] && [ -n "$all_connections" ]; then
        echo "--- [${timestamp}] 所有TCP连接 ---"
        echo "$all_connections"
        echo ""
    fi
}

# 执行检查
if [ "$ONCE_MODE" = true ]; then
    echo "执行一次性检查..."
    check_connections
    echo "检查完成。"
else
    echo "后台服务已启动，PID: $$"
    echo "日志文件: $LOG_FILE"
    echo "使用以下命令查看日志: tail -f $LOG_FILE"
    echo "使用以下命令停止服务: $0 -s"
    echo ""

    # 无限循环监控
    while true; do
        check_connections
        sleep "$CHECK_INTERVAL"
    done
fi

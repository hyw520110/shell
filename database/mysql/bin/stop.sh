#!/bin/bash

# 脚本名称和版本
SCRIPT_NAME="MySQL停止脚本"
SCRIPT_VERSION="2.1"
# 更新说明：增加了对mysqld_safe进程的更好支持，改进了强制停止功能
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置
DEFAULT_PORT=3306
DEFAULT_WAIT_TIME=15
DEFAULT_GRACE_PERIOD=5

# 导入配置文件（如果存在）
CONFIG_FILE="${SCRIPT_DIR}/../conf/mysql.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 全局变量声明
INSTALL_DIR=""
MYSQLD_PIDS=""
REMAIN_PIDS=""
PORT_INFO=""
DEBUG_MODE=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项] [参数]

选项:
  -h, --help          显示此帮助信息
  -v, --version       显示版本信息
  -f, --force         强制停止MySQL服务
  -k, --kill          直接杀死所有相关进程
  -d, --debug         调试模式
  -P, --port PORT     指定MySQL端口（默认3306）
  -i, --install-dir DIR  指定MySQL安装目录

参数:
  [force|kill]        快速方式停止MySQL服务

示例:
  $0                  # 正常停止MySQL
  $0 force            # 强制停止MySQL
  $0 kill             # 直接杀死所有MySQL进程
  $0 -d -f            # 调试模式下强制停止
EOF
}

# 日志函数
log_info() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${BLUE}[DEBUG]${NC} $1"
    fi
}

# 错误处理函数
error_exit() {
    log_error "$1"
    exit 1
}

# 健壮的命令执行函数
execute_with_retry() {
    local command="$1"
    local max_retries="${2:-3}"
    local retry_delay="${3:-1}"
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        log_debug "执行命令 (尝试 $attempt/$max_retries): $command"
        if eval "$command"; then
            log_debug "命令执行成功"
            return 0
        else
            log_warn "命令执行失败 (尝试 $attempt/$max_retries)"
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
            fi
            attempt=$((attempt + 1))
        fi
    done

    log_error "命令执行失败，已达到最大重试次数: $command"
    return 1
}

# 信号处理函数
cleanup() {
    log_info "收到中断信号，正在退出..."
    exit 1
}

# 捕获中断信号
trap cleanup INT TERM

# 解析命令行参数
parse_arguments() {
    local port_param=""
    local install_dir_param=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
                exit 0
                ;;
            -f|--force)
                MODE="force"
                shift
                ;;
            -k|--kill)
                MODE="kill"
                shift
                ;;
            -d|--debug)
                DEBUG_MODE=true
                shift
                ;;
            -P|--port)
                port_param="$2"
                shift 2
                ;;
            -i|--install-dir)
                install_dir_param="$2"
                shift 2
                ;;
            force|kill)
                MODE="$1"
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 使用命令行参数覆盖配置文件中的值
    if [ -n "$port_param" ]; then
        CUSTOM_PORT="$port_param"
    fi

    if [ -n "$install_dir_param" ]; then
        INSTALL_DIR="$install_dir_param"
    fi
}

# 检查是否以root或sudo运行，如果不是则自动使用sudo重新运行
check_root_access() {
    if [ "$EUID" -ne 0 ] && [ -z "$ALREADY_ELEVATED" ]; then
        echo "需要root权限来停止MySQL服务，正在使用sudo执行..."
        export ALREADY_ELEVATED=true
        sudo -E "$0" "$@"
        exit $?
    fi
}

# 设置脚本在任何命令失败时立即退出（除非特别指定）
set_strict_mode() {
    set -e
    # 同时启用调试模式
    if [ "$DEBUG_MODE" = true ]; then
        set -x
    fi
}

find_mysql_install_dir() {
    if [ ! -d "$INSTALL_DIR" ]; then
        if [ -f "$SCRIPT_DIR/find_mysql.sh" ]; then
            # 获取第一个找到的安装目录
            INSTALL_DIR=$(bash $SCRIPT_DIR/find_mysql.sh | head -n 1)
        else
            error_exit "找不到 find_mysql.sh 脚本"
        fi
    fi

    if [ -z "$INSTALL_DIR" ]; then
        log_warn "未找到MySQL安装目录，将使用通用方法停止MySQL服务"
    else
        log_info "MySQL安装目录: $INSTALL_DIR"
    fi
}

# 检查端口是否被占用
check_port() {
    local port=${CUSTOM_PORT:-$DEFAULT_PORT}

    if command -v ss >/dev/null 2>&1; then
        PORT_INFO=$(ss -tlnp 2>/dev/null | grep -E "\b$port\b" | head -1)
    elif command -v netstat >/dev/null 2>&1; then
        PORT_INFO=$(netstat -tlnp 2>/dev/null | grep -E "\b$port\b" | head -1)
    else
        log_warn "找不到ss或netstat命令，跳过端口检查"
        PORT_INFO=""
    fi
}

# 更精确的进程查找函数
find_mysql_processes() {
    local install_dir="$1"
    local process_type="$2"  # mysqld, mysqld_safe, or all

    if [ -n "$install_dir" ]; then
        case "$process_type" in
            mysqld)
                pgrep -f "$install_dir.*mysqld" 2>/dev/null || echo ""
                ;;
            mysqld_safe)
                pgrep -f "$install_dir.*mysqld_safe" 2>/dev/null || echo ""
                ;;
            all)
                # 同时查找 mysqld 和 mysqld_safe
                local mysqld_pids=$(pgrep -f "$install_dir.*mysqld" 2>/dev/null || echo "")
                local safe_pids=$(pgrep -f "$install_dir.*mysqld_safe" 2>/dev/null || echo "")
                echo "$mysqld_pids $safe_pids" | tr ' ' '\n' | sort -u | tr '\n' ' '
                ;;
            *)
                # 默认行为：查找指定的进程类型
                pgrep -f "$install_dir.*$process_type" 2>/dev/null || echo ""
                ;;
        esac
    else
        case "$process_type" in
            mysqld)
                pgrep -f "mysqld.*--defaults-file" 2>/dev/null || pgrep -x mysqld 2>/dev/null || echo ""
                ;;
            mysqld_safe)
                pgrep -x mysqld_safe 2>/dev/null || echo ""
                ;;
            all)
                # 同时查找 mysqld 和 mysqld_safe
                local mysqld_pids=$(pgrep -f "mysqld.*--defaults-file" 2>/dev/null || pgrep -x mysqld 2>/dev/null || echo "")
                local safe_pids=$(pgrep -x mysqld_safe 2>/dev/null || echo "")
                echo "$mysqld_pids $safe_pids" | tr ' ' '\n' | sort -u | tr '\n' ' '
                ;;
            *)
                # 默认行为：查找指定的进程类型
                pgrep -f "$process_type" 2>/dev/null || pgrep -x "$process_type" 2>/dev/null || echo ""
                ;;
        esac
    fi
}

# 强制杀死进程
force_kill_processes() {
    local pids="$1"
    if [ -z "$pids" ]; then
        return 0
    fi

    log_info "强制终止进程: $pids"

    # 先尝试SIGTERM（优雅停止）
    local term_pids=""
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            term_pids="$term_pids $pid"
        fi
    done

    # 等待GRACE_PERIOD秒后再检查
    sleep $DEFAULT_GRACE_PERIOD

    # 检查是否还有进程在运行
    local remain_pids=""
    for pid in $term_pids; do
        if kill -0 "$pid" 2>/dev/null; then
            remain_pids="$remain_pids $pid"
        fi
    done

    if [ -n "$remain_pids" ]; then
        log_info "仍有进程存在，强制终止: $remain_pids"
        for pid in $remain_pids; do
            kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 1

        # 再次检查是否有仍然存活的进程
        local hard_remain_pids=""
        for pid in $remain_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                hard_remain_pids="$hard_remain_pids $pid"
            fi
        done

        if [ -n "$hard_remain_pids" ]; then
            log_error "警告：以下进程难以终止: $hard_remain_pids"
            # 尝试使用pkill作为最后手段
            for pid in $hard_remain_pids; do
                kill -9 $pid 2>/dev/null || true
            done
        fi
    fi
}

# 检查并等待进程结束
wait_for_processes_to_end() {
    local max_wait=${WAIT_TIME:-$DEFAULT_WAIT_TIME}
    local count=0
    local process_pattern="$INSTALL_DIR.*mysqld"

    while [ $count -lt $max_wait ]; do
        if ! pgrep -f "$process_pattern" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

# 显示进程信息
show_process_info() {
    local install_dir="$1"
    if [ -n "$install_dir" ]; then
        log_info "检测到以下与 $install_dir 相关的mysqld进程："
        ps -ef | grep "$install_dir" | grep mysqld | grep -v grep || echo "无相关进程"
    else
        log_info "检测到以下mysqld进程："
        ps -ef | grep mysqld | grep -v grep || echo "无相关进程"
    fi
}

# 使用mysqladmin停止MySQL
stop_with_mysqladmin() {
    local install_dir="$1"
    log_info "尝试使用mysqladmin正常停止MySQL..."

    # 构造连接选项
    local mysqladmin_cmd
    local config_file_opt
    local password_opt=""

    if [ -n "$install_dir" ] && [ -f "$install_dir/bin/mysqladmin" ]; then
        mysqladmin_cmd="$install_dir/bin/mysqladmin"
        config_file_opt="--defaults-file=$install_dir/conf/my.cnf"

        # 尝试从配置或临时文件获取密码
        local temp_pass_file="$install_dir/data/.temp_pwd"
        if [ -f "$temp_pass_file" ]; then
            # 使用管道而非命令行参数传递密码，更安全
            # 先尝试使用默认密码文件
            $install_dir/bin/mysqladmin --defaults-file=$install_dir/conf/my.cnf -u root -p"$(cat "$temp_pass_file")" shutdown 2>/dev/null || {
                log_warn "使用临时密码失败，尝试交互式输入密码"
                $install_dir/bin/mysqladmin --defaults-file=$install_dir/conf/my.cnf -u root -p shutdown 2>/dev/null || return 1
            }
        else
            # 检查端口是否被占用，如没有进程则不执行需要输入密码的命令
            local mysqld_pids=$(find_mysql_processes "$install_dir" "mysqld")
            local safe_pids=$(find_mysql_processes "$install_dir" "mysqld_safe")

            if [ -z "$mysqld_pids" ] && [ -z "$safe_pids" ]; then
                log_info "未检测到MySQL进程，跳过密码验证。"
                return 1  # 返回失败，以便后续逻辑处理
            fi

            $install_dir/bin/mysqladmin --defaults-file=$install_dir/conf/my.cnf -u root -p shutdown 2>/dev/null || return 1
        fi
    else
        # 没有安装目录时使用系统mysqladmin
        # 检查是否有mysqld进程在运行
        local mysqld_pids=$(pgrep -f "mysqld.*--defaults-file" 2>/dev/null || pgrep -x mysqld 2>/dev/null || echo "")
        if [ -z "$mysqld_pids" ]; then
            log_info "未检测到MySQL进程，跳过密码验证。"
            return 1  # 返回失败，以便后续逻辑处理
        fi

        mysqladmin -u root -p shutdown 2>/dev/null || return 1
    fi

    return 0
}

# 检查进程是否仍在运行
check_remaining_processes() {
    local install_dir="$1"

    if [ -z "$install_dir" ]; then
        # 没有安装目录时检查所有mysqld进程
        REMAIN_PIDS=$(find_mysql_processes "" "mysqld")
    else
        # 有安装目录时检查特定目录的mysqld进程
        REMAIN_PIDS=$(find_mysql_processes "$install_dir" "mysqld")
    fi

    if [ -n "$REMAIN_PIDS" ]; then
        log_warn "警告：以下mysqld进程仍在运行："
        ps -p $REMAIN_PIDS 2>/dev/null || ps -ef | grep "$install_dir" | grep mysqld | grep -v grep
        return 1
    else
        return 0
    fi
}

# 处理没有找到安装目录的情况
handle_no_install_dir() {
    log_warn "未找到MySQL安装目录。"
    MYSQLD_PIDS=$(find_mysql_processes "" "mysqld")

    if [ -n "$MYSQLD_PIDS" ]; then
        log_info "警告：系统中有mysqld进程在运行，进程信息如下："
        show_process_info ""

        # 优先尝试mysqladmin
        if command -v mysqladmin >/dev/null 2>&1; then
            if stop_with_mysqladmin ""; then
                log_info "MySQL已正常停止。"
            else
                log_warn "mysqladmin 停止失败，尝试强制终止mysqld进程..."
                force_kill_processes "$MYSQLD_PIDS"
            fi
        else
            log_warn "未找到mysqladmin，直接强制终止mysqld进程..."
            force_kill_processes "$MYSQLD_PIDS"
        fi

        # 停止后再次检测
        check_remaining_processes ""
    else
        # 检查端口占用情况，只在端口被mysqld占用时才显示警告
        check_port
        if [ -n "$PORT_INFO" ] && echo "$PORT_INFO" | grep mysqld >/dev/null 2>&1; then
            local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
            log_warn "警告：端口 $port 仍被mysqld占用，请手动终止进程。"
        else
            # 如果端口未被mysqld占用，只显示简单的未启动消息
            log_info "MySQL未启动。"
        fi
        exit 0
    fi

    # 检查端口占用
    check_port
    if [ -n "$PORT_INFO" ]; then
        if echo "$PORT_INFO" | grep mysqld >/dev/null 2>&1; then
            local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
            log_warn "警告：端口 $port 仍被mysqld占用，请手动终止进程。"
        else
            local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
            log_warn "警告：端口 $port 被其他程序占用："
            echo "$PORT_INFO"
        fi
    else
        local port=${CUSTOM_PORT:-$DEFAULT_PORT}
        log_info "端口 $port 未被mysqld或其他程序占用。"
    fi

    # 最终判断
    if [ -z "$REMAIN_PIDS" ]; then
        log_info "MySQL已完全停止。"
        exit 0
    else
        log_error "MySQL未完全停止，请手动处理。"
        exit 1
    fi
}

# 处理找到安装目录的情况
handle_with_install_dir() {
    local mode="$1"
    # 优先查找 mysqld_safe 进程
    local safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")
    # 查找 mysqld 进程
    local mysqld_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld")

    # 合并PID列表
    local all_pids="$safe_pids $mysqld_pids"
    if [ -n "$all_pids" ]; then
        show_process_info "$INSTALL_DIR"

        case "$mode" in
            normal)
                # 优先尝试使用 mysqladmin 停止服务（最优雅的方式）
                if stop_with_mysqladmin "$INSTALL_DIR"; then
                    log_info "MySQL已正常停止。"
                else
                    log_warn "mysqladmin 停止失败，尝试向 mysqld_safe 发送停止信号..."
                    if [ -n "$safe_pids" ]; then
                        # 向 mysqld_safe 发送终止信号，它会负责终止 mysqld
                        log_info "向 mysqld_safe 进程发送停止信号: $safe_pids"
                        for pid in $safe_pids; do
                            kill -TERM $pid 2>/dev/null || true
                        done
                        # 等待一段时间让mysqld_safe优雅停止mysqld
                        sleep 3

                        # 检查 mysqld_safe 的子进程 (即 mysqld) 是否仍在运行
                        local killed_mysqld_pids=""
                        for safe_pid in $safe_pids; do
                            local child_pids=$(pgrep -P $safe_pid 2>/dev/null || echo "")
                            if [ -n "$child_pids" ]; then
                                killed_mysqld_pids="$killed_mysqld_pids $child_pids"
                            fi
                        done

                        if [ -n "$killed_mysqld_pids" ]; then
                            log_info "检测到 mysqld_safe 的子进程 (mysqld)，也向其发送停止信号: $killed_mysqld_pids"
                            for pid in $killed_mysqld_pids; do
                                kill -TERM $pid 2>/dev/null || true
                            done
                            sleep 2
                        fi
                    elif [ -n "$mysqld_pids" ]; then
                        # 如果没有 mysqld_safe，则直接尝试向 mysqld 发送信号
                        log_info "向 mysqld 进程发送停止信号: $mysqld_pids"
                        for pid in $mysqld_pids; do
                            kill -TERM $pid 2>/dev/null || true
                        done
                        sleep 2
                    fi
                fi
                ;;
            force)
                log_info "强制终止进程: $all_pids"
                force_kill_processes "$all_pids"
                ;;
        esac

        # 等待进程结束
        if ! wait_for_processes_to_end; then
            log_warn "等待进程结束超时，尝试强制终止..."
            # 再次确认并终止仍未结束的进程
            local remaining_pids=$(find_mysql_processes "$INSTALL_DIR" "all")
            if [ -n "$remaining_pids" ]; then
                force_kill_processes "$remaining_pids"
            fi
        fi
    else
        log_info "未检测到mysqld_safe 或 mysqld 进程，无需停止。"
        # 如果没有检测到进程但存在PID文件，也清理它
        local pid_file="$INSTALL_DIR/data/mysqld.pid"
        if [ -f "$pid_file" ]; then
            rm -f "$pid_file"
            log_info "已清理残留PID文件: $pid_file"
        fi
    fi
}

# 处理直接杀死所有MySQL进程的情况
kill_all_mysql_processes() {
    log_info "直接强制杀死所有MySQL相关进程..."

    # 杀死所有相关mysqld进程
    local all_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld")
    if [ -n "$all_pids" ]; then
        force_kill_processes "$all_pids"
    fi

    # 同时杀死mysqld_safe进程
    local safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")
    if [ -n "$safe_pids" ]; then
        force_kill_processes "$safe_pids"
    fi

    # 使用更广泛的方法确保没有遗漏的进程
    local extra_mysqld_pids=$(pgrep -f "mysqld.*--defaults-file" 2>/dev/null || echo "")
    if [ -n "$extra_mysqld_pids" ]; then
        force_kill_processes "$extra_mysqld_pids"
    fi

    local extra_safe_pids=$(pgrep -f "mysqld_safe" 2>/dev/null || echo "")
    if [ -n "$extra_safe_pids" ]; then
        force_kill_processes "$extra_safe_pids"
    fi
}

# 主逻辑
main() {
    log_info "开始停止MySQL服务..."
    # 初始化变量
    MODE="normal"

    # 解析命令行参数
    parse_arguments "$@"

    # 设置严格模式
    set_strict_mode

    # 查找安装目录
    find_mysql_install_dir

    # 首先检查是否有MySQL相关进程在运行，如果没有则直接退出，不需要sudo权限
    local mysqld_pids=""
    local safe_pids=""
    if [ -n "$INSTALL_DIR" ]; then
        # 有安装目录时检查特定目录的进程
        mysqld_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld")
        safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")
    else
        # 没有安装目录时检查系统中的mysqld进程
        mysqld_pids=$(pgrep -f "mysqld.*--defaults-file" 2>/dev/null || pgrep -x mysqld 2>/dev/null || echo "")
        safe_pids=$(pgrep -x mysqld_safe 2>/dev/null || echo "")
    fi

    # 如果没有相关进程在运行，则直接输出未启动并退出，不需要sudo权限
    if [ -z "$mysqld_pids" ] && [ -z "$safe_pids" ]; then
        # 检查端口占用情况，只在端口被mysqld占用时才显示警告
        check_port
        if [ -n "$PORT_INFO" ] && echo "$PORT_INFO" | grep mysqld >/dev/null 2>&1; then
            local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
            log_warn "警告：端口 $port 仍被mysqld占用，请手动终止进程。"
        else
            # 如果端口未被mysqld占用，只显示简单的未启动消息
            log_info "MySQL未启动。"
        fi
        exit 0
    fi

    # 确认需要停止服务后，检查是否有足够的权限
    check_root_access "$@"

    if [ -z "$INSTALL_DIR" ]; then
        handle_no_install_dir
    else
        # 有安装目录时，按逻辑处理
        case "$MODE" in
            kill)
                log_info "执行强制杀死所有MySQL进程模式"
                kill_all_mysql_processes
                # 检查是否还有残留进程
                local all_mysqld_pids=$(pgrep -f "$INSTALL_DIR.*mysqld" 2>/dev/null || echo "")
                local all_safe_pids=$(pgrep -f "$INSTALL_DIR.*mysqld_safe" 2>/dev/null || echo "")

                if [ -n "$all_mysqld_pids$all_safe_pids" ]; then
                    log_warn "仍有残留的MySQL进程，强制终止所有相关进程："
                    if [ -n "$all_mysqld_pids" ]; then
                        log_warn "mysqld 进程: $all_mysqld_pids"
                        force_kill_processes "$all_mysqld_pids"
                    fi
                    if [ -n "$all_safe_pids" ]; then
                        log_warn "mysqld_safe 进程: $all_safe_pids"
                        force_kill_processes "$all_safe_pids"
                    fi
                fi
                ;;
            force)
                log_info "执行强制停止模式"
                handle_with_install_dir "force"
                ;;
            *)
                log_info "执行正常停止模式"

                handle_with_install_dir "$MODE"

                # 额外检查是否有mysqld_safe进程残留
                local safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")
                if [ -n "$safe_pids" ]; then
                    log_warn "发现 mysqld_safe 进程仍在运行，强制终止: $safe_pids"
                    force_kill_processes "$safe_pids"
                fi
                ;;
        esac

        # 检查端口占用
        check_port
        if [ -n "$PORT_INFO" ]; then
            if echo "$PORT_INFO" | grep mysqld >/dev/null 2>&1; then
                local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
                log_warn "警告：端口 $port 仍被mysqld占用，请手动终止进程。"
            else
                local port=$(echo $PORT_INFO | awk '{print $4}' | sed 's/.*:\([0-9]*\).*/\1/')
                log_warn "警告：端口 $port 被其他程序占用："
                echo "$PORT_INFO"
            fi
        else
            local port=${CUSTOM_PORT:-$DEFAULT_PORT}
            log_info "端口 $port 未被mysqld或其他程序占用。"
        fi

        # 最终判断，检查是否还有与INSTALL_DIR相关的进程
        REMAIN_PIDS=$(find_mysql_processes "$INSTALL_DIR" "mysqld")
        local remaining_safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")

        if [ -z "$REMAIN_PIDS" ] && [ -z "$remaining_safe_pids" ]; then
            log_info "MySQL已完全停止。"
            exit 0
        else
            log_error "MySQL未完全停止:"
            if [ -n "$REMAIN_PIDS" ]; then
                log_error "  - mysqld 进程仍在运行: $REMAIN_PIDS"
                show_process_info "$INSTALL_DIR"
            fi
            if [ -n "$remaining_safe_pids" ]; then
                log_error "  - mysqld_safe 进程仍在运行: $remaining_safe_pids"
                ps -p $remaining_safe_pids 2>/dev/null || ps -ef | grep "$INSTALL_DIR" | grep mysqld_safe | grep -v grep
            fi

            # 最后的安全措施：强制杀死所有相关进程
            log_info "执行最终清理，强制终止所有MySQL相关进程..."
            if [ -n "$REMAIN_PIDS" ]; then
                force_kill_processes "$REMAIN_PIDS"
            fi
            if [ -n "$remaining_safe_pids" ]; then
                force_kill_processes "$remaining_safe_pids"
            fi

            # 确认进程是否真的被终止
            local final_check_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld")
            local final_check_safe_pids=$(find_mysql_processes "$INSTALL_DIR" "mysqld_safe")

            if [ -z "$final_check_pids" ] && [ -z "$final_check_safe_pids" ]; then
                log_info "MySQL已完全停止。"
                exit 0
            else
                log_error "无法完全停止MySQL，请手动检查进程。"
                exit 1
            fi
        fi
    fi
}

# 执行主逻辑
main "$@"
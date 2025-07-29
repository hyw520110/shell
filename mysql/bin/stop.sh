#!/bin/bash
# MySQL停止脚本

# 检查是否以root或sudo运行，如果不是则自动使用sudo重新运行
if [ "$EUID" -ne 0 ] && [ -z "$ALREADY_ELEVATED" ]; then
  echo "需要root权限来停止MySQL服务，正在使用sudo执行..."
  export ALREADY_ELEVATED=true
  sudo -E "$0" "$@"
  exit $?
fi

# 设置脚本在任何命令失败时立即退出
set -e

# 全局变量声明
SCRIPT_DIR=""
INSTALL_DIR=""
MYSQLD_PIDS=""
REMAIN_PIDS=""
port_info=""

# 日志函数
log_info() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [INFO] $1"
}

log_warn() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] $1"
}

log_error() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR] $1" >&2
}

# 错误处理函数
error_exit() {
    log_error "$1"
    exit 1
}

# 信号处理函数
cleanup() {
    log_info "收到中断信号，正在退出..."
    exit 1
}

# 捕获中断信号
trap cleanup INT TERM

# 获取脚本目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 查找MySQL安装目录
if [ -f "$SCRIPT_DIR/find_mysql.sh" ]; then
    INSTALL_DIR="$(bash "$SCRIPT_DIR/find_mysql.sh" "$1")"
else
    error_exit "找不到 find_mysql.sh 脚本"
fi

# 检查端口是否被占用
check_port() {
    local port=3306
    if command -v netstat >/dev/null 2>&1; then
        port_info=$(netstat -tlnp 2>/dev/null | grep ":$port" | head -1)
    elif command -v ss >/dev/null 2>&1; then
        port_info=$(ss -tlnp 2>/dev/null | grep ":$port" | head -1)
    else
        port_info=""
    fi
}

# 强制杀死进程
force_kill_processes() {
    local pids="$1"
    if [ -n "$pids" ]; then
        log_info "强制终止进程: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 2
    fi
}

# 检查并等待进程结束
wait_for_processes_to_end() {
    local max_wait=10
    local count=0
    
    while [ $count -lt $max_wait ]; do
        if ! pgrep -f "$INSTALL_DIR.*mysqld" > /dev/null 2>&1; then
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
    log_info "检测到以下mysqld进程："
    ps -ef | grep "$install_dir" | grep mysqld | grep -v grep || true
}

# 使用mysqladmin停止MySQL
stop_with_mysqladmin() {
    local install_dir="$1"
    log_info "尝试使用mysqladmin正常停止MySQL..."
    
    if [ -z "$install_dir" ]; then
        # 没有安装目录时使用系统mysqladmin
        mysqladmin -uroot -p shutdown 2>/dev/null || return 1
    else
        # 有安装目录时使用指定的mysqladmin
        $install_dir/bin/mysqladmin --defaults-file=$install_dir/conf/my.cnf -uroot -p shutdown 2>/dev/null || return 1
    fi
    
    return 0
}

# 检查进程是否仍在运行
check_remaining_processes() {
    local install_dir="$1"
    if [ -z "$install_dir" ]; then
        # 没有安装目录时检查所有mysqld进程
        REMAIN_PIDS=$(pgrep -f mysqld 2>/dev/null || true)
    else
        # 有安装目录时检查特定目录的mysqld进程
        REMAIN_PIDS=$(ps -ef | grep "$install_dir" | grep mysqld | grep -v grep | awk '{print $2}' 2>/dev/null || true)
    fi
    
    if [ -n "$REMAIN_PIDS" ]; then
        log_warn "警告：以下mysqld进程仍在运行："
        ps -ef | grep "$install_dir" | grep mysqld | grep -v grep || true
        return 1
    else
        log_info "mysqld进程已全部终止。"
        return 0
    fi
}

# 处理没有找到安装目录的情况
handle_no_install_dir() {
    log_warn "未找到MySQL安装目录。"
    MYSQLD_PIDS=$(pgrep -f mysqld 2>/dev/null || true)
    
    if [ -n "$MYSQLD_PIDS" ]; then
        log_info "警告：系统中有mysqld进程在运行，进程信息如下："
        ps -ef | grep mysqld | grep -v grep || true
        
        # 优先尝试mysqladmin
        if command -v mysqladmin >/dev/null 2>&1; then
            if stop_with_mysqladmin ""; then
                log_info "MySQL已正常停止。"
            else
                log_warn "mysqladmin 停止失败，尝试强制kill mysqld进程..."
                force_kill_processes "$MYSQLD_PIDS"
            fi
        else
            log_warn "未找到mysqladmin，直接强制kill mysqld进程..."
            force_kill_processes "$MYSQLD_PIDS"
        fi
        
        # 停止后再次检测
        check_remaining_processes ""
    else
        log_info "未检测到mysqld进程。"
    fi
    
    # 检查3306端口占用
    check_port
    if [ -n "$port_info" ]; then
        if echo "$port_info" | grep mysqld >/dev/null 2>&1; then
            log_warn "警告：3306端口仍被mysqld占用，请手动kill进程。"
        else
            log_warn "警告：3306端口被其他程序占用："
            echo "$port_info"
        fi
    else
        log_info "3306端口未被mysqld或其他程序占用。"
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
    local force_mode="$1"
    MYSQLD_PIDS=$(ps -ef | grep "$INSTALL_DIR" | grep mysqld | grep -v grep | awk '{print $2}' 2>/dev/null || true)
    
    if [ -n "$MYSQLD_PIDS" ]; then
        show_process_info "$INSTALL_DIR"
        
        if [ "$force_mode" != "force" ]; then
            if stop_with_mysqladmin "$INSTALL_DIR"; then
                log_info "MySQL已正常停止。"
                # 等待 mysqld_safe 进程结束
                if ! wait_for_processes_to_end; then
                    log_warn "等待进程结束超时，尝试强制终止..."
                    force_kill_processes "$MYSQLD_PIDS"
                else
                    log_info "mysqld_safe 进程已正常退出。"
                fi
            else
                log_warn "mysqladmin 停止失败，尝试强制kill mysqld进程..."
                force_kill_processes "$MYSQLD_PIDS"
            fi
        else
            log_info "强制kill进程: $MYSQLD_PIDS"
            force_kill_processes "$MYSQLD_PIDS"
        fi
        
        # 再次检查并杀死可能残留的 mysqld_safe 进程
        check_remaining_processes "$INSTALL_DIR"
        if [ -n "$REMAIN_PIDS" ]; then
            log_warn "警告：以下mysqld进程仍在运行，强制终止："
            ps -ef | grep "$INSTALL_DIR" | grep mysqld | grep -v grep || true
            force_kill_processes "$REMAIN_PIDS"
        fi
    else
        log_info "未检测到mysqld进程，无需停止。"
    fi
}

# 主逻辑
main() {
    if [ -z "$INSTALL_DIR" ]; then
        handle_no_install_dir
    else
        # 有安装目录时，按原逻辑处理
        if [ "" == "$1" ]; then
            handle_with_install_dir "normal"
        else
            handle_with_install_dir "force"
        fi
        
        # 检查3306端口占用
        check_port
        if [ -n "$port_info" ]; then
            if echo "$port_info" | grep mysqld >/dev/null 2>&1; then
                log_warn "警告：3306端口仍被mysqld占用，请手动kill进程。"
            else
                log_warn "警告：3306端口被其他程序占用："
                echo "$port_info"
            fi
        else
            log_info "3306端口未被mysqld或其他程序占用。"
        fi

        # 最终判断，检查是否还有与INSTALL_DIR相关的进程
        REMAIN_PIDS=$(ps -ef | grep "$INSTALL_DIR" | grep mysqld | grep -v grep | awk '{print $2}' 2>/dev/null || true)
        if [ -z "$REMAIN_PIDS" ]; then
            log_info "MySQL已完全停止。"
            exit 0
        else
            log_warn "MySQL未完全停止，强制终止残留进程。"
            ps -ef | grep "$INSTALL_DIR" | grep mysqld | grep -v grep || true
            force_kill_processes "$REMAIN_PIDS"
            exit 0
        fi
    fi
}

# 执行主逻辑
main "$@"
#!/bin/bash

# ActiveMQ停止脚本
# 支持Linux和MacOS系统

# 公共变量
DEFAULT_INSTALL_DIR_LINUX="$HOME/activemq"
DEFAULT_INSTALL_DIR_MACOS="$HOME/activemq"
DEFAULT_LOG_LEVEL="INFO"

# 运行时变量
INSTALL_DIR=""
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
FORCE_KILL=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印使用说明
print_usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -d, --dir PATH     指定安装目录（默认Linux: $DEFAULT_INSTALL_DIR_LINUX, MacOS: $DEFAULT_INSTALL_DIR_MACOS）"
    echo "  --log-level LEVEL  设置日志级别 (DEBUG, INFO, WARN, ERROR)（默认: $DEFAULT_LOG_LEVEL）"
    echo "  -f, --force        强制结束相关进程（跳过脚本优雅停止）"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认目录停止（不报错退出）"
    echo "  $0 -d /opt/activemq                  # 指定安装目录停止"
    echo "  $0 --log-level DEBUG                 # 设置日志级别为DEBUG"
    echo "  $0 --force                           # 强制结束进程"
}

# 通用日志函数
log_message() {
    local level=$1
    local message=$2
    local color=""
    case "$LOG_LEVEL" in
        DEBUG) ;;
        INFO) [[ "$level" != "DEBUG" ]] || return ;;
        WARN) [[ "$level" == "WARN" || "$level" == "ERROR" ]] || return ;;
        ERROR) [[ "$level" == "ERROR" ]] || return ;;
        *) ;;
    esac
    case "$level" in
        DEBUG|INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
    esac
    if [[ -t 1 ]]; then
        echo -e "${color}[$level]${NC} $message" >&2
    else
        echo "[$level] $message" >&2
    fi
}
log_debug() { log_message "DEBUG" "$1"; }
log_info() { log_message "INFO" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                INSTALL_DIR="$2"; shift 2 ;;
            --log-level)
                LOG_LEVEL="$2"; shift 2 ;;
            -f|--force)
                FORCE_KILL=true; shift 1 ;;
            -h|--help)
                print_usage; exit 0 ;;
            *)
                log_error "未知参数: $1"; print_usage; exit 1 ;;
        esac
    done
    if [[ -z "$INSTALL_DIR" ]]; then
        case "$(uname -s)" in
            Linux*) INSTALL_DIR="$DEFAULT_INSTALL_DIR_LINUX" ;;
            Darwin*) INSTALL_DIR="$DEFAULT_INSTALL_DIR_MACOS" ;;
            *) log_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
        esac
        log_debug "使用默认安装目录: $INSTALL_DIR"
    fi
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *) log_error "无效的日志级别: $LOG_LEVEL (有效值: DEBUG, INFO, WARN, ERROR)"; exit 1 ;;
    esac
}

# 检测操作系统类型
detect_os() {
    case "$(uname -s)" in
        Linux*) OS=Linux ;;
        Darwin*) OS=MacOS ;;
        *) log_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac
    log_debug "检测到操作系统: $OS"
    log_debug "安装目录: $INSTALL_DIR"
}

# 收集可能的ActiveMQ相关进程PID（通过命令行和端口）
collect_pids() {
    local pids_cmd=""
    local pids_ports=""
    pids_cmd=$(pgrep -f "activemq.jar|org.apache.activemq|ActiveMQ" 2>/dev/null || true)
    if command -v ss &> /dev/null; then
        pids_ports=$(ss -tlnp 2>/dev/null | grep -E ":61616|:8161" | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | tr '\n' ' ')
    elif command -v lsof &> /dev/null; then
        pids_ports=$( (lsof -i:61616 -t 2>/dev/null; lsof -i:8161 -t 2>/dev/null) | tr '\n' ' ')
    fi
    echo "$pids_cmd $pids_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' '
}

# 停止ActiveMQ服务
stop_activemq() {
    log_info "停止ActiveMQ服务"
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "未在 $INSTALL_DIR 找到ActiveMQ安装目录，可能服务未安装或已卸载"; return 0
    fi
    if [[ ! -d "$INSTALL_DIR/bin" ]]; then
        log_warn "未在 $INSTALL_DIR 找到bin目录，可能服务未安装或已卸载"; return 0
    fi
    if [[ ! -f "$INSTALL_DIR/bin/activemq" ]]; then
        log_warn "未在 $INSTALL_DIR/bin 找到activemq脚本，可能服务未安装或已卸载"; return 0
    fi

    if [[ "$FORCE_KILL" == "true" ]]; then
        log_info "强制模式：跳过优雅停止，直接终止进程"
    else
        if [[ -f "$INSTALL_DIR/data/activemq.pid" ]]; then
            PID=$(tr -d '\r\n' < "$INSTALL_DIR/data/activemq.pid" 2>/dev/null)
            if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
                log_info "检测到ActiveMQ运行 (PID: $PID)，正在停止"
                "$INSTALL_DIR/bin/activemq" stop 2>/dev/null || sudo -S "$INSTALL_DIR/bin/activemq" stop 2>/dev/null || true
                sleep 5
            else
                log_info "PID文件存在但进程未运行"
            fi
        else
            log_debug "未找到PID文件，尝试直接停止"
            "$INSTALL_DIR/bin/activemq" stop 2>/dev/null || sudo -S "$INSTALL_DIR/bin/activemq" stop 2>/dev/null || true
            sleep 5
        fi
    fi

    PIDS=$(collect_pids)
    if [[ -n "$PIDS" ]]; then
        if [[ "$FORCE_KILL" == "true" ]]; then
            log_warn "强制模式：直接强制终止进程: $PIDS"
            kill -9 $PIDS 2>/dev/null || sudo -S kill -9 $PIDS 2>/dev/null || true
        else
            log_debug "终止ActiveMQ相关进程: $PIDS"
            kill $PIDS 2>/dev/null || sudo -S kill $PIDS 2>/dev/null || true
            sleep 3
            PIDS=$(collect_pids)
            if [[ -n "$PIDS" ]]; then
                log_debug "强制终止ActiveMQ相关进程: $PIDS"
                kill -9 $PIDS 2>/dev/null || sudo -S kill -9 $PIDS 2>/dev/null || true
            fi
        fi
    else
        log_debug "未找到ActiveMQ相关进程"
    fi

    if [[ "$OS" == "Linux" ]]; then
        if systemctl is-active --quiet activemq 2>/dev/null; then
            log_debug "检测到systemd服务，正在停止"
            sudo -S systemctl stop activemq 2>/dev/null || true
        fi
    fi
    log_info "停止完成"
}

# 验证停止状态
verify_stop() {
    log_debug "验证停止状态"
    if [[ -f "$INSTALL_DIR/data/activemq.pid" ]]; then
        PID=$(tr -d '\r\n' < "$INSTALL_DIR/data/activemq.pid" 2>/dev/null)
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            log_warn "检测到ActiveMQ进程仍在运行 (PID: $PID)"; return 1
        else
            log_debug "PID文件存在但进程已停止"; rm -f "$INSTALL_DIR/data/activemq.pid" 2>/dev/null || true
        fi
    else
        log_debug "未找到PID文件"
    fi
    PIDS=$(collect_pids)
    if [[ -n "$PIDS" ]]; then
        log_warn "仍检测到ActiveMQ相关进程: $PIDS"; return 1
    else
        log_debug "未检测到相关进程"
    fi
    if command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":61616\|:8161"; then
            log_warn "检测到ActiveMQ相关端口仍在监听"
            ss -tlnp 2>/dev/null | grep ":61616\|:8161" | while read -r line; do log_warn "  $line"; done
            return 1
        else
            log_debug "未检测到相关端口监听"
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":61616\|:8161"; then
            log_warn "检测到ActiveMQ相关端口仍在监听"
            netstat -tlnp 2>/dev/null | grep ":61616\|:8161" | while read -r line; do log_warn "  $line"; done
            return 1
        else
            log_info "未检测到ActiveMQ相关端口监听"
        fi
    fi
    log_info "已成功停止"; return 0
}

# 主函数
main() {
    parse_arguments "$@"
    detect_os
    stop_activemq
    if verify_stop; then
        log_info "服务已成功停止"; exit 0
    else
        log_warn "停止完成，但检测到残留进程或端口"; exit 0
    fi
}

main "$@"

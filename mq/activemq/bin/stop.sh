#!/bin/bash

# ActiveMQ/Artemis停止脚本
# 支持Linux和MacOS系统
# 自动检测MQ类型（Artemis或Classic）
# 使用模块化设计，统一支持Artemis和Classic

# 加载公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" || { echo "无法加载公共函数库"; exit 1; }

# 运行时变量
INSTALL_DIR=""
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
FORCE_KILL=false

# 打印使用说明
print_usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -d, --dir PATH     指定安装目录（默认Linux: $DEFAULT_INSTALL_DIR, MacOS: $DEFAULT_INSTALL_DIR）"
    echo "  --log-level LEVEL  设置日志级别 (DEBUG, INFO, WARN, ERROR)（默认: $DEFAULT_LOG_LEVEL）"
    echo "  -f, --force        强制结束相关进程（跳过脚本优雅停止）"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "注意: 脚本会自动检测安装的MQ类型（Artemis或Classic）"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认目录停止（不报错退出）"
    echo "  $0 -d $DEFAULT_INSTALL_DIR                  # 指定安装目录停止"
    echo "  $0 --log-level DEBUG                 # 设置日志级别为DEBUG"
    echo "  $0 --force                           # 强制结束进程"
}

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
            --artemis|--classic)
                # 忽略MQ类型参数
                shift 1 ;;
            *)
                log_error "未知参数: $1"; print_usage; exit 1 ;;
        esac
    done
    if [[ -z "$INSTALL_DIR" ]]; then
        case "$(detect_os)" in
            Linux*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
            MacOS*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
            *) log_error "不支持的操作系统: $(detect_os)"; exit 1 ;;
        esac
    fi
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *) log_error "无效的日志级别: $LOG_LEVEL (有效值: DEBUG, INFO, WARN, ERROR)"; exit 1 ;;
    esac
}

# 停止MQ服务
stop_mq() {
    # 预先计算MQ类型和显示名称
    local mq_type=$(detect_mq_type_by_path "$INSTALL_DIR" "true")  # 静默模式检测
    local mq_display_name=$(get_mq_display_name "$mq_type")
    
    # 验证安装目录
    if ! validate_install_dir "$INSTALL_DIR"; then
        # Directory doesn't exist, nothing to stop
        exit 0
    fi
    
    local mq_script=$(get_mq_stop_script)
    if [[ ! -f "$mq_script" ]]; then
        # Exit successfully if stop script doesn't exist - service not installed
        exit 0
    fi

    if [[ "$FORCE_KILL" == "true" ]]; then
        echo "强制模式：跳过优雅停止，直接终止进程"
    else
        # 检查PID文件是否存在
        local pid_file=$(get_mq_pid_file)
        if [[ -f "$pid_file" ]]; then
            PID=$(tr -d '\r\n' < "$pid_file" 2>/dev/null)
            if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
                echo "检测到$mq_display_name运行 (PID: $PID)，正在停止"
                "$mq_script" stop >/dev/null 2>&1 || sudo -n "$mq_script" stop >/dev/null 2>&1 || true
                sleep 5
            else
                rm -f "$pid_file" 2>/dev/null || true
            fi
        else
            "$mq_script" stop >/dev/null 2>&1 || sudo -n "$mq_script" stop >/dev/null 2>&1 || true
            sleep 5
        fi
    fi

    # 收集并终止相关进程
    local PIDS=$(collect_pids)
    if [[ -n "$PIDS" ]]; then
        if [[ "$FORCE_KILL" == "true" ]]; then
            echo "强制模式：直接强制终止进程"
            for pid in $PIDS; do
                kill -9 "$pid" 2>/dev/null || sudo -n kill -9 "$pid" 2>/dev/null || true
            done
        else
            for pid in $PIDS; do
                kill "$pid" 2>/dev/null || sudo -n kill "$pid" 2>/dev/null || true
            done
            sleep 3
            PIDS=$(collect_pids)
            if [[ -n "$PIDS" ]]; then
                for pid in $PIDS; do
                    kill -9 "$pid" 2>/dev/null || sudo -n kill -9 "$pid" 2>/dev/null || true
                done
            fi
        fi
    fi

    # 检查systemd服务 (仅在Linux上)
    if [[ "$(detect_os)" == "Linux" ]]; then
        local service_name=$(get_mq_service_name)
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            sudo -n systemctl stop "$service_name" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# 验证停止状态
verify_stop() {
    # 检查PID文件
    local pid_file=$(get_mq_pid_file)
    if [[ -f "$pid_file" ]]; then
        PID=$(tr -d '\r\n' < "$pid_file" 2>/dev/null)
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            return 1
        else
            rm -f "$pid_file" 2>/dev/null || true
        fi
    fi
    
    # 检查进程
    local PIDS=$(collect_pids)
    if [[ -n "$PIDS" ]]; then
        return 1
    fi
    
    # 检查端口
    local broker_port=${BROKER_PORT:-61616}
    local jetty_port=${JETTY_PORT:-8161}
    
    if command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -qE ":$broker_port|:$jetty_port"; then
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -qE ":$broker_port|:$jetty_port"; then
            return 1
        fi
    fi
    
    return 0
}

# 主函数
main() {
    parse_arguments "$@"
    
    # 自动检测MQ类型和显示名称
    local MQ_TYPE=$(detect_mq_type_by_path "$INSTALL_DIR")
    local MQ_DISPLAY_NAME=$(get_mq_display_name "$MQ_TYPE")
    
    stop_mq
    
    if verify_stop; then
        echo "已成功停止"
        exit 0
    else
        echo "服务未运行或已停止"
        exit 0
    fi
}

main "$@"
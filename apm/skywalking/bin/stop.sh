#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载配置文件
CONFIG_FILE="$SCRIPT_DIR/skywalking.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 定义日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# 验证端口号
validate_port() {
    local port=$1
    local port_name=$2
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_error "$port_name 端口号无效: $port"
        return 1
    fi
    
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "$port_name 端口号超出范围: $port"
        return 1
    fi
    
    return 0
}

# 获取配置文件中的端口号
get_config_port() {
    local config_file="$SCRIPT_DIR/../webapp/application.yml"
    local port
    
    if [ -f "$config_file" ]; then
        port=$(grep 'serverPort:' "$config_file" | awk -F': ' '{print $2}' | sed 's/[^0-9]//g')
        if [ -n "$port" ]; then
            echo "$port"
            return 0
        fi
    fi
    
    # 如果配置文件不存在或读取失败，使用默认值
    echo "$UI_SERVER_PORT"
}

# 终止进程
terminate_process() {
    local pid=$1
    local service_name=$2
    local timeout=${3:-30}
    local count=0
    
    if [ -z "$pid" ]; then
        log_warn "$service_name 进程 ID 为空"
        return 1
    fi
    
    # 检查进程是否存在
    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "$service_name 进程不存在 (PID: $pid)"
        return 1
    fi
    
    log_info "正在停止 $service_name 服务 (PID: $pid)"
    
    # 发送 SIGTERM 信号
    kill -15 "$pid" 2>/dev/null || {
        log_error "无法向 $service_name 发送停止信号"
        return 1
    }
    
    # 等待进程优雅退出
    while [ $count -lt $timeout ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_info "$service_name 服务已成功停止"
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    # 如果优雅停止失败，强制终止
    log_warn "$service_name 未能优雅停止，正在强制终止"
    if kill -9 "$pid" 2>/dev/null; then
        log_info "$service_name 服务已强制终止"
        return 0
    else
        log_error "无法强制终止 $service_name 服务"
        return 1
    fi
}

# 通过端口查找进程
find_process_by_port() {
    local port=$1
    local pids
    
    # 使用多种方法查找进程
    pids=$(lsof -t -i:"$port" -sTCP:LISTEN 2>/dev/null)
    
    if [ -z "$pids" ]; then
        pids=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d'/' -f1)
    fi
    
    if [ -z "$pids" ]; then
        pids=$(ss -tlnp 2>/dev/null | grep ":$port " | awk '/LISTEN/ {print $7}' | cut -d',' -f2 | cut -d'=' -f2)
    fi
    
    echo "$pids"
}

# 通过进程名查找进程
find_process_by_name() {
    local process_name=$1
    local pids
    
    pids=$(ps -ef | grep "$process_name" | grep java | grep -v grep | awk '{print $2}')
    
    echo "$pids"
}

# 停止 WebApp 服务
stop_webapp_service() {
    log_info "开始停止 SkyWalking WebApp 服务..."
    
    # 获取端口号
    local ui_port=$(get_config_port)
    
    if ! validate_port "$ui_port" "WebApp"; then
        log_error "WebApp 端口验证失败"
        return 1
    fi
    
    log_info "WebApp 服务端口: $ui_port"
    
    # 查找进程
    local pids=$(find_process_by_port "$ui_port")
    
    if [ -z "$pids" ]; then
        log_info "WebApp 服务未运行"
        return 0
    fi
    
    local stopped_count=0
    local total_count=0
    
    # 停止所有相关进程
    for pid in $pids; do
        total_count=$((total_count + 1))
        if terminate_process "$pid" "WebApp"; then
            stopped_count=$((stopped_count + 1))
        fi
    done
    
    log_info "WebApp 服务停止完成: $stopped_count/$total_count"
    
    return $([ $stopped_count -eq $total_count ] && echo 0 || echo 1)
}

# 停止 OAP 服务
stop_oap_service() {
    log_info "开始停止 SkyWalking OAP 服务..."
    
    # 查找 OAP 进程
    local pids=$(find_process_by_name "oapService")
    
    if [ -z "$pids" ]; then
        # 如果通过进程名找不到，尝试通过端口查找
        if validate_port "$OAP_PORT" "OAP"; then
            pids=$(find_process_by_port "$OAP_PORT")
        fi
    fi
    
    if [ -z "$pids" ]; then
        log_info "OAP 服务未运行"
        return 0
    fi
    
    local stopped_count=0
    local total_count=0
    
    # 停止所有相关进程
    for pid in $pids; do
        total_count=$((total_count + 1))
        if terminate_process "$pid" "OAP"; then
            stopped_count=$((stopped_count + 1))
        fi
    done
    
    log_info "OAP 服务停止完成: $stopped_count/$total_count"
    
    return $([ $stopped_count -eq $total_count ] && echo 0 || echo 1)
}

# 验证服务停止状态
verify_stop_status() {
    log_info "验证服务停止状态..."
    
    local ui_port=$(get_config_port)
    local services_stopped=true
    
    # 检查 WebApp 服务
    if validate_port "$ui_port" "WebApp" && find_process_by_port "$ui_port" >/dev/null; then
        log_warn "WebApp 服务仍在运行"
        services_stopped=false
    else
        log_info "WebApp 服务已停止"
    fi
    
    # 检查 OAP 服务
    if validate_port "$OAP_PORT" "OAP" && find_process_by_port "$OAP_PORT" >/dev/null; then
        log_warn "OAP 服务仍在运行"
        services_stopped=false
    else
        log_info "OAP 服务已停止"
    fi
    
    if [ "$services_stopped" = true ]; then
        log_info "所有 SkyWalking 服务已成功停止"
        return 0
    else
        log_warn "部分服务仍在运行"
        return 1
    fi
}

# 主函数
main() {
    log_info "开始停止 SkyWalking 服务..."
    
    local webapp_result=0
    local oap_result=0
    
    # 停止 WebApp 服务
    stop_webapp_service
    webapp_result=$?
    
    # 停止 OAP 服务
    stop_oap_service
    oap_result=$?
    
    # 等待进程完全退出
    sleep 2
    
    # 验证停止状态
    verify_stop_status
    
    # 返回结果
    if [ $webapp_result -eq 0 ] && [ $oap_result -eq 0 ]; then
        log_info "SkyWalking 服务停止成功"
        exit 0
    else
        log_error "SkyWalking 服务停止失败"
        exit 1
    fi
}

# 执行主函数
main "$@"
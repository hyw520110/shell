#!/bin/bash

# SpringBoot服务管理脚本 - v2.0 (重构版)
# 支持多个服务的启动、停止、重启、状态查看等功能，使用PID文件管理。

# --- 安全设置 ---
set -eo pipefail

# --- 配置 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# [BUG修复] 修正了配置文件的名称
CONFIG_FILE="$SCRIPT_DIR/java-apps.conf"
LOG_DIR="$SCRIPT_DIR/logs"
# [优化] 使用独立的PID目录来管理所有服务的PID文件
PID_DIR="$SCRIPT_DIR/run"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# --- 核心函数 ---

# 加载服务配置
load_services() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    # 使用关联数组来存储服务配置，更清晰
    declare -g -A SERVICES
    
    # 使用 mapfile 读入配置，更安全
    mapfile -t lines < <(grep -vE "^#|^\s*$" "$CONFIG_FILE")
    for i in "${!lines[@]}"; do
        # 将每行按'|'分割成数组
        IFS='|' read -r -a fields <<< "${lines[i]}"
        local name="${fields[0]}"
        # 将所有字段存入以服务名为键的关联数组中
        SERVICES["$name,index"]=$i
        SERVICES["$name,path"]="${fields[1]}"
        SERVICES["$name,port"]="${fields[2]}"
        SERVICES["$name,profile"]="${fields[3]}"
        SERVICES["$name,jvm_opts"]="${fields[4]}"
    done
    # 获取所有服务名并排序
    IFS=$ '\n' read -d '' -r -a SERVICE_NAMES < <(printf "%s\n" "${!SERVICES[@]}" | grep ",index" | cut -d, -f1 | sort)
}

# 获取服务PID（通过PID文件）
get_service_pid() {
    local service_name=$1
    local pid_file="$PID_DIR/${service_name}.pid"
    if [ -f "$pid_file" ]; then
        cat "$pid_file"
    fi
}

# 检查服务是否运行（通过PID文件）
is_running() {
    local service_name=$1
    local pid=$(get_service_pid "$service_name")
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        return 0 # 正在运行
    fi
    return 1 # 已停止
}

# 检查服务状态（用于显示）
check_service_status() {
    local service_name=$1
    local port=${SERVICES[$service_name,port]}
    
    if is_running "$service_name"; then
        local pid=$(get_service_pid "$service_name")
        # 检查端口是否可访问，以判断是“运行中”还是“启动中”
        if [ -n "$port" ] && nc -z localhost "$port" 2>/dev/null;
        then
            echo -e "${GREEN}运行中${NC} (PID: $pid, Port: $port)"
        else
            echo -e "${YELLOW}启动中${NC} (PID: $pid, Port: ${port:-N/A})"
        fi
    else
        echo -e "${RED}已停止${NC}"
    fi
}

# 启动服务
start_service() {
    local service_name=$1
    echo -e "${BLUE}正在启动服务: $service_name${NC}"

    if is_running "$service_name"; then
        echo -e "${YELLOW}服务已经在运行中 (PID: $(get_service_pid "$service_name"))${NC}"
        return
    fi

    local jar_path=${SERVICES[$service_name,path]}
    if [[ ! -f "$jar_path" ]]; then
        echo -e "${RED}错误: JAR文件不存在 - $jar_path${NC}"
        return
    fi

    local port=${SERVICES[$service_name,port]}
    local profile=${SERVICES[$service_name,profile]}
    local jvm_opts=${SERVICES[$service_name,jvm_opts]}
    local pid_file="$PID_DIR/${service_name}.pid"
    local log_file="$LOG_DIR/${service_name}.log"

    # 构建启动命令
    local cmd="java $jvm_opts -Dspring.profiles.active=$profile -jar $jar_path"
    
    # 启动服务
    nohup $cmd > "$log_file" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$pid_file"

    echo -n "等待服务启动(PID: $new_pid)"
    for i in {1..30}; do
        sleep 1; echo -n "."
        if [ -n "$port" ] && nc -z localhost "$port" 2>/dev/null;
        then
            echo -e "\n${GREEN}服务启动成功!${NC}"
            return
        fi
    done
    echo -e "\n${YELLOW}服务已启动，但端口检查超时。请查看日志: $log_file${NC}"
}

# 停止服务
stop_service() {
    local service_name=$1
    echo -e "${BLUE}正在停止服务: $service_name${NC}"

    if ! is_running "$service_name"; then
        echo -e "${YELLOW}服务未运行${NC}"
        rm -f "$PID_DIR/${service_name}.pid" # 清理可能残留的pid文件
        return
    fi

    local pid=$(get_service_pid "$service_name")
    kill -TERM "$pid"
    echo -n "等待服务停止"
    for i in {1..15}; do
        sleep 1; echo -n "."
        if ! is_running "$service_name"; then
            rm -f "$PID_DIR/${service_name}.pid"
            echo -e "\n${GREEN}服务已停止${NC}"
            return
        fi
    done

    echo -e "\n${YELLOW}优雅停止超时，强制停止...${NC}"
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$PID_DIR/${service_name}.pid"
    echo -e "${GREEN}服务已强制停止${NC}"
}

# ... [其他UI和菜单函数将保持类似结构，但调用新的核心函数] ...
# 为了简洁，这里省略了 view_log, show_detail, batch_ops 等UI函数
# 它们的实现将与原脚本类似，但调用的是重构后的启停和状态检查函数

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}#################### SpringBoot服务管理器 v2.0 ####################${NC}"
        echo -e "${WHITE}当前时间: $(date '+%Y-%m-%d %H:%M:%S') | 配置文件: $CONFIG_FILE${NC}"
        echo -e "${CYAN}============================ 服务列表 ============================${NC}"
        printf "%s\n" "%-4s %-25s %s" "序号" "服务名称" "状态"
        echo "------------------------------------------------------------------"
        if [ ${#SERVICE_NAMES[@]} -eq 0 ]; then
            echo -e "${RED}未找到任何服务配置${NC}"
        else
            for i in "${!SERVICE_NAMES[@]}"; do
                local name=${SERVICE_NAMES[$i]}
                local status=$(check_service_status "$name")
                printf "%s\n" "%-4s %-25s %s" "$((i+1))" "$name" "$status"
            done
        fi
        echo -e "${CYAN}==================================================================${NC}"
        echo
        echo "操作选项: 1-${#SERVICE_NAMES[@]}) 管理服务 | b) 批量操作 | s) 系统信息 | r) 重载配置 | q) 退出"
        read -p "请输入选择: " main_choice

        case $main_choice in
            [1-9]|[1-9][0-9])
                local index=$((main_choice-1))
                if [ -n "${SERVICE_NAMES[$index]}" ]; then
                    # 此处应调用 service_management_menu ${SERVICE_NAMES[$index]}
                    echo "(功能实现中: 管理服务 ${SERVICE_NAMES[$index]})"
                    sleep 1
                else
                    echo -e "${RED}无效的服务序号${NC}"; sleep 1
                fi
                ;; 
            b|B) echo "(功能实现中: 批量操作)"; sleep 1 ;; # 此处应调用 batch_operations_menu
            s|S) echo "(功能实现中: 系统信息)"; sleep 1 ;; # 此处应调用 show_system_info
            r|R) 
                echo -e "${BLUE}重新加载配置文件...${NC}"
                load_services
                echo -e "${GREEN}配置加载完成${NC}"; sleep 1
                ;; 
            q|Q) exit 0 ;; 
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;; 
        esac
    done
}


# --- 启动入口 ---

# 检查依赖
check_dependencies() {
    local missing_deps=()
    command -v java >/dev/null 2>&1 || missing_deps+=("java")
    command -v nc >/dev/null 2>&1 || missing_deps+=("netcat (nc)")
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        echo -e "${RED}错误: 缺少必要的命令: ${missing_deps[*]}${NC}"
        exit 1
    fi
}

# 主函数
main() {
    # 创建必要的目录
    mkdir -p "$LOG_DIR"
    mkdir -p "$PID_DIR"
    check_dependencies
    load_services
    main_menu
}

main "$@"

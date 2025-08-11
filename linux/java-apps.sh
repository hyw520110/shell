#!/bin/bash

# SpringBoot服务管理脚本 - 可视化版本
# 支持多个服务的启动、停止、重启、状态查看等功能

# 配置目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/services.conf"
LOG_DIR="$SCRIPT_DIR/logs"

# 创建必要目录
mkdir -p "$LOG_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 加载服务配置
load_services() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在: $CONFIG_FILE${NC}"
        echo "请先创建配置文件，参考 services.conf.example"
        exit 1
    fi
    
    # 清空服务数组
    unset SERVICE_NAMES
    unset SERVICE_PATHS
    unset SERVICE_PORTS
    unset SERVICE_PROFILES
    unset SERVICE_JVM_OPTS
    
    declare -g -a SERVICE_NAMES=()
    declare -g -a SERVICE_PATHS=()
    declare -g -a SERVICE_PORTS=()
    declare -g -a SERVICE_PROFILES=()
    declare -g -a SERVICE_JVM_OPTS=()
    
    # 读取配置文件
    while IFS='|' read -r name path port profile jvm_opts; do
        # 跳过注释和空行
        [[ $name =~ ^#.*$ ]] && continue
        [[ -z "$name" ]] && continue
        
        SERVICE_NAMES+=("$name")
        SERVICE_PATHS+=("$path")
        SERVICE_PORTS+=("$port")
        SERVICE_PROFILES+=("$profile")
        SERVICE_JVM_OPTS+=("$jvm_opts")
    done < "$CONFIG_FILE"
}

# 获取服务PID
get_service_pid() {
    local service_name=$1
    local port=$2
    
    # 先通过端口查找
    if [[ -n "$port" ]]; then
        pid=$(lsof -ti:$port 2>/dev/null)
        if [[ -n "$pid" ]]; then
            echo $pid
            return
        fi
    fi
    
    # 通过jar文件名查找
    pid=$(ps aux | grep java | grep -v grep | grep "$service_name" | awk '{print $2}')
    echo $pid
}

# 检查服务状态
check_service_status() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    local port=${SERVICE_PORTS[$index]}
    
    local pid=$(get_service_pid "$service_name" "$port")
    
    if [[ -n "$pid" ]]; then
        # 检查端口是否可访问
        if [[ -n "$port" ]] && nc -z localhost $port 2>/dev/null; then
            echo -e "${GREEN}运行中${NC} (PID: $pid, Port: $port)"
        else
            echo -e "${YELLOW}启动中${NC} (PID: $pid)"
        fi
        return 0
    else
        echo -e "${RED}已停止${NC}"
        return 1
    fi
}

# 启动服务
start_service() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    local jar_path=${SERVICE_PATHS[$index]}
    local port=${SERVICE_PORTS[$index]}
    local profile=${SERVICE_PROFILES[$index]}
    local jvm_opts=${SERVICE_JVM_OPTS[$index]}
    
    echo -e "${BLUE}正在启动服务: $service_name${NC}"
    
    # 检查jar文件是否存在
    if [[ ! -f "$jar_path" ]]; then
        echo -e "${RED}错误: JAR文件不存在 - $jar_path${NC}"
        return 1
    fi
    
    # 检查服务是否已经运行
    local pid=$(get_service_pid "$service_name" "$port")
    if [[ -n "$pid" ]]; then
        echo -e "${YELLOW}服务已经在运行中 (PID: $pid)${NC}"
        return 0
    fi
    
    # 构建启动命令
    local cmd="java"
    [[ -n "$jvm_opts" ]] && cmd="$cmd $jvm_opts"
    [[ -n "$profile" ]] && cmd="$cmd -Dspring.profiles.active=$profile"
    cmd="$cmd -jar $jar_path"
    
    # 启动服务
    local log_file="$LOG_DIR/${service_name}.log"
    nohup $cmd > "$log_file" 2>&1 &
    local new_pid=$!
    
    echo "启动命令: $cmd" >> "$log_file"
    echo "启动时间: $(date)" >> "$log_file"
    echo "进程PID: $new_pid" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"
    
    # 等待服务启动
    echo -n "等待服务启动"
    for i in {1..30}; do
        sleep 1
        echo -n "."
        if [[ -n "$port" ]] && nc -z localhost $port 2>/dev/null; then
            echo
            echo -e "${GREEN}服务启动成功!${NC} (PID: $new_pid, Port: $port)"
            return 0
        fi
    done
    
    echo
    echo -e "${YELLOW}服务已启动，但端口检查超时${NC} (PID: $new_pid)"
    echo "请查看日志文件: $log_file"
    return 0
}

# 停止服务
stop_service() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    local port=${SERVICE_PORTS[$index]}
    
    echo -e "${BLUE}正在停止服务: $service_name${NC}"
    
    local pid=$(get_service_pid "$service_name" "$port")
    if [[ -z "$pid" ]]; then
        echo -e "${YELLOW}服务未运行${NC}"
        return 0
    fi
    
    # 优雅停止
    echo "发送TERM信号..."
    kill -TERM $pid
    
    # 等待服务停止
    echo -n "等待服务停止"
    for i in {1..15}; do
        sleep 1
        echo -n "."
        if ! kill -0 $pid 2>/dev/null; then
            echo
            echo -e "${GREEN}服务已停止${NC}"
            return 0
        fi
    done
    
    # 强制停止
    echo
    echo "优雅停止超时，强制停止..."
    kill -KILL $pid 2>/dev/null
    
    sleep 2
    if ! kill -0 $pid 2>/dev/null; then
        echo -e "${GREEN}服务已强制停止${NC}"
        return 0
    else
        echo -e "${RED}服务停止失败${NC}"
        return 1
    fi
}

# 重启服务
restart_service() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    
    echo -e "${BLUE}正在重启服务: $service_name${NC}"
    
    stop_service $index
    sleep 2
    start_service $index
}

# 查看服务日志
view_service_log() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    local log_file="$LOG_DIR/${service_name}.log"
    
    if [[ ! -f "$log_file" ]]; then
        echo -e "${RED}日志文件不存在: $log_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}查看服务日志: $service_name${NC}"
    echo "日志文件: $log_file"
    echo "----------------------------------------"
    
    # 选择查看方式
    echo "请选择查看方式:"
    echo "1) 查看最后50行"
    echo "2) 查看最后100行" 
    echo "3) 实时跟踪日志"
    echo "4) 查看全部日志"
    echo "0) 返回主菜单"
    
    read -p "请输入选择 [1-4]: " log_choice
    
    case $log_choice in
        1) tail -50 "$log_file" ;;
        2) tail -100 "$log_file" ;;
        3) echo "按 Ctrl+C 退出实时跟踪"
           sleep 2
           tail -f "$log_file" ;;
        4) less "$log_file" ;;
        0) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 显示服务详细信息
show_service_detail() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    local jar_path=${SERVICE_PATHS[$index]}
    local port=${SERVICE_PORTS[$index]}
    local profile=${SERVICE_PROFILES[$index]}
    local jvm_opts=${SERVICE_JVM_OPTS[$index]}
    
    clear
    echo -e "${CYAN}==================== 服务详细信息 ====================${NC}"
    echo -e "${WHITE}服务名称:${NC} $service_name"
    echo -e "${WHITE}JAR路径:${NC} $jar_path"
    echo -e "${WHITE}端口号:${NC} ${port:-未配置}"
    echo -e "${WHITE}环境配置:${NC} ${profile:-默认}"
    echo -e "${WHITE}JVM参数:${NC} ${jvm_opts:-默认}"
    
    local pid=$(get_service_pid "$service_name" "$port")
    echo -e "${WHITE}运行状态:${NC} $(check_service_status $index)"
    
    if [[ -n "$pid" ]]; then
        echo -e "${WHITE}进程PID:${NC} $pid"
        echo -e "${WHITE}内存使用:${NC} $(ps -p $pid -o rss= | awk '{printf "%.1f MB", $1/1024}')"
        echo -e "${WHITE}CPU使用:${NC} $(ps -p $pid -o %cpu= | awk '{print $1"%"}')"
        echo -e "${WHITE}启动时间:${NC} $(ps -p $pid -o lstart= | awk '{print $1" "$2" "$3" "$4}')"
    fi
    
    local log_file="$LOG_DIR/${service_name}.log"
    if [[ -f "$log_file" ]]; then
        echo -e "${WHITE}日志文件:${NC} $log_file"
        echo -e "${WHITE}日志大小:${NC} $(du -h "$log_file" | awk '{print $1}')"
    fi
    
    echo -e "${CYAN}======================================================${NC}"
    echo
    read -p "按回车键返回主菜单..."
}

# 显示系统资源使用情况
show_system_info() {
    clear
    echo -e "${CYAN}==================== 系统资源信息 ====================${NC}"
    
    # CPU使用率
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
    echo -e "${WHITE}CPU使用率:${NC} ${cpu_usage}%"
    
    # 内存使用情况
    memory_info=$(free -h | grep Mem)
    total_mem=$(echo $memory_info | awk '{print $2}')
    used_mem=$(echo $memory_info | awk '{print $3}')
    echo -e "${WHITE}内存使用:${NC} $used_mem / $total_mem"
    
    # 磁盘使用情况
    echo -e "${WHITE}磁盘使用:${NC}"
    df -h | grep -E '^/dev/' | awk '{printf "  %s: %s / %s (%s)\n", $1, $3, $2, $5}'
    
    # Java进程信息
    echo -e "${WHITE}Java进程:${NC}"
    ps aux | grep java | grep -v grep | while read line; do
        pid=$(echo $line | awk '{print $2}')
        mem=$(echo $line | awk '{print $4}')
        cmd=$(echo $line | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')
        echo "  PID: $pid, MEM: ${mem}%, CMD: ${cmd:0:50}..."
    done
    
    echo -e "${CYAN}======================================================${NC}"
    echo
    read -p "按回车键返回主菜单..."
}

# 批量操作菜单
batch_operations_menu() {
    while true; do
        clear
        echo -e "${PURPLE}==================== 批量操作菜单 ====================${NC}"
        echo "1) 启动所有服务"
        echo "2) 停止所有服务"
        echo "3) 重启所有服务"
        echo "4) 查看所有服务状态"
        echo "0) 返回主菜单"
        echo -e "${PURPLE}======================================================${NC}"
        
        read -p "请输入选择 [0-4]: " batch_choice
        
        case $batch_choice in
            1)
                echo -e "${BLUE}正在启动所有服务...${NC}"
                for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
                    start_service $i
                    echo
                done
                read -p "按回车键继续..."
                ;;
            2)
                echo -e "${BLUE}正在停止所有服务...${NC}"
                for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
                    stop_service $i
                    echo
                done
                read -p "按回车键继续..."
                ;;
            3)
                echo -e "${BLUE}正在重启所有服务...${NC}"
                for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
                    restart_service $i
                    echo
                done
                read -p "按回车键继续..."
                ;;
            4)
                clear
                echo -e "${CYAN}==================== 所有服务状态 ====================${NC}"
                printf "%-20s %-10s %-15s\n" "服务名称" "端口" "状态"
                echo "------------------------------------------------------"
                for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
                    status=$(check_service_status $i)
                    printf "%-20s %-10s %s\n" "${SERVICE_NAMES[$i]}" "${SERVICE_PORTS[$i]}" "$status"
                done
                echo -e "${CYAN}======================================================${NC}"
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 服务管理菜单
service_management_menu() {
    local index=$1
    local service_name=${SERVICE_NAMES[$index]}
    
    while true; do
        clear
        echo -e "${CYAN}==================== 服务管理: $service_name ====================${NC}"
        echo -e "当前状态: $(check_service_status $index)"
        echo
        echo "1) 启动服务"
        echo "2) 停止服务"
        echo "3) 重启服务"
        echo "4) 查看日志"
        echo "5) 服务详情"
        echo "0) 返回主菜单"
        echo -e "${CYAN}================================================================${NC}"
        
        read -p "请输入选择 [0-5]: " service_choice
        
        case $service_choice in
            1)
                start_service $index
                read -p "按回车键继续..."
                ;;
            2)
                stop_service $index
                read -p "按回车键继续..."
                ;;
            3)
                restart_service $index
                read -p "按回车键继续..."
                ;;
            4)
                view_service_log $index
                ;;
            5)
                show_service_detail $index
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}#################### SpringBoot服务管理器 ####################${NC}"
        echo -e "${WHITE}当前时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "${WHITE}配置文件: $CONFIG_FILE${NC}"
        echo -e "${WHITE}日志目录: $LOG_DIR${NC}"
        echo
        
        # 显示服务列表和状态
        if [[ ${#SERVICE_NAMES[@]} -eq 0 ]]; then
            echo -e "${RED}未找到任何服务配置${NC}"
        else
            echo -e "${CYAN}================== 服务列表 ==================${NC}"
            printf "%-3s %-20s %-10s %-15s\n" "序号" "服务名称" "端口" "状态"
            echo "-----------------------------------------------"
            for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
                status=$(check_service_status $i)
                printf "%-3s %-20s %-10s %s\n" "$((i+1))" "${SERVICE_NAMES[$i]}" "${SERVICE_PORTS[$i]}" "$status"
            done
            echo -e "${CYAN}===============================================${NC}"
        fi
        
        echo
        echo "操作选项:"
        echo "1-${#SERVICE_NAMES[@]}) 管理对应服务"
        echo "b) 批量操作"
        echo "s) 系统信息"
        echo "r) 重新加载配置"
        echo "q) 退出程序"
        echo -e "${GREEN}#########################################################${NC}"
        
        read -p "请输入选择: " main_choice
        
        case $main_choice in
            [1-9]|[1-9][0-9])
                index=$((main_choice-1))
                if [[ $index -ge 0 && $index -lt ${#SERVICE_NAMES[@]} ]]; then
                    service_management_menu $index
                else
                    echo -e "${RED}无效的服务序号${NC}"
                    sleep 1
                fi
                ;;
            b|B)
                batch_operations_menu
                ;;
            s|S)
                show_system_info
                ;;
            r|R)
                echo -e "${BLUE}重新加载配置文件...${NC}"
                load_services
                echo -e "${GREEN}配置加载完成${NC}"
                sleep 1
                ;;
            q|Q)
                echo -e "${GREEN}感谢使用SpringBoot服务管理器！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 检查依赖命令
check_dependencies() {
    local missing_deps=()
    
    command -v java >/dev/null 2>&1 || missing_deps+=("java")
    command -v lsof >/dev/null 2>&1 || missing_deps+=("lsof")
    command -v nc >/dev/null 2>&1 || missing_deps+=("netcat")
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        echo -e "${RED}错误: 缺少必要的命令工具${NC}"
        echo "请安装以下工具: ${missing_deps[*]}"
        echo
        echo "Ubuntu/Debian: sudo apt-get install openjdk-8-jdk lsof netcat"
        echo "CentOS/RHEL: sudo yum install java-1.8.0-openjdk lsof nc"
        exit 1
    fi
}

# 主程序入口
main() {
    # 检查依赖
    check_dependencies
    
    # 加载服务配置
    load_services
    
    # 显示欢迎信息
    clear
    echo -e "${GREEN}"
    echo "########################################################"
    echo "#                                                      #"
    echo "#          SpringBoot服务管理器 v1.0                    #"
    echo "#                                                      #"
    echo "#          支持多服务管理、日志查看、状态监控             #"
    echo "#                                                      #"
    echo "########################################################"
    echo -e "${NC}"
    
    sleep 2
    
    # 启动主菜单
    main_menu
}

# 脚本执行入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
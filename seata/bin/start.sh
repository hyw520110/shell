#!/bin/bash

# Seata服务启动脚本
# 兼容主流Linux和macOS系统
# 支持Docker和主机模式
# Also handles seata-namingserver startup

set -euo pipefail  # 启用严格模式

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    log_info "找不到公共函数库 $SCRIPT_DIR/common.sh" >&2
    exit 1
fi

# 运行模式：auto(自动检测), docker, host
RUN_MODE="auto"

# 检查docker-compose是否已安装，使用公共库函数

# 检查Seata服务是否已在运行
is_seata_running() {
    if is_container_running; then
        return 0
    fi
    
    return 1
}

# 检查seata-namingserver是否已在运行 (主机模式)
is_seata_namingserver_running() {
    # 在主机模式下检查命名服务器进程
    if pgrep -f "seata-namingserver" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查并输出Seata命名服务器状态
check_seata_namingserver_status() {
    if is_seata_namingserver_running; then
        log_info "Seata命名服务器正在运行"
        # 显示相关Java进程
        pgrep -fl "seata-namingserver"
    fi
}

# 启动Seata命名服务器 (主机模式)
start_seata_namingserver() {
    if [ "$START_NAMINGSERVER" = false ]; then
        return 0
    fi    
    log_info "正在启动Seata命名服务器..."
    
    # 获取当前脚本所在的Seata安装目录
    SEATA_HOME="$SCRIPT_DIR/.."
    NAMING_SERVER_DIR="$SEATA_HOME/seata-namingserver"
    
    # 检查命名服务器目录是否存在
    if [ ! -d "$NAMING_SERVER_DIR" ]; then
        return 1
    fi
    
    # 检查Java是否已安装
    if ! command -v java &> /dev/null; then
        log_error "未找到Java运行环境，请先安装Java"
        exit 1
    fi
    
    # 获取Seata命名服务器可执行脚本路径
    NAMING_SERVER_SCRIPT="$NAMING_SERVER_DIR/bin/seata-namingserver.sh"
    
    if [ ! -f "$NAMING_SERVER_SCRIPT" ]; then
        log_error "未找到Seata命名服务器启动脚本: $NAMING_SERVER_SCRIPT"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x "$NAMING_SERVER_SCRIPT" 2>/dev/null || true
    
    # 启动命名服务器
    "$NAMING_SERVER_SCRIPT"
    
    log_info "Seata命名服务器已启动"
}

# 检查并输出Seata服务状态及进程信息
check_seata_status() {
	is_process_running
    if is_docker_running;then
    	if [  -f "$PROJECT_DIR/docker-compose.yml" ]; then
		    if command -v docker-compose &> /dev/null; then
		        docker-compose ps
		    else
		        docker compose ps
		    fi    
	    fi
	    # 查找与seata相关的容器
	    SEATA_CONTAINERS=$(docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -i seata)
	    if [ -n "$SEATA_CONTAINERS" ]; then
	        log_info "$SEATA_CONTAINERS"
	    fi
	    if command -v pgrep &> /dev/null; then
	        DOCKER_PROCESSES=$(pgrep -f docker)
	        if [ -n "$DOCKER_PROCESSES" ]; then
	            log_info "$DOCKER_PROCESSES"
	            ps -p $DOCKER_PROCESSES -o pid,ppid,cmd 2>/dev/null || log_info "无法获取Docker进程详情"
	        fi
	    else
	        # 在macOS或其他没有pgrep的系统上使用ps
	        DOCKER_PROCESSES=$(ps aux | grep -i docker | grep -v grep)
	        if [ -n "$DOCKER_PROCESSES" ]; then
	            log_info "$DOCKER_PROCESSES"
	        fi
	    fi
    fi
}

 

# 重启Seata服务
restart_seata() {
    log_info "正在重启Seata服务..."
    
    # 调用停止脚本的强制停止功能
    "$SCRIPT_DIR/stop.sh" -f
    
    # 等待一段时间确保服务已停止
    sleep 3
    
    # 启动服务
    start_seata
}

# 显示帮助信息
show_help() {
    log_info "用法: $0 [选项]"
    log_info "  无参数              - 启动Seata服务"
    log_info "  -f                  - 重启Seata服务(先强制停止再启动)"
    log_info "  -s, --status        - 查看Seata服务状态及进程信息"
    log_info "  --mode MODE         - 指定运行模式: auto(自动检测, 默认), docker, host"
    log_info "  help                - 显示此帮助信息"
}

# 解析命令行参数
FORCE_RESTART=false
CHECK_STATUS=false
START_NAMINGSERVER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f)
            FORCE_RESTART=true
            shift
            ;;
        -H|--host)
            HOST="$2"
            shift 2
            ;; 
        -p|--port)
            PORT=$2
            shift 2
            ;;    
       -m|--storeMode)
            STORE_MODE=$2
            shift 2
            ;;    
        -s|--status)
            CHECK_STATUS=true
            shift
            ;;
        --with-namingserver)
            START_NAMINGSERVER=true
            shift
            ;;
        --mode)
            RUN_MODE="$2"
            if [[ "$RUN_MODE" != "auto" && "$RUN_MODE" != "docker" && "$RUN_MODE" != "host" ]]; then
                log_error "无效的运行模式 '$RUN_MODE'，有效值: auto, docker, host"
                show_help
                exit 1
            fi
            shift 2
            ;;
        help|-h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "不支持的参数 '$1'"
            show_help
            exit 1
            ;;
    esac
done

# 检测是否应该使用Docker模式
should_use_docker() {
    # 如果用户明确指定了模式，则按指定模式执行
    if [ "$RUN_MODE" = "docker" ]; then
        return 0  # true，使用Docker
    elif [ "$RUN_MODE" = "host" ]; then
        return 1  # false，不使用Docker
    fi
    # auto模式：自动检测
    # 检查Docker是否运行
    if is_docker_running; then
        # 检查docker-compose.yml文件是否存在
        if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
            return 0  # true，使用Docker
        else
            return 1  # false，不使用Docker
        fi
    else
        return 1  # false，不使用Docker
    fi
}

# 在Docker模式下启动Seata服务
start_seata_docker() {
    log_info "正在以Docker模式启动Seata服务..."
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        log_error "未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 检查配置目录是否存在，不存在则创建
    if [ ! -d "conf" ]; then
        log_warn " 未找到conf目录，将使用默认配置"
    fi
    
    # 检查日志目录是否存在，不存在则创建
    if [ ! -d "logs" ]; then
        mkdir -p logs
        log_info "创建日志目录: logs"
    fi
    
    # 启动服务
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    log_info "Seata服务已以Docker模式启动"
    log_info "访问地址: http://localhost:8091"
    log_info "默认事务群组: default_tx_group"
}

# 检查Docker模式下Seata服务是否已在运行
is_seata_running_docker() {
    cd "$PROJECT_DIR"
    
    if [ ! -f "docker-compose.yml" ]; then
        print_error "未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 使用新的通用函数检查容器状态
    if is_container_running; then
        return 0
    fi
    
    return 1
}

# 在Docker模式下停止Seata服务（用于重启）
stop_seata_docker() {
    log_info "正在停止Docker模式下的Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        log_error "未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 停止服务
    if command -v docker-compose &> /dev/null; then
        docker-compose down
    else
        docker compose down
    fi
    
    log_info "Docker模式下的Seata服务已停止"
}

# 在主机模式下启动Seata服务
start_seata_host() {
    # 检查Java是否已安装
    if ! command -v java &> /dev/null; then
        log_error "未找到Java运行环境，请先安装Java"
        exit 1
    fi
    log_info "启动Seata主机服务..."
    # 获取当前脚本所在的Seata安装目录
    SEATA_HOME="$PROJECT_DIR"
    # 创建日志目录
    mkdir -p "$(dirname $LOG_FILE)"
    # 启动Seata服务
    nohup $SEATA_HOME/bin/$SEATA_SERVER_SH -p $PORT -h $HOST -m $STORE_MODE >> "$LOG_FILE" 2>&1 &
    sleep 3
    # 通过端口获取进程ID
    SEATA_PID=$(is_process_running)
    
    if [ -n "$SEATA_PID" ]; then
        log_info "Seata服务已启动，进程ID: $SEATA_PID"
        log_info "访问地址: http://$HOST:$PORT"
        log_info "默认事务群组: default_tx_group"
        log_info "日志文件: $LOG_FILE"
    else
        log_error "Seata服务启动失败"
        exit 1
    fi
    
    # 启动Seata命名服务器
    start_seata_namingserver_host
}

# 在主机模式下启动Seata命名服务器
start_seata_namingserver_host() {
    if [ "$START_NAMINGSERVER" = false ]; then
        return 0
    fi
    log_info "正在以主机模式启动Seata命名服务器..."
    # 启动Seata命名服务器
    nohup $SCRIPT_DIR/$SEATA_NAMINGSERVER_SH 
}

start_seata() {
	if should_use_docker; then
		start_seata_docker
	else
		start_seata_host	
	fi
}
# 主程序逻辑
if [ "$CHECK_STATUS" = true ]; then
   check_seata_status
   check_seata_namingserver_status
   exit 0
elif [ "$FORCE_RESTART" = true ]; then
   $SCRIPT_DIR/$STOP_SCRIPT_PATH
fi
start_seata

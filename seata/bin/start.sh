#!/bin/bash

# Seata服务启动脚本
# 兼容主流Linux和macOS系统
# 支持Docker和主机模式
# Also handles seata-namingserver startup

set -e

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "错误: 找不到公共函数库 $LIB_DIR/common.sh"
    exit 1
fi

# 获取项目目录的绝对路径
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 运行模式：auto(自动检测), docker, host
RUN_MODE="auto"

# 检查docker-compose是否已安装，使用公共库函数

# 检查Seata服务是否已在运行
is_seata_running() {
    cd "$PROJECT_DIR"
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    if command -v docker-compose &> /dev/null; then
        # 使用docker-compose检查服务状态
        if docker-compose ps 2>/dev/null | grep -q "seata-server.*Up"; then
            return 0
        fi
    else
        # 使用docker compose检查服务状态
        if docker compose ps 2>/dev/null | grep -q "seata-server.*Up"; then
            return 0
        fi
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
    echo "正在检查Seata命名服务器状态..."
    
    if is_seata_namingserver_running; then
        echo "Seata命名服务器正在运行"
        # 显示相关Java进程
        pgrep -fl "seata-namingserver"
    else
        echo "Seata命名服务器未运行"
    fi
}

# 启动Seata命名服务器 (主机模式)
start_seata_namingserver() {
    echo "正在启动Seata命名服务器..."
    
    # 获取当前脚本所在的Seata安装目录
    SEATA_HOME="$SCRIPT_DIR/.."
    NAMING_SERVER_DIR="$SEATA_HOME/seata-namingserver"
    
    # 检查命名服务器目录是否存在
    if [ ! -d "$NAMING_SERVER_DIR" ]; then
        echo "警告: Seata命名服务器目录不存在: $NAMING_SERVER_DIR"
        return 1
    fi
    
    # 检查Java是否已安装
    if ! command -v java &> /dev/null; then
        echo "错误: 未找到Java运行环境，请先安装Java"
        exit 1
    fi
    
    # 获取Seata命名服务器可执行脚本路径
    NAMING_SERVER_SCRIPT="$NAMING_SERVER_DIR/bin/seata-namingserver.sh"
    
    if [ ! -f "$NAMING_SERVER_SCRIPT" ]; then
        echo "错误: 未找到Seata命名服务器启动脚本: $NAMING_SERVER_SCRIPT"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x "$NAMING_SERVER_SCRIPT" 2>/dev/null || true
    
    # 启动命名服务器
    "$NAMING_SERVER_SCRIPT"
    
    echo "Seata命名服务器已启动"
}

# 检查并输出Seata服务状态及进程信息
check_seata_status() {
    cd "$PROJECT_DIR"
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    echo "正在检查Seata服务状态..."
    
    if command -v docker-compose &> /dev/null; then
        # 使用docker-compose检查服务状态
        docker-compose ps
    else
        # 使用docker compose检查服务状态
        docker compose ps
    fi
    
    echo ""
    echo "正在查找相关Docker容器进程..."
    # 查找与seata相关的容器
    SEATA_CONTAINERS=$(docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -i seata)
    if [ -n "$SEATA_CONTAINERS" ]; then
        echo "$SEATA_CONTAINERS"
    else
        echo "未找到与Seata相关的运行中容器"
    fi
    
    echo ""
    echo "正在查找相关主机进程..."
    # 查找与Docker相关的进程
    if command -v pgrep &> /dev/null; then
        DOCKER_PROCESSES=$(pgrep -f docker)
        if [ -n "$DOCKER_PROCESSES" ]; then
            echo "Docker相关进程ID:"
            echo "$DOCKER_PROCESSES"
            echo "Docker相关进程详情:"
            ps -p $DOCKER_PROCESSES -o pid,ppid,cmd 2>/dev/null || echo "无法获取Docker进程详情"
        else
            echo "未找到Docker相关进程"
        fi
    else
        # 在macOS或其他没有pgrep的系统上使用ps
        DOCKER_PROCESSES=$(ps aux | grep -i docker | grep -v grep)
        if [ -n "$DOCKER_PROCESSES" ]; then
            echo "Docker相关进程:"
            echo "$DOCKER_PROCESSES"
        else
            echo "未找到Docker相关进程"
        fi
    fi
    
    echo ""
    echo "正在查找Seata命名服务器主机进程..."
    check_seata_namingserver_status
}

# 启动Seata服务
start_seata() {
    echo "正在启动Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 检查配置目录是否存在，不存在则创建
    if [ ! -d "conf" ]; then
        echo "警告: 未找到conf目录，将使用默认配置"
    fi
    
    # 检查日志目录是否存在，不存在则创建
    if [ ! -d "logs" ]; then
        mkdir -p logs
        echo "创建日志目录: logs"
    fi
    
    # 启动服务
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    echo "Seata服务已启动"
    echo "访问地址: http://localhost:8091"
    echo "默认事务群组: default_tx_group"
}

# 重启Seata服务
restart_seata() {
    echo "正在重启Seata服务..."
    
    # 调用停止脚本的强制停止功能
    "$SCRIPT_DIR/stop.sh" -f
    
    # 等待一段时间确保服务已停止
    sleep 3
    
    # 启动服务
    start_seata
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "  无参数              - 启动Seata服务"
    echo "  -f                  - 重启Seata服务(先强制停止再启动)"
    echo "  -s, --status        - 查看Seata服务状态及进程信息"
    echo "  --mode MODE         - 指定运行模式: auto(自动检测, 默认), docker, host"
    echo "  help                - 显示此帮助信息"
}

# 解析命令行参数
FORCE_RESTART=false
CHECK_STATUS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f)
            FORCE_RESTART=true
            shift
            ;;
        -s|--status)
            CHECK_STATUS=true
            shift
            ;;
        --mode)
            RUN_MODE="$2"
            if [[ "$RUN_MODE" != "auto" && "$RUN_MODE" != "docker" && "$RUN_MODE" != "host" ]]; then
                echo "错误: 无效的运行模式 '$RUN_MODE'，有效值: auto, docker, host"
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
            echo "错误: 不支持的参数 '$1'"
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
    if docker info >/dev/null 2>&1; then
        # 检查docker-compose.yml文件是否存在
        if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
            # 检查Seata Docker镜像是否存在
            if docker images seataio/seata-server:latest --format "table {{.Repository}}" 2>/dev/null | grep -q "seataio/seata-server"; then
                return 0  # true，使用Docker
            else
                # 尝试拉取镜像
                echo "Seata Docker镜像不存在，正在尝试拉取..."
                if docker pull seataio/seata-server:latest; then
                    return 0  # true，使用Docker
                else
                    echo "拉取Seata Docker镜像失败，将使用主机模式"
                    return 1  # false，不使用Docker
                fi
            fi
        else
            return 1  # false，不使用Docker
        fi
    else
        return 1  # false，不使用Docker
    fi
}

# 在Docker模式下启动Seata服务
start_seata_docker() {
    echo "正在以Docker模式启动Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 检查配置目录是否存在，不存在则创建
    if [ ! -d "conf" ]; then
        echo "警告: 未找到conf目录，将使用默认配置"
    fi
    
    # 检查日志目录是否存在，不存在则创建
    if [ ! -d "logs" ]; then
        mkdir -p logs
        echo "创建日志目录: logs"
    fi
    
    # 启动服务
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    echo "Seata服务已以Docker模式启动"
    echo "访问地址: http://localhost:8091"
    echo "默认事务群组: default_tx_group"
}

# 检查Docker模式下Seata服务是否已在运行
is_seata_running_docker() {
    cd "$PROJECT_DIR"
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    if command -v docker-compose &> /dev/null; then
        # 使用docker-compose检查服务状态
        if docker-compose ps 2>/dev/null | grep -q "seata-server.*Up"; then
            return 0
        fi
    else
        # 使用docker compose检查服务状态
        if docker compose ps 2>/dev/null | grep -q "seata-server.*Up"; then
            return 0
        fi
    fi
    
    return 1
}

# 在Docker模式下停止Seata服务（用于重启）
stop_seata_docker() {
    echo "正在停止Docker模式下的Seata服务..."
    
    cd "$PROJECT_DIR"
    
    # 检查docker-compose.yml文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo "错误: 未找到docker-compose.yml文件"
        exit 1
    fi
    
    # 停止服务
    if command -v docker-compose &> /dev/null; then
        docker-compose down
    else
        docker compose down
    fi
    
    echo "Docker模式下的Seata服务已停止"
}

# 在主机模式下启动Seata服务
start_seata_host() {
    echo "正在以主机模式启动Seata服务..."
    
    # 检查Java是否已安装
    if ! command -v java &> /dev/null; then
        echo "错误: 未找到Java运行环境，请先安装Java"
        exit 1
    fi

    # 获取当前脚本所在的Seata安装目录
    SEATA_HOME="$SCRIPT_DIR/.."
    
    # 获取Seata服务器可执行文件路径
    SEATA_SERVER_JAR=""
    if [ -f "$SEATA_HOME/target/seata-server.jar" ]; then
        SEATA_SERVER_JAR="$SEATA_HOME/target/seata-server.jar"
    elif [ -f "$SEATA_HOME/seata-server.jar" ]; then
        SEATA_SERVER_JAR="$SEATA_HOME/seata-server.jar"
    elif [ -f "$SEATA_HOME/lib/seata-server.jar" ]; then
        SEATA_SERVER_JAR="$SEATA_HOME/lib/seata-server.jar"
    else
        echo "错误: 未找到Seata服务器JAR文件在以下位置:"
        echo "  - $SEATA_HOME/target/seata-server.jar"
        echo "  - $SEATA_HOME/seata-server.jar"
        echo "  - $SEATA_HOME/lib/seata-server.jar"
        exit 1
    fi
    
    echo "使用Seata服务器JAR: $SEATA_SERVER_JAR"
    
    # 启动Seata服务
    # 使用与seata-server.sh类似的参数，但适配新版本
    JAVA_OPT="-server -Xmx2g -Xms2g -Xmn1g -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m -XX:+HeapDumpOnOutOfMemoryError -XX:+UseG1GC -XX:MaxGCPauseMillis=10 -XX:+UseStringDeduplication -Xloggc:gc.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCTimeStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=10M -XX:+PrintHeapAtGC -XX:+PrintTenuringDistribution -XX:+PrintGCApplicationStoppedTime -XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=75 -XX:+ScavengeALot -XX:+PrintAdaptiveSizePolicy -XX:+UnlockDiagnosticVMOptions -XX:+UnsyncloadClass -XX:MaxJavaStackTraceDepth=1024 -Dfile.encoding=utf-8 -Dlogback.configurationFile=$SEATA_HOME/conf/logback-spring.xml -Dspring.config.additional-location=$SEATA_HOME/conf/ -Dspring.config.location=$SEATA_HOME/conf/application.yml -Dlogging.config=$SEATA_HOME/conf/logback-spring.xml"
    
    # 设置Java命令
    JAVACMD="java"
    
    echo "受影响的JVM参数: $JAVA_OPT"
    
    # 创建日志目录
    mkdir -p "$SEATA_HOME/logs"
    
    # 启动Seata服务
    nohup $JAVACMD $JAVA_OPT -jar "$SEATA_SERVER_JAR" >> "$SEATA_HOME/logs/seata-server.log" 2>&1 &
    
    # 获取进程ID
    SEATA_PID=$!
    
    if [ $SEATA_PID -gt 0 ]; then
        echo "Seata服务已以主机模式启动，进程ID: $SEATA_PID"
        echo "访问地址: http://localhost:8091"
        echo "默认事务群组: default_tx_group"
        echo "日志文件: $SEATA_HOME/logs/seata-server.log"
    else
        echo "错误: Seata服务启动失败"
        exit 1
    fi
    
    # 启动Seata命名服务器
    start_seata_namingserver_host
}

# 在主机模式下启动Seata命名服务器
start_seata_namingserver_host() {
    echo "正在以主机模式启动Seata命名服务器..."
    
    # 获取当前脚本所在的Seata安装目录
    SEATA_HOME="$SCRIPT_DIR/.."
    NAMING_SERVER_DIR="$SEATA_HOME/seata-namingserver"
    
    # 检查命名服务器目录是否存在
    if [ ! -d "$NAMING_SERVER_DIR" ]; then
        echo "警告: Seata命名服务器目录不存在: $NAMING_SERVER_DIR"
        return 1
    fi
    
    # 检查Java是否已安装
    if ! command -v java &> /dev/null; then
        echo "错误: 未找到Java运行环境，请先安装Java"
        exit 1
    fi

    # 获取Seata命名服务器JAR文件路径
    NAMING_SERVER_JAR=""
    if [ -f "$NAMING_SERVER_DIR/target/seata-namingserver.jar" ]; then
        NAMING_SERVER_JAR="$NAMING_SERVER_DIR/target/seata-namingserver.jar"
    elif [ -f "$NAMING_SERVER_DIR/seata-namingserver.jar" ]; then
        NAMING_SERVER_JAR="$NAMING_SERVER_DIR/seata-namingserver.jar"
    elif [ -f "$NAMING_SERVER_DIR/lib/seata-namingserver.jar" ]; then
        NAMING_SERVER_JAR="$NAMING_SERVER_DIR/lib/seata-namingserver.jar"
    else
        echo "错误: 未找到Seata命名服务器JAR文件在以下位置:"
        echo "  - $NAMING_SERVER_DIR/target/seata-namingserver.jar"
        echo "  - $NAMING_SERVER_DIR/seata-namingserver.jar"
        echo "  - $NAMING_SERVER_DIR/lib/seata-namingserver.jar"
        return 1
    fi
    
    echo "使用Seata命名服务器JAR: $NAMING_SERVER_JAR"
    
    # 启动Seata命名服务器
    # 使用与seata-namingserver.sh类似的参数
    JAVA_OPT="-server -Xmx1g -Xms1g -Xmn512m -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m -Xloggc:gc.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCTimeStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=10M -XX:+PrintHeapAtGC -XX:+UseStringDeduplication -Dfile.encoding=utf-8 -Dlogging.config=$NAMING_SERVER_DIR/conf/logback-spring.xml -Dspring.config.additional-location=$NAMING_SERVER_DIR/conf/ -Dspring.config.location=$NAMING_SERVER_DIR/conf/application.yml"
    
    # 设置Java命令
    JAVACMD="java"
    
    # 创建日志目录
    mkdir -p "$NAMING_SERVER_DIR/logs"
    
    # 启动Seata命名服务器
    nohup $JAVACMD $JAVA_OPT -jar "$NAMING_SERVER_JAR" >> "$NAMING_SERVER_DIR/logs/seata-namingserver.log" 2>&1 &
    
    # 获取进程ID
    NAMING_PID=$!
    
    if [ $NAMING_PID -gt 0 ]; then
        echo "Seata命名服务器已以主机模式启动，进程ID: $NAMING_PID"
        echo "日志文件: $NAMING_SERVER_DIR/logs/seata-namingserver.log"
    else
        echo "警告: Seata命名服务器启动失败"
    fi
}

# 主程序逻辑
if [ "$CHECK_STATUS" = true ]; then
    if should_use_docker; then
        # Docker模式
        check_and_start_docker
        check_docker_compose
        check_seata_status
    else
        # 主机模式 - 简单检查Java进程
        echo "正在检查主机模式下的Seata服务状态..."
        if pgrep -f "seata-server" > /dev/null; then
            echo "Seata服务正在主机模式下运行"
            # 显示相关Java进程
            pgrep -fl "seata-server"
        else
            echo "Seata服务未在主机模式下运行"
        fi
        
        # 检查Seata命名服务器状态
        echo ""
        check_seata_namingserver_status
        
        # 同时检查Docker状态
        if check_and_start_docker && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
            echo ""
            echo "Docker模式下的服务状态："
            if command -v docker-compose &> /dev/null; then
                docker-compose ps
            else
                docker compose ps
            fi
        fi
    fi
elif [ "$FORCE_RESTART" = true ]; then
    if should_use_docker; then
        # Docker模式重启
        check_and_start_docker
        if ! check_docker_compose; then
            print_error "Docker Compose 检查失败"
            exit 1
        fi
        stop_seata_docker
        sleep 3
        start_seata_docker
    else
        # 主机模式重启 - 先停止再启动
        echo "正在重启主机模式下的Seata服务..."
        # 查找并终止现有进程
        pkill -f "seata-server" 2>/dev/null || true
        sleep 3
        start_seata_host
    fi
else
    if should_use_docker; then
        # Docker模式
        check_and_start_docker
        if ! check_docker_compose; then
            print_error "Docker Compose 检查失败"
            exit 1
        fi
        
        if is_seata_running_docker; then
            echo "提示: Docker模式下Seata服务已在运行，如需重启请使用 -f 参数"
            exit 0
        else
            start_seata_docker
        fi
    else
        # 主机模式
        if pgrep -f "seata-server" > /dev/null; then
            echo "提示: 主机模式下Seata服务已在运行，如需重启请使用 -f 参数"
            exit 0
        else
            start_seata_host
        fi
    fi
fi
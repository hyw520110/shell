#!/bin/bash
# SpringBoot服务部署脚本
# 自动化部署和管理SpringBoot应用，集成启停、备份、回滚、健康检查等功能。

# --- 安全设置 ---
# -e: 命令失败时立即退出
# -o pipefail: 管道中任一命令失败则整个管道失败
set -eo pipefail

# --- 配置 ---
APP_NAME="user-service"
APP_VERSION="1.0.0"
JAR_NAME="${APP_NAME}-${APP_VERSION}.jar"

# 目录配置
DEPLOY_DIR="/opt/webapps"
BACKUP_DIR="/opt/backups"
# PID和日志目录，使用/var/run和/var/log是标准实践，但需确保权限
# 为方便，这里我们放在部署目录下
PID_DIR="$DEPLOY_DIR/run"
LOG_DIR="$DEPLOY_DIR/logs"
PID_FILE="$PID_DIR/${APP_NAME}.pid"
LOG_FILE="$LOG_DIR/${APP_NAME}.log"

# 服务配置
SERVICE_PORT="8080"
PROFILE="prod"

# JVM参数配置
JVM_OPTS="-Xms512m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
JVM_OPTS+=" -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:$LOG_DIR/gc.log"
JVM_OPTS+=" -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=10M"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 核心服务管理函数 ---

# 检查服务是否正在运行
is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        # kill -0 pid 不发送信号，但能检查进程是否存在
        if kill -0 "$pid" >/dev/null 2>&1; then
            return 0 # 正在运行
        fi
    fi
    return 1 # 未运行
}

# 启动服务
start_service() {
    if is_running; then
        echo -e "${YELLOW}${APP_NAME} 已经在运行 (PID: $(cat "$PID_FILE"))${NC}"
        return 0
    fi
    
    echo -e "${BLUE}启动 ${APP_NAME}...${NC}"
    # 启动命令
    nohup java $JVM_OPTS -jar "$DEPLOY_DIR/$JAR_NAME" --server.port="$SERVICE_PORT" --spring.profiles.active="$PROFILE" > "$LOG_FILE" 2>&1 &
    
    # 将新进程的PID写入PID文件
    echo $! > "$PID_FILE"
    
    echo -e "${GREEN}服务启动命令已发送 (PID: $(cat "$PID_FILE"))${NC}"
}

# 停止服务
stop_service() {
    if ! is_running; then
        echo -e "${YELLOW}${APP_NAME} 未在运行${NC}"
        return 0
    fi
    
    local pid=$(cat "$PID_FILE")
    echo -e "${BLUE}正在停止 ${APP_NAME} (PID: $pid)...${NC}"
    
    # 发送SIGTERM信号，请求正常关闭
    kill "$pid"
    
    # 循环等待进程关闭，替换不稳定的 sleep
    for i in {1..15}; do # 最多等待30秒
        if ! is_running; then
            rm -f "$PID_FILE"
            echo -e "${GREEN}服务已停止${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    
    # 如果30秒后仍在运行，则强制终止
    echo -e "\n${YELLOW}服务在30秒内未正常关闭，将强制终止 (SIGKILL)...${NC}"
    kill -9 "$pid"
    rm -f "$PID_FILE"
    echo -e "${GREEN}服务已被强制终止${NC}"
}

# --- 部署流程函数 ---

# 创建必要目录
setup_directories() {
    echo -e "${BLUE}创建部署目录...${NC}"
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$PID_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    echo -e "${GREEN}目录创建完成${NC}"
}

# 备份当前版本
backup_current_version() {
    if [[ -f "$DEPLOY_DIR/$JAR_NAME" ]]; then
        echo -e "${BLUE}备份当前版本...${NC}"
        local backup_file="$BACKUP_DIR/${JAR_NAME}.$(date +%Y%m%d_%H%M%S).bak"
        cp "$DEPLOY_DIR/$JAR_NAME" "$backup_file"
        echo -e "${GREEN}备份完成: $backup_file${NC}"
    fi
}

# 部署新版本
deploy_new_version() {
    local jar_file=$1
    if [[ ! -f "$jar_file" ]]; then
        echo -e "${RED}错误: JAR文件不存在 - $jar_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}部署新版本...${NC}"
    stop_service
    cp "$jar_file" "$DEPLOY_DIR/$JAR_NAME"
    chmod +x "$DEPLOY_DIR/$JAR_NAME"
    echo -e "${GREEN}新版本JAR包已复制${NC}"
}

# 健康检查
health_check() {
    local max_attempts=30
    local attempt=0
    echo -e "${BLUE}进行健康检查 (http://localhost:$SERVICE_PORT/actuator/health)...${NC}"
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -f "http://localhost:$SERVICE_PORT/actuator/health" >/dev/null 2>&1; then
            echo -e "\n${GREEN}健康检查通过！${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    echo
    echo -e "${RED}健康检查失败！${NC}"
    return 1
}

# 回滚到上一版本
rollback() {
    echo -e "${YELLOW}开始回滚...${NC}"
    local latest_backup=$(ls -t "$BACKUP_DIR"/${JAR_NAME}.*.bak 2>/dev/null | head -1)
    if [[ -z "$latest_backup" ]]; then
        echo -e "${RED}没有找到备份文件用于回滚${NC}"
        return 1
    fi
    
    echo -e "${BLUE}回滚到: $(basename "$latest_backup")${NC}"
    stop_service
    cp "$latest_backup" "$DEPLOY_DIR/$JAR_NAME"
    start_service
    
    if health_check; then
        echo -e "${GREEN}回滚成功！${NC}"
    else
        echo -e "${RED}回滚后健康检查失败${NC}"
        return 1
    fi
}

# 完整部署流程
full_deploy() {
    local jar_file=$1
    echo -e "${GREEN}=== 开始部署 $APP_NAME ===${NC}"
    
    setup_directories
    backup_current_version
    
    if ! deploy_new_version "$jar_file"; then
        echo -e "${RED}部署失败${NC}"
        return 1
    fi
    
    start_service
    
    if health_check; then
        echo -e "${GREEN}部署成功！${NC}"
        echo -e "${BLUE}清理旧备份 (保留最近5个)...${NC}"
        ls -t "$BACKUP_DIR"/${JAR_NAME}.*.bak 2>/dev/null | tail -n +6 | xargs -r rm -f
        echo -e "${GREEN}清理完成${NC}"
    else
        echo -e "${RED}部署失败，开始回滚...${NC}"
        rollback
        return 1
    fi
}

# 显示使用帮助
show_help() {
    echo "SpringBoot应用部署脚本 (自包含版)"
    echo
    echo "用法: $0 [命令] [参数]"
    echo "命令:"
    echo "  deploy <jar-file>    - 部署新版本"
    echo "  start                - 启动服务"
    echo "  stop                 - 停止服务"
    echo "  restart              - 重启服务"
    echo "  status               - 查看服务状态"
    echo "  rollback             - 回滚到上一版本"
    echo "  health               - 健康检查"
    echo "  setup                - 初始化部署环境"
}

# --- 主程序入口 ---
main() {
    case "${1:-}" in
        deploy)
            if [[ -z "${2:-}" ]]; then echo -e "${RED}错误: 请指定JAR文件${NC}"; show_help; exit 1; fi
            full_deploy "$2"
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            stop_service
            start_service
            health_check
            ;;
        status)
            if is_running; then
                echo -e "${GREEN}${APP_NAME} 正在运行 (PID: $(cat "$PID_FILE"))${NC}"
            else
                echo -e "${YELLOW}${APP_NAME} 未在运行${NC}"
            fi
            ;;
        rollback)
            rollback
            ;;
        health)
            health_check
            ;;
        setup)
            setup_directories
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
#!/bin/bash
# SpringBoot服务部署脚本
# 自动化部署和管理SpringBoot应用

# 部署配置
APP_NAME="user-service"
APP_VERSION="1.0.0"
JAR_NAME="${APP_NAME}-${APP_VERSION}.jar"
DEPLOY_DIR="/opt/webapps"
BACKUP_DIR="/opt/backups"
SERVICE_PORT="8080"
PROFILE="prod"

# JVM参数配置
JVM_OPTS="-Xms512m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
JVM_OPTS="$JVM_OPTS -XX:+PrintGC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps"
JVM_OPTS="$JVM_OPTS -Xloggc:$DEPLOY_DIR/logs/gc.log -XX:+UseGCLogFileRotation"
JVM_OPTS="$JVM_OPTS -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=10M"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 创建必要目录
setup_directories() {
    echo -e "${BLUE}创建部署目录...${NC}"
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR/logs"
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
    
    # 停止当前服务
    ./springboot-service-manager.sh stop "$APP_NAME" 2>/dev/null || true
    
    # 等待服务完全停止
    sleep 3
    
    # 复制新版本
    cp "$jar_file" "$DEPLOY_DIR/$JAR_NAME"
    chmod +x "$DEPLOY_DIR/$JAR_NAME"
    
    echo -e "${GREEN}部署完成${NC}"
}

# 健康检查
health_check() {
    local max_attempts=30
    local attempt=0
    
    echo -e "${BLUE}进行健康检查...${NC}"
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -f "http://localhost:$SERVICE_PORT/actuator/health" >/dev/null 2>&1; then
            echo -e "${GREEN}健康检查通过！${NC}"
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
    
    # 查找最新的备份文件
    local latest_backup=$(ls -t "$BACKUP_DIR"/${JAR_NAME}.*.bak 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        echo -e "${RED}没有找到备份文件${NC}"
        return 1
    fi
    
    echo -e "${BLUE}回滚到: $latest_backup${NC}"
    
    # 停止当前服务
    ./springboot-service-manager.sh stop "$APP_NAME" 2>/dev/null || true
    sleep 3
    
    # 恢复备份
    cp "$latest_backup" "$DEPLOY_DIR/$JAR_NAME"
    
    # 启动服务
    ./springboot-service-manager.sh start "$APP_NAME"
    
    # 健康检查
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
    
    echo -e "${GREEN}开始部署 $APP_NAME${NC}"
    echo "JAR文件: $jar_file"
    echo "部署目录: $DEPLOY_DIR"
    echo "服务端口: $SERVICE_PORT"
    echo "环境配置: $PROFILE"
    echo "----------------------------------------"
    
    # 创建目录
    setup_directories
    
    # 备份当前版本
    backup_current_version
    
    # 部署新版本
    if ! deploy_new_version "$jar_file"; then
        echo -e "${RED}部署失败${NC}"
        return 1
    fi
    
    # 启动服务
    echo -e "${BLUE}启动服务...${NC}"
    ./springboot-service-manager.sh start "$APP_NAME"
    
    # 健康检查
    if health_check; then
        echo -e "${GREEN}部署成功！${NC}"
        
        # 清理旧备份（保留最近5个）
        echo -e "${BLUE}清理旧备份...${NC}"
        ls -t "$BACKUP_DIR"/${JAR_NAME}.*.bak 2>/dev/null | tail -n +6 | xargs rm -f
        echo -e "${GREEN}清理完成${NC}"
    else
        echo -e "${RED}部署失败，开始回滚...${NC}"
        rollback
        return 1
    fi
}

# 显示使用帮助
show_help() {
    echo "SpringBoot应用部署脚本"
    echo
    echo "用法:"
    echo "  $0 deploy <jar-file>    - 部署新版本"
    echo "  $0 rollback             - 回滚到上一版本"
    echo "  $0 health               - 健康检查"
    echo "  $0 setup                - 初始化部署环境"
    echo
    echo "示例:"
    echo "  $0 deploy app-1.0.0.jar"
    echo "  $0 rollback"
}

# 主程序
main() {
    case "${1:-}" in
        deploy)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}错误: 请指定JAR文件${NC}"
                show_help
                exit 1
            fi
            full_deploy "$2"
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
 


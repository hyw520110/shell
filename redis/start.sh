#!/bin/bash
# 脚本: start.sh
# 描述: 启动 Redis 服务器。

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/redis.conf"
REDIS_PID_FILE="$SCRIPT_DIR/redis-server.pid"
REDIS_LOG_FILE="$SCRIPT_DIR/logs/redis-server.log"

# 打印信息
info() {
    echo "[INFO] $1"
}

# 打印警告
warn() {
    echo "[WARN] $1" >&2
}

# 打印错误并退出
error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# 检查 Redis 是否已运行
is_redis_running() {
    if [ -f "$REDIS_PID_FILE" ]; then
        PID=$(cat "$REDIS_PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            return 0 # 运行中
        fi
    fi
    return 1 # 未运行
}

# 检查Redis是否已安装
is_redis_installed() {
    if command -v redis-server &> /dev/null; then
        return 0
    elif [[ "$(uname)" == "Darwin" ]] && [ -f "/usr/local/bin/redis-server" ]; then
        return 0
    elif [[ "$(uname)" == "Linux" ]] && [ -f "/usr/bin/redis-server" ]; then
        return 0
    fi
    return 1
}

main() {
    if is_redis_running; then
        info "Redis 已经在运行 (PID: $(cat "$REDIS_PID_FILE"))。"
        exit 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Redis 配置文件 '$CONFIG_FILE' 不存在。"
        read -p "是否运行安装脚本? (y/N): " -n 1 -r
        echo # 换行
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$SCRIPT_DIR/install.sh" || error "安装脚本执行失败。"
        else
            error "Redis 配置文件 '$CONFIG_FILE' 不存在。请先运行 install.sh。"
        fi
    fi

    # 确保日志目录存在
    LOG_DIR=$(dirname "$REDIS_LOG_FILE")
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" || error "创建日志目录失败: $LOG_DIR"
    fi

    info "正在启动 Redis 服务器..."
    
    # 确保使用正确的redis-server路径
    REDIS_SERVER=""
    if command -v redis-server &> /dev/null; then
        REDIS_SERVER="redis-server"
    elif [[ "$(uname)" == "Darwin" ]] && [ -f "/usr/local/bin/redis-server" ]; then
        REDIS_SERVER="/usr/local/bin/redis-server"
    elif [[ "$(uname)" == "Linux" ]] && [ -f "/usr/bin/redis-server" ]; then
        REDIS_SERVER="/usr/bin/redis-server"
    else
        error "未找到 'redis-server' 命令。请确保 Redis 已正确安装。"
    fi

    # 启动Redis服务器
    "$REDIS_SERVER" "$CONFIG_FILE" || error "Redis 启动失败。"

    # 检查是否成功启动
    sleep 2 # 等待 Redis 启动并写入 PID 文件
    if is_redis_running; then
        info "Redis 启动成功 (PID: $(cat "$REDIS_PID_FILE"))。"
        info "日志文件位置: $REDIS_LOG_FILE"
    else
        error "Redis 启动失败。请检查日志文件: $REDIS_LOG_FILE"
    fi
}

main
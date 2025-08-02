#!/bin/bash
# 脚本: stop.sh
# 描述: 停止 Redis 服务器。

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDIS_PID_FILE="$SCRIPT_DIR/redis-server.pid"
CONFIG_FILE="$SCRIPT_DIR/redis.conf"

# 打印信息
info() {
    echo "[INFO] $1"
}

# 打印警告
warn() {
    echo "[WARN] $1" >&2
}

# 打印错误
error() {
    echo "[ERROR] $1" >&2
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

# 优雅停止Redis
graceful_shutdown() {
    if [ -f "$CONFIG_FILE" ]; then
        # 从配置文件中获取密码
        PASSWORD=$(grep "^requirepass " "$CONFIG_FILE" | awk '{print $2}')
        PORT=$(grep "^port " "$CONFIG_FILE" | awk '{print $2}')
        PORT=${PORT:-6379}
        
        # 尝试使用redis-cli优雅关闭
        if command -v redis-cli &> /dev/null && [ -n "$PASSWORD" ]; then
            info "尝试优雅停止 Redis..."
            redis-cli -p "$PORT" -a "$PASSWORD" shutdown > /dev/null 2>&1 &
            
            # 等待最多10秒
            for i in $(seq 1 10); do
                if ! is_redis_running; then
                    info "Redis 已成功停止。"
                    [ -f "$REDIS_PID_FILE" ] && rm "$REDIS_PID_FILE"
                    return 0
                fi
                sleep 1
            done
        fi
    fi
    
    return 1
}

main() {
    if ! is_redis_running; then
        info "Redis 未运行。"
        # 即使 PID 文件存在但进程不存在，也清理 PID 文件
        if [ -f "$REDIS_PID_FILE" ]; then
            rm "$REDIS_PID_FILE"
            info "已清理无效的 PID 文件。"
        fi
        exit 0
    fi

    PID=$(cat "$REDIS_PID_FILE")
    info "正在停止 Redis (PID: $PID)..."

    # 首先尝试优雅停止
    if graceful_shutdown; then
        exit 0
    fi

    # 优雅停止失败，使用SIGTERM信号
    info "优雅停止失败，尝试使用 SIGTERM 信号..."
    kill "$PID" 2>/dev/null

    # 等待 Redis 停止
    for i in $(seq 1 10); do
        if ! ps -p "$PID" > /dev/null 2>&1; then
            info "Redis 已成功停止。"
            rm "$REDIS_PID_FILE"
            exit 0
        fi
        sleep 1
    done

    # 如果还无法停止，使用SIGKILL强制终止
    warn "Redis 未能在规定时间内停止 (PID: $PID)。尝试强制终止..."
    kill -9 "$PID" 2>/dev/null
    if ! ps -p "$PID" > /dev/null 2>&1; then
        info "Redis 已被强制终止。"
        rm "$REDIS_PID_FILE"
    else
        error "无法终止 Redis 进程 (PID: $PID)。可能需要手动干预。"
        exit 1
    fi
}

main
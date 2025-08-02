#!/bin/bash
# 脚本: install.sh
# 描述: 安装并初始化 Redis, 兼容 macOS 和 Linux。

# --- 配置 ---
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/redis.conf"
REDIS_LOG_FILE="$SCRIPT_DIR/logs/redis-server.log"
REDIS_PID_FILE="$SCRIPT_DIR/redis-server.pid"

# --- 函数 ---

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

# 检测操作系统
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS="macos"
    elif [[ "$(uname)" == "Linux" ]]; then
        OS="linux"
    else
        error "不支持的操作系统: $(uname)"
    fi
    info "检测到操作系统: $OS"
}

# 检查Redis是否已安装
is_redis_installed() {
    if command -v redis-server &> /dev/null; then
        return 0
    elif [[ "$OS" == "macos" ]] && [ -f "/usr/local/bin/redis-server" ]; then
        return 0
    elif [[ "$OS" == "linux" ]] && [ -f "/usr/bin/redis-server" ]; then
        return 0
    fi
    return 1
}

# 安装 Redis
install_redis() {
    if is_redis_installed; then
        info "Redis 已安装，跳过安装步骤。"
        return
    fi
    
    info "开始安装 Redis..."
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &> /dev/null; then
            error "未找到 Homebrew。请先安装 Homebrew: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""
        fi
        info "通过 Homebrew 安装 Redis..."
        brew install redis || error "通过 Homebrew 安装 Redis 失败。"
    elif [[ "$OS" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            info "通过 apt-get 安装 Redis..."
            sudo apt-get update && sudo apt-get install -y redis-server || error "通过 apt-get 安装 Redis 失败。"
        elif command -v yum &> /dev/null; then
            info "通过 yum 安装 Redis..."
            sudo yum install -y epel-release && sudo yum install -y redis || error "通过 yum 安装 Redis 失败。"
        else
            error "未找到 apt-get 或 yum, 无法自动安装 Redis。"
        fi
    fi
}

# 检查配置文件是否已配置
is_configured() {
    if [ -f "$CONFIG_FILE" ]; then
        # 检查是否已配置密码
        if grep -q "^requirepass " "$CONFIG_FILE" && [ -n "$(grep "^requirepass " "$CONFIG_FILE" | awk '{print $2}')" ]; then
            # 检查是否已禁用危险命令
            if grep -q "^rename-command FLUSHALL \".*\"" "$CONFIG_FILE" && \
               grep -q "^rename-command FLUSHDB \".*\"" "$CONFIG_FILE" && \
               grep -q "^rename-command CONFIG \".*\"" "$CONFIG_FILE"; then
                return 0
            fi
        fi
    fi
    return 1
}

# 生成不包含特殊字符的随机密码
generate_password() {
    # 生成一个16位的随机密码，只包含字母和数字
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# 创建配置文件
create_config() {
    if is_configured; then
        info "Redis 已配置，跳过配置步骤。"
        return
    fi

    if [ -f "$CONFIG_FILE" ]; then
        read -p "配置文件 $CONFIG_FILE 已存在。是否重新生成? (y/N): " -n 1 -r
        echo # 换行
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "跳过配置文件生成。"
            return
        fi
        info "正在重新生成配置文件..."
    fi

    info "创建新的配置文件: $CONFIG_FILE"

    # 生成随机密码
    PASSWORD=$(generate_password)
    if [ -z "$PASSWORD" ]; then
        error "生成随机密码失败, 请确保已安装 openssl。"
    fi

    info "正在生成配置文件..."
    # 使用 cat 和 EOF 创建配置文件
    cat <<EOF > "$CONFIG_FILE"
# --- Redis 配置文件 (由脚本生成) ---

# 网络
bind 127.0.0.1
protected-mode yes
port 6379
timeout 0
tcp-keepalive 300
tcp-backlog 511

# 安全
requirepass $PASSWORD
# 禁用危险命令 (通过重命名为空字符串)
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command DEBUG ""

# 通用
daemonize yes
pidfile $REDIS_PID_FILE
loglevel notice
logfile $REDIS_LOG_FILE
databases 16
always-show-logo yes

# RDB 持久化 (快照)
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir $SCRIPT_DIR/data # 将数据文件存放在 data 子目录

# AOF 持久化 (Append Only File)
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes

# 内存管理
maxmemory 256mb # 设置为 256MB, 你可以根据你的服务器进行调整
maxmemory-policy allkeys-lru
maxmemory-samples 5 # 采样数量，用于LRU/LFU算法

# 性能与限制
hz 10 # Redis 内部调度（如清除过期key）的频率
activerehashing yes # 启用渐进式 rehash
slowlog-log-slower-than 10000
slowlog-max-len 128
latency-monitor-threshold 0
notify-keyspace-events ""

EOF

    info "配置文件创建成功。"
    echo "========================================================================"
    echo "重要: Redis 密码已生成并配置."
    echo "密码: $PASSWORD"
    echo "配置文件: $CONFIG_FILE"
    echo "请妥善保管此密码!"
    if [[ "$OS" == "macos" ]]; then
        echo "注意: 在 macOS 上, 此脚本不会安装 Redis 作为自启动服务。"
        echo "      如需自启动, 请考虑使用 Homebrew services 或 launchd。"
    fi
    echo "========================================================================"
    mkdir -p "$SCRIPT_DIR/data" "$SCRIPT_DIR/logs" || error "创建数据目录或日志目录失败。"
}

# --- 主逻辑 ---
main() {
    detect_os
    install_redis
    create_config
    info "Redis 安装和配置完成。"
    info "请运行 ./start.sh 来启动 Redis."
}

main
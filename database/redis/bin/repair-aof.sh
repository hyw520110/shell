#!/usr/bin/env bash
# Repair Redis AOF metadata after data-directory migration.

set -euo pipefail

INSTALL_DIR="${1:-$HOME/redis}"
PORT="${2:-6379}"
LAUNCHAGENT_LABEL="${LAUNCHAGENT_LABEL:-org.redis.server}"
FORCE=false

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

show_help() {
    cat <<EOF
Redis AOF 修复脚本

功能:
  外置盘迁移、磁盘空间写满或 macOS 扩展属性异常后，如果 Redis 卡在
  AOF manifest 加载阶段，可备份并重写 appendonlydir 文件元数据，然后重启验证。

用法:
  $0 [INSTALL_DIR] [PORT] [--force]

示例:
  $0 ~/redis 6379 --force
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help; exit 0 ;;
        --force)
            FORCE=true; shift ;;
        *)
            if [ -z "${INSTALL_DIR_SET:-}" ]; then
                INSTALL_DIR="$1"; INSTALL_DIR_SET=1
            elif [ -z "${PORT_SET:-}" ]; then
                PORT="$1"; PORT_SET=1
            else
                die "未知参数: $1"
            fi
            shift ;;
    esac
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

real_path() {
    local path="$1"
    cd "$path" && pwd -P
}

redis_password() {
    local conf="$1"
    awk '
        /^[[:space:]]*requirepass[[:space:]]+/ && $1 !~ /^#/ {
            print $2
            exit
        }
    ' "$conf"
}

redis_cli() {
    local password="$1"
    if [ -n "$password" ]; then
        "$REAL_INSTALL_DIR/bin/redis-cli" -h 127.0.0.1 -p "$PORT" -t 2 -a "$password" --no-auth-warning "$@"
    else
        "$REAL_INSTALL_DIR/bin/redis-cli" -h 127.0.0.1 -p "$PORT" -t 2 "$@"
    fi
}

with_timeout() {
    local seconds="$1"
    shift
    if command_exists timeout; then
        timeout "$seconds" "$@"
    elif command_exists gtimeout; then
        gtimeout "$seconds" "$@"
    else
        "$@"
    fi
}

is_healthy() {
    local password="$1"
    local output
    output="$(with_timeout 5 redis_cli "$password" ping 2>/dev/null || true)"
    [ "$output" = "PONG" ]
}

redis_pids() {
    if command_exists lsof; then
        lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | while read -r pid; do
            ps -p "$pid" -o command= 2>/dev/null | grep -q 'redis-server' && echo "$pid"
        done
    else
        ps -ef | awk -v port="$PORT" '/redis-server/ && $0 ~ ":" port "([^0-9]|$)" {print $2}'
    fi
}

stop_redis() {
    local password="$1"
    local pids pid count

    if is_healthy "$password"; then
        log "Redis 当前可响应，尝试优雅 shutdown"
        redis_cli "$password" shutdown nosave >/dev/null 2>&1 || true
    fi

    count=0
    while [ "$count" -lt 10 ]; do
        pids="$(redis_pids | xargs 2>/dev/null || true)"
        [ -z "$pids" ] && return 0
        sleep 1
        count=$((count + 1))
    done

    pids="$(redis_pids | xargs 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        warn "Redis 未能优雅停止，将终止进程: $pids"
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 3
    fi

    pids="$(redis_pids | xargs 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        warn "Redis 仍未退出，将强制终止进程: $pids"
        for pid in $pids; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
}

rewrite_appendonlydir() {
    local aof_dir="$REAL_INSTALL_DIR/appendonlydir"
    local backup_dir tmp_dir ts

    [ -d "$aof_dir" ] || die "未找到 AOF 目录: $aof_dir"
    [ -f "$aof_dir/appendonly.aof.manifest" ] || die "未找到 AOF manifest: $aof_dir/appendonly.aof.manifest"

    ts="$(date +%Y%m%d%H%M%S)"
    backup_dir="$REAL_INSTALL_DIR/appendonlydir.bak.$ts"
    tmp_dir="$REAL_INSTALL_DIR/appendonlydir.rewrite.$ts"

    log "备份 AOF 目录: $backup_dir"
    cp -R "$aof_dir" "$backup_dir"
    mkdir -p "$tmp_dir"
    cp "$aof_dir"/* "$tmp_dir"/

    if [ "$(uname)" = "Darwin" ] && command_exists xattr; then
        xattr -cr "$REAL_INSTALL_DIR" "$tmp_dir" "$backup_dir" 2>/dev/null || true
    fi

    mv "$aof_dir" "$REAL_INSTALL_DIR/appendonlydir.old.$ts"
    mv "$tmp_dir" "$aof_dir"
    log "已重写 AOF 目录元数据，原目录保留为: $REAL_INSTALL_DIR/appendonlydir.old.$ts"
}

start_redis() {
    local plist="$HOME/Library/LaunchAgents/$LAUNCHAGENT_LABEL.plist"
    if [ "$(uname)" = "Darwin" ] && [ -f "$plist" ]; then
        launchctl kickstart -k "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    elif command_exists systemctl && systemctl list-unit-files redis.service >/dev/null 2>&1; then
        sudo systemctl restart redis.service
    else
        "$REAL_INSTALL_DIR/bin/startup.sh" 1 "$PORT"
    fi
}

main() {
    [ -d "$INSTALL_DIR" ] || die "安装目录不存在: $INSTALL_DIR"
    REAL_INSTALL_DIR="$(real_path "$INSTALL_DIR")"
    CONF_FILE="$REAL_INSTALL_DIR/conf/redis.conf"
    [ -x "$REAL_INSTALL_DIR/bin/redis-server" ] || die "未找到 redis-server: $REAL_INSTALL_DIR/bin/redis-server"
    [ -x "$REAL_INSTALL_DIR/bin/redis-cli" ] || die "未找到 redis-cli: $REAL_INSTALL_DIR/bin/redis-cli"
    [ -f "$CONF_FILE" ] || die "未找到 Redis 配置: $CONF_FILE"

    PASSWORD="$(redis_password "$CONF_FILE")"
    if is_healthy "$PASSWORD" && [ "$FORCE" != true ]; then
        log "Redis 已健康响应，无需修复"
        exit 0
    fi

    stop_redis "$PASSWORD"
    rewrite_appendonlydir
    start_redis

    for _ in $(seq 1 20); do
        if is_healthy "$PASSWORD"; then
            log "Redis 修复完成: $(redis_cli "$PASSWORD" ping)"
            log "Redis keys: $(redis_cli "$PASSWORD" dbsize)"
            exit 0
        fi
        sleep 1
    done

    die "Redis 重启后仍未健康响应，请检查日志"
}

main "$@"

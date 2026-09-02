#!/usr/bin/env bash
# Install a managed block of recommended SkyWalking alarm rules.

set -euo pipefail

SKYWALKING_HOME="${SKYWALKING_HOME:-$HOME/skywalking}"
CPU_HIGH="${CPU_HIGH:-85}"
MEMORY_HIGH="${MEMORY_HIGH:-90}"
SWAP_HIGH="${SWAP_HIGH:-50}"
FILESYSTEM_HIGH="${FILESYSTEM_HIGH:-85}"
MYSQL_CONNECTION_HIGH="${MYSQL_CONNECTION_HIGH:-85}"
MYSQL_SLOW_QUERIES_RATE="${MYSQL_SLOW_QUERIES_RATE:-0}"
REDIS_MEMORY_HIGH="${REDIS_MEMORY_HIGH:-85}"
REDIS_BLOCKED_CLIENTS="${REDIS_BLOCKED_CLIENTS:-0}"
ROCKETMQ_DISK_HIGH="${ROCKETMQ_DISK_HIGH:-85}"
ROCKETMQ_LATENCY_MS="${ROCKETMQ_LATENCY_MS:-60000}"
RESTART_SKYWALKING=false
OAP_HTTP_ENDPOINT="${OAP_HTTP_ENDPOINT:-127.0.0.1:12800}"
WEBHOOK_URLS=()

BEGIN_MARKER="  # BEGIN managed by shell/apm/skywalking/bin/setup-recommended-alarms.sh"
END_MARKER="  # END managed by shell/apm/skywalking/bin/setup-recommended-alarms.sh"
HOOK_BEGIN_MARKER="# BEGIN managed alarm hooks by shell/apm/skywalking/bin/setup-recommended-alarms.sh"
HOOK_END_MARKER="# END managed alarm hooks by shell/apm/skywalking/bin/setup-recommended-alarms.sh"

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
SkyWalking 推荐告警规则配置脚本

功能:
  在 alarm-settings.yml 的 rules 下维护一个可重复覆盖的告警区块。
  默认覆盖主机 CPU/内存/Swap/文件系统，以及 MySQL、Redis、RocketMQ 的关键指标。

用法:
  $0 [选项]

选项:
  --skywalking-home DIR       SkyWalking 安装目录，默认: $HOME/skywalking
  --cpu-high N                CPU 使用率阈值，默认: 85
  --memory-high N             内存使用率阈值，默认: 90
  --swap-high N               Swap 使用率阈值，默认: 50
  --filesystem-high N         文件系统使用率阈值，默认: 85
  --mysql-connection-high N   MySQL 连接占 max_connections 的比例阈值，默认: 85
  --mysql-slow-queries-rate N MySQL 慢查询每秒阈值，默认: 0
  --redis-memory-high N       Redis 内存使用率阈值，默认: 85
  --redis-blocked-clients N   Redis 阻塞客户端阈值，默认: 0
  --rocketmq-disk-high N      RocketMQ commitLog 磁盘比例阈值，默认: 85
  --rocketmq-latency-ms N     RocketMQ 消费延迟阈值，默认: 60000
  --webhook-url URL           配置 SkyWalking alarm webhook 通知地址，可重复传入多个
  --restart                   修改后重启 SkyWalking OAP 和 WebApp
  --oap-http-endpoint HOST:PORT
                              重启后健康检查地址，默认: 127.0.0.1:12800
  -h, --help                  显示帮助

示例:
  $0 --skywalking-home /opt/skywalking --restart
  $0 --memory-high 85 --filesystem-high 80
  $0 --webhook-url http://127.0.0.1:18080/skywalking/alarm --restart
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --skywalking-home)
                SKYWALKING_HOME="${2:-}"; shift 2 ;;
            --skywalking-home=*)
                SKYWALKING_HOME="${1#*=}"; shift ;;
            --cpu-high)
                CPU_HIGH="${2:-}"; shift 2 ;;
            --cpu-high=*)
                CPU_HIGH="${1#*=}"; shift ;;
            --memory-high)
                MEMORY_HIGH="${2:-}"; shift 2 ;;
            --memory-high=*)
                MEMORY_HIGH="${1#*=}"; shift ;;
            --swap-high)
                SWAP_HIGH="${2:-}"; shift 2 ;;
            --swap-high=*)
                SWAP_HIGH="${1#*=}"; shift ;;
            --filesystem-high)
                FILESYSTEM_HIGH="${2:-}"; shift 2 ;;
            --filesystem-high=*)
                FILESYSTEM_HIGH="${1#*=}"; shift ;;
            --mysql-connection-high)
                MYSQL_CONNECTION_HIGH="${2:-}"; shift 2 ;;
            --mysql-connection-high=*)
                MYSQL_CONNECTION_HIGH="${1#*=}"; shift ;;
            --mysql-slow-queries-rate)
                MYSQL_SLOW_QUERIES_RATE="${2:-}"; shift 2 ;;
            --mysql-slow-queries-rate=*)
                MYSQL_SLOW_QUERIES_RATE="${1#*=}"; shift ;;
            --redis-memory-high)
                REDIS_MEMORY_HIGH="${2:-}"; shift 2 ;;
            --redis-memory-high=*)
                REDIS_MEMORY_HIGH="${1#*=}"; shift ;;
            --redis-blocked-clients)
                REDIS_BLOCKED_CLIENTS="${2:-}"; shift 2 ;;
            --redis-blocked-clients=*)
                REDIS_BLOCKED_CLIENTS="${1#*=}"; shift ;;
            --rocketmq-disk-high)
                ROCKETMQ_DISK_HIGH="${2:-}"; shift 2 ;;
            --rocketmq-disk-high=*)
                ROCKETMQ_DISK_HIGH="${1#*=}"; shift ;;
            --rocketmq-latency-ms)
                ROCKETMQ_LATENCY_MS="${2:-}"; shift 2 ;;
            --rocketmq-latency-ms=*)
                ROCKETMQ_LATENCY_MS="${1#*=}"; shift ;;
            --webhook-url)
                WEBHOOK_URLS+=("${2:-}"); shift 2 ;;
            --webhook-url=*)
                WEBHOOK_URLS+=("${1#*=}"); shift ;;
            --restart)
                RESTART_SKYWALKING=true; shift ;;
            --oap-http-endpoint)
                OAP_HTTP_ENDPOINT="${2:-}"; shift 2 ;;
            --oap-http-endpoint=*)
                OAP_HTTP_ENDPOINT="${1#*=}"; shift ;;
            -h|--help)
                show_help; exit 0 ;;
            *)
                die "未知选项: $1" ;;
        esac
    done

    [ -n "$SKYWALKING_HOME" ] || die "SkyWalking 安装目录不能为空"
    for url in "${WEBHOOK_URLS[@]}"; do
        [ -n "$url" ] || die "--webhook-url 不能为空"
    done
    for item in CPU_HIGH MEMORY_HIGH SWAP_HIGH FILESYSTEM_HIGH MYSQL_CONNECTION_HIGH MYSQL_SLOW_QUERIES_RATE REDIS_MEMORY_HIGH REDIS_BLOCKED_CLIENTS ROCKETMQ_DISK_HIGH ROCKETMQ_LATENCY_MS; do
        [[ "${!item}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$item 必须是数字: ${!item}"
    done
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

python_bin() {
    if command_exists python3; then
        echo python3
    elif command_exists python; then
        echo python
    else
        die "未找到 python3/python，无法安全修改 alarm-settings.yml"
    fi
}

backup_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

write_alarm_rules() {
    local alarm_file="$SKYWALKING_HOME/config/alarm-settings.yml"
    local py

    [ -f "$alarm_file" ] || die "未找到告警配置: $alarm_file"
    backup_file "$alarm_file"
    py="$(python_bin)"

    "$py" - "$alarm_file" "$BEGIN_MARKER" "$END_MARKER" \
        "$CPU_HIGH" "$MEMORY_HIGH" "$SWAP_HIGH" "$FILESYSTEM_HIGH" \
        "$MYSQL_CONNECTION_HIGH" "$MYSQL_SLOW_QUERIES_RATE" \
        "$REDIS_MEMORY_HIGH" "$REDIS_BLOCKED_CLIENTS" \
        "$ROCKETMQ_DISK_HIGH" "$ROCKETMQ_LATENCY_MS" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
cpu, memory, swap, filesystem = sys.argv[4:8]
mysql_conn, mysql_slow = sys.argv[8:10]
redis_memory, redis_blocked = sys.argv[10:12]
rocketmq_disk, rocketmq_latency = sys.argv[12:14]

block = f"""{begin}
  vm_cpu_high_rule:
    expression: sum(meter_vm_cpu_total_percentage > {cpu}) >= 3
    period: 5
    silence-period: 10
    message: Host {{name}} CPU usage is higher than {cpu}% in 3 minutes of last 5 minutes.
  vm_memory_high_rule:
    expression: sum(meter_vm_memory_used / meter_vm_memory_total * 100 > {memory}) >= 3
    period: 5
    silence-period: 10
    message: Host {{name}} memory usage is higher than {memory}% in 3 minutes of last 5 minutes.
  vm_swap_high_rule:
    expression: sum(meter_vm_memory_swap_percentage > {swap}) >= 3
    period: 5
    silence-period: 10
    message: Host {{name}} swap usage is higher than {swap}% in 3 minutes of last 5 minutes.
  vm_filesystem_high_rule:
    expression: sum(meter_vm_filesystem_percentage > {filesystem}) >= 3
    period: 5
    silence-period: 10
    message: Host {{name}} filesystem usage is higher than {filesystem}% in 3 minutes of last 5 minutes.
  mysql_connections_high_rule:
    expression: sum(meter_mysql_instance_threads_connected / meter_mysql_instance_max_connections * 100 > {mysql_conn}) >= 3
    period: 5
    silence-period: 10
    message: MySQL {{name}} connections use more than {mysql_conn}% of max_connections in 3 minutes of last 5 minutes.
  mysql_slow_queries_high_rule:
    expression: sum(meter_mysql_instance_slow_queries_rate > {mysql_slow}) >= 3
    period: 5
    silence-period: 10
    message: MySQL {{name}} slow query rate is higher than {mysql_slow}/s in 3 minutes of last 5 minutes.
  redis_memory_high_rule:
    expression: sum(meter_redis_instance_memory_usage > {redis_memory}) >= 3
    period: 5
    silence-period: 10
    message: Redis {{name}} memory usage is higher than {redis_memory}% in 3 minutes of last 5 minutes.
  redis_blocked_clients_rule:
    expression: sum(meter_redis_instance_redis_blocked_clients > {redis_blocked}) >= 3
    period: 5
    silence-period: 10
    message: Redis {{name}} blocked clients is higher than {redis_blocked} in 3 minutes of last 5 minutes.
  rocketmq_commitlog_disk_high_rule:
    expression: sum(meter_rocketmq_cluster_commitLog_disk_ratio > {rocketmq_disk}) >= 3
    period: 5
    silence-period: 10
    message: RocketMQ {{name}} commitLog disk ratio is higher than {rocketmq_disk}% in 3 minutes of last 5 minutes.
  rocketmq_consumer_latency_high_rule:
    expression: sum(meter_rocketmq_cluster_max_consumer_latency > {rocketmq_latency}) >= 3
    period: 5
    silence-period: 10
    message: RocketMQ {{name}} max consumer latency is higher than {rocketmq_latency}ms in 3 minutes of last 5 minutes.
{end}
"""

text = path.read_text()
text = re.sub(re.escape(begin) + r"[\s\S]*?" + re.escape(end) + r"\n?", "", text)
if not re.search(r"^rules:\s*$", text, flags=re.MULTILINE):
    raise SystemExit("alarm-settings.yml 中未找到顶层 rules:")
text = re.sub(r"^rules:\s*$", "rules:\n" + block.rstrip(), text, count=1, flags=re.MULTILINE)
path.write_text(text)
PY

    log "已写入推荐告警规则: $alarm_file"
}

write_alarm_hooks() {
    local alarm_file="$SKYWALKING_HOME/config/alarm-settings.yml"
    local py

    [ "${#WEBHOOK_URLS[@]}" -gt 0 ] || return 0
    [ -f "$alarm_file" ] || die "未找到告警配置: $alarm_file"
    backup_file "$alarm_file"
    py="$(python_bin)"

    "$py" - "$alarm_file" "$HOOK_BEGIN_MARKER" "$HOOK_END_MARKER" "${WEBHOOK_URLS[@]}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
urls = sys.argv[4:]

text = path.read_text()
text = re.sub(re.escape(begin) + r"[\s\S]*?" + re.escape(end) + r"\n?", "", text)
if re.search(r"^hooks:\s*$", text, flags=re.MULTILINE):
    raise SystemExit("alarm-settings.yml 已存在非受管 hooks: 配置，请先手动合并，避免覆盖已有通知配置")

lines = [
    begin,
    "hooks:",
    "  webhook:",
    "    default:",
    "      is-default: true",
    "      urls:",
]
for url in urls:
    safe_url = url.replace("\\", "\\\\").replace('"', '\\"')
    lines.append(f'        - "{safe_url}"')
lines.append(end)

if not text.endswith("\n"):
    text += "\n"
text += "\n".join(lines) + "\n"
path.write_text(text)
PY

    log "已写入 SkyWalking 告警 webhook 通知地址: ${WEBHOOK_URLS[*]}"
}

find_skywalking_pids() {
    if command_exists pgrep; then
        pgrep -f 'org.apache.skywalking.oap.server.starter.OAPServerStartUp|org.apache.skywalking.oap.server.webapp.ApplicationStartUp' 2>/dev/null || true
    else
        ps -ef | awk '/org\.apache\.skywalking\.oap\.server\.(starter\.OAPServerStartUp|webapp\.ApplicationStartUp)/ && !/awk/ {print $2}'
    fi
}

restart_skywalking() {
    local pids pid count startup_script
    startup_script="$SKYWALKING_HOME/bin/startup.sh"
    [ -x "$startup_script" ] || die "未找到可执行启动脚本: $startup_script"

    pids="$(find_skywalking_pids)"
    if [ -n "$pids" ]; then
        log "停止 SkyWalking 进程: $pids"
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        count=0
        while [ "$count" -lt 45 ]; do
            if [ -z "$(find_skywalking_pids)" ]; then
                break
            fi
            sleep 1
            count=$((count + 1))
        done
    fi

    if [ -n "$(find_skywalking_pids)" ]; then
        warn "SkyWalking 未能在 45 秒内退出，将发送 KILL"
        for pid in $(find_skywalking_pids); do
            kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 2
    fi

    log "启动 SkyWalking: $startup_script"
    (cd "$SKYWALKING_HOME" && "$startup_script" >/dev/null 2>&1 &)

    if command_exists curl; then
        count=0
        while [ "$count" -lt 60 ]; do
            if curl -fsS -H 'Content-Type: application/json' \
                -d '{"query":"query { __typename }"}' \
                "http://${OAP_HTTP_ENDPOINT}/graphql" >/dev/null 2>&1; then
                log "SkyWalking OAP HTTP 已就绪: $OAP_HTTP_ENDPOINT"
                return 0
            fi
            sleep 2
            count=$((count + 1))
        done
        warn "未在等待时间内确认 OAP HTTP 就绪，请检查 $SKYWALKING_HOME/logs"
    fi
}

main() {
    parse_args "$@"
    write_alarm_rules
    write_alarm_hooks
    if [ "$RESTART_SKYWALKING" = true ]; then
        restart_skywalking
    else
        log "未重启 SkyWalking；告警规则通常需要重启 OAP 后生效"
    fi
}

main "$@"

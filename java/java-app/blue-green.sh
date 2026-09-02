#!/usr/bin/env bash

# 双节点 Java 应用蓝绿发布编排。
# 192.168.1.5=blue、192.168.1.6=green；Nginx 稳定入口默认位于 blue 节点。

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$SCRIPT_DIR/deploy.sh}"
readonly SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30)

BLUE_REMOTE="${BLUE_REMOTE:-dev@192.168.1.5}"
GREEN_REMOTE="${GREEN_REMOTE:-dev@192.168.1.6}"
BLUE_IP="${BLUE_IP:-192.168.1.5}"
GREEN_IP="${GREEN_IP:-192.168.1.6}"
LB_REMOTE="${LB_REMOTE:-dev@192.168.1.5}"
NGINX_DIR="${NGINX_DIR:-/data/dev/nginx}"
GATEWAY_PORT="${GATEWAY_PORT:-8000}"
NACOS_GROUP_PREFIX="${NACOS_GROUP_PREFIX:-DEV}"
SKYWALKING_BACKEND="${SKYWALKING_BACKEND:-192.168.1.5:11800}"

log() { printf '%s [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

show_help() {
    cat <<'EOF'
双节点 Java 应用蓝绿发布工具

用法:
  blue-green.sh prepare
  blue-green.sh status
  blue-green.sh deploy blue|green [deploy.sh 参数]
  blue-green.sh switch blue|green

流程:
  1. prepare：写入两台节点的颜色、Nacos 服务分组、注册 IP 和 SkyWalking 地址。
  2. deploy：仅向指定颜色部署并完成应用健康检查。
  3. switch：检查目标 Gateway 端口，通过 Nginx 配置校验后原子切流。
  4. 回滚只需 switch 到上一颜色，不依赖应用目录备份。

默认拓扑:
  blue  = dev@192.168.1.5，服务分组 DEV_BLUE
  green = dev@192.168.1.6，服务分组 DEV_GREEN
  稳定入口 Nginx = dev@192.168.1.5:/data/dev/nginx
  Gateway = 8000，SkyWalking OAP = 192.168.1.5:11800

可通过同名环境变量覆盖以上默认值。
EOF
}

validate_color() {
    case "${1:-}" in blue|green) return 0 ;; *) die "颜色仅支持 blue 或 green" ;; esac
}

color_remote() { [[ "$1" == blue ]] && printf '%s\n' "$BLUE_REMOTE" || printf '%s\n' "$GREEN_REMOTE"; }
color_ip() { [[ "$1" == blue ]] && printf '%s\n' "$BLUE_IP" || printf '%s\n' "$GREEN_IP"; }
color_group() {
    local color=$1
    printf '%s_%s\n' "$NACOS_GROUP_PREFIX" "$(printf '%s' "$color" | tr '[:lower:]' '[:upper:]')"
}

validate_value() {
    local label=$1 value=$2 pattern=$3
    [[ "$value" =~ $pattern ]] || die "$label 包含不安全字符: $value"
}

prepare_node() {
    local color=$1 remote ip group
    remote=$(color_remote "$color")
    ip=$(color_ip "$color")
    group=$(color_group "$color")
    validate_value "IP" "$ip" '^[0-9.]+$'
    validate_value "服务分组" "$group" '^[A-Za-z0-9._-]+$'

    log "配置 $color 节点: $remote (group=$group, ip=$ip)"
    ssh "${SSH_OPTS[@]}" "$remote" \
        "mkdir -p \"\$HOME/webapps\"; touch \"\$HOME/webapps/.env\"; grep -v -E '^(DEPLOY_COLOR|NACOS_DISCOVERY_GROUP|NACOS_GROUP|SPRING_CLOUD_NACOS_DISCOVERY_GROUP|NACOS_DISCOVERY_IP|SPRING_CLOUD_NACOS_DISCOVERY_IP|SKYWALKING_ENABLED|SKYWALKING_BACKEND_SERVICES|SW_AGENT_COLLECTOR_BACKEND_SERVICES)=' \"\$HOME/webapps/.env\" > \"\$HOME/webapps/.env.next\" || true; printf '%s\n' 'DEPLOY_COLOR=$color' 'NACOS_DISCOVERY_GROUP=$group' 'NACOS_GROUP=$group' 'SPRING_CLOUD_NACOS_DISCOVERY_GROUP=$group' 'NACOS_DISCOVERY_IP=$ip' 'SPRING_CLOUD_NACOS_DISCOVERY_IP=$ip' 'SKYWALKING_ENABLED=true' 'SKYWALKING_BACKEND_SERVICES=$SKYWALKING_BACKEND' 'SW_AGENT_COLLECTOR_BACKEND_SERVICES=$SKYWALKING_BACKEND' >> \"\$HOME/webapps/.env.next\"; mv \"\$HOME/webapps/.env.next\" \"\$HOME/webapps/.env\""
}

prepare() {
    prepare_node blue
    prepare_node green
    log "节点环境已准备；服务发现分组无需在 Nacos 中预创建"
}

status() {
    local color remote ip group
    for color in blue green; do
        remote=$(color_remote "$color")
        ip=$(color_ip "$color")
        group=$(color_group "$color")
        printf '%-6s %-24s group=%-10s gateway=' "$color" "$remote" "$group"
        if ssh "${SSH_OPTS[@]}" "$remote" "timeout 2 bash -c '</dev/tcp/127.0.0.1/$GATEWAY_PORT'" >/dev/null 2>&1; then
            printf 'UP (%s:%s)\n' "$ip" "$GATEWAY_PORT"
        else
            printf 'DOWN (%s:%s)\n' "$ip" "$GATEWAY_PORT"
        fi
    done
    printf 'active='
    ssh "${SSH_OPTS[@]}" "$LB_REMOTE" "cat '$NGINX_DIR/conf/conf.d/.active-color' 2>/dev/null || printf 'not-initialized\\n'"
}

deploy_color() {
    local color=$1
    shift
    validate_color "$color"
    [[ -x "$DEPLOY_SCRIPT" ]] || die "部署脚本不可执行: $DEPLOY_SCRIPT"

    local remote ip group
    remote=$(color_remote "$color")
    ip=$(color_ip "$color")
    group=$(color_group "$color")
    log "仅部署 $color 节点: $remote"
    "$DEPLOY_SCRIPT" --remotes "$remote" --profile dev \
        --nacos-group "$group" --nacos-ip "$ip" --deploy-color "$color" \
        --skywalking --skywalking-backend "$SKYWALKING_BACKEND" --fail-fast "$@"
}

switch_color() {
    local color=$1
    validate_color "$color"
    local remote ip config_tmp remote_tmp
    remote=$(color_remote "$color")
    ip=$(color_ip "$color")

    log "检查目标 Gateway: $remote -> $ip:$GATEWAY_PORT"
    ssh "${SSH_OPTS[@]}" "$remote" "timeout 3 bash -c '</dev/tcp/127.0.0.1/$GATEWAY_PORT'" \
        || die "$color Gateway 未监听 $GATEWAY_PORT，拒绝切流"

    config_tmp=$(mktemp)
    remote_tmp="/tmp/gateway.app.next.$$"
    trap 'rm -f "$config_tmp"' EXIT
    printf '%s\n' \
        '# 由 blue-green.sh 管理，请勿手工修改' \
        'upstream gateway {' \
        '    zone gateway_blue_green 64k;' \
        "    server $ip:$GATEWAY_PORT max_fails=2 fail_timeout=10s;" \
        '    keepalive 64;' \
        '}' > "$config_tmp"

    rsync -a -e "ssh ${SSH_OPTS[*]}" "$config_tmp" "$LB_REMOTE:$remote_tmp"
    log "测试 Nginx 配置并切换稳定入口到 $color"
    ssh "${SSH_OPTS[@]}" "$LB_REMOTE" \
        "set -e; target='$NGINX_DIR/conf/conf.d/gateway.app'; previous='/tmp/gateway.app.previous.$$'; cp \"\$target\" \"\$previous\"; mv '$remote_tmp' \"\$target\"; if sudo -n '$NGINX_DIR/sbin/nginx' -c '$NGINX_DIR/conf/nginx.conf' -t && sudo -n '$NGINX_DIR/sbin/nginx' -c '$NGINX_DIR/conf/nginx.conf' -s reload; then printf '%s\\n' '$color' > '$NGINX_DIR/conf/conf.d/.active-color'; rm -f \"\$previous\"; else cp \"\$previous\" \"\$target\"; sudo -n '$NGINX_DIR/sbin/nginx' -c '$NGINX_DIR/conf/nginx.conf' -s reload || true; rm -f \"\$previous\"; exit 1; fi"
    rm -f "$config_tmp"
    trap - EXIT
    log "切流完成，稳定入口当前指向 $color ($ip:$GATEWAY_PORT)"
}

main() {
    local command=${1:-}
    shift || true
    case "$command" in
        prepare) [[ $# -eq 0 ]] || die "prepare 不接受额外参数"; prepare ;;
        status) [[ $# -eq 0 ]] || die "status 不接受额外参数"; status ;;
        deploy) [[ $# -ge 1 ]] || die "deploy 需要颜色"; local color=$1; shift; deploy_color "$color" "$@" ;;
        switch) [[ $# -eq 1 ]] || die "switch 需要且仅需要颜色"; switch_color "$1" ;;
        -h|--help|help|'') show_help ;;
        *) die "未知命令: $command" ;;
    esac
}

main "$@"

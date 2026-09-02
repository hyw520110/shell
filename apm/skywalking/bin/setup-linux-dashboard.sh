#!/usr/bin/env bash
# Tune SkyWalking OS_LINUX dashboard defaults for host memory readability.

set -euo pipefail

SKYWALKING_HOME="${SKYWALKING_HOME:-$HOME/skywalking}"
MEMORY_UNIT="${SKYWALKING_MEMORY_UNIT:-auto}"
NODE_EXPORTER_TARGET="${NODE_EXPORTER_TARGET:-127.0.0.1:9100}"
AUTO_GB_THRESHOLD_GIB="${AUTO_GB_THRESHOLD_GIB:-16}"
APPLY_TEMPLATE_UPDATE=true
UPDATE_EXISTING_TEMPLATE=true
RESTART_SKYWALKING=false
OAP_HTTP_ENDPOINT="${OAP_HTTP_ENDPOINT:-127.0.0.1:12800}"
GRAPHQL_ENDPOINT="${GRAPHQL_ENDPOINT:-}"

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
SkyWalking Linux 主机面板优化脚本

功能:
  调整 SkyWalking OS_LINUX 初始面板中的内存显示单位。
  --unit auto 会按主机总内存自动选择 MB/GB，避免 128GB 机器显示成 75610 MB 这类不易读数值。

用法:
  $0 [选项]

选项:
  --skywalking-home DIR       SkyWalking 安装目录，默认: $HOME/skywalking
  --unit auto|mb|gb           内存显示单位，默认: auto
  --node-exporter-target HOST:PORT
                              auto 模式读取 node_exporter 的地址，默认: 127.0.0.1:9100
  --auto-gb-threshold-gib N   auto 模式选择 GB 的内存阈值，默认: 16
  --apply-template-update     将 application.yml 的 enableUpdateUITemplate 默认值设为 true，默认启用
  --no-template-update        只改模板文件，不改 enableUpdateUITemplate
  --update-existing-template  通过 GraphQL 更新已有 Linux-Service 模板，默认启用
  --no-existing-template-update
                              只改初始化模板文件，不调用 GraphQL 更新已有模板
  --restart                   修改后重启 SkyWalking OAP 和 WebApp，使模板/告警重新加载
  --oap-http-endpoint HOST:PORT
                              重启后健康检查地址，默认: 127.0.0.1:12800
  --graphql-endpoint URL      SkyWalking GraphQL 地址，默认: http://<oap-http-endpoint>/graphql
  -h, --help                  显示帮助

示例:
  $0 --unit auto --node-exporter-target 127.0.0.1:19100 --restart
  $0 --unit gb --skywalking-home /opt/skywalking
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --skywalking-home)
                SKYWALKING_HOME="${2:-}"; shift 2 ;;
            --skywalking-home=*)
                SKYWALKING_HOME="${1#*=}"; shift ;;
            --unit)
                MEMORY_UNIT="${2:-}"; shift 2 ;;
            --unit=*)
                MEMORY_UNIT="${1#*=}"; shift ;;
            --node-exporter-target)
                NODE_EXPORTER_TARGET="${2:-}"; shift 2 ;;
            --node-exporter-target=*)
                NODE_EXPORTER_TARGET="${1#*=}"; shift ;;
            --auto-gb-threshold-gib)
                AUTO_GB_THRESHOLD_GIB="${2:-}"; shift 2 ;;
            --auto-gb-threshold-gib=*)
                AUTO_GB_THRESHOLD_GIB="${1#*=}"; shift ;;
            --apply-template-update)
                APPLY_TEMPLATE_UPDATE=true; shift ;;
            --no-template-update)
                APPLY_TEMPLATE_UPDATE=false; shift ;;
            --update-existing-template)
                UPDATE_EXISTING_TEMPLATE=true; shift ;;
            --no-existing-template-update)
                UPDATE_EXISTING_TEMPLATE=false; shift ;;
            --restart)
                RESTART_SKYWALKING=true; shift ;;
            --oap-http-endpoint)
                OAP_HTTP_ENDPOINT="${2:-}"; shift 2 ;;
            --oap-http-endpoint=*)
                OAP_HTTP_ENDPOINT="${1#*=}"; shift ;;
            --graphql-endpoint)
                GRAPHQL_ENDPOINT="${2:-}"; shift 2 ;;
            --graphql-endpoint=*)
                GRAPHQL_ENDPOINT="${1#*=}"; shift ;;
            -h|--help)
                show_help; exit 0 ;;
            *)
                die "未知选项: $1" ;;
        esac
    done

    [ -n "$SKYWALKING_HOME" ] || die "SkyWalking 安装目录不能为空"
    [ -n "$NODE_EXPORTER_TARGET" ] || die "node_exporter 地址不能为空"
    if [ -z "$GRAPHQL_ENDPOINT" ]; then
        GRAPHQL_ENDPOINT="http://${OAP_HTTP_ENDPOINT}/graphql"
    fi
    case "$(printf '%s' "$MEMORY_UNIT" | tr '[:upper:]' '[:lower:]')" in
        auto|mb|gb) ;;
        *) die "--unit 只能是 auto、mb 或 gb" ;;
    esac
    [[ "$AUTO_GB_THRESHOLD_GIB" =~ ^[0-9]+$ ]] || die "--auto-gb-threshold-gib 必须是整数"
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
        die "未找到 python3/python，无法安全修改 JSON/YAML 文件"
    fi
}

detect_memory_bytes() {
    local total=""

    if command_exists curl; then
        total="$(curl -fsS "http://${NODE_EXPORTER_TARGET}/metrics" 2>/dev/null \
            | awk '$1=="node_memory_MemTotal_bytes" || $1=="node_memory_total_bytes" {printf "%.0f", $2; exit}' || true)"
    fi

    if [ -z "$total" ] && [ -r /proc/meminfo ]; then
        total="$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024; exit}' /proc/meminfo)"
    fi

    if [ -z "$total" ] && command_exists sysctl; then
        total="$(sysctl -n hw.memsize 2>/dev/null || true)"
    fi

    printf '%s' "$total"
}

resolve_unit() {
    local unit total threshold
    unit="$(printf '%s' "$MEMORY_UNIT" | tr '[:upper:]' '[:lower:]')"
    if [ "$unit" != "auto" ]; then
        printf '%s' "$unit"
        return 0
    fi

    total="$(detect_memory_bytes)"
    if [ -z "$total" ]; then
        warn "未能读取主机总内存，auto 模式回退为 MB"
        printf 'mb'
        return 0
    fi

    threshold=$((AUTO_GB_THRESHOLD_GIB * 1024 * 1024 * 1024))
    if [ "$total" -ge "$threshold" ]; then
        log "检测到主机总内存约 $((total / 1024 / 1024 / 1024)) GiB，面板内存单位使用 GB" >&2
        printf 'gb'
    else
        log "检测到主机总内存约 $((total / 1024 / 1024)) MiB，面板内存单位使用 MB" >&2
        printf 'mb'
    fi
}

backup_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

patch_dashboard_template() {
    local unit="$1"
    local template_file="$SKYWALKING_HOME/config/ui-initialized-templates/os_linux/linux-service.json"
    local py

    [ -f "$template_file" ] || die "未找到 Linux 面板模板: $template_file"
    backup_file "$template_file"
    py="$(python_bin)"

    "$py" - "$template_file" "$unit" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
unit = sys.argv[2].lower()
text = path.read_text()

memory_metrics = [
    "meter_vm_memory_used",
    "meter_vm_memory_total",
    "meter_vm_memory_available",
    "meter_vm_memory_buff_cache",
    "meter_vm_memory_swap_free",
    "meter_vm_memory_swap_total",
    "avg(meter_vm_memory_used)",
]

for metric in memory_metrics:
    text = text.replace(f"{metric}/1024/1024/1024", f"{metric}/1024/1024")

if unit == "gb":
    for metric in memory_metrics:
        text = text.replace(f"{metric}/1024/1024", f"{metric}/1024/1024/1024")
    text = text.replace('"title": "Memory RAM (MB)"', '"title": "Memory RAM (GB)"')
    text = text.replace('"title": "Memory Swap (MB)"', '"title": "Memory Swap (GB)"')
    text = re.sub(r'("title": "Memory RAM Usage"[\s\S]*?"unit": )"MB"', r'\1"GB"', text, count=1)
else:
    text = text.replace('"title": "Memory RAM (GB)"', '"title": "Memory RAM (MB)"')
    text = text.replace('"title": "Memory Swap (GB)"', '"title": "Memory Swap (MB)"')
    text = re.sub(r'("title": "Memory RAM Usage"[\s\S]*?"unit": )"GB"', r'\1"MB"', text, count=1)

path.write_text(text)
PY

    log "已更新 Linux 面板内存单位: $template_file ($unit)"
}

patch_template_update_switch() {
    local app_file="$SKYWALKING_HOME/config/application.yml"
    local py

    [ "$APPLY_TEMPLATE_UPDATE" = true ] || return 0
    [ -f "$app_file" ] || die "未找到 application.yml: $app_file"
    backup_file "$app_file"
    py="$(python_bin)"

    "$py" - "$app_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
new = re.sub(
    r'enableUpdateUITemplate:\s*\$\{SW_ENABLE_UPDATE_UI_TEMPLATE:(?:false|true)\}',
    'enableUpdateUITemplate: ${SW_ENABLE_UPDATE_UI_TEMPLATE:true}',
    text,
    count=1,
)
if new == text:
    new = re.sub(r'enableUpdateUITemplate:\s*false', 'enableUpdateUITemplate: true', text, count=1)
path.write_text(new)
PY

    log "已开启 UI 模板更新默认开关: $app_file"
}

update_existing_dashboard_template() {
    local template_file="$SKYWALKING_HOME/config/ui-initialized-templates/os_linux/linux-service.json"
    local py payload response

    [ "$UPDATE_EXISTING_TEMPLATE" = true ] || return 0
    if ! command_exists curl; then
        warn "未找到 curl，跳过已有 Linux-Service 面板更新"
        return 0
    fi
    [ -f "$template_file" ] || die "未找到 Linux 面板模板: $template_file"
    py="$(python_bin)"
    payload="$(mktemp "${TMPDIR:-/tmp}/skywalking-linux-template.XXXXXX.json")"
    response="$(mktemp "${TMPDIR:-/tmp}/skywalking-linux-template-rsp.XXXXXX.json")"

    "$py" - "$template_file" "$payload" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
payload_path = Path(sys.argv[2])
template = json.loads(template_path.read_text())
configuration = template[0]["configuration"]
payload = {
    "query": "mutation ChangeLinuxTemplate($setting: DashboardSetting!) { changeTemplate(setting: $setting) { id status message } }",
    "variables": {
        "setting": {
            "id": "Linux-Service",
            "configuration": json.dumps(configuration, ensure_ascii=False),
        }
    },
}
payload_path.write_text(json.dumps(payload))
PY

    if ! curl -fsS -H 'Content-Type: application/json' --data-binary "@$payload" "$GRAPHQL_ENDPOINT" >"$response"; then
        warn "调用 GraphQL 更新 Linux-Service 面板失败，跳过；如需当前 UI 生效，请确认 enableUpdateUITemplate 已启用并重试"
        rm -f "$payload" "$response"
        return 0
    fi

    if ! "$py" - "$response" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
if data.get("errors"):
    print("[WARN] GraphQL 返回错误: " + json.dumps(data["errors"], ensure_ascii=False), file=sys.stderr)
    raise SystemExit(2)
status = data.get("data", {}).get("changeTemplate", {})
if not status.get("status"):
    print("[WARN] Linux-Service 面板更新未成功: " + json.dumps(status, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(2)
print("[INFO] 已通过 GraphQL 更新已有 Linux-Service 面板: " + status.get("id", "Linux-Service"))
PY
    then
        rm -f "$payload" "$response"
        return 0
    fi
    rm -f "$payload" "$response"
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
    local unit
    parse_args "$@"
    unit="$(resolve_unit)"
    patch_dashboard_template "$unit"
    patch_template_update_switch
    if [ "$RESTART_SKYWALKING" = true ]; then
        restart_skywalking
    fi
    update_existing_dashboard_template
    if [ "$RESTART_SKYWALKING" != true ]; then
        log "未重启 SkyWalking；若 GraphQL 更新失败，请使用 --restart 或手动重启 OAP/WebApp"
    fi
}

main "$@"

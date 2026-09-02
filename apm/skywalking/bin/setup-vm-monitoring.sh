#!/usr/bin/env bash
# Wire node_exporter metrics into SkyWalking through OpenTelemetry Collector.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_EXPORTER_SCRIPT="$SCRIPT_DIR/../../../monitor/prometheus/bin/start_node_exporter.sh"

OTEL_COLLECTOR_VERSION="${OTEL_COLLECTOR_VERSION:-latest}"
INSTALL_DIR="${OTEL_COLLECTOR_INSTALL_DIR:-$HOME/otel-collector}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
CONFIG_FILE="${OTEL_COLLECTOR_CONFIG:-$INSTALL_DIR/config/vm-to-skywalking.yaml}"
LOG_DIR="${OTEL_COLLECTOR_LOG_DIR:-$INSTALL_DIR/logs}"

NODE_EXPORTER_TARGET="${NODE_EXPORTER_TARGET:-127.0.0.1:9100}"
EFFECTIVE_NODE_EXPORTER_TARGET="$NODE_EXPORTER_TARGET"
OAP_ENDPOINT="${OAP_ENDPOINT:-127.0.0.1:11800}"
HOST_NAME="${HOST_NAME:-$(hostname)}"
SERVICE_NAME="${SERVICE_NAME:-$HOST_NAME}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15s}"
TELEMETRY_ADDRESS="${TELEMETRY_ADDRESS:-127.0.0.1:18888}"
DARWIN_MEMORY_COMPAT="${DARWIN_MEMORY_COMPAT:-auto}"
DARWIN_COMPAT_PROXY_ADDRESS="${DARWIN_COMPAT_PROXY_ADDRESS:-127.0.0.1:19100}"
FORCE_RESTART=false
INSTALL_ONLY=false
START_NODE_EXPORTER=false

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
SkyWalking 主机指标接入脚本

功能:
  安装 OpenTelemetry Collector Contrib，抓取 node_exporter 指标，
  通过 OTLP gRPC 推送到 SkyWalking OAP 的 OS_LINUX 监控面板。

用法:
  $0 [选项]

选项:
  --node-exporter-target HOST:PORT   node_exporter 地址，默认: 127.0.0.1:9100
  --oap-endpoint HOST:PORT           SkyWalking OAP gRPC 地址，默认: 127.0.0.1:11800
  --host-name NAME                   SkyWalking 展示用主机名，默认: 当前 hostname
  --service-name NAME                VM 服务名，默认: host-name
  --scrape-interval DURATION         抓取间隔，默认: 15s
  --telemetry-address HOST:PORT      OTel 自身 telemetry 监听地址，默认: 127.0.0.1:18888
  --darwin-memory-compat MODE        macOS 内存指标兼容模式: auto|on|off，默认: auto
  --darwin-compat-proxy HOST:PORT    macOS 兼容代理地址，默认: 127.0.0.1:19100
  --install-dir DIR                  OTel Collector 安装目录，默认: $HOME/otel-collector
  --download-dir DIR                 下载目录，默认: $HOME/Downloads
  --version VERSION                  OTel Collector 版本，默认: latest
  --config FILE                      配置文件路径
  --start-node-exporter              如果本仓库存在 node_exporter 脚本，则先启动它
  --install-only                     只安装和生成配置，不启动
  -f, --force                        已运行时先停止再启动
  -h, --help                         显示帮助

前置条件:
  1. SkyWalking OAP 已启动，并监听 OTLP gRPC 端口 11800。
  2. node_exporter 已启动，并能访问 /metrics。
  3. SkyWalking OAP 需要启用 receiver-otel 和 vm 规则。
  4. CentOS/Ubuntu 等 Linux 主机直接使用 node_exporter 原始指标；
     macOS/Darwin 会自动启用兼容代理补齐 Linux 风格内存指标。

示例:
  $0 --node-exporter-target 127.0.0.1:9100 --oap-endpoint 127.0.0.1:11800 --host-name studio
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --node-exporter-target)
                NODE_EXPORTER_TARGET="${2:-}"; shift 2 ;;
            --node-exporter-target=*)
                NODE_EXPORTER_TARGET="${1#*=}"; shift ;;
            --oap-endpoint)
                OAP_ENDPOINT="${2:-}"; shift 2 ;;
            --oap-endpoint=*)
                OAP_ENDPOINT="${1#*=}"; shift ;;
            --host-name)
                HOST_NAME="${2:-}"; shift 2 ;;
            --host-name=*)
                HOST_NAME="${1#*=}"; shift ;;
            --service-name)
                SERVICE_NAME="${2:-}"; shift 2 ;;
            --service-name=*)
                SERVICE_NAME="${1#*=}"; shift ;;
            --scrape-interval)
                SCRAPE_INTERVAL="${2:-}"; shift 2 ;;
            --scrape-interval=*)
                SCRAPE_INTERVAL="${1#*=}"; shift ;;
            --telemetry-address)
                TELEMETRY_ADDRESS="${2:-}"; shift 2 ;;
            --telemetry-address=*)
                TELEMETRY_ADDRESS="${1#*=}"; shift ;;
            --darwin-memory-compat)
                DARWIN_MEMORY_COMPAT="${2:-}"; shift 2 ;;
            --darwin-memory-compat=*)
                DARWIN_MEMORY_COMPAT="${1#*=}"; shift ;;
            --darwin-compat-proxy)
                DARWIN_COMPAT_PROXY_ADDRESS="${2:-}"; shift 2 ;;
            --darwin-compat-proxy=*)
                DARWIN_COMPAT_PROXY_ADDRESS="${1#*=}"; shift ;;
            --install-dir|-d)
                INSTALL_DIR="${2:-}"; shift 2 ;;
            --install-dir=*|--dir=*)
                INSTALL_DIR="${1#*=}"; shift ;;
            --download-dir)
                DOWNLOAD_DIR="${2:-}"; shift 2 ;;
            --download-dir=*)
                DOWNLOAD_DIR="${1#*=}"; shift ;;
            --version)
                OTEL_COLLECTOR_VERSION="${2:-}"; shift 2 ;;
            --version=*)
                OTEL_COLLECTOR_VERSION="${1#*=}"; shift ;;
            --config)
                CONFIG_FILE="${2:-}"; shift 2 ;;
            --config=*)
                CONFIG_FILE="${1#*=}"; shift ;;
            --start-node-exporter)
                START_NODE_EXPORTER=true; shift ;;
            --install-only)
                INSTALL_ONLY=true; shift ;;
            -f|--force)
                FORCE_RESTART=true; shift ;;
            -h|--help)
                show_help; exit 0 ;;
            *)
                die "未知选项: $1" ;;
        esac
    done

    [ -n "$NODE_EXPORTER_TARGET" ] || die "node_exporter 地址不能为空"
    [ -n "$OAP_ENDPOINT" ] || die "OAP 地址不能为空"
    [ -n "$HOST_NAME" ] || die "host-name 不能为空"
    [ -n "$SERVICE_NAME" ] || die "service-name 不能为空"
    [ -n "$TELEMETRY_ADDRESS" ] || die "telemetry-address 不能为空"
    [[ "${TELEMETRY_ADDRESS##*:}" =~ ^[0-9]+$ ]] || die "telemetry-address 端口无效: $TELEMETRY_ADDRESS"
    case "$DARWIN_MEMORY_COMPAT" in
        auto|on|off) ;;
        *) die "darwin-memory-compat 只能是 auto、on 或 off" ;;
    esac
    [[ "${DARWIN_COMPAT_PROXY_ADDRESS##*:}" =~ ^[0-9]+$ ]] || die "darwin-compat-proxy 端口无效: $DARWIN_COMPAT_PROXY_ADDRESS"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

platform_suffix() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *) die "不支持的系统: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64) arch="amd64" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac

    echo "${os}_${arch}"
}

resolve_latest_version() {
    if [ "$OTEL_COLLECTOR_VERSION" != "latest" ]; then
        echo "$OTEL_COLLECTOR_VERSION"
        return 0
    fi

    if ! command_exists curl; then
        echo "0.131.0"
        return 0
    fi

    local latest_url version
    latest_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/open-telemetry/opentelemetry-collector-releases/releases/latest 2>/dev/null || true)"
    version="${latest_url##*/v}"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
    else
        echo "0.131.0"
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_file
    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"

    mkdir -p "$output_dir"

    if command_exists adl; then
        log "使用 adl 下载: $output_file"
        if adl "$url" "$output_dir" "$output_file"; then
            return 0
        fi
        warn "adl 下载失败，回退 curl/wget"
    fi

    if command_exists curl; then
        log "使用 curl 下载: $url"
        curl -fL -C - "$url" -o "$output"
    elif command_exists wget; then
        log "使用 wget 下载: $url"
        wget -c "$url" -O "$output"
    else
        die "未找到可用下载工具，请先安装 adl、curl 或 wget"
    fi
}

verify_archive() {
    local file="$1"
    [ -f "$file" ] && tar -tzf "$file" >/dev/null 2>&1
}

install_otel_collector() {
    local version suffix archive url root_name
    version="$(resolve_latest_version)"
    OTEL_COLLECTOR_VERSION="$version"
    suffix="$(platform_suffix)"
    archive="$DOWNLOAD_DIR/otelcol-contrib_${version}_${suffix}.tar.gz"
    url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}/otelcol-contrib_${version}_${suffix}.tar.gz"
    root_name="otelcol-contrib"

    mkdir -p "$INSTALL_DIR/bin" "$DOWNLOAD_DIR" "$LOG_DIR"

    if ! verify_archive "$archive"; then
        rm -f "$archive"
        download_file "$url" "$archive"
    fi

    tar -xzf "$archive" -C "$INSTALL_DIR/bin" "$root_name"
    chmod +x "$INSTALL_DIR/bin/$root_name"
    log "OpenTelemetry Collector 已安装: $INSTALL_DIR/bin/$root_name"
}

write_config() {
    local telemetry_host="${TELEMETRY_ADDRESS%:*}"
    local telemetry_port="${TELEMETRY_ADDRESS##*:}"
    [ -n "$telemetry_host" ] || telemetry_host="127.0.0.1"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: vm-monitoring
          scrape_interval: $SCRAPE_INTERVAL
          metrics_path: /metrics
          static_configs:
            - targets:
                - "$EFFECTIVE_NODE_EXPORTER_TARGET"
              labels:
                job_name: "vm-monitoring"
                host_name: "$HOST_NAME"
                node_identifier_host_name: "$HOST_NAME"
                service: "$SERVICE_NAME"

processors:
  resource:
    attributes:
      - key: host.name
        value: "$HOST_NAME"
        action: upsert
      - key: net.host.name
        value: "$HOST_NAME"
        action: upsert
      - key: service.name
        value: "$SERVICE_NAME"
        action: upsert
  batch:

exporters:
  otlp_grpc:
    endpoint: "$OAP_ENDPOINT"
    tls:
      insecure: true

service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: "$telemetry_host"
                port: $telemetry_port
  pipelines:
    metrics:
      receivers:
        - prometheus
      processors:
        - resource
        - batch
      exporters:
        - otlp_grpc
EOF
    log "已生成 OTel Collector 配置: $CONFIG_FILE"
}

write_darwin_memory_compat_proxy() {
    local proxy_script="$INSTALL_DIR/bin/node-exporter-darwin-compat-proxy.py"
    mkdir -p "$INSTALL_DIR/bin"
    cat > "$proxy_script" <<'PY'
#!/usr/bin/env python3
import argparse
import re
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

METRIC_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)\s+([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)$')

def parse_metrics(text):
    values = {}
    for line in text.splitlines():
        match = METRIC_RE.match(line)
        if match:
            try:
                values[match.group(1)] = float(match.group(2))
            except ValueError:
                pass
    return values

def metric_line(name, value):
    if value < 0:
        value = 0.0
    return f'{name} {value:g}'

def compat_lines(values, original):
    lines = []
    total = values.get('node_memory_total_bytes')
    free = values.get('node_memory_free_bytes')
    inactive = values.get('node_memory_inactive_bytes', 0.0)
    purgeable = values.get('node_memory_purgeable_bytes', 0.0)
    swap_total = values.get('node_memory_swap_total_bytes')
    swap_used = values.get('node_memory_swap_used_bytes', 0.0)

    def add(name, value):
        if value is None or name in values:
            return
        lines.append(f'# TYPE {name} gauge')
        lines.append(metric_line(name, value))

    available = None
    if free is not None:
        available = free + inactive
    cached = inactive + purgeable
    add('node_memory_MemTotal_bytes', total)
    add('node_memory_MemAvailable_bytes', available)
    add('node_memory_Buffers_bytes', 0.0)
    add('node_memory_Cached_bytes', cached)
    add('node_memory_SwapTotal_bytes', swap_total)
    if swap_total is not None:
        add('node_memory_SwapFree_bytes', swap_total - swap_used)
    return lines

class Handler(BaseHTTPRequestHandler):
    upstream = None

    def do_GET(self):
        if self.path not in ('/metrics', '/'):
            self.send_response(404)
            self.end_headers()
            return
        try:
            with urllib.request.urlopen(self.upstream, timeout=5) as response:
                text = response.read().decode('utf-8', errors='replace')
            values = parse_metrics(text)
            extra = compat_lines(values, text)
            body = text
            if extra:
                body = body.rstrip() + '\n\n# Darwin node_exporter compatibility metrics for SkyWalking vm.yaml\n' + '\n'.join(extra) + '\n'
            encoded = body.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except Exception as exc:
            body = f'upstream scrape failed: {exc}\n'.encode('utf-8')
            self.send_response(502)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--listen', required=True)
    parser.add_argument('--upstream', required=True)
    args = parser.parse_args()
    host, port_text = args.listen.rsplit(':', 1)
    Handler.upstream = args.upstream
    server = ThreadingHTTPServer((host, int(port_text)), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0

if __name__ == '__main__':
    sys.exit(main())
PY
    chmod +x "$proxy_script"
}

create_darwin_memory_compat_proxy_service() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    command_exists python3 || { warn "未找到 python3，跳过 macOS 内存指标兼容代理"; return 1; }

    write_darwin_memory_compat_proxy

    local label="org.skywalking.node_exporter.darwin_compat"
    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/$label.plist"
    local runtime_root="$plist_dir/runtime/$label"
    local runtime_bin="$runtime_root/bin"
    local runtime_logs="$runtime_root/logs"
    local runtime_script="$runtime_bin/node-exporter-darwin-compat-proxy.py"
    mkdir -p "$plist_dir" "$runtime_bin" "$runtime_logs"
    cp "$INSTALL_DIR/bin/node-exporter-darwin-compat-proxy.py" "$runtime_script"
    chmod +x "$runtime_script"

    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v python3)</string>
        <string>$runtime_script</string>
        <string>--listen</string>
        <string>$DARWIN_COMPAT_PROXY_ADDRESS</string>
        <string>--upstream</string>
        <string>http://$NODE_EXPORTER_TARGET/metrics</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF

    launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load -w "$plist_file"
    launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || true
    EFFECTIVE_NODE_EXPORTER_TARGET="$DARWIN_COMPAT_PROXY_ADDRESS"

    if command_exists curl; then
        local endpoint="http://$DARWIN_COMPAT_PROXY_ADDRESS/metrics"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            curl -fsS "$endpoint" >/dev/null 2>&1 && return 0
            sleep 1
        done
        warn "macOS 内存指标兼容代理暂不可访问: $endpoint"
    fi
}

prepare_node_exporter_target() {
    EFFECTIVE_NODE_EXPORTER_TARGET="$NODE_EXPORTER_TARGET"
    [ "$(uname -s)" = "Darwin" ] || return 0
    [ "$DARWIN_MEMORY_COMPAT" != "off" ] || return 0

    if [ "$DARWIN_MEMORY_COMPAT" = "on" ]; then
        create_darwin_memory_compat_proxy_service || return 0
        log "macOS 内存指标兼容代理已启用: $EFFECTIVE_NODE_EXPORTER_TARGET -> $NODE_EXPORTER_TARGET"
        return 0
    fi

    if command_exists curl && curl -fsS "http://$NODE_EXPORTER_TARGET/metrics" | grep -q '^node_memory_MemTotal_bytes'; then
        return 0
    fi
    create_darwin_memory_compat_proxy_service || return 0
    log "macOS 内存指标兼容代理已启用: $EFFECTIVE_NODE_EXPORTER_TARGET -> $NODE_EXPORTER_TARGET"
}

check_tcp() {
    local host_port="$1"
    local host="${host_port%:*}"
    local port="${host_port##*:}"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    if command_exists nc; then
        nc -z "$host" "$port" >/dev/null 2>&1
    else
        bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
    fi
}

start_node_exporter_if_requested() {
    if [ "$START_NODE_EXPORTER" != true ]; then
        return 0
    fi

    if [ ! -f "$NODE_EXPORTER_SCRIPT" ]; then
        warn "node_exporter 启动脚本不存在，跳过: $NODE_EXPORTER_SCRIPT"
        return 0
    fi

    log "启动 node_exporter..."
    bash "$NODE_EXPORTER_SCRIPT"
}

validate_inputs() {
    local exporter_url="http://$EFFECTIVE_NODE_EXPORTER_TARGET/metrics"
    if command_exists curl; then
        if curl -fsS "$exporter_url" >/dev/null 2>&1; then
            log "node_exporter 指标端点可访问: $exporter_url"
        else
            warn "node_exporter 指标端点暂不可访问: $exporter_url"
        fi
    fi

    if check_tcp "$OAP_ENDPOINT"; then
        log "SkyWalking OAP OTLP gRPC 端口可连接: $OAP_ENDPOINT"
    else
        warn "SkyWalking OAP OTLP gRPC 端口暂不可连接: $OAP_ENDPOINT"
    fi
}

stop_existing_collector() {
    local pids
    pids="$(pgrep -f "$INSTALL_DIR/bin/otelcol-contrib.*$CONFIG_FILE" 2>/dev/null || true)"
    pids="$pids
$(pgrep -f "org.skywalking.otelcol.vm/bin/otelcol-contrib" 2>/dev/null || true)"
    pids="$(printf '%s\n' "$pids" | awk 'NF && !seen[$0]++')"
    [ -n "$pids" ] || return 0

    log "停止已有 OTel Collector: $pids"
    kill $pids 2>/dev/null || true
    sleep 2
}

macos_service_running() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    launchctl print "gui/$(id -u)/org.skywalking.otelcol.vm" 2>/dev/null | grep -q "state = running"
}

create_linux_service() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$EUID" -eq 0 ] || return 1
    command_exists systemctl || return 1

    cat > /etc/systemd/system/otelcol-vm-skywalking.service <<EOF
[Unit]
Description=OpenTelemetry Collector for Linux VM to SkyWalking
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/otelcol-contrib --config $CONFIG_FILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable otelcol-vm-skywalking
    systemctl restart otelcol-vm-skywalking
}

create_macos_service() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    [ -x "$INSTALL_DIR/bin/otelcol-contrib" ] || return 1

    local label="org.skywalking.otelcol.vm"
    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/$label.plist"
    local runtime_root="$plist_dir/runtime/$label"
    local runtime_bin="$runtime_root/bin"
    local runtime_conf="$runtime_root/conf"
    local runtime_logs="$runtime_root/logs"
    mkdir -p "$plist_dir" "$runtime_bin" "$runtime_conf" "$runtime_logs"
    cp "$INSTALL_DIR/bin/otelcol-contrib" "$runtime_bin/otelcol-contrib"
    cp "$CONFIG_FILE" "$runtime_conf/vm-to-skywalking.yaml"
    chmod +x "$runtime_bin/otelcol-contrib"

    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runtime_bin/otelcol-contrib</string>
        <string>--config</string>
        <string>$runtime_conf/vm-to-skywalking.yaml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF

    launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load -w "$plist_file"
    launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || true
}

start_collector() {
    start_node_exporter_if_requested

    if [ ! -x "$INSTALL_DIR/bin/otelcol-contrib" ]; then
        install_otel_collector
    fi
    prepare_node_exporter_target
    write_config
    validate_inputs

    if [ "$INSTALL_ONLY" = true ]; then
        log "已完成安装和配置，未启动 OTel Collector"
        return 0
    fi

    if [ "$FORCE_RESTART" = true ]; then
        stop_existing_collector
    elif pgrep -f "$INSTALL_DIR/bin/otelcol-contrib.*$CONFIG_FILE" >/dev/null 2>&1; then
        log "OTel Collector 已经在运行"
        return 0
    fi

    if create_linux_service; then
        log "OTel Collector 已通过 systemd 启动"
    elif create_macos_service; then
        log "OTel Collector 已通过 macOS LaunchAgent 启动"
    else
        nohup "$INSTALL_DIR/bin/otelcol-contrib" --config "$CONFIG_FILE" > "$LOG_DIR/vm-to-skywalking.log" 2>&1 &
        log "OTel Collector 已启动，日志: $LOG_DIR/vm-to-skywalking.log"
    fi

    sleep 3
    if pgrep -f "$INSTALL_DIR/bin/otelcol-contrib.*$CONFIG_FILE" >/dev/null 2>&1 || macos_service_running; then
        log "Linux 主机指标接入进程运行中"
    else
        warn "OTel Collector 进程未检测到，请查看日志: $LOG_DIR/vm-to-skywalking.log"
    fi

    cat <<EOF

查看 SkyWalking:
  1. 打开 UI: http://<skywalking-host>:<ui-port>
  2. 进入 Infrastructure / Linux 或 OS_LINUX 面板查看主机指标
  3. 如果暂时没有数据，等待 1-2 个抓取周期，或确认 node_exporter /metrics 有 node_* 指标
EOF
}

parse_args "$@"
start_collector

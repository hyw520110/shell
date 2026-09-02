#!/bin/bash

set -e

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$CURRENT_DIR")"
BIN_DIR="$BASE_DIR/bin"
LOG_DIR="$BASE_DIR/logs"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
USER_NAME="prometheus"
GROUP_NAME="prometheus"
INSTALL_SERVICE_ONLY=false
UNINSTALL_SERVICE_ONLY=false
LAUNCHAGENT_LABEL="org.prometheus.node_exporter"

while [ $# -gt 0 ]; do
    case "$1" in
        --install-service)
            INSTALL_SERVICE_ONLY=true
            shift
            ;;
        --uninstall-service)
            UNINSTALL_SERVICE_ONLY=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [--install-service|--uninstall-service]"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

detect_platform_suffix() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *) echo "不支持的系统: $(uname -s)" >&2; return 1 ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64) arch="amd64" ;;
        *) echo "不支持的架构: $(uname -m)" >&2; return 1 ;;
    esac

    echo "${os}-${arch}"
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_file
    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"
    # 确保下载目录存在且可写
    if [ -d "$output_dir" ]; then
        if [ ! -w "$output_dir" ]; then
            echo "下载目录无写入权限，尝试修复: $output_dir"
            if command -v sudo >/dev/null 2>&1; then
                sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
            fi
        fi
    else
        mkdir -p "$output_dir" || { echo "无法创建下载目录" >&2; return 1; }
    fi
    if [ -f "$output" ] && [ ! -w "$output" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl >/dev/null 2>&1; then
        echo "使用 adl 下载: $url"
        adl "$url" "$output_dir" "$output_file"
    elif command -v curl >/dev/null 2>&1; then
        echo "使用 curl 下载: $url"
        curl -L -C - "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        echo "使用 wget 下载: $url"
        wget -c "$url" -O "$output"
    else
        echo "未找到可用下载工具，请先安装 adl、curl 或 wget" >&2
        return 1
    fi
}

install_node_exporter() {
    local suffix archive url root_dir
    suffix="$(detect_platform_suffix)"
    archive="$DOWNLOAD_DIR/node_exporter-${NODE_EXPORTER_VERSION}.${suffix}.tar.gz"
    url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${suffix}.tar.gz"
    root_dir="node_exporter-${NODE_EXPORTER_VERSION}.${suffix}"

    mkdir -p "$BIN_DIR" "$LOG_DIR" "$DOWNLOAD_DIR"

    if [ ! -f "$archive" ] || ! tar -tzf "$archive" >/dev/null 2>&1; then
        rm -f "$archive"
        download_file "$url" "$archive"
    fi

    tar -xzf "$archive" -C "$DOWNLOAD_DIR"
    cp "$DOWNLOAD_DIR/$root_dir/node_exporter" "$BIN_DIR/node_exporter"
    chmod +x "$BIN_DIR/node_exporter"
    rm -rf "$DOWNLOAD_DIR/$root_dir"
}

create_linux_service() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$EUID" -eq 0 ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1

    if command -v getent >/dev/null 2>&1; then
        getent group "$GROUP_NAME" >/dev/null 2>&1 || groupadd --system "$GROUP_NAME"
    fi
    id -u "$USER_NAME" >/dev/null 2>&1 || useradd -s /sbin/nologin --system -g "$GROUP_NAME" "$USER_NAME"

    cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
Type=simple
ExecStart=$BIN_DIR/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl restart node_exporter
}

create_macos_service() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    [ -x "$BIN_DIR/node_exporter" ] || return 1

    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/$LAUNCHAGENT_LABEL.plist"
    local runtime_root="$plist_dir/runtime/$LAUNCHAGENT_LABEL"
    local runtime_bin="$runtime_root/bin"
    local runtime_logs="$runtime_root/logs"
    mkdir -p "$plist_dir" "$runtime_bin" "$runtime_logs"
    cp "$BIN_DIR/node_exporter" "$runtime_bin/node_exporter"
    chmod +x "$runtime_bin/node_exporter"
    launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true

    local old_pids
    old_pids="$(pgrep -f "node_exporter" 2>/dev/null | while read -r pid; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        ps -p "$pid" -o command= 2>/dev/null | grep -q "$runtime_bin/node_exporter" && continue
        ps -p "$pid" -o command= 2>/dev/null | grep -q "start_node_exporter.sh" && continue
        echo "$pid"
    done)"
    if [ -n "$old_pids" ]; then
        echo "停止旧 node_exporter 进程: $old_pids"
        kill $old_pids 2>/dev/null || true
        sleep 2
    fi

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHAGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runtime_bin/node_exporter</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load -w "$plist_file"
    launchctl enable "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
    if ! pgrep -f "$BIN_DIR/node_exporter" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
    fi
}

remove_macos_service() {
    local plist_file="$HOME/Library/LaunchAgents/$LAUNCHAGENT_LABEL.plist"
    launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true
    rm -f "$plist_file"
    rm -rf "$HOME/Library/LaunchAgents/runtime/$LAUNCHAGENT_LABEL"
}

start_node_exporter() {
    if [ ! -x "$BIN_DIR/node_exporter" ]; then
        install_node_exporter
    fi

    if create_linux_service; then
        echo "Node Exporter 已通过 systemd 启动。"
        return 0
    fi

    if create_macos_service; then
        echo "Node Exporter 已通过 macOS LaunchAgent 配置自启动。"
        return 0
    fi

    if pgrep -f "$BIN_DIR/node_exporter" >/dev/null 2>&1; then
        echo "Node Exporter 已经在运行。"
        return 0
    fi

    nohup "$BIN_DIR/node_exporter" > "$LOG_DIR/node_exporter.log" 2>&1 &
    echo "Node Exporter 已启动，日志: $LOG_DIR/node_exporter.log"
}

if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    remove_macos_service
    echo "Node Exporter macOS LaunchAgent 已卸载。"
    exit 0
fi

start_node_exporter

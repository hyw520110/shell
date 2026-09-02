#!/usr/bin/env bash
# Prometheus一键安装配置脚本

set -e

PROMETHEUS_VERSION="3.0.1"
NODE_EXPORTER_VERSION="1.8.2"
ALERTMANAGER_VERSION="0.28.0-rc.0"
DEFAULT_INSTALL_DIR="$HOME/prometheus"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OS_TYPE="$(uname -s)"
INSTALL_MODE="host"
UNINSTALL_MODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

show_usage() {
    cat <<EOF
Prometheus一键安装配置脚本

用法: ./install.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -v, --version               检测Prometheus是否已安装
    -d, --dir DIR               安装父目录或实际安装目录 (默认: ~/prometheus)
    --download-dir DIR          下载目录 (默认: ~/Downloads，可用 DOWNLOAD_DIR 覆盖)
    -m, --mode MODE             安装模式: docker|host (默认: host)
    --uninstall                 卸载 Prometheus

说明:
    - 下载目录统一使用 ~/Downloads，支持 DOWNLOAD_DIR 或 --download-dir 覆盖
    - adl 可用时优先使用 adl 下载，失败后回退 curl/wget
    - macOS 使用主机当前用户安装和启动，不创建 systemd 服务
    - Linux root 执行时会创建 systemd 服务；非 root 执行时仅生成主机启动脚本
EOF
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "prometheus" ]; then
        echo "$input"
    else
        echo "$input/prometheus"
    fi
}

parse_args() {
    local opt
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                if command -v prometheus >/dev/null 2>&1; then
                    prometheus --version 2>/dev/null | head -1
                    exit 0
                elif pgrep -f "prometheus.*--config.file" >/dev/null 2>&1; then
                    echo "运行中"
                    exit 0
                fi
                exit 1
                ;;
            -d|--dir|--install-dir|--install-parent|--base-dir)
                opt="$1"
                shift
                [ $# -gt 0 ] || { echo "错误: $opt 需要指定目录" >&2; exit 1; }
                INSTALL_DIR="$(normalize_install_dir "$1")"
                ;;
            --dir=*|--install-dir=*|--install-parent=*|--base-dir=*)
                INSTALL_DIR="$(normalize_install_dir "${1#*=}")"
                ;;
            --download-dir)
                opt="$1"
                shift
                [ $# -gt 0 ] || { echo "错误: $opt 需要指定目录" >&2; exit 1; }
                DOWNLOAD_DIR="${1/#\~/$HOME}"
                ;;
            --download-dir=*)
                DOWNLOAD_DIR="${1#*=}"
                DOWNLOAD_DIR="${DOWNLOAD_DIR/#\~/$HOME}"
                ;;
            -m|--mode)
                opt="$1"
                shift
                [ $# -gt 0 ] || { echo "错误: $opt 需要指定模式" >&2; exit 1; }
                INSTALL_MODE="$1"
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                ;;
            *)
                echo "未知选项: $1" >&2
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

find_adl() {
    # 刷新常见工具路径，确保 SSH 非交互模式也能找到 adl
    local _d
    for _d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
        [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
    done

    if command_exists adl && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local filename
    local adl_path

    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"

    # 确保下载目录存在且当前用户可写
    if [ -d "$output_dir" ]; then
        if [ ! -w "$output_dir" ]; then
            echo "下载目录无写入权限，尝试修复: $output_dir"
            if command -v sudo >/dev/null 2>&1; then
                sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
            fi
        fi
    else
        mkdir -p "$output_dir" || {
            echo "错误: 无法创建下载目录: $output_dir" >&2
            return 1
        }
    fi

    # 如果目标文件存在但不可写（如之前用 sudo 下载的残留），删除它
    if [ -f "$output" ] && [ ! -w "$output" ]; then
        echo "目标文件存在但无写入权限，尝试删除: $output"
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -f "$output" 2>/dev/null || {
                echo "错误: 无法删除只读文件: $output" >&2
                return 1
            }
        else
            echo "错误: 目标文件只读且无法删除: $output" >&2
            return 1
        fi
    fi

    # 清理 aria2 断点文件
    if [ -f "$output.aria2" ] && [ ! -w "$output.aria2" ]; then
        sudo rm -f "$output.aria2" 2>/dev/null || rm -f "$output.aria2" 2>/dev/null || true
    fi

    if adl_path="$(find_adl)"; then
        echo "检测到可用 adl，优先使用 adl 下载: $filename"
        if "$adl_path" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        echo "adl 下载失败，回退 curl/wget: $filename"
    fi

    # 自动检测并使用系统代理
    local proxy_url=""
    if [ -n "$http_proxy" ]; then
        proxy_url="$http_proxy"
    elif [ -n "$https_proxy" ]; then
        proxy_url="$https_proxy"
    elif [ -n "$ALL_PROXY" ]; then
        proxy_url="$ALL_PROXY"
    fi

    if command_exists curl; then
        if [ -n "$proxy_url" ]; then
            echo "[INFO] 使用代理: $proxy_url"
            curl -L --fail -x "$proxy_url" -o "$output" "$url"
        else
            curl -L --fail -o "$output" "$url"
        fi
    elif command_exists wget; then
        if [ -n "$proxy_url" ]; then
            echo "[INFO] 使用代理: $proxy_url"
            wget -Y on -e use_proxy=yes -e http_proxy="$proxy_url" -e https_proxy="$proxy_url" -O "$output" "$url"
        else
            wget -O "$output" "$url"
        fi
    else
        echo "错误: 未找到可用下载工具，请安装 adl、curl 或 wget" >&2
        return 1
    fi
}

verify_tar_gz() {
    local file="$1"
    [ -f "$file" ] || return 1
    gunzip -c "$file" 2>/dev/null | tar -t -f - >/dev/null 2>&1
}

platform_suffix() {
    local os
    local arch
    case "$OS_TYPE" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *) echo "不支持的系统: $OS_TYPE" >&2; return 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "不支持的架构: $(uname -m)" >&2; return 1 ;;
    esac

    echo "$os-$arch"
}

install_archive() {
    local name="$1"
    local version="$2"
    local url="$3"
    local archive="$DOWNLOAD_DIR/${url##*/}"
    local root_dir

    if ! verify_tar_gz "$archive"; then
        [ -f "$archive" ] && echo "检测到安装包损坏或不完整，尝试重新下载: $archive"
        download_file "$url" "$archive"
    fi

    if ! verify_tar_gz "$archive"; then
        echo "错误: 安装包不是有效 tar.gz: $archive" >&2
        exit 1
    fi

    root_dir="$(gunzip -c "$archive" | tar -t -f - | head -1 | cut -d/ -f1)"
    rm -rf "$DOWNLOAD_DIR/$root_dir"
    gunzip -c "$archive" | tar -x -f - -C "$DOWNLOAD_DIR"

    case "$name" in
        prometheus)
            cp "$DOWNLOAD_DIR/$root_dir/prometheus" "$INSTALL_DIR/bin/"
            cp "$DOWNLOAD_DIR/$root_dir/promtool" "$INSTALL_DIR/bin/" 2>/dev/null || true
            [ -d "$DOWNLOAD_DIR/$root_dir/consoles" ] && rsync -a "$DOWNLOAD_DIR/$root_dir/consoles/" "$INSTALL_DIR/consoles/"
            [ -d "$DOWNLOAD_DIR/$root_dir/console_libraries" ] && rsync -a "$DOWNLOAD_DIR/$root_dir/console_libraries/" "$INSTALL_DIR/console_libraries/"
            ;;
        node_exporter)
            cp "$DOWNLOAD_DIR/$root_dir/node_exporter" "$INSTALL_DIR/bin/"
            ;;
        alertmanager)
            cp "$DOWNLOAD_DIR/$root_dir/alertmanager" "$INSTALL_DIR/bin/"
            cp "$DOWNLOAD_DIR/$root_dir/amtool" "$INSTALL_DIR/bin/" 2>/dev/null || true
            if [ -f "$DOWNLOAD_DIR/$root_dir/alertmanager.yml" ] && [ ! -f "$INSTALL_DIR/conf/alertmanager.yml" ]; then
                cp "$DOWNLOAD_DIR/$root_dir/alertmanager.yml" "$INSTALL_DIR/conf/"
            fi
            ;;
    esac

    chmod +x "$INSTALL_DIR/bin/${name}" 2>/dev/null || true
    rm -rf "$DOWNLOAD_DIR/$root_dir"
    echo "$name $version 已安装"
}

get_main_ip() {
    if command_exists ip.sh; then
        ip.sh 2>/dev/null | head -1 && return 0
    fi

    if [ "$OS_TYPE" = "Darwin" ]; then
        local interface
        interface="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')"
        [ -n "$interface" ] && ifconfig "$interface" 2>/dev/null | awk '$1 == "inet" {print $2; exit}' && return 0
    elif command_exists ip; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' && return 0
    fi

    echo "127.0.0.1"
}

configure_prometheus() {
    local main_ip
    main_ip="$(get_main_ip)"

    mkdir -p "$INSTALL_DIR/conf" "$INSTALL_DIR/data" "$INSTALL_DIR/logs" "$INSTALL_DIR/bin" "$INSTALL_DIR/consoles" "$INSTALL_DIR/console_libraries"

    if [ ! -f "$INSTALL_DIR/conf/prometheus.yml" ]; then
        cat > "$INSTALL_DIR/conf/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['$main_ip:9091']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['$main_ip:9100']
EOF
    fi

    if [ -f "$REPO_BASE_DIR/bin/startup.sh" ]; then
        cp "$REPO_BASE_DIR/bin/startup.sh" "$INSTALL_DIR/bin/startup.sh"
        chmod +x "$INSTALL_DIR/bin/startup.sh"
    fi
    if [ -f "$REPO_BASE_DIR/bin/stop.sh" ]; then
        cp "$REPO_BASE_DIR/bin/stop.sh" "$INSTALL_DIR/bin/stop.sh"
        chmod +x "$INSTALL_DIR/bin/stop.sh"
    fi
}

create_systemd_service() {
    local service_name="$1"
    local exec_start="$2"

    [ "$OS_TYPE" = "Linux" ] || return 0
    command_exists systemctl || return 0
    [ "$EUID" -eq 0 ] || return 0

    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=$service_name
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$exec_start
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl restart "$service_name"
}

start_host_services() {
    if [ -x "$INSTALL_DIR/bin/startup.sh" ]; then
        "$INSTALL_DIR/bin/startup.sh" || true
    else
        nohup "$INSTALL_DIR/bin/prometheus" \
            --config.file="$INSTALL_DIR/conf/prometheus.yml" \
            --storage.tsdb.path="$INSTALL_DIR/data" \
            --web.listen-address=":9091" \
            --web.console.templates="$INSTALL_DIR/consoles" \
            --web.console.libraries="$INSTALL_DIR/console_libraries" \
            > "$INSTALL_DIR/logs/prometheus.log" 2>&1 &
        nohup "$INSTALL_DIR/bin/node_exporter" > "$INSTALL_DIR/logs/node_exporter.log" 2>&1 &
    fi
}

install() {
    local suffix
    local prometheus_url
    local node_exporter_url
    local alertmanager_url

    suffix="$(platform_suffix)"
    prometheus_url="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.${suffix}.tar.gz"
    node_exporter_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${suffix}.tar.gz"
    alertmanager_url="https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.${suffix}.tar.gz"

    mkdir -p "$DOWNLOAD_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/conf" "$INSTALL_DIR/data" "$INSTALL_DIR/logs"
    echo "安装目录: $INSTALL_DIR"
    echo "下载目录: $DOWNLOAD_DIR"
    echo "平台: $suffix"

    install_archive prometheus "$PROMETHEUS_VERSION" "$prometheus_url"
    install_archive node_exporter "$NODE_EXPORTER_VERSION" "$node_exporter_url"
    install_archive alertmanager "$ALERTMANAGER_VERSION" "$alertmanager_url"
    configure_prometheus

    create_systemd_service "prometheus" "$INSTALL_DIR/bin/startup.sh"
    if [ "$OS_TYPE" != "Linux" ] || [ "$EUID" -ne 0 ] || ! command_exists systemctl; then
        echo "当前系统不使用 systemd，使用主机脚本启动 Prometheus/Node Exporter"
        start_host_services
    fi

    echo "Prometheus、Node Exporter、Alertmanager 安装和配置完成"
}

# === Docker 模式安装 ===
install_docker() {
    echo "使用 Docker 模式安装 Prometheus..."
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:v${PROMETHEUS_VERSION}
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9091:9090"
    volumes:
      - prometheus-data:/prometheus
      - ./conf:/etc/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    networks:
      - prometheus-network

  node-exporter:
    image: prom/node-exporter:v${NODE_EXPORTER_VERSION}
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    networks:
      - prometheus-network

  alertmanager:
    image: prom/alertmanager:v${ALERTMANAGER_VERSION}
    container_name: alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    volumes:
      - alertmanager-data:/alertmanager
      - ./conf:/etc/alertmanager
    networks:
      - prometheus-network

volumes:
  prometheus-data:
  alertmanager-data:

networks:
  prometheus-network:
    driver: bridge
EOF

    mkdir -p "$INSTALL_DIR/conf"
    cat > "$INSTALL_DIR/conf/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

    cat > "$INSTALL_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if docker compose version &>/dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi
echo "Prometheus 已启动: http://localhost:9091"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    cat > "$INSTALL_DIR/stop.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if docker compose version &>/dev/null; then
    docker compose down
else
    docker-compose down
fi
echo "Prometheus 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    echo "Prometheus Docker 配置创建完成"
    echo "启动: $INSTALL_DIR/start.sh"
}

# === 卸载 ===
uninstall_prometheus() {
    echo "卸载 Prometheus..."

    # 停止主机进程
    for proc in "prometheus" "node_exporter" "alertmanager"; do
        if pgrep -f "$proc" &>/dev/null; then
            echo "停止 $proc..."
            pids="$(pgrep -f "$proc" || true)"
            [ -n "$pids" ] && kill $pids 2>/dev/null || true
            sleep 1
            pids="$(pgrep -f "$proc" || true)"
            [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
        fi
    done

    # 停止 Docker 容器
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        echo "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        if docker compose version &>/dev/null; then
            docker compose down -v 2>/dev/null || true
        elif command -v docker-compose &>/dev/null; then
            docker-compose down -v 2>/dev/null || true
        fi
    fi

    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        echo "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    # 删除 systemd 服务
    if [ "$OS_TYPE" = "Linux" ]; then
        for svc in prometheus node_exporter alertmanager; do
            if [ -f "/etc/systemd/system/${svc}.service" ]; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "/etc/systemd/system/${svc}.service"
            fi
        done
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo "Prometheus 卸载完成"
}

# === 主入口 ===
main() {
    parse_args "$@"

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_prometheus
        exit 0
    fi

    case "$INSTALL_MODE" in
        docker)
            install_docker ;;
        host)
            install ;;
        *)
            echo "错误: 未知安装模式: $INSTALL_MODE" >&2
            exit 1 ;;
    esac
}

main "$@"

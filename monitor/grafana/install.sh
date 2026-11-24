#!/usr/bin/env bash
# Grafana一键安装配置脚本

set -e

GRAFANA_VERSION="${GRAFANA_VERSION:-11.4.0}"
DEFAULT_INSTALL_DIR="$HOME/grafana"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OS_TYPE="$(uname -s)"
INSTALL_MODE="host"
UNINSTALL_MODE=false

show_usage() {
    cat <<EOF
Grafana一键安装配置脚本

用法: ./install.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -v, --version               检测Grafana是否已安装
    -d, --dir DIR               安装父目录或实际安装目录 (默认: ~/grafana)
    --download-dir DIR          下载目录 (默认: ~/Downloads，可用 DOWNLOAD_DIR 覆盖)
    --version-num VERSION       Grafana 版本 (默认: $GRAFANA_VERSION，也可用 GRAFANA_VERSION 覆盖)
    -m, --mode MODE             安装模式: docker|host (默认: host)
    --uninstall                 卸载 Grafana
EOF
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "grafana" ]; then
        echo "$input"
    else
        echo "$input/grafana"
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
                if command -v grafana-server >/dev/null 2>&1; then
                    grafana-server --version 2>/dev/null | head -1
                    exit 0
                elif pgrep -f "grafana-server" >/dev/null 2>&1; then
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
            --version-num)
                opt="$1"
                shift
                [ $# -gt 0 ] || { echo "错误: $opt 需要指定版本" >&2; exit 1; }
                GRAFANA_VERSION="$1"
                ;;
            --version-num=*)
                GRAFANA_VERSION="${1#*=}"
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

    if command_exists curl; then
        curl -L --fail -o "$output" "$url"
    elif command_exists wget; then
        wget -O "$output" "$url"
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

create_scripts() {
    mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/logs"

    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
nohup "$INSTALL_DIR/bin/grafana-server" \\
  --homepath "$INSTALL_DIR" \\
  --config "$INSTALL_DIR/conf/defaults.ini" \\
  > "$INSTALL_DIR/logs/grafana.log" 2>&1 &
echo "Grafana started: http://localhost:3000"
EOF

    cat > "$INSTALL_DIR/stop.sh" <<EOF
#!/usr/bin/env bash
pids=\$(pgrep -f "$INSTALL_DIR/bin/grafana-server" 2>/dev/null || true)
if [ -n "\$pids" ]; then
  kill \$pids
  echo "Grafana stopped"
else
  echo "Grafana is not running"
fi
EOF

    chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/stop.sh"
}

install_grafana() {
    local suffix
    local url
    local archive
    local root_dir

    suffix="$(platform_suffix)"
    url="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.${suffix}.tar.gz"
    archive="$DOWNLOAD_DIR/${url##*/}"

    mkdir -p "$DOWNLOAD_DIR" "$INSTALL_DIR"
    echo "安装目录: $INSTALL_DIR"
    echo "下载目录: $DOWNLOAD_DIR"
    echo "平台: $suffix"

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
    rm -rf "$INSTALL_DIR"
    mv "$DOWNLOAD_DIR/$root_dir" "$INSTALL_DIR"
    create_scripts

    if [ "$OS_TYPE" = "Linux" ] && command_exists systemctl && [ "$EUID" -eq 0 ]; then
        cat > /etc/systemd/system/grafana.service <<EOF
[Unit]
Description=Grafana
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/grafana-server --homepath $INSTALL_DIR --config $INSTALL_DIR/conf/defaults.ini
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable grafana
        systemctl restart grafana
    else
        "$INSTALL_DIR/start.sh"
    fi

    echo "Grafana 安装完成，默认账号密码: admin / admin"
}

# === Docker 模式安装 ===
install_grafana_docker() {
    echo "使用 Docker 模式安装 Grafana..."
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning
    networks:
      - grafana-network

volumes:
  grafana-data:

networks:
  grafana-network:
    driver: bridge
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
echo "Grafana 已启动: http://localhost:3000"
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
echo "Grafana 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    echo "Grafana Docker 配置创建完成"
    echo "启动: $INSTALL_DIR/start.sh"
}

# === 卸载 ===
uninstall_grafana() {
    echo "卸载 Grafana..."

    # 停止主机进程
    if pgrep -f "$INSTALL_DIR/bin/grafana-server" &>/dev/null; then
        echo "停止 Grafana 进程..."
        pids="$(pgrep -f "$INSTALL_DIR/bin/grafana-server" || true)"
        [ -n "$pids" ] && kill $pids 2>/dev/null || true
        sleep 2
        pids="$(pgrep -f "$INSTALL_DIR/bin/grafana-server" || true)"
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi

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
    if [ "$OS_TYPE" = "Linux" ] && [ -f "/etc/systemd/system/grafana.service" ]; then
        systemctl stop grafana 2>/dev/null || true
        systemctl disable grafana 2>/dev/null || true
        rm -f /etc/systemd/system/grafana.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo "Grafana 卸载完成"
}

# === 主入口 ===
main() {
    parse_args "$@"

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_grafana
        exit 0
    fi

    case "$INSTALL_MODE" in
        docker)
            install_grafana_docker ;;
        host)
            install_grafana ;;
        *)
            echo "错误: 未知安装模式: $INSTALL_MODE" >&2
            exit 1 ;;
    esac
}

main "$@"

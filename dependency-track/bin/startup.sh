#!/bin/bash

set -e

# Dependency Track 安全系统安装、配置、启动脚本
# https://docs.dependencytrack.org/getting-started/deploy-docker/

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/dependency-track"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
COMPOSE_URL="https://dependencytrack.org/docker-compose.yml"
COMPOSE_FILE="docker-compose.yml"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
UNINSTALL_MODE=false

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -d, --dir DIR           安装父目录或实际安装目录 (默认: ~/dependency-track)
  --download-dir DIR      下载目录 (默认: ~/Downloads，可用 DOWNLOAD_DIR 覆盖)
  --uninstall             卸载 Dependency Track
  -h, --help              显示帮助
EOF
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "dependency-track" ]; then
        echo "$input"
    else
        echo "$input/dependency-track"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dir)
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            --download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

uninstall_dependency_track() {
    echo "卸载 Dependency Track..."

    local compose
    compose="$(compose_cmd)" || {
        echo "未检测到 Docker Compose，跳过容器停止"
        compose=""
    }

    if [ -n "$compose" ] && [ -f "$INSTALL_DIR/$COMPOSE_FILE" ]; then
        echo "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        $compose down -v 2>/dev/null || true
    fi

    if [ -d "$INSTALL_DIR" ]; then
        echo "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    echo "Dependency Track 卸载完成"
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local output_file

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
        mkdir -p "$output_dir" || { echo "无法创建下载目录: $output_dir" >&2; return 1; }
    fi
    if [ -f "$output" ] && [ ! -w "$output" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl >/dev/null 2>&1; then
        echo "使用 adl 下载: $url"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi

    if command -v curl >/dev/null 2>&1; then
        echo "使用 curl 下载: $url"
        curl -fsSL "$url" -o "$output"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        echo "使用 wget 下载: $url"
        wget -q "$url" -O "$output"
        return $?
    fi

    echo "未找到可用下载工具，请先安装 adl、curl 或 wget" >&2
    return 1
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        return 1
    fi
}

get_local_ip() {
    if command -v ip.sh >/dev/null 2>&1; then
        ip.sh | head -n 1
        return 0
    fi

    if [ -x "$CURRENT_DIR/../../os/ip.sh" ]; then
        "$CURRENT_DIR/../../os/ip.sh" | head -n 1
        return 0
    fi

    if command -v ipconfig >/dev/null 2>&1; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
        return 0
    fi

    hostname -I 2>/dev/null | awk '{print $1}'
}

main() {
    parse_args "$@"

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_dependency_track
        exit 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 Docker，Dependency Track 当前脚本仅支持 Docker Compose 模式" >&2
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "检测到 Docker 命令，但 Docker 未启动" >&2
        exit 1
    fi

    local compose
    compose="$(compose_cmd)" || {
        echo "未检测到 Docker Compose" >&2
        exit 1
    }

    mkdir -p "$INSTALL_DIR" "$DOWNLOAD_DIR"

    local downloaded="$DOWNLOAD_DIR/dependency-track-docker-compose.yml"
    if [ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]; then
        download_file "$COMPOSE_URL" "$downloaded"
        cp "$downloaded" "$INSTALL_DIR/$COMPOSE_FILE"
    fi

    local ip
    ip="$(get_local_ip)"
    if [ -n "$ip" ]; then
        awk -v ip="$ip" '
            /API_BASE_URL=http:\/\/.*:8082/ {
                sub(/API_BASE_URL=http:\/\/[^: ]*:8082/, "API_BASE_URL=http://" ip ":8082")
            }
            { print }
        ' "$INSTALL_DIR/$COMPOSE_FILE" > "$INSTALL_DIR/$COMPOSE_FILE.tmp"
        mv "$INSTALL_DIR/$COMPOSE_FILE.tmp" "$INSTALL_DIR/$COMPOSE_FILE"
    fi

    cd "$INSTALL_DIR"
    $compose up -d
}

main "$@"

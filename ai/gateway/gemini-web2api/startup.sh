#!/usr/bin/env bash

set -euo pipefail

APP_NAME="gemini-web2api"
REPO_URL="https://github.com/Sophomoresty/gemini-web2api"
ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/gemini-web2api}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
PORT="${PORT:-8081}"
HOST="${HOST:-0.0.0.0}"
ACTION="${1:-install}"
ASSUME_YES="${ASSUME_YES:-0}"

log() { printf '[%s] %s\n' "$APP_NAME" "$*"; }
warn() { printf '[%s][WARN] %s\n' "$APP_NAME" "$*" >&2; }
error() { printf '[%s][ERROR] %s\n' "$APP_NAME" "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

print_usage_guide() {
    local rc_file="${SHELL_RC:-}"
    if [ -z "$rc_file" ]; then
        case "${SHELL:-}" in
            */zsh) rc_file="$HOME/.zshrc" ;;
            */bash) rc_file="$HOME/.bashrc" ;;
            *) rc_file="$HOME/.zshrc" ;;
        esac
    fi

    cat <<EOF

[$APP_NAME] 配置与使用
  安装目录: $INSTALL_DIR
  配置文件: $INSTALL_DIR/config.json
  Cookie文件: $INSTALL_DIR/cookie.txt
  服务地址: http://localhost:$PORT
  OpenAI兼容Base URL: http://localhost:$PORT/v1
  Gemini CLI Base URL: http://localhost:$PORT

下一步:
  1. 确认 cookie 文件存在且有效:
     test -s "$INSTALL_DIR/cookie.txt" && echo OK

  2. 启动/重启服务:
     cd "$SCRIPT_DIR" && bash startup.sh restart

  3. 验证服务:
     curl -s http://localhost:$PORT/v1/models

  4. 加载 shell 函数:
     source "$rc_file"

  5. 使用 Gemini CLI:
     gemini-web

说明:
  gemini-web 不负责启动服务，只是让 gemini CLI 使用本地 gemini-web2api。
  等价环境变量:
     GEMINI_API_KEY=none GOOGLE_GEMINI_BASE_URL=http://localhost:$PORT gemini
EOF
}

confirm() {
    local prompt="$1"
    local answer=""
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    if [ -t 0 ]; then
        read -r -p "$prompt [y/N]: " answer
        [[ "$answer" == "y" || "$answer" == "Y" ]]
    else
        return 1
    fi
}

docker_available() {
    command_exists docker && docker info >/dev/null 2>&1
}

download_file() {
    local url="$1"
    local out="$2"
    local out_dir
    local out_name
    out_dir="$(dirname "$out")"
    out_name="$(basename "$out")"
    mkdir -p "$out_dir"

    if command_exists adl; then
        log "使用 adl 下载: $url"
        adl "$url" "$out_dir" "$out_name"
    elif command_exists curl; then
        curl -L --fail --retry 3 -o "$out" "$url"
    elif command_exists wget; then
        wget -O "$out" "$url"
    else
        error "需要 adl、curl 或 wget 下载源码"
        return 1
    fi
}

prepare_source() {
    local src_dir="$INSTALL_DIR/src"
    local archive="$DOWNLOAD_DIR/gemini-web2api-main.zip"
    local extract_dir="$DOWNLOAD_DIR/gemini-web2api-main"

    if [ -f "$src_dir/gemini_web2api.py" ]; then
        log "源码已存在: $src_dir"
        return 0
    fi

    command_exists unzip || {
        error "缺少 unzip，请先安装 unzip"
        return 1
    }

    mkdir -p "$INSTALL_DIR" "$DOWNLOAD_DIR"
    download_file "$ARCHIVE_URL" "$archive"
    rm -rf "$extract_dir"
    unzip -q -o "$archive" -d "$DOWNLOAD_DIR"
    rm -rf "$src_dir"
    mv "$extract_dir" "$src_dir"
    log "源码已准备: $src_dir"
}

write_config() {
    local config="$INSTALL_DIR/config.json"
    mkdir -p "$INSTALL_DIR"
    if [ -f "$config" ]; then
        log "配置文件已存在: $config"
        return 0
    fi

    cat > "$config" <<EOF
{
  "port": $PORT,
  "host": "$HOST",
  "retry_attempts": 3,
  "retry_delay_sec": 2,
  "request_timeout_sec": 180,
  "gemini_bl": null,
  "auth_user": null,
  "xsrf_token": null,
  "api_keys": [],
  "cookie_file": "$INSTALL_DIR/cookie.txt",
  "proxy": null,
  "log_requests": true
}
EOF
    log "已创建配置文件: $config"
}

install_shell_function() {
    local rc_file="${SHELL_RC:-}"
    if [ -z "$rc_file" ]; then
        case "${SHELL:-}" in
            */zsh) rc_file="$HOME/.zshrc" ;;
            */bash) rc_file="$HOME/.bashrc" ;;
            *) rc_file="$HOME/.zshrc" ;;
        esac
    fi

    mkdir -p "$(dirname "$rc_file")"
    touch "$rc_file"

    local begin="# >>> gemini-web2api >>>"
    local end="# <<< gemini-web2api <<<"
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/gemini-web-rc.XXXXXX") || return 1

    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$rc_file" > "$tmp"

    cat >> "$tmp" <<EOF
$begin
gemini-web() {
  GEMINI_API_KEY=none \\
  GOOGLE_GEMINI_BASE_URL=http://localhost:$PORT \\
  gemini "\$@"
}
$end
EOF
    mv "$tmp" "$rc_file"
    log "已写入 gemini-web 函数: $rc_file"
}

install_docker() {
    local src_dir="$INSTALL_DIR/src"
    write_config
    prepare_source
    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    docker build -t "$APP_NAME:latest" "$src_dir"
    docker run -d \
        --name "$APP_NAME" \
        --restart unless-stopped \
        -p "$PORT:$PORT" \
        -v "$INSTALL_DIR/config.json:/app/config.json" \
        -v "$INSTALL_DIR/cookie.txt:/app/cookie.txt" \
        "$APP_NAME:latest"
    log "Docker 模式启动完成: http://localhost:$PORT/v1"
}

install_host() {
    local src_dir="$INSTALL_DIR/src"
    local venv_dir="$INSTALL_DIR/venv"
    command_exists python3 || {
        error "缺少 python3，无法使用主机模式安装"
        return 1
    }
    write_config
    prepare_source
    python3 -m venv "$venv_dir"
    "$venv_dir/bin/python" -m pip install --upgrade pip
    if [ -f "$src_dir/requirements.txt" ]; then
        "$venv_dir/bin/python" -m pip install -r "$src_dir/requirements.txt"
    fi
    start_host
}

start_host() {
    local src_dir="$INSTALL_DIR/src"
    local venv_dir="$INSTALL_DIR/venv"
    local pid_file="$INSTALL_DIR/gemini-web2api.pid"
    local log_file="$INSTALL_DIR/gemini-web2api.log"

    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
        log "主机模式已运行，PID: $(cat "$pid_file")"
        return 0
    fi

    [ -x "$venv_dir/bin/python" ] || {
        error "未找到 Python 虚拟环境，请先执行 install"
        return 1
    }
    [ -f "$src_dir/gemini_web2api.py" ] || {
        error "未找到源码，请先执行 install"
        return 1
    }

    cd "$src_dir"
    nohup "$venv_dir/bin/python" gemini_web2api.py --config "$INSTALL_DIR/config.json" > "$log_file" 2>&1 &
    echo $! > "$pid_file"
    sleep 1
    log "主机模式启动完成: http://localhost:$PORT/v1"
}

stop_host() {
    local pid_file="$INSTALL_DIR/gemini-web2api.pid"
    if [ -f "$pid_file" ]; then
        kill "$(cat "$pid_file")" >/dev/null 2>&1 || true
        rm -f "$pid_file"
    fi
}

stop_all() {
    if docker_available; then
        docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi
    stop_host
    log "已停止 $APP_NAME"
}

status_app() {
    if docker_available && docker ps --format '{{.Names}}' | grep -qx "$APP_NAME"; then
        docker ps --filter "name=$APP_NAME" --format '{{.Status}}'
        return 0
    fi
    if [ -f "$INSTALL_DIR/gemini-web2api.pid" ] && kill -0 "$(cat "$INSTALL_DIR/gemini-web2api.pid")" >/dev/null 2>&1; then
        echo "running pid=$(cat "$INSTALL_DIR/gemini-web2api.pid")"
        return 0
    fi
    echo "not running"
}

uninstall_app() {
    stop_all
    if [ -d "$INSTALL_DIR" ]; then
        if confirm "确认删除安装目录 $INSTALL_DIR ?"; then
            rm -rf "$INSTALL_DIR"
            log "已删除安装目录: $INSTALL_DIR"
        else
            log "已保留安装目录: $INSTALL_DIR"
        fi
    fi
}

install_app() {
    if docker_available; then
        log "检测到 Docker，使用 Docker 模式"
        install_docker
    else
        log "Docker 不可用，使用主机模式"
        install_host
    fi
    install_shell_function
    print_usage_guide
}

case "$ACTION" in
    install) install_app ;;
    start)
        if docker_available && docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
            docker start "$APP_NAME" >/dev/null
            log "Docker 容器已启动"
        else
            start_host
        fi
        ;;
    stop) stop_all ;;
    restart) stop_all; install_app ;;
    status) status_app ;;
    guide) print_usage_guide ;;
    uninstall) uninstall_app ;;
    *)
        echo "用法: $0 {install|start|stop|restart|status|guide|uninstall}"
        exit 1
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

APP_NAME="opencut"
REPO_URL="${OPENCUT_REPO_URL:-https://github.com/OpenCut-app/OpenCut.git}"
INSTALL_DIR="${OPENCUT_INSTALL_DIR:-$HOME/.local/share/ai-hub/opencut}"
RUNTIME_DIR="${OPENCUT_AIHUB_DIR:-$HOME/.opencut-aihub}"
ENV_FILE="$INSTALL_DIR/.env.local"
MODE_FILE="$RUNTIME_DIR/install.mode"
WEB_PID_FILE="$RUNTIME_DIR/web.pid"
API_PID_FILE="$RUNTIME_DIR/api.pid"
WEB_LOG_FILE="$RUNTIME_DIR/web.log"
API_LOG_FILE="$RUNTIME_DIR/api.log"

WEB_PORT="${OPENCUT_WEB_PORT:-5173}"
API_PORT="${OPENCUT_API_PORT:-8787}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() { printf "${CYAN}[INFO]${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
success() { printf "${GREEN}[OK]${RESET} %s\n" "$*" >&2; }

ensure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "缺少依赖: $command_name"
        return 1
    fi
}

check_source_dir() {
    [[ -d "$INSTALL_DIR/.git" ]] || {
        error "OpenCut 源码目录不存在: $INSTALL_DIR"
        return 1
    }
}

prepare_env() {
    if [[ -f "$INSTALL_DIR/.env.example" && ! -f "$ENV_FILE" ]]; then
        cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
        info "已创建本地环境文件: $ENV_FILE"
    fi
}

install_dependencies() {
    require_command git
    require_command proto || {
        error "OpenCut 当前版本需要 proto。安装方法见: https://moonrepo.dev/docs/proto/install"
        return 1
    }

    if [[ ! -e "$INSTALL_DIR" ]]; then
        mkdir -p "$(dirname "$INSTALL_DIR")"
        info "正在克隆 OpenCut 到 $INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR"
    elif [[ ! -d "$INSTALL_DIR/.git" ]]; then
        error "目标路径已存在但不是 Git 仓库: $INSTALL_DIR"
        return 1
    else
        info "OpenCut 源码已存在: $INSTALL_DIR"
    fi

    (cd "$INSTALL_DIR" && proto use)
    (cd "$INSTALL_DIR/apps/web" && bun install)
    (cd "$INSTALL_DIR/apps/api" && bun install)
    prepare_env
    ensure_runtime_dir
    printf '%s\n' source > "$MODE_FILE"
    success "OpenCut 源码依赖安装完成。"
}

update_app() {
    require_command git
    check_source_dir
    (cd "$INSTALL_DIR" && git pull --ff-only && proto use)
    (cd "$INSTALL_DIR/apps/web" && bun install)
    (cd "$INSTALL_DIR/apps/api" && bun install)
    prepare_env
    success "OpenCut 已更新。"
}

pid_is_running() {
    local pid_file="$1"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

start_service() {
    local service="$1"
    local pid_file="$2"
    local log_file="$3"

    if pid_is_running "$pid_file"; then
        success "OpenCut $service 服务已在运行 (pid $(cat "$pid_file"))."
        return 0
    fi

    local command_name
    [[ "$service" == "web" ]] && command_name="web:dev" || command_name="api:dev"
    info "启动 OpenCut $service 服务"
    (
        cd "$INSTALL_DIR"
        exec moon run "$command_name"
    ) > "$log_file" 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
}

start_app() {
    check_source_dir
    require_command moon
    require_command bun
    prepare_env
    ensure_runtime_dir
    start_service web "$WEB_PID_FILE" "$WEB_LOG_FILE"
    start_service api "$API_PID_FILE" "$API_LOG_FILE"
    printf 'Web: http://localhost:%s\n' "$WEB_PORT"
    printf 'API: http://localhost:%s\n' "$API_PORT"
}

desktop_app() {
    check_source_dir
    require_command moon
    (cd "$INSTALL_DIR" && exec moon run desktop:dev)
}

stop_service() {
    local service="$1"
    local pid_file="$2"
    if pid_is_running "$pid_file"; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" >/dev/null 2>&1 || true
        success "OpenCut $service 服务已停止。"
    fi
    rm -f "$pid_file"
}

stop_app() {
    ensure_runtime_dir
    stop_service web "$WEB_PID_FILE"
    stop_service api "$API_PID_FILE"
}

http_ready() {
    local url="$1"
    # API 根路径可能返回 404；能建立 HTTP 连接就算服务已启动。
    curl -sS --connect-timeout 2 --max-time 5 "$url" >/dev/null 2>&1
}

status_app() {
    local mode="not installed"
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
    printf 'Mode: %s\n' "$mode"
    printf 'Source: %s\n' "$INSTALL_DIR"
    printf 'Web: http://localhost:%s\n' "$WEB_PORT"
    printf 'API: http://localhost:%s\n' "$API_PORT"

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        printf 'Dependencies: %s\n' "$(if [[ -d "$INSTALL_DIR/apps/web/node_modules" && -d "$INSTALL_DIR/apps/api/node_modules" ]]; then echo ready; else echo missing; fi)"
    fi
    if pid_is_running "$WEB_PID_FILE"; then
        printf 'Web process: running (pid %s)\n' "$(cat "$WEB_PID_FILE")"
    else
        printf 'Web process: stopped\n'
    fi
    if pid_is_running "$API_PID_FILE"; then
        printf 'API process: running (pid %s)\n' "$(cat "$API_PID_FILE")"
    else
        printf 'API process: stopped\n'
    fi

    http_ready "http://localhost:$WEB_PORT" && success "Web 服务可访问。" || warn "Web 服务未响应。"
    http_ready "http://localhost:$API_PORT" && success "API 服务可访问。" || warn "API 服务未响应。"
}

logs_app() {
    ensure_runtime_dir
    touch "$WEB_LOG_FILE" "$API_LOG_FILE"
    tail -f "$WEB_LOG_FILE" "$API_LOG_FILE"
}

doctor_app() {
    for command_name in git proto bun moon; do
        if command -v "$command_name" >/dev/null 2>&1; then
            printf '%-6s %s\n' "$command_name" "$($command_name --version 2>/dev/null | head -1 || true)"
        else
            printf '%-6s missing\n' "$command_name"
        fi
    done
    status_app
}

uninstall_app() {
    stop_app || true
    check_source_dir || return 0
    case "$INSTALL_DIR" in
        "$HOME/.local/share/ai-hub/opencut"|"$HOME/.local/share/ai-hub/opencut/"*) ;;
        *) error "拒绝删除非默认 OpenCut 路径: $INSTALL_DIR"; return 1 ;;
    esac
    rm -rf -- "$INSTALL_DIR"
    rm -f "$MODE_FILE"
    success "OpenCut 源码已卸载；运行时日志保留在 $RUNTIME_DIR。"
}

usage() {
    cat <<EOF
OpenCut AI Hub helper

Usage: $(basename "$0") <install|update|start|stop|status|logs|doctor|desktop|uninstall>

Web:    http://localhost:$WEB_PORT
API:    http://localhost:$API_PORT
Source: $INSTALL_DIR
Config: $ENV_FILE
EOF
}

main() {
    case "${1:-status}" in
        install) install_dependencies ;;
        update) update_app ;;
        start) start_app ;;
        stop) stop_app ;;
        status) status_app ;;
        logs) logs_app ;;
        doctor) doctor_app ;;
        desktop) desktop_app ;;
        uninstall) uninstall_app ;;
        help|-h|--help) usage ;;
        *) usage; return 2 ;;
    esac
}

main "$@"

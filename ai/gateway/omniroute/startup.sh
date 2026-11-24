#!/usr/bin/env bash
set -euo pipefail

APP_NAME="omniroute"
DEFAULT_PORT="20128"
CONFIG_DIR="${OMNIROUTE_AIHUB_DIR:-$HOME/.omniroute-aihub}"
ENV_FILE="$CONFIG_DIR/runtime.env"
PID_FILE="$CONFIG_DIR/omniroute.pid"
LOG_FILE="$CONFIG_DIR/omniroute.log"
MODE_FILE="$CONFIG_DIR/install.mode"

CONTAINER_NAME="${OMNIROUTE_CONTAINER_NAME:-omniroute}"
IMAGE_NAME="${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:latest}"
PORT="${OMNIROUTE_PORT:-$DEFAULT_PORT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() { printf "${CYAN}[INFO]${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
success() { printf "${GREEN}[OK]${RESET} %s\n" "$*" >&2; }

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<EOF
# OmniRoute AI Hub runtime options.
# Override before running this script or edit through ai-hub config menu.
OMNIROUTE_PORT=$PORT
OMNIROUTE_IMAGE=$IMAGE_NAME
OMNIROUTE_CONTAINER_NAME=$CONTAINER_NAME
EOF
    fi
}

load_env() {
    ensure_config_dir
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    PORT="${OMNIROUTE_PORT:-$PORT}"
    IMAGE_NAME="${OMNIROUTE_IMAGE:-$IMAGE_NAME}"
    CONTAINER_NAME="${OMNIROUTE_CONTAINER_NAME:-$CONTAINER_NAME}"
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

container_exists() {
    docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

service_ready() {
    curl -fsS --connect-timeout 2 --max-time 5 "http://localhost:$PORT" >/dev/null 2>&1
}

write_mode() {
    ensure_config_dir
    printf '%s\n' "$1" > "$MODE_FILE"
}

read_mode() {
    if [[ -f "$MODE_FILE" ]]; then
        cat "$MODE_FILE"
    elif docker_available && container_exists; then
        echo "docker"
    elif command -v omniroute >/dev/null 2>&1; then
        echo "npm"
    else
        echo ""
    fi
}

install_docker() {
    info "Installing OmniRoute with Docker image: $IMAGE_NAME"
    docker pull "$IMAGE_NAME"

    if container_exists; then
        info "Container already exists: $CONTAINER_NAME"
    else
        docker run -d \
            --name "$CONTAINER_NAME" \
            --restart unless-stopped \
            --stop-timeout 40 \
            -p "$PORT:$PORT" \
            -v "$CONFIG_DIR/data:/app/data" \
            "$IMAGE_NAME"
    fi

    write_mode "docker"
    success "OmniRoute installed. Dashboard: http://localhost:$PORT"
}

install_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        error "npm was not found. Install Node.js first, or run Docker Desktop and retry."
        return 1
    fi

    info "Installing OmniRoute globally with npm"
    npm install -g omniroute
    write_mode "npm"
    success "OmniRoute installed with npm"
}

install_app() {
    load_env
    if docker_available; then
        install_docker
    else
        warn "Docker is not available; falling back to npm global install."
        install_npm
    fi
}

start_docker() {
    if ! docker_available; then
        error "Docker is not available."
        return 1
    fi
    if ! container_exists; then
        install_docker
        return
    fi
    if container_running; then
        success "OmniRoute container is already running."
    else
        docker start "$CONTAINER_NAME" >/dev/null
        success "OmniRoute container started."
    fi
    info "Dashboard: http://localhost:$PORT"
}

start_npm() {
    if ! command -v omniroute >/dev/null 2>&1; then
        install_npm
    fi
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        success "OmniRoute is already running (pid $(cat "$PID_FILE"))."
        return 0
    fi
    info "Starting OmniRoute in background"
    PORT="$PORT" nohup omniroute --no-open > "$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
    success "OmniRoute started (pid $(cat "$PID_FILE"))."
    info "Dashboard: http://localhost:$PORT"
}

start_app() {
    load_env
    case "$(read_mode)" in
        docker) start_docker ;;
        npm) start_npm ;;
        *)
            if docker_available; then
                start_docker
            else
                start_npm
            fi
            ;;
    esac
}

stop_app() {
    load_env
    case "$(read_mode)" in
        docker)
            if docker_available && container_running; then
                docker stop "$CONTAINER_NAME" >/dev/null
                success "OmniRoute container stopped."
            else
                warn "OmniRoute container is not running."
            fi
            ;;
        npm|*)
            if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
                kill "$(cat "$PID_FILE")"
                rm -f "$PID_FILE"
                success "OmniRoute process stopped."
            else
                warn "OmniRoute process is not running."
            fi
            ;;
    esac
}

status_app() {
    load_env
    local mode
    mode="$(read_mode)"
    printf "Mode: %s\n" "${mode:-not installed}"
    printf "Dashboard: http://localhost:%s\n" "$PORT"

    if [[ "$mode" == "docker" ]] && docker_available; then
        docker ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    elif [[ "$mode" == "npm" ]]; then
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
            printf "Process: running (pid %s)\n" "$(cat "$PID_FILE")"
        else
            printf "Process: stopped\n"
        fi
    fi

    if service_ready; then
        success "Service is reachable."
    else
        warn "Service is not reachable yet."
    fi
}

logs_app() {
    load_env
    if [[ "$(read_mode)" == "docker" ]] && docker_available && container_exists; then
        docker logs -f "$CONTAINER_NAME"
    else
        touch "$LOG_FILE"
        tail -f "$LOG_FILE"
    fi
}

doctor_app() {
    load_env
    if command -v omniroute >/dev/null 2>&1; then
        omniroute --version 2>/dev/null || true
    fi
    status_app
}

update_app() {
    load_env
    case "$(read_mode)" in
        docker)
            install_docker
            if container_running; then
                docker restart "$CONTAINER_NAME" >/dev/null
            fi
            ;;
        npm) npm install -g omniroute ;;
        *) install_app ;;
    esac
}

uninstall_app() {
    load_env
    case "$(read_mode)" in
        docker)
            if docker_available && container_exists; then
                docker rm -f "$CONTAINER_NAME"
            fi
            ;;
        npm)
            if command -v npm >/dev/null 2>&1; then
                npm uninstall -g omniroute || true
            fi
            ;;
    esac
    rm -f "$PID_FILE" "$MODE_FILE"
    success "OmniRoute uninstall step completed. Runtime config remains at $CONFIG_DIR."
}

usage() {
    cat <<EOF
OmniRoute AI Hub helper

Usage: $(basename "$0") <install|update|start|stop|status|logs|doctor|uninstall>

Default dashboard: http://localhost:$DEFAULT_PORT
Runtime config: $ENV_FILE
EOF
}

main() {
    case "${1:-status}" in
        install) install_app ;;
        update) update_app ;;
        start) start_app ;;
        stop) stop_app ;;
        status) status_app ;;
        logs) logs_app ;;
        doctor) doctor_app ;;
        uninstall) uninstall_app ;;
        help|-h|--help) usage ;;
        *) usage; return 2 ;;
    esac
}

main "$@"

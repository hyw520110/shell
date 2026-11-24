#!/usr/bin/env bash
set -euo pipefail

APP_NAME="mirofish"
REPO_URL="${MIROFISH_REPO_URL:-https://github.com/666ghj/MiroFish.git}"
INSTALL_DIR="${MIROFISH_INSTALL_DIR:-$HOME/MiroFish}"
RUNTIME_DIR="${MIROFISH_AIHUB_DIR:-$HOME/.mirofish-aihub}"
ENV_FILE="$RUNTIME_DIR/.env"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
PID_FILE="$RUNTIME_DIR/mirofish.pid"
LOG_FILE="$RUNTIME_DIR/mirofish.log"
MODE_FILE="$RUNTIME_DIR/install.mode"

FRONTEND_PORT="${MIROFISH_FRONTEND_PORT:-3000}"
BACKEND_PORT="${MIROFISH_BACKEND_PORT:-5001}"
IMAGE_NAME="${MIROFISH_IMAGE:-ghcr.io/666ghj/mirofish:latest}"

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
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<EOF
# MiroFish AI Hub runtime options.
# Fill the required model and memory provider keys before starting.
MIROFISH_FRONTEND_PORT=$FRONTEND_PORT
MIROFISH_BACKEND_PORT=$BACKEND_PORT
MIROFISH_IMAGE=$IMAGE_NAME

# LLM API configuration. Supports OpenAI SDK-compatible endpoints.
LLM_API_KEY=
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
LLM_MODEL_NAME=qwen-plus

# Zep Cloud memory configuration.
ZEP_API_KEY=
EOF
    fi
}

load_env() {
    ensure_runtime_dir
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    FRONTEND_PORT="${MIROFISH_FRONTEND_PORT:-$FRONTEND_PORT}"
    BACKEND_PORT="${MIROFISH_BACKEND_PORT:-$BACKEND_PORT}"
    IMAGE_NAME="${MIROFISH_IMAGE:-$IMAGE_NAME}"
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
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

write_mode() {
    ensure_runtime_dir
    printf '%s\n' "$1" > "$MODE_FILE"
}

read_mode() {
    if [[ -f "$MODE_FILE" ]]; then
        cat "$MODE_FILE"
    elif [[ -d "$INSTALL_DIR/.git" ]]; then
        echo "source"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        echo "docker"
    else
        echo ""
    fi
}

write_compose_file() {
    load_env
    cat > "$COMPOSE_FILE" <<EOF
services:
  mirofish:
    image: ${IMAGE_NAME}
    container_name: mirofish
    restart: unless-stopped
    ports:
      - "${FRONTEND_PORT}:3000"
      - "${BACKEND_PORT}:5001"
    env_file:
      - .env
    volumes:
      - ./data:/app/data
EOF
}

frontend_ready() {
    curl -fsS --connect-timeout 2 --max-time 5 "http://localhost:$FRONTEND_PORT" >/dev/null 2>&1
}

backend_ready() {
    curl -fsS --connect-timeout 2 --max-time 5 "http://localhost:$BACKEND_PORT" >/dev/null 2>&1
}

install_docker() {
    load_env
    if ! docker_available; then
        return 1
    fi
    local dc
    dc="$(compose_cmd)" || {
        error "Docker Compose was not found."
        return 1
    }

    write_compose_file
    info "Installing MiroFish with Docker image: $IMAGE_NAME"
    (cd "$RUNTIME_DIR" && $dc pull && $dc up -d)
    write_mode "docker"
    success "MiroFish Docker service started."
    info "Frontend: http://localhost:$FRONTEND_PORT"
    info "Backend: http://localhost:$BACKEND_PORT"
}

install_source() {
    load_env
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v node >/dev/null 2>&1 || missing+=("node")
    command -v npm >/dev/null 2>&1 || missing+=("npm")
    command -v uv >/dev/null 2>&1 || missing+=("uv")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Source mode is missing dependencies: ${missing[*]}"
        error "Install Docker Desktop, or install Node.js 18+, Python 3.11-3.12 and uv."
        return 1
    fi

    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        info "Cloning MiroFish into $INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR"
    else
        info "MiroFish source already exists: $INSTALL_DIR"
    fi

    if [[ -f "$INSTALL_DIR/.env.example" && ! -f "$INSTALL_DIR/.env" ]]; then
        cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    elif [[ ! -f "$INSTALL_DIR/.env" ]]; then
        cp "$ENV_FILE" "$INSTALL_DIR/.env"
    fi

    if [[ -f "$INSTALL_DIR/package.json" ]]; then
        (cd "$INSTALL_DIR" && npm install)
    fi
    if [[ -f "$INSTALL_DIR/backend/pyproject.toml" ]]; then
        (cd "$INSTALL_DIR/backend" && uv sync)
    elif [[ -f "$INSTALL_DIR/pyproject.toml" ]]; then
        (cd "$INSTALL_DIR" && uv sync)
    fi

    write_mode "source"
    success "MiroFish source dependencies installed."
    warn "Edit $INSTALL_DIR/.env before starting if provider keys are required."
}

install_app() {
    if install_docker; then
        return 0
    fi
    warn "Docker is unavailable; falling back to source install."
    install_source
}

update_app() {
    load_env
    case "$(read_mode)" in
        docker)
            write_compose_file
            local dc
            dc="$(compose_cmd)" || return 1
            (cd "$RUNTIME_DIR" && $dc pull && $dc up -d)
            ;;
        source)
            [[ -d "$INSTALL_DIR/.git" ]] || { error "Source directory not found: $INSTALL_DIR"; return 1; }
            (cd "$INSTALL_DIR" && git pull)
            install_source
            ;;
        *) install_app ;;
    esac
}

start_source() {
    [[ -d "$INSTALL_DIR" ]] || install_source
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        success "MiroFish source process is already running (pid $(cat "$PID_FILE"))."
        return 0
    fi

    info "Starting MiroFish source process in background"
    (
        cd "$INSTALL_DIR"
        if [[ -f "package.json" ]]; then
            npm run dev
        else
            error "package.json not found in $INSTALL_DIR"
            exit 1
        fi
    ) > "$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
    success "MiroFish started (pid $(cat "$PID_FILE"))."
}

start_app() {
    load_env
    case "$(read_mode)" in
        docker)
            local dc
            dc="$(compose_cmd)" || return 1
            write_compose_file
            (cd "$RUNTIME_DIR" && $dc up -d)
            ;;
        source) start_source ;;
        *) install_app ;;
    esac
    info "Frontend: http://localhost:$FRONTEND_PORT"
    info "Backend: http://localhost:$BACKEND_PORT"
}

stop_app() {
    load_env
    case "$(read_mode)" in
        docker)
            local dc
            dc="$(compose_cmd)" || return 1
            (cd "$RUNTIME_DIR" && $dc down)
            ;;
        source|*)
            if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
                kill "$(cat "$PID_FILE")"
                rm -f "$PID_FILE"
                success "MiroFish source process stopped."
            else
                warn "MiroFish source process is not running."
            fi
            ;;
    esac
}

status_app() {
    load_env
    local mode
    mode="$(read_mode)"
    printf "Mode: %s\n" "${mode:-not installed}"
    printf "Frontend: http://localhost:%s\n" "$FRONTEND_PORT"
    printf "Backend: http://localhost:%s\n" "$BACKEND_PORT"

    if [[ "$mode" == "docker" ]] && command -v docker >/dev/null 2>&1; then
        docker ps -a --filter "name=mirofish" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    elif [[ "$mode" == "source" ]]; then
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
            printf "Process: running (pid %s)\n" "$(cat "$PID_FILE")"
        else
            printf "Process: stopped\n"
        fi
    fi

    frontend_ready && success "Frontend is reachable." || warn "Frontend is not reachable."
    backend_ready && success "Backend is reachable." || warn "Backend is not reachable."
}

logs_app() {
    load_env
    if [[ "$(read_mode)" == "docker" ]]; then
        local dc
        dc="$(compose_cmd)" || return 1
        (cd "$RUNTIME_DIR" && $dc logs -f)
    else
        touch "$LOG_FILE"
        tail -f "$LOG_FILE"
    fi
}

doctor_app() {
    command -v docker >/dev/null 2>&1 && docker --version || true
    command -v node >/dev/null 2>&1 && node --version || true
    command -v npm >/dev/null 2>&1 && npm --version || true
    command -v uv >/dev/null 2>&1 && uv --version || true
    status_app
}

uninstall_app() {
    stop_app || true
    if [[ "$(read_mode)" == "docker" ]] && command -v docker >/dev/null 2>&1; then
        docker rm -f mirofish >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE" "$MODE_FILE"
    success "MiroFish uninstall step completed. Runtime config remains at $RUNTIME_DIR."
}

usage() {
    cat <<EOF
MiroFish AI Hub helper

Usage: $(basename "$0") <install|update|start|stop|status|logs|doctor|uninstall>

Default frontend: http://localhost:$FRONTEND_PORT
Default backend:  http://localhost:$BACKEND_PORT
Runtime config:   $ENV_FILE
Source directory: $INSTALL_DIR
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

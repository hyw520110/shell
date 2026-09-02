#!/usr/bin/env bash
set -euo pipefail

APP_NAME="bettafish"
REPO_URL="${BETTAFISH_REPO_URL:-https://github.com/666ghj/BettaFish.git}"
INSTALL_DIR="${BETTAFISH_INSTALL_DIR:-$HOME/BettaFish}"
RUNTIME_DIR="${BETTAFISH_AIHUB_DIR:-$HOME/.bettafish-aihub}"
ENV_FILE="$RUNTIME_DIR/.env"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
PID_FILE="$RUNTIME_DIR/bettafish.pid"
LOG_FILE="$RUNTIME_DIR/bettafish.log"
MODE_FILE="$RUNTIME_DIR/install.mode"

APP_PORT="${BETTAFISH_PORT:-5000}"
QUERY_PORT="${BETTAFISH_QUERY_PORT:-8503}"
MEDIA_PORT="${BETTAFISH_MEDIA_PORT:-8502}"
INSIGHT_PORT="${BETTAFISH_INSIGHT_PORT:-8501}"
POSTGRES_PORT="${BETTAFISH_POSTGRES_PORT:-5444}"
IMAGE_NAME="${BETTAFISH_IMAGE:-ghcr.io/666ghj/bettafish:latest}"

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
    mkdir -p "$RUNTIME_DIR/logs" "$RUNTIME_DIR/final_reports" \
        "$RUNTIME_DIR/insight_engine_streamlit_reports" \
        "$RUNTIME_DIR/media_engine_streamlit_reports" \
        "$RUNTIME_DIR/query_engine_streamlit_reports"

    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<EOF
# BettaFish AI Hub runtime options.
HOST=0.0.0.0
PORT=$APP_PORT

# Database. Docker mode should use DB_HOST=db and DB_PORT=5432.
DB_HOST=db
DB_PORT=5432
POSTGRES_PORT=$POSTGRES_PORT
DB_USER=bettafish
DB_PASSWORD=bettafish
DB_NAME=bettafish
DB_CHARSET=utf8mb4
DB_DIALECT=postgresql

# OpenAI-compatible LLM settings for each agent.
INSIGHT_ENGINE_API_KEY=
INSIGHT_ENGINE_BASE_URL=
INSIGHT_ENGINE_MODEL_NAME=

MEDIA_ENGINE_API_KEY=
MEDIA_ENGINE_BASE_URL=
MEDIA_ENGINE_MODEL_NAME=

QUERY_ENGINE_API_KEY=
QUERY_ENGINE_BASE_URL=
QUERY_ENGINE_MODEL_NAME=

REPORT_ENGINE_API_KEY=
REPORT_ENGINE_BASE_URL=
REPORT_ENGINE_MODEL_NAME=

MINDSPIDER_API_KEY=
MINDSPIDER_BASE_URL=
MINDSPIDER_MODEL_NAME=

FORUM_HOST_API_KEY=
FORUM_HOST_BASE_URL=
FORUM_HOST_MODEL_NAME=

KEYWORD_OPTIMIZER_API_KEY=
KEYWORD_OPTIMIZER_BASE_URL=
KEYWORD_OPTIMIZER_MODEL_NAME=

# Search providers.
TAVILY_API_KEY=
SEARCH_TOOL_TYPE=AnspireAPI
ANSPIRE_BASE_URL=https://plugin.anspire.cn/api/ntsearch/search
ANSPIRE_API_KEY=
BOCHA_BASE_URL=https://api.bocha.cn/v1/ai-search
BOCHA_WEB_SEARCH_API_KEY=
EOF
    fi
}

load_env() {
    ensure_runtime_dir
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    APP_PORT="${PORT:-$APP_PORT}"
    QUERY_PORT="${BETTAFISH_QUERY_PORT:-$QUERY_PORT}"
    MEDIA_PORT="${BETTAFISH_MEDIA_PORT:-$MEDIA_PORT}"
    INSIGHT_PORT="${BETTAFISH_INSIGHT_PORT:-$INSIGHT_PORT}"
    POSTGRES_PORT="${POSTGRES_PORT:-$POSTGRES_PORT}"
    IMAGE_NAME="${BETTAFISH_IMAGE:-$IMAGE_NAME}"
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
    elif [[ -f "$COMPOSE_FILE" ]]; then
        echo "docker"
    elif [[ -d "$INSTALL_DIR/.git" ]]; then
        echo "source"
    else
        echo ""
    fi
}

write_compose_file() {
    load_env
    cat > "$COMPOSE_FILE" <<EOF
services:
  bettafish:
    image: ${IMAGE_NAME}
    container_name: bettafish
    restart: unless-stopped
    environment:
      - PYTHONUNBUFFERED=1
      - STREAMLIT_SERVER_ENABLE_FILE_WATCHER=false
    ports:
      - "${APP_PORT}:5000"
      - "${INSIGHT_PORT}:8501"
      - "${MEDIA_PORT}:8502"
      - "${QUERY_PORT}:8503"
    volumes:
      - ./logs:/app/logs
      - ./final_reports:/app/final_reports
      - ./.env:/app/.env
      - ./insight_engine_streamlit_reports:/app/insight_engine_streamlit_reports
      - ./media_engine_streamlit_reports:/app/media_engine_streamlit_reports
      - ./query_engine_streamlit_reports:/app/query_engine_streamlit_reports

  db:
    image: postgres:15
    container_name: bettafish-db
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_USER: \${DB_USER:-\${POSTGRES_USER:-bettafish}}
      POSTGRES_PASSWORD: \${DB_PASSWORD:-\${POSTGRES_PASSWORD:-bettafish}}
      POSTGRES_DB: \${DB_NAME:-\${POSTGRES_DB:-bettafish}}
    ports:
      - "\${POSTGRES_PORT:-5444}:5432"
    volumes:
      - ./db_data:/var/lib/postgresql/data
EOF
}

app_ready() {
    curl -fsS --connect-timeout 2 --max-time 5 "http://localhost:$APP_PORT" >/dev/null 2>&1
}

clone_source() {
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        info "Cloning BettaFish into $INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR"
    else
        info "BettaFish source already exists: $INSTALL_DIR"
    fi
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
    info "Installing BettaFish with Docker image: $IMAGE_NAME"
    (cd "$RUNTIME_DIR" && $dc pull && $dc up -d)
    write_mode "docker"
    success "BettaFish Docker service started."
    info "Main UI: http://localhost:$APP_PORT"
    info "Insight Engine: http://localhost:$INSIGHT_PORT"
    info "Media Engine: http://localhost:$MEDIA_PORT"
    info "Query Engine: http://localhost:$QUERY_PORT"
}

install_source() {
    load_env
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v uv >/dev/null 2>&1 || missing+=("uv")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Source mode is missing dependencies: ${missing[*]}"
        error "Install Docker Desktop, or install Python 3.9+ and uv."
        return 1
    fi

    clone_source
    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        cp "$ENV_FILE" "$INSTALL_DIR/.env"
    fi
    if [[ -f "$INSTALL_DIR/requirements.txt" ]]; then
        (cd "$INSTALL_DIR" && uv venv --python 3.11 2>/dev/null || uv venv)
        (cd "$INSTALL_DIR" && uv pip install -r requirements.txt)
    fi
    write_mode "source"
    success "BettaFish source dependencies installed."
    warn "Source mode needs a configured PostgreSQL/MySQL database in $INSTALL_DIR/.env."
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
            clone_source
            (cd "$INSTALL_DIR" && git pull)
            install_source
            ;;
        *) install_app ;;
    esac
}

start_source() {
    [[ -d "$INSTALL_DIR" ]] || install_source
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        success "BettaFish source process is already running (pid $(cat "$PID_FILE"))."
        return 0
    fi

    info "Starting BettaFish source process in background"
    (
        cd "$INSTALL_DIR"
        if [[ -f "app.py" ]]; then
            uv run python app.py
        else
            error "app.py not found in $INSTALL_DIR"
            exit 1
        fi
    ) > "$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
    success "BettaFish started (pid $(cat "$PID_FILE"))."
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
    info "Main UI: http://localhost:$APP_PORT"
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
                success "BettaFish source process stopped."
            else
                warn "BettaFish source process is not running."
            fi
            ;;
    esac
}

status_app() {
    load_env
    local mode
    mode="$(read_mode)"
    printf "Mode: %s\n" "${mode:-not installed}"
    printf "Main UI: http://localhost:%s\n" "$APP_PORT"
    printf "Insight Engine: http://localhost:%s\n" "$INSIGHT_PORT"
    printf "Media Engine: http://localhost:%s\n" "$MEDIA_PORT"
    printf "Query Engine: http://localhost:%s\n" "$QUERY_PORT"

    if [[ "$mode" == "docker" ]] && command -v docker >/dev/null 2>&1; then
        docker ps -a --filter "name=bettafish" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    elif [[ "$mode" == "source" ]]; then
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
            printf "Process: running (pid %s)\n" "$(cat "$PID_FILE")"
        else
            printf "Process: stopped\n"
        fi
    fi

    app_ready && success "Main UI is reachable." || warn "Main UI is not reachable."
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

reports_app() {
    load_env
    local report_dir="$RUNTIME_DIR/final_reports"
    if [[ "$(read_mode)" == "source" ]]; then
        report_dir="$INSTALL_DIR/final_reports"
    fi
    mkdir -p "$report_dir"
    echo "BettaFish reports: $report_dir"
    find "$report_dir" -maxdepth 2 -type f \( -name "*.html" -o -name "*.md" -o -name "*.pdf" -o -name "*.json" \) -print 2>/dev/null | tail -20
}

mirofish_guide() {
    load_env
    cat <<EOF
BettaFish -> MiroFish workflow

1. Start BettaFish and generate an analysis report:
   bash workbench/bettafish/startup.sh start
   Open http://localhost:$APP_PORT

2. Find generated reports:
   bash workbench/bettafish/startup.sh reports

3. Use the latest HTML/Markdown report in MiroFish as seed material:
   bash workbench/mirofish/startup.sh start
   Open http://localhost:3000

Typical report directory:
   $RUNTIME_DIR/final_reports
EOF
}

doctor_app() {
    command -v docker >/dev/null 2>&1 && docker --version || true
    command -v python3 >/dev/null 2>&1 && python3 --version || true
    command -v uv >/dev/null 2>&1 && uv --version || true
    status_app
}

uninstall_app() {
    stop_app || true
    if command -v docker >/dev/null 2>&1; then
        docker rm -f bettafish bettafish-db >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE" "$MODE_FILE"
    success "BettaFish uninstall step completed. Runtime config and reports remain at $RUNTIME_DIR."
}

usage() {
    cat <<EOF
BettaFish AI Hub helper

Usage: $(basename "$0") <install|update|start|stop|status|logs|reports|mirofish-guide|doctor|uninstall>

Default main UI: http://localhost:$APP_PORT
Runtime config:  $ENV_FILE
Reports:         $RUNTIME_DIR/final_reports
Source dir:      $INSTALL_DIR
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
        reports) reports_app ;;
        mirofish-guide) mirofish_guide ;;
        doctor) doctor_app ;;
        uninstall) uninstall_app ;;
        help|-h|--help) usage ;;
        *) usage; return 2 ;;
    esac
}

main "$@"

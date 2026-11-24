#!/usr/bin/env bash
# Open WebUI 一键安装配置脚本
# 支持 macOS 和 Linux，优先 Docker/Docker Compose，支持主机安装回退
# 下载优先使用 adl，默认下载到 ~/Downloads

set -euo pipefail

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# ── 常量 ──
SCRIPT_NAME="install-open-webui.sh"
DOWNLOAD_DIR="${HOME}/Downloads"
INSTALL_DIR="${HOME}/open-webui"
BACKEND_DIR="${INSTALL_DIR}/backend"
VENV_DIR="${INSTALL_DIR}/.venv"
META_FILE="${INSTALL_DIR}/.install-meta"
HOST_LOG_FILE="${INSTALL_DIR}/open-webui.log"
HOST_PID_FILE="${INSTALL_DIR}/open-webui.pid"
HASH_FILE="${INSTALL_DIR}/.install-hashes"
ENV_FILE="${OPENWEBUI_ENV_FILE:-${INSTALL_DIR}/.open-webui.env}"
LAUNCH_AGENT_LABEL="${OPENWEBUI_LAUNCH_AGENT_LABEL:-com.sky.open-webui}"
LAUNCH_AGENT_PLIST="${OPENWEBUI_LAUNCH_AGENT_PLIST:-${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist}"
DEFAULT_PORT="8080"
DEFAULT_HOST_PORT="3000"
DEFAULT_PYTHON_VERSION="3.12"
DEFAULT_FALLBACK_VERSION="v0.9.5"
DEFAULT_START_TIMEOUT="180"
DEFAULT_DS4_DIR="${HOME}/ds4"
DEFAULT_DS4_PORT="8000"
DS4_INSTALL_SCRIPT="${HOME}/work/shell/ai/runtime/ds4/install-ds4.sh"

# GitHub 仓库
OPENWEBUI_REPO="open-webui/open-webui"
OPENWEBUI_RELEASE_API="https://api.github.com/repos/${OPENWEBUI_REPO}/releases/latest"

# 检测到的变量
OS=""
ARCH=""
HAS_DOCKER=false
HAS_DOCKER_COMPOSE=false
HAS_ADL=false
ADL_BIN=""
HOST_SELECTED_PORT=""

# ── 检测 adl ──
find_adl() {
    if [[ -n "${ADL_PATH:-}" && -x "${ADL_PATH}" ]]; then
        ADL_BIN="${ADL_PATH}"
        return 0
    fi
    ADL_BIN=$(command -v adl 2>/dev/null) || return 1
}

ensure_adl_detected() {
    if [[ "$HAS_ADL" == true ]]; then
        return 0
    fi

    if find_adl; then
        HAS_ADL=true
        log_info "✓ adl 可用: $ADL_BIN"
    else
        log_warn "adl 未安装，将使用 curl/wget 下载"
        return 1
    fi
}

# ── 加载 Node.js 环境 ──
load_node_env() {
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        return 0
    fi

    local fnm_bin=""
    for candidate in \
        "$HOME/.fnm/fnm" \
        "$HOME/.local/bin/fnm" \
        "/opt/homebrew/bin/fnm" \
        "/usr/local/bin/fnm"; do
        if [[ -x "$candidate" ]]; then
            fnm_bin="$candidate"
            break
        fi
    done

    if [[ -z "${fnm_bin:-}" ]]; then
        fnm_bin=$(command -v fnm 2>/dev/null || true)
    fi

    if [[ -n "${fnm_bin:-}" ]]; then
        log_info "检测到 fnm: ${fnm_bin:-}，尝试加载 Node.js 环境"
        export PATH="$(dirname "${fnm_bin:-}"):$PATH"
        eval "$("${fnm_bin:-}" env --shell bash)"
        if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
            log_info "Node.js: $(node --version)，npm: $(npm --version)"
            return 0
        fi
    fi

    return 1
}

check_node_version() {
    local major
    major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    if [[ "$major" -lt 18 ]]; then
        log_error "Node.js 版本过低: $(node --version 2>/dev/null || echo unknown)，需要 Node.js 18+"
        return 1
    fi
    return 0
}

find_python_for_openwebui() {
    local requested="${OPENWEBUI_PYTHON_VERSION:-$DEFAULT_PYTHON_VERSION}"

    if [[ -n "${OPENWEBUI_PYTHON:-}" && -x "${OPENWEBUI_PYTHON:-}" ]]; then
        echo "${OPENWEBUI_PYTHON}"
        return 0
    fi

    if command -v "python${requested}" >/dev/null 2>&1; then
        command -v "python${requested}"
        return 0
    fi

    if command -v uv >/dev/null 2>&1; then
        local uv_python
        uv_python=$(uv python find "$requested" 2>/dev/null || true)
        if [[ -n "$uv_python" && -x "$uv_python" ]]; then
            echo "$uv_python"
            return 0
        fi

        log_info "未找到 Python ${requested}，尝试通过 uv 安装..." >&2
        uv python install "$requested" >&2
        uv_python=$(uv python find "$requested" 2>/dev/null || true)
        if [[ -n "$uv_python" && -x "$uv_python" ]]; then
            echo "$uv_python"
            return 0
        fi
    fi

    return 1
}

python_major_minor() {
    local python_bin="$1"
    "$python_bin" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

latest_cached_version() {
    local latest=""
    local file base ver
    for file in "${DOWNLOAD_DIR}"/open-webui-*.tar.gz; do
        [[ -f "$file" ]] || continue
        base=$(basename "$file")
        ver="${base#open-webui-}"
        ver="${ver%.tar.gz}"
        [[ -n "$ver" ]] || continue
        latest="$ver"
    done

    [[ -n "$latest" ]] && printf 'v%s\n' "$latest"
}

probe_openai_api() {
    local base_url="$1"
    if curl -fsS --connect-timeout 2 --max-time 4 "${base_url%/}/models" >/dev/null 2>&1; then
        return 0
    fi
    curl -fsS --connect-timeout 2 --max-time 5 -X POST "${base_url%/}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer sk-ds4-local-$(hostname -s)" \
        -d '{"model":"ds4","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' >/dev/null 2>&1
}

ds4_server_log() {
    printf '%s/ds4-server.log\n' "${DS4_DIR:-$DEFAULT_DS4_DIR}"
}

ds4_installed() {
    [[ -x "${DS4_DIR:-$DEFAULT_DS4_DIR}/ds4-server" ]]
}

ds4_model_ready() {
    [[ -f "${DS4_DIR:-$DEFAULT_DS4_DIR}/ds4flash.gguf" || -L "${DS4_DIR:-$DEFAULT_DS4_DIR}/ds4flash.gguf" ]]
}

ds4_command_basename() {
    local cmd="$1"
    local first="${cmd%% *}"
    first="${first##*/}"
    printf '%s\n' "$first"
}

ds4_server_pid() {
    local ds4_dir="${DS4_DIR:-$DEFAULT_DS4_DIR}"
    local pid cmd base
    while read -r pid cmd; do
        [[ -n "${pid:-}" ]] || continue
        [[ "$pid" == "$$" ]] && continue
        [[ "$cmd" == *"install-ds4.sh"* ]] && continue
        base=$(ds4_command_basename "$cmd")
        [[ "$base" == "ds4-server" || "$cmd" == *"${ds4_dir}/ds4-server"* ]] || continue
        echo "$pid"
        return 0
    done < <(ps -axo pid=,command=)
}

ds4_conflict_pid() {
    local ds4_dir="${DS4_DIR:-$DEFAULT_DS4_DIR}"
    local pid cmd base
    while read -r pid cmd; do
        [[ -n "${pid:-}" ]] || continue
        [[ "$pid" == "$$" ]] && continue
        [[ "$cmd" == *"install-ds4.sh"* ]] && continue
        base=$(ds4_command_basename "$cmd")
        case "$base" in
            ds4-server|ds4-bench)
                continue
                ;;
            ds4|ds4-agent|ds4-eval|ds4_cpu|ds4_native)
                echo "$pid"
                return 0
                ;;
        esac
        [[ "$cmd" == *"${ds4_dir}/ds4 "* || "$cmd" == *"${ds4_dir}/ds4 -" || "$cmd" == *" ./ds4 "* || "$cmd" == *" ./ds4 -" ]] || continue
        echo "$pid"
        return 0
    done < <(ps -axo pid=,command=)
}

ds4_server_running() {
    [[ -n "$(ds4_server_pid || true)" ]]
}

ds4_listen_port_from_log() {
    local log_file
    log_file=$(ds4_server_log)
    [[ -f "$log_file" ]] || return 1
    sed -nE 's/.*listening on http:\/\/[^:]+:([0-9]+).*/\1/p' "$log_file" | tail -1
}

ds4_candidate_ports() {
    local seen=" " port
    for port in "${OPENWEBUI_DS4_PORT:-}" "${DS4_PORT:-}" "$(ds4_listen_port_from_log || true)" "$DEFAULT_DS4_PORT" "8080"; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [[ "$seen" == *" $port "* ]] && continue
        printf '%s\n' "$port"
        seen="${seen}${port} "
    done
}

ds4_local_api_base() {
    local port
    while read -r port; do
        [[ -n "$port" ]] || continue
        if probe_openai_api "http://localhost:${port}/v1"; then
            printf 'http://localhost:%s/v1\n' "$port"
            return 0
        fi
    done < <(ds4_candidate_ports)
    return 1
}

ds4_preferred_api_base() {
    local live port
    live=$(ds4_local_api_base || true)
    if [[ -n "$live" ]]; then
        printf '%s\n' "$live"
        return 0
    fi

    if ds4_installed && ds4_model_ready; then
        port=$(ds4_listen_port_from_log || true)
        [[ "$port" =~ ^[0-9]+$ ]] || port="${OPENWEBUI_DS4_PORT:-${DS4_PORT:-$DEFAULT_DS4_PORT}}"
        printf 'http://localhost:%s/v1\n' "$port"
        return 0
    fi

    return 1
}

api_base_for_mode() {
    local base_url="$1"
    local mode="${2:-host}"
    if [[ "$mode" == "docker" ]]; then
        printf '%s\n' "${base_url/localhost/host.docker.internal}"
    else
        printf '%s\n' "$base_url"
    fi
}

maybe_start_ds4_server() {
    ds4_installed || return 1
    ds4_model_ready || return 1

    local ds4_api_base
    ds4_api_base=$(ds4_local_api_base || true)
    if [[ -n "$ds4_api_base" ]]; then
        export DS4_API_BASE_URL="$ds4_api_base"
        return 0
    fi

    if [[ -n "${DS4_START_ATTEMPTED:-}" ]]; then
        return 1
    fi
    export DS4_START_ATTEMPTED=1

    local server_pid="" conflict_pid="" auto_restart=0 auto_stop=0
    server_pid=$(ds4_server_pid || true)
    conflict_pid=$(ds4_conflict_pid || true)

    if [[ -n "$server_pid" ]]; then
        if [[ "${OPENWEBUI_AUTOSTART_DS4:-0}" == "1" ]]; then
            auto_restart=1
        elif ask_yes_no "检测到 ds4-server 进程 PID=${server_pid} 但 API 未响应，是否交由 DS4 脚本重启" "y" 10 >&2; then
            auto_restart=1
        else
            log_info "保留当前 ds4-server 进程；Open WebUI 可稍后手动配置模型后端。" >&2
            return 1
        fi
    elif [[ -n "$conflict_pid" ]]; then
        if [[ "${OPENWEBUI_AUTOSTART_DS4:-0}" == "1" ]]; then
            auto_stop=1
        elif ask_yes_no "检测到 DS4 CLI/其他进程 PID=${conflict_pid}，是否交由 DS4 脚本结束该进程并启动 ds4-server" "y" 10 >&2; then
            auto_stop=1
        else
            log_info "跳过启动 DS4；Open WebUI 可稍后在设置中配置模型后端。" >&2
            return 1
        fi
    elif [[ "${OPENWEBUI_AUTOSTART_DS4:-0}" != "1" ]]; then
        if ! ask_yes_no "检测到 DS4 已安装但 API 未运行，是否启动 ds4-server" "n" 10 >&2; then
            log_info "跳过启动 DS4；Open WebUI 可稍后在设置中配置模型后端。" >&2
            return 1
        fi
    fi

    log_info "正在调用 DS4 脚本启动 ds4-server..." >&2
    if [[ -x "$DS4_INSTALL_SCRIPT" ]]; then
        DS4_AUTO_STOP_CONFLICT="$auto_stop" \
        DS4_AUTO_RESTART_BROKEN_SERVER="$auto_restart" \
        "$DS4_INSTALL_SCRIPT" server-bg >&2 || return 1
    else
        (cd "${DS4_DIR:-$DEFAULT_DS4_DIR}" && nohup ./ds4-server > ds4-server.log 2>&1 & echo $! > ds4-server.pid)
    fi

    local i
    for i in {1..30}; do
        ds4_api_base=$(ds4_local_api_base || true)
        if [[ -n "$ds4_api_base" ]]; then
            export DS4_API_READY=1
            export DS4_API_BASE_URL="$ds4_api_base"
            return 0
        fi
        sleep 1
    done
    return 1
}

detect_api_backend() {
    local mode="${1:-host}"
    local ds4_api_base

    ds4_api_base=$(ds4_local_api_base || true)
    if [[ -n "$ds4_api_base" ]]; then
        printf '%s|sk-ds4-local-%s\n' "$(api_base_for_mode "$ds4_api_base" "$mode")" "$(hostname -s)"
        return 0
    fi

    if [[ "${DS4_API_READY:-0}" == "1" && -n "${DS4_API_BASE_URL:-}" ]]; then
        printf '%s|sk-ds4-local-%s\n' "$(api_base_for_mode "$DS4_API_BASE_URL" "$mode")" "$(hostname -s)"
        return 0
    fi

    if maybe_start_ds4_server; then
        ds4_api_base="${DS4_API_BASE_URL:-$(ds4_local_api_base || true)}"
        if [[ -n "$ds4_api_base" ]]; then
            printf '%s|sk-ds4-local-%s\n' "$(api_base_for_mode "$ds4_api_base" "$mode")" "$(hostname -s)"
            return 0
        fi
    fi

    local host_prefix="localhost"
    [[ "$mode" == "docker" ]] && host_prefix="host.docker.internal"
    if probe_openai_api "http://localhost:11434/v1"; then
        printf 'http://%s:11434/v1|\n' "$host_prefix"
        return 0
    fi

    if ds4_installed && ds4_model_ready; then
        if [[ -z "${DS4_START_ATTEMPTED:-}" ]]; then
            log_info "检测到 DS4 已安装但 API 未运行。" >&2
        fi
    fi

    return 1
}

configure_detected_backend_env() {
    local mode="${1:-host}"
    local detected api_base_url api_key

    if [[ -n "${OPENWEBUI_API_BASE_URL:-}" ]]; then
        export OPENWEBUI_API_BASE_URL="$OPENWEBUI_API_BASE_URL"
        [[ -n "${OPENWEBUI_API_KEY:-}" ]] && export OPENWEBUI_API_KEY="$OPENWEBUI_API_KEY"
        return 0
    fi

    detected=$(detect_api_backend "$mode" || true)
    [[ -n "$detected" ]] || return 1

    api_base_url="${detected%%|*}"
    api_key="${detected#*|}"
    export OPENWEBUI_API_BASE_URL="$api_base_url"
    if [[ -n "$api_key" ]]; then
        export OPENWEBUI_API_KEY="$api_key"
    fi
    log_info "已发现 OpenAI-compatible 后端: $api_base_url"
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

env_file_value() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$ENV_FILE" >/dev/null 2>&1 || exit 1
        eval "printf '%s' \"\${${key}:-}\""
    )
}

generate_webui_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import secrets; print(secrets.token_hex(32))'
        return 0
    fi
    date +%s | shasum -a 256 | awk '{print $1}'
}

generate_admin_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\n'
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import secrets; print(secrets.token_urlsafe(24))'
        return 0
    fi
    date +%s | shasum -a 256 | awk '{print $1}'
}

openwebui_has_users() {
    local data_dir="$1"
    local db="${data_dir}/webui.db"

    [[ -f "$db" ]] || return 1
    if command -v sqlite3 >/dev/null 2>&1; then
        local count
        count=$(sqlite3 "$db" "SELECT COUNT(*) FROM user;" 2>/dev/null || echo "")
        [[ "$count" =~ ^[1-9][0-9]*$ ]]
        return $?
    fi

    # sqlite3 不可用时保守处理：已有数据库就视为已有账号，避免覆盖管理员配置。
    return 0
}

openwebui_user_count() {
    local data_dir="$1"
    local db="${data_dir}/webui.db"

    [[ -f "$db" ]] || { echo 0; return 0; }
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db" "SELECT COUNT(*) FROM user;" 2>/dev/null || echo 0
    else
        echo "unknown"
    fi
}

openwebui_admin_emails() {
    local data_dir="$1"
    local db="${data_dir}/webui.db"

    [[ -f "$db" ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 "$db" "SELECT email FROM user WHERE role='admin' ORDER BY created_at LIMIT 5;" 2>/dev/null || true
}

openwebui_print_user_login_hint() {
    local data_dir="$1"
    local count admins

    count=$(openwebui_user_count "$data_dir")
    admins=$(openwebui_admin_emails "$data_dir" | tr '\n' ',' | sed 's/,$//')
    log_info "检测到已有 Open WebUI 用户数: ${count}。请使用已有账号登录。"
    if [[ -n "$admins" ]]; then
        log_info "当前管理员邮箱: $admins"
    fi
    log_info "忘记密码可执行: $0 reset-admin [邮箱]"
}

reset_admin_password() {
    local email="${1:-${OPENWEBUI_ADMIN_EMAIL:-}}"
    local data_dir="${OPENWEBUI_DATA_DIR:-${BACKEND_DIR}/data}"
    local db="${data_dir}/webui.db"
    local password="${OPENWEBUI_ADMIN_PASSWORD:-}"
    local name="${OPENWEBUI_ADMIN_NAME:-Admin}"
    local python_bin generated=false

    [[ -f "$db" ]] || {
        log_error "未找到 Open WebUI 数据库: $db。请先完成一次启动，或检查 OPENWEBUI_DATA_DIR。"
        return 1
    }

    if [[ -z "$email" ]] && command -v sqlite3 >/dev/null 2>&1; then
        email=$(sqlite3 "$db" "SELECT email FROM user WHERE role='admin' ORDER BY created_at LIMIT 1;" 2>/dev/null || true)
        [[ -n "$email" ]] || email=$(sqlite3 "$db" "SELECT email FROM user ORDER BY created_at LIMIT 1;" 2>/dev/null || true)
    fi
    email="${email:-admin@localhost}"

    if [[ -z "$password" ]]; then
        password=$(generate_admin_password)
        generated=true
    fi

    python_bin="$VENV_DIR/bin/python"
    [[ -x "$python_bin" ]] || python_bin=$(command -v python3 2>/dev/null || true)
    [[ -n "$python_bin" ]] || {
        log_error "未找到 Python，无法重置管理员密码。"
        return 1
    }

    "$python_bin" - "$db" "$email" "$password" "$name" <<'PY'
import sqlite3
import sys
import time
import uuid

try:
    import bcrypt
except Exception as exc:
    raise SystemExit(f"missing bcrypt: {exc}")

db, email, password, name = sys.argv[1:5]
now = int(time.time())
hashed = bcrypt.hashpw(password.encode("utf-8")[:72], bcrypt.gensalt()).decode("utf-8")

conn = sqlite3.connect(db)
cur = conn.cursor()

cur.execute("SELECT id FROM user WHERE lower(email)=lower(?) LIMIT 1", (email,))
row = cur.fetchone()

if row:
    user_id = row[0]
    cur.execute(
        "UPDATE user SET role='admin', updated_at=? WHERE id=?",
        (now, user_id),
    )
    cur.execute("SELECT COUNT(*) FROM auth WHERE id=?", (user_id,))
    if cur.fetchone()[0]:
        cur.execute(
            "UPDATE auth SET email=?, password=?, active=1 WHERE id=?",
            (email.lower(), hashed, user_id),
        )
    else:
        cur.execute(
            "INSERT INTO auth (id, email, password, active) VALUES (?, ?, ?, 1)",
            (user_id, email.lower(), hashed),
        )
else:
    user_id = str(uuid.uuid4())
    cur.execute(
        "INSERT INTO auth (id, email, password, active) VALUES (?, ?, ?, 1)",
        (user_id, email.lower(), hashed),
    )

    columns = [r[1] for r in cur.execute("PRAGMA table_info(user)").fetchall()]
    values = {
        "id": user_id,
        "email": email.lower(),
        "username": None,
        "role": "admin",
        "name": name,
        "profile_image_url": "/user.png",
        "profile_banner_image_url": None,
        "bio": None,
        "gender": None,
        "date_of_birth": None,
        "timezone": None,
        "presence_state": None,
        "status_emoji": None,
        "status_message": None,
        "status_expires_at": None,
        "info": None,
        "settings": None,
        "oauth": None,
        "scim": None,
        "last_active_at": now,
        "updated_at": now,
        "created_at": now,
    }
    insert_columns = [c for c in columns if c in values]
    placeholders = ", ".join(["?"] * len(insert_columns))
    cur.execute(
        f"INSERT INTO user ({', '.join(insert_columns)}) VALUES ({placeholders})",
        [values[c] for c in insert_columns],
    )

conn.commit()
conn.close()
print(email.lower())
PY

    log_info "管理员账号已设置: $email"
    if [[ "$generated" == true ]]; then
        log_warn "新管理员密码: $password"
        log_warn "请登录后立即修改密码。"
    else
        log_info "已使用 OPENWEBUI_ADMIN_PASSWORD 指定的密码。"
    fi
}

detect_static_api_backend() {
    local mode="${1:-host}"
    local host_prefix="localhost"
    local ds4_api_base
    [[ "$mode" == "docker" ]] && host_prefix="host.docker.internal"

    if [[ -n "${OPENWEBUI_API_BASE_URL:-}" ]]; then
        printf '%s|%s|custom\n' "$OPENWEBUI_API_BASE_URL" "${OPENWEBUI_API_KEY:-}"
        return 0
    fi

    ds4_api_base=$(ds4_preferred_api_base || true)
    if [[ -n "$ds4_api_base" ]]; then
        printf '%s|sk-ds4-local-%s|ds4\n' "$(api_base_for_mode "$ds4_api_base" "$mode")" "$(hostname -s)"
        return 0
    fi

    if probe_openai_api "http://localhost:11434/v1"; then
        printf 'http://%s:11434/v1||ollama\n' "$host_prefix"
        return 0
    fi

    return 1
}

write_openwebui_env_config() {
    local port="${1:-$(current_host_port)}"
    local host="${OPENWEBUI_HOST:-0.0.0.0}"
    local data_dir="${OPENWEBUI_DATA_DIR:-${BACKEND_DIR}/data}"
    local webui_url="${OPENWEBUI_URL:-http://localhost:${port}}"
    local auth="${OPENWEBUI_AUTH:-True}"
    local name="${OPENWEBUI_NAME:-Open WebUI}"
    local secret="${OPENWEBUI_SECRET_KEY:-}"
    local admin_email="${OPENWEBUI_ADMIN_EMAIL:-}"
    local admin_password="${OPENWEBUI_ADMIN_PASSWORD:-}"
    local admin_name="${OPENWEBUI_ADMIN_NAME:-Admin}"
    local signup="${OPENWEBUI_ENABLE_SIGNUP:-}"
    local default_user_role="${OPENWEBUI_DEFAULT_USER_ROLE:-pending}"
    local admin_generated=false
    local users_exist=false
    local detected api_base_url api_key backend
    local tmp

    mkdir -p "$INSTALL_DIR" "$data_dir"

    if [[ -z "$secret" ]]; then
        secret=$(env_file_value WEBUI_SECRET_KEY || true)
    fi
    if [[ -z "$secret" ]]; then
        secret=$(generate_webui_secret)
    fi

    if [[ -z "$admin_email" ]]; then
        admin_email=$(env_file_value WEBUI_ADMIN_EMAIL || true)
    fi
    if [[ -z "$admin_password" ]]; then
        admin_password=$(env_file_value WEBUI_ADMIN_PASSWORD || true)
    fi
    if [[ -z "$signup" ]]; then
        signup=$(env_file_value ENABLE_SIGNUP || true)
    fi
    if [[ -z "$signup" ]]; then
        signup="False"
    fi
    if ! openwebui_has_users "$data_dir"; then
        if [[ -z "$admin_email" ]]; then
            admin_email="${OPENWEBUI_DEFAULT_ADMIN_EMAIL:-admin@localhost}"
        fi
        if [[ -z "$admin_password" ]]; then
            admin_password=$(generate_admin_password)
            admin_generated=true
        fi
    else
        users_exist=true
    fi

    detected=$(detect_static_api_backend host || true)
    if [[ -n "$detected" ]]; then
        api_base_url="${detected%%|*}"
        local rest="${detected#*|}"
        api_key="${rest%%|*}"
        backend="${detected##*|}"
    else
        api_base_url="${OPENAI_API_BASE_URLS:-}"
        api_key="${OPENAI_API_KEYS:-}"
        backend="${OPENWEBUI_DETECTED_BACKEND:-none}"
    fi

    tmp=$(mktemp)
    if [[ -f "$ENV_FILE" ]]; then
        awk '
            /^# >>> open-webui auto config$/ {skip=1; next}
            /^# <<< open-webui auto config$/ {skip=0; next}
            skip != 1 {print}
        ' "$ENV_FILE" > "$tmp"
    fi

    {
        cat "$tmp"
        [[ -s "$tmp" ]] && printf '\n'
        echo "# >>> open-webui auto config"
        echo "# Managed by install-open-webui.sh. Put custom settings outside this block."
        echo "export WEBUI_SECRET_KEY=$(shell_quote "$secret")"
        echo "export WEBUI_NAME=$(shell_quote "$name")"
        echo "export WEBUI_AUTH=$(shell_quote "$auth")"
        echo "export ENABLE_SIGNUP=$(shell_quote "$signup")"
        echo "export DEFAULT_USER_ROLE=$(shell_quote "$default_user_role")"
        echo "export ENABLE_LOGIN_FORM=$(shell_quote "${ENABLE_LOGIN_FORM:-True}")"
        echo "export ENABLE_PASSWORD_AUTH=$(shell_quote "${ENABLE_PASSWORD_AUTH:-True}")"
        if [[ -n "$admin_email" && -n "$admin_password" ]]; then
            echo "export WEBUI_ADMIN_EMAIL=$(shell_quote "$admin_email")"
            echo "export WEBUI_ADMIN_PASSWORD=$(shell_quote "$admin_password")"
            echo "export WEBUI_ADMIN_NAME=$(shell_quote "$admin_name")"
        fi
        echo "export DATA_DIR=$(shell_quote "$data_dir")"
        echo "export HOST=$(shell_quote "$host")"
        echo "export PORT=$(shell_quote "$port")"
        echo "export OPENWEBUI_PORT=$(shell_quote "$port")"
        echo "export WEBUI_URL=$(shell_quote "$webui_url")"
        echo "export OPENWEBUI_FAST_STARTUP=$(shell_quote "${OPENWEBUI_FAST_STARTUP:-1}")"
        echo "export HF_HUB_OFFLINE=$(shell_quote "${HF_HUB_OFFLINE:-1}")"
        echo "export TRANSFORMERS_OFFLINE=$(shell_quote "${TRANSFORMERS_OFFLINE:-1}")"
        echo "export HF_HUB_ETAG_TIMEOUT=$(shell_quote "${HF_HUB_ETAG_TIMEOUT:-2}")"
        echo "export HF_HUB_DOWNLOAD_TIMEOUT=$(shell_quote "${HF_HUB_DOWNLOAD_TIMEOUT:-5}")"
        echo "export RAG_EMBEDDING_MODEL_AUTO_UPDATE=$(shell_quote "${RAG_EMBEDDING_MODEL_AUTO_UPDATE:-False}")"
        echo "export RAG_RERANKING_MODEL_AUTO_UPDATE=$(shell_quote "${RAG_RERANKING_MODEL_AUTO_UPDATE:-False}")"
        echo "export WHISPER_MODEL_AUTO_UPDATE=$(shell_quote "${WHISPER_MODEL_AUTO_UPDATE:-False}")"
        echo "export ENABLE_VERSION_UPDATE_CHECK=$(shell_quote "${ENABLE_VERSION_UPDATE_CHECK:-False}")"
        if [[ -n "$api_base_url" ]]; then
            echo "export ENABLE_OPENAI_API=$(shell_quote "${ENABLE_OPENAI_API:-True}")"
            echo "export OPENAI_API_BASE_URLS=$(shell_quote "$api_base_url")"
            [[ -n "$api_key" ]] && echo "export OPENAI_API_KEYS=$(shell_quote "$api_key")"
            echo "export OPENWEBUI_DETECTED_BACKEND=$(shell_quote "$backend")"
        fi
        echo "# <<< open-webui auto config"
    } > "$ENV_FILE"

    rm -f "$tmp"
    chmod 600 "$ENV_FILE" 2>/dev/null || true

    log_info "已写入 Open WebUI 自动配置: $ENV_FILE"
    log_info "认证已启用: WEBUI_AUTH=${auth:-True}，注册开关: ENABLE_SIGNUP=${signup:-False}，默认新用户角色: ${default_user_role:-pending}"
    if [[ "$users_exist" == false && -n "$admin_email" && -n "$admin_password" ]]; then
        log_info "已配置首个管理员账号: $admin_email"
        if [[ "$admin_generated" == true ]]; then
            log_warn "已自动生成管理员密码，保存在 ${ENV_FILE}；首次登录后建议在 UI 中修改。"
        fi
    elif [[ "$users_exist" == true ]]; then
        openwebui_print_user_login_hint "$data_dir"
        if [[ -n "$admin_email" && -n "$admin_password" ]]; then
            log_info "已保留 ${ENV_FILE} 中的 WEBUI_ADMIN_* 记录；它不会覆盖已有用户密码。"
        fi
    fi
    if [[ -n "$api_base_url" ]]; then
        log_info "自动配置模型后端: ${backend:-unknown} -> $api_base_url"
    else
        log_warn "未自动发现模型后端；可稍后在 Web UI 中配置或设置 OPENWEBUI_API_BASE_URL。"
    fi
}

ensure_host_start_script() {
    if [[ -x "$INSTALL_DIR/start.sh" ]]; then
        return 0
    fi
    if [[ ! -x "$BACKEND_DIR/start.sh" ]]; then
        log_error "未找到 Open WebUI 后端启动脚本: $BACKEND_DIR/start.sh"
        log_info "请先执行: $0 host"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"

ENV_FILE="${OPENWEBUI_ENV_FILE:-$(pwd)/.open-webui.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

export WEBUI_AUTH="${OPENWEBUI_AUTH:-${WEBUI_AUTH:-True}}"
export WEBUI_NAME="${WEBUI_NAME:-Open WebUI}"
export OPENWEBUI_PORT="${OPENWEBUI_PORT:-${PORT:-3000}}"

if ! command -v node >/dev/null 2>&1; then
    for fnm_bin in "$HOME/.fnm/fnm" "$HOME/.local/bin/fnm" "/opt/homebrew/bin/fnm" "/usr/local/bin/fnm"; do
        if [[ -x "${fnm_bin:-}" ]]; then
            export PATH="$(dirname "${fnm_bin:-}"):$PATH"
            eval "$("${fnm_bin:-}" env --shell bash)"
            break
        fi
    done
fi

probe_openai_api() {
    local base_url="$1"
    if curl -fsS --connect-timeout 2 --max-time 4 "${base_url%/}/models" >/dev/null 2>&1; then
        return 0
    fi
    curl -fsS --connect-timeout 2 --max-time 5 -X POST "${base_url%/}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer sk-ds4-local-$(hostname -s)" \
        -d '{"model":"ds4","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' >/dev/null 2>&1
}

load_ds4_env_backend() {
    [[ -f "$HOME/.ds4-env" ]] || return 1
    # shellcheck disable=SC1090
    source "$HOME/.ds4-env"
    if [[ -n "${DS4_API_BASE_URL:-}" ]] && probe_openai_api "$DS4_API_BASE_URL"; then
        export OPENAI_API_BASE_URLS="$DS4_API_BASE_URL"
        export OPENAI_API_KEYS="${DS4_API_KEY:-sk-ds4-local-$(hostname -s)}"
        echo "已加载 DS4 后端配置: $DS4_API_BASE_URL"
        return 0
    fi
    if [[ -n "${OPENAI_API_BASE_URL:-}" ]] && probe_openai_api "$OPENAI_API_BASE_URL"; then
        export OPENAI_API_BASE_URLS="$OPENAI_API_BASE_URL"
        export OPENAI_API_KEYS="${OPENAI_API_KEY:-sk-ds4-local-$(hostname -s)}"
        echo "已加载 OpenAI-compatible 后端配置: $OPENAI_API_BASE_URL"
        return 0
    fi
    return 1
}

if [[ -n "${OPENWEBUI_API_BASE_URL:-}" ]]; then
    export OPENAI_API_BASE_URLS="$OPENWEBUI_API_BASE_URL"
    if [[ -n "${OPENWEBUI_API_KEY:-}" ]]; then
        export OPENAI_API_KEYS="$OPENWEBUI_API_KEY"
    fi
    echo "已配置自定义 API 后端: $OPENWEBUI_API_BASE_URL"
elif [[ -n "${OPENAI_API_BASE_URLS:-}" ]] && probe_openai_api "${OPENAI_API_BASE_URLS%%,*}"; then
    echo "已加载 API 后端配置: $OPENAI_API_BASE_URLS"
elif load_ds4_env_backend; then
    :
elif probe_openai_api "http://localhost:8000/v1"; then
    export OPENAI_API_BASE_URLS="http://localhost:8000/v1"
    export OPENAI_API_KEYS="sk-ds4-local-$(hostname -s)"
    echo "已配置 DS4 后端"
elif probe_openai_api "http://localhost:8080/v1"; then
    export OPENAI_API_BASE_URLS="http://localhost:8080/v1"
    export OPENAI_API_KEYS="sk-ds4-local-$(hostname -s)"
    echo "已配置 DS4 后端"
elif probe_openai_api "http://localhost:11434/v1"; then
    export OPENAI_API_BASE_URLS="http://localhost:11434/v1"
    echo "已配置 Ollama 后端"
fi

export PATH="$(pwd)/.venv/bin:$PATH"
export HOST="${OPENWEBUI_HOST:-${HOST:-0.0.0.0}}"
export PORT="${OPENWEBUI_PORT:-${PORT:-3000}}"

if [[ "${OPENWEBUI_FAST_STARTUP:-1}" == "1" ]]; then
    export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
    export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
    export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-2}"
    export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-5}"
    export RAG_EMBEDDING_MODEL_AUTO_UPDATE="${RAG_EMBEDDING_MODEL_AUTO_UPDATE:-False}"
    export RAG_RERANKING_MODEL_AUTO_UPDATE="${RAG_RERANKING_MODEL_AUTO_UPDATE:-False}"
    export WHISPER_MODEL_AUTO_UPDATE="${WHISPER_MODEL_AUTO_UPDATE:-False}"
    export ENABLE_VERSION_UPDATE_CHECK="${ENABLE_VERSION_UPDATE_CHECK:-False}"
fi

cd backend
if [[ -z "${WEBUI_SECRET_KEY:-}" && -z "${WEBUI_JWT_SECRET_KEY:-}" ]]; then
    KEY_FILE="${WEBUI_SECRET_KEY_FILE:-.webui_secret_key}"
    if [[ ! -f "$KEY_FILE" ]]; then
        head -c 12 /dev/random | base64 > "$KEY_FILE"
    fi
    WEBUI_SECRET_KEY="$(cat "$KEY_FILE")"
    export WEBUI_SECRET_KEY
fi

PYTHON_CMD="$(command -v python3 || command -v python)"
UVICORN_WORKERS="${UVICORN_WORKERS:-1}"
exec "$PYTHON_CMD" -m uvicorn open_webui.main:app \
    --host "$HOST" \
    --port "$PORT" \
    --forwarded-allow-ips "${FORWARDED_ALLOW_IPS:-*}" \
    --workers "$UVICORN_WORKERS"
EOF
    chmod +x "$INSTALL_DIR/start.sh"
    log_info "已生成主机启动脚本: $INSTALL_DIR/start.sh"
}

current_host_port() {
    if [[ -n "${OPENWEBUI_PORT:-}" ]]; then
        echo "$OPENWEBUI_PORT"
        return 0
    fi
    if [[ -f "$META_FILE" ]]; then
        local meta_port
        meta_port=$(grep '^port=' "$META_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        if [[ "$meta_port" =~ ^[0-9]+$ ]]; then
            echo "$meta_port"
            return 0
        fi
    fi
    echo "$DEFAULT_HOST_PORT"
}

local_lan_ip() {
    local ip="" iface=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        iface=$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        if [[ -n "$iface" ]]; then
            ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        fi
        [[ -n "$ip" ]] || ip=$(ipconfig getifaddr en0 2>/dev/null || true)
        [[ -n "$ip" ]] || ip=$(ipconfig getifaddr en1 2>/dev/null || true)
    elif command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    [[ -n "$ip" ]] && echo "$ip"
}

print_host_access_urls() {
    local port="$1"
    local ip
    ip=$(local_lan_ip || true)
    log_info "访问地址: http://localhost:${port}"
    if [[ -n "$ip" ]]; then
        log_info "局域网访问: http://${ip}:${port}"
    fi
}

host_service_ready() {
    local port="${1:-$(current_host_port)}"
    curl -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:${port}/health" >/dev/null 2>&1
}

port_pid() {
    local port="$1"
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

process_cmd() {
    local pid="$1"
    ps -p "$pid" -o command= 2>/dev/null || true
}

openwebui_pids() {
    pgrep -f "open_webui.main:app" 2>/dev/null | while read -r pid; do
        [[ -n "$pid" && "$pid" != "$$" ]] && echo "$pid"
    done
}

pid_listen_ports() {
    local pid="$1"
    lsof -Pan -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {name=$9; sub(/^.*:/, "", name); sub(/ .*/, "", name); if (name ~ /^[0-9]+$/) print name}' | sort -n | uniq
}

is_openwebui_pid() {
    local pid="$1"
    local cmd
    cmd=$(process_cmd "$pid")
    [[ "$cmd" == *"open_webui.main:app"* || "$cmd" == *"$INSTALL_DIR"* || "$cmd" == *"open-webui"* ]]
}

cleanup_stale_openwebui_processes() {
    local keep_port="$1"
    local stale=()
    local pid ports port cmd
    local auto_cleanup="${OPENWEBUI_SINGLE_INSTANCE:-1}"

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        ports=$(pid_listen_ports "$pid" | tr '\n' ',' | sed 's/,$//')
        if [[ -z "$ports" ]]; then
            continue
        fi

        local keep=false
        IFS=',' read -r -a port_array <<< "$ports"
        for port in "${port_array[@]}"; do
            if [[ "$port" == "$keep_port" ]]; then
                keep=true
                break
            fi
        done
        [[ "$keep" == true ]] && continue
        stale+=("${pid}|${ports}|$(process_cmd "$pid")")
    done < <(openwebui_pids)

    [[ "${#stale[@]}" -eq 0 ]] && return 0

    log_warn "检测到其他 Open WebUI 历史进程:"
    for item in "${stale[@]}"; do
        IFS='|' read -r pid ports cmd <<< "$item"
        log_warn "  PID=$pid PORT=$ports CMD=$cmd"
    done

    if [[ "$auto_cleanup" == "1" ]]; then
        log_info "OPENWEBUI_SINGLE_INSTANCE=1，自动清理历史 Open WebUI 进程。"
    fi

    if [[ "$auto_cleanup" == "1" ]] || ask_yes_no "是否结束这些历史 Open WebUI 进程" "y"; then
        for item in "${stale[@]}"; do
            IFS='|' read -r pid ports cmd <<< "$item"
            kill "$pid" 2>/dev/null || true
        done
        sleep 1
        for item in "${stale[@]}"; do
            IFS='|' read -r pid ports cmd <<< "$item"
            kill -9 "$pid" 2>/dev/null || true
        done
        log_info "历史 Open WebUI 进程已清理。"
    fi
}

find_free_port() {
    local start="${1:-$DEFAULT_HOST_PORT}"
    local port
    for ((port=start; port<start+200; port++)); do
        if [[ -z "$(port_pid "$port")" ]]; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local timeout="${3:-5}"
    local answer suffix

    if [[ "$default" == "y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    if [[ -t 0 ]]; then
        if read -r -t "$timeout" -p "${prompt} ${suffix} (${timeout}s): " answer; then
            answer="${answer:-$default}"
        else
            printf '\n'
            answer="$default"
            log_info "输入超时，自动选择: $answer"
        fi
    else
        answer="$default"
        log_info "非交互模式，自动选择: $prompt -> $answer"
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

launchctl_domain() {
    printf 'gui/%s\n' "$(id -u)"
}

launch_agent_keepalive_xml() {
    if [[ "${OPENWEBUI_LAUNCH_KEEPALIVE:-0}" == "1" ]]; then
        cat <<'EOF'
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
EOF
    fi
}

write_launch_agent_plist() {
    if ! is_macos; then
        log_error "LaunchAgent 仅支持 macOS。"
        return 1
    fi
    ensure_host_start_script || return 1

    mkdir -p "$(dirname "$LAUNCH_AGENT_PLIST")" "$INSTALL_DIR"
    cat > "$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>exec "${INSTALL_DIR}/start.sh"</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
$(launch_agent_keepalive_xml)
    <key>EnvironmentVariables</key>
    <dict>
        <key>OPENWEBUI_ENV_FILE</key>
        <string>${ENV_FILE}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/open-webui.launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/open-webui.launchd.err.log</string>
</dict>
</plist>
EOF
    chmod 644 "$LAUNCH_AGENT_PLIST"
    log_info "已写入 LaunchAgent: $LAUNCH_AGENT_PLIST"
}

launch_agent_loaded() {
    is_macos || return 1
    launchctl print "$(launchctl_domain)/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1
}

unload_launch_agent() {
    is_macos || return 0
    if launch_agent_loaded; then
        launchctl bootout "$(launchctl_domain)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || \
            launchctl unload "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
    fi
}

enable_autostart() {
    log_step "启用 Open WebUI 开机自启动..."
    if ! is_macos; then
        log_error "当前自启动命令仅支持 macOS LaunchAgent。"
        return 1
    fi

    write_openwebui_env_config "$(current_host_port)"
    write_launch_agent_plist
    unload_launch_agent
    if launchctl bootstrap "$(launchctl_domain)" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
        :
    elif launchctl load -w "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
        :
    else
        log_error "LaunchAgent 加载失败: $LAUNCH_AGENT_PLIST"
        return 1
    fi
    launchctl enable "$(launchctl_domain)/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
    if host_service_ready "$(current_host_port)"; then
        log_info "Open WebUI 当前已在运行，仅注册下次登录/重启后自启动。"
    else
        launchctl kickstart -k "$(launchctl_domain)/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
    fi
    log_info "✓ 已启用 Open WebUI 开机自启动"
    log_info "LaunchAgent: $LAUNCH_AGENT_PLIST"
    log_info "查看状态: $0 autostart-status"
}

disable_autostart() {
    log_step "禁用 Open WebUI 开机自启动..."
    if ! is_macos; then
        log_error "当前自启动命令仅支持 macOS LaunchAgent。"
        return 1
    fi
    unload_launch_agent
    rm -f "$LAUNCH_AGENT_PLIST"
    log_info "✓ 已禁用 Open WebUI 开机自启动"
}

autostart_status() {
    if ! is_macos; then
        log_info "自启动状态: 当前系统不是 macOS，未使用 LaunchAgent。"
        return 0
    fi

    if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
        log_info "LaunchAgent 文件: $LAUNCH_AGENT_PLIST"
    else
        log_info "LaunchAgent 文件: 未创建"
    fi

    if launch_agent_loaded; then
        log_info "✓ 自启动状态: 已加载 (${LAUNCH_AGENT_LABEL})"
    else
        log_info "自启动状态: 未加载"
    fi
}

maybe_enable_autostart_after_default_install() {
    if ! is_macos; then
        return 0
    fi
    if [[ ! -x "$INSTALL_DIR/start.sh" && ! -x "$BACKEND_DIR/start.sh" ]]; then
        log_info "当前安装模式未生成主机启动脚本，跳过 LaunchAgent 自启动配置。"
        return 0
    fi
    if ask_yes_no "是否创建 Open WebUI 开机/登录自启动服务" "y" 15; then
        enable_autostart
    else
        log_info "跳过自启动配置。需要时可执行: $0 -a"
    fi
}

update_meta_port() {
    local port="$1"
    if [[ -f "$META_FILE" ]]; then
        if grep -q '^port=' "$META_FILE"; then
            sed -i.bak "s/^port=.*/port=$port/" "$META_FILE" && rm -f "${META_FILE}.bak"
        else
            echo "port=$port" >> "$META_FILE"
        fi
    fi
}

hash_paths() {
    local path
    for path in "$@"; do
        if [[ -f "$path" ]]; then
            shasum -a 256 "$path"
        else
            printf 'missing  %s\n' "$path"
        fi
    done | shasum -a 256 | awk '{print $1}'
}

get_cached_hash() {
    local key="$1"
    [[ -f "$HASH_FILE" ]] || return 0
    grep "^${key}=" "$HASH_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

set_cached_hash() {
    local key="$1"
    local value="$2"
    mkdir -p "$INSTALL_DIR"
    if [[ -f "$HASH_FILE" ]] && grep -q "^${key}=" "$HASH_FILE"; then
        sed -i.bak "s/^${key}=.*/${key}=${value}/" "$HASH_FILE" && rm -f "${HASH_FILE}.bak"
    else
        echo "${key}=${value}" >> "$HASH_FILE"
    fi
}

backend_deps_hash() {
    hash_paths "$BACKEND_DIR/requirements.txt"
}

frontend_deps_hash() {
    hash_paths \
        "$INSTALL_DIR/package.json" \
        "$INSTALL_DIR/package-lock.json" \
        "$INSTALL_DIR/pnpm-lock.yaml" \
        "$INSTALL_DIR/yarn.lock" \
        "$INSTALL_DIR/bun.lockb"
}

resolve_host_port() {
    local port
    local pid cmd new_port

    port=$(current_host_port)
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        log_warn "OPENWEBUI_PORT 非法: ${port}，改用默认端口 ${DEFAULT_HOST_PORT}"
        port="$DEFAULT_HOST_PORT"
    fi

    pid=$(port_pid "$port")
    if [[ -z "$pid" ]]; then
        HOST_SELECTED_PORT="$port"
        return 0
    fi

    cmd=$(process_cmd "$pid")
    if is_openwebui_pid "$pid"; then
        if host_service_ready "$port"; then
            log_info "端口 $port 已被 Open WebUI 占用，服务已启动。"
            log_info "进程: PID=$pid $cmd"
            if [[ "$cmd" == *"--host 127.0.0.1"* ]] && [[ "${OPENWEBUI_HOST:-0.0.0.0}" != "127.0.0.1" ]]; then
                log_warn "该实例仅监听 127.0.0.1，局域网 IP 无法访问。"
                if ask_yes_no "是否重启为 ${OPENWEBUI_HOST:-0.0.0.0} 监听" "y"; then
                    kill "$pid" 2>/dev/null || true
                    sleep 1
                    HOST_SELECTED_PORT="$port"
                    return 0
                fi
            elif ask_yes_no "是否结束该进程并重新启动" "n"; then
                kill "$pid" 2>/dev/null || true
                sleep 1
                HOST_SELECTED_PORT="$port"
                return 0
            fi
            log_info "复用当前 Open WebUI 实例。"
            HOST_SELECTED_PORT="$port"
            return 0
        fi

        log_warn "端口 $port 被 Open WebUI 相关进程占用，但服务不可访问。PID=$pid"
        log_warn "进程: $cmd"
        if ask_yes_no "是否结束该进程并重新启动" "n"; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            HOST_SELECTED_PORT="$port"
            return 0
        fi
        return 1
    fi

    log_warn "端口 $port 已被其他进程占用。PID=$pid"
    log_warn "进程: $cmd"
    if ask_yes_no "是否自动切换到未占用端口" "y"; then
        new_port=$(find_free_port "$((port + 1))")
        if [[ -z "$new_port" ]]; then
            log_error "未找到可用端口"
            return 1
        fi
        log_info "已选择可用端口: $new_port"
        HOST_SELECTED_PORT="$new_port"
        return 0
    fi

    log_error "端口 $port 被占用，未修改端口，启动中止。"
    return 1
}

latest_start_log_hint() {
    [[ -f "$HOST_LOG_FILE" ]] || return 0

    local hint
    hint=$(grep -E "Running upgrade|Application startup complete|Uvicorn running|Started server process|ERROR|Traceback|Exception|ModuleNotFoundError|Address already in use" "$HOST_LOG_FILE" 2>/dev/null | tail -1 || true)
    if [[ -n "$hint" ]]; then
        printf '%s' "$hint" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/INFO[[:space:]]+\\[[^]]+\\][[:space:]]*//; s/WARNI[[:space:]]+\\[[^]]+\\][[:space:]]*//; s/WARNING:[[:space:]]*//;' | cut -c 1-72
    fi
}

show_start_progress() {
    local elapsed="$1"
    local timeout="$2"
    local port="$3"
    local state="${4:-启动中}"
    local phase_override="${5:-}"
    local width=24
    local progress_elapsed="$elapsed"
    [[ "$state" == "已启动" ]] && progress_elapsed="$timeout"
    local filled=$(( progress_elapsed * width / timeout ))
    local empty=$(( width - filled ))
    local percent=$(( progress_elapsed * 100 / timeout ))
    local bar empty_bar hint phase line

    printf -v bar '%*s' "$filled" ''
    bar=${bar// /=}
    printf -v empty_bar '%*s' "$empty" ''
    empty_bar=${empty_bar// /.}

    if [[ -n "$phase_override" ]]; then
        phase="$phase_override"
    elif [[ -n "$(port_pid "$port")" ]]; then
        phase="等待健康检查"
    else
        phase="启动进程"
    fi

    hint=$(latest_start_log_hint)
    if [[ -n "$hint" ]]; then
        printf -v line '%s [%s%s] %3s%%  %3ss/%ss  %-14s  %s' "$state" "$bar" "$empty_bar" "$percent" "$elapsed" "$timeout" "$phase" "$hint"
    else
        printf -v line '%s [%s%s] %3s%%  %3ss/%ss  %-14s' "$state" "$bar" "$empty_bar" "$percent" "$elapsed" "$timeout" "$phase"
    fi
    printf '\r%-120s' "$line"
}

start_host_service() {
    local port

    HOST_SELECTED_PORT=""
    resolve_host_port || return 1
    port="$HOST_SELECTED_PORT"
    export OPENWEBUI_PORT="$port"
    update_meta_port "$port"
    write_openwebui_env_config "$port"
    cleanup_stale_openwebui_processes "$port"
    configure_detected_backend_env host || true

    if host_service_ready "$port"; then
        log_info "✓ Open WebUI 已在运行: http://localhost:${port}"
        print_host_access_urls "$port"
        return 0
    fi

    ensure_host_start_script || return 1

    log_step "启动 Open WebUI 主机服务..."
    mkdir -p "$INSTALL_DIR"
    nohup "$INSTALL_DIR/start.sh" > "$HOST_LOG_FILE" 2>&1 &
    local child_pid="$!"
    echo "$child_pid" > "$HOST_PID_FILE"

    local i timeout
    timeout="${OPENWEBUI_START_TIMEOUT:-$DEFAULT_START_TIMEOUT}"
    for ((i=1; i<=timeout; i++)); do
        if host_service_ready "$port"; then
            show_start_progress "$i" "$timeout" "$port" "已启动" "健康检查通过"
            printf '\n'
            log_info "✓ Open WebUI 已启动: http://localhost:${port}"
            print_host_access_urls "$port"
            log_info "日志文件: $HOST_LOG_FILE"
            if is_macos; then
                log_info "开机自启动: $0 autostart-on"
            fi
            return 0
        fi
        if ! kill -0 "$child_pid" 2>/dev/null; then
            printf '\n'
            log_warn "Open WebUI 进程已退出，请查看日志: $HOST_LOG_FILE"
            if [[ -f "$HOST_LOG_FILE" ]]; then
                tail -n 80 "$HOST_LOG_FILE" || true
            fi
            return 1
        fi
        show_start_progress "$i" "$timeout" "$port"
        sleep 1
    done

    printf '\n'
    log_warn "Open WebUI 未在 ${timeout}s 内通过健康检查，请查看日志: $HOST_LOG_FILE"
    if [[ -f "$HOST_LOG_FILE" ]]; then
        tail -n 40 "$HOST_LOG_FILE" || true
    fi
    return 1
}

# ── 检测平台 ──
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case "$OS" in
        darwin) OS="macos" ;;
        linux) OS="linux" ;;
        *) log_error "不支持的操作系统: $OS"; exit 1 ;;
    esac
    
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log_warn "未测试的架构: ${ARCH}，将尝试通用方案" ;;
    esac
    
    log_info "平台: $OS/$ARCH"
}

# ── 检测 Docker ──
detect_docker() {
    log_step "检测 Docker 环境..."
    
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            HAS_DOCKER=true
            log_info "✓ Docker 已安装且运行正常"
            
            # 检测 Docker Compose
            if docker compose version >/dev/null 2>&1; then
                HAS_DOCKER_COMPOSE=true
                log_info "✓ Docker Compose (plugin) 可用"
            elif command -v docker-compose >/dev/null 2>&1; then
                HAS_DOCKER_COMPOSE=true
                log_info "✓ Docker Compose (standalone) 可用"
            else
                log_warn "Docker Compose 未安装"
            fi
        else
            log_warn "Docker 已安装但守护进程未运行"
        fi
    else
        log_warn "Docker 未安装"
    fi
    
    # 检测 adl
    ensure_adl_detected || true
}

# ── 获取最新版本 ──
get_latest_version() {
    log_step "获取 Open WebUI 最新版本..." >&2
    
    local version
    version=$(curl -fsSL --connect-timeout 10 "$OPENWEBUI_RELEASE_API" 2>/dev/null | \
        grep -o '"tag_name": "[^"]*"' | head -1 | sed 's/"tag_name": "//;s/"$//')
    
    if [[ -z "$version" ]]; then
        version=$(latest_cached_version || true)
        if [[ -n "$version" ]]; then
            log_warn "无法获取最新版本，使用本地缓存版本: $version" >&2
        else
            version="$DEFAULT_FALLBACK_VERSION"
            log_warn "无法获取最新版本，使用 fallback: $version" >&2
        fi
    else
        log_info "最新版本: $version" >&2
    fi
    
    echo "$version"
}

# ── 下载文件 ──
download_file() {
    local url="$1"
    local output_dir="$2"
    local filename="$3"
    local output_path="${output_dir}/${filename}"
    
    # 检查是否已下载
    if [[ -f "$output_path" && -s "$output_path" ]]; then
        log_info "文件已存在，跳过下载: $output_path"
        return 0
    fi
    
    mkdir -p "$output_dir"
    
    # 优先使用 adl
    if [[ "$HAS_ADL" == true ]]; then
        log_info "使用 adl 下载..."
        if "$ADL_BIN" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        log_warn "adl 下载失败，尝试其他方式..."
    fi
    
    # 使用 curl
    log_info "使用 curl 下载..."
    if curl -fL --progress-bar --retry 3 --retry-delay 2 \
        -o "$output_path" "$url" 2>/dev/null; then
        return 0
    fi
    
    # 使用 wget
    if command -v wget >/dev/null 2>&1; then
        log_info "使用 wget 下载..."
        if wget --progress=bar:force -O "$output_path" "$url" 2>/dev/null; then
            return 0
        fi
    fi
    
    log_error "下载失败: $url"
    return 1
}

# ── Docker 方式安装 ──
install_docker() {
    log_step "使用 Docker 安装 Open WebUI..."
    
    local container_name="open-webui"
    local host_port
    host_port=$(current_host_port)
    local backend_port="${OPENWEBUI_BACKEND_PORT:-$DEFAULT_PORT}"
    
    # 检查容器是否已存在
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "Open WebUI 容器已存在"
        
        # 检查是否正在运行
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            log_info "✓ Open WebUI 已在运行"
            log_info "访问地址: http://localhost:${host_port}"
            return 0
        else
            log_info "启动已有容器..."
            docker start "$container_name"
            log_info "✓ Open WebUI 已启动"
            log_info "访问地址: http://localhost:${host_port}"
            return 0
        fi
    fi
    
    # 创建新容器
    log_info "创建 Open WebUI 容器..."
    
    # 检测 API 后端（如 DS4）
    local api_base_url="${OPENWEBUI_API_BASE_URL:-}"
    local api_key="${OPENWEBUI_API_KEY:-}"
    
    if [[ -z "$api_base_url" ]]; then
        local detected
        detected=$(detect_api_backend docker || true)
        if [[ -n "$detected" ]]; then
            api_base_url="${detected%%|*}"
            api_key="${detected#*|}"
            log_info "检测到 OpenAI-compatible 后端: $api_base_url"
        fi
    fi
    
    # 构建 docker run 命令
    local docker_args=(
        "-d"
        "--name" "$container_name"
        "--restart" "unless-stopped"
        "-p" "127.0.0.1:${host_port}:${backend_port}"
        "-v" "open-webui:/app/backend/data"
    )
    
    # 添加环境变量
    if [[ -n "$api_base_url" ]]; then
        docker_args+=("-e" "OPENAI_API_BASE_URLS=${api_base_url}")
    fi
    if [[ -n "$api_key" ]]; then
        docker_args+=("-e" "OPENAI_API_KEYS=${api_key}")
    fi
    
    # 添加其他常用环境变量
    docker_args+=("-e" "WEBUI_AUTH=${OPENWEBUI_AUTH:-True}")
    docker_args+=("-e" "ENABLE_SIGNUP=${OPENWEBUI_ENABLE_SIGNUP:-False}")
    docker_args+=("-e" "DEFAULT_USER_ROLE=${OPENWEBUI_DEFAULT_USER_ROLE:-pending}")
    docker_args+=("-e" "WEBUI_NAME=Open WebUI")
    
    # 运行容器
    docker run "${docker_args[@]}" ghcr.io/open-webui/open-webui:main
    
    log_info "✓ Open WebUI 容器已启动"
    log_info "访问地址: http://localhost:${host_port}"
    
    if [[ -n "$api_base_url" ]]; then
        log_info "已配置 API 后端: $api_base_url"
    else
        log_warn "未配置 API 后端，请在 Web UI 中手动设置"
    fi
}

# ── Docker Compose 方式安装 ──
install_docker_compose() {
    log_step "使用 Docker Compose 安装 Open WebUI..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    local compose_file="docker-compose.yml"
    local host_port
    host_port=$(current_host_port)
    
    # 检查是否已有配置
    if [[ -f "$compose_file" ]]; then
        log_info "检测到已有 Docker Compose 配置"
        
        # 检查容器状态
        if $HAS_DOCKER_COMPOSE; then
            if docker compose ps 2>/dev/null | grep -q "open-webui"; then
                log_info "Open WebUI 已在运行"
                log_info "访问地址: http://localhost:${host_port}"
                return 0
            fi
        fi
    fi
    
    # 创建 docker-compose.yml
    log_info "创建 Docker Compose 配置..."
    
    # 检测 API 后端
    local api_base_url="${OPENWEBUI_API_BASE_URL:-}"
    local api_key="${OPENWEBUI_API_KEY:-}"
    
    if [[ -z "$api_base_url" ]]; then
        local detected
        detected=$(detect_api_backend docker || true)
        if [[ -n "$detected" ]]; then
            api_base_url="${detected%%|*}"
            api_key="${detected#*|}"
            log_info "检测到 OpenAI-compatible 后端: $api_base_url"
        fi
    fi
    
    cat > "$compose_file" <<EOF
version: '3.8'

services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "127.0.0.1:${host_port}:${DEFAULT_PORT}"
    volumes:
      - open-webui:/app/backend/data
    environment:
      - WEBUI_AUTH=${OPENWEBUI_AUTH:-True}
      - ENABLE_SIGNUP=${OPENWEBUI_ENABLE_SIGNUP:-False}
      - DEFAULT_USER_ROLE=${OPENWEBUI_DEFAULT_USER_ROLE:-pending}
      - WEBUI_NAME=Open WebUI
EOF

    if [[ -n "$api_base_url" ]]; then
        echo "      - OPENAI_API_BASE_URLS=${api_base_url}" >> "$compose_file"
    fi
    if [[ -n "$api_key" ]]; then
        echo "      - OPENAI_API_KEYS=${api_key}" >> "$compose_file"
    fi

    cat >> "$compose_file" <<EOF
    restart: unless-stopped

volumes:
  open-webui:
EOF

    log_info "启动 Docker Compose..."
    if docker compose up -d; then
        log_info "✓ Open WebUI 已启动"
        log_info "访问地址: http://localhost:${host_port}"
    else
        log_error "Docker Compose 启动失败"
        return 1
    fi
}

# ── 主机方式安装 ──
install_host() {
    log_step "使用主机安装方式..."
    ensure_adl_detected || true
    
    log_warn "主机安装需要 Python 3.11+ 和 Node.js 18+"
    
    # 检查依赖
    local python_bin python_mm
    python_bin=$(find_python_for_openwebui || true)
    if [[ -z "$python_bin" ]]; then
        log_error "未找到 Python ${OPENWEBUI_PYTHON_VERSION:-$DEFAULT_PYTHON_VERSION}。可先安装 uv 后重试，或设置 OPENWEBUI_PYTHON=/path/to/python3.12。"
        exit 1
    fi
    python_mm=$(python_major_minor "$python_bin")
    log_info "Open WebUI 将使用 Python: $("${python_bin}" --version 2>&1) (${python_bin})"
    if [[ "$python_mm" != "3.11" && "$python_mm" != "3.12" ]]; then
        log_warn "当前选择的 Python 是 ${python_mm}；Open WebUI 主机安装更推荐 Python 3.11/3.12。"
    fi
    
    if ! load_node_env; then
        log_error "未找到 Node.js/npm。若已通过 fnm 安装，请确认 ~/.fnm/fnm 或 ~/.local/bin/fnm 存在，并重新运行。"
        exit 1
    fi
    check_node_version || exit 1
    
    # 获取版本
    local version
    version=$(get_latest_version)
    version=$(printf '%s\n' "$version" | tail -1 | sed 's/[^A-Za-z0-9._-]//g')
    version=${version#v}  # 去掉 v 前缀
    if [[ -z "$version" ]]; then
        version="${DEFAULT_FALLBACK_VERSION#v}"
        log_warn "版本解析失败，使用 fallback: v$version"
    fi
    
    local download_url="https://github.com/${OPENWEBUI_REPO}/archive/refs/tags/v${version}.tar.gz"
    local filename="open-webui-${version}.tar.gz"
    local source_dir="${DOWNLOAD_DIR}/open-webui-${version}"
    local host_port
    host_port=$(current_host_port)
    
    # 下载源码
    if [[ ! -d "$source_dir" ]]; then
        log_info "下载 Open WebUI 源码..."
        if ! download_file "$download_url" "$DOWNLOAD_DIR" "$filename"; then
            log_error "源码下载失败"
            exit 1
        fi

        log_info "解压源码..."
        rm -rf "$source_dir"
        tar -xzf "${DOWNLOAD_DIR}/${filename}" -C "$DOWNLOAD_DIR"
    else
        log_info "源码已存在: $source_dir"
    fi
    
    # 安装
    if [[ -d "$INSTALL_DIR" ]]; then
        log_info "安装目录已存在: $INSTALL_DIR"
        local installed_version=""
        [[ -f "$META_FILE" ]] && installed_version=$(grep '^version=' "$META_FILE" 2>/dev/null | cut -d= -f2- || true)
        if [[ -f "$BACKEND_DIR/requirements.txt" && "$installed_version" == "${version:-}" ]]; then
            log_info "检测到同版本源码目录，继续安装/修复依赖。"
        elif [[ -f "$BACKEND_DIR/requirements.txt" && -z "$installed_version" && "${OPENWEBUI_REPAIR_EXISTING:-0}" == "1" ]]; then
            log_warn "检测到旧安装目录但缺少版本元数据，按 OPENWEBUI_REPAIR_EXISTING=1 继续修复。"
        elif [[ -f "$BACKEND_DIR/requirements.txt" && "${OPENWEBUI_FORCE_REINSTALL:-0}" != "1" ]]; then
            if [[ -n "$installed_version" ]]; then
                log_info "检测到已安装版本 ${installed_version}，目标版本 ${version:-unknown}，将备份旧目录并升级。"
            else
                log_info "检测到旧安装目录但缺少版本元数据，将备份旧目录并安装目标版本 ${version:-unknown}。"
            fi
            local backup_dir="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
            mv "$INSTALL_DIR" "$backup_dir"
            log_info "旧目录已备份: $backup_dir"
        else
            rm -rf "$INSTALL_DIR"
        fi
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mv "$source_dir" "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"
    
    # 安装后端依赖
    log_step "安装后端依赖..."
    cd "$BACKEND_DIR"
    local backend_hash cached_backend_hash backend_ready
    backend_hash=$(backend_deps_hash)
    cached_backend_hash=$(get_cached_hash "backend_deps")
    backend_ready=false
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        local venv_mm
        venv_mm=$(python_major_minor "$VENV_DIR/bin/python" 2>/dev/null || echo "")
        if [[ "$venv_mm" != "$python_mm" ]]; then
            log_warn "已有虚拟环境 Python 版本为 ${venv_mm}，目标为 ${python_mm}，删除后重建。"
            rm -rf "$VENV_DIR"
        elif [[ "$cached_backend_hash" == "$backend_hash" ]]; then
            backend_ready=true
        elif [[ -z "$cached_backend_hash" && "${OPENWEBUI_FORCE_DEPS:-0}" != "1" ]]; then
            log_info "检测到已有后端虚拟环境，补写依赖摘要缓存。"
            set_cached_hash "backend_deps" "$backend_hash"
            backend_ready=true
        fi
    fi
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log_info "创建 Python 虚拟环境: $VENV_DIR"
        "$python_bin" -m venv "$VENV_DIR"
    fi
    if [[ "$backend_ready" == true && "${OPENWEBUI_FORCE_DEPS:-0}" != "1" ]]; then
        log_info "后端依赖配置未变化，跳过安装。"
    else
        local pip_index="${OPENWEBUI_PIP_INDEX_URL:-${PIP_INDEX_URL:-${UV_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}}}"
        log_info "使用 PyPI 镜像: $pip_index"
        if command -v uv >/dev/null 2>&1; then
            uv pip install --python "$VENV_DIR/bin/python" --upgrade pip setuptools wheel -i "$pip_index"
            uv pip install --python "$VENV_DIR/bin/python" -r requirements.txt -U --only-binary=:all: -i "$pip_index" || \
                uv pip install --python "$VENV_DIR/bin/python" -r requirements.txt -U -i "$pip_index"
        else
            "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel --prefer-binary --retries 5 --timeout 60 -i "$pip_index"
            "$VENV_DIR/bin/python" -m pip install -r requirements.txt -U --prefer-binary --retries 5 --timeout 60 -i "$pip_index"
        fi
        set_cached_hash "backend_deps" "$backend_hash"
    fi
    
    # 安装前端依赖
    log_step "安装前端依赖..."
    cd "$INSTALL_DIR"
    local frontend_hash cached_frontend_hash frontend_ready
    frontend_hash=$(frontend_deps_hash)
    cached_frontend_hash=$(get_cached_hash "frontend_deps")
    frontend_ready=false
    if [[ -d "$INSTALL_DIR/node_modules" && "$cached_frontend_hash" == "$frontend_hash" ]]; then
        frontend_ready=true
    elif [[ -d "$INSTALL_DIR/node_modules" && -z "$cached_frontend_hash" && "${OPENWEBUI_FORCE_DEPS:-0}" != "1" ]]; then
        log_info "检测到已有前端依赖目录，补写依赖摘要缓存。"
        set_cached_hash "frontend_deps" "$frontend_hash"
        frontend_ready=true
    fi
    if [[ "$frontend_ready" == true && "${OPENWEBUI_FORCE_DEPS:-0}" != "1" ]]; then
        log_info "前端依赖配置未变化，跳过 npm install。"
    else
        npm install
        set_cached_hash "frontend_deps" "$frontend_hash"
    fi
    if [[ -d "$INSTALL_DIR/build" && "$frontend_ready" == true && "${OPENWEBUI_FORCE_BUILD:-0}" != "1" ]]; then
        log_info "前端构建产物已存在且依赖配置未变化，跳过 npm run build。"
    else
        npm run build
    fi
    
    # 创建自动配置和启动脚本
    write_openwebui_env_config "$host_port"
    rm -f "$INSTALL_DIR/start.sh"
    ensure_host_start_script

    {
        echo "version=$version"
        echo "install_mode=host"
        echo "python=$python_bin"
        echo "node=$(command -v node 2>/dev/null || true)"
        echo "port=$host_port"
        echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$META_FILE"
    
    log_info "✓ Open WebUI 主机安装完成"
    log_info "启动命令: $INSTALL_DIR/start.sh"
    start_host_service || true
}

# ── 停止服务 ──
stop_service() {
    log_step "停止 Open WebUI..."
    
    # 尝试 Docker
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
        docker stop open-webui
        log_info "Docker 容器已停止"
    fi
    
    # 尝试 Docker Compose
    if command -v docker >/dev/null 2>&1 && [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        cd "$INSTALL_DIR"
        docker compose down 2>/dev/null || true
        log_info "Docker Compose 服务已停止"
    fi
    
    # 尝试主机进程
    if [[ -f "$HOST_PID_FILE" ]]; then
        kill "$(cat "$HOST_PID_FILE")" 2>/dev/null || true
        rm -f "$HOST_PID_FILE"
    fi
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
    done < <(openwebui_pids)
    sleep 1
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -9 "$pid" 2>/dev/null || true
    done < <(openwebui_pids)
    pkill -f "uvicorn open_webui.main:app" 2>/dev/null || true
    pkill -f "open-webui" 2>/dev/null || true
    
    log_info "Open WebUI 已停止"
}

# ── 卸载 ──
uninstall() {
    log_warn "准备卸载 Open WebUI..."
    
    if is_macos; then
        disable_autostart || true
    fi
    stop_service
    
    # 删除容器和卷
    if command -v docker >/dev/null 2>&1; then
        docker rm -f open-webui 2>/dev/null || true
        docker volume rm open-webui 2>/dev/null || true
    fi
    
    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log_info "已删除 $INSTALL_DIR"
    fi
    
    # 删除下载文件
    rm -f "${DOWNLOAD_DIR}"/open-webui-*.tar.gz
    
    log_info "Open WebUI 已卸载"
}

# ── 状态检查 ──
status() {
    log_step "检查 Open WebUI 状态..."
    
    # Docker 状态
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
        log_info "✓ Docker 容器运行中"
        docker ps --filter "name=open-webui" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        log_info "Docker 容器未运行"
    fi
    
    # 主机安装状态
    if [[ -d "$INSTALL_DIR" ]]; then
        log_info "主机安装目录: $INSTALL_DIR"
        if [[ -f "$META_FILE" ]]; then
            log_info "安装元数据:"
            sed 's/^/  /' "$META_FILE"
        fi
        if [[ -f "$INSTALL_DIR/start.sh" ]]; then
            log_info "启动脚本: $INSTALL_DIR/start.sh"
        fi
        if openwebui_has_users "${OPENWEBUI_DATA_DIR:-${BACKEND_DIR}/data}"; then
            openwebui_print_user_login_hint "${OPENWEBUI_DATA_DIR:-${BACKEND_DIR}/data}"
        fi
        if [[ -f "$ENV_FILE" ]]; then
            log_info "自动配置文件: $ENV_FILE"
            local configured_backend configured_urls
            configured_backend=$(env_file_value OPENWEBUI_DETECTED_BACKEND || true)
            configured_urls=$(env_file_value OPENAI_API_BASE_URLS || true)
            if [[ -n "$configured_urls" ]]; then
                log_info "已配置模型后端: ${configured_backend:-unknown} -> $configured_urls"
            fi
        fi
        local status_port
        status_port=$(current_host_port)
        if host_service_ready "$status_port"; then
            log_info "✓ 主机服务可访问: http://localhost:${status_port}"
            print_host_access_urls "$status_port"
        else
            log_info "主机服务未检测到运行"
        fi
    fi

    local pid ports cmd found_openwebui=false
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        found_openwebui=true
        ports=$(pid_listen_ports "$pid" | tr '\n' ',' | sed 's/,$//')
        cmd=$(process_cmd "$pid")
        log_info "Open WebUI 进程: PID=$pid PORT=${ports:-unknown} CMD=$cmd"
    done < <(openwebui_pids)
    [[ "$found_openwebui" == false ]] && log_info "未检测到 Open WebUI 主机进程"

    local status_ds4_api
    status_ds4_api=$(ds4_local_api_base || true)
    if [[ -n "$status_ds4_api" ]]; then
        log_info "✓ DS4/OpenAI-compatible 后端可用: $status_ds4_api"
    elif ds4_installed && ds4_model_ready; then
        if ds4_server_running; then
            log_warn "检测到 ds4-server 进程，但 API 暂不可用。候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
        else
            log_info "DS4 已安装且模型就绪，但 ds4-server 未运行。可执行: OPENWEBUI_AUTOSTART_DS4=1 $0 start"
        fi
    fi
    
    # 端口检查
    if lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_info "✓ 端口 3000 正在监听"
    fi
    if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_info "✓ 端口 8080 正在监听"
    fi
    if lsof -Pi :8000 -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_info "✓ 端口 8000 正在监听"
    fi

    autostart_status
}

# ── 主函数 ──
main() {
    local action="${1:-install}"
    local admin_email="${2:-}"
    
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  Open WebUI 安装/管理工具${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    case "$action" in
        -i|--install) action="install" ;;
        -d|--docker) action="docker" ;;
        -c|--compose) action="compose" ;;
        -H|--host) action="host" ;;
        -s|--start) action="start" ;;
        -S|--stop) action="stop" ;;
        -u|--uninstall) action="uninstall" ;;
        -t|--status) action="status" ;;
        -a|--autostart-on) action="autostart-on" ;;
        -A|--autostart-off) action="autostart-off" ;;
        -T|--autostart-status) action="autostart-status" ;;
        -r|--reset-admin) action="reset-admin" ;;
    esac
    
    case "$action" in
        install|"")
            detect_platform
            detect_docker
            
            if [[ "$HAS_DOCKER" == true ]]; then
                if [[ "$HAS_DOCKER_COMPOSE" == true ]]; then
                    log_info "优先使用 Docker Compose 安装"
                    install_docker_compose
                else
                    log_info "使用 Docker 安装"
                    install_docker
                fi
            else
                log_warn "Docker 不可用，使用主机安装方式"
                install_host
            fi
            maybe_enable_autostart_after_default_install
            ;;
        docker)
            detect_platform
            detect_docker
            if [[ "$HAS_DOCKER" != true ]]; then
                log_error "Docker 未安装或未运行"
                exit 1
            fi
            install_docker
            ;;
        compose)
            detect_platform
            detect_docker
            if [[ "$HAS_DOCKER_COMPOSE" != true ]]; then
                log_error "Docker Compose 未安装"
                exit 1
            fi
            install_docker_compose
            ;;
        host)
            detect_platform
            install_host
            ;;
        stop)
            stop_service
            ;;
        uninstall)
            uninstall
            ;;
        status)
            status
            ;;
        start)
            start_host_service
            ;;
        autostart-on|enable-autostart)
            enable_autostart
            ;;
        autostart-off|disable-autostart)
            disable_autostart
            ;;
        autostart-status)
            autostart_status
            ;;
        admin|reset-admin)
            reset_admin_password "$admin_email"
            ;;
        --help|-h|help)
            cat <<EOF
用法: $0 [命令] [参数]

命令:
  install, -i             自动检测并安装（默认；macOS 会询问是否创建自启动，默认创建）
  docker, -d              强制使用 Docker 安装
  compose, -c             强制使用 Docker Compose 安装
  host, -H                强制使用主机安装
  start, -s               启动主机安装的 Open WebUI
  stop, -S                停止服务
  uninstall, -u           卸载 Open WebUI
  status, -t              查看状态
  autostart-on, -a        启用 macOS 开机/登录自启动（用户级 LaunchAgent）
  autostart-off, -A       禁用 macOS 开机/登录自启动
  autostart-status, -T    查看 macOS 自启动状态
  reset-admin, -r [邮箱]  重置/创建管理员账号密码
  help, -h                显示帮助

环境变量:
  OPENWEBUI_PORT            Web UI 端口 (默认: 3000)
  OPENWEBUI_BACKEND_PORT    后端端口 (默认: 8080)
  OPENWEBUI_API_BASE_URL    API 后端地址
  OPENWEBUI_API_KEY         API Key
  OPENWEBUI_AUTH            是否启用认证 (默认: True)
  OPENWEBUI_NAME            Web UI 名称 (默认: Open WebUI)
  OPENWEBUI_URL             Web UI 外部访问地址 (默认: http://localhost:端口)
  OPENWEBUI_HOST            主机安装监听地址 (默认: 0.0.0.0)
  OPENWEBUI_DATA_DIR        数据目录 (默认: ~/open-webui/backend/data)
  OPENWEBUI_SECRET_KEY      会话/加密密钥，未设置时自动生成并持久化
  OPENWEBUI_ADMIN_EMAIL     首个管理员邮箱 (默认新库: admin@localhost)
  OPENWEBUI_ADMIN_PASSWORD  首个管理员密码，未设置且新库时自动生成
  OPENWEBUI_ENABLE_SIGNUP   是否开放注册 (默认: False)
  OPENWEBUI_DEFAULT_USER_ROLE 新注册用户角色 (默认: pending)
  OPENWEBUI_ENV_FILE        启动时加载的 env 文件 (默认: ~/open-webui/.open-webui.env)
  OPENWEBUI_LAUNCH_AGENT_LABEL macOS LaunchAgent Label (默认: com.sky.open-webui)
  OPENWEBUI_LAUNCH_AGENT_PLIST macOS LaunchAgent plist 路径
  OPENWEBUI_LAUNCH_KEEPALIVE 是否让 launchd 在异常退出后拉起 (默认: 0)
  OPENWEBUI_PYTHON_VERSION  主机安装 Python 版本 (默认: 3.12)
  OPENWEBUI_PYTHON          指定 Python 解释器路径
  OPENWEBUI_FORCE_REINSTALL 强制替换已有源码目录
  OPENWEBUI_FORCE_DEPS      强制重新安装前后端依赖
  OPENWEBUI_FORCE_BUILD     强制重新构建前端
  OPENWEBUI_REPAIR_EXISTING 修复无版本元数据的旧目录，不替换源码
  OPENWEBUI_PIP_INDEX_URL   Python 包镜像源
  OPENWEBUI_START_TIMEOUT   启动健康检查等待秒数 (默认: 180)
  OPENWEBUI_FAST_STARTUP    跳过启动期 Hugging Face 下载探测 (默认: 1)
  OPENWEBUI_SINGLE_INSTANCE 自动清理其他 Open WebUI 历史进程 (默认: 1)
  OPENWEBUI_AUTOSTART_DS4   未检测到 DS4 API 时自动启动 ds4-server (默认: 0)
  OPENWEBUI_DS4_PORT        指定 DS4 API 端口；未设置时自动探测，默认候选 8000/8080
  DS4_DIR                   DS4 安装目录 (默认: ~/ds4)
  ADL_PATH                  adl 路径

示例:
  $0                         # 自动安装；macOS 询问是否创建自启动，默认 Y
  $0 -H                      # 主机安装/修复
  $0 -d                      # 使用 Docker
  OPENWEBUI_PORT=8080 $0     # 指定端口
  OPENWEBUI_FORCE_REINSTALL=1 $0 -H
  $0 -a                      # macOS 登录后自动启动
  $0 -T                      # 查看自启动状态
  $0 reset-admin admin@localhost

EOF
            ;;
        *)
            log_error "未知命令: $action"
            echo "运行 '$0 help' 查看用法"
            exit 1
            ;;
    esac
}

main "$@"

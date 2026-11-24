#!/usr/bin/env bash
# DS4 (DeepSeek V4 Flash) 安装/管理脚本
# 针对 macOS Metal 和 128GB RAM 优化
# 库地址: https://github.com/antirez/ds4

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
log_success() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local timeout="${3:-10}"
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

# ── 变量 ──
INSTALL_DIR="${HOME}/ds4"
REPO_URL="https://github.com/antirez/ds4.git"
ARCHIVE_URL="https://github.com/antirez/ds4/archive/refs/heads/main.zip"
DOWNLOAD_DIR="${HOME}/Downloads"
ARCHIVE_FILE="${DOWNLOAD_DIR}/ds4-main.zip"
DEFAULT_MODEL_TYPE="q2-imatrix"
DEFAULT_SERVER_LOG="${INSTALL_DIR}/ds4-server.log"
DEFAULT_MODEL_FILE="${INSTALL_DIR}/ds4flash.gguf"
DEFAULT_DS4_PORT="8000"
DEFAULT_DS4_HOST="0.0.0.0"
Q2_IMATRIX_FILE="DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf"
Q2_IMATRIX_URL="https://huggingface.co/antirez/deepseek-v4-gguf/resolve/main/${Q2_IMATRIX_FILE}"
Q2_IMATRIX_MIN_COMPLETE_GB=78
Q4_IMATRIX_FILE="DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf"
Q4_IMATRIX_URL="https://huggingface.co/antirez/deepseek-v4-gguf/resolve/main/${Q4_IMATRIX_FILE}"
Q4_IMATRIX_MIN_COMPLETE_GB=150
# DeepSeek-V4-Flash 模型参数
DS4_MODEL_NAME="DeepSeek-V4-Flash"
DS4_TOTAL_PARAMS="671B"
DS4_ACTIVE_PARAMS="37B"
DS4_CONTEXT_WINDOW=65536  # 模型能力 64K tokens；服务端实际值以 --ctx 或 /v1/models 为准
DS4_DEFAULT_SERVER_CONTEXT_WINDOW="${DS4_DEFAULT_SERVER_CONTEXT_WINDOW:-32768}"
MIN_EXTERNAL_FREE_GB="${DS4_MIN_EXTERNAL_FREE_GB:-150}"

ds4_command_basename() {
    local cmd="$1"
    local first="${cmd%% *}"
    first="${first##*/}"
    printf '%s\n' "$first"
}

find_ds4_server_pid() {
    local pid cmd base
    while read -r pid cmd; do
        [[ -n "${pid:-}" ]] || continue
        [[ "$pid" == "$$" ]] && continue
        [[ "$cmd" == *"install-ds4.sh"* ]] && continue
        base=$(ds4_command_basename "$cmd")
        [[ "$base" == "ds4-server" || "$cmd" == *"$INSTALL_DIR/ds4-server"* ]] || continue
        echo "$pid"
        return 0
    done < <(ps -axo pid=,command= 2>/dev/null || true)
}

find_ds4_conflict_pid() {
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
        [[ "$cmd" == *"$INSTALL_DIR/ds4 "* || "$cmd" == *"$INSTALL_DIR/ds4 -" || "$cmd" == *" ./ds4 "* || "$cmd" == *" ./ds4 -" ]] || continue
        echo "$pid"
        return 0
    done < <(ps -axo pid=,command= 2>/dev/null || true)
}

handle_ds4_conflict_pid() {
    local conflict_pid="$1"
    [[ -n "$conflict_pid" ]] || return 0

    log_warn "检测到 DS4 CLI/其他进程正在运行 (PID: $conflict_pid)，ds4-server 无法同时启动。"
    if [[ "${DS4_AUTO_STOP_CONFLICT:-0}" == "1" ]]; then
        log_info "DS4_AUTO_STOP_CONFLICT=1，自动结束该 DS4 进程。"
        kill "$conflict_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$conflict_pid" 2>/dev/null || true
        return 0
    fi

    if ask_yes_no "是否结束该 DS4 进程并启动 ds4-server" "y" 10; then
        kill "$conflict_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$conflict_pid" 2>/dev/null || true
        return 0
    fi

    log_error "已取消启动 ds4-server。可稍后执行: $0 stop && $0 server-bg"
    return 1
}

start_ds4_server_once() {
    cd "$INSTALL_DIR"
    local host="${DS4_HOST:-$DEFAULT_DS4_HOST}"
    local port="${DS4_PORT:-$DEFAULT_DS4_PORT}"
    local args=("--host" "$host" "--port" "$port")
    if [[ -n "${DS4_SERVER_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        args+=(${DS4_SERVER_ARGS})
    fi
    log_step "后台启动 ds4-server (${host}:${port})..."
    : > "$DEFAULT_SERVER_LOG"
    rm -f "$INSTALL_DIR/ds4-server.pid"
    nohup ./ds4-server "${args[@]}" > "$DEFAULT_SERVER_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$INSTALL_DIR/ds4-server.pid"

    # 等待启动：进程存在 + 日志出现监听标记，最多 60 秒
    local max_wait="${DS4_SERVER_START_TIMEOUT:-60}"
    local waited=0
    while (( waited < max_wait )); do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            log_error "ds4-server 在 ${waited}s 内退出，请查看日志: $DEFAULT_SERVER_LOG"
            rm -f "$INSTALL_DIR/ds4-server.pid"
            return 1
        fi
        if grep -qE "listening on http|server started|listen.*:[0-9]+" "$DEFAULT_SERVER_LOG" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # 超时但进程还在：可能日志格式不同，最后探活
    kill -0 "$pid" >/dev/null 2>&1
}

ds4_listen_port_from_log() {
    [[ -f "$DEFAULT_SERVER_LOG" ]] || return 1
    sed -nE 's/.*listening on http:\/\/[^:]+:([0-9]+).*/\1/p' "$DEFAULT_SERVER_LOG" | tail -1
}

ds4_candidate_ports() {
    local seen=" " group port
    for group in ${DS4_DISCOVERY_PORTS:-} "${DS4_PORT:-}" "$(ds4_listen_port_from_log || true)" "$DEFAULT_DS4_PORT"; do
        group="${group//,/ }"
        for port in $group; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            [[ "$seen" == *" $port "* ]] && continue
            printf '%s\n' "$port"
            seen="${seen}${port} "
        done
    done
}

ds4_discovery_ports() {
    # 与 ds4_candidate_ports 等价，保留作为兼容别名。
    ds4_candidate_ports "$@"
}

is_valid_tcp_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

first_ds4_discovery_port() {
    local group port
    for group in ${DS4_DISCOVERY_PORTS:-} "${DS4_PORT:-}" "$DEFAULT_DS4_PORT"; do
        group="${group//,/ }"
        for port in $group; do
            if is_valid_tcp_port "$port"; then
                printf '%s\n' "$port"
                return 0
            fi
        done
    done
    printf '%s\n' "$DEFAULT_DS4_PORT"
}

ask_ds4_discovery_port() {
    local default_port port
    default_port=$(first_ds4_discovery_port)

    if [[ -t 0 ]]; then
        printf "DS4 服务端口 [%s]: " "$default_port" > /dev/tty
        read -r -t "${DS4_DISCOVERY_PORT_PROMPT_TIMEOUT:-15}" port || {
            printf '\n' > /dev/tty
            port="$default_port"
        }
        port="${port:-$default_port}"
    else
        port="$default_port"
    fi

    if ! is_valid_tcp_port "$port"; then
        port="$default_port"
    fi

    printf '%s\n' "$port"
}

normalize_ds4_api_base() {
    local value="$1"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$value" ]] || return 1
    [[ "$value" == http://* || "$value" == https://* ]] || value="http://$value"
    value="${value%/}"
    [[ "$value" == */v1 ]] || value="${value}/v1"
    printf '%s\n' "$value"
}

ds4_api_base_host() {
    printf '%s\n' "$1" | sed -E 's#^https?://\[?([^]/:]+)\]?.*#\1#'
}

ds4_is_loopback_api_base() {
    local host
    host=$(ds4_api_base_host "$1")
    case "$host" in
        localhost|127.*|0.0.0.0|::1) return 0 ;;
    esac
    return 1
}

probe_ds4_api() {
    local api_url="$1"
    if curl -fsS --noproxy "${DS4_CURL_NOPROXY:-*}" --connect-timeout 2 --max-time 4 "${api_url}/models" >/dev/null 2>&1; then
        return 0
    fi
    curl -fsS --noproxy "${DS4_CURL_NOPROXY:-*}" --connect-timeout 2 --max-time 5 -X POST "${api_url}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer sk-ds4-local-$(hostname -s)" \
        -d '{"model":"ds4","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' >/dev/null 2>&1
}

probe_ds4_api_discovery() {
    local api_url="$1" payload
    payload=$(curl -fsS \
        --noproxy "${DS4_CURL_NOPROXY:-*}" \
        --connect-timeout "${DS4_DISCOVERY_CONNECT_TIMEOUT:-0.8}" \
        --max-time "${DS4_DISCOVERY_MAX_TIME:-2}" \
        "${api_url}/models" 2>/dev/null) || return 1

    if [[ "$payload" == *'"ds4"'* || "$payload" == *"DeepSeek-V4-Flash"* || "$payload" == *"deepseek-v4"* || "$payload" == *'"data"'* || "$payload" == *'"object"'* ]]; then
        return 0
    fi

    [[ "${DS4_DISCOVERY_STRICT:-1}" == "0" ]]
}

ds4_local_api_base() {
    local port
    while read -r port; do
        [[ -n "$port" ]] || continue
        if probe_ds4_api "http://localhost:${port}/v1"; then
            printf 'http://localhost:%s/v1\n' "$port"
            return 0
        fi
    done < <(ds4_candidate_ports)
    return 1
}

ds4_lan_api_base_for_local_server() {
    local local_api="$1" port lan_ip
    port=$(printf '%s\n' "$local_api" | sed -nE 's#^https?://[^:/]+:([0-9]+)/v1$#\1#p')
    [[ "$port" =~ ^[0-9]+$ ]] || port="${DS4_PORT:-$DEFAULT_DS4_PORT}"
    lan_ip=$(ds4_primary_lan_ip || true)
    [[ -n "$lan_ip" ]] || return 1
    printf 'http://%s:%s/v1\n' "$lan_ip" "$port"
}

ds4_lan_api_ready_for_local_server() {
    local local_api="$1" lan_api
    lan_api=$(ds4_lan_api_base_for_local_server "$local_api" || true)
    [[ -n "$lan_api" ]] || return 1
    probe_ds4_api_discovery "$lan_api"
}

ds4_preferred_api_base() {
    local live port
    live=$(ds4_local_api_base || true)
    if [[ -n "$live" ]]; then
        printf '%s\n' "$live"
        return 0
    fi
    port=$(ds4_listen_port_from_log || true)
    [[ "$port" =~ ^[0-9]+$ ]] || port=$(first_ds4_discovery_port)
    printf 'http://localhost:%s/v1\n' "$port"
}

ds4_configured_remote_api_base() {
    local value group host port candidate fallback
    for value in "${DS4_REMOTE_API_BASE:-}" "${DS4_REMOTE_URL:-}"; do
        [[ -n "$value" ]] || continue
        normalize_ds4_api_base "$value" && return 0
    done

    for group in "${DS4_REMOTE_HOST:-}" ${DS4_REMOTE_HOSTS:-}; do
        group="${group//,/ }"
        for host in $group; do
            [[ -n "$host" ]] || continue
            if [[ "$host" == http://* || "$host" == https://* ]]; then
                normalize_ds4_api_base "$host" && return 0
            fi
            for port in $(ds4_discovery_ports); do
                candidate=$(normalize_ds4_api_base "${host}:${port}") || continue
                [[ -n "${fallback:-}" ]] || fallback="$candidate"
                if probe_ds4_api_discovery "$candidate"; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
            [[ -n "${fallback:-}" ]] && printf '%s\n' "$fallback" && return 0
        done
    done

    return 1
}

ds4_explicit_api_candidates() {
    local value group host port
    for value in "${DS4_REMOTE_API_BASE:-}" "${DS4_REMOTE_URL:-}" "${DS4_API_BASE_URL:-}" "${OPENAI_API_BASE_URL:-}" "${OPENAI_API_BASE:-}"; do
        [[ -n "$value" ]] || continue
        normalize_ds4_api_base "$value" || true
    done

    for group in ${DS4_REMOTE_HOSTS:-} ${DS4_DISCOVERY_HOSTS:-} "${DS4_REMOTE_HOST:-}"; do
        group="${group//,/ }"
        for host in $group; do
            [[ -n "$host" ]] || continue
            if [[ "$host" == http://* || "$host" == https://* ]]; then
                normalize_ds4_api_base "$host" || true
                continue
            fi
            for port in $(ds4_discovery_ports); do
                normalize_ds4_api_base "${host}:${port}" || true
            done
        done
    done
}

ds4_lan_ipv4_addresses() {
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet / {print $2}' | grep -Ev '^(127\.|0\.0\.0\.0$)' || true
    fi
}

ds4_primary_lan_ip() {
    local default_if ip
    default_if=$(ds4_default_route_interface || true)
    if [[ -n "$default_if" ]]; then
        ip=$(ds4_interface_cidrs "$default_if" | sed -nE 's#/.*##p' | head -1)
        [[ -n "$ip" ]] && printf '%s\n' "$ip" && return 0
    fi
    ds4_discovery_cidrs | sed -nE 's#/.*##p' | head -1
}

ds4_default_route_interface() {
    if command -v ip >/dev/null 2>&1; then
        ip route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
        return 0
    fi

    if command -v route >/dev/null 2>&1; then
        route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
    fi
}

prefix_from_netmask() {
    local mask="$1" bits=0 octet
    if [[ "$mask" == 0x* ]]; then
        mask=$(printf '%d.%d.%d.%d\n' \
            $(( (mask >> 24) & 255 )) \
            $(( (mask >> 16) & 255 )) \
            $(( (mask >> 8) & 255 )) \
            $(( mask & 255 )))
    fi
    [[ "$mask" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$mask"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        case "$octet" in
            255) bits=$((bits + 8)) ;;
            254) bits=$((bits + 7)) ;;
            252) bits=$((bits + 6)) ;;
            248) bits=$((bits + 5)) ;;
            240) bits=$((bits + 4)) ;;
            224) bits=$((bits + 3)) ;;
            192) bits=$((bits + 2)) ;;
            128) bits=$((bits + 1)) ;;
            0) ;;
            *) return 1 ;;
        esac
    done
    printf '%s\n' "$bits"
}

ds4_interface_cidrs() {
    local want_if="$1"
    [[ -n "$want_if" ]] || return 1

    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show dev "$want_if" scope global 2>/dev/null | awk '{print $4}'
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$want_if" 2>/dev/null | awk '
            /inet / && $2 !~ /^127\./ && $2 != "0.0.0.0" {
                ip=$2; mask="";
                for (i=1; i<=NF; i++) {
                    if ($i == "netmask" && (i+1) <= NF) {
                        mask=$(i+1);
                    }
                }
                if (mask != "") {
                    print ip "/" mask;
                }
            }
        ' | while IFS=/ read -r ip mask; do
            prefix=$(prefix_from_netmask "$mask" || true)
            [[ -n "${prefix:-}" ]] && printf '%s/%s\n' "$ip" "$prefix"
        done
    fi
}

ds4_lan_cidrs() {
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}'
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '
            /inet / && $2 !~ /^127\./ && $2 != "0.0.0.0" {
                ip=$2; mask="";
                for (i=1; i<=NF; i++) {
                    if ($i == "netmask" && (i+1) <= NF) {
                        mask=$(i+1);
                    }
                }
                if (mask != "") {
                    print ip "/" mask;
                }
            }
        ' | while IFS=/ read -r ip mask; do
            prefix=$(prefix_from_netmask "$mask" || true)
            [[ -n "${prefix:-}" ]] && printf '%s/%s\n' "$ip" "$prefix"
        done
    fi
}

ds4_discovery_cidrs() {
    local default_if cidr

    if [[ "${DS4_DISCOVERY_ALL_NETWORKS:-0}" == "1" ]]; then
        ds4_lan_cidrs
        return 0
    fi

    default_if=$(ds4_default_route_interface || true)
    if [[ -n "$default_if" ]]; then
        while read -r cidr; do
            [[ -n "$cidr" ]] || continue
            printf '%s\n' "$cidr"
        done < <(ds4_interface_cidrs "$default_if")
        return 0
    fi

    ds4_lan_cidrs | grep -Ev '^(127\.|169\.254\.|10\.211\.55\.|192\.168\.64\.)' || true
}

ds4_lan_cidrs_unique() {
    local seen=" " cidr
    while read -r cidr; do
        [[ -n "$cidr" ]] || continue
        [[ "$seen" == *" $cidr "* ]] && continue
        printf '%s\n' "$cidr"
        seen="${seen}${cidr} "
    done < <(ds4_discovery_cidrs)
}

join_lines_with_comma() {
    local item output=""
    while read -r item; do
        [[ -n "$item" ]] || continue
        if [[ -n "$output" ]]; then
            output="${output}, ${item}"
        else
            output="$item"
        fi
    done
    printf '%s\n' "$output"
}

ds4_lan_prefixes() {
    local seen=" " ip prefix
    while read -r ip; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        prefix="${ip%.*}"
        [[ "$seen" == *" $prefix "* ]] && continue
        printf '%s\n' "$prefix"
        seen="${seen}${prefix} "
    done < <(ds4_discovery_cidrs | sed -E 's#/.*##')
}

cidr_hosts() {
    local cidr="$1" ip prefix o1 o2 o3 o4 base start end n max_hosts
    [[ "$cidr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]] || return 1
    ip="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [[ "$prefix" -ge 24 && "$prefix" -le 30 ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    base=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    start=$(( (base >> (32 - prefix)) << (32 - prefix) ))
    end=$(( start + (1 << (32 - prefix)) - 1 ))
    max_hosts="${DS4_DISCOVERY_MAX_HOSTS:-1024}"
    [[ "$max_hosts" =~ ^[0-9]+$ && "$max_hosts" -gt 0 ]] || max_hosts=1024
    if (( end - start - 1 > max_hosts )); then
        return 1
    fi
    for ((n=start + 1; n<end; n++)); do
        printf '%d.%d.%d.%d\n' \
            $(( (n >> 24) & 255 )) \
            $(( (n >> 16) & 255 )) \
            $(( (n >> 8) & 255 )) \
            $(( n & 255 ))
    done
}

ds4_neighbor_hosts() {
    if command -v ip >/dev/null 2>&1; then
        ip neigh show 2>/dev/null | awk '/lladdr/ {print $1}'
    fi
    if command -v arp >/dev/null 2>&1; then
        arp -an 2>/dev/null | sed -nE 's/.*\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\).*/\1/p'
    fi
}

probe_ds4_hosts_for_api() {
    local host port api tmp max_jobs pid found
    tmp="${TMPDIR:-/tmp}/ds4-discovery.$$.$RANDOM"
    : > "$tmp"
    max_jobs="${DS4_DISCOVERY_JOBS:-64}"
    [[ "$max_jobs" =~ ^[0-9]+$ && "$max_jobs" -gt 0 ]] || max_jobs=64

    local pids=()
    while read -r host; do
        [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        for port in $(ds4_discovery_ports); do
            api="http://${host}:${port}/v1"
            (
                if probe_ds4_api_discovery "$api"; then
                    printf '%s\n' "$api" >> "$tmp"
                fi
            ) &
            pids+=("$!")
            if [[ "${#pids[@]}" -ge "$max_jobs" ]]; then
                for pid in "${pids[@]}"; do
                    wait "$pid" 2>/dev/null || true
                done
                pids=()
                found=$(sed -n '1p' "$tmp")
                if [[ -n "$found" ]]; then
                    rm -f "$tmp"
                    printf '%s\n' "$found"
                    return 0
                fi
            fi
        done
    done

    if [[ "${#pids[@]}" -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
    found=$(sed -n '1p' "$tmp")
    rm -f "$tmp"
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

ds4_lan_api_base() {
    local candidate cidr prefix host local_ips neighbor_file scan_file

    while read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if probe_ds4_api_discovery "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(ds4_explicit_api_candidates)

    [[ "${DS4_DISCOVERY_SCAN:-1}" != "0" ]] || return 1

    neighbor_file="${TMPDIR:-/tmp}/ds4-neighbors.$$.$RANDOM"
    scan_file="${TMPDIR:-/tmp}/ds4-scan-hosts.$$.$RANDOM"
    ds4_neighbor_hosts | sort -u > "$neighbor_file"
    if [[ -s "$neighbor_file" ]]; then
        if candidate=$(probe_ds4_hosts_for_api < "$neighbor_file"); then
            rm -f "$neighbor_file" "$scan_file"
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    local_ips=" $(ds4_discovery_cidrs | sed -E 's#/.*##' | tr '\n' ' ') "
    : > "$scan_file"
    while read -r cidr; do
        [[ -n "$cidr" ]] || continue
        cidr_hosts "$cidr" >> "$scan_file" || true
    done < <(ds4_discovery_cidrs)

    while read -r prefix; do
        [[ -n "$prefix" ]] || continue
        for i in {1..254}; do
            host="${prefix}.${i}"
            [[ "$local_ips" == *" $host "* ]] && continue
            printf '%s\n' "$host" >> "$scan_file"
        done
    done < <(ds4_lan_prefixes)

    if [[ -s "$scan_file" ]] && candidate=$(sort -u "$scan_file" | probe_ds4_hosts_for_api); then
        rm -f "$neighbor_file" "$scan_file"
        printf '%s\n' "$candidate"
        return 0
    fi

    rm -f "$neighbor_file" "$scan_file"
    return 1
}

ds4_preferred_client_api_base() {
    local configured live remote port
    configured=$(ds4_configured_remote_api_base || true)
    if [[ -n "$configured" ]]; then
        printf '%s\n' "$configured"
        return 0
    fi

    live=$(ds4_local_api_base || true)
    if [[ -n "$live" ]]; then
        printf '%s\n' "$live"
        return 0
    fi

    remote=$(ds4_lan_api_base || true)
    if [[ -n "$remote" ]]; then
        printf '%s\n' "$remote"
        return 0
    fi

    port=$(ds4_listen_port_from_log || true)
    [[ "$port" =~ ^[0-9]+$ ]] || port=$(first_ds4_discovery_port)
    printf 'http://localhost:%s/v1\n' "$port"
}

prepare_default_discovery() {
    local port cidrs local_api remote_api fallback first_cidr first_ip
    DS4_DEFAULT_DISCOVERY_FOUND=0
    export DS4_DEFAULT_DISCOVERY_FOUND

    port=$(ask_ds4_discovery_port)
    DS4_DISCOVERY_PORTS="$port"
    export DS4_DISCOVERY_PORTS

    cidrs=$(ds4_lan_cidrs_unique | join_lines_with_comma)
    if [[ -n "$cidrs" ]]; then
        log_info "探测: ${cidrs} 端口 ${port}"
    else
        log_warn "未获取到本机局域网 IPv4 网段，将只检查显式地址与本机地址。"
    fi

    local_api=$(ds4_local_api_base || true)
    if [[ -n "$local_api" ]]; then
        log_info "本机 DS4 API 可用: $local_api"
        DS4_DEFAULT_DISCOVERY_FOUND=1
        export DS4_DEFAULT_DISCOVERY_FOUND
        return 0
    fi

    remote_api=$(ds4_lan_api_base || true)
    if [[ -n "$remote_api" ]]; then
        DS4_REMOTE_API_BASE="$remote_api"
        export DS4_REMOTE_API_BASE
        log_info "发现 DS4 API: $remote_api"
        DS4_DEFAULT_DISCOVERY_FOUND=1
        export DS4_DEFAULT_DISCOVERY_FOUND
        return 0
    fi

    DS4_DISCOVERY_SCAN=0
    export DS4_DISCOVERY_SCAN
    fallback="http://localhost:${port}/v1"
    log_warn "未在同网段发现 DS4 服务，已回退到 $fallback"
    first_cidr=$(ds4_lan_cidrs_unique | sed -n '1p')
    first_ip="${first_cidr%/*}"
    if [[ "$first_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_info "验证服务端: curl --noproxy '*' http://<DS4机器IP>:${port}/v1/models"
    fi
}

prepare_server_discovery() {
    local api_base port lan_ip lan_api_base
    DS4_DEFAULT_DISCOVERY_FOUND=0
    export DS4_DEFAULT_DISCOVERY_FOUND
    DS4_SERVER_LAN_API_BASE=""
    DS4_SERVER_LAN_API_READY=0
    export DS4_SERVER_LAN_API_BASE DS4_SERVER_LAN_API_READY

    api_base=$(ds4_local_api_base || true)
    if [[ -n "$api_base" ]]; then
        log_info "本机 DS4 API 可用: $api_base"
        DS4_DEFAULT_DISCOVERY_FOUND=1
        export DS4_DEFAULT_DISCOVERY_FOUND

        port=$(printf '%s\n' "$api_base" | sed -nE 's#^https?://[^:/]+:([0-9]+)/v1$#\1#p')
        lan_ip=$(ds4_primary_lan_ip || true)
        if [[ -n "$lan_ip" && "$port" =~ ^[0-9]+$ ]]; then
            lan_api_base="http://${lan_ip}:${port}/v1"
            DS4_SERVER_LAN_API_BASE="$lan_api_base"
            export DS4_SERVER_LAN_API_BASE
            if probe_ds4_api_discovery "$lan_api_base"; then
                DS4_SERVER_LAN_API_READY=1
                DS4_REMOTE_API_BASE="$lan_api_base"
                export DS4_SERVER_LAN_API_READY DS4_REMOTE_API_BASE
                log_info "客户端 Base URL: $lan_api_base"
                log_info "健康检查: curl --noproxy '*' ${lan_api_base}/models"
            else
                log_warn "客户端 Base URL: $lan_api_base (局域网地址未验证，可能只监听 localhost 或被防火墙拦截)"
                log_info "当前监听状态: lsof -nP -iTCP:${port} -sTCP:LISTEN"
                log_info "健康检查: curl --noproxy '*' ${lan_api_base}/models"
            fi
        fi
        return 0
    fi

    port=$(ds4_listen_port_from_log || true)
    [[ "$port" =~ ^[0-9]+$ ]] || port=$(first_ds4_discovery_port)
    lan_ip=$(ds4_primary_lan_ip || true)
    if [[ -n "$lan_ip" ]]; then
        log_warn "本机 DS4 API 暂不可用，候选 Base URL: http://${lan_ip}:${port}/v1"
        log_info "健康检查: curl --noproxy '*' http://${lan_ip}:${port}/v1/models"
    else
        log_warn "本机 DS4 API 暂不可用，候选 Base URL: http://localhost:${port}/v1"
    fi
    log_info "查看服务日志: $DEFAULT_SERVER_LOG"
}

ds4_describe_api_base_source() {
    local api_base="$1"
    if ds4_is_loopback_api_base "$api_base"; then
        if probe_ds4_api "$api_base"; then
            printf '本机 DS4 API'
        else
            printf '本机默认地址（未探测到可用 API）'
        fi
    elif probe_ds4_api_discovery "$api_base"; then
        printf '局域网 DS4 API'
    else
        printf '显式/发现地址（未重新验证）'
    fi
}

ds4_api_ready() {
    ds4_local_api_base >/dev/null 2>&1
}

ds4_api_key() {
    printf 'sk-ds4-local-%s\n' "$(hostname -s)"
}

ds4_api_context_length() {
    local api_base="$1" payload context
    payload=$(curl -fsS \
        --noproxy "${DS4_CURL_NOPROXY:-*}" \
        --connect-timeout 2 \
        --max-time 4 \
        "${api_base}/models" 2>/dev/null) || return 1

    context=$(printf '%s\n' "$payload" | sed -nE 's/.*"context_length"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    [[ "$context" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$context"
}

ds4_client_context_length() {
    local api_base="${1:-$(ds4_preferred_client_api_base)}"
    ds4_api_context_length "$api_base" 2>/dev/null || printf '%s\n' "$DS4_DEFAULT_SERVER_CONTEXT_WINDOW"
}

current_model_type() {
    local current=""
    if [[ -L "$DEFAULT_MODEL_FILE" ]]; then
        current=$(readlink "$DEFAULT_MODEL_FILE")
    elif [[ -e "$DEFAULT_MODEL_FILE" ]]; then
        current="$DEFAULT_MODEL_FILE"
    fi

    case "$current" in
        *"$Q4_IMATRIX_FILE"*) echo "q4-imatrix" ;;
        *"$Q2_IMATRIX_FILE"*) echo "q2-imatrix" ;;
        "") echo "none" ;;
        *) echo "unknown" ;;
    esac
}

print_client_env() {
    local api_base="${1:-$(ds4_preferred_api_base)}"
    local api_key="${2:-$(ds4_api_key)}"
    local context_length="${3:-$(ds4_client_context_length "$api_base")}"
    cat <<EOF
export DS4_API_BASE_URL="$api_base"
export DS4_API_KEY="$api_key"
export DS4_MODEL="deepseek-v4-flash"
export DS4_CONTEXT_LENGTH="$context_length"

aider-ds4() {
  AIDER_OPENAI_API_BASE="$api_base" \\
  AIDER_OPENAI_API_KEY="$api_key" \\
  OPENAI_API_BASE="$api_base" \\
  OPENAI_API_BASE_URL="$api_base" \\
  OPENAI_API_KEY="$api_key" \\
  aider --model openai/deepseek-v4-flash \\
        --openai-api-base "$api_base" \\
        --openai-api-key "$api_key" \\
        --api-key openai="$api_key" \\
        --model-metadata-file "\$HOME/.aider.model.metadata.json" \\
        --no-show-model-warnings "\$@"
}
EOF
}

write_aider_model_metadata() {
    local api_base="${1:-$(ds4_preferred_client_api_base)}"
    local metadata_file="${AIDER_MODEL_METADATA_FILE:-$HOME/.aider.model.metadata.json}"
    local context_length
    context_length=$(ds4_client_context_length "$api_base")

    cat > "$metadata_file" <<EOF
{
  "openai/deepseek-v4-flash": {
    "max_tokens": $context_length,
    "max_input_tokens": $context_length,
    "max_output_tokens": 32768,
    "input_cost_per_token": 0,
    "output_cost_per_token": 0,
    "litellm_provider": "openai",
    "mode": "chat"
  }
}
EOF
    chmod 600 "$metadata_file" 2>/dev/null || true
    log_info "已写入 Aider DS4 模型元数据: $metadata_file (context_length=$context_length)"
}

write_ds4_env_file() {
    local env_file="${DS4_ENV_FILE:-$HOME/.ds4-env}"
    local api_base="${1:-$(ds4_preferred_api_base)}"
    local api_key="${2:-$(ds4_api_key)}"

    cat > "$env_file" <<EOF
# DS4 local OpenAI-compatible endpoint
# Managed by install-ds4.sh configure-clients
$(print_client_env "$api_base" "$api_key")
EOF
    chmod 600 "$env_file" 2>/dev/null || true
    log_info "已写入 DS4 通用环境变量: $env_file"
}

find_adl() {
    if [[ "${DS4_USE_ADL:-1}" == "0" ]]; then
        return 1
    fi
    if [[ -n "${ADL_PATH:-}" && -x "${ADL_PATH}" ]]; then
        echo "${ADL_PATH}"
        return 0
    fi
    command -v adl 2>/dev/null || return 1
}

get_memory_gb() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo $(($(sysctl -n hw.memsize 2>/dev/null || echo "0") / 1073741824))
    elif [[ -r /proc/meminfo ]]; then
        awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo
    else
        echo 0
    fi
}

path_free_gb() {
    local path="$1"
    df -g "$path" 2>/dev/null | awk 'NR==2 {print int($4)}'
}

file_size_gb() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo $(($(stat -f%z "$file" 2>/dev/null || echo 0) / 1073741824))
    else
        echo $(($(stat -c%s "$file" 2>/dev/null || echo 0) / 1073741824))
    fi
}

gguf_validate_file() {
    local file="$1"
    [[ "${DS4_GGUF_VALIDATE:-1}" != "0" ]] || return 0
    [[ -s "$file" ]] || return 1

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "未找到 python3，无法执行 GGUF 结构校验；仅使用基础文件检查。"
        return 0
    fi

    python3 - "$file" <<'PY'
import math
import os
import struct
import sys

path = sys.argv[1]
size = os.path.getsize(path)

# GGML type id -> (block_size, type_size_bytes)
# Values are from ggml/llama.cpp GGML type traits. They are enough for DS4's
# F16/Q8/Q4_K/Q2_K/IQ2_XXS model files and common GGUF variants.
TYPE_INFO = {
    0: (1, 4),      # F32
    1: (1, 2),      # F16
    2: (32, 18),    # Q4_0
    3: (32, 20),    # Q4_1
    6: (32, 22),    # Q5_0
    7: (32, 24),    # Q5_1
    8: (32, 34),    # Q8_0
    9: (32, 40),    # Q8_1
    10: (256, 84),  # Q2_K
    11: (256, 110), # Q3_K
    12: (256, 144), # Q4_K
    13: (256, 176), # Q5_K
    14: (256, 210), # Q6_K
    15: (256, 292), # Q8_K
    16: (256, 66),  # IQ2_XXS
    17: (256, 74),  # IQ2_XS
    18: (256, 98),  # IQ3_XXS
    19: (256, 50),  # IQ1_S
    20: (32, 18),   # IQ4_NL
    21: (256, 110), # IQ3_S
    22: (256, 82),  # IQ2_S
    23: (256, 136), # IQ4_XS
    24: (1, 1),     # I8
    25: (1, 2),     # I16
    26: (1, 4),     # I32
    27: (1, 8),     # I64
    28: (1, 8),     # F64
    29: (256, 56),  # IQ1_M
    30: (1, 2),     # BF16
}

class GGUFError(Exception):
    pass

def _gguf_excepthook(exc_type, exc, tb):
    if issubclass(exc_type, GGUFError):
        print(f"GGUF 校验失败: {exc}", file=sys.stderr)
        sys.exit(1)
    sys.__excepthook__(exc_type, exc, tb)

sys.excepthook = _gguf_excepthook

class Reader:
    def __init__(self, fh):
        self.fh = fh
        self.off = 0

    def read(self, n):
        if n < 0 or self.off + n > size:
            raise GGUFError(f"unexpected EOF at offset {self.off}, need {n} bytes")
        data = self.fh.read(n)
        if len(data) != n:
            raise GGUFError(f"short read at offset {self.off}")
        self.off += n
        return data

    def u32(self):
        return struct.unpack("<I", self.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.read(8))[0]

    def i64(self):
        return struct.unpack("<q", self.read(8))[0]

    def string(self):
        n = self.u64()
        if n > 1024 * 1024 * 128:
            raise GGUFError(f"unreasonable string length {n} at offset {self.off}")
        return self.read(n).decode("utf-8", "replace")

def skip_value(r, typ):
    if typ in (0, 1):
        r.read(1)
    elif typ in (2, 3):
        r.read(2)
    elif typ in (4, 5, 6):
        r.read(4)
    elif typ == 7:
        r.read(1)
    elif typ == 8:
        return r.string()
    elif typ == 9:
        elem_type = r.u32()
        n = r.u64()
        if n > 100_000_000:
            raise GGUFError(f"unreasonable array length {n}")
        for _ in range(n):
            skip_value(r, elem_type)
    elif typ in (10, 11, 12):
        r.read(8)
    else:
        raise GGUFError(f"unsupported metadata type {typ}")
    return None

def align(x, n):
    return ((x + n - 1) // n) * n

with open(path, "rb") as fh:
    r = Reader(fh)
    magic = r.read(4)
    if magic != b"GGUF":
        raise GGUFError("missing GGUF magic")
    version = r.u32()
    if version not in (2, 3):
        raise GGUFError(f"unsupported GGUF version {version}")

    tensor_count = r.u64()
    kv_count = r.u64()
    if tensor_count == 0 or tensor_count > 10_000_000:
        raise GGUFError(f"unreasonable tensor count {tensor_count}")
    if kv_count > 1_000_000:
        raise GGUFError(f"unreasonable metadata count {kv_count}")

    alignment = 32
    for _ in range(kv_count):
        key = r.string()
        typ = r.u32()
        before = r.off
        value = skip_value(r, typ)
        if key == "general.alignment" and typ in (4, 10):
            fh.seek(before)
            r.off = before
            alignment = r.u32() if typ == 4 else r.u64()
        if alignment <= 0 or alignment > 65536:
            raise GGUFError(f"invalid alignment {alignment}")

    tensors = []
    for _ in range(tensor_count):
        name = r.string()
        ndims = r.u32()
        if ndims > 8:
            raise GGUFError(f"tensor {name}: invalid dimensions {ndims}")
        dims = [r.u64() for _ in range(ndims)]
        typ = r.u32()
        offset = r.u64()
        if typ not in TYPE_INFO:
            raise GGUFError(f"tensor {name}: unsupported GGML type id {typ}")
        ne = 1
        for d in dims:
            if d == 0:
                raise GGUFError(f"tensor {name}: zero dimension")
            ne *= d
        block, type_size = TYPE_INFO[typ]
        nbytes = math.ceil(ne / block) * type_size
        tensors.append((name, offset, nbytes))

    data_start = align(r.off, alignment)
    if data_start > size:
        raise GGUFError("tensor data starts beyond EOF")

    max_end = data_start
    for name, offset, nbytes in tensors:
        begin = data_start + offset
        end = begin + nbytes
        if begin < data_start or end > size:
            raise GGUFError(
                f"tensor {name} points outside GGUF file: "
                f"offset={offset}, bytes={nbytes}, end={end}, file_size={size}"
            )
        max_end = max(max_end, end)

    print(f"ok tensors={tensor_count} data_end={max_end} file_size={size}")
PY
}

find_best_external_volume() {
    [[ "$(uname)" == "Darwin" && -d /Volumes ]] || return 1

    local best_path="" best_free=0 vol free_gb

    while IFS= read -r vol; do
        [[ -d "$vol" ]] || continue
        # 排除系统卷
        [[ "$(basename "$vol")" == "Macintosh HD" ]] && continue
        [[ "$(basename "$vol")" == "Recovery" ]] && continue

        free_gb=$(path_free_gb "$vol")
        [[ -n "$free_gb" ]] || continue

        if [[ "$free_gb" -gt "$best_free" ]]; then
            best_free="$free_gb"
            best_path="$vol"
        fi
    done < <(find /Volumes -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    if [[ -z "$best_path" ]]; then
        return 1
    fi

    if [[ "$best_free" -lt "$MIN_EXTERNAL_FREE_GB" ]]; then
        return 1
    fi

    # 输出: 路径 和 可用空间(GB)
    printf '%s\t%s\n' "$best_path" "$best_free"
}

migrate_model_files() {
    local source_dir="$1"
    local target_dir="$2"

    [[ -d "$source_dir" ]] || return 0
    [[ -n "$(ls -A "$source_dir" 2>/dev/null)" ]] || return 0

    # 检查是否有断点续传中的下载文件（aria2/part），避免迁移正在写入的文件
    if compgen -G "$source_dir/*.aria2" >/dev/null 2>&1 \
       || compgen -G "$source_dir/*.part" >/dev/null 2>&1; then
        log_error "$source_dir 中存在断点下载文件 (*.aria2 / *.part)。请先停止下载，再重新执行本命令迁移。"
        exit 1
    fi

    log_info "迁移已有模型/断点文件: $source_dir -> $target_dir"
    mkdir -p "$target_dir"

    shopt -s dotglob nullglob
    local item base
    for item in "$source_dir"/*; do
        base=$(basename "$item")
        if [[ -e "$target_dir/$base" ]]; then
            log_warn "目标已存在，跳过: $target_dir/$base"
            continue
        fi
        mv "$item" "$target_dir/"
    done
    shopt -u dotglob nullglob
}

prepare_model_storage() {
    local gguf_dir="$INSTALL_DIR/gguf"
    local target_dir=""

    if [[ -n "${DS4_MODEL_DIR:-}" ]]; then
        target_dir="${DS4_MODEL_DIR}"
        log_info "使用 DS4_MODEL_DIR 指定的模型目录: $target_dir"
    elif [[ "${DS4_USE_EXTERNAL_DISK:-1}" != "0" ]]; then
        local ext_info
        ext_info=$(find_best_external_volume 2>/dev/null || true)
        if [[ -n "${ext_info:-}" ]]; then
            local ext_path ext_free
            ext_path=$(echo "$ext_info" | cut -f1)
            ext_free=$(echo "$ext_info" | cut -f2)
            target_dir="${ext_path}/ds4/gguf"
            log_info "检测到外置硬盘: $(basename "$ext_path") (可用 ${ext_free}GB)，模型将放到: $target_dir"
        else
            log_warn "未找到可用外置硬盘（需要 ${MIN_EXTERNAL_FREE_GB}GB+），将使用内置存储。"
        fi
    fi

    [[ -n "$target_dir" ]] || { mkdir -p "$gguf_dir"; return 0; }

    mkdir -p "$target_dir"
    if [[ -L "$gguf_dir" ]]; then
        local current_target
        current_target=$(readlink "$gguf_dir")
        [[ "$current_target" == "$target_dir" ]] && return 0
        rm -f "$gguf_dir"
    elif [[ -d "$gguf_dir" ]] && [[ -n "$(ls -A "$gguf_dir" 2>/dev/null)" ]]; then
        migrate_model_files "$gguf_dir" "$target_dir"
        rm -rf "$gguf_dir"
    else
        rm -rf "$gguf_dir"
    fi

    ln -sfn "$target_dir" "$gguf_dir"
    log_info "模型下载目录: $gguf_dir -> $target_dir"
}

q2_model_complete() {
    local model_path="$INSTALL_DIR/gguf/$Q2_IMATRIX_FILE"
    [[ -s "$model_path" ]] || return 1
    [[ ! -f "$model_path.aria2" ]] || return 1
    [[ "$(file_size_gb "$model_path")" -ge "$Q2_IMATRIX_MIN_COMPLETE_GB" ]] || return 1
    gguf_validate_file "$model_path" >/dev/null 2>&1
}

q4_model_complete() {
    local model_path="$INSTALL_DIR/gguf/$Q4_IMATRIX_FILE"
    [[ -s "$model_path" ]] || return 1
    [[ ! -f "$model_path.aria2" ]] || return 1
    [[ "$(file_size_gb "$model_path")" -ge "$Q4_IMATRIX_MIN_COMPLETE_GB" ]] || return 1
    gguf_validate_file "$model_path" >/dev/null 2>&1
}

model_complete() {
    local type="${1:-q2-imatrix}"
    case "$type" in
        q4-imatrix) q4_model_complete ;;
        *) q2_model_complete ;;
    esac
}

model_file_for_type() {
    local type="${1:-q2-imatrix}"
    case "$type" in
        q4-imatrix) echo "$Q4_IMATRIX_FILE" ;;
        *) echo "$Q2_IMATRIX_FILE" ;;
    esac
}

model_url_for_type() {
    local type="${1:-q2-imatrix}"
    case "$type" in
        q4-imatrix) echo "$Q4_IMATRIX_URL" ;;
        *) echo "$Q2_IMATRIX_URL" ;;
    esac
}

model_min_gb() {
    local type="${1:-q2-imatrix}"
    case "$type" in
        q4-imatrix) echo "$Q4_IMATRIX_MIN_COMPLETE_GB" ;;
        *) echo "$Q2_IMATRIX_MIN_COMPLETE_GB" ;;
    esac
}

# 获取当前模型的上下文窗口大小（tokens）
model_context_window() {
    echo "$DS4_CONTEXT_WINDOW"
}

# 获取模型信息摘要
model_info_summary() {
    local type="${1:-$(current_model_type)}"
    local quant_label
    case "$type" in
        q4-imatrix) quant_label="Q4 (高质量)" ;;
        q2-imatrix) quant_label="Q2 (平衡)" ;;
        *) quant_label="$type" ;;
    esac
    echo "${DS4_MODEL_NAME} | ${DS4_TOTAL_PARAMS}总参/${DS4_ACTIVE_PARAMS}激活 | 上下文: $((DS4_CONTEXT_WINDOW / 1024))K | 量化: ${quant_label}"
}

default_model_complete() {
    local current="" size_gb
    if [[ -L "$DEFAULT_MODEL_FILE" ]]; then
        current=$(readlink "$DEFAULT_MODEL_FILE")
        case "$current" in
            *"$Q4_IMATRIX_FILE"*) q4_model_complete ;;
            *"$Q2_IMATRIX_FILE"*) q2_model_complete ;;
            *) return 1 ;;
        esac
        return $?
    fi

    if [[ -f "$DEFAULT_MODEL_FILE" && -s "$DEFAULT_MODEL_FILE" && ! -f "$DEFAULT_MODEL_FILE.aria2" ]]; then
        size_gb=$(file_size_gb "$DEFAULT_MODEL_FILE")
        [[ "$size_gb" -ge "$Q2_IMATRIX_MIN_COMPLETE_GB" ]] || return 1
        gguf_validate_file "$DEFAULT_MODEL_FILE" >/dev/null 2>&1
        return $?
    fi

    return 1
}

ensure_default_model_link() {
    if default_model_complete; then
        return 0
    fi

    if [[ -e "$DEFAULT_MODEL_FILE" || -L "$DEFAULT_MODEL_FILE" ]]; then
        log_warn "默认模型链接/文件不可用或未完整，将重新选择可用模型: $DEFAULT_MODEL_FILE"
        if [[ -L "$DEFAULT_MODEL_FILE" || ! -s "$DEFAULT_MODEL_FILE" ]]; then
            rm -f "$DEFAULT_MODEL_FILE"
        else
            mv "$DEFAULT_MODEL_FILE" "${DEFAULT_MODEL_FILE}.invalid.$(date +%Y%m%d_%H%M%S)"
        fi
    fi

    if q4_model_complete; then
        cd "$INSTALL_DIR"
        ln -sfn "gguf/$Q4_IMATRIX_FILE" "ds4flash.gguf"
        log_info "已建立 DS4 默认模型链接: $DEFAULT_MODEL_FILE -> gguf/$Q4_IMATRIX_FILE"
        return 0
    fi

    if q2_model_complete; then
        cd "$INSTALL_DIR"
        ln -sfn "gguf/$Q2_IMATRIX_FILE" "ds4flash.gguf"
        log_info "已建立 DS4 默认模型链接: $DEFAULT_MODEL_FILE -> gguf/$Q2_IMATRIX_FILE"
        return 0
    fi

    # 回退：gguf/ 目录不可访问（如外置硬盘未挂载），在 INSTALL_DIR 及其他位置查找模型
    local gguf_dir="$INSTALL_DIR/gguf"
    if [[ -L "$gguf_dir" && ! -e "$gguf_dir" ]]; then
        log_warn "gguf 符号链接目标不可访问: $(readlink "$gguf_dir")"
    fi

    local search_dir f
    for search_dir in "$INSTALL_DIR" "$INSTALL_DIR/gguf"; do
        [[ -d "$search_dir" ]] || continue
        for f in "$search_dir"/$Q4_IMATRIX_FILE "$search_dir"/$Q2_IMATRIX_FILE; do
            [[ -f "$f" && -s "$f" ]] || continue
            [[ ! -f "$f.aria2" ]] || continue
            if _is_complete_model "$f"; then
                cd "$INSTALL_DIR"
                ln -sfn "$(basename "$f")" "ds4flash.gguf"
                log_info "从 $search_dir 找到可用模型，已建立链接: ds4flash.gguf -> $(basename "$f")"
                return 0
            fi
        done
    done

    # 尝试自动挂载外置硬盘（macOS）
    if [[ -L "$gguf_dir" && ! -e "$gguf_dir" && "$(uname)" == "Darwin" ]]; then
        local target_vol
        target_vol=$(readlink "$gguf_dir" | sed 's|^/Volumes/||' | cut -d'/' -f1)
        if [[ -n "$target_vol" ]]; then
            local dev
            dev=$(diskutil list 2>/dev/null | grep -i "$target_vol" | awk '{print $NF}' | head -1)
            if [[ -n "$dev" ]]; then
                log_info "尝试挂载外置硬盘: $target_vol ($dev)"
                diskutil mount "$dev" >/dev/null 2>&1 || true
                if [[ -e "$gguf_dir" ]]; then
                    log_info "外置硬盘已挂载，重新检查模型..."
                    if q4_model_complete; then
                        cd "$INSTALL_DIR"
                        ln -sfn "gguf/$Q4_IMATRIX_FILE" "ds4flash.gguf"
                        return 0
                    fi
                    if q2_model_complete; then
                        cd "$INSTALL_DIR"
                        ln -sfn "gguf/$Q2_IMATRIX_FILE" "ds4flash.gguf"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    return 1
}

# 检查指定路径的模型文件是否完整
_is_complete_model() {
    local path="$1"
    [[ -f "$path" && -s "$path" ]] || return 1
    [[ ! -f "$path.aria2" ]] || return 1
    local min_gb
    case "$(basename "$path")" in
        *"$Q4_IMATRIX_FILE"*) min_gb=$Q4_IMATRIX_MIN_COMPLETE_GB ;;
        *"$Q2_IMATRIX_FILE"*) min_gb=$Q2_IMATRIX_MIN_COMPLETE_GB ;;
        *) return 1 ;;
    esac
    [[ "$(file_size_gb "$path")" -ge "$min_gb" ]] || return 1
    gguf_validate_file "$path" >/dev/null 2>&1
}

# ── 硬件检查 ──
check_hardware() {
    local quiet="${1:-0}"
    if [[ "$(uname)" != "Darwin" ]]; then
        [[ "$quiet" == "1" ]] || log_warn "此脚本主要针对 macOS Metal 优化，Linux 用户建议手动编译 CUDA 版本。"
    fi

    local mem_gb min_mem_gb
    min_mem_gb="${DS4_MIN_MEMORY_GB:-96}"
    mem_gb=$(get_memory_gb)
    if [[ "$mem_gb" -gt 0 && "$mem_gb" -lt "$min_mem_gb" ]]; then
        [[ "$quiet" == "1" ]] || log_warn "检测到内存为 ${mem_gb}GB，DS4 跑 DeepSeek-V4 推荐至少 ${min_mem_gb}GB (Q2 量化)。"
        if [[ "${DS4_FORCE_INSTALL_UNSUPPORTED:-0}" == "1" ]]; then
            [[ "$quiet" == "1" ]] || log_warn "DS4_FORCE_INSTALL_UNSUPPORTED=1，忽略硬件限制继续执行。"
            return 0
        fi
        if [[ "$quiet" != "1" ]]; then
            log_warn "硬件不满足最低要求，跳过本机安装。"
            log_info "如需连接局域网内其他 DS4 主机，可执行: $0 configure-clients -a http://<DS4机器IP>:8000/v1"
            log_info "如确认仍要本机安装，可执行: DS4_FORCE_INSTALL_UNSUPPORTED=1 $0 install"
        fi
        return 1
    elif [[ "$mem_gb" -lt 192 ]]; then
        [[ "$quiet" == "1" ]] || log_info "检测到内存为 ${mem_gb}GB，推荐优先下载 q2-imatrix；q4-imatrix 可能比较吃紧。"
    else
        [[ "$quiet" == "1" ]] || log_info "检测到内存为 ${mem_gb}GB，适合运行 DS4 Q2/Q4 量化模型。"
    fi
}

# ── 依赖检查 ──
check_dependencies() {
    local missing=()
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    if ! command -v git >/dev/null 2>&1; then
        log_warn "未检测到 git，将使用 GitHub zip 包下载源码。"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少必要依赖: ${missing[*]}"
        exit 1
    fi
}

extract_zip() {
    local zip_file="$1"
    local target_dir="$2"
    local tmp_extract
    tmp_extract=$(mktemp -d "${TMPDIR:-/tmp}/ds4-src.XXXXXX")

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip_file" -d "$tmp_extract"
    elif command -v ditto >/dev/null 2>&1; then
        ditto -x -k "$zip_file" "$tmp_extract"
    else
        log_error "缺少 unzip 或 ditto，无法解压 GitHub zip 包。"
        rm -rf "$tmp_extract"
        exit 1
    fi

    local src_dir
    src_dir=$(find "$tmp_extract" -maxdepth 1 -type d -name "ds4-*" | head -1)
    if [[ -z "$src_dir" || ! -f "$src_dir/Makefile" ]]; then
        log_error "源码包解压失败或格式异常。"
        rm -rf "$tmp_extract"
        exit 1
    fi

    rm -rf "$target_dir"
    mv "$src_dir" "$target_dir"
    rm -rf "$tmp_extract"
}

zip_valid() {
    local zip_file="$1"
    [[ -s "$zip_file" ]] || return 1

    if command -v unzip >/dev/null 2>&1; then
        unzip -tq "$zip_file" >/dev/null 2>&1
    elif command -v ditto >/dev/null 2>&1; then
        local test_dir
        test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ds4-zip-test.XXXXXX")
        if ditto -x -k "$zip_file" "$test_dir" >/dev/null 2>&1; then
            rm -rf "$test_dir"
            return 0
        fi
        rm -rf "$test_dir"
        return 1
    else
        return 1
    fi
}

download_archive_file() {
    mkdir -p "$DOWNLOAD_DIR"

    if zip_valid "$ARCHIVE_FILE"; then
        log_info "检测到可用源码 zip 缓存，跳过下载: $ARCHIVE_FILE"
        return 0
    fi

    if [[ -e "$ARCHIVE_FILE" ]]; then
        log_warn "检测到不可用源码 zip 缓存，删除后重新下载: $ARCHIVE_FILE"
        rm -f "$ARCHIVE_FILE"
    fi

    log_step "通过 GitHub zip 包下载 DS4 源码..."
    local adl_bin
    adl_bin="$(find_adl 2>/dev/null || true)"
    if [[ -n "${adl_bin:-}" ]]; then
        log_info "检测到 adl: ${adl_bin:-}，源码 zip 将下载到: $ARCHIVE_FILE"
        "${adl_bin:-}" "$ARCHIVE_URL" "$DOWNLOAD_DIR" "$(basename "$ARCHIVE_FILE")"
    else
        log_warn "未检测到 adl，回退使用 curl 下载源码 zip。"
        curl -fL --http1.1 --retry 3 --retry-delay 2 "$ARCHIVE_URL" -o "$ARCHIVE_FILE"
    fi

    zip_valid "$ARCHIVE_FILE" || {
        log_error "源码 zip 下载后校验失败: $ARCHIVE_FILE"
        exit 1
    }
}

download_source_archive() {
    download_archive_file
    extract_zip "$ARCHIVE_FILE" "$INSTALL_DIR"
}

clone_source() {
    if ! command -v git >/dev/null 2>&1; then
        download_source_archive
        return
    fi

    log_step "克隆 DS4 仓库..."
    if git -c http.version=HTTP/1.1 clone --depth 1 "$REPO_URL" "$INSTALL_DIR"; then
        return
    fi

    log_warn "git clone 失败，常见原因是 GitHub HTTP/2 连接问题，自动回退到 zip 下载。"
    rm -rf "$INSTALL_DIR"
    download_source_archive
}

# ── 安装/编译 ──
install() {
    if [[ "${DS4_HARDWARE_PRECHECKED:-0}" != "1" ]] && ! check_hardware; then
        return 2
    fi
    check_dependencies
    local should_build=1

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log_info "检测到 DS4 git 源码目录。"
        cd "$INSTALL_DIR"
        local origin
        origin=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$origin" != "$REPO_URL" && "$origin" != "git@github.com:antirez/ds4.git" ]]; then
            log_error "$INSTALL_DIR 已存在，但不是 antirez/ds4 仓库: $origin"
            exit 1
        fi

        if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" && "${DS4_FORCE_REBUILD:-0}" != "1" && "${DS4_UPDATE_SOURCE:-0}" != "1" && "${DS4_FORCE_SOURCE_REFRESH:-0}" != "1" ]]; then
            log_info "DS4 已编译，跳过源码更新和重新编译。"
            should_build=0
        elif [[ "${DS4_UPDATE_SOURCE:-0}" == "1" || "${DS4_FORCE_SOURCE_REFRESH:-0}" == "1" ]]; then
            local pull_output pull_rc
            log_info "按显式要求更新 DS4 源码..."
            set +e
            pull_output=$(git -c http.version=HTTP/1.1 pull 2>&1)
            pull_rc=$?
            set -e
            echo "$pull_output"
            if [[ "$pull_rc" -ne 0 ]]; then
                if [[ "${DS4_FORCE_SOURCE_REFRESH:-0}" == "1" ]]; then
                    log_warn "git pull 失败，按 DS4_FORCE_SOURCE_REFRESH=1 使用 zip 缓存刷新源码。"
                    cd "$HOME"
                    download_source_archive
                    cd "$INSTALL_DIR"
                else
                    log_warn "git pull 失败，保留现有 DS4 源码继续编译。需要使用 zip 强制刷新时执行: DS4_FORCE_SOURCE_REFRESH=1 $0 install"
                fi
            elif echo "$pull_output" | grep -q "Already up to date"; then
                if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" && "${DS4_FORCE_REBUILD:-0}" != "1" ]]; then
                    log_info "源码未更新且 DS4 已编译，跳过重新编译。需要强制重编时执行: DS4_FORCE_REBUILD=1 $0 install"
                    should_build=0
                fi
            fi
        elif [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" && "${DS4_FORCE_REBUILD:-0}" != "1" ]]; then
            log_info "DS4 已编译，跳过源码更新和重新编译。"
            should_build=0
        fi
    elif [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/Makefile" ]]; then
        log_info "检测到 DS4 源码目录。"
        cd "$INSTALL_DIR"
        if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" && "${DS4_FORCE_REBUILD:-0}" != "1" ]]; then
            if [[ "${DS4_FORCE_SOURCE_REFRESH:-0}" == "1" ]]; then
                log_warn "按 DS4_FORCE_SOURCE_REFRESH=1 使用 zip 缓存刷新源码。"
                cd "$HOME"
                download_source_archive
                cd "$INSTALL_DIR"
            else
                log_info "DS4 已编译，跳过源码下载和重新编译。"
                should_build=0
            fi
        fi
    elif [[ -e "$INSTALL_DIR" ]]; then
        if [[ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            rm -rf "$INSTALL_DIR"
            clone_source
            cd "$INSTALL_DIR"
        else
            log_error "$INSTALL_DIR 已存在但不是 DS4 源码目录，请先备份或删除后重试。"
            exit 1
        fi
    else
        clone_source
        cd "$INSTALL_DIR"
    fi

    [[ "$should_build" == "1" ]] || return 0

    log_step "开始编译 (macOS Metal)..."
    make clean 2>/dev/null || true
    if make; then
        log_info "DS4 编译成功！"
    else
        log_error "编译失败，请检查 Xcode 命令行工具是否已安装。"
        exit 1
    fi
}

# ── 模型下载 ──
download_model() {
    local type="$1"
    if [[ -z "$type" ]]; then
        log_error "download_model 缺少模型类型"
        return 1
    fi
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "DS4 未安装，请先执行 install"
        exit 1
    fi

    cd "$INSTALL_DIR"
    log_step "准备下载 $type 模型..."
    prepare_model_storage
    local adl_bin model_file model_url
    adl_bin="$(find_adl 2>/dev/null || true)"
    model_file=$(model_file_for_type "$type")
    model_url=$(model_url_for_type "$type")

    # 使用 adl 直链下载（支持 q2-imatrix 和 q4-imatrix）
    if [[ -n "${adl_bin:-}" && -n "$model_url" ]]; then
        mkdir -p "$INSTALL_DIR/gguf"
        if model_complete "$type"; then
            ensure_default_model_link
            log_info "检测到已有 $type 模型文件，跳过下载: $INSTALL_DIR/gguf/$model_file"
            _auto_restart_if_running "$type"
            return 0
        elif [[ -f "$INSTALL_DIR/gguf/$model_file.aria2" ]]; then
            log_info "检测到 $type 断点文件，将继续断点续传。"
        elif [[ -s "$INSTALL_DIR/gguf/$model_file" ]]; then
            log_warn "检测到未完成的 $type 模型文件，将交给 adl/aria2 继续校验和续传。"
        fi
        log_info "检测到 adl: ${adl_bin:-}，将直接用 adl 下载 $type 模型。"
        log_info "模型大小: $type 约 $(model_min_gb "$type")GB，请耐心等待..."
        ADL_EXPECTED_SIZE_GB="$(model_min_gb "$type")"
        local rc=0
        # adl 内部可能依赖未定义的环境变量；在子 shell 中关闭 set -u/-e 隔离，
        # 同时确保能正确捕获 adl 的退出码。
        ( set +eu; "${adl_bin:-}" "$model_url" "$INSTALL_DIR/gguf" "$model_file" ) || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            if ! model_complete "$type"; then
                log_error "$type 模型文件仍未完整，未切换默认模型。"
                log_info "当前大小: $(file_size_gb "$INSTALL_DIR/gguf/$model_file")GiB，期望至少: $(model_min_gb "$type")GiB，并且必须通过 GGUF 结构校验。"
                gguf_validate_file "$INSTALL_DIR/gguf/$model_file" 2>&1 || true
                log_info "请重新执行: $0 download $type"
                return 1
            fi
            ensure_default_model_link
            # 下载完成后，若 DS4 服务正在运行，自动重启以加载新模型
            _auto_restart_if_running "$type"
        else
            log_error "adl 下载失败 (退出码: $rc)"
            log_info "可尝试: 1) 更新 adl: adl update  2) 使用官方脚本下载: $0 download $type --no-adl"
        fi
        return $rc
    elif [[ -n "${adl_bin:-}" ]]; then
        log_info "检测到 adl，但 $type 暂无内置直链，回退到官方脚本。"
    fi

    # ./download_model.sh 内部会调用 curl/aria2c。保留 shim 作为 q2 之外的兼容路径。
    if [[ -n "${adl_bin:-}" ]]; then
        log_info "尝试使用 adl 接管官方脚本中的 curl 下载。"
        local shim_dir real_curl
        shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/ds4-adl-shim.XXXXXX")
        real_curl=$(command -v curl)
        cat > "$shim_dir/curl" <<'SHIM'
#!/usr/bin/env bash
set +u

out=""
url=""
next_is_out=false
for arg in "$@"; do
    if [[ "$next_is_out" == true ]]; then
        out="$arg"
        next_is_out=false
        continue
    fi
    case "$arg" in
        -o|--output) next_is_out=true ;;
        -o*) out="${arg#-o}" ;;
        http://*|https://*) url="$arg" ;;
    esac
done

if [[ -n "$url" && -n "${DS4_ADL_BIN:-}" ]]; then
    if [[ -z "$out" ]]; then
        out="$(basename "${url%%\?*}")"
        [[ -z "$out" || "$out" == "/" ]] && out="download.bin"
    fi
    mkdir -p "$(dirname "$out")"
    exec "$DS4_ADL_BIN" "$url" "$(dirname "$out")" "$(basename "$out")"
fi

exec "${DS4_REAL_CURL:-/usr/bin/curl}" "$@"
SHIM
        chmod +x "$shim_dir/curl"
        local rc=0
        DS4_ADL_BIN="${adl_bin:-}" DS4_REAL_CURL="$real_curl" PATH="$shim_dir:$PATH" bash ./download_model.sh "$type" || rc=$?
        rm -rf "$shim_dir"
        if [[ "$rc" -eq 0 ]]; then
            if ! model_complete "$type"; then
                log_error "$type 模型文件仍未完整，未切换默认模型。"
                log_info "当前大小: $(file_size_gb "$INSTALL_DIR/gguf/$model_file")GiB，期望至少: $(model_min_gb "$type")GiB，并且必须通过 GGUF 结构校验。"
                gguf_validate_file "$INSTALL_DIR/gguf/$model_file" 2>&1 || true
                return 1
            fi
            ensure_default_model_link
            _auto_restart_if_running "$type"
        fi
        return $rc
    else
        local rc=0
        bash ./download_model.sh "$type" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            if ! model_complete "$type"; then
                log_error "$type 模型文件仍未完整，未切换默认模型。"
                log_info "当前大小: $(file_size_gb "$INSTALL_DIR/gguf/$model_file")GiB，期望至少: $(model_min_gb "$type")GiB，并且必须通过 GGUF 结构校验。"
                gguf_validate_file "$INSTALL_DIR/gguf/$model_file" 2>&1 || true
                return 1
            fi
            ensure_default_model_link
            _auto_restart_if_running "$type"
        fi
        return $rc
    fi
}

has_model() {
    ensure_default_model_link >/dev/null 2>&1
}

smoke_test() {
    [[ -x "$INSTALL_DIR/ds4" ]] || { log_error "DS4 未安装或未编译成功"; exit 1; }
    ensure_default_model_link || { log_error "未发现可运行的默认模型 ds4flash.gguf，请先执行: $0 download ${DEFAULT_MODEL_TYPE}"; exit 1; }

    cd "$INSTALL_DIR"

    # 检查是否已有 DS4 CLI 进程在运行（排除 ds4-server/ds4-bench）
    local cli_conflict_pid
    cli_conflict_pid=$(find_ds4_conflict_pid || true)
    if [[ -n "$cli_conflict_pid" ]]; then
        log_info "检测到 DS4 CLI 进程已在运行 (PID: $cli_conflict_pid)"
        log_info "跳过冒烟测试（避免进程冲突）。如需重新测试，请先执行: $0 stop"
        return 0
    fi

    # 检查是否有 ds4-server 在运行，尝试通过 API 测试
    local existing_server_pid
    existing_server_pid=$(find_ds4_server_pid || true)
    if [[ -n "$existing_server_pid" ]]; then
        local api_base
        api_base=$(ds4_local_api_base || true)
        if [[ -n "$api_base" ]]; then
            log_step "检测到 ds4-server 已运行，通过 API 接口进行冒烟测试: $api_base"
            if smoke_test_api; then
                log_info "API 冒烟测试完成。"
            else
                log_warn "API 测试失败，服务可能尚未完全启动"
            fi
        else
            log_info "检测到 ds4-server 进程，但 API 暂不可用；候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
        fi
        return 0
    fi

    log_step "运行 DS4 冒烟测试..."
    local smoke_cmd=("./ds4" "-p" "你好，请用一句话介绍你自己，并说明你能帮我做什么？")
    if command -v timeout >/dev/null 2>&1; then
        smoke_cmd=("timeout" "120" "${smoke_cmd[@]}")
    fi
    if "${smoke_cmd[@]}" 2>&1 | tee /tmp/ds4-smoke-test.log; then
        log_info "冒烟测试完成。"
    else
        log_warn "冒烟测试未正常结束，可能是参数或模型加载耗时较长；日志: /tmp/ds4-smoke-test.log"
    fi
}

# 通过 API 接口进行冒烟测试
smoke_test_api() {
    local api_base api_url
    api_base=$(ds4_local_api_base || true)
    [[ -n "$api_base" ]] || api_base=$(ds4_preferred_api_base)
    api_url="${api_base%/}/chat/completions"
    local test_prompt="你好，请用一句话介绍你自己。"

    # 等待服务就绪（最多 10 秒）
    local retries=10
    while [[ $retries -gt 0 ]]; do
        if curl -s "$api_url" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        ((retries--))
    done

    [[ $retries -eq 0 ]] && return 1

    # 发送测试请求
    local response
    response=$(curl -s -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer sk-ds4-local-$(hostname -s)" \
        -d "{\"model\":\"ds4\",\"messages\":[{\"role\":\"user\",\"content\":\"$test_prompt\"}],\"max_tokens\":50}" \
        2>/dev/null)

    [[ -n "$response" && "$response" == *"content"* ]]
}

start_server_background() {
    [[ -x "$INSTALL_DIR/ds4-server" ]] || { log_error "ds4-server 未安装或未编译成功"; exit 1; }
    ensure_default_model_link || { log_error "未发现可运行的默认模型 ds4flash.gguf，请先执行: $0 download ${DEFAULT_MODEL_TYPE}"; exit 1; }

    local server_pid=""
    server_pid=$(find_ds4_server_pid || true)
    if [[ -n "$server_pid" ]]; then
        local running_api
        running_api=$(ds4_local_api_base || true)
        if [[ -n "$running_api" ]]; then
            if ds4_lan_api_ready_for_local_server "$running_api"; then
                log_info "ds4-server 已在运行且局域网 API 可用，PID: $server_pid"
                return 0
            fi
            log_warn "ds4-server 已运行且本机 API 可用，但局域网不可访问，可能只监听 127.0.0.1。"
            if [[ "${DS4_AUTO_RESTART_LOCALHOST_SERVER:-0}" == "1" ]]; then
                log_info "DS4_AUTO_RESTART_LOCALHOST_SERVER=1，自动用 --host ${DS4_HOST:-$DEFAULT_DS4_HOST} 重启。"
            elif ! ask_yes_no "是否重启 ds4-server 并绑定 ${DS4_HOST:-$DEFAULT_DS4_HOST}" "y" 10; then
                log_info "保留当前 ds4-server。局域网客户端仍无法直连。"
                return 0
            fi

            kill "$server_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$server_pid" 2>/dev/null || true
            server_pid=""
        fi

        if [[ -n "$server_pid" ]]; then
            log_warn "检测到 ds4-server 进程正在运行但 API 未响应，PID: $server_pid"
            if [[ "${DS4_AUTO_RESTART_BROKEN_SERVER:-0}" == "1" ]]; then
                log_info "DS4_AUTO_RESTART_BROKEN_SERVER=1，自动重启该 ds4-server 进程。"
            elif ! ask_yes_no "是否重启该 ds4-server 进程" "y" 10; then
                log_error "已取消启动 ds4-server。"
                return 1
            fi

            kill "$server_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$server_pid" 2>/dev/null || true
        fi
    fi

    local conflict_pid=""
    conflict_pid=$(find_ds4_conflict_pid || true)
    if [[ -n "$conflict_pid" ]]; then
        handle_ds4_conflict_pid "$conflict_pid" || return 1
    fi

    if ! start_ds4_server_once; then
        local lock_pid
        lock_pid=$(sed -nE 's/.*another ds4 process is already running \(pid ([0-9]+)\).*/\1/p' "$DEFAULT_SERVER_LOG" | tail -1)
        if [[ -n "$lock_pid" ]]; then
            handle_ds4_conflict_pid "$lock_pid" || return 1
            start_ds4_server_once || true
        fi
    fi

    if [[ -f "$INSTALL_DIR/ds4-server.pid" ]] && kill -0 "$(cat "$INSTALL_DIR/ds4-server.pid")" >/dev/null 2>&1; then
        log_info "ds4-server 已后台启动，PID: $(cat "$INSTALL_DIR/ds4-server.pid")"
        log_info "日志: $DEFAULT_SERVER_LOG"
    else
        log_error "ds4-server 启动失败，请查看日志: $DEFAULT_SERVER_LOG"
        exit 1
    fi
}

stop_server() {
    if [[ -f "$INSTALL_DIR/ds4-server.pid" ]] && kill -0 "$(cat "$INSTALL_DIR/ds4-server.pid")" >/dev/null 2>&1; then
        kill "$(cat "$INSTALL_DIR/ds4-server.pid")"
        rm -f "$INSTALL_DIR/ds4-server.pid"
        log_info "已停止 ds4-server。"
        return
    fi

    local server_pid
    server_pid=$(find_ds4_server_pid || true)
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        log_info "已停止 ds4-server (PID: $server_pid)。"
    else
        log_info "ds4-server 未运行。"
    fi
}

# ── 下载后自动重启（若服务正在运行） ──
_auto_restart_if_running() {
    local model_type="$1"
    local server_pid
    server_pid=$(find_ds4_server_pid 2>/dev/null || true)

    if [[ -z "$server_pid" ]]; then
        log_info "DS4 服务未运行，下次启动时将使用新下载的 ${model_type} 模型。"
        return 0
    fi

    log_warn "检测到 DS4 服务正在运行 (PID: $server_pid)，模型已更新需要重启才能生效。"
    log_info "正在自动重启 DS4 服务以加载 ${model_type} 模型..."

    # 停止旧服务
    stop_server >/dev/null 2>&1
    sleep 2

    # 启动新服务
    start_server_background
    log_success "DS4 服务已重启，正在加载 ${model_type} 模型。"
    log_info "API 地址: $(ds4_preferred_api_base)"
}

bootstrap() {
    local model_type=""
    if [[ "$#" -gt 0 ]]; then
        model_type="$1"
    fi
    # 如果未指定模型类型，交互式选择
    if [[ -z "$model_type" ]]; then
        model_type=$(select_model_type "选择要安装的模型类型") || exit 1
    fi
    install
    if has_model; then
        log_info "检测到已有模型文件，跳过模型下载。"
        # 检测外置硬盘，询问是否迁移
        check_and_offer_migration
    else
        download_model "$model_type"
    fi
    smoke_test
    print_next_steps
}

build_model_options() {
    local current_type
    local q2_current_label="" q4_current_label=""

    MODEL_OPTIONS=()
    MODEL_DESCRIPTIONS=()
    MODEL_DETAILS=()
    MODEL_DEFAULT_IDX=0
    current_type=$(current_model_type)
    if [[ "$current_type" == "q2-imatrix" ]]; then
        q2_current_label="，当前使用"
    elif [[ "$current_type" == "q4-imatrix" ]]; then
        q4_current_label="，当前使用"
    fi

    if q2_model_complete 2>/dev/null; then
        MODEL_OPTIONS+=("q2-imatrix")
        MODEL_DESCRIPTIONS+=("Q2-imatrix (平衡, 已安装${q2_current_label})")
        MODEL_DETAILS+=("文件: $INSTALL_DIR/gguf/$Q2_IMATRIX_FILE|大小: >= ${Q2_IMATRIX_MIN_COMPLETE_GB}GiB")
    fi
    if q4_model_complete 2>/dev/null; then
        MODEL_OPTIONS+=("q4-imatrix")
        MODEL_DESCRIPTIONS+=("Q4-imatrix (高质量, 已安装${q4_current_label})")
        MODEL_DETAILS+=("文件: $INSTALL_DIR/gguf/$Q4_IMATRIX_FILE|大小: >= ${Q4_IMATRIX_MIN_COMPLETE_GB}GiB")
    fi
    if ! q2_model_complete 2>/dev/null; then
        MODEL_OPTIONS+=("q2-imatrix")
        MODEL_DESCRIPTIONS+=("Q2-imatrix (平衡, 需下载)")
        MODEL_DETAILS+=("文件: $INSTALL_DIR/gguf/$Q2_IMATRIX_FILE|修复: $0 download q2-imatrix")
    fi
    if ! q4_model_complete 2>/dev/null; then
        MODEL_OPTIONS+=("q4-imatrix")
        MODEL_DESCRIPTIONS+=("Q4-imatrix (高质量, 需下载)")
        MODEL_DETAILS+=("文件: $INSTALL_DIR/gguf/$Q4_IMATRIX_FILE|修复: $0 download q4-imatrix")
    fi

    for i in "${!MODEL_OPTIONS[@]}"; do
        if [[ "${MODEL_OPTIONS[$i]}" == "$current_type" ]]; then
            MODEL_DEFAULT_IDX=$((i + 1))
            break
        fi
    done
    [[ "$MODEL_DEFAULT_IDX" -gt 0 ]] || MODEL_DEFAULT_IDX=1
    return 0
}

print_model_options() {
    local i detail

    for i in "${!MODEL_OPTIONS[@]}"; do
        printf "  %d. %s\n" $((i+1)) "${MODEL_DESCRIPTIONS[$i]}"
        IFS='|' read -r -a detail <<< "${MODEL_DETAILS[$i]}"
        for line in "${detail[@]}"; do
            [[ -n "$line" ]] && printf "     %s\n" "$line"
        done
        echo ""
    done
}

# 交互式选择模型类型
select_model_type() {
    local prompt="${1:-选择模型类型}"

    build_model_options

    if [[ ${#MODEL_OPTIONS[@]} -eq 1 ]]; then
        echo "${MODEL_OPTIONS[0]}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        echo "${MODEL_OPTIONS[$((MODEL_DEFAULT_IDX - 1))]}"
        return 0
    fi

    local choice
    printf "%s，请输入编号 [默认 %d]: " "$prompt" "$MODEL_DEFAULT_IDX" > /dev/tty
    read -r choice

    choice="${choice:-$MODEL_DEFAULT_IDX}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#MODEL_OPTIONS[@]} ]]; then
        local idx=$((choice-1))
        echo "${MODEL_OPTIONS[$idx]}"
        return 0
    else
        log_warn "无效选择: $choice"
        return 1
    fi
}

# 切换模型
use_model() {
    local target_type=""
    if [[ "$#" -gt 0 ]]; then
        target_type="$1"
    fi
    
    # 如果未指定类型，交互式选择
    if [[ -z "$target_type" ]]; then
        target_type=$(select_model_type "选择要使用的模型") || return 1
    fi
    
    # 验证模型是否已安装
    case "$target_type" in
        q4-imatrix)
            if ! q4_model_complete; then
                log_error "Q4-imatrix 模型未安装，请先执行: $0 download q4-imatrix"
                return 1
            fi
            ;;
        q2-imatrix)
            if ! q2_model_complete; then
                log_error "Q2-imatrix 模型未安装，请先执行: $0 download q2-imatrix"
                return 1
            fi
            ;;
        *)
            log_error "未知模型类型: $target_type"
            log_info "支持的类型: q2-imatrix, q4-imatrix"
            return 1
            ;;
    esac
    
    # 检查当前链接
    local current_target=""
    if [[ -L "$DEFAULT_MODEL_FILE" ]]; then
        current_target=$(readlink "$DEFAULT_MODEL_FILE")
    fi
    
    local new_target="gguf/$(model_file_for_type "$target_type")"
    
    # 如果已经是目标模型，无需切换
    if [[ "$current_target" == "$new_target" ]]; then
        log_info "当前已经是 $target_type 模型，无需切换。"
        return 0
    fi
    
    # 检查服务是否运行
    local server_pid
    server_pid=$(find_ds4_server_pid 2>/dev/null || true)
    local need_restart=false
    
    if [[ -n "$server_pid" ]]; then
        log_warn "DS4 服务正在运行 (PID: $server_pid)，切换模型需要重启服务。"
        if ask_yes_no "是否停止服务并切换模型" "y" 10; then
            stop_server
            need_restart=true
        else
            log_info "已取消切换。"
            return 0
        fi
    fi
    
    # 执行切换
    cd "$INSTALL_DIR"
    ln -sfn "$new_target" "ds4flash.gguf"
    log_info "已切换到 $target_type 模型: $DEFAULT_MODEL_FILE -> $new_target"
    
    # 如果需要，自动重启
    if [[ "$need_restart" == true ]]; then
        log_info "正在重启 DS4 服务..."
        start_server_background
    else
        log_info "下次启动时将使用 $target_type 模型。"
        log_info "手动启动: $0 server-bg"
    fi
}

ensure_model_ready_interactive() {
    local model_type
    model_type=$(select_model_type "选择默认模型（本地不存在会自动下载）") || return 1
    case "$model_type" in
        q2-imatrix|q4-imatrix) ;;
        *)
            log_error "未知模型类型: $model_type"
            return 1
            ;;
    esac

    if ! model_complete "$model_type"; then
        log_warn "$model_type 模型本地不存在或不完整，将开始下载。"
        download_model "$model_type"
    else
        log_info "$model_type 模型已存在。"
    fi

    use_model "$model_type"
}

# 列出已安装的模型
list_models() {
    build_model_options

    echo ""
    echo "========================================"
    echo "  DS4 模型"
    echo "========================================"

    local current=""
    if [[ -L "$DEFAULT_MODEL_FILE" ]]; then
        current=$(readlink "$DEFAULT_MODEL_FILE")
        echo "当前使用: $current"
        echo ""
    fi

    if [[ ${#MODEL_OPTIONS[@]} -gt 0 ]]; then
        print_model_options
    else
        echo "  未发现已安装的模型。"
        echo "  请执行: $0 download q2-imatrix"
    fi

    echo "========================================"
}

env_export_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$file" >/dev/null 2>&1 || exit 1
        eval "printf '%s' \"\${${key}:-}\""
    )
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

upsert_export_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local quoted
    quoted=$(shell_quote "$value")
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if grep -qE "^export[[:space:]]+${key}=" "$file"; then
        sed -i.bak -E "s|^export[[:space:]]+${key}=.*|export ${key}=${quoted}|" "$file" && rm -f "${file}.bak"
    elif grep -qE "^${key}=" "$file"; then
        sed -i.bak -E "s|^${key}=.*|export ${key}=${quoted}|" "$file" && rm -f "${file}.bak"
    else
        printf 'export %s=%s\n' "$key" "$quoted" >> "$file"
    fi
}

configure_open_webui_client() {
    local api_base="$1"
    local api_key="$2"
    local openwebui_dir="${OPENWEBUI_DIR:-$HOME/open-webui}"
    local env_file="${OPENWEBUI_ENV_FILE:-$openwebui_dir/.open-webui.env}"

    if [[ ! -d "$openwebui_dir" && ! -f "$env_file" ]]; then
        log_info "未检测到 Open WebUI 安装目录，跳过自动配置。"
        return 0
    fi

    upsert_export_var "$env_file" "ENABLE_OPENAI_API" "True"
    upsert_export_var "$env_file" "OPENAI_API_BASE_URLS" "$api_base"
    upsert_export_var "$env_file" "OPENAI_API_KEYS" "$api_key"
    upsert_export_var "$env_file" "OPENWEBUI_DETECTED_BACKEND" "ds4"
    chmod 600 "$env_file" 2>/dev/null || true
    log_info "已配置 Open WebUI DS4 后端: $env_file -> $api_base"
}

command_status() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        printf '已安装 (%s)\n' "$(command -v "$name")"
    else
        printf '未检测到\n'
    fi
}

command_path_any() {
    local cmd
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done
    return 1
}

command_status_any() {
    local path
    path=$(command_path_any "$@" || true)
    if [[ -n "$path" ]]; then
        printf '已安装 (%s)\n' "$path"
    else
        printf '未检测到\n'
    fi
}

client_installed() {
    local path
    path=$(command_path_any "$@" || true)
    [[ -n "$path" ]]
}

dir_status() {
    local label="$1"
    shift
    local path
    for path in "$@"; do
        if [[ -e "$path" ]]; then
            printf '已检测到 (%s)\n' "$path"
            return 0
        fi
    done
    printf '未检测到\n'
}

detect_client_inventory() {
    echo "客户端/IDE 检测:"
    echo "  Open WebUI: $([[ -d "$HOME/open-webui" || -f "$HOME/open-webui/.open-webui.env" ]] && echo "已安装" || echo "未检测到")"
    echo "  Google Antigravity CLI: $(command_status_any agy antigravity)"
    echo "  Claude Code: $(command_status claude)"
    echo "  OpenAI Codex CLI: $(command_status codex)"
    echo "  Cursor CLI: $(command_status_any agent cursor)"
    echo "  DeepSeek CLI/TUI: $(command_status deepseek)"
    echo "  Gemini CLI: $(command_status gemini)"
    echo "  GLM CLI: $(command_status glm)"
    echo "  gpt cli: $(command_status_any gpt-cli gpt)"
    echo "  Grok CLI: $(command_status grok)"
    echo "  iFlow CLI: $(command_status iflow)"
    echo "  Kimi CLI: $(command_status kimi)"
    echo "  MiniMax CLI: $(command_status_any mmx minimax)"
    echo "  OpenClaw CLI: $(command_status_any openclaw claw)"
    echo "  OpenCLI: $(command_status_any opencli)"
    echo "  OpenCode AI: $(command_status_any opencode opencode-ai)"
    echo "  Qoder CLI: $(command_status qoder)"
    echo "  Qwen CLI: $(command_status qwen)"
    echo "  Aider: $(command_status aider)"
    echo "  ChatDev: $(command_status_any chatdev ChatDev)"
    echo "  ClawX: $(dir_status ClawX '/Applications/ClawX.app' "$HOME/Applications/ClawX.app")"
    echo "  DeerFlow: $(dir_status DeerFlow "$HOME/DeerFlow" "$HOME/deer-flow" "$HOME/deerflow")"
    echo "  Hermes Agent: $(command_status hermes)"
    echo "  MonkeyCode: $(command_status_any monkeycode monkey)"
    echo "  OpenHands: $(command_status_any openhands)"
    echo "  OpenHuman: $(command_status_any openhuman)"
    echo "  OpenManus: $(dir_status OpenManus "$HOME/OpenManus" "$HOME/openmanus")"
    echo "  VS Code: $(dir_status VSCode "$HOME/Library/Application Support/Code" "$HOME/.config/Code")"
    echo "  Cursor IDE: $(dir_status Cursor "$HOME/Library/Application Support/Cursor" "$HOME/.cursor")"
    echo "  Windsurf: $(dir_status Windsurf "$HOME/Library/Application Support/Windsurf" "$HOME/.windsurf")"
    echo "  Continue: $(dir_status Continue "$HOME/.continue" "$HOME/.continue/config.json")"
}

print_client_config_guide() {
    local api_base="$1"
    local api_key="$2"
    local env_file="${DS4_ENV_FILE:-$HOME/.ds4-env}"
    local context_length
    context_length=$(ds4_client_context_length "$api_base")

    echo "========================================"
    echo "  DS4 客户端配置指南"
    echo "========================================"
    echo ""
    echo "📍 服务地址: $api_base"
    echo "🔑 API Key:  $api_key (DS4 不需要，可填任意值)"
    echo "🤖 Model:    deepseek-v4-flash"
    echo "📐 上下文:   ${context_length} tokens（以 /v1/models 返回为准；模型能力 64K）"
    echo ""
    echo "📋 快速配置:"
    echo "    source $env_file"
    echo "    aider-ds4"
    echo ""
    echo "   ⚠️  不建议把 DS4 的 OPENAI_API_BASE 全局写入 ~/.zshrc，避免影响 GPT/OpenAI 配置。"
    echo ""

    # 推荐排序的客户端
    echo "🌟 推荐客户端 (已按易用性排序):"
    echo ""

    if client_installed aider; then
        echo "  1️⃣  Aider (强烈推荐 - AI 结对编程)"
        echo "      配置: source $env_file"
        echo "      启动: aider-ds4"
        echo "      等价命令:"
        echo "            AIDER_OPENAI_API_BASE=\"$api_base\" AIDER_OPENAI_API_KEY=\"$api_key\" \\"
        echo "            aider --model openai/deepseek-v4-flash \\"
        echo "                  --openai-api-base \"$api_base\" \\"
        echo "                  --openai-api-key \"$api_key\" \\"
        echo "                  --model-metadata-file \"\$HOME/.aider.model.metadata.json\" \\"
        echo "                  --no-show-model-warnings"
        echo "      特点: 代码编辑 + Git 集成，OpenAI 兼容原生支持"
        echo ""
        echo "      ⚠️  判断是否连到 DS4 不要问模型自述，应该看 API model 字段:"
        echo "          curl --noproxy '*' $api_base/models"
        echo "          期望看到: deepseek-v4-flash, context_length=$context_length"
        echo ""
        echo "      ⚠️  若提示 'command not found'，添加 pip 用户目录到 PATH:"
        echo "          export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo "          # 或查找 aider 位置: python3 -m site --user-base"
        echo ""
    fi

    if [[ -d "$HOME/OpenManus" || -d "$HOME/openmanus" ]]; then
        echo "  2️⃣  OpenManus (通用 Agent 自动化)"
        echo "      配置: 编辑 OpenManus/config/config.toml"
        echo "            [llm]"
        echo "            model = \"deepseek-v4-flash\""
        echo "            base_url = \"$api_base\""
        echo "            api_key = \"$api_key\""
        echo "      启动: cd OpenManus && python run_mcp.py"
        echo "      特点: Computer Use + Browser Use + MCP 工具调用"
        echo ""
    fi

    if client_installed openhands; then
        echo "  3️⃣  OpenHands (AI 软件工程师)"
        echo "      配置: export LLM_MODEL=\"openai/deepseek-v4-flash\""
        echo "            export LLM_BASE_URL=\"$api_base\""
        echo "            export LLM_API_KEY=\"$api_key\""
        echo "      启动: python -m openhands"
        echo "      特点: 自主编码、调试、提交 PR"
        echo ""
    fi

    if client_installed deepseek; then
        echo "  4️⃣  DeepSeek CLI/TUI (官方客户端)"
        echo "      配置: 修改 ~/.deepseek/config 或环境变量"
        echo "            export DEEPSEEK_API_BASE=\"$api_base\""
        echo "      启动: deepseek chat 或 deepseek tui"
        echo ""
    fi

    if [[ -d "$HOME/open-webui" || -f "$HOME/open-webui/.open-webui.env" ]]; then
        echo "  🌐 Open WebUI (Web 界面)"
        echo "      状态: 已支持自动写入配置"
        echo "            OPENAI_API_BASE_URLS=$api_base"
        echo "      重启: $0 configure-clients && ~/open-webui/start.sh"
        echo ""
    fi

    # 其他客户端
    local other_clients=""
    if client_installed opencode opencode-ai; then
        other_clients="$other_clients OpenCode AI,"
        echo "  💻 OpenCode AI"
        echo "      配置: 使用 OpenAI-compatible provider"
        echo "            baseURL=$api_base, apiKey=$api_key, model=deepseek-v4-flash"
        echo "      注意: 不自动修改 ~/.opencode/settings.json，避免覆盖账号配置"
        echo ""
    fi

    if client_installed hermes; then
        other_clients="$other_clients Hermes,"
        echo "  💻 Hermes Agent"
        echo "      配置: hermes setup model → 新增 OpenAI-compatible provider"
        echo "            base_url=$api_base, api_key=$api_key, model=deepseek-v4-flash"
        echo ""
    fi

    # 账号型 CLI 提示
    if client_installed claude codex gemini agy antigravity agent cursor qwen kimi grok iflow glm mmx minimax openclaw claw opencli qoder; then
        echo "  ⚠️  账号型 CLI (需手动配置):"
        echo "      Claude Code / Codex / Gemini / Cursor / Qwen / Kimi / Grok 等"
        echo "      这些客户端通常绑定官方账号，若支持自定义 Provider:"
        echo "      - 选择 OpenAI Compatible / Custom Provider"
        echo "      - Base URL: $api_base"
        echo "      - API Key: $api_key"
        echo "      - Model: deepseek-v4-flash"
        echo ""
    fi

    # IDE 插件
    if [[ -d "$HOME/Library/Application Support/Code" || -d "$HOME/.config/Code" || -d "$HOME/Library/Application Support/Cursor" || -d "$HOME/.continue" ]]; then
        echo "  🛠️  IDE 插件配置:"
        echo "      Continue / Cline / Roo / Cursor / Windsurf"
        echo "      - Provider: OpenAI Compatible"
        echo "      - Base URL: $api_base"
        echo "      - API Key: $api_key"
        echo "      - Model: deepseek-v4-flash"
        echo ""
    fi

    echo "========================================"
    echo "  使用示例"
    echo "========================================"
    echo ""
    echo "1. 测试 API 连接:"
    echo "   curl $api_base/models"
    echo ""
    echo "2. 使用 Python OpenAI SDK:"
    echo "   from openai import OpenAI"
    echo "   client = OpenAI(base_url=\"$api_base\", api_key=\"$api_key\")"
    echo "   response = client.chat.completions.create("
    echo "       model=\"deepseek-v4-flash\","
    echo "       messages=[{\"role\": \"user\", \"content\": \"你好\"}]"
    echo "   )"
    echo ""
    echo "3. 一键配置环境变量:"
    echo "   source $env_file"
    echo ""
}

client_guide() {
    local api_base api_key
    api_base=""
    if [[ "$#" -gt 0 ]]; then
        api_base="$1"
    fi
    if [[ -z "$api_base" ]]; then
        api_base=$(ds4_preferred_client_api_base)
    else
        api_base=$(normalize_ds4_api_base "$api_base")
    fi
    if [[ "$#" -gt 1 ]]; then
        api_key="$2"
    else
        api_key=$(ds4_api_key)
    fi
    print_client_config_guide "$api_base" "$api_key"
}

client_guide_from_args() {
    local api_base="" api_key="" arg
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
            -a|--api-base|--base-url)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个地址"; return 1; }
                api_base="$1"
                shift
                ;;
            -k|--api-key)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个 API Key"; return 1; }
                api_key="$1"
                shift
                ;;
            *)
                if [[ -z "$api_base" ]]; then
                    api_base="$arg"
                elif [[ -z "$api_key" ]]; then
                    api_key="$arg"
                else
                    log_error "client-guide 不支持多余参数: $arg"
                    return 1
                fi
                ;;
        esac
    done

    if [[ -n "$api_base" && -n "$api_key" ]]; then
        client_guide "$api_base" "$api_key"
    elif [[ -n "$api_base" ]]; then
        client_guide "$api_base"
    else
        client_guide
    fi
}

configure_clients_from_args() {
    local arg
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
            -a|--api-base|--base-url)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个地址"; return 1; }
                DS4_REMOTE_API_BASE="$1"
                export DS4_REMOTE_API_BASE
                shift
                ;;
            -H|--host)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个主机地址"; return 1; }
                DS4_REMOTE_HOST="$1"
                export DS4_REMOTE_HOST
                shift
                ;;
            -p|--port)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个端口"; return 1; }
                DS4_DISCOVERY_PORTS="$1"
                export DS4_DISCOVERY_PORTS
                shift
                ;;
            --no-scan)
                DS4_DISCOVERY_SCAN=0
                export DS4_DISCOVERY_SCAN
                ;;
            *)
                log_error "configure-clients 不支持参数: $arg"
                return 1
                ;;
        esac
    done
    configure_clients
}

model_arg_from_options() {
    local model_type="" arg
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
            -t|--type|--model)
                [[ "$#" -gt 0 ]] || { log_error "$arg 需要一个模型类型"; return 1; }
                model_type="$1"
                shift
                ;;
            q2-imatrix|q4-imatrix)
                model_type="$arg"
                ;;
            *)
                log_error "不支持的模型参数: $arg"
                return 1
                ;;
        esac
    done
    printf '%s\n' "$model_type"
}

discover() {
    local api_base client_api_base api_key model_type server_pid commit
    api_base=$(ds4_preferred_api_base)
    client_api_base=$(ds4_preferred_client_api_base)
    api_key=$(ds4_api_key)
    model_type=$(current_model_type)
    server_pid=$(find_ds4_server_pid || true)
    commit="unknown"
    [[ -d "$INSTALL_DIR/.git" ]] && commit=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    echo "DS4 发现结果:"
    echo "  安装目录: $INSTALL_DIR"
    echo "  已安装: $([[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" ]] && echo "是" || echo "否")"
    echo "  Commit: $commit"
    echo "  模型信息: $(model_info_summary "$model_type")"
    echo "  模型目录: $([[ -L "$INSTALL_DIR/gguf" ]] && printf '%s -> %s' "$INSTALL_DIR/gguf" "$(readlink "$INSTALL_DIR/gguf")" || printf '%s' "$INSTALL_DIR/gguf")"
    echo "  默认模型: $model_type"
    echo "  上下文窗口: $((DS4_CONTEXT_WINDOW / 1024))K tokens"
    if [[ -n "$server_pid" ]]; then
        echo "  ds4-server: 运行中 (PID: $server_pid)"
    else
        echo "  ds4-server: 未运行"
    fi
    if ds4_api_ready; then
        echo "  API: 可用 (${api_base})"
    else
        echo "  API: 暂不可用；推荐地址: ${api_base}；候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
    fi
    echo "  客户端推荐地址: ${client_api_base} ($(ds4_describe_api_base_source "$client_api_base"))"
    echo "  API Key: $api_key"
    echo ""
    detect_client_inventory
    echo ""
    echo "通用环境变量:"
    print_client_env "$client_api_base" "$api_key" | sed 's/^/  /'
    echo ""
    print_client_config_guide "$client_api_base" "$api_key"
}

discover_brief() {
    local api_base client_api_base api_key server_pid source
    api_base=$(ds4_preferred_api_base)
    client_api_base=$(ds4_preferred_client_api_base)
    api_key=$(ds4_api_key)
    server_pid=$(find_ds4_server_pid || true)
    source=$(ds4_describe_api_base_source "$client_api_base")

    if [[ "${DS4_DISCOVER_BRIEF_MINIMAL:-0}" == "1" ]]; then
        echo "DS4 API: ${client_api_base} (${source})"
        echo "API Key: $api_key"
        return 0
    fi

    echo "DS4 发现摘要:"
    echo "  本机安装: $([[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" ]] && echo "是" || echo "否")"
    if [[ -n "$server_pid" ]]; then
        echo "  本机 ds4-server: 运行中 (PID: $server_pid)"
    else
        echo "  本机 ds4-server: 未运行"
    fi
    if ds4_api_ready; then
        echo "  本机 API: 可用 (${api_base})"
    else
        echo "  本机 API: 暂不可用；候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
    fi
    if [[ "${DS4_SERVER_ONLY:-0}" == "1" && -n "${DS4_SERVER_LAN_API_BASE:-}" ]]; then
        if [[ "${DS4_SERVER_LAN_API_READY:-0}" == "1" ]]; then
            echo "  客户端 Base URL: ${DS4_SERVER_LAN_API_BASE} (局域网可用)"
        else
            echo "  客户端 Base URL: ${DS4_SERVER_LAN_API_BASE} (局域网未开放)"
        fi
    else
        echo "  客户端推荐地址: ${client_api_base} (${source})"
    fi
    echo "  API Key: $api_key"
}

configure_clients() {
    local api_base api_key source
    api_base=$(ds4_preferred_client_api_base)
    api_key=$(ds4_api_key)
    source=$(ds4_describe_api_base_source "$api_base")

    log_info "客户端 API 地址: $api_base ($source)"
    if ! ds4_is_loopback_api_base "$api_base"; then
        log_info "检测到跨主机 DS4 部署，客户端将写入局域网地址。"
    elif [[ "$source" == *"未探测到可用 API"* ]]; then
        log_warn "未自动发现局域网 DS4。若 DS4 在其他主机，请尝试:"
        log_warn "  DS4_REMOTE_API_BASE=http://<DS4机器IP>:8000/v1 $0 configure-clients"
        log_warn "  或 DS4_DISCOVERY_HOSTS=<DS4机器IP> DS4_DISCOVERY_PORTS=8000 $0 configure-clients"
        log_warn "  并确认服务端监听局域网地址、防火墙放行，客户端代理未拦截局域网请求。"
    fi

    write_ds4_env_file "$api_base" "$api_key"
    write_aider_model_metadata "$api_base"
    configure_open_webui_client "$api_base" "$api_key"

    echo ""
    log_info "客户端配置建议:"
    print_client_config_guide "$api_base" "$api_key"
}

doctor() {
    local ok=true api_base client_api_base server_pid model_type
    api_base=$(ds4_preferred_api_base)
    client_api_base=$(ds4_preferred_client_api_base)
    server_pid=$(find_ds4_server_pid || true)
    model_type=$(current_model_type)

    echo "DS4 Doctor:"
    if [[ "${DS4_SERVER_ONLY:-0}" == "1" ]]; then
        if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" ]]; then
            echo "  [OK] DS4 可执行文件已安装"
        else
            echo "  [FAIL] DS4 未安装或未编译完整: $INSTALL_DIR"
            ok=false
        fi
        if [[ "$model_type" != "none" ]]; then
            echo "  [OK] 默认模型: $model_type"
        else
            echo "  [FAIL] 默认模型未就绪，请执行: $0 download q2-imatrix"
            ok=false
        fi
        if [[ -n "$server_pid" ]]; then
            echo "  [OK] ds4-server 进程: $server_pid"
        else
            echo "  [WARN] ds4-server 未运行，可执行: $0 server-bg"
        fi
        if ds4_api_ready; then
            echo "  [OK] 本机 API 可用: $api_base"
            if [[ -n "${DS4_SERVER_LAN_API_BASE:-}" ]]; then
                if [[ "${DS4_SERVER_LAN_API_READY:-0}" == "1" ]]; then
                    echo "  [OK] 局域网 API 可用: ${DS4_SERVER_LAN_API_BASE}"
                else
                    echo "  [WARN] 局域网 API 不可用: ${DS4_SERVER_LAN_API_BASE}"
                fi
            fi
        else
            echo "  [WARN] API 暂不可用，候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
        fi
        if [[ "$ok" == true ]]; then
            return 0
        fi
        return 1
    fi

    if [[ "${DS4_DOCTOR_CLIENT_MINIMAL:-0}" == "1" ]]; then
        if probe_ds4_api_discovery "$client_api_base"; then
            echo "  [OK] API 可用: $client_api_base"
        else
            echo "  [WARN] API 暂不可用: $client_api_base"
        fi
        if [[ -f "$HOME/.ds4-env" ]]; then
            echo "  [OK] 环境变量文件: $HOME/.ds4-env"
        else
            echo "  [WARN] 未发现 ~/.ds4-env，可执行: $0 configure-clients"
        fi
        return 0
    fi

    if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" ]]; then
        echo "  [OK] DS4 可执行文件已安装"
    elif [[ "${DS4_CLIENT_ONLY:-0}" == "1" ]]; then
        echo "  [INFO] 客户端模式：跳过本机 DS4 可执行文件检查"
    else
        echo "  [FAIL] DS4 未安装或未编译完整: $INSTALL_DIR"
        ok=false
    fi

    if [[ "$model_type" != "none" ]]; then
        echo "  [OK] 默认模型: $model_type"
    elif [[ "${DS4_CLIENT_ONLY:-0}" == "1" ]]; then
        echo "  [INFO] 客户端模式：跳过本机默认模型检查"
    else
        echo "  [FAIL] 默认模型未就绪，请执行: $0 download q2-imatrix"
        ok=false
    fi

    if [[ -n "$server_pid" ]]; then
        echo "  [OK] ds4-server 进程: $server_pid"
    elif [[ "${DS4_CLIENT_ONLY:-0}" == "1" ]]; then
        echo "  [INFO] 客户端模式：本机 ds4-server 未运行"
    else
        echo "  [WARN] ds4-server 未运行，可执行: $0 server-bg"
    fi

    if probe_ds4_api_discovery "$client_api_base"; then
        if ds4_is_loopback_api_base "$client_api_base"; then
            echo "  [OK] API 可用: $client_api_base"
        else
            echo "  [OK] 局域网 API 可用: $client_api_base"
        fi
    elif ds4_api_ready; then
        echo "  [OK] API 可用: $api_base"
    else
        echo "  [WARN] API 暂不可用，推荐地址: ${client_api_base}；候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
    fi

    if [[ -f "$HOME/.ds4-env" ]]; then
        echo "  [OK] 通用环境变量文件: $HOME/.ds4-env"
    else
        echo "  [WARN] 未发现 ~/.ds4-env，可执行: $0 configure-clients"
    fi

    if [[ -f "$HOME/open-webui/.open-webui.env" ]]; then
        local ow_base
        ow_base=$(env_export_value "$HOME/open-webui/.open-webui.env" OPENAI_API_BASE_URLS || true)
        if [[ "$ow_base" == "$client_api_base" ]]; then
            echo "  [OK] Open WebUI DS4 地址: $ow_base"
        else
            echo "  [WARN] Open WebUI 地址不一致: ${ow_base:-未配置}，建议执行: $0 configure-clients"
        fi
    else
        echo "  [INFO] 未发现 Open WebUI 配置"
    fi

    if [[ "${DS4_DOCTOR_BRIEF:-0}" != "1" ]]; then
        echo ""
        detect_client_inventory
    fi
    [[ "$ok" == true ]]
}

# 检测外置硬盘并询问是否迁移已有模型
check_and_offer_migration() {
    # 如果模型已在外置硬盘上，跳过
    if [[ -L "$INSTALL_DIR/gguf" ]]; then
        local current_target
        current_target=$(readlink "$INSTALL_DIR/gguf")
        if [[ "$current_target" == /Volumes/* ]]; then
            log_info "模型已在外置硬盘上: $current_target"
            return 0
        fi
    fi

    # 如果用户禁用了外置硬盘检测，跳过
    [[ "${DS4_USE_EXTERNAL_DISK:-1}" != "0" ]] || return 0

    # 如果用户已通过环境变量指定了模型目录，跳过
    [[ -n "${DS4_MODEL_DIR:-}" ]] && return 0

    # 扫描外置硬盘
    local ext_info
    ext_info=$(find_best_external_volume 2>/dev/null || true)
    [[ -n "${ext_info:-}" ]] || return 0

    local ext ext_free
    ext=$(echo "$ext_info" | cut -f1)
    ext_free=$(echo "$ext_info" | cut -f2)
    local target_dir="${ext}/ds4/gguf"

    # 计算当前模型占用空间
    local current_size_gb=0
    if [[ -d "$INSTALL_DIR/gguf" ]]; then
        current_size_gb=$(du -sg "$INSTALL_DIR/gguf" 2>/dev/null | awk '{print $1}')
    fi

    # 如果本地模型目录为空或很小，无需迁移
    [[ "$current_size_gb" -gt 1 ]] || return 0

    echo ""
    log_info "检测到外置大容量硬盘: $(basename "$ext") (可用 ${ext_free}GB)"
    log_info "当前模型占用: ${current_size_gb}GB (位于 $INSTALL_DIR/gguf)"
    echo ""
    read -p "是否将模型迁移到外置硬盘以释放本地空间? (y/N): " migrate_confirm

    if [[ "$migrate_confirm" =~ ^[Yy]$ ]]; then
        prepare_model_storage
        log_info "迁移完成！模型已移至: $(readlink "$INSTALL_DIR/gguf")"
    else
        log_info "保持模型在当前位置: $INSTALL_DIR/gguf"
    fi
}

print_next_steps() {
    local api_base
    api_base=$(ds4_preferred_api_base)
    cat <<EOF

[INFO] 下一步：
  交互使用:
    $0 start

  单次提问:
    $0 start -p "帮我审查这段代码..."

  启动 HTTP Server:
    $0 server-bg

  查看状态:
    $0 status

  推荐模型:
    128GB: $0 download q2-imatrix
    256GB+: $0 download q4-imatrix

[INFO] 本地私有化部署后续操作：
  1. 启动 API 服务:
    $0 server-bg
    # 默认监听 ${api_base%/v1}

  2. 测试 API 接口:
    curl ${api_base%/}/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer sk-ds4-local-\$(hostname -s)" \
      -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"你好"}]}'

  3. 配置 OpenAI 兼容客户端 (Cursor/Claude Code):

     推荐 API Key (已自动生成):
       sk-ds4-local-\$(hostname -s)

     方式 A - 在 Cursor/Claude Code 设置中:
       - OpenAI API Key: sk-ds4-local-\$(hostname -s)
       - OpenAI API Base: $api_base
       - Model: deepseek-v4-flash

     方式 B - 环境变量 (添加到 ~/.zshrc 或 ~/.bashrc):
       export OPENAI_API_BASE=$api_base
       export OPENAI_API_KEY=sk-ds4-local-\$(hostname -s)

     方式 C - 项目级配置 (在项目目录创建 .env 文件):
       OPENAI_API_BASE=$api_base
       OPENAI_API_KEY=sk-ds4-local-\$(hostname -s)

  4. Web UI (推荐 Open WebUI):
    # Docker 一键启动 (自带美观聊天界面)
    docker run -d --name open-webui \
      -p 3000:8080 \
      -e OPENAI_API_BASE_URLS=${api_base/localhost/host.docker.internal} \
      -e OPENAI_API_KEYS=sk-ds4-local-\$(hostname -s) \
      -v open-webui:/app/backend/data \
      ghcr.io/open-webui/open-webui:main

    # 启动后访问: http://localhost:3000
    # 首次打开需注册账号 (仅本地使用，无需担心安全)

    # 其他 Web UI 选择:
    #   - ChatGPT-Next-Web: docker run -d -p 3000:3000 yidadaa/chatgpt-next-web
    #   - LobeChat:         docker run -d -p 3210:3210 lobehub/lobe-chat

  5. 查看服务日志:
    tail -f $DEFAULT_SERVER_LOG

  6. 停止服务:
    $0 stop

EOF
}

start_cli() {
    [[ -x "$INSTALL_DIR/ds4" ]] || { log_error "DS4 未安装或未编译成功"; exit 1; }
    ensure_default_model_link || { log_error "未发现可运行的默认模型 ds4flash.gguf，请先执行: $0 download ${DEFAULT_MODEL_TYPE}"; exit 1; }
    cd "$INSTALL_DIR"
    exec ./ds4 "$@"
}

start_server() {
    [[ -x "$INSTALL_DIR/ds4-server" ]] || { log_error "ds4-server 未安装或未编译成功"; exit 1; }
    ensure_default_model_link || { log_error "未发现可运行的默认模型 ds4flash.gguf，请先执行: $0 download ${DEFAULT_MODEL_TYPE}"; exit 1; }
    cd "$INSTALL_DIR"
    if [[ "$#" -eq 0 ]]; then
        exec ./ds4-server --host "${DS4_HOST:-$DEFAULT_DS4_HOST}" --port "${DS4_PORT:-$DEFAULT_DS4_PORT}"
    fi
    exec ./ds4-server "$@"
}

bench() {
    [[ -x "$INSTALL_DIR/ds4-bench" ]] || { log_error "ds4-bench 未安装或未编译成功"; exit 1; }
    ensure_default_model_link || { log_error "未发现可运行的默认模型 ds4flash.gguf，请先执行: $0 download ${DEFAULT_MODEL_TYPE}"; exit 1; }
    cd "$INSTALL_DIR"
    exec ./ds4-bench "$@"
}

# ── 卸载 ──
uninstall() {
    log_warn "准备卸载 DS4..."

    # 路径白名单：拒绝危险的安装目录
    case "$INSTALL_DIR" in
        ""|"/"|"$HOME"|"/Users"|"/Users/"*"/"|"/home"|"/root")
            log_error "拒绝卸载：INSTALL_DIR=$INSTALL_DIR 不在允许范围内"
            exit 1
            ;;
    esac
    [[ "${INSTALL_DIR%/}" == "${HOME%/}" ]] && { log_error "拒绝删除 \$HOME"; exit 1; }

    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_info "未检测到 DS4 安装目录。"
        return 0
    fi

    # 二次确认 (DS4_FORCE_UNINSTALL=1 或显式同意)
    if [[ "${DS4_FORCE_UNINSTALL:-0}" != "1" ]]; then
        local size_hint=""
        size_hint=$(du -sh "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')
        log_warn "将永久删除: $INSTALL_DIR ${size_hint:+(占用 $size_hint)}"
        if [[ -L "$INSTALL_DIR/gguf" ]]; then
            local gguf_target
            gguf_target=$(readlink "$INSTALL_DIR/gguf")
            log_warn "注意: $INSTALL_DIR/gguf 是软链接 -> $gguf_target"
            log_warn "      仅删除链接本身，外置盘上的模型文件不会被清理"
            log_info "      若需同时清理外置盘模型，请手动执行: rm -rf '$gguf_target'"
        fi
        if ! ask_yes_no "确认卸载？此操作不可恢复" "n" 15; then
            log_info "已取消卸载。"
            return 0
        fi
    fi

    rm -rf "$INSTALL_DIR"
    log_info "已删除 $INSTALL_DIR"
}

# ── 状态/版本 ──
status() {
    if [[ -x "$INSTALL_DIR/ds4" ]]; then
        cd "$INSTALL_DIR"
        ensure_default_model_link || true
        local commit
        commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "DS4 已安装 (Commit: $commit)"
        echo "模型信息: $(model_info_summary)"
        echo "上下文窗口: $((DS4_CONTEXT_WINDOW / 1024))K tokens"
        if [[ -L "$INSTALL_DIR/gguf" ]]; then
            echo "模型下载目录: $INSTALL_DIR/gguf -> $(readlink "$INSTALL_DIR/gguf")"
        else
            echo "模型下载目录: $INSTALL_DIR/gguf"
        fi
        if [[ -L "$DEFAULT_MODEL_FILE" ]]; then
            echo "默认模型: $DEFAULT_MODEL_FILE -> $(readlink "$DEFAULT_MODEL_FILE")"
        elif [[ -e "$DEFAULT_MODEL_FILE" ]]; then
            echo "默认模型: $DEFAULT_MODEL_FILE"
        else
            echo "默认模型: 未就绪"
        fi
        if ls gguf/*.gguf >/dev/null 2>&1; then
            ls -lh gguf/*.gguf
        else
            echo "未发现下载好的模型文件，推荐: $0 download q2-imatrix"
        fi
        if find_ds4_server_pid >/dev/null 2>&1; then
            echo "ds4-server: 运行中"
            local api_base
            api_base=$(ds4_local_api_base || true)
            if [[ -n "$api_base" ]]; then
                echo "API: 可用 (${api_base})"
            else
                echo "API: 暂不可用，候选端口: $(ds4_candidate_ports | tr '\n' ',' | sed 's/,$//')"
            fi
        else
            echo "ds4-server: 未运行"
        fi
    else
        echo "未安装"
        return 1
    fi
}

version() {
    status
}

# ── 命令入口 ──
usage() {
    cat <<EOF
用法:
  $0                                 自动执行默认流程
  $0 [命令] [参数...]
  $0 [短参数]

常用命令:
  bootstrap [-t q2-imatrix|q4-imatrix]   一键安装、下载模型并冒烟测试
  install                                安装/更新并编译 DS4
  download [-t q2-imatrix|q4-imatrix]    下载模型；未指定时交互选择
  use [-t q2-imatrix|q4-imatrix]         切换模型；未指定时交互选择
  models                                 列出已安装模型
  status                                 查看安装、模型和服务状态
  discover                               自动发现 DS4 API 与客户端
  configure-clients [-a url|-H host]     自动发现本机/局域网 DS4 并写入客户端配置
  client-guide [-a url] [-k api_key]     只输出客户端配置指南
  doctor                                 诊断 DS4/API/客户端配置
  smoke-test                             CLI/API 冒烟测试
  server-bg                              后台启动 ds4-server
  stop                                   停止 ds4-server
  start [args...]                        前台启动 ./ds4
  server [args...]                       前台启动 ./ds4-server
  bench [args...]                        前台启动 ./ds4-bench
  uninstall                              删除 $INSTALL_DIR

无参数默认流程:
  自动安装（硬件不满足时仅跳过本机安装） -> 列出模型 ->
  本机可用时交互选择/下载/切换模型并启动服务 ->
  询问服务端口(默认 8000) -> 探测同网段 DS4 API ->
  输出发现摘要 -> 询问是否写入客户端配置 -> 自动诊断

短参数:
  -h, --help                             显示帮助
  -i, --interactive                      打开交互菜单
  -s, --status                           等同 status
  -m, --models                           等同 models
  -d, --discover                         等同 discover
  -c, --configure                        等同 configure-clients
  -g, --guide                            等同 client-guide
  -b, --server-bg                        等同 server-bg
  -x, --stop                             等同 stop

参数选项:
  -t, --type, --model <type>             模型类型: q2-imatrix 或 q4-imatrix
  -a, --api-base, --base-url <url>       DS4 OpenAI-compatible API 地址
  -k, --api-key <key>                    客户端配置指南使用的 API Key
  -H, --host <host>                      DS4 远端主机，供 configure-clients 探测
  -p, --port <port>                      DS4 发现端口，默认 8000
  --no-scan                              configure-clients 禁用网段扫描

示例:
  $0
  $0 -i
  $0 -m
  $0 download -t q2-imatrix
  $0 -c -a http://192.168.1.20:8000/v1
  $0 -g -a http://192.168.1.20:8000/v1 -k sk-ds4-local-host

推荐: Mac Studio M4 Max 128G 优先使用 q2-imatrix；q4-imatrix 需要更多内存余量。
EOF
}

interactive_menu() {
    if [[ ! -t 0 ]]; then
        usage
        return 0
    fi

    while true; do
        echo ""
        echo "========================================"
        echo "  DS4 管理菜单"
        echo "========================================"
        echo "  1) 状态"
        echo "  2) 已安装模型"
        echo "  3) 自动发现"
        echo "  4) 配置客户端"
        echo "  5) 客户端配置指南"
        echo "  6) 下载模型"
        echo "  7) 切换模型"
        echo "  8) 后台启动服务"
        echo "  9) 停止服务"
        echo " 10) 诊断"
        echo " 11) 一键安装"
        echo "  0) 退出"
        echo "========================================"
        local choice
        read -r -p "请选择 [0-11]: " choice
        case "$choice" in
            1) status || true ;;
            2) list_models ;;
            3) discover ;;
            4) configure_clients ;;
            5) client_guide ;;
            6)
                local model_type
                model_type=$(select_model_type "选择要下载的模型") || continue
                download_model "$model_type"
                ;;
            7) use_model ;;
            8) start_server_background ;;
            9) stop_server ;;
            10) doctor || true ;;
            11) bootstrap ;;
            0|q|Q) return 0 ;;
            *) log_warn "无效选择: $choice" ;;
        esac
    done
}

default_workflow() {
    local local_ready=true mem_gb min_mem_gb

    echo "========================================"
    echo "  DS4 默认流程"
    echo "========================================"

    if [[ -x "$INSTALL_DIR/ds4" && -x "$INSTALL_DIR/ds4-server" ]]; then
        log_info "DS4 已安装，跳过安装。"
    elif ! check_hardware 1; then
        local_ready=false
        mem_gb=$(get_memory_gb)
        min_mem_gb="${DS4_MIN_MEMORY_GB:-96}"
        log_warn "本机内存 ${mem_gb}GB < ${min_mem_gb}GB，跳过本机安装/下载/启动。"
        log_info "客户端模式：继续发现局域网 DS4 API。"
    else
        log_info "硬件满足要求，DS4 未安装或编译不完整，开始安装。"
        if ! DS4_HARDWARE_PRECHECKED=1 install; then
            local_ready=false
            log_warn "已跳过本机安装，继续执行客户端侧发现与配置流程。"
        fi
    fi

    if [[ "$local_ready" == true ]]; then
        list_models
    fi

    if [[ "$local_ready" == true ]]; then
        ensure_model_ready_interactive || {
            log_warn "未选择模型，跳过本机模型切换/下载/启动。"
            local_ready=false
        }
    fi

    if [[ "$local_ready" == true ]]; then
        start_server_background
    fi

    echo ""
    if [[ "$local_ready" == true ]]; then
        log_info "检测本机 DS4 API:"
        prepare_server_discovery
        DS4_SERVER_ONLY=1 discover_brief
    else
        log_info "自动发现 DS4 API:"
        prepare_default_discovery
        DS4_DISCOVER_BRIEF_MINIMAL=1 discover_brief
    fi

    if [[ "$local_ready" == true ]]; then
        local server_client_api_base
        server_client_api_base="${DS4_SERVER_LAN_API_BASE:-$(ds4_preferred_client_api_base)}"
        if [[ "${DS4_SERVER_LAN_API_READY:-0}" == "1" ]]; then
            log_info "服务端模式：跳过客户端配置写入。客户端机器可执行: $0 configure-clients -a ${server_client_api_base}"
        else
            log_info "服务端模式：跳过客户端配置写入。请先让 ds4-server 监听局域网地址后再配置客户端。"
        fi
    else
        local config_default="n"
        [[ "${DS4_DEFAULT_DISCOVERY_FOUND:-0}" == "1" ]] && config_default="y"

        if [[ -t 0 ]] && ask_yes_no "是否根据发现结果写入客户端配置" "$config_default" 15; then
            configure_clients
        else
            log_info "跳过客户端配置写入。需要时可执行: $0 configure-clients"
        fi
    fi

    echo ""
    log_info "自动诊断:"
    if [[ "$local_ready" == true ]]; then
        DS4_SERVER_ONLY=1 DS4_DOCTOR_BRIEF=1 doctor || true
    else
        DS4_CLIENT_ONLY=1 DS4_DOCTOR_BRIEF=1 DS4_DOCTOR_CLIENT_MINIMAL=1 doctor || true
    fi
}

dispatch_command() {
    local cmd="$1"
    shift || true

    case "$cmd" in
        -h|--help|help) usage ;;
        -i|--interactive|menu) interactive_menu ;;
        -s|--status|status) status ;;
        -m|--models|models) list_models ;;
        -d|--discover|discover) discover ;;
        -c|--configure|configure-clients|config-clients) configure_clients_from_args "$@" ;;
        -g|--guide|client-guide|guide|config-guide) client_guide_from_args "$@" ;;
        -b|--server-bg|server-bg) start_server_background ;;
        -x|--stop|stop) stop_server ;;
        -v|--version|version) version ;;
        install) install ;;
        uninstall) uninstall ;;
        bootstrap)
            local model_type
            model_type=$(model_arg_from_options "$@") || exit 1
            if [[ -n "$model_type" ]]; then
                bootstrap "$model_type"
            else
                bootstrap
            fi
            ;;
        download)
            local model_type
            model_type=$(model_arg_from_options "$@") || exit 1
            if [[ -z "$model_type" ]]; then
                model_type=$(select_model_type "选择要下载的模型") || exit 1
            fi
            download_model "$model_type"
            ;;
        use)
            local model_type
            model_type=$(model_arg_from_options "$@") || exit 1
            if [[ -n "$model_type" ]]; then
                use_model "$model_type"
            else
                use_model
            fi
            ;;
        doctor) doctor ;;
        smoke-test) smoke_test ;;
        start) start_cli "$@" ;;
        server) start_server "$@" ;;
        bench) bench "$@" ;;
        "")
            interactive_menu
            ;;
        *)
            log_error "未知命令或参数: $cmd"
            usage
            exit 1
            ;;
    esac
}

main() {
    if [[ "$#" -eq 0 ]]; then
        default_workflow
        return
    fi
    dispatch_command "$@"
}

main "$@"

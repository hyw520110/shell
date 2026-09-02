#!/bin/bash

# proxy-speed.sh - proxy node latency and download benchmark
# Usage:
#   ./proxy-speed.sh
#   ./proxy-speed.sh 127.0.0.1 7890
#   ./proxy-speed.sh --sources all
#   ./proxy-speed.sh --clash-benchmark "香港节点-02,新加坡节点-02"
#   DOWNLOAD_TIMEOUT=90 MIN_DOWNLOAD_MB=5 MAX_VALID_RESULTS=3 ./proxy-speed.sh

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; GRAY=$'\033[0;90m'
BOLD=$'\033[1m'; NC=$'\033[0m'

info()    { echo -e "${BLUE}[信息]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*" >&2; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-7890}"
CLASH_API="${CLASH_API:-http://127.0.0.1:9090}"
CLASH_GROUP="${CLASH_GROUP:-节点选择}"
CLASH_CONFIG_FILE="${CLASH_CONFIG_FILE:-}"
SOURCE_PROFILE="${SOURCE_PROFILE:-ap}"
CLASH_BENCHMARK_NODES=""
CHECK_CONFIG=0
RECOMMEND_FASTEST=0
REMOVE_INVALID=0
REMOVE_INVALID_FILTER=""
INVALID_TIMEOUT="${INVALID_TIMEOUT:-3}"

LATENCY_SAMPLES="${LATENCY_SAMPLES:-5}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-60}"
MIN_DOWNLOAD_MB="${MIN_DOWNLOAD_MB:-5}"
MAX_VALID_RESULTS="${MAX_VALID_RESULTS:-3}"
MIN_DOWNLOAD_BYTES=$(python3 -c "print(int(float('${MIN_DOWNLOAD_MB}') * 1024 * 1024))" 2>/dev/null || echo 5242880)

DELAY_TEST_URLS=(
    "http://www.gstatic.com/generate_204"
    "http://cp.cloudflare.com/generate_204"
    "http://www.google.com/robots.txt"
    "http://www.apple.com"
)

URLS_SG=(
    "https://sgp-ping.vultr.com/vultr.com.100MB.bin"
    "http://speedtest.singapore.linode.com/100MB-singapore.bin"
    "http://speedtest-sgp1.digitalocean.com/100mb.test"
)

URLS_HK=(
    "https://hkg-ping.vultr.com/vultr.com.100MB.bin"
    "http://speedtest.hkg12.moack.co.kr/100MB.bin"
)

URLS_AP=(
    "${URLS_HK[@]}"
    "${URLS_SG[@]}"
    "https://tyo1-speedtest.12global.com/100MB.test"
    "http://speedtest.tokyo.linode.com/100MB-tokyo.bin"
)

URLS_GLOBAL=(
    "https://proof.ovh.net/files/100Mb.dat"
    "http://speedtest.tele2.net/100MB.zip"
    "https://proof.ovh.net/files/10Mb.dat"
)

show_help() {
    cat <<EOF
Usage: $(basename "$0") [proxy-host] [proxy-port] [options]

Options:
  --sources ap|sg|hk|global|all   Test source profile. Default: ap
  --clash-benchmark A,B,C         Switch Clash group and benchmark listed nodes
  --clash-group NAME              Clash selector group. Default: 节点选择
  --clash-api URL                 Clash API URL. Default: http://127.0.0.1:9090
  --clash-file FILE               Clash.Meta YAML path. Auto-detected if omitted
  --check-config                  Check node syntax and server:port reachability
  --recommend-fastest             Benchmark Clash nodes and recommend fastest usable node
  --remove-invalid [A,B,C]        Re-check unreachable/listed nodes, then interactively confirm removal
  --help                          Show help

Environment:
  DOWNLOAD_TIMEOUT=60
  MIN_DOWNLOAD_MB=5
  MAX_VALID_RESULTS=3
  LATENCY_SAMPLES=5
  INVALID_TIMEOUT=3
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sources) SOURCE_PROFILE="$2"; shift 2 ;;
        --clash-benchmark) CLASH_BENCHMARK_NODES="$2"; shift 2 ;;
        --clash-group) CLASH_GROUP="$2"; shift 2 ;;
        --clash-api) CLASH_API="$2"; shift 2 ;;
        --clash-file|--config) CLASH_CONFIG_FILE="$2"; shift 2 ;;
        --check-config) CHECK_CONFIG=1; shift ;;
        --recommend-fastest) RECOMMEND_FASTEST=1; shift ;;
        --remove-invalid)
            REMOVE_INVALID=1
            CHECK_CONFIG=1
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                REMOVE_INVALID_FILTER="$2"
                shift 2
            else
                shift
            fi
            ;;
        --help|-h) show_help; exit 0 ;;
        -*)
            error "未知参数: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ "$PROXY_HOST" == "127.0.0.1" && -z "${_HOST_SET:-}" ]]; then
                PROXY_HOST="$1"; _HOST_SET=1
            elif [[ "$PROXY_PORT" == "7890" && -z "${_PORT_SET:-}" ]]; then
                PROXY_PORT="$1"; _PORT_SET=1
            else
                error "未知位置参数: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

build_test_urls() {
    TEST_URLS=()
    case "$SOURCE_PROFILE" in
        sg) TEST_URLS=("${URLS_SG[@]}" "${URLS_GLOBAL[@]}") ;;
        hk) TEST_URLS=("${URLS_HK[@]}" "${URLS_GLOBAL[@]}") ;;
        global) TEST_URLS=("${URLS_GLOBAL[@]}") ;;
        all) TEST_URLS=("${URLS_AP[@]}" "${URLS_GLOBAL[@]}") ;;
        ap|*) TEST_URLS=("${URLS_AP[@]}" "${URLS_GLOBAL[@]}") ;;
    esac
}

check_proxy_alive() {
    local host=$1 port=$2
    python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(('${host}', ${port}))
    s.close()
    print('OK')
except Exception:
    print('FAIL')
" 2>/dev/null
}

test_latency_direct() {
    curl -s --noproxy '*' --max-time 10 -o /dev/null -w '%{time_total}' "$1" 2>/dev/null
}

test_latency_proxy() {
    curl -s --max-time 10 -o /dev/null -w '%{time_total}' --proxy "http://${2}:${3}" "$1" 2>/dev/null
}

grade_speed_mbps() {
    local mbps=$1
    python3 -c "
mbps = float('${mbps}')
if mbps >= 100: print(f'极快 {mbps:.0f} Mbps - 4K流媒体、大文件下载无压力')
elif mbps >= 50: print(f'良好 {mbps:.0f} Mbps - 1080p多路串流、日常办公足够')
elif mbps >= 20: print(f'一般 {mbps:.0f} Mbps - 720p/1080p视频、一般浏览可用')
elif mbps >= 5: print(f'偏慢 {mbps:.0f} Mbps - 仅适合网页/音频，高清视频易缓冲')
else: print(f'很慢 {mbps:.2f} Mbps - 网页加载慢，建议检查链路')
" 2>/dev/null || echo "${mbps} Mbps"
}

grade_latency_ms() {
    local ms=$1
    python3 -c "
ms = float('${ms}')
if ms < 30: print(f'{ms:.0f}ms - 优秀')
elif ms < 80: print(f'{ms:.0f}ms - 良好')
elif ms < 150: print(f'{ms:.0f}ms - 一般')
else: print(f'{ms:.0f}ms - 偏高')
" 2>/dev/null || echo "${ms}ms"
}

_num_gt() {
    python3 -c "exit(0 if float('$1') > float('$2') else 1)" 2>/dev/null
}

_fmt_mbps() {
    python3 -c "print(f'{float(\"$1\") * 8 / 1_000_000:.2f}')" 2>/dev/null || echo "0.00"
}

_fmt_mb() {
    python3 -c "print(f'{float(\"$1\") / 1024 / 1024:.2f}')" 2>/dev/null || echo "0.00"
}

_parse_curl_metric() {
    python3 -c "
import sys
data = sys.argv[1]
key = sys.argv[2] + ':'
for item in data.split('|'):
    if item.startswith(key):
        print(item.split(':', 1)[1])
        break
" "$1" "$2" 2>/dev/null
}

summarize_download_results() {
    python3 - "$@" <<'PY'
import statistics
import sys
rows = []
for raw in sys.argv[1:]:
    url, mbps, size_mb, seconds = raw.split("|", 3)
    rows.append((url, float(mbps), float(size_mb), float(seconds)))
if not rows:
    raise SystemExit(1)
best = max(rows, key=lambda x: x[1])
speeds = [row[1] for row in rows]
print(f"best_url={best[0]}")
print(f"best_mbps={best[1]:.2f}")
print(f"best_size_mb={best[2]:.2f}")
print(f"best_time={best[3]:.2f}")
print(f"median_mbps={statistics.median(speeds):.2f}")
print(f"valid_count={len(rows)}")
PY
}

run_latency_test() {
    local delay_url="" result direct_time proxy_time direct_ms proxy_ms direct_avg proxy_avg overhead
    for url in "${DELAY_TEST_URLS[@]}"; do
        result=$(test_latency_proxy "$url" "$PROXY_HOST" "$PROXY_PORT")
        if [[ -n "$result" ]]; then delay_url="$url"; break; fi
    done
    if [[ -z "$delay_url" ]]; then
        warn "无法找到可用的延迟测试URL，跳过延迟测试"
        LATENCY_RESULT="0"
        return 0
    fi

    direct_samples=()
    proxy_samples=()
    for i in $(seq 1 "$LATENCY_SAMPLES"); do
        direct_ms=""
        proxy_ms=""
        direct_time=$(test_latency_direct "$delay_url")
        proxy_time=$(test_latency_proxy "$delay_url" "$PROXY_HOST" "$PROXY_PORT")
        if [[ -n "$direct_time" ]]; then
            direct_ms=$(python3 -c "print(f'{float(\"$direct_time\") * 1000:.0f}')")
            direct_samples+=("$direct_ms")
        fi
        if [[ -n "$proxy_time" ]]; then
            proxy_ms=$(python3 -c "print(f'{float(\"$proxy_time\") * 1000:.0f}')")
            proxy_samples+=("$proxy_ms")
        fi
        [[ "$QUIET_NODE" != "1" ]] && printf "   样本 %d: 直连 %sms | 代理 %sms\n" "$i" "${direct_ms:--}" "${proxy_ms:--}"
    done

    if [[ ${#direct_samples[@]} -gt 0 ]]; then
        direct_avg=$(python3 -c "nums=[int(x) for x in '${direct_samples[*]}'.split()]; print(f'{sum(nums)/len(nums):.0f}')")
    fi
    if [[ ${#proxy_samples[@]} -gt 0 ]]; then
        proxy_avg=$(python3 -c "nums=[int(x) for x in '${proxy_samples[*]}'.split()]; print(f'{sum(nums)/len(nums):.0f}')")
    fi
    LATENCY_RESULT="${proxy_avg:-0}"

    if [[ "$QUIET_NODE" != "1" ]]; then
        echo ""
        echo "   ${BOLD}直连延迟:${NC} $(grade_latency_ms "${direct_avg:-0}")"
        echo "   ${BOLD}代理延迟:${NC} $(grade_latency_ms "${proxy_avg:-0}")"
        if [[ -n "$direct_avg" && -n "$proxy_avg" ]]; then
            overhead=$(python3 -c "print(f'{max(0, $proxy_avg - $direct_avg):.0f}')")
            echo "   ${BOLD}额外开销:${NC} ${overhead}ms"
        fi
    fi
}

run_download_test() {
    build_test_urls
    best_mbps=0
    best_url=""
    valid_results=()

    for url in "${TEST_URLS[@]}"; do
        [[ "$QUIET_NODE" != "1" ]] && printf "   测试: %-45s " "${url:0:45}"
        result=$(curl -s --max-time "$DOWNLOAD_TIMEOUT" --proxy "http://${PROXY_HOST}:${PROXY_PORT}" \
            -o /dev/null -w 'speed_download:%{speed_download}|size_download:%{size_download}|time_total:%{time_total}|http_code:%{http_code}' \
            "$url" 2>&1)

        http_code=$(_parse_curl_metric "$result" "http_code")
        speed_bytes=$(_parse_curl_metric "$result" "speed_download")
        size_bytes=$(_parse_curl_metric "$result" "size_download")
        time_total=$(_parse_curl_metric "$result" "time_total")

        if [[ "$http_code" =~ ^(200|206)$ && -n "$speed_bytes" && -n "$size_bytes" && "$speed_bytes" != "0.000" ]] \
            && python3 -c "exit(0 if float('${size_bytes}') >= float('${MIN_DOWNLOAD_BYTES}') else 1)" 2>/dev/null; then
            mbps=$(_fmt_mbps "$speed_bytes")
            size_mb=$(_fmt_mb "$size_bytes")
            [[ "$QUIET_NODE" != "1" ]] && printf "${GREEN}%s Mbps${NC}  (%s MB / %.2fs)\n" "$mbps" "$size_mb" "$time_total"
            if _num_gt "$mbps" "$best_mbps"; then
                best_mbps="$mbps"
                best_url="$url"
            fi
            valid_results+=("${url}|${mbps}|${size_mb}|${time_total}")
            [[ ${#valid_results[@]} -ge "$MAX_VALID_RESULTS" ]] && break
        else
            size_mb=$(_fmt_mb "${size_bytes:-0}")
            if [[ "$QUIET_NODE" != "1" ]]; then
                if [[ "$http_code" =~ ^(200|206)$ ]]; then
                    printf "${YELLOW}跳过${NC} (仅下载 %s MB，低于 %s MB)\n" "$size_mb" "$MIN_DOWNLOAD_MB"
                else
                    printf "${RED}失败${NC} (HTTP ${http_code:-未知}, ${size_mb} MB)\n"
                fi
            fi
        fi
    done

    if [[ ${#valid_results[@]} -gt 0 ]]; then
        summary=$(summarize_download_results "${valid_results[@]}")
        BEST_URL=$(echo "$summary" | awk -F= '/^best_url=/{print $2}')
        BEST_MBPS=$(echo "$summary" | awk -F= '/^best_mbps=/{print $2}')
        BEST_SIZE_MB=$(echo "$summary" | awk -F= '/^best_size_mb=/{print $2}')
        BEST_TIME=$(echo "$summary" | awk -F= '/^best_time=/{print $2}')
        MEDIAN_MBPS=$(echo "$summary" | awk -F= '/^median_mbps=/{print $2}')
        VALID_COUNT=$(echo "$summary" | awk -F= '/^valid_count=/{print $2}')
        return 0
    fi

    BEST_URL=""
    BEST_MBPS="0"
    BEST_SIZE_MB="0"
    BEST_TIME="0"
    MEDIAN_MBPS="0"
    VALID_COUNT="0"
    return 1
}

print_single_summary() {
    if [[ "$VALID_COUNT" != "0" ]]; then
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  ${BOLD}测速结果汇总${NC}                                                ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║  源 profile: ${SOURCE_PROFILE}"
        echo "║  有效测试源: ${VALID_COUNT}"
        echo "║  最佳测试URL: ${BEST_URL:0:51}"
        echo "║  最佳样本: ${BEST_SIZE_MB} MB / ${BEST_TIME}s"
        echo "║  最佳速度: $(grade_speed_mbps "$BEST_MBPS")"
        echo "║  中位速度: ${MEDIAN_MBPS} Mbps"
        echo "║  速度换算: ${BEST_MBPS} Mbps ≈ $(python3 -c "print(f'{float(\"$BEST_MBPS\") * 1024 / 8:.0f}')") KB/s"
        echo "╚══════════════════════════════════════════════════════════════╝"
    else
        error "所有测试URL均失败或返回过小，无法判断真实下载速度"
    fi
}

run_single_benchmark() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          代理节点速度测试工具  proxy-speed.sh                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "代理地址: ${CYAN}${PROXY_HOST}:${PROXY_PORT}${NC}"
    echo "源 profile: ${CYAN}${SOURCE_PROFILE}${NC}"
    echo ""

    info "步骤1/3: 检查代理连通性..."
    proxy_status=$(check_proxy_alive "$PROXY_HOST" "$PROXY_PORT")
    if [[ "$proxy_status" == "FAIL" ]]; then
        error "代理端口 ${PROXY_HOST}:${PROXY_PORT} 无法连接"
        exit 1
    fi
    success "代理连通正常"

    echo ""
    info "步骤2/3: 延迟测试（${LATENCY_SAMPLES} 次采样）..."
    run_latency_test

    echo ""
    info "步骤3/3: 下载速度测试（最长 ${DOWNLOAD_TIMEOUT} 秒）..."
    echo "   规则: 小于 ${MIN_DOWNLOAD_MB}MB 的响应视为无效"
    echo ""
    run_download_test || true
    echo ""
    print_single_summary
}

urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

clash_get_group_now() {
    local encoded
    encoded=$(urlencode "$CLASH_GROUP")
    curl -s --max-time 3 "${CLASH_API}/proxies/${encoded}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('now',''))" 2>/dev/null
}

clash_set_group() {
    local encoded payload
    encoded=$(urlencode "$CLASH_GROUP")
    payload=$(python3 -c "import json,sys; print(json.dumps({'name': sys.argv[1]}, ensure_ascii=False))" "$1")
    curl -s --max-time 5 -X PUT "${CLASH_API}/proxies/${encoded}" -H "Content-Type: application/json" -d "$payload" >/dev/null
}

clash_api_available() {
    curl -s --max-time 2 "${CLASH_API}/version" >/dev/null 2>&1 || curl -s --max-time 2 "${CLASH_API}/proxies" >/dev/null 2>&1
}

clash_node_delay_ms() {
    local node="$1" encoded
    encoded=$(urlencode "$node")
    curl -s --max-time 8 "${CLASH_API}/proxies/${encoded}/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" |
        python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('delay',''))" 2>/dev/null
}

find_clash_config_file() {
    local home_dir="${HOME:-}"
    local candidates=(
        "$home_dir/.config/clash.meta/yuanhang.yaml"
        "$home_dir/.config/clash.meta/config.yaml"
        "$home_dir/.config/clash/config.yaml"
    )
    local file
    for file in "${candidates[@]}"; do
        [[ -f "$file" ]] && { echo "$file"; return 0; }
    done
    for file in "$home_dir"/.config/clash.meta/*.yaml "$home_dir"/.config/clash/*.yaml; do
        [[ -f "$file" ]] && { echo "$file"; return 0; }
    done
    return 1
}

ensure_clash_config_file() {
    if [[ -z "$CLASH_CONFIG_FILE" ]]; then
        CLASH_CONFIG_FILE="$(find_clash_config_file || true)"
    fi
    if [[ -z "$CLASH_CONFIG_FILE" || ! -f "$CLASH_CONFIG_FILE" ]]; then
        error "未找到 Clash.Meta 配置文件，请用 --clash-file 指定"
        return 1
    fi
}

extract_clash_nodes() {
    ensure_clash_config_file || return 1
    CLASH_CONFIG_FILE="$CLASH_CONFIG_FILE" python3 - <<'PY'
import re
import os
from pathlib import Path

path = Path(os.environ["CLASH_CONFIG_FILE"]).expanduser()
lines = path.read_text().splitlines()
try:
    start = next(i for i, line in enumerate(lines) if line.strip() == "proxies:") + 1
except StopIteration:
    raise SystemExit(0)
end = next((i for i in range(start, len(lines)) if re.match(r'^[A-Za-z0-9_-]+:', lines[i])), len(lines))
entries = []
cur = []
for line in lines[start:end]:
    if re.match(r'\s*-\s+name:', line):
        if cur:
            entries.append(cur)
        cur = [line]
    elif cur:
        cur.append(line)
if cur:
    entries.append(cur)

def val(entry, key):
    for line in entry:
        m = re.match(rf'\s*{re.escape(key)}:\s*["\']?(.+?)["\']?\s*$', line)
        if m:
            return m.group(1)
    return ""

for entry in entries:
    name = val(entry, "- name")
    if not name:
        m = re.match(r'\s*-\s+name:\s*["\']?(.+?)["\']?\s*$', entry[0])
        name = m.group(1) if m else ""
    server = val(entry, "server")
    port = val(entry, "port")
    ptype = val(entry, "type")
    if name and server and port:
        print("|".join([name, server, port, ptype]))
PY
}

trim_text() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

name_in_csv_filter() {
    local name="$1" filter="$2" item
    [[ -n "$filter" ]] || return 0
    IFS=',' read -r -a _filter_items <<< "$filter"
    for item in "${_filter_items[@]}"; do
        item="$(trim_text "$item")"
        [[ "$item" == "$name" ]] && return 0
    done
    return 1
}

probe_clash_node() {
    local name="$1" server="$2" port="$3" use_clash_api="$4" delay_ms
    if [[ "$use_clash_api" == "1" ]]; then
        delay_ms=$(clash_node_delay_ms "$name")
        if [[ "$delay_ms" =~ ^[0-9]+$ ]]; then
            NODE_PROBE_STATUS="${GREEN}可用 ${delay_ms}ms${NC}"
            NODE_PROBE_PLAIN="可用 ${delay_ms}ms"
            return 0
        fi
        NODE_PROBE_STATUS="${RED}失效/不可用${NC}"
        NODE_PROBE_PLAIN="失效/不可用"
        return 1
    fi

    if python3 - "$server" "$port" "$INVALID_TIMEOUT" <<'PY' >/dev/null 2>&1
import socket
import sys
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    s.connect((host, port))
finally:
    s.close()
PY
    then
        NODE_PROBE_STATUS="${GREEN}可达${NC}"
        NODE_PROBE_PLAIN="可达"
        return 0
    fi
    NODE_PROBE_STATUS="${RED}失效/不可达${NC}"
    NODE_PROBE_PLAIN="失效/不可达"
    return 1
}

remove_invalid_interactive() {
    local use_clash_api="$1"
    shift
    local rows=("$@")
    [[ ${#rows[@]} -gt 0 ]] || { warn "没有需要二次确认的候选节点"; return 0; }

    local names=() servers=() ports=() ptypes=() first_status=() second_status=() selected=()
    local row name server port ptype status_plain i key cursor=0 selected_names=()

    echo ""
    info "对候选节点执行二次检测，二次仍失败的节点会默认勾选"
    for row in "${rows[@]}"; do
        IFS='|' read -r name server port ptype status_plain <<< "$row"
        names+=("$name")
        servers+=("$server")
        ports+=("$port")
        ptypes+=("$ptype")
        first_status+=("$status_plain")
        if probe_clash_node "$name" "$server" "$port" "$use_clash_api"; then
            second_status+=("$NODE_PROBE_PLAIN")
            selected+=(0)
        else
            second_status+=("$NODE_PROBE_PLAIN")
            selected+=(1)
        fi
    done

    if [[ ! -t 0 ]]; then
        warn "当前不是交互终端，已跳过删除；请在终端中重新执行 --remove-invalid"
        return 0
    fi

    render_remove_menu() {
        printf '\033[H\033[J'
        echo "Clash.Meta 失效节点删除确认"
        echo ""
        echo "操作: ↑/↓ 移动，空格勾选/取消，回车删除当前勾选，a 全选，n 全不选，q 取消"
        echo ""
        printf "%-4s %-5s %-24s %-20s %-8s %-16s %-16s\n" "编号" "选择" "节点" "服务器" "端口" "首次检测" "二次检测"
        for i in "${!names[@]}"; do
            local pointer=" "
            [[ "$i" -eq "$cursor" ]] && pointer=">"
            if [[ "${selected[$i]}" == "1" ]]; then
                printf "%-4s %-5s %-24s %-20s %-8s %-16s %-16s\n" "${pointer}$((i + 1))" "[x]" "${names[$i]}" "${servers[$i]}" "${ports[$i]}" "${first_status[$i]}" "${second_status[$i]}"
            else
                printf "%-4s %-5s %-24s %-20s %-8s %-16s %-16s\n" "${pointer}$((i + 1))" "[ ]" "${names[$i]}" "${servers[$i]}" "${ports[$i]}" "${first_status[$i]}" "${second_status[$i]}"
            fi
        done
        echo ""
    }

    while true; do
        render_remove_menu
        IFS= read -rsn1 key || return 0
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 key || key=""
                case "$key" in
                    "[A") (( cursor > 0 )) && cursor=$((cursor - 1)) ;;
                    "[B") (( cursor < ${#names[@]} - 1 )) && cursor=$((cursor + 1)) ;;
                esac
                ;;
            " ")
                if [[ "${selected[$cursor]}" == "1" ]]; then
                    selected[$cursor]=0
                else
                    selected[$cursor]=1
                fi
                ;;
            "")
                break
                ;;
            q|Q)
                printf '\033[H\033[J'
                warn "已取消删除"
                return 0
                ;;
            a|A)
                for i in "${!selected[@]}"; do selected[$i]=1; done
                ;;
            n|N)
                for i in "${!selected[@]}"; do selected[$i]=0; done
                ;;
            $'\r'|$'\n')
                break
                ;;
        esac
    done

    selected_names=()
    for i in "${!names[@]}"; do
        [[ "${selected[$i]}" == "1" ]] && selected_names+=("${names[$i]}")
    done
    if [[ ${#selected_names[@]} -eq 0 ]]; then
        warn "没有勾选任何节点，未删除"
        return 0
    fi
    remove_invalid_nodes_from_config "${selected_names[@]}"
}

check_clash_config() {
    ensure_clash_config_file || return 1
    local use_clash_api=0
    clash_api_available && use_clash_api=1
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          Clash.Meta 配置有效性检查                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "配置文件: ${CLASH_CONFIG_FILE}"
    if [[ "$use_clash_api" == "1" ]]; then
        echo "检测方式: Clash/Mihomo API 节点真实延迟"
    else
        echo "检测方式: server:port TCP 连通性（Clash API 不可用时的保守回退）"
    fi
    echo ""
    printf "%-24s %-22s %-8s %-8s %s\n" "节点" "服务器" "端口" "协议" "状态"

    INVALID_NODES=()
    REMOVE_CANDIDATES=()
    TOTAL_NODES_CHECKED=0
    local row name server port ptype status status_plain
    while IFS='|' read -r name server port ptype; do
        [[ -z "$name" ]] && continue
        TOTAL_NODES_CHECKED=$((TOTAL_NODES_CHECKED + 1))
        if probe_clash_node "$name" "$server" "$port" "$use_clash_api"; then
            status="$NODE_PROBE_STATUS"
            status_plain="$NODE_PROBE_PLAIN"
        else
            status="$NODE_PROBE_STATUS"
            status_plain="$NODE_PROBE_PLAIN"
            INVALID_NODES+=("$name")
        fi
        if [[ "$REMOVE_INVALID" == "1" ]] && name_in_csv_filter "$name" "$REMOVE_INVALID_FILTER"; then
            if [[ -n "$REMOVE_INVALID_FILTER" || "$status_plain" == 失效/* ]]; then
                REMOVE_CANDIDATES+=("${name}|${server}|${port}|${ptype:-?}|${status_plain}")
            fi
        fi
        printf "%-24s %-22s %-8s %-8s %b\n" "$name" "$server" "$port" "${ptype:-?}" "$status"
    done < <(extract_clash_nodes)

    echo ""
    if [[ ${#INVALID_NODES[@]} -eq 0 ]]; then
        success "未发现不可达节点"
    else
        warn "发现 ${#INVALID_NODES[@]} 个不可达节点: ${INVALID_NODES[*]}"
    fi

    if [[ "$REMOVE_INVALID" == "1" ]]; then
        if [[ ${#REMOVE_CANDIDATES[@]} -eq 0 ]]; then
            if [[ -n "$REMOVE_INVALID_FILTER" ]]; then
                warn "指定列表中没有匹配到配置节点: ${REMOVE_INVALID_FILTER}"
            else
                success "没有需要删除确认的失效节点"
            fi
            return 0
        fi
        remove_invalid_interactive "$use_clash_api" "${REMOVE_CANDIDATES[@]}"
    fi
}

remove_invalid_nodes_from_config() {
    ensure_clash_config_file || return 1
    [[ $# -gt 0 ]] || { warn "没有需要删除的失效节点"; return 0; }
    CLASH_CONFIG_FILE="$CLASH_CONFIG_FILE" python3 - "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(os.environ["CLASH_CONFIG_FILE"]).expanduser()
remove = set(sys.argv[1:])
text = path.read_text()
lines = text.splitlines()

def proxy_name(entry):
    m = re.match(r'\s*-\s+name:\s*["\']?(.+?)["\']?\s*$', entry[0])
    return m.group(1) if m else ""

try:
    proxies_i = next(i for i, line in enumerate(lines) if line.strip() == "proxies:")
except StopIteration:
    raise SystemExit("目标配置缺少 proxies: 段")
groups_i = next((i for i in range(proxies_i + 1, len(lines)) if lines[i].strip() == "proxy-groups:"), len(lines))

before = lines[:proxies_i + 1]
block = lines[proxies_i + 1:groups_i]
after = lines[groups_i:]
entries, cur, loose = [], [], []
for line in block:
    if re.match(r'\s*-\s+name:', line):
        if cur:
            entries.append(cur)
        cur = [line]
    elif cur:
        cur.append(line)
    elif line.strip():
        loose.append(line)
if cur:
    entries.append(cur)

kept = [entry for entry in entries if proxy_name(entry) not in remove]
out = before + loose
for entry in kept:
    out.extend(entry)
out.extend(after)

filtered = []
for line in out:
    m = re.match(r'(\s+-\s+)(["\']?)(.+?)(\2)\s*$', line)
    if m and m.group(3) in remove:
        continue
    filtered.append(line)

backup = path.with_suffix(path.suffix + ".bak")
backup.write_text(text)
path.write_text("\n".join(filtered) + "\n")
print(f"removed={','.join(sorted(remove))}")
print(f"backup={backup}")
PY
}

nodes_from_config_csv() {
    extract_clash_nodes | awk -F'|' 'NF && $1 != "" { names = names ? names "," $1 : $1 } END { print names }'
}

run_clash_benchmark() {
    local original_now node old_quiet best_node="" best_score="-1" rows=()
    IFS=',' read -r -a nodes <<< "$CLASH_BENCHMARK_NODES"
    if [[ ${#nodes[@]} -eq 0 || -z "${nodes[0]}" ]]; then
        error "--clash-benchmark 需要节点列表，例如: 香港节点-02,新加坡节点-02"
        exit 1
    fi

    proxy_status=$(check_proxy_alive "$PROXY_HOST" "$PROXY_PORT")
    [[ "$proxy_status" == "OK" ]] || { error "代理端口不可用: ${PROXY_HOST}:${PROXY_PORT}"; exit 1; }

    original_now=$(clash_get_group_now)
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          Clash Meta 节点自动测速                             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "选择组: ${CLASH_GROUP}"
    echo "原节点: ${original_now:-未知}"
    echo "源 profile: ${SOURCE_PROFILE}"
    echo ""
    printf "%-22s %-10s %-10s %-10s %s\n" "节点" "延迟ms" "最佳Mbps" "中位Mbps" "有效源"

    old_quiet="${QUIET_NODE:-}"
    QUIET_NODE=1
    for node in "${nodes[@]}"; do
        node="${node#"${node%%[![:space:]]*}"}"
        node="${node%"${node##*[![:space:]]}"}"
        [[ -z "$node" ]] && continue
        clash_set_group "$node"
        sleep 1
        run_latency_test
        run_download_test || true
        printf "%-22s %-10s %-10s %-10s %s\n" "$node" "${LATENCY_RESULT:-0}" "${BEST_MBPS:-0}" "${MEDIAN_MBPS:-0}" "${VALID_COUNT:-0}"
        rows+=("${node}|${LATENCY_RESULT:-0}|${BEST_MBPS:-0}|${MEDIAN_MBPS:-0}|${VALID_COUNT:-0}")
        if python3 - "${BEST_MBPS:-0}" "${VALID_COUNT:-0}" "$best_score" <<'PY' >/dev/null 2>&1
import sys
mbps = float(sys.argv[1])
valid = int(float(sys.argv[2]))
best = float(sys.argv[3])
score = mbps if valid > 0 else -1
raise SystemExit(0 if score > best else 1)
PY
        then
            best_node="$node"
            best_score="${BEST_MBPS:-0}"
        fi
    done
    QUIET_NODE="$old_quiet"

    if [[ -n "$original_now" ]]; then
        clash_set_group "$original_now"
        echo ""
        echo "已恢复原节点: ${original_now}"
    fi

    echo ""
    if [[ -n "$best_node" && "$best_score" != "-1" ]]; then
        success "推荐最快可用节点: ${best_node} (${best_score} Mbps)"
    else
        warn "没有测到可推荐的可用节点"
    fi
}

if [[ "$CHECK_CONFIG" == "1" ]]; then
    check_clash_config
    if [[ "$RECOMMEND_FASTEST" != "1" ]]; then
        exit 0
    fi
fi

if [[ "$RECOMMEND_FASTEST" == "1" && -z "$CLASH_BENCHMARK_NODES" ]]; then
    ensure_clash_config_file || exit 1
    CLASH_BENCHMARK_NODES="$(nodes_from_config_csv)"
    if [[ -z "$CLASH_BENCHMARK_NODES" ]]; then
        error "配置文件中未找到可测速节点"
        exit 1
    fi
fi

if [[ -n "$CLASH_BENCHMARK_NODES" ]]; then
    run_clash_benchmark
else
    run_single_benchmark
fi

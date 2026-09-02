#!/usr/bin/env bash
# Katana 安装、版本检查和授权目标爬取辅助脚本。
# 运行产物默认写入仓库外的 ~/security-scans/katana。

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${HOME}/Downloads}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${HOME}/security-scans/katana}"
RELEASE_API="${RELEASE_API:-https://api.github.com/repos/projectdiscovery/katana/releases/latest}"
DEFAULT_DEPTH="${KATANA_DEPTH:-3}"
DEFAULT_RATE_LIMIT="${KATANA_RATE_LIMIT:-20}"
DEFAULT_CONCURRENCY="${KATANA_CONCURRENCY:-10}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf '[katana] %s\n' "$*"; }
ok()   { printf "${GREEN}[完成] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[警告] %s${NC}\n" "$*" >&2; }
die()  { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME <命令> [选项]

命令：
  install                    安装 ProjectDiscovery 官方预编译包
  version                    显示 Katana 版本
  crawl                     爬取已授权的 Web 目标（也可省略该命令）

选项：
  -u, --url <URL>            目标 URL（必填）
  -o, --output-dir <目录>    输出目录，默认 ~/security-scans/katana/<主域名>
  -f, --format <格式>        txt、jsonl、both，默认 both
  -d, --depth <数字>         爬取深度，默认 ${DEFAULT_DEPTH}
  -r, --rate-limit <数字>    每秒请求上限，默认 ${DEFAULT_RATE_LIMIT}
  -c, --concurrency <数字>   并发数，默认 ${DEFAULT_CONCURRENCY}
      --scope <rdn|fqdn|dn>  范围，默认 rdn
      --headless              启用无头浏览器（更慢、更重）
  -h, --help                 显示帮助

环境变量：INSTALL_DIR、DOWNLOAD_DIR、OUTPUT_ROOT、KATANA_VERSION、
KATANA_DEPTH、KATANA_RATE_LIMIT、KATANA_CONCURRENCY。

示例：
  $SCRIPT_NAME install
  $SCRIPT_NAME -u https://example.com/ -d 2 -r 10 -c 5
  $SCRIPT_NAME crawl --url https://example.com/ --format txt
EOF
}

extract_host() {
  local value="$1"
  value="${value#*://}"; value="${value#*@}"; value="${value%%/*}"
  value="${value%%\?*}"; value="${value%%\#*}"; value="${value%%:*}"
  value="${value%.}"
  printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}

registrable_domain() {
  local host="$1"
  host="${host#www.}"
  case "$host" in
    *.co.uk|*.org.uk|*.ac.uk|*.gov.uk|*.com.cn|*.net.cn|*.org.cn|*.com.au|*.net.au|*.org.au|*.co.jp|*.com.hk|*.com.tw|*.co.kr)
      printf '%s\n' "$host" | awk -F. '{print $(NF-2) "." $(NF-1) "." $NF}' ;;
    *) printf '%s\n' "$host" | awk -F. '{if (NF >= 2) print $(NF-1) "." $NF; else print $NF}' ;;
  esac
}

find_adl() {
  local candidate
  for candidate in "$(command -v adl 2>/dev/null || true)" \
    "$SCRIPT_DIR/../../../network/tools/adl" "/opt/homebrew/bin/adl" \
    "/usr/local/bin/adl" "$HOME/.local/bin/adl"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --help >/dev/null 2>&1; then
      printf '%s\n' "$candidate"; return 0
    fi
  done
  return 1
}

download_file() {
  local url="$1" output="$2" adl_path
  mkdir -p "$(dirname "$output")"
  if adl_path="$(find_adl || true)" && [ -n "$adl_path" ]; then
    log "使用 adl 下载：$(basename "$output")"
    if "$adl_path" "$url" "$(dirname "$output")" "$(basename "$output")" && [ -s "$output" ]; then
      return 0
    fi
    warn 'adl 下载失败，回退到 curl。'
  fi
  has curl || die '需要 curl。'
  curl -fL --progress-bar "$url" -o "$output"
}

latest_asset() {
  local os arch suffix payload asset release_api
  case "$(uname -s)" in Darwin) os='macOS' ;; Linux) os='linux' ;; *) die "不支持的系统：$(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch='amd64' ;; arm64|aarch64) arch='arm64' ;; *) die "不支持的架构：$(uname -m)" ;; esac
  suffix="_${os}_${arch}.zip"
  if [ -n "${KATANA_VERSION:-}" ]; then
    release_api="https://api.github.com/repos/projectdiscovery/katana/releases/tags/v${KATANA_VERSION}"
  else
    release_api="$RELEASE_API"
  fi
  payload="$(curl -fsSL --connect-timeout 10 --max-time 30 "$release_api")" || die '无法读取 Katana 官方发布信息。'
  asset="$(printf '%s' "$payload" | tr ',' '\n' | sed -nE "s/.*\"browser_download_url\"[[:space:]]*:[[:space:]]*\"([^\"]*${suffix})\".*/\1/p" | head -n 1)"
  [ -n "$asset" ] || die "未找到适用于 ${os}/${arch} 的 Katana 官方安装包。"
  printf '%s\n' "$asset"
}

install_binary() {
  local asset zip tmp extracted target
  has curl || die '需要 curl。'
  asset="$(latest_asset)"; zip="${DOWNLOAD_DIR}/${asset##*/}"
  download_file "$asset" "$zip"
  tmp="$(mktemp -d)"
  cleanup() { rm -rf "$tmp"; }
  trap cleanup EXIT
  unzip -q "$zip" -d "$tmp" || die '解压 Katana 安装包失败，请确认已安装 unzip。'
  extracted="$(find "$tmp" -type f -name katana -perm -111 -print -quit)"
  [ -n "$extracted" ] || die '安装包中未找到可执行文件。'
  target="${INSTALL_DIR}/katana"
  if [ -w "$INSTALL_DIR" ]; then cp "$extracted" "$target"; else sudo install -m 0755 "$extracted" "$target"; fi
  chmod +x "$target" 2>/dev/null || true
  rm -f "$zip"
  trap - EXIT; cleanup
  ok "Katana 安装成功：$target"
  "$target" -version 2>/dev/null || "$target" version 2>/dev/null || true
}

resolve_katana() {
  if has katana; then command -v katana; return 0; fi
  [ -x "${INSTALL_DIR}/katana" ] && { printf '%s\n' "${INSTALL_DIR}/katana"; return 0; }
  die '未找到 Katana，请先运行 install。'
}

cmd_version() {
  local bin; bin="$(resolve_katana)"; "$bin" -version 2>/dev/null || "$bin" version 2>/dev/null || "$bin" -h | head -n 5
}

cmd_crawl() {
  local url='' output_dir='' format='both' depth="$DEFAULT_DEPTH" rate="$DEFAULT_RATE_LIMIT" concurrency="$DEFAULT_CONCURRENCY" scope='rdn' headless=0
  local bin host domain txt json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u|--url) [ "$#" -ge 2 ] || die "$1 需要参数"; url="$2"; shift 2 ;;
      -o|--output-dir) [ "$#" -ge 2 ] || die "$1 需要参数"; output_dir="$2"; shift 2 ;;
      -f|--format) [ "$#" -ge 2 ] || die "$1 需要参数"; format="$2"; shift 2 ;;
      -d|--depth) [ "$#" -ge 2 ] || die "$1 需要参数"; depth="$2"; shift 2 ;;
      -r|--rate-limit) [ "$#" -ge 2 ] || die "$1 需要参数"; rate="$2"; shift 2 ;;
      -c|--concurrency) [ "$#" -ge 2 ] || die "$1 需要参数"; concurrency="$2"; shift 2 ;;
      --scope) [ "$#" -ge 2 ] || die "$1 需要参数"; scope="$2"; shift 2 ;;
      --headless) headless=1; shift ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ -n "$url" ] || die '需要 --url/-u。'
  case "$format" in txt|jsonl|both) ;; *) die '--format/-f 只支持 txt、jsonl、both。' ;; esac
  bin="$(resolve_katana)"; host="$(extract_host "$url")"; domain="$(registrable_domain "$host")"
  [ -n "$output_dir" ] || output_dir="${OUTPUT_ROOT}/${domain}"
  mkdir -p "$output_dir"
  txt="${output_dir}/urls.txt"; json="${output_dir}/crawl.jsonl"
  rm -f "$txt" "$json"
  log "输出目录：$output_dir"; log "目标：$url"; log "范围：${scope}，深度：${depth}，请求速率：${rate}/s，并发：${concurrency}"
  local opts=(-u "$url" -d "$depth" -rl "$rate" -c "$concurrency" -fs "$scope" -silent)
  [ "$headless" -eq 1 ] && opts+=(-headless)
  if [ "$format" = txt ]; then
    "$bin" "${opts[@]}" -o "$txt"
  else
    "$bin" "${opts[@]}" -jsonl -o "$json"
    if [ "$format" = both ]; then
      if has jq; then jq -r '(.request.endpoint // .endpoint // .url // empty)' "$json" > "$txt"; else sed -nE 's/.*"(endpoint|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$json" > "$txt"; fi
    fi
  fi
  [ -s "$txt" ] || { [ "$format" = jsonl ] && rm -f "$txt"; [ -e "$txt" ] && [ ! -s "$txt" ] && rm -f "$txt"; }
  [ -s "$json" ] || { [ "$format" != txt ] && [ -e "$json" ] && rm -f "$json"; }
  ok "爬取完成。结果目录：$output_dir"
}

command_name="${1:-}"
case "$command_name" in
  install) shift; install_binary ;;
  version) shift; cmd_version ;;
  crawl) shift; cmd_crawl "$@" ;;
  -h|--help|'') show_help ;;
  -u|--url|*) cmd_crawl "$@" ;;
esac

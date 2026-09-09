#!/usr/bin/env bash
# Nuclei 安装、模板更新和授权目标扫描辅助脚本。
# 仅对你明确获准测试的资产运行扫描。

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEFAULT_NUCLEI_VERSION="3.11.1"
NUCLEI_VERSION="${NUCLEI_VERSION:-$DEFAULT_NUCLEI_VERSION}"
RELEASE_API="${RELEASE_API:-https://api.github.com/repos/projectdiscovery/nuclei/releases/latest}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${HOME}/Downloads}"
# 扫描报告默认写入当前用户目录；如需临时保存或其他位置，请显式传入 --output-dir。
DEFAULT_OUTPUT_DIR="${NUCLEI_DEFAULT_OUTPUT_DIR:-${HOME}/nuclei_scan}"
OUTPUT_DIR_EXPLICIT=0
if [ -n "${OUTPUT_DIR:-}" ]; then
  OUTPUT_DIR_EXPLICIT=1
else
  OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { printf "[nuclei] %s\n" "$*"; }
ok()   { printf "${GREEN}[完成] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[警告] %s${NC}\n" "$*" >&2; }
die()  { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

is_nonnegative_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_positive_integer() {
  is_nonnegative_integer "$1" && [ "$1" -gt 0 ]
}

is_duration() {
  printf '%s\n' "${1:-}" | grep -Eq '^[0-9]+([smhd])?$'
}

extract_host() {
  local value="$1"
  value="${value#*://}"
  value="${value#*@}"
  value="${value%%/*}"
  value="${value%%\?*}"
  value="${value%%\#*}"
  case "$value" in
    \[*\]*)
      value="${value#\[}"
      value="${value%%\]*}"
      ;;
    *:*) value="${value%%:*}" ;;
  esac
  value="${value%.}"
  printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}

extract_registrable_domain() {
  local host="$1"
  local domain
  case "$host" in
    www.*) host="${host#www.}" ;;
  esac
  case "$host" in
    *.*.*.*)
      if printf '%s\n' "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        printf '%s\n' "$host"
        return 0
      fi
      ;;
  esac
  case "$host" in
    *.co.uk|*.org.uk|*.ac.uk|*.gov.uk|*.com.cn|*.net.cn|*.org.cn|*.edu.cn|*.gov.cn|*.com.au|*.net.au|*.org.au|*.co.jp|*.com.hk|*.com.tw|*.co.kr)
      domain="$(printf '%s\n' "$host" | awk -F. '{print $(NF-2) "." $(NF-1) "." $NF}')"
      ;;
    *)
      domain="$(printf '%s\n' "$host" | awk -F. '{if (NF >= 2) print $(NF-1) "." $NF; else print $NF}')"
      ;;
  esac
  printf '%s\n' "$domain"
}

output_dir_for_target() {
  local target="$1"
  local host domain safe
  host="$(extract_host "$target")"
  domain="$(extract_registrable_domain "$host")"
  safe="$(printf '%s\n' "$domain" | tr -cd 'a-z0-9.-')"
  [ -n "$safe" ] || safe="target"
  printf '%s/%s\n' "$OUTPUT_DIR" "$safe"
}

find_adl() {
  local candidate
  for candidate in \
    "$(command -v adl 2>/dev/null || true)" \
    "$SCRIPT_DIR/../../../network/tools/adl" \
    "/opt/homebrew/bin/adl" \
    "/usr/local/bin/adl" \
    "$HOME/.local/bin/adl"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --help >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME <命令> [参数]

安装/更新：
  install             安装 Nuclei 官方预编译二进制并初始化模板
  update              更新 Nuclei 二进制和模板
  templates           更新模板库
  report              将已有 Nuclei JSON 转为 Markdown 并追加复核结果
  verify              调用 nuclei-verify.sh 复核单条结果
  version             显示当前版本和最新版本

扫描（仅限已授权目标）：
  -l high -u https://example.com/
                      高危及严重级别
  --severity cve --url https://example.com/
                      CVE 模板

选项：
  -l, --severity <level>  扫描级别/类型，默认 high：cve、critical、high、exposures、misconfig、tech、all
  -u, --url <URL>         扫描目标 URL
  -L, --list <file>       批量扫描目标文件（列表）
  -f, --format <type>     报告格式：txt、json、md、html、both、all
  -c, --concurrency <n>    模板并发，默认 15
  -r, --rate-limit <n>     每秒最大请求数，默认 50
  -b, --bulk-size <n>      批量请求数，默认 10
  -o, --output <prefix>    输出文件前缀
  -d, --output-dir <dir>   覆盖自动输出目录
  -t, --timeout <sec>      单请求超时，默认 10
  -R, --retries <n>        失败重试次数，默认 1
  -m, --max-time <time>    单目标最长运行时间，如 10m、30m；默认 10m
  --stop-at-first-match    命中首个结果后停止，减少目标请求量
  --auto-verify            扫描完成后自动复核支持的低影响结果（默认开启）
  --no-auto-verify         关闭扫描后的自动复核
  --enable-risky           开启高风险标签模板（必须同时提供 --ack-authorized）
  --intrusive              --enable-risky 的兼容别名
  --ack-authorized         确认目标属于你或已取得书面授权
  --risk-tags <tags>       自定义需排除/放行确认的风险标签列表
  -s, --stats              显示扫描进度（默认开启）
  -S, --no-stats           关闭扫描进度
  -i, --interactsh         开启 OAST/Interactsh 模板
  -I, --no-interactsh      关闭 OAST/Interactsh（默认）
  -h, --help               显示帮助
  -v, --version            显示 Nuclei 版本

环境变量：
  NUCLEI_VERSION、INSTALL_DIR、DOWNLOAD_DIR、OUTPUT_DIR
  GITHUB_TOKEN         可选；仅用于 GitHub Releases API 鉴权，避免 API 限流
  NUCLEI_CONCURRENCY、NUCLEI_RATE_LIMIT、NUCLEI_BULK_SIZE、NUCLEI_TIMEOUT、NUCLEI_RETRIES
  NUCLEI_MAX_TIME=10m、NUCLEI_STOP_AT_FIRST_MATCH=0、NUCLEI_DEFAULT_OUTPUT_DIR
  NUCLEI_AUTO_VERIFY=1     扫描后自动复核 aspx-debug-mode、ds-store 等已支持结果
  NUCLEI_ALLOW_INTRUSIVE=0、NUCLEI_ACK_AUTHORIZED=0
  NUCLEI_RISKY_TAGS=dos,fuzz,bruteforce,default-login,phishing,unsafe
  NUCLEI_STATS=1、NUCLEI_STATS_INTERVAL=15、NUCLEI_INTERACTSH=0
  NUCLEI_FORMAT=md        报告格式：txt、json、md、html、both、all；默认单份 Markdown
  NUCLEI_DEFAULT_SEVERITY=high  未指定 -l/--severity 时的默认级别
  默认输出：${DEFAULT_OUTPUT_DIR}/<主域名>；可使用 --output-dir 指定目录
  全量安全扫描默认排除：dos、fuzz、bruteforce、default-login、phishing、unsafe
  自有靶场启用高风险模板：$SCRIPT_NAME -l all -u <URL> --enable-risky --ack-authorized
  SKIP_TEMPLATES=1    安装后跳过模板下载
  ALLOW_BREW_FALLBACK=1  二进制下载失败时允许尝试 Homebrew

示例：
  $SCRIPT_NAME install
  $SCRIPT_NAME version
  $SCRIPT_NAME report --json /path/to/scan.json
  $SCRIPT_NAME verify --check aspx-debug-mode --url https://example.com/Foobar-debug.aspx
  $SCRIPT_NAME -l high -u https://example.com/ -c 10
  $SCRIPT_NAME --severity high --url https://example.com/ --format txt
EOF
}

show_usage_after_install() {
  cat <<EOF

Nuclei 使用说明：
  版本检查：$SCRIPT_NAME version
  更新程序和模板：$SCRIPT_NAME update
  仅更新模板：$SCRIPT_NAME templates

  技术识别：$SCRIPT_NAME -l tech -u <URL>
  CVE 扫描：$SCRIPT_NAME -l cve -u <URL>
  高危扫描：$SCRIPT_NAME -l high -u <URL>
  全量扫描：$SCRIPT_NAME -l all -u <URL>
  TXT 报告：$SCRIPT_NAME -l high -u <URL> -f txt
  JSON 报告：$SCRIPT_NAME -l high -u <URL> -f json
  HTML 报告：$SCRIPT_NAME -l high -u <URL> -f html
  Markdown 报告：$SCRIPT_NAME -l high -u <URL> -f md

  默认性能参数：请求速率 50/s、模板并发 15、批量请求 10、超时 10s、失败重试 1 次、最长 10m。
  默认只生成一份 Markdown 报告，并将支持的复核结果追加到同一文件；如需原始 JSON/TXT，可使用 -f json、-f txt 或 -f both。
加速示例：NUCLEI_RATE_LIMIT=80 NUCLEI_CONCURRENCY=20 $SCRIPT_NAME -l all -u <目标>

扫描结果默认保存到：${DEFAULT_OUTPUT_DIR}/<主域名>
如需更改目录：$SCRIPT_NAME -l all -u <目标> --output-dir /path/to/reports
仅扫描你拥有或已获得明确授权的目标。
EOF
}

detect_os() {
  OS_TYPE="$(uname -s)"
  ARCH="$(uname -m)"
}

binary_arch() {
  case "$ARCH" in
    x86_64|amd64) printf 'amd64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *) die "不支持的架构：$ARCH" ;;
  esac
}

binary_os() {
  case "$OS_TYPE" in
    Darwin) printf 'macOS\n' ;;
    Linux) printf 'linux\n' ;;
    *) die "预编译二进制暂不支持：$OS_TYPE" ;;
  esac
}

latest_version() {
  has curl || return 0
  local payload
  local -a curl_args=(-fsSL --connect-timeout 10 --max-time 30)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H 'Accept: application/vnd.github+json')
  fi
  payload="$(curl "${curl_args[@]}" "$RELEASE_API" 2>/dev/null || true)"
  printf '%s\n' "$payload" |
    sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/p' |
    head -n 1
}

version_from_output() {
  sed -nE 's/.*[Vv]ersion[^0-9]*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1
}

version_is_newer() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".");
    for (i = 1; i <= 3; i++) {
      if ((x[i] + 0) > (y[i] + 0)) exit 0;
      if ((x[i] + 0) < (y[i] + 0)) exit 1;
    }
    exit 1
  }'
}

nuclei_bin() {
  if has nuclei; then
    command -v nuclei
  elif [ -x "$INSTALL_DIR/nuclei" ]; then
    printf '%s\n' "$INSTALL_DIR/nuclei"
  fi
}

check_installed() {
  [ -n "$(nuclei_bin || true)" ]
}

installed_version() {
  local bin
  bin="$(nuclei_bin || true)"
  [ -n "$bin" ] || return 0
  "$bin" -version 2>&1 | version_from_output
}

install_file() {
  local source="$1"
  if [ -w "$INSTALL_DIR" ]; then
    install -m 0755 "$source" "$INSTALL_DIR/nuclei"
  else
    has sudo || die "$INSTALL_DIR 不可写，且没有 sudo。"
    sudo install -m 0755 "$source" "$INSTALL_DIR/nuclei"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local adl_path
  mkdir -p "$(dirname "$output")"
  rm -f "$output"

  if adl_path="$(find_adl || true)" && [ -n "$adl_path" ]; then
    log "使用 adl 下载：$(basename "$output")"
    if "$adl_path" "$url" "$(dirname "$output")" "$(basename "$output")" && [ -s "$output" ]; then
      return 0
    fi
    warn "adl 下载失败，回退到 curl。"
    rm -f "$output"
  fi

  has curl || return 1
  curl -fL --retry 2 --connect-timeout 10 "$url" -o "$output"
  [ -s "$output" ]
}

install_binary() {
  local requested_version="${1:-${NUCLEI_VERSION:-$DEFAULT_NUCLEI_VERSION}}"
  local os_name arch filename url zip_file tmp_dir
  os_name="$(binary_os)"
  arch="$(binary_arch)"
  filename="nuclei_${requested_version}_${os_name}_${arch}.zip"
  url="https://github.com/projectdiscovery/nuclei/releases/download/v${requested_version}/${filename}"
  zip_file="$DOWNLOAD_DIR/$filename"

  has unzip || return 1
  mkdir -p "$DOWNLOAD_DIR"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuclei-install.XXXXXX")"

  log "下载官方预编译包：$filename"
  if ! download_file "$url" "$zip_file"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  if ! unzip -q "$zip_file" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  [ -f "$tmp_dir/nuclei" ] || { rm -rf "$tmp_dir"; return 1; }
  install_file "$tmp_dir/nuclei"
  if ! check_installed; then
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
  rm -f "$zip_file"
  return 0
}

install_brew_fallback() {
  [ "${ALLOW_BREW_FALLBACK:-0}" = "1" ] || return 1
  has brew || return 1
  warn "官方二进制不可用，尝试 Homebrew；macOS 12 可能触发本地 Go 编译。"
  brew install nuclei
}

install_go_fallback() {
  [ "${ALLOW_GO_FALLBACK:-0}" = "1" ] || return 1
  has go || return 1
  log "尝试 Go 安装（需要 Go >= 1.24.2 和足够磁盘空间）。"
  go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
  local gopath
  gopath="$(go env GOPATH)"
  [ -x "$gopath/bin/nuclei" ] || return 1
  install_file "$gopath/bin/nuclei"
}

update_templates() {
  local bin
  bin="$(nuclei_bin || true)"
  [ -n "$bin" ] || die "Nuclei 未安装。"
  log "更新 Nuclei 模板库..."
  "$bin" -update-templates || "$bin" -ut
}

cmd_install() {
  detect_os
  if check_installed; then
    ok "Nuclei 已安装：$(installed_version || true)"
    show_usage_after_install
    return 0
  fi

  local latest resolved_version
  resolved_version="${NUCLEI_VERSION:-$DEFAULT_NUCLEI_VERSION}"
  latest="$(latest_version || true)"
  [ -n "$latest" ] && resolved_version="$latest"
  log "开始安装 Nuclei v${resolved_version}（${OS_TYPE}/${ARCH}）"

  if ! install_binary "$resolved_version" &&
     ! install_brew_fallback &&
     ! install_go_fallback; then
    die "安装失败。优先检查代理/网络和磁盘空间；当前脚本不会再把失败误报为成功。"
  fi
  check_installed || die "安装命令结束，但未找到 nuclei 可执行文件。"
  ok "Nuclei 安装成功：$(installed_version || true)"

  if [ "${SKIP_TEMPLATES:-0}" = "1" ]; then
    warn "已跳过模板下载（SKIP_TEMPLATES=1）。"
  elif update_templates; then
    ok "模板库已更新。"
  else
    warn "Nuclei 已安装，但模板库更新失败；可稍后执行：$SCRIPT_NAME templates"
  fi
  show_usage_after_install
}

cmd_update() {
  check_installed || die "Nuclei 未安装，请先执行：$SCRIPT_NAME install"
  detect_os
  local latest current
  current="$(installed_version || true)"
  latest="$(latest_version || true)"
  if [ -n "$latest" ] && version_is_newer "$latest" "$current"; then
    install_binary "$latest" || die "二进制更新失败；请检查网络和代理。"
    ok "Nuclei 已更新：$current -> $latest"
  else
    log "未发现二进制更新（当前：${current:-unknown}，最新：${latest:-unknown}）。"
  fi
  update_templates
}

cmd_version() {
  local current latest
  current="$(installed_version || true)"
  latest="$(latest_version || true)"
  printf 'installed: %s\n' "${current:-not detected}"
  printf 'latest:    %s\n' "${latest:-not detected}"
  if [ -n "$current" ] && [ -n "$latest" ]; then
    if version_is_newer "$latest" "$current"; then
      printf 'update:    available\n'
    else
      printf 'update:    up to date\n'
    fi
  else
    printf 'update:    unable to compare\n'
  fi
}

cmd_templates() {
  update_templates
  ok "模板库更新完成。"
}

cmd_report() {
  local json_file="" markdown_file="" auto_verify="${NUCLEI_AUTO_VERIFY:-1}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) [ "$#" -ge 2 ] || die "$1 需要参数"; json_file="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die "$1 需要参数"; markdown_file="$2"; shift 2 ;;
      --auto-verify) auto_verify=1; shift ;;
      --no-auto-verify) auto_verify=0; shift ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知报告参数：$1；需要 --json <file>。" ;;
    esac
  done
  [ -n "$json_file" ] || die "report 需要 --json <file>。"
  [ -s "$json_file" ] || die "JSON 报告不存在或为空：$json_file"
  [ -n "$markdown_file" ] || markdown_file="${json_file%.json}.md"
  mkdir -p "$(dirname "$markdown_file")"
  render_markdown_report "$json_file" "$markdown_file" || die "生成 Markdown 报告需要 jq 或 python3。"
  if [ "$auto_verify" -eq 1 ]; then
    run_supported_verifications "$json_file" "$markdown_file" "$(dirname "$markdown_file")"
  fi
  ok "Markdown 报告已生成：$markdown_file"
}

cmd_verify() {
  local verifier="$SCRIPT_DIR/nuclei-verify.sh"
  [ -x "$verifier" ] || die "未找到可执行复核脚本：$verifier"
  exec "$verifier" "$@"
}

render_markdown_report() {
  local json_file="$1"
  local markdown_file="$2"
  has python3 || return 1
  [ -f "$SCRIPT_DIR/nuclei-report.py" ] || return 1
  python3 "$SCRIPT_DIR/nuclei-report.py" --json "$json_file" --output "$markdown_file"
}

render_html_report() {
  local json_file="$1"
  local html_file="$2"
  has python3 || return 1
  [ -f "$SCRIPT_DIR/nuclei-report.py" ] || return 1
  python3 "$SCRIPT_DIR/nuclei-report.py" --json "$json_file" --output "$html_file" --format html
}

verification_items() {
  local json_file="$1"
  if has jq; then
    jq -r '
      .[]
      | select((.["template-id"] == "aspx-debug-mode") or (.["template-id"] == "ds-store"))
      | [.["template-id"], (.["matched-at"] // .url // "")]
      | @tsv
    ' "$json_file" | sort -u
    return 0
  fi
  if has python3; then
    python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    raw = handle.read().strip()
try:
    items = json.loads(raw) if raw else []
except json.JSONDecodeError:
    items = [json.loads(line) for line in raw.splitlines() if line.strip()]
if isinstance(items, dict):
    items = [items]
seen = set()
for item in items:
    template_id = item.get("template-id")
    if template_id not in {"aspx-debug-mode", "ds-store"}:
        continue
    target = item.get("matched-at") or item.get("url") or ""
    value = (template_id, target)
    if target and value not in seen:
        print("%s\t%s" % value)
        seen.add(value)
PY
    return 0
  fi
  return 1
}

run_supported_verifications() {
  local json_file="$1" report_file="$2" scan_output_dir="$3"
  local items check target verify_rc count=0
  local verifier="$SCRIPT_DIR/nuclei-verify.sh"
  [ -x "$verifier" ] || { warn "未找到复核脚本，跳过自动复核：$verifier"; return 0; }
  [ -s "$json_file" ] || return 0
  items="$(verification_items "$json_file" || true)"
  [ -n "$items" ] || return 0
  log '开始对支持的低影响结果进行自动复核...'
  while IFS=$'\t' read -r check target; do
    [ -n "$check" ] && [ -n "$target" ] || continue
    verify_rc=0
    "$verifier" \
      --check "$check" \
      --url "$target" \
      --output-dir "$scan_output_dir" \
      --report-file "$report_file" \
      --append-report || verify_rc=$?
    count=$((count + 1))
    case "$verify_rc" in
      0) log "已确认：$check -> $target" ;;
      2) warn "未确认：$check -> $target" ;;
      *) warn "复核执行失败（退出码：$verify_rc）：$check -> $target" ;;
    esac
  done <<< "$items"
  log "自动复核完成：${count} 条；结果已追加到 $report_file"
}

do_scan() {
  check_installed || die "Nuclei 未安装，请先执行：$SCRIPT_NAME install"
  local scan_type="$1"
  local target_type="$2"
  local target_val="$3"
  local output_prefix="${4:-${scan_type}_$(date +%Y%m%d-%H%M%S)}"
  local bin scan_output_dir txt_report json_report markdown_report html_report scan_rc=0
  local found report_format
  local -a opts
  report_format="${REPORT_FORMAT:-md}"
  bin="$(nuclei_bin)"
  if [ "$OUTPUT_DIR_EXPLICIT" -eq 1 ]; then
    scan_output_dir="$OUTPUT_DIR"
  else
    if [ "$target_type" = "list" ]; then
      scan_output_dir="$(output_dir_for_target "batch-$(basename "$target_val")")"
    else
      scan_output_dir="$(output_dir_for_target "$target_val")"
    fi
  fi
  mkdir -p "$scan_output_dir"
  log "输出目录：$scan_output_dir"
  txt_report="$scan_output_dir/$output_prefix.txt"
  json_report="$scan_output_dir/$output_prefix.json"
  markdown_report="$scan_output_dir/$output_prefix.md"
  html_report="$scan_output_dir/$output_prefix.html"
  opts=()
  if [ "$target_type" = "list" ]; then
    opts+=(-l "$target_val")
  else
    opts+=(-u "$target_val")
  fi
  opts+=(-rl "$RATE_LIMIT"
    -c "$CONCURRENCY"
    -bs "$BULK_SIZE"
    -timeout "$TIMEOUT_SECONDS"
    -retries "$RETRIES"
    -mt "$MAX_TIME"
    -duc)
  [ "$USE_INTERACTSH" -eq 1 ] || opts+=(-ni)
  [ "$SHOW_STATS" -eq 1 ] && opts+=(-stats -si "$STATS_INTERVAL")
  [ "$STOP_AT_FIRST_MATCH" -eq 1 ] && opts+=(-spm)
  if [ "$ALLOW_INTRUSIVE" -eq 0 ]; then
    # 这些类别可能造成服务压力、凭据尝试、外部交互或主动利用，默认不运行。
    opts+=(-etags "$RISKY_TAGS")
  fi
  case "$report_format" in
    txt)  opts+=(-o "$txt_report") ;;
    json) opts+=(-json-export "$json_report") ;;
    both) opts+=(-o "$txt_report" -json-export "$json_report") ;;
    md|html|all) opts+=(-json-export "$json_report") ;;
  esac

  case "$scan_type" in
    cve)       opts+=(-t cves/ -severity critical,high,medium) ;;
    critical)  opts+=(-severity critical) ;;
    high)      opts+=(-severity critical,high) ;;
    exposures) opts+=(-t exposures/) ;;
    misconfig) opts+=(-t misconfiguration/) ;;
    tech)      opts+=(-t technologies/ -severity info) ;;
    all)       ;;
  esac

  log "$scan_type 扫描：$target"
  if "$bin" "${opts[@]}"; then
    scan_rc=0
  else
    scan_rc=$?
  fi
  found=0
  if [ "$report_format" = "txt" ]; then
    if [ -s "$txt_report" ]; then
      found="$(wc -l < "$txt_report" | tr -d ' ')"
    fi
  elif [ -s "$json_report" ]; then
    if has jq; then
      found="$(jq 'if type == "array" then length else 1 end' "$json_report" 2>/dev/null || echo 0)"
    else
      found="$(grep -c '"template-id"' "$json_report" 2>/dev/null || true)"
    fi
  fi

  if [ "$found" -eq 0 ]; then
    rm -f "$txt_report" "$json_report" "$markdown_report" "$html_report"
    [ "${scan_rc:-1}" -eq 0 ] || die "Nuclei 扫描失败（退出码：${scan_rc:-1}），空报告文件已清理。"
    ok "未发现匹配项，空报告文件已清理。"
    return 0
  fi
  case "$report_format" in
    md)
      render_markdown_report "$json_report" "$markdown_report" || die "生成 Markdown 报告需要 jq 或 python3。"
      [ "$AUTO_VERIFY" -eq 1 ] && run_supported_verifications "$json_report" "$markdown_report" "$scan_output_dir"
      rm -f "$json_report"
      ;;
    html)
      render_html_report "$json_report" "$html_report" || die "生成 HTML 报告需要 jq。"
      rm -f "$json_report"
      ;;
    all)
      render_markdown_report "$json_report" "$markdown_report" || die "生成 Markdown 报告需要 jq 或 python3。"
      render_html_report "$json_report" "$html_report" || die "生成 HTML 报告需要 jq。"
      [ "$AUTO_VERIFY" -eq 1 ] && run_supported_verifications "$json_report" "$markdown_report" "$scan_output_dir"
      ;;
  esac
  [ "${scan_rc:-1}" -eq 0 ] || warn "扫描退出码为 ${scan_rc:-1}，但已发现 ${found} 条结果。"
  ok "发现 ${found} 条结果，报告格式：${report_format}，目录：${scan_output_dir}"
}

main() {
  [ "$#" -gt 0 ] || { show_help; exit 1; }
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -v|--version) cmd_version; exit 0 ;;
  esac
  local cmd
  case "$1" in
    -l|--severity|-u|--url|-L|--list|-f|--format|-c|--concurrency|-r|--rate-limit|-b|--bulk-size|-o|--output|-d|--output-dir|-t|--timeout|-R|--retries|-m|--max-time|-s|--stats|-S|--no-stats|-i|--interactsh|-I|--no-interactsh|--stop-at-first-match|--auto-verify|--no-auto-verify|--enable-risky|--intrusive|--ack-authorized|--risk-tags)
      cmd="scan"
      ;;
    *)
      cmd="$1"
      shift
      ;;
  esac
  if [ "$cmd" = "verify" ]; then
    cmd_verify "$@"
  elif [ "$cmd" = "report" ]; then
    cmd_report "$@"
    return $?
  fi
  CONCURRENCY="${NUCLEI_CONCURRENCY:-15}"
  RATE_LIMIT="${NUCLEI_RATE_LIMIT:-50}"
  BULK_SIZE="${NUCLEI_BULK_SIZE:-10}"
  TIMEOUT_SECONDS="${NUCLEI_TIMEOUT:-10}"
  RETRIES="${NUCLEI_RETRIES:-1}"
  MAX_TIME="${NUCLEI_MAX_TIME:-10m}"
  STATS_INTERVAL="${NUCLEI_STATS_INTERVAL:-15}"
  SHOW_STATS="${NUCLEI_STATS:-1}"
  USE_INTERACTSH="${NUCLEI_INTERACTSH:-0}"
  STOP_AT_FIRST_MATCH="${NUCLEI_STOP_AT_FIRST_MATCH:-0}"
  AUTO_VERIFY="${NUCLEI_AUTO_VERIFY:-1}"
  ALLOW_INTRUSIVE="${NUCLEI_ALLOW_INTRUSIVE:-0}"
  ACK_AUTHORIZED="${NUCLEI_ACK_AUTHORIZED:-0}"
  RISKY_TAGS="${NUCLEI_RISKY_TAGS:-dos,fuzz,bruteforce,default-login,phishing,unsafe}"
  REPORT_FORMAT="${NUCLEI_FORMAT:-md}"
  OUTPUT_PREFIX=""
  SCAN_SEVERITY="${NUCLEI_DEFAULT_SEVERITY:-high}"
  local target=""
  local target_list=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -l|--severity) [ "$#" -ge 2 ] || die "$1 需要参数"; SCAN_SEVERITY="$2"; shift 2 ;;
      -u|--url) [ "$#" -ge 2 ] || die "$1 需要参数"; target="$2"; shift 2 ;;
      -L|--list) [ "$#" -ge 2 ] || die "$1 需要参数"; target_list="$2"; shift 2 ;;
      -f|--format) [ "$#" -ge 2 ] || die "$1 需要参数"; REPORT_FORMAT="$2"; shift 2 ;;
      -c|--concurrency) [ "$#" -ge 2 ] || die "$1 需要参数"; CONCURRENCY="$2"; shift 2 ;;
      -r|--rate-limit) [ "$#" -ge 2 ] || die "$1 需要参数"; RATE_LIMIT="$2"; shift 2 ;;
      -b|--bulk-size) [ "$#" -ge 2 ] || die "$1 需要参数"; BULK_SIZE="$2"; shift 2 ;;
      -o|--output) [ "$#" -ge 2 ] || die "$1 需要参数"; OUTPUT_PREFIX="$2"; shift 2 ;;
      -d|--output-dir) [ "$#" -ge 2 ] || die "$1 需要参数"; OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=1; shift 2 ;;
      -t|--timeout) [ "$#" -ge 2 ] || die "$1 需要参数"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      -R|--retries) [ "$#" -ge 2 ] || die "$1 需要参数"; RETRIES="$2"; shift 2 ;;
      -m|--max-time) [ "$#" -ge 2 ] || die "$1 需要参数"; MAX_TIME="$2"; shift 2 ;;
      -s|--stats) SHOW_STATS=1; shift ;;
      -S|--no-stats) SHOW_STATS=0; shift ;;
      -i|--interactsh) USE_INTERACTSH=1; shift ;;
      -I|--no-interactsh) USE_INTERACTSH=0; shift ;;
      --stop-at-first-match) STOP_AT_FIRST_MATCH=1; shift ;;
      --auto-verify) AUTO_VERIFY=1; shift ;;
      --no-auto-verify) AUTO_VERIFY=0; shift ;;
      --enable-risky) ALLOW_INTRUSIVE=1; shift ;;
      --intrusive) ALLOW_INTRUSIVE=1; shift ;;
      --ack-authorized) ACK_AUTHORIZED=1; shift ;;
      --risk-tags) [ "$#" -ge 2 ] || die "$1 需要参数"; RISKY_TAGS="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      -v|--version) cmd_version; exit 0 ;;
      --) die "扫描目标必须使用 --url/-u 或 --list/-L，不能使用位置参数。" ;;
      -*) die "未知参数：$1；运行 $SCRIPT_NAME --help 查看帮助。" ;;
      *) die "不支持位置参数：$1；请使用 --url/-u、--list/-L 和 --severity/-l。" ;;
    esac
  done

  case "$cmd" in
    install) cmd_install ;;
    update) cmd_update ;;
    templates) cmd_templates ;;
    version) cmd_version ;;
    scan)
      [ -n "$target" ] || [ -n "$target_list" ] || die "scan 需要 --url/-u 或 --list/-L"
      is_positive_integer "$CONCURRENCY" || die "并发必须是大于 0 的整数。"
      is_positive_integer "$RATE_LIMIT" || die "请求速率必须是大于 0 的整数。"
      is_positive_integer "$BULK_SIZE" || die "批量请求数必须是大于 0 的整数。"
      is_positive_integer "$TIMEOUT_SECONDS" || die "超时必须是大于 0 的整数。"
      is_nonnegative_integer "$RETRIES" || die "重试次数必须是非负整数。"
      case "$AUTO_VERIFY" in
        0|1) ;;
        *) die "自动复核开关必须是 0 或 1。" ;;
      esac
      is_duration "$MAX_TIME" || die "最长运行时间格式无效，应为 10m、30s、1h 等。"
      [ -n "$RISKY_TAGS" ] || die "高风险标签列表不能为空。"
      if [ "$ALLOW_INTRUSIVE" -eq 1 ] && [ "$ACK_AUTHORIZED" -ne 1 ]; then
        die "高风险模板需要同时提供 --enable-risky 和 --ack-authorized，且仅限自有或书面授权目标。"
      fi
      case "$REPORT_FORMAT" in
        txt|json|md|html|both|all) ;;
        *) die "不支持的报告格式：${REPORT_FORMAT}，可选 txt、json、md、html、both、all" ;;
      esac
      case "$SCAN_SEVERITY" in
        cve|critical|high|exposures|misconfig|tech|all) ;;
        *) die "不支持的扫描级别：${SCAN_SEVERITY}" ;;
      esac
      if [ -n "$target_list" ]; then
        do_scan "$SCAN_SEVERITY" "list" "$target_list" "$OUTPUT_PREFIX"
      else
        do_scan "$SCAN_SEVERITY" "url" "$target" "$OUTPUT_PREFIX"
      fi
      ;;
    -h|--help) show_help ;;
    *) die "未知命令：${cmd}；运行 $SCRIPT_NAME --help 查看帮助。" ;;
  esac
}

main "$@"

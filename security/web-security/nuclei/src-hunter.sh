#!/usr/bin/env bash
# 公益 SRC 目标的低影响自动化扫描编排器。
# 只扫描目标表中的资产；不自动提交漏洞，不启用主动利用模板。

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NUCLEI_SCRIPT="$SCRIPT_DIR/nuclei.sh"
REPORTER="$SCRIPT_DIR/src-hunter-report.py"
TARGETS_FILE="${SRC_TARGETS_FILE:-${HOME}/nuclei_scan/butian-public-src-targets.tsv}"
HISTORY_FILE="${SRC_SCAN_HISTORY_FILE:-${HOME}/nuclei_scan/scanned-domains.txt}"
OUTPUT_ROOT="${SRC_SCAN_OUTPUT_DIR:-${HOME}/nuclei_scan}"
RATE_LIMIT="${SRC_NUCLEI_RATE_LIMIT:-30}"
CONCURRENCY="${SRC_NUCLEI_CONCURRENCY:-10}"
BULK_SIZE="${SRC_NUCLEI_BULK_SIZE:-5}"
TIMEOUT_SECONDS="${SRC_NUCLEI_TIMEOUT:-8}"
RETRIES="${SRC_NUCLEI_RETRIES:-0}"
MAX_TIME="${SRC_NUCLEI_MAX_TIME:-15m}"
CURRENT_CLAIM_TARGET=""
CURRENT_CLAIM_BATCH=""
BATCH_COUNT=50

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { printf '[src-hunter] %s\n' "$*"; }
ok() { printf "${GREEN}[完成] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[警告] %s${NC}\n" "$*" >&2; }
die() { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
release_claim_on_exit() {
  if [ -n "$CURRENT_CLAIM_TARGET" ]; then
    python3 "$REPORTER" release-claim --history "$HISTORY_FILE" --target "$CURRENT_CLAIM_TARGET" >/dev/null 2>&1 || true
  fi
  if [ -n "${CURRENT_CLAIM_BATCH:-}" ] && [ -f "$CURRENT_CLAIM_BATCH" ]; then
    while IFS=$'\t' read -r vendor target source; do
      [ -z "$target" ] && continue
      python3 "$REPORTER" release-claim --history "$HISTORY_FILE" --target "$target" >/dev/null 2>&1 || true
    done < "$CURRENT_CLAIM_BATCH"
    rm -f "$CURRENT_CLAIM_BATCH"
  fi
}
trap release_claim_on_exit EXIT

show_help() {
  cat <<EOF
用法：$(basename "$0") <命令> [选项]

命令：
  scan-next              从公益 SRC TSV 中选择第一个未扫描目标并扫描
  scan-batch             批量认领并扫描多个未扫描目标（配合 --count 使用）
  scan --url <URL>       扫描指定目标；不在目标表中时需双重授权确认
  select-next            只显示下一个未扫描目标，不执行扫描
  report --json <file>   将 Nuclei JSON 分析为 Markdown

通用选项：
  --targets <file>       目标 TSV，默认：$TARGETS_FILE
  --history <file>       扫描历史，默认：$HISTORY_FILE
  --output-dir <dir>     报告根目录，默认：$OUTPUT_ROOT
  --vendor <name>        指定厂商名称
  --count <n>            批量扫描的目标数量，默认：$BATCH_COUNT
  --rate-limit <n>       请求速率，默认：$RATE_LIMIT
  --concurrency <n>      模板并发，默认：$CONCURRENCY
  --bulk-size <n>        批量请求数，默认：$BULK_SIZE
  --timeout <sec>        单请求超时，默认：$TIMEOUT_SECONDS
  --retries <n>          重试次数，默认：$RETRIES
  --max-time <time>      单目标最长时间，默认：$MAX_TIME
  report --log <file>    报告分析时附加 Nuclei 日志和覆盖率摘要
  --allow-unlisted       允许非 TSV 目标（必须同时 --ack-authorized）
  --ack-authorized       确认目标属于你或已取得书面授权
  --force                允许重扫历史中已记录目标

默认每个目标生成一份 Markdown 主报告和原始 JSON，保存到：
  <output-dir>/<主域名>/
扫描日志保存为同目录的 .log 文件；历史并发控制使用：
  <history>.lock 和 <history>.claims

安全边界：仅使用 nuclei.sh 安全默认模式；不自动执行代码执行、DoS、爆破、
默认口令、钓鱼或其他主动利用，也不会自动提交补天。
EOF
}

is_nonnegative_integer() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_positive_integer() { is_nonnegative_integer "$1" && [ "$1" -gt 0 ]; }
is_duration() { printf '%s\n' "${1:-}" | grep -Eq '^[0-9]+([smhd])?$'; }
require_dependencies() {
  has python3 || die '未找到 python3。'
  [ -f "$REPORTER" ] || die "未找到报告分析器：$REPORTER"
  [ -x "$NUCLEI_SCRIPT" ] || die "未找到可执行 Nuclei 脚本：$NUCLEI_SCRIPT"
}
validate_parameters() {
  is_positive_integer "$RATE_LIMIT" || die '请求速率必须是大于 0 的整数。'
  is_positive_integer "$CONCURRENCY" || die '并发必须是大于 0 的整数。'
  is_positive_integer "$BULK_SIZE" || die '批量请求数必须是大于 0 的整数。'
  is_positive_integer "$TIMEOUT_SECONDS" || die '超时必须是大于 0 的整数。'
  is_nonnegative_integer "$RETRIES" || die '重试次数必须是非负整数。'
  is_duration "$MAX_TIME" || die '最长运行时间格式无效，如 10m、30s、1h。'
}
target_domain() { python3 "$REPORTER" domain --target "$1"; }
select_next() { python3 "$REPORTER" select-next --targets "$TARGETS_FILE" --history "$HISTORY_FILE" --output-root "$OUTPUT_ROOT"; }
claim_next() { python3 "$REPORTER" claim-next --targets "$TARGETS_FILE" --history "$HISTORY_FILE" --output-root "$OUTPUT_ROOT"; }
target_is_listed() { [ -f "$TARGETS_FILE" ] && python3 "$REPORTER" is-listed --targets "$TARGETS_FILE" --target "$1"; }
target_is_scanned() { python3 "$REPORTER" is-scanned --history "$HISTORY_FILE" --target "$1" --output-root "$OUTPUT_ROOT"; }

parse_options() {
  URL=""; VENDOR=""; ACK_AUTHORIZED=0; ALLOW_UNLISTED=0; FORCE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --targets) [ "$#" -ge 2 ] || die "$1 需要参数"; TARGETS_FILE="$2"; shift 2 ;;
      --history) [ "$#" -ge 2 ] || die "$1 需要参数"; HISTORY_FILE="$2"; shift 2 ;;
      --output-dir) [ "$#" -ge 2 ] || die "$1 需要参数"; OUTPUT_ROOT="$2"; shift 2 ;;
      --url|-u) [ "$#" -ge 2 ] || die "$1 需要参数"; URL="$2"; shift 2 ;;
      --vendor) [ "$#" -ge 2 ] || die "$1 需要参数"; VENDOR="$2"; shift 2 ;;
      --rate-limit) [ "$#" -ge 2 ] || die "$1 需要参数"; RATE_LIMIT="$2"; shift 2 ;;
      --concurrency) [ "$#" -ge 2 ] || die "$1 需要参数"; CONCURRENCY="$2"; shift 2 ;;
      --bulk-size) [ "$#" -ge 2 ] || die "$1 需要参数"; BULK_SIZE="$2"; shift 2 ;;
      --timeout) [ "$#" -ge 2 ] || die "$1 需要参数"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      --retries) [ "$#" -ge 2 ] || die "$1 需要参数"; RETRIES="$2"; shift 2 ;;
      --max-time) [ "$#" -ge 2 ] || die "$1 需要参数"; MAX_TIME="$2"; shift 2 ;;
      --ack-authorized) ACK_AUTHORIZED=1; shift ;;
      --allow-unlisted) ALLOW_UNLISTED=1; shift ;;
      --force) FORCE=1; shift ;;
      --count) [ "$#" -ge 2 ] || die "$1 需要参数"; BATCH_COUNT="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      *) die "未知参数：$1；运行 $(basename "$0") --help 查看帮助。" ;;
    esac
  done
}

run_scan() {
  local target="$1" vendor="$2" domain="$3" target_dir prefix json_file report_file log_file scan_rc=0 verify_rc check check_target
  # Keep an explicit fallback for interrupted pipelines under `set -u`.
  scan_rc=0
  target_dir="$OUTPUT_ROOT/$domain"; prefix="nuclei-$(date +%Y%m%d-%H%M%S)"
  json_file="$target_dir/$prefix.json"; report_file="$target_dir/$prefix.md"; log_file="$target_dir/$prefix.log"
  mkdir -p "$target_dir"
  log "厂商：${vendor:-未提供}"; log "目标：$target"; log "输出目录：$target_dir"
  log "安全全量扫描：请求速率 ${RATE_LIMIT}/s，并发 ${CONCURRENCY}，最长 ${MAX_TIME}"
  set +e
  "$NUCLEI_SCRIPT" -l all -u "$target" -f json -o "$prefix" -d "$target_dir" \
    -r "$RATE_LIMIT" -c "$CONCURRENCY" -b "$BULK_SIZE" -t "$TIMEOUT_SECONDS" \
    -R "$RETRIES" -m "$MAX_TIME" --no-auto-verify 2>&1 | tee "$log_file"
  scan_rc="${PIPESTATUS[0]:-1}"
  set -e

  python3 "$REPORTER" analyze --json "$json_file" --output "$report_file" \
    --vendor "$vendor" --target "$target" --scan-status "$scan_rc" --log "$log_file"
  if [ -s "$json_file" ]; then
    while IFS=$'\t' read -r check check_target; do
      [ -n "$check" ] && [ -n "$check_target" ] || continue
      verify_rc=0
      "$NUCLEI_SCRIPT" verify --check "$check" --url "$check_target" \
        --output-dir "$target_dir" --report-file "$report_file" --append-report || verify_rc=$?
      case "$verify_rc" in
        0) log "已确认低影响检查：$check -> $check_target" ;;
        2) warn "未确认低影响检查：$check -> $check_target" ;;
        *) warn "复核执行失败（退出码 $verify_rc）：$check -> $check_target" ;;
      esac
    done < <(python3 "$REPORTER" checks --json "$json_file")
  fi

  if [ "${scan_rc:-1}" -eq 0 ]; then
    python3 "$REPORTER" mark-scanned --history "$HISTORY_FILE" --target "$target" >/dev/null
    ok "扫描完成并已记录历史：$domain"; ok "主报告：$report_file"
    [ -s "$json_file" ] && log "原始 JSON：$json_file"
    return 0
  fi
  warn "Nuclei 扫描退出码为 ${scan_rc:-1}，未写入扫描历史；请检查日志后决定是否重试。"
  return "${scan_rc:-1}"
}

run_scan_batch() {
  local list_file="$1" batch_name="$2"
  local target_dir prefix json_file report_file log_file scan_rc=0 verify_rc check check_target
  scan_rc=0
  target_dir="$OUTPUT_ROOT/$batch_name"; prefix="nuclei-$(date +%Y%m%d-%H%M%S)"
  json_file="$target_dir/$prefix.json"; report_file="$target_dir/$prefix.md"; log_file="$target_dir/$prefix.log"
  mkdir -p "$target_dir"
  log "批量扫描目标数量：$(wc -l < "$list_file")"; log "输出目录：$target_dir"
  log "安全全量扫描：请求速率 ${RATE_LIMIT}/s，并发 ${CONCURRENCY}，最长 ${MAX_TIME}"
  set +e
  "$NUCLEI_SCRIPT" -l all -L "$list_file" -f json -o "$prefix" -d "$target_dir" \
    -r "$RATE_LIMIT" -c "$CONCURRENCY" -b "$BULK_SIZE" -t "$TIMEOUT_SECONDS" \
    -R "$RETRIES" -m "$MAX_TIME" --no-auto-verify 2>&1 | tee "$log_file"
  scan_rc="${PIPESTATUS[0]:-1}"
  set -e

  python3 "$REPORTER" analyze --json "$json_file" --output "$report_file" \
    --scan-status "$scan_rc" --log "$log_file"
  if [ -s "$json_file" ]; then
    while IFS=$'\t' read -r check check_target; do
      [ -n "$check" ] && [ -n "$check_target" ] || continue
      verify_rc=0
      "$NUCLEI_SCRIPT" verify --check "$check" --url "$check_target" \
        --output-dir "$target_dir" --report-file "$report_file" --append-report || verify_rc=$?
      case "$verify_rc" in
        0) log "已确认低影响检查：$check -> $check_target" ;;
        2) warn "未确认低影响检查：$check -> $check_target" ;;
        *) warn "复核执行失败（退出码 $verify_rc）：$check -> $check_target" ;;
      esac
    done < <(python3 "$REPORTER" checks --json "$json_file")
  fi

  if [ "${scan_rc:-1}" -eq 0 ]; then
    while IFS=$'\t' read -r vendor target source; do
      python3 "$REPORTER" mark-scanned --history "$HISTORY_FILE" --target "$target" >/dev/null
    done < "$CURRENT_CLAIM_BATCH"
    ok "批量扫描完成并已记录历史：$batch_name"; ok "主报告：$report_file"
    [ -s "$json_file" ] && log "原始 JSON：$json_file"
    return 0
  fi
  warn "Nuclei 扫描退出码为 ${scan_rc:-1}，未写入扫描历史；请检查日志后决定是否重试。"
  return "${scan_rc:-1}"
}

cmd_select_next() {
  require_dependencies; [ -f "$TARGETS_FILE" ] || die "目标文件不存在：$TARGETS_FILE"
  local selection; selection="$(select_next || true)"; [ -n "$selection" ] || die '没有找到未扫描目标。'; printf '%s\n' "$selection"
}
cmd_scan_next() {
  require_dependencies; validate_parameters; [ -f "$TARGETS_FILE" ] || die "目标文件不存在：$TARGETS_FILE"
  local selection vendor target source domain; selection="$(claim_next || true)"; [ -n "$selection" ] || die '没有找到未扫描目标（可能全部已扫描或正在被其他任务占用）。'
  IFS=$'\t' read -r vendor target source <<< "$selection"; domain="$(target_domain "$target")" || die "无法解析目标主域名：$target"
  CURRENT_CLAIM_TARGET="$target"
  log "来源条目：${source:-未标注}"
  if run_scan "$target" "$vendor" "$domain"; then
    CURRENT_CLAIM_TARGET=""
  else
    local scan_rc=$?
    python3 "$REPORTER" release-claim --history "$HISTORY_FILE" --target "$target" || true
    CURRENT_CLAIM_TARGET=""
    return "$scan_rc"
  fi
}
cmd_scan_batch() {
  require_dependencies; validate_parameters; [ -f "$TARGETS_FILE" ] || die "目标文件不存在：$TARGETS_FILE"
  local selection; selection="$(python3 "$REPORTER" claim-batch --targets "$TARGETS_FILE" --history "$HISTORY_FILE" --output-root "$OUTPUT_ROOT" --count "$BATCH_COUNT" || true)"
  [ -n "$selection" ] || die '没有找到未扫描目标（可能全部已扫描或正在被其他任务占用）。'
  
  local batch_file; batch_file="$(mktemp)"
  CURRENT_CLAIM_BATCH="$batch_file"
  local url_list_file; url_list_file="$(mktemp)"
  
  echo "$selection" > "$batch_file"
  awk -F'\t' '{print $2}' "$batch_file" > "$url_list_file"
  
  local batch_name="batch-$(date +%Y%m%d-%H%M%S)"
  
  if run_scan_batch "$url_list_file" "$batch_name"; then
    rm -f "$batch_file" "$url_list_file"
    CURRENT_CLAIM_BATCH=""
  else
    local scan_rc=$?
    while IFS=$'\t' read -r vendor target source; do
      python3 "$REPORTER" release-claim --history "$HISTORY_FILE" --target "$target" || true
    done < "$batch_file"
    rm -f "$batch_file" "$url_list_file"
    CURRENT_CLAIM_BATCH=""
    return "$scan_rc"
  fi
}
cmd_scan() {
  require_dependencies; validate_parameters; [ -n "$URL" ] || die 'scan 需要 --url <URL>。'
  if ! target_is_listed "$URL"; then
    [ "$ALLOW_UNLISTED" -eq 1 ] && [ "$ACK_AUTHORIZED" -eq 1 ] || die '目标不在公益 SRC TSV 中；请同时使用 --allow-unlisted --ack-authorized。'
  fi
  if [ "$FORCE" -ne 1 ] && target_is_scanned "$URL"; then die '目标已在扫描历史中；如需复核请使用 --force。'; fi
  local domain; domain="$(target_domain "$URL")" || die "无法解析目标主域名：$URL"
  local claim_args=()
  [ "$FORCE" -eq 1 ] && claim_args+=(--force)
  python3 "$REPORTER" claim-target --history "$HISTORY_FILE" --target "$URL" "${claim_args[@]}" || die '目标已被其他任务占用或已扫描；如需重扫请检查 --force。'
  CURRENT_CLAIM_TARGET="$URL"
  if run_scan "$URL" "$VENDOR" "$domain"; then
    CURRENT_CLAIM_TARGET=""
  else
    local scan_rc=$?
    python3 "$REPORTER" release-claim --history "$HISTORY_FILE" --target "$URL" || true
    CURRENT_CLAIM_TARGET=""
    return "$scan_rc"
  fi
}
cmd_report() {
  local json_file="" output_file="" vendor="" target="" status="manual" log_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) [ "$#" -ge 2 ] || die "$1 需要参数"; json_file="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die "$1 需要参数"; output_file="$2"; shift 2 ;;
      --vendor) [ "$#" -ge 2 ] || die "$1 需要参数"; vendor="$2"; shift 2 ;;
      --target) [ "$#" -ge 2 ] || die "$1 需要参数"; target="$2"; shift 2 ;;
      --scan-status) [ "$#" -ge 2 ] || die "$1 需要参数"; status="$2"; shift 2 ;;
      --log) [ "$#" -ge 2 ] || die "$1 需要参数"; log_file="$2"; shift 2 ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知报告参数：$1" ;;
    esac
  done
  [ -n "$json_file" ] || die 'report 需要 --json <file>。'; [ -n "$output_file" ] || output_file="${json_file%.json}.md"
  require_dependencies; python3 "$REPORTER" analyze --json "$json_file" --output "$output_file" --vendor "$vendor" --target "$target" --scan-status "$status" --log "$log_file"
  ok "Markdown 报告已生成：$output_file"
}

main() {
  [ "$#" -gt 0 ] || { show_help; exit 1; }; local command="$1"; shift
  case "$command" in
    scan-next) parse_options "$@"; cmd_scan_next ;;
    scan-batch) parse_options "$@"; cmd_scan_batch ;;
    scan) parse_options "$@"; cmd_scan ;;
    select-next) parse_options "$@"; cmd_select_next ;;
    report) cmd_report "$@" ;;
    -h|--help) show_help ;;
    *) die "未知命令：$command；运行 $(basename "$0") --help 查看帮助。" ;;
  esac
}
main "$@"

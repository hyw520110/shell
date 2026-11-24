#!/usr/bin/env bash
# 对 Nuclei 结果进行低影响、可复核的二次验证。
# 仅对你拥有或已获得明确授权的目标运行。

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_OUTPUT_DIR="${NUCLEI_DEFAULT_OUTPUT_DIR:-${NUCLEI_VERIFY_OUTPUT_DIR:-${HOME}/nuclei_scan}}"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
OUTPUT_DIR_EXPLICIT=0
TIMEOUT_SECONDS="${NUCLEI_VERIFY_TIMEOUT:-15}"
INSECURE=0
CHECK=""
TARGET=""
REPORT_FILE=""
APPEND_REPORT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf '[nuclei-verify] %s\n' "$*"; }
ok()   { printf "${GREEN}[确认] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[未确认] %s${NC}\n" "$*" >&2; }
die()  { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME --check <检查项> --url <URL> [选项]

  用途：对 Nuclei 已发现的单条结果做低影响复核，不替代 Nuclei 扫描；自动生成 Markdown 报告。

检查项：
  aspx-debug-mode   发送一次 DEBUG/stop-debug 请求，验证 ASP.NET 调试配置
  ds-store          下载目标 .DS_Store，验证是否公开可读且为 DS_Store 文件

选项：
  --check <id>      检查项或 Nuclei template-id
  --url <URL>       Nuclei 结果中的 matched-at/url
  --output-dir <dir> Nuclei 报告根目录，默认：$DEFAULT_OUTPUT_DIR
  --report-file <file> 将报告写入指定 Markdown 文件
  --append-report   将复核章节追加到指定报告，而不是覆盖报告
  --timeout <sec>   单次请求最长时间，默认：$TIMEOUT_SECONDS
  --insecure        跳过 TLS 证书校验；仅在明确理解风险时使用
  -h, --help        显示帮助

退出码：
  0                 复核确认
  2                 请求完成但未满足复核条件
  1                 参数、依赖或执行错误

报告：
  <目标目录>/verification.md       自动更新的单份最新复核报告
  <目标目录>/verification/         每次复核的原始证据目录

示例：
  $SCRIPT_NAME --check aspx-debug-mode --url https://example.com/Foobar-debug.aspx
  $SCRIPT_NAME --check ds-store --url https://example.com/.DS_Store
EOF
}

is_positive_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

validate_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

safe_name() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's#^[a-zA-Z]+://##; s#[?#].*$##; s#/+#_#g; s#[^A-Za-z0-9._-]#_#g')"
  [ -n "$value" ] || value="target"
  printf '%s\n' "$value" | cut -c1-160
}

extract_host() {
  local value="$1"
  value="${value#*://}"
  value="${value#*@}"
  value="${value%%/*}"
  value="${value%%\?*}"
  value="${value%%\#*}"
  case "$value" in
    \[*\]*) value="${value#\[}"; value="${value%%\]*}" ;;
    *:*) value="${value%%:*}" ;;
  esac
  value="${value%.}"
  printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}

extract_registrable_domain() {
  local host="$1" domain
  case "$host" in www.*) host="${host#www.}" ;; esac
  case "$host" in
    *.co.uk|*.org.uk|*.ac.uk|*.gov.uk|*.com.cn|*.net.cn|*.org.cn|*.com.au|*.net.au|*.org.au|*.co.jp|*.com.hk|*.com.tw|*.co.kr)
      domain="$(printf '%s\n' "$host" | awk -F. '{print $(NF-2) "." $(NF-1) "." $NF}')" ;;
    *) domain="$(printf '%s\n' "$host" | awk -F. '{if (NF >= 2) print $(NF-1) "." $NF; else print $NF}')" ;;
  esac
  printf '%s\n' "$domain"
}

target_output_dir() {
  local host domain safe
  host="$(extract_host "$TARGET")"
  domain="$(extract_registrable_domain "$host")"
  safe="$(printf '%s\n' "$domain" | tr -cd 'a-z0-9.-')"
  [ -n "$safe" ] || safe="target"
  printf '%s/%s\n' "$OUTPUT_DIR" "$safe"
}

request_path() {
  local value="${1#*://}"
  case "$value" in
    */*) printf '/%s\n' "${value#*/}" ;;
    *) printf '/\n' ;;
  esac
}

write_hash() {
  local file="$1" output="$2"
  if has shasum; then
    shasum -a 256 "$file" > "$output"
  elif has sha256sum; then
    sha256sum "$file" > "$output"
  else
    printf 'unavailable\n' > "$output"
  fi
}

curl_common_args() {
  if [ "$INSECURE" -eq 1 ]; then
    printf '%s\n' '-k'
  fi
}

header_value() {
  local name="$1" file="$2"
  awk -v wanted="$name" '
    BEGIN { IGNORECASE=1 }
    index($0, ":") {
      key=$0; sub(/:.*/, "", key)
      if (key == wanted) { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }
    }
  ' "$file"
}

write_report() {
  local target_dir="$1" evidence_dir="$2" check_rc="$3" report_file result conclusion impact remediation evidence_rel
  if [ -n "$REPORT_FILE" ]; then
    report_file="$REPORT_FILE"
  else
    report_file="$target_dir/verification.md"
  fi
  evidence_rel="${evidence_dir#"$target_dir"/}"

  if [ "$check_rc" -eq 0 ]; then
    result='确认'
  elif [ "$check_rc" -eq 2 ]; then
    result='未确认'
  else
    result='执行错误'
  fi

  case "$CHECK" in
    aspx-debug-mode)
      conclusion='已复现 Nuclei 的 ASP.NET DEBUG 检查条件：目标接受一次 DEBUG/stop-debug 请求并返回 200/OK。'
      impact='这证明调试相关配置或处理链存在风险；仅凭该响应不能证明远程代码执行、认证绕过或敏感数据泄露。'
      remediation='生产环境关闭 ASP.NET debug；检查 web.config 的 compilation/debug 与 customErrors 配置；在 IIS/反向代理层限制 DEBUG 方法；变更后重新复核。'
      ;;
    ds-store)
      conclusion='已验证目标公开返回可识别的 .DS_Store 文件。'
      impact='实际影响取决于文件是否暴露目录名、文件名或内部路径；仅有 Finder 元数据时通常属于低价值信息暴露。'
      remediation='从 Web 发布目录移除 .DS_Store，并在发布流程中禁止生成或上传该文件；变更后确认返回 404/403。'
      ;;
    *)
      conclusion='检查项未定义。'
      impact='无法评估。'
      remediation='选择受支持的检查项。'
      ;;
  esac

  if [ "$APPEND_REPORT" -eq 1 ]; then
    {
      printf '\n---\n\n## 复核结果：%s\n\n' "$CHECK"
      printf -- '- 生成时间：`%s`\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
      printf -- '- 目标：`%s`\n' "$TARGET"
      printf -- '- 复核结论：**%s**\n' "$result"
      printf -- '- 脚本退出码：`%s`\n\n' "$check_rc"
      printf '### 结论\n\n%s\n\n' "$conclusion"
      printf '### 影响边界\n\n%s\n\n' "$impact"
      printf '### 修复建议\n\n%s\n\n' "$remediation"
      printf '### 请求与响应摘要\n\n'
      if [ -s "$evidence_dir/summary.txt" ]; then
        printf '```text\n'
        sed -n '1,80p' "$evidence_dir/summary.txt"
        printf '```\n\n'
      else
        printf '本次请求未产生完整摘要。\n\n'
      fi
      printf '### 证据文件\n\n'
      printf -- '- [summary.txt](%s/summary.txt)\n- [headers.txt](%s/headers.txt)\n' "$evidence_rel" "$evidence_rel"
      if [ -f "$evidence_dir/body.bin" ]; then
        printf -- '- [body.bin](%s/body.bin)\n' "$evidence_rel"
      fi
      if [ -f "$evidence_dir/request.txt" ]; then
        printf -- '- [request.txt](%s/request.txt)\n' "$evidence_rel"
      fi
      if [ -f "$evidence_dir/body.sha256" ]; then
        printf -- '- [body.sha256](%s/body.sha256)\n' "$evidence_rel"
      fi
      printf '\n> 该复核只记录低影响验证结果，不代表已执行主动利用。\n'
    } >> "$report_file"
  else
    {
      printf '# Nuclei 复核报告\n\n'
      printf -- '- 生成时间：`%s`\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
      printf -- '- 检查项：`%s`\n' "$CHECK"
      printf -- '- 目标：`%s`\n' "$TARGET"
      printf -- '- 复核结论：**%s**\n' "$result"
      printf -- '- 脚本退出码：`%s`\n\n' "$check_rc"
      printf '## 结论\n\n%s\n\n' "$conclusion"
      printf '## 影响边界\n\n%s\n\n' "$impact"
      printf '## 修复建议\n\n%s\n\n' "$remediation"
      printf '## 请求与响应摘要\n\n'
      if [ -s "$evidence_dir/summary.txt" ]; then
        printf '```text\n'
        sed -n '1,80p' "$evidence_dir/summary.txt"
        printf '```\n\n'
      else
        printf '本次请求未产生完整摘要。\n\n'
      fi
      printf '## 证据文件\n\n'
      printf -- '- [summary.txt](%s/summary.txt)\n- [headers.txt](%s/headers.txt)\n' "$evidence_rel" "$evidence_rel"
      if [ -f "$evidence_dir/body.bin" ]; then
        printf -- '- [body.bin](%s/body.bin)\n' "$evidence_rel"
      fi
      if [ -f "$evidence_dir/request.txt" ]; then
        printf -- '- [request.txt](%s/request.txt)\n' "$evidence_rel"
      fi
      if [ -f "$evidence_dir/body.sha256" ]; then
        printf -- '- [body.sha256](%s/body.sha256)\n' "$evidence_rel"
      fi
      printf '\n> 该报告只记录低影响复核结果，不代表已执行主动利用。\n'
    } > "$report_file"
  fi
  log "复核报告：$report_file"
}

run_aspx_debug_check() {
  local evidence_dir="$1" curl_args=() status size body server powered
  [ "${TARGET##*/}" = "Foobar-debug.aspx" ] ||
    log "提示：目标路径不是 Foobar-debug.aspx，将按传入 URL 复核。"

  while IFS= read -r arg; do curl_args+=("$arg"); done < <(curl_common_args)
  status="$(
    curl "${curl_args[@]}" -sS --http1.1 -X DEBUG \
      -H 'Command: stop-debug' \
      -H 'Content-Length: 2' \
      --data-binary $'\r\n' \
      -D "$evidence_dir/headers.txt" \
      -o "$evidence_dir/body.bin" \
      --connect-timeout 5 \
      --max-time "$TIMEOUT_SECONDS" \
      -w '%{http_code}' \
      "$TARGET"
  )" || {
    printf 'check=aspx-debug-mode\nurl=%s\nresult=request-error\n' "$TARGET" > "$evidence_dir/summary.txt"
    warn "请求失败；证据目录：$evidence_dir"
    return 1
  }
  {
    printf 'DEBUG %s HTTP/1.1\r\n' "$(request_path "$TARGET")"
    printf 'Host: %s\r\nCommand: stop-debug\r\nContent-Length: 2\r\n\r\n\r\n' "$(extract_host "$TARGET")"
  } > "$evidence_dir/request.txt"
  size="$(wc -c < "$evidence_dir/body.bin" | tr -d ' ')"
  body="$(tr -d '\r\n' < "$evidence_dir/body.bin")"
  server="$(header_value Server "$evidence_dir/headers.txt")"
  powered="$(header_value X-Powered-By "$evidence_dir/headers.txt")"

  {
    printf 'check=aspx-debug-mode\nurl=%s\nstatus=%s\nbody_bytes=%s\nbody=%s\n' \
      "$TARGET" "$status" "$size" "$body"
    printf 'server=%s\nx-powered-by=%s\n' "$server" "$powered"
  } > "$evidence_dir/summary.txt"
  write_hash "$evidence_dir/body.bin" "$evidence_dir/body.sha256"

  printf 'HTTP 状态：%s，响应体：%s 字节，内容：%s\n' "$status" "$size" "${body:-<empty>}"
  [ "$status" = '200' ] && [ "$size" = '2' ] && [ "$body" = 'OK' ] || {
    warn "未复现 ASP.NET DEBUG 的匹配条件；证据目录：$evidence_dir"
    return 2
  }
  ok "已复现 DEBUG/stop-debug 响应；这确认了配置风险，不等于已获得代码执行。证据目录：$evidence_dir"
}

run_ds_store_check() {
  local evidence_dir="$1" curl_args=() status size content_type signature
  while IFS= read -r arg; do curl_args+=("$arg"); done < <(curl_common_args)
  status="$(
    curl "${curl_args[@]}" -sS \
      -D "$evidence_dir/headers.txt" \
      -o "$evidence_dir/body.bin" \
      --connect-timeout 5 \
      --max-time "$TIMEOUT_SECONDS" \
      -w '%{http_code}' \
      "$TARGET"
  )" || {
    printf 'check=ds-store\nurl=%s\nresult=request-error\n' "$TARGET" > "$evidence_dir/summary.txt"
    warn "请求失败；证据目录：$evidence_dir"
    return 1
  }
  {
    printf 'GET %s HTTP/1.1\r\n' "$(request_path "$TARGET")"
    printf 'Host: %s\r\n\r\n' "$(extract_host "$TARGET")"
  } > "$evidence_dir/request.txt"
  size="$(wc -c < "$evidence_dir/body.bin" | tr -d ' ')"
  content_type="$(header_value Content-Type "$evidence_dir/headers.txt")"
  signature="$(od -An -tx1 -N4 "$evidence_dir/body.bin" | tr -d ' \n')"
  {
    printf 'check=ds-store\nurl=%s\nstatus=%s\nbody_bytes=%s\ncontent_type=%s\nsignature=%s\n' \
      "$TARGET" "$status" "$size" "$content_type" "$signature"
    if has file; then file "$evidence_dir/body.bin"; fi
  } > "$evidence_dir/summary.txt"
  write_hash "$evidence_dir/body.bin" "$evidence_dir/body.sha256"

  printf 'HTTP 状态：%s，响应体：%s 字节，Content-Type：%s，文件签名：%s\n' \
    "$status" "$size" "${content_type:-<empty>}" "${signature:-<empty>}"
  [ "$status" = '200' ] && [ -s "$evidence_dir/body.bin" ] && [ "$signature" = '00000001' ] || {
    warn "未确认公开可读的 DS_Store 文件；证据目录：$evidence_dir"
    return 2
  }
  ok "已确认目标公开返回 DS_Store 文件；这只证明信息暴露，影响等级仍需结合文件内容评估。证据目录：$evidence_dir"
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) [ "$#" -ge 2 ] || die "$1 需要参数"; CHECK="$2"; shift 2 ;;
      --url) [ "$#" -ge 2 ] || die "$1 需要参数"; TARGET="$2"; shift 2 ;;
      --output-dir) [ "$#" -ge 2 ] || die "$1 需要参数"; OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=1; shift 2 ;;
      --report-file) [ "$#" -ge 2 ] || die "$1 需要参数"; REPORT_FILE="$2"; shift 2 ;;
      --append-report) APPEND_REPORT=1; shift ;;
      --timeout) [ "$#" -ge 2 ] || die "$1 需要参数"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      --insecure) INSECURE=1; shift ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知参数：$1；运行 $SCRIPT_NAME --help 查看帮助。" ;;
    esac
  done

  has curl || die '缺少 curl。'
  [ -n "$CHECK" ] || die '必须提供 --check。'
  [ -n "$TARGET" ] || die '必须提供 --url。'
  validate_url "$TARGET" || die 'URL 仅支持 http:// 或 https://。'
  is_positive_integer "$TIMEOUT_SECONDS" || die 'timeout 必须是大于 0 的整数。'
  if [ "$APPEND_REPORT" -eq 1 ] && [ -z "$REPORT_FILE" ]; then
    die '--append-report 必须与 --report-file 一起使用。'
  fi
  if [ -n "$REPORT_FILE" ]; then
    mkdir -p "$(dirname "$REPORT_FILE")"
  fi

  case "$CHECK" in
    aspx-debug-mode|ds-store) ;;
    *) die "暂不支持检查项：${CHECK}；可用：aspx-debug-mode、ds-store。" ;;
  esac

  local target_dir evidence_dir
  if [ "$OUTPUT_DIR_EXPLICIT" -eq 1 ]; then
    target_dir="$OUTPUT_DIR"
  else
    target_dir="$(target_output_dir)"
  fi
  evidence_dir="$target_dir/verification/${CHECK}_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$evidence_dir"
  log "证据目录：$evidence_dir"
  local check_rc=0
  case "$CHECK" in
    aspx-debug-mode) run_aspx_debug_check "$evidence_dir" || check_rc=$? ;;
    ds-store) run_ds_store_check "$evidence_dir" || check_rc=$? ;;
  esac
  write_report "$target_dir" "$evidence_dir" "$check_rc"
  return "$check_rc"
}

main "$@"

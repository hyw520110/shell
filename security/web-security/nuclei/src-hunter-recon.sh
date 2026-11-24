#!/usr/bin/env bash
# SRC 环境诊断和限时侦察；由 src-hunter.sh 加载，不自行启动扫描。

is_kali() {
  [ -f /etc/kali_version ] || { [ -f /etc/os-release ] && grep -qE '^ID=("kali"|kali)$' /etc/os-release; }
}
kali_recon_enabled() {
  case "${KALI_RECON:-auto}" in
    0) return 1 ;;
    1) return 0 ;;
    *) is_kali ;;
  esac
}
resolve_httpx() {
  local candidate
  for candidate in httpx-toolkit httpx; do
    if has "$candidate" && "$candidate" -h 2>&1 | grep -F 'tech-detect' >/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}
doctor() {
  local tool executable
  if is_kali; then log '系统：Kali'; else log "系统：$(uname -s)"; fi
  executable=$(resolve_httpx || true)
  log "ProjectDiscovery HTTPX：${executable:-未找到（不会使用同名 Python httpx）}"
  for tool in nuclei curl dig whatweb subfinder wafw00f whois nmap nikto sqlmap sslscan; do
    executable=$(command -v "$tool" 2>/dev/null || true)
    log "${tool}：${executable:-未安装}"
  done
  log '默认：仅当前授权 URL 的可达性、DNS、低强度指纹；侦察有超时和独立日志。'
  log '子域主动探测需要 KALI_RECON_SUBDOMAINS=1 和 SRC_RECON_ALLOWLIST_FILE；nmap/WAF 需显式启用。'
  log 'Nikto/SQLmap/SSLscan 仅显示安装状态，不自动启动主动扫描。'
}
run_recon_command() {
  local dir="$1" tool="$2" output="$3" seconds="$4" rc=0
  shift 4
  python3 - "$output" "$seconds" "$@" <<'PY' || rc=$?
import subprocess
import sys
with open(sys.argv[1], 'w', encoding='utf-8') as out, open(sys.argv[1] + '.stderr.log', 'w', encoding='utf-8') as err:
    try:
        result = subprocess.run(sys.argv[3:], stdout=out, stderr=err, timeout=int(sys.argv[2]), check=False)
        raise SystemExit(result.returncode)
    except subprocess.TimeoutExpired:
        err.write('SRC reconnaissance timeout\n')
        raise SystemExit(124)
    except OSError as exc:
        err.write(type(exc).__name__ + '\n')
        raise SystemExit(127)
PY
  printf '%s\t%s\t%s\n' "$tool" "$rc" "$(basename "$output")" >> "$dir/status.tsv"
  if [ "$rc" -ne 0 ]; then warn "$tool 未完成（退出码 $rc），详情：$output.stderr.log"; fi
  return "$rc"
}
run_kali_recon() {
  local domain="$1" dir="$2" target="$3" httpx_bin host
  mkdir -p "$dir"
  : > "$dir/status.tsv"
  : > "$dir/live-urls.txt"
  : > "$dir/subdomains.txt"
  printf '%s\n' "$target" > "$dir/probe-targets.txt"
  host=$(python3 "$REPORTER" host --target "$target")
  if has curl; then
    # 不跟随重定向、不下载响应内容；HTTP 4xx/5xx 仍视为已建立 HTTP 连接。
    run_recon_command "$dir" curl "$dir/reachability.tsv" 20 \
      curl -sS --connect-timeout 5 --max-time 12 --max-redirs 0 --proto '=http,https' \
      -o /dev/null -w '%{http_code}\t%{time_total}\n' "$target" || true
  fi
  if has dig; then
    run_recon_command "$dir" dig "$dir/dns.txt" 10 dig +time=3 +tries=1 +short "$host" || true
  fi
  if has subfinder && [ "${KALI_RECON_SUBDOMAINS:-0}" = 1 ]; then
    run_recon_command "$dir" subfinder "$dir/subdomains.txt" 45 \
      subfinder -d "$domain" -silent -timeout 5 -max-time 1 || true
    if [ -n "${SRC_RECON_ALLOWLIST_FILE:-}" ] && [ -f "$SRC_RECON_ALLOWLIST_FILE" ]; then
      python3 "$REPORTER" filter-scope --input "$dir/subdomains.txt" \
        --allowlist "$SRC_RECON_ALLOWLIST_FILE" --limit 20 >> "$dir/probe-targets.txt"
    else
      warn '子域仅发现、不探测：尚未提供 SRC_RECON_ALLOWLIST_FILE 显式授权清单。'
    fi
  fi
  httpx_bin=$(resolve_httpx || true)
  if [ -n "$httpx_bin" ]; then
    run_recon_command "$dir" httpx "$dir/live.txt" 60 "$httpx_bin" \
      -l "$dir/probe-targets.txt" -silent -status-code -title -tech-detect -cdn \
      -threads 2 -rate-limit 2 -timeout 8 -retries 0 -no-fallback-scheme -disable-update-check || true
    # 输出必须再次按输入授权清单过滤，不根据响应中的域名扩大范围。
    python3 "$REPORTER" filter-scope --input "$dir/live.txt" --allowlist "$dir/probe-targets.txt" \
      --limit 21 > "$dir/live-urls.txt"
  else
    printf 'httpx\tskipped\t工具缺失或为 Python HTTP 客户端\n' >> "$dir/status.tsv"
  fi
  if has whatweb; then
    run_recon_command "$dir" whatweb "$dir/whatweb.txt" 25 whatweb \
      --aggression=1 --max-threads=1 --open-timeout=5 --read-timeout=10 --follow-redirect=never "$target" || true
  fi
  if [ "${KALI_RECON_WAF:-0}" = 1 ] && has wafw00f; then
    run_recon_command "$dir" wafw00f "$dir/waf.txt" 30 wafw00f -r "$target" || true
  fi
  if [ "${KALI_RECON_NMAP:-0}" = 1 ] && has nmap; then
    run_recon_command "$dir" nmap "$dir/nmap.txt" 40 nmap \
      -sT -Pn -n --top-ports 20 --max-rate 10 --max-retries 1 --host-timeout 30s "$host" || true
  fi
  return 0
}
run_kali_batch_recon() {
  local list_file="$1" dir="$2" httpx_bin
  mkdir -p "$dir"
  : > "$dir/status.tsv"
  httpx_bin=$(resolve_httpx || true)
  if [ -n "$httpx_bin" ]; then
    run_recon_command "$dir" httpx "$dir/live.txt" 90 "$httpx_bin" \
      -l "$list_file" -silent -status-code -title -tech-detect -cdn \
      -threads 2 -rate-limit 2 -timeout 8 -retries 0 -no-fallback-scheme -disable-update-check || true
  else
    printf 'httpx\tskipped\t工具缺失或为 Python HTTP 客户端\n' >> "$dir/status.tsv"
  fi
}

append_recon_summary() {
  local domain="$1" dir="$2" report_file="$3"
  [ -f "$dir/status.tsv" ] || return 0
  local relative_dir
  relative_dir=$(basename "$dir")
  {
    printf '\n## Kali 工具执行状态\n\n'
    printf '| 工具 | 退出码/状态 | 输出文件 |\n| --- | --- | --- |\n'
    while IFS=$'\t' read -r tool status output; do
      printf '| %s | %s | %s/%s |\n' "$tool" "$status" "$relative_dir" "$output"
    done < "$dir/status.tsv"
    printf '\n指纹、WAF 和开放端口是侦察信息，不等于已确认漏洞；非零退出码表示工具未完成。\n'
    printf '\n仅对显式授权输入进行探测；发现域名不会自动获得扫描授权。\n'
  } >> "$report_file"
}

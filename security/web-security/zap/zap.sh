#!/usr/bin/env bash
# OWASP ZAP 安装和基线扫描辅助脚本。
# Docker 可用时使用官方 ZAP 镜像；Docker 不可用时，macOS 回退到原生 ZAP。
# 基线扫描包含爬虫和被动检查，不执行主动攻击；仅扫描明确获准的目标。

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ZAP_IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${HOME}/security-scans/zap}"
ZAP_APP_PATH="${ZAP_APP_PATH:-/Applications/ZAP.app}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf '[zap] %s\n' "$*"; }
ok()   { printf "${GREEN}[完成] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[警告] %s${NC}\n" "$*" >&2; }
die()  { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME <命令> [选项]

命令：
  install                    Docker 可用时拉取镜像，否则安装 macOS 原生 ZAP
  status                     查看 Docker 镜像或原生 ZAP 状态
  baseline                   被动基线扫描（也可省略该命令）

选项：
  -u, --url <URL>            目标 URL（必填）
  -o, --output-dir <目录>    输出目录，默认 ~/security-scans/zap/<主域名>
  -f, --format <格式>        html、json、xml、all，默认 all
  -T, --max-minutes <数字>   最大扫描时间（分钟），默认 5
  -h, --help                 显示帮助

示例：
  $SCRIPT_NAME install
  $SCRIPT_NAME baseline -u https://example.com/ -T 10
  $SCRIPT_NAME -u https://example.com/ -f html

说明：Docker 模式的 baseline 只做爬取和被动分析，不执行主动漏洞利用；如需更强测试，
请在 ZAP GUI 中确认授权范围、排除规则和速率后再手动启动主动扫描。
Docker 不可用时会安装原生 ZAP；原生模式请使用 ZAP GUI 的 Quick Start，
自动化 baseline 命令仍需要 Docker。
EOF
}

docker_ready() { has docker && docker info >/dev/null 2>&1; }
native_zap_available() { [ -d "$ZAP_APP_PATH" ]; }
extract_host() {
  local value="$1"
  value="${value#*://}"; value="${value#*@}"; value="${value%%/*}"; value="${value%%:*}"
  value="${value%.}"; printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
}
registrable_domain() {
  local host="${1#www.}"
  case "$host" in
    *.co.uk|*.org.uk|*.ac.uk|*.gov.uk|*.com.cn|*.net.cn|*.org.cn|*.com.au|*.net.au|*.org.au|*.co.jp|*.com.hk|*.com.tw|*.co.kr)
      printf '%s\n' "$host" | awk -F. '{print $(NF-2) "." $(NF-1) "." $NF}' ;;
    *) printf '%s\n' "$host" | awk -F. '{if (NF >= 2) print $(NF-1) "." $NF; else print $NF}' ;;
  esac
}

cmd_install() {
  if docker_ready; then
    log "拉取官方 ZAP Docker 镜像：$ZAP_IMAGE"
    docker pull "$ZAP_IMAGE"
    ok 'ZAP Docker 镜像已准备好。'
    return 0
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    if native_zap_available; then
      ok "检测到原生 ZAP：$ZAP_APP_PATH"
      return 0
    fi
    has brew || die 'Docker 未安装或未启动，且未找到 Homebrew。请从 https://www.zaproxy.org/download/ 安装 macOS 原生 ZAP。'
    warn 'Docker 未安装或未启动，改用 macOS 原生 ZAP 安装。'
    brew install --cask zap
    native_zap_available || die "Homebrew 安装完成但未找到 ZAP：$ZAP_APP_PATH"
    ok "原生 ZAP 安装完成：$ZAP_APP_PATH"
    return 0
  fi

  die 'Docker 未安装或未启动；当前仅支持 macOS 自动回退到原生 ZAP，请先安装 Docker。'
}

cmd_status() {
  if docker_ready; then
    if docker image inspect "$ZAP_IMAGE" >/dev/null 2>&1; then
      docker image inspect "$ZAP_IMAGE" --format 'mode=docker image={{.RepoTags}} id={{.Id}} created={{.Created}}'
    else
      log "Docker 可用，但未找到镜像：$ZAP_IMAGE；请先运行 install。"
    fi
  elif native_zap_available; then
    printf 'mode=native app=%s\n' "$ZAP_APP_PATH"
  else
    die 'Docker 未运行，且未检测到原生 ZAP。请先运行 install。'
  fi
}

cmd_baseline() {
  local url='' output_dir='' format='all' max_minutes=5
  local host domain html json xml
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u|--url) [ "$#" -ge 2 ] || die "$1 需要参数"; url="$2"; shift 2 ;;
      -o|--output-dir) [ "$#" -ge 2 ] || die "$1 需要参数"; output_dir="$2"; shift 2 ;;
      -f|--format) [ "$#" -ge 2 ] || die "$1 需要参数"; format="$2"; shift 2 ;;
      -T|--max-minutes) [ "$#" -ge 2 ] || die "$1 需要参数"; max_minutes="$2"; shift 2 ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ -n "$url" ] || die '需要 --url/-u。'
  case "$format" in html|json|xml|all) ;; *) die '--format/-f 只支持 html、json、xml、all。' ;; esac
  if ! docker_ready; then
    native_zap_available || cmd_install
    die '当前为原生 ZAP 模式；baseline 自动化命令需要 Docker。请启动 Docker 后重试，或打开 ZAP GUI 使用 Quick Start。'
  fi
  docker image inspect "$ZAP_IMAGE" >/dev/null 2>&1 || cmd_install
  host="$(extract_host "$url")"; domain="$(registrable_domain "$host")"; output_dir="${output_dir:-${OUTPUT_ROOT}/${domain}}"
  mkdir -p "$output_dir"; html="${output_dir}/zap-baseline.html"; json="${output_dir}/zap-baseline.json"; xml="${output_dir}/zap-baseline.xml"
  rm -f "$html" "$json" "$xml"
  local args=(zap-baseline.py -t "$url" -T "$max_minutes")
  case "$format" in
    html) args+=(-r zap-baseline.html) ;;
    json) args+=(-J zap-baseline.json) ;;
    xml) args+=(-x zap-baseline.xml) ;;
    all) args+=(-r zap-baseline.html -J zap-baseline.json -x zap-baseline.xml) ;;
  esac
  log "输出目录：$output_dir"; log "目标：$url"; log '模式：baseline（爬取 + 被动分析）'
  docker run --rm -t -v "${output_dir}:/zap/wrk/:rw" "$ZAP_IMAGE" "${args[@]}"
  ok "ZAP 基线扫描完成。报告目录：$output_dir"
}

command_name="${1:-}"
case "$command_name" in
  install) shift; cmd_install ;;
  status) shift; cmd_status ;;
  baseline) shift; cmd_baseline "$@" ;;
  help|-h|--help|'') show_help ;;
  -u|--url|*) cmd_baseline "$@" ;;
esac

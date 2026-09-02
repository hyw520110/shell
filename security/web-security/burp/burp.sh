#!/usr/bin/env bash
# Burp Suite 安装、启动和本地代理配置辅助脚本。
# Burp 的主动扫描、拦截和重放请在 GUI 中确认授权范围后手动操作。

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
BURP_MEMORY="${BURP_MEMORY:-4g}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf '[burp] %s\n' "$*"; }
ok()   { printf "${GREEN}[完成] %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[警告] %s${NC}\n" "$*" >&2; }
die()  { printf "${RED}[错误] %s${NC}\n" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME <命令> [选项]

命令：
  install                    通过 Homebrew 安装 Burp Suite cask
  status                     检测 Burp 应用、JAR 和 Java
  start                      启动 Burp GUI 或 JAR
  proxy                      显示浏览器/系统代理配置

选项：
      --jar <文件>           指定 burp.jar
      --project <文件>       启动时打开项目文件（JAR 模式）
      --config <文件>        启动时加载 Burp 配置（JAR 模式）
      --memory <大小>        Java 堆大小，默认 ${BURP_MEMORY}
  -h, --help                 显示帮助

示例：
  $SCRIPT_NAME install
  $SCRIPT_NAME status
  $SCRIPT_NAME start
  $SCRIPT_NAME start --jar ~/Applications/burp.jar --memory 4g
  $SCRIPT_NAME proxy

说明：Burp Suite Community/Professional 的下载和授权以 PortSwigger 官方页面为准。
JAR 启动要求 Java 21 或更高版本；macOS 应用安装包自带运行环境。
EOF
}

find_app() {
  local app
  for app in \
    "/Applications/Burp Suite Professional.app" \
    "/Applications/Burp Suite Community Edition.app" \
    "/Applications/Burp Suite.app" \
    "$HOME/Applications/Burp Suite Professional.app" \
    "$HOME/Applications/Burp Suite Community Edition.app" \
    "$HOME/Applications/Burp Suite.app"; do
    [ -d "$app" ] && { printf '%s\n' "$app"; return 0; }
  done
  return 1
}

find_jar() {
  local candidate="${BURP_JAR:-}"
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  for candidate in "$HOME/Applications/burp.jar" "$HOME/Downloads/burp.jar" "$HOME/Downloads/burpsuite_pro.jar"; do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

cmd_install() {
  has brew || die '未找到 Homebrew。请先安装 Homebrew，或从 https://portswigger.net/burp/downloads 下载官方 macOS 安装包。'
  log '通过 Homebrew 安装官方 cask：burp-suite'
  brew install --cask burp-suite
  ok 'Burp Suite 安装命令已完成。'
}

cmd_status() {
  local app='' jar=''
  app="$(find_app || true)"; jar="$(find_jar || true)"
  [ -n "$app" ] && printf 'app:  %s\n' "$app" || printf 'app:  not detected\n'
  [ -n "$jar" ] && printf 'jar:  %s\n' "$jar" || printf 'jar:  not detected\n'
  if has java; then java -version 2>&1 | head -n 1; else printf 'java: not detected\n'; fi
}

cmd_proxy() {
  cat <<'EOF'
Burp 默认监听地址：127.0.0.1:8080

浏览器配置：
  HTTP 代理：127.0.0.1  端口：8080
  HTTPS 代理：127.0.0.1  端口：8080

首次抓取 HTTPS 时，请在 Burp 中打开 http://burp 下载并安装 CA 证书，
并只把已获准测试的站点加入 Target scope；完成后关闭浏览器代理即可恢复直连。
EOF
}

cmd_start() {
  local jar='' project='' config='' memory="$BURP_MEMORY" app
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jar) [ "$#" -ge 2 ] || die '--jar 需要参数'; jar="$2"; shift 2 ;;
      --project) [ "$#" -ge 2 ] || die '--project 需要参数'; project="$2"; shift 2 ;;
      --config) [ "$#" -ge 2 ] || die '--config 需要参数'; config="$2"; shift 2 ;;
      --memory) [ "$#" -ge 2 ] || die '--memory 需要参数'; memory="$2"; shift 2 ;;
      -h|--help) show_help; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  if [ -z "$jar" ]; then jar="$(find_jar || true)"; fi
  if [ -n "$jar" ]; then
    [ -f "$jar" ] || die "JAR 不存在：$jar"; has java || die 'JAR 模式需要 Java 21+。'
    local args=(-Xmx"$memory" -jar "$jar")
    [ -n "$project" ] && args+=(--project-file "$project")
    [ -n "$config" ] && args+=(--config-file "$config")
    log "启动 Burp JAR：$jar"; exec java "${args[@]}"
  fi
  app="$(find_app || true)"
  [ -n "$app" ] || die '未检测到 Burp Suite。请先运行 install，或使用 --jar 指定官方 JAR。'
  log "启动 Burp：$app"; open -a "$app"
}

command_name="${1:-}"
case "$command_name" in
  install) shift; cmd_install ;;
  status) shift; cmd_status ;;
  start) shift; cmd_start "$@" ;;
  proxy) shift; cmd_proxy ;;
  -h|--help|'') show_help ;;
  *) die "未知命令：$command_name" ;;
esac

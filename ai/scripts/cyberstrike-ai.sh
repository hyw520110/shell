#!/usr/bin/env bash
# CyberStrikeAI 本地安装与生命周期管理封装。
#
# 设计边界：
#   - 仅支持 macOS/Linux 的本地部署；默认绑定 127.0.0.1。
#   - 安装源码后固定到实际解析出的 Git commit，更新前备份配置和数据。
#   - 不自动启用 C2、WebShell、外部 MCP 或远程暴露。
#   - 报告、配置、数据库和源码均保存在用户目录，不写入当前仓库之外的临时目录。

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"

CYBERSTRIKE_REPOSITORY="${CYBERSTRIKE_REPOSITORY:-https://github.com/Ed1s0nZ/CyberStrikeAI.git}"
CYBERSTRIKE_REF="${CYBERSTRIKE_REF:-main}"
CYBERSTRIKE_ROOT="${CYBERSTRIKE_ROOT:-${HOME}/.local/share/cyberstrike-ai}"
CYBERSTRIKE_BINARY="${CYBERSTRIKE_BINARY:-$CYBERSTRIKE_ROOT/cyberstrike-ai}"
CYBERSTRIKE_CONFIG="${CYBERSTRIKE_CONFIG:-$CYBERSTRIKE_ROOT/config.yaml}"
CYBERSTRIKE_LOG_DIR="${CYBERSTRIKE_LOG_DIR:-$CYBERSTRIKE_ROOT/logs}"
CYBERSTRIKE_BACKUP_DIR="${CYBERSTRIKE_BACKUP_DIR:-$CYBERSTRIKE_ROOT/backups}"
CYBERSTRIKE_PID_FILE="${CYBERSTRIKE_PID_FILE:-$CYBERSTRIKE_ROOT/cyberstrike-ai.pid}"
CYBERSTRIKE_PORT="${CYBERSTRIKE_PORT:-8080}"
MARKER="$CYBERSTRIKE_ROOT/.managed-by-shell"

die() { printf '[cyberstrike-ai][错误] %s\n' "$*" >&2; exit 1; }
log() { printf '[cyberstrike-ai] %s\n' "$*"; }
ok() { printf '[cyberstrike-ai][完成] %s\n' "$*"; }
warn() { printf '[cyberstrike-ai][警告] %s\n' "$*" >&2; }
has() { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
CyberStrikeAI 本地安装与生命周期管理

用法：$(basename "$0") <命令>

命令：
  install              克隆、创建 Python 环境并构建本地服务
  update               备份后更新源码并重新构建
  start                以 localhost HTTPS 服务启动
  stop                 停止本脚本启动的服务
  restart              重启服务
  status               查看安装、版本和进程状态
  uninstall --yes      删除本脚本创建的用户目录

环境变量：
  CYBERSTRIKE_REPOSITORY  Git 仓库，默认上游 README 使用的 Ed1s0nZ/CyberStrikeAI
  CYBERSTRIKE_REF         分支、标签或提交，默认 main；安装后记录实际 commit
  CYBERSTRIKE_ROOT        安装根目录，默认 ~/.local/share/cyberstrike-ai
  CYBERSTRIKE_PORT        状态提示端口，默认 8080

安全默认：绑定 127.0.0.1；使用仓库示例配置的本地自签 HTTPS；
不自动配置 API Key，不启用 C2/WebShell/外部 MCP，不进行远程扫描或自动提交。
EOF
}

require_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin|Linux) ;;
    *) die "不支持的操作系统：$(uname -s 2>/dev/null)" ;;
  esac
}

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    has "$command_name" || missing+=("$command_name")
  done
  [ "${#missing[@]}" -eq 0 ] || die "缺少依赖：${missing[*]}"
}

validate_root_path() {
  case "$CYBERSTRIKE_ROOT" in
    ''|/|.|..|"$HOME"|"$HOME/"*)
      die "拒绝使用过宽的安装目录：$CYBERSTRIKE_ROOT"
      ;;
  esac
}

check_go_version() {
  local version major minor
  version="$(go version | awk '{print $3}' | sed 's/^go//')"
  IFS=. read -r major minor _ <<EOF
$version
EOF
  major="${major:-0}"; minor="${minor:-0}"
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 25 ]; }; then
    die "CyberStrikeAI 需要 Go 1.25+，当前为 Go $version"
  fi
  log "Go 版本满足要求：$version"
}

check_python_version() {
  local version major minor
  version="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  IFS=. read -r major minor <<EOF
$version
EOF
  if [ "${major:-0}" -lt 3 ] || { [ "${major:-0}" -eq 3 ] && [ "${minor:-0}" -lt 10 ]; }; then
    die "CyberStrikeAI 需要 Python 3.10+，当前为 Python $version"
  fi
  log "Python 版本满足要求：$version"
}

ensure_dependencies() {
  require_commands git go python3 awk sed grep mv mkdir cp chmod date sleep find rmdir tr nohup rm
  check_go_version
  check_python_version
}

ensure_root_safe() {
  validate_root_path
  if [ -e "$CYBERSTRIKE_ROOT" ] && [ ! -f "$MARKER" ]; then
    die "目标目录已存在但没有本脚本管理标记，拒绝覆盖：$CYBERSTRIKE_ROOT"
  fi
  mkdir -p "$CYBERSTRIKE_ROOT"
}

backup_state() {
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$CYBERSTRIKE_BACKUP_DIR/$stamp"
  mkdir -p "$backup"
  [ ! -f "$CYBERSTRIKE_CONFIG" ] || cp "$CYBERSTRIKE_CONFIG" "$backup/config.yaml"
  [ ! -d "$CYBERSTRIKE_ROOT/data" ] || cp -R "$CYBERSTRIKE_ROOT/data" "$backup/data"
  log "已备份配置/数据：$backup"
}

clone_or_validate_source() {
  ensure_root_safe
  if [ ! -d "$CYBERSTRIKE_ROOT/.git" ]; then
    [ ! -e "$CYBERSTRIKE_ROOT" ] || [ -z "$(find "$CYBERSTRIKE_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || die "安装目录非空且不是 Git 工作树：$CYBERSTRIKE_ROOT"
    log "克隆 CyberStrikeAI：$CYBERSTRIKE_REPOSITORY（ref=$CYBERSTRIKE_REF）"
    rmdir "$CYBERSTRIKE_ROOT" 2>/dev/null || true
    git clone --depth 1 --branch "$CYBERSTRIKE_REF" "$CYBERSTRIKE_REPOSITORY" "$CYBERSTRIKE_ROOT"
  fi
  [ -f "$CYBERSTRIKE_ROOT/go.mod" ] || die "源码目录缺少 go.mod：$CYBERSTRIKE_ROOT"
}

initialize_config() {
  if [ ! -f "$CYBERSTRIKE_CONFIG" ]; then
    [ -f "$CYBERSTRIKE_ROOT/config.example.yaml" ] || die "源码缺少 config.example.yaml"
    cp "$CYBERSTRIKE_ROOT/config.example.yaml" "$CYBERSTRIKE_CONFIG"
    # 仅修改新复制的配置；不覆盖用户已有配置。
    local tmp="$CYBERSTRIKE_CONFIG.tmp.$$"
    awk 'BEGIN { done=0 } /^[[:space:]]*host:[[:space:]]*/ && done==0 { print "  host: \"127.0.0.1\""; done=1; next } { print }' "$CYBERSTRIKE_CONFIG" > "$tmp"
    mv "$tmp" "$CYBERSTRIKE_CONFIG"
    chmod 600 "$CYBERSTRIKE_CONFIG"
    ok "已创建本地安全配置：$CYBERSTRIKE_CONFIG"
  fi
  grep -Eq '^[[:space:]]*host:[[:space:]]*.*127[.]0[.]0[.]1' "$CYBERSTRIKE_CONFIG" || die "配置未确认绑定 127.0.0.1，请检查：$CYBERSTRIKE_CONFIG"
  grep -Eq '^[[:space:]]*tls_(enabled|auto_self_sign):[[:space:]]*true' "$CYBERSTRIKE_CONFIG" || die "配置未确认启用本地 HTTPS，请检查：$CYBERSTRIKE_CONFIG"
  chmod 600 "$CYBERSTRIKE_CONFIG"
}

prepare_python_environment() {
  local python_bin="$CYBERSTRIKE_ROOT/venv/bin/python3"
  if [ ! -x "$python_bin" ]; then
    log "创建 Python 虚拟环境"
    python3 -m venv "$CYBERSTRIKE_ROOT/venv"
  fi
  if [ -f "$CYBERSTRIKE_ROOT/requirements.txt" ]; then
    log "安装 Python 依赖"
    "$python_bin" -m pip install -r "$CYBERSTRIKE_ROOT/requirements.txt"
  fi
}

build_binary() {
  log "下载 Go 依赖并构建 CyberStrikeAI"
  git -C "$CYBERSTRIKE_ROOT" status --porcelain --untracked-files=no >/dev/null
  (cd "$CYBERSTRIKE_ROOT" && go mod download && go build -o "$CYBERSTRIKE_BINARY" ./cmd/server)
  chmod 0755 "$CYBERSTRIKE_BINARY"
  git -C "$CYBERSTRIKE_ROOT" rev-parse HEAD > "$MARKER"
  chmod 600 "$MARKER"
  ok "已构建版本：$(git -C "$CYBERSTRIKE_ROOT" rev-parse --short HEAD)"
}

cmd_install() {
  require_platform; ensure_dependencies; clone_or_validate_source; initialize_config; prepare_python_environment; build_binary
  ok "安装完成：$CYBERSTRIKE_ROOT"
  log "首次启动前请编辑 $CYBERSTRIKE_CONFIG 配置 AI 通道；不会自动写入 API Key。"
  log "启动命令：$(basename "$0") start"
}

cmd_update() {
  require_platform; ensure_dependencies
  [ -f "$MARKER" ] && [ -d "$CYBERSTRIKE_ROOT/.git" ] || die "尚未安装，请先执行：$0 install"
  backup_state
  [ -z "$(git -C "$CYBERSTRIKE_ROOT" status --porcelain --untracked-files=no)" ] || die "源码存在未提交修改，拒绝更新以避免覆盖：$CYBERSTRIKE_ROOT"
  git -C "$CYBERSTRIKE_ROOT" fetch --tags origin "$CYBERSTRIKE_REF"
  git -C "$CYBERSTRIKE_ROOT" checkout --detach FETCH_HEAD
  initialize_config; prepare_python_environment; build_binary
  ok "更新完成；C2、WebShell 和外部 MCP 保持不自动启用。"
}

read_pid() {
  [ -s "$CYBERSTRIKE_PID_FILE" ] || return 1
  tr -d '[:space:]' < "$CYBERSTRIKE_PID_FILE"
}

pid_running() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cmd_start() {
  [ -x "$CYBERSTRIKE_BINARY" ] || die "未找到可执行文件，请先执行：$0 install"
  local pid log_file
  if pid="$(read_pid || true)" && pid_running "$pid"; then
    ok "CyberStrikeAI 已运行：PID $pid"
    return 0
  fi
  mkdir -p "$CYBERSTRIKE_LOG_DIR"
  log_file="$CYBERSTRIKE_LOG_DIR/server-$(date +%Y%m%d).log"
  umask 077
  log "启动本地 HTTPS 服务，日志：$log_file"
  (cd "$CYBERSTRIKE_ROOT" && nohup "$CYBERSTRIKE_BINARY" --config "$CYBERSTRIKE_CONFIG" >> "$log_file" 2>&1 & echo $! > "$CYBERSTRIKE_PID_FILE")
  sleep 2
  pid="$(read_pid || true)"
  if pid_running "$pid"; then
    ok "CyberStrikeAI 已启动：PID $pid"
    log "本地地址：https://127.0.0.1:${CYBERSTRIKE_PORT}/"
  else
    warn "服务未保持运行，请查看日志：$log_file"
    return 1
  fi
}

cmd_stop() {
  local pid
  pid="$(read_pid || true)"
  if ! pid_running "$pid"; then
    rm -f "$CYBERSTRIKE_PID_FILE"
    log 'CyberStrikeAI 未运行。'
    return 0
  fi
  kill "$pid"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pid_running "$pid" || break
    sleep 1
  done
  if pid_running "$pid"; then
    warn "进程未在 10 秒内退出，请手工检查 PID $pid；未强制 kill -9。"
    return 1
  fi
  rm -f "$CYBERSTRIKE_PID_FILE"
  ok 'CyberStrikeAI 已停止。'
}

cmd_status() {
  printf '安装目录：%s\n' "$CYBERSTRIKE_ROOT"
  if [ -f "$MARKER" ]; then
    printf '安装状态：已安装\n版本提交：%s\n' "$(cat "$MARKER")"
  else
    printf '安装状态：未安装\n'
    return 0
  fi
  local pid
  pid="$(read_pid || true)"
  if pid_running "$pid"; then
    printf '进程状态：运行中（PID %s）\n' "$pid"
    printf '本地地址：https://127.0.0.1:%s/\n' "$CYBERSTRIKE_PORT"
  else
    printf '进程状态：未运行\n'
  fi
  printf '配置文件：%s\n数据目录：%s\n' "$CYBERSTRIKE_CONFIG" "$CYBERSTRIKE_ROOT/data"
}

cmd_uninstall() {
  [ "${1:-}" = "--yes" ] || die '卸载需要显式提供 --yes'
  validate_root_path
  [ -f "$MARKER" ] || die "未找到本脚本管理标记，拒绝删除：$CYBERSTRIKE_ROOT"
  cmd_stop || true
  rm -rf -- "$CYBERSTRIKE_ROOT"
  ok "已删除 CyberStrikeAI 用户目录：$CYBERSTRIKE_ROOT"
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_stop || true; cmd_start "$@" ;;
    status) cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) show_help ;;
    *) die "未知命令：$command；运行 $0 --help 查看帮助" ;;
  esac
}

main "$@"

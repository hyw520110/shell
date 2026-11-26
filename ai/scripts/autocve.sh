#!/usr/bin/env bash
# AutoCVE 安装与本地 Docker Compose 生命周期管理封装。
#
# AutoCVE 面向源码审计/CVE 研究，不是公网 Web 扫描器。
# 上游 Compose 会挂载 Docker socket，因此启动前必须显式确认授权；
# 本封装默认只绑定 localhost，不自动连接公网目标或提交漏洞。

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"

AUTOCVE_VERSION="${AUTOCVE_VERSION:-v1.0.5}"
AUTOCVE_ROOT="${AUTOCVE_ROOT:-${HOME}/.local/share/autocve}"
AUTOCVE_COMPOSE_FILE="${AUTOCVE_COMPOSE_FILE:-$AUTOCVE_ROOT/docker-compose.prod.yml}"
AUTOCVE_ENV_FILE="${AUTOCVE_ENV_FILE:-$AUTOCVE_ROOT/.env}"
AUTOCVE_PROJECT_NAME="${AUTOCVE_PROJECT_NAME:-autocve}"
AUTOCVE_MARKER="$AUTOCVE_ROOT/.managed-by-shell"
AUTOCVE_COMPOSE_URL="${AUTOCVE_COMPOSE_URL:-https://raw.githubusercontent.com/larlarua/AutoCVE/${AUTOCVE_VERSION}/docker-compose.prod.yml}"

die() { printf '[autocve][错误] %s\n' "$*" >&2; exit 1; }
log() { printf '[autocve] %s\n' "$*"; }
ok() { printf '[autocve][完成] %s\n' "$*"; }
warn() { printf '[autocve][警告] %s\n' "$*" >&2; }
has() { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
AutoCVE 源码审计平台安装与 Docker Compose 管理

用法：$(basename "$0") <命令>

命令：
  install                    下载固定版本 Compose 文件并校验，不启动容器
  update                     备份配置后更新固定版本 Compose 文件
  start --ack-authorized    启动 AutoCVE；必须显式确认授权和 Docker socket 风险
  stop                       停止容器但保留容器/数据卷
  status                     查看 Compose 和容器状态
  logs                       查看最近日志（可追加服务名）
  uninstall --yes            删除容器和脚本创建的配置目录，保留数据卷
  purge --yes                删除容器、数据卷和脚本创建的配置目录

环境变量：
  AUTOCVE_VERSION       固定版本，默认 $AUTOCVE_VERSION
  AUTOCVE_ROOT          配置/项目目录，默认 $AUTOCVE_ROOT
  AUTOCVE_PROJECT_NAME  Compose 项目名，默认 $AUTOCVE_PROJECT_NAME

安全边界：
  - 默认端口仅绑定 127.0.0.1:3000 和 127.0.0.1:8000。
  - 上游后端/Worker 挂载 /var/run/docker.sock，启动前必须确认本机高权限风险。
  - 不自动写入真实 LLM_API_KEY，不自动导入源码，不自动执行 CVE PoC 或提交报告。
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
  case "$AUTOCVE_ROOT" in
    ''|/|.|..|"$HOME"|"$HOME/"*)
      die "拒绝使用过宽的安装目录：$AUTOCVE_ROOT"
      ;;
  esac
}

ensure_docker_cli() {
  require_commands docker
  docker compose version >/dev/null 2>&1 || die '未找到 Docker Compose 插件；请先安装 Docker Desktop 或其他支持 docker compose 的运行时。'
}

ensure_docker_daemon() {
  ensure_docker_cli
  docker info >/dev/null 2>&1 || die 'Docker daemon 未运行；请先启动 Docker Desktop/Colima，再重试。'
}

ensure_root_safe() {
  validate_root_path
  if [ -e "$AUTOCVE_ROOT" ] && [ ! -f "$AUTOCVE_MARKER" ]; then
    die "目标目录已存在但没有本脚本管理标记，拒绝覆盖：$AUTOCVE_ROOT"
  fi
  mkdir -p "$AUTOCVE_ROOT/projects" "$AUTOCVE_ROOT/backups"
}

compose() {
  docker compose --project-name "$AUTOCVE_PROJECT_NAME" --file "$AUTOCVE_COMPOSE_FILE" --env-file "$AUTOCVE_ENV_FILE" "$@"
}

harden_compose() {
  local tmp="$AUTOCVE_COMPOSE_FILE.tmp.$$"
  # 上游默认将宿主机端口暴露到所有接口；本地工具强制限制到 localhost。
  sed -e 's/"8000:8000"/"127.0.0.1:8000:8000"/g' \
      -e 's/"3000:80"/"127.0.0.1:3000:80"/g' \
      "$AUTOCVE_COMPOSE_FILE" > "$tmp"
  mv "$tmp" "$AUTOCVE_COMPOSE_FILE"
  grep -Fq '127.0.0.1:8000:8000' "$AUTOCVE_COMPOSE_FILE" || die 'Compose 未确认后端仅绑定 localhost。'
  grep -Fq '127.0.0.1:3000:80' "$AUTOCVE_COMPOSE_FILE" || die 'Compose 未确认前端仅绑定 localhost。'
  grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$AUTOCVE_COMPOSE_FILE" || warn '未检测到 Docker socket 挂载，可能与上游版本结构不一致；请人工检查。'
}

write_env_file() {
  if [ ! -f "$AUTOCVE_ENV_FILE" ]; then
    umask 077
    printf '%s\n' \
      '# AutoCVE 本地配置；请勿提交真实凭证。' \
      'POSTGRES_DB_NAME=autocve' \
      'AGENT_WORKER_CONCURRENCY=1' \
      'ONE_CLICK_CVE_WORKER_CONCURRENCY=1' \
      'LLM_PROVIDER=openai' \
      'LLM_MODEL=gpt-4o' \
      '# 配置模型前再填写 LLM_API_KEY。' \
      'LLM_API_KEY=not-configured' \
      > "$AUTOCVE_ENV_FILE"
    chmod 600 "$AUTOCVE_ENV_FILE"
    ok "已创建本地环境文件：$AUTOCVE_ENV_FILE"
  fi
  chmod 600 "$AUTOCVE_ENV_FILE"
}

validate_compose() {
  [ -s "$AUTOCVE_COMPOSE_FILE" ] || die "Compose 文件为空：$AUTOCVE_COMPOSE_FILE"
  grep -Fq 'services:' "$AUTOCVE_COMPOSE_FILE" || die 'Compose 文件缺少 services 定义。'
  grep -Fq 'ghcr.io/larlarua/autocve-' "$AUTOCVE_COMPOSE_FILE" || die 'Compose 文件不是预期的 AutoCVE 官方镜像配置。'
  compose config >/dev/null
}

download_compose() {
  require_commands curl sed mv grep mkdir cp chmod date
  local tmp="$AUTOCVE_COMPOSE_FILE.tmp.$$"
  log "下载 AutoCVE Compose：$AUTOCVE_VERSION"
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
    -A 'security-tools-wrapper/1.0' "$AUTOCVE_COMPOSE_URL" -o "$tmp"
  [ -s "$tmp" ] || die '下载的 Compose 文件为空。'
  mv "$tmp" "$AUTOCVE_COMPOSE_FILE"
  harden_compose
  validate_compose
}

cmd_install() {
  require_platform; ensure_docker_cli; validate_root_path; ensure_root_safe
  if [ -f "$AUTOCVE_COMPOSE_FILE" ]; then
    log "已存在 Compose 文件，执行安全校验：$AUTOCVE_COMPOSE_FILE"
    harden_compose
  else
    download_compose
  fi
  write_env_file; validate_compose
  printf '%s\n' "$AUTOCVE_VERSION" > "$AUTOCVE_MARKER"
  chmod 600 "$AUTOCVE_MARKER"
  ok "AutoCVE 已准备完成，但未启动容器。"
  log "启动前请检查 $AUTOCVE_ENV_FILE，并使用：$(basename "$0") start --ack-authorized"
  log "上游 Compose 包含 Docker socket 挂载，请仅在隔离且已授权的环境启用 Agent/CVE 任务。"
}

backup_state() {
  local stamp="$1" backup="$AUTOCVE_ROOT/backups/$stamp"
  mkdir -p "$backup"
  [ ! -f "$AUTOCVE_COMPOSE_FILE" ] || cp "$AUTOCVE_COMPOSE_FILE" "$backup/docker-compose.prod.yml"
  [ ! -f "$AUTOCVE_ENV_FILE" ] || cp "$AUTOCVE_ENV_FILE" "$backup/.env"
  chmod 600 "$backup"/* 2>/dev/null || true
  log "已备份配置：$backup"
}

cmd_update() {
  require_platform; ensure_docker_cli; ensure_root_safe
  [ -f "$AUTOCVE_MARKER" ] || die '尚未安装，请先执行 install。'
  backup_state "$(date +%Y%m%d-%H%M%S)"
  download_compose; write_env_file; validate_compose
  printf '%s\n' "$AUTOCVE_VERSION" > "$AUTOCVE_MARKER"
  chmod 600 "$AUTOCVE_MARKER"
  ok "Compose 已更新为 $AUTOCVE_VERSION；容器未自动重启。"
}

cmd_start() {
  local ack=0 arg
  for arg in "$@"; do
    [ "$arg" = "--ack-authorized" ] && ack=1
  done
  [ "$ack" -eq 1 ] || die 'AutoCVE 启动会使用 Docker socket，必须显式提供 --ack-authorized。'
  require_platform; ensure_root_safe; ensure_docker_daemon
  [ -f "$AUTOCVE_MARKER" ] || die '尚未安装，请先执行 install。'
  write_env_file; validate_compose
  log '启动 AutoCVE 容器；前端 http://127.0.0.1:3000，后端 http://127.0.0.1:8000'
  compose up -d
  ok 'AutoCVE 已启动。'
}

cmd_stop() {
  ensure_docker_daemon; [ -f "$AUTOCVE_COMPOSE_FILE" ] || { log '未找到 Compose 文件。'; return 0; }
  compose stop
  ok 'AutoCVE 容器已停止，数据卷保留。'
}

cmd_status() {
  printf '安装目录：%s\n' "$AUTOCVE_ROOT"
  if [ -f "$AUTOCVE_MARKER" ]; then
    printf '安装状态：已准备（版本 %s）\n' "$(tr -d '[:space:]' < "$AUTOCVE_MARKER")"
  else
    printf '安装状态：未安装\n'
    return 0
  fi
  if ensure_docker_cli >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      compose ps || true
    else
      printf 'Docker 状态：daemon 未运行\n'
    fi
  else
    printf 'Docker 状态：CLI/Compose 不可用\n'
  fi
}

cmd_logs() {
  ensure_docker_daemon; [ -f "$AUTOCVE_COMPOSE_FILE" ] || die '尚未安装，请先执行 install。'
  compose logs --tail=100 "$@"
}

cmd_uninstall() {
  [ "${1:-}" = "--yes" ] || die '卸载需要显式提供 --yes'
  validate_root_path; [ -f "$AUTOCVE_MARKER" ] || die "未找到本脚本管理标记，拒绝删除：$AUTOCVE_ROOT"
  ensure_docker_daemon
  compose down --remove-orphans
  rm -rf -- "$AUTOCVE_ROOT"
  ok "已删除 AutoCVE 容器和配置目录；数据卷未删除。"
}

cmd_purge() {
  [ "${1:-}" = "--yes" ] || die '彻底清理需要显式提供 --yes'
  validate_root_path; [ -f "$AUTOCVE_MARKER" ] || die "未找到本脚本管理标记，拒绝删除：$AUTOCVE_ROOT"
  ensure_docker_daemon
  compose down --volumes --remove-orphans
  rm -rf -- "$AUTOCVE_ROOT"
  ok '已删除 AutoCVE 容器、数据卷和配置目录；镜像未强制删除。'
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    purge) cmd_purge "$@" ;;
    help|-h|--help) show_help ;;
    *) die "未知命令：$command；运行 $0 --help 查看帮助" ;;
  esac
}

main "$@"

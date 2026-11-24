#!/usr/bin/env bash
#
# Nessus helper for macOS/Linux.
# - Standard scanner: Docker image tenable/nessus:latest-oracle
# - Nessus Expert WAS: native Nessus Expert + Docker available on the host
#
# Use only against assets for which you have explicit authorization.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
CONTAINER_NAME="${CONTAINER_NAME:-nessus}"
NESSUS_VERSION="${NESSUS_VERSION:-latest}"
NESSUS_IMAGE_OS="${NESSUS_IMAGE_OS:-oracle}"
DOCKER_IMAGE="${DOCKER_IMAGE:-tenable/nessus:${NESSUS_VERSION}-${NESSUS_IMAGE_OS}}"
NESSUS_PORT="${NESSUS_PORT:-8834}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${HOME}/Downloads}"
DOWNLOADS_API="${DOWNLOADS_API:-https://www.tenable.com/downloads/api/v2/pages/nessus}"
NESSUS_URL="https://localhost:${NESSUS_PORT}"

log()  { printf '[nessus] %s\n' "$*"; }
warn() { printf '[nessus][警告] %s\n' "$*" >&2; }
die()  { printf '[nessus][错误] %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<EOF
用法：$SCRIPT_NAME <命令>

生命周期：
  install             安装 Docker Scanner 或本机 Nessus Expert
  start|stop|restart  启动、停止或重启当前安装
  status              查看服务、容器状态和本地版本
  uninstall           删除 Docker 容器或卸载本机 Nessus

更新和注册：
  version             显示已安装版本和最新可用版本
  check-update        检查是否有可用更新
  update              更新 Nessus 核心（本机）或拉取 Docker 镜像
  update-plugins      更新全部 Nessus 插件/feed 数据
  register <code>     使用 Nessus 激活码注册

Web 应用扫描：
  was-status          检查本机 Nessus Expert 和 Docker 前置条件
  enable-was          打开 Nessus Expert WAS 设置页面
  templates           输出常用 WAS 扫描模板和适用场景

环境变量：
  CONTAINER_NAME、DOCKER_IMAGE、NESSUS_VERSION、NESSUS_IMAGE_OS、NESSUS_PORT
  DOWNLOAD_DIR、DOWNLOADS_API

镜像说明：
  默认使用官方 Oracle Linux 8 镜像（latest-oracle），比 Ubuntu 版略小。
  可用 NESSUS_IMAGE_OS=ubuntu 切回官方 Ubuntu 镜像，或直接指定 DOCKER_IMAGE。

示例：
  $SCRIPT_NAME version
  $SCRIPT_NAME update-plugins
  $SCRIPT_NAME was-status
  $SCRIPT_NAME enable-was
EOF
}

docker_available() {
  has docker && docker info >/dev/null 2>&1
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

container_image() {
  docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true
}

native_install_exists() {
  [ -e /Library/Nessus ] || \
    [ -e /Library/LaunchDaemons/com.tenablesecurity.nessusd.plist ] || \
    [ -e '/Library/PreferencePanes/Nessus Preferences.prefPane' ] || \
    [ -e /Applications/Nessus ]
}

native_cli() {
  if [ -x /opt/nessus/sbin/nessuscli ]; then
    printf '%s\n' /opt/nessus/sbin/nessuscli
  elif [ -x /Library/Nessus/run/sbin/nessuscli ]; then
    printf '%s\n' /Library/Nessus/run/sbin/nessuscli
  fi
}

native_daemon() {
  if [ -x /opt/nessus/sbin/nessusd ]; then
    printf '%s\n' /opt/nessus/sbin/nessusd
  elif [ -x /Library/Nessus/run/sbin/nessusd ]; then
    printf '%s\n' /Library/Nessus/run/sbin/nessusd
  fi
}

extract_version() {
  sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+)([^0-9].*|$)/\1/p' | head -n 1
}

latest_version() {
  has curl || return 0
  local payload versions
  payload="$(curl -fsSL --connect-timeout 10 --max-time 30 "$DOWNLOADS_API" 2>/dev/null || true)"
  versions="$(printf '%s' "$payload" | grep -Eo 'Nessus[-_ ]?[0-9]+\.[0-9]+\.[0-9]+' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [ -z "$versions" ]; then
    versions="$(printf '%s' "$payload" | grep -Eo '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  fi
  [ -n "$versions" ] || return 0
  printf '%s\n' "$versions" | awk -F. '{printf "%08d.%08d.%08d %s\n", $1+0, $2+0, $3+0, $0}' | sort | awk 'END {print $2}'
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

installed_version() {
  local output=""
  if container_exists; then
    output="$(docker exec "$CONTAINER_NAME" /opt/nessus/sbin/nessuscli -v 2>/dev/null || true)"
  elif [ -n "$(native_cli || true)" ]; then
    output="$("$(native_cli)" -v 2>/dev/null || true)"
  fi
  [ -n "$output" ] || return 0
  printf '%s\n' "$output" | extract_version
}

show_access_info() {
  log "Nessus 管理界面：$NESSUS_URL"
  log "首次打开时请在浏览器中完成管理员账户、激活码和证书确认。"
}

cmd_version() {
  local current latest
  current="$(installed_version || true)"
  latest="$(latest_version || true)"
  printf '已安装版本：%s\n' "${current:-未检测到}"
  printf '最新版本：  %s\n' "${latest:-未检测到}"
  if [ -n "$current" ] && [ -n "$latest" ]; then
    if version_is_newer "$latest" "$current"; then
      printf '更新状态：  有可用更新\n'
    else
      printf '更新状态：  已是最新\n'
    fi
  else
    printf '更新状态：  暂无法比较\n'
  fi
}

cmd_check_update() {
  local current latest
  current="$(installed_version || true)"
  latest="$(latest_version || true)"
  [ -n "$current" ] || die "未检测到 Nessus 安装。"
  [ -n "$latest" ] || die "无法从 Tenable Downloads API 获取最新版本。"
  if version_is_newer "$latest" "$current"; then
    log "有可用更新：$current -> $latest"
    return 0
  fi
  log "已是最新版本：$current"
  return 1
}

install_docker() {
  docker_available || die "Docker 未运行。请先启动 Docker Desktop。"

  # 已有容器包含 Nessus 配置和许可证状态。不要为了切换标签自动重建，
  # 也不要无意义地拉取 latest；Tenable 不支持用 volume 持久化 Nessus 数据。
  if container_exists; then
    local current_image
    current_image="$(container_image)"
    if [ -n "$current_image" ] && [ "$current_image" != "$DOCKER_IMAGE" ]; then
      warn "已有容器使用镜像 $current_image；当前目标为 $DOCKER_IMAGE。"
      warn "为避免丢失配置，不会自动重建容器；确认备份后再手工迁移。"
    fi
    if container_running; then
      warn "容器 $CONTAINER_NAME 已在运行，不重复拉取或重建。"
    else
      docker start "$CONTAINER_NAME" >/dev/null
      log "已启动现有容器 $CONTAINER_NAME。"
    fi
    show_access_info
    return 0
  fi

  log "拉取官方镜像：$DOCKER_IMAGE"
  docker pull "$DOCKER_IMAGE"
  docker run -d --name "$CONTAINER_NAME" \
    -p "${NESSUS_PORT}:8834" \
    --restart unless-stopped \
    "$DOCKER_IMAGE" >/dev/null
  log "Docker Scanner 已启动。"
  show_access_info
  warn "Docker 模式用于标准 Nessus Scanner；WAS 请使用本机原生 Nessus Expert + 本机 Docker。"
}

install_native() {
  has curl || die "需要 curl。"
  local version os arch url package
  version="$(latest_version || true)"
  version="${version:-${NESSUS_VERSION:-10.12.3}}"
  os="$(uname -s)"
  arch="$(uname -m)"
  [ "$arch" = "x86_64" ] || warn "当前架构为 $arch；WAS 官方支持范围请以 Tenable 文档为准。"
  mkdir -p "$DOWNLOAD_DIR"

  if [ "$os" = "Darwin" ]; then
    url="https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-${version}.dmg"
    package="$DOWNLOAD_DIR/Nessus-${version}.dmg"
    log "下载 Nessus Expert ${version}"
    curl -fL --progress-bar "$url" -o "$package"
    open "$package"
    log "安装包已打开，请在图形安装器中完成安装；完成后再运行：$SCRIPT_NAME register <activation-code>"
  elif [ "$os" = "Linux" ]; then
    if has dpkg; then
      url="https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-${version}-ubuntu1604_amd64.deb"
      package="$DOWNLOAD_DIR/Nessus-${version}-ubuntu1604_amd64.deb"
      curl -fL --progress-bar "$url" -o "$package"
      sudo dpkg -i "$package"
    elif has rpm; then
      url="https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-${version}-el8.x86_64.rpm"
      package="$DOWNLOAD_DIR/Nessus-${version}-el8.x86_64.rpm"
      curl -fL --progress-bar "$url" -o "$package"
      sudo rpm -U "$package"
    else
      die "未找到 dpkg 或 rpm。"
    fi
    log "原生 Nessus 已安装，请运行：$SCRIPT_NAME register <activation-code>"
  else
    die "不支持的操作系统：$os"
  fi
}

cmd_install() {
  cat <<'EOF'
选择安装方式：
  1) Docker Nessus Scanner（标准网络/主机扫描）
  2) 原生 Nessus Expert（WAS 前置方式，需本机 Docker）
  3) 退出
EOF
  printf '请输入 [1-3]: '
  read -r choice
  case "$choice" in
    1) install_docker ;;
    2) install_native ;;
    *) log "已取消。" ;;
  esac
}

cmd_start() {
  if container_exists; then
    container_running || docker start "$CONTAINER_NAME" >/dev/null
  elif [ -n "$(native_daemon || true)" ]; then
    sudo "$(native_daemon)" >/dev/null 2>&1 &
  else
    die "未检测到 Docker 容器或原生 Nessus。"
  fi
  show_access_info
}

cmd_stop() {
  if container_running; then
    docker stop "$CONTAINER_NAME" >/dev/null
  elif [ -n "$(native_daemon || true)" ]; then
    sudo "$(native_daemon)" stop || true
  else
    die "未检测到运行中的 Nessus。"
  fi
}

cmd_restart() {
  cmd_stop || true
  cmd_start
}

cmd_status() {
  if container_exists; then
    docker ps -a --filter "name=^/$CONTAINER_NAME$" --format 'container={{.Names}} status={{.Status}} image={{.Image}}'
  fi
  if [ -n "$(native_cli || true)" ]; then
    "$(native_cli)" -v || true
  fi
  cmd_version
  show_access_info
}

nessuscli_exec() {
  local cli_cmd="$1"
  shift
  if container_running; then
    docker exec "$CONTAINER_NAME" /opt/nessus/sbin/nessuscli "$cli_cmd" "$@"
  elif [ -n "$(native_cli || true)" ]; then
    sudo "$(native_cli)" "$cli_cmd" "$@"
  else
    die "未检测到运行中的 Nessus。"
  fi
}

cmd_update_plugins() {
  log "更新 Nessus 插件/feed 数据。"
  nessuscli_exec update --plugins-only
}

cmd_update() {
  if container_exists; then
    docker_available || die "Docker 未运行。"
    log "拉取镜像更新：$DOCKER_IMAGE"
    docker pull "$DOCKER_IMAGE"
    warn "现有容器不会自动删除重建，以避免丢失配置；请先确认备份后手工重建容器。"
  elif [ -n "$(native_cli || true)" ]; then
    log "更新原生 Nessus 核心和插件。"
    sudo "$(native_cli)" update --all
  else
    die "未检测到 Nessus 安装。"
  fi
}

cmd_register() {
  [ "${1:-}" != "" ] || die "用法：$SCRIPT_NAME register <activation-code>"
  nessuscli_exec fetch --code "$1"
}

cmd_was_status() {
  local cli
  cli="$(native_cli || true)"
  printf '本机 Nessus：%s\n' "${cli:-未检测到}"
  if docker_available; then
    printf 'Docker：      可用\n'
  else
    printf 'Docker：      不可用\n'
  fi
  printf '许可证：      WAS 需要 Nessus Expert\n'
  printf '系统架构：    %s\n' "$(uname -m)"
  printf '设置地址：    %s/#/web-app-scanning\n' "$NESSUS_URL"
  if [ -n "$cli" ] && docker_available; then
    log "前置条件已满足：请确认许可证为 Nessus Expert，然后在 UI 中启用 WAS。"
  else
    warn "WAS 前置条件未满足：需要本机原生 Nessus Expert 和可用 Docker。"
  fi
}

open_local_url() {
  local url="$1"
  if [ "$(uname -s)" = "Darwin" ] && has open; then
    open "$url"
  elif has xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 &
  else
    log "请手工打开：$url"
  fi
}

cmd_enable_was() {
  cmd_was_status
  [ -n "$(native_cli || true)" ] || die "未检测到本机原生 Nessus；Docker-only 模式不能启用 WAS。"
  docker_available || die "Docker 不可用；请先启动 Docker Desktop。"
  log "打开 WAS 设置页面；需要你在 Nessus UI 中确认 Nessus Expert 许可并完成启用。"
  open_local_url "$NESSUS_URL/#/web-app-scanning"
}

cmd_templates() {
  cat <<'EOF'
常用 Web Application Scanning 模板（在 Nessus UI 中选择）：

  Web App Overview
    仅做范围/入口发现，适合首次确认站点结构，通常不主动验证漏洞。
  Quick Scan
    快速检查常见 Web 配置、响应头和外部配置问题。
  Scan
    综合 Web 应用主动扫描；仅对已授权测试环境使用。
  SSL TLS
    仅检查 TLS/证书/密码套件，不做页面爬取。
  Web App Config Audit
    关注安全响应头和外部 Web 配置。
  Vulnerabilities API
    对 OpenAPI/Swagger API 文档定义的接口进行检查。

建议顺序：Web App Overview -> Quick Scan -> 按授权范围使用 Scan；
API 目标另建 Vulnerabilities API；TLS 问题单独使用 SSL TLS。
不要手工“全选插件”：先更新插件 feed，再使用模板和明确的目标范围。
EOF
}

cmd_uninstall() {
  if container_exists; then
    warn "直接停止并删除 Docker 容器 $CONTAINER_NAME；镜像不会删除。"
    docker rm -f "$CONTAINER_NAME" >/dev/null
    log "容器已删除；镜像仍保留，可用 docker image rm 手工清理。"
  elif native_install_exists; then
    warn "将卸载本机 Nessus，并删除配置、许可证、插件和日志数据。"
    warn "删除目标：/Library/Nessus、Nessus 启动服务、偏好设置和 /Applications/Nessus"
    sudo -v || die "管理员身份验证失败，已取消卸载。"

    # 按 Tenable 官方流程先移除 launchd 服务，再删除安装目录。
    sudo launchctl remove com.tenablesecurity.nessusd 2>/dev/null || true
    local path
    for path in \
      /Library/Nessus \
      /Library/LaunchDaemons/com.tenablesecurity.nessusd.plist \
      '/Library/PreferencePanes/Nessus Preferences.prefPane' \
      /Applications/Nessus; do
      if [ -e "$path" ]; then
        sudo rm -rf -- "$path"
      fi
    done
    log "本机 Nessus 已卸载。配置、许可证、插件和日志数据已删除。"
  else
    warn "未检测到 Docker 容器或本机 Nessus。"
  fi
}

main() {
  case "${1:-help}" in
    help|-h|--help) show_help ;;
    install) cmd_install ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
    version) cmd_version ;;
    check-update) cmd_check_update ;;
    update) cmd_update ;;
    update-plugins) cmd_update_plugins ;;
    register) shift; cmd_register "${1:-}" ;;
    was-status) cmd_was_status ;;
    enable-was) cmd_enable_was ;;
    templates) cmd_templates ;;
    *) die "未知命令：$1；运行 $SCRIPT_NAME help 查看帮助。" ;;
  esac
}

main "$@"

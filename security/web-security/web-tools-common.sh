#!/usr/bin/env bash

# Web 安全工具安装脚本共享函数。请由同目录下的 install-*.sh 调用。

WEB_TOOLS_OS="$(uname -s)"
WEB_TOOLS_ARCH="$(uname -m)"
WEB_TOOLS_ROOT="${WEB_SECURITY_TOOLS_ROOT:-${HOME}/.local/share/web-security-tools}"
WEB_TOOLS_BIN="${WEB_SECURITY_BIN_DIR:-${HOME}/.local/bin}"
WEB_TOOLS_DRY_RUN=0

WEB_RED='\033[0;31m'
WEB_GREEN='\033[0;32m'
WEB_YELLOW='\033[1;33m'
WEB_NC='\033[0m'

web_log() {
  printf '[web-tools] %s\n' "$*"
}

web_ok() {
  printf "${WEB_GREEN}[完成] %s${WEB_NC}\n" "$*"
}

web_warn() {
  printf "${WEB_YELLOW}[警告] %s${WEB_NC}\n" "$*" >&2
}

web_die() {
  printf "${WEB_RED}[错误] %s${WEB_NC}\n" "$*" >&2
  exit 1
}

web_has() {
  command -v "$1" >/dev/null 2>&1
}

web_require_platform() {
  case "$WEB_TOOLS_OS" in
    Darwin|Linux) ;;
    *) web_die "不支持的操作系统：$WEB_TOOLS_OS" ;;
  esac
}

web_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) WEB_TOOLS_DRY_RUN=1 ;;
      -h|--help) return 10 ;;
      *) web_die "未知参数：$1；运行 --help 查看帮助。" ;;
    esac
    shift
  done
  return 0
}

web_prepare() {
  mkdir -p "$WEB_TOOLS_ROOT" "$WEB_TOOLS_BIN"
}

web_link() {
  local source_path="$1"
  local command_name="$2"
  [ -e "$source_path" ] || web_die "未找到工具文件：$source_path"
  chmod +x "$source_path" 2>/dev/null || true
  ln -sfn "$source_path" "$WEB_TOOLS_BIN/$command_name"
}

web_install_prerequisites() {
  local need_python=0
  local need_git=0
  local need_go=0
  local need_curl=0
  local command_name
  local missing=()

  for command_name in "$@"; do
    case "$command_name" in
      python3) need_python=1 ;;
      git) need_git=1 ;;
      go) need_go=1 ;;
      curl) need_curl=1 ;;
      *) web_die "共享安装器不支持的依赖：$command_name" ;;
    esac
  done

  [[ "$need_python" -eq 1 ]] && ! web_has python3 && missing+=(python3)
  [[ "$need_git" -eq 1 ]] && ! web_has git && missing+=(git)
  [[ "$need_go" -eq 1 ]] && ! web_has go && missing+=(go)
  [[ "$need_curl" -eq 1 ]] && ! web_has curl && missing+=(curl)

  if [[ "$need_python" -eq 1 && -x "$(command -v python3 2>/dev/null || true)" ]]; then
    python3 -m venv --help >/dev/null 2>&1 || missing+=(python3-venv)
  fi

  [[ ${#missing[@]} -eq 0 ]] && return 0

  if [[ "$WEB_TOOLS_OS" == "Darwin" ]]; then
    web_has brew || web_die "缺少依赖：${missing[*]}。请先安装 Homebrew。"
    local brew_packages=()
    [[ "$need_python" -eq 1 ]] && brew_packages+=(python)
    [[ "$need_git" -eq 1 ]] && brew_packages+=(git)
    [[ "$need_go" -eq 1 ]] && brew_packages+=(go)
    [[ "$need_curl" -eq 1 ]] && brew_packages+=(curl)
    web_log "通过 Homebrew 安装依赖：${brew_packages[*]}"
    brew install "${brew_packages[@]}"
    return 0
  fi

  if web_has apt-get; then
    local apt_packages=(ca-certificates)
    [[ "$need_python" -eq 1 ]] && apt_packages+=(python3 python3-venv python3-pip)
    [[ "$need_git" -eq 1 ]] && apt_packages+=(git)
    [[ "$need_go" -eq 1 ]] && apt_packages+=(golang-go)
    [[ "$need_curl" -eq 1 ]] && apt_packages+=(curl)
    web_log "通过 apt 安装依赖：${apt_packages[*]}"
    sudo apt-get update
    sudo apt-get install -y "${apt_packages[@]}"
  elif web_has dnf; then
    local dnf_packages=()
    [[ "$need_python" -eq 1 ]] && dnf_packages+=(python3 python3-pip)
    [[ "$need_git" -eq 1 ]] && dnf_packages+=(git)
    [[ "$need_go" -eq 1 ]] && dnf_packages+=(golang)
    [[ "$need_curl" -eq 1 ]] && dnf_packages+=(curl)
    web_log "通过 dnf 安装依赖：${dnf_packages[*]}"
    sudo dnf install -y "${dnf_packages[@]}"
  elif web_has pacman; then
    local pacman_packages=()
    [[ "$need_python" -eq 1 ]] && pacman_packages+=(python python-pip)
    [[ "$need_git" -eq 1 ]] && pacman_packages+=(git)
    [[ "$need_go" -eq 1 ]] && pacman_packages+=(go)
    [[ "$need_curl" -eq 1 ]] && pacman_packages+=(curl)
    web_log "通过 pacman 安装依赖：${pacman_packages[*]}"
    sudo pacman -Sy --noconfirm "${pacman_packages[@]}"
  else
    web_die "缺少依赖：${missing[*]}；未识别到 apt、dnf 或 pacman。"
  fi
}

web_show_plan() {
  local tool_name="$1"
  local description="$2"
  printf '工具：%s\n说明：%s\n系统：%s (%s)\n安装目录：%s\n命令目录：%s\n' \
    "$tool_name" "$description" "$WEB_TOOLS_OS" "$WEB_TOOLS_ARCH" \
    "$WEB_TOOLS_ROOT" "$WEB_TOOLS_BIN"
}

web_finish() {
  local tool_name="$1"
  web_ok "$tool_name 安装完成。"
  printf '\n请确认 PATH 包含：%s\n' "$WEB_TOOLS_BIN"
  printf 'export PATH="%s:\$PATH"\n' "$WEB_TOOLS_BIN"
}

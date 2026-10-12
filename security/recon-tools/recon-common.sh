#!/usr/bin/env bash
#
# recon-tools 共享函数库。
# 供 security/recon-tools/ 下的工具脚本 source，
# 提供在 macOS / Linux 上从 GitHub Releases 安装、配置与卸载的通用能力。
#
# 注意：这些工具用于资产侦察 / 代码泄露扫描，仅限你有权访问的目标。
set -euo pipefail

[ -n "${RECON_COMMON_LOADED:-}" ] && return 0
RECON_COMMON_LOADED=1

RECON_COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RECON_OS_TYPE="$(uname -s)"
RECON_OS_ARCH="$(uname -m)"
RECON_ROOT="${RECON_ROOT:-${HOME}/.local/share/recon-tools}"
RECON_BIN_DIR="${RECON_BIN_DIR:-${HOME}/.local/bin}"
RECON_DOWNLOAD_DIR="${RECON_DOWNLOAD_DIR:-${HOME}/Downloads}"
RECON_KEEP_DOWNLOADS="${RECON_KEEP_DOWNLOADS:-0}"

RECON_RED='\033[0;31m'
RECON_GREEN='\033[0;32m'
RECON_YELLOW='\033[1;33m'
RECON_NC='\033[0m'

recon_log()  { printf '[recon-tools] %s\n' "$*"; }
recon_ok()   { printf "${RECON_GREEN}[完成] %s${RECON_NC}\n" "$*"; }
recon_warn() { printf "${RECON_YELLOW}[警告] %s${RECON_NC}\n" "$*" >&2; }
recon_die()  { printf "${RECON_RED}[错误] %s${RECON_NC}\n" "$*" >&2; exit 1; }
recon_has()  { command -v "$1" >/dev/null 2>&1; }

recon_require_platform() {
  case "$RECON_OS_TYPE" in
    Darwin|Linux) ;;
    *) recon_die "不支持的操作系统：${RECON_OS_TYPE}（仅支持 macOS / Linux）" ;;
  esac
}

recon_find_adl() {
  local candidate
  for candidate in \
    "$(command -v adl 2>/dev/null || true)" \
    "$RECON_COMMON_DIR/../../../network/tools/adl" \
    "/opt/homebrew/bin/adl" \
    "/usr/local/bin/adl" \
    "$HOME/.local/bin/adl"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      if "$candidate" --help >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

recon_gh_api() {
  local url="$1"
  local -a args=(-fsSL --connect-timeout 10 --max-time 30)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H 'Accept: application/vnd.github+json')
  fi
  curl "${args[@]}" "$url"
}

recon_latest_tag() {
  local repo="$1" payload
  payload="$(recon_gh_api "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)"
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload" |
    sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/p' |
    head -n 1
}

recon_asset_url() {
  local repo="$1" version="$2" regex="$3" payload
  version="${version#v}"
  payload="$(recon_gh_api "https://api.github.com/repos/${repo}/releases/tags/v${version}" 2>/dev/null || true)"
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload" |
    tr ',' '\n' |
    sed -nE 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' |
    grep -E "$regex" |
    head -n 1
}

recon_pick_version() {
  local repo="$1" pinned="${2:-}" version
  if [ -n "$pinned" ]; then
    printf '%s\n' "${pinned#v}"
    return 0
  fi
  version="$(recon_latest_tag "$repo" || true)"
  [ -n "$version" ] || return 1
  printf '%s\n' "${version#v}"
}

recon_download() {
  local url="$1" dest="$2" adl_path
  mkdir -p "$(dirname "$dest")"
  rm -f "$dest"
  if adl_path="$(recon_find_adl || true)" && [ -n "$adl_path" ]; then
    recon_log "使用 adl 下载：$(basename "$dest")"
    if "$adl_path" "$url" "$(dirname "$dest")" "$(basename "$dest")" && [ -s "$dest" ]; then
      return 0
    fi
    recon_warn 'adl 下载失败，回退到 curl。'
    rm -f "$dest"
  fi
  recon_has curl || recon_die '缺少 curl。'
  curl -fL --retry 2 --connect-timeout 10 "$url" -o "$dest"
  [ -s "$dest" ] || recon_die "下载失败：$url"
}

recon_install_asset() {
  local binary="$1" url="$2"
  local archive tmp extracted target
  archive="$RECON_DOWNLOAD_DIR/$(basename "$url")"
  recon_download "$url" "$archive"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/recon-tools.XXXXXX")"

  case "$archive" in
    *.zip)
      recon_has unzip || { rm -rf "$tmp"; recon_die '解压 .zip 需要 unzip。'; }
      unzip -q "$archive" -d "$tmp" || { rm -rf "$tmp"; recon_die "解压失败：$archive"; }
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$tmp" || { rm -rf "$tmp"; recon_die "解压失败：$archive"; }
      ;;
    *.gz)
      gzip -dc "$archive" > "$tmp/$binary" || { rm -rf "$tmp"; recon_die "解压失败：$archive"; }
      ;;
    *)
      rm -rf "$tmp"
      recon_die "无法识别的压缩包格式：$(basename "$archive")"
      ;;
  esac

  extracted="$(find "$tmp" -type f -name "$binary" -print -quit)"
  [ -n "$extracted" ] || { rm -rf "$tmp"; recon_die "安装包中未找到 ${binary}。"; }
  chmod +x "$extracted" 2>/dev/null || true

  mkdir -p "$RECON_BIN_DIR"
  target="$RECON_BIN_DIR/$binary"
  install -m 0755 "$extracted" "$target"
  rm -rf "$tmp"

  if [ "$RECON_KEEP_DOWNLOADS" = "1" ]; then
    recon_log "保留安装包：$archive"
  else
    rm -f "$archive"
  fi
  recon_log "已安装：$target"
}

recon_mark_managed() {
  local root="$1"
  mkdir -p "$root"
  printf '# managed by security/recon-tools\ncreated=%s\n' "$(date +%Y-%m-%d)" > "$root/.managed-by-recon"
}

recon_resolve_bin() {
  local binary="$1"
  if [ -x "$RECON_BIN_DIR/$binary" ]; then
    printf '%s\n' "$RECON_BIN_DIR/$binary"
    return 0
  fi
  if recon_has "$binary"; then
    printf '%s\n' "$(command -v "$binary")"
    return 0
  fi
  return 1
}

recon_uninstall() {
  local tool_name="$1" binary="$2" tool_root="$3"
  shift 3
  [ "${1:-}" = "--yes" ] || recon_die "卸载需要显式确认：uninstall --yes（避免误删）"
  local target="$RECON_BIN_DIR/$binary"
  if [ -f "$tool_root/.managed-by-recon" ]; then
    [ -e "$target" ] && { rm -f "$target" && recon_log "已删除：$target"; }
    [ -e "$tool_root" ] && { rm -rf "$tool_root" && recon_log "已删除：$tool_root"; }
    recon_ok "$tool_name 卸载完成。"
  else
    recon_warn "跳过删除（未找到本脚本管理标记）：$target / $tool_root"
  fi
}

recon_path_hint() {
  case ":$PATH:" in
    *":$RECON_BIN_DIR:"*) return 0 ;;
  esac
  recon_warn "请把安装目录加入 PATH："
  printf '  export PATH="%s:$PATH"\n' "$RECON_BIN_DIR"
}

recon_require_prereqs() {
  local missing=() cmd
  for cmd in "$@"; do
    recon_has "$cmd" || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] || recon_die "缺少依赖：${missing[*]}"
}
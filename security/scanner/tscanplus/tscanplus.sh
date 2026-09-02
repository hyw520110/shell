#!/usr/bin/env bash
# ============================================================================
# TscanPlus/TscanClient 安装与低影响扫描封装
#
# 设计目标：
#   - 支持 macOS Intel/Apple Silicon 与 Linux x86_64/arm64
#   - 默认只运行 URL 指纹和 JS 信息收集，不启用 POC、爆破或全端口扫描
#   - 工具、MCP 和报告均安装/写入用户目录，不污染当前仓库
#   - 仅使用 TideSec/TscanPlus 官方仓库中的构建文件
#
# 用法：
#   ./tscanplus.sh install [client|mcp|all]
#   ./tscanplus.sh status
#   ./tscanplus.sh scan-url --ack-authorized https://example.com/
#   ./tscanplus.sh scan-urls --ack-authorized urls.txt
#   ./tscanplus.sh mcp
#   ./tscanplus.sh uninstall --yes
#
# 注意：TscanPlus 的 POC、crack、cyber 等能力可能产生主动请求或处理敏感凭据，
# 本封装不提供自动启用入口；如需在授权实验室使用，请直接阅读官方文档并人工操作。
# ============================================================================

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

TSCAN_VERSION="${TSCAN_VERSION:-3.4.2}"
TSCAN_ROOT="${TSCAN_ROOT:-${HOME}/.local/share/tscanplus}"
TSCAN_BIN_DIR="${TSCAN_BIN_DIR:-${HOME}/.local/bin}"
TSCAN_CLIENT_BIN="$TSCAN_ROOT/TscanClient"
TSCAN_GUI_ROOT="$TSCAN_ROOT/TscanPlus.app"
TSCAN_MCP_SHIM="$TSCAN_BIN_DIR/tscanplus-mcp"
TSCAN_CLIENT_LINK="$TSCAN_BIN_DIR/tscanclient"
TSCAN_MARKER="$TSCAN_ROOT/.managed-by-shell"
TSCAN_GITHUB_RAW="https://github.com/TideSec/TscanPlus/raw/refs/heads/main"

web_require_platform() {
  case "$(uname -s)" in
    Darwin|Linux) ;;
    *) die "不支持的操作系统：$(uname -s)" ;;
  esac
}

show_help() {
  cat <<'EOF'
TscanPlus/TscanClient 安装与低影响扫描封装

安装/管理：
  install [client|mcp|all]  安装命令行版、MCP/GUI 版或全部（默认 client）
  update [client|mcp|all]   更新已选组件
  status                    查看安装状态，不执行扫描
  uninstall --yes           删除本脚本创建的用户目录和命令链接

低影响扫描：
  scan-url --ack-authorized <URL> [-o <报告文件>] [--include-dir]
  scan-urls --ack-authorized <URL文件> [-o <报告文件>] [--include-dir]

MCP：
  mcp                       由 Codex/其他 MCP 客户端以 stdio 方式启动

说明：扫描默认只启用 url,js；--include-dir 只增加低并发目录枚举。
本封装不自动启用 poc、crack、cyber、全端口、POC 全量或凭据验证。
报告默认写入 ~/security-scans/tscanplus/，不会写入当前仓库。
EOF
}

die() {
  printf '[tscanplus][错误] %s\n' "$*" >&2
  exit 1
}

log() { printf '[tscanplus] %s\n' "$*"; }

require_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "缺少依赖：${missing[*]}"
}

detect_asset_suffix() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:x86_64|Darwin:amd64) printf 'Mac_Amd64' ;;
    Darwin:arm64|Darwin:aarch64) printf 'Mac_Arm64' ;;
    Linux:x86_64|Linux:amd64) printf 'Linux_Amd64' ;;
    Linux:arm64|Linux:aarch64) printf 'Linux_Arm64' ;;
    *) die "不支持的平台：${os}/${arch}（仅支持 macOS/Linux x64/arm64）" ;;
  esac
}

download_file() {
  local url="$1" output="$2"
  require_cmds curl
  log "下载官方构建：$url"
  curl -fL --retry 2 --connect-timeout 15 --max-time 900 \
    -A 'security-tools-wrapper/1.0' "$url" -o "$output"
  [[ -s "$output" ]] || die "下载文件为空：$output"
}

find_binary() {
  local root="$1" preferred="$2" found
  found="$(find "$root" -type f -name "$preferred" -print -quit 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$root" -type f -perm -u+x -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$found" ]] || die "压缩包中未找到可执行文件：$preferred"
  printf '%s' "$found"
}

install_client() {
  require_cmds curl unzip find mkdir cp chmod ln
  local suffix archive tmp extract source
  suffix="$(detect_asset_suffix)"
  archive="$(mktemp "${TMPDIR:-/tmp}/tscanclient.XXXXXX.zip")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tscanclient-extract.XXXXXX")"
  trap 'rm -f "${archive:-}"; rm -rf "${tmp:-}"' RETURN

  download_file "$TSCAN_GITHUB_RAW/TscanClient/TscanClient_${suffix}.zip" "$archive"
  unzip -tq "$archive" >/dev/null || die "压缩包校验失败"
  unzip -q "$archive" -d "$tmp"
  source="$(find_binary "$tmp" TscanClient)"

  mkdir -p "$TSCAN_ROOT" "$TSCAN_BIN_DIR"
  cp "$source" "$TSCAN_CLIENT_BIN"
  chmod 0755 "$TSCAN_CLIENT_BIN"
  ln -sfn "$TSCAN_CLIENT_BIN" "$TSCAN_CLIENT_LINK"
  : > "$TSCAN_MARKER"
  trap - RETURN
  rm -f "$archive"
  rm -rf "$tmp"
  log "TscanClient 已安装：$TSCAN_CLIENT_LINK"
}

install_mcp() {
  require_cmds curl unzip find mkdir cp chmod ln
  local suffix tmp archive extract source mount app
  suffix="$(detect_asset_suffix)"
  mkdir -p "$TSCAN_ROOT" "$TSCAN_BIN_DIR"

  if [[ "$suffix" == Mac_* ]]; then
    require_cmds hdiutil ditto
    archive="$(mktemp "${TMPDIR:-/tmp}/tscanplus.XXXXXX.dmg")"
    mount="$(mktemp -d "${TMPDIR:-/tmp}/tscanplus-mount.XXXXXX")"
    trap 'rm -f "${archive:-}"; hdiutil detach "${mount:-}" >/dev/null 2>&1 || true; rmdir "${mount:-}" >/dev/null 2>&1 || true' RETURN
    download_file "$TSCAN_GITHUB_RAW/TscanPlus-v${TSCAN_VERSION}/TscanPlus_${suffix}.dmg" "$archive"
    hdiutil attach "$archive" -nobrowse -readonly -mountpoint "$mount" >/dev/null
    app="$(find "$mount" -maxdepth 2 -type d -name '*.app' -print -quit 2>/dev/null || true)"
    [[ -n "$app" ]] || die "DMG 中未找到 TscanPlus.app"
    if [[ -e "$TSCAN_GUI_ROOT" && ! -f "$TSCAN_MARKER" ]]; then
      die "目标目录已存在但没有本脚本管理标记，拒绝覆盖：$TSCAN_GUI_ROOT"
    fi
    rm -rf "$TSCAN_GUI_ROOT"
    ditto "$app" "$TSCAN_GUI_ROOT"
  else
    require_cmds unzip
    archive="$(mktemp "${TMPDIR:-/tmp}/tscanplus.XXXXXX.zip")"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/tscanplus-extract.XXXXXX")"
    trap 'rm -f "${archive:-}"; rm -rf "${tmp:-}"' RETURN
    download_file "$TSCAN_GITHUB_RAW/TscanPlus-v${TSCAN_VERSION}/TscanPlus_${suffix}.zip" "$archive"
    unzip -tq "$archive" >/dev/null || die "压缩包校验失败"
    unzip -q "$archive" -d "$tmp"
    source="$(find_binary "$tmp" TscanPlus)"
    cp "$source" "$TSCAN_ROOT/TscanPlus"
    chmod 0755 "$TSCAN_ROOT/TscanPlus"
  fi

  # 复制当前封装到用户安装目录，使 MCP 不依赖当前仓库路径。
  cp "$SCRIPT_PATH" "$TSCAN_ROOT/tscanplus.sh"
  chmod 0755 "$TSCAN_ROOT/tscanplus.sh"
  ln -sfn "$TSCAN_ROOT/tscanplus.sh" "$TSCAN_MCP_SHIM"
  : > "$TSCAN_MARKER"
  trap - RETURN
  rm -f "${archive:-}"
  rm -rf "${tmp:-}"
  if [[ -n "${mount:-}" ]]; then
    hdiutil detach "$mount" >/dev/null 2>&1 || true
    rmdir "$mount" >/dev/null 2>&1 || true
  fi
  log "TscanPlus MCP 启动器已安装：$TSCAN_MCP_SHIM"
}

cmd_install() {
  local what="${1:-client}"
  web_require_platform
  case "$what" in
    client) install_client ;;
    mcp) install_mcp ;;
    all) install_client; install_mcp ;;
    *) die "未知安装目标：$what（可选 client、mcp、all）" ;;
  esac
}

cmd_status() {
  printf 'TscanClient: '
  if [[ -x "$TSCAN_CLIENT_BIN" ]]; then
    printf '已安装 (%s)\n' "$TSCAN_CLIENT_BIN"
  else
    printf '未安装\n'
  fi
  printf 'TscanPlus MCP: '
  if [[ -x "$TSCAN_MCP_SHIM" ]]; then
    printf '启动器已安装 (%s)\n' "$TSCAN_MCP_SHIM"
  else
    printf '未安装\n'
  fi
  if [[ -d "$TSCAN_GUI_ROOT" ]]; then
    printf 'TscanPlus.app: %s\n' "$TSCAN_GUI_ROOT"
  elif [[ -x "$TSCAN_ROOT/TscanPlus" ]]; then
    printf 'TscanPlus Linux: %s\n' "$TSCAN_ROOT/TscanPlus"
  fi
  printf '报告目录: %s\n' "${TSCAN_OUTPUT_DIR:-$HOME/security-scans/tscanplus}"
}

require_authorized_url() {
  local target="$1" ack="$2"
  [[ "$ack" == "1" ]] || die "公网/远程扫描必须显式提供 --ack-authorized"
  [[ "$target" =~ ^https?://[^[:space:]]+$ ]] || die "目标必须是合法的 http(s) URL"
  [[ "$target" != *$'\n'* && "$target" != *$'\r'* ]] || die "目标不能包含换行"
}

run_scan() {
  local input_kind="$1" input="$2" output="$3" include_dir="$4"
  [[ -x "$TSCAN_CLIENT_BIN" ]] || die "TscanClient 未安装，请先执行：$0 install client"
  mkdir -p "$(dirname "$output")"
  local modules="url,js"
  [[ "$include_dir" == "1" ]] && modules="url,js,dir"
  log "低影响扫描：模块=$modules，报告=$output"
  if [[ "$input_kind" == "url" ]]; then
    "$TSCAN_CLIENT_BIN" -m "$modules" -u "$input" -wt 8 -ds 10 -nocolor -o "$output"
  else
    "$TSCAN_CLIENT_BIN" -m "$modules" -uf "$input" -wt 8 -ds 10 -nocolor -o "$output"
  fi
  log "扫描完成：$output"
}

parse_scan_args() {
  local kind="$1"; shift
  local target="" output="" ack=0 include_dir=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ack-authorized) ack=1; shift ;;
      --include-dir) include_dir=1; shift ;;
      -o) [[ $# -ge 2 ]] || die '-o 需要报告文件路径'; output="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      -*) die "未知扫描参数：$1" ;;
      *) [[ -z "$target" ]] || die '只能指定一个目标或目标文件'; target="$1"; shift ;;
    esac
  done
  [[ -n "$target" ]] || die '请指定目标或 URL 文件'
  if [[ "$kind" == "url" ]]; then
    require_authorized_url "$target" "$ack"
  else
    [[ "$ack" == "1" ]] || die "公网/远程扫描必须显式提供 --ack-authorized"
    [[ -f "$target" ]] || die "目标文件不存在：$target"
  fi
  if [[ -z "$output" ]]; then
    local stamp safe
    stamp="$(date +%Y%m%d-%H%M%S)"
    safe="$(basename "$target" | tr -c '[:alnum:]._- ' '_' | tr ' ' '_')"
    output="${TSCAN_OUTPUT_DIR:-$HOME/security-scans/tscanplus}/${safe}-${stamp}.txt"
  fi
  run_scan "$kind" "$target" "$output" "$include_dir"
}

cmd_uninstall() {
  [[ "${1:-}" == "--yes" ]] || die '卸载需要显式提供 --yes'
  if [[ -f "$TSCAN_MARKER" ]]; then
    rm -rf "$TSCAN_ROOT"
  else
    [[ ! -e "$TSCAN_ROOT" ]] || die "未找到管理标记，拒绝删除非本脚本创建的目录：$TSCAN_ROOT"
  fi
  rm -f "$TSCAN_CLIENT_LINK" "$TSCAN_MCP_SHIM"
  log 'TscanPlus/TscanClient 用户安装已删除。'
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    install|update) cmd_install "${1:-client}" ;;
    status) cmd_status ;;
    scan-url) parse_scan_args url "$@" ;;
    scan-urls) parse_scan_args urls "$@" ;;
    mcp) cmd_mcp "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    -h|--help|help) show_help ;;
    *) die "未知命令：$cmd；运行 $0 --help 查看帮助" ;;
  esac
}

cmd_mcp() {
  local bin="${TSCANPLUS_GUI_BIN:-}"
  local candidate
  if [[ -z "$bin" ]]; then
    for candidate in \
      "$TSCAN_GUI_ROOT/Contents/MacOS/TscanPlus" \
      "$TSCAN_ROOT/TscanPlus"; do
      if [[ -x "$candidate" ]]; then bin="$candidate"; break; fi
    done
  fi
  [[ -n "$bin" && -x "$bin" ]] || die "未找到 TscanPlus MCP 可执行文件，请先执行：$0 install mcp"
  exec "$bin" mcp stdio "$@"
}

main "$@"

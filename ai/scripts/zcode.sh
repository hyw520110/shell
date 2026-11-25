#!/usr/bin/env bash
#
# zcode.sh — ZCode 单一管理脚本 (安装 / 更新 / 检测最新版本 / 配置 / 卸载)
#
# 用法:
#   zcode.sh install              安装最新 ZCode
#   zcode.sh update               更新到最新 ZCode
#   zcode.sh latest [ARCH]        检测最新版本号 (默认按当前系统自动识别)
#   zcode.sh latest --json        JSON 格式 (供 ai-hub 消费)
#   zcode.sh latest --url [ARCH]  输出完整下载 URL
#   zcode.sh version              当前已安装版本
#   zcode.sh status               安装状态总览
#   zcode.sh check-latest         检测最新版本 (同 latest)
#   zcode.sh config view|edit|reset
#   zcode.sh uninstall
#
# 架构: mac-arm64, mac-x64, win-x64, win-arm64, linux-x64, linux-arm64
#
set -euo pipefail

# ─── 常量 ───────────────────────────────────────────────────────────────
CDN_BASE="https://cdn-zcode.z.ai/zcode/electron/releases"
HOME_PAGE="https://zcode.z.ai/cn#all-downloads"
DEFAULT_ARCH="mac-x64"
FALLBACK_VERSION="3.17.2"
# macOS 兼容版本: 系统版本 <= 12.x 时使用 (3.14.0 实测 LSMinimumSystemVersion=12.0 / minos=12.0, 兼容 macOS 12.7.6)
ZCODE_COMPAT_VERSION="3.14.0"
# macOS 兼容上限: 当系统主版本 <= 12 时强制用兼容版本
ZCODE_COMPAT_MAX_MAJOR="12"
CURL_OPTS="--connect-timeout 3 --max-time 5"
# adl 下载器 (优先使用, 用户要求)
ADL_BIN="$(command -v adl 2>/dev/null || echo '/Users/mac/workspace/shell/network/tools/adl')"
# 统一下载目录 + 装后删包约定
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
# CDN 下载探测列表: 从最新已知版本逐级向下
VERSION_CANDIDATES="4.0.0 3.17.2 3.17.1 3.17.0 3.16.0 3.15.0 3.14.0 3.13.0 3.12.0 3.11.0 3.10.0 3.9.0 3.8.0 3.7.0 3.6.0 3.5.0 3.4.0 3.3.0 3.2.0 2.15.0 2.14.0 2.13.0"
APP_GLOB="/Applications/ZCode*.app"
ZC_OS="$(uname -s 2>/dev/null || echo unknown)"
case "$ZC_OS" in
  Linux)
    ZC_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ZCode"
    ZC_CFG_DIR2="${XDG_CONFIG_HOME:-$HOME/.config}/zcode"
    ;;
  *)
    ZC_CFG_DIR="$HOME/Library/Application Support/ZCode"
    ZC_CFG_DIR2="$HOME/Library/Application Support/com.zcode-ai.zcode"
    ;;
esac
CACHE_FILE="${HOME}/.cache/ai-hub/zcode_version_hint"

# ─── 工具函数 ─────────────────────────────────────────────────────────────
safe_curl() { curl -s ${CURL_OPTS} "$@" 2>/dev/null || true; }

_log() { printf '%s\n' "$*"; }

# 安全 HTTP 状态码检测 (只发 HEAD，避免把 200MB 的 .deb 下载到 /dev/null)
http_code() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -I --connect-timeout 3 --max-time 5 "$1" 2>/dev/null || true)
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s\n' "$code"
}

# 当前 macOS 主版本号 (sw_vers 无输出/非 macOS 时回退 "99" 表示未知高版本)
macos_major() {
  sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 99
}

# 当前 macOS 完整版本 (如 12.7.6)
macos_full() {
  sw_vers -productVersion 2>/dev/null || echo "0.0.0"
}

# 当前系统 + CPU 架构 → ZCode 架构标识
# 修复：旧版只看 uname -m，把 Linux x86_64 误判成 mac-x64 并下载 DMG
detect_arch() {
  local os machine
  os="$(uname -s 2>/dev/null || echo unknown)"
  machine="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      case "$machine" in arm64|aarch64) echo 'mac-arm64' ;; *) echo 'mac-x64' ;; esac
      ;;
    Linux)
      case "$machine" in arm64|aarch64) echo 'linux-arm64' ;; *) echo 'linux-x64' ;; esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      case "$machine" in arm64|aarch64) echo 'win-arm64' ;; *) echo 'win-x64' ;; esac
      ;;
    *)
      case "$machine" in arm64|aarch64) echo 'mac-arm64' ;; *) echo 'mac-x64' ;; esac
      ;;
  esac
}

# 选择兼容版本: 系统主版本 <= ZCODE_COMPAT_MAX_MAJOR 时, 若探测到的最新版不兼容则用兼容版
# 返回: 0=用最新版(输出最新版号), 1=需用兼容版(输出 ZCODE_COMPAT_VERSION)
resolve_compatible_version() {
  local arch="${1:-mac-x64}" major
  major=$(macos_major)
  # macOS 主版本 <= 12 时强制用兼容版 (3.14.0 实测支持 macOS 12; 3.17.2 要求 macOS 13)
  if [[ "$major" != "99" ]] && (( major <= ZCODE_COMPAT_MAX_MAJOR )); then
    _log "[警告]  macOS $(macos_full) <= 12.x, 使用兼容版 v${ZCODE_COMPAT_VERSION} (最新版要求 macOS 13+)" >&2
    printf '%s\n' "$ZCODE_COMPAT_VERSION"
    return 1
  fi
  # 其他系统直接用最新
  get_latest_version "$arch"
  return 0
}


# 安全删除：仅当目标路径非空、basename 以 ZCode 开头、父目录为 /Applications 时才执行
# 防止变量为空导致 rm -rf /Applications/ 这类灾难 (曾误删 /Applications 下全部软件)
safe_rm_zcode_app() {
  local target="$1" base parent
  # 1) 空值 / 绝对根 / 目录本身 —— 一律拒绝
  [[ -z "$target" ]] && { _log "[警告]  跳过空路径删除"; return 0; }
  case "$target" in
    /|"/"|"."|".."|/*/) _log "[警告]  拒绝删除目录本身: $target"; return 0 ;;
  esac
  # 2) basename 必须非空且不是 "/"
  base=$(basename "$target")
  [[ -z "$base" || "$base" == "/" ]] && { _log "[警告]  basename 为空或 '/'，拒绝删除: $target"; return 0; }
  # 3) 父目录必须是 /Applications
  parent=$(dirname "$target")
  [[ "$parent" != "/Applications" ]] && { _log "[警告]  父目录非 /Applications，拒绝删除: $target"; return 0; }
  # 4) basename 必须匹配 ZCode 应用，防止误删其他软件
  case "$base" in
    ZCode*|zcode*) ;;
    *) _log "[警告]  非 ZCode 应用，拒绝删除: $target"; return 0 ;;
  esac
  rm -rf "$target" 2>/dev/null || sudo rm -rf "$target"
}
# 架构 → 平台目录 (mac-arm64 → macos-arm64, win-x64 → windows-x64)
platform_dir() {
  case "${1:-mac-arm64}" in
    mac-arm64|macos-arm64) echo "macos-arm64" ;;
    mac-x64|macos-x64)     echo "macos-x64" ;;
    win-x64|windows-x64)   echo "windows-x64" ;;
    win-arm64|windows-arm64) echo "windows-arm64" ;;
    linux-x64)             echo "linux-x64" ;;
    linux-arm64)           echo "linux-arm64" ;;
    *)                     echo "macos-x64" ;;
  esac
}

# 架构 → 文件后缀
file_ext() {
  case "${1:-mac-x64}" in
    mac-*) echo "dmg" ;;
    win-*) echo "exe" ;;
    linux-x64) echo "deb" ;;
    linux-arm64) echo "deb" ;;
    *) echo "dmg" ;;
  esac
}

# 构造完整下载 URL: ${CDN_BASE}/${ver}/${platform}/ZCode-${ver}-${arch}.${ext}
build_url() {
  local ver="$1" arch="${2:-mac-x64}" pdir ext
  pdir=$(platform_dir "$arch")
  ext=$(file_ext "$arch")
  echo "${CDN_BASE}/${ver}/${pdir}/ZCode-${ver}-${arch}.${ext}"
}

# ─── 版本检测 ─────────────────────────────────────────────────────────────
# 从官网文档抓取 hint 版本号作为探测起点 (带 60 分钟缓存)
fetch_hint_version() {
  local hint=""

  if [[ -f "$CACHE_FILE" ]] && [[ $(find "$CACHE_FILE" -mmin -60 2>/dev/null) ]]; then
    hint=$(cat "$CACHE_FILE" 2>/dev/null || true)
    if [[ -n "$hint" ]]; then printf '%s\n' "$hint"; return 0; fi
  fi

  # 官网文档抓取 (兼容 BSD grep: 用 -oE + sed, 不用 GNU 的 -oP)
  hint=$(safe_curl "https://zcode.z.ai/cn/docs/install" \
    | grep -oE 'ZCode-[0-9]+\.[0-9]+\.[0-9]+' \
    | sed 's/ZCode-//' \
    | head -1 || true)

  if [[ -z "$hint" ]]; then
    hint=$(safe_curl "https://zcode.z.ai" \
      | grep -oE 'releases/[0-9]+\.[0-9]+\.[0-9]+' \
      | sed 's#releases/##' \
      | head -1 || true)
  fi

  hint="${hint:-$FALLBACK_VERSION}"
  mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
  printf '%s\n' "$hint" > "$CACHE_FILE" 2>/dev/null || true
  printf '%s\n' "$hint"
}

# 探测指定架构下是否存在某版本 (带结果缓存，避免 status 每次都全量 HTTP)
PROBE_CACHE_DIR="${HOME}/.cache/ai-hub/zcode_probe"
probe_version() {
  local ver="$1" arch="${2:-mac-x64}" code cf
  # 缓存键: <arch>-<ver>.code，有效期 60 分钟
  cf="${PROBE_CACHE_DIR}/${arch}-${ver}.code"
  if [[ -f "$cf" ]] && [[ $(find "$cf" -mmin -60 2>/dev/null) ]]; then
    local cached
    cached=$(cat "$cf" 2>/dev/null || true)
    if [[ "$cached" =~ ^[0-9]{3}$ ]]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi
  code=$(http_code "$(build_url "$ver" "$arch")")
  mkdir -p "$PROBE_CACHE_DIR" 2>/dev/null || true
  printf '%s\n' "$code" > "$cf" 2>/dev/null || true
  printf '%s\n' "$code"
}

# 获取最新版本号
get_latest_version() {
  local arch="${1:-mac-x64}" ver v code

  # 1) 先按已知候选列表从高到低探测 (最可靠)
  for v in $VERSION_CANDIDATES; do
    code=$(probe_version "$v" "$arch")
    if [[ "$code" == "200" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  done

  # 2) 候选列表无命中时, 用官网 hint 向上/向下探测
  local hint major minor patch p
  hint=$(fetch_hint_version)
  IFS='.' read -r major minor patch <<< "$hint" || true
  for p in $((patch + 2)) $((patch + 1)) "$patch" $((patch - 1)) $((patch - 2)); do
    [[ $p -lt 0 ]] && continue
    code=$(probe_version "${major}.${minor}.${p}" "$arch")
    if [[ "$code" == "200" ]]; then
      printf '%s\n' "${major}.${minor}.${p}"
      return 0
    fi
  done

  printf '%s\n' "$hint"
}

# 输出 JSON (供 ai-hub 消费)
output_json() {
  local arch ver_arm64 ver_x64 ver_win ver_linux_x64 ver_linux_arm64
  local url_arm64 url_x64 url_win url_linux_x64 url_linux_arm64
  arch=$(detect_arch)

  ver_arm64=$(get_latest_version "mac-arm64")
  ver_x64=$(get_latest_version "mac-x64")
  ver_win=$(get_latest_version "win-x64")
  ver_linux_x64=$(get_latest_version "linux-x64")
  ver_linux_arm64=$(get_latest_version "linux-arm64")

  url_arm64=$(build_url "$ver_arm64" mac-arm64)
  url_x64=$(build_url "$ver_x64" mac-x64)
  url_win=$(build_url "$ver_win" win-x64)
  url_linux_x64=$(build_url "$ver_linux_x64" linux-x64)
  url_linux_arm64=$(build_url "$ver_linux_arm64" linux-arm64)

  cat <<JSONEOF
{
  "latest_version": "${ver_arm64}",
  "current_arch": "${arch}",
  "downloads": {
    "mac-arm64": { "version": "${ver_arm64}", "url": "${url_arm64}" },
    "mac-x64":   { "version": "${ver_x64}",   "url": "${url_x64}" },
    "win-x64":   { "version": "${ver_win}",   "url": "${url_win}" },
    "linux-x64": { "version": "${ver_linux_x64}", "url": "${url_linux_x64}" },
    "linux-arm64": { "version": "${ver_linux_arm64}", "url": "${url_linux_arm64}" }
  }
}
JSONEOF
}

# ─── 安装 / 更新 (共用逻辑) ──────────────────────────────────────────────
# Linux: CDN 提供 .deb，使用 apt 安装 (可自动解决依赖)
do_install_deb() {
  local arch="$1" ver="$2" url="$3"
  local pkg="$DOWNLOAD_DIR/ZCode-${ver}-${arch}.deb" dl_ok=0

  rm -f "$pkg"
  if [[ -x "$ADL_BIN" ]]; then
    _log "[下载] 使用 adl 下载 (优先级高)..."
    if "$ADL_BIN" "$url" "$DOWNLOAD_DIR" "$(basename "$pkg")" >/dev/null 2>&1; then
      dl_ok=1
    else
      _log "[警告]  adl 下载失败，回退 curl..."
    fi
  fi
  if (( ! dl_ok )); then
    pkg=$(mktemp "${TMPDIR:-/tmp}/zcode.XXXXXX.deb")
    if ! curl -fL# --retry 3 --connect-timeout 10 --max-time 0 "$url" -o "$pkg"; then
      _log '[失败] 下载失败，请手动下载: ' "$HOME_PAGE"
      rm -f "$pkg"
      return 1
    fi
  fi

  _log "正在安装 ZCode v${ver} (${arch})..."
  if ! command -v sudo >/dev/null 2>&1; then
    _log '[失败] 系统级安装需要 sudo，当前环境不可用'
    rm -f "$pkg"
    return 1
  fi
  if ! sudo apt install -y "$pkg"; then
    _log '[警告]  apt 安装失败，尝试 dpkg + 依赖修复...'
    sudo dpkg -i "$pkg" || true
    sudo apt -f install -y || true
  fi
  rm -f "$pkg"

  if command -v zcode >/dev/null 2>&1 || dpkg -s zcode 2>/dev/null | grep -q 'Status: install ok installed'; then
    _log "[OK] ZCode 安装完成！版本 v$(installed_version)"
    _log "   命令: $(command -v zcode 2>/dev/null || echo zcode)"
    _log '首次启动: 1) 注册/登录智谱账号  2) 配置 AI 供应商 (BigModel/Z.ai/自定义 API Key)  3) 选择模型'
    return 0
  fi
  _log '[失败] 安装后未检测到 zcode，请尝试手动安装: ' "$HOME_PAGE"
  return 1
}

do_install() {
  local ZC_ARCH url_code url dmg vol app installed
  ZC_ARCH=$(detect_arch)

  _log "检测 ZCode 兼容版本 (${ZC_ARCH})..."
  local ZC_VER
  ZC_VER=$(resolve_compatible_version "$ZC_ARCH") || true
  url_code=$(build_url "$ZC_VER" "$ZC_ARCH")
  _log "[下载] 正在下载 ZCode v${ZC_VER} (${ZC_ARCH})..."
  _log "   ${url_code}"

  case "$ZC_ARCH" in
    linux-*) do_install_deb "$ZC_ARCH" "$ZC_VER" "$url_code"; return $? ;;
  esac

  local dl_ok=0
  if [[ -x "$ADL_BIN" ]]; then
    _log "[下载] 使用 adl 下载 (优先级高)..."
    dmg="$DOWNLOAD_DIR/ZCode-${ZC_VER}-${ZC_ARCH}.dmg"
    rm -f "$dmg"
    if "$ADL_BIN" "$url_code" "$DOWNLOAD_DIR" "$(basename "$dmg")" >/dev/null 2>&1; then
      dl_ok=1
    else
      _log "[警告]  adl 下载失败，回退 curl..."
    fi
  fi
  if (( ! dl_ok )); then
    dmg=$(mktemp /tmp/zcode.XXXXXX)
    if ! curl -fL# --retry 3 --connect-timeout 10 --max-time 0 "$url_code" -o "$dmg"; then
      _log '[失败] 下载失败，请手动下载: ' "$HOME_PAGE"
      rm -f "$dmg"
      return 1
    fi
  fi

  _log ''
  _log '正在挂载 DMG...'
  vol=$(hdiutil attach "$dmg" -nobrowse 2>/dev/null | awk '/Volumes/ {print $3}' | head -1)
  if [[ -z "$vol" ]] || [[ ! -d "$vol" ]]; then
    vol=$(ls -d /Volumes/ZCode* 2>/dev/null | head -1)
  fi
  if [[ -z "$vol" ]] || [[ ! -d "$vol" ]]; then
    _log '[失败] 挂载 DMG 失败'
    rm -f "$dmg"
    return 1
  fi
  _log "   挂载点: ${vol}"

  app=$(ls -d "$vol"/*.app 2>/dev/null | head -1)
  if [[ -z "$app" ]]; then
    _log '[失败] DMG 中未找到 .app'
    hdiutil detach "$vol" -force 2>/dev/null || true
    rm -f "$dmg"
    return 1
  fi

  _log "正在安装 $(basename "$app") 到 /Applications..."
  local _existing="/Applications/$(basename "$app")"
  if [[ -n "$app" ]] && [[ -d "$_existing" ]]; then
    _log '   覆盖已有版本...'
    safe_rm_zcode_app "$_existing"
  fi
  cp -R "$app" /Applications/ 2>/dev/null || sudo cp -R "$app" /Applications/

  _log '正在清理...'
  hdiutil detach "$vol" 2>/dev/null || hdiutil detach "$vol" -force 2>/dev/null || true
  rm -f "$dmg"

  installed=$(ls -d $APP_GLOB 2>/dev/null | head -1)
  if [[ -n "$installed" ]]; then
    _log "[OK] ZCode 安装完成！版本 v$(installed_version)"
    _log "应用路径: ${installed}"
    _log '首次启动: 1) 注册/登录智谱账号  2) 配置 AI 供应商 (BigModel/Z.ai/自定义 API Key)  3) 选择模型'
    _log '第三方 API: 设置 → 模型设置 → 添加供应商 → 填入 token173 等 API 地址和 Key'
  else
    _log '[失败] 安装失败，请尝试手动安装: ' "$HOME_PAGE"
    return 1
  fi
}

cmd_install()  { do_install; }
cmd_update()   { do_install; }

# ─── 已安装版本 ─────────────────────────────────────────────────────────
installed_path() {
  if [[ "$ZC_OS" == "Linux" ]]; then
    command -v zcode 2>/dev/null || true
  else
    ls -d $APP_GLOB 2>/dev/null | head -1
  fi
}

installed_version() {
  local app v
  if [[ "$ZC_OS" == "Linux" ]]; then
    v=$(dpkg-query -W -f='${Version}' zcode 2>/dev/null || true)
    if [[ -n "$v" ]]; then
      printf '%s\n' "${v%%-*}"
      return
    fi
    if command -v zcode >/dev/null 2>&1; then
      zcode --version 2>/dev/null | head -1 || echo "未知"
      return
    fi
    echo "未安装"
    return
  fi
  app=$(installed_path)
  [[ -z "$app" ]] && { echo "未安装"; return; }
  defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "未知"
}

cmd_version() { printf '已安装版本: v%s\n' "$(installed_version)"; }

cmd_status() {
  local app ver latest
  app=$(installed_path)
  ver=$(installed_version)
  if [[ -n "$app" ]]; then
    _log "[OK] 已安装 v${ver}"
    _log "   路径: ${app}"
  else
    _log "[失败] 未安装"
  fi
  if [[ -d "$ZC_CFG_DIR" ]]; then
    _log "[OK] 配置目录: ${ZC_CFG_DIR} (已初始化)"
  else
    _log "[警告]  配置目录未初始化 (首次启动后创建)"
  fi
  latest=$(get_latest_version "$(detect_arch)")
  _log "最新版本: v${latest} (${HOME_PAGE})"
}

# ─── 配置管理 ───────────────────────────────────────────────────────────
cmd_config() {
  local op="${1:-view}"
  case "$op" in
    view)
      _log "ZCode 配置目录: ${ZC_CFG_DIR}"
      ls -la "$ZC_CFG_DIR" 2>/dev/null || _log '配置目录不存在 (首次启动后创建)'
      ;;
    edit)
      if [[ "$ZC_OS" == "Linux" ]] && command -v zcode >/dev/null 2>&1; then
        zcode >/dev/null 2>&1 &
        _log '请在 ZCode → 设置 中修改配置'
      elif command -v open >/dev/null 2>&1; then
        open -a ZCode 2>/dev/null && _log '请在 ZCode → 设置 (Command+,) 中修改配置' || _log 'ZCode 未安装'
      else
        _log 'ZCode 未安装'
      fi
      ;;
    reset)
      printf '[警告]  确认重置 ZCode 所有配置？[y/N] '
      read -r _reset || return 0
      [[ "$_reset" == "y" ]] || { _log '已取消'; return 0; }
      rm -rf "$ZC_CFG_DIR" "$ZC_CFG_DIR2" 2>/dev/null || true
      _log '[OK] ZCode 配置已重置 (重启 ZCode 后生效)'
      ;;
    *)
      _log "用法: $0 config view|edit|reset"
      return 1
      ;;
  esac
}

# ─── 卸载 ───────────────────────────────────────────────────────────────
cmd_uninstall() {
  _log '[卸载]  正在卸载 ZCode...'
  local apps app
  if [[ "$ZC_OS" == "Linux" ]]; then
    if dpkg -s zcode 2>/dev/null | grep -q 'Status: install ok installed'; then
      command -v sudo >/dev/null 2>&1 && sudo apt remove -y zcode || sudo dpkg -r zcode
    else
      _log '未检测到已安装的 zcode 包'
    fi
    printf '是否同时删除配置数据 (%s/)？[y/N] ' "$ZC_CFG_DIR"
    read -r _ans || true
    if [[ "$_ans" == "y" ]]; then
      rm -rf "$ZC_CFG_DIR" "$ZC_CFG_DIR2" 2>/dev/null || true
    fi
    _log '[OK] ZCode 已卸载'
    return 0
  fi
  apps=$(ls -d $APP_GLOB 2>/dev/null || true)
  if [[ -n "$apps" ]]; then
    for app in $apps; do
      _log "  删除: $app"
      safe_rm_zcode_app "$app"
    done
  fi
  printf '是否同时删除配置数据 (%s/)？[y/N] ' "$ZC_CFG_DIR"
  read -r _ans || true
  if [[ "$_ans" == "y" ]]; then
    rm -rf "$ZC_CFG_DIR" "$ZC_CFG_DIR2" 2>/dev/null || true
  fi
  _log '[OK] ZCode 已卸载'
}

# ─── 入口 ───────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
用法: $0 [命令] [选项]

命令:
  install                 安装最新 ZCode (默认)
  update                  更新到最新 ZCode
  latest [ARCH]           检测最新版本号
  latest --json           JSON 格式 (供 ai-hub 消费)
  latest --url [ARCH]     输出完整下载 URL
  version                 当前已安装版本
  status                  安装状态总览
  check-latest            同 latest
  config view|edit|reset  配置管理
  uninstall               卸载

架构 (latest 默认按当前系统自动识别):
  mac-arm64, mac-x64, win-x64, win-arm64, linux-x64, linux-arm64

示例:
  $0 install
  $0 latest --url mac-arm64
  $0 status
EOF
}

cmd="${1:-install}"
shift || true

case "$cmd" in
  install)            cmd_install "$@" ;;
  update)             cmd_update "$@" ;;
  version|-v)         cmd_version "$@" ;;
  status)             cmd_status "$@" ;;
  latest|check-latest)
    case "${1:-}" in
      --json)  output_json ;;
      --url)   build_url "$(get_latest_version "${2:-$(detect_arch)}")" "${2:-$(detect_arch)}" ;;
      *)       get_latest_version "${1:-$(detect_arch)}" ;;
    esac
    ;;
  config)             cmd_config "${1:-view}" "${2:-}" ;;
  uninstall)          cmd_uninstall ;;
  -h|--help|help)     usage ;;
  "")                 usage ;;
  *)
    # 兼容旧调用方式: 直接传 ARCH 参数 (如 mac-arm64)
    if [[ "$cmd" == mac-* || "$cmd" == win-* || "$cmd" == linux-* ]]; then
      get_latest_version "$cmd"
    else
      _log "未知命令: $cmd"
      usage
      return 1
    fi
    ;;
esac

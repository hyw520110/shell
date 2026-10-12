#!/usr/bin/env bash
# =============================================================================
# install.sh - mihomo (Clash Meta 内核) 安装 / 卸载 / 更新 / 配置脚本
# -----------------------------------------------------------------------------
# - 跨平台：Linux (amd64/arm64/armv7) + macOS (amd64/arm64)
# - 支持 systemd 服务管理（Linux）和 LaunchAgent（macOS）
# - 支持 GitHub 镜像加速（--mirror）和代理下载（--proxy）
# - 支持订阅链接导入（--config URL）
# - 自动下载 GeoIP/GeoSite 数据库
# -----------------------------------------------------------------------------
# 用法:
#   sudo ./install.sh                           # 交互式安装（系统级）
#   sudo ./install.sh --install                 # 直接安装
#   sudo ./install.sh --update                  # 更新到最新版
#   sudo ./install.sh --uninstall               # 卸载
#   sudo ./install.sh --config "https://sub.url/config.yaml"  # 导入订阅
#   ./install.sh --user                         # 用户级安装（不用 sudo）
#   ./install.sh --mirror "https://ghproxy.net" # 使用 GitHub 镜像加速
#   ./install.sh --proxy "http://127.0.0.1:7890" # 通过代理下载
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

BINARY_NAME="mihomo"
REPO="MetaCubeX/mihomo"
# GitHub 镜像加速前缀（用户可通过 --mirror 覆盖）
GITHUB_MIRROR=""
# GitHub 镜像候选（自动检测用，按顺序尝试）
MIRROR_CANDIDATES=(
  "https://ghproxy.net"
  "https://gh-proxy.com"
  "https://ghfast.top"
  "https://mirror.ghproxy.com"
  "https://ghps.cc"
)
PROXY_MEMO_FILE=""   # 代理记忆文件（init_paths 后确定）

# ---------------------------------------------------------------------------
# 默认路径（根据安装模式动态设置）
# ---------------------------------------------------------------------------
INSTALL_MODE="system"  # system 或 user
DOWNLOAD_DIR="${HOME}/Downloads"
CONFIG_DIR=""
INSTALL_DIR=""
SERVICE_FILE=""
SERVICE_NAME="mihomo"

# 动作
ACTION=""
SUB_CONFIG_URL=""
PROXY_URL=""
FORCE=0
SPECIFY_VERSION=""

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS] [ACTION]

ACTION（缺省时交互式询问）:
  --install        安装 mihomo
  --update         更新到最新版
  --uninstall      卸载 mihomo
  --import-clashx [SOURCE]  从 ClashX Meta 导入配置（SOURCE: 本地路径 或 user@host:path，缺省交互输入）
  --ui                     安装/更新 metacubexd Web 面板（external-ui）

OPTIONS:
  --config URL        导入订阅链接（下载 config.yaml）
  --user              用户级安装（安装到 ~/.local/bin，配置在 ~/.config/mihomo，不用 sudo）
  --mirror URL        GitHub 镜像加速前缀（如 https://ghproxy.net）
  --proxy URL         通过指定代理下载（如 http://127.0.0.1:7890）
  --download-dir DIR  下载缓存目录（默认: ~/Downloads）
  --config-dir DIR    配置目录（默认: 系统级 /etc/mihomo，用户级 ~/.config/mihomo）
  --force             跳过所有交互确认
  --version VER       指定版本号（如 v1.19.29），跳过 GitHub API 查询
  --help, -h          显示本帮助

示例:
  sudo ./install.sh                                          # 系统级安装
  sudo ./install.sh --install --mirror https://ghproxy.net   # 用镜像加速安装
  sudo ./install.sh --config "https://example.com/sub.yaml"  # 导入订阅
  sudo ./install.sh --update                                 # 更新
  sudo ./install.sh --uninstall                              # 卸载
  ./install.sh --user                                        # 用户级安装
  ./install.sh --proxy http://127.0.0.1:7890 --install       # 通过代理下载
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install)        ACTION="install" ;;
    --update)         ACTION="update" ;;
    --uninstall)      ACTION="uninstall" ;;
    --import-clashx)
      ACTION="clashx_import"
      if [ $# -gt 1 ] && [[ "$2" != -* ]]; then shift; CLASHX_SOURCE="$1"; fi
      ;;
    --ui)                 ACTION="install_ui" ;;
    --config)         shift; SUB_CONFIG_URL="$1" ;;
    --user)           INSTALL_MODE="user" ;;
    --mirror)         shift; GITHUB_MIRROR="${1%/}" ;;
    --proxy)          shift; PROXY_URL="$1" ;;
    --download-dir)   shift; DOWNLOAD_DIR="$1" ;;
    --config-dir)     shift; CONFIG_DIR="$1" ;;
    --force)          FORCE=1 ;;
    --version)        shift; SPECIFY_VERSION="$1" ;;
    --help|-h)        usage; exit 0 ;;
    *)
      error "未知参数: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 初始化路径
# ---------------------------------------------------------------------------
init_paths() {
  if [ "$INSTALL_MODE" = "user" ]; then
    INSTALL_DIR="${HOME}/.local/bin"
    CONFIG_DIR="${CONFIG_DIR:-${HOME}/.config/mihomo}"
    SERVICE_FILE=""
    PROXY_MEMO_FILE="${CONFIG_DIR}/.proxy.conf"
  else
    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="${CONFIG_DIR:-/etc/mihomo}"
    PROXY_MEMO_FILE="${CONFIG_DIR}/.proxy.conf"
    if [ "$(uname -s)" = "Darwin" ]; then
      SERVICE_FILE="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    else
      SERVICE_FILE="/etc/systemd/system/mihomo.service"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 平台检测
# ---------------------------------------------------------------------------
detect_platform() {
  OS=""
  ARCH=""
  case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux" ;;
    *)
      error "不支持的系统: $(uname -s)"
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    arm64|aarch64)  ARCH="arm64" ;;
    armv7l)          ARCH="armv7" ;;
    *)
      error "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac

  ok "平台: ${OS}/${ARCH}（安装模式: ${INSTALL_MODE}）"
}

# ---------------------------------------------------------------------------
# 权限检查
# ---------------------------------------------------------------------------
check_root() {
  if [ "$INSTALL_MODE" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    error "系统级安装需要 root 权限，请使用 sudo 或加 --user 用户级安装"
    exit 1
  fi
}

# 交互确认
ask_yes_no() {
  [ "$FORCE" -eq 1 ] && return 0
  local prompt="${1:-继续? (y/N)}"
  local reply
  printf "%s " "$prompt"
  read -r reply || reply="n"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# 下载工具
# ---------------------------------------------------------------------------
# 构建下载 URL（支持镜像加速）
build_url() {
  local github_url="$1"
  if [ -n "$GITHUB_MIRROR" ]; then
    echo "${GITHUB_MIRROR}/${github_url}"
  else
    echo "$github_url"
  fi
}

# ---------------------------------------------------------------------------
# 网络通道自动检测（直连 → 镜像 → 记忆代理 → 交互输入代理）
# ---------------------------------------------------------------------------
# 测试 URL 是否可达（返回 0 表示可达）
test_url() {
  local url="$1" proxy_args=""
  [ -n "$PROXY_URL" ] && proxy_args="--proxy $PROXY_URL"
  curl -s -o /dev/null -w '%{http_code}' -L --connect-timeout 8 --max-time 12 $proxy_args "$url" 2>/dev/null | grep -qE '^(200|301|302|307|308)$'
}

# 加载上次保存的代理
load_proxy_memo() {
  [ -n "$PROXY_MEMO_FILE" ] || return 0
  [ -f "$PROXY_MEMO_FILE" ] || return 0
  local saved old
  saved="$(head -1 "$PROXY_MEMO_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$saved" ] && return 0
  old="$PROXY_URL"
  PROXY_URL="$saved"
  if test_url "https://github.com"; then
    ok "使用上次保存的代理: ${PROXY_URL}"
  else
    warn "上次保存的代理不可用: ${PROXY_URL}"
    PROXY_URL="$old"
  fi
}

# 保存代理记忆（下次自动复用）
save_proxy_memo() {
  [ -z "$PROXY_URL" ] && return 0
  [ -n "$PROXY_MEMO_FILE" ] || return 0
  mkdir -p "$(dirname "$PROXY_MEMO_FILE")" 2>/dev/null || true
  echo "$PROXY_URL" > "$PROXY_MEMO_FILE" 2>/dev/null && info "已保存代理配置（下次自动复用）: ${PROXY_MEMO_FILE}"
}

# 交互式提示输入代理地址（IP + 端口）
prompt_proxy() {
  if [ "$FORCE" -eq 1 ] || [ ! -t 0 ]; then
    warn "非交互模式，请手动指定: --proxy http://IP:PORT 或 --mirror URL"
    return 1
  fi
  echo ""
  warn "检测不到可用的 GitHub 通道（直连与镜像均失败）"
  warn "必须通过代理才能访问 GitHub 下载 mihomo"
  local input
  read -r -p "请输入代理地址（如 http://192.168.1.100:7890，直接回车跳过）: " input
  input="$(echo "$input" | tr -d '[:space:]')"
  [ -z "$input" ] && return 1
  # 补充协议前缀
  [[ "$input" != http://* && "$input" != https://* && "$input" != socks5://* ]] && input="http://${input}"
  # 格式校验: 协议://主机:端口
  if ! echo "$input" | grep -qE '^(https?|socks5)://[^:/[:space:]]+:[0-9]{1,5}$'; then
    warn "代理格式不正确: $input（应为 http://IP:端口）"
    return 1
  fi
  PROXY_URL="$input"
  if test_url "https://github.com"; then
    ok "代理可用: ${PROXY_URL}"
    return 0
  fi
  # 容错: https 前缀访问 http 代理端口常失败，自动改用 http 前缀再试一次
  if [[ "$input" == https://* ]]; then
    local alt="http://${input#https://}"
    PROXY_URL="$alt"
    if test_url "https://github.com"; then
      warn "https 前缀不通，自动改用 http 前缀"
      ok "代理可用: ${PROXY_URL}"
      return 0
    fi
  fi
  warn "代理不可达: ${PROXY_URL}（请确认代理服务和地址）"
  PROXY_URL=""
  return 1
}

# 自动检测可用下载通道（已显式指定则直接使用）
detect_channel() {
  # 容错: --mirror 误填了代理地址（形如 IP:端口 或 协议://IP:端口 且无路径）→ 自动转为代理
  if [ -n "$GITHUB_MIRROR" ]; then
    local m="$GITHUB_MIRROR"
    if echo "$m" | grep -qE '^(https?|socks5)://[^/:]+:[0-9]{1,5}$' || echo "$m" | grep -qE '^[0-9a-zA-Z.-]+:[0-9]{1,5}$'; then
      warn "检测到 --mirror 参数看起来像代理地址（${m}），自动转为 --proxy 使用"
      PROXY_URL="$m"
      [[ "$PROXY_URL" != http://* && "$PROXY_URL" != https://* && "$PROXY_URL" != socks5://* ]] && PROXY_URL="http://${PROXY_URL}"
      GITHUB_MIRROR=""
      ok "已转为代理: ${PROXY_URL}"
      return 0
    fi
    ok "使用指定镜像: ${GITHUB_MIRROR}"
    return 0
  fi
  [ -n "$PROXY_URL" ] && { ok "使用指定代理: ${PROXY_URL}"; return 0; }

  info "自动检测 GitHub 访问通道..."

  # 1) 直连
  if test_url "https://github.com"; then
    ok "直连 GitHub 可用"
    return 0
  fi
  warn "直连 GitHub 失败"

  # 2) 上次保存的代理
  load_proxy_memo
  [ -n "$PROXY_URL" ] && return 0

  # 3) 镜像候选（依次测试）
  local m
  for m in "${MIRROR_CANDIDATES[@]}"; do
    if test_url "${m}/https://github.com"; then
      ok "镜像可用: ${m}"
      GITHUB_MIRROR="$m"
      return 0
    fi
  done
  warn "所有 GitHub 镜像均不可用"

  # 4) 交互式输入代理
  prompt_proxy && return 0

  return 1
}

# 下载文件（支持代理和镜像，自动重试）
download_file() {
  local url="$1"
  local dest="$2"
  local desc="${3:-文件}"

  mkdir -p "$(dirname "$dest")"

  # 构建实际下载 URL
  local actual_url
  actual_url="$(build_url "$url")"

  # 代理参数
  local proxy_args=""
  if [ -n "$PROXY_URL" ]; then
    proxy_args="--proxy $PROXY_URL"
  fi

  info "开始下载 ${desc}: $(basename "$dest")"

  # 优先使用 aria2c（多线程加速，带超时避免卡死）
  if command -v aria2c >/dev/null 2>&1; then
    info "使用 aria2c 多线程下载"
    aria2c \
      --max-connection-per-server=5 \
      --continue=true \
      --split=5 \
      --allow-overwrite=true \
      --check-certificate=false \
      --file-allocation=none \
      --connect-timeout=30 \
      --timeout=300 \
      --max-tries=3 \
      --retry-wait=5 \
      $proxy_args \
      --out="$(basename "$dest")" \
      --dir="$(dirname "$dest")" \
      "$actual_url" 2>&1 || {
        warn "aria2c 下载失败，尝试 curl ..."
        local curl_proxy=""
        [ -n "$PROXY_URL" ] && curl_proxy="--proxy $PROXY_URL"
        curl -L --fail --connect-timeout 30 --max-time 600 --retry 3 $curl_proxy -o "$dest" "$actual_url"
      }
  else
    info "使用 curl 下载（安装 aria2 可提速）"
    local curl_proxy=""
    [ -n "$PROXY_URL" ] && curl_proxy="--proxy $PROXY_URL"
    curl -L --fail --connect-timeout 30 --max-time 600 --retry 3 $curl_proxy -o "$dest" "$actual_url"
  fi

  [ -s "$dest" ] || { error "下载文件为空: $dest"; return 1; }
  ok "${desc}下载完成: $(du -h "$dest" | awk '{print $1}')"
}

# ---------------------------------------------------------------------------
# 查询 GitHub 最新版本
# ---------------------------------------------------------------------------
# 返回: tag \t asset_name \t download_url
query_release() {
  local curl_proxy=""
  [ -n "$PROXY_URL" ] && curl_proxy="--proxy $PROXY_URL"

  # 平台信息
  local os_name arch_name
  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64)  arch_name="amd64" ;;
    arm64|aarch64) arch_name="arm64" ;;
    armv7l)         arch_name="armv7" ;;
    *)              arch_name="amd64" ;;
  esac

  # 方案0: 用户指定版本号（跳过 API 查询）
  if [ -n "$SPECIFY_VERSION" ]; then
    local tag="$SPECIFY_VERSION"
    # 确保以 v 开头
    [[ "$tag" != v* ]] && tag="v$tag"
    local asset_name="mihomo-${os_name}-${arch_name}-${tag}.gz"
    local base_url="https://github.com/${REPO}/releases/download/${tag}"
    echo -e "${tag}\t${asset_name}\t${base_url}/${asset_name}"
    return 0
  fi

  # 方案1: 通过 GitHub API 查询（直连，或经镜像代理 api.github.com）
  local api="https://api.github.com/repos/${REPO}/releases/latest"
  local api_url="$api"
  [ -n "$GITHUB_MIRROR" ] && api_url="${GITHUB_MIRROR}/${api}"
  local json
  json=$(curl -sSL --max-time 15 $curl_proxy "$api_url" 2>/dev/null) || true

  if [ -n "$json" ]; then
    # 通过临时文件传递 JSON 给 python3
    # （环境变量传递在 JSON >128KB 时会触发 E2BIG 参数列表过长）
    local json_tmp
    json_tmp="$(mktemp)"
    printf '%s' "$json" > "$json_tmp"
    local result
    result=$(MIHOMO_JSON_FILE="$json_tmp" MIHOMO_OS="$os_name" MIHOMO_ARCH="$arch_name" python3 -c '
import json, os, sys
try:
    with open(os.environ.get("MIHOMO_JSON_FILE", ""), encoding="utf-8") as f:
        release = json.load(f)
except Exception:
    sys.exit(1)

tag = release.get("tag_name", "")
os_name = os.environ.get("MIHOMO_OS", "linux")
arch_name = os.environ.get("MIHOMO_ARCH", "amd64")

assets = [a for a in release.get("assets", [])
          if not a.get("name", "").endswith(".sig")
          and not a.get("name", "").endswith(".txt")]

prefix = f"mihomo-{os_name}-{arch_name}"

# 优先级: 基础版 > compatible > v3
basic = []
compatible = []
v3 = []

for a in assets:
    name = a["name"]
    # 只匹配 .gz 压缩包（install.sh 解压逻辑支持 .gz/.tar.gz，.deb/.rpm 等需排除）
    if not name.startswith(prefix) or not name.endswith(".gz"):
        continue
    lower = name.lower()
    if "compatible" in lower:
        compatible.append(a)
    elif "-v3" in lower or "-go" in lower:
        v3.append(a)
    else:
        basic.append(a)

match = None
if basic:
    match = basic[0]
elif compatible:
    match = compatible[0]
elif v3:
    match = v3[0]

if match is None:
    print("NO_MATCH\t\t")
else:
    print(tag + "\t" + match["name"] + "\t" + match["browser_download_url"])
' 2>/dev/null) || true
    rm -f "$json_tmp"

    if [ -n "$result" ] && [ "$result" != "NO_MATCH"$'\t'$'\t' ]; then
      printf "%s" "$result"
      return 0
    fi
  fi

  # 方案2: API 失败时，通过 redirect 获取版本号
  info "GitHub API 不可用，尝试通过 redirect 获取版本号..."
  local redirect_url tag=""
  local latest_url="https://github.com/${REPO}/releases/latest"

  # 通过选定通道尝试（镜像优先，直连兜底）
  # 注意: 不能用 -L（会跟随重定向导致 %{redirect_url} 为空），用 -sS 取 Location
  local probe_url="$latest_url"
  [ -n "$GITHUB_MIRROR" ] && probe_url="${GITHUB_MIRROR}/${latest_url}"
  redirect_url=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 15 $curl_proxy "$probe_url" 2>/dev/null) || true
  [ -n "$redirect_url" ] && tag="$(echo "$redirect_url" | grep -oE 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | sed 's|tag/||')"

  # 镜像 redirect 拿不到时，再直连尝试一次
  if [ -z "$tag" ] && [ -n "$GITHUB_MIRROR" ]; then
    redirect_url=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 15 $curl_proxy "$latest_url" 2>/dev/null) || true
    [ -n "$redirect_url" ] && tag="$(echo "$redirect_url" | grep -oE 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | sed 's|tag/||')"
  fi

  if [ -z "$tag" ]; then
    error "无法获取最新版本号"
    info "请手动指定版本号: sudo $0 --install --version v1.19.29"
    return 1
  fi

  ok "获取到版本号: ${tag}"

  # 构造下载 URL（使用基础版资产名）
  local asset_name="mihomo-${os_name}-${arch_name}-${tag}.gz"
  local base_url="https://github.com/${REPO}/releases/download/${tag}"
  echo -e "${tag}\t${asset_name}\t${base_url}/${asset_name}"
}

# ---------------------------------------------------------------------------
# 安装 mihomo
# ---------------------------------------------------------------------------
install_mihomo() {
  local tag="$1" asset_name="$2" download_url="$3"

  info "待安装版本: ${tag}（${asset_name}）"

  # 检查已安装版本
  local current_version=""
  if command -v "$BINARY_NAME" >/dev/null 2>&1; then
    current_version="$("$BINARY_NAME" -v 2>/dev/null | head -1 | awk '{print $2}' || true)"
  fi
  if [ -n "$current_version" ]; then
    info "当前已安装: ${current_version}"
    if [ "$current_version" = "$tag" ] && [ "$FORCE" -ne 1 ]; then
      warn "已是最新版本: ${tag}"
      ask_yes_no "是否重新安装？(y/N)" || return 0
    fi
  fi

  # 下载
  local pkg_path="${DOWNLOAD_DIR}/${asset_name}"
  download_file "$download_url" "$pkg_path" "mihomo 二进制"

  # 解压
  local bin_path="${INSTALL_DIR}/${BINARY_NAME}"
  mkdir -p "$INSTALL_DIR"

  info "解压到: $bin_path"
  case "$asset_name" in
    *.gz)
      # gzip 压缩的单个二进制
      gunzip -c "$pkg_path" > "$bin_path"
      ;;
    *.tar.gz|*.tgz)
      # tar.gz 压缩包
      local tmp_extract
      tmp_extract="$(mktemp -d)"
      tar -xzf "$pkg_path" -C "$tmp_extract"
      local extracted_bin
      extracted_bin="$(find "$tmp_extract" -name "$BINARY_NAME" -type f | head -1)"
      [ -z "$extracted_bin" ] && { error "压缩包中未找到 $BINARY_NAME"; rm -rf "$tmp_extract"; return 1; }
      cp -f "$extracted_bin" "$bin_path"
      rm -rf "$tmp_extract"
      ;;
    *)
      # 直接是二进制文件
      cp -f "$pkg_path" "$bin_path"
      ;;
  esac

  chmod +x "$bin_path"
  ok "已安装: $bin_path ($tag)"

  # 验证
  "$bin_path" -v 2>&1 | head -1 || true

  # 创建配置目录
  mkdir -p "$CONFIG_DIR"

  # 下载 GeoIP/GeoSite 数据库（mihomo 新版支持自动下载，这里仅做预置）
  download_geo_data

  # 生成默认配置（如果不存在）
  if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    generate_default_config
  fi

  # 创建服务
  if [ "$INSTALL_MODE" = "system" ]; then
    create_service
  fi

  # 导入订阅（如果指定）
  if [ -n "$SUB_CONFIG_URL" ]; then
    import_subscription "$SUB_CONFIG_URL"
  fi
}

# ---------------------------------------------------------------------------
# 下载 GeoIP/GeoSite 数据库（带超时，失败不阻塞安装流程）
# ---------------------------------------------------------------------------
download_geo_data() {
  # mihomo 官方推荐使用 meta-rules-dat 仓库的 metadb 格式
  # 也兼容 Loyalsoldier 的 geoip.dat/geosite.dat
  local geoip_metadb_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
  local country_mmdb_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
  local geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

  # 检查是否已存在（任一组合即可）
  local has_geoip=false has_geosite=false
  { [ -f "${CONFIG_DIR}/geoip.metadb" ] || [ -f "${CONFIG_DIR}/Country.mmdb" ] || [ -f "${CONFIG_DIR}/geoip.dat" ]; } && has_geoip=true
  [ -f "${CONFIG_DIR}/geosite.dat" ] && has_geosite=true

  if $has_geoip && $has_geosite; then
    info "GeoIP/GeoSite 数据库已存在，跳过下载"
    return 0
  fi

  info "下载 GeoIP/GeoSite 数据库（带 60s 超时，失败不阻塞）..."

  # 下载函数：带超时，失败返回非 0 但不退出
  # 参数: url, dest, desc
  _download_geo_file() {
    local url="$1" dest="$2" desc="$3"
    [ -f "$dest" ] && { info "${desc}已存在，跳过"; return 0; }

    local actual_url
    actual_url="$(build_url "$url")"

    local proxy_args=""
    [ -n "$PROXY_URL" ] && proxy_args="--proxy $PROXY_URL"

    info "下载 ${desc}..."
    # 使用 curl 带超时（aria2c 对小文件无优势且可能卡死）
    if curl -sSL --fail --connect-timeout 15 --max-time 60 $proxy_args -o "$dest" "$actual_url" 2>/dev/null && [ -s "$dest" ]; then
      ok "${desc}下载完成: $(du -h "$dest" | awk '{print $1}')"
      return 0
    fi

    # 失败时清理空文件
    rm -f "$dest" 2>/dev/null
    warn "${desc}下载失败（将跳过，mihomo 启动时会尝试自动下载）"
    return 1
  }

  # 下载 GeoIP（metadb 优先，失败回退 Country.mmdb，再回退 geoip.dat）
  if ! $has_geoip; then
    _download_geo_file "$geoip_metadb_url" "${CONFIG_DIR}/geoip.metadb" "geoip.metadb" \
      || _download_geo_file "$country_mmdb_url" "${CONFIG_DIR}/Country.mmdb" "Country.mmdb" \
      || _download_geo_file "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" "${CONFIG_DIR}/geoip.dat" "geoip.dat" \
      || true
  fi

  # 下载 GeoSite
  if ! $has_geosite; then
    _download_geo_file "$geosite_url" "${CONFIG_DIR}/geosite.dat" "geosite.dat" \
      || _download_geo_file "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" "${CONFIG_DIR}/geosite.dat" "geosite.dat" \
      || true
  fi
}

# ---------------------------------------------------------------------------
# 生成默认配置
# ---------------------------------------------------------------------------
generate_default_config() {
  info "生成默认配置: ${CONFIG_DIR}/config.yaml"

  local proxy_port="7890"
  local api_port="9090"

  cat > "${CONFIG_DIR}/config.yaml" << 'EOF'
# mihomo 默认配置
# 请通过 --config URL 导入你的订阅配置，或手动编辑此文件

# 混合代理端口（HTTP + SOCKS5）
mixed-port: 7890

# API 控制端口
external-controller: 127.0.0.1:9090

# 允许局域网连接
allow-lan: true
bind-address: '*'

# 运行模式: rule / global / direct
mode: rule

# 日志级别: silent / error / warning / info / debug
log-level: info

# GeoIP/GeoSite 自动更新
geo-auto-update: true
geo-update-interval: 24

# DNS 配置
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query

# 空代理组（请导入订阅或手动添加节点）
proxies: []

# 空规则
rules:
  - MATCH,DIRECT
EOF
  ok "默认配置已生成: ${CONFIG_DIR}/config.yaml"
}

# ---------------------------------------------------------------------------
# 创建系统服务
# ---------------------------------------------------------------------------
create_service() {
  [ -z "$SERVICE_FILE" ] && return 0

  info "创建服务: $SERVICE_FILE"

  if [ "$(uname -s)" = "Darwin" ]; then
    # macOS LaunchAgent
    cat > "$SERVICE_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.mihomo</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/${BINARY_NAME}</string>
    <string>-d</string>
    <string>${CONFIG_DIR}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${CONFIG_DIR}/mihomo.log</string>
  <key>StandardErrorPath</key>
  <string>${CONFIG_DIR}/mihomo.log</string>
</dict>
</plist>
EOF
    ok "LaunchAgent 已创建: $SERVICE_FILE"
    info "加载服务: launchctl load $SERVICE_FILE"
    launchctl unload "$SERVICE_FILE" 2>/dev/null || true
    launchctl load "$SERVICE_FILE" 2>/dev/null || true
  else
    # Linux systemd
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -d ${CONFIG_DIR}
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
    ok "systemd 服务已创建: $SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable mihomo 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# 导入订阅配置
# ---------------------------------------------------------------------------
# 修补配置以适配服务器场景
# - 补充 external-controller（如缺失）
# - 关闭 TUN（服务器不需要透明代理，且易出 UDP 权限错误）
# - 修正 dns-hijack 格式（纯 IP → IP:53）
# - 确保 allow-lan: true
patch_config_for_server() {
  local cfg="${CONFIG_DIR}/config.yaml"
  [ -f "$cfg" ] || return 0

  local changed=0

  # 1) 补充 external-controller（如缺失）
  if ! grep -qE '^[[:space:]]*external-controller:' "$cfg"; then
    info "补充 external-controller: 0.0.0.0:9090"
    # 在 mixed-port 行后插入
    if grep -qE '^[[:space:]]*mixed-port:' "$cfg"; then
      sed -i.bak '/^[[:space:]]*mixed-port:/a\
external-controller: 0.0.0.0:9090\
secret: ""' "$cfg" && rm -f "$cfg.bak"
      changed=1
    fi
  fi

  # 2) 关闭 TUN（tun.enable: true → false）
  if grep -qE '^[[:space:]]*tun:' "$cfg"; then
    # 检查 tun 下是否有 enable: true
    if awk '/^[[:space:]]*tun:/{f=1} f&&/^[[:space:]]*enable:[[:space:]]*true/{print;exit}' "$cfg" | grep -q .; then
      info "关闭 TUN 模式（服务器场景不需要，避免 UDP 权限错误）"
      # 只替换 tun 块下的第一个 enable: true
      awk '
        /^[[:space:]]*tun:/{tun=1}
        tun && /^[[:space:]]*enable:[[:space:]]*true/ {sub(/true/, "false"); tun=0}
        {print}
      ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
      changed=1
    fi
  fi

  # 3) 修正 dns-hijack 中的纯 IP（添加 :53 端口）
  #    匹配 "  - 1.2.3.4" 或 "  - 1.2.3.4" 这种不带端口的
  if grep -qE '^[[:space:]]*-[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$cfg"; then
    info "修正 dns-hijack 格式（补充 :53 端口）"
    sed -i.bak -E 's/^([[:space:]]*-[[:space:]]*)([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$/\1\2:53/' "$cfg" && rm -f "$cfg.bak"
    changed=1
  fi

  # 4) 确保 allow-lan: true
  if grep -qE '^[[:space:]]*allow-lan:[[:space:]]*false' "$cfg"; then
    info "开启 allow-lan（服务器场景需要局域网访问）"
    sed -i.bak -E 's/^([[:space:]]*allow-lan:[[:space:]]*)false/\1true/' "$cfg" && rm -f "$cfg.bak"
    changed=1
  fi

  # 5) geodata-mode: true → false（mihomo 服务端默认用 geoip.metadb；
  #    ClashX Meta 的 geodata-mode: true 需要 geoip.dat（v2ray-rules-dat 格式），
  #    而 metadb 含 private 等完整分类，可避免 "country code private not found" 启动失败）
  if grep -qE '^[[:space:]]*geodata-mode:[[:space:]]*true' "$cfg"; then
    info "geodata-mode 切换为 false（改用 geoip.metadb，避免缺 geoip.dat 导致启动失败）"
    sed -i.bak -E 's/^([[:space:]]*geodata-mode:[[:space:]]*)true/\1false/' "$cfg" && rm -f "$cfg.bak"
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    ok "配置已适配服务器场景"
  fi
}

import_subscription() {
  local sub_url="$1"
  info "导入订阅配置: $sub_url"

  local curl_proxy=""
  [ -n "$PROXY_URL" ] && curl_proxy="--proxy $PROXY_URL"

  # 备份现有配置
  if [ -f "${CONFIG_DIR}/config.yaml" ]; then
    local backup="${CONFIG_DIR}/config.yaml.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${CONFIG_DIR}/config.yaml" "$backup"
    info "已备份现有配置到: $backup"
  fi

  # 下载订阅
  curl -sSL --fail --connect-timeout 30 $curl_proxy -o "${CONFIG_DIR}/config.yaml" "$sub_url" || {
    error "订阅配置下载失败"
    return 1
  }

  [ -s "${CONFIG_DIR}/config.yaml" ] || { error "订阅配置为空"; return 1; }
  ok "订阅配置已导入: ${CONFIG_DIR}/config.yaml"

  # 服务器场景配置适配（修补 ClashX Meta 等客户端配置的不兼容项）
  patch_config_for_server

  # 重启服务
  if [ "$INSTALL_MODE" = "system" ] && [ -n "$SERVICE_FILE" ]; then
    if [ "$(uname -s)" != "Darwin" ]; then
      info "重启 mihomo 服务..."
      systemctl restart mihomo 2>/dev/null || warn "服务重启失败，请手动: sudo systemctl restart mihomo"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 从 ClashX Meta（macOS 客户端）导入配置
#   源格式: 本地路径 /path/to/config.yaml  或  scp 格式 user@host:/path/to/config.yaml
# ---------------------------------------------------------------------------
import_clashx_config() {
  local src="$1"
  local tmp=""

  if [ -z "$src" ]; then
    info "从 ClashX Meta 导入配置（支持两种源）:"
    echo "  1. 本地文件: /path/to/config.yaml"
    echo "  2. 远程 scp: user@mac-ip:/path/to/config.yaml"
    printf "请输入配置源: "
    read -r src || { error "未输入配置源"; return 1; }
    [ -n "$src" ] || { error "未输入配置源"; return 1; }
  fi

  # 备份现有配置
  if [ -f "${CONFIG_DIR}/config.yaml" ]; then
    local backup="${CONFIG_DIR}/config.yaml.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${CONFIG_DIR}/config.yaml" "$backup"
    info "已备份现有配置到: $backup"
  fi

  # 远程 scp 源拉取
  if [[ "$src" == *":"* ]] && [[ "$src" != /* ]]; then
    tmp="$(mktemp /tmp/clashx-config.XXXXXX.yaml)" || tmp="/tmp/clashx-config.yaml"
    info "从远程拉取: $src"
    if ! scp -q "$src" "$tmp" 2>/dev/null; then
      error "scp 拉取失败: $src"
      return 1
    fi
    src="$tmp"
  fi

  [ -f "$src" ] || { error "配置源不存在: $src"; return 1; }
  cp "$src" "${CONFIG_DIR}/config.yaml"
  ok "配置已导入: ${CONFIG_DIR}/config.yaml ($(wc -l < "${CONFIG_DIR}/config.yaml") 行)"
  [ -n "$tmp" ] && rm -f "$tmp"

  # 服务器场景适配（external-controller/allow-lan/TUN/dns-hijack/geodata-mode）
  patch_config_for_server

  # 校验配置
  info "校验配置..."
  if mihomo -t -d "$CONFIG_DIR" -f "${CONFIG_DIR}/config.yaml" 2>&1 | tail -1 | grep -qi "successful"; then
    ok "配置校验通过"
  else
    error "配置校验失败，请检查上面的错误信息"
    info "可回滚: sudo cp ${CONFIG_DIR}/config.yaml.backup.* ${CONFIG_DIR}/config.yaml"
    return 1
  fi

  # 重启服务
  if [ "$INSTALL_MODE" = "system" ] && [ "$(uname -s)" != "Darwin" ]; then
    info "重启 mihomo 服务..."
    systemctl restart mihomo 2>/dev/null || {
      warn "服务重启失败，请手动: sudo systemctl restart mihomo"
      return 1
    }
    sleep 3
  fi

  # 代理出站自测
  info "代理出站自测 (经 127.0.0.1:7890)..."
  local code
  code=$(curl -x http://127.0.0.1:7890 -s -o /dev/null -w "%{http_code}" --connect-timeout 8 -m 12 https://www.google.com 2>/dev/null || true)
  case "$code" in
    200|301|302)
      ok "出站测试通过 (google → $code)"
      ;;
    *)
      warn "出站测试未通过 (google → ${code:-FAIL})，请检查节点状态: sudo ./service.sh nodes"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 安装/更新 metacubexd Web 面板（external-ui）
# ---------------------------------------------------------------------------
UI_REPO="MetaCubeX/metacubexd"
UI_ZIP_URL="https://github.com/${UI_REPO}/archive/refs/heads/gh-pages.zip"

install_ui() {
  info "安装/更新 metacubexd Web 面板..."
  local tmp_zip="/tmp/metacubexd.zip"
  local tmp_dir="/tmp/metacubexd-ui"
  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"

  # 下载通道：优先指定代理 → 记忆代理 → 直连
  local proxy_opt=""
  if [ -n "$PROXY_URL" ]; then
    proxy_opt="-x $PROXY_URL"
  elif [ -f "${CONFIG_DIR}/.proxy.conf" ]; then
    local memo
    memo="$(cat "${CONFIG_DIR}/.proxy.conf" 2>/dev/null || true)"
    [ -n "$memo" ] && proxy_opt="-x $memo"
  fi

  info "下载面板: $UI_ZIP_URL${proxy_opt:+ (经代理)}"
  if ! curl $proxy_opt -sSL --fail --connect-timeout 30 -o "$tmp_zip" "$UI_ZIP_URL"; then
    error "面板下载失败"
    info "可手动下载 ${UI_ZIP_URL} 放到 ${tmp_zip} 后重试"
    return 1
  fi
  ok "面板下载完成 ($(du -h "$tmp_zip" | cut -f1))"

  mkdir -p "$tmp_dir"
  unzip -q "$tmp_zip" -d "$tmp_dir" || { error "解压失败"; return 1; }

  # 定位面板根目录（含 index.html 的最上层目录）
  local src_dir
  src_dir="$(find "$tmp_dir" -maxdepth 3 -name index.html -exec dirname {} \; 2>/dev/null | head -1)"
  [ -z "$src_dir" ] && { error "未找到面板文件"; return 1; }

  mkdir -p "${CONFIG_DIR}/ui"
  cp -r "$src_dir"/. "${CONFIG_DIR}/ui/"
  ok "面板已安装到: ${CONFIG_DIR}/ui/"

  # 配置写入 external-ui
  local cfg="${CONFIG_DIR}/config.yaml"
  if ! grep -qE '^[[:space:]]*external-ui:' "$cfg"; then
    if grep -qE '^[[:space:]]*external-controller:' "$cfg"; then
      sed -i.bak '/^[[:space:]]*external-controller:/a\
external-ui: ./ui' "$cfg" && rm -f "$cfg.bak"
    else
      printf '\nexternal-ui: ./ui\n' >> "$cfg"
    fi
    info "已写入 external-ui: ./ui"
  fi

  # 重启服务
  if [ "$INSTALL_MODE" = "system" ] && [ "$(uname -s)" != "Darwin" ]; then
    info "重启 mihomo 服务..."
    systemctl restart mihomo 2>/dev/null || {
      warn "服务重启失败，请手动: sudo systemctl restart mihomo"
      return 1
    }
    sleep 3
  fi

  # 验证
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:9090/ui/" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    ok "面板访问正常: http://127.0.0.1:9090/ui/"
  else
    warn "面板状态: ${code:-未知}（浏览器访问 http://127.0.0.1:9090/ui 确认）"
  fi

  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
uninstall_mihomo() {
  info "开始卸载 mihomo..."

  # 停止服务
  if [ "$INSTALL_MODE" = "system" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
      [ -f "$SERVICE_FILE" ] && launchctl unload "$SERVICE_FILE" 2>/dev/null || true
    else
      systemctl stop mihomo 2>/dev/null || true
      systemctl disable mihomo 2>/dev/null || true
    fi
  fi

  # 删除二进制
  local bin_path="${INSTALL_DIR}/${BINARY_NAME}"
  if [ -f "$bin_path" ]; then
    rm -f "$bin_path"
    ok "已删除: $bin_path"
  else
    warn "二进制不存在: $bin_path"
  fi

  # 删除服务文件
  if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    ok "已删除服务: $SERVICE_FILE"
    [ "$(uname -s)" != "Darwin" ] && systemctl daemon-reload 2>/dev/null || true
  fi

  # 询问是否删除配置
  if [ -d "$CONFIG_DIR" ]; then
    if ask_yes_no "是否删除配置目录 ${CONFIG_DIR}？（包含订阅和规则）(y/N)"; then
      rm -rf "$CONFIG_DIR"
      ok "已删除配置目录: $CONFIG_DIR"
    else
      info "保留配置目录: $CONFIG_DIR"
    fi
  fi

  ok "卸载完成"
}

# ---------------------------------------------------------------------------
# 显示安装结果
# ---------------------------------------------------------------------------
show_summary() {
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  mihomo 安装完成${NC}"
  echo -e "  二进制: ${INSTALL_DIR}/${BINARY_NAME}"
  echo -e "  配置目录: ${CONFIG_DIR}"
  if [ "$INSTALL_MODE" = "system" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
      echo -e "  服务: ${SERVICE_FILE}"
    else
      echo -e "  服务: systemctl start/stop/status mihomo"
    fi
  else
    echo -e "  启动: ${INSTALL_DIR}/${BINARY_NAME} -d ${CONFIG_DIR}"
  fi
  echo -e "  代理端口: 7890 (HTTP+SOCKS5)"
  echo -e "  API: http://127.0.0.1:9090"
  echo -e "${GREEN}============================================================${NC}"

  if [ -z "$SUB_CONFIG_URL" ] && [ ! -f "${CONFIG_DIR}/config.yaml.bak" ]; then
    echo ""
    warn "尚未导入订阅配置，请使用以下命令导入:"
    echo "  sudo $0 --config \"https://your-subscription-url/config.yaml\""
  fi

  echo ""
  info "使用代理（在 .bashrc 中添加）:"
  echo "  export http_proxy=http://127.0.0.1:7890"
  echo "  export https_proxy=http://127.0.0.1:7890"
  echo "  export all_proxy=socks5://127.0.0.1:7890"
  echo "  export no_proxy=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,::1"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  init_paths
  detect_platform
  check_root

  # 如果没有指定动作，交互式询问
  if [ -z "$ACTION" ]; then
    echo ""
    echo -e "${CYAN}请选择操作:${NC}"
    echo "  1) 安装 mihomo"
    echo "  2) 更新 mihomo"
    echo "  3) 卸载 mihomo"
    echo "  4) 仅导入订阅配置"
    echo "  5) 从 ClashX Meta 导入配置"
    echo "  6) 安装/更新 Web 面板"
    echo "  7) 取消"
    printf "输入 [1-7]: "
    read -r reply || reply="7"
    case "$reply" in
      1) ACTION="install" ;;
      2) ACTION="update" ;;
      3) ACTION="uninstall" ;;
      4) ACTION="config_only" ;;
      5) ACTION="clashx_import" ;;
      6) ACTION="install_ui" ;;
      *) exit 0 ;;
    esac
    echo ""
  fi

  case "$ACTION" in
    install|update)
      # 自动检测网络通道（直连/镜像/代理），失败时交互提示输入代理
      detect_channel || {
        error "无法访问 GitHub（直连/镜像/代理均不可用）"
        info "手动方案:"
        echo "  1. sudo $0 --install --version v1.19.32 --mirror https://可用镜像"
        echo "  2. sudo $0 --install --proxy http://代理IP:端口"
        echo "  3. 在能访问 GitHub 的机器下载 mihomo-linux-amd64-v1.19.32.gz 后手动安装"
        exit 1
      }
      # 查询最新版本
      info "查询 GitHub 最新版本..."
      local result
      result=$(query_release) || {
        error "查询 GitHub releases 失败（网络问题）"
        echo ""
        info "可选方案:"
        echo "  1. 使用镜像加速: sudo $0 --install --mirror https://ghproxy.net"
        echo "  2. 使用代理下载: sudo $0 --install --proxy http://YOUR_PROXY:PORT"
        echo "  3. 手动下载: https://github.com/${REPO}/releases"
        exit 1
      }

      local tag asset_name download_url
      tag=$(printf "%s" "$result" | cut -f1)
      asset_name=$(printf "%s" "$result" | cut -f2)
      download_url=$(printf "%s" "$result" | cut -f3)

      if [ "$tag" = "NO_MATCH" ] || [ -z "$download_url" ]; then
        error "未能匹配到兼容的包（${OS}/${ARCH}）"
        info "请手动访问 https://github.com/${REPO}/releases 下载"
        exit 1
      fi

      ok "最新版本: ${tag} / ${asset_name}"

      if [ "$ACTION" = "update" ]; then
        info "更新模式: 先停止服务再安装..."
        if [ "$INSTALL_MODE" = "system" ] && [ "$(uname -s)" != "Darwin" ]; then
          systemctl stop mihomo 2>/dev/null || true
        fi
      fi

      install_mihomo "$tag" "$asset_name" "$download_url"
      # 安装完成后自动安装 Web 面板（失败不阻塞安装）
      install_ui || warn "Web 面板安装失败（可稍后: sudo $0 --ui 重试）"
      save_proxy_memo
      show_summary
      ;;

    uninstall)
      uninstall_mihomo
      ;;

    config_only)
      if [ -z "$SUB_CONFIG_URL" ]; then
        error "请指定订阅链接: sudo $0 --config URL"
        exit 1
      fi
      import_subscription "$SUB_CONFIG_URL"
      ;;

    clashx_import)
      import_clashx_config "$CLASHX_SOURCE"
      ;;

    install_ui)
      install_ui
      ;;

    *)
      error "未知动作: $ACTION"
      exit 2
      ;;
  esac
}

main "$@"

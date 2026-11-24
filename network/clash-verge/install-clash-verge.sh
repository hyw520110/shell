#!/usr/bin/env bash
# =============================================================================
# install-clash-verge.sh
# 一键安装 / 更新 / 卸载 Clash Verge Rev（跨平台：macOS + Linux）
# -----------------------------------------------------------------------------
# - 自动检测平台/架构并选择正确包（macOS DMG / Linux .deb / .rpm）
# - 下载优先使用 aria2c（aria2 已安装时多线程加速），否则回退到 curl
# - 默认下载目录：${HOME}/Downloads（可通过 --download-dir 覆盖）
# - 默认安装目录：macOS /Applications；Linux 系统级，无需指定
# - 已安装时，交互式询问：更新 / 卸载 / 取消
# -----------------------------------------------------------------------------
# 用法:
#   ./install-clash-verge.sh                # 交互式（推荐首次使用）
#   ./install-clash-verge.sh --install      # 明确安装
#   ./install-clash-verge.sh --update       # 强制更新到最新版
#   ./install-clash-verge.sh --uninstall    # 卸载
#   ./install-clash-verge.sh --download-dir /tmp/pkgs
#   ./install-clash-verge.sh --download-dir ~/Downloads --install-dir /Applications
#   ./install-clash-verge.sh --no-aria2     # 禁用 aria2，强制用 curl
#   ./install-clash-verge.sh --force        # 跳过所有交互式确认
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERR ]${NC}  $1" >&2; }
banner()  {
  echo -e "${BLUE}===========================================================${NC}"
  echo -e "${BLUE}         🚀  Clash Verge Rev 一键安装 / 更新 / 卸载${NC}"
  echo -e "${BLUE}===========================================================${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./install-clash-verge.sh [OPTIONS] [ACTION]

ACTION（缺省时交互式询问）:
  --install      安装 Clash Verge Rev（如已安装会提示先卸载/更新）
  --update       强制更新到最新版（先卸载旧版本）
  --uninstall    卸载当前安装的 Clash Verge Rev
  --check        只做本机体检（macOS 兼容性 + 内核版本/anytls 支持），不下载不安装

OPTIONS:
  --download-dir <DIR>  指定下载缓存目录（默认: ~/Downloads）
  --install-dir  <DIR>  macOS 指定安装目录（默认: /Applications；Linux 忽略）
  --no-aria2            强制用 curl 下载（不检测 aria2）
  --use-aria2           强制用 aria2c（若不可用会报错退出）
  --force               跳过所有交互（自动 yes）
  --no-color            禁用彩色输出
  --help, -h            显示本帮助

示例:
  ./install-clash-verge.sh                             # 首次使用，完全交互式
  ./install-clash-verge.sh --install                   # 直接安装
  ./install-clash-verge.sh --update --download-dir ~/Temp
  ./install-clash-verge.sh --uninstall --force
  ./install-clash-verge.sh --install --no-aria2
EOF
}

# 默认值
ACTION=""
DOWNLOAD_DIR="${HOME}/Downloads"
INSTALL_DIR=""       # 空 = macOS /Applications；Linux 由包管理器决定
FORCE_ARIA2=0
NO_ARIA2=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install)     ACTION="install" ;;
    --update)      ACTION="update" ;;
    --uninstall)   ACTION="uninstall" ;;
    --check)       ACTION="check" ;;
    --download-dir) shift; DOWNLOAD_DIR="$1" ;;
    --install-dir)  shift; INSTALL_DIR="$1" ;;
    --no-aria2)    NO_ARIA2=1 ;;
    --use-aria2)   FORCE_ARIA2=1 ;;
    --force)       FORCE=1 ;;
    --no-color)    NC='' ; RED='' ; GREEN='' ; YELLOW='' ; BLUE='' ; CYAN='' ; BOLD='' ;;
    --help|-h)     usage; exit 0 ;;
    *)
      error "未知参数: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
need_sudo() {
  # macOS 安装到 /Applications 通常不需要 sudo（用户可写）
  # Linux 安装包一定需要 root
  if [ "$(uname)" = "Darwin" ]; then
    # macOS 只有在卸载（可能修改 /Applications）时才提示输入密码，实际由 Finder 处理
    return 1
  fi
  return 0
}

# 交互式确认（--force 模式自动 yes）
ask_yes_no() {
  [ "$FORCE" -eq 1 ] && return 0
  local prompt="${1:-继续? (y/N)}"
  local reply
  printf "%s " "$prompt"
  read -r reply || reply="n"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# 通过 GitHub releases API 查询最新版本；返回三列：tag \t pkg_name \t download_url
# 实现方式：curl 拉取 JSON（能走 HTTP_PROXY/HTTPS_PROXY），python3 解析 JSON（可靠）
query_release() {
  local api="https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest"
  local json
  json=$(curl -sSL --max-time 20 "$api" 2>/dev/null) || {
    echo "API_ERROR" >&2
    return 1
  }
  [ -z "$json" ] && { echo "API_EMPTY" >&2; return 1; }

  # 注意：不能用 `printf "$json" | python3 - <<'PY'`，heredoc 会抢占 python 的 stdin，
  # 导致 sys.stdin.read() 读空串、json.loads 报 "Expecting value: line 1 column 1"。
  # JSON 改由环境变量传入，heredoc 仅作为脚本载体。
  ZCV_JSON="$json" python3 - <<'PY'
import json, os, subprocess, sys
try:
    release = json.loads(os.environ["ZCV_JSON"])
except Exception as e:
    print(f"JSON_ERROR {e}", file=sys.stderr); sys.exit(1)

tag = release.get("tag_name","")
try:
    machine = subprocess.check_output(["uname","-m"]).decode().strip().lower()
    plat    = subprocess.check_output(["uname"]).decode().strip().lower()
except Exception:
    machine, plat = "x86_64","linux"

candidates = [a for a in release.get("assets", [])
              if not a.get("name","").endswith(".sig")]

def matcher(n):
    n = n.lower()
    if plat == "darwin":
        if machine in ("arm64","aarch64"):
            return n.endswith("_aarch64.dmg")
        return n.endswith("_x64.dmg")
    if machine in ("arm64","aarch64"):
        return n.endswith("_arm64.deb") or ("aarch64" in n and n.endswith(".rpm"))
    if machine == "armv7l":
        return n.endswith("_armhf.deb")
    return n.endswith("_amd64.deb") or ("x86_64" in n and n.endswith(".rpm"))

match = None
for a in candidates:
    if matcher(a["name"]):
        match = a; break

# Linux 无 .deb 时回退到 .rpm
if (not match) and plat != "darwin":
    for a in candidates:
        n=a["name"].lower()
        if n.endswith(".rpm"):
            if machine in ("arm64","aarch64") and "aarch" in n:
                match=a; break
            if machine in ("x86_64","amd64") and ("x86_64" in n or "amd64" in n):
                match=a; break

if match is None:
    print("NO_MATCH\t\t")
else:
    print(tag + "\t" + match["name"] + "\t" + match["browser_download_url"])
PY
}

# 下载文件
# $1: URL   $2: 目标文件路径
# ---------------------------------------------------------------------------
# 下载产物格式校验
# adl 已内置魔数+SHA256 校验 (失败返回非零), 所以 adl 成功路径无需重复校验;
# 但 curl / aria2 回退路径没有 adl 的校验, 必须自己验 (本次事故: adl 从坏镜像
# 拿回 374B HTML 错误页仍返回 0, 无校验就会继续装坏包)。
# 支持: DMG (kPFK 6b50464b / PKZip 504b0304), deb (!<arch>), rpm (ed ab ee db)
# ---------------------------------------------------------------------------
validate_archive() {
  local file="$1"
  local magic

  [ -s "$file" ] || { warn "产物为空: $file"; return 1; }

  magic=$(head -c 4 "$file" | xxd -p 2>/dev/null)
  case "$magic" in
    6b50464b) ok "格式校验通过: DMG (kPFK)"; return 0 ;;   # DMG
    504b0304) ok "格式校验通过: ZIP/PKZip"; return 0 ;;    # zip 容器 (含 dmg)
    213c6172) ok "格式校验通过: deb (!<arch>)"; return 0 ;; # Debian 包
    edabeedb) ok "格式校验通过: rpm"; return 0 ;;          # RPM
    *)
      warn "格式校验失败: 魔数 ${magic:-未知} (可能是 HTML 错误页或坏包)"
      return 1
      ;;
  esac
}

download_file() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"

  # 检测 aria2c 可用性
  # 优先级: adl（aria2c 超集：多线程 + 断点续传 + 代理测速 + 大小校验）> aria2c > curl
  local use_adl=0
  if command -v adl >/dev/null 2>&1; then use_adl=1; fi

  local use_aria2=0
  if [ "$FORCE_ARIA2" -eq 1 ]; then
    if [ "$use_adl" -eq 1 ]; then use_aria2=0
    elif command -v aria2c >/dev/null 2>&1; then use_aria2=1
    else error "--use-aria2 指定但未找到 aria2c 或 adl，请先安装: brew install aria2（mac）或 apt install aria2（Linux）"; return 1; fi
  elif [ "$NO_ARIA2" -eq 1 ]; then
    use_aria2=0; use_adl=0
  else
    # 自动检测：有 aria2c 就用它（多线程 + 断点续传更快）
    if [ "$use_adl" -eq 0 ] && command -v aria2c >/dev/null 2>&1; then use_aria2=1; fi
  fi

  info "开始下载: $(basename "$dest")"

  if [ "$use_adl" -eq 1 ]; then
    info "使用 adl 下载（多线程 + 断点续传 + 代理测速）"
    # adl 已内置魔数+SHA256 校验; 只需确认产物非空
    # (adl 对空文件是跳过校验的)
    if adl "$url" "$(dirname "$dest")" "$(basename "$dest")" && [ -s "$dest" ]; then
      ok "adl 下载完成并校验通过"
      return 0
    fi
    warn "adl 下载失败或产物异常，回退到 curl ..."
    rm -f "$dest"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" || return 1
    validate_archive "$dest" || return 1
  elif [ "$use_aria2" -eq 1 ]; then
    info "使用 aria2c 多线程下载（5 连接）"
    aria2c \
      --max-connection-per-server=5 \
      --continue=true \
      --split=5 \
      --allow-overwrite=true \
      --check-certificate=true \
      --file-allocation=none \
      --out="$(basename "$dest")" \
      --dir="$(dirname "$dest")" \
      "$url" || {
        warn "aria2c 下载失败，回退到 curl ..."
        rm -f "$dest"
        curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" || return 1
      }
    validate_archive "$dest" || return 1
  else
    info "使用 curl 下载（安装 aria2 可提速: brew install aria2）"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" || return 1
    validate_archive "$dest" || return 1
  fi

  [ -s "$dest" ] || { error "下载文件为空: $dest"; return 1; }
  ok "下载完成: $dest ($(du -h "$dest" | awk '{print $1}'))"
}

# ---------------------------------------------------------------------------
# 平台检测
# ---------------------------------------------------------------------------
detect_platform() {
  OS=""
  ARCH=""
  case "$(uname -s)" in
    Darwin) OS="macOS" ;;
    Linux)  OS="Linux" ;;
    *)
      error "不支持的系统: $(uname -s)（本脚本仅支持 macOS / Linux）"
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    armv7l)         ARCH="armhf" ;;
    x86_64|amd64)   ARCH="x86_64" ;;
    *)
      error "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

# 已安装版本（仅用于用户信息提示）
detect_installed_version() {
  INSTALLED_VERSION=""
  if [ "$OS" = "macOS" ]; then
    local plist="/Applications/Clash Verge.app/Contents/Info.plist"
    if [ -f "$plist" ]; then
      INSTALLED_VERSION=$(defaults read "$(dirname "$plist")/Info" CFBundleShortVersionString 2>/dev/null || true)
    fi
  elif [ "$OS" = "Linux" ]; then
    if command -v dpkg >/dev/null 2>&1; then
      INSTALLED_VERSION=$(dpkg -l 2>/dev/null | awk '{print $2" "$3}' | grep -i "clash.*verge" | awk '{print $2}' | head -1 || true)
    fi
    if [ -z "$INSTALLED_VERSION" ] && command -v rpm >/dev/null 2>&1; then
      INSTALLED_VERSION=$(rpm -q clash-verge 2>/dev/null | grep -v "not installed" || true)
    fi
  fi
}

# ---------------------------------------------------------------------------
# macOS 兼容性预检 + 内置 Mihomo 内核体检
# 本次事故教训: ClashX Meta 从 v1.4.46 起 LSMinimumSystemVersion 升到 13.0,
# macOS 12 上装完 open 直接报 "Unable to find application named ..."。
# 必须安装前读新包 Info.plist 的 LSMinimumSystemVersion 并对比本机系统。
# ---------------------------------------------------------------------------
macos_major() {
  sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 99
}
macos_full() {
  sw_vers -productVersion 2>/dev/null || echo "0.0.0"
}

# 比较两个点分版本号, 返回 0 表示 $1 >= $2; $1/$2 形如 "13.0"/"12.7.6"
compare_macos_version_ge() {
  local left="$1" right="$2"
  [ -z "$left" ] || [ -z "$right" ] && return 0
  awk -v l="$left" -v r="$right" 'BEGIN {
    n1 = split(l, a, "."); n2 = split(r, b, ".");
    for (i = 1; i <= 3; i++) {
      x = (i <= n1 && a[i] != "") ? a[i] + 0 : 0;
      y = (i <= n2 && b[i] != "") ? b[i] + 0 : 0;
      if (x > y) { exit 0 }
      if (x < y) { exit 1 }
    }
    exit 0
  }'
}

# 读取给定 .app 的 Info.plist 里 LSMinimumSystemVersion; 空 = 未声明
app_min_system() {
  local app="$1"
  local plist="${app}/Contents/Info.plist"
  [ -f "$plist" ] || return 1
  /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo ""
}

# 安装前校验: 新包要求的最低 macOS 是否被本机满足; 不满足返回 1
check_app_macos_compat() {
  local app="$1"
  local plist="${app}/Contents/Info.plist"
  local min_sys cur

  if [ ! -f "$plist" ]; then
    warn "未找到 Info.plist, 跳过系统兼容性检查"
    return 0
  fi

  min_sys=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo "")
  if [ -z "$min_sys" ]; then
    info "该版本未声明 LSMinimumSystemVersion, 跳过检查"
    return 0
  fi

  cur=$(macos_full)
  if ! compare_macos_version_ge "$cur" "$min_sys"; then
    error "系统不兼容: App 要求 macOS ${min_sys}+, 本机为 macOS ${cur}"
    error "这个版本装上也无法启动 (open 会报 Unable to find application)"
    error "请改用支持本系统的版本, 或升级 macOS"
    return 1
  fi

  info "系统兼容性检查通过: 要求 macOS ${min_sys}+, 本机 ${cur}"
  return 0
}

# 从二进制里提取 Mihomo 内核版本 (静态分析, 绝不用裸抓 v1.x.y)
# 实测: ClashX 的 helper 二进制以 root 拉起, 无 TTY 下会挂住终端;
# go version -m 拿不到 (devel), 裸抓 v1.x.y 会误抓依赖库版本 (protobuf v1.34.2 96次)。
# 完整内核二进制里只有格式串 "Mihomo Meta %s %s %s", 版本号运行时才填入,
# 所以静态只能确认"这是 mihomo"; 可靠版本需运行 "$bin -v"。
# Clash Verge 的内核 (verge-mihomo) 是完整二进制, -v 立即返回 (实测 0.29s),
# 但仍用超时保护防意外 (bash 无 timeout, 用后台+kill 实现)。
extract_mihomo_version() {
  local binary="$1" v="" out="" pid=""
  [ -f "$binary" ] || return 1

  # 1) 静态: 确认是 mihomo 并尝试提取格式串里的版本 (多为空)
  v=$(strings -a "$binary" 2>/dev/null | grep -oE 'Mihomo[ ]?[Mm]eta v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi

  # 2) 运行 -v (超时保护: 后台跑, 5s 后 kill; 完整内核立即返回)
  out=""
  "$binary" -v >/tmp/verge_v.out 2>&1 &
  pid=$!
  ( sleep 5; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  out=$(cat /tmp/verge_v.out 2>/dev/null)
  rm -f /tmp/verge_v.out
  v=$(printf '%s' "$out" | grep -oE '[Mm]ihomo( [Mm]eta)? v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi

  return 1
}

# 版本解析为 "M m p 0"; 供 core_version_ge 比较
parse_mihomo_version() {
  local raw="$1" num
  num=$(printf '%s\n' "$raw" | grep -oE '[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
  if [ -z "$num" ]; then echo "0 0 0 0"; return 1; fi
  num="${num#v}"; num="${num#V}"
  awk -v v="$num" 'BEGIN {
    n = split(v, p, ".");
    for (i = 1; i <= 4; i++) {
      val = (i <= n && p[i] != "") ? p[i] : 0;
      printf "%s ", val + 0;
    }
    printf "\n";
  }'
}

# 内核版本 >= 目标版本? $1="M m p 0" $2="1.19.3"
mihomo_version_ge() {
  local nums="$1" target maj1 min1 pat1 maj2 min2 pat2
  local IFS_SAVE="$IFS"
  target=$(parse_mihomo_version "$2")
  # 脚本头部设了 IFS=$'\n\t' (不含空格), read 会按 IFS 拆字段;
  # 临时设 IFS=' ' 确保按空格拆分 "1 19 33 0"。
  IFS=' '
  read -r maj1 min1 pat1 _ <<< "$nums"
  read -r maj2 min2 pat2 _ <<< "$target"
  IFS="$IFS_SAVE"
  maj1=${maj1:-0}; min1=${min1:-0}; pat1=${pat1:-0}
  maj2=${maj2:-0}; min2=${min2:-0}; pat2=${pat2:-0}
  if [ "$maj1" -lt "$maj2" ]; then return 1; fi
  if [ "$maj1" -gt "$maj2" ]; then return 0; fi
  if [ "$min1" -lt "$min2" ]; then return 1; fi
  if [ "$min1" -gt "$min2" ]; then return 0; fi
  [ "$pat1" -ge "$pat2" ]
}

# 安装后体检: 从已安装的 .app 里找内置 Mihomo 内核并报告版本与 anytls 支持
# Clash Verge Rev 把内核放在 Contents/MacOS/ (verge-mihomo, verge-mihomo-alpha)
# 而不是 Resources; 两个位置都搜。
report_mihomo_core() {
  local app="$1"
  local base_macos="${app}/Contents/MacOS"
  local base_res="${app}/Contents/Resources"
  local bin=""
  local found=""
  local ver=""

  # Clash Verge Rev 内核通常叫 verge-mihomo / verge-mihomo-alpha
  # ClashX 类叫 clash-meta / clash / mihomo
  for name in "verge-mihomo" "verge-mihomo-alpha" "clash-meta" "clash" "mihomo"; do
    for base in "$base_macos" "$base_res"; do
      local c="${base}/${name}"
      if [ -x "$c" ] || [ -f "$c" ]; then
        bin="$c"
        if found=$(extract_mihomo_version "$bin" 2>/dev/null); then
          ver="$found"
          break 2
        fi
      fi
    done
  done

  if [ -z "$ver" ]; then
    # 再搜 .gz (内核以压缩形式打包)
    local gz
    for gz in "$base"/*.gz; do
      [ -f "$gz" ] || continue
      local tmpd
      tmpd=$(mktemp -d "${TMPDIR:-/tmp}/verge-core.XXXXXX")
      if gunzip -c "$gz" > "$tmpd/core" 2>/dev/null && [ -s "$tmpd/core" ]; then
        if found=$(extract_mihomo_version "$tmpd/core" 2>/dev/null); then
          ver="$found"; bin="$gz"; rm -rf "$tmpd"; break
        fi
      fi
      rm -rf "$tmpd"
    done
  fi

  if [ -z "$ver" ]; then
    warn "未检测到内置 Mihomo 内核 (客户端启动后会自行解压)"
    return 1
  fi

  info "内置内核: ${ver}"
  local nums
  nums=$(parse_mihomo_version "$ver")
  if mihomo_version_ge "$nums" "1.19.3"; then
    ok "内核支持 anytls (>= v1.19.3)"
  else
    warn "内核低于 v1.19.3, 无法解析 anytls 节点"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 核心动作：安装、更新、卸载
# ---------------------------------------------------------------------------
install_clash_verge() {
  local tag="$1" pkg_name="$2" url="$3" pkg_path="${DOWNLOAD_DIR}/${pkg_name}"

  info "待安装版本: ${tag}（${pkg_name}）"
  if [ -f "$pkg_path" ]; then
    info "检测到缓存文件: $pkg_path"
    # --continue-at - 可避免重复下载
  fi

  download_file "$url" "$pkg_path"

  if [ "$OS" = "macOS" ]; then
    local target_dir="${INSTALL_DIR:-/Applications}"
    info "macOS: 挂载 DMG 并安装到 ${target_dir}"
    local mount_point="/Volumes/ClashVergeInstall"
    # 清理之前可能残留的同名挂载
    [ -d "$mount_point" ] && hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true

    hdiutil attach "$pkg_path" -mountpoint "$mount_point" -nobrowse -quiet 2>&1 >/dev/null
    # 在 DMG 里查找 .app
    local app_src
    app_src=$(find "$mount_point" -maxdepth 2 -type d -name "*.app" | head -1)
    if [ -z "$app_src" ]; then
      warn "DMG 中未找到 .app；尝试直接打开（交给 Finder 处理）..."
      open "$pkg_path"
      sleep 3
    else
      local app_name="$(basename "$app_src")"
      info "将 '${app_name}' 复制到 ${target_dir}/"
      # 安装前校验: 新包要求的最低 macOS 是否被本机满足 (本次事故根因)
      check_app_macos_compat "$app_src" || {
        hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
        return 1
      }
      # 如已存在旧版本，先备份再替换
      if [ -d "${target_dir}/${app_name}" ]; then
        warn "检测到旧版安装，将被替换（若正在运行，请先退出应用）"
        if [ "$FORCE" -ne 1 ]; then
          ask_yes_no "是否继续？(y/N)" || {
            hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
            return 1
          }
        fi
      fi
      cp -R "$app_src" "${target_dir}/"
      xattr -dr com.apple.quarantine "${target_dir}/${app_name}" 2>/dev/null || true
      ok "已复制到 ${target_dir}/${app_name}"
      info "提示：首次启动若提示『无法验证开发者』，请右键 → 打开"
      # 安装后体检: 内置 Mihomo 内核版本与 anytls 支持
      report_mihomo_core "${target_dir}/${app_name}" || true
    fi
    # 卸载 DMG
    hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
  else
    # Linux
    local pkg_type="deb"
    case "$pkg_name" in
      *.deb) pkg_type="deb" ;;
      *.rpm) pkg_type="rpm" ;;
    esac
    info "Linux：以 $pkg_type 方式安装"
    if [ "$pkg_type" = "deb" ]; then
      if ! command -v dpkg >/dev/null 2>&1; then
        error "本系统没有 dpkg，检测到的包为 .deb，但此环境可能不是 Debian/Ubuntu。请改用适用于本发行版的包。"
        return 1
      fi
      if [ "$(id -u)" -eq 0 ]; then
        dpkg -i "$pkg_path"
      else
        sudo dpkg -i "$pkg_path"
      fi
    elif [ "$pkg_type" = "rpm" ]; then
      if [ "$pkg_type" = "rpm" ]; then
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y "$pkg_path"
        elif command -v yum >/dev/null 2>&1; then
          sudo yum install -y "$pkg_path"
        elif command -v zypper >/dev/null 2>&1; then
          sudo zypper install -y "$pkg_path"
        else
          sudo rpm -i "$pkg_path"
        fi
      fi
    fi
  fi

  # 默认安装成功即删除安装包；KEEP_PACKAGE=1 时保留
  if [ "${KEEP_PACKAGE:-0}" != "1" ] && [ -n "$pkg_path" ]; then
    case "$pkg_path" in
      /*) rm -f -- "$pkg_path" "$pkg_path.url" 2>/dev/null || true && ok "已删除安装包: $pkg_path" ;;
      *) warn "跳过删除安装包（非绝对路径）: $pkg_path" ;;
    esac
  fi
}

uninstall_clash_verge() {
  info "开始卸载 Clash Verge Rev..."

  if [ "$OS" = "macOS" ]; then
    local target="${INSTALL_DIR:-/Applications}/Clash Verge.app"
    if [ ! -d "$target" ]; then
      warn "未在 ${INSTALL_DIR:-/Applications} 发现 Clash Verge.app"
      # 尝试在 ~/Applications 找
      if [ -d "${HOME}/Applications/Clash Verge.app" ]; then
        target="${HOME}/Applications/Clash Verge.app"
      else
        info "没有找到可卸载的 Clash Verge Rev。"
        return 0
      fi
    fi
    info "目标: ${target}"
    if [ "$FORCE" -ne 1 ]; then
      ask_yes_no "确认卸载 Clash Verge Rev？(y/N)" || { info "已取消。"; return 0; }
    fi
    # 若正在运行，先退出
    if pgrep -xq "Clash Verge" 2>/dev/null; then
      warn "应用正在运行，尝试退出..."
      osascript -e 'tell application "Clash Verge" to quit' 2>/dev/null || true
      sleep 2
    fi
    rm -rf "${target}"
    # 清理常见配置目录（可选；保留用户订阅/规则）
    info "保留用户配置目录：~/.config/clash-verge ~/.config/clash-nyanpasu ~/.config/mihomo"
    ok "已卸载: ${target}"
  else
    # Linux
    if command -v dpkg >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -qi "clash.*verge"; then
      local pkg
      pkg=$(dpkg -l 2>/dev/null | grep -iE "clash.*verge" | awk '{print $2}' | head -1)
      [ -n "$pkg" ] && sudo dpkg -r "$pkg"
    elif command -v rpm >/dev/null 2>&1 && rpm -q clash-verge 2>/dev/null | grep -qv "not installed"; then
      sudo rpm -e clash-verge
    else
      warn "未检测到通过包管理器安装的 Clash Verge；若您是解压到本地目录，请手动删除。"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  banner

  # 1) 平台/架构检测
  detect_platform
  detect_installed_version
  info "当前环境: ${OS} / ${ARCH}"
  if [ -n "$INSTALLED_VERSION" ]; then
    info "已安装: ${INSTALLED_VERSION}"
  else
    info "未检测到已安装版本"
  fi

  # 0) --check: 只做本机体检, 不下载不安装
  if [ "$ACTION" = "check" ]; then
    info "▶ 本机体检模式"
    if [ "$OS" = "macOS" ]; then
      local installed_app="${INSTALL_DIR:-/Applications}/Clash Verge.app"
      if [ -d "$installed_app" ]; then
        info "应用已安装: $installed_app"
        # 安装后体检: 内置 Mihomo 内核版本与 anytls 支持
        report_mihomo_core "$installed_app" || true
      else
        warn "Clash Verge.app 未安装"
      fi
      # 系统兼容性预检 (针对最新版, 用当前已装 app 或直接报告本机)
      local cur min_sys
      cur=$(macos_full)
      info "本机 macOS: ${cur}"
      if [ -d "$installed_app" ]; then
        min_sys=$(app_min_system "$installed_app")
        info "已装应用要求 macOS: ${min_sys:-未声明}"
        if [ -n "$min_sys" ] && ! compare_macos_version_ge "$cur" "$min_sys"; then
          warn "当前系统 ${cur} 低于已装应用要求 ${min_sys}, 可能无法启动"
        fi
      fi
      # 检测下载工具
      for t in adl aria2c curl; do
        if command -v "$t" >/dev/null 2>&1; then
          info "下载工具: $t ✓"
        else
          info "下载工具: $t ✗ (未安装)"
        fi
      done
    fi
    echo ""
    exit 0
  fi

  # 2) 获取最新 release 信息
  local result tag pkg_name url
  result=$(query_release) || {
    error "查询 GitHub releases 失败（可能是网络不通 GitHub）。请手动访问 https://github.com/clash-verge-rev/clash-verge-rev/releases"
    exit 1
  }
  tag=$(printf "%s" "$result" | cut -f1)
  pkg_name=$(printf "%s" "$result" | cut -f2)
  url=$(printf "%s" "$result" | cut -f3)

  if [ "$tag" = "NO_MATCH" ] || [ -z "$url" ]; then
    error "未能匹配到与当前平台兼容的包（${OS} / ${ARCH}）"
    info "请手动访问 https://github.com/clash-verge-rev/clash-verge-rev/releases 下载对应版本"
    exit 1
  fi
  ok "最新可用版本: ${tag} / ${pkg_name}"

  # 3) 如果用户没指定动作，交互式询问
  if [ -z "$ACTION" ]; then
    if [ -n "$INSTALLED_VERSION" ]; then
      echo ""
      echo -e "${CYAN}检测到已安装版本：${INSTALLED_VERSION}${NC}"
      echo "请选择操作: "
      echo "  1) 更新到 ${tag}"
      echo "  2) 卸载当前版本"
      echo "  3) 取消"
      printf "输入 [1-3]："
      read -r _reply || _reply="3"
      case "$_reply" in
        1) ACTION="update" ;;
        2) ACTION="uninstall" ;;
        *) ACTION="cancel" ;;
      esac
    else
      echo ""
      echo -e "${CYAN}未检测到已安装版本，请选择操作：${NC}"
      echo "  1) 安装 Clash Verge Rev ${tag}"
      echo "  2) 取消"
      printf "输入 [1-2]："
      read -r _reply || _reply="2"
      case "$_reply" in
        1) ACTION="install" ;;
        *) ACTION="cancel" ;;
      esac
    fi
  fi

  # 4) 执行
  echo ""
  case "$ACTION" in
    install)
      info "▶ 安装 Clash Verge Rev ${tag}"
      if [ -n "$INSTALLED_VERSION" ]; then
        warn "检测到已存在版本 ${INSTALLED_VERSION}，将在同一目录覆盖。"
        if [ "$FORCE" -ne 1 ]; then
          ask_yes_no "是否继续？(y/N)" || { info "已取消。"; exit 0; }
        fi
      fi
      install_clash_verge "$tag" "$pkg_name" "$url"
      ;;
    update)
      info "▶ 更新 Clash Verge Rev → ${tag}"
      # 先卸载旧版本
      uninstall_clash_verge
      # 再安装
      install_clash_verge "$tag" "$pkg_name" "$url"
      ;;
    uninstall)
      uninstall_clash_verge
      ;;
    cancel)
      info "已取消。"
      exit 0
      ;;
    *)
      error "未知 ACTION: ${ACTION}"
      exit 2
      ;;
  esac

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  操作完成。${NC}"
  echo -e "  安装目录: ${INSTALL_DIR:-/Applications}（Linux 由包管理器管理）"
  echo -e "  下载缓存: ${DOWNLOAD_DIR}"
  echo -e "${GREEN}============================================================${NC}"
}

main "$@"

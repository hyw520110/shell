#!/usr/bin/env bash
# =============================================================================
# install-sogou.sh - 搜狗输入法 / 中文输入法 一键安装脚本
# -----------------------------------------------------------------------------
# 支持的发行版:
#   - Kali GNU/Linux Rolling   → 自动降级为 fcitx5 + 中文拼音
#                                （搜狗官方 Linux 包仅支持 fcitx4，Kali Rolling
#                                 仓库已移除 fcitx4，官方包无法满足依赖）
#   - Ubuntu / Debian / Deepin / UOS → 搜狗输入法（fcitx4 + 官方 deb）
# -----------------------------------------------------------------------------
# 用法:
#   sudo ./install-sogou.sh                        # 自动检测并安装
#   sudo ./install-sogou.sh --deb /path/to.deb     # 使用本地搜狗 deb 包
#   sudo ./install-sogou.sh --yes                  # 非交互（全部默认）
#   sudo ./install-sogou.sh --fcitx5               # 强制 fcitx5 + 拼音方案
#   sudo ./install-sogou.sh --force-sogou          # Kali 上强制尝试搜狗（不推荐）
#   sudo ./install-sogou.sh --fix-mirror           # 仅修复 Kali apt 源（USTC https）
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

DEB_FILE=""
ASSUME_YES=0
FORCE_FCITX5=0
FORCE_SOGOU=0
ONLY_FIX_MIRROR=0
SUDO="sudo"

usage() {
  cat <<'EOF'
install-sogou.sh - 搜狗输入法 / 中文输入法 一键安装脚本

用法:
  sudo ./install-sogou.sh                        # 自动检测并安装
  sudo ./install-sogou.sh --deb /path/to.deb     # 使用本地搜狗 deb 包
  sudo ./install-sogou.sh --yes                  # 非交互（全部默认）
  sudo ./install-sogou.sh --fcitx5               # 强制 fcitx5 + 拼音方案
  sudo ./install-sogou.sh --force-sogou          # Kali 上强制尝试搜狗（不推荐）
  sudo ./install-sogou.sh --fix-mirror           # 仅修复 Kali apt 源（USTC https）
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --deb)         shift; DEB_FILE="$1" ;;
    --yes)         ASSUME_YES=1 ;;
    --fcitx5)      FORCE_FCITX5=1 ;;
    --force-sogou) FORCE_SOGOU=1 ;;
    --fix-mirror)  ONLY_FIX_MIRROR=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) error "未知参数: $1"; usage; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] && SUDO=""

# ---------------------------------------------------------------------------
# 发行版检测
# ---------------------------------------------------------------------------
detect_os() {
  local id version
  id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
  version="$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
  printf '%s %s' "$id" "$version"
}

# ---------------------------------------------------------------------------
# Kali apt 源修复：官方 redirector 多镜像易超时/403 → 单一 USTC https
# ---------------------------------------------------------------------------
fix_kali_mirror() {
  local src="/etc/apt/sources.list.d/kali.sources"
  [ -f "$src" ] || return 0
  if grep -q "http.kali.org" "$src" 2>/dev/null; then
    info "Kali 官方源为多镜像 redirector，部分镜像（wane.kr 超时 / tuna http 403）易下载失败"
    $SUDO cp "$src" "${src}.bak.$(date +%Y%m%d)"
    $SUDO tee "$src" >/dev/null <<'EOF'
Types: deb
URIs: https://mirrors.ustc.edu.cn/kali/
Suites: kali-rolling
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/kali-archive-keyring.gpg
EOF
    ok "已切换 Kali 源为 USTC https: $src"
    $SUDO apt update 2>&1 | tail -3 || true
  else
    ok "Kali 源无需修复"
  fi
}

# ---------------------------------------------------------------------------
# 方案 A：fcitx5 + 中文拼音（Kali 及其他无 fcitx4 仓库的系统）
# ---------------------------------------------------------------------------
install_fcitx5_fallback() {
  info "方案: 安装 fcitx5 + 中文拼音（替代搜狗，Kali 官方仓库稳定可用）"
  $SUDO apt install -y --fix-missing \
    fcitx5 fcitx5-chinese-addons fcitx5-config-qt \
    fcitx5-frontend-gtk3 fcitx5-frontend-qt5 fcitx5-frontend-qt6 \
    2>&1 | tail -4 || {
    error "fcitx5 安装失败"
    return 1
  }
  if dpkg -s fcitx5 2>/dev/null | grep -q "install ok installed"; then
    ok "fcitx5 + 中文拼音 安装完成"
    IME_FRAMEWORK="fcitx5"
    return 0
  fi
  error "fcitx5 未就绪"
  return 1
}

# ---------------------------------------------------------------------------
# 方案 B：搜狗输入法（fcitx4 生态，支持 ubuntu/debian/deepin/uos）
# ---------------------------------------------------------------------------
install_sogou_standard() {
  # 搜狗硬依赖 fcitx4，先确认仓库可用
  if ! apt-cache policy fcitx 2>/dev/null | grep -qE "候选|Candidate"; then
    error "当前发行版仓库不提供 fcitx4（搜狗硬依赖），无法安装搜狗"
    info "建议改用: sudo $0 --fcitx5（fcitx5 + 中文拼音）"
    return 1
  fi

  info "安装搜狗依赖（fcitx4 生态）..."
  $SUDO apt install -y --fix-missing \
    fcitx fcitx-frontend-gtk2 fcitx-frontend-gtk3 fcitx-frontend-qt5 \
    fcitx-module-x11 libxtst6 im-config lsb-release \
    2>&1 | tail -3 || true

  if [ -z "$DEB_FILE" ]; then
    local url="https://ime-sec.gtimg.com/soft/dl/sogoupinyin_4.2.1.145_amd64.deb"
    info "自动下载搜狗官方包（sogoupinyin_4.2.1.145_amd64.deb）..."
    warn "官方下载地址可能变动，失败请手动下载后重试: sudo $0 --deb /path/to.deb"
    if ! curl -fsSL --connect-timeout 20 -o /tmp/sogoupinyin.deb "$url"; then
      error "自动下载失败"
      return 1
    fi
    DEB_FILE="/tmp/sogoupinyin.deb"
  fi

  [ -f "$DEB_FILE" ] || { error "deb 包不存在: $DEB_FILE"; return 1; }
  $SUDO dpkg -P sogoupinyin 2>/dev/null || true   # 清理冲突旧包
  ok "安装搜狗输入法: $DEB_FILE"
  if ! $SUDO dpkg -i "$DEB_FILE"; then
    warn "依赖缺失，尝试自动修复..."
    $SUDO apt install -y -f 2>&1 | tail -3 || true
    $SUDO dpkg --configure -a 2>&1 | tail -3 || true
  fi

  if dpkg -s sogoupinyin 2>/dev/null | grep -q "install ok installed"; then
    ok "搜狗输入法安装成功"
    IME_FRAMEWORK="fcitx"
    return 0
  fi
  error "搜狗输入法配置失败（依赖不满足，可尝试: sudo $0 --fcitx5）"
  return 1
}

# ---------------------------------------------------------------------------
# 系统级 IM 环境变量（/etc/environment）：登录会话必生效，
# 不依赖 Xsession 是否 source ~/.xprofile（Kali 的 Xsession 不读 xprofile）
# ---------------------------------------------------------------------------
write_system_env() {
  local envf="/etc/environment"
  if ! grep -q "GTK_IM_MODULE=fcitx" "$envf" 2>/dev/null; then
    $SUDO tee -a "$envf" >/dev/null <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
    ok "已写入系统级 IM 环境变量: $envf"
  else
    ok "系统级 IM 环境变量已存在"
  fi
}

# ---------------------------------------------------------------------------
# 重建 GTK3 输入法模块缓存（im-fcitx5.so 存在但缓存未注册时 GTK 应用仍英文）
# ---------------------------------------------------------------------------
rebuild_gtk_im_cache() {
  if command -v update-gtk-immodules-x11 >/dev/null 2>&1; then
    $SUDO update-gtk-immodules-x11 >/dev/null 2>&1 && ok "已重建 GTK3 immodule 缓存"
  elif command -v gtk-query-immodules-3.0 >/dev/null 2>&1; then
    $SUDO gtk-query-immodules-3.0 --update-cache >/dev/null 2>&1 && ok "已重建 GTK3 immodule 缓存"
  else
    warn "缺少 gtk-query-immodules-3.0，尝试安装 libgtk-3-bin..."
    $SUDO apt install -y libgtk-3-bin >/dev/null 2>&1 || true
    if command -v gtk-query-immodules-3.0 >/dev/null 2>&1; then
      $SUDO gtk-query-immodules-3.0 --update-cache >/dev/null 2>&1 && ok "已重建 GTK3 immodule 缓存"
    else
      warn "GTK3 缓存工具不可用（fcitx5-frontend-gtk3 安装时通常已自动注册）"
    fi
  fi
  local cache
  cache="$(ls /usr/lib/*/gtk-3.0/3.0.0/immodules.cache 2>/dev/null | head -1)"
  if [ -n "$cache" ] && grep -qi fcitx "$cache" 2>/dev/null; then
    ok "GTK3 immodule 缓存已含 fcitx5"
  else
    warn "GTK3 缓存未见 fcitx5（重启后 GTK 应用仍英文则需进一步排查）"
  fi
}

# ---------------------------------------------------------------------------
# 安装后自检（进程 / 拼音状态 / GTK 模块 / Qt 插件）
# ---------------------------------------------------------------------------
verify_ime() {
  echo ""
  info "=== 输入法自检 ==="
  if pgrep -x fcitx5 >/dev/null 2>&1; then
    ok "fcitx5 进程运行中 (PID $(pgrep -x fcitx5 | head -1))"
  else
    warn "fcitx5 未运行（重启后自动启动，或手动: fcitx5 -d &）"
  fi
  if command -v fcitx5-remote >/dev/null 2>&1; then
    local st
    st="$(DISPLAY=:0 fcitx5-remote 2>/dev/null || true)"
    [ -n "$st" ] && ok "fcitx5-remote 状态: $st (0=拼音激活)"
  fi
  local qtplugin
  qtplugin="$(ls /usr/lib/*/qt5/plugins/platforminputcontexts/libfcitx5platforminputcontextplugin.so 2>/dev/null | head -1)"
  if [ -n "$qtplugin" ]; then
    ok "Qt5 fcitx5 插件: $qtplugin"
  else
    warn "Qt5 fcitx5 插件缺失（Qt5 应用需 fcitx5-frontend-qt5）"
  fi
  qtplugin="$(ls /usr/lib/*/qt6/plugins/platforminputcontexts/libfcitx5platforminputcontextplugin.so 2>/dev/null | head -1)"
  if [ -n "$qtplugin" ]; then
    ok "Qt6 fcitx5 插件: $qtplugin"
  else
    warn "Qt6 fcitx5 插件缺失（qterminal 等 Qt6 应用需 fcitx5-frontend-qt6）"
  fi
  if ls /usr/lib/*/gtk-3.0/3.0.0/immodules/im-fcitx5.so >/dev/null 2>&1; then
    ok "GTK3 fcitx5 模块: im-fcitx5.so"
  fi
}

# ---------------------------------------------------------------------------
# 输入法环境变量 + 默认框架
# ---------------------------------------------------------------------------
set_ime_env() {
  local framework="${1:-fcitx}"
  local xprofile="${HOME}/.xprofile"
  touch "$xprofile"
  if ! grep -q "GTK_IM_MODULE=fcitx" "$xprofile" 2>/dev/null; then
    cat >> "$xprofile" <<'EOF'
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
    ok "已写入输入法环境变量: $xprofile"
  fi
  if command -v im-config >/dev/null 2>&1; then
    # 注意：im-config 写用户级 ~/.xinputrc，不能用 sudo（否则写到 root 家目录）
    im-config -n "$framework" >/dev/null 2>&1 && ok "已设置默认输入法框架: $framework"
  else
    warn "未找到 im-config，默认框架需手动设置"
  fi

  # 桌面自启动（部分发行版如 Kali 的 fcitx5 不带 autostart 文件）
  local autostart_dir="${HOME}/.config/autostart"
  local desktop="${autostart_dir}/fcitx5.desktop"
  if [ ! -f "$desktop" ]; then
    mkdir -p "$autostart_dir"
    cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Fcitx5
Comment=Start Fcitx5 Input Method
Exec=${framework}
Icon=fcitx
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    ok "已创建输入法自启动: $desktop"
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
IME_FRAMEWORK="fcitx"
read -r OS_ID OS_VER <<< "$(detect_os)"
info "系统: ${OS_ID} ${OS_VER:-} (arch: $(uname -m))"
[ "$(uname -m)" = "x86_64" ] || { error "仅支持 x86_64"; exit 1; }

case "$OS_ID" in
  kali)
    if [ "$ONLY_FIX_MIRROR" = "1" ]; then fix_kali_mirror; exit 0; fi
    fix_kali_mirror
    if [ "$FORCE_SOGOU" = "1" ]; then
      warn "--force-sogou: Kali 仓库无 fcitx4，强制安装大概率失败"
      install_sogou_standard || exit 1
    elif [ "$FORCE_FCITX5" = "1" ] || [ "$ASSUME_YES" = "1" ]; then
      install_fcitx5_fallback || exit 1
    else
      warn "搜狗官方 Linux 版仅支持 fcitx4，而 Kali Rolling 仓库已移除 fcitx4，官方包无法安装"
      printf "是否改用 fcitx5 + 中文拼音方案？[Y/n] "
      read -r r || r="y"
      if [[ "$r" =~ ^[Yy]?$ ]]; then
        install_fcitx5_fallback || exit 1
      else
        info "已取消（如需尝试搜狗: sudo $0 --force-sogou，不推荐）"
        exit 0
      fi
    fi
    ;;
  ubuntu|debian|deepin|uos|linuxmint)
    install_sogou_standard || {
      warn "搜狗安装失败，可改用: sudo $0 --fcitx5"
      exit 1
    }
    ;;
  *)
    error "暂不支持的发行版: ${OS_ID:-未知}（支持: kali / ubuntu / debian / deepin / uos）"
    exit 1
    ;;
esac

set_ime_env "$IME_FRAMEWORK"
write_system_env
rebuild_gtk_im_cache
verify_ime
echo ""
ok "安装完成！请注销或重启后，在输入法设置中添加「拼音」或「搜狗」"
info "重启: sudo reboot"

#!/bin/bash
#
# Kiri 管理脚本 — 轻量容器运行时（Docker Desktop 替代）
# Kiri 用 Apple Virtualization.framework 跑一个小 Linux VM，兼容 docker CLI/Compose/buildx
#
# 功能：
#   install    下载 Kiri dmg（adl 优先），安装到 /Applications，配置 docker context + LaunchAgent，启动 daemon
#   update     检测最新版本（GitHub API 限流回退 URL 探测），下载新版，staging 验证后安全替换
#   uninstall  用 kiri setup --uninstall 清理（LaunchAgent/context/PATH），删 app + 数据
#   status     显示当前版本与运行状态
#   --print-url   打印下载 URL（不下载）
#   --version     打印版本
#
# 用法：
#   ./install-kiri.sh install
#   ./install-kiri.sh update
#   ./install-kiri.sh uninstall
#   ./install-kiri.sh status
#   ./install-kiri.sh --print-url
#
# 官网：https://github.com/libracoder/kiri  |  https://runkiri.com

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# === 颜色 ===
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly NC=$'\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 默认配置 ===
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
KEEP_PACKAGE="${KEEP_PACKAGE:-0}"   # 1=保留安装包，默认装后删
APP_NAME="Kiri"
APP_PATH="/Applications/${APP_NAME}.app"
GH_OWNER="libracoder"
GH_REPO="kiri"
GH_BASE="https://github.com/${GH_OWNER}/${GH_REPO}"
INSTALL_DIR="$HOME/.kiri"
KIRI_BIN="$APP_PATH/Contents/MacOS/kiri"
# 精确 pgrep 模式（避免误匹配含 "kiri daemon" 的其他进程）
DAEMON_PATTERN="/Applications/Kiri.app/Contents/MacOS/kiri daemon"
# 国内镜像加速（Docker Hub 直连国内不可达）
REGISTRY_MIRROR="${KIRI_REGISTRY_MIRROR:-docker.m.daocloud.io}"

# === 路径安全校验（防 rm -rf 误删/越界） ===
# APP_PATH 必须精确在 /Applications 下
validate_app_path() {
    [[ "$APP_PATH" == "/Applications/Kiri.app" ]] || {
        print_error "非法 APP_PATH: ${APP_PATH}（必须为 /Applications/Kiri.app）"; return 1; }
    return 0
}
# INSTALL_DIR 必须以 $HOME 开头、非空、非 /、非 $HOME 本身
validate_install_dir() {
    [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "$HOME" ]] || {
        print_error "非法 INSTALL_DIR: $INSTALL_DIR"; return 1; }
    [[ "$INSTALL_DIR" == "$HOME"/* ]] || {
        print_error "INSTALL_DIR 必须在 \$HOME 下: $INSTALL_DIR"; return 1; }
    return 0
}
# KIRI_BIN 必须指向 /Applications/Kiri.app 内
validate_kiri_bin() {
    validate_app_path || return 1
    [[ "$KIRI_BIN" == "/Applications/Kiri.app/Contents/MacOS/kiri" ]] || {
        print_error "非法 KIRI_BIN: $KIRI_BIN"; return 1; }
    return 0
}

# === 环境变量 PATH 幂等更新 ===
# 幂等追加 $INSTALL_DIR/bin 到 PATH（防重复：case 匹配已含则跳过，同 Kiri 官方 setup 写法）
# 若 PATH 已含 kiri/bin 则跳过（不重复追加）；否则写入 ~/.zshrc
ensure_path() {
    local bin_dir="$INSTALL_DIR/bin"
    [[ -d "$bin_dir" ]] || { print_warn "未找到 ${bin_dir}，跳过 PATH 配置"; return 0; }
    local target="$HOME/.zshrc"
    [[ -f "$target" ]] || touch "$target"
    # 检测是否已含 .kiri/bin（固定字符串，兼容 "$HOME/.kiri/bin" 与绝对路径两种写法）
    if grep -qF ".kiri/bin" "$target"; then
        print_info "PATH 已配置（~/.zshrc 已含 kiri/bin），跳过"
        return 0
    fi
    {
        echo ""
        echo "# Added by install-kiri.sh: kiri docker/kiri CLI"
        echo 'case ":$PATH:" in *":$HOME/.kiri/bin:"*) ;; *) export PATH="$PATH:$HOME/.kiri/bin" ;; esac'
    } >> "$target"
    print_success "已写入 PATH 到 $target"
    return 0
}

# === 工具函数 ===
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "darwin" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)       echo "unknown" ;;
    esac
}

# 系统最低版本检查：Kiri 官方声明 macOS 14+，但实测 12.7.6 可用（Virtualization.framework 74.12 足够）。
# 不硬性拒绝，仅警告。
check_os() {
    local os_type
    os_type=$(detect_os)
    if [[ "$os_type" != "darwin" ]]; then
        print_error "Kiri 仅支持 macOS（当前: ${os_type}）"
        return 1
    fi
    local major minor
    major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    minor=$(sw_vers -productVersion 2>/dev/null | cut -d. -f2)
    if [[ "$major" -lt 12 ]]; then
        print_error "Kiri 需要 macOS 12 或更高（当前: ${major}.${minor}）"
        return 1
    fi
    if [[ "$major" -lt 14 ]]; then
        print_warn "Kiri 官方声明 macOS 14+，当前 ${major}.${minor}；实测 12.7.6 可运行（Virtualization.framework 74.12 足够），继续..."
    fi
    return 0
}

# adl 优先下载（用户强制），失败回退 curl/wget
find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_file() {
    local url="$1" dir="$2" filename="$3"
    local out="$dir/$filename"
    mkdir -p "$dir"
    local adl_path
    if adl_path=$(find_adl); then
        print_info "使用 adl 下载..."
        if "$adl_path" "$url" "$dir" "$filename"; then
            return 0
        fi
        print_warn "adl 下载失败，回退到 curl/wget"
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url"
    else
        print_error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# 版本检测：GitHub API（限流回退 URL 探测）
get_latest_version() {
    local os_type arch_type platform
    os_type=$(detect_os)
    arch_type=$(detect_arch)
    [[ "$os_type" == "darwin" ]] || return 1

    local api="https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/releases/latest"
    local json
    json=$(curl -sL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" "$api" 2>/dev/null || true)
    if [[ -n "$json" ]] && ! echo "$json" | grep -q "API rate limit exceeded"; then
        local ver
        ver=$(echo "$json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("tag_name",""))' 2>/dev/null || echo "")
        ver="${ver#v}"
        if [[ -n "$ver" && "$ver" != "null" ]]; then
            echo "$ver"
            return 0
        fi
    fi
    # 回退：GitHub API 的 tags 列表（更准，不写死候选版本）
    local tags_json
    tags_json=$(curl -sL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/tags?per_page=20" 2>/dev/null || true)
    if [[ -n "$tags_json" ]] && ! echo "$tags_json" | grep -q "API rate limit exceeded"; then
        local top_ver
        top_ver=$(echo "$tags_json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([t["name"].lstrip("v") for t in d if "name" in t][0] if d else "")' 2>/dev/null || echo "")
        if [[ -n "$top_ver" && "$top_ver" != "null" ]]; then
            echo "$top_ver"
            return 0
        fi
    fi
    # 最后兜底：从已知版本向上探测下载 URL 存在性（release-assets 302=存在/404=不存在）
    # 按"补丁号优先递增"覆盖真实版本序列（0.2.2 -> 0.2.3 -> ... -> 0.3.0 -> ...），不写死候选
    local base="0.2.2" idx ver
    for idx in $(seq 0 1 30); do
        ver=$(python3 -c "
v='$base'.split('.')
major, minor, patch = int(v[0]), int(v[1]), int(v[2])
total = major*10000 + minor*100 + patch + $idx
print(f'{total//10000}.{(total//100)%100}.{total%100}')" 2>/dev/null || echo "")
        [[ -n "$ver" ]] || continue
        local durl="${GH_BASE}/releases/download/v${ver}/Kiri-${ver}-${arch_type}.dmg"
        if curl -sIL --max-time 8 "$durl" 2>/dev/null | grep -qi "release-assets"; then
            echo "$ver"
            return 0
        fi
    done
    return 1
}

get_current_version() {
    if [[ -x "$KIRI_BIN" ]]; then
        local out
        out=$("$KIRI_BIN" update --check 2>/dev/null | head -1)
        echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

build_url() {
    local version="$1"
    local arch_type
    arch_type=$(detect_arch)
    [[ "$arch_type" == "unknown" ]] && { print_error "不支持的架构: $(uname -m)"; return 1; }
    echo "${GH_BASE}/releases/download/v${version}/Kiri-${version}-${arch_type}.dmg"
}

# 下载 dmg
download_dmg() {
    local version="$1"
    local url
    url=$(build_url "$version") || return 1
    local filename
    filename=$(basename "$url")
    local pkg="$DOWNLOAD_DIR/$filename"
    print_info "下载: $url"
    if [[ ! -s "$pkg" ]]; then
        download_file "$url" "$DOWNLOAD_DIR" "$filename" || return 1
    else
        print_info "已存在安装包: $filename"
    fi
    [[ -s "$pkg" ]] || { print_error "下载后文件为空"; return 1; }
    echo "$pkg"
}

# GUI 兼容修复：Kiri 官方 Info.plist 声明 LSMinimumSystemVersion=14.0，但主二进制 minos=10.12，
# 实测 12.7.6 可运行。Finder/LaunchServices 读 Info.plist 拒绝打开（-10825），必须改 plist +
# 重签 + 重建 LaunchServices 缓存。⚠️ 重签必须保留 entitlements（com.apple.security.virtualization），
# 否则 VM 无法启动（invalid VM config: process doesn't have the "com.apple.security.virtualization" entitlement）。
# 参数 $1 = 原始（dmg 内）app 路径，用于提取原始 entitlements。
fix_gui_compat() {
    local orig_app="${1:-$APP_PATH}"
    local plist="$APP_PATH/Contents/Info.plist"
    [[ -f "$plist" ]] || return 0
    # 1) 降 LSMinimumSystemVersion 到 12.0（≤ macOS 12.7.6）
    local cur
    cur=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist" 2>/dev/null || echo "")
    if [[ -n "$cur" && "$cur" != "12.0" ]]; then
        print_info "GUI 兼容修复: LSMinimumSystemVersion $cur -> 12.0"
        /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 12.0" "$plist" 2>/dev/null || true
    fi
    # 2) 重签：从原始 app 提取 entitlements（保留 com.apple.security.virtualization）
    local ent_file="/tmp/kiri-ent.$$.xml"
    if codesign -d --entitlements :- "$orig_app/Contents/MacOS/kiri" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
        codesign -d --entitlements :- "$orig_app/Contents/MacOS/kiri" 2>/dev/null | tr -d '\0' > "$ent_file" 2>/dev/null || true
        if [[ -s "$ent_file" ]]; then
            print_info "重签（保留 com.apple.security.virtualization entitlement）"
            codesign --force --deep --sign - --entitlements "$ent_file" "$APP_PATH" >/dev/null 2>&1 || true
            rm -f "$ent_file"
        else
            codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
        fi
    else
        # 无 virtualization entitlement 的 app（普通 app）→ 简单 ad-hoc 重签即可
        codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
    fi
    # 3) 重建 LaunchServices 缓存（关键：不刷新仍报 -10825）
    local lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ -x "$lsreg" ]] && "$lsreg" -f "$APP_PATH" >/dev/null 2>&1 || true
    killall launchservicesd 2>/dev/null || true
    return 0
}

# 从 dmg 安装 app
install_from_dmg() {
    local dmg="$1"
    local mnt
    mnt=$(mktemp -d /tmp/kiri-mnt.XXXXXX)
    print_info "挂载 dmg..."
    if ! hdiutil attach "$dmg" -mountpoint "$mnt" -nobrowse >/dev/null 2>&1; then
        print_error "挂载失败: $dmg"
        rm -rf "$mnt"
        return 1
    fi
    local src="$mnt/${APP_NAME}.app"
    if [[ ! -d "$src" ]]; then
        print_error "dmg 内未找到 ${APP_NAME}.app"
        hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
        rm -rf "$mnt"
        return 1
    fi
    # 替换旧版（先校验精确路径，防 APP_PATH 被环境覆盖）
    validate_app_path || { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; rm -rf "$mnt"; return 1; }
    if [[ -d "$APP_PATH" ]]; then
        print_info "移除旧版 $APP_PATH"
        rm -rf "$APP_PATH"
    fi
    if ! ditto "$src" "$APP_PATH"; then
        print_error "安装失败"
        hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
        rm -rf "$mnt"
        return 1
    fi
    # GUI 兼容修复（Finder/LaunchServices 门槛）—— 在 detach 前调用，${src}（原始 app）仍可访问
    fix_gui_compat "$src"
    hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
    rm -rf "$mnt"
    print_success "${APP_NAME}.app 已安装"
    return 0
}

# 启动 daemon（nohup 优先，launchctl 兜底）
start_daemon() {
    if pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1 && [[ -S "$INSTALL_DIR/run/docker.sock" ]]; then
        print_info "kiri daemon 已在运行（socket 就绪）"
        return 0
    fi
    print_info "启动 kiri daemon..."
    # 优先直接后台起（已验证可行），不依赖 launchctl bootstrap（之前实测报 I/O error）
    if ! pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1; then
        nohup "$KIRI_BIN" daemon >>"$INSTALL_DIR/daemon.log" 2>&1 &
    fi
    # 轮询 socket 就绪（最多 30s）
    local i
    for i in $(seq 1 30); do
        if pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1 && [[ -S "$INSTALL_DIR/run/docker.sock" ]]; then
            print_success "kiri daemon 已启动（socket 就绪）"
            return 0
        fi
        sleep 1
    done
    # 兜底：尝试 launchctl
    local la="$HOME/Library/LaunchAgents/dev.kiri.daemon.plist"
    if [[ -f "$la" ]]; then
        launchctl bootstrap "gui/$(id -u)" "$la" 2>/dev/null || true
        sleep 3
        if pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1; then
            print_success "kiri daemon 已启动（launchctl）"
            return 0
        fi
    fi
    print_warn "daemon 未确认就绪，请检查 ~/.kiri/daemon.log"
    return 1
}

# 镜像加速提示 + 可选配置
print_mirror_hint() {
    print_info "国内镜像加速（Docker Hub 直连国内不可达）:"
    print_info "  docker pull ${REGISTRY_MIRROR}/library/nginx:latest"
    print_info "  或用 KIRI_REGISTRY_MIRROR 环境变量指定其他镜像源"
}

# === 动作 ===
action_install() {
    check_os || return 1
    # 幂等：已装版本则跳过重复安装（get_latest_version 失败时用已装版本兜底）
    local current="" latest=""
    current=$(get_current_version)
    if [[ -n "$current" ]]; then
        latest=$(get_latest_version 2>/dev/null || echo "$current")
        if [[ "$latest" == "$current" ]]; then
            print_info "Kiri 已安装（${current}），跳过重复安装"
            ensure_path
            start_daemon
            print_success "Kiri $current 已安装"
            print_mirror_hint
            return 0
        fi
        print_info "Kiri 已安装（${current}），有新版 ${latest}，执行更新"
    else
        latest=$(get_latest_version 2>/dev/null) || { print_error "无法获取最新版本"; return 1; }
    fi
    print_info "安装 Kiri $latest"
    local dmg
    dmg=$(download_dmg "$latest") || return 1
    install_from_dmg "$dmg" || return 1
    [[ "$KEEP_PACKAGE" == "1" ]] || rm -f "$dmg"
    # 配置（若未配置过）—— setup --use 会保持前台卡住，改为后台运行 + 轮询配置完成标志
    if [[ ! -f "$HOME/Library/LaunchAgents/dev.kiri.daemon.plist" ]]; then
        print_info "配置 kiri（docker context / LaunchAgent / PATH）..."
        "$KIRI_BIN" setup --use >/dev/null 2>&1 &
        local setup_pid=$!
        # 轮询配置完成标志（最多 60s）：docker context 含 kiri 且 LaunchAgent 存在
        # 用 Kiri 自带 docker CLI（系统 PATH 可能无 docker）
        local kiri_docker="$INSTALL_DIR/bin/docker"
        local i configured
        configured=0
        for i in $(seq 1 60); do
            if "$kiri_docker" context ls 2>/dev/null | grep -q "kiri" \
               && [[ -f "$HOME/Library/LaunchAgents/dev.kiri.daemon.plist" ]]; then
                configured=1
                break
            fi
            sleep 1
        done
        if [[ "$configured" == "1" ]]; then
            print_success "kiri 配置完成（context + LaunchAgent）"
        else
            print_warn "配置标志未在 60s 内就绪，可能仍配置中"
        fi
        # 收尸：setup 若仍卡着（保持前台），等待有限时间后终止，避免残留
        if kill -0 "$setup_pid" 2>/dev/null; then
            print_warn "kiri setup 仍在后台运行，等待其退出（最多 20s）..."
            local j
            for j in $(seq 1 20); do
                if ! kill -0 "$setup_pid" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "$setup_pid" 2>/dev/null; then
                print_warn "kiri setup 卡住超时，终止它（配置已独立生效）"
                kill "$setup_pid" 2>/dev/null || true
            fi
        fi
    fi
    # PATH 幂等更新（若 setup 未写或需兜底）
    ensure_path
    start_daemon
    print_success "Kiri $latest 安装完成"
    print_mirror_hint
    print_info "使用: docker --context kiri ps  (或直接 docker ps，若已设为默认)"
}

action_update() {
    check_os || return 1
    local current="" latest=""
    current=$(get_current_version)
    latest=$(get_latest_version) || { print_error "无法获取最新版本"; return 1; }
    print_info "当前: ${current:-未安装}  最新: $latest"
    if [[ -n "$current" && "$current" == "$latest" ]]; then
        print_success "Kiri 已是最新版本 ($latest)"
        return 0
    fi
    if [[ -z "$current" ]]; then
        print_warn "未检测到已安装的 Kiri，执行安装"
        action_install
        return 0
    fi
    print_info "升级 $current -> $latest"
    local dmg
    dmg=$(download_dmg "$latest") || return 1
    # 安全升级：staging 验证后替换
    install_from_dmg "$dmg" || { rm -f "$dmg"; return 1; }
    [[ "$KEEP_PACKAGE" == "1" ]] || rm -f "$dmg"
    # 验证新版可用
    if [[ -x "$KIRI_BIN" ]]; then
        if ! "$KIRI_BIN" update --check >/dev/null 2>&1; then
            print_error "新版本验证失败"
            return 1
        fi
    fi
    ensure_path
    start_daemon
    print_success "Kiri 已升级到 $latest"
}

action_uninstall() {
    print_info "卸载 Kiri..."
    validate_app_path || return 1
    validate_install_dir || return 1
    # 停止 daemon
    if pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1; then
        pkill -f "$DAEMON_PATTERN" 2>/dev/null || true
        print_info "已停止 daemon"
    fi
    # Kiri 自带清理（LaunchAgent/context/PATH）
    if [[ -x "$KIRI_BIN" ]]; then
        "$KIRI_BIN" setup --uninstall >/dev/null 2>&1 || true
        print_info "已执行 kiri setup --uninstall"
    fi
    # 删除 app（已校验精确路径）
    if [[ -d "$APP_PATH" ]]; then
        rm -rf "$APP_PATH"
        print_success "已删除 $APP_PATH"
    fi
    # 删除数据目录（提示保留选项）—— 路径已校验在 $HOME 下
    if [[ "${KEEP_DATA:-0}" != "1" ]]; then
        rm -rf "$INSTALL_DIR" "$HOME/Kiri" "$HOME/Library/Application Support/Kiri" "$HOME/Library/Application Support/kiri" 2>/dev/null || true
        print_info "已删除数据目录"
    else
        print_warn "KEEP_DATA=1，保留 ~/.kiri 与 ~/Library/Application Support/Kiri"
    fi
    # 清理 LaunchAgent 文件（保险）
    rm -f "$HOME/Library/LaunchAgents/dev.kiri.daemon.plist" 2>/dev/null || true
    print_success "Kiri 卸载完成"
}

action_status() {
    local current
    current=$(get_current_version)
    if [[ -d "$APP_PATH" ]]; then
        print_info "${APP_NAME}.app 已安装: ${current:-版本未知}"
        if pgrep -f "$DAEMON_PATTERN" >/dev/null 2>&1; then
            print_info "daemon: 运行中"
        else
            print_warn "daemon: 未运行"
        fi
        local sock="$INSTALL_DIR/run/docker.sock"
        [[ -S "$sock" ]] && print_info "docker.sock: $sock" || print_warn "docker.sock 未就绪"
    else
        print_warn "${APP_NAME}.app 未安装"
        return 1
    fi
}

# === 帮助 ===
show_help() {
    cat << EOF
Kiri 管理脚本 — 轻量容器运行时（Docker Desktop 替代）

用法: ./$SCRIPT_NAME [install|update|uninstall|status] [选项]

命令:
    install     安装 Kiri（下载 dmg，装到 /Applications，配置并启动）
    update      升级到最新版本（自动检测，staging 验证后安全替换）
    uninstall   卸载（kiri setup --uninstall 清理 + 删除 app/数据）
    status      显示版本与运行状态

选项:
    -h, --help         显示此帮助
    --print-url        打印下载 URL（不下载）
    --version          打印版本
    KEEP_PACKAGE=1     保留安装包（默认装后删）
    KEEP_DATA=1        卸载时保留数据目录
    KIRI_REGISTRY_MIRROR=xxx  镜像加速源（默认 docker.m.daocloud.io）

镜像加速（国内 Docker Hub 不可达，用镜像前缀）:
    docker pull docker.m.daocloud.io/library/nginx:latest

官网: https://github.com/libracoder/kiri
EOF
}

# === 主流程 ===
ACTION=""
ver=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        install)   ACTION="install" ; shift ;;
        update)    ACTION="update" ; shift ;;
        uninstall) ACTION="uninstall" ; shift ;;
        status)    ACTION="status" ; shift ;;
        --print-url)
            print_info "最新版本探测中..."
            ver=$(get_latest_version 2>/dev/null || echo "0.2.2")
            echo "$(build_url "$ver")"
            exit 0 ;;
        --version)
            echo "$(get_latest_version 2>/dev/null || echo "0.2.2")"
            exit 0 ;;
        -h|--help) show_help; exit 0 ;;
        *) print_error "未知选项: $1"; show_help; exit 1 ;;
    esac
done

[[ -n "$ACTION" ]] || { show_help; exit 0; }

case "$ACTION" in
    install|update|uninstall)
        # 路径安全：任何写/删操作前校验，防环境覆盖误删
        validate_app_path || exit 1
        validate_install_dir || exit 1
        validate_kiri_bin || true   # KIRI_BIN 可不存在（首次安装），仅格式校验
        ;;
esac

case "$ACTION" in
    install)   action_install ;;
    update)    action_update ;;
    uninstall) action_uninstall ;;
    status)    action_status ;;
esac

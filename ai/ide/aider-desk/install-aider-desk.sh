#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO="hotovo/aider-desk"
APP_NAMES=("AiderDesk.app" "Aider Desk.app")
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*" >&2; }

format_size() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GiB", b / 1073741824;
        else if (b >= 1048576) printf "%.2f MiB", b / 1048576;
        else if (b >= 1024) printf "%.1f KiB", b / 1024;
        else printf "%d B", b;
    }'
}

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "unsupported" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64) echo "x64" ;;
        *) echo "unknown" ;;
    esac
}

find_app() {
    local app
    for app in "${APP_NAMES[@]}"; do
        if [[ -d "/Applications/$app" ]]; then
            echo "/Applications/$app"
            return 0
        fi
    done
    return 1
}

is_installed() {
    find_app >/dev/null || command -v aider-desk >/dev/null 2>&1
}

get_version() {
    local app
    app=$(find_app 2>/dev/null || true)
    if [[ -n "$app" ]]; then
        defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "已安装"
    elif command -v aider-desk >/dev/null 2>&1; then
        aider-desk --version 2>/dev/null || echo "已安装"
    fi
}

download() {
    local url="$1"
    local out="$2"
    local expected_size="${3:-}"
    mkdir -p "$(dirname "$out")"

    if command -v adl >/dev/null 2>&1; then
        if [[ "$expected_size" =~ ^[0-9]+$ && "$expected_size" -gt 0 ]]; then
            ADL_EXPECTED_SIZE_BYTES="$expected_size" adl "$url" "$(dirname "$out")" "$(basename "$out")"
        else
            adl "$url" "$(dirname "$out")" "$(basename "$out")"
        fi
    else
        curl -L --fail -o "$out" "$url"
    fi
}

latest_release_json() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest"
}

select_asset() {
    local os="$1"
    local arch="$2"
    local json="$3"
    local pattern=""

    case "$os:$arch" in
        macos:arm64) pattern='macos-arm64\.dmg$' ;;
        macos:x64) pattern='macos-x64\.dmg$' ;;
        linux:arm64) pattern='arm64\.AppImage$' ;;
        linux:x64) pattern='x86_64\.AppImage$|[^a-z]AppImage$' ;;
        windows:*) pattern='setup\.exe$' ;;
        *) return 1 ;;
    esac

    printf '%s' "$json" | jq -r --arg pattern "$pattern" '
        .assets[]
        | select(.name | test($pattern))
        | [.browser_download_url, (.size // 0)]
        | @tsv
    ' | head -1
}

install_macos() {
    local dmg="$1"
    local mount_dir
    mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/aider-desk-mount.XXXXXX")

    cleanup_mount() {
        local dir="${1:-}"
        [[ -n "$dir" ]] || return 0
        hdiutil detach "$dir" >/dev/null 2>&1 || return 1
        rmdir "$dir"
    }

    log_info "挂载 DMG: $dmg"
    if ! hdiutil attach "$dmg" -mountpoint "$mount_dir" -nobrowse -readonly >/dev/null; then
        cleanup_mount "$mount_dir"
        return 1
    fi

    local app
    app=$(find "$mount_dir" -maxdepth 2 -name "*.app" -type d | head -1)
    if [[ -z "$app" ]]; then
        log_error "DMG 中未找到 .app"
        cleanup_mount "$mount_dir"
        return 1
    fi

    local dest="/Applications/$(basename "$app")"
    log_info "复制到 $dest"
    rm -rf "$dest"
    if ! cp -R "$app" "/Applications/"; then
        cleanup_mount "$mount_dir"
        return 1
    fi

    cleanup_mount "$mount_dir" || return 1

    log_ok "AiderDesk 安装完成"
}

install_linux() {
    local appimage="$1"
    local install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
    cp "$appimage" "$install_dir/aider-desk"
    chmod +x "$install_dir/aider-desk"
    log_ok "AiderDesk 已安装到 $install_dir/aider-desk"
}

install_windows() {
    local exe="$1"
    log_info "启动 Windows 安装程序: $exe"
    "$exe"
}

main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        get_version
        exit 0
    fi

    if is_installed; then
        log_warn "AiderDesk 已安装 $(get_version)"
        if [[ -t 0 ]]; then
            read -r -p "是否重新安装? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
        fi
    fi

    command -v jq >/dev/null 2>&1 || { log_error "缺少 jq，无法解析 GitHub release"; exit 1; }
    command -v curl >/dev/null 2>&1 || { log_error "缺少 curl，无法下载 release 信息"; exit 1; }

    local os arch release tag asset url size file
    os=$(detect_os)
    arch=$(detect_arch)
    [[ "$os" != "unsupported" && "$arch" != "unknown" ]] || { log_error "不支持的系统或架构: $(uname -s)/$(uname -m)"; exit 1; }

    log_info "查询 AiderDesk 最新版本..."
    release=$(latest_release_json)
    tag=$(printf '%s' "$release" | jq -r '.tag_name')
    asset=$(select_asset "$os" "$arch" "$release")
    url=$(printf '%s' "$asset" | awk -F '\t' '{print $1}')
    size=$(printf '%s' "$asset" | awk -F '\t' '{print $2}')
    [[ -n "$url" && "$url" != "null" ]] || { log_error "未找到适合 $os/$arch 的安装包"; exit 1; }

    mkdir -p "$DOWNLOAD_DIR"
    file="$DOWNLOAD_DIR/$(basename "$url")"

    log_info "版本: $tag"
    log_info "下载: $url"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]]; then
        log_info "大小: $(format_size "$size")"
    fi
    download "$url" "$file" "$size"

    case "$os" in
        macos) install_macos "$file" ;;
        linux) install_linux "$file" ;;
        windows) install_windows "$file" ;;
    esac

    if rm -f -- "$file"; then
        log_info "已删除安装包: $file"
    else
        log_warn "安装成功，但安装包清理失败: $file"
    fi
    log_ok "完成"
}

main "$@"

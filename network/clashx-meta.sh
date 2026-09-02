#!/bin/bash

set -euo pipefail

APP_NAME="ClashX Meta"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.metacubex.ClashX.meta"
HELPER_LABEL="com.metacubex.ClashX.ProxyConfigHelper"
REPO_API="https://api.github.com/repos/MetaCubeX/ClashX.Meta/releases/latest"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
ClashX Meta 一键安装/更新/卸载脚本

用法:
  $0 [命令] [选项]

命令:
  install              安装；已安装时更新到最新版本
  update               同 install
  uninstall            卸载软件（默认）：删除 App 和 helper，保留用户数据
  purge                完全卸载：删除 App、helper、缓存、日志和用户配置

选项:
  --download-dir DIR   下载目录，默认: ~/Downloads
  -h, --help           显示帮助

示例:
  $0                   # 安装或更新
  $0 uninstall         # 卸载软件，保留配置
  $0 purge             # 完全卸载
EOF
}

need_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        log_error "ClashX Meta 仅支持 macOS"
        exit 1
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

adl_cmd() {
    if has_cmd adl; then
        command -v adl
        return 0
    fi
    if [[ -x "$SCRIPT_DIR/tools/adl" ]]; then
        printf '%s\n' "$SCRIPT_DIR/tools/adl"
        return 0
    fi
    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_file adl_path

    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"
    mkdir -p "$output_dir"

    if adl_path="$(adl_cmd 2>/dev/null)"; then
        log_info "使用 adl 下载: $url"
        "$adl_path" "$url" "$output_dir" "$output_file"
        return $?
    fi

    if has_cmd curl; then
        log_info "使用 curl 下载: $url"
        curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url"
        return $?
    fi

    if has_cmd wget; then
        log_info "使用 wget 下载: $url"
        wget -O "$output" "$url"
        return $?
    fi

    log_error "未找到可用下载工具，请先安装 adl、curl 或 wget"
    return 1
}

installed_version() {
    local info_plist="$APP_PATH/Contents/Info.plist"

    [[ -d "$APP_PATH" && -f "$info_plist" ]] || return 1

    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null \
        || defaults read "$info_plist" CFBundleShortVersionString 2>/dev/null \
        || return 1
}

version_key() {
    local version="$1"

    version="${version#v}"
    version="${version%%-*}"

    awk -v v="$version" 'BEGIN {
        n = split(v, p, /[^0-9]+/);
        for (i = 1; i <= 4; i++) {
            val = (i <= n && p[i] != "") ? p[i] : 0;
            printf "%06d", val;
        }
        printf "\n";
    }'
}

version_gt() {
    local left right
    left=$(version_key "$1")
    right=$(version_key "$2")
    [[ "$left" > "$right" ]]
}

latest_release_info() {
    local json tmp_json

    tmp_json=$(mktemp "${TMPDIR:-/tmp}/clashx-meta-latest.XXXXXX.json")
    if ! download_file "$REPO_API" "$tmp_json" >/dev/null; then
        rm -f "$tmp_json"
        return 1
    fi
    json=$(cat "$tmp_json")
    rm -f "$tmp_json"

    if ! has_cmd python3; then
        local tag url
        tag=$(printf '%s\n' "$json" | awk -F'"' '/"tag_name"/ {print $4; exit}')
        url=$(printf '%s\n' "$json" \
            | awk -F'"' '/browser_download_url/ && /\.(dmg|zip)/ && $4 !~ /[Ss]ource/ {print $4; exit}'
        )
        [[ -n "$tag" && -n "$url" ]] || return 1
        printf '%s\t%s\n' "$tag" "$url"
        return
    fi

    printf '%s\n' "$json" | python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
assets = data.get("assets", [])
patterns = [
    re.compile(r"ClashX.*Meta.*\.(dmg|zip)$", re.I),
    re.compile(r"ClashX.*\.(dmg|zip)$", re.I),
    re.compile(r".*\.(dmg|zip)$", re.I),
]

for pattern in patterns:
    for asset in assets:
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        if pattern.fullmatch(name) and "source" not in name.lower():
            print("%s\t%s" % (data.get("tag_name", ""), url))
            sys.exit(0)

sys.exit(1)
'
}

quit_app() {
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    pkill -f "$APP_NAME" >/dev/null 2>&1 || true
    pkill -f "ClashX" >/dev/null 2>&1 || true
}

remove_helper() {
    local helper_file="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
    local daemon_file="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

    if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
        sudo launchctl bootout system "/Library/LaunchDaemons/${HELPER_LABEL}.plist" >/dev/null 2>&1 || true
    fi

    if [[ -e "$helper_file" ]]; then
        sudo rm -f "$helper_file"
    fi
    if [[ -e "$daemon_file" ]]; then
        sudo rm -f "$daemon_file"
    fi
}

install_app_from_archive() {
    local archive="$1"
    local mount_point=""
    local app_source=""
    local tmp_extract=""

    case "$archive" in
        *.dmg)
            log_info "挂载 DMG..."
            mount_point=$(hdiutil attach "$archive" -nobrowse 2>/dev/null | sed -n 's#^/dev/.*\(/Volumes/.*\)$#\1#p' | head -1)
            if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
                log_error "DMG 挂载失败"
                return 1
            fi
            app_source=$(find "$mount_point" -maxdepth 2 -name "*.app" -type d | head -1)
            ;;
        *.zip)
            tmp_extract=$(mktemp -d)
            log_info "解压 ZIP..."
            ditto -x -k "$archive" "$tmp_extract"
            app_source=$(find "$tmp_extract" -maxdepth 3 -name "*.app" -type d | head -1)
            ;;
        *)
            log_error "不支持的安装包格式: $archive"
            return 1
            ;;
    esac

    if [[ -z "$app_source" || ! -d "$app_source" ]]; then
        [[ -n "$mount_point" ]] && hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        [[ -n "$tmp_extract" ]] && rm -rf "$tmp_extract"
        log_error "安装包中未找到 .app"
        return 1
    fi

    quit_app
    log_info "安装到 /Applications..."
    if [[ -d "$APP_PATH" ]]; then
        rm -rf "$APP_PATH" 2>/dev/null || sudo rm -rf "$APP_PATH"
    fi
    cp -R "$app_source" "$APP_PATH" 2>/dev/null || sudo cp -R "$app_source" "$APP_PATH"

    [[ -n "$mount_point" ]] && hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    [[ -n "$tmp_extract" ]] && rm -rf "$tmp_extract"

    if [[ -d "$APP_PATH" ]]; then
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
        log_info "安装完成: $APP_PATH"
        return 0
    fi

    log_error "安装失败，未找到 $APP_PATH"
    return 1
}

install_or_update() {
    local release_info remote_version url local_version filename archive

    need_macos
    mkdir -p "$DOWNLOAD_DIR"

    log_info "获取 ClashX Meta 最新版本信息..."
    release_info=$(latest_release_info) || {
        log_error "未能从 GitHub release 中识别 macOS 安装包"
        log_error "请手动查看: https://github.com/MetaCubeX/ClashX.Meta/releases"
        exit 1
    }
    IFS=$'\t' read -r remote_version url <<< "$release_info"

    if local_version=$(installed_version 2>/dev/null); then
        log_info "本地已安装版本: ${local_version}"
    else
        log_info "本地未安装 ClashX Meta"
    fi

    log_info "远程最新版本: ${remote_version:-unknown}"
    if [[ -z "$url" ]]; then
        log_error "GitHub release 未返回可下载的 macOS 安装包"
        log_error "请手动查看: https://github.com/MetaCubeX/ClashX.Meta/releases"
        exit 1
    fi

    if [[ -n "${local_version:-}" && -n "${remote_version:-}" ]]; then
        if ! version_gt "$remote_version" "$local_version"; then
            log_info "当前已是最新版本，无需下载。"
            return 0
        fi
    fi

    filename="$(basename "${url%%\?*}")"
    archive="$DOWNLOAD_DIR/$filename"

    log_info "下载地址: $url"
    if download_file "$url" "$archive"; then
        remove_helper
        install_app_from_archive "$archive"
    fi
    rm -f "$archive"

    log_info "启动 ClashX Meta..."
    open -a "$APP_NAME" || true
}

uninstall_app() {
    need_macos
    quit_app
    remove_helper

    if [[ -d "$APP_PATH" ]]; then
        log_info "删除 App: $APP_PATH"
        rm -rf "$APP_PATH" 2>/dev/null || sudo rm -rf "$APP_PATH"
    fi

    log_info "软件卸载完成，用户配置已保留。"
}

purge_app() {
    uninstall_app

    log_info "删除用户配置、缓存和日志..."
    rm -rf \
        "$HOME/Library/Application Support/${BUNDLE_ID}" \
        "$HOME/Library/WebKit/${BUNDLE_ID}" \
        "$HOME/Library/HTTPStorages/${BUNDLE_ID}" \
        "$HOME/Library/Caches/${BUNDLE_ID}" \
        "$HOME/Library/Caches/com.MetaCubeX.ClashX.meta" \
        "$HOME/Library/Preferences/${BUNDLE_ID}.plist" \
        "$HOME/Library/Logs/ClashX Meta" \
        "$HOME/.config/clash" \
        "$HOME/.config/clash.bak" 2>/dev/null || true

    log_info "完全卸载完成。"
}

main() {
    local command="install"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|update|uninstall|purge)
                command="$1"
                shift
                ;;
            --download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$command" in
        install|update) install_or_update ;;
        uninstall) uninstall_app ;;
        purge) purge_app ;;
    esac
}

main "$@"

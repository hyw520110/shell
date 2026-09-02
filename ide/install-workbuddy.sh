#!/bin/bash

set -euo pipefail

APP_NAME="WorkBuddy"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="/Applications"
UPDATE_API="https://www.codebuddy.cn/v2/update"

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64) echo "x64" ;;
        *) log_error "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
}

json_value() {
    local key="$1"
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

stat_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

validate_dmg() {
    local file="$1"
    local size

    [[ -f "$file" ]] || { log_error "下载文件不存在: $file"; return 1; }
    size=$(stat_size "$file")
    [[ "$size" -gt 10485760 ]] || { log_error "下载文件过小 ($size bytes)，可能是错误页"; return 1; }
    if file "$file" | grep -Eiq 'HTML|text|JSON|XML'; then
        log_error "下载结果不是 DMG 镜像: $(file "$file")"
        return 1
    fi
    hdiutil imageinfo "$file" >/dev/null 2>&1
}

download_file() {
    local url="$1"
    local target_dir="$2"
    local filename="$3"
    local sha256="$4"
    local target_file="$target_dir/$filename"

    mkdir -p "$target_dir"
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        ADL_SHA256="$sha256" adl "$url" "$target_dir" "$filename"
    else
        curl -fL --retry 3 --connect-timeout 10 --max-time 0 -o "$target_file" "$url"
        if [[ -n "$sha256" ]]; then
            local actual
            actual=$(shasum -a 256 "$target_file" | awk '{print $1}')
            [[ "$actual" == "$sha256" ]] || { log_error "SHA256 校验失败"; return 1; }
        fi
    fi
}

resolve_download() {
    local arch="$1"
    local platform="workbuddy-darwin-${arch}"
    local response url sha256

    response=$(curl -fsSL --connect-timeout 10 --max-time 30 "${UPDATE_API}?platform=${platform}")
    url=$(printf '%s' "$response" | json_value url)
    sha256=$(printf '%s' "$response" | json_value sha256hash)

    [[ -n "$url" ]] || { log_error "未从 WorkBuddy 更新接口获取到下载地址"; return 1; }
    url="${url%.zip}.dmg"
    printf '%s\n%s\n' "$url" "$sha256"
}

install_app_from_dmg() {
    local dmg_path="$1"
    local mount_output volume_path app_path

    log_info "挂载镜像: $dmg_path"
    mount_output=$(hdiutil attach "$dmg_path" -nobrowse -readonly)
    volume_path=$(printf '%s\n' "$mount_output" | grep -o "/Volumes/.*" | tail -1)
    [[ -n "$volume_path" && -d "$volume_path" ]] || { log_error "无法找到挂载卷"; return 1; }

    app_path=$(find "$volume_path" -maxdepth 1 \( -name "WorkBuddy.app" -o -name "*.app" \) | head -1)
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        hdiutil detach "$volume_path" >/dev/null 2>&1 || true
        log_error "未在镜像中找到 WorkBuddy.app"
        return 1
    fi

    log_info "复制 WorkBuddy.app 到 $INSTALL_DIR"
    rm -rf "$INSTALL_DIR/WorkBuddy.app" 2>/dev/null || true
    cp -R "$app_path" "$INSTALL_DIR/" 2>/dev/null || sudo cp -R "$app_path" "$INSTALL_DIR/"
    hdiutil detach "$volume_path" >/dev/null
}

main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        defaults read "$INSTALL_DIR/WorkBuddy.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
        exit 0
    fi

    local arch download_info url sha256 filename target_file
    arch=$(detect_arch)
    download_info=$(resolve_download "$arch")
    url=$(printf '%s\n' "$download_info" | sed -n '1p')
    sha256=$(printf '%s\n' "$download_info" | sed -n '2p')

    if [[ "${1:-}" == "--print-url" ]]; then
        printf '%s\n' "$url"
        exit 0
    fi

    filename="$(basename "$url")"
    target_file="$DOWNLOAD_DIR/$filename"

    log_info "准备下载 WorkBuddy: $url"
    if [[ ! -f "$target_file" ]] || ! validate_dmg "$target_file"; then
        rm -f "$target_file"
        download_file "$url" "$DOWNLOAD_DIR" "$filename" "$sha256"
    else
        log_info "已存在有效安装包，跳过下载"
    fi

    validate_dmg "$target_file"
    install_app_from_dmg "$target_file"
    [[ -d "$INSTALL_DIR/WorkBuddy.app" ]]
    log_info "WorkBuddy 安装完成"
}

main "$@"

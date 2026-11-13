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
    # 官方包为 .zip，接口 sha256hash 是其哈希。adl 下载后仍需校验（adl 不识别 ADL_SHA256 环境变量时）。
    # 统一在下载完成后用 shasum 校验，确保与接口哈希一致。
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$url" "$target_dir" "$filename"
    else
        curl -fL --retry 3 --connect-timeout 10 --max-time 0 -o "$target_file" "$url"
    fi
    # 下载后校验（zip 哈希，接口给定）
    if [[ -n "$sha256" && -s "$target_file" ]]; then
        local actual
        actual=$(shasum -a 256 "$target_file" | awk '{print $1}')
        [[ "$actual" == "$sha256" ]] || { log_error "SHA256 校验失败\n  期望: $sha256\n  实际: $actual"; rm -f "$target_file"; return 1; }
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
    # 官方包为 .zip（内含 WorkBuddy.app），接口 sha256hash 是 zip 的哈希；保留 zip URL 以便校验后解压
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

install_app_from_zip() {
    local zip_file="$1"
    local extract_dir="$DOWNLOAD_DIR/.wb_extract"

    log_info "解压安装包: $zip_file"
    rm -rf "$extract_dir" 2>/dev/null || true
    mkdir -p "$extract_dir"
    unzip -q -o "$zip_file" -d "$extract_dir" 2>/dev/null || { log_error "zip 解压失败"; return 1; }

    local extracted_app
    extracted_app=$(find "$extract_dir" -maxdepth 2 -iname 'WorkBuddy.app' -type d 2>/dev/null | head -1)
    if [[ -z "$extracted_app" || ! -d "$extracted_app" ]]; then
        log_error "zip 解压后未找到 WorkBuddy.app"
        rm -rf "$extract_dir" 2>/dev/null || true
        return 1
    fi

    log_info "安装包为目录形式（.app），直接复制"
    rm -rf "$INSTALL_DIR/WorkBuddy.app" 2>/dev/null || true
    cp -R "$extracted_app" "$INSTALL_DIR/" 2>/dev/null || sudo cp -R "$extracted_app" "$INSTALL_DIR/"
    rm -rf "$extract_dir" 2>/dev/null || true
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
    if [[ ! -f "$target_file" ]]; then
        download_file "$url" "$DOWNLOAD_DIR" "$filename" "$sha256"
    else
        log_info "已存在安装包，跳过下载: $filename"
    fi

    # 官方包是 .zip（接口 sha256hash 为其哈希）；zip 内直接是 WorkBuddy.app（无 dmg）。
    if [[ "$target_file" == *.zip ]]; then
        install_app_from_zip "$target_file"
    else
        validate_dmg "$target_file"
        install_app_from_dmg "$target_file"
    fi

    [[ -d "$INSTALL_DIR/WorkBuddy.app" ]] || { log_error "安装失败：/Applications/WorkBuddy.app 不存在"; exit 1; }
    if rm -f -- "$target_file"; then
        log_info "已删除安装包: $target_file"
    else
        log_info "安装成功，但安装包清理失败: $target_file"
    fi
    log_info "WorkBuddy 安装完成"
}

main "$@"

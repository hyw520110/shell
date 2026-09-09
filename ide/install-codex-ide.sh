#!/bin/bash

set -euo pipefail

APP_NAME="Codex"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="/Applications"
CODEX_ARM_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
CODEX_X64_URL="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"

log_info() { echo "[INFO] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

detect_url() {
    case "$(uname -m)" in
        arm64|aarch64) echo "$CODEX_ARM_URL" ;;
        x86_64) echo "$CODEX_X64_URL" ;;
        *) log_error "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
}

stat_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

validate_dmg() {
    local file="$1"
    local size

    [[ -f "$file" ]] || return 1
    size=$(stat_size "$file")
    [[ "$size" -gt 10485760 ]] || return 1
    if file "$file" | grep -Eiq 'HTML|text|JSON|XML'; then
        return 1
    fi
    hdiutil imageinfo "$file" >/dev/null 2>&1
}

download_file() {
    local url="$1"
    local filename="$2"
    mkdir -p "$DOWNLOAD_DIR"
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$url" "$DOWNLOAD_DIR" "$filename"
    else
        curl -fL --retry 3 --connect-timeout 10 --max-time 0 -o "$DOWNLOAD_DIR/$filename" "$url"
    fi
}

install_app_from_dmg() {
    local dmg_path="$1"
    local mount_output volume_path app_path

    log_info "挂载镜像: $dmg_path"
    mount_output=$(hdiutil attach "$dmg_path" -nobrowse -readonly)
    volume_path=$(printf '%s\n' "$mount_output" | grep -o "/Volumes/.*" | tail -1)
    [[ -n "$volume_path" && -d "$volume_path" ]] || { log_error "无法找到挂载卷"; return 1; }

    app_path=$(find "$volume_path" -maxdepth 1 \( -name "Codex.app" -o -name "OpenAI Codex.app" -o -name "*.app" \) | head -1)
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        hdiutil detach "$volume_path" >/dev/null 2>&1 || true
        log_error "未在镜像中找到 Codex 应用"
        return 1
    fi

    log_info "复制 $(basename "$app_path") 到 $INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$(basename "$app_path")" 2>/dev/null || true
    cp -R "$app_path" "$INSTALL_DIR/" 2>/dev/null || sudo cp -R "$app_path" "$INSTALL_DIR/"
    hdiutil detach "$volume_path" >/dev/null
}

main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        local app_path
        app_path=$(ls -d "$INSTALL_DIR/Codex.app" "$INSTALL_DIR/OpenAI Codex.app" 2>/dev/null | head -1)
        [[ -n "$app_path" ]] && defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
        exit 0
    fi

    local url filename target_file
    url=$(detect_url)
    if [[ "${1:-}" == "--print-url" ]]; then
        printf '%s\n' "$url"
        exit 0
    fi

    filename="$(basename "$url")"
    [[ "$filename" == "Codex.dmg" ]] || filename="Codex-${filename}"
    target_file="$DOWNLOAD_DIR/$filename"

    log_info "准备下载 OpenAI Codex IDE: $url"
    if [[ ! -f "$target_file" ]] || ! validate_dmg "$target_file"; then
        rm -f "$target_file"
        download_file "$url" "$filename"
    else
        log_info "已存在有效安装包，跳过下载"
    fi

    validate_dmg "$target_file"
    install_app_from_dmg "$target_file"
    ls -d "$INSTALL_DIR/Codex.app" "$INSTALL_DIR/OpenAI Codex.app" >/dev/null 2>&1
    if rm -f -- "$target_file"; then
        log_info "已删除安装包: $target_file"
    else
        log_info "安装成功，但安装包清理失败: $target_file"
    fi
    log_info "OpenAI Codex IDE 安装完成"
}

main "$@"

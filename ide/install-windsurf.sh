#!/bin/bash

# Windsurf/Devin Desktop 一键安装配置脚本
# Windsurf 已更名为 Devin Desktop，官方下载仍提供 Windsurf redirect API

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
APP_NAME="Windsurf/Devin Desktop"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="/Applications"
WINDSURF_DOWNLOAD_API="https://windsurf.com/api/windsurf/download-redirect"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

stat_size() {
    if stat -f%z "$1" >/dev/null 2>&1; then
        stat -f%z "$1"
    else
        stat -c%s "$1"
    fi
}

resolve_download_url() {
    local arch="$1"
    local build

    case "$arch" in
        arm64) build="darwin-arm64-dmg" ;;
        x64) build="darwin-x64-dmg" ;;
        *)
            log_error "不支持的系统架构: $(uname -m)"
            return 1
            ;;
    esac

    printf '%s?build=%s&isNext=false\n' "$WINDSURF_DOWNLOAD_API" "$build"
}

validate_dmg() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "下载文件不存在: $file"
        return 1
    fi

    local size
    size=$(stat_size "$file")
    if [ "$size" -lt 10485760 ]; then
        log_error "下载文件过小 ($size bytes)，很可能是 404/错误页: $file"
        return 1
    fi

    if file "$file" | grep -Eiq 'HTML|text|JSON|XML'; then
        log_error "下载结果不是 DMG 镜像: $(file "$file")"
        return 1
    fi

    if command -v hdiutil >/dev/null 2>&1; then
        hdiutil imageinfo "$file" >/dev/null 2>&1 && hdiutil verify "$file" >/dev/null 2>&1
    fi
}

download_file() {
    local url="$1"
    local target_dir="$2"
    local filename="$3"
    local target_file="$target_dir/$filename"

    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$url" "$target_dir" "$filename"
    else
        log_warn "未找到 adl，使用 curl 下载"
        curl -fL --retry 3 --connect-timeout 10 --max-time 0 -o "$target_file" "$url"
    fi
}

# 检测是否已安装
check_installed() {
    if [ -d "/Applications/Windsurf.app" ] || [ -d "/Applications/Devin.app" ] || [ -d "/Applications/Devin Desktop.app" ]; then
        return 0
    fi
    return 1
}

# 获取版本
get_version() {
    local app_path=""
    for candidate in "/Applications/Windsurf.app" "/Applications/Devin.app" "/Applications/Devin Desktop.app"; do
        if [ -d "$candidate" ]; then
            app_path="$candidate"
            break
        fi
    done

    if [ -n "$app_path" ]; then
        defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "已安装"
        return
    fi

    echo ""
}

# 下载 Windsurf
download_windsurf() {
    local arch=$(detect_arch)

    local download_url
    download_url=$(resolve_download_url "$arch")
    local download_file="Devin-darwin-${arch}.dmg"
    
    log_info "准备下载 Windsurf..."
    log_info "下载地址: $download_url"
    
    mkdir -p "$DOWNLOAD_DIR"
    local target_file="$DOWNLOAD_DIR/$download_file"
    
    if [ -f "$target_file" ]; then
        log_info "发现已存在的文件: $target_file"
        log_info "正在验证镜像完整性..."
        
        if hdiutil imageinfo "$target_file" &>/dev/null && hdiutil verify "$target_file" &>/dev/null; then
            log_info "文件验证通过，跳过下载"
            echo "$target_file"
            return 0
        else
            log_warn "文件损坏或校验失败，准备重新下载..."
            rm -f "$target_file"
        fi
    fi
    
    download_file "$download_url" "$DOWNLOAD_DIR" "$download_file"

    log_info "正在验证下载结果..."
    if ! validate_dmg "$target_file"; then
        rm -f "$target_file"
        log_error "Windsurf/Devin Desktop 下载失败或文件无效，请检查官方接口/网络后重试"
        return 1
    fi
    
    echo "$target_file"
}

# 安装 Windsurf
install_windsurf() {
    log_info "开始安装 Windsurf..."
    
    local dmg_path=$(download_windsurf)
    
    log_info "挂载镜像: $dmg_path"
    local mount_output
    mount_output=$(hdiutil attach "$dmg_path" -nobrowse -readonly)
    
    local volume_path
    volume_path=$(echo "$mount_output" | grep -o "/Volumes/.*" | tail -1)
    
    if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
        log_error "无法找到挂载卷"
        hdiutil detach "$dmg_path" 2>/dev/null || true
        return 1
    fi
    
    log_info "发现挂载卷: $volume_path"
    
    local app_in_volume
    app_in_volume=$(find "$volume_path" -maxdepth 1 \( -name "Windsurf.app" -o -name "Devin.app" -o -name "Devin Desktop.app" -o -name "*Devin*.app" -o -name "*.app" \) | head -1)
    if [ -n "$app_in_volume" ] && [ -d "$app_in_volume" ]; then
        log_info "正在复制 $APP_NAME 到 $INSTALL_DIR..."
        cp -R "$app_in_volume" "$INSTALL_DIR/"
    else
        log_error "未在镜像中找到 Windsurf/Devin Desktop 应用"
        hdiutil detach "$volume_path" 2>/dev/null || true
        return 1
    fi
    
    hdiutil detach "$volume_path"
    log_info "Windsurf/Devin Desktop 安装完成！"
}

# 主函数
main() {
    if [[ "$1" == "-v" || "$1" == "--version" ]]; then
        get_version
        exit 0
    fi

    local force_reinstall="${AI_HUB_FORCE_REINSTALL:-0}"
    if [[ "${1:-}" == "--force" || "${1:-}" == "--reinstall" ]]; then
        force_reinstall=1
    fi

    if [[ "$1" == "--print-url" ]]; then
        resolve_download_url "$(detect_arch)"
        exit 0
    fi

    if check_installed; then
        log_warn "Windsurf/Devin Desktop 已安装 (版本: $(get_version))"
        if [[ "$force_reinstall" != "1" ]]; then
            local reinstall=""
            if [[ "${AI_HUB_NON_INTERACTIVE:-0}" == "1" || ! -t 0 || ! -r /dev/tty ]]; then
                log_info "已安装，默认跳过重装；如需强制重装请设置 AI_HUB_FORCE_REINSTALL=1 或传入 --force。"
                exit 0
            fi
            printf "是否重新安装? (y/N): " > /dev/tty
            IFS= read -r reinstall < /dev/tty || reinstall=""
            if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
                log_info "已跳过重装"
                exit 0
            fi
        fi
        log_info "确认重装 Windsurf/Devin Desktop"
    fi

    install_windsurf
}

main "$@"

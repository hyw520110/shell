#!/bin/bash

# Trae 一键安装配置脚本 (字节跳动 AI IDE)
# Trae 是字节跳动推出的一款自适应 AI IDE

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
APP_NAME="Trae"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
INSTALL_DIR="/Applications"
TRAE_DOWNLOAD_API="https://icube-normal.trae.ai/icube/api/v1/native/version/trae/latest"
TRAE_DOWNLOAD_REGION="${TRAE_DOWNLOAD_REGION:-sg}"

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

python_bin() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif [ -x /usr/bin/python3 ]; then
        echo "/usr/bin/python3"
    else
        return 1
    fi
}

# 从 Trae 官网前端使用的官方 API 动态解析最新版 DMG。
resolve_download_url() {
    local arch="$1"
    local chip="apple"
    if [ "$arch" = "x64" ]; then
        chip="intel"
    fi

    local py
    py=$(python_bin) || {
        log_error "未找到 python3，无法解析 Trae 官方下载 JSON"
        return 1
    }

    "$py" - "$chip" "$TRAE_DOWNLOAD_REGION" "$TRAE_DOWNLOAD_API" <<'PY'
import json
import sys
import urllib.request

chip = sys.argv[1]
region = (sys.argv[2] or "sg").lower()
api = sys.argv[3]
if region == "us":
    region = "va"

request = urllib.request.Request(api, headers={"User-Agent": "ai-hub-installer/1.0"})
with urllib.request.urlopen(request, timeout=60) as response:
    payload = json.load(response)
downloads = (
    payload.get("data", {})
    .get("manifest", {})
    .get("darwin", {})
    .get("download", [])
)

preferred = None
for item in downloads:
    if (item.get("region") or "").lower() == region and item.get(chip):
        preferred = item
        break
if preferred is None:
    for item in downloads:
        if (item.get("region") or "").lower() == "sg" and item.get(chip):
            preferred = item
            break
if preferred is None:
    preferred = next((item for item in downloads if item.get(chip)), None)

if not preferred:
    raise SystemExit("Trae download URL not found in official manifest")

print(preferred[chip])
PY
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
    if [ -d "/Applications/Trae.app" ] || [ -d "/Applications/TRAE SOLO CN.app" ] || ls -d /Applications/*Trae*.app &>/dev/null || ls -d /Applications/*trae*.app &>/dev/null; then
        return 0
    fi
    return 1
}

# 获取版本
get_version() {
    local app_path=""
    if [ -d "/Applications/Trae.app" ]; then
        app_path="/Applications/Trae.app"
    elif [ -d "/Applications/TRAE SOLO CN.app" ]; then
        app_path="/Applications/TRAE SOLO CN.app"
    else
        app_path=$(ls -d /Applications/*Trae*.app 2>/dev/null | head -1)
        if [ -z "$app_path" ]; then
            app_path=$(ls -d /Applications/*trae*.app 2>/dev/null | head -1)
        fi
    fi

    if [ -n "$app_path" ] && [ -d "$app_path" ]; then
        defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "已安装"
    else
        echo ""
    fi
}

# 下载 Trae
download_trae() {
    local arch=$(detect_arch)

    if [ "$arch" = "unknown" ]; then
        log_error "不支持的系统架构: $(uname -m)"
        return 1
    fi

    local download_url
    download_url=$(resolve_download_url "$arch")
    local download_file="Trae-darwin-${arch}.dmg"
    
    log_info "准备下载 Trae..."
    log_info "下载地址: $download_url"
    
    mkdir -p "$DOWNLOAD_DIR"
    local target_file="$DOWNLOAD_DIR/$download_file"
    
    if [ -f "$target_file" ]; then
        log_info "发现已存在的文件: $target_file"
        log_info "正在验证镜像完整性..."
        
        # Trae 的 DMG 通常很大，校验结构和校验和
        if hdiutil imageinfo "$target_file" &>/dev/null && hdiutil verify "$target_file" &>/dev/null; then
            log_info "文件验证通过，跳过下载"
            echo "$target_file"
            return 0
        else
            log_warn "文件损坏或校验失败，准备处理..."
            rm -f "$target_file"
        fi
    fi
    
    download_file "$download_url" "$DOWNLOAD_DIR" "$download_file"

    log_info "正在验证下载结果..."
    if ! validate_dmg "$target_file"; then
        rm -f "$target_file"
        log_error "Trae 下载失败或文件无效，请检查官方接口/网络后重试"
        return 1
    fi
    
    echo "$target_file"
}

# 安装 Trae
install_trae() {
    log_info "开始安装 Trae..."
    
    local dmg_path=$(download_trae)
    
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
    
    local app_in_volume=$(find "$volume_path" -maxdepth 1 -name "Trae.app" | head -1)
    if [ -n "$app_in_volume" ] && [ -d "$app_in_volume" ]; then
        log_info "正在复制 $APP_NAME 到 $INSTALL_DIR..."
        cp -R "$app_in_volume" "$INSTALL_DIR/"
    else
        log_error "未在镜像中找到 Trae.app"
        hdiutil detach "$volume_path" 2>/dev/null || true
        return 1
    fi
    
    hdiutil detach "$volume_path"
    log_info "Trae 安装完成！"
}

# 主函数
main() {
    if [[ "$1" == "-v" || "$1" == "--version" ]]; then
        get_version
        exit 0
    fi

    if [[ "$1" == "--print-url" ]]; then
        resolve_download_url "$(detect_arch)"
        exit 0
    fi

    if check_installed; then
        log_warn "Trae 已安装 (版本: $(get_version))"
        read -p "是否重新安装? (y/N): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    install_trae
}

main "$@"

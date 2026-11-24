#!/usr/bin/env bash
# Marvis 马维斯 - 自动下载安装脚本
# 腾讯系统级 AI 助手
# 兼容 Bash 3.2+ (macOS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Marvis"
APP_PATH="/Applications/Marvis.app"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
HOMEPAGE_URL="https://marvis.qq.com"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
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

check_installed() {
    [ -d "$APP_PATH" ]
}

get_version() {
    if [ -d "$APP_PATH" ]; then
        defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 从官网解析 macOS 下载地址
# Marvis 官网提供直接下载重定向: https://marvis.qq.com/download/dmg
resolve_download_url() {
    local arch="$1"
    local url=""

    log_info "正在解析 Marvis 官方下载地址..."

    # 官方直接下载链接（自动重定向到 CDN）
    local official_url="https://marvis.qq.com/download/dmg"

    # 验证链接是否有效
    local http_code
    http_code=$(curl -sIL --connect-timeout 10 -o /dev/null -w "%{http_code}" "$official_url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        log_info "官方下载地址有效"
        echo "$official_url"
        return 0
    fi

    log_warn "官方下载链接不可用 (HTTP $http_code)"
    echo ""
    return 1
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
        hdiutil imageinfo "$file" >/dev/null 2>&1 || { log_error "DMG 镜像结构校验失败"; return 1; }
    fi
}

download_file() {
    local url="$1"
    local target_dir="$2"
    local filename="$3"
    local target_file="$target_dir/$filename"

    log_info "开始下载 Marvis 安装包..."
    log_info "下载地址: $url"

    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$url" "$target_dir" "$filename"
    else
        curl -fL --retry 3 --connect-timeout 10 --progress-bar -o "$target_file" "$url"
    fi
}

install_from_dmg() {
    local dmg_file="$1"

    log_info "挂载镜像: $(basename "$dmg_file")"
    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/marvis-mount.XXXXXX") || return 1
    local attach_rc=0
    hdiutil attach "$dmg_file" -nobrowse -readonly -mountpoint "$mp" >/dev/null 2>&1 || attach_rc=$?
    if [ "$attach_rc" -ne 0 ]; then
        log_error "DMG 挂载失败"
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi

    local app_in_volume
    app_in_volume=$(find "$mp" -maxdepth 1 -type d \( -iname "*marvis*.app" -o -iname "*马维斯*.app" \) 2>/dev/null | head -1)
    if [ -z "$app_in_volume" ] || [ ! -d "$app_in_volume" ]; then
        log_error "未在镜像中找到 Marvis.app"
        hdiutil detach "$mp" >/dev/null 2>&1 || true
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi

    # 先复制到临时目录，成功后再替换旧应用
    log_info "正在安装到 /Applications ..."
    local tmp_app="/Applications/.Marvis.app.new.$$"
    rm -rf "$tmp_app"
    if ! cp -R "$app_in_volume" "$tmp_app"; then
        rm -rf "$tmp_app" 2>/dev/null || true
        hdiutil detach "$mp" >/dev/null 2>&1 || true
        rmdir "$mp" 2>/dev/null || true
        log_error "复制应用失败"
        return 1
    fi
    hdiutil detach "$mp" >/dev/null 2>&1 || true
    rmdir "$mp" 2>/dev/null || true

    if [ -d "$APP_PATH" ]; then
        log_info "正在替换旧版本应用..."
        osascript -e 'quit app "Marvis"' >/dev/null 2>&1 || true
        sleep 1
        rm -rf "$APP_PATH"
    fi
    if ! mv "$tmp_app" "$APP_PATH"; then
        rm -rf "$tmp_app" 2>/dev/null || true
        log_error "替换应用失败"
        return 1
    fi

    rm -f -- "$dmg_file" && log_info "已清理安装包" || log_warn "安装成功，但安装包清理失败"

    local new_ver
    new_ver=$(get_version)
    log_info "🎉 Marvis 安装完成！当前版本: ${new_ver:-未知}"
}

open_download_page() {
    log_info "正在打开 Marvis 官网下载页面..."
    if command -v open >/dev/null 2>&1; then
        open "$HOMEPAGE_URL"
        log_info "已在浏览器中打开: $HOMEPAGE_URL"
    else
        log_warn "请手动访问: $HOMEPAGE_URL"
    fi
}

install_marvis() {
    local arch
    arch=$(detect_arch)

    if [ "$arch" = "unknown" ]; then
        log_error "不支持的系统架构: $(uname -m)"
        return 1
    fi

    # Marvis macOS 版仅支持 Apple Silicon (arm64)
    if [ "$arch" = "x64" ]; then
        log_error "Marvis macOS 版仅支持 Apple Silicon (M 系列芯片)"
        echo ""
        echo "  你的 Mac 是 Intel x86_64 架构，无法运行 Marvis。"
        echo "  官方要求: Apple M 系列芯片 (arm64)"
        echo ""
        echo "  官网说明: $HOMEPAGE_URL"
        echo ""
        # 清理可能错误安装的 arm64 版本
        if [ -d "$APP_PATH" ]; then
            log_warn "检测到错误安装的 arm64 版本，正在清理..."
            rm -rf "$APP_PATH" 2>/dev/null || true
        fi
        return 1
    fi

    mkdir -p "$DOWNLOAD_DIR" || return 1

    # 尝试自动解析下载地址
    local download_url
    download_url=$(resolve_download_url "$arch") || true

    if [ -z "$download_url" ]; then
        log_warn "无法自动解析下载地址"
        echo ""
        echo "  请按以下步骤手动下载安装:"
        echo "  1. 打开官网: $HOMEPAGE_URL"
        echo "  2. 下载 macOS 版本 DMG 文件"
        echo "  3. 将 DMG 文件放到: $DOWNLOAD_DIR/"
        echo "  4. 重新运行本脚本"
        echo ""
        open_download_page

        # 检查是否已有手动下载的 DMG
        local manual_dmg
        manual_dmg=$(find "$DOWNLOAD_DIR" -maxdepth 1 -name "*arvis*.dmg" -o -name "*马维斯*.dmg" 2>/dev/null | head -1)
        if [ -n "$manual_dmg" ] && [ -f "$manual_dmg" ]; then
            log_info "发现手动下载的安装包: $(basename "$manual_dmg")"
            install_from_dmg "$manual_dmg"
            return 0
        fi

        return 0
    fi

    local filename
    filename=$(basename "$download_url")
    [[ -n "$filename" ]] || filename="Marvis-latest-mac.dmg"
    local target_file="$DOWNLOAD_DIR/$filename"

    # 复用已有的安装包
    if [ -f "$target_file" ] && [ -f "$target_file.url" ] && [ "$(cat "$target_file.url")" = "$download_url" ]; then
        log_info "发现已存在的安装包: $filename"
        if validate_dmg "$target_file"; then
            log_info "安装包校验通过，跳过下载"
        else
            log_warn "安装包损坏，重新下载"
            rm -f "$target_file" "$target_file.url"
        fi
    fi

    if [ ! -f "$target_file" ]; then
        download_file "$download_url" "$DOWNLOAD_DIR" "$filename" || return 1
        if ! validate_dmg "$target_file"; then
            rm -f "$target_file"
            log_error "下载失败或文件无效，请检查网络后重试"
            return 1
        fi
        printf '%s\n' "$download_url" > "$target_file.url"
    fi

    install_from_dmg "$target_file"
}

usage() {
    echo '用法: install-marvis.sh [--yes] [--force] [--print-url] [-v|--version] [--help]'
    echo '  --yes        非交互：已安装且非最新时直接更新，不询问'
    echo '  --force      忽略版本比较，强制重装最新版'
    echo '  --print-url  仅打印当前架构的最新下载地址'
    echo '  -v/--version 打印已安装版本'
}

main() {
    case "${1:-}" in
        -v|--version)
            get_version
            exit 0
            ;;
        --print-url)
            local arch
            arch=$(detect_arch)
            [ "$arch" != "unknown" ] || { log_error "不支持的系统架构: $(uname -m)"; exit 1; }
            resolve_download_url "$arch"
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --yes|--force|"") ;;
        *)
            echo "未知参数: ${1:-}" >&2
            usage >&2
            exit 2
            ;;
    esac

    if [ "$(uname -s)" != "Darwin" ]; then
        log_error "当前脚本仅支持 macOS 自动安装（DMG 方式）"
        echo "Marvis 官网: $HOMEPAGE_URL"
        echo "Windows/Linux 请前往官网手动下载对应安装包，完成后回到 AI Hub 刷新状态。"
        return 3
    fi

    local arch
    arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then
        log_error "不支持的系统架构: $(uname -m)"
        return 1
    fi

    local force_reinstall=false
    case "${1:-}" in
        --force) force_reinstall=true ;;
    esac

    local installed_version=""
    if check_installed; then
        installed_version=$(get_version)
    fi

    if [ -n "$installed_version" ]; then
        log_info "当前已安装版本: $installed_version"
        if [ "$force_reinstall" = "true" ]; then
            log_info "按 --force 强制重装"
        else
            log_info "已是最新版本，如需重装请使用 --force"
            if [ "${1:-}" != "--yes" ]; then
                read -p "是否继续重装？(y/N): " answer
                case "$answer" in
                    y|Y) ;;
                    *) echo "已取消"; exit 0 ;;
                esac
            fi
        fi
    else
        log_info "未检测到已安装的 Marvis，开始安装"
    fi

    install_marvis
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

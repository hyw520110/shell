#!/usr/bin/env bash
# 豆包 (Doubao) 电脑版 - 自动下载安装脚本
# 通过豆包官网设置接口 (saman_update_address) 解析最新版 DMG，
# 按当前架构下载、校验并安装到 /Applications。兼容 Bash 3.2+ (macOS)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Doubao"
APP_PATH="/Applications/Doubao.app"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
# 豆包官网前端使用的官方版本清单接口（公开、无需登录）
SETTINGS_API="${DOUBAO_SETTINGS_API:-https://www.doubao.com/service/settings/v3/?device_platform=web&brand=doubao&aid=582478}"

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

python_bin() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif [ -x /usr/bin/python3 ]; then
        echo "/usr/bin/python3"
    else
        return 1
    fi
}

# 解析豆包官方最新版本与下载地址，输出 "version<TAB>url"
resolve_download_info() {
    local arch="$1"
    local py
    py=$(python_bin) || { log_error "未找到 python3，无法解析豆包官方下载 JSON"; return 1; }

    "$py" - "$arch" "$SETTINGS_API" <<'PY'
import json
import sys
import urllib.request

arch = sys.argv[1]
api = sys.argv[2]
request = urllib.request.Request(api, headers={"User-Agent": "ai-hub-installer/1.0"})
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
except Exception as exc:  # noqa: BLE001
    raise SystemExit("豆包官方设置接口请求失败: %s" % exc)

try:
    settings = payload["data"]["settings"]["saman_update_address"]
except (KeyError, TypeError):
    raise SystemExit("豆包官方设置接口未返回下载配置")

version = settings.get("version") or ""
if arch == "arm64":
    url = settings.get("mac_arm64_url") or settings.get("mac_universal_url") or ""
elif arch == "x64":
    url = settings.get("mac_x64_url") or settings.get("mac_universal_url") or ""
else:
    url = settings.get("mac_universal_url") or ""

if not url:
    raise SystemExit("未找到 macOS %s 架构的官方下载地址" % arch)
print(version + "\t" + url)
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
        hdiutil imageinfo "$file" >/dev/null 2>&1 || { log_error "DMG 镜像结构校验失败"; return 1; }
        # verify 较慢，仅警告不阻断
        hdiutil verify "$file" >/dev/null 2>&1 || log_warn "DMG 校验和未通过，继续尝试安装"
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

install_doubao() {
    local latest_version="$1"
    local url="$2"

    mkdir -p "$DOWNLOAD_DIR" || return 1
    local filename target_file
    filename=$(basename "$url")
    [[ -n "$filename" ]] || filename="Doubao-${latest_version:-latest}-darwin.dmg"
    target_file="$DOWNLOAD_DIR/$filename"

    # URL 随版本变化，仅复用相同来源的完整镜像
    if [ -f "$target_file" ] && [ -f "$target_file.url" ] && [ "$(cat "$target_file.url")" = "$url" ]; then
        log_info "发现已存在的安装包: $filename"
        if validate_dmg "$target_file"; then
            log_info "安装包校验通过，跳过下载"
        else
            log_warn "安装包损坏，重新下载"
            rm -f "$target_file" "$target_file.url"
        fi
    fi

    if [ ! -f "$target_file" ]; then
        log_info "开始下载豆包 ${latest_version:-最新版} ..."
        log_info "下载地址: $url"
        download_file "$url" "$DOWNLOAD_DIR" "$filename" || return 1
        if ! validate_dmg "$target_file"; then
            rm -f "$target_file"
            log_error "下载失败或文件无效，请检查网络后重试"
            return 1
        fi
        printf '%s\n' "$url" > "$target_file.url"
    fi

    log_info "挂载镜像: $filename"
    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/doubao-mount.XXXXXX") || return 1
    local attach_rc=0
    hdiutil attach "$target_file" -nobrowse -readonly -mountpoint "$mp" >/dev/null 2>&1 || attach_rc=$?
    if [ "$attach_rc" -ne 0 ]; then
        log_error "DMG 挂载失败"
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi

    local app_in_volume
    app_in_volume=$(find "$mp" -maxdepth 1 -type d \( -iname "*doubao*.app" -o -iname "*豆包*.app" \) 2>/dev/null | head -1)
    if [ -z "$app_in_volume" ] || [ ! -d "$app_in_volume" ]; then
        log_error "未在镜像中找到 Doubao.app / 豆包.app"
        hdiutil detach "$mp" >/dev/null 2>&1 || true
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi

    # 先复制到临时目录，成功后再替换旧应用，避免中途失败丢应用
    log_info "正在安装到 /Applications ..."
    local tmp_app="/Applications/.Doubao.app.new.$$"
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
        osascript -e 'quit app "Doubao"' >/dev/null 2>&1 || true
        sleep 1
        rm -rf "$APP_PATH"
    fi
    if ! mv "$tmp_app" "$APP_PATH"; then
        rm -rf "$tmp_app" 2>/dev/null || true
        log_error "替换应用失败"
        return 1
    fi

    rm -f -- "$target_file" "$target_file.url" && log_info "已清理安装包: $filename" || log_warn "安装成功，但安装包清理失败: $target_file"

    local new_ver
    new_ver=$(get_version)
    log_info "豆包安装完成！当前版本: ${new_ver:-${latest_version:-未知}}"
}

usage() {
    echo '用法: install-doubao.sh [--yes] [--force] [--print-url] [-v|--version] [--help]'
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
            resolve_download_info "$arch" | cut -f2
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
        echo "豆包电脑版官网: https://www.doubao.com/download/desktop"
        echo "Windows/Linux 请前往官网手动下载对应安装包，完成后回到 AI Hub 刷新状态。"
        return 3
    fi

    local arch
    arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then
        log_error "不支持的系统架构: $(uname -m)"
        return 1
    fi

    local info latest_version latest_url
    info=$(resolve_download_info "$arch") || return 1
    latest_version="${info%%$'\t'*}"
    latest_url="${info#*$'\t'}"
    [ -n "$latest_url" ] || { log_error "未能解析豆包下载地址"; return 1; }

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
        elif [ -n "$latest_version" ] && [ "$installed_version" = "$latest_version" ]; then
            log_info "已是最新版本 v${installed_version}，无需更新"
            exit 0
        else
            log_info "发现新版本: v${installed_version} → v${latest_version:-最新版}"
            if [ "${1:-}" != "--yes" ]; then
                if [ -t 0 ]; then
                    read -p "是否立即更新？(y/N): " answer
                    case "$answer" in
                        y|Y) ;;
                        *) echo "已取消更新"; exit 0 ;;
                    esac
                else
                    echo "非交互环境，跳过确认直接更新（或使用 --yes）" >&2
                fi
            fi
        fi
    else
        log_info "未检测到已安装的豆包，开始安装"
    fi

    install_doubao "$latest_version" "$latest_url"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

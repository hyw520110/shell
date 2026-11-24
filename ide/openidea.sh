#!/bin/bash
# OpenIDEA 一键安装/更新/卸载脚本（macOS）
# 官方: https://github.com/l0ng-ai/openidea (Apache 2.0)
# OpenIDEA 是 Rust 核心 + Tauri 的 IntelliJ IDEA 风格原生 IDE（非 JetBrains 官方）
#
# 用法:
#   ./openidea.sh              安装/更新到最新版
#   ./openidea.sh install      安装/更新到最新版
#   ./openidea.sh update       更新到最新版
#   ./openidea.sh status        查看安装状态与版本
#   ./openidea.sh uninstall     卸载
#   ./openidea.sh --print-url    打印最新版下载 URL
#   ./openidea.sh --version 0.1.50   安装指定版本
#
# 环境变量:
#   DOWNLOAD_DIR   下载目录 (默认 ~/Downloads)
#   KEEP_PACKAGE   1=安装成功后保留安装包 (默认 0=删除)
#   TRAE.../ADL    存在 adl 时优先多线程下载

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# === 公共安装函数（内联，自包含）===
log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_ok()    { echo "[OK]    $*" >&2; }

# 检测 adl（优先）
find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        echo "adl"; return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for p in "$script_dir/../network/tools/adl" "$script_dir/../../network/tools/adl" "$script_dir/../../../network/tools/adl"; do
        if [[ -x "$p" ]]; then echo "$p"; return 0; fi
    done
    return 1
}

# 下载文件（adl 优先，回退 curl）
download_file() {
    local url="$1" target_dir="$2" filename="$3"
    mkdir -p "$target_dir"
    local adl_cmd
    if adl_cmd=$(find_adl); then
        log_info "使用 adl 下载: $filename"
        if "$adl_cmd" "$url" "$target_dir" "$filename"; then
            return 0
        fi
        log_warn "adl 下载失败，回退 curl"
    fi
    curl -fL --retry 3 --connect-timeout 15 --max-time 1200 -o "$target_dir/$filename" "$url"
}

# 挂载 DMG 并返回卷路径
mount_dmg() {
    local dmg_path="$1"
    local mount_output
    # -noverify: 跳过校验和（大 dmg 校验慢易超时，WPS 教训）；检测挂载失败
    mount_output=$(hdiutil attach "$dmg_path" -nobrowse -readonly -noverify 2>/dev/null)
    [[ -n "$mount_output" ]] || { log_error "hdiutil attach 失败: $dmg_path"; return 1; }
    printf '%s\n' "$mount_output" | grep -o "/Volumes/.*" | tail -1
}

# 安全复制 .app 到 /Applications（带空值保护 + 精确匹配删除旧版）
# install_app_from_path <源app路径> <应用名>
install_app_from_path() {
    local src_app="$1" app_name="$2"
    [[ -n "$app_name" ]] || { log_error "应用名为空，拒绝安装"; return 1; }
    [[ "$app_name" == *.app ]] || app_name="$app_name.app"
    # 空值保护：禁止删除空/根/Applications 本身
    local target="/Applications/$app_name"
    [[ "$target" == "/Applications/"* ]] && [[ "$target" != "/Applications/" ]] || { log_error "非法目标路径: $target"; return 1; }
    if [[ -d "$target" ]]; then
        log_info "替换旧版本: $target"
        rm -rf "$target" 2>/dev/null || { log_warn "无法删除旧版（可能权限），尝试 sudo"; sudo rm -rf "$target" 2>/dev/null || true; }
    fi
    cp -R "$src_app" /Applications/ 2>/dev/null || sudo cp -R "$src_app" /Applications/
    [[ -d "$target" ]] || { log_error "复制失败: $target 不存在"; return 1; }
    return 0
}

# 从 DMG 安装 <dmg文件> <应用名或通配>
install_from_dmg() {
    local dmg_path="$1" app_glob="$2"
    [[ -f "$dmg_path" ]] || { log_error "DMG 不存在: $dmg_path"; return 1; }
    local vol
    vol=$(mount_dmg "$dmg_path")
    [[ -n "$vol" && -d "$vol" ]] || { log_error "挂载失败: $dmg_path"; return 1; }
    local app_path
    app_path=$(find "$vol" -maxdepth 1 -iname "$app_glob" -type d 2>/dev/null | head -1)
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        # 兜底：任意 .app
        app_path=$(find "$vol" -maxdepth 1 -iname "*.app" -type d 2>/dev/null | head -1)
    fi
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        hdiutil detach "$vol" -force -quiet 2>/dev/null || true
        log_error "未在 DMG 内找到 .app ($app_glob)"; return 1
    fi
    local app_name
    app_name=$(basename "$app_path")
    install_app_from_path "$app_path" "$app_name"
    hdiutil detach "$vol" -force -quiet 2>/dev/null || true
}

# 从 zip 安装（解压后找 .app）<zip文件> <应用名或通配>
install_from_zip() {
    local zip_path="$1" app_glob="$2"
    [[ -f "$zip_path" ]] || { log_error "zip 不存在: $zip_path"; return 1; }
    local extract_dir
    extract_dir=$(mktemp -d /tmp/app-extract.XXXXXX) || { log_error "mktemp 失败"; return 1; }
    unzip -q -o "$zip_path" -d "$extract_dir" 2>/dev/null || { log_error "解压失败: $zip_path"; rm -rf "$extract_dir"; return 1; }
    local app_path
    app_path=$(find "$extract_dir" -maxdepth 2 -iname "$app_glob" -type d 2>/dev/null | head -1)
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        app_path=$(find "$extract_dir" -maxdepth 2 -iname "*.app" -type d 2>/dev/null | head -1)
    fi
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        log_error "未在 zip 内找到 .app ($app_glob)"; rm -rf "$extract_dir"; return 1
    fi
    local app_name
    app_name=$(basename "$app_path")
    install_app_from_path "$app_path" "$app_name"
    rm -rf "$extract_dir" 2>/dev/null || true
}

# 主入口：install_app <名称> <URL> <包类型dmg|zip> [app_glob]
install_app() {
    local name="$1" url="$2" pkg_type="$3" app_glob="${4:-*.app}"
    local download_dir="${DOWNLOAD_DIR:-$HOME/Downloads}"
    local filename
    filename=$(basename "$url")
    filename="${filename%%\?*}"  # 去掉 query string
    local pkg_path="$download_dir/$filename"

    log_info "准备下载 $name: $url"
    if [[ ! -s "$pkg_path" ]]; then
        download_file "$url" "$download_dir" "$filename" || { log_error "下载失败: $name"; return 1; }
    else
        log_info "已存在安装包，跳过下载: $filename"
    fi

    [[ -s "$pkg_path" ]] || { log_error "下载后文件为空: $name"; return 1; }

    case "$pkg_type" in
        dmg) install_from_dmg "$pkg_path" "$app_glob" || return 1 ;;
        zip) install_from_zip "$pkg_path" "$app_glob" || return 1 ;;
        *) log_error "不支持的包类型: $pkg_type"; return 1 ;;
    esac

    # 安装成功后清理安装包
    if [[ "${KEEP_PACKAGE:-0}" != "1" ]]; then
        rm -f "$pkg_path" 2>/dev/null || true
        log_info "已清理安装包: $filename"
    fi
    log_ok "$name 安装完成"
    return 0
}
# === 公共安装函数结束 ===


APP_NAME="OpenIDEA"
APP_GLOB="OpenIDEA.app"
TARGET="/Applications/OpenIDEA.app"
REPO="l0ng-ai/openidea"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# 按系统架构选 mac 资产: Intel -> x64, Apple Silicon -> aarch64
detect_asset_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "aarch64" ;;
        x86_64)         echo "x64" ;;
        *)              echo "" ;;
    esac
}

# 从 GitHub release 资产里取指定版本的 mac dmg 下载 URL
# $1 = 版本号 (可省前缀 v), $2 = 资产架构
asset_url() {
    local ver="$1" arch="$2"
    ver="${ver#v}"
    local api="https://api.github.com/repos/$REPO/releases/tags/v$ver"
    local json
    json=$(curl -fsSL --max-time 25 -A "ai-hub-installer/1.0" "$api" 2>/dev/null) || return 1
    [[ -n "$json" ]] || return 1
    printf '%s' "$json" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
arch = sys.argv[1]
ver = sys.argv[2].lstrip("v")
want = "OpenIDEA_%s_%s.dmg" % (ver, arch)
assets = payload.get("assets", [])
for a in assets:
    if a["name"] == want:
        print(a["browser_download_url"])
        sys.exit(0)
sys.exit(3)
' "$arch" "$ver"
}

# 取最新版号 (releases/latest)
latest_version() {
    local json
    json=$(curl -fsSL --max-time 25 -A "ai-hub-installer/1.0" \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || return 1
    [[ -n "$json" ]] || return 1
    printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'
}

resolve_url() {
    local ver="${1:-}" arch
    arch=$(detect_asset_arch)
    [[ -n "$arch" ]] || { log_error "不支持的系统架构: $(uname -m)"; return 1; }
    [[ -n "$ver" ]] || { ver=$(latest_version) || { log_error "无法获取 OpenIDEA 最新版本号"; return 1; }; }
    log_info "目标版本: $ver ($arch)"
    asset_url "$ver" "$arch"
}

# 安全卸载: 变量非空 + 必须是 /Applications 下的 OpenIDEA.app
safe_rm_app() {
    local target="$1"
    [[ -n "$target" ]] || { log_error "目标路径为空，拒绝删除"; return 1; }
    [[ "$target" == "/Applications/"* ]] || { log_error "非法目标路径: $target"; return 1; }
    [[ "$(basename "$target")" == "OpenIDEA.app" ]] || { log_error "非预期 app 名: $target"; return 1; }
    rm -rf "$target" 2>/dev/null || sudo rm -rf "$target" 2>/dev/null || {
        log_error "删除失败（可能无权限）: $target"; return 1; }
}

do_uninstall() {
    if [[ ! -d "$TARGET" ]]; then
        log_info "$APP_NAME 未安装"
        return 0
    fi
    safe_rm_app "$TARGET" || return 1
    log_ok "已卸载 $APP_NAME"
}

do_status() {
    if [[ -d "$TARGET" ]]; then
        echo "安装状态: 已安装"
        local ver
        ver=$(defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
        echo "  版本: ${ver:-未知}"
        if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; then
            echo "  进程: 运行中"
        else
            echo "  进程: 未运行"
        fi
    else
        echo "安装状态: 未安装"
    fi
}

install_latest() {
    local ver="${1:-}" url arch
    url=$(resolve_url "$ver") || return 1
    log_info "下载地址: $url"

    # install_app 负责下载 (adl 优先) + dmg 挂载 + 原子替换 + 装后删包
    install_app "$APP_NAME" "$url" "dmg" "$APP_GLOB" || return 1

    log_info "启动 $APP_NAME..."
    open -a "$APP_NAME" 2>/dev/null || true
}

# 子命令分发
cmd="${1:-install}"
case "$cmd" in
    status|--status)            do_status; exit $? ;;
    uninstall|--uninstall)      do_uninstall; exit $? ;;
    --print-url)               resolve_url "${2:-}"; exit $? ;;
    --version)                 shift; install_latest "${1:-}"; exit $? ;;
    install|update|update-all)  install_latest; exit $? ;;
    -h|--help|help)
        sed -n '2,20p' "$0"; exit 0 ;;
    *)
        log_error "未知子命令: $cmd (支持 install/update/status/uninstall/--print-url/--version <ver>)"
        exit 1 ;;
esac

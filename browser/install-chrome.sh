#!/bin/bash
# install-chrome.sh - Google Chrome 安装/卸载/更新脚本
# 支持: macOS, Linux (Debian/Ubuntu, Fedora/RHEL)
# 功能: 安装、卸载、更新（已安装则自动检测最新版本并更新）
# 下载: 优先使用 adl 多线程断点续传
# 类型: 支持标准版 Chrome 和 Chrome for Testing

set -euo pipefail

# 颜色
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

info()    { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()    { printf "${BLUE}[STEP]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }

# macOS 稳定版下载地址（通用，官方始终提供最新版）
CHROME_MAC_DMG_URL="https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
# macOS Legacy 版本下载地址（兼容旧系统）
CHROME_MAC_LEGACY_10_11_URL="https://dl.google.com/dl/chrome/mac/legacy10_11/GGRO/googlechrome.dmg"  # macOS 10.11-10.12
CHROME_MAC_LEGACY_10_13_URL="https://dl.google.com/dl/chrome/mac/legacy10_13/GGRO/googlechrome.dmg"  # macOS 10.13-10.14
CHROME_MAC_LEGACY_10_15_URL="https://dl.google.com/dl/chrome/mac/legacy10_15/GGRO/googlechrome.dmg"  # macOS 10.15
# Linux 下载地址
CHROME_LINUX_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
CHROME_LINUX_RPM_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm"

# Chrome for Testing（官方并行发布通道，用于旧系统回退）
CFT_BASE_URL="https://storage.googleapis.com/chrome-for-testing-public"
CFT_INDEX_URL="https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json"
CFT_APP_PATH="/Applications/Google Chrome for Testing.app"

# 安装类型和版本控制
CHROME_TYPE="${CHROME_TYPE:-standard}"  # standard 或 testing
CFT_VERSION="${CFT_VERSION:-}"          # 指定Chrome for Testing版本，空则自动选择

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macOS" ;;
        Linux*)  echo "Linux" ;;
        *)       echo "Unknown" ;;
    esac
}

# 当前 macOS 版本（如 12.7.6），非 macOS 输出空
macos_version() {
    sw_vers -productVersion 2>/dev/null || echo ""
}

# $1 >= $2 时返回 0（按版本号比较，忽略同版本差异）
version_ge() {
    [[ -n "$1" && -n "$2" ]] || return 1
    [[ "$1" == "$2" ]] && return 0
    local lowest
    lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
    [[ "$lowest" == "$2" ]]
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "unknown" ;;
    esac
}

python_bin() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif [[ -x /usr/bin/python3 ]]; then
        echo "/usr/bin/python3"
    else
        return 1
    fi
}

# 查找 adl 下载工具
find_adl() {
    if command -v adl >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for p in \
        "$script_dir/adl" \
        "$script_dir/../network/tools/adl" \
        "$script_dir/../../network/tools/adl" \
        "/usr/local/bin/adl" \
        "/opt/homebrew/bin/adl"; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 通用下载函数：优先 adl 多线程断点续传
download_file() {
    local url="$1"
    local output="$2"
    local adl_bin=""
    adl_bin=$(find_adl 2>/dev/null || true)

    if [[ -n "$adl_bin" ]]; then
        info "检测到 adl，使用 adl 多线程断点续传下载..."
        local output_dir output_file
        output_dir=$(dirname "$output")
        output_file=$(basename "$output")
        mkdir -p "$output_dir"
        if "$adl_bin" "$url" "$output_dir" "$output_file"; then
            return 0
        fi
        warn "adl 下载失败，回退到 curl/wget..."
        rm -f "$output"
    fi

    if command -v curl >/dev/null 2>&1; then
        info "使用 curl 下载..."
        curl -fL --retry 3 --connect-timeout 30 -C - -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        info "使用 wget 下载..."
        wget -c --tries=3 --timeout=30 -O "$output" "$url"
    else
        error "需要 adl、curl 或 wget 来下载"
        return 1
    fi
}

chrome_app_path_macos() {
    local candidates=(
        "/Applications/Google Chrome.app"
        "$HOME/Applications/Google Chrome.app"
        "$CFT_APP_PATH"
        "$HOME/Applications/Google Chrome for Testing.app"
    )
    local p
    for p in "${candidates[@]}"; do
        if [[ -d "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    # 兜底查找
    p=$(ls -d /Applications/Google\ Chrome*.app 2>/dev/null | head -1 || true)
    if [[ -n "$p" && -d "$p" ]]; then
        echo "$p"
        return 0
    fi
    return 1
}

is_installed() {
    local os
    os=$(detect_os)
    case "$os" in
        macOS)
            chrome_app_path_macos >/dev/null 2>&1
            ;;
        Linux)
            command -v google-chrome >/dev/null 2>&1 || \
            command -v google-chrome-stable >/dev/null 2>&1 || \
            [[ -x /opt/google/chrome/google-chrome ]] || \
            [[ -f /usr/bin/google-chrome-stable ]]
            ;;
        *)
            return 1
            ;;
    esac
}

get_installed_version() {
    local os
    os=$(detect_os)
    case "$os" in
        macOS)
            local app_path
            app_path=$(chrome_app_path_macos 2>/dev/null || true)
            if [[ -n "$app_path" && -f "$app_path/Contents/Info.plist" ]]; then
                defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ""
            fi
            ;;
        Linux)
            if command -v google-chrome-stable >/dev/null 2>&1; then
                google-chrome-stable --version 2>/dev/null | awk '{print $NF}'
            elif command -v google-chrome >/dev/null 2>&1; then
                google-chrome --version 2>/dev/null | awk '{print $NF}'
            elif [[ -x /opt/google/chrome/google-chrome ]]; then
                /opt/google/chrome/google-chrome --version 2>/dev/null | awk '{print $NF}'
            fi
            ;;
    esac
}

# 获取 Chrome 稳定版最新版本号（优先 Google VersionHistory API）
get_latest_version() {
    local os platform
    os=$(detect_os)
    case "$os" in
        macOS) platform="mac" ;;
        Linux) platform="linux" ;;
        *)     platform="mac" ;;
    esac

    local version=""
    local api="https://versionhistory.googleapis.com/v1/chrome/platforms/${platform}/channels/stable/versions"

    local py
    if py=$(python_bin 2>/dev/null); then
        version=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api" 2>/dev/null | "$py" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    versions = data.get("versions") or []
    if versions:
        print(versions[0].get("version", ""))
except Exception:
    pass
' 2>/dev/null || true)
    fi

    # 回退：简单文本解析
    if [[ -z "$version" ]]; then
        version=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api" 2>/dev/null | \
            grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | head -1 | \
            sed -E 's/.*"([0-9.]+)".*/\1/' || true)
    fi

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    return 1
}

version_gt() {
    # return 0 if $1 > $2
    [[ "$1" == "$2" ]] && return 1
    local first
    first=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
    [[ "$first" == "$1" ]]
}

# 读取 app bundle 的版本与最低系统要求，输出 "版本<TAB>最低系统"
macos_app_info() {
    local app="$1"
    [[ -f "$app/Contents/Info.plist" ]] || return 1
    local ver min
    ver=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    min=$(defaults read "$app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    printf '%s\t%s\n' "${ver:-未知}" "${min:-未知}"
}

# Chrome for Testing 平台标识
cft_platform() {
    case "$(uname -m)" in
        arm64|aarch64) echo "mac-arm64" ;;
        *)             echo "mac-x64" ;;
    esac
}

# 用 HTTP Range 只读取远程 zip 内的 Info.plist，输出 "版本 最低系统"。
# 这样探测兼容性只需几十 KB，不必下载 200MB+ 的完整包。
cft_probe_zip() {
    local url="$1"
    local py
    py=$(python_bin 2>/dev/null) || return 1
    "$py" - "$url" <<'PY'
import sys, struct, plistlib, zlib
import urllib.request

url = sys.argv[1]

def head_size(u):
    req = urllib.request.Request(u, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])

def rng(u, start, end):
    req = urllib.request.Request(u, headers={"Range": "bytes=%d-%d" % (start, end)})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

size = head_size(url)
tail_len = min(size, 1 << 16)
tail = rng(url, size - tail_len, size - 1)
pos = tail.rfind(b"PK\x05\x06")
if pos < 0:
    sys.exit("EOCD not found")
eocd = tail[pos:pos + 22]
cd_size, cd_off = struct.unpack("<II", eocd[12:20])
cd = rng(url, cd_off, cd_off + cd_size - 1)

target = None
i = 0
while i + 46 <= len(cd):
    if cd[i:i + 4] != b"PK\x01\x02":
        break
    method, = struct.unpack("<H", cd[i + 10:i + 12])
    comp, _uncomp = struct.unpack("<II", cd[i + 20:i + 28])
    fnl, exl, cml = struct.unpack("<HHH", cd[i + 28:i + 34])
    lho, = struct.unpack("<I", cd[i + 42:i + 46])
    name = cd[i + 46:i + 46 + fnl].decode("utf-8", "replace")
    if name.endswith("Google Chrome for Testing.app/Contents/Info.plist"):
        target = (method, comp, lho)
        break
    i += 46 + fnl + exl + cml

if not target:
    sys.exit("Info.plist not found in zip")

method, comp, lho = target
hdr = rng(url, lho, lho + 29)
fnl, exl = struct.unpack("<HH", hdr[26:30])
data_off = lho + 30 + fnl + exl
raw = rng(url, data_off, data_off + comp - 1)
if method == 8:
    raw = zlib.decompress(raw, -15)
pl = plistlib.loads(raw)
print(pl.get("CFBundleShortVersionString", ""), pl.get("LSMinimumSystemVersion", ""))
PY
}

# 列出 CfT 索引中每个主版本的最新可下载版本（从新到旧），输出 "版本 url"
cft_candidates() {
    local platform py
    platform=$(cft_platform)
    py=$(python_bin 2>/dev/null) || return 1
    curl -fsSL --connect-timeout 15 --max-time 90 "$CFT_INDEX_URL" 2>/dev/null | \
        "$py" -c '
import json, sys
platform = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
best = {}
for v in data.get("versions", []):
    ver = v.get("version", "")
    if not ver:
        continue
    major = ver.split(".")[0]
    for x in v.get("downloads", {}).get("chrome", []):
        if x.get("platform") == platform:
            best[major] = (ver, x.get("url", ""))
            break
for major in sorted(best, key=int, reverse=True):
    ver, url = best[major]
    if url:
        print(ver, url)
' "$platform"
}

# 官方最新版（CfT 索引里最新主版本）要求的最低 macOS
cft_newest_min_os() {
    local candidates ver url out
    candidates=$(cft_candidates 2>/dev/null) || return 1
    [[ -n "$candidates" ]] || return 1
    while read -r ver url; do
        [[ -n "${ver:-}" && -n "${url:-}" ]] || continue
        out=$(cft_probe_zip "$url" 2>/dev/null || true)
        [[ -n "$out" ]] || return 1
        printf '%s\n' "$out" | awk '{print $2}'
        return 0
    done <<< "$candidates"
    return 1
}

# 从新到旧探测，找到最后一个兼容当前 macOS 的 CfT 版本，输出 "版本 url 最低系统"
cft_find_compatible_version() {
    local cur_mac candidates ver url out min_os
    cur_mac=$(macos_version)
    candidates=$(cft_candidates) || {
        error "获取 Chrome for Testing 版本索引失败"
        return 1
    }
    [[ -n "$candidates" ]] || {
        error "索引中没有适用于 $(cft_platform) 的版本"
        return 1
    }

    while read -r ver url; do
        [[ -n "${ver:-}" && -n "${url:-}" ]] || continue
        if ! out=$(cft_probe_zip "$url" 2>/dev/null); then
            warn "无法探测 ${ver} 的系统要求，跳过" >&2
            continue
        fi
        min_os=$(printf '%s\n' "$out" | awk '{print $2}')
        if [[ -z "$min_os" ]]; then
            warn "版本 ${ver} 缺少最低系统要求信息，跳过" >&2
            continue
        fi
        if version_ge "$cur_mac" "$min_os"; then
            printf '%s %s %s\n' "$ver" "$url" "$min_os"
            return 0
        fi
        info "  ${ver} 要求 macOS ${min_os}，高于当前 ${cur_mac}，继续向前查找" >&2
    done <<< "$candidates"
    return 1
}

# 原子替换安装 app bundle
install_app_atomic() {
    local src="$1"
    local dest="$2"
    local dir base staging backup
    dir=$(dirname "$dest")
    base=$(basename "$dest")
    staging="$dir/.${base}.staging.$$"
    backup="$dir/.${base}.backup.$$"
    rm -rf "$staging" "$backup"

    if command -v ditto >/dev/null 2>&1; then
        ditto "$src" "$staging" || return 1
    else
        cp -R "$src" "$staging" || return 1
    fi

    if [[ -d "$dest" ]]; then
        mv "$dest" "$backup" || return 1
    fi
    if ! mv "$staging" "$dest"; then
        [[ -d "$backup" ]] && mv "$backup" "$dest"
        rm -rf "$staging"
        return 1
    fi
    rm -rf "$backup"
    return 0
}

# 退出正在运行的 Chrome（官方版与 for Testing）
stop_chrome_processes() {
    local name
    for name in "Google Chrome" "Google Chrome for Testing"; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            warn "检测到 $name 正在运行，尝试退出..."
            osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
            sleep 2
            pkill -x "$name" >/dev/null 2>&1 || true
            sleep 1
        fi
    done
}

# 删除无法在当前系统启动的官方 Chrome（仅在确认不兼容时）
remove_incompatible_official_app() {
    local app="/Applications/Google Chrome.app"
    [[ -d "$app" ]] || return 0
    local info min_os cur_mac
    info=$(macos_app_info "$app") || return 0
    min_os=$(printf '%s\n' "$info" | cut -f2)
    cur_mac=$(macos_version)
    [[ "$min_os" != "未知" ]] || return 0
    version_ge "$cur_mac" "$min_os" && return 0

    warn "官方 Chrome 要求 macOS ${min_os}，当前 macOS ${cur_mac}，无法启动"
    if confirm_action "移除无法启动的 ${app}?"; then
        rm -rf "$app" && success "已移除不兼容的官方 Chrome"
    else
        warn "保留 ${app}（该应用无法在当前系统启动）"
    fi
    return 0
}

# 官方版不兼容时，回退安装最后一个兼容当前系统的 Chrome for Testing
install_cft_macos() {
    local cur_mac platform picked ver url min_os installed_cft
    cur_mac=$(macos_version)
    platform=$(cft_platform)

    step "查找兼容 macOS ${cur_mac} 的 Chrome for Testing 版本..."
    if ! picked=$(cft_find_compatible_version); then
        error "未能找到兼容 macOS ${cur_mac} 的 Chrome 版本"
        error "可升级 macOS 后重试"
        return 1
    fi
    ver=$(printf '%s\n' "$picked" | awk '{print $1}')
    url=$(printf '%s\n' "$picked" | awk '{print $2}')
    min_os=$(printf '%s\n' "$picked" | awk '{print $3}')
    info "兼容版本: Chrome for Testing ${ver}（要求 macOS ${min_os}，当前 macOS ${cur_mac}）"

    if [[ -d "$CFT_APP_PATH" ]]; then
        installed_cft=$(defaults read "$CFT_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
        info "已安装 Chrome for Testing: ${installed_cft:-未知版本}"
        if [[ -n "$installed_cft" && "$installed_cft" == "$ver" && "${FORCE:-false}" != "true" ]]; then
            success "已安装兼容版本，无需更新"
            remove_incompatible_official_app
            return 0
        fi
    fi

    local tmp_zip="/tmp/chrome-cft-$$.zip"
    local workdir="/tmp/chrome-cft-$$"
    step "下载 Chrome for Testing ${ver}..."
    info "下载地址: ${url}"
    download_file "$url" "$tmp_zip" || {
        rm -f "$tmp_zip"
        return 1
    }
    if [[ ! -s "$tmp_zip" ]]; then
        error "下载文件为空"
        rm -f "$tmp_zip"
        return 1
    fi

    step "解压..."
    rm -rf "$workdir"
    mkdir -p "$workdir"
    if ! unzip -q -o "$tmp_zip" -d "$workdir"; then
        error "解压失败"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    local src_app="$workdir/$platform/Google Chrome for Testing.app"
    if [[ ! -d "$src_app" ]]; then
        src_app=$(find "$workdir" -maxdepth 2 -type d -name "Google Chrome for Testing.app" | head -1 || true)
    fi
    if [[ -z "$src_app" || ! -d "$src_app" ]]; then
        error "解压后未找到 Google Chrome for Testing.app"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    # 用实际解压出的 bundle 再校验一次，避免探测结果与实体不一致
    local real_ver real_min
    real_ver=$(defaults read "$src_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    real_min=$(defaults read "$src_app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    if [[ -n "$real_min" ]] && ! version_ge "$cur_mac" "$real_min"; then
        error "下载的 ${real_ver:-$ver} 要求 macOS ${real_min}，当前 macOS ${cur_mac}，已中止"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    stop_chrome_processes

    step "安装到 ${CFT_APP_PATH}..."
    if ! install_app_atomic "$src_app" "$CFT_APP_PATH"; then
        error "安装失败"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi
    rm -rf "$workdir" "$tmp_zip"

    remove_incompatible_official_app

    local new_ver
    new_ver=$(defaults read "$CFT_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    success "Chrome for Testing 安装完成${new_ver:+ (版本: ${new_ver})}"
    info "启动命令: open -a \"Google Chrome for Testing\""
    return 0
}

# 安装指定版本的 Chrome for Testing
install_cft_macos_specific() {
    local target_version="$1"
    local cur_mac platform url installed_cft
    cur_mac=$(macos_version)
    platform=$(cft_platform)

    step "查找 Chrome for Testing ${target_version}..."
    
    # 从索引中查找指定版本
    local candidates ver found_url
    candidates=$(cft_candidates) || {
        error "获取 Chrome for Testing 版本索引失败"
        return 1
    }
    
    while read -r ver url; do
        [[ -n "${ver:-}" && -n "${url:-}" ]] || continue
        if [[ "$ver" == "$target_version" ]]; then
            found_url="$url"
            break
        fi
    done <<< "$candidates"
    
    if [[ -z "$found_url" ]]; then
        error "未找到 Chrome for Testing ${target_version}"
        return 1
    fi
    
    info "找到版本: ${target_version}"
    info "下载地址: ${found_url}"

    if [[ -d "$CFT_APP_PATH" ]]; then
        installed_cft=$(defaults read "$CFT_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
        info "已安装 Chrome for Testing: ${installed_cft:-未知版本}"
        if [[ -n "$installed_cft" && "$installed_cft" == "$target_version" && "${FORCE:-false}" != "true" ]]; then
            success "已安装指定版本，无需更新"
            return 0
        fi
    fi

    local tmp_zip="/tmp/chrome-cft-$$.zip"
    local workdir="/tmp/chrome-cft-$$"
    step "下载 Chrome for Testing ${target_version}..."
    download_file "$found_url" "$tmp_zip" || {
        rm -f "$tmp_zip"
        return 1
    }
    if [[ ! -s "$tmp_zip" ]]; then
        error "下载文件为空"
        rm -f "$tmp_zip"
        return 1
    fi

    step "解压..."
    rm -rf "$workdir"
    mkdir -p "$workdir"
    if ! unzip -q -o "$tmp_zip" -d "$workdir"; then
        error "解压失败"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    local src_app="$workdir/$platform/Google Chrome for Testing.app"
    if [[ ! -d "$src_app" ]]; then
        src_app=$(find "$workdir" -maxdepth 2 -type d -name "Google Chrome for Testing.app" | head -1 || true)
    fi
    if [[ -z "$src_app" || ! -d "$src_app" ]]; then
        error "解压后未找到 Google Chrome for Testing.app"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    # 校验版本和系统兼容性
    local real_ver real_min
    real_ver=$(defaults read "$src_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    real_min=$(defaults read "$src_app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    
    if [[ "$real_ver" != "$target_version" ]]; then
        warn "下载的版本 (${real_ver}) 与指定版本 (${target_version}) 不匹配"
    fi
    
    if [[ -n "$real_min" ]] && ! version_ge "$cur_mac" "$real_min"; then
        error "版本 ${real_ver} 要求 macOS ${real_min}，当前 macOS ${cur_mac}，无法安装"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi

    stop_chrome_processes

    step "安装到 ${CFT_APP_PATH}..."
    if ! install_app_atomic "$src_app" "$CFT_APP_PATH"; then
        error "安装失败"
        rm -rf "$workdir" "$tmp_zip"
        return 1
    fi
    rm -rf "$workdir" "$tmp_zip"

    local new_ver
    new_ver=$(defaults read "$CFT_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    success "Chrome for Testing ${target_version} 安装完成${new_ver:+ (实际版本: ${new_ver})}"
    info "启动命令: open -a \"Google Chrome for Testing\""
    return 0
}

# 查找兼容当前系统的标准版版本
find_compatible_standard_version() {
    local cur_mac="$1"
    local py candidates ver url out min_os
    
    py=$(python_bin 2>/dev/null) || return 1
    
    # 使用 Google 版本历史 API 获取历史版本
    local api="https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions"
    
    step "获取 Chrome 标准版历史版本列表..."
    local version_list
    version_list=$(curl -fsSL --connect-timeout 15 --max-time 30 "$api" 2>/dev/null | "$py" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    versions = data.get("versions", [])
    for v in versions:
        print(v.get("version", ""))
except Exception:
    pass
' 2>/dev/null || true)
    
    if [[ -z "$version_list" ]]; then
        warn "无法获取标准版历史版本列表"
        return 1
    fi
    
    # 从新到旧查找兼容版本
    while IFS= read -r ver; do
        [[ -n "$ver" ]] || continue
        
        # 跳过太旧的版本（不包含完整的版本号）
        [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        
        info "  检查标准版 ${ver}..."
        
        # 下载对应版本的 DMG 并检查兼容性
        local dmg_url="https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
        # 标准版 DMG 无法指定版本，我们只能通过其他方式探测
        
        # 由于标准版 DMG 不支持版本指定，我们使用另一种方法：
        # 下载最新 DMG，检查兼容性，如果不兼容则回退到 Chrome for Testing
        break
    done <<< "$version_list"
    
    # 由于标准版无法直接获取历史版本 DMG，返回空让用户使用 Chrome for Testing
    return 1
}

# 安装指定版本的标准版 Chrome
install_standard_version() {
    local target_version="$1"
    local cur_mac installed
    
    cur_mac=$(macos_version)
    
    step "准备安装标准版 Chrome ${target_version}..."
    
    # 检查是否已安装
    if [[ -d "/Applications/Google Chrome.app" ]]; then
        installed=$(defaults read "/Applications/Google Chrome.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
        info "已安装标准版 Chrome: ${installed:-未知版本}"
        if [[ -n "$installed" && "$installed" == "$target_version" && "${FORCE:-false}" != "true" ]]; then
            success "已安装指定版本，无需更新"
            return 0
        fi
    fi
    
    # 由于标准版 DMG 不支持版本指定，我们直接下载最新 DMG
    local tmp_dmg="/tmp/googlechrome.dmg"
    local mount_point=""
    
    step "下载 Google Chrome DMG..."
    info "下载地址: $CHROME_MAC_DMG_URL"
    download_file "$CHROME_MAC_DMG_URL" "$tmp_dmg" || {
        rm -f "$tmp_dmg"
        return 1
    }
    
    if [[ ! -s "$tmp_dmg" ]]; then
        error "下载文件为空"
        rm -f "$tmp_dmg"
        return 1
    fi
    
    step "挂载 DMG..."
    local attach_out
    attach_out=$(hdiutil attach "$tmp_dmg" -nobrowse -readonly 2>&1) || {
        error "挂载 DMG 失败"
        rm -f "$tmp_dmg"
        return 1
    }
    mount_point=$(echo "$attach_out" | grep -o '/Volumes/[^"]*' | tail -1)
    if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
        mount_point="/Volumes/Google Chrome"
    fi
    
    local src_app=""
    if [[ -d "$mount_point/Google Chrome.app" ]]; then
        src_app="$mount_point/Google Chrome.app"
    else
        src_app=$(find "$mount_point" -maxdepth 1 -type d -name "*.app" | head -1 || true)
    fi
    if [[ -z "$src_app" || ! -d "$src_app" ]]; then
        error "在挂载卷中未找到 Google Chrome.app"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi
    
    # 检查 DMG 内版本的兼容性
    local src_ver src_min
    src_ver=$(defaults read "$src_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    src_min=$(defaults read "$src_app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    
    if [[ -n "$src_min" ]] && ! version_ge "$cur_mac" "$src_min"; then
        error "DMG 内版本 ${src_ver} 要求 macOS ${src_min}，当前 macOS ${cur_mac}，无法安装"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        # 自动回退到兼容的标准版 legacy 版本
        if [[ "${CHROME_NO_FALLBACK:-0}" != "1" ]]; then
            warn "官方稳定版已不支持当前系统，自动回退到最后一个兼容标准版..."
            local legacy_url=""
            if version_ge "$cur_mac" "10.15"; then
                legacy_url="$CHROME_MAC_LEGACY_10_15_URL"
            elif version_ge "$cur_mac" "10.13"; then
                legacy_url="$CHROME_MAC_LEGACY_10_13_URL"
            elif version_ge "$cur_mac" "10.11"; then
                legacy_url="$CHROME_MAC_LEGACY_10_11_URL"
            fi
            if [[ -n "$legacy_url" ]]; then
                info "使用兼容标准版: $legacy_url"
                if install_legacy_standard "$legacy_url"; then
                    return 0
                fi
            fi
            error "未能找到兼容 macOS ${cur_mac} 的 Chrome 标准版版本"
            error "可升级 macOS 后重试"
        fi
        return 1
    fi
    
    if [[ "$src_ver" != "$target_version" ]]; then
        warn "DMG 内版本 (${src_ver}) 与目标版本 (${target_version}) 不匹配"
        info "DMG 始终提供最新版本，将安装 ${src_ver}"
    fi
    
    stop_chrome_processes
    
    step "安装到 /Applications..."
    if ! install_app_atomic "$src_app" "/Applications/Google Chrome.app"; then
        error "安装失败"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi
    
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    rm -f "$tmp_dmg"
    
    local new_ver
    new_ver=$(get_installed_version)
    success "标准版 Chrome 安装完成${new_ver:+ (版本: $new_ver)}"
    return 0
}

# 安装 legacy 标准版 Chrome
install_legacy_standard() {
    local legacy_url="$1"
    local cur_mac installed src_ver src_min
    
    cur_mac=$(macos_version)
    
    step "下载兼容的标准版 legacy Chrome..."
    info "下载地址: $legacy_url"
    
    local tmp_dmg="/tmp/googlechrome-legacy.dmg"
    download_file "$legacy_url" "$tmp_dmg" || {
        rm -f "$tmp_dmg"
        return 1
    }
    
    if [[ ! -s "$tmp_dmg" ]]; then
        error "下载文件为空"
        rm -f "$tmp_dmg"
        return 1
    fi
    
    step "挂载 DMG..."
    local attach_out
    attach_out=$(hdiutil attach "$tmp_dmg" -nobrowse -readonly 2>&1) || {
        error "挂载 DMG 失败"
        rm -f "$tmp_dmg"
        return 1
    }
    local mount_point
    mount_point=$(echo "$attach_out" | grep -o '/Volumes/[^"]*' | tail -1)
    if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
        mount_point="/Volumes/Google Chrome"
    fi
    
    local src_app=""
    if [[ -d "$mount_point/Google Chrome.app" ]]; then
        src_app="$mount_point/Google Chrome.app"
    else
        src_app=$(find "$mount_point" -maxdepth 1 -type d -name "*.app" | head -1 || true)
    fi
    if [[ -z "$src_app" || ! -d "$src_app" ]]; then
        error "在挂载卷中未找到 Google Chrome.app"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi
    
    # 检查 DMG 内版本的兼容性
    src_ver=$(defaults read "$src_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    src_min=$(defaults read "$src_app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    
    info "Legacy 版本: ${src_ver}（要求 macOS ${src_min}）"
    
    if [[ -n "$src_min" ]] && ! version_ge "$cur_mac" "$src_min"; then
        error "Legacy 版本 ${src_ver} 要求 macOS ${src_min}，当前 macOS ${cur_mac}，仍然不兼容"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        info "将回退到 Chrome for Testing"
        install_cft_macos
        return $?
    fi
    
    # 检查是否已安装相同版本
    if [[ -d "/Applications/Google Chrome.app" ]]; then
        installed=$(defaults read "/Applications/Google Chrome.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
        if [[ -n "$installed" && "$installed" == "$src_ver" && "${FORCE:-false}" != "true" ]]; then
            success "已安装兼容版本 ${src_ver}，无需更新"
            hdiutil detach "$mount_point" >/dev/null 2>&1 || true
            rm -f "$tmp_dmg"
            return 0
        fi
    fi
    
    stop_chrome_processes
    
    step "安装到 /Applications..."
    if ! install_app_atomic "$src_app" "/Applications/Google Chrome.app"; then
        error "安装失败"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi
    
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    rm -f "$tmp_dmg"
    
    local new_ver
    new_ver=$(get_installed_version)
    success "标准版 Chrome (Legacy) 安装完成${new_ver:+ (版本: $new_ver)}"
    info "注意: 这是 legacy 版本，不再自动更新，可能存在安全风险"
    return 0
}

confirm_action() {
    local prompt="$1"
    local ans=""
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    read -r -p "$prompt [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

install_macos() {
    local force="${1:-false}"
    local app_path installed latest

    # 根据 CHROME_TYPE 决定安装策略
    if [[ "$CHROME_TYPE" == "testing" ]]; then
        info "安装类型: Chrome for Testing"
        if [[ -n "$CFT_VERSION" ]]; then
            info "指定版本: $CFT_VERSION"
            install_cft_macos_specific "$CFT_VERSION"
        else
            install_cft_macos
        fi
        return $?
    fi

    # 标准版安装逻辑
    info "安装类型: 标准版 Google Chrome"

    # 首先检查系统兼容性，如果不兼容直接尝试 legacy 版本
    local cur_mac newest_min
    cur_mac=$(macos_version)
    newest_min=$(cft_newest_min_os 2>/dev/null || true)
    
    if [[ -n "$newest_min" ]] && ! version_ge "$cur_mac" "$newest_min" && "${FORCE:-false}" != "true" && "${CHROME_NO_FALLBACK:-0}" != "1" ]]; then
        info "官方最新版要求 macOS ${newest_min}，当前 macOS ${cur_mac}"
        info "跳过最新版，直接尝试下载兼容的标准版 legacy 版本..."
        
        # 根据系统版本选择合适的 legacy 下载链接
        local legacy_url=""
        if version_ge "$cur_mac" "10.15"; then
            legacy_url="$CHROME_MAC_LEGACY_10_15_URL"
            info "使用 macOS 10.15+ legacy 版本"
        elif version_ge "$cur_mac" "10.13"; then
            legacy_url="$CHROME_MAC_LEGACY_10_13_URL"
            info "使用 macOS 10.13-10.14 legacy 版本"
        elif version_ge "$cur_mac" "10.11"; then
            legacy_url="$CHROME_MAC_LEGACY_10_11_URL"
            info "使用 macOS 10.11-10.12 legacy 版本"
        else
            warn "系统版本过低 (${cur_mac})，无法找到兼容的标准版"
            info "将使用 Chrome for Testing 作为替代"
            if confirm_action "是否继续安装 Chrome for Testing?"; then
                install_cft_macos
                return $?
            else
                error "用户取消安装"
                return 1
            fi
        fi
        
        if [[ -n "$legacy_url" ]]; then
            if install_legacy_standard "$legacy_url"; then
                return 0
            else
                warn "Legacy 标准版安装失败，将回退到 Chrome for Testing"
                install_cft_macos
                return $?
            fi
        fi
    fi

    # 已装 Chrome for Testing 且官方最新版仍要求更高 macOS 时，直接走 CfT 流程，
    # 避免每次更新都白下载 276 MB 官方 DMG。
    if [[ ! -d "/Applications/Google Chrome.app" && -d "$CFT_APP_PATH" ]]; then
        if [[ -n "$newest_min" ]] && ! version_ge "$cur_mac" "$newest_min"; then
            info "官方最新版要求 macOS ${newest_min}，当前 macOS ${cur_mac}，继续使用 Chrome for Testing"
            install_cft_macos
            return $?
        fi
    fi

    if is_installed; then
        installed=$(get_installed_version)
        info "检测到已安装 Google Chrome: ${installed:-未知版本}"
        latest=$(get_latest_version 2>/dev/null || true)
        if [[ -n "$latest" ]]; then
            info "官方稳定版最新发布号: $latest"
            if [[ -n "$installed" && "$installed" == "$latest" && "$force" != "true" ]]; then
                success "已是最新版本，无需更新"
                return 0
            fi
            if [[ -n "$installed" ]]; then
                info "已安装 ${installed}，将检查官方 DMG 是否提供更新版本"
            fi
        else
            warn "无法获取最新版本号，将直接下载安装官方稳定版"
        fi
    else
        latest=$(get_latest_version 2>/dev/null || true)
        [[ -n "$latest" ]] && info "官方稳定版最新发布号: $latest"
    fi

    local tmp_dmg="/tmp/googlechrome.dmg"
    local mount_point=""

    step "下载 Google Chrome..."
    info "下载地址: $CHROME_MAC_DMG_URL"
    download_file "$CHROME_MAC_DMG_URL" "$tmp_dmg" || {
        error "下载失败"
        rm -f "$tmp_dmg"
        return 1
    }

    # 简单校验 DMG
    if [[ ! -s "$tmp_dmg" ]]; then
        error "下载文件为空"
        rm -f "$tmp_dmg"
        return 1
    fi
    if command -v hdiutil >/dev/null 2>&1; then
        if ! hdiutil imageinfo "$tmp_dmg" >/dev/null 2>&1; then
            error "下载文件不是有效的 DMG 镜像"
            rm -f "$tmp_dmg"
            return 1
        fi
    fi

    step "挂载 DMG..."
    local attach_out
    attach_out=$(hdiutil attach "$tmp_dmg" -nobrowse -readonly 2>&1) || {
        error "挂载 DMG 失败"
        rm -f "$tmp_dmg"
        return 1
    }
    mount_point=$(echo "$attach_out" | grep -o '/Volumes/[^"]*' | tail -1)
    if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
        mount_point="/Volumes/Google Chrome"
    fi

    local src_app=""
    if [[ -d "$mount_point/Google Chrome.app" ]]; then
        src_app="$mount_point/Google Chrome.app"
    else
        src_app=$(find "$mount_point" -maxdepth 1 -type d -name "*.app" | head -1 || true)
    fi
    if [[ -z "$src_app" || ! -d "$src_app" ]]; then
        error "在挂载卷中未找到 Google Chrome.app"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi

    # 读取 DMG 内的真实版本与最低系统要求
    local src_ver="" src_min=""
    src_ver=$(defaults read "$src_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    src_min=$(defaults read "$src_app/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)

    # 系统兼容性校验放在版本比对之前：已装的旧版即使与 DMG 同版本，
    # 只要它在本机无法启动，就必须走回退流程。
    if [[ -n "$src_min" ]]; then
        local cur_mac
        cur_mac=$(macos_version)
        if [[ -n "$cur_mac" ]] && ! version_ge "$cur_mac" "$src_min"; then
            error "官方 DMG 为 Chrome ${src_ver:-未知版本}，要求 macOS ${src_min} 或更高"
            error "当前系统为 macOS ${cur_mac}，安装后无法启动（Chrome 会因缺少新系统符号崩溃）"
            if [[ "${CHROME_ALLOW_INCOMPATIBLE:-0}" == "1" ]]; then
                warn "已设置 CHROME_ALLOW_INCOMPATIBLE=1，继续安装（可能无法启动）"
            else
                hdiutil detach "$mount_point" >/dev/null 2>&1 || true
                rm -f "$tmp_dmg"
                if [[ "${CHROME_NO_FALLBACK:-0}" == "1" ]]; then
                    warn "已禁用自动回退 (CHROME_NO_FALLBACK=1)，未做任何变更"
                    return 1
                fi
                warn "官方稳定版已不支持当前系统，自动回退到最后一个兼容版本"
                install_cft_macos
                return $?
            fi
        fi
    fi

    # DMG 才是本次实际可安装的版本；与已安装版本相同则无需替换，
    # 避免 API 发布号领先 DMG 时反复“更新”却版本不变。
    if [[ -n "$installed" && -n "$src_ver" && "$installed" == "$src_ver" && "$force" != "true" ]]; then
        success "已是最新可获取版本 ($installed)，官方 DMG 未提供更高版本"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 0
    fi

    # 安装前退出正在运行的 Chrome
    stop_chrome_processes

    step "安装到 /Applications..."
    if ! install_app_atomic "$src_app" "/Applications/Google Chrome.app"; then
        error "安装失败，已回滚"
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -f "$tmp_dmg"
        return 1
    fi

    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    rm -f "$tmp_dmg"

    local new_ver
    new_ver=$(get_installed_version)
    success "Google Chrome 安装/更新完成${new_ver:+ (版本: $new_ver)}"
}

install_linux() {
    local force="${1:-false}"
    local arch
    arch=$(detect_arch)

    if [[ "$arch" != "amd64" ]]; then
        error "当前仅支持 Linux amd64 架构的 Google Chrome 官方安装包"
        return 1
    fi

    if is_installed; then
        local installed latest
        installed=$(get_installed_version)
        info "检测到已安装 Google Chrome: ${installed:-未知版本}"
        latest=$(get_latest_version 2>/dev/null || true)
        if [[ -n "$latest" ]]; then
            info "官方最新稳定版: $latest"
            if [[ -n "$installed" && "$installed" == "$latest" && "$force" != "true" ]]; then
                success "已是最新版本，无需更新"
                return 0
            fi
        else
            warn "无法获取最新版本号，将继续下载安装最新版"
        fi
    fi

    if command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
        local pkg="/tmp/google-chrome-stable_current_amd64.deb"
        step "下载 Google Chrome (.deb)..."
        download_file "$CHROME_LINUX_DEB_URL" "$pkg" || { rm -f "$pkg"; return 1; }
        step "安装 .deb 包..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -y >/dev/null 2>&1 || true
            sudo apt-get install -y "$pkg" || sudo dpkg -i "$pkg" || sudo apt-get -f install -y
        else
            sudo dpkg -i "$pkg" || true
        fi
        rm -f "$pkg"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then
        local pkg="/tmp/google-chrome-stable_current_x86_64.rpm"
        step "下载 Google Chrome (.rpm)..."
        download_file "$CHROME_LINUX_RPM_URL" "$pkg" || { rm -f "$pkg"; return 1; }
        step "安装 .rpm 包..."
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y "$pkg"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$pkg"
        else
            sudo rpm -Uvh "$pkg"
        fi
        rm -f "$pkg"
    else
        error "未检测到支持的包管理器 (apt/dpkg/dnf/yum/rpm)"
        return 1
    fi

    local new_ver
    new_ver=$(get_installed_version)
    success "Google Chrome 安装/更新完成${new_ver:+ (版本: $new_ver)}"
}

cmd_install() {
    local os
    os=$(detect_os)
    case "$os" in
        macOS) install_macos "${FORCE:-false}" ;;
        Linux) install_linux "${FORCE:-false}" ;;
        *)     error "不支持的操作系统: $os"; return 1 ;;
    esac
}

cmd_update() {
    local os
    os=$(detect_os)
    if ! is_installed; then
        warn "未检测到已安装的 Google Chrome，将执行安装..."
    fi
    case "$os" in
        macOS) install_macos "${FORCE:-false}" ;;
        Linux) install_linux "${FORCE:-false}" ;;
        *)     error "不支持的操作系统: $os"; return 1 ;;
    esac
}

cmd_uninstall() {
    local os
    os=$(detect_os)
    
    # 根据 CHROME_TYPE 决定卸载目标
    local uninstall_all=false
    if [[ "$CHROME_TYPE" == "testing" ]]; then
        uninstall_all=false
    elif [[ "$CHROME_TYPE" == "standard" ]]; then
        uninstall_all=false
    else
        uninstall_all=true
    fi

    case "$os" in
        macOS)
            local targets=()
            local p
            
            if [[ "$uninstall_all" == "true" ]]; then
                # 卸载所有 Chrome 版本
                for p in \
                    "/Applications/Google Chrome.app" \
                    "$HOME/Applications/Google Chrome.app" \
                    "$CFT_APP_PATH" \
                    "$HOME/Applications/Google Chrome for Testing.app"; do
                    if [[ -d "$p" ]]; then
                        targets+=("$p")
                    fi
                done
            elif [[ "$CHROME_TYPE" == "testing" ]]; then
                # 只卸载 Chrome for Testing
                for p in "$CFT_APP_PATH" "$HOME/Applications/Google Chrome for Testing.app"; do
                    if [[ -d "$p" ]]; then
                        targets+=("$p")
                    fi
                done
            else
                # 只卸载标准版
                for p in "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do
                    if [[ -d "$p" ]]; then
                        targets+=("$p")
                    fi
                done
            fi
            
            if [[ ${#targets[@]} -eq 0 ]]; then
                warn "未找到已安装的 Chrome 应用"
                return 0
            fi
            
            for p in "${targets[@]}"; do
                warn "将删除应用: $p"
            done
            warn "用户数据目录 (~/Library/Application Support/Google/Chrome) 默认保留"
            if ! confirm_action "确认卸载 Chrome?"; then
                info "已取消"
                return 0
            fi
            stop_chrome_processes
            for p in "${targets[@]}"; do
                if [[ -d "$p" ]]; then
                    rm -rf "$p" && success "已卸载: $p"
                fi
            done
            ;;
        Linux)
            warn "将通过包管理器卸载 google-chrome-stable（用户数据默认保留）"
            if ! confirm_action "确认卸载 Google Chrome?"; then
                info "已取消"
                return 0
            fi
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get remove -y google-chrome-stable || true
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf remove -y google-chrome-stable || true
            elif command -v yum >/dev/null 2>&1; then
                sudo yum remove -y google-chrome-stable || true
            elif command -v rpm >/dev/null 2>&1; then
                sudo rpm -e google-chrome-stable || true
            else
                error "未检测到支持的包管理器，无法自动卸载"
                return 1
            fi
            success "Google Chrome 卸载完成"
            ;;
        *)
            error "不支持的操作系统: $os"
            return 1
            ;;
    esac
}

cmd_status() {
    local os installed latest
    os=$(detect_os)
    echo "操作系统: $os ($(uname -m))"

    if [[ "$os" == "macOS" ]]; then
        local cur_mac p app_info ver min_os found=0
        cur_mac=$(macos_version)
        for p in \
            "/Applications/Google Chrome.app" \
            "$HOME/Applications/Google Chrome.app" \
            "$CFT_APP_PATH" \
            "$HOME/Applications/Google Chrome for Testing.app"; do
            [[ -d "$p" ]] || continue
            app_info=$(macos_app_info "$p" 2>/dev/null || true)
            [[ -n "$app_info" ]] || continue
            found=1
            ver=$(printf '%s\n' "$app_info" | cut -f1)
            min_os=$(printf '%s\n' "$app_info" | cut -f2)
            echo "应用: $p"
            echo "  版本: ${ver}（要求 macOS ${min_os}）"
            if [[ "$min_os" != "未知" ]] && version_ge "$cur_mac" "$min_os"; then
                success "  系统兼容（当前 macOS ${cur_mac}）"
            else
                error "  系统不兼容（当前 macOS ${cur_mac}），应用无法启动"
            fi
        done
        if [[ $found -eq 0 ]]; then
            warn "Google Chrome 未安装"
        fi
        installed=$(get_installed_version)
    else
        if is_installed; then
            installed=$(get_installed_version)
            success "Google Chrome 已安装${installed:+: $installed}"
        else
            warn "Google Chrome 未安装"
        fi
    fi

    echo ""
    step "检查最新稳定版..."
    latest=$(get_latest_version 2>/dev/null || true)
    if [[ -n "$latest" ]]; then
        echo "最新发布号: ${latest}（官方 DMG 实际推送版本可能略低）"
        if [[ -n "${installed:-}" ]]; then
            if [[ "$installed" == "$latest" ]]; then
                success "当前已是最新版本"
            elif [[ "$os" == "macOS" && -d "$CFT_APP_PATH" ]]; then
                local newest_min
                newest_min=$(cft_newest_min_os 2>/dev/null || true)
                if [[ -n "$newest_min" ]] && ! version_ge "$(macos_version)" "$newest_min"; then
                    info "官方最新版要求 macOS ${newest_min}，当前系统不支持，已使用兼容版本 ${installed}"
                else
                    warn "检测到更新: $installed -> $latest"
                fi
            else
                warn "检测到更新: $installed -> $latest"
            fi
        fi
    else
        warn "无法获取最新版本号（网络或 API 不可用）"
    fi
}

show_help() {
    cat <<'EOF'
Google Chrome 安装脚本

用法:
  ./install-chrome.sh [命令] [选项]

命令:
  install     安装 Chrome（若已安装则检查并更新到最新版本）
  update      更新 Chrome（自动检测最新版本，已安装则覆盖更新）
  uninstall   卸载 Chrome（保留用户数据）
  status      查看安装状态、系统兼容性与最新版本
  help        显示帮助

选项:
  -y, --yes       卸载时跳过确认
  --force         强制重装官方版，并跳过 macOS 兼容性拦截
  --no-fallback   官方版不兼容时禁用自动回退（默认会回退）
  --type TYPE     指定安装类型: standard（标准版，默认）或 testing（Chrome for Testing）
  --version VER   指定 Chrome for Testing 版本（仅用于 --type testing）

说明:
  - 下载时优先使用 adl（若存在）进行多线程断点续传，否则回退 curl/wget
  - macOS: 使用官方稳定版 DMG 安装到 /Applications
  - Linux: 支持 amd64 的 deb/rpm 官方包
  - 版本检测: 通过 Google VersionHistory API 获取最新发布号，安装时以 DMG 内实际版本为准
  - 兼容性校验: 安装前读取 DMG 的 LSMinimumSystemVersion，系统过低不会安装官方版
  - 兼容回退: 官方稳定版要求高于当前 macOS 时，自动安装官方 Chrome for Testing 中
    最后一个兼容版本（/Applications/Google Chrome for Testing.app），并移除无法启动的官方版
  - 探测兼容性时只读取远程包内 Info.plist（HTTP Range），不会为探测下载整个安装包
  - Chrome 类型选择:
    * standard: 标准版 Google Chrome（默认，适合日常使用）
    * testing: Chrome for Testing（专门用于自动化测试）
  - Chrome for Testing 版本选择:
    * 不指定 --version: 自动选择兼容当前系统的最新版本
    * 指定 --version: 安装指定版本（如 150.0.7871.124）
  - uninstall 根据 --type 参数选择卸载目标，未指定时卸载所有版本

示例:
  # 安装标准版 Chrome（默认）
  ./install-chrome.sh install
  
  # 安装 Chrome for Testing（自动选择兼容版本）
  ./install-chrome.sh install --type testing
  
  # 安装指定版本的 Chrome for Testing
  ./install-chrome.sh install --type testing --version 150.0.7871.124
  
  # 更新标准版 Chrome
  ./install-chrome.sh update
  
  # 查看安装状态
  ./install-chrome.sh status
  
  # 卸载标准版 Chrome
  ./install-chrome.sh uninstall --type standard
  
  # 卸载 Chrome for Testing
  ./install-chrome.sh uninstall --type testing
  
  # 卸载所有 Chrome 版本
  ./install-chrome.sh uninstall -y
EOF
}

main() {
    local cmd="${1:-install}"
    shift || true

    # 解析全局/命令选项
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --force) FORCE=true ;;
            --no-fallback) export CHROME_NO_FALLBACK=1 ;;
            --type) 
                shift || true
                case "$1" in
                    standard|testing) CHROME_TYPE="$1" ;;
                    *) error "无效的 Chrome 类型: $1 (支持: standard, testing)"; return 1 ;;
                esac
                ;;
            --version)
                shift || true
                CFT_VERSION="$1"
                ;;
            -h|--help) cmd="help" ;;
            *) warn "未知选项: $1" ;;
        esac
        shift || true
    done

    [[ "${FORCE:-false}" == "true" ]] && export CHROME_ALLOW_INCOMPATIBLE=1

    case "$cmd" in
        install)   cmd_install ;;
        update)    cmd_update ;;
        uninstall) cmd_uninstall ;;
        status)    cmd_status ;;
        help|-h|--help) show_help ;;
        *)
            error "未知命令: $cmd"
            show_help
            return 1
            ;;
    esac
}

main "$@"

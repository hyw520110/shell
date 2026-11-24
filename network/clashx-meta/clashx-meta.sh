#!/bin/bash

set -euo pipefail

APP_NAME="ClashX Meta"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.metacubex.ClashX.meta"
HELPER_LABEL="com.metacubex.ClashX.ProxyConfigHelper"
REPO="MetaCubeX/ClashX.Meta"
REPO_API="https://api.github.com/repos/${REPO}/releases/latest"
REPO_API_TAG="https://api.github.com/repos/${REPO}/releases/tags"
# macOS 兼容版本兜底: 仅当系统太老、最新版确实跑不起来时才使用
CLASHX_COMPAT_VERSION="v1.3.18"
CLASHX_COMPAT_MAX_MAJOR="12"
# 内置内核最低可接受版本: 低于此版本无法解析 anytls 等较新协议
CORE_MIN_VERSION="1.19.3"
# anytls 协议于 mihomo v1.19.3 加入内核, 低于该版本会报 unsupport proxy type: anytls
CORE_ANYTLS_VERSION="1.19.3"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/${BUNDLE_ID}"
PRIVATE_CORE_DIR="$APP_SUPPORT_DIR/.private_core"
# 注意: 内核文件名是 ${HELPER_LABEL}.meta (不是裸 HELPER_LABEL), 漏掉 .meta 会全部落空
ACTIVE_CORE_FILE="$PRIVATE_CORE_DIR/${HELPER_LABEL}.meta"
BUNDLED_CORE_FILE="$APP_PATH/Contents/Resources/${HELPER_LABEL}.meta"
BUNDLED_CORE_GZ="$APP_PATH/Contents/Resources/${HELPER_LABEL}.meta.gz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_detail() { echo -e "${CYAN}       ${NC}$*"; }

# 当前 macOS 主版本号 (非 macOS 或无输出回退 99)
macos_major() {
    sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 99
}
macos_full() {
    sw_vers -productVersion 2>/dev/null || echo "0.0.0"
}

usage() {
    cat <<EOF
ClashX Meta 一键安装/更新/卸载脚本

用法:
  $0 [命令] [选项]

命令:
  install              安装；已安装时更新到最新版本 (默认)
  update               同 install
  report               仅输出版本体检报告: 客户端版本 + 内置内核(Mihomo)版本 +
                       内核能力判定(如 anytls 支持) + 远程最新版本 + 升级建议
  uninstall            卸载软件（默认）：删除 App 和 helper，保留用户数据
  purge                完全卸载：删除 App、helper、缓存、日志和用户配置

选项:
  --download-dir DIR   下载目录，默认: ~/Downloads
  --version TAG        安装指定版本 (如 v1.3.18, 使用 GitHub release tag)
  --force-latest       忽略 macOS 兼容兜底, 强制取 GitHub 最新发布版
                       (macOS 12 用户升级内核时通常需要这个)
  --clean-core         安装/更新后清理 AppSupport 里的旧 Mihomo 内核,
                       让客户端重新解压内置内核 (解决升级后内核仍是旧版的问题)
  --no-launch          安装后不自动启动 ClashX Meta
  --json               以 JSON 输出报告 (供脚本消费)
  -h, --help           显示帮助

示例:
  $0 report                        # 只看版本体检报告, 不装任何东西
  $0 --json report                 # JSON 格式报告
  $0                              # 安装或更新
  $0 --force-latest --clean-core  # macOS 12 强升最新版并清理旧内核
  $0 --version v1.3.18             # 安装指定版本
  $0 uninstall                     # 卸载软件，保留配置
  $0 purge                         # 完全卸载

注意:
  切换配置文件报 "unsupport proxy type: anytls" 时, 先跑
  $0 report
  确认内置内核版本 >= v1.19.3, 再
  $0 --force-latest --clean-core
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

# 校验下载产物是真正的安装包, 防止镜像返回 HTML 错误页却被当成 zip 装下去
# adl/aria2 遇到坏镜像时可能把几百字节的 HTML 落盘并仍返回 0, 必须自己再验一次
validate_archive() {
    local path="$1" size=""
    [[ -s "$path" ]] || { log_error "安装包为空: $path"; return 1; }

    size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)

    # 签名是可靠的区分点 (真 zip 最小 22B, 所以不要用大阈值卡大小)
    local magic=""
    magic=$(head -c 4 "$path" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')

    case "$path" in
        *.zip)
            if [[ "$magic" != "504b0304" ]]; then
                log_error "不是有效的 ZIP 文件 (${size}B, 签名: ${magic:-空})"
                log_error "常见原因: 镜像返回了错误页, 换一个 --version 或稍后重试"
                return 1
            fi
            ;;
        *.dmg)
            # 现代 .dmg 可能是 PKZip 容器 (504b0304) 或老式 kPFK 头 (6b50464b)
            if [[ "$magic" != "504b0304" && "$magic" != "6b50464b" ]]; then
                log_error "不是有效的 DMG 文件 (${size}B, 签名: ${magic:-空})"
                return 1
            fi
            ;;
        *)
            # 未知后缀: 只要求非空
            ;;
    esac

    # 兜底: 小于 22B (zip EOCD 最小) 的归档必然无效
    if (( size < 22 )); then
        log_error "归档异常过小 (${size}B)"
        return 1
    fi

    return 0
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_file adl_path

    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"
    mkdir -p "$output_dir"

    # adl 已内置文件格式校验(魔数)+SHA256 校验, 失败会返回非零并终止下载。
    # 因此 adl 路径不再重复 validate_archive; 仅需确认产物非空
    # (adl 对空文件是跳过校验的)。curl/wget 路径没有 adl 的校验, 必须保留。
    if adl_path="$(adl_cmd 2>/dev/null)"; then
        log_info "使用 adl 下载: $url"
        if "$adl_path" "$url" "$output_dir" "$output_file" && [[ -s "$output" ]]; then
            return 0
        fi
        log_warn "adl 下载失败或产物异常, 回退到 curl 直连 ..."
        rm -f "$output"
        curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url" || return 1
        validate_archive "$output" || return 1
        return 0
    fi

    if has_cmd curl; then
        log_info "使用 curl 下载: $url"
        curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url" || return 1
        validate_archive "$output" || return 1
        return 0
    fi

    if has_cmd wget; then
        log_info "使用 wget 下载: $url"
        wget -O "$output" "$url" || return 1
        validate_archive "$output" || return 1
        return 0
    fi

    log_error "未找到可用下载工具，请先安装 adl、curl 或 wget"
    return 1
}

installed_version() {
    local info_plist="$APP_PATH/Contents/Info.plist"
    local v

    [[ -d "$APP_PATH" && -f "$info_plist" ]] || return 1

    v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null \
        || defaults read "$info_plist" CFBundleShortVersionString 2>/dev/null \
        || return 1)
    # 统一去掉 v 前缀, 调用方打印时自行加 "v"
    printf '%s\n' "${v#v}"
}

app_min_system() {
    local info_plist="$APP_PATH/Contents/Info.plist"
    [[ -f "$info_plist" ]] || return 1
    /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist" 2>/dev/null || return 1
}

# 比较两个点分版本号, 返回 0 表示 $1 >= $2
# $1/$2 形如 "13.0" / "12.7.6"; 允许空段按 0 处理
compare_macos_version_ge() {
    local left="$1" right="$2"
    [[ -z "$left" || -z "$right" ]] && return 0
    awk -v l="$left" -v r="$right" 'BEGIN {
        n1 = split(l, a, "."); n2 = split(r, b, ".");
        for (i = 1; i <= 3; i++) {
            x = (i <= n1 && a[i] != "") ? a[i] + 0 : 0;
            y = (i <= n2 && b[i] != "") ? b[i] + 0 : 0;
            if (x > y) { exit 0 }
            if (x < y) { exit 1 }
        }
        exit 0
    }'
}

# 校验 App 要求的最低 macOS 版本是否满足本机
# 本机 macOS 12.7.6 与 App 要求 13.0 时返回 1, 避免装上后 open 报
# "Unable to find application named ..." (LaunchServices 按 LSMinimumSystemVersion 硬拦截)
check_app_macos_compat() {
    local app="$1"
    local info_plist="${app}/Contents/Info.plist"
    local min_sys cur

    if [[ ! -f "$info_plist" ]]; then
        log_warn "未找到 Info.plist, 跳过系统兼容性检查"
        return 0
    fi

    min_sys=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist" 2>/dev/null || echo "")
    if [[ -z "$min_sys" ]]; then
        log_detail "该版本未声明 LSMinimumSystemVersion, 跳过检查"
        return 0
    fi

    cur=$(macos_full)
    if ! compare_macos_version_ge "$cur" "$min_sys"; then
        log_error "系统不兼容: App 要求 macOS ${min_sys}+, 本机为 macOS ${cur}"
        log_error "这个版本装上也无法启动 (open 会报 Unable to find application)"
        log_error "请改用支持本系统的版本, 例如: $0 --version ${CLASHX_COMPAT_VERSION}"
        return 1
    fi

    log_detail "系统兼容性检查通过: 要求 macOS ${min_sys}+, 本机 ${cur}"
    return 0
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

# 解析 mihomo 内核版本字符串, 输出四段数字 (1.19.3 -> "1 19 3 0")
# 支持: "Mihomo v1.19.28", "Mihomo Meta v1.19.28 linux/amd64",
#       "Mihomo v1.18.8 alpha-2cd1443", "clash meta v1.19.3", 裸 "v1.18.8"
parse_core_version() {
    local raw="$1" num
    num=$(printf '%s\n' "$raw" | grep -oE '[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [[ -z "$num" ]]; then
        echo "0 0 0 0"
        return 1
    fi
    num="${num#v}"
    num="${num#V}"
    awk -v v="$num" 'BEGIN {
        n = split(v, p, ".");
        for (i = 1; i <= 4; i++) {
            val = (i <= n && p[i] != "") ? p[i] : 0;
            printf "%s ", val + 0;
        }
        printf "\n";
    }'
}

# 内核版本是否 >= 目标版本: $1 = "M m p 0" (已解析), $2 = "1.19.3"
core_version_ge() {
    local nums="$1" target maj1 min1 pat1 maj2 min2 pat2
    target=$(parse_core_version "$2")

    read -r maj1 min1 pat1 _ <<< "$nums"
    read -r maj2 min2 pat2 _ <<< "$target"

    maj1=${maj1:-0}; min1=${min1:-0}; pat1=${pat1:-0}
    maj2=${maj2:-0}; min2=${min2:-0}; pat2=${pat2:-0}

    if (( maj1 < maj2 )); then return 1; fi
    if (( maj1 > maj2 )); then return 0; fi
    if (( min1 < min2 )); then return 1; fi
    if (( min1 > min2 )); then return 0; fi
    (( pat1 >= pat2 ))
}

# 从二进制里提取 Mihomo 内核版本
#
# 取版本说明 (顺序很重要, 每一层都实测验证过):
#   1. "Mihomo vX.Y.Z" 规范串 —— 部分发行版有。
#   2. Mihomo 的 -v 输出格式: ASCII 字符画 banner 之后, 版本号独占一行,
#      下一行是 go 工具链版本 (go1.x.y)。本机实测就是这个布局,
#      形如 "...banner...\n333333\n<v<y5\n?DR>\nUUUUU\n?ffffff\n@wKA\nv1.18.8\ngo1.23.0\nexpand 32-byte k"。
#      这是官方 release 二进制唯一可靠的版本来源。
#
# 踩过的坑 (不要改回去):
#   - 绝不能用 `"$c" -v` 探测: Mihomo helper 会以 root 拉起 PrivilegedHelper,
#     在无 TTY 的脚本里会挂住整个终端。只能静态分析 strings。
#   - `go version -m` 拿不到版本: ClashX 的 helper 是 git 检出构建,
#     mod 行显示 "(devel)", 没有版本号。
#   - 裸抓 v1.x.y 会误判: 依赖库版本串 (如 klauspost/compress v1.17.9)
#     出现 55 次, 真版本 v1.18.8 只出现 1 次, 排序靠前的反而是错的。
#   - 以上都失败就返回空, 宁可报"未识别"也不要瞎猜。
#
# 用法: extract_core_version_from_binary <二进制路径>  -> echo "Mihomo X.Y.Z"
extract_core_version_from_binary() {
    local binary="$1" v=""
    [[ -f "$binary" ]] || return 1

    # 1) 规范串
    v=$(strings -a "$binary" 2>/dev/null \
        | grep -iE '^[Mm]ihomo( Meta)? v?[0-9]' \
        | head -1 || true)
    if [[ -n "$v" ]]; then
        printf '%s\n' "$v"
        return 0
    fi

    # 2) banner 后独占一行的版本号, 紧跟 go 工具链版本
    v=$(strings -a "$binary" 2>/dev/null \
        | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+\ngo1\.' \
        | grep -oE '^[vV]?[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 || true)
    if [[ -z "$v" ]]; then
        # banner 与 go 行之间可能夹了别的行, 放宽到任意相邻匹配
        v=$(strings -a "$binary" 2>/dev/null \
            | grep -B1 -E '^go1\.[0-9]+\.[0-9]+$' \
            | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' \
            | head -1 || true)
    fi

    if [[ -n "$v" ]]; then
        printf 'Mihomo %s\n' "${v#v}"
        return 0
    fi

    return 1
}

# 输出: <内核版本字符串>\t<内核文件路径>
# 找不到时不输出, 返回 1
# 候选优先级: 正在运行的内核 > App 自带内核 (plain) > App 自带内核 (.gz)
core_binary_info() {
    local candidates=()
    local gz_candidates=()
    local c v

    # App 已启动过才有这个文件, 它才是真正在跑的内核
    [[ -x "$ACTIVE_CORE_FILE" ]] && candidates+=("$ACTIVE_CORE_FILE")
    [[ -f "$BUNDLED_CORE_FILE" ]] && candidates+=("$BUNDLED_CORE_FILE")
    # App 自带内核以 gzip 形式打进 Resources, 未启动前只能读它
    [[ -f "$BUNDLED_CORE_GZ" ]] && gz_candidates+=("$BUNDLED_CORE_GZ")

    # bash 3.2 (macOS 自带) 在 set -u 下展开空数组会报 unbound variable, 必须显式判空
    if [[ "${#candidates[@]}" -gt 0 ]]; then
        for c in "${candidates[@]}"; do
            if v=$(extract_core_version_from_binary "$c"); then
                printf '%s\t%s\n' "$v" "$c"
                return 0
            fi
        done
    fi

    # .gz: 解到临时目录再抽版本 (不执行该二进制, 避免触发 sudo)
    if [[ "${#gz_candidates[@]}" -gt 0 ]]; then
        local tmp_dir gz
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/clashx-core-probe.XXXXXX")
        for gz in "${gz_candidates[@]}"; do
            if gunzip -c "$gz" > "$tmp_dir/core" 2>/dev/null && [[ -s "$tmp_dir/core" ]]; then
                if v=$(extract_core_version_from_binary "$tmp_dir/core"); then
                    printf '%s\t%s\n' "$v" "$gz"
                    rm -rf "$tmp_dir"
                    return 0
                fi
            fi
        done
        rm -rf "$tmp_dir"
    fi

    return 1
}

# ---------------------------------------------------------------------------
# GitHub release 资产解析
# 输出格式统一为: <tag>\t<asset_name>\t<download_url>
# ---------------------------------------------------------------------------
RELEASE_PICKER_PY='
import json
import re
import sys

data = json.load(sys.stdin)
assets = data.get("assets", [])
compat_mode = len(sys.argv) > 1 and sys.argv[1] == "compat"

# macOS 12 兼容资产: 名字里显式带 macOS.12.0+ / macos12 字样
compat_patterns = [
    re.compile(r"macOS[.-]?12[^\s]*\.(dmg|zip)$", re.I),
    re.compile(r"macos12.*\.(dmg|zip)$", re.I),
    re.compile(r"12[.-]0[^\s]*\.(dmg|zip)$", re.I),
]
general_patterns = [
    re.compile(r"ClashX.*Meta.*\.(dmg|zip)$", re.I),
    re.compile(r"ClashX.*\.(dmg|zip)$", re.I),
]

groups = (compat_patterns, general_patterns) if compat_mode else (general_patterns,)

for patterns in groups:
    for asset in assets:
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        if any(p.fullmatch(name) for p in patterns) and "source" not in name.lower():
            print("%s\t%s\t%s" % (data.get("tag_name", ""), name, url))
            sys.exit(0)

# 兜底: 任何 zip/dmg
for asset in assets:
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if re.search(r"\.(dmg|zip)$", name, re.I) and "source" not in name.lower():
        print("%s\t%s\t%s" % (data.get("tag_name", ""), name, url))
        sys.exit(0)

sys.exit(1)
'

fetch_release_json() {
    local url="$1" tmp_json out
    tmp_json=$(mktemp "${TMPDIR:-/tmp}/clashx-meta-release.json.XXXXXX")
    if ! download_file "$url" "$tmp_json" >/dev/null 2>&1; then
        rm -f "$tmp_json"
        return 1
    fi
    out="${TMPDIR:-/tmp}/clashx-meta-release.json"
    mv "$tmp_json" "$out"
    printf '%s\n' "$out"
}

# 输出: <tag>\t<asset_name>\t<download_url>
latest_release_info() {
    local mode="${1:-latest}" tmp_json json tag url name
    tmp_json=$(fetch_release_json "$REPO_API") || return 1
    json=$(cat "$tmp_json")
    rm -f "$tmp_json"

    if ! has_cmd python3; then
        tag=$(printf '%s\n' "$json" | awk -F'"' '/"tag_name"/ {print $4; exit}')
        url=$(printf '%s\n' "$json" \
            | awk -F'"' '/browser_download_url/ && /\.(dmg|zip)/ && $4 !~ /[Ss]ource/ {print $4; exit}')
        [[ -n "$tag" && -n "$url" ]] || return 1
        printf '%s\t%s\t%s\n' "$tag" "$(basename "${url%%\?*}")" "$url"
        return
    fi

    printf '%s\n' "$json" | CLASHX_PICK_MODE="$mode" python3 -c "$RELEASE_PICKER_PY"
}

# 输出: <tag>\t<asset_name>\t<download_url>
release_by_tag() {
    local tag="$1" mode="${2:-latest}" tmp_json json
    tmp_json=$(fetch_release_json "${REPO_API_TAG}/${tag}") || {
        log_warn "无法获取版本 ${tag} 的 release 信息"
        return 1
    }
    json=$(cat "$tmp_json")
    rm -f "$tmp_json"
    printf '%s\n' "$json" | CLASHX_PICK_MODE="$mode" python3 -c "$RELEASE_PICKER_PY"
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
quit_app() {
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    pkill -f "$APP_NAME" >/dev/null 2>&1 || true
    pkill -f "ClashX" >/dev/null 2>&1 || true
}

remove_helper() {
    local helper_file="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
    local daemon_file="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

    # sudo -n: 无交互环境下不弹密码框, 拿不到权限就跳过 (helper 通常已在运行时持有)
    if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
        sudo -n launchctl bootout system "/Library/LaunchDaemons/${HELPER_LABEL}.plist" >/dev/null 2>&1 || true
    fi

    if [[ -e "$helper_file" ]]; then
        rm -f "$helper_file" 2>/dev/null || sudo -n rm -f "$helper_file" || true
    fi
    if [[ -e "$daemon_file" ]]; then
        rm -f "$daemon_file" 2>/dev/null || sudo -n rm -f "$daemon_file" || true
    fi
}

# 清理 AppSupport 中不兼容/过期的 meta core (防止 startMetaFailed)
# 根因: 旧 core (如 alpha-2cd1443, 或低于 CORE_MIN_VERSION 的 v1.18.x) 与当前客户端不兼容,
#       Helper 启动 core 时卡死; 升级 App 后内核仍残留旧版, 表现为协议不支持
cleanup_stale_core() {
    local core_file="$ACTIVE_CORE_FILE"

    if [[ ! -f "$core_file" ]]; then
        log_info "未发现残留内核, 无需清理: $core_file"
        return 0
    fi

    local core_ver nums
    # 复用 core_binary_info 的提取逻辑 (不要用 "$core_file" -v: helper 会以 root 拉起, 无 TTY 下会挂住终端)
    core_ver=$(extract_core_version_from_binary "$core_file" || true)

    # 检测 alpha (不兼容) 或版本读不出来时清理
    if [[ "$core_ver" == *alpha* ]] || [[ -z "$core_ver" ]]; then
        log_warn "检测到不兼容/过期的 meta core: ${core_ver:-unknown}"
        log_warn "清理 AppSupport 旧 core, 让 ClashX 重新解压兼容 core..."
        rm -f "$core_file" 2>/dev/null || sudo -n rm -f "$core_file" || true
        log_info "已清理: $core_file"
        return 0
    fi

    # 内核版本低于 CORE_MIN_VERSION 时同样清理, 否则升级 App 后内核仍是旧版
    nums=$(parse_core_version "$core_ver")
    if ! core_version_ge "$nums" "$CORE_MIN_VERSION"; then
        log_warn "内置内核版本过低: ${core_ver} (要求 >= v${CORE_MIN_VERSION}, anytls 支持)"
        log_warn "清理旧 core, 让 ClashX 重新解压客户端自带的新内核..."
        rm -f "$core_file" 2>/dev/null || sudo -n rm -f "$core_file" || true
        log_info "已清理: $core_file"
        return 0
    fi

    log_info "内置内核版本正常: ${core_ver} (>= v${CORE_MIN_VERSION}), 保留"
    return 0
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

    # 安装前先校验 App 要求的最低 macOS 版本, 避免装完才发现 open 报
    # "Unable to find application named ..." (LaunchServices 按 LSMinimumSystemVersion 硬拦截)
    check_app_macos_compat "$app_source" || {
        [[ -n "$mount_point" ]] && hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        [[ -n "$tmp_extract" ]] && rm -rf "$tmp_extract"
        return 1
    }

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

print_post_install_report() {
    local new_ver info v nums
    new_ver=$(installed_version 2>/dev/null || true)
    if [[ -z "$new_ver" ]]; then
        return 0
    fi

    echo ""
    log_info "安装后体检:"
    log_detail "客户端版本: v${new_ver}"

    if info=$(core_binary_info); then
        IFS=$'\t' read -r v _path <<< "$info"
        nums=$(parse_core_version "$v")
        log_detail "内置内核:    ${v}"
        if core_version_ge "$nums" "$CORE_MIN_VERSION"; then
            log_detail "anytls 支持:  ✓ (内核 >= v${CORE_MIN_VERSION})"
        else
            log_warn "anytls 支持:  ✗ 内核仍低于 v${CORE_MIN_VERSION}, 建议追加 --clean-core"
        fi
    else
        log_detail "内置内核:    待客户端首次启动后解压, 可稍后跑 report 复核"
    fi
}

# 指定版本安装: 按 GitHub tag 获取资产
install_specific_version() {
    local tag="$1" release_info remote_version asset_name url filename archive local_mode

    need_macos
    if [[ -z "$tag" ]]; then
        log_error "请通过 --version 指定版本 (如 v1.3.18)"
        return 1
    fi

    mkdir -p "$DOWNLOAD_DIR"
    # 指定版本安装时用 compat 选择器: macOS 12 上的旧 tag 才带 macOS.12.0+ 资产
    local_mode="compat"

    log_info "获取指定版本 ${tag} 的 release 信息..."
    release_info=$(release_by_tag "$tag" "$local_mode") || {
        log_error "未能获取版本 ${tag} 的 release 信息"
        log_error "请确认版本存在: https://github.com/${REPO}/releases"
        return 1
    }
    IFS=$'\t' read -r remote_version asset_name url <<< "$release_info"

    if [[ -z "$url" ]]; then
        log_error "版本 ${tag} 没有可下载的 macOS 安装包"
        return 1
    fi

    log_info "目标版本: ${remote_version:-$tag} (${asset_name})"
    log_info "下载地址: $url"

    filename="${asset_name}"
    archive="$DOWNLOAD_DIR/$filename"

    if download_file "$url" "$archive"; then
        remove_helper
        install_app_from_archive "$archive"
        if [[ "$clean_core" -eq 1 ]]; then
            cleanup_stale_core
        fi
    fi
    rm -f "$archive"

    if [[ "$no_launch" -ne 1 ]]; then
        log_info "启动 ClashX Meta..."
        open -a "$APP_NAME" || true
    fi
    print_post_install_report
}

# 选择目标版本: 优先最新版, 仅在系统太老时回退兼容版
# 结果写入 SELECTED_TAG / SELECTED_ASSET / SELECTED_URL
select_release() {
    local mode="latest" major select_release_info

    if [[ "$force_latest" -eq 1 ]]; then
        log_info "--force-latest: 忽略 macOS 兼容兜底, 直接取 GitHub 最新版"
        mode="latest"
    else
        major=$(macos_major)
        if [[ "$major" != "99" ]] && (( major <= CLASHX_COMPAT_MAX_MAJOR )); then
            log_warn "当前 macOS $(macos_full) <= 12.x, 默认回退兼容版 ${CLASHX_COMPAT_VERSION}"
            log_warn "若因内核过旧报 unsupport proxy type (如 anytls), 请改用 --force-latest"
            mode="compat"
        fi
    fi

    SELECTED_MODE="$mode"
    if [[ "$mode" == "compat" ]]; then
        select_release_info=$(release_by_tag "$CLASHX_COMPAT_VERSION" "latest") || {
            log_warn "兼容版 ${CLASHX_COMPAT_VERSION} 获取失败, 回退到最新版"
            select_release_info=$(latest_release_info "latest") || {
                log_error "未能获取 macOS 安装包"
                log_error "请手动查看: https://github.com/${REPO}/releases"
                return 1
            }
        }
    else
        select_release_info=$(latest_release_info "latest") || {
            log_error "未能从 GitHub release 中识别 macOS 安装包"
            log_error "请手动查看: https://github.com/${REPO}/releases"
            return 1
        }
    fi

    IFS=$'\t' read -r SELECTED_TAG SELECTED_ASSET SELECTED_URL <<< "$select_release_info"
}

install_or_update() {
    local local_version filename archive remote_version url asset_name

    need_macos
    mkdir -p "$DOWNLOAD_DIR"

    log_info "获取 ClashX Meta 版本信息..."
    select_release
    remote_version="$SELECTED_TAG"
    url="$SELECTED_URL"
    asset_name="$SELECTED_ASSET"

    if local_version=$(installed_version 2>/dev/null); then
        log_info "本地已安装版本: ${local_version}"
    else
        log_info "本地未安装 ClashX Meta"
    fi

    log_info "目标版本: ${remote_version:-unknown} (${asset_name:-?})"
    if [[ -z "$url" ]]; then
        log_error "GitHub release 未返回可下载的 macOS 安装包"
        log_error "请手动查看: https://github.com/${REPO}/releases"
        exit 1
    fi

    if [[ -n "${local_version:-}" && -n "${remote_version:-}" ]]; then
        if ! version_gt "$remote_version" "$local_version"; then
            log_info "当前已是最新版本 ${local_version}，无需下载。"
            log_info "如需强制重装: $0 --version ${local_version}"
            return 0
        fi
        log_info "升级: ${local_version} -> ${remote_version}"
    fi

    filename="${asset_name:-$(basename "${url%%\?*}")}"
    archive="$DOWNLOAD_DIR/$filename"

    log_info "下载地址: $url"
    if download_file "$url" "$archive"; then
        remove_helper
        install_app_from_archive "$archive"
        if [[ "$clean_core" -eq 1 ]]; then
            cleanup_stale_core
        fi
    fi
    rm -f "$archive"

    if [[ "$no_launch" -ne 1 ]]; then
        log_info "启动 ClashX Meta..."
        open -a "$APP_NAME" || true
    fi
    print_post_install_report
}

# ---------------------------------------------------------------------------
# 版本体检报告
# ---------------------------------------------------------------------------
REPORT_CORE_VERSION=""
REPORT_CORE_FILE=""
REPORT_CORE_OK=2

report_core_status() {
    local info version_str core_path nums
    REPORT_CORE_VERSION=""
    REPORT_CORE_FILE=""
    REPORT_CORE_OK=2
    if ! info=$(core_binary_info); then
        return 1
    fi
    IFS=$'\t' read -r version_str core_path <<< "$info"
    nums=$(parse_core_version "$version_str")
    REPORT_CORE_VERSION="$version_str"
    REPORT_CORE_FILE="$core_path"
    if core_version_ge "$nums" "$CORE_MIN_VERSION"; then
        REPORT_CORE_OK=1
    else
        REPORT_CORE_OK=0
    fi
    return 0
}

print_report() {
    local local_version remote_version min_sys nums

    local_version=$(installed_version 2>/dev/null || echo "")
    min_sys=$(app_min_system 2>/dev/null || echo "")

    report_core_status || true

    remote_version=$(latest_release_info "latest" 2>/dev/null | cut -f1 || echo "")

    if [[ "$REPORT_JSON" -eq 1 ]] && has_cmd python3; then
        REPORT_LOCAL="${local_version}" \
        REPORT_REMOTE="${remote_version}" \
        REPORT_MIN_SYS="${min_sys}" \
        REPORT_MACOS="$(macos_full)" \
        REPORT_CORE="${REPORT_CORE_VERSION}" \
        REPORT_CORE_FILE="${REPORT_CORE_FILE}" \
        REPORT_CORE_OK="${REPORT_CORE_OK}" \
        REPORT_CORE_MIN="${CORE_MIN_VERSION}" \
            python3 -c '
import json, os
g = lambda k: os.environ.get(k, "")
core_ok = int(g("REPORT_CORE_OK"))
print(json.dumps({
    "local_version": g("REPORT_LOCAL"),
    "remote_version": g("REPORT_REMOTE"),
    "app_min_system": g("REPORT_MIN_SYS"),
    "macos_version": g("REPORT_MACOS"),
    "core_version": g("REPORT_CORE"),
    "core_file": g("REPORT_CORE_FILE"),
    "core_satisfies_anytls": core_ok == 1,
    "core_min_version": g("REPORT_CORE_MIN"),
}, ensure_ascii=False, indent=2))
' && return 0
    fi

    echo -e "${CYAN}========== ClashX Meta 版本体检 ==========${NC}"
    log_detail "macOS 版本:   $(macos_full)"

    if [[ -n "$local_version" ]]; then
        log_detail "客户端版本:   v${local_version}"
        if [[ -n "$min_sys" ]]; then
            log_detail "系统要求:     macOS ${min_sys}+"
        fi
    else
        log_detail "客户端版本:   未安装"
    fi

    if [[ -n "$REPORT_CORE_VERSION" ]]; then
        log_detail "内置内核:     ${REPORT_CORE_VERSION}"
        log_detail "内核文件:     ${REPORT_CORE_FILE}"
        if [[ "$REPORT_CORE_OK" -eq 1 ]]; then
            log_info "内核能力:       ✓ 满足 v${CORE_MIN_VERSION}+, 支持 anytls / VLESS Reality / Hysteria2"
        else
            log_error "内核能力:       ✗ 低于 v${CORE_MIN_VERSION}, 无法解析 anytls 节点"
        fi
    else
        log_detail "内置内核:     未检测到 (客户端首次启动后才会解压)"
    fi

    if [[ -n "$remote_version" ]]; then
        log_detail "远程最新版:   ${remote_version}"
        if [[ -n "$local_version" ]]; then
            if version_gt "$remote_version" "$local_version"; then
                log_warn "可升级:         ${local_version} -> ${remote_version}"
            else
                log_info "已是最新客户端版本"
            fi
        fi
    fi

    echo ""
    echo -e "${CYAN}---------- 升级建议 ----------${NC}"
    if [[ "$REPORT_CORE_OK" -eq 0 ]]; then
        log_warn "订阅里出现 anytls 节点时, 切换配置会报:"
        log_detail "  重载配置文件失败 proxy 0: unsupport proxy type: anytls"
        log_warn "原因: 内置内核低于 v${CORE_ANYTLS_VERSION} (anytls 于该版本加入 mihomo)"
        log_info "修复:"
        log_detail "  $0 --force-latest --clean-core"
    elif [[ "$REPORT_CORE_OK" -eq 2 ]]; then
        log_info "先启动一次 ClashX Meta 让内核解压, 再跑 report 复核。"
    else
        log_info "客户端与内核均已就绪, 无需额外处理。"
    fi
    echo -e "${CYAN}====================================${NC}"
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
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
        "$APP_SUPPORT_DIR" \
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

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
main() {
    local command="install"
    local target_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|update|report|uninstall|purge)
                command="$1"
                shift
                ;;
            --download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --version)
                target_version="${2/#\~/$HOME}"
                shift 2
                ;;
            --force-latest)
                force_latest=1
                shift
                ;;
            --clean-core)
                clean_core=1
                shift
                ;;
            --no-launch)
                no_launch=1
                shift
                ;;
            --json)
                REPORT_JSON=1
                shift
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
        install|update)
            if [[ -n "$target_version" ]]; then
                install_specific_version "$target_version"
            else
                install_or_update
            fi
            ;;
        report)
            need_macos
            print_report
            ;;
        uninstall) uninstall_app ;;
        purge) purge_app ;;
    esac
}

# 默认值 (参数解析前初始化, 供 set -u 安全使用)
select_mode="latest"
force_latest=0
clean_core=0
no_launch=0
REPORT_JSON=0
SELECTED_MODE="latest"
SELECTED_TAG=""
SELECTED_ASSET=""
SELECTED_URL=""

main "$@"
#!/usr/bin/env bash
# OpenHuman 安装/更新脚本
# 自动检测最新版本，使用 aria2c 多线程加速下载
# 支持 macOS (ARM64/x86_64) 和 Linux (x86_64/aarch64)

set -euo pipefail

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ── 常量 ──
GITHUB_REPO="tinyhumansai/openhuman"
LATEST_JSON_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/latest.json"
RELEASES_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
PROXY_MIRRORS=(
    "https://mirror.ghproxy.com"
    "https://gh-proxy.com"
    "https://ghproxy.cc"
)

# ── 依赖检查 ──
check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1   || missing+=("jq")
    command -v tar >/dev/null 2>&1   || missing+=("tar")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少必要依赖: ${missing[*]}"
        if command -v brew >/dev/null 2>&1; then
            log_info "正在通过 brew 安装..."
            brew install "${missing[@]}"
        else
            log_error "请手动安装: ${missing[*]}"
            exit 1
        fi
    fi
}

# ── 检测平台 ──
detect_platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        darwin)
            case "$arch" in
                arm64)  echo "darwin/aarch64" ;;
                x86_64) echo "darwin/x86_64" ;;
                *)      log_error "不支持的 macOS 架构: $arch"; exit 1 ;;
            esac
            ;;
        linux)
            case "$arch" in
                x86_64|amd64)  echo "linux/x86_64" ;;
                aarch64|arm64)  echo "linux/aarch64" ;;
                *)              log_error "不支持的 Linux 架构: $arch"; exit 1 ;;
            esac
            ;;
        *)
            log_error "不支持的操作系统: $os"
            exit 1
            ;;
    esac
}

# ── 获取文件名模式 ──
get_asset_pattern() {
    local platform="$1"
    local os="${platform%%/*}"
    local arch="${platform##*/}"

    case "$os" in
        darwin)
            case "$arch" in
                aarch64) echo "OpenHuman_.*_aarch64-apple-darwin.app.tar.gz" ;;
                x86_64)  echo "OpenHuman_.*_x86_64-apple-darwin.dmg" ;;
            esac
            ;;
        linux)
            echo "openhuman-core-.*-${arch}-unknown-linux-gnu.tar.gz"
            ;;
    esac
}

# ── 获取安装目标路径 ──
get_install_target() {
    local platform="$1"
    local os="${platform%%/*}"

    case "$os" in
        darwin) echo "/Applications" ;;
        linux)  echo "$HOME/.local/bin" ;;
    esac
}

# ── 检测代理 ──
detect_proxy() {
    local proxy=""
    # 常见代理端口
    for port in 7890 7891 1080 8080 8888; do
        if curl -s --connect-timeout 2 "http://127.0.0.1:${port}" >/dev/null 2>&1; then
            proxy="http://127.0.0.1:${port}"
            break
        fi
    done

    # 环境变量
    [[ -z "$proxy" && -n "${http_proxy:-}" ]] && proxy="$http_proxy"
    [[ -z "$proxy" && -n "${HTTP_PROXY:-}" ]] && proxy="$HTTP_PROXY"
    [[ -z "$proxy" && -n "${https_proxy:-}" ]] && proxy="$https_proxy"

    if [[ -n "$proxy" ]]; then
        log_info "检测到代理: $proxy"
        export http_proxy="$proxy"
        export https_proxy="$proxy"
        export ALL_PROXY="$proxy"
        return 0
    fi
    return 1
}

# ── 获取最新版本信息 ──
fetch_latest_version() {
    log_step "检测最新版本..."

    # 方式 1: 通过 latest.json
    local json_data
    json_data=$(curl -fsSL --connect-timeout 10 "$LATEST_JSON_URL" 2>/dev/null) && {
        LATEST_VERSION=$(echo "$json_data" | jq -r '.version // .tag // empty' 2>/dev/null)
        if [[ -n "$LATEST_VERSION" ]]; then
            log_info "最新版本: $LATEST_VERSION (via latest.json)"
            return 0
        fi
    }

    # 方式 2: 通过 GitHub API
    json_data=$(curl -fsSL --connect-timeout 10 "$RELEASES_API" 2>/dev/null) && {
        LATEST_VERSION=$(echo "$json_data" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
        if [[ -n "$LATEST_VERSION" ]]; then
            log_info "最新版本: $LATEST_VERSION (via GitHub API)"
            return 0
        fi
    }

    log_error "无法获取最新版本信息"
    exit 1
}

# ── 构建下载 URL ──
build_download_url() {
    local version="$1"
    local pattern="$2"

    # 从 GitHub Release 页面解析 asset URL
    local release_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}"
    local html_page
    html_page=$(curl -fsSL --connect-timeout 10 \
        "https://github.com/${GITHUB_REPO}/releases/tag/v${version}" 2>/dev/null) || true

    # 提取匹配的 asset 文件名
    local asset_name=""
    asset_name=$(echo "$html_page" | grep -oE "href=\"[^\"]*${pattern}\"" | head -1 | sed 's/href="//;s/"//')

    if [[ -n "$asset_name" ]]; then
        # 构建完整 URL
        if [[ "$asset_name" == http* ]]; then
            echo "$asset_name"
        else
            echo "https://github.com${asset_name}"
        fi
        return 0
    fi

    # 回退: 直接拼接
    local os="${PLATFORM%%/*}"
    local arch="${PLATFORM##*/}"
    case "$os" in
        darwin)
            case "$arch" in
                aarch64) echo "${release_url}/OpenHuman_${version}_aarch64-apple-darwin.app.tar.gz" ;;
                x86_64)  echo "${release_url}/OpenHuman_${version}_x86_64-apple-darwin.dmg" ;;
            esac
            ;;
        linux)
            echo "${release_url}/openhuman-core-${version}-${arch}-unknown-linux-gnu.tar.gz"
            ;;
    esac
}

# ── 下载函数（优先使用 adl，回退 aria2c，再回退 curl） ──
download_file() {
    local url="$1"
    local output_dir="$2"
    local filename="$3"
    shift 3 2>/dev/null || true
    # 剩余参数作为镜像 URL

    # 优先级 1: adl（自定义 aria2c 封装，自动检测代理 + 镜像回退）
    if command -v adl >/dev/null 2>&1; then
        log_info "使用 adl 加速下载..."
        if [[ $# -gt 0 ]]; then
            adl "$url" "$output_dir" "$filename" "$@" && return 0
        else
            # 自动拼接常用镜像
            local mirror_urls=()
            for m in "${PROXY_MIRRORS[@]}"; do
                mirror_urls+=("${m}/${url}")
            done
            adl "$url" "$output_dir" "$filename" "${mirror_urls[@]}" && return 0
        fi
        log_warn "adl 下载失败，尝试 aria2c..."
    fi

    # 优先级 2: aria2c
    if command -v aria2c >/dev/null 2>&1; then
        log_info "使用 aria2c 多线程下载 (16 连接)..."
        if aria2c \
            -x 16 -s 16 -k 1M -c \
            --max-tries=5 --retry-wait=3 \
            --connect-timeout=15 --timeout=120 \
            --check-certificate=false \
            --summary-interval=5 \
            --console-log-level=notice \
            -d "$output_dir" -o "$filename" \
            "$url"; then
            return 0
        fi
        log_warn "aria2c 下载失败，尝试镜像..."
        for m in "${PROXY_MIRRORS[@]}"; do
            log_info "尝试镜像: $m"
            if aria2c \
                -x 16 -s 16 -k 1M -c \
                --max-tries=3 --retry-wait=3 \
                --connect-timeout=10 --timeout=120 \
                --check-certificate=false \
                -d "$output_dir" -o "$filename" \
                "${m}/${url}"; then
                return 0
            fi
        done
    fi

    # 优先级 3: curl（最终回退）
    log_warn "aria2c 不可用，使用 curl 下载（速度较慢）..."
    curl -fL --progress-bar --retry 3 --connect-timeout 30 \
        -o "$output_dir/$filename" "$url"
}

# ── 安装 macOS 版本 ──
install_macos() {
    local url="$1"
    local version="$2"
    local arch="${PLATFORM##*/}"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/openhuman-install.XXXXXX")
    local filename="OpenHuman_${version}_aarch64-apple-darwin.app.tar.gz"

    # 下载
    log_step "开始下载 OpenHuman $version..."
    log_info "下载地址: $url"

    if ! download_file "$url" "$tmp_dir" "$filename"; then
        log_error "下载失败"
        rm -rf "$tmp_dir"
        exit 1
    fi

    # 校验文件大小
    local output="$tmp_dir/$filename"
    local file_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null)
    if [[ "$file_size" -lt 10000000 ]]; then
        log_error "下载文件异常 (仅 $((file_size / 1024 / 1024))MB)，可能下载不完整"
        rm -rf "$tmp_dir"
        exit 1
    fi

    # 解压安装
    log_step "解压并安装..."
    if [[ "$filename" == *.dmg ]]; then
        # DMG 安装
        local mount_point
        mount_point=$(hdiutil attach "$output" -nobrowse -quiet 2>/dev/null | grep -o '/Volumes/[^ ]*' | head -1) || true
        if [[ -z "$mount_point" ]]; then
            log_error "挂载 DMG 失败"
            rm -rf "$tmp_dir"
            exit 1
        fi
        cp -R "$mount_point/OpenHuman.app" /Applications/ 2>/dev/null
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    else
        # tar.gz 安装
        tar -xzf "$output" -C /Applications/ 2>/dev/null
    fi

    # 清理
    rm -rf "$tmp_dir"

    # 验证
    if [[ -d "/Applications/OpenHuman.app" ]]; then
        log_info "安装成功: /Applications/OpenHuman.app"
        return 0
    else
        log_error "安装失败"
        return 1
    fi
}

# ── 安装 Linux 版本 ──
install_linux() {
    local url="$1"
    local version="$2"
    local arch="${PLATFORM##*/}"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/openhuman-install.XXXXXX")
    local filename="openhuman-core-${version}-${arch}-unknown-linux-gnu.tar.gz"
    local output="$tmp_dir/$filename"

    log_step "开始下载 OpenHuman $version..."
    log_info "下载地址: $url"

    if ! download_file "$url" "$tmp_dir" "$filename"; then
        log_error "下载失败"
        rm -rf "$tmp_dir"
        exit 1
    fi

    # 解压安装
    log_step "解压并安装..."
    local install_dir="$HOME/.local"
    mkdir -p "$install_dir/bin"
    tar -xzf "$output" -C "$install_dir" --strip-components=1 2>/dev/null

    # 清理
    rm -rf "$tmp_dir"

    log_info "安装完成: $install_dir/bin/openhuman"
}

# ── 检测已安装版本 ──
get_installed_version() {
    local os="${PLATFORM%%/*}"
    case "$os" in
        darwin)
            if [[ -d "/Applications/OpenHuman.app" ]]; then
                # 尝试从 Info.plist 获取版本
                defaults read /Applications/OpenHuman.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown"
            else
                echo ""
            fi
            ;;
        linux)
            if command -v openhuman >/dev/null 2>&1; then
                openhuman --version 2>/dev/null | awk '{print $NF}' || echo "unknown"
            else
                echo ""
            fi
            ;;
    esac
}

# ── 卸载 ──
uninstall() {
    local os="${PLATFORM%%/*}"
    log_step "卸载 OpenHuman..."

    case "$os" in
        darwin)
            local removed_any=false
            if [[ -d "/Applications/OpenHuman.app" ]]; then
                rm -rf /Applications/OpenHuman.app
                log_info "已删除 /Applications/OpenHuman.app"
                removed_any=true
            else
                log_info "未发现 /Applications/OpenHuman.app"
            fi
            if [[ -n "$(command -v openhuman 2>/dev/null || true)" ]]; then
                log_warn "仍检测到 PATH 中存在 openhuman: $(command -v openhuman)"
            fi
            if [[ -d "$HOME/.openhuman" ]]; then
                rm -rf "$HOME/.openhuman" 2>/dev/null
                log_info "已清理配置目录 ~/.openhuman"
                removed_any=true
            else
                log_info "配置目录 ~/.openhuman 不存在"
            fi
            [[ "$removed_any" == true ]] || log_info "OpenHuman 未安装或已清理，无需操作"
            ;;
        linux)
            local removed_any=false
            if [[ -f "$HOME/.local/bin/openhuman" ]]; then
                rm -f "$HOME/.local/bin/openhuman" 2>/dev/null
                log_info "已删除 $HOME/.local/bin/openhuman"
                removed_any=true
            else
                log_info "未发现 $HOME/.local/bin/openhuman"
            fi
            if [[ -d "$HOME/.openhuman" ]]; then
                rm -rf "$HOME/.openhuman" 2>/dev/null
                log_info "已清理配置目录 ~/.openhuman"
                removed_any=true
            else
                log_info "配置目录 ~/.openhuman 不存在"
            fi
            [[ "$removed_any" == true ]] || log_info "OpenHuman 未安装或已清理，无需操作"
            ;;
    esac

    log_info "卸载完成"
}

# ── 主函数 ──
main() {
    local action="${1:-install}"
    local force=false
    [[ "${2:-}" == "--force" ]] && force=true

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  OpenHuman 安装/更新工具${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    case "$action" in
        uninstall)
            PLATFORM=$(detect_platform)
            uninstall
            exit 0
            ;;
        version|--version|-v)
            PLATFORM=$(detect_platform)
            local installed=$(get_installed_version)
            if [[ -n "$installed" && "$installed" != "unknown" ]]; then
                log_info "已安装版本: $installed"
            else
                log_info "OpenHuman 未安装"
            fi
            fetch_latest_version
            exit 0
            ;;
        install|update|"")
            ;;
        --help|-h|help)
            echo "用法: $0 [install|update|uninstall|version] [--force]"
            echo ""
            echo "命令:"
            echo "  install    安装最新版本 (默认)"
            echo "  update     更新到最新版本"
            echo "  uninstall  卸载 OpenHuman"
            echo "  version    查看版本信息"
            echo ""
            echo "选项:"
            echo "  --force    强制安装，跳过版本检查"
            exit 0
            ;;
        *)
            log_error "未知命令: $action"
            exit 1
            ;;
    esac

    # 检查依赖
    check_dependencies

    # 检测平台
    PLATFORM=$(detect_platform)
    local os="${PLATFORM%%/*}"
    local arch="${PLATFORM##*/}"
    log_info "平台: $os/$arch"

    # 检测代理
    detect_proxy

    # 获取最新版本
    fetch_latest_version

    # 检查已安装版本
    local installed_version=$(get_installed_version)
    if [[ -n "$installed_version" && "$installed_version" != "unknown" && "$force" != true ]]; then
        if [[ "$installed_version" == "$LATEST_VERSION" ]]; then
            log_info "已是最新版本: $LATEST_VERSION"
            echo ""
            read -p "是否重新安装? (y/N): " reinstall
            [[ ! "$reinstall" =~ ^[Yy]$ ]] && exit 0
        else
            log_info "当前版本: $installed_version → 最新版本: $LATEST_VERSION"
            echo ""
            read -p "是否更新? (Y/n): " update_confirm
            [[ "$update_confirm" =~ ^[Nn]$ ]] && exit 0
        fi
    fi

    # 获取下载 URL
    local asset_pattern=$(get_asset_pattern "$PLATFORM")
    local download_url=$(build_download_url "$LATEST_VERSION" "$asset_pattern")

    if [[ -z "$download_url" ]]; then
        log_error "无法构建下载 URL"
        exit 1
    fi

    log_info "下载文件: $(basename "$download_url")"

    # 安装
    case "$os" in
        darwin) install_macos "$download_url" "$LATEST_VERSION" ;;
        linux)  install_linux  "$download_url" "$LATEST_VERSION" ;;
    esac

    # 完成
    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  OpenHuman $LATEST_VERSION 安装完成!${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    case "$os" in
        darwin)
            log_info "启动方式: open /Applications/OpenHuman.app"
            ;;
        linux)
            log_info "启动方式: openhuman"
            ;;
    esac
}

main "$@"

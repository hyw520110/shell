#!/bin/bash
#
# OpenAI Codex Desktop App 安装脚本
# Codex 是 OpenAI 推出的 AI 编程助手桌面应用
#
# 用法:
#   ./install-codex.sh              # 安装 Codex Desktop App
#   ./install-codex.sh --status     # 查看状态
#   ./install-codex.sh --uninstall  # 卸载
#   ./install-codex.sh --help       # 显示帮助

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Codex 下载地址
readonly CODEX_DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
# macOS 兼容版: 系统 <= 12.x 时用构建 5848 (版本 26.721.41059, 2026-07-24)
# ⚠️ 实测结论: 8月及以后版本 (构建 6223+/6415+) 虽然 Info.plist 声称 12.0 但主二进制 minos=13.0 无法运行
#   只有 7月及更早版本 (构建 5848 等) 主二进制真正 minos=12.0, 兼容 macOS 12.7.6
CODEX_COMPAT_VERSION="26.721.41059"
CODEX_COMPAT_BUILD="5848"
CODEX_COMPAT_URL="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-${CODEX_COMPAT_VERSION}.zip"
CODEX_COMPAT_MAX_MAJOR="12"

# === 日志函数 ===
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }

# === 检测系统 ===
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*) echo "linux" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

# === 获取真实用户目录 ===
get_user_home() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        eval echo "~$SUDO_USER"
    else
        echo "$HOME"
    fi
}

# === 查找 adl 工具 ===
find_adl() {
    if command -v adl &> /dev/null; then
        echo "adl"
        return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for p in "$script_dir/../network/tools/adl" "$script_dir/../../network/tools/adl"; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# === 下载文件 ===
download_file() {
    local url="$1"
    local output="$2"

    # 优先使用 adl（代理检测 + 多线程加速）
    local adl_cmd
    if adl_cmd=$(find_adl); then
        log_info "使用 adl 加速下载..."
        local dir=$(dirname "$output")
        local file=$(basename "$output")
        if "$adl_cmd" "$url" "$dir" "$file"; then
            return 0
        fi
        log_warn "adl 下载失败，尝试 curl..."
    fi

    # 回退到 curl
    curl -f -L --retry 3 --connect-timeout 30 --max-time 600 -o "$output" "$url"
}

# === 安装 Codex CLI (npm 全局) ===
install_codex_cli() {
    log_header "安装 Codex CLI"

    # 已安装则跳过
    if command -v codex &> /dev/null; then
        log_success "Codex CLI 已安装: $(codex --version 2>/dev/null | head -1 || echo 'codex')"
        return 0
    fi

    # 确保 npm 存在
    if ! command -v npm &> /dev/null; then
        log_error "未找到 npm，请先安装 Node.js (brew install node)"
        return 1
    fi

    log_info "使用 npm 安装 @openai/codex (全局)..."
    if npm install -g @openai/codex; then
        log_success "Codex CLI 安装完成: $(command -v codex)"
    else
        log_error "Codex CLI 安装失败"
        return 1
    fi
}

# === 当前 macOS 版本 ===
macos_major() {
    sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 99
}
macos_full() {
    sw_vers -productVersion 2>/dev/null || echo "0.0.0"
}

# === 检测 macOS 版本兼容性 (app 的 minos <= 当前系统) ===
# 下载后、挂载前检查：避免安装后才发现二进制要求更高系统版本
check_macos_compat() {
    local volume="$1"
    local app_name="$2"
    local app_path="$volume/$app_name"

    # 读取 Info.plist 的 LSMinimumSystemVersion
    local min_os
    min_os=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app_path/Contents/Info.plist" 2>/dev/null || echo "")
    # 读取二进制 minos (Mach-O)
    local exe
    exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app_path/Contents/Info.plist" 2>/dev/null || echo "")
    local bin_minos=""
    if [[ -n "$exe" && -f "$app_path/Contents/MacOS/$exe" ]]; then
        bin_minos=$(otool -l "$app_path/Contents/MacOS/$exe" 2>/dev/null | grep -A3 "LC_BUILD_VERSION" | grep minos | head -1 | awk '{print $2}')
    fi

    # 当前系统版本
    local cur_ver cur_major
    cur_ver=$(sw_vers -productVersion 2>/dev/null || echo "12.0")
    cur_major=$(echo "$cur_ver" | cut -d. -f1)

    # 用更高的那个作为实际要求
    local req=""
    if [[ -n "$bin_minos" ]]; then
        req="$bin_minos"
    elif [[ -n "$min_os" ]]; then
        req="$min_os"
    fi

    if [[ -z "$req" ]]; then
        log_info "未检测到系统版本要求，跳过兼容性检查"
        return 0
    fi

    local req_major
    req_major=$(echo "$req" | cut -d. -f1)
    log_info "应用要求 macOS $req+, 当前系统 $cur_ver"

    if (( req_major > cur_major )); then
        log_error "不兼容：此应用要求 macOS $req+，当前系统为 $cur_ver，无法安装。"
        log_error "请升级 macOS 到 $req+ 后再安装。"
        return 1
    fi
    log_success "兼容性检查通过 (应用要求 $req+, 当前 $cur_ver)"
    return 0
}

# === 安装 Codex Desktop App (macOS) ===
install_codex_macos() {
    # 检查是否已安装
    if [[ -d "/Applications/Codex.app" ]] || [[ -d "/Applications/ChatGPT.app" ]]; then
        log_success "OpenAI Codex (ChatGPT) Desktop App 已安装"
        return 0
    fi

    local user_home
    user_home=$(get_user_home)
    local downloads_dir="$user_home/Downloads"
    local dmg_file="$downloads_dir/Codex.dmg"
    local compat_url="" compat_file=""

    # macOS <= 12.x: 用兼容版 (构建 5848, 26.721.41059, 主二进制 minos=12.0, 真正兼容 12.7.6)
    local cur_major
    cur_major=$(macos_major)
    if [[ "$cur_major" != "99" ]] && (( cur_major <= CODEX_COMPAT_MAX_MAJOR )); then
        log_warn "当前 macOS $(macos_full) <= 12.x, 使用兼容版 v${CODEX_COMPAT_VERSION} (构建 ${CODEX_COMPAT_BUILD})"
        compat_url="$CODEX_COMPAT_URL"
        compat_file="$downloads_dir/$(basename "$CODEX_COMPAT_URL")"
    fi

    # 下载
    log_info "正在下载 Codex Desktop App..."
    if [[ -n "$compat_url" ]]; then
        log_info "下载地址: $compat_url"
        log_info "保存路径: $compat_file"
        dmg_file="$compat_file"
    else
        log_info "下载地址: $CODEX_DMG_URL"
        log_info "保存路径: $dmg_file"
    fi
    echo ""

    mkdir -p "$downloads_dir"

    local dl_url="${compat_url:-$CODEX_DMG_URL}"
    if ! download_file "$dl_url" "$dmg_file"; then
        log_error "下载失败"
        log_info "请手动下载: $dl_url"
        return 1
    fi

    # 检查文件
    if [[ ! -f "$dmg_file" ]] || [[ ! -s "$dmg_file" ]]; then
        log_error "下载的文件不存在或为空"
        return 1
    fi

    log_info "文件大小: $(du -h "$dmg_file" | cut -f1)"

    # 挂载 DMG 或解压 ZIP (兼容版是 zip)
    local volume=""
    local is_zip=0
    if [[ "$dmg_file" == *.zip ]]; then
        is_zip=1
        log_info "正在解压 ZIP 文件..."
        local extract_dir
        extract_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-extract.XXXXXX")
        if ! unzip -q "$dmg_file" -d "$extract_dir"; then
            log_error "解压 ZIP 文件失败"
            rm -rf "$extract_dir"
            return 1
        fi
        volume="$extract_dir"
    else
        log_info "正在挂载 DMG 文件..."
        volume=$(hdiutil attach "$dmg_file" 2>/dev/null | grep 'Volumes' | awk -F '\t' '{print $NF}')
        if [[ -z "$volume" ]]; then
            log_error "挂载 DMG 文件失败"
            return 1
        fi
    fi

    # 安装到 Applications
    log_info "正在安装到 /Applications..."
    local app_name=""
    if [[ -d "$volume/Codex.app" ]]; then
        app_name="Codex.app"
    elif [[ -d "$volume/ChatGPT.app" ]]; then
        app_name="ChatGPT.app"
    fi
    if [[ -n "$app_name" ]]; then
        # 兼容性检查：app 要求 macOS 版本 > 当前系统则拒绝安装
        if ! check_macos_compat "$volume" "$app_name"; then
            if (( is_zip )); then
                rm -rf "$volume"
            else
                hdiutil detach "$volume" > /dev/null 2>&1
            fi
            return 1
        fi
        cp -R "$volume/$app_name" /Applications
    else
        log_error "未在镜像中找到 Codex.app 或 ChatGPT.app"
        if (( is_zip )); then
            rm -rf "$volume"
        else
            hdiutil detach "$volume" > /dev/null 2>&1
        fi
        return 1
    fi

    # 卸载 DMG / 清理解压目录
    if (( is_zip )); then
        rm -rf "$volume"
    else
        hdiutil detach "$volume" > /dev/null 2>&1
    fi
    rm -f "$dmg_file"

    log_success "Codex Desktop App 安装完成"
    echo ""
    echo "使用方法:"
    echo "  1. 打开 Applications 文件夹"
    echo "  2. 双击 Codex.app 启动"
    echo "  3. 配置 API Key: export OPENAI_API_KEY='sk-...'"
}

# === 安装 Codex (CLI + App) ===
install_codex() {
    local mode="${1:-all}"   # all | cli-only | app-only

    log_header "安装 OpenAI Codex"

    local os=$(detect_os)

    case "$os" in
        macos)
            # 安装 CLI (除非仅 app)
            if [[ "$mode" != "app-only" ]]; then
                install_codex_cli
            fi
            # 安装 App (除非仅 CLI)
            if [[ "$mode" != "cli-only" ]]; then
                install_codex_macos
            fi
            ;;
        windows)
            log_info "Windows 系统"
            echo ""
            echo "正在打开 Microsoft Store 下载页面..."
            start "https://apps.microsoft.com/detail/9plm9xgg6vks" 2>/dev/null || true
            ;;
        linux)
            log_warn "Linux 系统不支持 Codex Desktop App"
            echo ""
            echo "替代方案："
            echo "  1. 使用 Codex CLI: npm install -g @openai/codex"
            echo "  2. 使用 VS Code + Copilot 插件"
            ;;
        *)
            log_error "不支持的操作系统: $os"
            return 1
            ;;
    esac
}

# === 卸载 Codex ===
uninstall_codex() {
    log_header "卸载 OpenAI Codex Desktop App"

    local os=$(detect_os)

    case "$os" in
        macos)
            local removed=0
            if [[ -d "/Applications/Codex.app" ]]; then
                log_info "正在卸载 Codex.app..."
                rm -rf "/Applications/Codex.app"
                removed=1
            fi
            if [[ -d "/Applications/ChatGPT.app" ]]; then
                log_info "正在卸载 ChatGPT.app (OpenAI Codex)..."
                rm -rf "/Applications/ChatGPT.app"
                removed=1
            fi
            if [[ "$removed" -eq 1 ]]; then
                log_success "OpenAI Codex Desktop App 已卸载"
            else
                log_warn "未找到 Codex.app 或 ChatGPT.app"
            fi
            ;;
        windows)
            log_info "请在 Windows 设置 > 应用 > 已安装的应用 中卸载 Codex"
            ;;
        *)
            log_warn "当前系统不支持自动卸载"
            ;;
    esac
}

# === 查看状态 ===
show_status() {
    log_header "Codex 状态"

    local os=$(detect_os)
    echo "系统: $os"
    echo ""

    # CLI 状态
    if command -v codex &> /dev/null; then
        echo "CLI: 已安装 ($(codex --version 2>/dev/null | head -1 || echo 'codex'))"
        echo "CLI 路径: $(command -v codex)"
    else
        echo "CLI: 未安装 (安装: ./install-codex.sh --install-cli)"
    fi
    echo ""

    case "$os" in
        macos)
            if [[ -d "/Applications/Codex.app" ]]; then
                echo "安装状态: 已安装"
                echo "应用路径: /Applications/Codex.app"
            elif [[ -d "/Applications/ChatGPT.app" ]]; then
                echo "安装状态: 已安装 (ChatGPT.app = OpenAI Codex 桌面版)"
                echo "应用路径: /Applications/ChatGPT.app"
            else
                echo "安装状态: 未安装"
                echo ""
                echo "安装命令: ./install-codex.sh"
            fi
            ;;
        *)
            echo "安装状态: 请手动查看"
            ;;
    esac

    echo ""
    echo "API Key 状态:"
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        echo "  已设置 (环境变量)"
    else
        echo "  未设置"
        echo ""
        echo "配置方法:"
        echo "  export OPENAI_API_KEY='sk-...'"
    fi
}

# === 显示帮助 ===
show_help() {
    cat << 'EOF'
OpenAI Codex 安装脚本 (CLI + Desktop App)

Codex 是 OpenAI 推出的 AI 编程助手，含 CLI 与桌面应用 (ChatGPT.app/Codex.app)。

用法: ./install-codex.sh [选项]

选项:
    --install       安装 Codex CLI + Desktop App (默认)
    --install-cli   仅安装 Codex CLI (npm @openai/codex)
    --install-app   仅安装 Desktop App
    --uninstall     卸载 Codex App (保留 CLI)
    --status        查看 Codex 状态
    -h, --help      显示此帮助

功能:
    - Codex CLI: npm install -g @openai/codex
    - Desktop App: 下载 Codex.dmg 安装到 /Applications (ChatGPT.app/Codex.app)
    - 兼容性检查: 安装前验证 app 要求的 macOS 版本 <= 当前系统，不兼容则拒绝

支持系统:
    - macOS (直接下载 DMG 安装，含兼容性检查)
    - Windows (Microsoft Store)
    - Linux (仅 CLI)

配置 API Key:
    export OPENAI_API_KEY='sk-...'

示例:
    ./install-codex.sh              # 一键安装 CLI + App
    ./install-codex.sh --install-cli  # 仅装 CLI
    ./install-codex.sh --install-app  # 仅装 App
    ./install-codex.sh --status     # 查看状态
    ./install-codex.sh --uninstall  # 卸载 App

官网: https://openai.com/codex
EOF
}

# === 主函数 ===
main() {
    case "${1:-}" in
        --install | -i | "")
            install_codex "all"
            ;;
        --install-cli)
            install_codex "cli-only"
            ;;
        --install-app)
            install_codex "app-only"
            ;;
        --uninstall)
            uninstall_codex
            ;;
        --status)
            show_status
            ;;
        -h | --help)
            show_help
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

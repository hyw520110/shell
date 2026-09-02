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

# === 安装 Codex Desktop App (macOS) ===
install_codex_macos() {
    # 检查是否已安装
    if [[ -d "/Applications/Codex.app" ]]; then
        log_success "Codex Desktop App 已安装"
        return 0
    fi

    local user_home
    user_home=$(get_user_home)
    local downloads_dir="$user_home/Downloads"
    local dmg_file="$downloads_dir/Codex.dmg"

    # 下载
    log_info "正在下载 Codex Desktop App..."
    log_info "下载地址: $CODEX_DMG_URL"
    log_info "保存路径: $dmg_file"
    echo ""

    mkdir -p "$downloads_dir"

    if ! download_file "$CODEX_DMG_URL" "$dmg_file"; then
        log_error "下载失败"
        log_info "请手动下载: $CODEX_DMG_URL"
        return 1
    fi

    # 检查文件
    if [[ ! -f "$dmg_file" ]] || [[ ! -s "$dmg_file" ]]; then
        log_error "下载的文件不存在或为空"
        return 1
    fi

    log_info "文件大小: $(du -h "$dmg_file" | cut -f1)"

    # 挂载 DMG
    log_info "正在挂载 DMG 文件..."
    local volume
    volume=$(hdiutil attach "$dmg_file" 2>/dev/null | grep 'Volumes' | awk -F '\t' '{print $NF}')

    if [[ -z "$volume" ]]; then
        log_error "挂载 DMG 文件失败"
        return 1
    fi

    # 安装到 Applications
    log_info "正在安装到 /Applications..."
    if [[ -d "$volume/Codex.app" ]]; then
        cp -R "$volume/Codex.app" /Applications
    else
        log_error "未找到 Codex.app"
        hdiutil detach "$volume" > /dev/null 2>&1
        return 1
    fi

    # 卸载 DMG
    hdiutil detach "$volume" > /dev/null 2>&1
    rm -f "$dmg_file"

    log_success "Codex Desktop App 安装完成"
    echo ""
    echo "使用方法:"
    echo "  1. 打开 Applications 文件夹"
    echo "  2. 双击 Codex.app 启动"
    echo "  3. 配置 API Key: export OPENAI_API_KEY='sk-...'"
}

# === 安装 Codex Desktop App ===
install_codex() {
    log_header "安装 OpenAI Codex Desktop App"

    local os=$(detect_os)

    case "$os" in
        macos)
            install_codex_macos
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
            if [[ -d "/Applications/Codex.app" ]]; then
                log_info "正在卸载..."
                rm -rf "/Applications/Codex.app"
                log_success "Codex Desktop App 已卸载"
            else
                log_warn "未找到 Codex.app"
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
    log_header "Codex Desktop App 状态"

    local os=$(detect_os)
    echo "系统: $os"
    echo ""

    case "$os" in
        macos)
            if [[ -d "/Applications/Codex.app" ]]; then
                echo "安装状态: 已安装"
                echo "应用路径: /Applications/Codex.app"
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
OpenAI Codex Desktop App 安装脚本

Codex 是 OpenAI 推出的 AI 编程助手桌面应用，支持多智能体协作编程。

用法: ./install-codex.sh [选项]

选项:
    --install       安装 Codex Desktop App (默认)
    --uninstall     卸载 Codex
    --status        查看 Codex 状态
    -h, --help      显示此帮助

功能:
    - AI 代码生成和编辑
    - 多智能体协作编程
    - 自动化开发任务
    - 代码 diff 查看
    - 项目终端集成

支持系统:
    - macOS (直接下载 DMG 安装)
    - Windows (Microsoft Store)
    - Linux (不支持 Desktop App，请使用 CLI)

配置 API Key:
    export OPENAI_API_KEY='sk-...'

示例:
    ./install-codex.sh              # 一键安装
    ./install-codex.sh --status     # 查看状态
    ./install-codex.sh --uninstall  # 卸载

官网: https://openai.com/codex
EOF
}

# === 主函数 ===
main() {
    case "${1:-}" in
        --install | "")
            install_codex
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

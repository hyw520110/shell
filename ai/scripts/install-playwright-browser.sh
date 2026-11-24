#!/bin/bash
#
# Playwright 浏览器智能安装脚本
# 自动检测系统 Chrome，已安装则默认不下载 Chromium（可手动覆盖）
# 未安装 Chrome 则自动安装 Chromium
#

set -e

# 颜色
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

# 检测系统 Chrome（跨平台）
detect_system_chrome() {
    local chrome_path=""

    case "$(uname -s)" in
        Darwin)
            # macOS: 检测常见 Chrome 安装路径
            local paths=(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                "/Applications/Chromium.app/Contents/MacOS/Chromium"
                "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                "$HOME/Applications/Chromium.app/Contents/MacOS/Chromium"
            )
            for p in "${paths[@]}"; do
                if [[ -x "$p" ]]; then
                    chrome_path="$p"
                    break
                fi
            done
            # 也尝试 which
            if [[ -z "$chrome_path" ]]; then
                chrome_path=$(command -v "Google Chrome" 2>/dev/null || true)
            fi
            ;;
        Linux)
            # Linux: 检测常见路径和命令
            local paths=(
                "/usr/bin/google-chrome"
                "/usr/bin/google-chrome-stable"
                "/usr/bin/chromium"
                "/usr/bin/chromium-browser"
                "/snap/bin/chromium"
            )
            for p in "${paths[@]}"; do
                if [[ -x "$p" ]]; then
                    chrome_path="$p"
                    break
                fi
            done
            if [[ -z "$chrome_path" ]]; then
                chrome_path=$(command -v google-chrome 2>/dev/null || command -v google-chrome-stable 2>/dev/null || command -v chromium 2>/dev/null || command -v chromium-browser 2>/dev/null || true)
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*)
            # Windows (WSL/Git Bash)
            local win_paths=(
                "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
                "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
            )
            for p in "${win_paths[@]}"; do
                if [[ -x "$p" ]]; then
                    chrome_path="$p"
                    break
                fi
            done
            ;;
    esac

    printf '%s' "$chrome_path"
}

# 检测 Playwright 是否已配置使用系统 Chrome
detect_playwright_chrome_config() {
    # 检查环境变量
    if [[ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]]; then
        if [[ -x "$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" ]]; then
            printf '%s' "$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"
            return 0
        fi
    fi
    return 1
}


# 主逻辑
main() {
    info "Playwright 浏览器智能安装"
    echo ""

    # 1. 检查是否已配置 Playwright 使用系统 Chrome
    local configured_chrome
    if configured_chrome=$(detect_playwright_chrome_config); then
        ok "已配置 Playwright 使用系统 Chrome: $configured_chrome"
        info "跳过 Chromium 下载"
        exit 0
    fi

    # 2. 检测系统 Chrome
    local chrome_path
    chrome_path=$(detect_system_chrome)

    if [[ -n "$chrome_path" && -x "$chrome_path" ]]; then
        ok "检测到系统 Chrome: $chrome_path"
        info "Playwright 将使用系统 Chrome，跳过 Chromium 下载"
        exit 0
    else
        warn "未检测到系统 Chrome"
        info "开始下载 Chromium（Playwright 内置版本）..."
        npx playwright install chromium
        ok "Chromium 安装完成"
    fi
}

main "$@"

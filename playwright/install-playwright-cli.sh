#!/bin/bash

# Playwright CLI 一键安装配置脚本
# 支持 macOS 和 Linux
# 文档: https://github.com/microsoft/playwright-cli

set -e

# ==================== 配置 ====================
SCRIPT_NAME=$(basename "$0")
PLAYWRIGHT_CLI_VERSION="latest"
INSTALL_BROWSERS=true
INSTALL_SKILLS=true
USE_PROXY=false
HTTP_PROXY=""
HTTPS_PROXY=""
BROWSER="chromium"  # chromium, firefox, webkit, chrome, msedge

# 镜像源配置
NPM_REGISTRY="https://registry.npmmirror.com/"
PLAYWRIGHT_BREW_MIRROR="${PLAYWRIGHT_DOWNLOAD_HOST:-}"
SELECTED_MIRROR=""
SELECTED_MIRROR_NAME=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 帮助信息 ====================
USAGE="用法: ./$SCRIPT_NAME [选项]"
HELP_TEXT="
$USAGE

Playwright CLI 一键安装配置脚本

选项:
  -h, --help           显示帮助信息
  --no-browsers        不安装浏览器依赖
  --no-skills          不安装 Skills
  --browser <name>     指定浏览器 (chromium|firefox|webkit|chrome|msedge)，默认: chromium
  --all-browsers       安装所有浏览器
  --proxy <url>        设置代理 (如 http://127.0.0.1:7890)
  --registry <url>     设置 npm 镜像源
  --version <ver>      指定 playwright-cli 版本，默认: latest

示例:
  ./$SCRIPT_NAME                           # 默认安装（自动检测最快镜像）
  ./$SCRIPT_NAME --browser firefox         # 安装 firefox 浏览器
  ./$SCRIPT_NAME --all-browsers            # 安装所有浏览器
  ./$SCRIPT_NAME --proxy http://127.0.0.1:7890  # 使用代理
"

# Playwright 浏览器镜像源列表（用于自动检测）
PLAYWRIGHT_MIRRORS=(
    "official|https://cdn.playwright.dev|官方源"
    "npmmirror|https://npmmirror.com/mirrors/playwright|淘宝镜像"
    "tencent|https://mirrors.cloud.tencent.com/playwright|腾讯镜像"
)

# ==================== 日志函数 ====================
echo_info() {
    echo -e "${CYAN}[信息]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

echo_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
}

echo_warn() {
    echo -e "${YELLOW}[警告]${NC} $1" >&2
}

echo_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# ==================== 解析命令行参数 ====================
ALL_BROWSERS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "$HELP_TEXT"
            exit 0
            ;;
        --no-browsers)
            INSTALL_BROWSERS=false
            shift
            ;;
        --no-skills)
            INSTALL_SKILLS=false
            shift
            ;;
        --browser)
            BROWSER="$2"
            shift 2
            ;;
        --all-browsers)
            ALL_BROWSERS=true
            shift
            ;;
        --proxy)
            HTTP_PROXY="$2"
            HTTPS_PROXY="$2"
            USE_PROXY=true
            shift 2
            ;;
        --registry)
            NPM_REGISTRY="$2"
            shift 2
            ;;
        --version)
            PLAYWRIGHT_CLI_VERSION="$2"
            shift 2
            ;;
        *)
            echo_error "未知选项: $1"
            echo "$USAGE"
            exit 1
            ;;
    esac
done

# ==================== 检测系统 ====================
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        echo_info "检测到系统: macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        echo_info "检测到系统: Linux"
    else
        echo_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
}

# ==================== 检查 Node.js ====================
check_nodejs() {
    echo_step "检查 Node.js 环境..."
    
    if ! command -v node &> /dev/null; then
        echo_error "Node.js 未安装"
        echo_info "请先安装 Node.js 18 或更高版本"
        echo_info "推荐使用: ./node/node.sh"
        exit 1
    fi
    
    NODE_VERSION=$(node -v | sed 's/^v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    
    if [[ $NODE_MAJOR -lt 18 ]]; then
        echo_error "Node.js 版本过低: v$NODE_VERSION"
        echo_info "Playwright CLI 需要 Node.js 18 或更高版本"
        exit 1
    fi
    
    echo_success "Node.js 版本: v$NODE_VERSION"
}

# ==================== 设置 npm 镜像源 ====================
setup_npm_registry() {
    echo_step "设置 npm 镜像源..."
    
    local current_registry
    current_registry=$(npm config get registry 2>/dev/null || echo "")
    
    if [[ "$current_registry" != "$NPM_REGISTRY" ]]; then
        npm config set registry "$NPM_REGISTRY"
        echo_success "npm 镜像源已设置为: $NPM_REGISTRY"
    else
        echo_info "npm 镜像源已是: $NPM_REGISTRY"
    fi
}

# ==================== 设置代理 ====================
setup_proxy() {
    if [[ "$USE_PROXY" == true ]]; then
        echo_step "配置代理..."
        export HTTP_PROXY="$HTTP_PROXY"
        export HTTPS_PROXY="$HTTPS_PROXY"
        export http_proxy="$HTTP_PROXY"
        export https_proxy="$HTTPS_PROXY"
        
        # Playwright 浏览器下载代理
        export PLAYWRIGHT_DOWNLOAD_HOST="${HTTP_PROXY}"
        
        echo_success "代理已设置: $HTTP_PROXY"
    fi
}

# ==================== 安装 Playwright CLI ====================
install_playwright_cli() {
    echo_step "安装 @playwright/cli@$PLAYWRIGHT_CLI_VERSION..."
    
    # 检查是否已安装
    if command -v playwright-cli &> /dev/null; then
        local current_version
        current_version=$(playwright-cli --version 2>/dev/null | head -1 || echo "unknown")
        echo_info "当前已安装版本: $current_version"
        
        read -p "$(echo -e ${YELLOW}是否更新到最新版本? [y/N]: ${NC})" response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo_info "跳过更新"
            return 0
        fi
        
        npm update -g @playwright/cli
    else
        npm install -g @playwright/cli@$PLAYWRIGHT_CLI_VERSION
    fi
    
    # 验证安装
    if command -v playwright-cli &> /dev/null; then
        local version
        version=$(playwright-cli --version 2>/dev/null | head -1 || echo "installed")
        echo_success "Playwright CLI 安装完成: $version"
    else
        echo_error "Playwright CLI 安装失败"
        exit 1
    fi
}

# ==================== 安装 Skills ====================
install_skills() {
    if [[ "$INSTALL_SKILLS" == true ]]; then
        echo_step "安装 Playwright Skills..."
        
        if playwright-cli install --skills 2>/dev/null; then
            echo_success "Skills 安装完成"
        else
            echo_warn "Skills 安装失败，可稍后手动执行: playwright-cli install --skills"
        fi
    fi
}

# ==================== 检测最快镜像源 ====================
detect_fastest_mirror() {
    echo_info "检测最快的 Playwright 镜像源..."
    
    local best_mirror=""
    local best_time=99999
    local best_name=""
    local timeout=3
    
    for mirror_info in "${PLAYWRIGHT_MIRRORS[@]}"; do
        IFS='|' read -r id url name <<< "$mirror_info"
        
        # 官方源可能较慢，给更长超时时间
        if [[ "$id" == "official" ]]; then
            timeout=5
        else
            timeout=3
        fi
        
        # 使用 curl 的 time_total 获取连接时间（兼容 macOS）
        local result duration
        result=$(curl --connect-timeout "$timeout" --max-time "$timeout" -sI -w "%{time_total}" -o /dev/null "$url" 2>/dev/null)
        
        if [[ -n "$result" && "$result" != "0.000" ]]; then
            # 将秒转换为毫秒（去掉小数点）
            duration=$(echo "$result" | awk '{printf "%.0f", $1 * 1000}')
            
            echo_info "  $name: ${duration}ms"
            
            if [[ $duration -lt $best_time ]]; then
                best_time=$duration
                best_mirror="$url"
                best_name="$name"
            fi
        else
            echo_info "  $name: 不可用"
        fi
    done
    
    if [[ -n "$best_mirror" ]]; then
        echo_success "选择镜像源: $best_name ($best_mirror)"
        SELECTED_MIRROR="$best_mirror"
        SELECTED_MIRROR_NAME="$best_name"
        return 0
    else
        echo_warn "所有镜像源都不可用，将使用默认源"
        SELECTED_MIRROR=""
        return 1
    fi
}

# ==================== 安装浏览器 ====================
install_browsers() {
    if [[ "$INSTALL_BROWSERS" == true ]]; then
        echo_step "安装浏览器依赖..."
        
        # 自动检测并选择最快的镜像源
        if [[ -z "$SELECTED_MIRROR" ]]; then
            detect_fastest_mirror
        fi
        
        local install_cmd=""
        if [[ "$ALL_BROWSERS" == true ]]; then
            install_cmd="npx playwright install"
        else
            install_cmd="npx playwright install $BROWSER"
        fi
        
        # 尝试使用镜像源
        if [[ -n "$SELECTED_MIRROR" && "$SELECTED_MIRROR_NAME" != "官方源" ]]; then
            echo_info "尝试使用 $SELECTED_MIRROR_NAME 下载浏览器..."
            export PLAYWRIGHT_DOWNLOAD_HOST="$SELECTED_MIRROR"
            
            if $install_cmd 2>&1; then
                echo_success "浏览器安装完成"
            else
                echo_warn "镜像源下载失败，回退到官方源重试..."
                unset PLAYWRIGHT_DOWNLOAD_HOST
                echo_info "使用官方源下载浏览器..."
                
                if $install_cmd; then
                    echo_success "浏览器安装完成（来自官方源）"
                else
                    echo_error "浏览器安装失败，请检查网络或使用代理"
                    echo_info "手动安装命令: npx playwright install $BROWSER"
                    return 1
                fi
            fi
        else
            # 直接使用官方源
            echo_info "使用官方源下载浏览器..."
            unset PLAYWRIGHT_DOWNLOAD_HOST
            $install_cmd
            echo_success "浏览器安装完成"
        fi
        
        # 安装系统依赖 (Linux)
        if [[ "$OS" == "linux" ]]; then
            echo_info "安装系统依赖..."
            if command -v apt &> /dev/null; then
                sudo npx playwright install-deps 2>/dev/null || true
            elif command -v yum &> /dev/null; then
                sudo npx playwright install-deps 2>/dev/null || true
            fi
        fi
    fi
}

# ==================== 配置环境变量提示 ====================
show_config_hint() {
    echo ""
    echo_info "=========================================="
    echo_info "安装完成！常用命令:"
    echo_info ""
    echo_info "  playwright-cli --help              查看帮助"
    echo_info "  playwright-cli open <url>          打开网页"
    echo_info "  playwright-cli snapshot            获取页面快照"
    echo_info "  playwright-cli screenshot          截图"
    echo_info "  playwright-cli list                列出所有会话"
    echo_info "  playwright-cli show                打开可视化仪表板"
    echo_info ""
    echo_info "配置文件位置: ~/.playwright-cli/"
    echo_info "=========================================="
}

# ==================== 主函数 ====================
main() {
    echo_info "开始安装 Playwright CLI..."
    echo ""
    
    # 1. 检测系统
    detect_os
    
    # 2. 检查 Node.js
    check_nodejs
    
    # 3. 设置 npm 镜像源
    setup_npm_registry
    
    # 4. 设置代理
    setup_proxy
    
    # 5. 安装 Playwright CLI
    install_playwright_cli
    
    # 6. 安装 Skills
    install_skills
    
    # 7. 安装浏览器
    install_browsers
    
    # 8. 显示配置提示
    show_config_hint
    
    echo ""
    echo_success "Playwright CLI 安装配置完成！"
}

# 执行主函数
main "$@"

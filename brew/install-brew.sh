#!/bin/bash

# 脚本功能：一键安装并自动配置 Homebrew
# 支持系统：macOS
# 特点：支持中国镜像源加速、自动配置环境变量、代理检测

set -euo pipefail

# --- 配置 ---
OFFICIAL_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
# 推荐的国内镜像安装脚本 (由 Cunkai 提供，广受好评)
CN_INSTALL_URL="https://gitee.com/cunkai/HomebrewCN/raw/master/Homebrew.sh"

# 默认配置
USE_MIRROR=true
INSTALL_COMMON_TOOLS=true
COMMON_TOOLS=("curl" "wget" "jq")

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 函数定义 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help        显示帮助信息"
    echo "  --official        使用官方安装源 (默认使用国内镜像)"
    echo "  --no-tools        安装完成后不安装常用工具 (${COMMON_TOOLS[*]})"
    echo "  --uninstall       卸载 Homebrew"
}

# 检查 OS
check_os() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_error "此脚本仅支持 macOS 系统。"
        exit 1
    fi
}

# 检测并设置代理 (参考 node.sh)
detect_proxy() {
    if [ -n "$http_proxy" ] || [ -n "$HTTP_PROXY" ]; then
        log_info "检测到已设置代理，跳过自动检测。"
        return 0
    fi

    local common_ports=(7890 7891 1080 10808 10809)
    for port in "${common_ports[@]}"; do
        if curl -s --connect-timeout 0.5 "http://127.0.0.1:$port" > /dev/null 2>&1 || [ $? -eq 52 ]; then
            log_info "检测到本地代理端口: $port，已自动应用。"
            export http_proxy="http://127.0.0.1:$port"
            export https_proxy="http://127.0.0.1:$port"
            return 0
        fi
    done
}

# 自动配置环境变量
setup_env() {
    local shell_rc
    if [[ "$SHELL" == */zsh ]]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bash_profile"
    fi

    log_info "正在配置环境变量 ($shell_rc)..."
    
    # 确定 brew 路径 (Apple Silicon vs Intel)
    local brew_path="/usr/local/bin/brew"
    if [[ "$(uname -m)" == "arm64" ]]; then
        brew_path="/opt/homebrew/bin/brew"
    fi

    # 使用 command -v 检查命令是否真正可用，而不只是检查文件
    if command -v brew &>/dev/null; then
        if ! grep -q "brew shellenv" "$shell_rc" 2>/dev/null; then
            local eval_cmd="eval \"\$($brew_path shellenv)\""
            echo "" >> "$shell_rc"
            echo "# Homebrew" >> "$shell_rc"
            echo "$eval_cmd" >> "$shell_rc"
            log_info "环境变量已添加到 $shell_rc"
            eval "$($brew_path shellenv)"
        else
            log_info "环境变量已存在，跳过。"
        fi
    else
        log_warn "brew 命令不可用，可能安装不完整"
        return 1
    fi
}

# 安装 Homebrew
install_brew() {
    if command -v brew &>/dev/null; then
        log_info "检测到 Homebrew 已安装: $(brew -v | head -n 1)"
        setup_env
        return 0
    fi

    if [ "$USE_MIRROR" = true ]; then
        log_info "正在使用国内镜像安装 Homebrew..."
        # 注意：镜像安装脚本通常是交互式的，用户需要根据提示选择镜像源
        /bin/bash -c "$(curl -fsSL $CN_INSTALL_URL)"
    else
        log_info "正在使用官方源安装 Homebrew..."
        detect_proxy
        /bin/bash -c "$(curl -fsSL $OFFICIAL_INSTALL_URL)"
    fi

    # 重新加载环境变量
    if [ -f "$HOME/.zshrc" ]; then
        source "$HOME/.zshrc" 2>/dev/null || true
    fi
    
    # 检查 brew 是否真正安装成功
    if ! command -v brew &>/dev/null; then
        log_error "brew 安装可能失败，命令不可用"
        log_info "请手动检查 Homebrew 安装状态，或重新运行此脚本"
        return 1
    fi
    
    setup_env
    log_info "Homebrew 安装成功！"
}

# 卸载 Homebrew
uninstall_brew() {
    log_warn "正在准备卸载 Homebrew..."
    if [ "$USE_MIRROR" = true ]; then
        /bin/bash -c "$(curl -fsSL https://gitee.com/cunkai/HomebrewCN/raw/master/HomebrewUninstall.sh)"
    else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
    fi
}

# 安装常用工具
install_tools() {
    if [ "$INSTALL_COMMON_TOOLS" = true ]; then
        # 检查 brew 命令是否可用
        if ! command -v brew &>/dev/null; then
            log_warn "brew 命令不可用，跳过常用工具安装"
            log_info "请先确保 Homebrew 安装成功"
            return 1
        fi
        log_info "正在安装常用工具: ${COMMON_TOOLS[*]}..."
        brew install "${COMMON_TOOLS[@]}"
    fi
}

# --- 主逻辑 ---
main() {
    check_os

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            --official) USE_MIRROR=false; shift ;;
            --no-tools) INSTALL_COMMON_TOOLS=false; shift ;;
            --uninstall) uninstall_brew; exit 0 ;;
            *) log_error "未知选项: $1"; show_help; exit 1 ;;
        esac
    done

    install_brew
    install_tools

    log_info "Homebrew 环境配置完成！"
    log_info "请执行 'source ~/.zshrc' (或重新打开终端) 以生效。"
}

main "$@"

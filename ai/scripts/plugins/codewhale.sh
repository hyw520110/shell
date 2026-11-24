#!/usr/bin/env bash
# AI Hub CodeWhale 插件
# 用于 CodeWhale (DeepSeek-TUI) 的自动化安装、配置与状态检查

PLUGIN_NAME="codewhale"
PLUGIN_VERSION="1.0.0"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

plugin_install() {
    local tool_id="$1"
    local tool_name="$2"
    
    log_info "开始安装 $tool_name..."
    
    # 优先使用 npm 安装，因为它跨平台支持最好且官方推荐
    if command -v npm >/dev/null 2>&1; then
        log_info "正在通过 npm 安装 codewhale..."
        npm install -g codewhale --registry "${NPM_REGISTRY:-https://registry.npmmirror.com}"
    else
        log_error "未找到 npm，无法完成自动安装。请先安装 Node.js 或手动安装 CodeWhale。"
        return 1
    fi
    
    # 检查安装结果
    if command -v codewhale >/dev/null 2>&1 && command -v codewhale-tui >/dev/null 2>&1; then
        success_log "$tool_name 安装成功！"
        log_info "建议运行 'codewhale setup' 来配置您的 API Key。"
        return 0
    else
        log_error "安装似乎不完整，请检查 PATH 是否包含 npm 全局路径。"
        return 1
    fi
}

plugin_uninstall() {
    local tool_id="$1"
    local tool_name="$2"
    
    log_info "开始卸载 $tool_name..."
    
    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g codewhale
        log_info "$tool_name 卸载完成。"
    else
        log_warn "未找到 npm，请手动清理二进制文件。"
    fi
    return 0
}

plugin_status() {
    if command -v codewhale >/dev/null 2>&1 && command -v codewhale-tui >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

plugin_update() {
    log_info "正在更新 $2..."
    plugin_install "$@"
}

main() {
    local action="$1"
    local tool_id="$2"
    local tool_name="${3:-$tool_id}"
    
    case "$action" in
        install) plugin_install "$tool_id" "$tool_name" ;;
        uninstall) plugin_uninstall "$tool_id" "$tool_name" ;;
        status) plugin_status "$tool_id" ;;
        update) plugin_update "$tool_id" "$tool_name" ;;
        *) echo "Usage: $0 {install|uninstall|status|update} <tool_id> [tool_name]"; exit 1 ;;
    esac
}

main "$@"

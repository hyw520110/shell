#!/usr/bin/env bash
# AI Hub ClawX 插件
# 用于 ClawX 的自动化安装/卸载

PLUGIN_NAME="clawx"
PLUGIN_VERSION="1.0.0"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ClawX 安装路径
CLAWX_APP_PATH="/Applications/ClawX.app"
CLAWX_BIN_PATH="/usr/local/bin/ClawX"

plugin_install() {
    local tool_id="$1"
    local tool_name="$2"
    
    log_info "开始安装 $tool_name..."
    
    # 检查是否已安装
    if [[ -d "$CLAWX_APP_PATH" ]]; then
        log_info "$tool_name 已安装"
        return 0
    fi
    
    # 下载 ClawX
    local download_url="https://github.com/openclaw/clawx/releases/latest/download/ClawX-macos.dmg"
    local temp_dmg="/tmp/ClawX-install.dmg"
    
    log_info "正在下载 $tool_name..."
    if ! curl -L -o "$temp_dmg" "$download_url" 2>/dev/null; then
        log_error "下载失败，请手动下载: $download_url"
        return 1
    fi
    
    # 挂载 DMG
    log_info "正在挂载 DMG..."
    local mount_point=$(hdiutil attach "$temp_dmg" 2>/dev/null | grep -o '/Volumes/[^ ]*' | head -1)
    
    if [[ -z "$mount_point" ]]; then
        log_error "挂载 DMG 失败"
        rm -f "$temp_dmg"
        return 1
    fi
    
    # 复制到应用程序目录
    log_info "正在安装到应用程序目录..."
    cp -R "$mount_point/ClawX.app" "$CLAWX_APP_PATH" 2>/dev/null || {
        log_error "安装失败"
        hdiutil detach "$mount_point" 2>/dev/null
        rm -f "$temp_dmg"
        return 1
    }
    
    # 卸载 DMG
    hdiutil detach "$mount_point" 2>/dev/null
    rm -f "$temp_dmg"
    
    # 设置权限
    chmod -R 755 "$CLAWX_APP_PATH" 2>/dev/null
    
    log_info "$tool_name 安装成功！"
    return 0
}

plugin_uninstall() {
    local tool_id="$1"
    local tool_name="$2"
    
    log_info "开始卸载 $tool_name..."
    
    if [[ ! -d "$CLAWX_APP_PATH" ]]; then
        log_info "$tool_name 未安装"
        return 0
    fi
    
    # 删除应用
    rm -rf "$CLAWX_APP_PATH"
    rm -f "$CLAWX_BIN_PATH"
    
    log_info "$tool_name 卸载成功！"
    return 0
}

plugin_status() {
    if [[ -d "$CLAWX_APP_PATH" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

plugin_update() {
    plugin_uninstall "$@"
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

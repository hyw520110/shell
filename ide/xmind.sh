#!/bin/bash
# XMind 安装脚本（macOS）
# 官方下载页 302 重定向到 dl3.xmind.app 的真实 dmg（URL 带版本号，动态解析）
# 用法：./install-xmind.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="XMind"
APP_GLOB="XMind*.app"
TARGET="/Applications/XMind.app"

# 官方 mac 下载页（302 -> dl3.xmind.app/<真实dmg>）
DOWNLOAD_PAGE="https://xmind.app/zen/download/mac/"

case "${1:-}" in
    --status)
        if [[ -d "$TARGET" ]]; then
            echo "安装状态: 已安装"
            defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | sed 's/^/  版本: /'
        else
            echo "安装状态: 未安装"
        fi
        exit 0
        ;;
    --uninstall)
        if [[ -d "$TARGET" ]]; then
            rm -rf "$TARGET" && echo "已卸载 $APP_NAME"
        else
            echo "未安装 $APP_NAME"
        fi
        exit 0
        ;;
    --print-url)
        # 跟随重定向拿真实 dmg URL
        curl -sIL --max-time 15 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" "$DOWNLOAD_PAGE" 2>/dev/null | grep -i '^location:' | tail -1 | tr -d '\r' | awk '{print $2}'
        exit 0
        ;;
esac

if [[ -d "$TARGET" ]]; then
    echo "$APP_NAME 已安装，跳过"
    exit 0
fi

# 动态解析真实 dmg URL（302 location）
REAL_URL=$(curl -sIL --max-time 15 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" "$DOWNLOAD_PAGE" 2>/dev/null | grep -i '^location:' | tail -1 | tr -d '\r' | awk '{print $2}')
if [[ -z "$REAL_URL" ]]; then
    log_error "无法解析 XMind 下载 URL"
    exit 1
fi
log_info "解析到 XMind 下载地址: $REAL_URL"

# 用 common 框架下载+安装（dmg 类型）
install_app "$APP_NAME" "$REAL_URL" "dmg" "$APP_GLOB"

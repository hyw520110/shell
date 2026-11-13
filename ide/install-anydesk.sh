#!/bin/bash
# AnyDesk 安装脚本（macOS）
# 官方：https://download.anydesk.com/anydesk.dmg（x64；arm64 用官网下载页选择）
# 用法：./install-anydesk.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="AnyDesk"
APP_GLOB="AnyDesk.app"
TARGET="/Applications/AnyDesk.app"

# x64 官方直链；arm64 无固定直链（官网下载页）
URL="https://download.anydesk.com/anydesk.dmg"

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
        echo "$URL"
        exit 0
        ;;
esac

if [[ -d "$TARGET" ]]; then
    echo "$APP_NAME 已安装，跳过"
    exit 0
fi

if [[ "$(uname -m)" == "arm64" ]]; then
    log_warn "当前为 arm64，AnyDesk 官方 x64 直链可用（Rosetta），或从 https://anydesk.com/en/downloads/mac-os 下载 arm64"
fi

install_app "$APP_NAME" "$URL" "dmg" "$APP_GLOB"

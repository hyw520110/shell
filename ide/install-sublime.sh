#!/bin/bash
# Sublime Text 安装脚本（macOS）
# 官方下载：https://download.sublimetext.com/sublime_text_build_<ver>_mac.zip
# 用法：./install-sublime.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="Sublime Text"
APP_GLOB="Sublime Text.app"
TARGET="/Applications/Sublime Text.app"

# 最新稳定版 build（可从官网页面读取，此处固定为已验证可达的 4215）
BUILD="${SUBLIME_BUILD:-4215}"
URL="https://download.sublimetext.com/sublime_text_build_${BUILD}_mac.zip"

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

install_app "$APP_NAME" "$URL" "zip" "$APP_GLOB"

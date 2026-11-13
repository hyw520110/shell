#!/bin/bash
# Chat2DB 安装脚本（macOS）
# 官方 GitHub release：https://github.com/OtterMind/Chat2DB/releases
# 用法：./install-chat2db.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="Chat2DB"
APP_GLOB="Chat2DB.app"
TARGET="/Applications/Chat2DB.app"

# x64 本机 -> x64 dmg；arm64 -> arm64
ARCH="x64"
[[ "$(uname -m)" == "arm64" ]] && ARCH="arm64"
VERSION="${CHAT2DB_VERSION:-5.3.8}"
URL="https://github.com/OtterMind/Chat2DB/releases/download/v${VERSION}/Chat2DB-Community-${VERSION}-${ARCH}.dmg"

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

install_app "$APP_NAME" "$URL" "dmg" "$APP_GLOB"

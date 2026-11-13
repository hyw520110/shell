#!/bin/bash
# VLC 安装脚本（macOS）
# 官方：https://get.videolan.org/vlc/last/macosx/
# 用法：./install-vlc.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="VLC"
APP_GLOB="VLC.app"
TARGET="/Applications/VLC.app"

# 本机 x64 -> intel64；arm64 -> arm64
ARCH="intel64"
[[ "$(uname -m)" == "arm64" ]] && ARCH="arm64"
VERSION="${VLC_VERSION:-3.0.24}"
URL="https://get.videolan.org/vlc/${VERSION}/macosx/vlc-${VERSION}-${ARCH}.dmg"

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

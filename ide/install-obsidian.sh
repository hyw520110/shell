#!/bin/bash
# Obsidian 安装脚本（macOS）
# 官方 GitHub release：https://github.com/obsidianmd/obsidian-releases/releases
# 用法：./install-obsidian.sh [--status|--uninstall]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-app-common.sh"

APP_NAME="Obsidian"
APP_GLOB="Obsidian.app"
TARGET="/Applications/Obsidian.app"

# 最新稳定版（GitHub release，已验证可达 1.15.1）
VERSION="${OBSIDIAN_VERSION:-1.15.1}"
URL="https://github.com/obsidianmd/obsidian-releases/releases/download/v${VERSION}/Obsidian-${VERSION}.dmg"

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

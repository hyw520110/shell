#!/bin/bash
set -e

# 显示帮助信息
show_help() {
    cat << EOF
Cursor AI 编辑器安装脚本

安装 Cursor - 基于 VS Code 的 AI 驱动代码编辑器，提供智能编程助手。

用法: ./install-cursor.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息

说明:
    - 基于 VS Code 构建
    - AI 代码助手和自动补全
    - 支持多种编程语言
    - 兼容 VS Code 插件
    - 自动下载并安装

特性:
    - AI 代码生成
    - 智能代码补全
    - 代码重构建议
    - Bug 自动修复
    - 代码解释功能

示例:
    ./install-cursor.sh              # 安装 Cursor
    ./install-cursor.sh --version    # 显示版本信息

使用方式:
    # 安装后启动
    cursor

    # 查看 AI 助手
    Cursor + Tab (AI 补全)

验证安装:
    cursor --version

注意事项:
    - 需要网络连接下载
    - 支持 macOS 和 Linux
    - 建议使用官方账号获得更多功能

更多信息: https://cursor.sh/

EOF
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Cursor安装脚本版本: 1.0"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 主安装逻辑
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
mkdir -p "$DOWNLOAD_DIR"

# 优先走 Cursor 官方下载入口（cursor.com/api/download -> 302 到 dmgs 托管的
# Cursor.dmg）。原来的第三方 fork 仓库 yongpin/cursor-free-vip 既非官方也常不可达
# （raw.githubusercontent.com 连接被重置），且安装"免费 VIP"逻辑不该出现在官方安装器里。
CURL_ARCH="$(uname -m)"
[ "$CURL_ARCH" = "arm64" ] || CURL_ARCH="x64"
CURL_DMG="$DOWNLOAD_DIR/Cursor.dmg"

# Cursor 官方 API 需要 platform + releaseTrack 参数，返回 JSON
# {"downloadUrl":"https://downloads.cursor.com/production/<sha>/darwin/<arch>/Cursor-darwin-<arch>.dmg",...}
# 裸 curl cursor.com/api/download 会 400（Platform is required）。
CURL_API="https://cursor.com/api/download?platform=darwin&releaseTrack=stable"
DL_URL=""

fetch_cursor_url() {
    local tmp
    tmp=$(mktemp /tmp/cursor-api.XXXXXX 2>/dev/null || echo /tmp/cursor-api.json)
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$CURL_API" /tmp "$(basename "$tmp")" >/dev/null 2>&1 || true
    else
        curl -fsSL --max-time 60 "$CURL_API" -o "$tmp" 2>/dev/null || true
    fi
    if [ -s "$tmp" ]; then
        DL_URL=$(python3 -c "import json,sys; d=json.load(open('$tmp')); print(d.get('downloadUrl',''))" 2>/dev/null)
    fi
    rm -f "$tmp"
    if [ -z "$DL_URL" ]; then
        DL_URL="https://downloader.cursor.sh/darwin/${CURL_ARCH}/stable"
    fi
}

if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
    echo "使用 adl 下载 Cursor 官方安装包（先解析 downloadUrl）..."
    fetch_cursor_url
    echo "下载地址: $DL_URL"
    adl "$DL_URL" "$DOWNLOAD_DIR" "$(basename "$CURL_DMG")"
else
    echo "使用 curl 下载 Cursor 官方安装包（先解析 downloadUrl）..."
    fetch_cursor_url
    echo "下载地址: $DL_URL"
    curl -fSL --retry 3 --connect-timeout 20 --max-time 600 -o "$CURL_DMG" "$DL_URL"
fi

if [ ! -s "$CURL_DMG" ]; then
    echo "[WARN] 官方源下载失败，回退到第三方镜像..."
    TMP_SCRIPT="$DOWNLOAD_DIR/cursor-free-vip-install.sh"
    URL="https://raw.githubusercontent.com/yeongpin/cursor-free-vip/main/scripts/install.sh"
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$URL" "$DOWNLOAD_DIR" "$(basename "$TMP_SCRIPT")"
    else
        curl -fsSLk "$URL" -o "$TMP_SCRIPT"
    fi
    [ -f "$TMP_SCRIPT" ] && chmod +x "$TMP_SCRIPT" && "$TMP_SCRIPT"
    echo "Cursor 安装完成（第三方源）！"
    exit $?
fi

echo "下载完成: $CURL_DMG ($(du -h "$CURL_DMG" | awk '{print $1}'))"
VOL=$(hdiutil attach "$CURL_DMG" -nobrowse -quiet 2>/dev/null | grep -oE '/Volumes/.*$' | head -1)
if [ -z "$VOL" ] || [ ! -d "$VOL" ]; then
    echo "[ERROR] DMG 挂载失败" >&2
    exit 1
fi
APP_SRC=$(find "$VOL" -maxdepth 1 -iname '*.app' | head -1)
if [ -z "$APP_SRC" ]; then
    hdiutil detach "$VOL" -force -quiet 2>/dev/null || true
    echo "[ERROR] DMG 内未找到 .app" >&2
    exit 1
fi
cp -R "$APP_SRC" /Applications/ 2>/dev/null || sudo cp -R "$APP_SRC" /Applications/
hdiutil detach "$VOL" -force -quiet 2>/dev/null || hdiutil detach "$VOL" -force -quiet 2>/dev/null || true

if [ -d "/Applications/Cursor.app" ]; then
    echo "Cursor 安装完成：/Applications/Cursor.app"
    # 默认安装成功即删除安装包；KEEP_PACKAGE=1 时保留
    if [ "${KEEP_PACKAGE:-0}" != "1" ]; then
        rm -f -- "$CURL_DMG" "$CURL_DMG.url" 2>/dev/null || true
        echo "已删除安装包: $CURL_DMG"
    fi
else
    echo "[ERROR] 安装失败，/Applications/Cursor.app 不存在" >&2
    exit 1
fi

#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}      ClawX 安装脚本 (macOS/Linux/Windows)${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

check_command() {
    command -v "$1" &> /dev/null
}

get_latest_version() {
    curl -s "https://api.github.com/repos/ValueCell-ai/ClawX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

get_download_url() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local download_url=""

    case "$os" in
        darwin)
            if [[ "$arch" == "arm64" ]]; then
                download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-mac-arm64.dmg"
            else
                download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-mac-x64.dmg"
            fi
            ;;
        win32|windows)
            if [[ "$arch" == "arm64" ]]; then
                download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-win-arm64.exe"
            else
                download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-win-x64.exe"
            fi
            ;;
        linux)
            if command -v dpkg &> /dev/null; then
                if [[ "$arch" == "arm64" ]]; then
                    download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-arm64.deb"
                else
                    download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-amd64.deb"
                fi
            elif command -v rpm &> /dev/null; then
                download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-x86_64.rpm"
            else
                if [[ "$arch" == "arm64" ]]; then
                    download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-arm64.AppImage"
                else
                    download_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-x86_64.AppImage"
                fi
            fi
            ;;
    esac

    echo "$download_url"
}

check_clawx_installed() {
    case "$(uname)" in
        Darwin)
            test -d "/Applications/ClawX.app"
            ;;
        Linux)
            command -v ClawX &> /dev/null || test -f "/usr/bin/ClawX" || test -f "/usr/local/bin/ClawX"
            ;;
        MINGW*|CYGWIN*|MSYS*)
            command -v ClawX.exe &> /dev/null || test -f "$PROGRAMFILES/ClawX/ClawX.exe"
            ;;
    esac
}

get_system_info() {
    local os=""
    local arch=$(uname -m)

    case "$(uname)" in
        Darwin)  os="darwin" ;;
        Linux)   os="linux" ;;
        MINGW*|CYGWIN*|MSYS*) os="win32" ;;
        *)       echo -e "${RED}❌ 不支持的操作系统${NC}"; exit 1 ;;
    esac

    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
        arch="arm64"
    else
        arch="x64"
    fi

    echo "$os $arch"
}

install_darwin() {
    local dmg_path="/tmp/ClawX.dmg"
    local mount_point="/Volumes/ClawX"

    echo -e "${YELLOW}正在下载 ClawX...${NC}"
    curl -L -o "$dmg_path" "$1"

    echo "正在挂载 DMG..."
    hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse

    echo "正在安装到 Applications..."
    if [ -d "/Applications/ClawX.app" ]; then
        rm -rf "/Applications/ClawX.app"
    fi
    cp -R "$mount_point/ClawX.app" "/Applications/"

    echo "正在卸载 DMG..."
    hdiutil detach "$mount_point"

    rm -f "$dmg_path"

    echo -e "${GREEN}✅ 安装成功！${NC}"
    echo ""
    echo -e "启动 ClawX: ${YELLOW}open -a ClawX${NC}"
}

install_linux() {
    local deb_url="$1"
    local rpm_url="$2"
    local appimage_url="$3"
    local download_file="/tmp/ClawX"

    if command -v dpkg &> /dev/null; then
        echo -e "${YELLOW}正在下载 DEB 包...${NC}"
        curl -L -o "${download_file}.deb" "$deb_url"
        echo "正在安装..."
        sudo dpkg -i "${download_file}.deb" || sudo apt-get -f install -y
        rm -f "${download_file}.deb"
        echo -e "${GREEN}✅ 安装成功！${NC}"
        echo -e "启动 ClawX: ${YELLOW}ClawX${NC}"
    elif command -v rpm &> /dev/null; then
        echo -e "${YELLOW}正在下载 RPM 包...${NC}"
        curl -L -o "${download_file}.rpm" "$rpm_url"
        echo "正在安装..."
        sudo rpm -i "${download_file}.rpm"
        rm -f "${download_file}.rpm"
        echo -e "${GREEN}✅ 安装成功！${NC}"
        echo -e "启动 ClawX: ${YELLOW}ClawX${NC}"
    else
        echo -e "${YELLOW}正在下载 AppImage...${NC}"
        curl -L -o "${download_file}.AppImage" "$appimage_url"
        chmod +x "${download_file}.AppImage"
        echo -e "${GREEN}✅ 下载成功！${NC}"
        echo ""
        echo -e "AppImage 已下载到: ${YELLOW}${download_file}.AppImage${NC}"
        echo -e "运行 ClawX: ${YELLOW}${download_file}.AppImage${NC}"
    fi
}

install_windows() {
    local exe_path="$TEMP/ClawX-Setup.exe"

    echo -e "${YELLOW}正在下载 ClawX 安装程序...${NC}"
    curl -L -o "$exe_path" "$1"

    echo "正在启动安装程序..."
    "$exe_path"

    rm -f "$exe_path"
}

main() {
    if check_clawx_installed; then
        echo -e "${GREEN}✅ ClawX 已安装${NC}"
        echo ""
        read -p "是否要重新安装？(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}取消安装${NC}"
            exit 0
        fi
    fi

    echo -e "${YELLOW}正在获取最新版本...${NC}"
    local version=$(get_latest_version)
    if [ -z "$version" ]; then
        echo -e "${RED}❌ 无法获取最新版本${NC}"
        exit 1
    fi
    echo -e "最新版本: ${GREEN}$version${NC}"
    echo ""

    read -r os arch <<< "$(get_system_info)"
    echo "检测到平台: $os ($arch)"

    local download_url=$(get_download_url "$version" "$os" "$arch")
    if [ -z "$download_url" ]; then
        echo -e "${RED}❌ 不支持的平台${NC}"
        exit 1
    fi
    echo "下载链接: $download_url"
    echo ""

    case "$os" in
        darwin)
            install_darwin "$download_url"
            ;;
        linux)
            local deb_url=$(get_download_url "$version" "$os" "$arch")
            local rpm_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-x86_64.rpm"
            local appimage_url="https://github.com/ValueCell-ai/ClawX/releases/download/${version}/ClawX-${version}-linux-${arch}.AppImage"
            install_linux "$deb_url" "$rpm_url" "$appimage_url"
            ;;
        win32)
            install_windows "$download_url"
            ;;
    esac

    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${GREEN}ClawX 特性：${NC}"
    echo -e "  • OpenClaw AI Agent 图形管理界面"
    echo -e "  • 多渠道 AI 对话管理"
    echo -e "  • 定时任务自动化"
    echo -e "  • Skills 市场"
    echo -e "  • 安全的 API 密钥存储"
    echo -e "${BLUE}================================================${NC}"
}

main

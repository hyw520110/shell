#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_command() {
    command -v "$1" &> /dev/null
}

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}      Devin IDE 安装脚本 (macOS/Linux/Windows)${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

check_devin_installed() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        [ -d '/Applications/Devin.app' ]
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        command -v devin-desktop &> /dev/null
    elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        [ -d '/c/Program Files/Devin' ] || [ -d '/c/Program Files (x86)/Devin' ]
    else
        return 1
    fi
}

if check_devin_installed; then
    echo -e "${GREEN}✅ Devin IDE 已安装${NC}"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        version=$(defaults read /Applications/Devin.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "已安装")
        echo -e "  版本: ${YELLOW}$version${NC}"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        devin-desktop --version 2>/dev/null || echo -e "  版本: 已安装"
    fi
    
    echo ""
    read -p "是否要重新安装？(y/N): " REINSTALL
    if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}取消安装${NC}"
        exit 0
    fi
fi

echo -e "${YELLOW}开始安装 Devin IDE...${NC}"
echo ""

case "$(uname)" in
    Darwin)
        echo "检测到 macOS 系统"
        
        # 检测架构
        arch=$(uname -m)
        download_url=""
        
        if [[ "$arch" == "arm64" ]]; then
            echo "检测到 Apple Silicon (arm64)"
            download_url="https://devin.ai/download?platform=mac&arch=arm64"
        else
            echo "检测到 Intel (x64)"
            download_url="https://devin.ai/download?platform=mac&arch=x64"
        fi
        
        echo "正在下载 Devin IDE..."
        dmg_file="/tmp/Devin-installer.dmg"
        
        if check_command curl; then
            curl -L "$download_url" -o "$dmg_file"
        elif check_command wget; then
            wget -O "$dmg_file" "$download_url"
        else
            echo -e "${RED}❌ 缺少 curl 或 wget${NC}"
            exit 1
        fi
        
        if [[ ! -f "$dmg_file" ]]; then
            echo -e "${RED}❌ 下载失败${NC}"
            exit 1
        fi
        
        echo "正在挂载 DMG 文件..."
        mount_dir="/tmp/devin-mount-$$"
        mkdir -p "$mount_dir"
        hdiutil attach "$dmg_file" -mountpoint "$mount_dir" -nobrowse -quiet
        
        echo "正在复制应用到 Applications 文件夹..."
        cp -R "$mount_dir/Devin.app" /Applications/ 2>/dev/null || cp -R "$mount_dir"/*.app /Applications/
        
        echo "正在卸载 DMG 文件..."
        hdiutil detach "$mount_dir" -quiet
        rm -f "$dmg_file"
        rmdir "$mount_dir"
        
        if check_devin_installed; then
            echo -e "${GREEN}✅ 安装成功！${NC}"
            echo ""
            echo -e "启动 Devin: ${YELLOW}open -a Devin${NC}"
            echo -e "或者在 Spotlight 中搜索 \"Devin\""
        else
            echo -e "${RED}❌ 安装失败${NC}"
            exit 1
        fi
        ;;
        
    Linux)
        echo "检测到 Linux 系统"
        
        arch=$(uname -m)
        download_url=""
        
        if command -v apt-get &> /dev/null; then
            echo "正在通过 apt 安装..."
            
            # 添加 Devin 官方仓库
            curl -fsSL https://apt.devin.ai/debian/devin-desktop.gpg | sudo gpg --dearmor -o /usr/share/keyrings/devin-desktop.gpg
            echo "deb [signed-by=/usr/share/keyrings/devin-desktop.gpg] https://apt.devin.ai/debian stable main" | sudo tee /etc/apt/sources.list.d/devin-desktop.list > /dev/null
            
            sudo apt-get update
            sudo apt-get install -y devin-desktop
            
            if check_devin_installed; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "启动 Devin: ${YELLOW}devin-desktop${NC}"
            else
                echo -e "${RED}❌ 安装失败${NC}"
                exit 1
            fi
            
        elif command -v yum &> /dev/null; then
            echo "正在通过 yum 安装..."
            
            # 添加 Devin 官方仓库
            sudo rpm --import https://yum.devin.ai/devin-desktop.gpg
            sudo yum-config-manager --add-repo https://yum.devin.ai/devin-desktop.repo
            
            sudo yum install -y devin-desktop
            
            if check_devin_installed; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "启动 Devin: ${YELLOW}devin-desktop${NC}"
            else
                echo -e "${RED}❌ 安装失败${NC}"
                exit 1
            fi
            
        else
            echo -e "${RED}❌ 不支持的包管理器，请使用 apt 或 yum${NC}"
            exit 1
        fi
        ;;
        
    MINGW*|CYGWIN*|MSYS*)
        echo "检测到 Windows 系统"
        
        if check_command winget; then
            echo "正在通过 winget 安装..."
            winget install Cognition.Devin --accept-source-agreements --accept-package-agreements
            
            if check_devin_installed; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "请在开始菜单中找到 Devin 并启动"
            else
                echo -e "${RED}❌ 安装失败${NC}"
                exit 1
            fi
        else
            echo -e "${RED}❌ winget 未安装${NC}"
            echo "请从官网下载安装: https://devin.ai/download"
            exit 1
        fi
        ;;
        
    *)
        echo -e "${RED}❌ 不支持的操作系统: $OSTYPE${NC}"
        echo "Devin IDE 支持: macOS, Linux, Windows"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}Devin IDE 特性：${NC}"
echo -e "  • AI 辅助编程和代码生成"
echo -e "  • 深度上下文理解"
echo -e "  • Agent 协作模式"
echo -e "  • Flow 模式自主编程"
echo -e "  • 多项目管理和记忆"
echo -e "${BLUE}================================================${NC}"

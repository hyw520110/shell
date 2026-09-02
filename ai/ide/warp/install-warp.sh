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
echo -e "${BLUE}      Warp 终端安装脚本 (macOS/Linux/Windows)${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

check_warp_installed() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew list --cask warp &> /dev/null
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        command -v warp-terminal &> /dev/null || command -v warp &> /dev/null
    elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win32"* ]]; then
        command -v warp &> /dev/null
    else
        return 1
    fi
}

if check_warp_installed; then
    echo -e "${GREEN}✅ Warp 终端已安装${NC}"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local version=$(brew list --cask warp --versions 2>/dev/null | head -1)
        echo -e "  版本: ${YELLOW}$version${NC}"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        warp --version 2>/dev/null || echo -e "  版本: 已安装"
    fi
    
    echo ""
    read -p "是否要重新安装？(y/N): " REINSTALL
    if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}取消安装${NC}"
        exit 0
    fi
fi

echo -e "${YELLOW}开始安装 Warp 终端...${NC}"
echo ""

case "$(uname)" in
    Darwin)
        echo "检测到 macOS 系统"
        
        if ! check_command brew; then
            echo -e "${RED}❌ Homebrew 未安装${NC}"
            echo "请先安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
        
        echo "正在通过 Homebrew 安装..."
        brew install --cask warp
        
        if check_warp_installed; then
            echo -e "${GREEN}✅ 安装成功！${NC}"
            echo ""
            echo -e "启动 Warp: ${YELLOW}open -a Warp${NC}"
            echo -e "或者在 Spotlight 中搜索 \"Warp\""
        else
            echo -e "${RED}❌ 安装失败${NC}"
            exit 1
        fi
        ;;
        
    Linux)
        echo "检测到 Linux 系统"
        
        local arch=$(uname -m)
        local download_url=""
        
        if command -v apt-get &> /dev/null; then
            echo "正在通过 apt 安装..."
            wget -q --content-disposition "https://app.warp.dev/download?package=deb" -O /tmp/warp-terminal.deb
            
            if sudo apt-get install -y /tmp/warp-terminal.deb; then
                rm -f /tmp/warp-terminal.deb
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "启动 Warp: ${YELLOW}warp-terminal${NC}"
            else
                rm -f /tmp/warp-terminal.deb
                echo -e "${RED}❌ 安装失败${NC}"
                exit 1
            fi
            
        elif command -v yum &> /dev/null; then
            echo "正在通过 yum 安装..."
            wget -q --content-disposition "https://app.warp.dev/download?package=rpm" -O /tmp/warp-terminal.rpm
            
            if sudo yum install -y /tmp/warp-terminal.rpm; then
                rm -f /tmp/warp-terminal.rpm
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "启动 Warp: ${YELLOW}warp-terminal${NC}"
            else
                rm -f /tmp/warp-terminal.rpm
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
            winget install Warp.Warp --accept-source-agreements --accept-package-agreements
            
            if check_warp_installed; then
                echo -e "${GREEN}✅ 安装成功！${NC}"
                echo ""
                echo -e "请在开始菜单中找到 Warp 并启动"
            else
                echo -e "${RED}❌ 安装失败${NC}"
                exit 1
            fi
        else
            echo -e "${RED}❌ winget 未安装${NC}"
            echo "请从官网下载安装: https://warp.dev"
            exit 1
        fi
        ;;
        
    *)
        echo -e "${RED}❌ 不支持的操作系统: $OSTYPE${NC}"
        echo "Warp 支持: macOS, Linux, Windows"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}Warp 特性：${NC}"
echo -e "  • AI 辅助命令搜索和生成"
echo -e "  • 命令块和历史记录"
echo -e "  • 团队协作和共享"
echo -e "  • 现代化界面"
echo -e "${BLUE}================================================${NC}"

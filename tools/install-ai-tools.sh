#!/bin/bash

# AI Tools Installer for Qwen CLI, Gemini CLI, and Claude Code
# Compatible with Linux and macOS

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logo
print_logo() {
    echo -e "${CYAN}"
    cat << "EOF"
   █████╗ ██╗    ████████╗ ██████╗  ██████╗ ██╗     ███████╗
  ██╔══██╗██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
  ███████║██║       ██║   ██║   ██║██║   ██║██║     ███████╗
  ██╔══██║██║       ██║   ██║   ██║██║   ██║██║     ╚════██║
  ██║  ██║██║       ██║   ╚██████╔╝╚██████╔╝███████╗███████║
  ╚═╝  ╚═╝╚═╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
                                                            
  ████████╗███████╗██████╗ ███████╗███████╗███████╗██████╗ 
  ╚══██╔══╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██╔══██╗
     ██║   █████╗  ██████╔╝█████╗  ███████╗█████╗  ██████╔╝
     ██║   ██╔══╝  ██╔══██╗██╔══╝  ╚════██║██╔══╝  ██╔══██╗
     ██║   ███████╗██║  ██║███████╗███████║███████╗██║  ██║
     ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝
EOF
    echo -e "${NC}"
}

# Detect OS
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS="macOS"
    elif [[ "$(uname)" == "Linux" ]]; then
        OS="Linux"
    else
        echo -e "${RED}❌ 不支持的操作系统${NC}"
        exit 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check installed tools
check_tools() {
    echo -e "${CYAN}🔍 检查已安装的AI工具...${NC}"
    
    # Check Qwen CLI
    if command_exists qwen; then
        QWEN_VERSION=$(qwen --version 2>/dev/null || echo "unknown")
        echo -e "1. ${GREEN}✅ Qwen CLI${NC} ($QWEN_VERSION) - 已安装"
        QWEN_INSTALLED=true
    else
        echo -e "1. ${YELLOW}⚠️ Qwen CLI${NC} - 未安装"
        QWEN_INSTALLED=false
    fi
    
    # Check Gemini CLI
    if command_exists gemini; then
        GEMINI_VERSION=$(gemini --version 2>/dev/null || echo "unknown")
        echo -e "2. ${GREEN}✅ Gemini CLI${NC} ($GEMINI_VERSION) - 已安装"
        GEMINI_INSTALLED=true
    else
        echo -e "2. ${YELLOW}⚠️ Gemini CLI${NC} - 未安装"
        GEMINI_INSTALLED=false
    fi
    
    # Check Claude Code
    if command_exists claude; then
        CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
        echo -e "3. ${GREEN}✅ Claude Code${NC} ($CLAUDE_VERSION) - 已安装"
        CLAUDE_INSTALLED=true
    else
        echo -e "3. ${YELLOW}⚠️ Claude Code${NC} - 未安装"
        CLAUDE_INSTALLED=false
    fi
}

# Install Qwen CLI
install_qwen() {
    echo -e "${CYAN}🚀 安装 Qwen CLI...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        # Check if Homebrew is installed
        if ! command_exists brew; then
            echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1
        fi
        echo -e "${CYAN}📦 通过 Homebrew 安装 Qwen CLI...${NC}"
        brew install qwen > /dev/null 2>&1
    elif [[ "$OS" == "Linux" ]]; then
        # Check if npm is installed
        if command_exists npm; then
            echo -e "${CYAN}📦 通过 npm 安装 Qwen CLI...${NC}"
            npm install -g qwen > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm。请先安装 Node.js。${NC}"
            return 1
        fi
    fi
    
    if command_exists qwen; then
        QWEN_VERSION=$(qwen --version)
        echo -e "${GREEN}✅ Qwen CLI 安装成功! (版本: $QWEN_VERSION)${NC}"
    else
        echo -e "${RED}❌ Qwen CLI 安装失败${NC}"
        return 1
    fi
}

# Update Qwen CLI
update_qwen() {
    echo -e "${CYAN}🔄 更新 Qwen CLI...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        if command_exists brew; then
            echo -e "${CYAN}🔄 通过 Homebrew 更新 Qwen CLI...${NC}"
            brew upgrade qwen > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 Homebrew${NC}"
            return 1
        fi
    elif [[ "$OS" == "Linux" ]]; then
        if command_exists npm; then
            echo -e "${CYAN}🔄 通过 npm 更新 Qwen CLI...${NC}"
            npm update -g qwen > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm${NC}"
            return 1
        fi
    fi
    
    if command_exists qwen; then
        QWEN_VERSION=$(qwen --version)
        echo -e "${GREEN}✅ Qwen CLI 更新成功! (版本: $QWEN_VERSION)${NC}"
    else
        echo -e "${RED}❌ Qwen CLI 更新失败${NC}"
        return 1
    fi
}

# Install Gemini CLI
install_gemini() {
    echo -e "${CYAN}🚀 安装 Gemini CLI...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        # Check if Homebrew is installed
        if ! command_exists brew; then
            echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1
        fi
        echo -e "${CYAN}📦 通过 Homebrew 安装 Gemini CLI...${NC}"
        brew install gemini > /dev/null 2>&1
    elif [[ "$OS" == "Linux" ]]; then
        # Check if npm is installed
        if command_exists npm; then
            echo -e "${CYAN}📦 通过 npm 安装 Gemini CLI...${NC}"
            npm install -g gemini > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm。请先安装 Node.js。${NC}"
            return 1
        fi
    fi
    
    if command_exists gemini; then
        GEMINI_VERSION=$(gemini --version)
        echo -e "${GREEN}✅ Gemini CLI 安装成功! (版本: $GEMINI_VERSION)${NC}"
    else
        echo -e "${RED}❌ Gemini CLI 安装失败${NC}"
        return 1
    fi
}

# Update Gemini CLI
update_gemini() {
    echo -e "${CYAN}🔄 更新 Gemini CLI...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        if command_exists brew; then
            echo -e "${CYAN}🔄 通过 Homebrew 更新 Gemini CLI...${NC}"
            brew upgrade gemini > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 Homebrew${NC}"
            return 1
        fi
    elif [[ "$OS" == "Linux" ]]; then
        if command_exists npm; then
            echo -e "${CYAN}🔄 通过 npm 更新 Gemini CLI...${NC}"
            npm update -g gemini > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm${NC}"
            return 1
        fi
    fi
    
    if command_exists gemini; then
        GEMINI_VERSION=$(gemini --version)
        echo -e "${GREEN}✅ Gemini CLI 更新成功! (版本: $GEMINI_VERSION)${NC}"
    else
        echo -e "${RED}❌ Gemini CLI 更新失败${NC}"
        return 1
    fi
}

# Install Claude Code
install_claude() {
    echo -e "${CYAN}🚀 安装 Claude Code...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        # Check if Homebrew is installed
        if ! command_exists brew; then
            echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1
        fi
        echo -e "${CYAN}📦 通过 Homebrew 安装 Claude Code...${NC}"
        brew install claude > /dev/null 2>&1
    elif [[ "$OS" == "Linux" ]]; then
        # Check if npm is installed
        if command_exists npm; then
            echo -e "${CYAN}📦 通过 npm 安装 Claude Code...${NC}"
            npm install -g claude > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm。请先安装 Node.js。${NC}"
            return 1
        fi
    fi
    
    if command_exists claude; then
        CLAUDE_VERSION=$(claude --version)
        echo -e "${GREEN}✅ Claude Code 安装成功! (版本: $CLAUDE_VERSION)${NC}"
    else
        echo -e "${RED}❌ Claude Code 安装失败${NC}"
        return 1
    fi
}

# Update Claude Code
update_claude() {
    echo -e "${CYAN}🔄 更新 Claude Code...${NC}"
    
    if [[ "$OS" == "macOS" ]]; then
        if command_exists brew; then
            echo -e "${CYAN}🔄 通过 Homebrew 更新 Claude Code...${NC}"
            brew upgrade claude > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 Homebrew${NC}"
            return 1
        fi
    elif [[ "$OS" == "Linux" ]]; then
        if command_exists npm; then
            echo -e "${CYAN}🔄 通过 npm 更新 Claude Code...${NC}"
            npm update -g claude > /dev/null 2>&1
        else
            echo -e "${RED}❌ 未找到 npm${NC}"
            return 1
        fi
    fi
    
    if command_exists claude; then
        CLAUDE_VERSION=$(claude --version)
        echo -e "${GREEN}✅ Claude Code 更新成功! (版本: $CLAUDE_VERSION)${NC}"
    else
        echo -e "${RED}❌ Claude Code 更新失败${NC}"
        return 1
    fi
}

# Main menu
show_menu() {
    echo ""
    echo -e "${BLUE}========== AI 工具管理菜单 ==========${NC}"
    echo ""
    
    if [ "$QWEN_INSTALLED" = true ]; then
        echo -e "1. ${GREEN}✅ 更新 Qwen CLI${NC}"
    else
        echo -e "1. ${YELLOW}📥 安装 Qwen CLI${NC}"
    fi
    
    if [ "$GEMINI_INSTALLED" = true ]; then
        echo -e "2. ${GREEN}✅ 更新 Gemini CLI${NC}"
    else
        echo -e "2. ${YELLOW}📥 安装 Gemini CLI${NC}"
    fi
    
    if [ "$CLAUDE_INSTALLED" = true ]; then
        echo -e "3. ${GREEN}✅ 更新 Claude Code${NC}"
    else
        echo -e "3. ${YELLOW}📥 安装 Claude Code${NC}"
    fi
    
    echo -e "4. 🔄 ${CYAN}刷新工具状态${NC}"
    echo -e "5. 🚪 ${RED}退出${NC}"
    echo ""
    echo -e "${BLUE}====================================${NC}"
}

# Process user choice
process_choice() {
    case $1 in
        1)
            if [ "$QWEN_INSTALLED" = true ]; then
                update_qwen
            else
                install_qwen
            fi
            ;;
        2)
            if [ "$GEMINI_INSTALLED" = true ]; then
                update_gemini
            else
                install_gemini
            fi
            ;;
        3)
            if [ "$CLAUDE_INSTALLED" = true ]; then
                update_claude
            else
                install_claude
            fi
            ;;
        4)
            echo -e "${CYAN}🔄 刷新工具状态...${NC}"
            check_tools
            ;;
        5)
            echo -e "${GREEN}👋 再见!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效选项，请重试。${NC}"
            ;;
    esac
}

# Main program
main() {
    print_logo
    detect_os
    check_tools
    
    while true; do
        show_menu
        echo ""
        read -p "请选择操作 (1-5): " choice
        process_choice $choice
        echo ""
        read -p "按回车键继续..."
    done
}

# Run main program
main "$@"
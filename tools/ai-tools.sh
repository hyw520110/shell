#!/bin/bash

# AI工具安装器，支持多种AI CLI工具
# 兼容Linux和macOS系统

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 工具配置: 命令:名称:包名:类型
TOOLS=(
    "qwen:Qwen CLI:qwen:npm"
    "gemini:Gemini CLI:gemini:npm"
    "claude:Claude Code:claude:npm"
    "codex:OpenAI Codex CLI:@openai/codex:npm"
    "grok:Grok CLI:@vibe-kit/grok-cli:npm"
    "codebuddy:Codebuddy Code:@tencent-ai/codebuddy-code:npm"
    "iflow:iFlow CLI:@iflow-ai/iflow-cli:npm"
)

# 工具状态全局变量
TOOL_STATUS=()

# 检测操作系统
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

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 通用npm安装函数
install_with_npm() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        echo -e "${RED}❌ 未找到 npm。请先安装 Node.js。${NC}"
        return 1
    fi
    
    echo -e "${CYAN}📦 通过 npm 安装 $tool_name...${NC}"
    
    # 尝试安装，捕获输出用于调试
    if npm install -g "$package_name" > /tmp/install.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
        return 0
    else
        echo -e "${RED}❌ $tool_name 安装失败${NC}"
        echo -e "${YELLOW}查看 /tmp/install.log 获取详细信息${NC}"
        return 1
    fi
}

# 通用npm更新函数
update_with_npm() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        echo -e "${RED}❌ 未找到 npm${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔄 通过 npm 更新 $tool_name...${NC}"
    
    # 尝试更新，捕获输出用于调试
    if npm update -g "$package_name" > /tmp/update.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
        return 0
    else
        echo -e "${RED}❌ $tool_name 更新失败${NC}"
        echo -e "${YELLOW}查看 /tmp/update.log 获取详细信息${NC}"
        return 1
    fi
}

# 通用brew安装函数（仅macOS）
install_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
    
    # 检查Homebrew是否已安装
    if ! command_exists brew; then
        echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
        if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1; then
            echo -e "${RED}❌ Homebrew 安装失败${NC}"
            return 1
        fi
    fi
    
    echo -e "${CYAN}📦 通过 Homebrew 安装 $tool_name...${NC}"
    
    # 尝试安装，如果brew失败则回退到npm
    if brew install "$package_name" > /tmp/install.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 安装失败，尝试通过 npm 安装...${NC}"
        install_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 通用brew更新函数（仅macOS）
update_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
    
    # 检查Homebrew是否已安装
    if ! command_exists brew; then
        echo -e "${RED}❌ 未找到 Homebrew${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔄 通过 Homebrew 更新 $tool_name...${NC}"
    
    # 尝试更新，如果brew失败则回退到npm
    if brew upgrade "$package_name" > /tmp/update.log 2>&1; then
        echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 更新失败，尝试通过 npm 更新...${NC}"
        update_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 检查已安装的工具
check_tools() {
    echo -e "${CYAN}🔍 检查已安装的AI工具...${NC}"
    TOOL_STATUS=()
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        
        if command_exists "$cmd"; then
            local version=$($cmd --version 2>/dev/null || echo "unknown")
            echo -e "$i. ${GREEN}✅ $name${NC} ($version) - 已安装"
            TOOL_STATUS+=("true")
        else
            echo -e "$i. ${YELLOW}⚠️ $name${NC} - 未安装"
            TOOL_STATUS+=("false")
        fi
        ((i++))
    done
}

# 根据索引安装工具
install_tool() {
    local index=$1
    local tool=${TOOLS[$index]}
    
    local cmd=$(echo $tool | cut -d: -f1)
    local name=$(echo $tool | cut -d: -f2)
    local package=$(echo $tool | cut -d: -f3)
    local type=$(echo $tool | cut -d: -f4)
    
    case $type in
        npm)
            install_with_npm "$name" "$package"
            ;;
        brew)
            if [[ "$OS" == "macOS" ]]; then
                install_with_brew "$name" "$package"
            else
                install_with_npm "$name" "$package"
            fi
            ;;
        *)
            echo -e "${RED}❌ 不支持的安装类型: $type${NC}"
            return 1
            ;;
    esac
    
    # 重新检查工具状态
    check_tools
}

# 根据索引更新工具
update_tool() {
    local index=$1
    local tool=${TOOLS[$index]}
    
    local cmd=$(echo $tool | cut -d: -f1)
    local name=$(echo $tool | cut -d: -f2)
    local package=$(echo $tool | cut -d: -f3)
    local type=$(echo $tool | cut -d: -f4)
    
    case $type in
        npm)
            update_with_npm "$name" "$package"
            ;;
        brew)
            if [[ "$OS" == "macOS" ]]; then
                update_with_brew "$name" "$package"
            else
                update_with_npm "$name" "$package"
            fi
            ;;
        *)
            echo -e "${RED}❌ 不支持的更新类型: $type${NC}"
            return 1
            ;;
    esac
    
    # 重新检查工具状态
    check_tools
}

# 显示主菜单
show_menu() {
    echo -e "\n按需选择:"
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        
        if [ "${TOOL_STATUS[$((i-1))]}" = "true" ]; then
            echo -e "$i. ${GREEN}✅ 更新 $name${NC}"
        else
            echo -e "$i. ${YELLOW}📥 安装 $name${NC}"
        fi
        ((i++))
    done
    
    echo -e "$i. 🔄 ${CYAN}刷新${NC}"
    ((i++))
    echo -e "$i. 🚪 ${RED}退出${NC}"
    echo ""
}

# 处理用户选择
process_choice() {
    local choice=$1
    local tool_count=${#TOOLS[@]}
    
    # 检查选择是否为工具
    if [[ $choice -ge 1 && $choice -le $tool_count ]]; then
        local index=$((choice-1))
        if [ "${TOOL_STATUS[$index]}" = "true" ]; then
            update_tool $index
        else
            install_tool $index
        fi
    # 检查选择是否为刷新
    elif [[ $choice -eq $((tool_count+1)) ]]; then
        echo -e "${CYAN}🔄 刷新...${NC}"
        check_tools
    # 检查选择是否为退出
    elif [[ $choice -eq $((tool_count+2)) ]]; then
        echo -e "${GREEN}👋 再见!${NC}"
        exit 0
    else
        echo -e "${RED}❌ 无效选项，请重试。${NC}"
    fi
}

# 主程序
main() {
    detect_os
    check_tools
    
    while true; do
        show_menu
        echo ""
        read -p "请选择操作 (1-$(( ${#TOOLS[@]} + 2 ))): " choice
        process_choice $choice
        echo ""
    done
}

# 运行主程序
main "$@"

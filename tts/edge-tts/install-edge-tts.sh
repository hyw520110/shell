#!/bin/bash

# Edge-TTS 一键安装脚本
# 支持 Linux 和 macOS
# 支持安装和卸载
# 支持重复执行不重复安装

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 基础路径
BASE_DIR="$HOME/edge-tts"
VENV_DIR="$BASE_DIR/venv"
BIN_DIR="$HOME/.local/bin"
LOG_DIR="$BASE_DIR/logs"

# 检查操作系统
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" != "Linux" && "$OS_TYPE" != "Darwin" ]]; then
    echo -e "${RED}不支持的操作系统：$OS_TYPE${NC}"
    exit 1
fi

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否已安装
check_installed() {
    if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ]; then
        source "$VENV_DIR/bin/activate" 2>/dev/null || return 1
        if command_exists edge-tts; then
            return 0
        fi
    fi
    return 1
}

# 打印状态信息
print_status() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Edge-TTS 安装管理${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# 检查 Python 环境
check_python() {
    echo -e "${YELLOW}检查 Python 环境...${NC}"
    
    if ! command_exists python3; then
        echo -e "${RED}未检测到 Python 3，请先安装 Python 3.8 或更高版本。${NC}"
        echo -e "Linux (Ubuntu/Debian): sudo apt install python3 python3-pip python3-venv"
        echo -e "Linux (CentOS/RHEL): sudo yum install python3 python3-pip"
        echo -e "macOS: brew install python@3.12"
        exit 1
    fi
    
    PYTHON_VERSION=$(python3 --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+')
    if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" 2>/dev/null; then
        echo -e "${RED}Python 版本 $PYTHON_VERSION < 3.8，无法继续安装。${NC}"
        echo -e "请升级 Python 至 3.8 或更高版本。"
        exit 1
    fi
    
    echo -e "${GREEN}Python 3.8+ 已满足。${NC}"
}

# 创建虚拟环境
create_venv() {
    echo -e "${YELLOW}创建 Python 虚拟环境...${NC}"
    
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}虚拟环境创建失败，请检查 Python 3 安装。${NC}"
            exit 1
        fi
        echo -e "${GREEN}虚拟环境创建成功。${NC}"
    else
        echo -e "${GREEN}虚拟环境已存在，跳过创建。${NC}"
    fi
}

# 安装/升级 edge-tts（--upgrade 保证已有环境也能拿到新版）
install_edge_tts() {
    echo -e "${YELLOW}安装/升级 edge-tts...${NC}"
    
    source "$VENV_DIR/bin/activate"
    
    # 升级 pip
    pip install --upgrade pip -q
    
    # 安装 edge-tts（已安装时升级到最新版）
    pip install --upgrade edge-tts
    
    echo -e "${GREEN}edge-tts 安装/升级成功。${NC}"
}

# 仅升级 edge-tts（不重建虚拟环境）
upgrade_edge_tts() {
    print_status
    
    if ! check_installed; then
        echo -e "${YELLOW}Edge-TTS 未安装，将执行完整安装。${NC}"
        install
        return 0
    fi
    
    echo -e "${YELLOW}升级 edge-tts 到最新版本...${NC}"
    source "$VENV_DIR/bin/activate" 2>/dev/null
    pip install --upgrade edge-tts
    
    # 保证全局命令链接仍然有效
    create_global_command
    
    echo -e "${GREEN}edge-tts 已升级。${NC}"
    echo -e "当前版本：$(edge-tts --version 2>/dev/null || echo "未知")"
}

# 创建必要目录
create_dirs() {
    echo -e "${YELLOW}创建必要目录...${NC}"
    mkdir -p "$BASE_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$BIN_DIR"
    echo -e "${GREEN}目录创建完成。${NC}"
}

# 创建全局命令链接
create_global_command() {
    echo -e "${YELLOW}创建全局命令链接...${NC}"
    
    local symlink_path="$BIN_DIR/edge-tts"
    local target_path="$VENV_DIR/bin/edge-tts"
    
    if [ -f "$target_path" ]; then
        if [ -L "$symlink_path" ]; then
            rm "$symlink_path"
        fi
        ln -s "$target_path" "$symlink_path"
        echo -e "${GREEN}全局命令创建成功：$symlink_path${NC}"
    fi
}

# 检查 PATH 是否包含 BIN_DIR
check_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        echo -e "${YELLOW}警告：$BIN_DIR 不在 PATH 中${NC}"
        echo -e "请将以下内容添加到 ~/.bashrc 或 ~/.zshrc："
        echo -e "  ${BLUE}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
        echo ""
    fi
}

# 安装完成信息
print_install_complete() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Edge-TTS 安装完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "使用方法："
    echo ""
    echo -e "  1. 直接使用全局命令（推荐）："
    echo -e "     ${BLUE}edge-tts --list-voices${NC}"
    echo -e "     ${BLUE}edge-tts --text \"你好，欢迎使用 Edge TTS\" --write-media hello.mp3${NC}"
    echo ""
    echo -e "  2. 或激活虚拟环境后使用："
    echo -e "     ${BLUE}source $VENV_DIR/bin/activate${NC}"
    echo -e "     ${BLUE}edge-tts --list-voices${NC}"
    echo ""
    echo -e "  3. 查看所有中文语音："
    echo -e "     ${BLUE}edge-tts --list-voices | grep zh-CN${NC}"
    echo ""
    echo -e "  4. 使用指定语音："
    echo -e "     ${BLUE}edge-tts --voice zh-CN-XiaoxiaoNeural --text \"你好\" --write-media hello.mp3${NC}"
    echo ""
    echo -e "  5. 使用 SSML（语音合成标记语言）："
    echo -e "     ${BLUE}edge-tts --text '<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"zh-CN\"><voice name=\"zh-CN-XiaoxiaoNeural\">你好</voice></speak>' --write-media hello.mp3${NC}"
    echo ""
    echo -e "常用中文语音："
    echo -e "  - zh-CN-XiaoxiaoNeural (女声，自然)"
    echo -e "  - zh-CN-YunxiNeural (男声，自然)"
    echo -e "  - zh-CN-XiaoyiNeural (女声，温柔)"
    echo -e "  - zh-CN-YunjianNeural (男声，播音)"
    echo -e "  - zh-CN-XiaochenNeural (女声，甜美)"
    echo -e "  - zh-CN-YunyangNeural (男声，新闻)"
    echo ""
    echo -e "安装目录："
    echo -e "  - 虚拟环境：$VENV_DIR"
    echo -e "  - 全局命令：$BIN_DIR/edge-tts"
    echo -e "  - 日志目录：$LOG_DIR"
    echo ""
}

# 安装主流程
install() {
    print_status
    
    if check_installed; then
        echo -e "${YELLOW}Edge-TTS 已安装，正在升级到最新版本...${NC}"
        upgrade_edge_tts
        return 0
    fi
    
    echo -e "${YELLOW}开始安装 Edge-TTS...${NC}"
    echo ""
    
    create_dirs
    check_python
    create_venv
    install_edge_tts
    create_global_command
    check_path
    
    print_install_complete
}

# 卸载
uninstall() {
    print_status
    
    echo -e "${RED}即将卸载 Edge-TTS...${NC}"
    echo ""
    echo -e "将删除以下内容："
    echo -e "  - $BASE_DIR"
    echo -e "  - $BIN_DIR/edge-tts (符号链接)"
    echo ""
    read -p "确认卸载？(y/N) " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"
        
        # 删除符号链接
        rm -f "$BIN_DIR/edge-tts"
        
        # 删除安装目录
        rm -rf "$BASE_DIR"
        
        echo -e "${GREEN}卸载完成！${NC}"
    else
        echo -e "${YELLOW}已取消卸载。${NC}"
    fi
}

# 帮助信息
show_help() {
    print_status
    echo "使用方法："
    echo "  $0 [命令]"
    echo ""
    echo "命令："
    echo "  install    - 安装 Edge-TTS（默认，已安装时升级）"
    echo "  upgrade    - 升级 Edge-TTS 到最新版本"
    echo "  uninstall  - 卸载 Edge-TTS"
    echo "  help       - 显示此帮助信息"
    echo "  status     - 检查安装状态"
    echo "  voices     - 列出所有可用语音"
    echo ""
}

# 检查状态
show_status() {
    print_status
    
    if check_installed; then
        echo -e "${GREEN}✓ Edge-TTS 已安装${NC}"
        echo ""
        
        # 显示版本
        source "$VENV_DIR/bin/activate" 2>/dev/null
        local version=$(edge-tts --version 2>/dev/null || echo "未知")
        echo -e "版本：$version"
        echo ""
        
        echo -e "安装目录："
        echo -e "  - 虚拟环境：$VENV_DIR"
        echo -e "  - 全局命令：$BIN_DIR/edge-tts"
        echo ""
        
        echo -e "快速使用："
        echo -e "  ${BLUE}edge-tts --text \"你好\" --write-media hello.mp3${NC}"
        echo ""
    else
        echo -e "${YELLOW}✗ Edge-TTS 未安装${NC}"
        echo ""
        echo -e "运行以下命令进行安装："
        echo -e "  ${BLUE}$0 install${NC}"
        echo ""
    fi
}

# 列出所有语音
list_voices() {
    print_status
    
    if ! check_installed; then
        echo -e "${RED}Edge-TTS 未安装，请先安装。${NC}"
        echo -e "运行：$0 install"
        exit 1
    fi
    
    echo -e "${YELLOW}列出所有可用语音...${NC}"
    echo ""
    
    source "$VENV_DIR/bin/activate" 2>/dev/null
    edge-tts --list-voices
}

# 主函数
main() {
    case "${1:-install}" in
        install)
            install
            ;;
        upgrade|update)
            upgrade_edge_tts
            ;;
        uninstall)
            uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        status)
            show_status
            ;;
        voices)
            list_voices
            ;;
        *)
            echo -e "${RED}未知命令：$1${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

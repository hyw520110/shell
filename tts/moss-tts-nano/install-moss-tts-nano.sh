#!/bin/bash

# MOSS-TTS-Nano 一键安装脚本
# 支持 Linux 和 macOS
# 支持安装和卸载
# 支持重复执行不重复安装
# 优先使用 adl 下载

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 基础路径
BASE_DIR="$HOME/moss-tts-nano"
VENV_DIR="$BASE_DIR/venv"
REPO_DIR="$BASE_DIR/repo"
MODEL_DIR="$BASE_DIR/models"
LOG_DIR="$BASE_DIR/logs"

# 仓库地址
REPO_URL="https://github.com/OpenMOSS/MOSS-TTS-Nano.git"

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

# 检查 adl 是否可用
check_adl() {
    if command_exists adl; then
        # 验证 adl 是否可用
        if adl --help >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 使用下载工具下载文件
download_file() {
    local url="$1"
    local output_path="$2"
    local output_dir=$(dirname "$output_path")
    
    mkdir -p "$output_dir"
    
    if check_adl; then
        echo -e "${GREEN}使用 adl 下载...${NC}"
        adl "$url" "$output_dir" "$(basename "$output_path")"
    else
        echo -e "${YELLOW}使用 curl 下载...${NC}"
        if command_exists curl; then
            curl -L -o "$output_path" "$url"
        elif command_exists wget; then
            wget -O "$output_path" "$url"
        else
            echo -e "${RED}未找到 curl 或 wget，无法下载${NC}"
            return 1
        fi
    fi
}

# 检查是否已安装
check_installed() {
    if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ] && [ -d "$REPO_DIR" ]; then
        # 检查是否可以导入
        source "$VENV_DIR/bin/activate" 2>/dev/null || return 1
        if python3 -c "import moss_tts_nano" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 打印状态信息
print_status() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  MOSS-TTS-Nano 安装管理${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# 检查 Python 环境
check_python() {
    echo -e "${YELLOW}检查 Python 环境...${NC}"
    
    if ! command_exists python3; then
        echo -e "${RED}未检测到 Python 3，请先安装 Python 3.10 或更高版本。${NC}"
        echo -e "Linux (Ubuntu/Debian): sudo apt install python3 python3-pip python3-venv"
        echo -e "Linux (CentOS/RHEL): sudo yum install python3 python3-pip"
        echo -e "macOS: brew install python@3.12"
        exit 1
    fi
    
    PYTHON_VERSION=$(python3 --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+')
    if [[ "$PYTHON_VERSION" < "3.10" ]]; then
        echo -e "${RED}Python 版本 $PYTHON_VERSION < 3.10，无法继续安装。${NC}"
        echo -e "请升级 Python 至 3.10 或更高版本。"
        exit 1
    fi
    
    echo -e "${GREEN}Python 3.10+ 已满足。${NC}"
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

# 克隆或更新仓库
clone_repo() {
    echo -e "${YELLOW}获取 MOSS-TTS-Nano 代码...${NC}"
    
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$REPO_URL" "$REPO_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}代码克隆失败，请检查网络连接。${NC}"
            exit 1
        fi
        echo -e "${GREEN}代码克隆成功。${NC}"
    else
        echo -e "${YELLOW}仓库已存在，检查是否需要更新...${NC}"
        cd "$REPO_DIR"
        git fetch origin
        LOCAL=$(git rev-parse @)
        REMOTE=$(git rev-parse @{u})
        if [ "$LOCAL" != "$REMOTE" ]; then
            echo -e "${YELLOW}发现更新，正在拉取...${NC}"
            git pull
            echo -e "${GREEN}代码更新成功。${NC}"
        else
            echo -e "${GREEN}代码已是最新版本。${NC}"
        fi
        cd - >/dev/null
    fi
}

# 安装依赖
install_deps() {
    echo -e "${YELLOW}安装依赖...${NC}"
    
    source "$VENV_DIR/bin/activate"
    
    cd "$REPO_DIR"
    
    # 检查是否有 requirements.txt
    if [ -f "requirements.txt" ]; then
        echo -e "${YELLOW}安装 PyTorch 和相关依赖...${NC}"
        
        # 先尝试安装 pynini (如果是 conda 环境)
        if command_exists conda 2>/dev/null; then
            echo -e "${YELLOW}检测到 conda，尝试安装 pynini...${NC}"
            conda install -c conda-forge pynini=2.1.6.post1 -y 2>/dev/null || true
        fi
        
        # 安装 requirements.txt
        pip install -r requirements.txt
        
        # 安装项目
        echo -e "${YELLOW}安装 MOSS-TTS-Nano...${NC}"
        pip install -e .
        
        echo -e "${GREEN}依赖安装成功。${NC}"
    else
        echo -e "${RED}未找到 requirements.txt 文件。${NC}"
        exit 1
    fi
}

# 创建必要目录
create_dirs() {
    echo -e "${YELLOW}创建必要目录...${NC}"
    mkdir -p "$BASE_DIR"
    mkdir -p "$MODEL_DIR"
    mkdir -p "$LOG_DIR"
    echo -e "${GREEN}目录创建完成。${NC}"
}

# 安装完成信息
print_install_complete() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  MOSS-TTS-Nano 安装完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "使用方法："
    echo -e "  1. 激活虚拟环境："
    echo -e "     ${BLUE}source $VENV_DIR/bin/activate${NC}"
    echo ""
    echo -e "  2. 使用 ONNX 版本（推荐，CPU 友好）："
    echo -e "     ${BLUE}cd $REPO_DIR${NC}"
    echo -e "     ${BLUE}python infer_onnx.py --prompt-audio-path assets/audio/zh_1.wav --text \"你好，欢迎使用 MOSS-TTS-Nano\"${NC}"
    echo ""
    echo -e "  3. 启动 Web 界面："
    echo -e "     ${BLUE}python app_onnx.py${NC}"
    echo -e "     然后访问 http://127.0.0.1:18083"
    echo ""
    echo -e "  4. 使用 CLI 命令："
    echo -e "     ${BLUE}moss-tts-nano generate --backend onnx --prompt-speech assets/audio/zh_1.wav --text \"你好\"${NC}"
    echo ""
    echo -e "安装目录："
    echo -e "  - 虚拟环境：$VENV_DIR"
    echo -e "  - 代码仓库：$REPO_DIR"
    echo -e "  - 模型目录：$MODEL_DIR"
    echo -e "  - 日志目录：$LOG_DIR"
    echo ""
}

# 安装主流程
install() {
    print_status
    
    if check_installed; then
        echo -e "${GREEN}MOSS-TTS-Nano 已安装，跳过安装步骤。${NC}"
        print_install_complete
        return 0
    fi
    
    echo -e "${YELLOW}开始安装 MOSS-TTS-Nano...${NC}"
    echo ""
    
    create_dirs
    check_python
    create_venv
    clone_repo
    install_deps
    
    print_install_complete
}

# 卸载
uninstall() {
    print_status
    
    echo -e "${RED}即将卸载 MOSS-TTS-Nano...${NC}"
    echo ""
    echo -e "将删除以下内容："
    echo -e "  - $BASE_DIR"
    echo ""
    read -p "确认卸载？(y/N) " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"
        
        # 停止可能正在运行的进程
        pkill -f "python.*moss-tts-nano" 2>/dev/null || true
        pkill -f "app_onnx.py" 2>/dev/null || true
        pkill -f "app.py" 2>/dev/null || true
        
        # 删除目录
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
    echo "  install    - 安装 MOSS-TTS-Nano（默认）"
    echo "  uninstall  - 卸载 MOSS-TTS-Nano"
    echo "  help       - 显示此帮助信息"
    echo "  status     - 检查安装状态"
    echo ""
}

# 检查状态
show_status() {
    print_status
    
    if check_installed; then
        echo -e "${GREEN}✓ MOSS-TTS-Nano 已安装${NC}"
        echo ""
        echo -e "安装目录："
        echo -e "  - 虚拟环境：$VENV_DIR"
        echo -e "  - 代码仓库：$REPO_DIR"
        echo -e "  - 模型目录：$MODEL_DIR"
        echo ""
        echo -e "激活虚拟环境："
        echo -e "  ${BLUE}source $VENV_DIR/bin/activate${NC}"
        echo ""
    else
        echo -e "${YELLOW}✗ MOSS-TTS-Nano 未安装${NC}"
        echo ""
        echo -e "运行以下命令进行安装："
        echo -e "  ${BLUE}$0 install${NC}"
        echo ""
    fi
}

# 主函数
main() {
    case "${1:-install}" in
        install)
            install
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
        *)
            echo -e "${RED}未知命令：$1${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

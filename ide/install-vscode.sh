#!/bin/bash

# Visual Studio Code 一键安装配置脚本
# 支持检测、安装、配置 VS Code

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 检测VS Code是否已安装
check_installed() {
    # 方法1: 检查code命令
    if command -v code &> /dev/null; then
        return 0
    fi
    
    # 方法2: 检查/Applications (macOS)
    if [ -d "/Applications/Visual Studio Code.app" ]; then
        return 0
    fi
    
    # 方法3: 检查Linux常见安装位置
    if [ -f "/usr/share/code/code" ] || [ -f "/usr/bin/code" ]; then
        return 0
    fi
    
    return 1
}

# 获取VS Code版本信息
get_version() {
    if command -v code &> /dev/null; then
        code --version 2>&1 | head -1
    elif [ -d "/Applications/Visual Studio Code.app" ]; then
        defaults read /Applications/Visual\ Studio\ Code.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo ""
    elif [ -f "/usr/share/code/code" ]; then
        /usr/share/code/code --version 2>&1 | head -1
    else
        echo ""
    fi
}

# 检测系统类型
detect_os() {
    local os_type=$(uname -s)
    case "$os_type" in
        Linux*)
            echo "linux"
            ;;
        Darwin*)
            echo "macos"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 检测Linux发行版
detect_linux_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 安装VS Code（macOS）
install_vscode_macos() {
    log_info "在 macOS 上安装 Visual Studio Code..."
    
    # 使用Homebrew安装
    if command -v brew &> /dev/null; then
        log_info "使用 Homebrew 安装..."
        brew install --cask visual-studio-code
        return 0
    fi
    
    # 下载DMG并安装
    local DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
    local download_file="VSCode-darwin-universal.dmg"
    
    # 确保下载目录存在
    mkdir -p "$DOWNLOAD_DIR"
    
    log_info "下载 Visual Studio Code DMG..."
    log_info "保存目录: $DOWNLOAD_DIR"
    
    # 检查文件是否已存在
    if [ -f "$DOWNLOAD_DIR/$download_file" ]; then
        log_info "文件已存在，跳过下载: $DOWNLOAD_DIR/$download_file"
    else
        if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
            adl "https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal" "$DOWNLOAD_DIR" "$download_file"
        else
            curl -L -o "$DOWNLOAD_DIR/$download_file" "https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal"
        fi
    fi
    
    log_info "挂载 DMG..."
    hdiutil attach "$DOWNLOAD_DIR/$download_file" -nobrowse -readonly
    
    log_info "复制到 /Applications..."
    cp -R "/Volumes/Visual Studio Code/Visual Studio Code.app" /Applications/
    
    log_info "卸载 DMG..."
    hdiutil detach "/Volumes/Visual Studio Code"
    
    log_info "Visual Studio Code 安装完成！"
}

# 安装VS Code（Linux）
install_vscode_linux() {
    local distro=$(detect_linux_distro)
    log_info "在 Linux ($distro) 上安装 Visual Studio Code..."
    
    case "$distro" in
        ubuntu|debian|linuxmint|pop)
            log_info "使用 apt 安装..."
            
            # 安装依赖
            sudo apt-get install -y software-properties-common apt-transport-https wget
            
            # 添加Microsoft GPG密钥
            wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
            
            # 添加VS Code仓库
            sudo add-apt-repository -y "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main"
            
            # 更新并安装
            sudo apt-get update
            sudo apt-get install -y code
            ;;
        
        fedora|rhel|centos)
            log_info "使用 rpm/yum/dnf 安装..."
            
            # 添加Microsoft GPG密钥
            sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
            
            # 添加VS Code仓库
            sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
            
            # 安装
            if command -v dnf &> /dev/null; then
                sudo dnf install -y code
            elif command -v yum &> /dev/null; then
                sudo yum install -y code
            fi
            ;;
        
        arch|manjaro)
            log_info "使用 pacman 安装..."
            sudo pacman -S --noconfirm code
            ;;
        
        *)
            log_error "不支持的Linux发行版: $distro"
            log_info "请手动安装: https://code.visualstudio.com/docs/setup/linux"
            return 1
            ;;
    esac
    
    log_info "Visual Studio Code 安装完成！"
}

# 安装VS Code
install_vscode() {
    local os=$(detect_os)
    
    log_info "开始安装 Visual Studio Code..."
    
    case "$os" in
        macos)
            install_vscode_macos
            ;;
        linux)
            install_vscode_linux
            ;;
        *)
            log_error "不支持的操作系统: $os"
            return 1
            ;;
    esac
}

# 配置VS Code（安装常用扩展）
configure_vscode() {
    if ! command -v code &> /dev/null; then
        log_warn "VS Code 未安装，跳过配置"
        return 1
    fi
    
    log_info "配置 Visual Studio Code..."
    
    # Java扩展
    log_info "安装 Java 扩展..."
    code --install-extension vscjava.vscode-java-pack
    
    # Python扩展
    log_info "安装 Python 扩展..."
    code --install-extension ms-python.python
    
    # Git扩展
    log_info "安装 Git 扩展..."
    code --install-extension eamodio.gitlens
    
    # 中文语言包
    log_info "安装中文语言包..."
    code --install-extension MS-CEINTL.vscode-language-pack-zh-hans
    
    log_info "Visual Studio Code 配置完成！"
}

# 显示使用帮助
show_help() {
    cat << EOF
Visual Studio Code 一键安装配置脚本

用法: $0 [选项]

选项:
  -h, --help       显示此帮助信息
  -v, --version    显示版本信息（空表示未安装）
  -i, --install    安装 Visual Studio Code
  -p, --plugins    配置常用插件（需要已安装）

示例:
  $0              # 交互式安装
  $0 --version    # 检查是否已安装
  $0 --install    # 直接安装
  $0 --plugins    # 配置常用插件

EOF
}

# 主函数
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            ;;
        -v|--version)
            get_version
            ;;
        -p|--plugins)
            configure_vscode
            ;;
        -i|--install|"")
            if check_installed; then
                log_warn "Visual Studio Code 已安装"
                echo "版本: $(get_version)"
                read -p "是否重新安装? (y/N): " reinstall
                if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
                    exit 0
                fi
            fi
            
            install_vscode
            
            # 安装成功后配置插件
            if [ $? -eq 0 ]; then
                read -p "是否配置常用插件? (Y/n): " config_plugins
                if [ "$config_plugins" != "n" ] && [ "$config_plugins" != "N" ]; then
                    configure_vscode
                fi
            fi
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

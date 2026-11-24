#!/bin/bash

# HBuilderX CLI 一键安装配置脚本
# 支持主流 Linux 发行版和 macOS
# 支持重复运行，避免重复下载或安装

set -e  # 遇到错误时退出

# 全局变量
CUSTOM_PATH=""

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 检测操作系统
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        log_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
    log_info "检测到操作系统: $OS"
}

# 检查是否已安装 HBuilderX CLI
check_hx_cli() {
    if command -v cli &> /dev/null; then
        log_info "HBuilderX CLI 已安装"
        local version=$(cli --version 2>/dev/null || echo "未知")
        log_info "当前版本: $version"
        return 0
    else
        log_debug "HBuilderX CLI 未安装或不在 PATH 中"
        return 1
    fi
}

# 检查 Node.js 是否已安装
check_nodejs() {
    if command -v node &> /dev/null && command -v npm &> /dev/null; then
        log_info "Node.js 和 npm 已安装"
        log_info "Node.js 版本: $(node --version)"
        log_info "npm 版本: $(npm --version)"
        return 0
    else
        log_error "Node.js 和 npm 未安装或不在 PATH 中"
        return 1
    fi
}

# 在 Linux 上查找 HBuilderX 安装路径
find_hbuilderx_linux() {
    # 尝试常见的 Linux HBuilderX 安装路径
    local possible_paths=(
        "$HOME/hbuilderx"
        "/opt/HBuilderX"
        "/opt/hbuilderx"
        "/usr/local/hbuilderx"
        "/usr/local/HBuilderX"
        "$HOME/HBuilderX"
        "$HOME/.local/hbuilderx"
    )

    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" && -f "$path/cli" ]]; then
            echo "$path"
            return 0
        fi
    done

    # 也检查可能的子目录结构
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]]; then
            # 检查 HBuilderX 是否安装在子目录中，例如 HBuilderX/ HBuilderX-Alpha/
            for sub_dir in "$path/"*; do
                if [[ -d "$sub_dir" && -f "$sub_dir/cli" ]]; then
                    echo "$sub_dir"
                    return 0
                fi
            done
        fi
    done

    log_debug "未找到 HBuilderX 安装路径"
    return 1
}

# 在 macOS 上查找 HBuilderX 安装路径
find_hbuilderx_macos() {
    local possible_paths=(
        "/Applications/HBuilderX.app/Contents/MacOS"
        "$HOME/Applications/HBuilderX.app/Contents/MacOS"
        "/Applications/HBuilderX-Alpha.app/Contents/MacOS"
        "$HOME/Applications/HBuilderX-Alpha.app/Contents/MacOS"
    )

    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" && -f "$path/cli" ]]; then
            echo "$path"
            return 0
        fi
    done

    # HBuilderX 在 macOS 上可能还有其他位置
    # 检查 .app 包中的 cli 可执行文件
    for path in "${possible_paths[@]}"; do
        local app_path="${path%/Contents/MacOS}"
        if [[ -d "$app_path" && -f "$app_path/Contents/MacOS/cli" ]]; then
            echo "$app_path/Contents/MacOS"
            return 0
        fi
    done

    log_debug "未找到 HBuilderX 安装路径"
    return 1
}

# 查找 HBuilderX 安装路径
find_hbuilderx() {
    local hbuilderx_path=""

    # 如果用户提供了自定义路径，优先使用
    if [[ -n "$CUSTOM_PATH" && -d "$CUSTOM_PATH" ]]; then
        if [[ -f "$CUSTOM_PATH/cli" ]]; then
            echo "$CUSTOM_PATH"
            return 0
        else
            log_warn "自定义路径中未找到 cli 可执行文件: $CUSTOM_PATH/cli"
            return 1
        fi
    fi

    if [[ "$OS" == "linux" ]]; then
        hbuilderx_path=$(find_hbuilderx_linux)
    elif [[ "$OS" == "macos" ]]; then
        hbuilderx_path=$(find_hbuilderx_macos)
    fi

    if [[ -n "$hbuilderx_path" ]]; then
        echo "$hbuilderx_path"
        return 0
    else
        return 1
    fi
}

# 添加 HBuilderX CLI 到 PATH
add_to_path() {
    local hbuilderx_path="$1"
    local cli_path="$hbuilderx_path"
    
    # 检查当前 shell 配置文件
    local shell_config=""
    if [[ "$SHELL" == *"bash"* ]]; then
        shell_config="$HOME/.bashrc"
    elif [[ "$SHELL" == *"zsh"* ]]; then
        shell_config="$HOME/.zshrc"
    else
        # 尝试检测 shell
        if [[ -n "$ZSH_VERSION" ]]; then
            shell_config="$HOME/.zshrc"
        elif [[ -n "$BASH_VERSION" ]]; then
            shell_config="$HOME/.bashrc"
        else
            shell_config="$HOME/.bashrc"  # 默认
        fi
    fi
    
    # 检查是否已经添加到 PATH
    if grep -q "export PATH.*$cli_path" "$shell_config" 2>/dev/null; then
        log_info "HBuilderX CLI 路径已添加到 $shell_config"
    else
        log_info "将 HBuilderX CLI 路径添加到 $shell_config"
        {
            echo ""
            echo "# HBuilderX CLI"
            echo "export PATH=\"\$PATH:$cli_path\""
        } >> "$shell_config"
        
        # 立即应用更改
        export PATH="$PATH:$cli_path"
        log_info "HBuilderX CLI 路径已临时添加到当前会话的 PATH"
    fi
}

# 安装 HBuilderX CLI (通过 npm)
install_hx_cli_npm() {
    log_info "尝试通过 npm 安装 HBuilderX CLI 相关工具..."
    
    # 检查是否已全局安装 @dcloudio/uni-cli-i18n
    if npm list -g @dcloudio/uni-cli-i18n &>/dev/null; then
        log_info "@dcloudio/uni-cli-i18n 已全局安装"
    else
        log_info "安装 @dcloudio/uni-cli-i18n..."
        npm install -g @dcloudio/uni-cli-i18n
        if [[ $? -eq 0 ]]; then
            log_info "@dcloudio/uni-cli-i18n 安装成功"
        else
            log_error "@dcloudio/uni-cli-i18n 安装失败"
            return 1
        fi
    fi
}

# 验证安装
verify_installation() {
    if command -v cli &> /dev/null; then
        log_info "HBuilderX CLI 安装验证成功"
        log_info "版本信息: $(cli --version 2>/dev/null || echo '无法获取')"
        return 0
    else
        log_error "HBuilderX CLI 安装验证失败"
        return 1
    fi
}

# 主安装流程
main() {
    log_info "开始安装和配置 HBuilderX CLI..."
    
    # 检测操作系统
    detect_os
    
    # 检查 Node.js
    if ! check_nodejs; then
        log_error "请先安装 Node.js 和 npm，然后重新运行脚本"
        exit 1
    fi
    
    # 检查是否已安装 HBuilderX CLI
    if check_hx_cli; then
        log_info "HBuilderX CLI 已经安装并配置，无需重复操作"
        verify_installation
        exit 0
    fi
    
    # 查找 HBuilderX 安装路径
    hbuilderx_path=$(find_hbuilderx)
    if [[ $? -eq 0 ]]; then
        log_info "找到 HBuilderX 安装路径: $hbuilderx_path"

        # 添加到 PATH
        add_to_path "$hbuilderx_path"

        # 验证安装
        if verify_installation; then
            log_info "HBuilderX CLI 配置完成！"
            log_info "您可以使用 'cli --help' 命令验证功能"
        else
            log_error "HBuilderX CLI 配置失败"
            exit 1
        fi
    else
        if [[ -n "$CUSTOM_PATH" ]]; then
            log_error "在指定的自定义路径中未找到 HBuilderX CLI: $CUSTOM_PATH"
            log_info "请确认路径正确且 HBuilderX 已安装在该位置"
        else
            log_warn "未找到 HBuilderX 安装路径"
            log_info "HBuilderX CLI 依赖于 HBuilderX IDE，需要先安装 HBuilderX IDE"
            log_info ""
            log_info "下载地址: https://www.dcloud.io/hbuilderx.html"
            log_info ""
            log_info "Linux 安装步骤:"
            log_info "  1. 访问下载页面，下载 Linux 版本"
            log_info "  2. 解压安装包: tar -xvf HBuilderX-linux-x64-*.tar"
            log_info "  3. 移动到目标目录: mv HBuilderX ~/hbuilderx"
            log_info "  4. 启动 HBuilderX: ~/hbuilderx/HBuilderX"
            log_info ""
            log_info "macOS 安装步骤:"
            log_info "  1. 访问下载页面，下载 macOS 版本"
            log_info "  2. 解压并拖拽到 /Applications 文件夹"
            log_info "  3. 启动 HBuilderX 并完成首次配置"
            log_info ""
            log_info "常见安装路径:"
            if [[ "$OS" == "linux" ]]; then
                log_info "  - ~/hbuilderx"
                log_info "  - /opt/HBuilderX"
                log_info "  - /opt/hbuilderx"
                log_info "  - ~/.local/hbuilderx"
            elif [[ "$OS" == "macos" ]]; then
                log_info "  - /Applications/HBuilderX.app"
                log_info "  - ~/Applications/HBuilderX.app"
            fi
            log_info ""
            log_info "安装完成后，重新运行此脚本进行 CLI 配置"
        fi

        # 尝试通过 npm 安装替代方案
        log_info "尝试通过 npm 安装 uni-app 相关 CLI 工具..."
        install_hx_cli_npm
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
HBuilderX CLI 一键安装配置脚本

用法:
    $(basename "$0") [选项] [自定义路径]

选项:
    -h, --help          显示此帮助信息
    -v, --version       显示脚本版本
    -p, --path PATH     指定 HBuilderX 安装路径

功能:
    - 自动检测操作系统 (Linux/macOS)
    - 检测 HBuilderX 安装路径
    - 将 HBuilderX CLI 添加到系统 PATH
    - 验证安装结果
    - 支持重复运行，避免重复安装

示例:
    ./$(basename "$0")                    # 自动检测并安装配置 HBuilderX CLI
    ./$(basename "$0") --help             # 显示帮助信息
    ./$(basename "$0") -p /opt/HBuilderX  # 指定自定义安装路径
    ./$(basename "$0") /opt/HBuilderX     # 指定自定义安装路径（位置参数）

注意事项:
    - 需要预先安装 HBuilderX IDE (https://www.dcloud.io/hbuilderx.html)
    - 需要 Node.js 和 npm 环境
    - 脚本会自动修改 shell 配置文件 (~/.bashrc 或 ~/.zshrc)
EOF
}

# 版本信息
show_version() {
    echo "HBuilderX CLI 安装配置脚本 v1.0.0"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -p|--path)
            CUSTOM_PATH="$2"
            if [[ -z "$CUSTOM_PATH" ]]; then
                log_error "错误: --path 选项需要指定路径参数"
                exit 1
            fi
            shift 2
            ;;
        -*)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
        *)
            # 处理位置参数（自定义路径）
            if [[ -z "$CUSTOM_PATH" ]]; then
                CUSTOM_PATH="$1"
                shift
            else
                log_error "错误: 只能指定一个自定义路径"
                exit 1
            fi
            ;;
    esac
done

# 运行主函数
main "$@"
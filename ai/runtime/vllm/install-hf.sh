#!/bin/bash

# HuggingFace (hf) CLI 一键安装脚本 (2026 版)
# 'hf' 是 Hugging Face 推出的高性能、多功能的现代命令行工具

set -e

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检测系统
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    echo "$os"
}

# 自动安装 hf
install_hf() {
    info "准备安装现代 'hf' CLI 工具..."
    
    local pkg_spec="huggingface_hub[cli]"
    
    # 优先使用 uv 安装（如果可用）
    if command -v uv &>/dev/null; then
        info "使用 uv 引擎进行安装..."
        # uv tool install 需要包名，huggingface-cli 实际上由 huggingface_hub 提供
        uv tool install "$pkg_spec" --python 3.12 --force
    elif command -v brew &>/dev/null; then
        info "使用 Homebrew 安装..."
        brew install huggingface-cli
    else
        info "使用 pip 安装..."
        pip install -U "$pkg_spec"
    fi
    
    # 检查并设置别名 (2026 规范中 hf 是别名或独立二进制)
    # 即使安装成功，命令名可能依然是 huggingface-cli
    if ! command -v hf &>/dev/null; then
        local target_bin=$(command -v huggingface-cli || echo "")
        if [[ -n "$target_bin" ]]; then
            info "配置 'hf' 命令快捷方式..."
            local rc_file="$HOME/.zshrc"
            [[ "$SHELL" == *"bash"* ]] && rc_file="$HOME/.bash_profile"
            
            if ! grep -q "alias hf=" "$rc_file"; then
                echo -e "\n# HuggingFace CLI Alias\nalias hf='huggingface-cli'" >> "$rc_file"
                info "已添加 alias hf='huggingface-cli' 到 $rc_file"
            fi
            # 立即在当前环境生效（仅限本脚本进程）
            alias hf='huggingface-cli'
        fi
    fi
    
    if command -v hf &>/dev/null || command -v huggingface-cli &>/dev/null; then
        success "hf CLI 安装完成！"
        info "提示: 如果 'hf' 命令未立即生效，请执行 'source $rc_file' 或重启终端。"
    else
        error "安装似乎未成功，请检查错误输出。"
        return 1
    fi
}

# 主函数
main() {
    if command -v hf &>/dev/null; then
        success "hf 已安装: $(hf --version | head -n1)"
        exit 0
    fi
    
    install_hf
}

main "$@"

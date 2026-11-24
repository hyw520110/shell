#!/usr/bin/env bash
# uv Python 版本切换脚本
# 解决 uv 安装 Python 后，python/python3 命令未指向新版本的问题

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"; }

# 显示帮助
show_help() {
    cat << 'EOF'
uv Python 版本切换脚本

用法: ./uv-use-python.sh <版本号>

功能:
    将指定版本的 Python 设置为默认的 python/python3 命令

示例:
    ./uv-use-python.sh 3.12    # 设置 Python 3.12 为默认
    ./uv-use-python.sh 3.13    # 设置 Python 3.13 为默认
    ./uv-use-python.sh --list  # 列出已安装的 Python 版本

说明:
    此脚本会在 ~/.local/bin 中创建指向 uv 安装的 Python 的符号链接，
    并确保 ~/.local/bin 在 PATH 的最前面。

EOF
}

# 列出已安装的 Python
list_installed() {
    log_info "已安装的 Python 版本:"
    uv python list 2>/dev/null || log_warn "无法获取列表"
}

# 设置默认 Python
use_python() {
    local version="${1:-}"
    
    if [[ -z "$version" ]]; then
        log_error "请指定版本号，例如: 3.12"
        show_help
        exit 1
    fi

    # 检查是否已安装该版本
    log_info "检查 Python ${version}..."
    
    # 获取 uv 管理的 Python 路径
    local uv_python_path=""
    
    # 尝试找到对应版本的 Python
    uv_python_path=$(uv python find "${version}" 2>/dev/null || true)
    
    if [[ -z "$uv_python_path" ]] || [[ ! -x "$uv_python_path" ]]; then
        log_warn "Python ${version} 未安装或找不到"
        log_info "正在尝试安装 Python ${version}..."
        uv python install "${version}"
        uv_python_path=$(uv python find "${version}" 2>/dev/null || true)
    fi

    if [[ -z "$uv_python_path" ]] || [[ ! -x "$uv_python_path" ]]; then
        log_error "无法找到 Python ${version} 的可执行文件"
        exit 1
    fi

    log_success "找到 Python ${version}: $uv_python_path"

    # 创建符号链接的目录
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"

    # 备份现有的 python 链接
    local backup_suffix=".backup.$(date +%Y%m%d%H%M%S)"
    
    if [[ -L "$bin_dir/python" ]]; then
        mv "$bin_dir/python" "$bin_dir/python${backup_suffix}" 2>/dev/null || true
        log_info "已备份原有的 python 链接"
    fi
    
    if [[ -L "$bin_dir/python3" ]]; then
        mv "$bin_dir/python3" "$bin_dir/python3${backup_suffix}" 2>/dev/null || true
        log_info "已备份原有的 python3 链接"
    fi

    # 创建新的符号链接
    ln -sf "$uv_python_path" "$bin_dir/python"
    ln -sf "$uv_python_path" "$bin_dir/python3"
    
    log_success "已创建符号链接:"
    log_info "  $bin_dir/python -> $uv_python_path"
    log_info "  $bin_dir/python3 -> $uv_python_path"

    # 检查 PATH 配置
    ensure_path_config

    # 验证
    echo ""
    log_success "验证安装:"
    
    # 使用完整路径验证
    local new_version=$("$bin_dir/python3" --version 2>&1)
    log_success "Python 版本: $new_version"
    
    # 提示用户
    echo ""
    log_info "重要提示:"
    log_info "1. 当前终端会话中，请运行以下命令使更改生效:"
    echo -e "   ${YELLOW}hash -r${NC}  (清除命令缓存)"
    echo ""
    log_info "2. 新终端会话将自动使用新版本的 Python"
    echo ""
    log_info "3. 验证命令:"
    echo -e "   ${YELLOW}which python3${NC}"
    echo -e "   ${YELLOW}python3 --version${NC}"
}

# 确保 PATH 配置正确
ensure_path_config() {
    local shell_rc=""
    
    # 检测当前 shell
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == *"bash"* ]]; then
        if [[ -f "$HOME/.bashrc" ]]; then
            shell_rc="$HOME/.bashrc"
        elif [[ -f "$HOME/.bash_profile" ]]; then
            shell_rc="$HOME/.bash_profile"
        fi
    fi

    if [[ -z "$shell_rc" ]]; then
        shell_rc="$HOME/.profile"
    fi

    log_info "检查 shell 配置: $shell_rc"

    # 检查是否已有 PATH 配置
    if grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$shell_rc" 2>/dev/null; then
        log_info "PATH 配置已存在"
    else
        log_warn "添加 PATH 配置到 $shell_rc"
        {
            echo ""
            echo "# uv Python 路径配置 (由 uv-use-python.sh 添加)"
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$shell_rc"
        log_success "已添加 PATH 配置"
    fi

    # 检查 PATH 顺序（确保 ~/.local/bin 在最前面）
    local path_line=$(grep 'export PATH.*\.local/bin' "$shell_rc" | tail -1)
    if [[ -n "$path_line" ]] && [[ ! "$path_line" =~ \$HOME/\.local/bin:\$PATH ]] && [[ ! "$path_line" =~ \$HOME/.local/bin:\$PATH ]]; then
        log_warn "检测到 PATH 配置可能不在最前面"
        log_info "建议手动编辑 $shell_rc，确保以下行在最前面:"
        echo -e "   ${YELLOW}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    fi
}

# 主函数
main() {
    local cmd="${1:-help}"
    
    case "$cmd" in
        --list|-l|list)
            list_installed
            ;;
        --help|-h|help)
            show_help
            ;;
        *)
            use_python "$cmd"
            ;;
    esac
}

main "$@"

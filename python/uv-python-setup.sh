#!/usr/bin/env bash
# uv Python 环境配置脚本
# 解决 uv 安装 Python 后，python/python3 命令未指向新版本的问题

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# 显示帮助
show_help() {
    cat << 'EOF'
uv Python 环境配置脚本

用法: ./uv-python-setup.sh [命令] [选项]

命令:
    list                列出已安装的 Python 版本
    use <version>       设置默认 Python 版本 (创建符号链接)
    pin <version>       在当前目录创建 .python-version 文件
    venv <version>      创建虚拟环境
    fix-path            修复 PATH 配置，确保 uv 优先

示例:
    ./uv-python-setup.sh list
    ./uv-python-setup.sh use 3.12
    ./uv-python-setup.sh pin 3.12
    ./uv-python-setup.sh venv 3.12

EOF
}

# 列出已安装的 Python
list_pythons() {
    log_info "已安装的 Python 版本:"
    uv python list
}

# 设置默认 Python 版本 (创建符号链接到 ~/.local/bin)
use_python() {
    local version="${1:-}"
    if [[ -z "$version" ]]; then
        log_error "请指定版本号，例如: 3.12"
        exit 1
    fi

    # 检查是否已安装
    if ! uv python list | grep -q "${version}"; then
        log_warn "Python ${version} 未安装，正在安装..."
        uv python install "${version}"
    fi

    local uv_python_dir="$HOME/.local/share/uv/python"
    local target_python=""

    # 查找对应版本的 python
    if [[ "$version" == "3.12" ]]; then
        target_python=$(find "$uv_python_dir" -name "python3.12" -type f 2>/dev/null | head -1)
    elif [[ "$version" == "3.11" ]]; then
        target_python=$(find "$uv_python_dir" -name "python3.11" -type f 2>/dev/null | head -1)
    elif [[ "$version" == "3.13" ]]; then
        target_python=$(find "$uv_python_dir" -name "python3.13" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$target_python" ]]; then
        log_error "找不到 Python ${version} 的可执行文件"
        log_info "已安装的位置:"
        find "$uv_python_dir" -name "python*" -type f 2>/dev/null || true
        exit 1
    fi

    log_info "找到 Python: $target_python"

    # 创建符号链接到 ~/.local/bin
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"

    # 备份旧的链接
    if [[ -L "$bin_dir/python" ]]; then
        mv "$bin_dir/python" "$bin_dir/python.backup.$(date +%s)" 2>/dev/null || true
    fi
    if [[ -L "$bin_dir/python3" ]]; then
        mv "$bin_dir/python3" "$bin_dir/python3.backup.$(date +%s)" 2>/dev/null || true
    fi

    # 创建新的符号链接
    ln -sf "$target_python" "$bin_dir/python"
    ln -sf "$target_python" "$bin_dir/python3"

    log_info "已创建符号链接:"
    log_info "  $bin_dir/python -> $target_python"
    log_info "  $bin_dir/python3 -> $target_python"

    # 验证
    if command -v python >/dev/null 2>&1; then
        local current_version=$(python --version 2>&1)
        log_info "当前 python 版本: $current_version"
    else
        log_warn "python 命令仍不可用，请检查 PATH 配置"
        log_info "建议运行: ./uv-python-setup.sh fix-path"
    fi
}

# 在当前目录创建 .python-version 文件
pin_python() {
    local version="${1:-}"
    if [[ -z "$version" ]]; then
        log_error "请指定版本号，例如: 3.12"
        exit 1
    fi

    echo "${version}" > .python-version
    log_info "已创建 .python-version 文件: ${version}"
    log_info "在此目录下运行 'uv run' 时将自动使用该版本"
}

# 创建虚拟环境
create_venv() {
    local version="${1:-}"
    if [[ -z "$version" ]]; then
        log_error "请指定版本号，例如: 3.12"
        exit 1
    fi

    # 检查是否已安装
    if ! uv python list | grep -q "${version}"; then
        log_warn "Python ${version} 未安装，正在安装..."
        uv python install "${version}"
    fi

    local venv_name=".venv"
    if [[ -d "$venv_name" ]]; then
        log_warn "虚拟环境已存在: $venv_name"
        read -p "是否重新创建? (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$venv_name"
        else
            log_info "保持现有虚拟环境"
            return 0
        fi
    fi

    log_info "创建虚拟环境 (Python ${version})..."
    uv venv --python "${version}"

    log_info "虚拟环境创建完成: $venv_name"
    log_info "激活方式:"
    log_info "  source $venv_name/bin/activate  (bash/zsh)"
    log_info "  source $venv_name/bin/activate.fish  (fish)"
}

# 修复 PATH 配置
fix_path() {
    local shell_rc=""
    if [[ -f "$HOME/.zshrc" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_rc="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        shell_rc="$HOME/.bash_profile"
    fi

    if [[ -z "$shell_rc" ]]; then
        log_error "找不到 shell 配置文件"
        exit 1
    fi

    log_info "检查 PATH 配置: $shell_rc"

    # 检查是否已有 uv 的 PATH 配置
    if grep -q "\.local/bin" "$shell_rc"; then
        log_info "已存在 .local/bin 的 PATH 配置"
    else
        log_info "添加 .local/bin 到 PATH..."
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
        log_info "已添加 PATH 配置到 $shell_rc"
    fi

    # 确保 uv 的 PATH 在最前面
    log_warn "请手动编辑 $shell_rc，确保以下行在最前面:"
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo ""
    log_info "编辑完成后，运行: source $shell_rc"
}

# 主函数
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        list)
            list_pythons
            ;;
        use)
            use_python "$@"
            ;;
        pin)
            pin_python "$@"
            ;;
        venv)
            create_venv "$@"
            ;;
        fix-path)
            fix_path
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

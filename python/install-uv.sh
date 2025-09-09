#!/bin/bash
set -euo pipefail  # 严格模式：错误退出、未定义变量退出、管道失败退出

# === 常量定义 ===
readonly UV_INSTALL_SCRIPT_URL="https://astral.sh/uv/install.sh"
readonly UV_INSTALL_DIR="$HOME/.local/bin"
readonly UV_BINARY="$UV_INSTALL_DIR/uv"
readonly DEFAULT_PYPI_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"  # 默认使用清华源
readonly ALIYUN_PYPI_MIRROR="https://mirrors.aliyun.com/pypi/simple"
# === 函数定义 ===

detect_os() {
    # 检测操作系统类型（可扩展）
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS"
    elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
        echo "Windows"
    else
        echo "Unknown"
    fi
}

install_dependency() {
    local install_cmd
    if command -v apt &> /dev/null; then
        install_cmd="sudo apt update && sudo apt install -y $1"
    elif command -v yum &> /dev/null; then
        install_cmd="sudo yum install -y $1"   
    elif command -v dnf &> /dev/null; then
        install_cmd="sudo dnf install -y $1"
    elif command -v brew &> /dev/null; then
        install_cmd="brew install $1"
    else
        echo "❌ 不支持的操作系统，Windows 安装命令：irm https://astral.sh/uv/install.ps1 | iex" 
        exit 1
    fi
    echo "▶ 检测到 $1 未安装，自动安装..."
    if ! eval "$install_cmd"; then
        echo "❌ 依赖安装失败，请手动安装 $1 并重试。" >&2
        exit 1
    fi
    echo "✓ $1 安装成功！"
}

check_dependencies() {
    if ! command -v curl >/dev/null 2>&1; then
        install_dependency curl
    fi
}

install_uv() {
    # 检查是否已安装
    if [ -x "$UV_BINARY" ]; then
        echo "✓ uv 已安装，版本: $($UV_BINARY --version)"
        return 0
    fi
    echo "▶ 正在下载并安装 uv..."
    # 下载并执行安装脚本
    if ! curl -LsSf "$UV_INSTALL_SCRIPT_URL" | sh; then
        echo "❌ 安装失败！请检查输出日志"
        exit 1
    fi
}

configure_path() {
    local target_path="$UV_INSTALL_DIR"
    local shell_profile
    local pypi_mirror="$DEFAULT_PYPI_MIRROR"

    # 使用用户指定的镜像（优先级高于默认）
    if [ -n "${UV_INDEX_URL:-}" ]; then
        pypi_mirror="$UV_INDEX_URL"
    fi

    # 创建安装目录（如果不存在）
    mkdir -p "$target_path"

    # 自动检测 Shell 类型和配置文件（兼容 macOS）
    case "$(basename "$SHELL")" in
        zsh) shell_profile="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                shell_profile="$HOME/.bash_profile"
            else
                shell_profile="$HOME/.bashrc"
            fi
            ;;
        *) shell_profile="$HOME/.profile" ;;
    esac

    # 临时添加路径到当前会话
    if [[ ":$PATH:" != *":$target_path:"* ]]; then
        echo "✓ 临时添加路径到当前会话..."
        export PATH="$target_path:$PATH"
    else
        echo "✓ 当前 PATH 已包含 $target_path"
    fi

    # 永久配置检查（避免重复添加）
    if [ -f "$shell_profile" ]; then
        if grep -qF "export PATH=\"$target_path:\$PATH\"" "$shell_profile"; then
            echo "✓ 路径配置已存在于 $shell_profile"
        else
            echo "✓ 永久添加路径到 $shell_profile..."
            echo "export PATH=\"$target_path:\$PATH\"" >> "$shell_profile"
        fi

        # 配置 PyPI 镜像（仅在未设置时添加）
        if ! grep -qF "UV_INDEX_URL" "$shell_profile"; then
            echo "✓ 永久添加 PyPI 镜像配置到 $shell_profile..."
            echo "export UV_INDEX_URL=\"$pypi_mirror\"" >> "$shell_profile"
        fi
    else
        echo "⚠️ 配置文件 $shell_profile 不存在，将创建并添加路径..."
        echo "export PATH=\"$target_path:\$PATH\"" > "$shell_profile"
        echo "export UV_INDEX_URL=\"$pypi_mirror\"" >> "$shell_profile"
    fi

    # 临时设置镜像（当前会话生效）
    if [ -z "${UV_INDEX_URL:-}" ]; then
        export UV_INDEX_URL="$pypi_mirror"
    fi
}

verify_installation() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "❌ uv 安装失败！请尝试以下操作："
        echo "1. 重新打开终端"
        echo "2. 手动执行：source $shell_profile"
        exit 1
    fi
    echo "✓ 安装成功！版本信息：$(uv --version)"
    echo "✓ 当前 PyPI 镜像配置：$UV_INDEX_URL"
}

main() {
    check_dependencies
    install_uv
    configure_path
    verify_installation
    echo "✅ 所有操作已完成！"

    # === 使用说明 ===
    echo
    echo "🔧 快速使用指南："
    echo "  初始化项目：uv init my_project"
    echo "  指定 Python 版本：uv init my_project --python 3.11"
    echo "  添加生产依赖：uv add requests"
    echo "  添加开发依赖：uv add pytest --dev"
    echo "  移除依赖：uv remove requests"
    echo
    echo "📦 依赖管理："
    echo "  安装全局工具：uv tool install ruff"
    echo "  同步依赖：uv sync"
    echo "  升级依赖：uv sync --upgrade"
    echo "  升级特定包：uv sync --upgrade-package requests"
    echo "  查看已安装包：uv pip list"
    echo "  生成 requirements.txt：uv pip freeze > requirements.txt"
    echo "  安装 requirements.txt：uv pip install -r requirements.txt"
    echo
    echo "🌐 国内镜像说明："
    echo "  默认使用清华源（$DEFAULT_PYPI_MIRROR），如需切换镜像："
    echo "  1. 手动修改环境变量 UV_INDEX_URL"
    echo "  2. 或运行脚本时指定：UV_INDEX_URL=$ALIYUN_PYPI_MIRROR ./install_uv.sh"
    echo
    echo "🗑️ 清理缓存："
    echo "  清理 uv 缓存：uv cache clean"
    echo "  清理 pip 缓存：uv pip cache purge"
}

# === 执行主逻辑 ===
main
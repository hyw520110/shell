#!/bin/bash
set -euo pipefail  # 严格模式：错误退出、未定义变量退出、管道失败退出

# 常量定义
readonly UV_INSTALL_SCRIPT_URL="https://astral.sh/uv/install.sh"
readonly UV_INSTALL_DIR="$HOME/.local/bin"
readonly UV_BINARY="$UV_INSTALL_DIR/uv"

# 检测操作系统类型
detect_os() {

}

# 安装依赖（自动安装 curl）
install_dependency() {
    local install_cmd
    if command -v apt &> /dev/null; then
        install_cmd="sudo apt update && sudo apt install -y curl"
    elif command -v yum &> /dev/null; then
        install_cmd="sudo yum install -y curl"   
    elif command -v dnf &> /dev/null; then
        install_cmd="sudo dnf install -y curl"
    elif command -v brew &> /dev/null; then
        install_cmd="brew install curl"
    else
        echo "不支持的操作系统，windows安装(PowerShell)：irm https://astral.sh/uv/install.ps1 | iex" 
        exit 1
    fi
    echo "▶ 检测到 curl 未安装，自动安装..."
    if ! eval "$install_cmd"; then
        echo "❌ 依赖安装失败，请手动安装 curl 并重试。" >&2
        exit 1
    fi
    echo "✓ curl 安装成功！"
}

# 依赖检查（自动安装 curl）
check_dependencies() {
    if ! command -v curl >/dev/null 2>&1; then
        install_dependency
    fi
}

# 安装 UV
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

# 配置环境变量
configure_path() {
    local target_path="$UV_INSTALL_DIR"
    local shell_profile

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
        if ! grep -qF "UV_INDEX_URL" "$shell_profile"; then
	        echo 'export UV_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"' >> "$shell_profile"
        fi
    else
        echo "⚠️ 配置文件 $shell_profile 不存在，将创建并添加路径..."
        echo "export PATH=\"$target_path:\$PATH\"" > "$shell_profile"
    fi
}

# 验证安装
verify_installation() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "❌ uv 安装失败！请尝试以下操作："
        echo "1. 重新打开终端"
        echo "2. 手动执行：source $shell_profile"
        exit 1
    fi
    echo "✓ 安装成功！版本信息：$(uv --version)"
}

main() {
    check_dependencies
    install_uv
    configure_path
    verify_installation
    echo "✅ 所有操作已完成！"
    echo "初始化项目：uv init my_project"
    echo "指定python版本初始化项目：uv init my_project --python 3.11"
    echo "添加生产依赖：uv add requests"
    echo "添加开发依赖：uv add pytest --dev"
    echo "移除依赖：uv remove requests"
    # 全局系统级安装：uv pip install --system pandas
    # 安装全局工具：uv tool install ruff  # 安装代码格式化工具
    # 运行工具:uv tool run ruff check .
    echo "同步依赖(根据 pyproject.toml 和 uv.lock 安装依赖)：uv sync"
    echo "升级依赖：uv sync --upgrade"
    echo　"升级特定包:uv sync --upgrade-package requests"
    echo "已安装包:uv pip list"
    echo "依赖树:uv tree"
    echo "导出/安装依赖：uv pip freeze > requirements.txt
    uv pip install -r requirements.txt"
    echo "创建虚拟环境：uv venv .venv"
    echo "激活虚拟环境：source .venv/bin/activate"
    # 清理缓存
    # uv cache clean
	#uv pip cache purge
    
}

main
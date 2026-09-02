#!/bin/bash
set -e

# 显示帮助信息
show_help() {
    cat << EOF
Cursor AI 编辑器安装脚本

安装 Cursor - 基于 VS Code 的 AI 驱动代码编辑器，提供智能编程助手。

用法: ./install-cursor.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息

说明:
    - 基于 VS Code 构建
    - AI 代码助手和自动补全
    - 支持多种编程语言
    - 兼容 VS Code 插件
    - 自动下载并安装

特性:
    - AI 代码生成
    - 智能代码补全
    - 代码重构建议
    - Bug 自动修复
    - 代码解释功能

示例:
    ./install-cursor.sh              # 安装 Cursor
    ./install-cursor.sh --version    # 显示版本信息

使用方式:
    # 安装后启动
    cursor

    # 查看 AI 助手
    Cursor + Tab (AI 补全)

验证安装:
    cursor --version

注意事项:
    - 需要网络连接下载
    - 支持 macOS 和 Linux
    - 建议使用官方账号获得更多功能

更多信息: https://cursor.sh/

EOF
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Cursor安装脚本版本: 1.0"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 主安装逻辑
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
mkdir -p "$DOWNLOAD_DIR"
TMP_SCRIPT="$DOWNLOAD_DIR/cursor-free-vip-install.sh"
URL="https://raw.githubusercontent.com/yeongpin/cursor-free-vip/main/scripts/install.sh"

echo "开始安装 Cursor AI 编辑器..."

if [ ! -f "$TMP_SCRIPT" ]; then
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        adl "$URL" "$DOWNLOAD_DIR" "$(basename "$TMP_SCRIPT")"
    else
        curl -fsSLk "$URL" -o "$TMP_SCRIPT"
    fi
fi
chmod +x "$TMP_SCRIPT"
"$TMP_SCRIPT"

echo "Cursor 安装完成！"

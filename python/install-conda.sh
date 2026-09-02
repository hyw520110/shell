#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
Miniconda 安装脚本

安装 Miniconda（Anaconda 的轻量版本），用于 Python 环境和包管理。

用法: ./install-conda.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息
    --version <版本>       指定 Miniconda 版本

说明:
    - 自动下载并安装 Miniconda
    - 安装到用户主目录
    - 自动配置环境变量
    - 支持自定义安装版本

示例:
    ./install-conda.sh                           # 安装最新版本
    ./install-conda.sh --version py39_4.12.0    # 安装指定版本

注意事项:
    - 需要网络连接下载安装包
    - 安装后需要重新加载 shell 配置
    - 建议在非 root 用户下安装

验证安装:
    source ~/.bashrc
    conda --version

EOF
}

# 参数解析
MINICONDA_VERSION=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Miniconda安装脚本版本: 1.0"
            exit 0
            ;;
        --version)
            MINICONDA_VERSION="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 主安装逻辑
if [ -z "$MINICONDA_VERSION" ]; then
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    bash Miniconda3-latest-Linux-x86_64.sh
    rm -rf Miniconda3-latest-Linux-x86_64.sh
else
    wget https://repo.anaconda.com/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh
    bash Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh
    rm -rf Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh
fi

source ~/.bashrc
conda --version

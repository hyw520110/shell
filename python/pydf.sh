#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
pydf 工具安装脚本

安装 pydf（Python 数据框架工具），用于数据分析和处理。

用法: ./pydf.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息

说明:
    - 自动安装 Python pip
    - 升级 pip 到最新版本
    - 安装 pydf 数据分析包

依赖要求:
    - Python 3.6+
    - pip 包管理器
    - 系统权限（安装系统包）

示例:
    ./pydf.sh                # 安装pydf
    ./pydf.sh --version       # 显示版本信息

使用方式:
    # pydf 是一个数据分析工具
    # 具体使用方式请查看官方文档或 pydf --help

注意事项:
    - 需要root权限安装系统Python包
    - 安装过程中需要网络连接
    - 建议在虚拟环境中使用

验证安装:
    python -c "import pydf; print(pydf.__version__)"

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
            echo "pydf安装脚本版本: 1.0"
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
yum -y install python-pip

pip install --upgrade pip

pip install pydf

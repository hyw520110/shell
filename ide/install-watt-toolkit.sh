#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
Watt Toolkit 安装脚本

安装 Watt Toolkit - 游戏平台加速工具，支持 Steam、Epic 等平台加速。

用法: ./install-watt-toolkit.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息

说明:
    - Steam 平台加速
    - Epic Games 加速
    - 游戏下载加速
    - 社区访问加速
    - 自动配置网络优化

支持的平台:
    - Steam
    - Epic Games Store
    - Origin
    - Uplay
    - 其他游戏平台

示例:
    ./install-watt-toolkit.sh              # 安装 Watt Toolkit
    ./install-watt-toolkit.sh --version    # 显示版本信息

使用方式:
    # 安装后启动 Watt Toolkit
    watt-toolkit

    # 选择需要加速的平台
    # 配置加速节点

验证安装:
    which watt-toolkit

注意事项:
    - 需要网络连接下载
    - 主要支持 Linux 系统
    - 需要管理员权限
    - 可能会影响其他网络连接

更多信息: https://steampp.net/

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
            echo "Watt Toolkit安装脚本版本: 1.0"
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
echo "开始安装 Watt Toolkit..."

curl -sSL https://steampp.net/Install/Linux.sh | bash

echo "Watt Toolkit 安装完成！"

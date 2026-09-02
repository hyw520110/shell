#!/usr/bin/env bash

# ==============================================================================
# Qualys Cloud Agent (macOS) 一键安装与卸载脚本
# ==============================================================================

set -e

usage() {
    echo "用法:"
    echo "  安装: $0 install <ActivationId> <CustomerId> <DownloadURL>"
    echo "  卸载: $0 uninstall"
    echo ""
    echo "注意: Qualys 安装包下载通常需要身份验证，请提供一个可直接下载的预签名 URL 链接。"
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

ACTION=$1

if [ "$ACTION" == "uninstall" ]; then
    echo "🗑️ 开始卸载 Qualys Cloud Agent..."
    UNINSTALL_TOOL="/Applications/QualysCloudAgent.app/Contents/MacOS/qualys-cloud-agent.sh"
    
    if [ -f "$UNINSTALL_TOOL" ]; then
        sudo "$UNINSTALL_TOOL" Uninstall
        echo "✅ Qualys 官方卸载程序执行完成。"
    else
        echo "⚠️ 未找到官方卸载脚本，尝试手动清理..."
        sudo rm -rf /Applications/QualysCloudAgent.app
        sudo rm -rf /Library/Application\ Support/QualysCloudAgent
        sudo pkgutil --forget com.qualys.cloud-agent 2>/dev/null || true
        echo "✅ 手动清理完成。"
    fi
    exit 0

elif [ "$ACTION" == "install" ]; then
    if [ "$#" -lt 4 ]; then
        usage
    fi
    
    ACTIVATION_ID=$2
    CUSTOMER_ID=$3
    DOWNLOAD_URL=$4
    PKG_PATH="/tmp/QualysCloudAgent_$(date +%s).pkg"

    echo "⬇️ 正在从提供的链接下载 Qualys 安装包..."
    curl -L -o "$PKG_PATH" "$DOWNLOAD_URL"

    if [ ! -f "$PKG_PATH" ]; then
        echo "❌ 下载失败，请检查 URL 是否有效。"
        exit 1
    fi

    echo "📦 开始安装 Qualys Cloud Agent (需要 sudo 权限)..."
    sudo installer -pkg "$PKG_PATH" -target /

    echo "⚙️ 正在配置并注册 Agent 到 Qualys 平台..."
    CONFIG_TOOL="/Applications/QualysCloudAgent.app/Contents/MacOS/qualys-cloud-agent.sh"

    if [ -f "$CONFIG_TOOL" ]; then
        sudo "$CONFIG_TOOL" ActivationId="$ACTIVATION_ID" CustomerId="$CUSTOMER_ID"
        echo "✅ Qualys Cloud Agent 安装并配置完成！"
    else
        echo "❌ 错误: 未找到配置脚本 $CONFIG_TOOL"
        exit 1
    fi
    
    # 清理临时下载文件
    rm -f "$PKG_PATH"
else
    usage
fi

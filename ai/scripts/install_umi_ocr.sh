#!/usr/bin/env bash
set -e

echo "========================================="
echo "        Umi-OCR 安装指南"
echo "========================================="

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
    echo "⚠️ Umi-OCR 暂未提供原生的 macOS 版本。"
    echo "💡 推荐在 macOS 上的使用方案："
    echo "   1. 使用 Parallels Desktop、VMware 等虚拟机运行 Windows 版本的 Umi-OCR。"
    echo "   2. 在 Umi-OCR 设置中开启 HTTP 服务（默认端口 1224）。"
    echo "   3. 确保你的环境中 UMI_OCR_URL 环境变量指向虚拟机的 IP，如: export UMI_OCR_URL=http://192.168.x.x:1224"
    echo "   4. 确认 http://192.168.x.x:1224/api/ocr 可以在宿主机访问后即可正常使用本 MCP。"
elif [ "$OS" = "Linux" ]; then
    echo "ℹ️ Linux 用户请执行以下手动步骤："
    echo "   1. 访问 https://github.com/hiroi-sora/Umi-OCR/releases 下载 Umi-OCR_Linux_*.tar.xz"
    echo "   2. 解压归档文件"
    echo "   3. 执行解压目录下的 umi-ocr.sh"
    echo "   4. 在 Umi-OCR 的全局设置中开启 HTTP API 服务 (默认端口 1224)"
else
    echo "ℹ️ Windows 用户请执行以下步骤："
    echo "   1. 访问 https://github.com/hiroi-sora/Umi-OCR/releases 下载 Umi-OCR_*.7z.exe"
    echo "   2. 运行并解压"
    echo "   3. 启动 Umi-OCR.exe"
    echo "   4. 在全局设置中开启 HTTP API 服务 (默认端口 1224)"
fi

echo "========================================="
echo "✅ 环境检测完成，MCP 包装器已就绪。"
exit 0

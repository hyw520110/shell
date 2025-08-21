#!/bin/bash

# 脚本功能：生成一个密码学安全的、经过Base64编码的随机字符串。

set -eo pipefail

# --- 配置 ---
# 如果用户不指定长度，默认生成的随机字节数。
# 32字节是生成API密钥等场景的一个安全选择，会产生约43个Base64字符。
DEFAULT_BYTES=32
# --- 结束配置 ---

# --- 帮助函数 ---
show_help() {
    echo "用法: $0 [字节数]"
    echo "生成一个安全的、Base64编码的随机字符串。"
    echo
    echo "  字节数 (可选):   要生成的随机源的字节数。默认为 ${DEFAULT_BYTES}。"
    echo
    echo "示例: $0 16  # 生成一个源自16字节随机数的Base64字符串 (约22个字符长)"
}

# --- 主逻辑 ---

# 1. 处理帮助参数
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# 2. 验证输入，并确定最终的字节数
NUM_BYTES="${1:-$DEFAULT_BYTES}"
if ! [[ "$NUM_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: 字节数必须是一个正整数。" >&2
    show_help
    exit 1
fi

# 3. 生成随机字符串
# 优先使用 openssl，它的 -base64 选项可以一步到位，非常方便。
if command -v openssl &> /dev/null; then
    openssl rand -base64 "$NUM_BYTES"
else
    # 如果 openssl 不可用，则使用 /dev/urandom 作为备用方案。
    # 直接将原始随机字节通过管道传给 base64 命令。
    head -c "$NUM_BYTES" /dev/urandom | base64
fi
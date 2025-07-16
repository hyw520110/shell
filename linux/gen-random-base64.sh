#!/bin/bash

# 检查openssl是否已安装
if command -v openssl &> /dev/null; then
    # 使用openssl生成32位随机字符字符串
    random_string=$(openssl rand -hex 16)
else
    # 使用/dev/urandom生成32位随机字符字符串
    random_string=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \t\n' | tr '0-9a-f' 'g-p')
fi

# 对生成的字符串进行Base64编码
encoded_string=$(echo -n "$random_string" | base64)

# 输出结果
echo "Random String: $random_string"
echo "Base64 Encoded: $encoded_string"

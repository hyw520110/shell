#!/bin/bash
# 设置SSH免密登录到指定的主机
# 参数1：ip或主机名
# 参数2：用户名（可选，默认为root）

# 定义缓存文件路径
ssh_cache=~/.ssh_cache
rsa_pub_file=~/.ssh/id_rsa.pub

# 创建缓存文件，如果不存在的话
if [ ! -f "$ssh_cache" ]; then
    touch "$ssh_cache"
fi

# 检查是否已经对目标主机设置过免密登录
if grep -q -w "$1" "$ssh_cache"; then
    echo "已经为 $1 设置过免密登录，退出。"
    exit 0
else
    echo "$1" >> "$ssh_cache"
fi

# 生成RSA密钥对，如果尚未生成
if [ ! -f "$rsa_pub_file" ]; then
    ssh-keygen -t rsa -N ""
fi

# 获取目标主机和用户名
target_ip="$1"
target_user="${2:-root}"

# 检查目标主机是否可达
if ping -c 1 -W 1 "$target_ip" &> /dev/null; then
    # 尝试进行SSH公钥复制
    if ssh-copy-id -i "$rsa_pub_file" "$target_user@$target_ip"; then
        echo "成功设置 $target_ip 的免密登录。"
    else
        echo "无法设置 $target_ip 的免密登录。"
        exit 1
    fi
else
    echo "$target_ip 不可达。"
    exit 1
fi
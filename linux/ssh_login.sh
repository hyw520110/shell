#!/bin/bash

# 用法提示
usage() {
  echo "Usage: $0 <target_ip> [target_user]"
  echo "  target_ip: 目标主机的IP或主机名 (必填)"
  echo "  target_user: 目标主机的用户名 (可选，默认为root)"
  exit 1
}

# 获取目标主机和用户名
get_target_ip() {
  while true; do
    read -p "请输入目标主机的IP或主机名: " target_ip
    if [ -z "$target_ip" ]; then
      echo "目标主机的IP或主机名不能为空。"
    elif ! ping -c 1 -W 1 "$target_ip" &> /dev/null; then
      echo "$target_ip 不可达，请重新输入。"
    else
      break
    fi
  done
}

get_target_user() {
  read -t 8 -p "请输入目标主机的用户名 (默认为root): " target_user
  target_user="${target_user:-root}"
}

# 获取目标主机和用户名
get_target_ip
get_target_user

# 定义缓存文件路径
ssh_cache=~/.ssh_cache
rsa_pub_file=~/.ssh/id_rsa.pub

# 创建缓存文件，如果不存在的话
if [ ! -f "$ssh_cache" ]; then
    touch "$ssh_cache"
fi

# 检查是否已经对目标主机设置过免密登录
if grep -q -w "$target_ip" "$ssh_cache"; then
    echo "已经为 $target_ip 设置过免密登录，退出。"
    exit 0
else
    echo "$target_ip" >> "$ssh_cache"
fi

# 生成RSA密钥对，如果尚未生成
if [ ! -f "$rsa_pub_file" ]; then
    ssh-keygen -t rsa -N ""
fi

# 尝试进行SSH公钥复制
if ssh-copy-id -i "$rsa_pub_file" "$target_user@$target_ip"; then
    echo "成功设置 $target_ip 的免密登录。"
else
    echo "无法设置 $target_ip 的免密登录。"
    exit 1
fi
#!/bin/bash

# 检查是否已经安装了git
if ! command -v git &> /dev/null; then
    echo "Git 未安装。请先安装 Git。"
    exit 1
fi

# 检查是否已经安装了ssh-keygen
if ! command -v ssh-keygen &> /dev/null; then
    echo "ssh-keygen 未安装。请先安装 ssh-keygen。"
    exit 1
fi

# 显示现有的 SSH 密钥文件
echo "现有的 SSH 密钥文件:"
find ~/.ssh -name "id_rsa*" -type f -print

# 显示现有的 Git 配置
echo "现有的 Git 配置:"
git config --list

# 获取用户输入的邮箱地址
read -p "请输入用于新 SSH 密钥的邮箱地址: " email

# 检查邮箱是否为空
if [ -z "$email" ]; then
    echo "邮箱地址不能为空。请重新运行脚本并输入有效的邮箱地址。"
    exit 0
fi

# 检查默认密钥文件中是否已存在该邮箱的公钥
default_pub_key_file="~/.ssh/id_rsa.pub"
default_pub_key_file=$(eval echo $default_pub_key_file)  # 解析 ~ 为用户的家目录

if [ -f "$default_pub_key_file" ] && grep -q "$email" "$default_pub_key_file"; then
    echo "默认密钥文件 $default_pub_key_file 中已存在该邮箱的公钥。"
    exit 0
fi

# 定义密钥文件路径
key_file="~/.ssh/id_rsa_${email//./_}"
key_file=$(echo $key_file | sed 's/@/_at_/' | sed 's/\./_/g')
key_file=$(eval echo $key_file)  # 解析 ~ 为用户的家目录

# 检查密钥文件是否存在
if [ -f "$key_file" ]; then
    echo "SSH 密钥已存在于 $key_file"
else
    # 生成新的SSH密钥
    ssh-keygen -t rsa -C "$email" -f "$key_file" -q -N ""
    echo "新的 SSH 密钥已生成于 $key_file"
fi

# 检查当前目录是否为Git仓库
if [ -d .git ]; then
    read -p "这是一个 Git 仓库。您希望将其配置为局部设置还是全局设置？(局部/全局): " config_type
else
    config_type="全局"
    echo "不在 Git 仓库中。将配置为全局设置。"
fi

# 设置用户名和邮箱
set_git_config() {
    git config ${1} user.name "$(git config --get user.name)"
    git config ${1} user.email "$email"
    echo "${2} Git 配置已更新为邮箱 $email"
}

if [ "$config_type" == "局部" ]; then
    set_git_config "" "局部"
elif [ "$config_type" == "全局" ]; then
    set_git_config "--global" "全局"
else
    echo "无效的配置类型。使用全局配置。"
    set_git_config "--global" "全局"
fi

# 更新SSH配置文件
ssh_config_file="~/.ssh/config"
ssh_config_file=$(eval echo $ssh_config_file)  # 解析 ~ 为用户的家目录

# 检查SSH配置文件是否存在
if [ ! -f "$ssh_config_file" ]; then
    touch "$ssh_config_file"
    echo "已创建 SSH 配置文件于 $ssh_config_file"
fi

# 获取主机名
hostname=$(echo $email | cut -d'@' -f2)
host_alias="git_${hostname}_${email//./_}"
host_alias=$(echo $host_alias | sed 's/@/_at_/' | sed 's/\./_/g')

# 检查是否已存在相同的配置
if ! grep -q "Host $host_alias" "$ssh_config_file"; then
    echo "正在添加新的 SSH 配置信息"
    echo "Host $host_alias" >> "$ssh_config_file"
    echo "    HostName $hostname" >> "$ssh_config_file"
    echo "    User git" >> "$ssh_config_file"
    echo "    IdentityFile $key_file" >> "$ssh_config_file"
    echo "" >> "$ssh_config_file"
    echo "SSH 配置信息已添加"
else
    echo "SSH 配置信息已存在"
fi

# 输出提示信息
echo "设置已完成。您可以使用新的 SSH 密钥进行身份验证。"
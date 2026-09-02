#!/bin/bash

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法确定操作系统类型"
    exit 1
fi

# 函数：更新系统包
update_packages() {
    if [ "$OS" == "centos" ]; then
        sudo yum update -y
    elif [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
        sudo apt-get update -y
        sudo apt-get upgrade -y
    else
        echo "不支持的操作系统: $OS"
        exit 1
    fi
}

# 函数：安装软件包
install_package() {
    local package_name=$1
    if [ "$OS" == "centos" ]; then
        sudo yum install -y $package_name
    elif [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
        sudo apt-get install -y $package_name
    fi
}

# 更新系统包
echo "Updating system packages..."
update_packages

# 安装 EPEL 仓库（仅限 CentOS）
if [ "$OS" == "centos" ]; then
    if ! rpm -q epel-release &> /dev/null; then
        echo "Installing EPEL repository..."
        install_package epel-release
    else
        echo "EPEL repository is already installed."
    fi
fi

# 安装 Ansible
if ! command -v ansible &> /dev/null; then
    echo "Installing Ansible..."
    install_package ansible
else
    echo "Ansible is already installed."
fi

# 安装 Python3 和 pip
if ! command -v python3 &> /dev/null || ! command -v pip3 &> /dev/null; then
    echo "Installing Python3 and pip..."
    install_package python3 python3-pip
else
    echo "Python3 and pip are already installed."
fi

# 升级 pip
echo "Upgrading pip..."
sudo pip3 install -U pip

# 升级 Ansible
echo "Upgrading Ansible..."
sudo pip3 install -U ansible

# 创建 Ansible 配置文件目录
sudo mkdir -p /etc/ansible

# 创建或更新 Ansible 配置文件
sudo tee /etc/ansible/ansible.cfg > /dev/null <<EOL
[defaults]
inventory = /etc/ansible/hosts
remote_tmp = ~/.ansible/tmp
local_tmp = ~/.ansible/tmp
forks = 5
poll_interval = 15
transport = smart
gathering = implicit
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 300
nocows = 1
host_key_checking = False
log_path = /var/log/ansible.log
EOL

# 创建或更新 Ansible 主机文件
sudo tee /etc/ansible/hosts > /dev/null <<EOL
[local]
localhost ansible_connection=local

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOL

# 验证 Ansible 安装
echo "Verifying Ansible installation..."
ansible --version

# 输出安装完成信息
echo "Ansible has been installed and configured successfully."
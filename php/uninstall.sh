#!/bin/bash

# 更新包列表
sudo apt-get update

# 获取已安装的 PHP 包列表
installed_php_packages=$(dpkg -l | grep '^ii  php' | awk '{print $2}')

# 检查是否有 PHP 包安装
if [ -z "$installed_php_packages" ]; then
    echo "没有安装 PHP 及其相关组件。"
    exit 0
fi

# 显示将要卸载的 PHP 包列表
echo "将要卸载以下 PHP 包:"
echo "$installed_php_packages"

# 卸载 PHP 及其相关组件
sudo apt-get remove --purge -y $installed_php_packages

# 清理残留的配置文件和依赖
sudo apt-get autoremove -y
sudo apt-get clean

# 删除 PHP 配置目录
sudo rm -rf /etc/php/ /var/lib/php/ /var/run/php


# 重启 Nginx 服务
#sudo systemctl restart nginx

echo "PHP 及其相关组件已经卸载完成。"
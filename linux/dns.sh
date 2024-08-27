#!/bin/bash

# 定义DNS服务器地址
dns1="223.5.5.5"
dns2="223.6.6.6"

# 查找当前活跃的网络连接的名称
activename=$(nmcli connection show --active | awk 'NR>1 {print $1}' | head -n 1)

# 检查是否找到了活动连接的名称
if [ -z "$activename" ]; then
    echo "No active network connection found."
    exit 1
fi

# 输出当前活动连接的名称
echo "Active connection name: $activename"

# 一次性设置两个DNS服务器
nmcli connection modify "$activename" ipv4.dns "$dns1,$dns2"

# 检查命令是否成功执行
if [ $? -ne 0 ]; then
    echo "Failed to set DNS servers for connection: $activename"
    exit 1
fi

echo "DNS servers set successfully."

# 重新激活连接以应用新的DNS设置
nmcli connection up "$activename"

# 检查命令是否成功执行
if [ $? -ne 0 ]; then
    echo "Failed to bring up the connection: $activename"
    exit 1
fi

echo "Connection $activename brought up with new DNS settings."
#!/bin/bash

# 获取当前IP地址
function get_current_ip() {
    local ip_tool=$(command -v ip)  # 检查ip工具是否存在
    local ifconfig_tool=$(command -v ifconfig)  # 检查ifconfig工具是否存在

    if [ -n "$ip_tool" ]; then
        # 使用ip工具获取IP地址
        ip_addr=$($ip_tool addr | grep -A 2 "state UP" | grep inet | grep -Ev "inet6|127|172" | grep -v "\.250\." | awk '{print $2}' | awk -F'/' '{print $1}')
    elif [ -n "$ifconfig_tool" ]; then
        # 使用ifconfig工具获取IP地址
        ip_addr=$($ifconfig_tool -a | grep inet | grep -v 127.0.0.1 | grep -v "\.250\." | grep -v inet6 | awk '{print $2}')
    else
        echo "Neither ip nor ifconfig tool found."
        return 1
    fi

    echo "$ip_addr"
}

# 调用函数获取当前IP
ip=$(get_current_ip)
if [ -z "$ip" ]; then
    echo "Failed to detect current IP address."
    exit 1
fi

# 处理命令行参数
if [ "$1" == "-a" ]; then
    echo "Detecting LAN IP..."
    echo "$ip"
    # 获取ARP表中的IP地址
    arp -a | grep -oP '\(\K[^)]*' | grep -v "$ip"
else
    echo "$ip"
fi
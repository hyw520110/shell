#!/bin/bash

# 定义公网 IP 查询 URL 列表
PUBLIC_IP_URLS=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "http://checkip.amazonaws.com"
    "http://ipv4.ident.me"
    "http://ipecho.net/plain"
    "http://myip.ipip.net"
)

# 获取当前IP地址
function get_current_ip() {
    local ip_tool=$(command -v ip)  # 检查ip工具是否存在
    local ifconfig_tool=$(command -v ifconfig)  # 检查ifconfig工具是否存在

    if [ -n "$ip_tool" ]; then
        # 使用ip工具获取IP地址
        ip_addr=$($ip_tool addr show up | grep inet | grep -Ev "inet6|127|172" | grep -v "\.250\." | awk '{print $2}' | awk -F'/' '{print $1}')
    elif [ -n "$ifconfig_tool" ]; then
        # 使用ifconfig工具获取IP地址
        ip_addr=$($ifconfig_tool -a | grep inet | grep -v 127.0.0.1 | grep -v "\.250\." | grep -v inet6 | awk '{print $2}')
    else
        echo "ip或ifconfig命令未找到."
        return 1
    fi

    echo "$ip_addr"
}

# 获取公网 IP 地址
get_public_ip() {
    # 尝试使用 dig 获取公网 IP
    public_ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
    if [ -n "$public_ip" ]; then
        echo "当前公网IP:$public_ip"
        return 0
    fi

    # 如果 dig 失败，尝试使用 HTTP 请求
    for url in "${PUBLIC_IP_URLS[@]}"; do
        public_ip=$(curl -s "$url")
        if [ -n "$public_ip" ]; then
            echo "当前公网IP:$public_ip"
            return 0
        fi
    done
    echo "无法获取公网 IP 地址。"
    return 1
}
get_lan_ips(){
    lan_ips=$(arp -a | grep -oP '\(\K[^)]*')
    if [ -z "$lan_ips" ]; then
        echo "没有找到局域网中的其他设备。"
    else
        echo "局域网中的IP地址:"
        filtered_ips=$(echo "$lan_ips" | grep -v "$local_ip")
        if [ -n "$filtered_ips" ]; then
            echo "$filtered_ips"
        else
            echo "$lan_ips"
        fi
    fi
}
# 显示帮助信息
show_help() {
echo """
Usage: $(basename "$0") [OPTIONS]
Options:
  -a,  获取局域网中的所有 IP 地址
  -p,  获取当前计算机的公网 IP 地址
  -h,  显示此帮助信息
脚本无参数时默认获取当前ip.
"""
}

# 解析命令行参数
OPTIND=1
while getopts ":aph" opt; do
    case "$opt" in
        a)
            get_lan_ips
            ;;
        p)
            get_public_ip
            ;;
        h)
            show_help
            ;;
        \?)
            echo "无效的选项: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# 调用函数获取当前IP
local_ip=$(get_current_ip)
if [ -z "$local_ip" ]; then
    echo "获取当前ip失败."
    exit 1
fi
echo "$local_ip"
shift $((OPTIND - 1))


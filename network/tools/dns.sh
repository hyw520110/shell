#!/bin/bash

# 脚本功能：修改网络连接的DNS服务器（支持 macOS 和 Linux）

set -eo pipefail

# --- 配置 ---
# 如果用户不提供DNS服务器，则使用下面的默认值
DEFAULT_DNS_SERVERS="223.5.5.5,223.6.6.6"
# --- 结束配置 ---

# --- 帮助函数 ---
show_help() {
    cat << EOF
DNS 服务器配置工具 - 修改网络连接的DNS服务器

用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -s, --servers       指定DNS服务器（多个用空格分隔）
  -n, --interface     指定网络接口
  -l, --list          列出所有网络接口
  -g, --get           查看当前DNS配置

示例:
  $0                           # 交互式选择网络接口并设置DNS
  $0 -s "8.8.8.8 8.8.4.4"    # 设置自定义DNS
  $0 -n Wi-Fi -s "8.8.8.8"    # 指定接口 Wi-Fi
  $0 -l                        # 列出所有网络接口
  $0 -g                        # 交互式选择接口并查看DNS配置
  $0 -n Wi-Fi -g               # 查看 Wi-Fi 的DNS配置

EOF
}

# --- 获取网络接口列表 ---
get_network_interfaces() {
    if [ "$(uname)" = "Darwin" ]; then
        # macOS: 使用 networksetup
        networksetup -listallnetworkservices | grep -v "An asterisk"
    else
        # Linux: 使用 nmcli
        if command -v nmcli &> /dev/null; then
            nmcli connection show --active | awk 'NR>1 {print $1}'
        else
            # 备选：使用 ip 命令
            ip link show | grep -E "^[0-9]+:" | awk -F: '{print $2}' | tr -d ' '
        fi
    fi
}

# --- 查看 DNS 配置 ---
get_dns() {
    local interface="$1"
    
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo "接口 '$interface' 的 DNS 配置:"
        echo "----------------------------------------"
        networksetup -getdnsservers "$interface"
        echo "----------------------------------------"
    else
        echo "连接 '$interface' 的 DNS 配置:"
        echo "----------------------------------------"
        nmcli connection show "$interface" | grep -E "ipv4.dns|ipv6.dns" || echo "未找到 DNS 配置"
        echo "----------------------------------------"
    fi
}

# --- 设置 DNS (macOS) ---
set_dns_macos() {
    local interface="$1"
    local dns_servers="$2"

    echo "正在为接口 '$interface' 设置 DNS..."
    # macOS 的 networksetup 需要空格分隔的 DNS 服务器
    # 将逗号分隔的字符串转换为空格分隔
    dns_servers=$(echo "$dns_servers" | tr ',' ' ')
    networksetup -setdnsservers "$interface" $dns_servers
    echo "DNS 设置已成功应用。"
}

# --- 设置 DNS (Linux) ---
set_dns_linux() {
    local interface="$1"
    local dns_servers="$2"

    if command -v nmcli &> /dev/null; then
        echo "正在为连接 '$interface' 设置 DNS..."
        nmcli connection modify "$interface" ipv4.dns "$dns_servers"
        nmcli connection modify "$interface" ipv6.dns ""
        nmcli connection down "$interface" || true
        nmcli connection up "$interface"
        echo "DNS 设置已成功应用。"
    else
        echo "错误: Linux 系统需要安装 NetworkManager (nmcli)" >&2
        exit 1
    fi
}

# --- 主逻辑 ---

# 检测操作系统
OS_TYPE=$(uname)

# 解析命令行参数
INTERFACE=""
DNS_SERVERS=""
GET_DNS_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--servers)
            shift
            DNS_SERVERS="$1"
            shift
            ;;
        -n|--interface)
            shift
            INTERFACE="$1"
            shift
            ;;
        -l|--list)
            echo "可用的网络接口:"
            get_network_interfaces
            exit 0
            ;;
        -g|--get)
            GET_DNS_ONLY=true
            shift
            ;;
        *)
            echo "错误: 未知参数 '$1'" >&2
            echo "使用 -h 或 --help 查看帮助信息" >&2
            exit 1
            ;;
    esac
done

# 如果是只查看 DNS 配置
if [ "$GET_DNS_ONLY" = true ]; then
    # 如果未指定接口，则交互式选择
    if [ -z "$INTERFACE" ]; then
        echo "可用的网络接口:"
        interfaces=($(get_network_interfaces))

        if [ ${#interfaces[@]} -eq 0 ]; then
            echo "错误: 未找到任何网络接口。" >&2
            exit 1
        fi

        # 创建交互式菜单
        PS3="请选择网络接口: "
        select choice in "${interfaces[@]}"; do
            if [ -n "$choice" ]; then
                INTERFACE="$choice"
                break
            else
                echo "无效选择，请重试。"
            fi
        done
    fi

    get_dns "$INTERFACE"
    exit 0
fi

# 设置默认 DNS
if [ -z "$DNS_SERVERS" ]; then
    DNS_SERVERS="$DEFAULT_DNS_SERVERS"
fi

# 如果未指定接口，交互式选择
if [ -z "$INTERFACE" ]; then
    echo "可用的网络接口:"
    interfaces=($(get_network_interfaces))

    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "错误: 未找到任何网络接口。" >&2
        exit 1
    fi

    # 创建交互式菜单
    PS3="请选择网络接口: "
    select choice in "${interfaces[@]}"; do
        if [ -n "$choice" ]; then
            INTERFACE="$choice"
            break
        else
            echo "无效选择，请重试。"
        fi
    done
fi

echo "--------------------------------------------------"
echo "将要执行以下操作:"
echo "  - 操作系统: $OS_TYPE"
echo "  - 网络接口: $INTERFACE"
echo "  - DNS 服务器: $DNS_SERVERS"
echo "--------------------------------------------------"

# 根据操作系统设置 DNS
if [ "$OS_TYPE" = "Darwin" ]; then
    set_dns_macos "$INTERFACE" "$DNS_SERVERS"
else
    set_dns_linux "$INTERFACE" "$DNS_SERVERS"
fi

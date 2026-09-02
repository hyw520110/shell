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

# 获取本机主 IP 地址（排除虚拟网卡和无效 IP）
get_main_ip() {
    local os=$(uname -s)

    if [ "$os" = "Linux" ]; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
    elif [ "$os" = "Darwin" ]; then
        local interface=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
        if [ -z "$interface" ]; then
            echo "无法确定网络接口" >&2
            return 1
        fi
        ifconfig "$interface" 2>/dev/null | awk '$1 == "inet" {print $2}'
    else
        local ip_tool=$(command -v ip 2>/dev/null)  # 检查ip工具是否存在
        local ifconfig_tool=$(command -v ifconfig 2>/dev/null)  # 检查ifconfig工具是否存在

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
    fi
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

# 获取主机名（通过反向 DNS 解析）
get_hostname() {
    local ip="$1"
    local os=$(uname -s)

    if [ "$os" = "Linux" ]; then
        nslookup "$ip" 2>/dev/null | awk '/name/ {print $3}' | sed 's/\.$//' | head -n 1
    elif [ "$os" = "Darwin" ]; then
        host "$ip" 2>/dev/null | awk -F 'pointer to ' '/pointer/ {print $2}' | sed 's/\.$//' | head -n 1
    else
        echo "未知"
    fi
}

# 获取 MAC 地址（通过 arp 命令）
get_mac_address() {
    local ip="$1"
    local os=$(uname -s)

    if [ "$os" = "Linux" ]; then
        arp -n "$ip" | awk '/ether/ {print $3}' 2>/dev/null
    elif [ "$os" = "Darwin" ]; then
        # 使用更精确的正则表达式匹配 MAC 地址
        arp -a | grep -E "$ip" | awk '{print $4}' | sed 's/:/g; s/../&:/g; s/:$//' 2>/dev/null
    else
        echo "未知"
    fi
}

# 计算网段范围（仅支持 CIDR 格式）
calculate_network_range() {
    local ip="$1"
    local cidr="$2"

    IFS='.' read -r a b c d <<< "$ip"
    local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    local mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    local network=$(( ip_int & mask ))
    local broadcast=$(( network | (~mask & 0xFFFFFFFF) ))

    echo "$network $broadcast"
}

# 扫描当前网段的所有 IP 地址（并行化版本）
scan_network() {
    local main_ip="$1"
    local cidr="${2:-24}"
    local scan_mode="${3:-all}" # all, online, or offline

    # 内部函数，用于扫描单个IP并收集结果
    _scan_ip() {
        local target_ip="$1"
        local tmp_file="$2"

        if ping -c 1 -W 1 "$target_ip" > /dev/null 2>&1; then
            local hostname
            local mac
            hostname=$(get_hostname "$target_ip")
            mac=$(get_mac_address "$target_ip")
            echo "$target_ip|${hostname:-未知}|${mac:-未知}|在线" >> "$tmp_file"
        else
            echo "$target_ip|未知|未知|离线" >> "$tmp_file"
        fi
    }

    IFS='/' read -ra ip_parts <<< "$main_ip"
    local ip="${ip_parts[0]}"
    local cidr_to_scan="${ip_parts[1]:-$cidr}"

    read network broadcast <<< "$(calculate_network_range "$ip" "$cidr_to_scan")"

    echo "开始扫描网段: $ip/$cidr_to_scan (模式: $scan_mode)"

    # 打印表头
    printf "%-15s %-20s %-20s %s\n" "IP 地址" "主机名" "物理网卡" "状态"
    printf "%-15s %-20s %-20s %s\n" "---------------" "--------------------" "-------------------" "--------"

    # 使用临时文件来收集无序的并行扫描结果
    local tmpfile=$(mktemp)

    # 增加并发数以提高速度
    local MAX_CONCURRENT=50

    for ((ip_int=network+1; ip_int<broadcast; ip_int++)); do
        # 计算IP地址
        a=$(( (ip_int >> 24) & 0xFF ))
        b=$(( (ip_int >> 16) & 0xFF ))
        c=$(( (ip_int >> 8)  & 0xFF ))
        d=$(( ip_int & 0xFF ))
        local current_ip="$a.$b.$c.$d"

        # 跳过本机IP
        if [ "$current_ip" = "$ip" ]; then
            continue
        fi

        # 在后台执行扫描
        _scan_ip "$current_ip" "$tmpfile" &

        # 控制并发任务数量
        while (( $(jobs -p | wc -l) >= MAX_CONCURRENT )); do
            sleep 0.1
        done
    done

    # 等待所有后台任务完成
    wait

    # 根据模式过滤、排序并输出结果
    local results
    if [ "$scan_mode" = "online" ]; then
        results=$(grep '|在线$' "$tmpfile")
    elif [ "$scan_mode" = "offline" ]; then
        results=$(grep '|离线$' "$tmpfile")
    else
        results=$(cat "$tmpfile")
    fi

    if [ -n "$results" ]; then
        echo "$results" | sort -t '.' -k 1,1n -k 2,2n -k 3,3n -k 4,4n | while IFS='|' read -r ip_addr host mac status; do
            printf "%-15s %-20s %-17s %s\n" "$ip_addr" "$host" "$mac" "$status"
        done
    else
        echo "在 '$scan_mode' 模式下未找到任何主机."
    fi
    # 清理临时文件
    rm -f "$tmpfile"
}

# 显示帮助信息
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "获取本机 IP、扫描网段、获取公网 IP 或显示帮助信息。"
    echo ""
    echo "Options:"
    echo "  -h               显示此帮助信息"
    echo "  -p               获取当前主机的公网 IP 地址"
    echo "  -s [FILTER]      扫描当前网段内的所有 IP 地址（默认 /24 子网）"
    echo ""
    echo "Scan Filters (optional, use with -s):"
    echo "  --online         只显示在线的主机"
    echo "  --offline        只显示离线的主机"
    echo ""
    exit 0
}

# 主程序逻辑
main() {
    if [ $# -eq 0 ]; then
        get_main_ip
        exit 0
    fi

    local scan_mode="all"
    local action=""

    # 解析参数
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h)
                action="help"
                shift
                ;;
            -p)
                action="public_ip"
                shift
                ;;
            -s)
                action="scan"
                shift
                ;;
            --online)
                if [ "$scan_mode" = "offline" ]; then
                    echo "错误: --online 和 --offline 参数不能同时使用。" >&2
                    exit 1
                fi
                scan_mode="online"
                shift
                ;;
            --offline)
                if [ "$scan_mode" = "online" ]; then
                    echo "错误: --online 和 --offline 参数不能同时使用。" >&2
                    exit 1
                fi
                scan_mode="offline"
                shift
                ;;
            *)
                echo "未知参数: $1" >&2
                show_help
                ;;
        esac
    done

    # 执行动作
    case "$action" in
        help)
            show_help
            ;;
        public_ip)
            public_ip=$(get_public_ip)
            if [ -n "$public_ip" ]; then
                echo "$public_ip"
            else
                exit 1
            fi
            ;;
        scan)
            main_ip=$(get_main_ip)
            if [ -z "$main_ip" ]; then
                echo "无法获取有效 IP 地址" >&2
                exit 1
            fi

            if [[ "$main_ip" =~ ^(127\.|169\.254\.) ]]; then
                echo "检测到无效地址（$main_ip），跳过" >&2
                exit 1
            fi

            scan_network "$main_ip" 24 "$scan_mode"
            ;;
        *)
            # 默认行为（如果没有提供有效action但有未知参数）
            get_main_ip
            ;;
    esac
}

# 执行主程序
main "$@"

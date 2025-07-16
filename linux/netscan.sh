#!/bin/bash

# 设置语言环境避免乱码
export LC_ALL=C.UTF-8

# 定义常量
readonly MAC_DB_URL="https://raw.githubusercontent.com/venhow/macdata/refs/heads/main/mac.csv"
readonly MAC_DB="/tmp/${MAC_DB_URL##*/}"  
readonly DEFAULT_TIMEOUT=120  # 默认下载超时时间（秒）

# 获取网络接口
get_interface() {
    if command -v ip &> /dev/null; then
        ip route | grep default | awk '{print $5}'
    elif command -v ifconfig &> /dev/null; then
        netstat -rn | grep default | awk '{print $8}'
    else
        echo "无法找到网络接口"
        exit 1
    fi
}

# 获取子网地址
get_subnet() {
    if command -v ip &> /dev/null; then
        local interface=$(get_interface)
        local ip_info=$(ip addr show "$interface" | grep 'inet ')
        local ip_address=$(echo "$ip_info" | awk '{print $2}' | cut -d '/' -f 1)
        local subnet_mask=$(echo "$ip_info" | awk '{print $2}' | cut -d '/' -f 2)
        ipcalc -n "$ip_address/$subnet_mask" | grep Network | awk '{print $2}'
    elif command -v ifconfig &> /dev/null; then
        local interface=$(get_interface)
        local ip_address=$(ifconfig "$interface" | grep 'inet ' | awk '{print $2}')
        echo "${ip_address}/24"
    else
        echo "无法找到 ip 或 ifconfig 命令，请手动输入子网"
        exit 1
    fi
}

# 安装缺失的依赖包
install_packages() {
    local MISSING=()
    for PACKAGE in "$@"; do
        if ! command -v "$PACKAGE" &> /dev/null; then
            MISSING+=("$PACKAGE")
        fi
    done

    if [ ${#MISSING[@]} -eq 0 ]; then
        return 0
    fi

    echo "开始安装：${MISSING[*]}"
    if [ "$(uname)" == "Linux" ]; then
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -y && sudo apt-get install -y "${MISSING[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${MISSING[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${MISSING[@]}"
        else
            echo "请手动安装: ${MISSING[*]}"
            exit 1
        fi
    elif [ "$(uname)" == "Darwin" ]; then
        brew install "${MISSING[@]}"
    else
        echo "不支持的操作系统"
        exit 1
    fi

    for PACKAGE in "${MISSING[@]}"; do
        if ! command -v "$PACKAGE" &> /dev/null; then
            echo "【失败】安装 $PACKAGE 失败，请手动安装。"
            exit 1
        else
            echo "【成功】$PACKAGE 已安装"
        fi
    done
}

# 加载 MAC 地址数据库（优先本地，没有则下载）
load_mac_database() {
    # 检查本地文件是否存在且未过期（24小时内）
    if [ -f "$MAC_DB" ] && [ $(find "$MAC_DB" -mtime +7) ]; then
        rm -f "$MAC_DB"
    fi

    # 如果本地文件不存在，则下载
    if [ ! -f "$MAC_DB" ]; then
        echo "正在从远程下载 MAC 数据库..."
        if ! curl -sSLo "$MAC_DB" "$MAC_DB_URL" --max-time $DEFAULT_TIMEOUT; then
            return 1
        fi
    fi

    # 解析 CSV 文件
    declare -A oui_map device_map
    tail -n +2 "$MAC_DB" | while IFS=, read -r oui vendor device; do
        # 清理数据
        oui=$(echo "$oui" | tr '[:upper:]' '[:lower:]' | sed 's/ //g')
        vendor=$(echo "$vendor" | sed 's/"/""/g')
        device=$(echo "$device" | sed 's/"/""/g')

        # 构建映射
        oui_map["$oui"]="$vendor"
        device_map["$oui"]="$device"
    done

    # 导出为全局变量
    export -f guess_device_type
    export oui_map device_map
}

# 设备类型识别函数
guess_device_type() {
    local IP=$1
    local MAC=$2
    local PORTS=$3
    local SERVICE_INFO=$4

    DEVICE_TYPE="未知设备"
    VENDOR="未知厂商"

    # 如果 MAC 为空，则直接返回
    if [[ -z "$MAC" ]]; then
        echo "$DEVICE_TYPE|$VENDOR"
        return
    fi

    # 清理 MAC 地址格式
    MAC_CLEAN=$(echo "$MAC" | tr -d ':' | tr '[:upper:]' '[:lower:]')

    # 仅当 MAC_CLEAN 长度为6位时才提取 OUI
    if [[ ${#MAC_CLEAN} -eq 6 ]]; then
        OUI="${MAC_CLEAN:0:6}"
        VENDOR="${oui_map[$OUI]:-未知厂商}"
        DEVICE_TYPE="${device_map[$OUI]:-未知设备}"
    fi

    # 网络设备特征检测
    NETWORK_PORTS="22,23,80,161,179,443,5060,5061"
    ROUTER_SIGNALS="routeros,cisco ios,xrvr,asr9000,nexus"
    SWITCH_SIGNALS="procurve,catalyst,nx-os,ios-xe,ws-c2960x"

    # 根据厂商初步判断
    case $VENDOR in
        "Cisco"|"Juniper"|"Huawei"|"H3C")
            DEVICE_TYPE="网络设备"
            ;;
        "HP"|"Dell"|"Ubiquiti")
            DEVICE_TYPE="网络设备"
            ;;
    esac

    # 根据端口深度判断
    if [[ $PORTS == *"161"* || $PORTS == *"23"* ]]; then
        DEVICE_TYPE="网络设备（SNMP/Telnet）"
    fi

    if [[ $PORTS == *"179"* ]]; then
        DEVICE_TYPE="路由器（BGP）"
    fi

    # 根据服务信息精准识别
    if [[ $SERVICE_INFO == *"RouterOS"* ]]; then
        DEVICE_TYPE="MikroTik路由器"
    elif [[ $SERVICE_INFO == *"Cisco IOS"* ]]; then
        DEVICE_TYPE="Cisco路由器"
    elif [[ $SERVICE_INFO == *"WS-C2960X"* ]]; then
        DEVICE_TYPE="Cisco交换机"
    elif [[ $SERVICE_INFO == *"Huawei VRPV8"* ]]; then
        DEVICE_TYPE="华为路由器"
    fi

    # 端口组合逻辑
    if [[ $PORTS == *"80"* && $PORTS == *"22"* && $PORTS == *"161"* ]]; then
        if [[ $VENDOR == "Cisco" ]]; then
            DEVICE_TYPE="Cisco企业级路由器"
        elif [[ $VENDOR == "Huawei" ]]; then
            DEVICE_TYPE="华为企业级路由器"
        fi
    fi

    echo "$DEVICE_TYPE|$VENDOR"
}

main_scan() {
    check_sudo
    
    declare -A SERVICES_INFO DEVICE_TYPES VENDORS
    declare -a ONLINE_DEVICES
	BEGIN_TIME=$(date +%s)
    # 获取网络信息
    INTERFACE=$(get_interface)
    SUBNET=$(get_subnet)
    echo "【当前接口】: $INTERFACE"
    echo "【当前子网】: $SUBNET"

    # 安装依赖
    install_packages arp-scan nmap curl

    # 加载 MAC 数据库
    load_mac_database

    START_TIME=$(date +%s)
    
    # 使用 arp-scan 获取在线设备
    ONLINE_DEVICES=($(sudo arp-scan --interface="$INTERFACE" --localnet --quiet | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}/ {print $1}'))
    echo "【检测到设备】: ${ONLINE_DEVICES[@]}"

    # 扫描设备信息
    for IP in "${ONLINE_DEVICES[@]}"; do
        echo "扫描 $IP..."
        SCAN_RESULT=$(sudo nmap -sV -T4 -p22,23,80,161,179,443,5060,5061 "$IP" 2>/dev/null)
        PORTS=$(grep 'open' <<< "$SCAN_RESULT" | awk '{print $1}' | cut -d'/' -f1 | paste -sd ',' -)
        SERVICE_INFO=$(grep -E 'open|Service Info' <<< "$SCAN_RESULT" | grep -v 'Nmap scan' | sed 's/^[ \t]*//;s/  \+/ /g' | paste -sd ';' -)
        MAC=$(arp -n "$IP" | awk '/ether/{print $3}' | head -1)

        IFS='|' read -r DEVICE_TYPE VENDOR <<< "$(guess_device_type "$IP" "$MAC" "$PORTS" "$SERVICE_INFO")"
        DEVICE_TYPES["$IP"]=$DEVICE_TYPE
        VENDORS["$IP"]=$VENDOR
        SERVICES_INFO["$IP"]=$SERVICE_INFO
    done

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo "【扫描耗时】: ${DURATION}秒"

    # 显示扫描结果
    printf "\n%-16s %-18s %-25s %-20s %s\n" "IP地址" "MAC地址" "设备类型" "厂商" "服务信息"
    echo "===================================================================================================="
    
    for IP in "${!DEVICE_TYPES[@]}"; do
        MAC=$(arp -n "$IP" | awk '/ether/{print $3}' | head -1)
        printf "%-16s %-18s %-25s %-20s %s\n" \
            "$IP" \
            "${MAC:-未知}" \
            "${DEVICE_TYPES[$IP]}" \
            "${VENDORS[$IP]}" \
            "${SERVICES_INFO[$IP]:0:40}"
    done

    # 显示网络拓扑
    echo -e "\n【网络拓扑结构】："
    GATEWAY=$(ip route | awk '/default/{print $3}')
    echo "└── 网关: $GATEWAY"
    for IP in "${!DEVICE_TYPES[@]}"; do
        [[ $IP != $GATEWAY ]] && echo "    ├── $IP (${DEVICE_TYPES[$IP]})"
    done
	COST=$(($(date +%s) - BEGIN_TIME))
	echo "【总耗时】: ${COST}秒"
}

# 检查管理员权限
check_sudo() {
    if [ "$UID" -ne 0 ]; then
        echo "【错误】请以管理员权限运行此脚本。"
        exit 1
    fi
}

main_scan
exit 0
#!/usr/bin/env bash

# ==============================================================================
# 网络设备扫描工具 (netscan.sh)
# 功能：扫描局域网设备，识别厂商、设备类型及开放服务
# 支持：macOS, Linux (Debian/Ubuntu, CentOS/RHEL)
# ==============================================================================

# 设置语言环境避免乱码
if [[ "$(uname)" == "Darwin" ]]; then
    export LC_ALL=en_US.UTF-8
else
    export LC_ALL=C.UTF-8
fi

# 检查 bash 版本（需要 4.0+ 支持关联数组）
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    for alt_bash in /usr/local/bin/bash /opt/homebrew/bin/bash; do
        if [[ -f "$alt_bash" ]]; then exec "$alt_bash" "$0" "$@"; fi
    done
    echo "【错误】此脚本需要 bash 4.0 或更高版本。请运行: brew install bash (macOS)"
    exit 1
fi

# 常量定义
readonly MAC_DB_URL="https://standards-oui.ieee.org/oui/oui.csv"
readonly CACHE_DIR="${HOME}/.cache/netscan"
readonly MAC_DB="${CACHE_DIR}/ieee_oui.csv"
readonly MAC_DB_INDEX="${CACHE_DIR}/mac_oui_index.txt"
readonly MAC_DB_READY_MARKER="${CACHE_DIR}/.ieee_oui.ready"
readonly MAC_DB_CONNECT_TIMEOUT=15
readonly MAC_DB_TIMEOUT=45
readonly MAC_DB_RETRIES=2
readonly MAC_DB_RETRY_MAX_TIME=90
readonly DEFAULT_PORTS="22,23,80,161,179,443,5060,5061"
readonly QUICK_PORTS="22,80,443"

# 全局变量
CUSTOM_HOST=""
CUSTOM_INTERFACE=""
CUSTOM_SUBNET=""
CUSTOM_PORTS=""
NO_MAC_DB=false
MAC_DB_READY=false
QUICK_MODE=false
SCAN_ALL=false
RAW_SORT=false
OUTPUT_FILE=""
PARALLEL_JOBS=10

# ==============================================================================
# 基础工具函数
# ==============================================================================

# 检查管理员权限
check_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "【错误】此操作需要管理员权限，请使用 sudo 运行。"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd"); fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    echo "正在安装缺失依赖: ${missing[*]}..."
    if [[ "$(uname)" == "Darwin" ]]; then
        brew install "${missing[@]}"
    else
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "${missing[@]}"
        fi
    fi

    for cmd in "${missing[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "【错误】安装 $cmd 失败，请手动安装。"
            exit 1
        fi
    done
}

# 获取默认网关
get_gateway() {
    if [[ "$(uname)" == "Darwin" ]]; then
        route -n get default 2>/dev/null | awk '/gateway:/{print $2}'
    elif command -v ip &>/dev/null; then
        ip route | awk '/default/{print $3}' | head -1
    else
        netstat -rn | grep default | head -1 | awk '{print $2}'
    fi
}

# 获取网络接口
get_interface() {
    if [[ -n "$CUSTOM_INTERFACE" ]]; then
        echo "$CUSTOM_INTERFACE"
        return
    fi
    if command -v ip &>/dev/null; then
        ip route | grep default | awk '{print $5}' | head -1
    elif [[ "$(uname)" == "Darwin" ]]; then
        netstat -rn | grep default | head -1 | awk '{print $NF}'
    else
        netstat -rn | grep default | head -1 | awk '{print $8}'
    fi
}

# 获取子网
get_subnet() {
    if [[ -n "$CUSTOM_SUBNET" ]]; then
        echo "$CUSTOM_SUBNET"
        return
    fi
    local interface=$(get_interface)
    [[ -z "$interface" ]] && return

    if command -v ip &>/dev/null; then
        ip -o -f inet addr show "$interface" | awk '{print $4}' | head -1
    elif [[ "$(uname)" == "Darwin" ]]; then
        local ip_info=$(ifconfig "$interface" | grep 'inet ' | head -1)
        local ip_addr=$(echo "$ip_info" | awk '{print $2}')
        local netmask_hex=$(echo "$ip_info" | awk '{print $4}')
        local netmask_dec=$((netmask_hex))
        local count=0
        for (( i=31; i>=0; i-- )); do
            if (( (netmask_dec >> i) & 1 )); then ((count++)); else break; fi
        done
        echo "${ip_addr}/${count}"
    fi
}

# ==============================================================================
# MAC 地址与厂商识别
# ==============================================================================

# 加载 MAC 数据库
mac_db_is_valid() {
    local db_file=$1

    [[ -s "$db_file" ]] || return 1

    # 只接受看起来完整的 IEEE OUI CSV。下载失败时不会让半截文件覆盖旧缓存。
    awk -F, '
        NR == 1 {
            valid_header = ($0 ~ /Assignment/ && $0 ~ /Organization/)
            next
        }
        NF >= 3 { rows++ }
        END { exit !(valid_header && rows >= 1000) }
    ' "$db_file" >/dev/null 2>&1
}

mac_db_index_is_valid() {
    local index_file=$1

    [[ -s "$index_file" ]] || return 1
    awk -F'|' 'NF >= 2 { rows++ } END { exit !(rows >= 1000) }' \
        "$index_file" >/dev/null 2>&1
}

build_mac_database_index() {
    local index_tmp

    index_tmp=$(mktemp "${CACHE_DIR}/.mac_oui_index.XXXXXX") || return 1
    if ! awk -F, 'NR > 1 {
        oui = tolower($2); gsub(/[" ]/, "", oui);
        vendor = $3; gsub(/^"|"$/, "", vendor);
        if (oui != "") print oui "|" substr(vendor, 1, 50)
    }' "$MAC_DB" >"$index_tmp" 2>/dev/null || ! mac_db_index_is_valid "$index_tmp"; then
        rm -f "$index_tmp"
        return 1
    fi

    mv -f "$index_tmp" "$MAC_DB_INDEX" || {
        rm -f "$index_tmp"
        return 1
    }
    if printf '%s\n' "ready" >"$MAC_DB_READY_MARKER"; then
        MAC_DB_READY=true
    else
        rm -f "$MAC_DB_READY_MARKER"
        return 1
    fi
}

load_mac_database() {
    [[ "$NO_MAC_DB" == true ]] && return 0
    mkdir -p "$CACHE_DIR" || return 0

    local download_tmp headers_tmp
    download_tmp=$(mktemp "${CACHE_DIR}/.ieee_oui.XXXXXX") || return 0
    headers_tmp=$(mktemp "${CACHE_DIR}/.ieee_oui_headers.XXXXXX") || {
        rm -f "$download_tmp"
        return 0
    }

    # 使用临时文件下载，成功且通过校验后才替换正式缓存。
    # 所有网络错误均静默处理：厂商库不可用不应阻断局域网扫描。
    local curl_opts=(
        --fail --location --silent
        --connect-timeout "$MAC_DB_CONNECT_TIMEOUT"
        --max-time "$MAC_DB_TIMEOUT"
        --retry "$MAC_DB_RETRIES"
        --retry-delay 2
        --retry-max-time "$MAC_DB_RETRY_MAX_TIME"
        --dump-header "$headers_tmp"
        --output "$download_tmp"
    )
    [[ -f "$MAC_DB" ]] && curl_opts+=(--time-cond "$MAC_DB")

    if curl "${curl_opts[@]}" "$MAC_DB_URL" >/dev/null 2>&1 && mac_db_is_valid "$download_tmp"; then
        if mv -f "$download_tmp" "$MAC_DB"; then
            echo "正在更新 MAC 厂商索引..."
            if ! build_mac_database_index; then
                MAC_DB_READY=false
                rm -f "$MAC_DB_READY_MARKER"
            fi
        fi
    else
        rm -f "$download_tmp"
        # 仅回退到本脚本确认过的完整缓存，避免继续使用旧版本留下的半截 CSV。
        if [[ -f "$MAC_DB_READY_MARKER" ]] &&
            mac_db_is_valid "$MAC_DB" && mac_db_index_is_valid "$MAC_DB_INDEX"; then
            MAC_DB_READY=true
        else
            MAC_DB_READY=false
            echo "MAC 厂商数据库暂不可用，跳过厂商识别。"
        fi
    fi

    rm -f "$headers_tmp" "$download_tmp"
    return 0
}

# 获取厂商和设备类型
identify_device() {
    local ip=$1 mac=$2 ports=$3 info=$4
    local vendor="未知厂商" type="未知设备"

    if [[ -n "$mac" ]]; then
        local oui=$(echo "$mac" | tr -d ':' | tr '[:upper:]' '[:lower:]' | cut -c1-6)
        if [[ "$MAC_DB_READY" == true && -f "$MAC_DB_INDEX" ]]; then
            vendor=$(grep "^$oui|" "$MAC_DB_INDEX" | head -1 | cut -d'|' -f2)
            [[ -z "$vendor" ]] && vendor="未知厂商"
        fi
    fi

    # 基于厂商的初步识别
    case "$(echo "$vendor" | tr '[:upper:]' '[:lower:]')" in
        *apple*) type="苹果设备" ;;
        *samsung*) type="三星设备" ;;
        *huawei*) type="华为设备" ;;
        *xiaomi*) type="小米设备" ;;
        *cisco*) type="Cisco网络设备" ;;
        *tp-link*) type="TP-Link网络设备" ;;
        *hikvision*) type="监控设备(海康)" ;;
        *dahua*) type="监控设备(大华)" ;;
        *intel*|*realtek*) type="电脑/服务器" ;;
        *espressif*) type="物联网设备" ;;
        *raspberry*) type="树莓派" ;;
    esac

    # 基于端口和服务的精细识别
    if [[ "$ports" == *"161"* ]] || [[ "$ports" == *"23"* ]]; then type="网络设备(SNMP/Telnet)"; fi
    if [[ "$ports" == *"179"* ]]; then type="路由器(BGP)"; fi
    if [[ "$info" == *"RouterOS"* ]]; then type="MikroTik路由器"; fi
    if [[ "$info" == *"Cisco IOS"* ]]; then type="Cisco设备"; fi
    if [[ "$info" == *"Hikvision"* ]]; then type="监控设备"; fi
    
    echo "$vendor|$type"
}

# ==============================================================================
# 扫描核心逻辑
# ==============================================================================

# 发现子网在线设备
discover_ips() {
    local subnet=$1 interface=$2
    if command -v nmap &>/dev/null; then
        sudo nmap -sn -PR "$subnet" -e "$interface" -oG - | awk '/Up$/{print $2}'
    elif command -v arp-scan &>/dev/null; then
        sudo arp-scan --interface="$interface" "$subnet" --quiet | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}/ {print $1}'
    else
        # 最后的手段：并行 ping
        local base_ip=$(echo "$subnet" | cut -d'/' -f1 | cut -d. -f1-3)
        local ping_timeout=1
        [[ "$(uname)" == "Darwin" ]] && ping_timeout=500
        
        for i in {1..254}; do
            ( ping -c 1 -W "$ping_timeout" "${base_ip}.${i}" &>/dev/null && echo "${base_ip}.${i}" ) &
            [[ $((i % 50)) -eq 0 ]] && wait
        done
        wait
    fi
}

# 详细端口扫描（优化版：支持实时输出、分批次扫描、超时控制）
scan_all_details() {
    local ip_list=("$@")
    local ports="${CUSTOM_PORTS:-$DEFAULT_PORTS}"
    
    if [[ -n "$CUSTOM_HOST" && "$SCAN_ALL" == true ]]; then
        ports="1-65535"
        echo "【全端口模式】: 正在执行 1-65535 全端口扫描..."
        echo "【提示】全端口扫描需要较长时间，请耐心等待。按 Ctrl+C 可中断扫描"
    elif [[ "$QUICK_MODE" == true ]]; then
        ports="$QUICK_PORTS"
    fi
    
    local ip_file="/tmp/netscan_ips_$$.txt"
    local output_file="/tmp/netscan_output_$$.txt"
    printf "%s\n" "${ip_list[@]}" > "$ip_file"

    echo "正在扫描 ${#ip_list[@]} 个主机的服务信息 (端口: $ports)..."

    # 构建 Nmap 命令
    local nmap_cmd="sudo nmap -sV -T4 --open -v -p$ports -iL $ip_file -oG $output_file"

    # 全端口扫描时，分批次执行并显示实时进度
    if [[ "$ports" == "1-65535" ]]; then
        echo "【进度】扫描开始，Nmap 将显示实时进度信息..."
        echo "----------------------------------------"
        # 直接运行 nmap，让用户看到实时输出，同时保存到文件
        eval "$nmap_cmd" 2>&1 | tee /dev/tty | grep -E "(Stats:|Scanning|Finished)" || true
        echo "----------------------------------------"
        echo "【进度】扫描完成，正在处理结果..."
    else
        # 非全端口扫描，使用原有方式但添加 --open 优化
        eval "$nmap_cmd" 2>/dev/null
    fi

    # 输出结果
    if [[ -f "$output_file" ]]; then
        cat "$output_file"
    fi
    
    rm -f "$ip_file" "$output_file"
}

# ==============================================================================
# 主函数
# ==============================================================================

show_help() {
    cat << EOF
网络设备扫描工具 (netscan.sh)

用法: $0 [选项]

选项:
  -H, --host IP/DOMAIN    扫描单个主机
  -i, --interface INTF    指定网卡 (如 eth0, en0)
  -s, --subnet CIDR       指定子网 (如 192.168.1.0/24)
  -p, --ports PORTS       指定端口 (如 80,443)
  -q, --quick             快速模式 (仅扫描常用端口)
  -a, --all               子网模式: 包含离线地址; 主机模式: 扫描全端口(1-65535)
  -r, --raw               按 IP 排序 (默认在线优先)
  -n, --no-mac-db         不使用厂商数据库
  -o, --output FILE       结果保存到文件
  -h, --help              显示此帮助

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -H|--host) CUSTOM_HOST="$2"; shift 2 ;;
            -i|--interface) CUSTOM_INTERFACE="$2"; shift 2 ;;
            -s|--subnet) CUSTOM_SUBNET="$2"; shift 2 ;;
            -p|--ports) CUSTOM_PORTS="$2"; shift 2 ;;
            -q|--quick) QUICK_MODE=true; shift ;;
            -a|--all) SCAN_ALL=true; shift ;;
            -r|--raw) RAW_SORT=true; shift ;;
            -n|--no-mac-db) NO_MAC_DB=true; shift ;;
            -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "未知参数: $1"; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"
    check_sudo
    install_dependencies nmap curl awk grep

    # 设置中断处理，清理临时文件
    trap 'echo -e "\n【中断】扫描被用户中断，正在清理..."; rm -f /tmp/netscan_*.txt; exit 130' INT TERM

    load_mac_database

    local start_ts=$(date +%s)
    local interface=$(get_interface)
    local subnet=$(get_subnet)
    local gateway=$(get_gateway)

    declare -A results_mac results_vendor results_type results_info results_status

    if [[ -n "$CUSTOM_HOST" ]]; then
        # 域名解析为 IP
        local resolved_ip=$(nmap -sL "$CUSTOM_HOST" 2>/dev/null | awk '/Nmap scan report for/{print $NF}' | tr -d '()')
        [[ -z "$resolved_ip" ]] && resolved_ip="$CUSTOM_HOST"
        
        if [[ "$resolved_ip" != "$CUSTOM_HOST" ]]; then
            echo "【扫描目标】: $CUSTOM_HOST ($resolved_ip) (单主机模式)"
        else
            echo "【扫描目标】: $resolved_ip (单主机模式)"
        fi
        local online_ips=("$resolved_ip")
    else
        echo "【当前接口】: $interface"
        echo "【检测子网】: $subnet"
        echo "【默认网关】: $gateway"
        echo "正在探测在线设备..."
        local online_ips=($(discover_ips "$subnet" "$interface"))
        echo "发现在线设备: ${#online_ips[@]} 个"
    fi

    if [[ ${#online_ips[@]} -gt 0 ]]; then
        local scan_output
        scan_output=$(scan_all_details "${online_ips[@]}")
        
        # 为所有在线设备初始化基本信息（MAC、厂商、类型）
        for ip in "${online_ips[@]}"; do
            results_status["$ip"]="online"
            
            # 获取 MAC 地址
            local mac=""
            if [[ "$(uname)" == "Darwin" ]]; then
                mac=$(arp -n "$ip" 2>/dev/null | grep -oEi '([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}')
            else
                mac=$(arp -n "$ip" 2>/dev/null | awk '/ether/{print $3}')
            fi
            results_mac["$ip"]="${mac:-未知}"
            
            # 识别厂商和设备类型
            IFS='|' read -r v t <<< "$(identify_device "$ip" "$mac" "" "")"
            results_vendor["$ip"]="$v"
            results_type["$ip"]="$t"
            results_info["$ip"]=""
        done
        
        # 解析扫描结果，更新端口和服务信息
        while IFS= read -r line; do
            if [[ "$line" =~ Host:\ ([0-9.]+) ]]; then
                local ip="${BASH_REMATCH[1]}"
                
                if [[ "$line" == *"Ports:"* ]]; then
                    local ports_info="${line#*Ports: }"
                    # 提取开放端口 (兼容 BSD/GNU grep)
                    local open_ports=$(echo "$ports_info" | tr ',' '\n' | grep '/open/' | cut -d/ -f1 | tr -d ' ' | paste -sd, -)
                    
                    # 提取服务简要信息
                    results_info["$ip"]=$(echo "$ports_info" | sed 's/\/\/\// /g' | cut -c1-60)
                    
                    # 如果有端口信息，重新识别设备类型
                    if [[ -n "$open_ports" ]]; then
                        IFS='|' read -r v t <<< "$(identify_device "$ip" "${results_mac[$ip]}" "$open_ports" "${results_info[$ip]}")"
                        results_vendor["$ip"]="$v"
                        results_type["$ip"]="$t"
                    fi
                fi
            fi
        done <<< "$scan_output"
    fi

    # 准备输出列表
    local display_ips=()
    if [[ "$SCAN_ALL" == true && -z "$CUSTOM_HOST" ]]; then
        local base_ip=$(echo "$subnet" | cut -d/ -f1 | cut -d. -f1-3)
        for i in {1..254}; do display_ips+=("${base_ip}.$i"); done
    else
        display_ips=("${online_ips[@]}")
    fi

    # 排序
    if [[ "$RAW_SORT" == true ]]; then
        IFS=$'\n' display_ips=($(sort -V <<<"${display_ips[*]}")); unset IFS
    else
        # 在线优先
        local sorted=()
        for ip in "${display_ips[@]}"; do [[ "${results_status[$ip]}" == "online" ]] && sorted+=("$ip"); done
        for ip in "${display_ips[@]}"; do [[ "${results_status[$ip]}" != "online" ]] && sorted+=("$ip"); done
        display_ips=("${sorted[@]}")
    fi

    # 打印结果
    local fmt="%-16s %-18s %-20s %-20s %s\n"
    local header=$(printf "$fmt" "IP地址" "MAC地址" "设备类型" "厂商" "服务信息")
    local sep=$(printf '%.0s=' {1..100})

    {
        echo "$header"
        echo "$sep"
        for ip in "${display_ips[@]}"; do
            if [[ "${results_status[$ip]}" == "online" ]]; then
                # 即使没有端口信息也显示设备
                local mac="${results_mac[$ip]:-未知}"
                local vendor="${results_vendor[$ip]:-未知厂商}"
                local type="${results_type[$ip]:-未知设备}"
                local info="${results_info[$ip]:-无开放端口}"
                printf "$fmt" "$ip" "$mac" "$type" "$vendor" "$info"
            elif [[ "$SCAN_ALL" == true ]]; then
                printf "$fmt" "$ip" "-" "离线" "-" "-"
            fi
        done
        echo "$sep"
        echo "扫描耗时: $(($(date +%s) - start_ts)) 秒"
    } | tee "${OUTPUT_FILE:-/dev/null}"

    [[ -n "$OUTPUT_FILE" ]] && echo "结果已保存至: $OUTPUT_FILE"
}

main "$@"

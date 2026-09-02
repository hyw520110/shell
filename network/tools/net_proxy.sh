#!/bin/bash

# 默认值
DEFAULT_IP="127.0.0.1"
DEFAULT_PORT="7890"
USR_ENV_FILE=""

# 全局代理变量定义 - 兼容 macOS
PROXY_VARS="HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy"
# 代理文件目录
PROXY_DIR="$HOME/.net_proxy"
mkdir -p "$PROXY_DIR"

# 脚本参数
# 执行操作
ACTION=""
# 代理IP
PROVIDED_IP=""
# 代理端口
PROVIDED_PORT=""
# 代理类型 (http|socks5)
PROXY_TYPE="http"

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] [IP地址] [端口]"
    echo ""
    echo "选项:"
    echo "  -s, --set         设置代理（当前会话+自动更新配置文件）"
    echo "  -u, --unset       取消代理（当前会话+自动更新配置文件）"
    echo "  -v, --view        查看当前代理信息"
    echo "  -d, --download    下载代理列表 (all|http|socks4|socks5|us)"
    echo "  -n, --count       自动检测时检查的代理数量（默认1）"
    echo "  -t, --type        代理类型 (http|socks5，默认http)"
    echo "  -h, --help        显示此帮助信息"
    echo ""
    echo "参数:"
    echo "  IP地址            代理服务器IP地址 (默认: $DEFAULT_IP)"
    echo "  端口              代理服务器端口 (默认: $DEFAULT_PORT)"
    echo ""
    echo "示例:"
    echo "  $0 -s                    # 使用HTTP代理自动检测并设置"
    echo "  $0 -s -t socks5          # 使用SOCKS5代理自动检测并设置"
    echo "  $0 -s 192.168.1.100      # 使用指定IP和默认端口设置代理"
    echo "  $0 -s 192.168.1.100 8080 # 使用指定IP和端口设置代理"
    echo "  $0 -s -n 5               # 自动检测并检查5个代理"
    echo "  $0 -u                    # 取消代理"
    echo "  $0 -v                    # 查看当前代理信息"
    echo "  $0 -d http               # 下载HTTP代理列表"
    echo "  $0 -d socks5             # 下载SOCKS5代理列表"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--set)
            ACTION="set"
            shift
            ;;
        -u|--unset)
            ACTION="unset"
            shift
            ;;
        -v|--view)
            ACTION="view"
            shift
            ;;
        -d|--download)
            ACTION="download"
            shift
            if [[ -n "$1" ]]; then
                DOWNLOAD_TYPE="$1"
                shift
            else
                echo "错误: -d 选项需要指定参数 (all|http|socks4|socks5|us)"
                show_help
                exit 1
            fi
            ;;
        -n|--count)
            shift
            if [[ -n "$1" && "$1" =~ ^[0-9]+$ ]]; then
                PROXY_CHECK_COUNT="$1"
                shift
            else
                echo "错误: -n 选项需要指定数字参数"
                show_help
                exit 1
            fi
            ;;
        -t|--type)
            shift
            if [[ -n "$1" && "$1" =~ ^(http|socks5)$ ]]; then
                PROXY_TYPE="$1"
                shift
            else
                echo "错误: -t 选项需要指定 http 或 socks5"
                show_help
                exit 1
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ -z "$PROVIDED_IP" ]]; then
                PROVIDED_IP="$1"
            elif [[ -z "$PROVIDED_PORT" ]]; then
                PROVIDED_PORT="$1"
            else
                echo "错误: 未识别的参数: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# 获取当前主机IP
get_current_ip() {
    # 多种方法获取IP，增加可靠性
    local ip

    # 优先使用hostname -I
    ip=$(hostname -I | awk '{print $1}' 2>/dev/null)
    if [[ -n "$ip" && "$ip" != "127.0.0.1" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
        return
    fi

    # 备选方案：使用ip命令
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return
        fi
    fi

    # 最后备选方案：使用ifconfig
    if command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return
        fi
    fi

    # 如果都失败了，返回默认值
    echo "127.0.0.1"
}

# 检测用户的shell类型
get_shell_type() {
    local shell_type
    if [[ "$SHELL" == *"/zsh"* ]]; then
        shell_type="zsh"
    elif [[ "$SHELL" == *"/bash"* ]]; then
        shell_type="bash"
    elif [[ -f "$HOME/.zshrc" ]]; then
        shell_type="zsh"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_type="bash"
    else
        shell_type="bash"  # 默认使用bash
    fi
    echo "$shell_type"
}

# 获取shell配置文件路径
load_usr_env_file() {
    local shell_type=$(get_shell_type)
    if [[ "$shell_type" == "zsh" ]]; then
        USR_ENV_FILE="$HOME/.zshrc"
    else
        USR_ENV_FILE="$HOME/.bashrc"
    fi
    #echo "source $USR_ENV_FILE"
    source $USR_ENV_FILE
}

# 删除指定配置文件中的代理设置行 - 封装为函数
delete_proxy_from_config() {
    local USR_ENV_FILE="$1"
    
    # 检查文件是否存在
    if [[ ! -f "$USR_ENV_FILE" ]]; then
        return 0
    fi
    
    # 遍历删除所有代理变量设置
    for var in $PROXY_VARS; do
        sed -i.bak "/export $var/d" "$USR_ENV_FILE" 2>/dev/null || {
            # 对于 macOS（BSD sed），语法略有不同
            sed -i '' "/export $var/d" "$USR_ENV_FILE"
        }
    done
    
    # 删除可能存在的其他代理相关设置
    sed -i.bak '/export ALL_PROXY/d' "$USR_ENV_FILE" 2>/dev/null || {
        sed -i '' '/export ALL_PROXY/d' "$USR_ENV_FILE"
    }
    sed -i.bak '/export all_proxy/d' "$USR_ENV_FILE" 2>/dev/null || {
        sed -i '' '/export all_proxy/d' "$USR_ENV_FILE"
    }
    sed -i.bak '/网络代理设置 - 由 net_proxy.sh 自动生成/d' "$USR_ENV_FILE" 2>/dev/null || {
        sed -i '' '/网络代理设置 - 由 net_proxy.sh 自动生成/d' "$USR_ENV_FILE"
    }
    sed -i.bak '/socks代理设置/d' "$USR_ENV_FILE" 2>/dev/null || {
        sed -i '' '/socks代理设置/d' "$USR_ENV_FILE"
    }
    sed -i.bak '/socks5:\/\//d' "$USR_ENV_FILE" 2>/dev/null || {
        sed -i '' '/socks5:\/\//d' "$USR_ENV_FILE"
    }
}

# 在配置文件中设置环境变量（添加或更新）
set_proxy_in_config() {
    local USR_ENV_FILE="$1"
    local ip="$2"
    local port="$3"
    local proxy_type="${4:-http}"

    # 检查配置文件是否存在，如果不存在则创建
    if [[ ! -f "$USR_ENV_FILE" ]]; then
        touch "$USR_ENV_FILE"
    fi

    # 先删除现有的代理设置
    delete_proxy_from_config "$USR_ENV_FILE"

    # 添加新的代理设置到文件末尾
    {
        echo ""
        echo "# 网络代理设置 - 由 net_proxy.sh 自动生成"
        if [[ "$proxy_type" == "socks5" ]]; then
            echo "export ALL_PROXY=\"socks5://$ip:$port\""
            echo "export all_proxy=\"socks5://$ip:$port\""
            echo "export HTTP_PROXY=\"http://$ip:$port\""
            echo "export HTTPS_PROXY=\"http://$ip:$port\""
            echo "export http_proxy=\"http://$ip:$port\""
            echo "export https_proxy=\"http://$ip:$port\""
        else
            echo "export HTTP_PROXY=\"http://$ip:$port\""
            echo "export HTTPS_PROXY=\"http://$ip:$port\""
            echo "export http_proxy=\"http://$ip:$port\""
            echo "export https_proxy=\"http://$ip:$port\""
            echo "#export ALL_PROXY=\"socks5://$ip:$port\"  # 如果需要socks代理，取消注释此行"
        fi
        echo "export NO_PROXY=\"\""
        echo "export no_proxy=\"\$NO_PROXY\""
    } >> "$USR_ENV_FILE"

    source $USR_ENV_FILE
}

# 从配置文件中移除代理设置
unset_proxy_from_config() {
    local USR_ENV_FILE="$1"
    delete_proxy_from_config "$USR_ENV_FILE"
}

# 检测端口连通性
check_port_connectivity() {
    local ip="$1"
    local port="$2"

    # 优先使用nc命令检测
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w5 "$ip" "$port"; then
            return 0
        else
            return 1
        fi
    # 如果nc不可用，使用telnet作为备选方案
    elif command -v telnet >/dev/null 2>&1; then
        # 使用telnet命令测试连接
        timeout 5 telnet "$ip" "$port" < /dev/null > /dev/null 2>&1
        return $?
    else
        # 最后备选方案：使用bash的/dev/tcp功能
        if (exec 3<>/dev/tcp/$ip/$port) 2>/dev/null; then
            exec 3<&- 3>&-
            return 0
        else
            echo "警告: 未找到nc或telnet命令，无法检测端口连通性"
            return 0
        fi
    fi
}

# 下载免费代理列表
# 检测端口连通性 - 单个代理验证函数
check_proxy_connectivity() {
    local proxy_url="$1"
    local timeout="${2:-5}"

    # 从URL中提取IP和端口
    local ip=$(echo "$proxy_url" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
    local port=$(echo "$proxy_url" | sed 's/.*:\/\/[^:]*:\(.*\)/\1/')
    check_port_connectivity $ip $port
}

# 使用 curl 测试代理是否实际可用
test_proxy_with_curl() {
    local proxy_url="$1"
    local timeout="${2:-5}"

    # 从URL中提取IP和端口
    local ip=$(echo "$proxy_url" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
    local port=$(echo "$proxy_url" | sed 's/.*:\/\/[^:]*:\(.*\)/\1/')

    # 使用 curl 测试代理 - 使用 httpbin.org 作为测试目标（更宽松）
    if [[ "$proxy_url" =~ ^http:// ]]; then
        curl -x "http://$ip:$port" -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" --max-time "$timeout" "http://httpbin.org/ip" 2>/dev/null | grep -q "200\|301\|302"
    elif [[ "$proxy_url" =~ ^socks5:// ]]; then
        curl --socks5 "$ip:$port" -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" --max-time "$timeout" "http://httpbin.org/ip" 2>/dev/null | grep -q "200\|301\|302"
    else
        return 1
    fi
}

# 并行验证代理列表
validate_proxy_list() {
    local input_file="$1"
    local output_file="$2"
    local timeout="${3:-5}"
    local max_jobs="${4:-10}"  # 并行任务数
    
    if [[ ! -f "$input_file" ]]; then
        echo "错误: 输入文件 $input_file 不存在"
        return 1
    fi
    
    echo "正在并行验证代理列表: $input_file"
    echo "并行任务数: $max_jobs, 超时时间: ${timeout}秒"
    
    # 创建临时文件存储有效的代理
    local temp_file=$(mktemp)
    
    # 统计变量
    local total_count=$(wc -l < "$input_file")
    local valid_count=0
    local invalid_count=0
    local current=0
    local batch=()
    
    # 使用批处理方式兼容 macOS bash
    while IFS= read -r proxy_url; do
        batch+=("$proxy_url")
        
        # 达到批次大小时执行
        if [[ ${#batch[@]} -ge $max_jobs ]]; then
            for proxy in "${batch[@]}"; do
                current=$((current + 1))
                (
                    if check_proxy_connectivity "$proxy" "$timeout"; then
                        echo "$proxy" >> "$temp_file" 2>/dev/null
                    fi
                ) &
            done
            wait  # 等待当前批次完成
            batch=()
            printf "\r验证进度: %d/%d" "$current" "$total_count"
        fi
    done < "$input_file"
    
    # 处理剩余的代理
    if [[ ${#batch[@]} -gt 0 ]]; then
        for proxy in "${batch[@]}"; do
            current=$((current + 1))
            (
                if check_proxy_connectivity "$proxy" "$timeout"; then
                    echo "$proxy" >> "$temp_file" 2>/dev/null
                fi
            ) &
        done
        wait
        printf "\r验证进度: %d/%d" "$current" "$total_count"
    fi
    
    echo ""  # 换行
    echo "验证完成！"
    
    # 统计有效代理
    if [[ -f "$temp_file" ]]; then
        valid_count=$(wc -l < "$temp_file")
        invalid_count=$((total_count - valid_count))
        echo "总代理数: $total_count, 有效代理数: $valid_count, 无效代理数: $invalid_count"
        
        # 将有效代理写入输出文件
        mv "$temp_file" "$output_file"
        echo "有效代理已保存到: $output_file"
    else
        echo "没有找到有效代理"
        touch "$output_file"
    fi
}

download_proxy_list() {
    local type="$1"
    local output_file="$2"
    
    case "$type" in
        "all")
            url="https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/all/data.txt"
            ;;
        "http")
            url="https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt"
            ;;
        "socks4")
            url="https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks4/data.txt"
            ;;
        "socks5")
            url="https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt"
            ;;
        "us")
            url="https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/countries/US/data.txt"
            ;;
        *)
            echo "错误: 无效的代理类型 '$type'. 使用 all|http|socks4|socks5|us"
            exit 1
            ;;
    esac
    
    echo "正在下载 $type 代理列表到 $output_file..."
    # 使用 --noproxy "*" 禁用代理，避免代理设置影响下载
    if curl -sL --noproxy "*" "$url" -o "$output_file"; then
        echo "下载成功！文件已保存到 $output_file"
        # 显示前5行以便预览
        echo "前5行预览:"
        head -n 5 "$output_file"
        
        # 自动验证代理列表并删除无效的代理
        local validated_file="${output_file%.txt}_validated.txt"
        validate_proxy_list "$output_file" "$validated_file" 5 10
        echo "代理验证完成，有效代理保存到: $validated_file"
    else
        echo "错误: 下载失败！URL: $url"
        exit 1
    fi
}

# 验证IP地址格式
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local octets
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 验证端口范围
validate_port() {
    local port="$1"
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 显示当前代理信息
show_proxy_info() {
    for var in $PROXY_VARS; do
        local val="${!var}"
        if [[ "$var" == "NO_PROXY" || "$var" == "no_proxy" ]]; then
            echo "$var=\"$val\""
        else
            echo "$var=$val"
        fi
    done
}

# 取消当前会话中的所有代理变量
unset_proxy_session() {
    for var in $PROXY_VARS; do
        unset "$var"
    done
}

unset_proxy() {
    # 取消当前会话代理
    unset_proxy_session
    # 获取shell配置文件路径并从配置文件中移除代理
    load_usr_env_file
    echo "移除代理设置: $USR_ENV_FILE"
    unset_proxy_from_config "$USR_ENV_FILE"
    echo "提示: 重新打开终端或运行 'source $USR_ENV_FILE' 以在新会话中应用更改。"
}

load_usr_env_file
# 如果提供了IP，则使用提供的IP，否则使用默认IP
if [[ -n "$PROVIDED_IP" ]]; then
    IP="$PROVIDED_IP"
else
    IP="$DEFAULT_IP"
fi

# 如果提供了端口，则使用提供的端口，否则使用默认端口
if [[ -n "$PROVIDED_PORT" ]]; then
    PORT="$PROVIDED_PORT"
else
    PORT="$DEFAULT_PORT"
fi

# 验证参数
if [[ "$ACTION" == "unset" ]]; then
    # 取消代理功能
    if [[ -n "$2" || -n "$3" ]]; then
        echo "警告: 取消代理时不需要指定IP和端口"
    fi
elif [[ "$ACTION" == "view" ]]; then
    # 查看代理信息功能
    if [[ -n "$2" || -n "$3" ]]; then
        echo "警告: 查看代理信息时不需要指定IP和端口"
    fi
    show_proxy_info
    exit 0
elif [[ "$ACTION" == "download" ]]; then
    # 下载代理列表功能
    case "$DOWNLOAD_TYPE" in
        "all")
            download_proxy_list "all" "$PROXY_DIR/all.txt"
            ;;
        "http")
            download_proxy_list "http" "$PROXY_DIR/http.txt"
            ;;
        "socks4")
            download_proxy_list "socks4" "$PROXY_DIR/socks4.txt"
            ;;
        "socks5")
            download_proxy_list "socks5" "$PROXY_DIR/socks5.txt"
            ;;
        "us")
            download_proxy_list "us" "$PROXY_DIR/us.txt"
            ;;
        *)
            echo "错误: 无效的下载类型 '$DOWNLOAD_TYPE'. 使用 all|http|socks4|socks5|us"
            exit 1
            ;;
    esac
    exit 0
fi

# 自动检测并设置代理
# 参数: $1 - 检测代理数量（默认1）, $2 - 代理类型（http|socks5）
auto_detect_and_set_proxy() {
    local check_count="${1:-1}"
    local proxy_type="${2:-http}"
    # 确保是有效数字
    [[ ! "$check_count" =~ ^[0-9]+$ ]] && check_count=1

    # 1. 首先检查默认本地代理 127.0.0.1:7890
    if check_port_connectivity "127.0.0.1" "7890"; then
        echo "✓ 检测到本地代理 127.0.0.1:7890 可用"
        IP="127.0.0.1"
        PORT="7890"
        return 0
    fi

    echo "✗ 本地代理 127.0.0.1:7890 不可用"

    # 2. 检查是否存在已下载的代理文件（优先检查已验证的）
    local proxy_file=""
    local validated_file="$PROXY_DIR/${proxy_type}_validated.txt"
    local raw_file="$PROXY_DIR/${proxy_type}.txt"

    if [[ -f "$validated_file" ]]; then
        proxy_file="$validated_file"
    elif [[ -f "$raw_file" ]]; then
        proxy_file="$raw_file"
        echo "✓ 找到原始代理文件: $proxy_file"
        # 对原始文件进行逐个验证，找到第一个可用的就停止
        echo "正在验证代理（找到第一个可用即停止）..."
        while IFS= read -r proxy_url; do
            [[ -z "$proxy_url" ]] && continue
            if check_proxy_connectivity "$proxy_url" 3; then
                # 端口连通，继续用 curl 测试
                local ip=$(echo "$proxy_url" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
                local port=$(echo "$proxy_url" | sed 's/.*:\/\/[^:]*:\(.*\)/\1/')
                echo "  端口连通: $ip:$port，正在用 curl 测试..."
                if test_proxy_with_curl "$proxy_url" 5; then
                    IP="$ip"
                    PORT="$port"
                    echo "✓ 找到可用代理: $IP:$PORT"
                    return 0
                else
                    echo "  ✗ curl 测试失败: $ip:$port"
                fi
            fi
        done < "$proxy_file"
        echo "✗ 未找到可用代理"
        return 1
    fi

    if [[ -f "$proxy_file" ]]; then
        echo "✓ 找到代理文件: $proxy_file"
        # 从已验证文件中选择第一个可用代理，并用 curl 测试
        echo "正在从 $proxy_file 中测试代理..."
        while IFS= read -r proxy_url; do
            [[ -z "$proxy_url" ]] && continue
            # 从URL中提取IP和端口
            local ip=$(echo "$proxy_url" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
            local port=$(echo "$proxy_url" | sed 's/.*:\/\/[^:]*:\(.*\)/\1/')
            # 用 curl 测试
            echo "  测试代理: $ip:$port"
            if test_proxy_with_curl "$proxy_url" 5; then
                IP="$ip"
                PORT="$port"
                echo "✓ 选择代理: $IP:$PORT"
                return 0
            else
                echo "  ✗ curl 测试失败: $ip:$port"
            fi
        done < "$proxy_file"
        echo "✗ 未找到可用代理"
        return 1
    else
        echo "✗ 未找到代理文件，正在下载..."
        # 下载指定类型的代理
        download_proxy_list "$proxy_type" "$raw_file"
        # 下载后进行验证
        validate_proxy_list "$raw_file" "$validated_file" 3 10
        proxy_file="$validated_file"
    fi

    # 3. 从代理文件中选择可用的代理
    if [[ -f "$proxy_file" ]]; then
        echo "正在从 $proxy_file 中检测可用代理..."
        local valid_proxies=()
        local checked_count=0

        while IFS= read -r proxy_url && [[ ${#valid_proxies[@]} -lt $check_count ]]; do
            [[ -z "$proxy_url" ]] && continue
            checked_count=$((checked_count + 1))

            if check_proxy_connectivity "$proxy_url" 3 && test_proxy_with_curl "$proxy_url" 5; then
                # 从URL中提取IP和端口
                local proxy_ip=$(echo "$proxy_url" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
                local proxy_port=$(echo "$proxy_url" | sed 's/.*:\/\/[^:]*:\(.*\)/\1/')
                valid_proxies+=("$proxy_ip:$proxy_port")
                echo "✓ 找到可用代理 [$${#valid_proxies[@]}/$check_count]: $proxy_ip:$proxy_port"
            fi
        done < "$proxy_file"

        echo "已检测 $checked_count 个代理，找到 ${#valid_proxies[@]} 个可用代理"

        if [[ ${#valid_proxies[@]} -gt 0 ]]; then
            # 使用第一个可用代理
            IP=$(echo "${valid_proxies[0]}" | cut -d':' -f1)
            PORT=$(echo "${valid_proxies[0]}" | cut -d':' -f2)
            echo "✓ 选择代理: $IP:$PORT"
            return 0
        else
            echo "✗ 未找到可用代理"
            return 1
        fi
    fi

    return 1
}

# 执行操作
case "$ACTION" in
    "set")
        # 如果未提供IP和端口，自动检测
        if [[ -z "$PROVIDED_IP" && -z "$PROVIDED_PORT" ]]; then
            if ! auto_detect_and_set_proxy "${PROXY_CHECK_COUNT:-1}" "$PROXY_TYPE"; then
                echo "错误: 无法自动检测可用代理"
                exit 1
            fi
        fi

        # 验证参数
        if ! validate_ip "$IP"; then
            echo "错误: 无效的IP地址格式: $IP"
            exit 1
        fi

        if ! validate_port "$PORT"; then
            echo "错误: 无效的端口号: $PORT (端口号必须在1-65535之间)"
            exit 1
        fi

        # 检测端口连通性（自动检测时已经检查过，跳过）
        if [[ -n "$PROVIDED_IP" || -n "$PROVIDED_PORT" ]]; then
            if ! check_port_connectivity "$IP" "$PORT"; then
                echo "错误: 无法连接到 $IP:$PORT"
                exit 1
            fi
        fi

        # 设置当前会话代理
        if [[ "$PROXY_TYPE" == "socks5" ]]; then
            export ALL_PROXY="socks5://$IP:$PORT"
            export all_proxy="socks5://$IP:$PORT"
            export HTTP_PROXY="http://$IP:$PORT"
            export HTTPS_PROXY="http://$IP:$PORT"
            export http_proxy="$HTTP_PROXY"
            export https_proxy="$HTTPS_PROXY"
        else
            export HTTP_PROXY="http://$IP:$PORT"
            export HTTPS_PROXY="http://$IP:$PORT"
            export http_proxy="$HTTP_PROXY"
            export https_proxy="$HTTPS_PROXY"
        fi
        export NO_PROXY=""
        export no_proxy="$NO_PROXY"

        # 获取shell配置文件路径并更新配置文件
        echo "添加代理设置: $USR_ENV_FILE"
        # 在配置文件中设置代理
        set_proxy_in_config "$USR_ENV_FILE" "$IP" "$PORT" "$PROXY_TYPE"
        show_proxy_info
        echo ""
        echo "提示: 代理已设置到当前会话和配置变量文件中。重新打开终端或运行 'source $USR_ENV_FILE' 以在新会话中生效。"
        ;;
    "unset")
      unset_proxy
        ;;
    *)
        unset_proxy
        ;;
esac
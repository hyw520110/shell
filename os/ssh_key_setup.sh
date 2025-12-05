#!/bin/bash

# 公共变量定义
TARGET_IP=""
TARGET_USER="root"
TARGET_PORT="22"
INTERACTIVE=true
KEY_TYPE="ed25519"  # 使用更安全的密钥类型
DEBUG_MODE=false
NO_CONNECT=false    # 设置密钥后不自动连接

# 检查是否有nc命令（用于连接测试）
if command -v nc >/dev/null 2>&1; then
    HAS_NC=true
else
    HAS_NC=false
fi

# 配置文件路径（使用系统已有的SSH配置文件）
SSH_CONFIG_FILE="$HOME/.ssh/config"
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

# 帮助函数
usage() {
    echo "用法: $0 [选项] <主机IP或主机名> [用户名] [端口]"
    echo "  -h, --host <目标主机>     目标主机的IP或主机名 (必填)"
    echo "  -u, --user <用户名>       目标主机的用户名 (可选，默认为$TARGET_USER)"
    echo "  -p, --port <端口>         目标主机的SSH端口 (可选，默认为$TARGET_PORT)"
    echo "  -t, --key-type <类型>     SSH密钥类型 (ed25519, rsa, ecdsa) (可选，默认为$KEY_TYPE)"
    echo "  --no-connect              设置密钥后不自动连接SSH"
    echo "  -d, --debug               启用调试模式"
    echo "  -i, --interactive         使用交互式输入模式"
    echo "  --help                    显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -h example.com -u myuser -p 2222"
    echo "  $0 example.com myuser 2222"
    echo "  $0 -h example.com --no-connect"
    echo "  $0 -i"
    exit 1
}

# 日志函数
log_info() {
    echo "[信息] $1"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[调试] $1"
    fi
}

log_error() {
    echo "[错误] $1" >&2
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "端口号必须是1-65535之间的数字: $port"
        return 1
    fi
    return 0
}

# 验证IP地址或主机名格式
validate_host() {
    local host="$1"
    
    # 检查是否为有效的IP地址
    if [[ $host =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # 验证每个IP段
        IFS='.' read -ra ADDR <<< "$host"
        for i in "${ADDR[@]}"; do
            if [ "$i" -gt 255 ] 2>/dev/null; then
                return 1
            fi
        done
        return 0
    fi
    
    # 检查是否为有效的主机名格式
    if [[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9](\.[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9])*$ ]]; then
        return 0
    fi
    
    # 如果不是IP地址也不是主机名格式，则验证是否为单个域名
    if [[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]$ ]]; then
        return 0
    fi
    
    return 1
}

# 测试SSH端口连通性
test_ssh_connectivity() {
    local host="$1"
    local port="$2"
    
    log_info "测试SSH连接到 $host:$port..."
    
    if [ "$HAS_NC" = true ]; then
        if nc -z -w5 "$host" "$port" 2>/dev/null; then
            log_info "SSH端口 $port 在主机 $host 上是开放的"
            return 0
        else
            log_error "错误: SSH端口 $port 在主机 $host 上不可达"
            return 1
        fi
    else
        # 如果没有nc命令，使用SSH的连接测试功能
        log_debug "没有找到nc命令，使用SSH测试连接..."
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -p "$port" "root@$host" exit 2>/dev/null
        local result=$?
        if [ $result -eq 0 ] || [ $result -eq 255 ]; then
            # 0 = 成功连接, 255 = 连接但认证失败（端口开放）
            log_info "SSH端口 $port 在主机 $host 上可达"
            return 0
        else
            log_error "错误: SSH端口 $port 在主机 $host 上不可达"
            return 1
        fi
    fi
}

# 检查目标主机是否在known_hosts中
check_known_hosts() {
    local host="$1"
    local port="$2"
    
    if [ -f "$KNOWN_HOSTS_FILE" ]; then
        if ssh-keygen -F "[$host]:$port" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1; then
            log_debug "主机 $host:$port 已在known_hosts中"
            return 0
        else
            log_debug "主机 $host:$port 不在known_hosts中"
            return 1
        fi
    fi
    return 1
}

# 添加主机到SSH配置
add_to_ssh_config() {
    local host="$1"
    local user="$2"
    local port="$3"
    
    # 检查是否已经存在此主机的配置
    if [ -f "$SSH_CONFIG_FILE" ] && grep -q "Host $host$" "$SSH_CONFIG_FILE" 2>/dev/null; then
        log_debug "主机 $host 已在SSH配置中"
        return 0
    fi
    
    # 创建SSH配置文件（如果不存在）
    mkdir -p "$(dirname "$SSH_CONFIG_FILE")"
    
    # 添加主机配置到SSH配置文件
    {
        echo ""
        echo "Host $host"
        echo "    User $user"
        echo "    Port $port"
        echo "    StrictHostKeyChecking no"
    } >> "$SSH_CONFIG_FILE"
    
    log_info "已将主机 $host 添加到SSH配置文件"
}

# 生成SSH密钥对
generate_ssh_key() {
    local key_type="$1"
    local key_path="$HOME/.ssh/id_$key_type"
    local pub_path="$HOME/.ssh/id_${key_type}.pub"
    
    if [ ! -f "$pub_path" ]; then
        log_info "生成 $key_type 类型的SSH密钥对..."
        ssh-keygen -t "$key_type" -N "" -f "$key_path" -C "ssh_setup@$(date +%Y%m%d)"
        if [ $? -ne 0 ]; then
            log_error "密钥生成失败"
            exit 1
        fi
    else
        log_info "使用现有的 $key_type 密钥: $pub_path"
    fi
    
    # 设置正确的权限
    chmod 600 "$key_path"
    chmod 644 "$pub_path"
    
    echo "$pub_path"
}

# 交互式获取目标主机、用户名和端口
get_target_ip() {
    while true; do
        read -p "请输入目标主机的IP或主机名: " target_ip
        if [ -z "$target_ip" ]; then
            log_error "目标主机的IP或主机名不能为空。"
        elif ! validate_host "$target_ip"; then
            log_error "无效的主机格式: $target_ip"
        elif ! ping -c 1 -W 1 "$target_ip" &> /dev/null; then
            log_error "$target_ip 不可达，请重新输入。"
        else
            break
        fi
    done
}

get_target_user() {
    read -t 8 -p "请输入目标主机的用户名 (默认为$TARGET_USER): " target_user
    target_user="${target_user:-$TARGET_USER}"
}

get_target_port() {
    read -t 8 -p "请输入目标主机的SSH端口 (默认为$TARGET_PORT): " target_port
    target_port="${target_port:-$TARGET_PORT}"
    
    if ! validate_port "$target_port"; then
        log_error "无效的端口号: $target_port，使用默认值 $TARGET_PORT"
        target_port="$TARGET_PORT"
    fi
}

get_key_type() {
    read -t 8 -p "请选择SSH密钥类型 (ed25519/rsa/ecdsa, 默认为$KEY_TYPE): " key_type_input
    key_type_input="${key_type_input:-$KEY_TYPE}"
    
    # 验证密钥类型是否支持
    case "$key_type_input" in
        "ed25519"|"rsa"|"ecdsa") 
            KEY_TYPE="$key_type_input"
            ;;
        *) 
            log_error "不支持的密钥类型: $key_type_input，使用默认值 $KEY_TYPE"
            KEY_TYPE="$KEY_TYPE"
            ;;
    esac
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            if [ -n "$2" ]; then
                if ! validate_host "$2"; then
                    log_error "无效的主机格式: $2"
                    exit 1
                fi
                TARGET_IP="$2"
                INTERACTIVE=false
                shift 2
            else
                log_error "错误: -h 选项需要指定主机IP或主机名"
                usage
            fi
            ;;
        -u|--user)
            TARGET_USER="$2"
            shift 2
            ;;
        -p|--port)
            if validate_port "$2"; then
                TARGET_PORT="$2"
                shift 2
            else
                log_error "无效的端口号: $2"
                exit 1
            fi
            ;;
        -t|--key-type)
            case "$2" in
                "ed25519"|"rsa"|"ecdsa")
                    KEY_TYPE="$2"
                    shift 2
                    ;;
                *)
                    log_error "不支持的密钥类型: $2 (支持: ed25519, rsa, ecdsa)"
                    exit 1
                    ;;
            esac
            ;;
        --no-connect)
            NO_CONNECT=true
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -i|--interactive)
            INTERACTIVE=true
            shift
            ;;
        --help)
            usage
            ;;
        -*)
            log_error "未知选项: $1"
            usage
            ;;
        *)
            # 位置参数
            if [[ -z "$TARGET_IP" ]]; then
                if ! validate_host "$1"; then
                    log_error "无效的主机格式: $1"
                    exit 1
                fi
                TARGET_IP="$1"
                INTERACTIVE=false
            elif [[ -z "$TARGET_USER" ]]; then
                TARGET_USER="$1"
            elif [[ -z "$TARGET_PORT" ]]; then
                if validate_port "$1"; then
                    TARGET_PORT="$1"
                else
                    log_error "无效的端口号: $1"
                    exit 1
                fi
            else
                log_error "过多的参数: $1"
                usage
            fi
            shift
            ;;
    esac
done

# 如果没有提供目标IP且不在交互模式，则显示用法
if [ -z "$TARGET_IP" ] && [ "$INTERACTIVE" = false ]; then
    log_error "必须指定目标主机IP或主机名"
    usage
fi

# 根据参数决定是否使用交互式输入
if [ "$INTERACTIVE" = true ]; then
    log_info "交互式模式启动..."
    get_target_ip
    get_target_user
    get_target_port
    get_key_type
else
    # 使用命令行参数
    target_ip="$TARGET_IP"
    target_user="$TARGET_USER"
    target_port="$TARGET_PORT"
fi

# 执行基本验证
if ! validate_port "$target_port"; then
    log_error "无效的端口号: $target_port"
    exit 1
fi

if ! validate_host "$target_ip"; then
    log_error "无效的主机格式: $target_ip"
    exit 1
fi

# 测试SSH连通性
if ! test_ssh_connectivity "$target_ip" "$target_port"; then
    log_error "无法连接到 $target_ip:$target_port"
    exit 1
fi

# 检查目标主机是否在known_hosts中
if ! check_known_hosts "$target_ip" "$target_port"; then
    log_info "主机 $target_ip:$target_port 不在known_hosts中，连接时可能需要确认主机密钥"
fi

# 生成SSH密钥对
log_info "使用密钥类型: $KEY_TYPE"
pub_key_path=$(generate_ssh_key "$KEY_TYPE")

# 尝试进行SSH公钥复制，使用指定端口
log_info "正在设置 $target_user@$target_ip:$target_port 的免密登录..."
if ssh-copy-id -i "$pub_key_path" -p "$target_port" "$target_user@$target_ip"; then
    log_info "成功设置 $target_ip:$target_port 的免密登录。"
    
    # 添加主机到SSH配置文件
    add_to_ssh_config "$target_ip" "$target_user" "$target_port"
    
    # 如果不需要自动连接，则退出
    if [ "$NO_CONNECT" = true ]; then
        log_info "密钥设置完成，不自动连接。"
        exit 0
    fi
    
    # SSH连接到目标主机
    log_info "连接到 $target_user@$target_ip:$target_port..."
    ssh -p "$target_port" "$target_user@$target_ip"
else
    log_error "无法设置 $target_ip:$target_port 的免密登录。"
    exit 1
fi
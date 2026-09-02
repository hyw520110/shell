#!/bin/bash
# 设置更严格的错误处理
set -euo pipefail
IFS=$'\n\t'

# 脚本调试模式
DEBUG=${DEBUG:-false}
if [ "$DEBUG" = true ]; then
    set -x
fi

# 常量定义
readonly SCRIPT_NAME=$(basename "$0")
readonly CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_API_DOMAIN="api.pg-bo.me"
readonly DEFAULT_API_PORT=443
readonly TEMP_DIR="/tmp/nginx_cert_check_$$"

# API域名和端口
API_DOMAIN=${DEFAULT_API_DOMAIN}
API_PORT=${DEFAULT_API_PORT}

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*" >&2
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    exit 1
}

debug() {
    if [[ ${DEBUG:-false} == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
    fi
}

# 清理函数
cleanup() {
    local exit_code=$?
    # 清理临时文件
    rm -f "$TEMP_DIR"/api_certificate.txt "$TEMP_DIR"/api_supported_versions.txt "$TEMP_DIR"/api_supported_ciphers.txt 2>/dev/null || true
    rmdir "$TEMP_DIR" 2>/dev/null || true
    exit $exit_code
}

# 设置退出时清理
trap cleanup EXIT INT TERM

# 创建临时目录
mkdir -p "$TEMP_DIR"

# 验证域名格式
validate_domain() {
    local domain="$1"
    if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9](\.[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9])*\.?$ ]]; then
        return 0
    else
        return 1
    fi
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 验证路径安全性，防止路径遍历
validate_path() {
    local path="$1"
    case "$path" in
        *"../"*|*"../"*|"/..;"|"/../")
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            if validate_domain "$2"; then
                API_DOMAIN="$2"
                log "设置API域名: $API_DOMAIN"
            else
                error "无效的域名: $2"
            fi
            shift 2
            ;;
        --port)
            if validate_port "$2"; then
                API_PORT="$2"
                log "设置API端口: $API_PORT"
            else
                error "无效的端口号: $2"
            fi
            shift 2
            ;;
        --nginx-conf-dir)
            if validate_path "$2" && [ -d "$2" ]; then
                NGINX_CONF_DIR="$2"
                log "设置Nginx配置目录: $NGINX_CONF_DIR"
            else
                error "无效或不存在的配置目录: $2"
            fi
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --domain DOMAIN    API域名，默认为$DEFAULT_API_DOMAIN"
            echo "  --port PORT        API端口，默认为$DEFAULT_API_PORT"
            echo "  --nginx-conf-dir DIR  Nginx配置目录，默认自动检测"
            echo "  --help, -h         显示此帮助信息"
            exit 0
            ;;
        *)
            error "未知参数: $1"
            ;;
    esac
done

# 自动检测Nginx配置目录
detect_nginx_conf_dir() {
    local possible_paths=(
        "/etc/nginx"
        "/usr/local/nginx/conf"
        "/usr/local/etc/nginx"
        "/opt/nginx/conf"
        "$HOME/nginx/conf"
    )

    for path in "${possible_paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/nginx.conf" ]; then
            echo "$path"
            return 0
        fi
    done

    # 如果都没找到，返回默认路径
    echo "/etc/nginx"
}

# Nginx配置文件路径
if [ -z "$NGINX_CONF_DIR" ]; then
    NGINX_CONF_DIR=$(detect_nginx_conf_dir)
    log "自动检测Nginx配置目录: $NGINX_CONF_DIR"
else
    log "使用指定的Nginx配置目录: $NGINX_CONF_DIR"
fi

log "使用Nginx配置目录: $NGINX_CONF_DIR"

# 查找包含指定proxy_pass的配置文件
log "查找包含proxy_pass https://$API_DOMAIN的配置文件..."
NGINX_CONF_FILE=$(find "$NGINX_CONF_DIR" -type f -name "*.conf" -exec grep -l "proxy_pass https://$API_DOMAIN" {} \; 2>/dev/null | head -1)

if [ -z "$NGINX_CONF_FILE" ]; then
    error "未找到与API域名: $API_DOMAIN 对应的Nginx配置文件"
fi

log "找到配置文件: $NGINX_CONF_FILE"


# 递归查找include文件中的配置
find_included_configs() {
    local conf_file="$1"
    local conf_dir=$(dirname "$conf_file")

    # 查找include指令
    grep -E "^\s*include\s+" "$conf_file" 2>/dev/null | while read -r line; do
        # 提取文件路径
        local included_path=$(echo "$line" | awk '{print $2}' | sed 's/;//')

        # 验证路径安全性
        if ! validate_path "$included_path"; then
            log "跳过不安全的路径: $included_path"
            continue
        fi

        # 处理相对路径和通配符
        if [[ "$included_path" == /* ]]; then
            # 绝对路径
            echo "$included_path"
        elif [[ "$included_path" == .* ]]; then
            # 相对于配置文件目录的路径
            echo "$conf_dir/$included_path"
        else
            # 相对于nginx配置目录的路径
            echo "$NGINX_CONF_DIR/$included_path"
        fi
    done
}

# 递归提取证书路径
extract_certificate_paths() {
    local conf_file="$1"
    local visited_files="$2"

    # 验证配置文件是否存在和安全
    if [ ! -f "$conf_file" ] || ! validate_path "$conf_file"; then
        return
    fi

    # 避免循环引用
    if echo "$visited_files" | grep -q "$conf_file"; then
        log "检测到循环引用，跳过: $conf_file"
        return
    fi

    # 更新已访问文件列表
    visited_files="$visited_files:$conf_file"

    # 直接从当前配置文件提取
    local cert_path=$(grep 'ssl_certificate ' "$conf_file" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
    local key_path=$(grep 'ssl_certificate_key ' "$conf_file" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)

    if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
        # 验证证书路径安全性
        if validate_path "$cert_path" && validate_path "$key_path"; then
            echo "cert:$cert_path"
            echo "key:$key_path"
            return
        else
            log "证书路径不安全，跳过: $cert_path, $key_path"
        fi
    fi

    # 从include文件中查找
    find_included_configs "$conf_file" | while read -r included_file; do
        # 处理通配符
        if [[ "$included_file" == *"*"* ]]; then
            # 展开通配符
            for f in $included_file; do
                if [ -f "$f" ] && validate_path "$f"; then
                    extract_certificate_paths "$f" "$visited_files"
                fi
            done
        elif [ -f "$included_file" ] && validate_path "$included_file"; then
            extract_certificate_paths "$included_file" "$visited_files"
        fi
    done
}

# 提取Nginx域名和证书路径
extract_nginx_info() {
    NGINX_DOMAIN=$(grep -A 5 "443" "$NGINX_CONF_FILE" | grep "server_name " | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}' | head -1)

    # 验证域名格式
    if ! validate_domain "$NGINX_DOMAIN"; then
        log "警告: 无法从配置文件中提取有效的域名"
        NGINX_DOMAIN=""
    fi

    # 递归查找证书路径
    local cert_info=$(extract_certificate_paths "$NGINX_CONF_FILE" "")
    CERTIFICATE_PATH=$(echo "$cert_info" | grep "^cert:" | cut -d: -f2 | head -1)
    PRIVATE_KEY_PATH=$(echo "$cert_info" | grep "^key:" | cut -d: -f2 | head -1)

    log "Nginx Domain: $NGINX_DOMAIN"
    log "Certificate Path: $CERTIFICATE_PATH"
    log "Private Key Path: $PRIVATE_KEY_PATH"
}

# 获取对方API证书的TLS版本和加密算法
get_api_certificate_info() {
    log "获取API证书信息: $API_DOMAIN:$API_PORT"

    # 获取证书 - 使用临时文件并验证输出
    if ! timeout 10 openssl s_client -connect "$API_DOMAIN:$API_PORT" </dev/null 2>/dev/null | openssl x509 -noout -text > "$TEMP_DIR/api_certificate.txt"; then
        error "无法获取API证书信息: $API_DOMAIN:$API_PORT"
    fi

    # 获取TLS版本
    local supported_versions=$(timeout 10 openssl s_client -connect "$API_DOMAIN:$API_PORT" -tls1_2 </dev/null 2>/dev/null | grep -i "New, (TLSv1|TLSv1.1|TLSv1.2|TLSv1.3)" | awk '{print $3}' | sed 's/,//g' | tr '\n' ' ')
    if [ -z "$supported_versions" ]; then
        supported_versions=$(timeout 10 openssl s_client -connect "$API_DOMAIN:$API_PORT" -tls1_3 </dev/null 2>/dev/null | grep -i "New, (TLSv1|TLSv1.1|TLSv1.2|TLSv1.3)" | awk '{print $3}' | sed 's/,//g' | tr '\n' ' ')
    fi

    # 获取加密算法
    local supported_ciphers=$(timeout 10 openssl s_client -connect "$API_DOMAIN:$API_PORT" -cipher 'ALL' -tls1_2 </dev/null 2>/dev/null | grep -i "Cipher " | awk -F': ' '{print $2}' | tr '\n' ' ')
    if [ -z "$supported_ciphers" ]; then
        supported_ciphers=$(timeout 10 openssl s_client -connect "$API_DOMAIN:$API_PORT" -cipher 'ALL' -tls1_3 </dev/null 2>/dev/null | grep -i "Cipher is" | awk '{print $3}' | tr '\n' ' ')
    fi

    log "TLS versions: $supported_versions"
    log "Ciphers: $supported_ciphers"

    echo "$supported_versions" > "$TEMP_DIR/api_supported_versions.txt"
    echo "$supported_ciphers" > "$TEMP_DIR/api_supported_ciphers.txt"
}

# 获取当前Nginx证书的TLS版本和加密算法
get_current_tls_versions() {
    openssl s_client -connect $NGINX_DOMAIN:$API_PORT -tls1_2 </dev/null 2>/dev/null | grep -i "New, (TLSv1|TLSv1.1|TLSv1.2|TLSv1.3)" | awk '{print $3}' | sed 's/,//g' | tr '\n' ' '
}

get_current_ciphers() {
    openssl s_client -connect $NGINX_DOMAIN:$API_PORT -cipher 'ALL' -tls1_2 </dev/null 2>/dev/null | grep -i "Cipher is" | awk '{print $3}' | tr '\n' ' '
}

# 比较TLS版本和加密算法
compare_tls_versions() {
    local current_versions=$(get_current_tls_versions)
    local supported_versions=$(cat api_supported_versions.txt)
    local match=true
    for version in $current_versions; do
        if [[ ! " $supported_versions " =~ " $version " ]]; then
            match=false
            break
        fi
    done
    echo $match
}

compare_ciphers() {
    local current_ciphers=$(get_current_ciphers)
    local supported_ciphers=$(cat api_supported_ciphers.txt)
    local match=true
    for cipher in $current_ciphers; do
        if [[ ! " $supported_ciphers " =~ " $cipher " ]]; then
            match=false
            break
        fi
    done
    echo $match
}

# 判断是否需要重新生成证书
need_renew_certificate() {
    if compare_tls_versions && compare_ciphers; then
        echo "证书无需更新"
        return 1
    else
        echo "需要更新证书"
        return 0
    fi
}

# 重新生成证书
renew_certificate() {
    local supported_versions=$(cat "$TEMP_DIR/api_supported_versions.txt")
    local supported_ciphers=$(cat "$TEMP_DIR/api_supported_ciphers.txt")

    log "正在更新证书配置..."

    # 生成新的证书 - 需要用户邮箱
    read -p "请输入证书注册邮箱: " -r EMAIL
    if [ -z "$EMAIL" ]; then
        error "邮箱不能为空"
    fi

    # 验证邮箱格式
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "邮箱格式无效: $EMAIL"
    fi

    log "使用Certbot生成新证书..."
    if ! sudo certbot certonly --webroot -w /var/www/html -d "$NGINX_DOMAIN" --agree-tos --email "$EMAIL" --non-interactive; then
        error "证书生成失败"
    fi

    # 更新Nginx配置
    log "更新Nginx配置文件..."
    if [ -f "$NGINX_CONF_FILE" ]; then
        # 创建备份
        sudo cp "$NGINX_CONF_FILE" "$NGINX_CONF_FILE.backup"
        log "已创建配置备份: $NGINX_CONF_FILE.backup"

        # 更新协议和加密算法
        sudo sed -i.bak "s/ssl_protocols .*/ssl_protocols ${supported_versions// / };/" "$NGINX_CONF_FILE"
        sudo sed -i.bak "s/ssl_ciphers .*/ssl_ciphers '${supported_ciphers// /:}';/" "$NGINX_CONF_FILE"

        # 验证配置
        if ! nginx -t -c "$NGINX_CONF_FILE"; then
            log "配置验证失败，恢复备份..."
            sudo cp "$NGINX_CONF_FILE.backup" "$NGINX_CONF_FILE"
            error "Nginx配置更新失败，已恢复备份"
        fi
    else
        error "Nginx配置文件不存在: $NGINX_CONF_FILE"
    fi

    # 重启Nginx
    log "重启Nginx服务..."
    if sudo systemctl restart nginx; then
        log "Nginx服务重启成功"
    else
        error "Nginx服务重启失败"
    fi
}

# 检查所需工具
check_required_tools() {
    local missing_tools=()

    if ! command -v openssl > /dev/null 2>&1; then
        missing_tools+=("openssl")
    fi

    if ! command -v certbot > /dev/null 2>&1; then
        missing_tools+=("certbot")
    fi

    if ! command -v systemctl > /dev/null 2>&1; then
        missing_tools+=("systemctl")
    fi

    if ! command -v timeout > /dev/null 2>&1; then
        missing_tools+=("timeout")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "错误: 缺少以下工具: ${missing_tools[*]}. 请安装这些工具后再运行此脚本"
    fi

    log "所有必需工具都已找到"
}

# 主逻辑
check_required_tools

if [ -z "$NGINX_CONF_FILE" ]; then
    error "未找到与API域名: $API_DOMAIN 对应的Nginx配置文件"
fi

extract_nginx_info "$NGINX_CONF_FILE"

# 检查证书文件是否存在
if [ ! -f "$CERTIFICATE_PATH" ] || [ ! -f "$PRIVATE_KEY_PATH" ]; then
    error "错误: 证书文件或私钥文件不存在\n证书文件: $CERTIFICATE_PATH\n私钥文件: $PRIVATE_KEY_PATH"
fi

# 获取对方API证书的TLS版本和加密算法
get_api_certificate_info

if need_renew_certificate; then
    renew_certificate
else
    log "证书是最新的"
fi

log "证书检查完成"

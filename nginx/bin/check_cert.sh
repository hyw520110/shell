#!/bin/bash

# API域名和端口
API_DOMAIN="api.pg-bo.me"
API_PORT=443

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            API_DOMAIN="$2"
            shift 2
            ;;
        --port)
            API_PORT="$2"
            shift 2
            ;;
        --nginx-conf-dir)
            NGINX_CONF_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --domain DOMAIN    API域名，默认为api.pg-bo.me"
            echo "  --port PORT        API端口，默认为443"
            echo "  --nginx-conf-dir DIR  Nginx配置目录，默认自动检测"
            echo "  --help, -h         显示此帮助信息"
            exit 0
            ;;
        *)
            shift
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
fi

echo "使用Nginx配置目录: $NGINX_CONF_DIR"

# 查找包含指定proxy_pass的配置文件
NGINX_CONF_FILE=$(find "$NGINX_CONF_DIR" -type f -name "*.conf" -exec grep -l "proxy_pass https://$API_DOMAIN" {} \; 2>/dev/null | head -1)


# 递归查找include文件中的配置
find_included_configs() {
    local conf_file="$1"
    local conf_dir=$(dirname "$conf_file")
    
    # 查找include指令
    grep -E "^\s*include\s+" "$conf_file" 2>/dev/null | while read -r line; do
        # 提取文件路径
        local included_path=$(echo "$line" | awk '{print $2}' | sed 's/;//')
        
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
    
    # 避免循环引用
    if echo "$visited_files" | grep -q "$conf_file"; then
        return
    fi
    
    # 更新已访问文件列表
    visited_files="$visited_files:$conf_file"
    
    # 直接从当前配置文件提取
    local cert_path=$(grep 'ssl_certificate ' "$conf_file" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
    local key_path=$(grep 'ssl_certificate_key ' "$conf_file" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
    
    if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
        echo "cert:$cert_path"
        echo "key:$key_path"
        return
    fi
    
    # 从include文件中查找
    find_included_configs "$conf_file" | while read -r included_file; do
        # 处理通配符
        if [[ "$included_file" == *"*"* ]]; then
            # 展开通配符
            for f in $included_file; do
                if [ -f "$f" ]; then
                    extract_certificate_paths "$f" "$visited_files"
                fi
            done
        elif [ -f "$included_file" ]; then
            extract_certificate_paths "$included_file" "$visited_files"
        fi
    done
}

# 提取Nginx域名和证书路径
extract_nginx_info() {
    NGINX_DOMAIN=$(grep -A 5 "443" $NGINX_CONF_FILE | grep "server_name " | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
    
    # 递归查找证书路径
    local cert_info=$(extract_certificate_paths "$NGINX_CONF_FILE" "")
    CERTIFICATE_PATH=$(echo "$cert_info" | grep "^cert:" | cut -d: -f2 | head -1)
    PRIVATE_KEY_PATH=$(echo "$cert_info" | grep "^key:" | cut -d: -f2 | head -1)
    
    echo "Nginx Domain: $NGINX_DOMAIN"
    echo "Certificate Path: $CERTIFICATE_PATH"
    echo "Private Key Path: $PRIVATE_KEY_PATH"
}

# 获取对方API证书的TLS版本和加密算法
get_api_certificate_info() {
    # 获取证书
    openssl s_client -connect $API_DOMAIN:$API_PORT </dev/null 2>/dev/null | openssl x509 -noout -text > api_certificate.txt

    # 获取TLS版本
    supported_versions=$(openssl s_client -connect $API_DOMAIN:$API_PORT -tls1_2 </dev/null 2>/dev/null | grep -i "New, (TLSv1|TLSv1.1|TLSv1.2|TLSv1.3)" | awk '{print $3}' | sed 's/,//g' | tr '\n' ' ')
    if [ -z "$supported_versions" ]; then
        supported_versions=$(openssl s_client -connect $API_DOMAIN:$API_PORT -tls1_3 </dev/null 2>/dev/null | grep -i "New, (TLSv1|TLSv1.1|TLSv1.2|TLSv1.3)" | awk '{print $3}' | sed 's/,//g' | tr '\n' ' ')
    fi

    # 获取加密算法
    local supported_ciphers=$(openssl s_client -connect $API_DOMAIN:$API_PORT -cipher 'ALL' -tls1_2 </dev/null 2>/dev/null | grep -i "Cipher " | awk -F': ' '{print $2}' | tr '\n' ' ')
    if [ -z "$supported_ciphers" ]; then
        supported_ciphers=$(openssl s_client -connect $API_DOMAIN:$API_PORT -cipher 'ALL' -tls1_3 </dev/null 2>/dev/null | grep -i "Cipher is" | awk '{print $3}' | tr '\n' ' ')
    fi

    echo "TLS versions: $supported_versions"
    echo "Ciphers: $supported_ciphers"
    echo "$supported_versions" > api_supported_versions.txt
    echo "$supported_ciphers" > api_supported_ciphers.txt
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
    local supported_versions=$(cat api_supported_versions.txt)
    local supported_ciphers=$(cat api_supported_ciphers.txt)

    # 生成新的证书
    sudo certbot certonly --webroot -w /var/www/html -d $NGINX_DOMAIN --agree-tos --email your_email@example.com

    # 更新Nginx配置
    sudo sed -i "s/ssl_protocols .*/ssl_protocols ${supported_versions// / };/" $NGINX_CONF_FILE
    sudo sed -i "s/ssl_ciphers .*/ssl_ciphers '${supported_ciphers// /:}';/" $NGINX_CONF_FILE

    # 重启Nginx
    sudo systemctl restart nginx
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
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "错误: 缺少以下工具: ${missing_tools[*]}"
        echo "请安装这些工具后再运行此脚本"
        exit 1
    fi
}

# 主逻辑
check_required_tools

if [ -z "$NGINX_CONF_FILE" ]; then
    echo "未找到与API域名: $API_DOMAIN 对应的Nginx配置文件"
    exit 1
fi

extract_nginx_info $NGINX_CONF_FILE

# 检查证书文件是否存在
if [ ! -f "$CERTIFICATE_PATH" ] || [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo "错误: 证书文件或私钥文件不存在"
    echo "证书文件: $CERTIFICATE_PATH"
    echo "私钥文件: $PRIVATE_KEY_PATH"
    exit 1
fi

# 获取对方API证书的TLS版本和加密算法
get_api_certificate_info $API_DOMAIN $API_PORT

if need_renew_certificate; then
    renew_certificate
else
    echo "证书是最新的"
fi

# 清理临时文件
rm -f api_certificate.txt api_supported_versions.txt api_supported_ciphers.txt

#!/bin/bash

# API域名和端口

API_DOMAIN="api.pg-bo.me"
API_PORT=443

# Nginx配置文件路径
NGINX_CONF_DIR="/etc/nginx"
NGINX_CONF_FILE=$(find $NGINX_CONF_DIR -type f -name "*.conf" -exec grep -l "proxy_pass https://$API_DOMAIN" {} \;)


# 提取Nginx域名和证书路径
extract_nginx_info() {
    NGINX_DOMAIN=$(grep -A 5 "443" $NGINX_CONF_FILE |grep "server_name " | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
    CERTIFICATE_PATH=$(grep 'ssl_certificate ' $NGINX_CONF_FILE | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
    PRIVATE_KEY_PATH=$(grep 'ssl_certificate_key ' $NGINX_CONF_FILE | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
    if [ ! -n "$CERTIFICATE_PATH" ] || [ ! -n "$PRIVATE_KEY_PATH" ]; then
         conf_file=$(grep "include" $NGINX_CONF_FILE|awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
         CERTIFICATE_PATH=$(grep 'ssl_certificate ' ${NGINX_CONF_DIR}/$conf_file | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
         PRIVATE_KEY_PATH=$(grep 'ssl_certificate_key ' ${NGINX_CONF_DIR}/$conf_file | awk '{gsub(/ /, "", $2); gsub(/;/, "", $2); print $2}')
    fi
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

# 主逻辑
if [ -z "$NGINX_CONF_FILE" ]; then
    echo "未找到与API域名: $API_DOMAIN 对应的Nginx配置文件"
    exit 1
fi

extract_nginx_info $NGINX_CONF_FILE

# 获取对方API证书的TLS版本和加密算法
get_api_certificate_info $API_DOMAIN $API_PORT

if need_renew_certificate; then
    renew_certificate
else
    echo "证书是最新的"
fi
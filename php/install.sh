#!/bin/bash

# 变量定义
DEFAULT_USER="www-data"
DEFAULT_GROUP="www-data"
DEFAULT_PHP_DIR="/opt/php"

# 更新包列表
update_package_list() {
    if command -v apt-get &> /dev/null; then
         apt-get update
    elif command -v yum &> /dev/null; then
         yum makecache
    else
        echo "不支持的包管理器。"
        exit 1
    fi
}

# 检查并安装 PHP 和 PHP-FPM
install_php_fpm() {
    if ! dpkg -l 2>/dev/null | grep -q '^ii  php-fpm' && ! rpm -q php-fpm &> /dev/null; then
        echo "正在安装 PHP 和 PHP-FPM..."
        if command -v apt-get &> /dev/null; then
             apt-get install -y php-fpm
        elif command -v yum &> /dev/null; then
             yum install -y php-fpm
        else
            echo "不支持的包管理器。"
            exit 1
        fi
    else
        echo "PHP 和 PHP-FPM 已经安装。"
    fi
}

# 获取 PHP 版本
get_php_version() {
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f 2 | cut -d '.' -f 1-2)
    else
        echo "PHP 未安装。"
        exit 1
    fi
}

# 检查并安装常用的 PHP 扩展
install_php_extensions() {
    extensions=(
        php-mysql
        php-curl
        php-gd
        php-mbstring
        php-xml
        php-zip
        php-bcmath
        php-json
        php-intl
        php-soap
        php-ldap
        php-opcache
    )

    for extension in "${extensions[@]}"; do
        if ! dpkg -l | grep -q "^ii  ${extension}" && ! rpm -q ${extension} &> /dev/null; then
            echo "正在安装 ${extension}..."
            if command -v apt-get &> /dev/null; then
                 apt-get install -y ${extension}
            elif command -v yum &> /dev/null; then
                 yum install -y ${extension}
            else
                echo "不支持的包管理器。"
                exit 1
            fi
        else
            echo "${extension} 已经安装。"
        fi
    done
}

# 提示用户输入所属用户和组
prompt_user_group() {
    read -t 8 -p "请输入 PHP-FPM 的用户（默认 ${DEFAULT_USER}）: " user_input
    user=${user_input:-${DEFAULT_USER}}

    read -t 8 -p "请输入 PHP-FPM 的组（默认 ${DEFAULT_GROUP}）: " group_input
    group=${group_input:-${DEFAULT_GROUP}}

    echo "使用用户: ${user}"
    echo "使用组: ${group}"
}

# 提示用户输入部署目录
prompt_php_dir() {
    read -t 8 -p "请输入部署目录 (默认 ${DEFAULT_PHP_DIR}): " php_dir_input
    php_dir=${php_dir_input:-${DEFAULT_PHP_DIR}}

    echo "使用部署目录: ${php_dir}"
}

# 确保 PHP-FPM 服务配置正确
configure_php_fpm() {
    PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    echo "使用 PHP 版本: ${PHP_VERSION}"
    echo "PHP-FPM 套接字: ${PHP_FPM_SOCKET}"

     sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/${PHP_VERSION}/fpm/php.ini

    # 修改 PHP-FPM 配置文件
    # sed -i "s/^listen = 127.0.0.1:9000/listen = ${PHP_FPM_SOCKET}/" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
     chown -R ${user}:${group} ${php_dir}
     chmod -R 755 ${php_dir}
    # 如果用户不是 www-data，修改配置文件中的用户和组
    if [ "$user" != "${DEFAULT_USER}" ]; then
         sed -i "s/^user = .*/user = ${user}/" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
         sed -i "s/^group = .*/group = ${group}/" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
        echo "修改 PHP-FPM 相关目录的所有权和权限..."
         chown -R ${user}:${group} /var/lib/php /etc/php/
         find ${php_dir} -type f -exec chmod 644 {} \;
    fi
}

# 重启 PHP-FPM 服务
restart_php_fpm() {
    if command -v systemctl &> /dev/null; then
         systemctl restart php${PHP_VERSION}-fpm
    else
        echo "不支持的系统服务管理器。"
        exit 1
    fi
}

# 重启 Nginx 服务
restart_nginx() {
    if command -v systemctl &> /dev/null; then
         systemctl restart nginx
    else
        echo "不支持的系统服务管理器。"
        exit 1
    fi
}

# 主函数
main() {
    update_package_list
    install_php_fpm
    get_php_version
    install_php_extensions
    prompt_user_group
    prompt_php_dir
    configure_php_fpm
    restart_php_fpm
    restart_nginx
    echo "PHP 和常用扩展已经安装并配置完成。"
}

# 执行主函数
main
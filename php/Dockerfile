# 使用官方的 CentOS 7 镜像作为基础镜像
FROM centos:centos7.9.2009

# 设置非交互式环境变量以避免配置提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装必要的工具和依赖
RUN yum install -y \
    epel-release \
    http://rpms.remirepo.net/enterprise/remi-release-7.rpm \
    && yum-config-manager --enable remi-php74 \
    && yum update -y \
    && yum install -y \
    gcc \
    make \
    libmemcached-devel \
    zlib-devel \
    unzip \
    git \
    curl \
    wget \
    && yum clean all

# 安装 PHP-FPM 7.4 及相关扩展
RUN yum install -y \
    php-fpm \
    php-mysqlnd \
    php-cli \
    php-json \
    php-zip \
    php-gd \
    php-mbstring \
    php-curl \
    php-intl \
    php-bcmath \
    php-soap \
    php-xml \
    php-pecl-redis5 \
    && yum clean all

# 安装 MongoDB PHP 扩展
RUN pecl install mongodb-1.11.1 \
    && echo "extension=mongodb.so" > /etc/php.d/20-mongodb.ini

# 设置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# 设置 PHP 配置
RUN sed -i "s/;date.timezone =/date.timezone = Asia\/Shanghai/" /etc/php.ini

# 设置工作目录
WORKDIR /var/www/html

# 暴露端口
EXPOSE 9000

# 启动 PHP-FPM
CMD ["php-fpm", "-F"]
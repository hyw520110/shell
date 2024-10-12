#!/bin/bash
port=${1:-7898}
# 定义路径
SYSTEMD_SYSTEM_DIRS=("/etc/systemd/system" "/usr/lib/systemd/system")
DOCKER_SERVICE_FILE="docker.service"
PROXY_CONF_FILE="http-proxy.conf"
CONFIG_CONTENT="[Service]
Environment=\"HTTP_PROXY=http://localhost:$port\"
Environment=\"HTTPS_PROXY=http://localhost:$port\"
Environment=\"NO_PROXY=localhost,127.0.0.1\""

# 检查是否已有代理配置
has_proxy_config() {
    local dir=$1
    local service_file="$dir/$DOCKER_SERVICE_FILE"
    local conf_dir="$dir/docker.service.d"

    # 检查 service 文件中是否有代理配置
    if [ -f "$service_file" ] && grep -qE "(^| )[Ee]nvironment=\"?HTTP_PROXY=|(^| )[Ee]nvironment=\"?HTTPS_PROXY=|(^| )[Ee]nvironment=\"?NO_PROXY=" "$service_file"; then
        return 0
    fi

    # 检查是否有代理配置文件
    if [ -d "$conf_dir" ] && find "$conf_dir" -type f -exec grep -lE "(^| )[Ee]nvironment=\"?HTTP_PROXY=|(^| )[Ee]nvironment=\"?HTTPS_PROXY=|(^| )[Ee]nvironment=\"?NO_PROXY=" {} \+ | grep -q .; then
        return 0
    fi

    return 1
}

# 重启 Docker 服务
restart_docker_service() {
    echo "正在重启 Docker 服务..."
    sudo systemctl daemon-reload
    if sudo systemctl is-active docker; then
        sudo systemctl restart docker
    else
        sudo systemctl start docker
    fi

    if sudo systemctl is-active docker; then
        echo "Docker 服务已成功重启。"
        echo "检查 Docker 守护进程环境变量设置情况："
        sudo systemctl show docker --property=Environment
    else
        echo "Docker 服务重启失败，请检查日志文件。"
    fi
}

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要 root 权限才能运行。请使用 sudo 或以 root 用户身份运行此脚本。"
    exit 1
fi

# 标记是否找到了 docker.service 文件
found_docker_service=false

# 遍历所有 systemd 目录
for dir in "${SYSTEMD_SYSTEM_DIRS[@]}"; do
    if has_proxy_config "$dir"; then
        echo "代理配置已在 $dir 中存在，无需重复添加。"
        exit 0
    fi

    # 检查是否存在 docker.service 文件
    service_file="$dir/$DOCKER_SERVICE_FILE"
    conf_dir="$dir/docker.service.d"

    if [ -f "$service_file" ]; then
        found_docker_service=true
        # 如果没有代理配置，则在 docker.service 文件所在的目录的 docker.service.d 子目录下添加配置
        [ ! -d $conf_dir ] && mkdir -p "$conf_dir"
        echo "$CONFIG_CONTENT" > "$conf_dir/$PROXY_CONF_FILE"
        echo "配置文件 $conf_dir/$PROXY_CONF_FILE 已创建并添加。"
        restart_docker_service
        exit 0
    fi
done

# 如果没有找到 docker.service 文件，给出提示
if [ "$found_docker_service" = false ]; then
    echo "没有找到 $DOCKER_SERVICE_FILE 文件。请确保 Docker 服务已被正确安装。"
    exit 1
fi

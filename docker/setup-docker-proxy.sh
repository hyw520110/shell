#!/bin/bash

# 定义路径
SYSTEMD_SYSTEM_DIRS=("/etc/systemd/system" "/usr/lib/systemd/system")
DOCKER_SERVICE_FILE="docker.service"
PROXY_CONF_FILE="http-proxy.conf"
DEFAULT_PORT=7898

# 检查是否已有代理配置，并检查是否匹配
has_proxy_config() {
    local dir=$1
    local ip=$2
    local port=$3
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

    # 检查环境变量中是否有代理配置
    local http_proxy=$HTTP_PROXY
    local https_proxy=$HTTPS_PROXY
    local no_proxy=$NO_PROXY

    if [ -n "$http_proxy" ] || [ -n "$https_proxy" ] || [ -n "$no_proxy" ]; then
        if [ "$http_proxy" == "http://$ip:$port" ] && \
           [ "$https_proxy" == "http://$ip:$port" ] && \
           [ "$no_proxy" == "localhost,127.0.0.1" ]; then
            return 0
        else
            return 2
        fi
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

# 显示菜单
show_menu() {
    echo "请选择操作："
    echo "1. 添加代理配置"
    echo "2. 删除代理配置"
    read -p "请输入选项 (1 或 2): " choice
}

# 处理添加代理配置
add_proxy_config() {
    # 获取代理 IP 地址
    read -p "请输入代理 IP 地址（默认: 127.0.0.1）: " proxy_ip
    proxy_ip=${proxy_ip:-127.0.0.1}

    # 获取端口号参数，如果没有提供则提示用户输入
    read -p "请输入 HTTP 代理端口号（默认: ${DEFAULT_PORT}）: " port
    port=${port:-$DEFAULT_PORT}

    # 构建配置内容
    CONFIG_CONTENT="[Service]
Environment=\"HTTP_PROXY=http://$proxy_ip:$port\"
Environment=\"HTTPS_PROXY=http://$proxy_ip:$port\"
Environment=\"NO_PROXY=localhost,127.0.0.1\""

    # 标记是否找到了 docker.service 文件
    found_docker_service=false

    # 遍历所有 systemd 目录
    for dir in "${SYSTEMD_SYSTEM_DIRS[@]}"; do
        if has_proxy_config "$dir" "$proxy_ip" "$port"; then
            case $? in
                0)
                    echo "代理配置已在 $dir 中存在且匹配，无需重复添加。"
                    exit 0
                    ;;
                2)
                    read -p "代理配置已在 $dir 中存在，但 IP 或端口不匹配。是否要修改？(y/n): " confirm
                    if [ "$confirm" != "y" ]; then
                        echo "操作已取消。"
                        exit 0
                    fi
                    # 修改现有配置
                    [ ! -d "$dir/docker.service.d" ] && mkdir -p "$dir/docker.service.d"
                    echo "$CONFIG_CONTENT" > "$dir/docker.service.d/$PROXY_CONF_FILE"
                    echo "配置文件 $dir/docker.service.d/$PROXY_CONF_FILE 已更新。"
                    restart_docker_service
                    exit 0
                    ;;
            esac
        fi

        # 检查是否存在 docker.service 文件
        service_file="$dir/$DOCKER_SERVICE_FILE"
        conf_dir="$dir/docker.service.d"

        if [ -f "$service_file" ]; then
            found_docker_service=true
            # 如果没有代理配置，则在 docker.service 文件所在的目录的 docker.service.d 子目录下添加配置
            [ ! -d "$conf_dir" ] && mkdir -p "$conf_dir"
            echo "$CONFIG_CONTENT" > "$conf_dir/$PROXY_CONF_FILE"
            echo "配置文件 $conf_dir/$PROXY_CONF_FILE 已创建并添加。"
            restart_docker_service
            exit 0
        fi
    done

    if [ "$found_docker_service" = true ]; then
        exit 0
    fi

    echo "没有找到 $DOCKER_SERVICE_FILE 文件。将代理配置添加到环境变量中。"
    # 检测当前使用的 shell 配置文件
    if [ -f ~/.zshrc ]; then
        SHELL_CONFIG_FILE=~/.zshrc
    elif [ -f ~/.bashrc ]; then
        SHELL_CONFIG_FILE=~/.bashrc
    else
        echo "无法找到 .zshrc 或 .bashrc 文件。请手动设置环境变量。"
        exit 1
    fi

    # 检查环境变量中是否有代理配置
    if has_proxy_config "" "$proxy_ip" "$port"; then
        case $? in
            0)
                echo "环境变量中已存在相同的代理配置，无需重复添加。"
                exit 0
                ;;
            2)
                read -p "环境变量中已存在代理配置，但 IP 或端口不匹配。是否要修改？(y/n): " confirm
                if [ "$confirm" != "y" ]; then
                    echo "操作已取消。"
                    exit 0
                fi
                ;;
        esac
    fi

    # 检查并添加环境变量到 shell 配置文件
    if ! grep -q "^export HTTP_PROXY=http://$proxy_ip:$port$" "$SHELL_CONFIG_FILE"; then
        sed -i '/^export HTTP_PROXY=/d' "$SHELL_CONFIG_FILE"
        echo "export HTTP_PROXY=http://$proxy_ip:$port" >> "$SHELL_CONFIG_FILE"
    fi
    if ! grep -q "^export HTTPS_PROXY=http://$proxy_ip:$port$" "$SHELL_CONFIG_FILE"; then
        sed -i '/^export HTTPS_PROXY=/d' "$SHELL_CONFIG_FILE"
        echo "export HTTPS_PROXY=http://$proxy_ip:$port" >> "$SHELL_CONFIG_FILE"
    fi
    if ! grep -q "^export NO_PROXY=localhost,127.0.0.1$" "$SHELL_CONFIG_FILE"; then
        sed -i '/^export NO_PROXY=/d' "$SHELL_CONFIG_FILE"
        echo "export NO_PROXY=localhost,127.0.0.1" >> "$SHELL_CONFIG_FILE"
    fi

    echo "环境变量已添加到 $SHELL_CONFIG_FILE。"
    source "$SHELL_CONFIG_FILE"
    echo "环境变量已加载。"
}

# 处理删除代理配置
remove_proxy_config() {
    # 删除 systemd 目录中的代理配置文件
    for dir in "${SYSTEMD_SYSTEM_DIRS[@]}"; do
        conf_dir="$dir/docker.service.d"
        if [ -d "$conf_dir" ] && [ -f "$conf_dir/$PROXY_CONF_FILE" ]; then
            rm -f "$conf_dir/$PROXY_CONF_FILE"
            echo "已删除 $conf_dir/$PROXY_CONF_FILE。"
        fi
    done

    # 重新加载 systemd 配置并重启 Docker 服务
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "Docker 服务已重启。"
    sudo systemctl show docker --property=Environment

    # 删除环境变量中的代理配置
    if [ -f ~/.zshrc ]; then
        SHELL_CONFIG_FILE=~/.zshrc
    elif [ -f ~/.bashrc ]; then
        SHELL_CONFIG_FILE=~/.bashrc
    else
        echo "无法找到 .zshrc 或 .bashrc 文件。请手动删除环境变量。"
        exit 1
    fi

    # 删除环境变量配置
    sed -i '/^export HTTP_PROXY=/d' "$SHELL_CONFIG_FILE"
    sed -i '/^export HTTPS_PROXY=/d' "$SHELL_CONFIG_FILE"
    sed -i '/^export NO_PROXY=/d' "$SHELL_CONFIG_FILE"

    echo "环境变量已从 $SHELL_CONFIG_FILE 中删除。"
    source "$SHELL_CONFIG_FILE"
    echo "环境变量已重新加载。"
}

# 显示菜单并处理选择
show_menu
case $choice in
    1)
        add_proxy_config
        ;;
    2)
        remove_proxy_config
        ;;
    *)
        echo "无效的选择。请重新运行脚本并选择 1 或 2。"
        ;;
esac
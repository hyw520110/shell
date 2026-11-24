#!/bin/bash

# Nginx状态检查公共函数库

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# 尝试使用sudo执行命令
sudo_exec() {
    if command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        echo "错误: 需要root权限但未找到sudo命令" >&2
        return 1
    fi
}

# 检查主机模式Nginx是否已启动
check_host_nginx_running() {
    if check_root; then
        if command -v pgrep > /dev/null 2>&1; then
            [ $(pgrep nginx | wc -l) -gt 0 ] && return 0
        else
            [ $(ps -ef | grep nginx | grep -v grep | wc -l) -gt 0 ] && return 0
        fi
    else
        if command -v pgrep > /dev/null 2>&1; then
            # 修复sudo在管道中的问题
            local count=0
            count=$(sudo pgrep nginx 2>/dev/null | wc -l)
            [ $count -gt 0 ] && return 0
        else
            local count=0
            count=$(sudo ps -ef 2>/dev/null | grep nginx | grep -v grep | wc -l)
            [ $count -gt 0 ] && return 0
        fi
    fi
    return 1
}

# 检查Docker模式Nginx是否已启动
check_docker_nginx_running() {
    if command -v docker > /dev/null 2>&1; then
        if check_root; then
            [ $(docker ps 2>/dev/null | grep nginx | grep -v grep | wc -l) -gt 0 ] && return 0
        else
            [ $(sudo docker ps 2>/dev/null | grep nginx | grep -v grep | wc -l) -gt 0 ] && return 0
        fi
    fi
    return 1
}

# 检查Nginx是否已启动（主机模式或Docker模式）
check_nginx_running() {
    if check_host_nginx_running || check_docker_nginx_running; then
        return 0
    else
        return 1
    fi
}

# 显示Nginx进程状态
show_nginx_status() {
    if check_root; then
        ps -ef | grep nginx | grep -v grep
    else
        sudo ps -ef 2>/dev/null | grep nginx | grep -v grep
    fi
    
    # 显示Docker容器状态
    if command -v docker > /dev/null 2>&1; then
        if check_root; then
            docker ps 2>/dev/null | grep nginx
        else
            sudo docker ps 2>/dev/null | grep nginx
        fi
    fi
}


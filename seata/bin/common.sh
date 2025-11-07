#!/bin/bash

# Seata 公共函数库
# 包含安装、启动、停止脚本中重复使用的函数

set -e

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 带颜色的输出函数
print_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检测操作系统是否为 macOS 或 Linux
get_os_type() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux"
    else
        print_error "不支持的操作系统: $OSTYPE"
        return 1
    fi
}

# 检查 docker-compose 是否已安装
check_docker_compose() {
    if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
        print_error "未找到docker-compose或docker compose命令"
        return 1
    fi
    return 0
}

# 检查Docker是否运行，如果没有则尝试启动
check_and_start_docker() {
    if ! docker info > /dev/null 2>&1; then
        print_info "Docker服务未运行，正在尝试启动Docker..."
        
        # 尝试在不同系统上启动Docker
        if command -v systemctl &> /dev/null; then
            # Linux系统，尝试使用systemctl
            if systemctl is-active --quiet docker; then
                print_info "Docker服务已存在但未响应，尝试重启..."
                sudo systemctl restart docker
            else
                print_info "正在启动Docker服务..."
                sudo systemctl start docker
            fi
        elif command -v brew &> /dev/null; then
            # macOS系统，使用brew services
            print_info "正在启动Docker服务..."
            brew services start docker 2>/dev/null || print_warn "请手动启动Docker应用"
        elif command -v service &> /dev/null; then
            # 传统Linux系统，使用service命令
            if service docker status 2>/dev/null | grep -q running; then
                print_info "Docker服务已存在但未响应，尝试重启..."
                sudo service docker restart
            else
                print_info "正在启动Docker服务..."
                sudo service docker start
            fi
        else
            # 在常见安装目录下查找Docker
            local possible_docker_paths=(
                "/usr/bin/docker"
                "/usr/local/bin/docker"
                "/opt/docker/docker"
                "/Applications/Docker.app/Contents/Resources/bin/docker"  # macOS
            )
            
            local docker_found=false
            for path in "${possible_docker_paths[@]}"; do
                if [ -x "$path" ]; then
                    print_info "找到Docker可执行文件: $path"
                    print_warn "请手动启动Docker服务或应用程序"
                    docker_found=true
                    break
                fi
            done
            
            if [ "$docker_found" = false ]; then
                print_error "无法找到Docker，请确认已安装Docker并手动启动"
                return 1
            fi
        fi
        
        # 等待Docker启动
        print_info "等待Docker服务启动..."
        local timeout=30
        local count=0
        while [ $count -lt $timeout ]; do
            if docker info > /dev/null 2>&1; then
                print_info "Docker服务已启动"
                return 0
            fi
            sleep 1
            ((count++))
        done
        
        if [ $count -eq $timeout ]; then
            print_error "Docker服务启动超时，请手动启动Docker后再运行此脚本"
            return 1
        fi
    fi
    
    return 0
}
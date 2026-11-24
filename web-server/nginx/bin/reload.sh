#!/bin/bash
#nginx加载配置

BASE_DIR=`cd $(dirname $0)/..; pwd`
conf_file=$BASE_DIR/conf/nginx.conf

# 全局变量用于缓存权限检测结果
IS_ROOT_DETERMINED=false
IS_ROOT=false
NEEDS_SUDO_DETERMINED=false
NEEDS_SUDO=false

# 检查是否以root权限运行
check_root() {
    if [ "$IS_ROOT_DETERMINED" = true ]; then
        if [ "$IS_ROOT" = true ]; then
            return 0
        else
            return 1
        fi
    fi
    
    if [[ $EUID -eq 0 ]]; then
        IS_ROOT=true
        IS_ROOT_DETERMINED=true
        return 0
    else
        IS_ROOT=false
        IS_ROOT_DETERMINED=true
        return 1
    fi
}

# 确定是否需要sudo权限
determine_needs_sudo() {
    if [ "$NEEDS_SUDO_DETERMINED" = true ]; then
        if [ "$NEEDS_SUDO" = true ]; then
            return 0
        else
            return 1
        fi
    fi
    
    # 检查Nginx进程所有者
    local nginx_owner=""
    if check_root; then
        nginx_owner=$(ps -ef | grep nginx | grep master | awk '{print $1}' | head -1)
    else
        nginx_owner=$(sudo ps -ef 2>/dev/null | grep nginx | grep master | awk '{print $1}' | head -1)
    fi
    
    if [ "$nginx_owner" = "root" ] && ! check_root; then
        NEEDS_SUDO=true
        NEEDS_SUDO_DETERMINED=true
        return 0
    else
        NEEDS_SUDO=false
        NEEDS_SUDO_DETERMINED=true
        return 1
    fi
}

# 通用执行函数
exec_cmd() {
    local purpose="$1"
    shift
    local cmd=("$@")
    
    # 确定是否需要sudo
    if ! determine_needs_sudo; then
        # 不需要sudo
        echo "$purpose: ${cmd[*]}"
        "${cmd[@]}"
    else
        # 需要sudo
        if command -v sudo > /dev/null 2>&1; then
            echo "$purpose: sudo ${cmd[*]}"
            sudo "${cmd[@]}"
        else
            echo "错误: 需要root权限但未找到sudo命令" >&2
            return 1
        fi
    fi
}

# Docker执行函数
exec_docker_cmd() {
    local purpose="$1"
    shift
    local cmd=("$@")
    
    if check_root; then
        echo "$purpose: ${cmd[*]}"
        "${cmd[@]}"
    else
        if command -v sudo > /dev/null 2>&1; then
            echo "$purpose: sudo ${cmd[*]}"
            sudo "${cmd[@]}"
        else
            echo "错误: 需要root权限但未找到sudo命令" >&2
            return 1
        fi
    fi
}

# 获取Docker容器名称
get_docker_container_name() {
    local compose_file="$BASE_DIR/docker-compose.yml"
    if [ -f "$compose_file" ]; then
        # 从docker-compose.yml中提取容器名称
        local container_name=$(grep "container_name:" "$compose_file" 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$container_name" ]; then
            echo "$container_name"
            return 0
        fi
    fi
    # 默认容器名称
    echo "nginx"
}

reload_nginx() {
    # 获取容器名称
    local container_name=$(get_docker_container_name)
    
    # 检查指定容器是否正在运行
    if [ -n "`docker ps -a 2>/dev/null | grep $container_name | grep Up`" ]; then
        echo "检测到Docker中的Nginx容器($container_name)正在运行"
        local isOk=""
        isOk=$(exec_docker_cmd "配置测试" docker exec $container_name nginx -t 2>/dev/null | grep ok)
        if [ -n "$isOk" ]; then
            echo "$isOk"
            echo "重新加载Docker中的Nginx配置..."
            exec_docker_cmd "重新加载" docker exec $container_name nginx -s reload
        fi
    else
        # 检查nginx命令是否存在
        if command -v nginx >/dev/null 2>&1; then
            NGINX_CMD="nginx"
        else
            # 尝试在常见位置查找nginx
            local nginx_paths=(
                "/usr/sbin/nginx"
                "/usr/bin/nginx"
                "/usr/local/bin/nginx"
                "/usr/local/nginx/sbin/nginx"
                "/opt/nginx/sbin/nginx"
                "/usr/local/openresty/nginx/sbin/nginx"
                "$HOME/nginx/sbin/nginx"
            )
            
            for path in "${nginx_paths[@]}"; do
                if [ -x "$path" ]; then
                    NGINX_CMD="$path"
                    break
                fi
            done
        fi
        # 如果找到了nginx命令
        if [ -n "$NGINX_CMD" ]; then
            # 先测试配置
            local test_result=""
            test_result=$(exec_cmd "检查配置" $NGINX_CMD -c $conf_file -t 2>&1)
            
            echo "$test_result"
            
            if echo "$test_result" | grep -q "syntax is ok"; then
                echo "Nginx配置ok"
                # 尝试重新加载
                local reload_result=""
                reload_result=$(exec_cmd "重新加载" $NGINX_CMD -c $conf_file -s reload 2>&1)
                
                echo "$reload_result"
                
                if [ $? -eq 0 ] || echo "$reload_result" | grep -q "signal"; then
                    echo "Nginx重新加载成功"
                else
                    echo "Nginx重新加载失败"
                    return 1
                fi
            else
                echo "Nginx配置测试失败"
                return 1
            fi
        else
            echo "错误: 找不到nginx命令"
            return 1
        fi
    fi
}

# 执行重新加载
reload_nginx
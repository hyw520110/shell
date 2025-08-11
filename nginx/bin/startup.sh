#!/bin/bash
# nginx智能启动脚本 - 支持Docker模式和主机模式

#CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取本机IP（macOS兼容方式）
get_ip() {
    if command -v ip > /dev/null 2>&1; then
        ip addr | awk '/inet / && !/127.0.0.1/ {sub("/.*", "", $2); print $2; exit}'
    elif command -v ifconfig > /dev/null 2>&1; then
        ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
    else
        echo "127.0.0.1"
    fi
}

# 检查Docker是否可用
check_docker_available() {
    if ! command -v docker > /dev/null 2>&1; then
        echo -e "${YELLOW}Docker未安装，将使用主机模式启动${NC}"
        return 1
    fi
    
    # 检查Docker守护进程是否运行
    if ! docker info > /dev/null 2>&1; then
        echo -e "${YELLOW}Docker未启动，将使用主机模式启动${NC}"
        return 1
    fi
    
    return 0
}

# 查找nginx执行文件
find_nginx_executable() {
    local nginx_paths=(
        "/usr/bin/nginx"
        "/usr/local/bin/nginx"
        "/usr/local/nginx/sbin/nginx"
        "/opt/nginx/sbin/nginx"
        "$HOME/nginx/sbin/nginx"
        "/opt/local/nginx/sbin/nginx"
        "/usr/local/opt/nginx/bin/nginx"  # macOS Homebrew
    )
    
    for path in "${nginx_paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # 查找PATH中的nginx
    if command -v nginx > /dev/null 2>&1; then
        which nginx
        return 0
    fi
    
    return 1
}

# 检查Nginx是否已启动
check_nginx_running() {
    if command -v pgrep > /dev/null 2>&1; then
        [ $(pgrep nginx | wc -l) -gt 0 ] && return 0
    else
        [ $(ps -ef | grep nginx | grep -v grep | wc -l) -gt 0 ] && return 0
    fi
    return 1
}

# 启动主机模式Nginx
start_host_nginx() {
    echo -e "${GREEN}使用主机模式启动Nginx${NC}"
    
    local nginx_bin=$(find_nginx_executable)
    if [ -z "$nginx_bin" ]; then
        echo -e "${RED}错误: 未找到nginx执行文件${NC}"
        echo "已搜索以下位置:"
        echo "  /usr/bin/nginx"
        echo "  /usr/local/bin/nginx"
        echo "  /usr/local/nginx/sbin/nginx"
        echo "  /opt/nginx/sbin/nginx"
        echo "  $HOME/nginx/sbin/nginx"
        echo "  /usr/local/opt/nginx/bin/nginx (macOS Homebrew)"
        echo "以及PATH环境变量中的nginx"
        return 1
    fi
    
    echo -e "${GREEN}找到nginx执行文件: $nginx_bin${NC}"
    BASE_DIR=$(dirname $nginx_bin)
    # 检查配置文件
    if [ ! -f "$BASE_DIR/conf/nginx.conf" ]; then
        echo -e "${RED}错误: Nginx配置文件不存在: $BASE_DIR/conf/nginx.conf${NC}"
        return 1
    fi
    
    if check_nginx_running; then
        echo -e "${YELLOW}Nginx已经在运行中...${NC}"
        if command -v pgrep > /dev/null 2>&1; then
            pgrep nginx | xargs ps -p
        else
            ps -ef | grep nginx | grep -v grep
        fi
        return 0
    fi
    
    echo "启动Nginx..."
    "$nginx_bin" -c "$BASE_DIR/conf/nginx.conf"
    sleep 2
    
    if check_nginx_running; then
        echo -e "${GREEN}Nginx主机模式启动成功！${NC}"
        if command -v pgrep > /dev/null 2>&1; then
            pgrep nginx | xargs ps -p
        else
            ps -ef | grep nginx | grep -v grep
        fi
        return 0
    else
        echo -e "${RED}Nginx主机模式启动失败！${NC}"
        return 1
    fi
}

# 启动Docker模式Nginx
start_docker_nginx() {
    echo -e "${GREEN}=== 使用Docker模式启动Nginx ===${NC}"
    
    local compose_file="$BASE_DIR/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        echo -e "${YELLOW}Docker Compose文件不存在: $compose_file${NC}"
        return 1
    fi
    
    # 检查Docker Compose
    if ! command -v docker-compose > /dev/null 2>&1; then
        echo -e "${YELLOW}Docker Compose未安装，尝试使用主机模式...${NC}"
        return 1
    fi
    
    # 处理Docker Compose配置
    handle_docker_compose "$compose_file"
    
    # 获取容器名称
    local container_name=$(grep "container_name:" "$compose_file" 2>/dev/null | awk '{print $2}' || echo "nginx")
    
    # 检查容器状态
    if docker-compose ps | grep -v NAME | grep "$container_name" | grep -Ev "exited|restarting" > /dev/null 2>&1; then
        echo -e "${GREEN}Docker容器已在运行${NC}"
        docker-compose ps
        return 0
    fi
    
    echo "启动Docker容器..."
    docker-compose up -d
    sleep 5
    
    if docker-compose ps | grep -v NAME | grep "$container_name" | grep -Ev "exited|restarting" > /dev/null 2>&1; then
        echo -e "${GREEN}Docker模式启动成功！${NC}"
        docker-compose ps
        return 0
    else
        echo -e "${RED}Docker模式启动失败！${NC}"
        docker-compose logs --tail=50
        return 1
    fi
}

# 处理Docker Compose配置
handle_docker_compose() {
    local compose_file="$1"
    
    # 检查volumes路径
    if command -v awk > /dev/null 2>&1; then
        local volumes_section=$(awk '/volumes:/,/^$/' "$compose_file" 2>/dev/null || echo "")
        if [ -n "$volumes_section" ]; then
            echo "$volumes_section" | grep '\- ' | grep -v "#" | awk '{print $2}' | awk -F':' '{print $1}' | while read -r dir; do
                if [ -n "$dir" ]; then
                    # 相对路径转换绝对路径
                    case "$dir" in
                        .*) dir="${dir#.}"; dir="$BASE_DIR/$dir" ;;
                    esac
                    # 创建目录
                    if [ ! -f "$dir" ] && [ ! -d "$dir" ]; then
                        echo "创建目录: $dir"
                        mkdir -p "$dir"
                    fi
                fi
            done
        fi
    fi
}

# 处理IP替换
handle_ip_replace() {
    local ip=$1
    
    if [ -d "$BASE_DIR/conf/conf.d" ]; then
        if [ -n "$ip" ]; then
            local exists=$(find "$BASE_DIR/conf/conf.d/" -type f -exec grep -l "$ip" {} \; 2>/dev/null || echo "")
            if [ -z "$exists" ]; then
                echo -e "${GREEN}当前服务器IP: $ip${NC}"
                read -p "是否替换配置文件中的IP?(y/n，默认n)：" replace
                if [ "y" = "$replace" ]; then
                    echo "开始替换配置文件中的IP..."
                    find "$BASE_DIR/conf/conf.d/" -type f \! -name "*.bak" \! -name "*.txt" \! -name "ip-black.conf" | while IFS= read -r f; do
                        if [ -f "$f" ]; then
                            if [[ "$OSTYPE" == "darwin"* ]]; then
                                sed -i '' "s/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$ip/g" "$f"
                            else
                                sed -i "s/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/$ip/g" "$f"
                            fi
                        fi
                    done
                    echo -e "${GREEN}IP替换完成${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}配置文件目录不存在: $BASE_DIR/conf/conf.d${NC}"
    fi
}

# 显示使用帮助
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -d, --docker    强制使用Docker模式启动"
    echo "  -h, --host      强制使用主机模式启动"
    echo "  --help          显示此帮助信息"
    echo ""
    echo "默认行为：自动检测Docker可用性，优先使用Docker模式，否则回退到主机模式"
}

# 主逻辑
main() {
    local mode="auto"  # auto, docker, host
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--docker)
                mode="docker"
                shift
                ;;
            -h|--host)
                mode="host"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    echo -e "${GREEN}Nginx启动模式: $mode${NC}"
    
    # 获取本机IP
    local ip=$(get_ip)
    
    # 处理IP替换
    handle_ip_replace "$ip"
    
    case $mode in
        "docker")
            start_docker_nginx || {
                echo -e "${YELLOW}Docker模式失败，尝试主机模式...${NC}"
                start_host_nginx
            }
            ;;
        "host")
            start_host_nginx
            ;;
        "auto")
            if check_docker_available; then
                start_docker_nginx || {
                    echo -e "${YELLOW}Docker模式失败，尝试主机模式...${NC}"
                    start_host_nginx
                }
            else
                start_host_nginx
            fi
            ;;
    esac
}

# 执行主逻辑
main "$@"

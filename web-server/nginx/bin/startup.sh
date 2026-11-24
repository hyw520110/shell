#!/bin/bash
# nginx智能启动脚本 - 支持Docker模式和主机模式

# 获取脚本所在目录（兼容 macOS，避免依赖 GNU readlink -f）
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 导入公共函数库
if [ -f "$CURRENT_DIR/check_nginx_running.sh" ]; then
    source "$CURRENT_DIR/check_nginx_running.sh"
else
    echo -e "${RED}错误: 未找到公共函数库: $CURRENT_DIR/check_nginx_running.sh${NC}"
    exit 1
fi

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
        #echo -e "${YELLOW}Docker未安装，将使用主机模式启动${NC}"
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
    # 优先使用当前安装目录的nginx
    local nginx_paths=(
        "$BASE_DIR/sbin/nginx"
        "$HOME/nginx/sbin/nginx"
        "/usr/sbin/nginx"
        "/usr/bin/nginx"
        "/usr/local/bin/nginx"
        "/usr/local/nginx/sbin/nginx"
        "/opt/nginx/sbin/nginx"
        "/usr/local/openresty/nginx/sbin/nginx"
        "/opt/local/nginx/sbin/nginx"
        "/usr/local/opt/nginx/bin/nginx"  # macOS Homebrew
        "/snap/bin/nginx"  # Snap package
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

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

resolve_link_target() {
    local path="$1"
    local target
    target=$(readlink "$path") || return 1
    case "$target" in
        /*) echo "$target" ;;
        *) echo "$(cd "$(dirname "$path")" && cd "$(dirname "$target")" && pwd -P)/$(basename "$target")" ;;
    esac
}

# 尝试使用sudo执行命令
sudo_exec() {
    if command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "${RED}错误: 需要root权限但未找到sudo命令${NC}"
        return 1
    fi
}

# 启动主机模式Nginx
start_host_nginx() {
    echo -e "${GREEN}使用主机模式启动Nginx${NC}"
    
    local nginx_bin=$(find_nginx_executable)
    if [ -z "$nginx_bin" ]; then
        echo -e "${RED}错误: 未找到nginx执行文件${NC}"
        return 1
    fi
    
    echo -e "${GREEN}找到nginx执行文件: $nginx_bin${NC}"
    
    # 处理软链接情况：如果nginx是软链接，解析其真实路径
    local real_nginx_bin="$nginx_bin"
    if [ -L "$nginx_bin" ]; then
        real_nginx_bin=$(resolve_link_target "$nginx_bin")
        echo -e "${GREEN}解析软链接: $nginx_bin -> $real_nginx_bin${NC}"
        nginx_bin=$real_nginx_bin
    fi
    
    # 获取nginx真实路径的目录
    BASE_DIR=$(dirname $(dirname "$real_nginx_bin"))
    CONF_DIR="$BASE_DIR/conf"
    # 检查配置文件
    if [ ! -f "$CONF_DIR/nginx.conf" ]; then
        echo -e "${RED}错误: Nginx配置文件不存在: $CONF_DIR/nginx.conf${NC}"
        return 1
    fi
    echo -e "${GREEN}配置目录: $CONF_DIR${NC}"
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
    $nginx_bin -c "$CONF_DIR/nginx.conf" 2>/dev/null || sudo $nginx_bin -c "$CONF_DIR/nginx.conf"
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
        # 检查是否使用Docker插件模式 (Docker Compose V2)
        if ! docker compose version > /dev/null 2>&1; then
            echo -e "${YELLOW}Docker Compose未安装，尝试使用主机模式...${NC}"
            return 1
        else
            # 使用Docker Compose V2
            echo -e "${GREEN}检测到Docker Compose V2${NC}"
            local docker_compose_cmd="docker compose"
        fi
    else
        # 使用传统Docker Compose
        local docker_compose_cmd="docker-compose"
        # 检查版本兼容性
        local compose_version=$($docker_compose_cmd version --short 2>/dev/null)
        if [[ $compose_version =~ ^1\. ]]; then
            if [[ ${compose_version#1.} -lt 20 ]]; then
                echo -e "${YELLOW}Docker Compose版本过低 (${compose_version})，建议升级到1.20以上${NC}"
            fi
        fi
    fi
    
    # 处理Docker Compose配置
    handle_docker_compose "$compose_file"
    
    # 获取容器名称
    local container_name=$(grep "container_name:" "$compose_file" 2>/dev/null | awk '{print $2}' || echo "nginx")
    
    # 检查容器状态
    if $docker_compose_cmd ps | grep -v NAME | grep "$container_name" | grep -Ev "exited|restarting" > /dev/null 2>&1; then
        echo -e "${GREEN}Docker容器已在运行${NC}"
        $docker_compose_cmd ps
        return 0
    fi
    
    echo "启动Docker容器..."
    $docker_compose_cmd up -d
    sleep 5
    
    if $docker_compose_cmd ps | grep -v NAME | grep "$container_name" | grep -Ev "exited|restarting" > /dev/null 2>&1; then
        echo -e "${GREEN}Docker模式启动成功！${NC}"
        $docker_compose_cmd ps
        return 0
    else
        echo -e "${RED}Docker模式启动失败！${NC}"
        $docker_compose_cmd logs --tail=50
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
            # 检查是否已经存在当前IP
            local exists=$(find "$BASE_DIR/conf/conf.d/" -type f -name "*.conf" -exec grep -l "{{SERVER_IP}}" {} \; 2>/dev/null || echo "")
            if [ -n "$exists" ]; then
                echo -e "${GREEN}检测到配置文件中有IP占位符，当前服务器IP: $ip${NC}"
                read -p "是否替换配置文件中的IP占位符?(y/n，默认n)：" replace
                if [ "y" = "$replace" ]; then
                    echo "开始替换配置文件中的IP占位符..."
                    find "$BASE_DIR/conf/conf.d/" -type f -name "*.conf" \! -name "*.bak" \! -name "ip-black.conf" | while IFS= read -r f; do
                        if [ -f "$f" ]; then
                            # 只替换包含占位符的文件
                            if grep -q "{{SERVER_IP}}" "$f" 2>/dev/null; then
                                if [[ "$OSTYPE" == "darwin"* ]]; then
                                    sed -i '' "s/{{SERVER_IP}}/$ip/g" "$f"
                                else
                                    sed -i "s/{{SERVER_IP}}/$ip/g" "$f"
                                fi
                                echo "已替换: $f"
                            fi
                        fi
                    done
                    echo -e "${GREEN}IP占位符替换完成${NC}"
                fi
            #else
                #echo -e "${YELLOW}未找到包含IP占位符的配置文件${NC}"
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

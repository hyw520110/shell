#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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

# 停止主机模式Nginx
stop_host_nginx() {
    if check_host_nginx_running; then
        echo "停止主机模式Nginx进程..."
        local nginx_pids=""
        if check_root; then
            nginx_pids=$(pgrep nginx 2>/dev/null)
        else
            nginx_pids=$(sudo pgrep nginx 2>/dev/null)
        fi
        
        if [ -n "$nginx_pids" ]; then
            echo "找到Nginx进程: $nginx_pids"
            
            # 优雅停止
            echo "发送QUIT信号..."
            if check_root; then
                echo "$nginx_pids" | xargs kill -QUIT 2>/dev/null
            else
                echo "$nginx_pids" | xargs sudo kill -QUIT 2>/dev/null
            fi
            
            # 等待进程结束（最多等待10秒）
            echo "等待进程结束..."
            local count=0
            while [ $count -lt 10 ] && check_host_nginx_running; do
                sleep 1
                count=$((count + 1))
            done
            
            # 检查是否还有残留进程，强制杀死
            if check_host_nginx_running; then
                echo "进程未正常结束，强制终止..."
                if check_root; then
                    nginx_pids=$(pgrep nginx 2>/dev/null)
                    [ -n "$nginx_pids" ] && echo "$nginx_pids" | xargs kill -9 2>/dev/null
                else
                    nginx_pids=$(sudo pgrep nginx 2>/dev/null)
                    [ -n "$nginx_pids" ] && echo "$nginx_pids" | xargs sudo kill -9 2>/dev/null
                fi
            fi
        fi
        return 0
    else
        echo "未发现Nginx进程"
        return 1
    fi
}


# 停止Docker模式Nginx
stop_docker_nginx() {
    if command -v docker > /dev/null 2>&1 && command -v docker-compose > /dev/null 2>&1; then
        if check_docker_nginx_running; then
            echo "停止Docker模式Nginx容器..."
            if check_root; then
                docker-compose stop 2>/dev/null
            else
                sudo docker-compose stop 2>/dev/null
            fi
            return 0
        else
            echo "未发现运行中的Docker模式Nginx容器"
            return 1
        fi
    fi
    return 1
}
# 主逻辑
main() {
    # 显示当前进程状态
    show_nginx_status
    
    # 先停止主机模式进程，再停止Docker容器
    stop_host_nginx
    stop_docker_nginx
    
    # 再次显示状态
    sleep 2
    show_nginx_status
}

# 执行主逻辑
main "$@"
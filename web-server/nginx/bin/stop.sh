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
    # 检查是否有Nginx进程在运行
    if check_host_nginx_running; then
        echo "停止主机模式Nginx进程..."
        local nginx_master_pids=""
        local nginx_worker_pids=""
        
        # 获取master和worker进程ID
        if check_root; then
            nginx_master_pids=$(pgrep -f "nginx: master" 2>/dev/null)
            nginx_worker_pids=$(pgrep -f "nginx: worker" 2>/dev/null)
        else
            nginx_master_pids=$(sudo pgrep -f "nginx: master" 2>/dev/null)
            nginx_worker_pids=$(sudo pgrep -f "nginx: worker" 2>/dev/null)
        fi
        
        # 合并所有进程ID
        local nginx_pids="$nginx_master_pids $nginx_worker_pids"
        
        if [ -n "$nginx_pids" ]; then
            echo "找到Nginx进程: $nginx_pids"
            
            # 优雅停止
            echo "发送QUIT信号..."
            if check_root; then
                echo "$nginx_pids" | xargs kill -QUIT 2>/dev/null
            else
                echo "$nginx_pids" | xargs sudo kill -QUIT 2>/dev/null
            fi
            
            # 等待进程结束（最多等待15秒）
            echo "等待进程结束..."
            local count=0
            while [ $count -lt 15 ] && check_host_nginx_running; do
                sleep 1
                count=$((count + 1))
                # 每5秒显示一次状态
                if [ $((count % 5)) -eq 0 ]; then
                    echo "等待中... ($count/15秒)"
                fi
            done
            
            # 检查是否还有残留进程，强制杀死
            if check_host_nginx_running; then
                echo "进程未正常结束，强制终止..."
                if check_root; then
                    nginx_master_pids=$(pgrep -f "nginx: master" 2>/dev/null)
                    nginx_worker_pids=$(pgrep -f "nginx: worker" 2>/dev/null)
                    local remaining_pids="$nginx_master_pids $nginx_worker_pids"
                    [ -n "$remaining_pids" ] && echo "$remaining_pids" | xargs kill -9 2>/dev/null
                else
                    nginx_master_pids=$(sudo pgrep -f "nginx: master" 2>/dev/null)
                    nginx_worker_pids=$(sudo pgrep -f "nginx: worker" 2>/dev/null)
                    local remaining_pids="$nginx_master_pids $nginx_worker_pids"
                    [ -n "$remaining_pids" ] && echo "$remaining_pids" | xargs sudo kill -9 2>/dev/null
                fi
            else
                echo "Nginx进程已正常停止"
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
    if command -v docker > /dev/null 2>&1; then
        # 检查Docker守护进程是否运行
        if ! docker info > /dev/null 2>&1; then
            echo "Docker未启动"
            return 1
        fi
        
        # 确定使用的docker-compose命令
        local docker_compose_cmd=""
        if command -v docker-compose > /dev/null 2>&1; then
            docker_compose_cmd="docker-compose"
        elif docker compose version > /dev/null 2>&1; then
            docker_compose_cmd="docker compose"
        else
            echo "未找到docker-compose命令"
            return 1
        fi
        
        # 检查是否有运行中的Nginx容器
        if check_docker_nginx_running; then
            echo "停止Docker模式Nginx容器..."
            if check_root; then
                $docker_compose_cmd stop 2>/dev/null
            else
                sudo $docker_compose_cmd stop 2>/dev/null
            fi
            
            # 检查容器是否已停止
            sleep 2
            if ! check_docker_nginx_running; then
                echo "Docker模式Nginx容器已停止"
                return 0
            else
                echo "Docker模式Nginx容器停止失败"
                return 1
            fi
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
    
    # 先停止Docker容器，再停止主机模式进程
    stop_docker_nginx
    stop_host_nginx
    
    # 再次显示状态
    sleep 2
    show_nginx_status
}

# 执行主逻辑
main "$@"
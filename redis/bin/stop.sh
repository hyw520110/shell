#!/bin/bash
# 默认端口
# TODO 强制结束进程时判断是否需要提权
port=${1:-6379}
# 强制
force=${2}
# 优雅停止等待时间
wait=15
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

# 检查 Redis 是否已运行
is_running() {
    # 检查docker进程
    if [ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ] && [ `docker ps -a 2>/dev/null|grep redis|grep -v Exited|grep -v grep|wc -l` -gt 0 ]; then
        return 2 
    fi
    
    # 检查主机进程
    redis_server=$(ps -ef|grep redis-server|grep -v grep|awk '{print $8}'|head -1)
    if [ -n "$redis_server" ]; then
        CURRENT_DIR=$(dirname "$redis_server")
        BASE_DIR=$(dirname "$CURRENT_DIR")
        return 1
    fi
    
    # 检测端口
    if [ `netstat -tunlp 2>/dev/null |grep $port |grep -v grep| wc -l` -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

#结束进程 
stop(){
    is_running
    status=$?
    if [ $status -eq 2 ]; then
        if [ -f "$BASE_DIR/docker-compose.yml" ]; then
            docker-compose -f "$BASE_DIR/docker-compose.yml" stop
        else
            docker stop redis
        fi
    elif [ $status -eq 1 ]; then
    	if [ ! -f $BASE_DIR/bin/redis-cli ]; then
    		path=$(ps -ef|grep redis|grep -v grep|awk '{print $8}')
    		[ -n "$path" ] && CURRENT_DIR=$(dirname $path) && BASE_DIR=$(dirname $CURRENT_DIR)
    	fi
        # 优雅停止
        if [ -f "$BASE_DIR/bin/redis-cli" ]; then
            # 查找端口对应配置文件
            cnf=`find "$BASE_DIR/conf/" -name "redis.conf" 2>/dev/null `
            if [ -f "$cnf" ]; then
                isNum $port || port=$(grep "^port " "$cnf" | awk '{print $2}' | head -1)
                pwd=`cat "$cnf" 2>/dev/null |grep requirepass|grep -Ev "^#"|awk '{print $2}'`
                
                # 尝试优雅关闭
                if [ -n "$pwd" ]; then
                    "$BASE_DIR/bin/redis-cli" -p "$port" -a "$pwd" shutdown > /dev/null 2>&1 &
                else
                    "$BASE_DIR/bin/redis-cli" -p "$port" shutdown > /dev/null 2>&1 &
                fi
                
                echo "正在优雅停止 Redis (端口: $port)..."
                
                # 等待进程结束
                for i in $(seq 1 $wait); do
                    if ! pgrep -f "redis-server.*$port" > /dev/null 2>&1; then
                        echo "Redis 已停止"
                        return 0
                    fi
                    sleep 1
                done
                
                echo "优雅停止超时，将强制终止进程"
            fi
        fi
        pids=$(ps -ef|grep redis|grep -v grep |awk '{print $2}')
        # 强制停止
        if [ "$force" = "-f" ] || [ -n "$pids" ]; then
            echo "强制终止 Redis 进程: $pids"
            kill -9 $pids 2>/dev/null
        fi
    else
        echo "Redis 未运行"
    fi
}

isNum(){
    echo "$1" | grep -E '^[0-9]+$' > /dev/null
    return $?
}

# 停止
stop
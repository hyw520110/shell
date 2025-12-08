#!/bin/bash

# 从配置文件中提取端口号
SW_PORT=$(grep 'serverPort:' ../webapp/application.yml | awk -F': ' '{print $2}' | sed 's/[^0-9]//g')
# 检查是否成功提取到端口号
if [ -z "$SW_PORT" ]; then
    echo "配置文件中未找到服务端口号。"
    exit 1
fi

# 查找 SkyWalking OAP 服务的 PID
PID=$(lsof -t -i:$SW_PORT -sTCP:LISTEN | grep java | awk '{print $1}')

# 检查是否找到了 PID
if [ -z "$PID" ]; then
    echo "SkyWalking webapp 服务未运行。"
else

    echo "SkyWalking webapp 服务运行在端口：$SW_PORT"

    # 尝试优雅地停止服务
    echo "正在停止 SkyWalking webapp 服务，进程 ID：$PID"
    kill -15 $PID

    # 等待服务停止
    sleep 5

    # 检查服务是否已经停止
    if ps -p $PID > /dev/null 2>&1; then
        echo "服务未能优雅停止，正在强制关闭。"
        kill -9 $PID
    else
        echo "服务已成功停止。"
    fi
fi

oap_port=$(ps -ef|grep oap|grep java|grep -v grep|awk '{print $2}')

if [ -n "$oap_port" ]; then
    echo "oap_port: $oap_port"
    kill -15 $oap_port
    sleep 5
    kill -9 $oap_port
fi
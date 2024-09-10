#!/bin/bash

# 获取当前脚本的绝对路径
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
PROXY_PORT="38080"
PROXY_LOG="proxy.log"

# 检查是否已安装 proxy
if [ ! -x "/usr/bin/proxy" ]; then
    echo "未检测到 proxy，现在开始自动安装..."
    bash "$INSTALL_SCRIPT"
    if [ $? -ne 0 ]; then
        echo "安装失败，请手动检查并安装 proxy。"
        exit 1
    fi
fi

# 检查端口是否被占用
if netstat -tuln | grep -q ":$PROXY_PORT "; then
    echo "端口 $PROXY_PORT 已被占用，请检查是否有其他服务正在使用此端口。"
    exit 1
fi

# 判断服务是否已启动
if pgrep -x "proxy" > /dev/null; then
    echo "proxy 服务已启动。"
else
    # 启动服务
    echo "启动 proxy 服务..."
    proxy http -t tcp -p "0.0.0.0:$PROXY_PORT" --forever --log "$PROXY_LOG" --daemon
    if [ $? -eq 0 ]; then
        echo "proxy 服务已启动。"
    else
        echo "启动 proxy 服务失败，请检查日志文件。"
        exit 1
    fi
fi

# 查看实时日志
echo "查看实时日志..."
tail -f "$PROXY_LOG"

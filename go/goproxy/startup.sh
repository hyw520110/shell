#!/bin/bash

# 获取当前脚本的绝对路径
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
PROXY_PORT="7898"
PROXY_LOG="proxy.log"

# 公网 IP 查询 URL 列表
PUBLIC_IP_URLS=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "http://checkip.amazonaws.com"
    "http://ipv4.ident.me"
    "http://ipecho.net/plain"
    "http://myip.ipip.net"
)

# 检查是否已安装 proxy
ensure_installed() {
    if [ ! -x "/usr/bin/proxy" ]; then
        echo "未检测到 proxy，现在开始自动安装..."
        bash "$INSTALL_SCRIPT"
        if [ $? -ne 0 ]; then
            echo "安装失败，请手动检查并安装 proxy。"
            exit 1
        fi
    fi
}

# 检查端口是否被占用
check_port() {
    if command -v netstat &> /dev/null; then
        # 使用 netstat 检查端口
        if netstat -tuln | grep -q ":$1 "; then
            return 0
        fi
    elif command -v lsof &> /dev/null; then
        # 使用 lsof 检查端口
        if lsof -i :$1 &> /dev/null; then
            return 0
        fi
    else
        echo "既没有安装 netstat 也没有安装 lsof，无法检查端口占用情况。"
        exit 1
    fi
    return 1
}

# 获取公网 IP 地址
get_public_ip() {
    # 尝试使用 dig 获取公网 IP
    public_ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return 0
    fi

    # 如果 dig 失败，尝试使用 HTTP 请求
    for url in "${PUBLIC_IP_URLS[@]}"; do
        public_ip=$(curl -s "$url")
        if [ -n "$public_ip" ]; then
            echo "$public_ip"
            return 0
        fi
    done

    # 如果所有方法都失败
    echo "无法获取公网 IP 地址。"
    return 1
}


ensure_installed

# 检查端口是否被占用
if check_port "$PROXY_PORT"; then
    echo "端口 $PROXY_PORT 已被占用，请检查是否有其他服务正在使用此端口。"
    exit 1
fi

# 判断服务是否已启动
if pgrep -x "proxy" > /dev/null; then
    echo "proxy 服务已启动。"
    exit 0
fi

# 获取公网 IP 地址
public_ip=$(get_public_ip)
# 启动服务
echo "启动 proxy 服务..."
if [ $? -eq 0 ]; then
    echo "当前公网IP: $public_ip"
    proxy http -t tcp -g "$public_ip" -p "0.0.0.0:$PROXY_PORT" --forever --log "$PROXY_LOG" --daemon
else
    proxy http -t tcp -p "0.0.0.0:$PROXY_PORT" --forever --log "$PROXY_LOG" --daemon
fi

if [ $? -eq 0 ]; then
    echo "proxy 服务已启动。"
else
    echo "启动 proxy 服务失败，请检查日志文件。"
    exit 1
fi

# 查看实时日志
echo "查看实时日志..."
tail -f "$PROXY_LOG"

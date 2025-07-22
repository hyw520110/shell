#!/bin/bash

# 获取本机IP地址
get_local_ip() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        ip=$(ipconfig getifaddr en0)
    else
        # Linux
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

# 检查IP和端口是否可达
check_ip_port() {
    local ip=$1
    local port=$2
    
    # 检查IP格式
    if ! [[ "$ip" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    # 检查端口连接
    if command -v nc &> /dev/null; then
        timeout 3 nc -zv $ip $port &> /dev/null
    else
        # 使用bash内置功能检查端口
        (echo > /dev/tcp/$ip/$port) &> /dev/null
    fi
}

# 获取用户输入的IP和端口
get_user_ip_port() {
    while true; do
        read -p "请输入Ollama的IP地址和端口(例如 192.168.0.104:11434): " ip_port
        if [[ "$ip_port" =~ ^([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}):([0-9]{1,5})$ ]]; then
            echo "$ip_port"
            return
        else
            echo "输入格式错误，请使用IP:PORT格式"
        fi
    done
}

# 主函数
main() {
    local ip_port="$1"
    
    # 如果未指定IP和端口，则使用本机IP
    if [ -z "$ip_port" ]; then
        ip=$(get_local_ip)
        ip_port="$ip:11434"
    fi
    
    # 分割IP和端口
    ip=$(echo $ip_port | cut -d: -f1)
    port=$(echo $ip_port | cut -d: -f2)
    
    # 验证IP和端口直到成功
    while ! check_ip_port $ip $port; do
        echo "无法连接到 $ip:$port"
        ip_port=$(get_user_ip_port)
        ip=$(echo $ip_port | cut -d: -f1)
        port=$(echo $ip_port | cut -d: -f2)
    done
    
    echo "成功连接到 Ollama 服务: $ip_port"
    
    # 循环获取用户输入并调用API
    while true; do
        read -p "请输入您的问题(输入'exit'退出): " prompt
        if [ "$prompt" = "exit" ]; then
            break
        fi
        
        if [ -n "$prompt" ]; then
            api_url="http://$ip:$port/api/generate"
            response=$(curl -s -X POST $api_url -H "Content-Type: application/json" -d '{
                "model": "gema3:4b",
                "prompt": "$prompt",
                "stream": false,
                "option": {
                    "num_ctx": 4096
                }
            }')
            
            echo "
响应结果:"
            echo "$response" | jq -r '.response'
            echo ""
        fi
    done
}

# 脚本入口
if [ $# -gt 1 ]; then
    echo "用法: $0 [IP:PORT]"
    exit 1
fi

main $1
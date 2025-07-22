#!/bin/bash

# ollama_client.sh - 用于连接和测试Ollama服务的客户端脚本
# 用途: 测试Ollama服务连接并进行简单的文本生成交互
# 参数: 可选的IP:PORT参数指定Ollama服务地址，默认使用本机IP:11434
# 版本: 1.0
# 作者: 你的名字
# 使用示例:
#   ./ollama_client.sh            # 使用本机IP:11434连接
#   ./ollama_client.sh 192.168.1.100:11434  # 使用指定IP和端口连接

# 如果任何命令失败则立即退出
set -e

# 获取本机IP地址
# 输出: 返回本机IP地址
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
# 参数:
#   $1 - IP地址
#   $2 - 端口号
# 输出:
#   0 - 可达
#   1 - 不可达
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
# 输出:
#   格式正确的IP:PORT字符串
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

# 获取Ollama模型列表
# 参数:
#   $1 - Ollama服务地址（IP:PORT）
# 输出:
#   模型名称列表
get_ollama_models() {
    local ip_port="$1"
    local api_url="http://$ip_port/api/tags"
    
    # 获取模型列表
    local response=$(curl -s -X GET $api_url)
    
    # 检查curl是否执行成功
    if [ $? -ne 0 ]; then
        echo "错误: 无法连接到Ollama服务"
        exit 1
    fi
    
    # 解析响应获取模型名称列表
    echo "$response" | jq -r '.models[].name'
}

# 信号处理函数
handle_signal() {
    echo "
捕获到中断信号，退出程序"
    exit 1
}

# 捕获中断信号
trap handle_signal INT TERM

# 主函数
# 参数:
#   $1 - 可选的IP:PORT参数
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

    # 获取模型列表
    local models=$(get_ollama_models $ip_port)
    
    # 检查是否获取到模型列表
    if [ -z "$models" ]; then
        echo "错误: 无法获取Ollama模型列表"
        exit 1
    fi
    
    # 将模型列表转换为数组
    IFS=$'\n' read -d '' -r -a model_array <<< "$models"
    
    # 获取模型数量
    local model_count=${#model_array[@]}
    
    # 如果只有一个模型，自动选择
    if [ $model_count -eq 1 ]; then
        selected_model=${model_array[0]}
        echo "自动选择唯一模型: $selected_model"
    else
        # 显示模型列表并提示用户选择
        echo "可用模型列表:"
        for i in "${!model_array[@]}"; do
            echo "$((i+1))). ${model_array[$i]}"
        done
        
        # 提示用户选择
        while true; do
            read -p "请选择模型编号(1-$model_count): " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le $model_count ]; then
                selected_model=${model_array[$((choice-1))]}
                break
            else
                echo "输入无效，请输入1到$model_count之间的数字"
            fi
        done
    fi

    echo "使用模型: $selected_model"

    # 循环获取用户输入并调用API
    while true; do
        read -p "请输入您的问题(输入'exit'退出): " prompt
        if [ "$prompt" = "exit" ]; then
            echo "退出程序"
            exit 0
        fi

        if [ -n "$prompt" ]; then
            api_url="http://$ip:$port/api/generate"
            response=$(curl -s -X POST $api_url -H "Content-Type: application/json" -d '{
                "model": "$selected_model",
                "prompt": "$prompt",
                "stream": false,
                "option": {
                    "num_ctx": 4096
                }
            }')

            # 检查curl是否执行成功
            if [ $? -ne 0 ]; then
                echo "错误: 无法连接到Ollama服务"
                exit 1
            fi

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
    echo "示例:"
    echo "  $0                # 使用本机IP:11434连接"
    echo "  $0 192.168.1.100:11434  # 使用指定IP和端口连接"
    exit 1
fi

main $1
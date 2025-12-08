#!/bin/bash

# ollama_cli.sh - 用于连接和测试Ollama服务的客户端脚本
# 用途: 测试Ollama服务连接并进行简单的文本生成交互
# 参数: 可选的IP:PORT参数指定Ollama服务地址，默认使用本机IP:11434
# 版本: 1.0
# 作者: 你的名字
# 使用示例:
#   ./ollama_cli.sh            # 使用本机IP:11434连接
#   ./ollama_cli.sh 192.168.1.100:11434  # 使用指定IP和端口连接
#   ./ollama_cli.sh -s false   # 禁用流式输出

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
        # 如果hostname -I命令没有返回结果，尝试其他方法
        if [ -z "$ip" ]; then
            ip=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
        fi
        # 如果还是没有获取到IP，使用ifconfig
        if [ -z "$ip" ]; then
            ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1)
        fi
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
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && [ "$ip" != "localhost" ]; then
        # 不是IPv4格式也不是localhost，可能是IPv6
        if command -v nc &> /dev/null; then
            timeout 3 nc -z -6 "$ip" $port &> /dev/null
            return $?
        else
            # 使用bash内置功能检查端口
            (echo > /dev/tcp/[$ip]/$port) &> /dev/null
            return $?
        fi
    fi

    # IPv4或localhost的情况
    if command -v nc &> /dev/null; then
        timeout 3 nc -z "$ip" $port &> /dev/null
        return $?
    else
        # 使用bash内置功能检查端口
        (echo > /dev/tcp/$ip/$port) &> /dev/null
        return $?
    fi
}

# 获取用户输入的IP和端口
# 输出:
#   格式正确的IP:PORT字符串
get_user_ip_port() {
    while true; do
        read -p "请输入Ollama的IP地址和端口(例如 192.168.0.104:11434): " ip_port
        if [[ "$ip_port" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}):([0-9]{1,5})$ ]] || [[ "$ip_port" == "localhost:"[0-9]* ]]; then
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

# 获取系统可用内存（GB）
# 输出: 返回系统可用内存大小（GB）
get_available_memory() {
    if command -v free &> /dev/null; then
        # 使用free命令获取可用内存（以GB为单位）
        available_mem_gb=$(free -g | awk '/^Mem:/{print $7}')
        echo "$available_mem_gb"
    else
        # 如果没有free命令，尝试其他方法
        echo "0"
    fi
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [IP:PORT] [-s|--stream true|false]"
    echo ""
    echo "Ollama客户端脚本，用于与Ollama服务进行交互"
    echo ""
    echo "参数说明:"
    echo "  IP:PORT               Ollama服务地址，默认为localhost:11434"
    echo "  -s, --stream [true|false] 是否启用流式输出，默认为true"
    echo "  --help                显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                     # 使用localhost:11434连接，启用流式输出"
    echo "  $0 192.168.1.100:11434 # 使用指定IP和端口连接，启用流式输出"
    echo "  $0 -s false            # 使用localhost:11434连接，禁用流式输出"
    echo "  $0 192.168.1.100:11434 -s false # 使用指定IP和端口连接，禁用流式输出"
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
#   $@ - 命令行参数
main() {
    local ip_port=""
    local stream=true
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--stream)
                if [[ "$2" == "false" || "$2" == "true" ]]; then
                    stream=$2
                    shift 2
                else
                    stream=true
                    shift
                fi
                ;;
            --help)
                show_help
                exit 0
                ;;
            -*)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$ip_port" ]]; then
                    ip_port="$1"
                fi
                shift
                ;;
        esac
    done

    # 如果未指定IP和端口，则使用localhost（因为Ollama服务监听在0.0.0.0）
    if [ -z "$ip_port" ]; then
        ip_port="localhost:11434"
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
        echo "警告: 未找到任何模型"
        echo "请确保已拉取至少一个模型，例如: ollama pull qwen3:8b"
        exit 0
    fi
    
    # 将模型列表转换为数组
    local model_array=()
    while IFS= read -r line; do
        model_array+=("$line")
    done <<< "$models"
    
    # 获取模型数量
    local model_count=${#model_array[@]}
    
    # 获取系统可用内存
    local available_mem=$(get_available_memory)
    
    # 如果只有一个模型，自动选择
    if [ $model_count -eq 1 ]; then
        selected_model=${model_array[0]}
        echo "自动选择唯一模型: $selected_model"
        # 检查模型名称是否可能需要大量内存
        if [[ "$selected_model" == *"qwen3"* || "$selected_model" == *"llama3"* || "$selected_model" == *"deepseek"* ]] && [ "$available_mem" -lt 32 ] 2>/dev/null; then
            echo "注意: 检测到您的系统内存为 ${available_mem}GB，所选模型可能需要更多内存才能正常运行"
        fi
    else
        # 显示模型列表并提示用户选择
        echo "可用模型列表 (系统可用内存: ${available_mem}GB):"
        for i in "${!model_array[@]}"; do
            model_name="${model_array[$i]}"
            # 为可能需要大量内存的模型添加提示
            if [[ "$model_name" == *"qwen3"* || "$model_name" == *"llama3"* || "$model_name" == *"deepseek"* ]] && [ "$available_mem" -lt 32 ] 2>/dev/null; then
                echo "$((i+1))). ${model_name} (注意: 可能需要大量内存)"
            else
                echo "$((i+1))). ${model_name}"
            fi
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

    # 显示流式输出状态
    if [ "$stream" = true ]; then
        echo "使用模型: $selected_model (流式输出已启用)"
    else
        echo "使用模型: $selected_model (流式输出已禁用)"
    fi

    # 循环获取用户输入并调用API
    while true; do
        read -p "请输入您的问题(输入'exit'退出): " prompt
        if [ "$prompt" = "exit" ]; then
            echo "退出程序"
            exit 0
        fi

        if [ -n "$prompt" ]; then
            api_url="http://$ip:$port/api/generate"
            
            # 根据stream参数决定调用方式
            if [ "$stream" = true ]; then
                echo "
响应结果:"
                # 流式输出处理
                curl -s -N -X POST "$api_url" -H "Content-Type: application/json" -d "{\"model\":\"$selected_model\",\"prompt\":\"$prompt\",\"stream\":true,\"options\":{\"num_ctx\":4096}}" | \
                while IFS= read -r line; do
                    # 检查是否有错误
                    if echo "$line" | jq -e .error >/dev/null 2>&1; then
                        echo "API调用出错:"
                        echo "$line" | jq -r '.error'
                        break
                    fi
                    
                    # 提取响应内容
                    content=$(echo "$line" | jq -r '.response // empty')
                    if [ -n "$content" ]; then
                        printf "%s" "$content"
                    fi
                    
                    # 检查是否完成
                    if echo "$line" | jq -e .done >/dev/null 2>&1; then
                        if echo "$line" | jq -r .done | grep -q true; then
                            echo ""  # 添加换行
                            break
                        fi
                    fi
                done
            else
                # 非流式输出处理
                response=$(curl -s -X POST "$api_url" -H "Content-Type: application/json" -d "{\"model\":\"$selected_model\",\"prompt\":\"$prompt\",\"stream\":false,\"options\":{\"num_ctx\":4096}}")

                # 检查curl是否执行成功
                if [ $? -ne 0 ]; then
                    echo "错误: 无法连接到Ollama服务"
                    continue
                fi

                # 检查响应中是否有错误信息
                if echo "$response" | jq -e .error >/dev/null 2>&1; then
                    echo "API调用出错:"
                    error_msg=$(echo "$response" | jq -r '.error')
                    echo "$error_msg"
                    
                    # 如果是内存不足的错误，提供解决方案建议
                    if [[ "$error_msg" == *"memory"* ]]; then
                        echo ""
                        echo "提示: 您可以尝试以下解决方案:"
                        echo "1. 使用更小的模型，例如: gemma:2b, phi3:3.8b"
                        echo "2. 拉取量化版本的模型，例如: qwen3:0.5b 或 qwen3:1.8b"
                        echo "3. 增加系统交换空间"
                        echo "4. 调整模型参数，如减小 num_ctx 值"
                    fi
                    continue
                fi

                echo "
响应结果:"
                echo "$response" | jq -r '.response'
            fi
            echo ""
        fi
    done
}

# 脚本入口
if [ $# -gt 4 ]; then
    show_help
    exit 1
fi

main "$@"
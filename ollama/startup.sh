#!/bin/bash
set -euo pipefail

# 定义下载目录变量
DOWNLOAD_DIR="${HOME}/Downloads"
MODEL_DIR="${HOME}/.ollama/models"

# 设置环境变量
export OLLAMA_HOST=0.0.0.0
export OLLAMA_PORT=11434
export OLLAMA_MODELS=$MODEL_DIR
export OLLAMA_DEBUG=1

# 检查ollama服务是否已启动
check_ollama_service() {
    # 检查端口是否监听
    if ! nc -z "$OLLAMA_HOST" "$OLLAMA_PORT" 2>/dev/null; then
        return 1
    fi
    
    # 检查服务是否响应
    if curl -s --connect-timeout 3 http://$OLLAMA_HOST:$OLLAMA_PORT >/dev/null; then
        echo "ollama服务已启动"
        return 0
    else
        return 1
    fi
}

# 下载文件函数
download_file() {
    local url=$1
    local output=$2
    
    # 检查文件是否已存在且大小正常
    if [ -f "$output" ] && [ -s "$output" ]; then
        echo "文件已存在且大小正常，跳过下载: $output"
        return 0
    fi
    
    echo "正在下载: $url"
    wget -c "$url" -O "$output"
    return $?
}

# 安装启动 ollama
start_ollama() {
    # 尝试Docker方式启动
    if command -v docker &> /dev/null; then
        if docker info > /dev/null 2>&1; then
            # 检查Ollama容器状态
            if docker ps --filter "name=ollama" --filter "status=running" | grep -q ollama; then
                echo "ollama容器已在运行"
                return 0
            fi

            # 检查是否存在已停止的ollama容器
            if docker ps -a --filter "name=ollama" | grep -q ollama; then
                echo "启动已存在的ollama容器..."
                docker start ollama && echo "ollama容器已启动" && return 0
            fi

            # 尝试使用docker-compose启动
            if command -v docker-compose &>/dev/null && [ -f "docker-compose.yml" ]; then
                echo "使用docker-compose启动ollama..."
                docker-compose up -d && echo "ollama容器已启动" && return 0
            fi


        else
            echo "Docker服务未启动，将尝试主机安装"
        fi
    fi
    # 主机安装
    if ! command -v ollama &> /dev/null; then
        # 判断是否是macos系统
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # 获取最新版本的下载链接
            url=$(wget -q -O- https://api.github.com/repos/ollama/ollama/releases/latest | grep browser_download_url | grep darwin.zip | awk -F': ' '{print $2}' | tr -d '"')
            zip_file=$(basename "$url")
            
            # 下载文件
            if [ ! -f "$DOWNLOAD_DIR/$zip_file" ]; then
                download_file "$url" "$DOWNLOAD_DIR/$zip_file" || {
                    echo "下载失败，请检查网络连接"
                    return 1
                }
            fi
            
            # 解压并安装应用
            if [ ! -d /Applications/Ollama.app/Contents ]; then
                echo "正在安装ollama..."
                unzip "$DOWNLOAD_DIR/$zip_file" -d /Applications/ || {
                    echo "解压失败，请检查文件完整性"
                    rm -f "$DOWNLOAD_DIR/$zip_file"
                    return 1
                }
            fi
            
            # 确保命令行可用
            if ! ollama --version >/dev/null 2>&1; then
                echo "首次启动Ollama应用以完成安装..."
                open /Applications/Ollama.app
                # 等待应用启动
                sleep 10
            }
        else
            echo "开始安装ollama..."
            wget -c  https://ollama.com/install.sh && sh install.sh || {
					url=https://ollama.com/download/ollama-linux-amd64.tgz
					file_name=$(basename $url)
                    if [ ! -f "$DOWNLOAD_DIR/$file_name" ]; then
                    download_file $url "$DOWNLOAD_DIR/$file_name" || {
                        echo "下载ollama-linux-amd64.tgz失败，请检查网络连接"
                        return 1
                    }
                fi
                sudo tar -C /usr -xzf "$DOWNLOAD_DIR/$file_name"
            }
        fi
    fi
    [ $? -ne 0 ] && echo "ollama安装失败，访问:https://ollama.com/download 下载安装" && exit 1
    if command -v systemctl &> /dev/null; then
        if ! sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
	        echo "启动ollama服务..."
	        sudo systemctl start ollama.service 2>/dev/null
	        sleep 5
	    fi
    fi

    # 检查并启动ollama服务
    if ! check_ollama_service; then
        echo "正在启动ollama服务..."
        nohup ollama serve > ollama.log 2>&1 &
        # 等待服务启动
        for i in {1..10}; do
            if check_ollama_service; then
                echo "ollama服务已启动"
                return 0
            fi
            sleep 1
        done
        echo "ollama服务启动失败，请查看ollama.log了解详情"
        return 1
    fi
    return 0
    ollama list
}

# 检查并安装 tmux
install_tmux() {
    if ! command -v tmux &> /dev/null; then
        echo "正在安装 tmux..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
         	brew install tmux
        elif command -v apt &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif command -v yum &> /dev/null; then
            sudo yum install -y tmux
        else
            echo "请手动安装 tmux。"
            exit 1
        fi
    fi
}
# 在 tmux 中启动模型会话（如果尚未运行），并在需要时拉取模型
start_model_in_tmux() {
    local model_full_name=$1
    local model_name=$(echo "$model_full_name" | cut -d':' -f1)
    local param_size=$(echo "$model_full_name" | cut -d':' -f2)
    local session_name="$model_name"
    local model_command="ollama run $model_full_name"

    # 拉取模型（如果尚未存在）
    if ! ollama list | grep -v NAME | grep -q "$model_full_name"; then
        echo "正在拉取模型 $model_full_name..."
        ollama pull $model_full_name
        if [ $? -ne 0 ]; then
            echo "模型 $model_full_name 拉取失败,如报错412表示需要升级ollama版本" && exit 1
        fi
    fi

    # 启动模型会话（如果尚未运行）
    if ! pgrep -f "$model_command" > /dev/null; then
        install_tmux
        tmux new-session -d -s "$session_name" "bash -c \"$model_command; exec bash\""
        echo "要连接到 $session_name 会话，请执行：tmux attach-session -t $session_name"
    fi
}


# 示例 API 调用
demo_api_call() {
    local api_url="http://$OLLAMA_HOST:$OLLAMA_PORT/api/generate"
    local model=$(ollama list | grep -v NAME | head -n 1 | awk '{print $1}')
    echo "调用 $model 进行文本生成:"
    local command="curl -X POST $api_url -H \"Content-Type: application/json\" -d  '{\"model\": \"$model\",\"prompt\": \"天为什么那么蓝?\",\"stream\": false,\"options\": {\"num_ctx\": 4096}}'"
    echo "$command"
    # eval $command
}

# 主程序流程
main() {
    start_ollama

    main() {
        start_ollama

        # 模型检测与用户输入处理
        if ollama list | grep -v NAME | grep -q .; then
        echo "本地已存在模型，模型列表如下："
        ollama list
    else
        read -t 15 -p "本地未检测到模型，请输入模型名称及参数量（如qwen3:8b, deepseek-r1:8b或llama3:8b, 15秒后使用默认值qwen3:8b）：" model_input
        model_input=${model_input:-qwen3:8b}
        echo "使用模型：$model_input"
        start_model_in_tmux "$model_input"
    fi
    # 打印监听端口和进程信息
    lsof -i:11434
    ollama ps
    demo_api_call
}

main
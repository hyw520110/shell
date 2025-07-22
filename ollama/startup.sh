#!/bin/bash

# 定义下载目录变量
DOWNLOAD_DIR="${HOME}/Downloads"
MODEL_DIR="${HOME}/.ollama/models"

# 设置环境变量
export OLLAMA_HOST=0.0.0.0
export OLLAMA_PORT=11434
export OLLAMA_MODELS=$MODEL_DIR
export OLLAMA_DEBUG=1

# 安装启动 ollama
start_ollama() {
    if command -v docker &> /dev/null; then
        # 基于Docker容器端口或容器状态检查 是否正在运行，
        if docker info > /dev/null 2>&1 ; then
            if docker ps 2>/dev/null | grep ollama | grep Up >/dev/null 2>&1 ; then
               echo "ollama服务已在运行" && exit 0
            fi
          if command -v docker-compose &>/dev/null ; then
              docker-compose up -d
            [ $? -eq 0 ] && echo "ollama服务已启动"  && exit 0
          else
            echo "docker-compose未安装" && exit 1
          fi
      fi
    fi
    # docker未启动则主机安装
    if ! command -v ollama &> /dev/null; then
	    # 判断是否是macos系统
        if [[ "$OSTYPE" == "darwin"* ]]; then
           url=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest | grep browser_download_url|grep darwin.zip|awk -F': ' '{print $2}' | tr -d '"')
           zip_file=$(basename $url | tr -d '"')
           [ ! -f $DOWNLOAD_DIR/$zip_file ] && wget https://github.com/ollama/ollama/releases/download/v0.9.2/ollama-darwin.zip -O $DOWNLOAD_DIR/$zip_file
           [ ! -d /Applications/Ollama.app/Contents ] && unzip $DOWNLOAD_DIR/$zip_file -d /Applications/
           # 第一次要打开应用，执行安装后ollama命令行才能用
           [ ! -d /Applications/Ollama.app/Contents ] && echo "ollama安装失败，请手动安装" && exit 1
           ollama --version 2>/dev/null || open /Applications/Ollama.app
        else
           echo "开始安装 ollama..."
           curl -fsSL https://ollama.com/install.sh | sh
           [ $? -ne 0 ] && wget -c --no-check-certificate https://ollama.com/download/ollama-linux-amd64.tgz -O $DOWNLOAD_DIR/ollama-linux-amd64.tgz && sudo tar -C /usr -xzf $DOWNLOAD_DIR/ollama-linux-amd64.tgz
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

    # 如果 systemd 服务未启动，则使用 nohup 启动 ollama serve
    if ! pgrep -f 'ollama serve' > /dev/null; then
        nohup ollama serve > ollama.log 2>&1 &
        sleep 5
    fi
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

    # 模型检测与用户输入处理
    if ollama list | grep -v NAME | grep -q .; then
        echo "本地已存在模型，模型列表如下："
        ollama list
    else
        read -t 5 -p "本地未检测到模型，请输入模型名称及参数量（如qwen3:8b或deepseek-r1:8b,5秒后使用默认值qwen3:8b）：" model_input
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
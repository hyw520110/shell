#!/bin/bash

# 设置环境变量
export OLLAMA_HOST=0.0.0.0
export OLLAMA_PORT=11434
export OLLAMA_MODELS=/opt/ollama/models
export OLLAMA_DEBUG=1

# 检查并安装 tmux
install_tmux() {
    if ! command -v tmux &> /dev/null; then
        echo "正在安装 tmux..."
        if [ -x "$(command -v apt)" ]; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif [ -x "$(command -v yum)" ]; then
            sudo yum install -y tmux
        else
            echo "请手动安装 tmux。"
            exit 1
        fi
    fi
}

# 检查并安装 ollama
install_ollama() {
    if ! command -v ollama &> /dev/null; then
        echo "正在安装 ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi
}

# 启动 ollama serve 如果没有运行
start_ollama_serve() {
    # 检查 systemd 服务是否正在运行
    if ! sudo systemctl is-active --quiet ollama.service; then
        echo "Starting ollama systemd service..."
        sudo systemctl start ollama.service
        sleep 5
    fi

    # 如果 systemd 服务未启动，则使用 nohup 启动 ollama serve
    if ! pgrep -f 'ollama serve' > /dev/null; then
        nohup ollama serve > ollama.log 2>&1 &
        sleep 5
    fi
    ollama list
}

# 在 tmux 中启动模型会话（如果尚未运行），并在需要时拉取模型
start_model_in_tmux() {
    local session_name=$1
    local model=$2
    local model_command="ollama run $model"

    # 拉取模型（如果尚未存在）
    if ! ollama list | grep -q "$model"; then
        ollama pull "$model" || { echo "拉取 $model 失败"; return 1; }
    fi

    # 启动模型会话（如果尚未运行）
    if ! pgrep -f "$model_command" > /dev/null; then
        tmux new-session -d -s "$session_name" "bash -c \"$model_command; exec bash\""
        echo "要连接到 $session_name 会话，请执行：tmux attach-session -t $session_name"
    fi
}

demo_api_call() {
    local api_url="http://localhost:11434/api/generate"
    model=$(ollama list | grep -v NAME | head -n 1|awk '{print $1}')
    echo "调用$model 进行文本生成:"
    local command='curl -X POST "'$api_url'" -H "Content-Type: application/json" -d '\''{"model": "'$model'","prompt": "天为什么那么蓝?","stream": false,"options": {"num_ctx": 4096}}'\'

    echo "$command"
    # eval $command
}

# 主程序流程
main() {
    install_tmux
    install_ollama
    start_ollama_serve
    
    # 启动模型会话并拉取模型
    start_model_in_tmux "qwen2" "qwen2.5-coder:7b"
    start_model_in_tmux "deepseek" "deepseek-r1:7b"

    # 打印监听端口和进程信息
    lsof -i:11434
    ollama ps

    # 示例 API 调用
    demo_api_call
}

main
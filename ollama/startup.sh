#!/bin/bash
set -euo pipefail

# 定义下载目录变量
DOWNLOAD_DIR="${HOME}/Downloads"
MODEL_DIR="${HOME}/.ollama/models"
MODEL_NAME=${1:-}
readonly DEFAULT_MODEL="qwen3:8b"
# 设置环境变量
export OLLAMA_HOST=0.0.0.0
export OLLAMA_PORT=11434
# 模型目录，默认为空。
export OLLAMA_MODELS=$MODEL_DIR
# 是否开启调试模式，默认为 false。
export OLLAMA_DEBUG=1
# 保持连接的时间，默认为 5m。
export OLLAMA_KEEP_ALIVE=24h
# 并行数，默认为 1。
export OLLAMA_NUM_PARALLEL=100
# 最大加载模型数，默认为 1。
export OLLAMA_MAX_LOADED_MODELS=4
# 调度分布，默认为空。
export OLLAMA_SCHED_SPREAD=1
# 是否闪烁注意力，默认为 true。
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_ACCELERATE=1

#OLLAMA_LLM_LIBRARY：LLM 库，默认为空。
#OLLAMA_MAX_QUEUE：最大队列数，默认为空。
#OLLAMA_MAX_VRAM：最大虚拟内存，默认为空。
#OLLAMA_NOHISTORY：是否保存历史记录，默认为 false。
#OLLAMA_NOPRUNE：是否启用剪枝，默认为 false。
#OLLAMA_ORIGINS：允许的来源，默认为空。
#OLLAMA_RUNNERS_DIR：运行器目录，默认为空。
#OLLAMA_TMPDIR：临时文件目录，默认为空。

# 检查ollama服务是否已启动
check_ollama_service() {
    # 检查端口是否监听
    if  nc -z "$OLLAMA_HOST" "$OLLAMA_PORT" 2>/dev/null; then
        return 0
    fi
    # 检查服务是否响应
    if curl -s --connect-timeout 3 http://$OLLAMA_HOST:$OLLAMA_PORT >/dev/null; then
        return 0
    else
        return 1
    fi
}


# 通用下载函数
# 参数:
#   $1 - 下载链接
#   $2 - 下载目录
#   $3 - 重试次数（可选，默认3次）
#   $4 - 超时时间（可选，默认无）
# 输出:
#   0 - 下载成功
#   1 - 下载失败
download_file() {
    local url="$1"
    local download_dir="$2"
    local max_retries=${3:-3}  # 默认3次重试
    local timeout_opt=""

    # 检查是否提供了超时时间
    if [ -n "$4" ] && [ $4 -gt 0 ]; then
        # 根据操作系统选择合适的timeout命令参数格式
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS使用秒数前缀格式
            timeout_opt="-t $4"
        else
            # Linux使用--preserve-status格式
            timeout_opt="--preserve-status --kill-after=10 $4"
        fi
    fi
    # 检查文件是否已存在且大小正常
    if [ -f "$output" ] && [ -s "$output" ]; then
        echo "文件已存在且大小正常，跳过下载: $output"
        return 0
    fi
    # 创建下载目录
    mkdir -p "$download_dir"

    # 获取文件名
    local filename=$(basename "$url")
    local download_path="$download_dir/$filename"

    # 记录开始时间
    local start_time=$(date +%s)

    # 尝试下载
    local retry=0
    while [ $retry -le $max_retries ]; do
        echo "尝试下载 $filename: $url"
        echo "下载开始时间: $(date)"
        echo "目标路径: $download_path"

        # 使用timeout控制下载时间（如果已启用）
        local cmd="wget -c --no-check-certificate -q -O \"$download_path\" \"$url\""
        if [ -n "$timeout_opt" ]; then
            cmd="timeout $timeout_opt $cmd"
        fi

        if eval $cmd; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载完成: $filename"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载耗时: $(($duration / 60))分$((duration % 60))秒"
            return 0
        else
            local exit_code=$?

            # 检查是否是超时
            if [ -n "$timeout_opt" ] && [ $exit_code -eq 124 ]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载超时，清理部分下载文件..."
                rm -f "$download_path"
            else
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载失败，错误代码: $exit_code"
            fi

            if [ $retry -lt $max_retries ]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载失败，$((retry+1))秒后重试... (尝试次数: $((retry+1))/$max_retries)"
                sleep $((retry+1))
                retry=$((retry+1))
            else
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 达到最大重试次数，下载失败"
                return 1
            fi
        fi
    done

    # 返回下载失败
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载失败，未知错误"
    return 1
}
# 增强的服务启动逻辑
start_ollama_service() {
    if command -v systemctl &> /dev/null; then
        # 检查是否存着ollama服务
        if sudo systemctl status ollama.service >/dev/null 2>&1; then
            if ! sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
                echo "启动ollama服务..."
                sudo systemctl start ollama.service 2>/dev/null
                sleep 5
                if sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
                    echo "ollama服务已启动"
                    return 0
                else
                    echo "ollama服务启动失败"
                    return 1
                fi
            else
                echo "ollama服务已在运行"
                return 0
            fi
        fi
    fi

    # 如果 systemd 服务未找到，使用 nohup 启动
    echo "使用nohup启动ollama服务..."
    nohup ollama serve > "$HOME/ollama.log" 2>&1 &

    # 等待服务启动
    for i in {1..10}; do
        if check_ollama_service; then
            echo "ollama服务已启动"
            return 0
        fi
        sleep 1
    done

    echo "ollama服务启动失败，请查看$HOME/ollama.log了解详情"
    return 1
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
            fi
        else
            echo "开始安装ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            if [ $? -ne 0 ] && ! command -v ollama &> /dev/null; then
              url=https://ollama.com/download/ollama-linux-amd64.tgz
              file_name=$(basename $url)
              echo "正在下载$DOWNLOAD_DIR/$file_name..."
              if [ ! -f "$DOWNLOAD_DIR/$file_name" ]; then
                  download_file $url "$DOWNLOAD_DIR/$file_name" || {
                      echo "下载ollama-linux-amd64.tgz失败，请检查网络连接"
                      return 1
                  }
              fi
              echo "解压到/usr/local/..."
              #sudo tar -C /usr/local/ -xzf "$DOWNLOAD_DIR/$file_name"
              if ! sudo tar -C /usr/local/ -xzf "$DOWNLOAD_DIR/$file_name"; then
                  echo "解压Ollama失败，文件可能损坏"
                  rm -f "$DOWNLOAD_DIR/$file_name"
                  return 1
              fi

              # 配置环境变量
#              [Unit]
#              Description=Ollama Service
#              After=network-online.target
#
#              [Service]
#              ExecStart=/usr/local/bin/ollama serve
#              User=ollama
#              Group=ollama
#              Restart=always
#              RestartSec=3
#              Environment="PATH=/data/1-software/1-setup/1-miniconda/bin:/data/1-software/1-setup/1-miniconda/condabin:/data/1-software/1-setup/1-miniconda/bin:/usr/bin:/usr/local/bin:/usr/local/cuda/bin:/usr/bin/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
#
#
#              Environment="OLLAMA_MODELS=/data/4-ollama-models"
#              Environment="OLLAMA_HOST=0.0.0.0:11434"
#              Environment="OLLAMA_KEEP_ALIVE=24h"
#              Environment="OLLAMA_NUM_PARALLEL=100"
#              Environment="OLLAMA_MAX_LOADED_MODELS=4"
#              Environment="OLLAMA_SCHED_SPREAD=1"
#              Environment="OLLAMA_FLASH_ATTENTION=1"
#              Environment="OLLAMA_DEBUG=1"
#              Environment="OLLAMA_ACCELERATE=1"
#
#              [Install]
#              WantedBy=default.target
            fi
        fi
    fi
    [ $? -ne 0 ] && echo "ollama安装失败，访问:https://ollama.com/download 下载安装" && exit 1
    if command -v systemctl &> /dev/null; then
        # 检查是否存着ollama服务
        if sudo systemctl status ollama.service >/dev/null 2>&1 && ! sudo systemctl is-active --quiet ollama.service 2>/dev/null; then
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
    # ollama默认限制上下文的长度是2048 num_predict 4096
    local command="curl -X POST $api_url -H \"Content-Type: application/json\" -d  '{\"model\": \"$model\",\"prompt\": \"天为什么那么蓝?\",\"stream\": false,\"options\": {\"num_ctx\": 32768}}'"
    echo "$command"
    # eval $command
}
get_model_version() {
    local model_name=$1
    ollama list | grep "$model_name" | awk '{print $2}'
}
check_model_exists() {
    local model_name=$1
    if ollama list | grep -v NAME | grep -q "$model_name"; then
        return 0
    else
        return 1
    fi
}
# 主程序流程
main() {
     # 动态安装启动ollama服务
     start_ollama
     # 模型检测与用户输入处理
    if ollama list | grep -v NAME | grep -q .; then
        echo "本地已存在模型，模型列表如下："
        ollama list
    else
        echo "本地未检测到模型"
    fi
    read -t 15 -p "请输入模型名称及参数量（如qwen3:8b, deepseek-r1:8b或llama3:8b, 15秒后使用默认值$DEFAULT_MODEL）：" MODEL_NAME
    MODEL_NAME=${MODEL_NAME:-$DEFAULT_MODEL}
    if ! check_model_exists "$MODEL_NAME"; then
        start_model_in_tmux "$MODEL_NAME"
    fi
    # 打印监听端口和进程信息
    lsof -i:11434
    ollama ps
    demo_api_call
}

main
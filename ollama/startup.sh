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
           
           # 定义下载链接和目录
           local primary_url="https://ollama.com/download/ollama-linux-amd64.tgz"
           local backup_url="https://npmmirror.com/mirrors/ollama/ollama-linux-amd64.tgz"
           
           # 创建临时目录用于下载安装脚本
           local temp_dir=$(mktemp -d)
           local install_script="$temp_dir/install.sh"
           
           # 尝试下载安装脚本
           if download_file "https://ollama.com/install.sh" "$temp_dir" 3 600; then
               echo "下载安装脚本成功，正在执行..."
               chmod +x "$install_script"
               if [ -f "$install_script" ]; then
                   . "$install_script"
               else
                   echo "安装脚本不存在，下载失败"
                   exit 1
               fi
           else
               echo "curl下载失败，尝试使用wget断点续传..."
               
               # 首先尝试使用主下载源
               if download_file "$primary_url" "$DOWNLOAD_DIR" 3 600; then
                   echo "主源下载成功"
               else
                   echo "主源下载失败，尝试使用备用源..."
                   # 主源失败后使用备用源
                   if ! download_file "$backup_url" "$DOWNLOAD_DIR" 3 600; then
                       echo "下载失败，请检查网络连接或手动下载安装"
                       exit 1
                   fi
               fi
               
               # 解压下载的文件
               sudo tar -C /usr -xzf "$DOWNLOAD_DIR/ollama-linux-amd64.tgz"
           fi
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
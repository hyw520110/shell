#!/bin/bash
BASE_DIR=$HOME/funasr
# 下载模型文件
MODEL_DIR=$HOME/.cache/modelscope 
LOG_DIR=$BASE_DIR/logs
HTTP_PORT=8090
WSS_PORT=8095
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查操作系统
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" != "Linux" && "$OS_TYPE" != "Darwin" ]]; then
    echo -e "${RED}不支持的操作系统：$OS_TYPE${NC}"
    exit 1
fi

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查Docker状态
check_docker() {
    if command_exists docker; then
        if docker info > /dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# 检查并安装依赖
check_and_install_deps() {
    echo -e "${YELLOW}检查依赖环境...${NC}"

    # 检查 Python 版本
    if ! command_exists python3; then
        echo -e "${RED}未检测到 Python 3，请先安装 Python 3.8 或更高版本。${NC}"
        echo -e "Linux: sudo apt install python3.8"
        echo -e "macOS: brew install python@3.8"
        exit 1
    fi

    PYTHON_VERSION=$(python3 --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+')
    if [[ "$PYTHON_VERSION" < "3.8" ]]; then
        echo -e "${RED}Python 版本 $PYTHON_VERSION < 3.8，无法继续安装。${NC}"
        echo -e "请升级 Python 至 3.8 或更高版本。"
        exit 1
    fi

    echo -e "${GREEN}Python 3.8+ 已满足。${NC}"

    # 创建虚拟环境
    VENV_DIR=~/funasr_env
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv $VENV_DIR
        if [ $? -ne 0 ]; then
            echo -e "${RED}虚拟环境创建失败，请检查 Python 3 安装。${NC}"
            exit 1
        fi
    fi
    source $VENV_DIR/bin/activate

    # 检查 PyTorch 和 torchaudio
    if ! python3 -c "import torch"; then
        echo -e "${YELLOW}PyTorch 未安装，正在安装...${NC}"
        pip install torch torchaudio --extra-index-url https://download.pytorch.org/whl/torch_stable.html
        if [ $? -ne 0 ]; then
            echo -e "${RED}PyTorch 安装失败，请检查网络或手动安装。${NC}"
            exit 1
        fi
    else
        TORCH_VERSION=$(python3 -c "import torch; print(torch.__version__)")
        if [[ "$TORCH_VERSION" < "1.13" ]]; then
            echo -e "${YELLOW}PyTorch 版本 $TORCH_VERSION < 1.13，正在升级...${NC}"
            pip install --upgrade torch torchaudio --extra-index-url https://download.pytorch.org/whl/torch_stable.html
            if [ $? -ne 0 ]; then
                echo -e "${RED}PyTorch 升级失败，请检查网络或手动安装。${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}PyTorch $TORCH_VERSION 已满足。${NC}"
        fi
    fi

    if ! python3 -c "import torchaudio"; then
        echo -e "${YELLOW}torchaudio 未安装，正在安装...${NC}"
        pip install torchaudio --extra-index-url https://download.pytorch.org/whl/torch_stable.html
        if [ $? -ne 0 ]; then
            echo -e "${RED}torchaudio 安装失败，请检查网络或手动安装。${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}torchaudio 已安装。${NC}"
    fi
}

# Docker安装FunASR
docker_install() {
    DOCKER_IMG="funasr/funasr:latest"
    
    echo -e "${YELLOW}拉取FunASR Docker镜像...${NC}"
    docker pull $DOCKER_IMG
    
    echo -e "${YELLOW}启动FunASR容器...${NC}"
    docker run -d --name funasr -p $HTTP_PORT:8080 -v $MODEL_DIR:/models $DOCKER_IMG
    
    echo -e "${GREEN}Docker安装完成，服务已启动在$HTTP_PORT端口${NC}"
    echo -e "访问 http://localhost:$HTTP_PORT 查看服务状态"
}

# 主机安装FunASR
host_install() {
    echo -e "${YELLOW}开始主机安装FunASR...${NC}"

    # 检查并安装依赖
    check_and_install_deps

   
	# https://www.modelscope.cn/models
    # echo -e "${YELLOW}正在下载模型文件，请耐心等待...${NC}"
   	# modelscope download --model iic/speech_paraformer-large_asr_nat-zh-cn-16k-aishell1-vocab8404-pytorch  --local_dir $MODEL_DIR/
    cd $BASE_DIR
    [ ! -d $BASE_DIR/runtime ] && git clone https://github.com/modelscope/FunASR.git $BASE_DIR
	pip install -e ./
	# pip install -e ./ 会安装modelscope
	#if ! command_exists modelscope; then
	#	pip install modelscope
	#fi
	# pip install torchaudio 
	
  	# pip install -U modelscope funasr -i https://mirror.sjtu.edu.cn/pypi/web/simple
  	
  	#cd $BASE_DIR/runtime/python/http/
  	#pip install -r requirements.txt
  	#pip install ffmpeg-python python-multipart
    #echo -e "${YELLOW}启动FunASR HTTP服务...${NC}"
    #python -u server.py --host=localhost --port=$HTTP_PORT 
    # HTTP_PID=$!
    # echo -e "${GREEN}HTTP 服务已启动，PID: $HTTP_PID${NC}"
        #echo -e "访问 http://localhost:$HTTP_PORT 查看服务状态"
    # curl -X POST -F "audio=@/Users/mac/tts/zh.wav" http://localhost:8081/recognition
    # {"text":"我认为跑步最重要的就是给我带来了身体健康。","sentences":[{"text":"我认为跑步最重要的就是给我带来了身体健康。","start":410,"end":4585}],"code":0}
 	
 	
 	cd $BASE_DIR/runtime/python/websocket && pip install -r requirements_server.txt
 	echo -e "${YELLOW}启动FunASR WebSocket服务...${NC}"
    #nohup funasr-wss-server  --model-dir $MODEL_DIR/$MODEL_NAME   --port $WSS_PORT  > $LOG_DIR/wss_server.log 2>&1 &
    # wss服务
    #nohup python funasr_wss_server.py --host=0.0.0.0  --port $WSS_PORT > $LOG_DIR/wss_server.log 2>&1 &
    # ws服务
    nohup python funasr_wss_server.py --port $WSS_PORT --certfile "" --keyfile "" > $LOG_DIR/wss_server.log 2>&1 &
	WSS_PID=$!
    echo -e "${GREEN}WebSocket 服务已启动，PID: $WSS_PID${NC}"
	echo -e "查看日志：${YELLOW}  ${YELLOW}tail -f $LOG_DIR/wss_server.log${NC}"

    echo -e "${GREEN}主机安装完成！${NC}"
    #echo -e "HTTP服务端口: ${YELLOW}$HTTP_PORT${NC}"
    echo -e "WebSocket服务端口: ${YELLOW}$WSS_PORT${NC}"
    echo -e "模型存储目录: ${YELLOW}$MODEL_DIR${NC}"
    echo -e "日志目录: ${YELLOW}$LOG_DIR${NC}"

}

main() {
    echo -e "${GREEN}开始安装FunASR...${NC}"
    [ ! -d $MODEL_DIR ] && mkdir -p $MODEL_DIR
    [ ! -d $LOG_DIR ] &&  mkdir -p $LOG_DIR
    if check_docker; then
        echo -e "${GREEN}检测到Docker服务正在运行，优先使用Docker安装${NC}"
        docker_install
    else
        echo -e "${YELLOW}未检测到Docker服务，将进行主机安装${NC}"
        host_install
    fi
}

main "$@"
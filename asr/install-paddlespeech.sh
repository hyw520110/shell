#!/bin/bash

# 检测是否在中国大陆（简化版）
in_china=false
if [[ $(curl -s --max-time 2 https://ipinfo.io/country) == "CN" ]]; then
    in_china=true
fi

# Docker安装函数
install_with_docker() {
    local image="paddlecloud/paddlespeech:develop-cpu-fb4d25"
    #local image="paddlecloud/paddlespeech:latest"
    docker ps -a | grep "$image" | grep Up  && echo "$image 已启动" && exit 0
    echo "开始拉取docker镜像..."
    # 尝试拉取镜像
    if ! docker pull $image; then
        echo "镜像拉取失败."
        if $in_china; then
            echo "配置docker镜像加速器"
        fi
        exit 1
    fi
    #echo -e "\nUsage:"
    #echo "  docker run -it --rm $image"
    #echo "  docker run -it --rm -v \$(pwd):/data $image"
	
    echo "GPU:"
    echo "docker pull paddlecloud/paddlespeech:develop-gpu-cuda10.2-cudnn7-fb4d25"
    echo "启动PaddleSpeech服务..."
    docker ps -a | grep paddlespeech && docker start paddlespeech && echo "paddlespeech容器已启动" && exit 0
    #  进入容器paddlespeech目录启动服务默认端口8090
    container_id=$(docker run -d --name paddlespeech -p 8090:8090 $image bash -c "cd paddlespeech && paddlespeech_server start --config_file /home/PaddleSpeech/paddlespeech/server/conf/application.yaml")
    docker logs -f $container_id
    # 启动完成后(启动过程下载的模型很大，启动需很久，拷贝数据也需要很久):
    # docker cp paddlespeech:/root/.paddlespeech $HOME/ 
    # docker stop paddlespeech && docker rm paddlespeech
    # docker run -d --name paddlespeech -p 8090:8090 -v $HOME/.paddlespeech/:/root/.paddlespeech $image bash -c "cd paddlespeech && paddlespeech_server start --config_file /home/PaddleSpeech/paddlespeech/server/conf/application.yaml"
    # 下载或录制wav文件 拷贝到容器测试 docker exec -it paddlespeech /bin/bash
    # paddlespeech_client asr --server_ip 127.0.0.1 --port 8090 --input $HOME/zh.wav
    # 基于paddle镜像挂载PaddleSpeech源码目录进行构建PaddleSpeech镜像
    # cd $HOME/workspace/ && git clone https://github.com/PaddlePaddle/PaddleSpeech.git
    # docker run -it --name paddle -v $HOME/workspace/PaddleSpeech:/workspace paddlepaddle/paddle:3.0.0 /bin/bash
    # cd /workspace
	#  pip install .
}
# 主机安装函数
install_on_host() {
	# 检查操作系统类型
	os_type=$(uname -s)
	if [[ "$os_type" == "Linux" ]]; then
	    echo "Linux系统."
	elif [[ "$os_type" == "Darwin" ]]; then
	    echo "macOS系统."
	else
	    echo "不支持的系统: $os_type"
	    exit 1
	fi
    echo "开始主机安装..."
    
    # 检查Python环境
    if ! command -v python3 &> /dev/null; then
        echo "Python3 未安装，请先安装Python 3.7-3.1."
        exit 1
    fi
    
    py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if [[ $py_version < 3.7 || $py_version > 3.11 ]]; then
        echo "不支持的python版本: $py_version (requires 3.7-3.11)"
        exit 1
    fi
    
    # 检查pip
    if ! command -v pip3 &> /dev/null; then
        if ! python3 -m ensurepip --upgrade; then
            echo "pip安装失败，请手动安装pip3."
            exit 1
        fi
    fi

    # 安装系统依赖
    echo "安装系统依赖..."
    if [[ "$os_type" == "Linux" ]]; then
        # 检测包管理器
        if command -v apt-get &> /dev/null; then
            # 避免sudo如果已经是root
            if [[ $EUID -ne 0 ]]; then
                SUDO="sudo"
            fi
            $SUDO apt-get update
            $SUDO apt-get install -y ffmpeg
        else
            echo "先手动安装ffmpeg."
            exit 1
        fi
    elif [[ "$os_type" == "Darwin" ]]; then
        if ! command -v brew &> /dev/null; then
            echo "Homebrew not found. Installing..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew update
        brew install ffmpeg
    fi

    # 配置pip镜像源
    pip_args=""
    if $in_china; then
        pip_args="-i https://mirror.baidu.com/pypi/simple"
        echo "Using Baidu pip mirror"
    fi

    # 安装Python包
    pip3 install --upgrade pip $pip_args
    # https://www.paddlepaddle.org.cn/
    python -m pip install paddlepaddle==3.0.0 -i https://www.paddlepaddle.org.cn/packages/stable/cpu/
    #pip3 install paddlepaddle $pip_args || { echo "Failed to install paddlepaddle"; exit 1; }
    pip3 install paddlespeech $pip_args || { echo "Failed to install paddlespeech"; exit 1; }
    
    echo "PaddleSpeech安装完成."

}


# 检查Docker安装
if command -v docker &> /dev/null; then
   install_with_docker
else
    install_on_host
fi

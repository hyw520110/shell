#!/bin/bash

# 设置环境变量
export OLLAMA_HOST=0.0.0.0:11434

# 检查 tmux 是否已安装
if ! command -v tmux &> /dev/null
then
    if [ -x "$(command -v apt)" ]; then
        sudo apt-get update && sudo apt-get install -y tmux
    elif [ -x "$(command -v yum)" ]; then
        sudo yum install -y tmux
    else
        echo "请手动安装tmux。"
        exit 1
    fi
fi

if [ $(ps -ef | grep 'ollama serve' |grep -v grep| wc -l) -eq 0 ]; then
  nohup ollama serve > ollama.log 2>&1 &
  sleep 5
  #ollama pull nomic-embed-text
fi
if [ $(ollama list|grep qwen2|wc -l) -eq 0 ];then
  ollama pull qwen2:7b
fi
if [ $(ollama list|grep llama3|wc -l) -eq 0 ];then
  ollama pull llama3.1:8b 2>/dev/null
  support=$?
fi
ollama list
if [ $(ps -ef | grep 'ollama run qwen2:7b' | grep -v grep | wc -l) -eq 0 ]; then
  #screen -dmS qwen2 -t xterm bash -c 'ollama run qwen2:7b; exec bash'
  tmux new-session -d -s qwen2 'bash -c "ollama run qwen2:7b; exec bash"'
  echo "重新连接到qwen2会话执行：tmux attach-session -t qwen2"
fi
if [ $support -eq 0 ] && [ $(ps -ef | grep 'ollama run llama3.1:8b' | grep -v grep | wc -l) -eq 0 ]; then
  tmux new-session -d -s llama3 'bash -c "ollama run llama3.1:8b; exec bash"'
  echo "连接llama3:tmux attach-session -t llama3"
fi

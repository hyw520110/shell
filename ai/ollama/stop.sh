#!/bin/bash
if  sudo systemctl is-active --quiet ollama.service; then
  # 停止 systemd 服务
  echo "停止ollama服务..."
  sudo systemctl stop ollama.service
  sudo systemctl disable ollama.service
fi

process=$(ps -ef | grep ollama | grep -v grep | grep -v "$0" | awk '{print $2}')
if [ -z "$process" ]; then
  exit 0
fi
echo "Stopping ollama processes: $process"
kill -9 $process

# 停止所有 tmux 会话
tmux_sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
if [ -n "$tmux_sessions" ]; then
  echo "Stopping tmux sessions: $tmux_sessions"
  for session in $tmux_sessions; do
    tmux kill-session -t $session
  done
fi

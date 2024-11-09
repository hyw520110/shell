#!/bin/bash

# 检查参数
if [ $# -eq 0 ]; then
  echo "用法: $0 <关键字1> [关键字2] [关键字3] ..."
  exit 1
fi

# 定义查找端口的函数
find_ports_for_pid() {
  local pid=$1
  local ports=()

  if command -v netstat > /dev/null; then
    ports=$(netstat -tulnpe | grep "$pid" | awk '{print $4}' | awk -F: '{print $NF}')
  elif command -v lsof > /dev/null; then
    ports=$(lsof -i -P -n | grep "$pid" | awk '{print $9}' | awk -F: '{print $NF}')
  else
    echo "未安装 netstat 和 lsof"
    exit 1
  fi

  echo "$ports"
}

# 构建 grep 的模式
grep_pattern=""
for keyword in "$@"; do
  if [ -z "$grep_pattern" ]; then
    grep_pattern="$keyword"
  else
    grep_pattern="$grep_pattern.*$keyword"
  fi
done

# 获取所有匹配的PID
pids=$(ps -ef | grep "$grep_pattern" | grep -v grep | awk '{print $2}')
if [ -z "$pids" ]; then
  echo "未找到与关键字组合匹配的进程"
  exit 1
fi

# 遍历每个PID
for pid in $pids; do
  echo "PID: $pid"
  ports=$(find_ports_for_pid $pid)
  if [ -z "$ports" ]; then
    echo "  未找到与PID $pid 关联的端口"
  else
    echo "  PID $pid 对应的端口: $ports"
  fi
done
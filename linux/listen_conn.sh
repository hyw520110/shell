#!/bin/bash

# 检查是否以root身份运行
if [ "$(id -u)" != "0" ]; then
    echo "请以root身份运行此脚本."
    exit 1
fi

# 定义列标题
column_headers="Proto\tLocal Address\tRemote Address\tPID/Program name"
echo "当前活动的网络连接:"
echo -e "$column_headers"

# 使用ss命令列出所有网络连接，并显示PID和程序路径
while true; do
    # 获取ss命令的输出
    ss_output=$(ss -tnlp)

    # 遍历每一行输出
    while IFS= read -r line; do
        # 提取协议
        proto=$(echo "$line" | awk '{print $1}')
        
        # 提取本地地址
        local_addr=$(echo "$line" | awk -F' ' '{print $5}' | sed 's/users://')
        
        # 提取远程地址
        remote_addr=$(echo "$line" | awk -F' ' '{print $6}' | sed 's/users://')
        
        # 提取PID
        pid=$(echo "$line" | awk '{print $9}' | cut -d':' -f1)
        
        # 获取程序名称
        program=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        
        # 输出格式化的结果
        printf "%s\t%s\t%s\t%d/%s\n" "$proto" "$local_addr" "$remote_addr" "$pid" "$program"
    done <<< "$ss_output"
    
    sleep 5 # 每隔5秒刷新一次输出
done
#!/bin/bash

# 检查参数数量
if [ "$#" -lt 1 ]; then
    echo "用法: $0 <目录> [后缀]"
    exit 1
fi

# 设置默认目录为当前目录
dir=$(pwd)
# 如果提供了目录参数，则使用该目录
if [ -n "$1" ]; then
    dir=$1
fi

# 设置默认后缀为空，表示匹配所有文件
suffix=""
# 如果提供了后缀参数，则使用该后缀
if [ -n "$2" ]; then
    suffix=$2
fi

# 检查目录是否存在
if [ ! -d "$dir" ]; then
    echo "错误: 指定的目录不存在。"
    exit 1
fi

# 进入指定目录
cd "$dir"

# 遍历目录下的所有文件
for file in *"$suffix"; do
    # 检查是否为文件
    if [ -f "$file" ]; then
        # 显示文件名
        echo "$file:"
        # 显示文件内容
        cat "$file"
        # 在文件内容后添加换行，以便区分不同文件的内容
        echo ""
    fi
done


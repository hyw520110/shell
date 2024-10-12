#!/bin/bash

# 检查是否提供了足够的参数
if [ $# -lt 3 ]; then
    echo "Usage: $0 <directory> <original_suffix> <target_suffix>"
    echo "Example usage: $0 /path/to/directory .cypher .j2.cypher"
    exit 1
fi

# 获取目录、原始后缀和目标后缀
directory="$1"
original_suffix="$2"
target_suffix="$3"

# 切换到指定目录
cd "$directory" || { echo "Directory not found: $directory"; exit 1; }

# 遍历当前目录下的所有符合原始后缀的文件
for file in *"$original_suffix"; do
    # 检查文件是否存在
    if [[ -f "$file" ]]; then
        # 获取新的文件名
        new_file="${file%.*}$target_suffix"
        
        # 重命名文件
        mv "$file" "$new_file"
    fi
done

echo "All files with suffix '$original_suffix' in directory '$directory' have been renamed to '$target_suffix'."

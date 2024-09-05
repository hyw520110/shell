#!/bin/bash

# 默认的docker-compose文件路径
compose_file=${1:-"docker-compose.yml"}

# 检查docker-compose文件是否存在
while [ ! -f "$compose_file" ]; do
    read -p "文件 '$compose_file' 不存在。请输入您的 docker-compose 文件路径: " compose_file
    if [ ! -f "$compose_file" ]; then
        echo "文件 '$compose_file' 仍然未找到。请检查路径并重试。"
    fi
done

# 提取docker-compose文件所在的目录
script_dir=$(dirname "$compose_file")

# 切换到docker-compose文件所在目录
cd "$script_dir" || { echo "无法切换到目录 '$script_dir'"; exit 1; }

# 获取镜像名称
images=()
while IFS= read -r line; do
    images+=("$line")
done < <(docker-compose -f "$compose_file" ps | awk 'NR > 1 {print $2}' | grep -Ev "WARN|IMAGE")

# 检查images数组是否为空
if [ ${#images[@]} -eq 0 ]; then
    echo "没有找到任何镜像，请检查您的docker-compose文件配置。"
    exit 1
fi

# 循环保存每个镜像
for img in "${images[@]}"; do
    if [[ -n $img ]]; then
        # 生成文件名，使用'-'替换非法字符'/'
        tar_filename=$(echo "$img" | tr '/' '-' | tr ':' '-')
        # 保存镜像到tar文件
        docker save -o "${tar_filename}.tar" "$img"
        echo "已保存镜像 $img 为 ${tar_filename}.tar"
    else
        echo "跳过空镜像名称"
    fi
done

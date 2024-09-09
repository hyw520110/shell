#!/bin/bash

# 默认的docker-compose文件路径
compose_file=${1:-"docker-compose.yml"}

# 检查docker-compose文件是否存在
while [ ! -f "$compose_file" ]; do
    read -p "文件 '$compose_file' 不存在。请输入您的 docker-compose 文件路径: " compose_file
    if [ ! -f "$compose_file" ]; then
        echo "文件 '$compose_file' 仍然未找到。请检查路径并重试。"
        exit 1
    fi
done

# 提取docker-compose文件所在的目录
script_dir=$(dirname "$compose_file")

# 切换到docker-compose文件所在目录
cd "$script_dir" || { echo "无法切换到目录 '$script_dir'"; exit 1; }

# 获取镜像名称和大小
images_output=$(docker-compose -f "$compose_file" images | grep -Ev "WARN|CONTAINER")
IFS=$'\n' read -rd '' -a images <<< "$images_output"

# 检查images数组是否为空
if [ ${#images[@]} -eq 0 ]; then
    echo "没有找到任何镜像，请检查您的docker-compose文件配置。"
    exit 1
fi

# 初始化总大小
total_size=0

# 定义一个函数来将大小转换为字节
convert_to_bytes() {
    local size_str="$1"
    local num=$(echo "$size_str" | sed 's/[GMKB]//g'|bc)
    local unit=$(echo "$size_str" | sed 's/[0-9.]//g')
    case "${unit,,}" in
        g|gb)
            echo "$num * 1024 * 1024 * 1024 / 1" | bc ;;
        m|mb)
            echo "$num * 1024 * 1024 / 1" | bc ;;
        k|kb)
            echo "$num * 1024 / 1" | bc ;;
        *)
            echo "$num / 1" | bc ;;
    esac
}

# 计算所有镜像所需的总磁盘空间
for line in "${images[@]}"; do
    # 提取大小列
    size=$(echo "$line" | awk '{print $NF}')
    # 调用函数转换为字节
    size_in_bytes=$(convert_to_bytes "$size")
    total_size=$((total_size + size_in_bytes))
done

# 获取当前目录的可用空间
available_space=$(df -BM . | awk 'NR==2 {print $4}' | sed 's/M//')
available_space=$((available_space * 1024 * 1024)) # 转换为字节

# 显示需要的总空间
echo "保存所有镜像需要的总磁盘空间为 $(($total_size / (1024 * 1024))) MB。"

# 检查可用空间是否足够
if (( total_size > available_space )); then
    echo "当前目录可用空间不足以保存所有镜像，需要约 $(($total_size - $available_space) / (1024 * 1024)) MB 的额外空间。"
    exit 1
fi

read -p "确定要保存或迁移所有镜像吗？(1：保存镜像；2:迁移镜像 (1/2): " confirm

confirm=${confirm:-"2"}
if [[ $confirm == "2" ]]; then
    read -p "请输入远程IP地址: " remote_ip
    read -p "请输入远程用户名: " remote_user
    read -p "请输入远程目录: " remote_dir
fi

tar_filenames=()

# 循环保存每个镜像
for line in "${images[@]}"; do
    # 解析每一行，提取REPOSITORY和TAG列
    repository=$(echo "$line" | awk '{print $2}')
    tag=$(echo "$line" | awk '{print $3}')
    image="$repository:$tag"

    # 生成文件名
    # 截取第一个 : 左边的字符串
    img_short=$(echo "$image" | cut -d':' -f1)
    # 再截取最后一个 / 右边的字符串
    img_name=$(echo "$img_short" | awk -F'/' '{print $NF}')
    # 生成文件名
    tar_filename="$img_name.tar"

    # 检查文件是否已经存在
    if [ -f "$tar_filename" ]; then
        echo "镜像 $image 已经保存为 $tar_filename，跳过保存"
    else
        # 保存镜像到tar文件
        docker save -o "$tar_filename" "$image"
        if [ $? -eq 0 ]; then
            echo "已保存镜像 $image 为 $tar_filename"
        else
            echo "保存镜像 $image 出现错误"
            continue
        fi
    fi

    if [[ $confirm == "2" ]] && [[ -f "$tar_filename" ]]; then
        tar_filenames+=("$tar_filename")
        echo "正在传输 $tar_filename 到 $remote_ip:$remote_dir"
        if command -v rsync &> /dev/null; then
            rsync -az -e "ssh -o StrictHostKeyChecking=no" "$tar_filename" "$remote_user@$remote_ip:$remote_dir"
        else
            scp -q "$tar_filename" "$remote_user@$remote_ip:$remote_dir"
        fi
        if [ $? -eq 0 ]; then
            echo "传输 $tar_filename 成功"
            rm -rf "$tar_filename"
            echo "已删除本地文件 $tar_filename"
            sudo rm -rf /var/lib/docker/tmp/* &> /dev/null
        else
            echo "传输 $tar_filename 失败"
        fi
    fi
done

if [ ${#tar_filenames[@]} -gt 0 ]; then
    echo "导入镜像，请在迁移目标主机上执行以下命令:"
    for name in "${tar_filenames[@]}"; do
        echo "docker load -i $name"
    done
fi

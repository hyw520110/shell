#!/bin/bash

# 初始化参数
local_repo_dir="${1:-"$HOME/workspace/reporter"}"
commit_hash="${2:-""}"
source_dir="${3:-""}"
target_dir="${4:-"$HOME"}"

# 用户输入本地仓库目录
while [[ -z "$local_repo_dir" || ! -d "$local_repo_dir" ]]; do
    read -p "请输入本地 Git 仓库目录: " local_repo_dir
    if ! cd "$local_repo_dir" || ! git rev-parse --is-inside-work-tree &> /dev/null; then
        echo "错误：'$local_repo_dir' 不是一个有效的 Git 仓库目录。"
        local_repo_dir=""
    fi
done
cd "$local_repo_dir" && git remote -v

# 提取仓库的最后一级目录名
repo_basename=$(basename "$local_repo_dir")

# 用户输入版本号
while [[ -z "$commit_hash" ]]; do
    read -p "请输入版本号（commit hash）: " commit_hash
    if ! git rev-parse "$commit_hash" &> /dev/null; then
        echo "错误：仓库中不存在版本号 '$commit_hash'。"
        commit_hash=""
    fi
done

# 用户输入目录
while [[ -z "$source_dir" ]]; do
    # 列出所有目录和文件
    all_dirs=$(git ls-tree -r --name-only "$commit_hash" | sort -u)
    echo "版本号 '$commit_hash' 下的文件："
    printf "$all_dirs" && echo ""
    read -p "请输入目录名称: " source_dir
    if ! git ls-tree -r --name-only "$commit_hash" | grep -q "^$source_dir/"; then
        echo "错误：版本号 '$commit_hash' 下不存在目录 '$source_dir'。"
        source_dir=""
    fi
done

# 显示 source_dir 及其子目录下的文件列表
echo "版本号 '$commit_hash' 下目录 '$source_dir' 中的文件："
file_list=$(git ls-tree -r --name-only "$commit_hash" | grep "^$source_dir/")
file_count=0
for file in $file_list; do
    let file_count++
    relative_path="${file#$source_dir/}"
    # 解码文件名
    decoded_relative_path=$(printf "${relative_path}")
    echo "[$file_count] $decoded_relative_path"
done

# 默认导出所有文件
read -p "请输入想要下载导出的文件编号，用空格分隔 (按回车默认导出所有): " selected_numbers
selected_numbers=${selected_numbers:-$(seq 1 $file_count)}
source_dir=$(echo "$source_dir" | sed 's/^"//;s/"$//')
# 记住用户的选择
overwrite_choice=""

# 处理每个选定的文件
for number in $selected_numbers; do
    # 校验编号是否有效
    if [[ "$number" =~ ^[0-9]+$ ]] && (( number > 0 )) && (( number <= file_count )); then
        # 计算文件相对于 source_dir 的相对路径
        index=$((number - 1))
        selected_file=$(echo "$file_list" | awk "NR==$((index + 1))")
        # 去除引号
        relative_path=$(echo "$selected_file" | sed 's/^"//;s/"$//')
        # 解码文件名
        relative_path=$(printf "$relative_path")
        # 构建目标文件路径
        target_file="$target_dir/$repo_basename/$relative_path"
        # 创建所需的子目录
        mkdir -p "$(dirname "$target_file")"
        # 检查文件是否存在
        if [[ -e "$target_file" ]]; then
            if [[ -z "$overwrite_choice" ]]; then
                read -p "文件 $target_file 已经存在。您是否要覆盖它？(A/n/q): " overwrite_choice
            fi
            case "$overwrite_choice" in
                a|A )
                    # 覆盖文件
                    git show ${commit_hash}:$relative_path > "$target_file"
                    echo "文件 $decoded_relative_path 已覆盖至 $target_file。"
                    ;;
                n|N )
                    # 重命名文件
                    timestamp=$(date +%Y%m%d_%H%M%S)
                    new_target_file="${target_file%.*}_${timestamp}${target_file#*.}"
                    git show ${commit_hash}:$relative_path > "$new_target_file"
                    echo "文件 $decoded_relative_path 已保存为 $new_target_file。"
                    ;;
                * )
                    echo "退出" && exit 1
                    ;;
            esac
        else
            # 获取并保存文件内容
            git show ${commit_hash}:$relative_path > "$target_file"
            echo "文件 $decoded_relative_path 已下载至 $target_file。"
        fi
    else
        echo "无效编号：$number。请输入范围内的有效编号。"
    fi
done

# 输出完成信息
echo "版本号 $commit_hash 下目录 $source_dir 中的文件已导出至 $target_dir/$repo_basename/$source_dir。"
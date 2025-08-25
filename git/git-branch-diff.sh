#!/bin/bash

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -h, --help             显示此帮助信息"
    echo "  -b, --branch BRANCH    指定要对比的分支（默认为 origin/当前分支）"
    echo "  -c, --current BRANCH   指定当前分支（默认为当前检出的分支）"
    echo "  -d, --dir DIRECTORY    指定 Git 目录（默认为当前目录）"
    echo ""
    echo "示例:"
    echo "  $0                          # 对比当前分支与远程分支"
    echo "  $0 -b develop               # 对比当前分支与 origin/develop"
    echo "  $0 -c feature-a -b develop  # 对比 feature-a 分支与 origin/develop"
    echo "  $0 -d /path/to/repo         # 指定 Git 目录"
}

# 初始化变量
current_branch=""
compare_branch=""
git_dir=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--current)
            current_branch="$2"
            shift 2
            ;;
        -b|--branch)
            compare_branch="$2"
            shift 2
            ;;
        -d|--dir)
            git_dir="$2"
            shift 2
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 如果未指定 Git 目录，则使用当前目录
if [ -z "$git_dir" ]; then
    git_dir="$(pwd)"
fi

# 检查指定目录是否为 Git 目录
while [ ! -d "$git_dir/.git" ]; do
    echo "❌ 错误: $git_dir 不是一个 Git 目录"
    read -p "请输入 Git 目录路径 (或按 Ctrl+C 退出): " git_dir
    # 展开波浪号路径
    git_dir="${git_dir/#\~/$HOME}"
done

# 进入 Git 目录
cd "$git_dir" || exit 1

echo "Git 目录: $(pwd)"

# 如果未指定当前分支，则获取当前分支名称
if [ -z "$current_branch" ]; then
    current_branch=$(git rev-parse --abbrev-ref HEAD)
fi

# 如果未指定对比分支，则默认为 origin/当前分支
if [ -z "$compare_branch" ]; then
    compare_branch="origin/$current_branch"
fi

echo "当前分支: $current_branch"
echo "对比分支: $compare_branch"
echo "正在获取远程分支状态..."

# 更新远程分支状态
git fetch origin

# 获取需要对比的文件列表（排除 dist 目录和其他不需要对比的文件）
files=$(git diff --name-only "$current_branch" "$compare_branch" | grep -Ev '^dist/|^node_modules/|yarn.lock|.lock$|^\.vscode/|^\.hbuilderx/')

# 如果没有需要对比的文件，则退出
if [ -z "$files" ]; then
    echo "🎉 没有需要对比的文件，$current_branch 分支与 $compare_branch 分支无差异"
    exit 0
fi

# 显示需要对比的文件列表
echo "🔍 发现以下差异文件:"
echo "$files" | nl -w4 -s'. '
total_files=$(echo "$files" | wc -l)
echo ""
echo "共计: $total_files 个文件"

# 处理单个文件对比的函数
process_file() {
    local file=$1
    local index=$2
    local total=$3
    
    # 检查文件是否存在
    if [ -f "$file" ] || git ls-files --error-unmatch "$file" &>/dev/null; then
        echo "[$index/$total] 正在对比: $file"
        git difftool "$current_branch" "$compare_branch" -- "$file"
    else
        echo "[$index/$total] 文件已删除或不存在: $file"
    fi
}

read -p "请输入选项(a查看所有文件的具体差异; n或回车退出;文件编号或路径查看对应文件的具体差异):" choice

# 去除空格并转换为小写
choice=$(echo "$choice" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

# 处理退出情况
if [[ "$choice" == "n" || -z "$choice" ]]; then
    echo "已取消操作"
    exit 0
fi

# 处理查看所有文件的情况
if [[ "$choice" == "a" ]]; then
    echo "开始对比所有文件差异..."
fi
    
# 遍历文件列表并调用 git difftool
file_index=0
echo "$files" | while IFS= read -r file; do
    file_index=$((file_index + 1))
    if [[ "$choice" == "a" || "$choice" == "$file" || "$choice" == "$file_index" ]]; then
    	process_file "$file" "$file_index" "$total_files"
    fi
done

if [[ "$choice" == "a" ]]; then
	echo "✅ 差异对比完成！已处理 $total_files 个文件。"
fi


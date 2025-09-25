#!/bin/bash

# =============================================================================
# Git 分支差异对比工具
# 用于比较两个 Git 分支之间的文件差异，并提供交互式文件对比功能
# =============================================================================

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -h, --help                    显示此帮助信息"
    echo "  -r, --remote BRANCH           指定要对比的远程分支（默认为 origin/当前分支）"
    echo "  -c, --current BRANCH          指定当前分支（默认为当前检出的分支）"
    echo "  -d, --dir DIRECTORY           指定 Git 目录（默认为当前目录）"
    echo "  -l, --local-branch BRANCH     指定要对比的本地分支（替代远程分支）"
    echo "  -e, --exclude PATTERN         添加额外的排除模式（可多次使用）"
    echo ""
    echo "示例:"
    echo "  $0                                    # 对比当前分支与远程分支"
    echo "  $0 -r develop                         # 对比当前分支与 origin/develop"
    echo "  $0 -c feature-a -r develop            # 对比 feature-a 分支与 origin/develop"
    echo "  $0 -c feature-a -l develop            # 对比 feature-a 分支与本地 develop 分支"
    echo "  $0 -d /path/to/repo                   # 指定 Git 目录"
    echo "  $0 -e \"^config/\" -e \"\.md$\"          # 添加自定义排除模式"
}

# =============================================================================
# 初始化变量
# =============================================================================
current_branch=""
compare_branch=""
local_branch=""
git_dir=""
# 存储用户自定义的排除模式
custom_exclude_patterns=()

# =============================================================================
# 解析命令行参数
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--current)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "❌ 错误: -c/--current 选项需要指定分支名称"
                show_help
                exit 1
            fi
            current_branch="$2"
            shift 2
            ;;
        -r|--remote)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "❌ 错误: -r/--remote 选项需要指定分支名称"
                show_help
                exit 1
            fi
            compare_branch="$2"
            shift 2
            ;;
        -l|--local-branch)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "❌ 错误: -l/--local-branch 选项需要指定分支名称"
                show_help
                exit 1
            fi
            local_branch="$2"
            shift 2
            ;;
        -d|--dir)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "❌ 错误: -d/--dir 选项需要指定目录路径"
                show_help
                exit 1
            fi
            git_dir="$2"
            shift 2
            ;;
        -e|--exclude)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "❌ 错误: -e/--exclude 选项需要指定排除模式"
                show_help
                exit 1
            fi
            custom_exclude_patterns+=("$2")
            shift 2
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 验证 Git 目录路径安全性
validate_git_dir() {
    local dir="$1"
    
    # 检查路径是否为空
    if [ -z "$dir" ]; then
        echo "❌ 错误: 目录路径不能为空"
        return 1
    fi
    
    # 规范化路径
    if ! normalized_dir=$(realpath "$dir" 2>/dev/null) || [ -z "$normalized_dir" ]; then
        echo "❌ 错误: 无法解析目录路径 '$dir'"
        return 1
    fi
    
    # 检查路径是否指向目录
    if [ ! -d "$normalized_dir" ]; then
        echo "❌ 错误: $normalized_dir 不是一个有效的目录"
        return 1
    fi
    
    # 检查目录是否为 Git 仓库
    if [ ! -d "$normalized_dir/.git" ]; then
        echo "❌ 错误: $normalized_dir 不是一个 Git 目录"
        return 1
    fi
    
    echo "$normalized_dir"
    return 0
}

# 如果未指定 Git 目录，则使用当前目录
if [ -z "$git_dir" ]; then
    git_dir="$(pwd)"
else
    # 验证指定的 Git 目录
    git_dir=$(validate_git_dir "$git_dir") || exit 1
fi

# 进入 Git 目录
cd "$git_dir" || {
    echo "❌ 错误: 无法进入目录 $git_dir"
    exit 1
}

echo "Git 目录: $(pwd)"

# 验证当前目录确实是 Git 仓库
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ 错误: 当前目录不是 Git 仓库"
    exit 1
fi

# 如果未指定当前分支，则获取当前分支名称
if [ -z "$current_branch" ]; then
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    # 检查命令是否成功执行
    if [ $? -ne 0 ]; then
        echo "❌ 错误: 无法获取当前分支信息"
        exit 1
    fi
fi

# 验证分支名称安全性
validate_branch_name() {
    local branch="$1"
    
    # 检查分支名称是否为空
    if [ -z "$branch" ]; then
        echo "❌ 错误: 分支名称不能为空"
        return 1
    fi
    
    # 检查分支名称长度（Git 限制为 256 字符）
    if [ ${#branch} -gt 256 ]; then
        echo "❌ 错误: 分支名称过长（超过 256 字符）"
        return 1
    fi
    
    # 检查是否包含非法字符（Git 分支名称不能包含以下字符）
    # 允许的字符：字母、数字、以及 . _ - /（但不能以这些字符开头或结尾，也不能连续出现）
    if [[ "$branch" =~ [^a-zA-Z0-9._/-] ]]; then
        echo "❌ 错误: 分支名称包含非法字符"
        return 1
    fi
    
    # 检查是否以斜杠、点或连字符开头或结尾
    if [[ "$branch" =~ ^[./-]|[-/]$ ]]; then
        echo "❌ 错误: 分支名称不能以斜杠、点或连字符开头或结尾"
        return 1
    fi
    
    # 检查是否包含连续的斜杠、点或连字符
    if [[ "$branch" =~ \.\.|//--|-$ ]]; then
        echo "❌ 错误: 分支名称不能包含连续的点或斜杠"
        return 1
    fi
    
    # 检查是否包含特殊文件名
    if [[ "$branch" == "@" || "$branch" =~ @\{ ]]; then
        echo "❌ 错误: 分支名称不能包含 '@{' 或单独的 '@'"
        return 1
    fi
    
    # 检查是否为 Git 保留名称
    if [[ "$branch" == "HEAD" || "$branch" == "MERGE_HEAD" || "$branch" == "FETCH_HEAD" ]]; then
        echo "❌ 错误: '$branch' 是 Git 保留名称"
        return 1
    fi
    
    return 0
}

# 验证当前分支名称安全性
if ! validate_branch_name "$current_branch"; then
    exit 1
fi

# 验证当前分支是否存在
if ! git show-ref --verify --quiet "refs/heads/$current_branch"; then
    echo "❌ 错误: 当前分支 '$current_branch' 不存在"
    exit 1
fi

# 处理分支对比逻辑
if [ -n "$local_branch" ]; then
    # 验证本地分支名称安全性
    if ! validate_branch_name "$local_branch"; then
        exit 1
    fi
    
    # 使用指定的本地分支进行对比
    compare_branch="$local_branch"
    echo "当前分支 (左边): $current_branch"
    echo "对比分支 (右边): $compare_branch (本地分支)"
    
    # 验证本地分支是否存在
    if ! git show-ref --verify --quiet "refs/heads/$local_branch"; then
        echo "❌ 错误: 本地分支 '$local_branch' 不存在"
        exit 1
    fi
elif [ -n "$compare_branch" ]; then
    # 验证远程分支名称安全性
    if ! validate_branch_name "$compare_branch"; then
        exit 1
    fi
    
    # 使用指定的远程分支进行对比
    remote_branch="$compare_branch"
    compare_branch="origin/$compare_branch"
    echo "当前分支 (左边): $current_branch"
    echo "对比分支 (右边): $compare_branch (远程分支)"
    
    # 验证远程分支是否存在
    if ! git show-ref --verify --quiet "refs/remotes/origin/$remote_branch"; then
        echo "⚠️  警告: 远程分支 'origin/$remote_branch' 不存在，将继续执行但可能无结果"
    fi
else
    # 默认使用当前分支的远程分支进行对比
    compare_branch="origin/$current_branch"
    echo "当前分支 (左边): $current_branch"
    echo "对比分支 (右边): $compare_branch (默认远程分支)"
    
    # 验证远程分支是否存在
    if ! git show-ref --verify --quiet "refs/remotes/origin/$current_branch"; then
        echo "⚠️  警告: 远程分支 '$compare_branch' 不存在，将继续执行但可能无结果"
    fi
fi

echo "正在获取远程分支状态..."
# 只有在需要时才更新远程分支状态
if [[ "$compare_branch" == origin/* ]]; then
    git fetch origin
    # 检查命令是否成功执行
    if [ $? -ne 0 ]; then
        echo "❌ 错误: 无法获取远程分支状态"
        exit 1
    fi
fi

# 获取需要对比的文件列表（排除构建目录、依赖目录和其他不需要对比的文件）
# 使用数组来存储排除模式，提高可维护性
# 默认排除 Java 和 Vue 项目相关的目录和文件
exclude_patterns=(
    # 构建输出目录
    '^dist/'
    '^build/'
    '^target/'
    '^out/'
    
    # 依赖管理目录
    '^node_modules/'
    '^\.m2/'
    '^\.gradle/'
    
    # 锁文件
    'yarn\.lock'
    'package-lock\.json'
    '\.lock$'
    
    # IDE 和编辑器相关
    '^\.vscode/'
    '^\.idea/'
    '^\.hbuilderx/'
    '\.swp$'
    '\.swo$'
    
    # 版本控制相关
    '^\.git/'
    '\.patch$'
    
    # 日志文件
    '\.log$'
    
    # Java 相关
    '\.class$'
    '\.jar$'
    '\.war$'
    '\.ear$'
    
    # Vue 相关
    '^public/'
)

# 添加用户自定义的排除模式
for pattern in "${custom_exclude_patterns[@]}"; do
    exclude_patterns+=("$pattern")
done

# 构建 grep 排除模式
grep_pattern=""
for pattern in "${exclude_patterns[@]}"; do
    if [ -z "$grep_pattern" ]; then
        grep_pattern="$pattern"
    else
        grep_pattern="$grep_pattern|$pattern"
    fi
done

# 获取分支差异文件列表
files=$(git diff --name-only "$current_branch" "$compare_branch" 2>/dev/null)

# 检查 git diff 命令是否成功执行
if [ $? -ne 0 ]; then
    echo "❌ 错误: 无法比较分支差异，请检查分支名称是否正确"
    echo "当前分支: $current_branch"
    echo "对比分支: $compare_branch"
    exit 1
fi

# 应用文件过滤器
if [ -n "$files" ] && [ -n "$grep_pattern" ]; then
    files=$(echo "$files" | grep -Ev "$grep_pattern")
fi

# 如果没有需要对比的文件，则退出
if [ -z "$files" ]; then
    echo "🎉 没有需要对比的文件，$current_branch 分支与 $compare_branch 分支无差异"
    exit 0
fi

# 使用数组存储文件列表，提高处理效率
IFS=$'\n'
files_array=($files)
total_files=${#files_array[@]}

# 显示需要对比的文件列表
echo "🔍 发现以下差异文件:"
for i in "${!files_array[@]}"; do
    printf "%4d. %s\n" $((i+1)) "${files_array[i]}"
done
echo ""
echo "共计: $total_files 个文件"

# 安全转义函数，防止命令注入
safe_escape() {
    local input="$1"
    # 使用 printf %q 进行安全转义
    printf "%q" "$input"
}

# 同步文件到指定分支并提交
sync_and_commit() {
    local source_branch="$1"
    local target_branch="$2"
    local file="$3"
    local commit_message="$4"
    
    # 保存当前分支
    local original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    
    # 切换到目标分支
    if ! git checkout "$target_branch" >/dev/null 2>&1; then
        echo "❌ 错误: 无法切换到 $target_branch 分支"
        # 尝试切换回原分支
        git checkout "$original_branch" >/dev/null 2>&1
        return 1
    fi
    
    # 检出源分支的文件到目标分支
    if ! git checkout "$source_branch" -- "$file" >/dev/null 2>&1; then
        echo "❌ 错误: 无法同步文件 $file"
        # 切换回原分支
        git checkout "$original_branch" >/dev/null 2>&1
        return 1
    fi
    
    # 添加并提交更改
    if git add "$file" && git commit -m "$commit_message" >/dev/null 2>&1; then
        echo "✅ 已提交更改到 $target_branch 分支"
    else
        echo "⚠️  警告: 无法自动提交更改，请手动提交"
    fi
    
    # 切换回原分支
    if ! git checkout "$original_branch" >/dev/null 2>&1; then
        echo "⚠️  警告: 无法切换回原分支 $original_branch"
        return 1
    fi
    
    return 0
}

# 处理单个文件对比的函数
process_file() {
    local file=$1
    local index=$2
    local total=$3
    
    # 检查文件是否存在
    if [ -f "$file" ] || git ls-files --error-unmatch "$file" &>/dev/null; then
        echo "[$index/$total] 正在对比: $file"
        echo "  左边: $current_branch 分支"
        echo "  右边: $compare_branch 分支"
        
        # 获取两个分支中文件的修改时间
        left_file_time=$(git log -1 --format="%ct" "$current_branch" -- "$file" 2>/dev/null || echo "0")
        right_file_time=$(git log -1 --format="%ct" "$compare_branch" -- "$file" 2>/dev/null || echo "0")
        
        # 显示文件修改时间
        if [ "$left_file_time" != "0" ]; then
            left_time_str=$(date -d "@$left_file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$left_file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
            echo "  左边文件修改时间: $left_time_str"
        else
            echo "  左边文件修改时间: 未知"
        fi
        
        if [ "$right_file_time" != "0" ]; then
            right_time_str=$(date -d "@$right_file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$right_file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
            echo "  右边文件修改时间: $right_time_str"
        else
            echo "  右边文件修改时间: 未知"
        fi
        
        # 调用 git difftool 查看差异
        git difftool "$current_branch" "$compare_branch" -- "$file"
        
        # 根据文件修改时间自动判断是否需要同步
        if [ "$left_file_time" != "0" ] && [ "$right_file_time" != "0" ]; then
            # 检查是否有时间差异
            if [ "$left_file_time" -gt "$right_file_time" ]; then
                echo ""
                echo "检测到左边($current_branch)的文件更新"
                read -p "是否同步更新? [Y/n]: " sync_choice
                sync_choice=${sync_choice:-Y}
                
                if [[ "$sync_choice" =~ ^[Yy]$ ]]; then
                    sync_and_commit "$current_branch" "$compare_branch" "$file" "同步 $file 文件从 $current_branch 分支"
                else
                    echo "跳过同步"
                fi
            elif [ "$right_file_time" -gt "$left_file_time" ]; then
                echo ""
                echo "检测到右边($compare_branch)的文件更新"
                read -p "是否同步更新? [Y/n]: " sync_choice
                sync_choice=${sync_choice:-Y}
                
                if [[ "$sync_choice" =~ ^[Yy]$ ]]; then
                    sync_and_commit "$compare_branch" "$current_branch" "$file" "同步 $file 文件从 $compare_branch 分支"
                else
                    echo "跳过同步"
                fi
            else
                # 文件时间相同，检查是否有实际的内容差异
                if ! git diff --quiet "$current_branch" "$compare_branch" -- "$file" 2>/dev/null; then
                    echo ""
                    echo "检测到文件内容有差异"
                    read -p "是否同步更新? [Y/n]: " sync_choice
                    sync_choice=${sync_choice:-Y}
                    
                    if [[ "$sync_choice" =~ ^[Yy]$ ]]; then
                        # 询问用户希望同步到哪个分支
                        echo "文件内容有差异但修改时间相同，请选择同步方向:"
                        echo "  1) 将左边($current_branch)的更改同步到右边($compare_branch)"
                        echo "  2) 将右边($compare_branch)的更改同步到左边($current_branch)"
                        read -p "请选择 [1-2]: " direction_choice
                        
                        case $direction_choice in
                            1)
                                sync_and_commit "$current_branch" "$compare_branch" "$file" "同步 $file 文件从 $current_branch 分支"
                                ;;
                            2)
                                sync_and_commit "$compare_branch" "$current_branch" "$file" "同步 $file 文件从 $compare_branch 分支"
                                ;;
                            *)
                                echo "跳过同步"
                                ;;
                        esac
                    else
                        echo "跳过同步"
                    fi
                else
                    echo ""
                    echo "两边文件内容相同，无需同步"
                fi
            fi
        else
            echo ""
            echo "无法确定文件修改时间，跳过自动同步检查"
        fi
    else
        echo "[$index/$total] 文件已删除或不存在: $file"
    fi
}

# 提供更清晰的输入提示
echo ""
read -p "请选择操作 [a]查看所有差异 [n]退出程序 [数字]查看指定文件 [文件路径]查看指定文件: " choice

# 去除空格并转换为小写
choice=$(echo "$choice" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

# 输入验证
if [[ -n "$choice" && "$choice" != "a" && "$choice" != "n" ]]; then
    # 如果输入的是数字，检查是否在有效范围内
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total_files" ]; then
            echo "❌ 错误: 文件编号应在 1 到 $total_files 之间"
            exit 1
        fi
    else
        # 如果输入的不是数字，检查是否是文件路径
        found=false
        for i in "${!files_array[@]}"; do
            if [[ "${files_array[i]}" == "$choice" ]]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            echo "❌ 错误: 无效的文件路径或选项"
            exit 1
        fi
    fi
fi

# 处理退出情况
if [[ "$choice" == "n" || -z "$choice" ]]; then
    echo "已取消操作"
    exit 0
fi

# 处理查看所有文件的情况
if [[ "$choice" == "a" ]]; then
    echo "开始对比所有文件差异..."
    echo "左边: $current_branch 分支"
    echo "右边: $compare_branch 分支"
    
    # 遍历所有文件
    for i in "${!files_array[@]}"; do
        file_index=$((i+1))
        process_file "${files_array[i]}" "$file_index" "$total_files"
    done
    
    echo "✅ 差异对比完成！已处理 $total_files 个文件。"
    
    # 统计需要同步的文件
    sync_left_count=0
    sync_right_count=0
    sync_content_diff_count=0
    
    for file in "${files_array[@]}"; do
        # 获取两个分支中文件的修改时间
        left_file_time=$(git log -1 --format="%ct" "$current_branch" -- "$file" 2>/dev/null || echo "0")
        right_file_time=$(git log -1 --format="%ct" "$compare_branch" -- "$file" 2>/dev/null || echo "0")
        
        # 根据文件修改时间统计需要同步的文件数量
        if [ "$left_file_time" != "0" ] && [ "$right_file_time" != "0" ]; then
            if [ "$left_file_time" -gt "$right_file_time" ]; then
                sync_left_count=$((sync_left_count + 1))
            elif [ "$right_file_time" -gt "$left_file_time" ]; then
                sync_right_count=$((sync_right_count + 1))
            elif ! git diff --quiet "$current_branch" "$compare_branch" -- "$file" 2>/dev/null; then
                sync_content_diff_count=$((sync_content_diff_count + 1))
            fi
        fi
    done
    
    # 如果有需要同步的文件，询问用户是否批量同步
    total_sync_count=$((sync_left_count + sync_right_count + sync_content_diff_count))
    if [ "$total_sync_count" -gt 0 ]; then
        echo ""
        echo "检测到以下文件需要同步:"
        if [ "$sync_left_count" -gt 0 ]; then
            echo "  $sync_left_count 个文件在 $current_branch 分支上更新"
        fi
        if [ "$sync_right_count" -gt 0 ]; then
            echo "  $sync_right_count 个文件在 $compare_branch 分支上更新"
        fi
        if [ "$sync_content_diff_count" -gt 0 ]; then
            echo "  $sync_content_diff_count 个文件内容有差异但时间相同"
        fi
        
        read -p "是否需要自动同步这些文件? [Y/n]: " batch_sync_choice
        batch_sync_choice=${batch_sync_choice:-Y}
        
        if [[ "$batch_sync_choice" =~ ^[Yy]$ ]]; then
            # 执行批量同步
            for file in "${files_array[@]}"; do
                # 获取两个分支中文件的修改时间
                left_file_time=$(git log -1 --format="%ct" "$current_branch" -- "$file" 2>/dev/null || echo "0")
                right_file_time=$(git log -1 --format="%ct" "$compare_branch" -- "$file" 2>/dev/null || echo "0")
                
                # 根据文件修改时间执行同步
                if [ "$left_file_time" != "0" ] && [ "$right_file_time" != "0" ]; then
                    if [ "$left_file_time" -gt "$right_file_time" ]; then
                        echo "正在将 $current_branch 分支的更改同步到 $compare_branch 分支: $file"
                        sync_and_commit "$current_branch" "$compare_branch" "$file" "同步 $file 文件从 $current_branch 分支"
                    elif [ "$right_file_time" -gt "$left_file_time" ]; then
                        echo "正在将 $compare_branch 分支的更改同步到 $current_branch 分支: $file"
                        sync_and_commit "$compare_branch" "$current_branch" "$file" "同步 $file 文件从 $compare_branch 分支"
                    elif ! git diff --quiet "$current_branch" "$compare_branch" -- "$file" 2>/dev/null; then
                        # 文件内容有差异但时间相同，需要用户选择同步方向
                        echo "文件 $file 内容有差异但修改时间相同，请选择同步方向:"
                        echo "  1) 将左边($current_branch)的更改同步到右边($compare_branch)"
                        echo "  2) 将右边($compare_branch)的更改同步到左边($current_branch)"
                        read -p "请选择 [1-2] (跳过请输入其他值): " direction_choice
                        
                        case $direction_choice in
                            1)
                                echo "正在将 $current_branch 分支的更改同步到 $compare_branch 分支: $file"
                                sync_and_commit "$current_branch" "$compare_branch" "$file" "同步 $file 文件从 $current_branch 分支"
                                ;;
                            2)
                                echo "正在将 $compare_branch 分支的更改同步到 $current_branch 分支: $file"
                                sync_and_commit "$compare_branch" "$current_branch" "$file" "同步 $file 文件从 $compare_branch 分支"
                                ;;
                            *)
                                echo "跳过文件 $file 的同步"
                                ;;
                        esac
                    fi
                fi
            done
            echo "✅ 批量文件同步完成"
        else
            echo "跳过批量同步"
        fi
    else
        echo ""
        echo "所有文件都相同，无需同步"
    fi
else
    # 处理单个文件或按编号选择文件的情况
    found=false
    for i in "${!files_array[@]}"; do
        file_index=$((i+1))
        if [[ "$choice" == "${files_array[i]}" || "$choice" == "$file_index" ]]; then
            process_file "${files_array[i]}" "$file_index" "$total_files"
            found=true
            break
        fi
    done
    
    # 如果没有找到匹配的文件
    if [ "$found" = false ]; then
        echo "❌ 错误: 无效的文件路径或编号"
        exit 1
    fi
fi
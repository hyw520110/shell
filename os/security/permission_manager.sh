#!/bin/bash

# 文件/目录权限管理脚本
# 功能：解读指定文件或目录的权限，并可设置权限

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] [文件/目录路径]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -s, --set      设置权限模式 (例如: 755, 644)"
    echo "  -u, --user     设置所有者"
    echo "  -g, --group    设置组"
    echo "  -r, --recursive 递归处理目录"
    echo ""
    echo "示例:"
    echo "  $0                    # 解读当前目录权限"
    echo "  $0 /path/to/file      # 解读指定文件权限"
    echo "  $0 -s 755 /path/file  # 设置文件权限为755"
    echo "  $0 -u user1 file      # 设置文件所有者为user1"
    echo "  $0 -s 644 -u user1 -g group1 file  # 同时设置权限、所有者和组"
    echo "  $0 -r /path/dir       # 递归解读目录权限"
}

# 解析权限位为rwx格式
parse_permissions() {
    local perm_num=$1
    local result=""
    
    # 所有者权限
    (( perm_num & 4 )) && result="${result}r" || result="${result}-"
    (( perm_num & 2 )) && result="${result}w" || result="${result}-"
    (( perm_num & 1 )) && result="${result}x" || result="${result}-"
    
    echo "$result"
}

# 解读权限
interpret_permissions() {
    local file=$1
    if [[ ! -e "$file" ]]; then
        echo -e "${RED}错误: 文件或目录 '$file' 不存在${NC}"
        return 1
    fi
    
    # 获取文件信息
    local perm=$(stat -c "%A" "$file")
    local owner_uid=$(stat -c "%u" "$file")
    local group_gid=$(stat -c "%g" "$file")
    local owner_name=$(stat -c "%U" "$file")
    local group_name=$(stat -c "%G" "$file")
    local size=$(stat -c "%s" "$file")
    local mtime=$(stat -c "%y" "$file")
    local filename="$file"
    local basename_filename=$(basename "$filename")
    
    # 解析权限位
    local file_type=${perm:0:1}
    local owner_part=${perm:1:3}
    local group_part=${perm:4:3}
    local other_part=${perm:7:3}
    
    # 计算权限数字
    local owner_digit=0
    local group_digit=0
    local other_digit=0
    
    # 计算所有者权限数字
    [[ "${owner_part:0:1}" == "r" ]] && ((owner_digit+=4))
    [[ "${owner_part:1:1}" == "w" ]] && ((owner_digit+=2))
    [[ "${owner_part:2:1}" == "x" ]] && ((owner_digit+=1))
    
    # 计算组权限数字
    [[ "${group_part:0:1}" == "r" ]] && ((group_digit+=4))
    [[ "${group_part:1:1}" == "w" ]] && ((group_digit+=2))
    [[ "${group_part:2:1}" == "x" ]] && ((group_digit+=1))
    
    # 计算其他用户权限数字
    [[ "${other_part:0:1}" == "r" ]] && ((other_digit+=4))
    [[ "${other_part:1:1}" == "w" ]] && ((other_digit+=2))
    [[ "${other_part:2:1}" == "x" ]] && ((other_digit+=1))
    
    local owner_perm="$owner_part"
    local group_perm="$group_part"
    local other_perm="$other_part"
    
    # 格式化大小
    local formatted_size=""
    if [[ $size -lt 1024 ]]; then
        formatted_size="${size}B"
    elif [[ $size -lt 1048576 ]]; then
        formatted_size="$(printf "%.1fK" $(echo "scale=1; $size/1024" | bc))"
    elif [[ $size -lt 1073741824 ]]; then
        formatted_size="$(printf "%.1fM" $(echo "scale=1; $size/1048576" | bc))"
    else
        formatted_size="$(printf "%.1fG" $(echo "scale=1; $size/1073741824" | bc))"
    fi
    
    # 格式化时间
    local formatted_time=$(date -d "$mtime" "+%m月%d日 %H:%M")
    
    # 显示详细信息（类似ls -lrth格式）
    echo "  $perm $owner_name $group_name $formatted_size $formatted_time $basename_filename"
    echo ""
    
    # 显示权限解读
    local file_type_desc=""
    case "$file_type" in
        "d") file_type_desc="目录" ;;
        "l") file_type_desc="链接" ;;
        "c") file_type_desc="字符设备" ;;
        "b") file_type_desc="块设备" ;;
        "p") file_type_desc="管道" ;;
        "s") file_type_desc="套接字" ;;
        "-") file_type_desc="文件" ;;
        *) file_type_desc="其他" ;;
    esac
    
    # 权限描述
    local owner_desc=""
    local group_desc=""
    local other_desc=""
    
    case "$owner_digit" in
        "7") owner_desc="可读写执行" ;;
        "6") owner_desc="可读写" ;;
        "5") owner_desc="可读执行" ;;
        "4") owner_desc="可读" ;;
        "3") owner_desc="可写执行" ;;
        "2") owner_desc="可写" ;;
        "1") owner_desc="可执行" ;;
        "0") owner_desc="无权限" ;;
        *) owner_desc="未知权限" ;;
    esac
    
    case "$group_digit" in
        "7") group_desc="可读写执行" ;;
        "6") group_desc="可读写" ;;
        "5") group_desc="可读执行" ;;
        "4") group_desc="可读" ;;
        "3") group_desc="可写执行" ;;
        "2") group_desc="可写" ;;
        "1") group_desc="可执行" ;;
        "0") group_desc="无权限" ;;
        *) group_desc="未知权限" ;;
    esac
    
    case "$other_digit" in
        "7") other_desc="可读写执行" ;;
        "6") other_desc="可读写" ;;
        "5") other_desc="可读执行" ;;
        "4") other_desc="可读" ;;
        "3") other_desc="可写执行" ;;
        "2") other_desc="可写" ;;
        "1") other_desc="可执行" ;;
        "0") other_desc="无权限" ;;
        *) other_desc="未知权限" ;;
    esac
    
    echo "权限解读: $file_type_desc$owner_digit$group_digit$other_digit 所有者$owner_desc 组$group_desc 其他用户$other_desc"
    echo ""
    
    # 显示详细解读
    echo "详细解读($perm):"
    case "$file_type" in
        "d") echo "d目录" ;;
        "l") echo "l链接" ;;
        "c") echo "c字符设备" ;;
        "b") echo "b块设备" ;;
        "p") echo "p管道" ;;
        "s") echo "s套接字" ;;
        "-") echo "-文件" ;;
        *) echo "$file_type其他" ;;
    esac
    
    # 显示各部分权限
    local r1="${owner_part:0:1}"
    local w1="${owner_part:1:1}"
    local x1="${owner_part:2:1}"
    local r2="${group_part:0:1}"
    local w2="${group_part:1:1}"
    local x2="${group_part:2:1}"
    local r3="${other_part:0:1}"
    local w3="${other_part:1:1}"
    local x3="${other_part:2:1}"
    
    # 转换权限字符为数字
    local r1_num=0
    local w1_num=0
    local x1_num=0
    local r2_num=0
    local w2_num=0
    local x2_num=0
    local r3_num=0
    local w3_num=0
    local x3_num=0
    
    [[ "$r1" == "r" ]] && r1_num=4
    [[ "$w1" == "w" ]] && w1_num=2
    [[ "$x1" == "x" ]] && x1_num=1
    [[ "$r2" == "r" ]] && r2_num=4
    [[ "$w2" == "w" ]] && w2_num=2
    [[ "$x2" == "x" ]] && x2_num=1
    [[ "$r3" == "r" ]] && r3_num=4
    [[ "$w3" == "w" ]] && w3_num=2
    [[ "$x3" == "x" ]] && x3_num=1
    
    echo "$owner_perm($owner_digit) 所有者($owner_name): r(读$r1_num)+w(写$w1_num)+x(执行$x1_num)"
    echo "$group_perm($group_digit) 组($group_name): r(读$r2_num)+w(写$w2_num)+x(执行$x2_num)"
    echo "$other_perm($other_digit) 其他用户: r(读$r3_num)+w(写$w3_num)+x(执行$x3_num)"
    echo ""
}

# 解读目录权限（支持递归）
interpret_directory_permissions() {
    local dir=$1
    local recursive=$2
    local abs_path=$(realpath "$dir")
    local basename_dir=$(basename "$abs_path")
    
    # 检查目录下是否有文件或子目录
    local file_count=0
    for item in "$dir"/*; do
        if [[ -e "$item" ]]; then
            ((file_count++))
        fi
    done
    
    # 显示目录信息
    echo -e "${BLUE}目录: $abs_path${NC}"
    interpret_permissions "$dir"
    
    
    # 如果没有内容，直接返回
    if [[ $file_count -eq 0 ]]; then
        return
    fi
    
    # 如果是递归模式，直接处理
    if [[ "$recursive" == true ]]; then
        process_directory_recursive "$dir" 1
        return
    fi
    
    # 如果目录没有子目录，也不询问
    local dir_count=0
    for item in "$dir"/*; do
        if [[ -d "$item" && -e "$item" ]]; then
            ((dir_count++))
        fi
    done
    
    # 如果没有子目录，只显示文件
    if [[ $dir_count -eq 0 ]]; then
        process_directory_contents "$dir"
        return
    fi
    
    # 如果是当前目录，询问是否递归
    if [[ "$dir" == "." ]]; then
        read -p "是否递归解读子目录权限? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            process_directory_recursive "$dir" 1
        else
            process_directory_contents "$dir"
        fi
        return
    fi
    
    # 对于其他有子目录的目录，询问是否递归
    read -p "是否递归解读子目录权限? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        process_directory_recursive "$dir" 1
    else
        process_directory_contents "$dir"
    fi
}

# 处理目录内容（非递归）
process_directory_contents() {
    local dir=$1
    
    # 显示目录下的文件和子目录
    for item in "$dir"/*; do
        if [[ -e "$item" ]]; then
            local abs_item=$(realpath "$item")
            echo -e "${BLUE}$abs_item:${NC}"
            interpret_permissions "$item"
            echo ""
        fi
    done
}

# 递归处理目录
process_directory_recursive() {
    local dir=$1
    local depth=$2
    
    # 遍历目录内容
    for item in "$dir"/*; do
        if [[ -e "$item" ]]; then
            local abs_item=$(realpath "$item")
            local indent=$(printf "%*s" $((depth * 2)) "")
            
            echo -e "${BLUE}${indent}$abs_item:${NC}"
            interpret_permissions "$item"
            
            if [[ -d "$item" ]]; then
                # 递归处理子目录
                process_directory_recursive "$item" $((depth + 1))
            fi
        fi
    done
}

# 设置权限
set_permissions() {
    local perm=$1
    local file=$2
    
    if [[ ! -e "$file" ]]; then
        echo -e "${RED}错误: 文件或目录 '$file' 不存在${NC}"
        return 1
    fi
    
    # 验证权限格式
    if [[ ! "$perm" =~ ^[0-7]{3,4}$ ]]; then
        echo -e "${RED}错误: 权限格式不正确，应为3位或4位数字 (例如: 755, 0644)${NC}"
        return 1
    fi
    
    # 设置权限
    if chmod "$perm" "$file"; then
        echo -e "${GREEN}成功设置权限 '$perm' 到 '$file'${NC}"
    else
        echo -e "${RED}错误: 无法设置权限 '$perm' 到 '$file'${NC}"
        return 1
    fi
}

# 设置所有者
set_owner() {
    local owner=$1
    local file=$2
    
    if [[ ! -e "$file" ]]; then
        echo -e "${RED}错误: 文件或目录 '$file' 不存在${NC}"
        return 1
    fi
    
    # 设置所有者
    if chown "$owner" "$file"; then
        echo -e "${GREEN}成功设置所有者 '$owner' 到 '$file'${NC}"
    else
        echo -e "${RED}错误: 无法设置所有者 '$owner' 到 '$file'${NC}"
        return 1
    fi
}

# 设置组
set_group() {
    local group=$1
    local file=$2
    
    if [[ ! -e "$file" ]]; then
        echo -e "${RED}错误: 文件或目录 '$file' 不存在${NC}"
        return 1
    fi
    
    # 设置组
    if chgrp "$group" "$file"; then
        echo -e "${GREEN}成功设置组 '$group' 到 '$file'${NC}"
    else
        echo -e "${RED}错误: 无法设置组 '$group' 到 '$file'${NC}"
        return 1
    fi
}

# 主程序
main() {
    local target="."
    local perm=""
    local owner=""
    local group=""
    local recursive=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--set)
                if [[ -n "$2" && "$2" != -* ]]; then
                    perm="$2"
                    shift 2
                else
                    echo -e "${RED}错误: -s/--set 参数需要一个权限值${NC}"
                    exit 1
                fi
                ;;
            -u|--user)
                if [[ -n "$2" && "$2" != -* ]]; then
                    owner="$2"
                    shift 2
                else
                    echo -e "${RED}错误: -u/--user 参数需要一个用户名${NC}"
                    exit 1
                fi
                ;;
            -g|--group)
                if [[ -n "$2" && "$2" != -* ]]; then
                    group="$2"
                    shift 2
                else
                    echo -e "${RED}错误: -g/--group 参数需要一个组名${NC}"
                    exit 1
                fi
                ;;
            -r|--recursive)
                recursive=true
                shift
                ;;
            -*)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                show_help
                exit 1
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done
    
    # 如果没有指定目标，则使用当前目录
    if [[ -z "$target" ]]; then
        target="."
    fi
    
    # 检查目标是否存在
    if [[ ! -e "$target" ]]; then
        echo -e "${RED}错误: 目标 '$target' 不存在${NC}"
        exit 1
    fi
    
    # 执行操作
    if [[ -n "$perm" || -n "$owner" || -n "$group" ]]; then
        echo -e "${BLUE}设置操作:${NC}"
        # 设置权限
        if [[ -n "$perm" ]]; then
            set_permissions "$perm" "$target"
        fi
        
        # 设置所有者
        if [[ -n "$owner" ]]; then
            set_owner "$owner" "$target"
        fi
        
        # 设置组
        if [[ -n "$group" ]]; then
            set_group "$group" "$target"
        fi
        echo ""
    fi
    
    # 显示权限信息
    if [[ -d "$target" ]]; then
        interpret_directory_permissions "$target" "$recursive"
    else
        interpret_permissions "$target"
    fi
}

# 执行主程序
main "$@"

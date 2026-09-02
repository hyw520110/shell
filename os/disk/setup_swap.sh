#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
交换空间配置脚本

自动配置 Linux 系统 swap 交换空间，智能推荐大小和位置。

用法: ./setup_swap.sh [选项]

选项:
    -h, --help        显示此帮助信息
    -v, --version     显示版本信息
    -s <大小>         指定 swap 大小（单位: GB）
    -p <路径>         指定 swap 文件路径
    -d                删除现有 swap

说明:
    - 自动检测系统内存大小
    - 智能推荐 swap 大小
    - 支持多种使用场景
    - 自动配置 swap 文件
    - 设置合适的权限和参数

使用场景选择:
    1) 普通服务器/桌面 - 平衡性能和内存
    2) 休眠支持 - swap >= RAM 大小
    3) 数据库/大数据 - 高性能需求

swap 大小推荐:
    内存 <= 2GB:   swap = 2GB
    内存 2-4GB:     swap = 4GB
    内存 4-8GB:     swap = 2GB
    内存 8-16GB:    swap = 2GB
    内存 16-32GB:   swap = 1GB
    内存 > 32GB:    swap = 根据需求

示例:
    ./setup_swap.sh                      # 自动配置
    ./setup_swap.sh -s 8 -p /swapfile    # 指定大小和路径
    ./setup_swap.sh -d                     # 删除现有 swap

注意事项:
    - 需要 root 权限运行
    - swap 文件占用磁盘空间
    - swap 性能低于物理内存
    - 建议使用 SSD 存储 swap
    - 配置后立即生效

性能影响:
    - 使用 swap 会显著降低性能
    - 仅在内存不足时使用 swap
    - 过多的 swap 使用可能导致系统卡顿
    - 监控 swap 使用率很重要

监控 swap:
    # 查看 swap 使用情况
    free -h
    swapon -s

    # 监控 swap 性能
    vmstat 1
    iotop

相关命令:
    swapon -s          # 查看 swap 状态
    swapoff -a         # 关闭所有 swap
    swapon /swapfile   # 启用 swap 文件
    fallocate -l 2G /swapfile  # 预分配文件

EOF
}

# 参数解析
SWAP_SIZE=""
SWAP_PATH=""
DELETE_SWAP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "交换空间配置脚本版本: 1.0"
            exit 0
            ;;
        -s)
            SWAP_SIZE="$2"
            shift 2
            ;;
        -p)
            SWAP_PATH="$2"
            shift 2
            ;;
        -d)
            DELETE_SWAP=true
            shift
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# setup_swap.sh - 自动配置 swap 文件的智能脚本
# 支持自动建议大小、路径选择等高级交互功能

# 获取当前内存大小（单位 GB）
get_ram_size() {
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo "$((ram_kb / 1024 / 1024))" # 转换为 GB
}

# 根据用途和内存推荐 Swap 大小
suggest_swap_size() {
    local ram_gb=$1
    local purpose=$2
    case $purpose in
        1) # 普通服务器/桌面
            if [ "$ram_gb" -le 2 ]; then echo 2; elif [ "$ram_gb" -le 4 ]; then echo 4; elif [ "$ram_gb" -le 8 ]; then echo 2; elif [ "$ram_gb" -le 16 ]; then echo 2; elif [ "$ram_gb" -le 32 ]; then echo 1; else echo 0; fi
            ;;
        2) # 休眠
            echo "$ram_gb" # swap >= RAM
            ;;
        3) # 数据库/大数据
            if [ "$ram_gb" -le 4 ]; then echo 4; elif [ "$ram_gb" -le 8 ]; then echo 8; elif [ "$ram_gb" -le 16 ]; then echo 8; elif [ "$ram_gb" -le 32 ]; then echo 8; else echo 16; fi
            ;;
        *)
            echo 2
            ;;
    esac
}

# 获取所有已激活swap的总大小（MB），兼容老版本swapon
get_total_swap_mb() {
    swapon -s | awk 'NR>1 {sum+=$3} END{print int(sum/1024)}'
}

# 检查是否已有激活的 swap（分区或文件），并返回swapfile路径（如有）
check_swap() {
    local swap_info=$(swapon -s)
    local swapfile_path=""
    local total_swap_mb=0
    if [ "$(echo "$swap_info" | wc -l)" -gt 1 ]; then
        if echo "$swap_info" | awk 'NR>1 {print $1,$2}' | grep -q 'file'; then
            swapfile_path=$(echo "$swap_info" | awk 'NR>1 && $2=="file" {print $1; exit}')
            echo "$swapfile_path"
        else
            echo "partition"
        fi
    else
        echo ""
    fi
}

# 创建 swap 文件
create_swap_file() {
    local swap_file=$1
    local size=$2

    echo "正在创建 $size GB 的swap文件于 $swap_file..."
    sudo dd if=/dev/zero of="$swap_file" bs=1G count="$size" status=progress
    sudo chmod 600 "$swap_file"
    sudo mkswap "$swap_file"
    sudo swapon "$swap_file"

    # 添加到 fstab
    if ! grep -Fxq "$swap_file none swap sw 0 0" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
        echo "✅ 已将swap文件信息添加到/etc/fstab。"
    else
        echo "ℹ️ Swap文件信息已在/etc/fstab中。"
    fi

    echo "✅ 交换文件配置完成并启用。"
}

# 平台判断，仅支持 Linux
if [[ "$(uname)" != "Linux" ]]; then
    echo "本脚本仅支持 Linux 系统，当前平台: $(uname)。无需手动管理 swap，已退出。"
    exit 0
fi

main() {
    echo "正在检测系统已有swap信息..."
    swap_status=$(check_swap)
    total_swap_mb=$(get_total_swap_mb)
    DEFAULT_SWAPFILE="/swapfile"
    SWAP_FILE_PATH=""

    if [ -n "$swap_status" ]; then
        # 有 swapfile 或分区
        if [ "$swap_status" = "partition" ]; then
            echo "检测到swap分区，建议保留。脚本结束。" >&2
            exit 0
        else
            # 有 swapfile
            swap_gb=$(( (total_swap_mb + 512) / 1024 ))
            echo "检测到系统已存在${swap_gb}GB swap（${total_swap_mb}MB）："
            swapon -s
            echo -n "检测到swapfile，选择操作：[1]更新swapfile（覆盖） [2]新增swapfile（输入新路径） [3]结束退出 [默认3]: " >&2
            read update_choice
            update_choice=${update_choice:-3}
            if [[ "$update_choice" == "1" ]]; then
                echo "将禁用并删除现有swapfile，准备更新..." >&2
                sudo swapoff "$swap_status" 2>/dev/null || echo "警告: swapoff 失败，可能是文件已经关闭"
                sudo rm -f "$swap_status"
                if [ -n "$swap_status" ]; then
                    # 使用不同的分隔符避免路径中包含/导致的问题
                    sudo sed -i "\#$swap_status#d" /etc/fstab 2>/dev/null || echo "警告: 从fstab中删除条目失败"
                fi
                SWAP_FILE_PATH="$swap_status"
                total_swap_mb=0  # 关键：重置 swap 总量，保证建议正确
            elif [[ "$update_choice" == "2" ]]; then
                echo -n "请输入新的swap文件路径 [$DEFAULT_SWAPFILE]: "
                read SWAP_FILE_PATH
                [ -z "$SWAP_FILE_PATH" ] && SWAP_FILE_PATH="$DEFAULT_SWAPFILE"
            else
                echo "已取消操作，脚本结束。" >&2
                exit 0
            fi
        fi
    else
        # 没有 swap，直接输入路径
        echo "系统当前无已激活 swap。"
        echo -n "请输入 swap 文件路径 [$DEFAULT_SWAPFILE]: "
        read SWAP_FILE_PATH
        if [ -z "$SWAP_FILE_PATH" ]; then
            SWAP_FILE_PATH="$DEFAULT_SWAPFILE"
            echo "使用默认路径: $SWAP_FILE_PATH"
        else
            echo "使用自定义路径: $SWAP_FILE_PATH"
        fi
    fi

    # 检查该路径是否存在
    while [ -f "$SWAP_FILE_PATH" ]; do
        echo "❌ 错误: swap文件 $SWAP_FILE_PATH 已存在。"
        echo -n "请选择操作：[1]更新swapfile（覆盖） [2]新增swapfile（输入新路径） [3]结束退出 [默认3]: "
        read file_choice
        file_choice=${file_choice:-3}
        if [[ "$file_choice" == "1" ]]; then
            echo "将禁用并删除现有swapfile，准备更新..."
            sudo swapoff "$SWAP_FILE_PATH" 2>/dev/null || echo "警告: swapoff 失败，可能是文件已经关闭"
            sudo rm -f "$SWAP_FILE_PATH"
            # 使用不同的分隔符避免路径中包含/导致的问题
            sudo sed -i "\#$SWAP_FILE_PATH#d" /etc/fstab 2>/dev/null || echo "警告: 从fstab中删除条目失败"
            break
        elif [[ "$file_choice" == "2" ]]; then
            echo -n "请输入新的swap文件路径: "
            read SWAP_FILE_PATH
            [ -z "$SWAP_FILE_PATH" ] && SWAP_FILE_PATH="$DEFAULT_SWAPFILE"
        else
            echo "已取消操作，脚本结束。"
            exit 0
        fi
    done
    RAM_GB=$(get_ram_size)

    # 用途选择
    SUGGESTED1=$(suggest_swap_size "$RAM_GB" 1)
    SUGGESTED2=$(suggest_swap_size "$RAM_GB" 2)
    SUGGESTED3=$(suggest_swap_size "$RAM_GB" 3)
    REMAIN1=$(( SUGGESTED1*1024-total_swap_mb )); [ $REMAIN1 -lt 0 ] && REMAIN1=0
    REMAIN2=$(( SUGGESTED2*1024-total_swap_mb )); [ $REMAIN2 -lt 0 ] && REMAIN2=0
    REMAIN3=$(( SUGGESTED3*1024-total_swap_mb )); [ $REMAIN3 -lt 0 ] && REMAIN3=0
    SUGGEST_TXT1=$(( (REMAIN1+1023)/1024 ))
    SUGGEST_TXT2=$(( (REMAIN2+1023)/1024 ))
    SUGGEST_TXT3=$(( (REMAIN3+1023)/1024 ))
    echo "请选择用途:"
    echo "  1) 普通服务器/桌面 (建议 ${SUGGEST_TXT1}GB)"
    echo "  2) 需要休眠 (建议 ${SUGGEST_TXT2}GB)"
    echo "  3) 数据库/大数据/特殊场景 (建议 ${SUGGEST_TXT3}GB)"
    echo "  4) 自定义大小"
    echo -n "请输入用途编号 [1]: "
    read PURPOSE
    PURPOSE=${PURPOSE:-1}

    if [[ "$PURPOSE" == "4" ]]; then
        echo -n "请输入swap大小（支持如2G、2048M，单位GB/M）: "
        read SIZE_INPUT
        if [[ "$SIZE_INPUT" =~ ^[0-9]+[Gg]$ ]]; then
            SIZE_GB=${SIZE_INPUT%[Gg]}
        elif [[ "$SIZE_INPUT" =~ ^[0-9]+[Mm]$ ]]; then
            SIZE_MB=${SIZE_INPUT%[Mm]}
            SIZE_GB=$((SIZE_MB / 1024))
            [ $((SIZE_MB % 1024)) -ne 0 ] && SIZE_GB=$((SIZE_GB + 1))
        elif [[ "$SIZE_INPUT" =~ ^[0-9]+$ ]]; then
            SIZE_GB=$SIZE_INPUT
        else
            echo "❌ 输入无效，必须为正整数或带单位的数字（如2G、2048M）。"
            exit 1
        fi
    else
        # 推荐 swap 大小
        SUGGESTED_SWAP=$(suggest_swap_size "$RAM_GB" "$PURPOSE")
        SUGGESTED_SWAP_MB=$((SUGGESTED_SWAP * 1024))
        REMAIN_SWAP_MB=$((SUGGESTED_SWAP_MB - total_swap_mb))
        if [ $REMAIN_SWAP_MB -le 0 ]; then
            echo "当前系统已有swap总量(${total_swap_mb}MB)已满足建议，无需新增。"
            exit 0
        fi
        SIZE_GB=$(( (REMAIN_SWAP_MB + 1023) / 1024 ))
        echo "使用建议新增大小: ${SIZE_GB}GB"
    fi

    echo -n "确认新增swap大小: ${SIZE_GB}GB吗？[Y/n]: "
    read CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        echo "已取消操作，脚本结束。"
        exit 0
    fi

    create_swap_file "$SWAP_FILE_PATH" "$SIZE_GB"
    echo "当前交换状态(执行swapon -s或grep swap /etc/fstab):"
    swapon -s
	echo "设置优先级(数值越大优先级越高):sudo swapon -p 10 /swapfile"
	echo "关闭所有交换空间执行：sudo swapoff -a"
	echo "启用所有交换空间执行: sudo swapon -a"
}

main
#!/bin/bash

# setup_swap.sh - 自动配置 swap 文件的智能脚本
# 支持自动建议大小、路径选择、超时确认等高级交互功能

# 获取当前内存大小（单位 GB）
get_ram_size() {
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo "$((ram_kb / 1024 / 1024))" # 转换为 GB
}

# 根据内存大小推荐 Swap 大小
suggest_swap_size() {
    local ram_gb=$1
    local enable_hibernate=false

    # 自动检测是否启用休眠
    if systemctl is-enabled hibernate &>/dev/null; then
        echo "$ram_gb"
    else
        if [ "$ram_gb" -le 2 ]; then
            echo 2
        elif [ "$ram_gb" -le 4 ]; then
            echo 4
        elif [ "$ram_gb" -le 8 ]; then
            echo 2
        elif [ "$ram_gb" -le 16 ]; then
            echo 2
        elif [ "$ram_gb" -le 32 ]; then
            echo 1
        else
            echo 0
        fi
    fi
}

# 检查是否已有激活的 swap
check_swap() {
    if swapon --show | grep -q 'swap'; then
        echo "警告: 系统中已存在激活的swap分区或文件。"
        exit 1
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

main() {
    check_swap

    # 默认 swap 文件路径
    DEFAULT_SWAPFILE="/swapfile"
    echo -n "请输入swap文件路径 [$DEFAULT_SWAPFILE]: "
    read -t 6 SWAP_FILE_PATH
    if [ -z "$SWAP_FILE_PATH" ]; then
        SWAP_FILE_PATH="$DEFAULT_SWAPFILE"
        echo "使用默认路径: $SWAP_FILE_PATH"
    else
        echo "使用自定义路径: $SWAP_FILE_PATH"
    fi

    # 检查该路径是否存在
    if [ -f "$SWAP_FILE_PATH" ]; then
        echo "❌ 错误: swap文件 $SWAP_FILE_PATH 已存在。"
        exit 1
    fi
	RAM_GB=$(get_ram_size)
    # 推荐 swap 大小
    SUGGESTED_SWAP=$(suggest_swap_size "$RAM_GB")
    if [ $SUGGESTED_SWAP -eq 0 ];then
    	echo "不建议创建" && exit 0
    fi
    echo -n "建议swap大小: ${SUGGESTED_SWAP}GB（当前内存: ${RAM_GB}GB）。确认使用此值吗？[Y/n] (5秒后自动确认): "
    read -t 5 CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        echo -n "请输入swap大小（单位GB）: "
        read SIZE_GB
        if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]]; then
            echo "❌ 输入无效，必须为正整数。"
            exit 1
        fi
    else
        SIZE_GB=$SUGGESTED_SWAP
        echo "使用推荐大小: ${SIZE_GB}GB"
    fi

    create_swap_file "$SWAP_FILE_PATH" "$SIZE_GB"
}

main

#!/bin/bash

# 脚本功能：一个健壮的内存压力测试工具，通过挂载tmpfs来安全地消耗指定大小的内存。

# --- 配置 ---
DEFAULT_MEM_SIZE="1024M" # 默认消耗的内存大小 (例如: 512M, 2G)
MOUNT_POINT="/tmp/memory_stress" # 挂载点
# --- 结束配置 ---

# --- 函数定义 ---

# 日志记录
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 帮助文档
show_help() {
    echo "用法: $0 [大小]"
    echo "  大小 (可选): 要消耗的内存量。例如: 512M, 2G。默认为 ${DEFAULT_MEM_SIZE}。"
    echo
    echo "示例: sudo $0 2G"
}

# 清理函数，由trap在脚本退出时自动调用
cleanup() {
    log_message "收到退出信号，开始释放内存..."
    # mountpoint -q 检查一个目录是否为挂载点
    if mountpoint -q "$MOUNT_POINT"; then
        log_message "正在卸载 $MOUNT_POINT..."
        umount "$MOUNT_POINT"
    fi
    if [ -d "$MOUNT_POINT" ]; then
        log_message "正在移除目录 $MOUNT_POINT..."
        rmdir "$MOUNT_POINT"
    fi
    log_message "内存已释放。"
}

# --- 主程序 ---

# 设置trap，捕获退出信号，确保cleanup函数被执行
trap cleanup EXIT INT TERM

# 1. 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 此脚本必须以root权限运行。请使用 'sudo $0'。" >&2
    exit 1
fi

# 2. 处理参数
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi
MEM_SIZE="${1:-$DEFAULT_MEM_SIZE}"

# 3. 启动前先执行一次清理，以防上次有残留
# trap 会在脚本最终退出时执行，但我们在这里手动调用一次以清理旧的运行实例
if mountpoint -q "$MOUNT_POINT" || [ -d "$MOUNT_POINT" ]; then
    log_message "发现上次运行残留，执行清理..."
    # 手动调用cleanup
    if mountpoint -q "$MOUNT_POINT"; then umount "$MOUNT_POINT"; fi
    if [ -d "$MOUNT_POINT" ]; then rmdir "$MOUNT_POINT"; fi
fi


# 4. 分配内存
log_message "准备分配 ${MEM_SIZE} 内存..."
mkdir -p "$MOUNT_POINT"
if ! mount -t tmpfs -o size="$MEM_SIZE" tmpfs "$MOUNT_POINT"; then
    log_message "错误: 挂载 tmpfs 失败。请检查权限或可用内存。" >&2
    exit 1
fi
log_message "成功在 $MOUNT_POINT 挂载 tmpfs。"

# 5. 填满内存
log_message "正在写入文件以填满内存，这可能需要一点时间..."
# dd命令在写满tmpfs时会因“空间不足”而失败退出，这是预期的行为。
# 我们用 || true 来忽略这个“错误”，防止 set -e 中断脚本。
dd if=/dev/zero of="${MOUNT_POINT}/block" bs=1M status=none 2>/dev/null || true

log_message "内存已成功消耗。按 Ctrl+C 来停止并释放内存。"

# 6. 挂起脚本，持续占用内存
sleep infinity
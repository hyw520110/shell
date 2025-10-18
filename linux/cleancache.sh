#!/bin/bash

# 脚本功能：安全地清理Linux系统的页面、目录和inode缓存。
# 使用场景：主要用于性能测试或特殊情况下的内存释放。不建议在生产环境常规使用。

set -e # 如果任何命令失败，立即退出脚本

# 1. 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
   echo "错误：此脚本必须以root权限运行。请使用 'sudo ./cleancache.sh'。" >&2
   exit 1
fi

echo "--- 清理前内存状态 ---"
free -h
echo

# 2. 同步文件系统，确保所有待写数据落盘
sync

echo "正在清理缓存 (page cache, dentries, and inodes)..."
# 使用 'echo' 的方式兼容性更广，且无需安装额外工具
if echo 3 > /proc/sys/vm/drop_caches; then
    echo "缓存清理成功。"
else
    echo "错误：清理缓存失败。" >&2
    exit 1
fi
echo

echo "--- 清理后内存状态 ---"
free -h
#!/bin/bash

# 脚本功能：在一个目标目录中，删除那些与源目录中项目同名的文件或目录。
# 警告：这是一个破坏性操作，请谨慎使用。

# --- 配置 ---
SOURCE_DIR="/opt/nginx/html"
TARGET_DIR="/opt/nginx"

# 安全开关：设置为 "false" 才会执行真正的删除操作。
# 默认为 "true"，即只打印将要删除的内容，不实际操作。
DRY_RUN=true
# --- 结束配置 ---

set -e # 如果任何命令失败，立即退出脚本

# 1. 检查目录是否存在
if [ ! -d "$SOURCE_DIR" ]; then
    echo "错误: 源目录不存在: $SOURCE_DIR" >&2
    exit 1
fi
if [ ! -d "$TARGET_DIR" ]; then
    echo "错误: 目标目录不存在: $TARGET_DIR" >&2
    exit 1
fi

echo "--- 开始检查 ---"
echo "源目录: $SOURCE_DIR"
echo "目标目录: $TARGET_DIR"
echo "Dry Run 模式: $DRY_RUN"
echo "--------------------------------------------------"

# 2. 使用 find 和 while read 安全地遍历所有文件和目录
# -mindepth 1 -maxdepth 1 只查找第一层
# -print0 和 read -d '' 组合可以处理任何特殊字符的文件名
find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0 | while IFS= read -r -d '' source_item_path; do
    # 提取基本名称
    item_name=$(basename "$source_item_path")
    target_item_path="$TARGET_DIR/$item_name"

    # 检查目标目录中是否存在同名项
    if [ -e "$target_item_path" ]; then
        # 增加一个额外的安全检查，确保源和目标不是同一个文件（例如通过符号链接）
        if [ "$(realpath "$source_item_path")" != "$(realpath "$target_item_path")" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "[演习模式] 将删除: $target_item_path"
            else
                echo "正在删除: $target_item_path"
                rm -rf "$target_item_path"
            fi
        fi
    fi
done

echo "--------------------------------------------------"
if [ "$DRY_RUN" = true ]; then
    echo "演习完成。没有文件被实际删除。"
    echo "要执行真正的删除，请编辑此脚本并将 DRY_RUN 设置为 false。"
else
    echo "删除操作已完成。"
fi
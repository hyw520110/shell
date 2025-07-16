#!/bin/bash

# 定义备份目录（支持命令行参数）
BACKUP_DIR=${1:-"$HOME/backup"}

# 创建备份目录（如果不存在）
mkdir -p "$BACKUP_DIR"

# 获取当前日期
CURRENT_DATE=$(date +%F)

# 备份环境变量
echo "正在备份环境变量..."
env > "$BACKUP_DIR/环境变量_$CURRENT_DATE.txt"

# 备份环境变量配置文件（如 .bashrc, .bash_profile, .profile 等）
echo "正在备份环境变量配置文件..."

# 定义需要备份的环境变量文件列表
ENV_FILES=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.bash_aliases"
    "$HOME/.zshrc"
    "/etc/profile"
    "/etc/bash.bashrc"
    "/etc/environment"
)

# 遍历所有环境变量文件并备份
for file in "${ENV_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        # 构造目标备份路径，保留原始路径结构
        relative_path="${file#/}"  # 去掉路径开头的 "/"
        backup_file="$BACKUP_DIR/$relative_path"
        backup_dir=$(dirname "$backup_file")

        # 创建备份目录（如果不存在）
        mkdir -p "$backup_dir"

        # 复制文件到备份路径
        cp -v "$file" "$backup_file"
    fi
done

# 备份已安装的软件清单
echo "正在备份已安装的软件清单..."

# 清空或创建最终输出文件
SOFTWARE_LIST_FILE="$BACKUP_DIR/已安装软件包清单_$CURRENT_DATE.txt"
> "$SOFTWARE_LIST_FILE"

# 使用 dpkg-query 获取所有已安装软件包的信息，并将软件包名称写入文件
dpkg -l | awk '/^ii/{print $2}' | sort >> "$SOFTWARE_LIST_FILE"

# 生成软件清单文件
echo "正在生成软件清单文件..."
SOFTWARE_LIST_FILE="$BACKUP_DIR/已安装软件清单_$CURRENT_DATE.txt"
> "$SOFTWARE_LIST_FILE"

# 定义要检查的目录
DIRECTORIES=(
    "/var/lib/linglong/"
    "/opt/apps/"
    "$HOME/.local/share/applications/"
)

# 遍历每个目录
for dir in "${DIRECTORIES[@]}"; do
    # 检查目录是否存在
    if [ -d "$dir" ]; then
        # 查找目录下的所有 .desktop 文件
        for file in $(find "$dir" -type f -name "*.desktop"); do
            # 提取 Name 字段
            NAME=$(grep -Po '^Name=\K.*' "$file")
            # 提取 Path 字段
            PATH_FIELD=$(grep -Po '^Path=\K.*' "$file")
            # 如果 Path 字段为空，则尝试提取 Exec 字段
            if [ -z "$PATH_FIELD" ]; then
                EXEC_FIELD=$(grep -Po '^Exec=\K.*' "$file")
                # 从 Exec 字段中提取目录
                if [ -n "$EXEC_FIELD" ]; then
                    PATH_FIELD=$(dirname "$EXEC_FIELD")
                fi
            fi
            # 写入软件清单文件
            if [ -n "$NAME" ] && [ -n "$PATH_FIELD" ]; then
                echo "# $NAME = $PATH_FIELD" >> "$SOFTWARE_LIST_FILE"
            fi
        done
    fi
done

echo "软件清单已生成：$SOFTWARE_LIST_FILE"

# 输出备份完成信息
echo "备份完成： $BACKUP_DIR"
echo "执行恢复脚本：sudo $BACKUP_DIR/recovery.sh"
cp ./recovery.sh "$BACKUP_DIR/"
chmod +x "$BACKUP_DIR"/*.sh
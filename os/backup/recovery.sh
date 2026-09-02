#!/bin/bash

# 动态获取备份目录（脚本所在目录）
SCRIPT_DIR=$(dirname "$(realpath "$0")")
BACKUP_DIR="$SCRIPT_DIR"

# 准确获取当前用户的用户名，即使以 sudo 执行
REAL_USER=$(logname 2>/dev/null || echo "$SUDO_USER" || whoami)
CURRENT_USER=${REAL_USER:-$(whoami)}

# 获取当前用户的主目录
CURRENT_HOME=$(eval echo ~"$CURRENT_USER")

# 检查是否有未安装的软件包并安装
install_missing_packages() {
    echo "正在检查是否有未安装的软件包..."

    # 查找最新的已安装软件清单文件
    SOFTWARE_LIST_FILE=$(ls "$BACKUP_DIR"/已安装软件包清单_*.txt 2>/dev/null | sort -r | head -n1)
    if [[ -z "$SOFTWARE_LIST_FILE" ]]; then
        echo "未找到已安装软件清单文件，跳过软件包检查。"
        return
    fi

    missing_packages=$(grep -v '^#' "$SOFTWARE_LIST_FILE" | xargs -n1 sh -c '
        dpkg -s "$0" >/dev/null 2>&1 || echo "$0"
    ' --)

    if [ -z "$missing_packages" ]; then
        echo "所有软件包均已安装，无需执行安装操作。"
    else
        echo "以下软件包需要安装："
        echo "$missing_packages"
        read -rp "是否安装这些软件包？(y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            sudo apt-get update && \\
            echo "$missing_packages" | xargs sudo apt-get install -y
        else
            echo "跳过安装操作。"
        fi
    fi
}

# 检查环境变量文件差异并更新
check_env_diff() {
    local backup_file="$1"
    # 去掉 $BACKUP_DIR 路径，保留子目录
    target_file="${backup_file#$BACKUP_DIR}"

    if [[ ! -f "$target_file" ]]; then
        # 替换路径中的原用户名为当前用户名
        target_file="${target_file/$ORIGINAL_HOME/$CURRENT_HOME}"
    fi
    if [[ ! -f "$target_file" ]]; then
        echo "$target_file 不存在，无法恢复。"
        return 1
    fi

    diff_output=$(diff "$target_file" "$backup_file")
    if [[ -n "$diff_output" ]]; then
        echo "发现差异："
        echo "$diff_output"
        read -rp "是否将差异内容应用到当前系统文件中？(y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            if [[ "$target_file" == /etc/* ]]; then
                # 系统级文件需要 sudo 权限
                sudo cp -v "$backup_file" "$target_file"
                echo "已更新系统文件：$target_file"
            else
                # 用户级文件无需 sudo
                cp -v "$backup_file" "$target_file"
                echo "已更新用户文件：$target_file"
            fi
        else
            echo "跳过更新系统文件。"
        fi
    else
        echo "$target_file 没有变化，无需更新。"
    fi
}

# 主逻辑
echo "正在执行恢复操作..."

# 获取备份用户的主目录
ORIGINAL_HOME=$(stat -c '%U' "$BACKUP_DIR" 2>/dev/null || echo "$CURRENT_HOME")

# 1. 安装缺失的软件包
install_missing_packages

# 2. 遍历所有环境变量文件并检查差异
echo "正在恢复环境变量配置文件..."

# 使用 find 命令递归遍历备份目录下的所有文件
find "$BACKUP_DIR" -type f | while read -r file; do
    # 排除根目录下的非配置文件
    if [[ "$file" != "$BACKUP_DIR/"*".txt" && "$file" != "$BACKUP_DIR/"*".sh" ]]; then
        check_env_diff "$file"
    fi
done

echo "一键恢复脚本执行完毕。"
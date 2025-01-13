#!/bin/bash

# 定义本地仓库路径、日志文件路径和工作空间路径
REPO_PATH="$HOME/.m2/repository"
LOG_FILE="$HOME/maven-repo-cleanup.log"
WORKSPACE_PATH="$HOME/workspace"  # 替换为你的实际工作空间路径

# 定义保留期限（以天为单位）
RETENTION_DAYS=30

# 创建日志目录（如果不存在）
mkdir -p "$(dirname "$LOG_FILE")"

# 打印开始时间和信息到日志文件
echo "[$(date)] 开始清理 Maven 本地仓库..." >> "$LOG_FILE"

# 检查是否安装了 GNU parallel
if ! command -v parallel &> /dev/null; then
    echo "GNU parallel 未安装，正在安装..."

    # 检查操作系统类型并安装 parallel
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        case $ID in
            ubuntu|debian|Deepin)
                sudo apt-get update && sudo apt-get install -y parallel
                ;;
            centos|rhel|fedora)
                sudo yum install -y parallel
                ;;
            *)
                echo "未知的操作系统，无法自动安装 parallel。请手动安装。"
                exit 1
                ;;
        esac
    else
        echo "无法检测操作系统，无法自动安装 parallel。请手动安装。"
        exit 1
    fi
fi

# 提取所有 artifactId（如果 WORKSPACE_PATH 存在）
if [ -d "$WORKSPACE_PATH" ]; then
    ARTIFACT_IDS=$(find "$WORKSPACE_PATH" -type f -name "pom.xml" -print0 | xargs -0 grep -oP '(?<=<artifactId>)[^<]+(?=</artifactId>)' | sort -u)
else
    ARTIFACT_IDS=""
fi

# 使用 find 和 parallel 处理文件
find "$REPO_PATH" -type f -atime +$RETENTION_DAYS $ -name "*.jar" -o -name "*.pom" $ -print0 | \
    parallel -0 -j $(nproc) --progress bash -c '
        local file="{}"
        if [ -n "$0" ]; then
            if [[ $file == *.jar ]]; then
                local artifact_id=$(basename "$file" | sed -E "s/.*-([^-]+)-[0-9.]+\.jar/\1/")
                if ! echo "$0" | grep -qxF "$artifact_id"; then
                    echo "删除未引用的文件: $file" >> "'"$LOG_FILE"'"
                    rm -f "$file"
                else
                    echo "文件仍在使用: $file" >> "'"$LOG_FILE"'"
                fi
            else
                echo "删除超过保留期限的文件: $file" >> "'"$LOG_FILE"'"
                rm -f "$file"
            fi
        else
            echo "工作空间路径 '$WORKSPACE_PATH' 不存在。删除超过保留期限的文件: $file" >> "'"$LOG_FILE"'"
            rm -f "$file"
        fi
    ' _ "$ARTIFACT_IDS"

# 删除空目录
find "$REPO_PATH" -type d -empty -delete

# 清理 .lastUpdated 文件
find "$REPO_PATH" -type f -name "*lastUpdated*" -delete

# 打印结束时间和信息到日志文件
echo "[$(date)] 清理完成。" >> "$LOG_FILE"

#!/bin/bash

# 定义本地仓库路径和日志文件路径
REPO_PATH="$HOME/.m2/repository"
LOG_FILE="$HOME/maven-repo-cleanup.log"

# 定义保留期限（以天为单位）
RETENTION_DAYS=30

# 创建日志目录（如果不存在）
mkdir -p "$(dirname "$LOG_FILE")"

# 打印开始时间和信息到日志文件
echo "[$(date)] Starting cleanup of Maven local repository..." >> "$LOG_FILE"

# 查找并删除过去 $RETENTION_DAYS 天内未被访问的文件
find "$REPO_PATH" -type f -atime +$RETENTION_DAYS -name "*.jar" -o -name "*.pom" | while read -r file; do
    # 检查文件是否还在任何 pom.xml 文件中被引用
    if ! grep -qRlF --include="*.xml" --exclude-dir=".git" --exclude-dir="target" "$(basename "$file")" "$HOME/*"; then
        echo "Removing unused file: $file" >> "$LOG_FILE"
        rm -f "$file"
    else
        echo "File still in use: $file" >> "$LOG_FILE"
    fi
done

# 删除空目录
find "$REPO_PATH" -type d -empty -delete

# 打印结束时间和信息到日志文件
echo "[$(date)] Cleanup completed." >> "$LOG_FILE"

find ~/.m2 -type f -name "*lastUpdated*" |xargs rm -rf 

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

# 提取所有 artifactId（如果 WORKSPACE_PATH 存在）
if [ -d "$WORKSPACE_PATH" ]; then
    ARTIFACT_IDS=$(find "$WORKSPACE_PATH" -type f -name "pom.xml" -print0 | xargs -0 grep -oP '(?<=<artifactId>)[^<]+(?=</artifactId>)' | sort -u)
else
    ARTIFACT_IDS=""
fi

# 定义处理单个文件的函数
process_file() {
    local file="$1"
    local artifact_ids="$2"
    if [ -n "$artifact_ids" ]; then
        if [[ $file == *.jar ]]; then
            local artifact_id=$(basename "$file" | sed -E "s/.*-([^-]+)-[0-9.]+\.jar/\1/")
            if ! echo "$artifact_ids" | grep -qxF "$artifact_id"; then
                echo "删除未引用的文件: $file" >> "$LOG_FILE"
                rm -f "$file"
            else
                echo "文件仍在使用: $file" >> "$LOG_FILE"
            fi
        elif [[ $file == *.pom ]]; then
            echo "删除超过保留期限的文件: $file" >> "$LOG_FILE"
            rm -f "$file"
        fi
    else
        echo "工作空间路径 '$WORKSPACE_PATH' 不存在。删除超过保留期限的文件: $file" >> "$LOG_FILE"
        rm -f "$file"
    fi
}

# 使用 find 处理文件
# 直接遍历并处理文件
while IFS= read -r -d '' file; do
    echo "Processing file: $file" >&2
    process_file "$file" "$ARTIFACT_IDS"
done < <(find "$REPO_PATH" -type f $ -name "*.jar" -o -name "*.pom" $ -atime +"$RETENTION_DAYS" -print0)

# 删除空目录
find "$REPO_PATH" -type d -empty -delete

# 清理 .lastUpdated 文件
find "$REPO_PATH" -type f -name "*lastUpdated*" -delete

# 打印结束时间和信息到日志文件
echo "[$(date)] 清理完成。" >> "$LOG_FILE"
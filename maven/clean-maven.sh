#!/bin/bash

# === 基础配置 ===
REPO_PATH="$HOME/.m2/repository"
LOG_FILE="$HOME/maven-repo-cleanup.log"
WORKSPACE_PATH="$HOME/workspace2"
RETENTION_DAYS=60
DRY_RUN=false

# === 环境检查 ===
if ! command -v bc > /dev/null 2>&1; then
    echo "错误: 需要安装 'bc' 工具来进行大小计算" >&2
    exit 1
fi

# === 日志系统 ===
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 工具函数 ===
get_dir_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
}

format_size() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1024*1024 )); then
        echo "$(( (bytes + 512) / 1024 ))KB"
    elif (( bytes < 1024*1024*1024 )); then
        echo "$(( (bytes + 512*1024) / (1024*1024) ))MB"
    else
        printf "%.1fGB\n" "$(echo "scale=1; $bytes/(1024*1024*1024)" | bc)"
    fi
}

# === 主程序 ===
main() {
    log "=== 开始清理Maven仓库 ==="

    initial_size=$(get_dir_size "$REPO_PATH")
    initial_size=${initial_size:-0}
    log "清理前仓库大小: $(format_size "$initial_size")"

    declare -a dependencies=()

    # === 收集所有 pom.xml 文件（排除 target 目录） ===
    POM_FILES=()
    if [ -d "$WORKSPACE_PATH" ]; then
        log "开始扫描工作目录: $WORKSPACE_PATH"
        while IFS= read -r -d '' file; do
            POM_FILES+=("$file")
        done < <(find "$WORKSPACE_PATH" -type f -name 'pom.xml' ! -path '*/target/*' -print0)
    else
        log "未找到工作目录: $WORKSPACE_PATH"
    fi

    # === 为每个 pom.xml 生成依赖列表（不创建临时文件） ===
    for pom in "${POM_FILES[@]}"; do
        log "处理: $pom"
        # 直接通过管道读取 mvn 命令的输出
        if mvn -f "$pom" dependency:tree 2>/dev/null | grep '^$$INFO$$'|grep ".jar" > /dev/null; then
            log "成功生成依赖列表"
            while IFS= read -r line; do
                if [[ $line =~ ^$$INFO$$\ ([^:]+):([^:]+):jar:([^:]+): ]]; then
                    artifact=${BASH_REMATCH[2]}
                    version=${BASH_REMATCH[3]}
                    filename="${artifact}-${version}.jar"
                    if ! [[ " ${dependencies[@]} " =~ " ${filename} " ]]; then
                        dependencies+=("$filename")
                    fi
                fi
            done < <(mvn -f "$pom" dependency:tree 2>/dev/null | grep '^$$INFO$$')
        fi
    done

    log "删除所有 .lastUpdated 文件..."
    if [ "$DRY_RUN" = false ]; then
        find "$REPO_PATH" -type f -name "*.lastUpdated" -print0 | xargs -0 -P 4 -n 100 rm -f
    else
        find "$REPO_PATH" -type f -name "*.lastUpdated" -print0 |
        while IFS= read -r -d '' file; do
            log "删除: $file"
        done | tee -a "$LOG_FILE"
    fi

    # === 删除过期文件（排除依赖列表中的 jar 包） ===
    log "扫描仓库: $REPO_PATH 删除: 超过 ${RETENTION_DAYS}天的文件（排除依赖列表中的 jar）"

    if [ "$DRY_RUN" = false ]; then
        exclude_expr=""
        if [ ${#dependencies[@]} -gt 0 ]; then
            for dep in "${dependencies[@]}"; do
                exclude_expr+="! -name \"$dep\" -a "
            done
            exclude_expr="${exclude_expr::-4}"
        fi

        eval find "$REPO_PATH" -type f $(
            if [ -n "$exclude_expr" ]; then
                echo "$exclude_expr -a "
            fi
            echo " -name *.jar -atime +${RETENTION_DAYS}"
        ) -print0 | xargs -0 -P 4 -n 100 rm -f
    else
        exclude_expr=""
        if [ ${#dependencies[@]} -gt 0 ]; then
            for dep in "${dependencies[@]}"; do
                exclude_expr+="! -name \"$dep\" -a "
            done
            exclude_expr="${exclude_expr::-4}"
        fi

        eval find "$REPO_PATH" -type f $(
            if [ -n "$exclude_expr" ]; then
                echo "$exclude_expr -a "
            fi
            echo "$$ -name *.jar -o -name *.pom $$ -atime +${RETENTION_DAYS}"
        ) -print0 |
        while IFS= read -r -d '' file; do
            log "删除: $file"
        done | tee -a "$LOG_FILE"
    fi

    # === 清理空目录 ===
    log "清理空目录..."
    if [ "$DRY_RUN" = false ]; then
        find "$REPO_PATH" -depth -type d -empty | xargs -P 4 -n 1 rmdir
    else
        find "$REPO_PATH" -depth -type d -empty |
        while read -r dir; do
            log "删除空目录: $dir"
        done | tee -a "$LOG_FILE"
    fi

    # === 记录最终状态 ===
    final_size=$(get_dir_size "$REPO_PATH")
    final_size=${final_size:-0}
    saved_size=$(( initial_size - final_size ))
    
    log "清理后仓库大小: $(format_size "$final_size")"
    if (( saved_size > 0 )); then
        log "共释放空间: $(format_size "$saved_size")"
    elif (( saved_size < 0 )); then
        log "警告：仓库变大了（可能有新文件写入）"
    else
        log "未释放任何空间"
    fi
    
    log "=== 清理完成 ==="
}

main "$@"

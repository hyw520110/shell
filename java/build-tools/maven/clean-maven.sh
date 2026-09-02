#!/bin/bash

# === 基础配置 ===
REPO_PATH="$HOME/.m2/repository"
LOG_FILE="$HOME/maven-repo-cleanup.log"
# 首个位置参数是工作目录，但如果它是选项参数则忽略（避免 --dry-run 等被误当作目录）
POS_ARG="${1:-}"
if [[ "$POS_ARG" == --* ]]; then
    WORKSPACE_PATH="$HOME/workspace"
else
    WORKSPACE_PATH="$POS_ARG"
fi
RETENTION_DAYS=60
SNAPSHOT_RETENTION_DAYS=7
CONCURRENCY=8
DRY_RUN=false
SKIP_UPGRADE_PROMPT=false

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
    # 如果不是完全后台运行，也输出到终端
    if [ -t 1 ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
    fi
}

get_dir_size() {
    local dir="$1"
    [[ ! -d "$dir" ]] && { echo "0"; return; }
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local size_kb
        size_kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
        [[ "$size_kb" =~ ^[0-9]+$ ]] && echo $((size_kb * 1024)) || echo "0"
    else
        du -sb "$dir" 2>/dev/null | awk '{print $1}'
    fi
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

main() {
    # === 0. 解析命令行参数 ===
    local run_upgrade=false
    local workspace="$WORKSPACE_PATH"
    for arg in "$@"; do
        case "$arg" in
            --upgrade)      run_upgrade=true ;;
            --skip-upgrade) SKIP_UPGRADE_PROMPT=true ;;
            --dry-run)      DRY_RUN=true ;;
            --repo=*)       REPO_PATH="${arg#*=}" ;;
            --workspace=*)  workspace="${arg#*=}" ;;
            *)              if [[ "$arg" != --* ]]; then workspace="$arg"; fi ;;
        esac
    done
    WORKSPACE_PATH="$workspace"

    if [ "$DRY_RUN" = true ]; then
        log "!!! 预览模式 (--dry-run): 只统计不删除 !!!"
    fi

    # === 0. 可选前置步骤：依赖升级 ===
    if [ "$run_upgrade" = false ] && [ "$SKIP_UPGRADE_PROMPT" != true ] && [ -t 0 ]; then
        read -p "是否需要在清理前扫描并统一升级各个项目的次版本依赖 (将修改 pom.xml)？ [y/N]: " choice
        case "$choice" in 
            y|Y ) run_upgrade=true ;;
        esac
    fi

    if [ "$run_upgrade" = true ]; then
        local upgrade_script="$(dirname "$0")/upgrade-maven-deps.sh"
        if [ -x "$upgrade_script" ]; then
            log ">>> 开始执行依赖升级脚本 <<<"
            "$upgrade_script" "$WORKSPACE_PATH"
            log ">>> 依赖升级执行完毕 <<<"
        else
            log "警告: 找不到依赖升级脚本 ($upgrade_script) 或没有执行权限。"
        fi
    fi

    log "=== 开始极致清理 Maven 仓库 ==="
    initial_size=$(get_dir_size "$REPO_PATH")
    initial_size=${initial_size:-0}
    log "清理前仓库大小: $(format_size "$initial_size")"

    local tmp_dir=$(mktemp -d)
    local dependencies_file="$tmp_dir/dependencies.txt"
    touch "$dependencies_file"

    # === 1. 收集 POM 文件 ===
    POM_FILES=()
    if [ -d "$WORKSPACE_PATH" ]; then
        log "开始扫描工作目录: $WORKSPACE_PATH"
        while IFS= read -r -d '' file; do
            POM_FILES+=("$file")
        done < <(find "$WORKSPACE_PATH" -type f -name 'pom.xml' \
            ! -path '*/target/*' ! -path '*/templates/*' ! -name '*{*]*' -print0)
    fi
    log "共发现 ${#POM_FILES[@]} 个 pom.xml 文件"
    # 注意: 不再过滤子模块——聚合 pom 本身往往没有 dependencies，
    # 若跳过子模块会漏掉真正的活跃依赖，导致误删多模块项目的依赖

    # === 3. 并发解析活跃依赖 ===
    log "开启 $CONCURRENCY 线程并发离线扫描活跃依赖..."
    local count=0
    for pom in "${POM_FILES[@]}"; do
        # 离线解析依赖树，提取 "artifactId:version"（含 pom/test-jar/bundle 等所有类型，
        # 避免 BOM/父 POM 等纯 POM 依赖被误删）
        # 注意: 不能用 -q，否则 [INFO] 依赖树输出会被吞掉，导致活跃依赖收集为空而误删大量依赖
        (
            local tree_out
            tree_out=$(mvn --batch-mode -o -f "$pom" dependency:tree 2>/dev/null)
            if [[ "$?" -ne 0 || -z "$tree_out" ]]; then
                echo "$pom" >> "$tmp_dir/fail_${count}.txt"
            else
                echo "$tree_out" | awk '
                    function is_type(t) {
                        return (t=="jar"||t=="pom"||t=="test-jar"||t=="bundle"||t=="war"||t=="ear"||t=="rar"||t=="ejb"||t=="maven-plugin"||t=="zip"||t=="par"||t=="aar"||t=="java-source"||t=="javadoc")
                    }
                    /^\[INFO\]/ && /:/ {
                        n=split($0,a,":");
                        if (n>=4 && is_type(a[3])) ver=a[4];
                        else if (n>=3) ver=a[3];
                        else next;
                        art=a[2];
                        if (art!="" && ver!="") print art":"ver;
                    }
                ' >> "$tmp_dir/deps_${count}.txt"
            fi
            # 静态兜底: 解析 pom.xml 直接依赖坐标（含 ${property} 属性版本），
            # 覆盖 mvn 离线解析失败的 pom，避免其直接依赖被误删（多保护无害）
            awk '
                BEGIN { inprops=0; art=""; ver="" }
                /<properties>/ { inprops=1; next }
                /<\/properties>/ { inprops=0; next }
                inprops && /<[A-Za-z0-9._-]+>/ && /<\/[A-Za-z0-9._-]+>/ {
                    k=$0; sub(/.*</,"",k); sub(/>.*/,"",k)
                    v=$0; sub(/.*>/,"",v); sub(/<.*/,"",v)
                    props[k]=v
                    next
                }
                /<artifactId>/ {
                    art=$0; sub(/.*<artifactId>/,"",art); sub(/<\/artifactId>.*/,"",art); gsub(/[ \t\r]/,"",art)
                }
                /<version>/ {
                    ver=$0; sub(/.*<version>/,"",ver); sub(/<\/version>.*/,"",ver); gsub(/[ \t\r]/,"",ver)
                    if (ver ~ /^\$\{/) {
                        pk=ver; sub(/^\$\{/,"",pk); sub(/\}$/,"",pk)
                        if (pk in props) ver=props[pk]
                    }
                    if (art!="" && ver!="" && ver !~ /^\$\{/) print art ":" ver
                    art=""
                }
            ' "$pom" >> "$tmp_dir/deps_${count}.txt"
        ) &
        
        ((count++))
        if (( count % CONCURRENCY == 0 )); then
            wait
        fi
    done
    wait # 等待最后一批完成
    
    # 合并去重
    cat "$tmp_dir"/deps_*.txt 2>/dev/null | sort -u > "$dependencies_file"
    local active_deps_count=$(wc -l < "$dependencies_file")
    local pom_fail_count
    pom_fail_count=$(cat "$tmp_dir"/fail_*.txt 2>/dev/null | wc -l | tr -d ' ')
    log "并发扫描完成，收集到 ${active_deps_count// /} 个唯一依赖"
    if [ "${pom_fail_count:-0}" != "0" ]; then
        log "警告: 有 $pom_fail_count 个 pom 离线解析失败（其依赖未被保护）"
    fi

    # === 4. 专项清理：清理过期 SNAPSHOT 版本目录 ===
    log "清理超过 $SNAPSHOT_RETENTION_DAYS 天未修改的 SNAPSHOT 目录..."
    local snap_deleted=0
    while IFS= read -r snap_dir; do
        [[ -z "$snap_dir" ]] && continue
        # 如果目录内最近 X 天没有文件被修改过，则删除
        local recent=$(find "$snap_dir" -type f -mtime -${SNAPSHOT_RETENTION_DAYS} | head -n 1)
        if [ -z "$recent" ]; then
            if [ "$DRY_RUN" = false ]; then
                rm -rf "$snap_dir"
            fi
            ((snap_deleted++))
        fi
    done < <(find "$REPO_PATH" -type d -name "*-SNAPSHOT" 2>/dev/null)
    log "已整目录删除 $snap_deleted 个过期 SNAPSHOT"

    # === 5. 整目录清理：删除不活跃的老旧 Release 依赖 ===
    # 说明: 用 mtime 而非 atime（relatime/noatime 挂载下 atime 不可靠）；
    #       按目录末两段 (artifactId:version) 做活跃匹配，同时覆盖 jar/pom/test-jar 等类型；
    #       用 awk 一次匹配全部候选，避免逐目录 fork grep 导致性能问题
    log "清理超过 $RETENTION_DAYS 天未修改的 Release 目录（排除当前活跃项目）..."
    local candidates_file="$tmp_dir/release_candidates.txt"
    local active_keys_file="$tmp_dir/active_keys.txt"
    local to_delete_file="$tmp_dir/to_delete.txt"

    # 候选: 超过 RETENTION_DAYS 天未修改、且含 .pom 的版本目录，格式 "artifactId:version|/绝对路径"
    find "$REPO_PATH" -name "*.pom" -type f -mtime +${RETENTION_DAYS} 2>/dev/null | while IFS= read -r pom_file; do
        local dir=$(dirname "$pom_file")
        local artifact=$(basename "$(dirname "$dir")")
        local version=$(basename "$dir")
        [[ -z "$artifact" || -z "$version" ]] && continue
        echo "$artifact:$version|$dir"
    done | sort -u > "$candidates_file"

    # 活跃依赖键列表（去重）
    awk -F: '{print $1":"$2}' "$dependencies_file" | sort -u > "$active_keys_file"

    # 一次性筛出"不活跃"的候选目录（awk 数组匹配，避免逐行 fork grep）
    awk -F'|' 'NR==FNR{active[$1]=1; next} !($1 in active){print $2}' \
        "$active_keys_file" "$candidates_file" > "$to_delete_file"

    local release_deleted=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if [ "$DRY_RUN" = false ]; then
            rm -rf "$dir"
        fi
        ((release_deleted++))
    done < "$to_delete_file"
    log "已整目录删除 $release_deleted 个过期 Release 版本"

    # === 6. 垃圾碎片清理 ===
    log "清理垃圾文件与空目录..."
    local trash_deleted=0
    if [ "$DRY_RUN" = false ]; then
        trash_deleted=$(find "$REPO_PATH" -type f \( -name "*.lastUpdated" -o -name "_remote.repositories" \) 2>/dev/null | wc -l)
        find "$REPO_PATH" -type f \( -name "*.lastUpdated" -o -name "_remote.repositories" \) -delete 2>/dev/null
    fi
    log "删除了 $trash_deleted 个无用缓存文件"

    local empty_dir_count=0
    if [ "$DRY_RUN" = false ]; then
        for i in {1..3}; do
            local count=$(find "$REPO_PATH" -depth -type d -empty 2>/dev/null | wc -l)
            [[ $count -eq 0 ]] && break
            find "$REPO_PATH" -depth -type d -empty -delete 2>/dev/null
            ((empty_dir_count += count))
        done
    fi
    log "删除了 $empty_dir_count 个空目录"

    # === 记录最终状态 ===
    final_size=$(get_dir_size "$REPO_PATH")
    final_size=${final_size:-0}
    saved_size=$(( initial_size - final_size ))
    
    log "=========================================="
    log "清理前仓库大小: $(format_size "$initial_size")"
    log "清理后仓库大小: $(format_size "$final_size")"
    if (( saved_size > 0 )); then
        log "共彻底释放空间: $(format_size "$saved_size") 🎉"
    else
        log "未释放任何空间或仓库变大"
    fi
    
    rm -rf "$tmp_dir"
    log "=== 极致清理完成 ==="
}

main "$@"

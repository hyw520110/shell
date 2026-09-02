#!/bin/bash

# === 基础配置 ===
WORKSPACE_PATH="${1:-$HOME/workspace}"
LOG_FILE="$HOME/node-cleanup.log"
RETENTION_DAYS=60

# === 日志系统 ===
exec > >(tee -a "$LOG_FILE") 2>&1
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    if [ -t 1 ]; then echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2; fi
}

get_dir_size() {
    local dir="$1"
    [[ ! -d "$dir" ]] && { echo "0"; return; }
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local size_kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
        [[ "$size_kb" =~ ^[0-9]+$ ]] && echo $((size_kb * 1024)) || echo "0"
    else
        du -sb "$dir" 2>/dev/null | awk '{print $1}'
    fi
}

format_size() {
    local bytes=$1
    if (( bytes < 1024 )); then echo "${bytes}B"
    elif (( bytes < 1024*1024 )); then echo "$(( (bytes + 512) / 1024 ))KB"
    elif (( bytes < 1024*1024*1024 )); then echo "$(( (bytes + 512*1024) / (1024*1024) ))MB"
    else printf "%.1fGB\n" "$(echo "scale=1; $bytes/(1024*1024*1024)" | bc)"; fi
}

main() {
    local run_upgrade=false
    for arg in "$@"; do [[ "$arg" == "--upgrade" ]] && run_upgrade=true; done

    if [ "$run_upgrade" = false ] && [ -t 0 ]; then
        read -p "是否需要在清理前统一升级各项目的 Node 依赖 (更新 package.json 的次版本)？ [y/N]: " choice
        case "$choice" in y|Y ) run_upgrade=true ;; esac
    fi

    if [ "$run_upgrade" = true ]; then
        local upgrade_script="$(dirname "$0")/upgrade-node-deps.sh"
        if [ -x "$upgrade_script" ]; then
            log ">>> 开始执行依赖升级脚本 <<<"
            "$upgrade_script" "$WORKSPACE_PATH"
            log ">>> 依赖升级执行完毕 <<<"
        fi
    fi

    log "=== 开始清理 Node 环境碎片与缓存 ==="
    
    # 统计几个大户的初始体积
    local npm_cache="$HOME/.npm"
    local yarn_cache="$HOME/Library/Caches/Yarn"
    [[ ! -d "$yarn_cache" ]] && yarn_cache="$HOME/.cache/yarn"
    local pnpm_store="$HOME/Library/pnpm/store"
    [[ ! -d "$pnpm_store" ]] && pnpm_store="$HOME/.local/share/pnpm/store"
    
    local initial_npm=$(get_dir_size "$npm_cache")
    local initial_yarn=$(get_dir_size "$yarn_cache")
    local initial_pnpm=$(get_dir_size "$pnpm_store")
    local initial_total=$((initial_npm + initial_yarn + initial_pnpm))
    
    log "全局缓存总大小: $(format_size $initial_total)"

    log "1. 清理 npm 缓存..."
    if command -v npm >/dev/null; then npm cache clean --force 2>/dev/null; fi
    
    log "2. 清理 yarn 缓存..."
    if command -v yarn >/dev/null; then yarn cache clean 2>/dev/null; fi
    
    log "3. 裁剪 pnpm store (只删无引用的孤儿包)..."
    if command -v pnpm >/dev/null; then pnpm store prune 2>/dev/null; fi

    log "4. 扫描并删除工作区超过 $RETENTION_DAYS 天未使用的 node_modules 目录..."
    local nm_deleted=0
    # 查找超过 60 天没被 modified/accessed 过的 node_modules
    while IFS= read -r -d '' dir; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            ((nm_deleted++))
        fi
    done < <(find "$WORKSPACE_PATH" -name "node_modules" -type d -prune -mtime +$RETENTION_DAYS -print0 2>/dev/null)
    
    log "已删除 $nm_deleted 个老旧 node_modules 目录"

    local final_npm=$(get_dir_size "$npm_cache")
    local final_yarn=$(get_dir_size "$yarn_cache")
    local final_pnpm=$(get_dir_size "$pnpm_store")
    local final_total=$((final_npm + final_yarn + final_pnpm))
    
    local saved=$((initial_total - final_total))
    log "=========================================="
    if (( saved > 0 )); then
        log "全局缓存清理完毕，共释放: $(format_size $saved) 🎉"
        log "(不包含删除的 $nm_deleted 个 node_modules 释放的巨量空间)"
    else
        log "缓存无需清理。"
    fi
    log "=== Node 环境清理完成 ==="
}

main "$@"

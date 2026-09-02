#!/bin/bash

# === 基础配置 ===
WORKSPACE_PATH="${1:-$HOME/workspace}"
LOG_FILE="$HOME/python-cleanup.log"
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
        read -p "是否需要在清理前统一升级各项目的 Python 依赖 (修改 requirements/toml)？ [y/N]: " choice
        case "$choice" in y|Y ) run_upgrade=true ;; esac
    fi

    if [ "$run_upgrade" = true ]; then
        local upgrade_script="$(dirname "$0")/upgrade-python-deps.sh"
        if [ -x "$upgrade_script" ]; then
            log ">>> 开始执行依赖升级脚本 <<<"
            "$upgrade_script" "$WORKSPACE_PATH"
            log ">>> 依赖升级执行完毕 <<<"
        fi
    fi

    log "=== 开始清理 Python 环境碎片与缓存 ==="
    
    local pip_cache="$HOME/Library/Caches/pip"
    [[ ! -d "$pip_cache" ]] && pip_cache="$HOME/.cache/pip"
    local uv_cache="$HOME/Library/Caches/uv"
    [[ ! -d "$uv_cache" ]] && uv_cache="$HOME/.cache/uv"
    local poetry_cache="$HOME/Library/Caches/pypoetry"
    [[ ! -d "$poetry_cache" ]] && poetry_cache="$HOME/.cache/pypoetry"
    
    local initial_pip=$(get_dir_size "$pip_cache")
    local initial_uv=$(get_dir_size "$uv_cache")
    local initial_total=$((initial_pip + initial_uv))
    
    log "全局包缓存总大小: $(format_size $initial_total)"

    log "1. 清理 pip 缓存..."
    if command -v pip >/dev/null; then pip cache purge >/dev/null 2>&1; fi
    
    log "2. 裁剪 uv 缓存..."
    if command -v uv >/dev/null; then uv cache prune >/dev/null 2>&1; fi
    
    log "3. 清理 conda 缓存 (如果存在)..."
    if command -v conda >/dev/null; then conda clean -a -y >/dev/null 2>&1; fi
    
    log "4. 清理 poetry 缓存 (如果存在)..."
    if command -v poetry >/dev/null; then poetry cache clear --all pypi -n >/dev/null 2>&1; fi

    log "5. 扫描并删除工作区内的无用缓存目录 (__pycache__, .pytest_cache等)..."
    local cache_deleted=0
    while IFS= read -r -d '' dir; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            ((cache_deleted++))
        fi
    done < <(find "$WORKSPACE_PATH" -type d \( -name "__pycache__" -o -name ".pytest_cache" -o -name ".mypy_cache" -o -name ".ruff_cache" -o -name ".tox" \) -print0 2>/dev/null)
    
    log "已删除 $cache_deleted 个项目级临时缓存目录"

    local final_pip=$(get_dir_size "$pip_cache")
    local final_uv=$(get_dir_size "$uv_cache")
    local final_total=$((final_pip + final_uv))
    
    local saved=$((initial_total - final_total))
    log "=========================================="
    if (( saved > 0 )); then
        log "全局缓存清理完毕，共释放: $(format_size $saved) 🎉"
        log "(不包含 $cache_deleted 个本地 __pycache__ 等清理出的离散空间)"
    else
        log "缓存无需清理。"
    fi
    log "=== Python 环境清理完成 ==="
}

main "$@"

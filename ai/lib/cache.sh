#!/bin/bash

# ==================== 性能优化：缓存模块 ====================

# 检查是否支持缓存（Bash 4.0+ 原生支持，旧版使用模拟层）
CACHE_SUPPORTED=false
CACHE_FILE="${AI_HUB_CACHE_FILE:-$HOME/.ai-tools-cache}"

# 只要定义了关联数组包装器，就认为支持缓存
if declare -F assoc_set_wrapper >/dev/null; then
    CACHE_SUPPORTED=true
    if [[ "$_USE_ASSOC_ARRAY" == "true" ]]; then
        declare -A PATH_CACHE 2>/dev/null || true
    fi
    _cache_debug_msg="缓存功能已启用 (原生支持: $_USE_ASSOC_ARRAY)"
else
    _cache_debug_msg="未找到 assoc 兼容层，缓存功能已禁用"
fi



# 保存缓存到文件
save_cache() {
    [[ "$CACHE_SUPPORTED" != "true" ]] && return 0
    debug_log "保存缓存到文件: $CACHE_FILE"

    local cache_dir temp_cache_file
    cache_dir=$(dirname "$CACHE_FILE")
    mkdir -p "$cache_dir" 2>/dev/null || true
    temp_cache_file=$(mktemp "${cache_dir}/.ai-tools-cache.XXXXXX") || return 1
    chmod 600 "$temp_cache_file" 2>/dev/null || true

    if [[ "$_USE_ASSOC_ARRAY" == "true" ]]; then
        for key in "${!PATH_CACHE[@]}"; do
            printf '%s\t%s\n' "$key" "${PATH_CACHE[$key]}"
        done > "$temp_cache_file" 2>/dev/null
    else
        set | grep "^ASSOC_PATH_CACHE_" > "$temp_cache_file" 2>/dev/null
    fi

    mv "$temp_cache_file" "$CACHE_FILE" 2>/dev/null || { rm -f "$temp_cache_file"; return 1; }
}

# 设置缓存值
set_cache() {
    [[ "$CACHE_SUPPORTED" != "true" ]] && return 0
    local key=$1 value=$2 ttl=${3:-3600}
    local expires=$(($(date +%s) + ttl))

    assoc_set_wrapper "PATH_CACHE" "$key:value" "$value"
    assoc_set_wrapper "PATH_CACHE" "$key:expires" "$expires"
    debug_log "缓存设置: $key (TTL: $ttl 秒)"
}

# 获取缓存值
get_cache() {
    [[ "$CACHE_SUPPORTED" != "true" ]] && return 1
    local key=$1
    local now=$(date +%s)
    local expires=$(assoc_get_wrapper "PATH_CACHE" "$key:expires")

    if [[ -n "$expires" && $now -lt $expires ]]; then
        assoc_get_wrapper "PATH_CACHE" "$key:value"
        return 0
    fi
    return 1
}


#!/bin/bash
# ==================== 模块加载器 ====================
# 负责加载所有模块文件

# 获取模块所在目录
_LOADER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 判断 loader.sh 是否已经在 lib 目录下
if [[ "$(basename "$_LOADER_DIR")" == "lib" ]]; then
    LIB_DIR="$_LOADER_DIR"
else
    LIB_DIR="${_LOADER_DIR}/lib"
fi

# 检查模块目录
if [[ ! -d "$LIB_DIR" ]]; then
    echo "❌ 错误: 模块目录不存在: $LIB_DIR"
    exit 1
fi

# 加载模块文件（utils.sh 必须最先加载，因为提供日志函数）
modules=(
    "utils.sh"
    "assoc.sh"
    "json.sh"
    "proxy.sh"
    "cache.sh"
    "config.sh"
    "config-defaults.sh"
    "tools.sh"
    "system.sh"
    "chrome.sh"
    "menu.sh"
    "config-validator.sh"
)

for module in "${modules[@]}"; do
    module_path="${LIB_DIR}/${module}"
    if [[ -f "$module_path" ]]; then
        source "$module_path"
        debug_log "已加载模块: $module"
    else
        echo "❌ 错误: 模块文件不存在: $module_path"
        exit 1
    fi
done

# 输出 cache.sh 的延迟日志
if [[ -n "${_cache_debug_msg:-}" ]]; then
    debug_log "$_cache_debug_msg"
    unset _cache_debug_msg
fi

debug_log "所有模块加载完成"


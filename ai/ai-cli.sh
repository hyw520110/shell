#!/bin/bash

# AI工具安装器，支持多种AI CLI工具
# 兼容Linux和macOS系统

# ==================== 公共变量定义 ====================

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # 无颜色

# 日志级别定义
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_QUIET=4

# 默认日志级别
LOG_LEVEL=$LOG_LEVEL_INFO

# 系统相关变量
OS=""
CACHE_SUPPORTED=false
CACHE_FILE="$HOME/.ai-cli-cache"

# 工具相关变量
TOOL_STATUS=()
INSTALLED_MCP_TOOLS=()
INSTALLED_MCP_CONFIGS=()
MCP_SERVERS_NAMES=()

# 文档目录变量
DOCS_DIR="${docs_dir:-./ai-cli-docs}"

# 临时文件路径
readonly TEMP_CMD_LOG="/tmp/ai-cli.log"
readonly TEMP_ERROR_LOG="$HOME/.ai-cli-error.log"

# ==================== 日志和错误处理模块 ====================

# 设置日志级别函数
set_log_level() {
    case $1 in
        "debug") LOG_LEVEL=$LOG_LEVEL_DEBUG ;;
        "info") LOG_LEVEL=$LOG_LEVEL_INFO ;;
        "warn") LOG_LEVEL=$LOG_LEVEL_WARN ;;
        "error") LOG_LEVEL=$LOG_LEVEL_ERROR ;;
        "quiet") LOG_LEVEL=$LOG_LEVEL_QUIET ;;
        *) echo -e "${YELLOW}⚠️ 未知日志级别: $1, 使用默认级别${NC}";;
    esac
}

# 日志记录函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        $LOG_LEVEL_DEBUG)
            [[ $LOG_LEVEL -le $LOG_LEVEL_DEBUG ]] && echo -e "${BLUE}[$timestamp DEBUG] $message${NC}"
            ;;
        $LOG_LEVEL_INFO)
            [[ $LOG_LEVEL -le $LOG_LEVEL_INFO ]] && echo -e "${CYAN}[$timestamp INFO] $message${NC}"
            ;;
        $LOG_LEVEL_WARN)
            [[ $LOG_LEVEL -le $LOG_LEVEL_WARN ]] && echo -e "${YELLOW}[$timestamp WARN] $message${NC}"
            ;;
        $LOG_LEVEL_ERROR)
            [[ $LOG_LEVEL -le $LOG_LEVEL_ERROR ]] && echo -e "${RED}[$timestamp ERROR] $message${NC}"
            ;;
    esac
}

# 调试日志
debug_log() {
    log $LOG_LEVEL_DEBUG "$@"
}

# 信息日志
info_log() {
    log $LOG_LEVEL_INFO "$@"
}

# 警告日志
warn_log() {
    log $LOG_LEVEL_WARN "$@"
}

# 错误日志
error_log() {
    log $LOG_LEVEL_ERROR "$@"
}

# 通用错误处理函数
handle_error() {
    local error_code=$1
    local error_message=$2
    local context=$3
    
    error_log "错误代码: $error_code"
    error_log "错误信息: $error_message"
    [[ -n "$context" ]] && error_log "上下文: $context"
    
    # 记录到日志文件
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $error_code: $error_message (Context: $context)" >> "${TEMP_ERROR_LOG}" 2>/dev/null
    
    # 如果错误日志文件过大，清理旧记录
    if [[ -f "$TEMP_ERROR_LOG" ]]; then
        local log_size=$(stat -f%z "$TEMP_ERROR_LOG" 2>/dev/null || stat -c%s "$TEMP_ERROR_LOG" 2>/dev/null || echo "0")
        # 如果日志文件超过1MB，保留最后100行
        if [[ $log_size -gt 1048576 ]]; then
            tail -n 100 "$TEMP_ERROR_LOG" > "${TEMP_ERROR_LOG}.tmp" && mv "${TEMP_ERROR_LOG}.tmp" "$TEMP_ERROR_LOG" 2>/dev/null
        fi
    fi
    
    return $error_code
}

# 带重试的命令执行函数
run_with_retry() {
    local max_attempts=${2:-3}
    local timeout=${3:-30}
    local attempt=1
    local exit_code=0
    
    info_log "执行命令 (最多重试 $max_attempts 次): $1"
    
    # 确定使用的timeout命令
    local timeout_cmd="timeout"
    if ! command -v timeout >/dev/null 2>&1; then
        if command -v gtimeout >/dev/null 2>&1; then
            timeout_cmd="gtimeout"
        else
            # 在不支持timeout的系统上(如macOS)，使用内置的超时机制
            timeout_cmd=""
        fi
    fi
    
    while [ $attempt -le $max_attempts ]; do
        info_log "尝试第 $attempt 次..."
        
        # 使用timeout命令限制执行时间
        if [[ -n "$timeout_cmd" ]]; then
            $timeout_cmd $timeout bash -c "$1" > "$TEMP_CMD_LOG" 2>&1
        else
            # 在没有timeout命令的系统上，直接执行
            bash -c "$1" > "$TEMP_CMD_LOG" 2>&1
        fi
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            info_log "命令执行成功"
            return 0
        else
            warn_log "命令执行失败，退出码: $exit_code"
            warn_log "尝试 $attempt/$max_attempts"
            
            if [ $attempt -lt $max_attempts ]; then
                info_log "等待 2 秒后重试..."
                sleep 2
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    error_log "命令执行失败，已达到最大重试次数 $max_attempts"
    cat "$TEMP_CMD_LOG" >&2
    return $exit_code
}

# 检查配置文件是否存在
check_config_file() {
    local config_file="ai-cli.conf"
    if [[ -f "$config_file" ]]; then
        return 0
    else
        # 检查其他可能的配置文件位置
        local possible_paths=(
            "./ai-cli.conf"
            "$HOME/.config/ai-cli/ai-cli.conf"
            "/etc/ai-cli.conf"
        )
        
        for path in "${possible_paths[@]}"; do
            if [[ -f "$path" ]]; then
                config_file="$path"
                return 0
            fi
        done
        
        # 如果没有找到配置文件，使用默认配置
        warn_log "未找到配置文件 ai-cli.conf，使用默认配置"
        return 1
    fi
}

# 加载外部配置
load_config() {
    if check_config_file; then
        source ai-cli.conf
        info_log "配置文件加载成功"
        return 0
    else
        # 设置默认配置
        tools=()
        mcp_servers=()
        docs_dir="./ai-cli-docs"
        warn_log "使用默认配置"
        return 1
    fi
}

# 验证Chrome路径是否正确
validate_chrome_path() {
    local path=$1
    
    if [[ -z "$path" ]]; then
        debug_log "Chrome路径为空"
        return 1
    fi
    
    if [[ ! -f "$path" ]]; then
        debug_log "Chrome路径文件不存在: $path"
        return 1
    fi
    
    if [[ ! -r "$path" ]]; then
        debug_log "Chrome路径文件不可读: $path"
        return 1
    fi
    
    if [[ ! -x "$path" ]]; then
        debug_log "Chrome路径文件不可执行，尝试添加执行权限: $path"
        if ! chmod +x "$path" 2>/dev/null; then
            error_log "无法为Chrome文件添加执行权限: $path"
            handle_error 101 "无法为Chrome文件添加执行权限" "$path"
            return 1
        fi
        info_log "已成功为Chrome文件添加执行权限: $path"
    fi
    
    # 进一步验证：检查是否真的是Chrome可执行文件
    local file_type
    file_type=$(file -b "$path" 2>/dev/null || echo "unknown")
    if [[ "$file_type" != *"executable"* && "$file_type" != *"application"* ]]; then
        warn_log "文件类型可能不是可执行文件: $file_type"
    fi
    
    info_log "Chrome路径验证成功: $path"
    return 0
}

# 检测Chrome可执行文件路径
detect_chrome_path() {
    # 检查缓存
    local cached_path
    cached_path=$(get_cache "chrome_path")
    if [[ -n "$cached_path" ]]; then
        debug_log "从缓存获取Chrome路径: $cached_path"
        echo "$cached_path"
        return 0
    fi

    local chrome_path=""
    
    debug_log "开始检测Chrome路径，当前操作系统: $OS"

    # 首先检查环境变量
    if [[ -n "$CHROME_PATH" && -f "$CHROME_PATH" ]]; then
        chrome_path="$CHROME_PATH"
        debug_log "使用环境变量CHROME_PATH: $chrome_path"
        set_cache "chrome_path" "$chrome_path" 1800  # 缓存30分钟
        echo "$chrome_path"
        return 0
    fi

    if [[ "$OS" == "macOS" ]]; then
        # macOS常见Chrome安装路径
        local macos_paths=(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        
        for path in "${macos_paths[@]}"; do
            if [[ -f "$path" ]]; then
                chrome_path="$path"
                debug_log "在macOS路径找到Chrome: $path"
                break
            fi
        done
    elif [[ "$OS" == "Linux" ]]; then
        # Linux常见Chrome安装路径
        local linux_paths=(
            "/usr/bin/google-chrome"
            "/usr/bin/google-chrome-stable" 
            "/usr/local/bin/google-chrome"
            "/opt/google/chrome/google-chrome"
            "/usr/bin/chromium-browser"
        )
        
        for path in "${linux_paths[@]}"; do
            if [[ -f "$path" ]]; then
                chrome_path="$path"
                debug_log "在Linux路径找到Chrome: $path"
                break
            fi
        done

        # 也尝试使用which命令
        if [[ -z "$chrome_path" ]]; then
            local which_result
            which_result=$(which google-chrome 2>/dev/null || which chromium-browser 2>/dev/null || which chromium 2>/dev/null || echo "")
            if [[ -n "$which_result" && -f "$which_result" ]]; then
                chrome_path="$which_result"
                debug_log "通过which命令找到Chrome: $chrome_path"
            fi
        fi
        
        # 如果which命令没找到，尝试whereis
        if [[ -z "$chrome_path" ]]; then
            local whereis_result=$(whereis google-chrome 2>/dev/null | cut -d' ' -f2- | cut -d' ' -f1)
            if [[ -n "$whereis_result" && -f "$whereis_result" ]]; then
                chrome_path="$whereis_result"
                debug_log "通过whereis命令找到Chrome: $chrome_path"
            fi
        fi
    else
        warn_log "不支持的操作系统: $OS"
    fi

    if [[ -n "$chrome_path" ]]; then
        debug_log "检测到Chrome路径: $chrome_path"
        # 设置缓存，TTL为30分钟
        set_cache "chrome_path" "$chrome_path" 1800
        echo "$chrome_path"
        return 0
    else
        debug_log "未找到Chrome浏览器"
        # 缓存"未找到"的结果，但TTL较短，以便系统状态变化后能重新检测
        set_cache "chrome_path" "" 300  # 缓存5分钟
        return 1
    fi
}

# 验证并修复Chrome路径配置
validate_and_fix_chrome_config() {
    info_log "开始验证Chrome配置路径"
    
    # 检查配置中的Chrome路径
    local current_path=$(echo "$mcp_chromedevtools" | grep -o '"--executablePath=[^"]*"' | cut -d'=' -f2 | sed 's/"$//')
    
    if [[ -n "$current_path" ]]; then
        debug_log "当前Chrome配置路径: $current_path"
        
        # 验证当前路径是否有效
        if validate_chrome_path "$current_path"; then
            info_log "Chrome配置路径有效: $current_path"
        else
            warn_log "Chrome配置中的路径无效，正在搜索系统中的Chrome..."
            local detected_path=$(detect_chrome_path)
            
            if [[ -n "$detected_path" ]]; then
                # 更新配置变量
                mcp_chromedevtools=$(echo "$mcp_chromedevtools" | sed "s/\"--executablePath=[^\\\"]*\"/\"--executablePath=$detected_path\"/")
                info_log "Chrome路径已更新为: $detected_path"
                
                # 更新所有配置文件中的Chrome路径
                update_chrome_devtools_config_in_file "$detected_path"
            else
                warn_log "未找到Chrome浏览器"
            fi
        fi
    else
        warn_log "配置中未设置Chrome路径，正在搜索Chrome..."
        local detected_path=$(detect_chrome_path)
        
        if [[ -n "$detected_path" ]]; then
            # 更新配置变量
            mcp_chromedevtools=$(echo "$mcp_chromedevtools" | sed "s/\"--executablePath=[^\\\"]*\"/\"--executablePath=$detected_path\"/")
            info_log "Chrome路径已设置为: $detected_path"
            
            # 更新所有配置文件中的Chrome路径
            update_chrome_devtools_config_in_file "$detected_path"
        else
            warn_log "未找到Chrome浏览器"
        fi
    fi
}

# 初始化配置
init_config() {
    # 加载外部配置
    load_config
    
    # 将配置文件中的数组赋值给脚本变量
    TOOLS=("${tools[@]}")
    
    # 提取MCP服务器名称列表
    MCP_SERVERS_NAMES=()
    for server in "${mcp_servers[@]}"; do
        name=$(echo $server | cut -d: -f1)
        MCP_SERVERS_NAMES+=("$name")
    done
    
    # 设置文档目录变量
    DOCS_DIR="${docs_dir:-./ai-cli-docs}"
    
    # 自动验证并修复Chrome配置路径
    validate_and_fix_chrome_config
}

# 通用MCP配置映射函数 - 将MCP名称转换为变量名
get_server_config_var() {
    local server_name=$1
    # 将连字符替换为无字符，生成bash兼容的变量名
    local var_name="mcp_$(echo $server_name | sed 's/-//g')"
    # 验证变量是否存在 - 使用兼容方式检查变量是否存在
    if eval "[[ -n \"\${$var_name+x}\" ]]"; then
        echo $var_name
    else
        # 如果转换后的变量不存在，返回空
        echo ""
    fi
}

# 通用获取服务器配置的函数
get_server_config() {
    local server_name=$1
    local var_name=$(get_server_config_var "$server_name")
    if [[ -n "$var_name" ]]; then
        local value
        eval "value=\${$var_name}"
        echo "$value"
    else
        echo ""
    fi
}

# 检查MCP服务器配置是否已存在
is_mcp_server_configured() {
    local config_file=$1
    local server_name=$2
    
    if ! file_exists "$config_file"; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        local exists=$(jq -r ".mcpServers | has(\"$server_name\")" "$config_file" 2>/dev/null)
        [[ "$exists" == "true" ]]
    else
        # 如果jq不可用，使用grep作为后备
        grep -q "\"$server_name\"" "$config_file"
    fi
}


# 工具状态全局变量
TOOL_STATUS=()

# 已安装且支持MCP的工具列表
INSTALLED_MCP_TOOLS=()
INSTALLED_MCP_CONFIGS=()

# 重置工具相关数组
reset_tool_arrays() {
    TOOL_STATUS=()
    INSTALLED_MCP_TOOLS=()
    INSTALLED_MCP_CONFIGS=()
}

# ==================== 性能优化：缓存模块 ====================

# 检查是否支持关联数组 - 兼容性更好的检测方法
CACHE_SUPPORTED=false
CACHE_FILE="$HOME/.ai-tools-cache"

# 检查Bash版本是否支持关联数组 (需要Bash 4.0+)
if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
    # 进一步验证是否真正支持关联数组
    if (eval "declare -A test_array" 2>/dev/null); then
        CACHE_SUPPORTED=true
        # 缓存变量
        declare -A PATH_CACHE
        debug_log "系统支持关联数组，启用缓存功能"
    else
        debug_log "Bash版本满足要求但关联数组功能不可用"
    fi
else
    debug_log "Bash版本较低 (${BASH_VERSION})，不支持关联数组，缓存功能将被禁用"
fi

# 初始化缓存
init_cache() {
    if [[ "$CACHE_SUPPORTED" == true ]]; then
        debug_log "初始化缓存"
        
        # 从缓存文件加载数据
        if [[ -f "$CACHE_FILE" ]]; then
            debug_log "从文件加载缓存: $CACHE_FILE"
            source "$CACHE_FILE" 2>/dev/null || true
        fi
    fi
}

# 保存缓存到文件
save_cache() {
    if [[ "$CACHE_SUPPORTED" == true ]]; then
        debug_log "保存缓存到文件: $CACHE_FILE"
        
        local temp_cache_file="${CACHE_FILE}.tmp"
        {
            echo "declare -A PATH_CACHE=("
            for key in "${!PATH_CACHE[@]}"; do
                printf "[%q]=%q " "$key" "${PATH_CACHE[$key]}"
            done
            echo ")"
        } > "$temp_cache_file" 2>/dev/null
        
        # 只有在成功生成缓存文件后才替换原文件
        if [[ -f "$temp_cache_file" ]]; then
            mv "$temp_cache_file" "$CACHE_FILE" 2>/dev/null || true
        fi
    fi
}

# 设置缓存值
set_cache() {
    if [[ "$CACHE_SUPPORTED" == true ]]; then
        local key=$1
        local value=$2
        local ttl=${3:-3600}  # 默认TTL为1小时
        
        # 存储值和过期时间
        PATH_CACHE["$key:value"]="$value"
        PATH_CACHE["$key:expires"]=$(($(date +%s) + ttl))
        
        debug_log "缓存设置: $key = $value (TTL: $ttl 秒)"
    fi
}

# 获取缓存值
get_cache() {
    if [[ "$CACHE_SUPPORTED" == true ]]; then
        local key=$1
        
        # 检查是否过期
        local now=$(date +%s)
        local expires="${PATH_CACHE[$key:expires]}"
        
        if [[ -n "$expires" && $now -lt $expires ]]; then
            debug_log "缓存命中: $key"
            echo "${PATH_CACHE[$key:value]}"
            return 0
        else
            # 清除过期条目
            if [[ -n "$expires" ]]; then
                unset PATH_CACHE["$key:value"]
                unset PATH_CACHE["$key:expires"]
                debug_log "缓存已过期: $key"
            fi
            return 1
        fi
    else
        # 如果不支持缓存，返回失败，表示未命中
        return 1
    fi
}

# 清除缓存
clear_cache() {
    if [[ "$CACHE_SUPPORTED" == true ]]; then
        local pattern=$1
        
        if [[ -z "$pattern" ]]; then
            # 清除所有缓存
            unset PATH_CACHE
            declare -A PATH_CACHE
            info_log "已清除所有缓存"
        else
            # 清除匹配特定模式的缓存
            for key in "${!PATH_CACHE[@]}"; do
                if [[ "$key" == *"$pattern"* ]]; then
                    unset PATH_CACHE["$key"]
                fi
            done
            info_log "已清除模式为 '$pattern' 的缓存"
        fi
    else
        info_log "缓存功能不可用"
    fi
}

# 初始化缓存
init_cache

# 检测操作系统
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        OS="macOS"
    elif [[ "$(uname)" == "Linux" ]]; then
        OS="Linux"
    else
        echo -e "${RED}❌ 不支持的操作系统${NC}"
        exit 1
    fi
}

# 使用jq更新JSON配置文件
update_json_config_with_jq() {
    local config_file=$1
    local jq_filter=$2
    local temp_file="${config_file}.tmp"
    
    # 使用jq更新配置
    if jq "$jq_filter" "$config_file" > "$temp_file" 2>/dev/null; then
        if safe_move_file "$temp_file" "$config_file"; then
            info_log "$config_file 已更新"
            return 0
        else
            error_log "移动临时文件失败: $temp_file -> $config_file"
            safe_remove_file "$temp_file"
            return 1
        fi
    else
        error_log "jq更新配置失败: $config_file"
        safe_remove_file "$temp_file"
        return 1
    fi
}

# 通用MCP服务器配置更新函数
update_mcp_server_config_in_file() {
    local server_name=$1
    local property_name=$2
    local new_value=$3
    
    debug_log "更新MCP服务器配置: server=$server_name, property=$property_name, value=$new_value"
    
    # 检查jq是否可用
    if ! command -v jq >/dev/null 2>&1; then
        warn_log "未安装jq，无法自动更新MCP配置"
        return 2
    fi
    
    # 遍历所有已安装支持MCP的工具配置文件
    for idx in "${!INSTALLED_MCP_CONFIGS[@]}"; do
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        if file_exists "$config_file"; then
            # 检查配置文件中是否包含指定的MCP服务器配置
            if grep -q "$server_name" "$config_file"; then
                info_log "更新 $config_file 中的 $server_name 配置..."
                
                # 根据属性名称使用不同的更新逻辑
                local jq_filter=""
                if [[ "$property_name" == "executablePath" ]]; then
                    # 专门处理executablePath的情况
                    jq_filter="--arg new_path \"$new_value\" --arg server \"$server_name\" 'if .mcpServers and (.mcpServers | has(\$server)) then .mcpServers[\$server].args = map(if test(\"--executablePath=\") then \"--executablePath=\" + \$new_path else . end) else . end'"
                else
                    # 通用属性更新逻辑
                    jq_filter="--arg new_value \"$new_value\" --arg server \"$server_name\" --arg prop \"$property_name\" 'if .mcpServers and (.mcpServers | has(\$server)) then if \$prop == \"command\" then .mcpServers[\$server].command = \$new_value elif \$prop == \"transportType\" then .mcpServers[\$server].transportType = \$new_value else .mcpServers[\$server] end else . end'"
                fi
                
                # 使用jq更新配置
                if update_json_config_with_jq "$config_file" "$jq_filter"; then
                    info_log "$server_name 配置更新成功"
                else
                    error_log "更新 $server_name 配置失败"
                    return 1
                fi
            fi
        fi
    done
    
    return 0
}

# 更新配置文件中的Chrome DevTools配置
update_chrome_devtools_config_in_file() {
    local new_path=$1
    
    update_mcp_server_config_in_file "chrome-devtools" "executablePath" "$new_path"
}

# 检查命令是否存在
# (此函数已移至上方定义)

# 检查命令是否存在的通用函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查并安装依赖
check_and_install_dependency() {
    local cmd=$1
    local install_cmd=$2
    local name=$3
    
    if ! command_exists "$cmd"; then
        warn_log "未找到 $name，正在尝试安装..."
        if eval "$install_cmd"; then
            info_log "$name 安装成功"
            return 0
        else
            error_log "$name 安装失败"
            return 1
        fi
    fi
    return 0
}

# 通用npm操作函数
npm_operation() {
    local operation=$1
    local tool_name=$2
    local package_name=$3
    local log_file="/tmp/npm-${operation}.log"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        error_log "未找到 npm。请先安装 Node.js。"
        return 1
    fi
    
    case $operation in
        "install")
            echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
            echo -e "${CYAN}📦 通过 npm 安装 $tool_name...${NC}"
            if npm install -g "$package_name" > "$log_file" 2>&1; then
                echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
                return 0
            else
                echo -e "${RED}❌ $tool_name 安装失败${NC}"
                echo -e "${YELLOW}查看 $log_file 获取详细信息${NC}"
                return 1
            fi
            ;;
        "update")
            echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
            echo -e "${CYAN}🔄 通过 npm 更新 $tool_name...${NC}"
            if npm update -g "$package_name" > "$log_file" 2>&1; then
                echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
                return 0
            else
                echo -e "${RED}❌ $tool_name 更新失败${NC}"
                echo -e "${YELLOW}查看 $log_file 获取详细信息${NC}"
                return 1
            fi
            ;;
        "uninstall")
            echo -e "${CYAN}🗑️ 卸载 $tool_name...${NC}"
            if npm uninstall -g "$package_name" > "$log_file" 2>&1; then
                echo -e "${GREEN}✅ $tool_name 卸载成功!${NC}"
                return 0
            else
                echo -e "${RED}❌ $tool_name 卸载失败${NC}"
                echo -e "${YELLOW}查看 $log_file 获取详细信息${NC}"
                return 1
            fi
            ;;
        *)
            error_log "未知的npm操作: $operation"
            return 1
            ;;
    esac
}

# 通用npm安装函数
install_with_npm() {
    local tool_name=$1
    local package_name=$2
    local max_retries=${3:-3}  # 默认重试3次
    
    info_log "开始安装 $tool_name (包名: $package_name)"
    
    # 检查npm是否已安装
    if ! command_exists npm; then
        error_log "未找到 npm。请先安装 Node.js。"
        return 1
    fi
    
    # 尝试安装，使用重试机制
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        info_log "尝试安装 (第 $attempt/$max_retries 次)..."
        
        if run_with_retry "npm install -g '$package_name'" 1 60; then
            info_log "$tool_name 安装成功!"
            return 0
        else
            warn_log "$tool_name 安装失败，尝试第 $attempt/$max_retries"
            if [ $attempt -lt $max_retries ]; then
                info_log "等待 3 秒后重试..."
                sleep 3
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    error_log "$tool_name 安装失败，已达到最大重试次数"
    return 1
}

# 通用npm更新函数
update_with_npm() {
    local tool_name=$1
    local package_name=$2
    
    npm_operation "update" "$tool_name" "$package_name"
}

# 通用brew操作函数（仅macOS）
brew_operation() {
    local operation=$1
    local tool_name=$2
    local package_name=$3
    local log_file="/tmp/brew-${operation}.log"
    
    # 检查Homebrew是否已安装
    if ! command_exists brew; then
        echo -e "${YELLOW}⚠️ 未找到 Homebrew。正在安装 Homebrew...${NC}"
        if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > /dev/null 2>&1; then
            echo -e "${RED}❌ Homebrew 安装失败${NC}"
            return 1
        fi
    fi
    
    case $operation in
        "install")
            echo -e "${CYAN}📦 通过 Homebrew 安装 $tool_name...${NC}"
            if brew install "$package_name" > "$log_file" 2>&1; then
                echo -e "${GREEN}✅ $tool_name 安装成功!${NC}"
                return 0
            else
                echo -e "${RED}❌ $tool_name 安装失败${NC}"
                echo -e "${YELLOW}查看 $log_file 获取详细信息${NC}"
                return 1
            fi
            ;;
        "update")
            echo -e "${CYAN}🔄 通过 Homebrew 更新 $tool_name...${NC}"
            if brew upgrade "$package_name" > "$log_file" 2>&1; then
                echo -e "${GREEN}✅ $tool_name 更新成功!${NC}"
                return 0
            else
                echo -e "${RED}❌ $tool_name 更新失败${NC}"
                echo -e "${YELLOW}查看 $log_file 获取详细信息${NC}"
                return 1
            fi
            ;;
        *)
            error_log "未知的brew操作: $operation"
            return 1
            ;;
    esac
}

# 通用brew安装函数（仅macOS）
install_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🚀 安装 $tool_name...${NC}"
    
    # 尝试安装，如果brew失败则回退到npm
    if brew_operation "install" "$tool_name" "$package_name"; then
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 安装失败，尝试通过 npm 安装...${NC}"
        install_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 通用brew更新函数（仅macOS）
update_with_brew() {
    local tool_name=$1
    local package_name=$2
    
    echo -e "${CYAN}🔄 更新 $tool_name...${NC}"
    
    # 尝试更新，如果brew失败则回退到npm
    if brew_operation "update" "$tool_name" "$package_name"; then
        return 0
    else
        echo -e "${YELLOW}⚠️ Homebrew 更新失败，尝试通过 npm 更新...${NC}"
        update_with_npm "$tool_name" "$package_name"
        return $?
    fi
}

# 获取工具版本信息
get_tool_version() {
    local cmd=$1
    local version=$($cmd --version 2>/dev/null || echo "unknown")
    echo "$version"
}

# 检查已安装的工具
check_tools() {
    echo -e "${CYAN}🔍 检查已安装的AI工具...${NC}"
    # 重置数组
    reset_tool_arrays
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local cmd=$(echo $tool | cut -d: -f1)
        local name=$(echo $tool | cut -d: -f2)
        local config_path=$(echo $tool | cut -d: -f5)
        
        if command_exists "$cmd"; then
            local version=$(get_tool_version "$cmd")
            echo -e "$i. ${GREEN}✅ $name${NC} ($version) - 已安装"
            TOOL_STATUS+=("true")
            
            # 如果该工具支持MCP（配置路径非空），则添加到MCP工具列表
            if [[ -n "$config_path" ]]; then
                INSTALLED_MCP_TOOLS+=("$name")
                INSTALLED_MCP_CONFIGS+=("$config_path")
            fi
        else
            echo -e "$i. ${YELLOW}⚠️ $name${NC} - 未安装"
            TOOL_STATUS+=("false")
        fi
        ((i++))
    done
}

# 获取工具信息
get_tool_info() {
    local index=$1
    local tool=${TOOLS[$index]}
    
    local cmd=$(echo $tool | cut -d: -f1)
    local name=$(echo $tool | cut -d: -f2)
    local package=$(echo $tool | cut -d: -f3)
    local type=$(echo $tool | cut -d: -f4)
    
    echo "$cmd:$name:$package:$type"
}

# 通用工具操作函数
operate_tool() {
    local index=$1
    local operation=$2  # "install" 或 "update"
    
    local tool_info=$(get_tool_info "$index")
    
    local cmd=$(echo "$tool_info" | cut -d: -f1)
    local name=$(echo "$tool_info" | cut -d: -f2)
    local package=$(echo "$tool_info" | cut -d: -f3)
    local type=$(echo "$tool_info" | cut -d: -f4)
    
    case $type in
        npm)
            if [[ "$operation" == "install" ]]; then
                install_with_npm "$name" "$package"
            else
                update_with_npm "$name" "$package"
            fi
            ;;
        brew)
            if [[ "$OS" == "macOS" ]]; then
                if [[ "$operation" == "install" ]]; then
                    install_with_brew "$name" "$package"
                else
                    update_with_brew "$name" "$package"
                fi
            else
                if [[ "$operation" == "install" ]]; then
                    install_with_npm "$name" "$package"
                else
                    update_with_npm "$name" "$package"
                fi
            fi
            ;;
        config)
            case $cmd in
                mcp-servers)
                    manage_mcp_servers
                    ;;
                *)
                    echo -e "${RED}❌ 未知的配置类型: $cmd${NC}"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}❌ 不支持的${operation}类型: $type${NC}"
            return 1
            ;;
    esac

    # 重新检查工具状态
    check_tools

    # 对特定工具执行额外的初始化步骤
    if [[ "$name" == "veCLI" && "$operation" == "install" ]]; then
        echo -e "${CYAN}ℹ️ veCLI 安装完成！${NC}"
        echo -e "${CYAN}💡 请运行 'vecli login' 命令完成火山引擎账户的认证${NC}"
        echo -e "${CYAN}💡 详细使用方法请参考: https://www.volcengine.com/docs/83927/1826757${NC}"
    fi
}

# 根据索引安装工具
install_tool() {
    operate_tool "$1" "install"
}

# 根据索引更新工具
update_tool() {
    operate_tool "$1" "update"
}

# 显示主菜单
show_menu() {
    echo -e "\n${CYAN}=== AI 工具管理菜单 ===${NC}"
    
    local i=1
    for tool in "${TOOLS[@]}"; do
        local name=$(echo $tool | cut -d: -f2)
        
        if [ "${TOOL_STATUS[$((i-1))]}" = "true" ]; then
            echo -e "$i. ${GREEN}更新 $name${NC}"
        else
            echo -e "$i. ${YELLOW}安装 $name${NC}"
        fi
        ((i++))
    done
    
    echo -e "\n${CYAN}=== 配置管理 ===${NC}"
    echo -e "m. 🔧 管理 MCP 服务器配置"
    echo -e "d. 📚 管理 AI 指令文档"
    echo -e "r. 🔄 刷新工具列表"
    echo -e "q. 🚪 退出"
    echo ""
}

# 检查并创建目录
ensure_dir_exists() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        info_log "目录不存在，创建: $dir"
        mkdir -p "$dir"
        return $?
    fi
    return 0
}

# 检查文件是否存在
file_exists() {
    [[ -f "$1" ]]
}

# 检查目录是否存在
dir_exists() {
    [[ -d "$1" ]]
}

# 安全删除文件
safe_remove_file() {
    local file=$1
    if file_exists "$file"; then
        rm -f "$file"
        return $?
    fi
    return 0
}

# 安全移动文件
safe_move_file() {
    local src=$1
    local dest=$2
    if file_exists "$src"; then
        mv "$src" "$dest"
        return $?
    fi
    return 1
}

# 创建默认配置文件
create_default_config() {
    local config_file=$1
    local tool_name=$2
    
    local config_dir=$(dirname "$config_file")
    if ! ensure_dir_exists "$config_dir"; then
        warn_log "无法创建配置目录: $config_dir"
        return 1
    fi
    
    if ! file_exists "$config_file"; then
        info_log "配置文件不存在，创建默认配置: $config_file"
        case $tool_name in
            "Qwen CLI")
                cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "selectedAuthType": "qwen-oauth",
  "mcpServers": {}
}
EOF
                ;;
            "Gemini CLI")
                cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "mcpServers": {}
}
EOF
                ;;
            "veCLI")
                cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "mcpServers": {}
}
EOF
                ;;
            *)
                cat > "$config_file" << 'EOF'
{
  "mcpServers": {}
}
EOF
                ;;
        esac
    fi
}

# 管理 MCP 服务器配置
manage_mcp_servers() {
    echo -e "${CYAN}🔧 管理 MCP 服务器配置...${NC}"
    
    
    # 为每个支持的AI工具检查并创建配置目录和文件
    local idx
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        create_default_config "$config_file" "$ai_tool"
    done
    
    # 显示所有AI工具的配置文件路径
    echo -e "${GREEN}✅ AI 工具配置文件路径:${NC}"
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        echo -e "  $idx: $config_file"
    done
    echo ""
    
    # 显示所有AI工具的当前 MCP 服务器配置
    echo -e "${CYAN}📋 所有 AI 工具的当前 MCP 服务器配置:${NC}"
    if command -v jq >/dev/null 2>&1; then
        local has_config=false
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
                local server_count=$(jq -r '.mcpServers | length' "$config_file" 2>/dev/null)
                if [[ "$server_count" != "0" ]] && [[ "$server_count" != "null" ]]; then
                    echo -e "  ${ai_tool} (${config_file}):"
                    jq -r '.mcpServers | to_entries[] | "    - \(.key): \(.value.command) \(.value.args // [])"' "$config_file" 2>/dev/null || echo "    无配置的 MCP 服务器"
                    has_config=true
                fi
            fi
        done
        
        if [[ "$has_config" == false ]]; then
            echo "  无配置的 MCP 服务器"
        fi
    else
        echo -e "${YELLOW}⚠️ 未安装 jq，无法解析配置文件。请先安装 jq 以获得更好的体验。${NC}"
        # 简单显示各配置文件是否存在
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
                echo -e "  ${ai_tool}: $config_file (存在)"
            else
                echo -e "  ${ai_tool}: $config_file (不存在或为空)"
            fi
        done
    fi

    # 提供选项来管理 MCP 服务器
    echo -e "MCP 服务器管理选项:"
    echo -e "1. ${GREEN}添加常用 MCP 服务器支持${NC}"
    echo -e "2. ${YELLOW}查看详细的 MCP 配置${NC}"
    echo -e "3. ${RED}重置 MCP 配置${NC}"
    echo -e "4. ${BLUE}返回主菜单${NC}"
    echo ""
    
    read -p "请选择操作 (1-4): " mcp_choice
    
    case $mcp_choice in
        1)
            add_common_mcp_servers
            ;;
        2)
            echo -e "${CYAN}🔍 详细 MCP 配置信息:${NC}"
            for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
                local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
                local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
                echo -e "${CYAN}$ai_tool 配置 (${config_file}):${NC}"
                if [[ -f "$config_file" ]]; then
                    cat "$config_file" | jq '.' 2>/dev/null || cat "$config_file"
                else
                    echo "  配置文件不存在"
                fi
                echo ""
            done
            ;;
        3)
            echo -e "${YELLOW}⚠️ 选择要重置 MCP 配置的 AI 工具:${NC}"
            local i=0
            local tool_names=()
            local config_paths=()
            for ai_tool in "${INSTALLED_MCP_TOOLS[@]}"; do
                echo -e "$i. $ai_tool"
                tool_names[$i]="$ai_tool"
                config_paths[$i]="${INSTALLED_MCP_CONFIGS[$i]}"
                ((i++))
            done
            echo ""
            
            read -p "请选择 AI 工具 (0-$((i-1))): " tool_choice
            
            if [[ $tool_choice -ge 0 && $tool_choice -lt $i ]]; then
                local selected_tool="${tool_names[$tool_choice]}"
                local config_file="${config_paths[$tool_choice]}"
                
                echo -e "${YELLOW}⚠️ 此操作将清除 $selected_tool 的所有 MCP 服务器配置，是否继续？(y/N)${NC}"
                read -p "确认 (y/N): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    # 重置配置，只保留基本结构
                    local tool_base_name=$(echo "$selected_tool" | cut -d' ' -f1)
                    case $tool_base_name in
                        "Qwen")
                            cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "selectedAuthType": "qwen-oauth",
  "mcpServers": {}
}
EOF
                            ;;
                        "Gemini")
                            cat > "$config_file" << 'EOF'
{
  "hasSeenIdeIntegrationNudge": true,
  "mcpServers": {}
}
EOF
                            ;;
                        *)
                            cat > "$config_file" << 'EOF'
{
  "mcpServers": {}
}
EOF
                            ;;
                    esac
                    echo -e "${GREEN}✅ $selected_tool 的 MCP 配置已重置${NC}"
                else
                    echo -e "${YELLOW}❌ 操作已取消${NC}"
                fi
            else
                echo -e "${RED}❌ 无效选项${NC}"
            fi
            ;;
        4)
            echo -e "${GREEN}🔙 返回主菜单${NC}"
            ;;
        *)
            echo -e "${RED}❌ 无效选项${NC}"
            ;;
    esac
}

# 显示可用的MCP服务器列表
show_mcp_servers_list() {
    echo -e "${CYAN}🔧 可用的 MCP 服务器:${NC}"
    
    local i=0
    for server in "${mcp_servers[@]}"; do
        local name=$(echo $server | cut -d: -f1)
        local display_name=$(echo $server | cut -d: -f2)
        
        # 使用默认颜色显示所有服务器
        echo -e "$i. $display_name"
        ((i++))
    done
    
    echo -e "$i. ${CYAN}以上全部${NC}"
    echo -e "$((i+1)). ${RED}返回上一级${NC}"
    echo ""
}

# 通用MCP服务器添加函数
add_mcp_servers() {
    local choice=$1
    
    if [[ $choice -ge 0 && $choice -lt ${#MCP_SERVERS_NAMES[@]} ]]; then
        # 添加单个MCP服务器
        local server_name="${MCP_SERVERS_NAMES[$choice]}"
        add_mcp_server_by_name "$server_name"
    elif [[ $choice -eq ${#MCP_SERVERS_NAMES[@]} ]]; then
        # 批量添加所有MCP服务器
        # 先收集所有需要添加的MCP服务器配置，并检查Chrome路径
        local all_servers_configs=()
        for server_name in "${MCP_SERVERS_NAMES[@]}"; do
            local server_config=$(get_server_config "$server_name")
            if [[ -n "$server_config" ]]; then
                # 如果是Chrome DevTools配置，检查并修复路径
                if [[ "$server_name" == "chrome-devtools" ]]; then
                    local updated_config=$(check_and_fix_chrome_path_in_config "$server_config")
                    all_servers_configs+=("$server_name:$updated_config")
                else
                    all_servers_configs+=("$server_name:$server_config")
                fi
            fi
        done
        
        # 一次性更新每个已安装工具的配置文件
        local success_count=0
        local total_count=${#INSTALLED_MCP_TOOLS[@]}
        
        for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
            local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
            local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
            
            if file_exists "$config_file"; then
                # 更新配置文件，添加所有服务器配置
                if add_all_mcp_configs_to_file "$config_file" "${all_servers_configs[@]}"; then
                    echo -e "${GREEN}✅ $ai_tool 的所有 MCP 服务器配置已添加到配置${NC}"
                    ((success_count++))
                else
                    echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️ $ai_tool 的配置文件不存在: $config_file，跳过${NC}"
            fi
        done
        
        # 显示配置更新结果
        if [[ $success_count -eq $total_count ]]; then
            info_log "所有MCP工具配置更新成功"
        else
            warn_log "$success_count/$total_count 个MCP工具配置更新成功"
        fi
        
        # 批量安装所有MCP服务器包
        for server_name in "${MCP_SERVERS_NAMES[@]}"; do
            install_mcp_server_package "$server_name"
        done
    elif [[ $choice -eq $((${#MCP_SERVERS_NAMES[@]} + 1)) ]]; then
        # 返回上级菜单
        echo -e "${GREEN}🔙 返回上级菜单${NC}"
        return 1
    else
        echo -e "${RED}❌ 无效选项${NC}"
        return 1
    fi
    
    return 0
}

# 添加常用 MCP 服务器
add_common_mcp_servers() {
    echo -e "${CYAN}🔧 添加常用 MCP 服务器支持:${NC}"
    
    # 显示可用的MCP服务器
    show_mcp_servers_list
    read -p "请选择要添加的 MCP 服务器支持 (0-$(( ${#MCP_SERVERS_NAMES[@]} + 1 ))): " server_choice
    
    add_mcp_servers "$server_choice"
}

# 使用sed作为后备方案添加MCP服务器配置
add_mcp_server_to_config_fallback() {
    local config_file=$1
    local server_name=$2
    local server_config=$3
    
    debug_log "使用后备方案为 $server_name 添加配置到 $config_file"
    
    if [ -z "$server_config" ]; then
        error_log "服务器配置为空"
        return 1
    fi
    
    # 检查配置是否已存在
    if is_mcp_server_configured "$config_file" "$server_name"; then
        warn_log "$server_name 配置已存在"
        return 0  # 返回0表示成功（配置已存在）
    fi
    
    # 确保配置文件末尾有正确的结构
    local temp_file="${config_file}.tmp"
    
    # 检查文件是否以"}"结尾
    if tail -c 1 "$config_file" | grep -q "}"; then
        # 在最后一个"}"前插入MCP服务器配置
        # 先移除最后一个"}"
        sed '$s/}/  ,\n  "'$server_name'": '$server_config'\n}/' "$config_file" > "$temp_file"
    else
        # 如果文件结构不符合预期，直接追加
        cp "$config_file" "$temp_file"
        echo "  ,\"$server_name\": $server_config" >> "$temp_file"
        echo "}" >> "$temp_file"
    fi
    
    # 移动临时文件到原文件
    if safe_move_file "$temp_file" "$config_file"; then
        info_log "$server_name 配置更新成功（使用后备方案）"
        return 0
    else
        error_log "更新 $server_name 配置失败（后备方案）"
        safe_remove_file "$temp_file"
        return 1
    fi
}

# 通用函数：添加MCP服务器到配置
add_mcp_server_to_config() {
    local config_file=$1
    local server_name=$2
    local server_config=$3
    
    debug_log "为 $server_name 添加配置到 $config_file"
    debug_log "服务器配置内容: $server_config"
    
    if [ -z "$server_config" ]; then
        error_log "服务器配置为空"
        return 1
    fi
    
    # 检查配置是否已存在
    if is_mcp_server_configured "$config_file" "$server_name"; then
        warn_log "$server_name 配置已存在，跳过"
        return 0
    fi
    
    if command -v jq >/dev/null 2>&1; then
        # 尝试使用--argjson方法（如果服务器配置是有效JSON）
        if jq --argjson server_config "$server_config" --arg server_name "$server_name" \
           '.mcpServers[$server_name] = $server_config' "$config_file" > "${config_file}.tmp" 2>/dev/null; then
            mv "${config_file}.tmp" "$config_file"
            info_log "$server_name 配置更新成功"
            return 0
        else
            # 如果--argjson失败，说明server_config可能不是有效JSON
            # 尝试使用--arg和fromjson方法
            if jq --arg server_config_str "$server_config" --arg server_name "$server_name" \
               '.mcpServers[$server_name] = ($server_config_str | fromjson)' "$config_file" > "${config_file}.tmp" 2>/dev/null; then
                mv "${config_file}.tmp" "$config_file"
                info_log "$server_name 配置更新成功"
                return 0
            else
                warn_log "jq更新失败，尝试后备方案"
                # jq方法都失败，使用sed作为后备
                add_mcp_server_to_config_fallback "$config_file" "$server_name" "$server_config"
                return $?
            fi
        fi
    else
        warn_log "未安装 jq，使用后备方案更新配置"
        # jq不可用，使用sed作为后备
        add_mcp_server_to_config_fallback "$config_file" "$server_name" "$server_config"
        return $?
    fi
}

# 一次性向配置文件添加所有MCP服务器配置
add_all_mcp_configs_to_file() {
    local config_file=$1
    shift
    local all_configs=("$@")
    
    # 对每个配置使用jq更新
    local temp_config="$config_file.tmp"
    cp "$config_file" "$temp_config"
    
    local success_count=0
    local total_count=${#all_configs[@]}
    local ai_tool_name=$(basename $(dirname "$config_file"))  # 提取工具名称如qwen, gemini等
    
    # 先显示开始更新配置文件的消息
    echo -e "${CYAN}➕ 开始更新 $ai_tool_name 的所有 MCP 服务器配置...${NC}"
    
    for config_entry in "${all_configs[@]}"; do
        local server_name="${config_entry%%:*}"
        local server_config="${config_entry#*:}"
        
        # 检查配置是否已存在
        if command -v jq >/dev/null 2>&1; then
            # 使用jq检查配置是否存在
            local exists=$(jq -r ".mcpServers | has(\"$server_name\")" "$temp_config" 2>/dev/null)
            if [[ "$exists" == "true" ]]; then
                echo -e "${YELLOW}⚠️ $server_name 配置已存在${NC}"
                ((success_count++))
                continue
            fi
            
            # 更新配置
            if jq --argjson server_config "$server_config" --arg server_name "$server_name" \
               '.mcpServers[$server_name] = $server_config' "$temp_config" > "${temp_config}.tmp" 2>/dev/null; then
                echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                mv "${temp_config}.tmp" "$temp_config"
                ((success_count++))
            else
                # 如果jq --argjson失败，尝试使用--arg和fromjson
                if jq --arg server_config_str "$server_config" --arg server_name "$server_name" \
                   '.mcpServers[$server_name] = ($server_config_str | fromjson)' "$temp_config" > "${temp_config}.tmp" 2>/dev/null; then
                    echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                    mv "${temp_config}.tmp" "$temp_config"
                    ((success_count++))
                else
                    echo -e "${RED}❌ 更新 $server_name 配置失败${NC}"
                fi
            fi
        else
            # 如果jq不可用，使用后备函数逐个添加
            local result=$(add_mcp_server_to_config_fallback "$temp_config" "$server_name" "$server_config" 2>&1)
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                # 检查是否是"已存在"消息
                if echo "$result" | grep -q "配置已存在"; then
                    echo -e "${YELLOW}⚠️ $server_name 配置已存在${NC}"
                else
                    echo -e "${GREEN}✅ $server_name 配置已添加${NC}"
                fi
                ((success_count++))
            else
                echo -e "${RED}❌ 更新 $server_name 配置失败${NC}"
            fi
        fi
    done
    
    # 如果所有配置都成功添加或已存在，移动临时文件到原文件
    if [[ $success_count -eq $total_count ]]; then
        mv "$temp_config" "$config_file"
        echo -e "${GREEN}✅ $ai_tool_name 的所有 MCP 服务器配置已处理完成${NC}"
        return 0
    else
        # 部分失败，保留临时文件用于调试
        echo -e "${YELLOW}⚠️ $ai_tool_name 部分配置更新失败，保留临时文件 $temp_config 用于调试${NC}"
        return 1
    fi
}

# 检查并修复Chrome路径在配置中的函数
check_and_fix_chrome_path_in_config() {
    local server_config="$1"
    
    # 如果是Chrome DevTools配置，检查并修复路径
    if [[ "$server_config" == *"--executablePath"* ]]; then
        # 提取当前路径
        local current_path=$(echo "$server_config" | grep -o '"--executablePath=[^"]*"' | cut -d'=' -f2 | sed 's/"$//')
        
        info_log "检测到Chrome DevTools配置，验证Chrome路径: $current_path"
        
        # 验证当前路径是否有效
        if validate_chrome_path "$current_path"; then
            debug_log "Chrome路径已存在且有效: $current_path"
            echo "$server_config"  # 返回原配置
        else
            warn_log "Chrome路径无效或Chrome未安装: $current_path"
            
            # 搜索系统中的Chrome
            local detected_path=$(detect_chrome_path)
            
            if [[ -n "$detected_path" ]]; then
                info_log "发现Chrome可执行文件: $detected_path"
                
                # 更新配置中的路径
                local updated_config=$(echo "$server_config" | sed "s/\"--executablePath=[^\"]*\"/\"--executablePath=$detected_path\"/")
                
                # 更新全局配置变量
                mcp_chromedevtools=$(echo "$mcp_chromedevtools" | sed "s/\"--executablePath=[^\\\"]*\"/\"--executablePath=$detected_path\"/")
                
                echo "$updated_config"  # 返回更新后的配置
            else
                warn_log "未在系统中找到Chrome浏览器"
                
                # 提供手动输入路径的选项
                read -p "是否要手动输入Chrome路径? (y/N): " manual_input
                if [[ "$manual_input" == "y" || "$manual_input" == "Y" ]]; then
                    read -p "请输入Chrome可执行文件路径: " manual_path
                    
                    if [[ -n "$manual_path" ]] && [[ -f "$manual_path" ]]; then
                        if validate_chrome_path "$manual_path"; then
                            info_log "手动输入的Chrome路径有效: $manual_path"
                            
                            # 更新配置中的路径
                            local updated_config=$(echo "$server_config" | sed "s/\"--executablePath=[^\"]*\"/\"--executablePath=$manual_path\"/")
                            
                            # 更新全局配置变量
                            mcp_chromedevtools=$(echo "$mcp_chromedevtools" | sed "s/\"--executablePath=[^\\\"]*\"/\"--executablePath=$manual_path\"/")
                            
                            echo "$updated_config"  # 返回更新后的配置
                        else
                            error_log "手动输入的Chrome路径无效: $manual_path"
                            echo "$server_config"  # 返回原配置
                        fi
                    else
                        warn_log "手动输入的路径不存在: $manual_path"
                        echo "$server_config"  # 返回原配置
                    fi
                else
                    warn_log "未修复Chrome路径，使用原始配置"
                    echo "$server_config"  # 返回原配置
                fi
            fi
        fi
    else
        # 不是Chrome配置，直接返回原配置
        debug_log "非Chrome DevTools配置，跳过路径验证"
        echo "$server_config"
    fi
}

# 通用MCP服务器操作函数
operate_mcp_server() {
    local server_name=$1
    local operation=$2  # "add" 或 "config-only"
    
    local server_config=$(get_server_config "$server_name")
    
    if [[ -z "$server_config" ]]; then
        echo -e "${RED}❌ 未找到服务器配置: $server_name${NC}"
        return 1
    fi
    
    # 如果是Chrome DevTools配置，检查并修复路径（仅在添加操作时）
    if [[ "$server_name" == "chrome-devtools" && "$operation" == "add" ]]; then
        local updated_config=$(check_and_fix_chrome_path_in_config "$server_config")
        server_config="$updated_config"
    fi
    
    if [[ "$operation" == "add" ]]; then
        echo -e "${CYAN}➕ 添加 $server_name MCP 服务器支持${NC}"
    else
        echo -e "${CYAN}➕ 添加 $server_name MCP 服务器配置到已安装工具...${NC}"
    fi
    
    # 确保已安装的MCP工具列表是最新的（仅在添加操作时）
    if [[ "$operation" == "add" ]]; then
        check_tools
    fi
    
    local success_count=0
    local total_count=${#INSTALLED_MCP_TOOLS[@]}
    
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        # 只在配置文件存在时才添加MCP服务器配置
        if [[ -f "$config_file" ]]; then
            # 检查是否已存在配置
            if command -v jq >/dev/null 2>&1; then
                local exists=$(jq -r '.mcpServers | has("'$server_name'")' "$config_file" 2>/dev/null)
                if [[ "$exists" == "true" ]]; then
                    echo -e "${YELLOW}⚠️ $ai_tool 的 $server_name 配置已存在，跳过${NC}"
                    ((success_count++))
                    continue
                fi
            fi
            
            # 直接使用获取到的服务器配置
            if add_mcp_server_to_config "$config_file" "$server_name" "$server_config"; then
                echo -e "${GREEN}✅ $ai_tool 的 $server_name MCP 服务器已添加到配置${NC}"
                ((success_count++))
            else
                echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ $ai_tool 的配置文件不存在: $config_file，跳过${NC}"
        fi
    done
    
    # 显示配置更新结果（仅在添加操作时）
    if [[ "$operation" == "add" ]]; then
        if [[ $success_count -eq $total_count ]]; then
            info_log "所有MCP工具配置更新成功"
        else
            warn_log "$success_count/$total_count 个MCP工具配置更新成功"
        fi
        
        # 安装MCP服务器包
        install_mcp_server_package "$server_name"
    fi
}

# 通过名称添加MCP服务器
add_mcp_server_by_name() {
    operate_mcp_server "$1" "add"
}

# 仅添加MCP配置，不处理包安装
add_mcp_config_only() {
    operate_mcp_server "$1" "config-only"
}

# 获取MCP服务器安装信息
get_mcp_server_install_info() {
    local server_name=$1
    local package=""
    local install_type=""
    
    for mcp_server in "${mcp_servers[@]}"; do
        local name=$(echo $mcp_server | cut -d: -f1)
        if [[ "$name" == "$server_name" ]]; then
            package=$(echo $mcp_server | cut -d: -f3)
            install_type=$(echo $mcp_server | cut -d: -f4)
            break
        fi
    done
    
    # 清理包名中的前后空格
    package=$(echo "$package" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    echo "$package:$install_type"
}

# 检查NPM包是否已安装
is_npm_package_installed() {
    local package=$1
    npm list -g "$package" >/dev/null 2>&1
}

# 安装NPM包（带重试机制）
install_npm_package_with_retry() {
    local package=$1
    
    # 先尝试安装
    if npm install -g "$package"; then
        return 0
    else
        # 如果失败，尝试先卸载再安装
        warn_log "安装失败，尝试先卸载再安装..."
        npm uninstall -g "$package" 2>/dev/null
        # 再次尝试安装
        if npm install -g "$package"; then
            return 0
        else
            return 1
        fi
    fi
}

# 仅安装MCP服务器包，不处理配置添加
install_mcp_server_package() {
    local server_name=$1
    
    # 获取服务器安装信息
    local install_info=$(get_mcp_server_install_info "$server_name")
    local package=$(echo "$install_info" | cut -d: -f1)
    local install_type=$(echo "$install_info" | cut -d: -f2)
    
    # 如果找到了服务器配置，执行安装
    if [[ -n "$package" && -n "$install_type" ]]; then
        case $install_type in
            npm)
                # 检查 MCP 包是否已安装
                if is_npm_package_installed "$package"; then
                    echo -e "${GREEN}✅ $server_name MCP 包 ($package) 已安装${NC}"
                else
                    # 安装 MCP 包
                    echo -e "${CYAN}📦 安装 $package...${NC}"
                    if install_npm_package_with_retry "$package"; then
                        echo -e "${GREEN}✅ $server_name MCP 包安装成功${NC}"
                    else
                        echo -e "${YELLOW}⚠️ $server_name MCP 包 ($package) 安装失败，请手动安装${NC}"
                    fi
                fi
                ;;
            *)
                echo -e "${YELLOW}⚠️ 不支持的安装类型: $install_type${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}⚠️ 未找到 $server_name 的安装配置${NC}"
    fi
}

# 添加新的 MCP 服务器
add_mcp_server() {
    local settings_file="$1"
    local ai_tool="$2"
    
    # 如果没有提供AI工具名称，则默认为"Unknown"
    if [[ -z "$ai_tool" ]]; then
        ai_tool="Unknown"
    fi
    
    echo -e "${CYAN}➕ 为 $ai_tool 添加新的 MCP 服务器${NC}"
    
    read -p "请输入服务器名称 (如: mysql, chrome-devtools, 等): " server_name
    
    # 验证服务器名称
    if [[ -z "$server_name" ]]; then
        echo -e "${RED}❌ 服务器名称不能为空${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}常用 MCP 服务器示例:${NC}"
    echo "  1. MySQL 数据库: npx @f4ww4z/mcp-mysql-server"
    echo "  2. Chrome DevTools: npx chrome-devtools-mcp@latest"
    echo "  3. 自定义命令"
    
    read -p "请输入命令 (如: npx, node 等): " server_command
    
    if [[ -z "$server_command" ]]; then
        echo -e "${RED}❌ 命令不能为空${NC}"
        return 1
    fi
    
    # 添加参数输入
    echo -e "${YELLOW}请输入参数 (多个参数用空格分隔，如: -y @f4ww4z/mcp-mysql-server)${NC}"
    read -p "参数: " server_args
    
    # 询问是否需要环境变量
    read -p "是否需要设置环境变量? (y/N): " need_env
    local env_vars=""
    if [[ "$need_env" == "y" || "$need_env" == "Y" ]]; then
        echo -e "${YELLOW}请输入环境变量 (格式: KEY1=VALUE1,KEY2=VALUE2):${NC}"
        read -p "环境变量: " env_input
        if [[ -n "$env_input" ]]; then
            # 转换逗号分隔的环境变量为 JSON 格式
            IFS=',' read -ra ENV_PAIRS <<< "$env_input"
            env_vars="{"
            local first=true
            for pair in "${ENV_PAIRS[@]}"; do
                IFS='=' read -r key value <<< "$pair"
                if [[ "$first" == true ]]; then
                    env_vars="${env_vars}\\\"$key\\\":\\\"$value\\\""
                    first=false
                else
                    env_vars="${env_vars},\\\"$key\\\":\\\"$value\\\""
                fi
            done
            env_vars="${env_vars}}"
        fi
    fi
    
    # 询问传输类型
    echo -e "${YELLOW}传输类型 (stdio/tcp) [默认: stdio]:${NC}"
    read -p "传输类型: " transport_type
    transport_type=${transport_type:-"stdio"}
    
    # 询问自动批准的权限
    echo -e "${YELLOW}请输入自动批准的权限 (用逗号分隔，如: connect_db,execute,query)${NC}"
    read -p "自动批准权限: " auto_approve
    
    # 构建 MCP 服务器配置
    local new_config=""
    if [[ -n "$auto_approve" ]]; then
        if [[ -n "$env_vars" ]]; then
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "env": $env_vars,
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/\\",\\"/g' | sed 's/^/\\\"/' | sed 's/$/\\\"/')]
}
EOF
)
        else
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "transportType": "$transport_type",
  "autoApprove": [$(echo "$auto_approve" | sed 's/,/\\",\\"/g' | sed 's/^/\\\"/' | sed 's/$/\\\"/')]
}
EOF
)
        fi
    else
        if [[ -n "$env_vars" ]]; then
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "env": $env_vars,
  "transportType": "$transport_type"
}
EOF
)
        else
            # 处理参数数组
            local args_array=""
            if [[ -n "$server_args" ]]; then
                # 将空格分隔的参数转换为 JSON 数组
                IFS=' ' read -ra ARGS_ARRAY <<< "$server_args"
                args_array="\\\"${ARGS_ARRAY[0]}\\\""
                for arg in "${ARGS_ARRAY[@]:1}"; do
                    if [[ -n "$arg" ]]; then
                        args_array="${args_array},\\\"$arg\\\""
                    fi
                done
            fi
            
            new_config=$(cat << EOF
{
  "command": "$server_command",
  "args": [$args_array],
  "transportType": "$transport_type"
}
EOF
)
        fi
    fi
    
    # 如果 jq 可用，使用它来更新配置
    if command -v jq >/dev/null 2>&1; then
        # 更新配置
        jq --argjson server_config "$new_config" --arg server_name "$server_name" \
           '.mcpServers[$server_name] = $server_config' "$settings_file" > "${settings_file}.tmp" && \
        mv "${settings_file}.tmp" "$settings_file"
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✅ $ai_tool 的 MCP 服务器 '$server_name' 已添加到配置${NC}"
        else
            echo -e "${RED}❌ 更新 $ai_tool 的 MCP 配置失败${NC}"
        fi
    else
        echo -e "${RED}❌ 未安装 jq，无法更新配置。请安装 jq 后重试。${NC}"
        return 1
    fi
}

# 管理AI指令文档
manage_ai_docs() {
    echo -e "${CYAN}📚 管理 AI 指令文档${NC}"
    
    # 确保文档目录存在
    if ! ensure_dir_exists "$DOCS_DIR"; then
        error_log "无法创建文档目录: $DOCS_DIR"
        return 1
    fi
    
    # 显示文档目录中的文件
    echo -e "${GREEN}📋 文档目录中的文件 ($DOCS_DIR):${NC}"
    if command -v ls >/dev/null 2>&1; then
        local doc_files=($(ls -1 "$DOCS_DIR" 2>/dev/null || echo ""))
        if [[ ${#doc_files[@]} -gt 0 ]]; then
            local i=0
            for doc_file in "${doc_files[@]}"; do
                echo -e "$i. $doc_file"
                ((i++))
            done
        else
            echo "  文档目录为空"
        fi
    else
        echo "  无法列出文档目录内容"
    fi
    
    echo ""
    echo -e "文档管理选项:"
    echo -e "1. ${GREEN}创建新文档${NC}"
    echo -e "2. ${YELLOW}查看文档${NC}"
    echo -e "3. ${BLUE}编辑文档${NC}"
    echo -e "4. ${RED}删除文档${NC}"
    echo -e "5. ${CYAN}返回主菜单${NC}"
    echo ""
    
    read -p "请选择操作 (1-5): " doc_choice
    
    case $doc_choice in
        1)
            create_ai_doc
            ;;
        2)
            view_ai_doc
            ;;
        3)
            edit_ai_doc
            ;;
        4)
            delete_ai_doc
            ;;
        5)
            echo -e "${GREEN}🔙 返回主菜单${NC}"
            ;;
        *)
            echo -e "${RED}❌ 无效选项${NC}"
            ;;
    esac
}

# 创建新AI文档
create_ai_doc() {
    read -p "请输入文档名称 (不含扩展名): " doc_name
    if [[ -z "$doc_name" ]]; then
        echo -e "${RED}❌ 文档名称不能为空${NC}"
        return 1
    fi
    
    local doc_file="$DOCS_DIR/${doc_name}.md"
    
    # 检查文件是否已存在
    if file_exists "$doc_file"; then
        echo -e "${YELLOW}⚠️ 文档已存在: $doc_file${NC}"
        read -p "是否覆盖? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            echo -e "${GREEN}🔙 取消创建${NC}"
            return 0
        fi
    fi
    
    # 提供文档模板选择
    echo -e "${CYAN}选择文档模板:${NC}"
    echo "1. 基础模板"
    echo "2. 高级模板"
    read -p "请选择模板 (1-2): " template_choice
    
    # 使用handle_template_file函数处理模板
    handle_template_file "$template_choice" "$doc_file"
    
    # 询问是否立即编辑
    read -p "是否立即编辑文档? (y/N): " edit_now
    if [[ "$edit_now" == "y" || "$edit_now" == "Y" ]]; then
        edit_ai_doc_file "$doc_file"
    fi
}

# 列出文档目录中的文件并返回选择
# 参数: $1 - 操作类型 (view/edit/delete)
# 返回: 选中的文件路径或空字符串
list_and_select_docs() {
    local operation=$1
    local action=""
    local prompt=""
    
    case $operation in
        "view")
            action="查看"
            prompt="请选择要查看的文档"
            ;;
        "edit")
            action="编辑"
            prompt="请选择要编辑的文档"
            ;;
        "delete")
            action="删除"
            prompt="请选择要删除的文档"
            ;;
        *)
            action="操作"
            prompt="请选择文档"
            ;;
    esac
    
    echo -e "${CYAN}📋 可${action}的文档:${NC}"
    if command -v ls >/dev/null 2>&1; then
        local doc_files=($(ls -1 "$DOCS_DIR"/*.md 2>/dev/null || echo ""))
        if [[ ${#doc_files[@]} -gt 0 ]]; then
            local i=0
            for doc_file in "${doc_files[@]}"; do
                echo -e "$i. $(basename "$doc_file")"
                ((i++))
            done
            
            echo ""
            read -p "${prompt} (0-$((i-1))): " doc_choice
            
            if [[ $doc_choice -ge 0 && $doc_choice -lt $i ]]; then
                echo "${doc_files[$doc_choice]}"
                return 0
            else
                echo -e "${RED}❌ 无效选项${NC}"
                return 1
            fi
        else
            echo "  文档目录中没有找到.md文件"
            return 1
        fi
    else
        echo "  无法列出文档目录内容"
        return 1
    fi
}

# 查看AI文档
view_ai_doc() {
    local selected_doc=$(list_and_select_docs "view")
    if [[ $? -eq 0 && -n "$selected_doc" ]]; then
        echo -e "${GREEN}📄 文档内容 ($selected_doc):${NC}"
        echo "=================================================="
        if command -v less >/dev/null 2>&1; then
            less "$selected_doc"
        elif command -v more >/dev/null 2>&1; then
            more "$selected_doc"
        else
            cat "$selected_doc"
        fi
        echo "=================================================="
    fi
}

# 编辑AI文档
edit_ai_doc() {
    local selected_doc=$(list_and_select_docs "edit")
    if [[ $? -eq 0 && -n "$selected_doc" ]]; then
        edit_ai_doc_file "$selected_doc"
    fi
}

# 删除AI文档
delete_ai_doc() {
    local selected_doc=$(list_and_select_docs "delete")
    if [[ $? -eq 0 && -n "$selected_doc" ]]; then
        echo -e "${YELLOW}⚠️ 确定要删除文档: $(basename "$selected_doc")? (y/N)${NC}"
        read -p "确认 (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if safe_remove_file "$selected_doc"; then
                echo -e "${GREEN}✅ 文档已删除: $(basename "$selected_doc")${NC}"
            else
                echo -e "${RED}❌ 删除文档失败: $(basename "$selected_doc")${NC}"
            fi
        else
            echo -e "${GREEN}🔙 取消删除${NC}"
        fi
    fi
}

# 选择可用的文本编辑器
select_editor() {
    if command -v nano >/dev/null 2>&1; then
        echo "nano"
    elif command -v vim >/dev/null 2>&1; then
        echo "vim"
    elif command -v vi >/dev/null 2>&1; then
        echo "vi"
    else
        echo ""
    fi
}

# 编辑指定的AI文档文件
edit_ai_doc_file() {
    local doc_file=$1
    
    if [[ -z "$doc_file" ]]; then
        echo -e "${RED}❌ 未指定文档文件${NC}"
        return 1
    fi
    
    if ! file_exists "$doc_file"; then
        echo -e "${RED}❌ 文档文件不存在: $doc_file${NC}"
        return 1
    fi
    
    # 检查可用的编辑器
    local editor=$(select_editor)
    if [[ -z "$editor" ]]; then
        echo -e "${YELLOW}⚠️ 未找到可用的文本编辑器，请手动编辑: $doc_file${NC}"
        return 1
    fi
    
    echo -e "${GREEN}📝 使用 $editor 编辑文档: $doc_file${NC}"
    $editor "$doc_file"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✅ 文档编辑完成${NC}"
    else
        echo -e "${RED}❌ 文档编辑失败${NC}"
    fi
}

# 处理用户选择
# 处理用户选择
process_choice() {
    local choice=$1
    local tool_count=${#TOOLS[@]}
    
    # 检查是否为字母选择
    if [[ "$choice" == "m" || "$choice" == "M" ]]; then
        manage_mcp_servers
    elif [[ "$choice" == "d" || "$choice" == "D" ]]; then
        manage_ai_docs
    elif [[ "$choice" == "r" || "$choice" == "R" ]]; then
        info_log "刷新配置..."
        init_config
        check_tools
    elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        info_log "正在退出AI工具管理脚本..."
        save_cache  # 保存缓存
        echo -e "${GREEN}👋 再见!${NC}"
        exit 0
    # 检查选择是否为工具（数字）
    elif [[ $choice =~ ^[0-9]+$ ]] && [[ $choice -ge 1 && $choice -le $tool_count ]]; then
        local index=$((choice-1))
        if [ "${TOOL_STATUS[$index]}" = "true" ]; then
            update_tool $index
        else
            install_tool $index
        fi
    else
        echo -e "${RED}❌ 无效选项，请重试。${NC}"
    fi
}

# 主程序
main() {
    # 解析命令行参数，支持日志级别设置
    local log_level="info"
    local direct_mode=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log-level)
                log_level="$2"
                shift 2
                ;;
            --log-level=*)
                log_level="${1#*=}"
                shift
                ;;
            m|M|mcp)
                direct_mode="mcp"
                shift
                ;;
            d|D|docs)
                direct_mode="docs"
                shift
                ;;
            r|R|refresh)
                direct_mode="refresh"
                shift
                ;;
            h|help|--help|-h)
                show_help
                ;;
            *)
                # 非选项参数，停止解析
                break
                ;;
        esac
    done
    
    # 设置日志级别
    set_log_level "$log_level"
    info_log "AI工具管理脚本已启动 (日志级别: $log_level)"
    
    detect_os
    
    # 执行工具检查
    check_tools
    
    # 检查是否提供了直接模式参数
    if [[ -n "$direct_mode" ]]; then
        case $direct_mode in
            "mcp")
                manage_mcp_servers
                ;;
            "docs")
                manage_ai_docs
                ;;
            "refresh")
                init_config
                check_tools
                show_menu
                ;;
        esac
    else
        # 交互式菜单模式
        while true; do
            show_menu
            read -p "请选择操作: " choice
            
            # 处理退出命令
            if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
                info_log "正在退出AI工具管理脚本..."
                save_cache
                echo -e "${GREEN}👋 再见!${NC}"
                exit 0
            fi
            
            # 处理用户选择
            process_choice "$choice"
            echo ""
        done
    fi
    
    # 脚本结束时保存缓存
    save_cache
}

# 显示帮助信息
show_help() {
    echo "AI工具管理脚本"
    echo "用法:"
    echo "  $0              # 交互式菜单"
    echo "  $0 m            # 直接进入MCP管理"
    echo "  $0 r            # 刷新工具列表"
    echo "  $0 --log-level=LEVEL  # 设置日志级别 (debug/info/warn/error)"
    echo "  $0 --help       # 显示此帮助"
    echo "  $0 -h           # 显示此帮助"
    echo ""
    echo "环境变量:"
    echo "  CHROME_PATH     # 指定Chrome浏览器路径"
    echo "  AI_TOOLS_CONFIG # 指定配置文件路径"
    echo "  LOG_LEVEL       # 设置默认日志级别"
    echo ""
    echo "日志级别:"
    echo "  debug - 最详细，用于调试"
    echo "  info  - 默认级别，显示一般信息"
    echo "  warn  - 仅显示警告和错误"
    echo "  error - 仅显示错误"
    echo "  quiet - 静默模式，不显示任何日志"
    exit 0
}

# 在脚本启动时初始化配置
init_config

# 运行主程序
main "$@"
#!/bin/bash

# ==================== 配置校验和修复模块 ====================

# 校验配置文件的有效性
validate_config() {
    local config_file=$1
    local tool_name=$2
    local silent_mode="${3:-false}"
    local errors=()
    local warnings=()

    # 检查文件是否存在
    if ! file_exists "$config_file"; then
        errors+=("配置文件不存在: $config_file")
        return 1
    fi

    # 检查是否是有效的JSON或YAML
    if command -v jq >/dev/null 2>&1; then
        # 对于 JSON 文件，使用 jq 验证
        if [[ "$config_file" == *.json ]]; then
            if ! jq empty "$config_file" 2>/dev/null; then
                errors+=("配置文件不是有效的JSON格式")
                return 1
            fi
        fi
    fi

    # 对于 YAML 文件，进行基本验证
    if [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
        if ! file_exists "$config_file" || [[ ! -s "$config_file" ]]; then
            errors+=("配置文件为空或不存在")
            return 1
        fi
        # 检查是否有基本的 YAML 结构
        if ! grep -q ":" "$config_file" 2>/dev/null; then
            errors+=("配置文件不是有效的YAML格式")
            return 1
        fi
    fi

    # 检查MCP服务器配置
    if command -v jq >/dev/null 2>&1; then
        # 检查chrome-devtools配置
        local chrome_config=$(jq -r '.mcpServers["chrome-devtools"]' "$config_file" 2>/dev/null)
        if [[ -n "$chrome_config" && "$chrome_config" != "null" ]]; then
            local chrome_path=$(echo "$chrome_config" | jq -r '.args[] | select(startswith("--executablePath=")) | split("=")[1]' 2>/dev/null)
            if [[ -n "$chrome_path" ]]; then
                if ! validate_chrome_path "$chrome_path"; then
                    warnings+=("Chrome路径无效或不存在: $chrome_path")
                fi
            fi
        fi

        # 检查mysql配置
        local mysql_config=$(jq -r '.mcpServers.mysql' "$config_file" 2>/dev/null)
        if [[ -n "$mysql_config" && "$mysql_config" != "null" ]]; then
            local mysql_host=$(echo "$mysql_config" | jq -r '.env.MYSQL_HOST' 2>/dev/null)
            local mysql_port=$(echo "$mysql_config" | jq -r '.env.MYSQL_PORT' 2>/dev/null)
            if [[ -z "$mysql_host" || "$mysql_host" == "null" ]]; then
                warnings+=("MySQL配置缺少 MYSQL_HOST")
            fi
            if [[ -z "$mysql_port" || "$mysql_port" == "null" ]]; then
                warnings+=("MySQL配置缺少 MYSQL_PORT")
            fi
        fi
    fi

    # 检查 MetaGPT YAML 配置
    if [[ "$tool_name" == "MetaGPT" && "$config_file" == *.yaml ]]; then
        # 检查 API Key 是否已配置
        if grep -q "YOUR_API_KEY_HERE" "$config_file" 2>/dev/null; then
            warnings+=("MetaGPT API Key 未配置，请编辑配置文件设置您的 API Key")
        fi
        # 检查是否配置了 api_type
        if ! grep -q "api_type:" "$config_file" 2>/dev/null; then
            errors+=("MetaGPT 配置缺少 api_type")
        fi
        # 检查是否配置了 model
        if ! grep -q "model:" "$config_file" 2>/dev/null; then
            errors+=("MetaGPT 配置缺少 model")
        fi
    fi

    # 显示校验结果
    if [[ "$silent_mode" != "true" ]]; then
        if [[ ${#errors[@]} -gt 0 || ${#warnings[@]} -gt 0 ]]; then
            echo -e "${YELLOW}⚠️  $tool_name 配置校验结果:${NC}"
            
            for error in "${errors[@]}"; do
                echo -e "  ${RED}❌ $error${NC}"
            done
            
            for warning in "${warnings[@]}"; do
                echo -e "  ${YELLOW}⚠️  $warning${NC}"
            done
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}


# 通用MCP配置映射函数 - 将MCP名称转换为变量名
get_server_config_var() {
    local server_name=$1
    # 将连字符替换为无字符，生成bash兼容的变量名
    local var_name="mcp_$(echo $server_name | sed 's/-//g')"
    # 验证变量是否存在 - 使用间接引用检查变量是否存在
    if [[ -n "${!var_name+x}" ]]; then
        echo $var_name
    else
        # 如果转换后的变量不存在，返回空
        echo ""
    fi
}

# 通用获取服务器配置的函数
get_server_config() {
    local server_name=$1
    
    info_log "get_server_config: 请求 $server_name 的配置"
    
    # 优先从关联数组获取 (JSON配置模式)
    local cached_config=""
    cached_config=$(assoc_get_wrapper "MCP_SERVER_CONFIGS" "$server_name" 2>/dev/null || true)
    if [[ "$CACHE_SUPPORTED" == true && -n "$cached_config" ]]; then
        info_log "get_server_config: 从关联数组获取"
        echo "$cached_config"
        return 0
    fi

    # 后备：尝试从全局变量获取 (旧版变量模式)
    local var_name=$(get_server_config_var "$server_name")
    if [[ -n "$var_name" && -n "${!var_name}" ]]; then
        info_log "get_server_config: 从全局变量 $var_name 获取"
        echo "${!var_name}"
        return 0
    fi
    
    # 最后后备：直接从 JSON 配置文件读取
    local config_file=""
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info_log "get_server_config: 脚本目录=$script_dir"
    
    local possible_paths=(
        "$script_dir/ai-cli.json"
        "./ai-cli.json"
        "$HOME/.config/ai-tools/ai-cli.json"
        "/etc/ai-cli.json"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" ]]; then
            config_file="$path"
            info_log "get_server_config: 找到配置文件 $config_file"
            break
        fi
    done
    
    if [[ -z "$config_file" ]]; then
        error_log "get_server_config: 未找到配置文件"
        echo ""
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        info_log "get_server_config: 从 $config_file 读取 $server_name"
        local config_json=$(jq -r ".mcp_servers[\"$server_name\"].config | tostring" "$config_file" 2>/dev/null)
        info_log "get_server_config: 配置结果长度=${#config_json}"
        if [[ -n "$config_json" && "$config_json" != "null" ]]; then
            echo "$config_json"
            return 0
        else
            error_log "get_server_config: 配置为空或null"
        fi
    else
        error_log "get_server_config: jq 不可用"
    fi
    
    echo ""
    return 1
}




# ==================== 统一变量解析函数 ====================
# 支持 {{var}} 和 $VAR 两种格式，优先级：
# 1. 环境变量
# 2. global.json 中定义的全局变量
# 3. 系统变量 ($HOME, $USER, $PATH 等)

# 全局变量缓存（首次加载后复用）
_EXPAND_VARS_LOADED=false
declare -A _EXPAND_VARS_CACHE 2>/dev/null || true

# 加载全局变量定义
_load_expand_vars() {
    if [[ "$_EXPAND_VARS_LOADED" == "true" ]]; then
        return
    fi

    local global_file="${SCRIPT_DIR:-.}/conf/global.json"
    if [[ -f "$global_file" ]]; then
        # 优化：使用 json_batch_get 一次性读取所有字段
        local batch_output
        batch_output=$(json_batch_get "$global_file" "global.npm_registry" "proxy.http" "proxy.https" "proxy.pip")

        if [[ -n "$batch_output" ]]; then
            # 解析批量输出
            while IFS='=' read -r key value; do
                case "$key" in
                    "global.npm_registry") assoc_set_wrapper "_EXPAND_VARS_CACHE" "npm_registry" "$value" ;;
                    "proxy.http") assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_http" "$value" ;;
                    "proxy.https") assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_https" "$value" ;;
                    "proxy.pip") assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_pip" "$value" ;;
                esac
            done <<< "$batch_output"
        else
            # 后备方案：单独读取
            assoc_set_wrapper "_EXPAND_VARS_CACHE" "npm_registry" "$(jq -r '.global.npm_registry // "https://registry.npmmirror.com"' "$global_file" 2>/dev/null)"
            assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_http" "$(jq -r '.proxy.http // ""' "$global_file" 2>/dev/null)"
            assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_https" "$(jq -r '.proxy.https // ""' "$global_file" 2>/dev/null)"
            assoc_set_wrapper "_EXPAND_VARS_CACHE" "proxy_pip" "$(jq -r '.proxy.pip // ""' "$global_file" 2>/dev/null)"
        fi
    fi

    # 系统变量
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "HOME" "$HOME"
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "USER" "$USER"
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "PATH" "$PATH"
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "SCRIPT_DIR" "${SCRIPT_DIR:-.}"
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "workspace_path" "${AI_WORKSPACE_PATH:-${WORKSPACE_PATH:-$(cd "${SCRIPT_DIR:-.}/.." && pwd)}}"

    local chrome_path="${CHROME_PATH:-}"
    if [[ -z "$chrome_path" ]] && declare -F detect_chrome_path >/dev/null 2>&1; then
        chrome_path=$(detect_chrome_path 2>/dev/null || true)
    fi
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "chrome_path" "$chrome_path"

    local github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [[ -z "$github_token" ]] && command -v gh >/dev/null 2>&1; then
        github_token=$(gh auth token 2>/dev/null || true)
    fi
    assoc_set_wrapper "_EXPAND_VARS_CACHE" "github_token" "$github_token"

    _EXPAND_VARS_LOADED=true
}

# 展开字符串中的变量（支持 {{var}} 和 ${var} 格式）
expand_vars() {
    local input="$1"
    local result="$input"

    _load_expand_vars

    # 处理 {{var}} 格式
    while [[ "$result" =~ \{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value=""

        # 优先级：环境变量 > 缓存变量 > 保持原样
        if [[ -n "${!var_name:-}" ]]; then
            var_value="${!var_name}"
        else
            var_value=$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "$var_name")
            # 未知或未配置变量替换为空，避免把 {{placeholder}} 写进工具配置。
            [[ -z "$var_value" ]] && var_value=""
        fi

        result="${result//\{\{${var_name}\}\}/$var_value}"
    done

    # 处理 ${var} 格式（简单替换）
    # 注意：由于无法直接遍历模拟实现的关联数组，这里列出常用的系统变量进行替换
    local sys_vars=("HOME" "USER" "PATH" "SCRIPT_DIR" "npm_registry" "proxy_http" "proxy_https" "proxy_pip" "workspace_path" "chrome_path" "github_token")
    for var_name in "${sys_vars[@]}"; do
        local var_value=$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "$var_name")
        [[ -n "$var_value" ]] && result="${result//\$\{${var_name}\}/$var_value}"
    done

    # 处理通用 shell 风格环境变量: ${VAR} / ${VAR:-default}
    # MCP 配置里经常使用 ${TOKEN:-} 这类写法，写入前必须展开为实际值或默认值。
    while [[ "$result" =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*)(:-([^}]*))?\} ]]; do
        local token="${BASH_REMATCH[0]}"
        local var_name="${BASH_REMATCH[1]}"
        local default_value="${BASH_REMATCH[3]:-}"
        local var_value="${!var_name:-$default_value}"
        result="${result//$token/$var_value}"
    done

    result="${result//\{\{env.HOME\}\}/$HOME}"
    result="${result//\{\{env.USER\}\}/$USER}"
    result="${result//\{\{global.npm_registry\}\}/$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "npm_registry")}"

    echo "$result"
}

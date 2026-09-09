#!/bin/bash

# ==================== JSON 解析封装函数 ====================

# 工具元数据字段分隔符。不要使用 "|"：安装命令经常包含管道。
TOOL_FIELD_SEP="${TOOL_FIELD_SEP:-$'\037'}"

# 从 JSON 文件中获取字符串值
# 用法: json_get_str <文件路径> <jq表达式> [默认值]
json_get_str() {
    local file="$1"
    local expr="$2"
    local default="${3:-}"
    [[ -f "$file" ]] || { echo "$default"; return 1; }
    local result=$(jq -r "${expr} // \"${default}\"" "$file" 2>/dev/null)
    echo "${result:-$default}"
}

# 从 JSON 字符串中获取值
# 用法: json_get_val <JSON字符串> <jq表达式> [默认值]
json_get_val() {
    local json="$1"
    local expr="$2"
    local default="${3:-}"
    [[ -n "$json" ]] || { echo "$default"; return 1; }
    local result=$(echo "$json" | jq -r "${expr} // \"${default}\"" 2>/dev/null)
    echo "${result:-$default}"
}

# 检查 JSON 路径是否存在
# 用法: json_has <文件路径> <jq表达式>
json_has() {
    local file="$1"
    local expr="$2"
    [[ -f "$file" ]] || return 1
    jq -e "$expr" "$file" >/dev/null 2>&1
}

# 获取 JSON 数组长度
# 用法: json_arr_len <文件路径> <jq表达式>
json_arr_len() {
    local file="$1"
    local expr="$2"
    [[ -f "$file" ]] || { echo "0"; return 1; }
    jq -r "${expr} | length" "$file" 2>/dev/null || echo "0"
}

# 优化：批量读取 JSON 多个字段（减少 jq 调用次数）
# 用法: json_batch_get <文件路径> <字段1,字段2,...>
# 返回: 键值对格式 field1=value1\nfield2=value2
json_batch_get() {
    local file="$1"
    shift
    local fields=("$@")
    
    [[ -f "$file" ]] || return 1
    
    # 构建 jq 表达式一次性提取所有字段
    local jq_expr="{"
    local first=true
    for field in "${fields[@]}"; do
        if $first; then
            jq_expr+="\"$field\": .$field"
            first=false
        else
            jq_expr+=", \"$field\": .$field"
        fi
    done
    jq_expr+="} | to_entries[] | \"\(.key)=\(.value)\""
    
    jq -r "$jq_expr" "$file" 2>/dev/null
}

# 加载扩展命令列表 (从工具 JSON 中提取特定动作，如 post_install)
# 参数: $1 - 工具ID, $2 - 动作类型
load_extended_commands() {
    local tool_id=$1; local action=$2
    [[ "$action" =~ ^[a-zA-Z0-9_]+$ ]] || { echo "[]"; return 1; }
    # 从 TOOLS 数组中找到该工具的文件路径
    local tool_file=""
    for t in "${TOOLS[@]}"; do
        parse_tool_data "$t" "LEC"
        if [[ "$LEC_id" == "$tool_id" ]]; then
            tool_file="$LEC_file"
            break
        fi
    done

    [[ -f "$tool_file" ]] || { echo "null"; return 1; }
    
    # 提取 JSON 数组
    jq -c ".$action // []" "$tool_file" 2>/dev/null
}

# 优化：批量解析目录下所有工具配置 (带 AOT 编译缓存)
# 支持递归扫描子目录，自动根据子目录名推导 category
# 优先使用预编译缓存，缓存不存在时动态解析
#
# 输出字段格式 (16 字段，TOOL_FIELD_SEP 分隔):
# id, name, pkg, type, plugin, conf_path, pypi, cmd, v_check, desc, category, file_path, check_cmd, sort_order, sort_key, group
parse_all_tool_configs() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    local parser_version="tools-parser-v3-bulk"
    
    local cache_base="${AI_HUB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-hub}"
    local cache_dir="$cache_base"
    [[ "$(uname -s 2>/dev/null)" == "Darwin" && -z "${AI_HUB_CACHE_DIR:-}" && -z "${XDG_CACHE_HOME:-}" ]] && cache_dir="$HOME/Library/Caches/ai-hub"
    [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"
    local cache_file="$cache_dir/tools_compiled.txt"
    
    # 1. 计算配置目录的内容哈希指纹。使用文件内容本身计算 MD5/cksum。
    local current_fingerprint
    current_fingerprint=$(
        {
            printf '%s\n' "$parser_version" "$dir" "$HOME"
            cat "${LIB_DIR:-${SCRIPT_DIR:-.}/lib}/parse-tools.jq"
            find "$dir" -name "*.json" -type f | sort
            find "$dir" -name "*.json" -type f -exec cat {} + 2>/dev/null
        } | if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'; elif command -v md5 >/dev/null 2>&1; then md5 -q; else cksum | awk '{print $1}'; fi
    )
    current_fingerprint="${parser_version}:${current_fingerprint}"
    
    # 2. 检查缓存是否有效
    if [[ -f "$cache_file" ]]; then
        local cached_fingerprint=$(head -1 "$cache_file" | sed 's/#FINGERPRINT://')
        if [[ "$current_fingerprint" == "$cached_fingerprint" ]]; then
            debug_log "AOT 缓存命中，秒开工具列表"
            tail -n +2 "$cache_file"
            return 0
        fi
    fi

    debug_log "缓存失效，正在重新编译 AOT 元数据..."
    local files=() file
    while IFS= read -r file; do
        [[ "${file##*/}" == "_template.json" ]] || files+=("$file")
    done < <(find "$dir" -name '*.json' -type f | sort)
    [[ ${#files[@]} -gt 0 ]] || return 0

    # 一次 jq 解析所有文件；避免每个工具启动 jq / basename / awk / sed。
    local rows tmp_file
    rows=$(mktemp "$cache_dir/.tools_rows.XXXXXX") || return 1
    tmp_file=$(mktemp "$cache_dir/.tools_compiled.XXXXXX") || { rm -f "$rows"; return 1; }
    if ! jq -r --arg sep "$TOOL_FIELD_SEP" --arg user_home "$HOME" \
        -f "${LIB_DIR:-${SCRIPT_DIR:-.}/lib}/parse-tools.jq" "${files[@]}" > "$rows"; then
        rm -f "$rows" "$tmp_file"
        return 1
    fi
    {
        printf '#FINGERPRINT:%s\n' "$current_fingerprint"
        sort -t $'\t' -k1,1n -k2,2f -k3,3 "$rows" | cut -f4-
    } > "$tmp_file"
    rm -f "$rows"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$cache_file" || { rm -f "$tmp_file"; return 1; }
    tail -n +2 "$cache_file"
}

# 解析工具 JSON 配置文件并返回格式化字符串
# 用法: parse_tool_config <文件路径>
# 返回: id, name, pkg, type, plugin, config_path, use_official_pypi, cmd, version_check, desc, category, file_path, check_cmd, sort_order, sort_key
parse_tool_config() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    # 一次性调用 jq 提取所有字段，使用 __E__ 作为空值占位符
    jq -r '
        def p(v): (v // "") | tostring | gsub("[\r\n\t]+"; " ") | if . == "" then "__E__" else . end;
        def check_cmd:
            (.install.methods[0].check // "")
            | if type == "string" then . else "" end;
        [
            p(.id),
            p(.name),
            p(.install.methods[0].command // ""), # 临时占位，稍后提取 pkg
            p(.install.methods[0].type // "unknown"),
            p(.install.methods[0].plugin // ""),
            p(.config.path),
            "", # use_official_pypi 占位
            p(.commands.start // .id),
            (p(.commands.version) | tostring),
            p(.description),
            p(.category),
            p(check_cmd),
            p(.sort_order // .order // 5000),
            p(.sort_key // .name)
        ] | join("\t")
    ' "$file" | while IFS=$'\t' read -r id name inst_cmd type plugin conf_path pypi cmd v_check desc cat check_cmd sort_order sort_key; do
        # 还原占位符
        [[ "$id" == "__E__" ]] && id=""
        [[ "$name" == "__E__" ]] && name=""
        [[ "$inst_cmd" == "__E__" ]] && inst_cmd=""
        [[ "$type" == "__E__" ]] && type="unknown"
        [[ "$plugin" == "__E__" ]] && plugin=""
        [[ "$conf_path" == "__E__" ]] && conf_path=""
        [[ "$cmd" == "__E__" ]] && cmd=""
        [[ "$v_check" == "__E__" ]] && v_check=""
        [[ "$desc" == "__E__" ]] && desc=""
        [[ "$cat" == "__E__" ]] && cat=""
        [[ "$check_cmd" == "__E__" ]] && check_cmd=""
        [[ "$sort_order" == "__E__" || ! "$sort_order" =~ ^[0-9]+$ ]] && sort_order=5000
        [[ "$sort_key" == "__E__" || -z "$sort_key" ]] && sort_key="$name"

        # 提取包名
        local pkg=""
        case "$type" in
            "npm") pkg=$(echo "$inst_cmd" | sed -n 's/.*npm install -g \([^ ]*\).*/\1/p' | head -1) ;;
            "pip"|"pip_official") pkg=$(echo "$inst_cmd" | sed -n 's/.*pip3 install \([^ ]*\).*/\1/p' | head -1) ;;
            "brew") pkg=$(echo "$inst_cmd" | sed -n 's/.*brew install \([^ ]*\).*/\1/p' | head -1) ;;
        esac

        # 展开 config_path 中的 $HOME
        conf_path="${conf_path//\$HOME/$HOME}"

        echo "${id}${TOOL_FIELD_SEP}${name}${TOOL_FIELD_SEP}${pkg}${TOOL_FIELD_SEP}${type}${TOOL_FIELD_SEP}${plugin}${TOOL_FIELD_SEP}${conf_path}${TOOL_FIELD_SEP}${pypi}${TOOL_FIELD_SEP}${cmd}${TOOL_FIELD_SEP}${v_check}${TOOL_FIELD_SEP}${desc}${TOOL_FIELD_SEP}${cat}${TOOL_FIELD_SEP}${file}${TOOL_FIELD_SEP}${check_cmd}${TOOL_FIELD_SEP}${sort_order}${TOOL_FIELD_SEP}${sort_key}"
    done
}

# 使用jq更新JSON配置文件
update_json_config_with_jq() {
    local config_file="$1"
    local jq_filter="$2"
    shift 2
    local extra_args=("$@")
    local temp_file
    local config_lock="${config_file}.aihub.lock"

    [[ ! -f "$config_file" ]] && return 1
    if type acquire_config_lock >/dev/null 2>&1; then
        acquire_config_lock "$config_file" || return 1
        if type backup_config_file >/dev/null 2>&1; then
            backup_config_file "$config_file" || { release_config_lock "$config_lock"; return 1; }
        fi
    fi

    # 使用 jq 处理，并检查输出是否为有效的 JSON 且不为空
    temp_file=$(mktemp "$(dirname "$config_file")/.aihub-json.XXXXXX") || {
        type release_config_lock >/dev/null 2>&1 && release_config_lock "$config_lock"
        return 1
    }
    if jq "${extra_args[@]}" "$jq_filter" "$config_file" > "$temp_file" 2>/dev/null && [[ -s "$temp_file" ]] && jq empty "$temp_file" >/dev/null 2>&1; then
        chmod 600 "$temp_file" 2>/dev/null || true
        mv "$temp_file" "$config_file"
        type release_config_lock >/dev/null 2>&1 && release_config_lock "$config_lock"
        return 0
    fi
    rm -f "$temp_file"
    type release_config_lock >/dev/null 2>&1 && release_config_lock "$config_lock"
    return 1
}
cache_dir_jq() {
    local dir="$1"
    local cache_name="$2"
    local jq_cmd="$3"
    shift 3
    local files=("$@")

    local cache_base="${AI_HUB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-hub}"
    local cache_dir="$cache_base"
    [[ "$(uname -s 2>/dev/null)" == "Darwin" && -z "${AI_HUB_CACHE_DIR:-}" && -z "${XDG_CACHE_HOME:-}" ]] && cache_dir="$HOME/Library/Caches/ai-hub"
    [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"
    local cache_file="$cache_dir/${cache_name}_cache.txt"

    local current_fingerprint
    current_fingerprint=$(
        cat "${files[@]}" 2>/dev/null | if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'; elif command -v md5 >/dev/null 2>&1; then md5 -q; else cksum | awk '{print $1}'; fi
    )

    if [[ -f "$cache_file" ]]; then
        local cached_fingerprint=$(head -1 "$cache_file" | sed 's/#FINGERPRINT://')
        if [[ "$current_fingerprint" == "$cached_fingerprint" ]]; then
            tail -n +2 "$cache_file"
            return 0
        fi
    fi

    local tmp_file
    tmp_file=$(mktemp "${cache_dir}/.${cache_name}_cache.XXXXXX") || return 1
    if printf '%s\n' "#FINGERPRINT:$current_fingerprint" > "$tmp_file" \
        && jq -r "$jq_cmd" "${files[@]}" >> "$tmp_file" \
        && chmod 600 "$tmp_file" 2>/dev/null \
        && mv "$tmp_file" "$cache_file"; then
        tail -n +2 "$cache_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

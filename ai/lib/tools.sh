#!/bin/bash

# 解析工具元数据 (统一入口)
# 字段顺序 (16 字段，TOOL_FIELD_SEP 分隔):
#   id, name, pkg, type, plugin, conf_path, pypi, cmd, v_check, desc, category, tool_file, check_cmd, sort_order, sort_key, group
parse_tool_data() {
    local tool_str="$1"
    local prefix="${2:-T}" # 变量前缀，默认 T
    [[ "$prefix" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    local sep="${TOOL_FIELD_SEP:-$'\037'}"
    
    local IFS_OLD=$IFS
    if [[ "$tool_str" == *"$sep"* ]]; then
        IFS="$sep" read -r ${prefix}_id ${prefix}_name ${prefix}_pkg ${prefix}_type ${prefix}_plugin \
                 ${prefix}_conf ${prefix}_pypi ${prefix}_cmd ${prefix}_vcheck ${prefix}_desc \
                 ${prefix}_cat ${prefix}_file ${prefix}_check ${prefix}_order ${prefix}_sort_key \
                 ${prefix}_group <<< "$tool_str"
    else
        IFS='|' read -r ${prefix}_id ${prefix}_name ${prefix}_pkg ${prefix}_type ${prefix}_plugin \
                 ${prefix}_conf ${prefix}_pypi ${prefix}_cmd ${prefix}_vcheck ${prefix}_desc \
                 ${prefix}_cat ${prefix}_file ${prefix}_check ${prefix}_order ${prefix}_sort_key \
                 ${prefix}_group <<< "$tool_str"
    fi
    IFS=$IFS_OLD
    
    # 路径处理：只展开 $HOME，不执行任意 shell。
    local conf_var="${prefix}_conf"
    local conf_value="${!conf_var}"
    conf_value="${conf_value//\$HOME/$HOME}"
    printf -v "$conf_var" '%s' "$conf_value"

    local order_var="${prefix}_order"
    local order_value="${!order_var:-}"
    [[ "$order_value" =~ ^[0-9]+$ ]] || order_value=5000
    printf -v "$order_var" '%s' "$order_value"

    local sort_key_var="${prefix}_sort_key"
    local sort_key_value="${!sort_key_var:-}"
    local name_var="${prefix}_name"
    [[ -n "$sort_key_value" ]] || sort_key_value="${!name_var:-}"
    printf -v "$sort_key_var" '%s' "$sort_key_value"
}

# 获取全局 NPM 根目录 (动态检测)
_get_npm_root() {
    local cached=$(get_cache "npm_global_root")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return 0
    fi

    local npm_root
    npm_root=$(run_with_timeout 3 npm root -g 2>/dev/null || echo "")
    
    if [[ -z "$npm_root" ]]; then
        # npm 不可用时只检查当前 Node 前缀，不递归遍历整个 NVM 安装目录。
        local node_bin
        node_bin=$(command -v node 2>/dev/null || true)
        if [[ "$node_bin" == */bin/node ]]; then
            local candidate="${node_bin%/bin/node}/lib/node_modules"
            [[ ! -d "$candidate" ]] || npm_root="$candidate"
        fi
    fi

    if [[ -n "$npm_root" ]]; then
        set_cache "npm_global_root" "$npm_root" 3600
        echo "$npm_root"
    fi
}

# 快速检测单个工具状态
_pip_user_bin() {
    local base
    base=$(python3 -m site --user-base 2>/dev/null || true)
    [[ -n "$base" && -d "$base/bin" ]] && echo "$base/bin"
}

_pip_console_script_exists() {
    local cmd="$1"
    local user_bin
    [[ -n "$cmd" ]] || return 1

    user_bin=$(_pip_user_bin)
    [[ -n "$user_bin" && -x "$user_bin/$cmd" ]] && return 0
    return 1
}

_check_single_tool_fast() {
    local tool_str="$1"
    local npm_root="$2"
    
    parse_tool_data "$tool_str" "T"
    
    local is_installed=false
    local cmd_to_check="${T_cmd:-$T_id}"
    local check_cmd="${T_check:-}"
    
    local npm_check_pattern='^npm list -g ([^[:space:]]+) --depth=0$'
    if [[ "$check_cmd" =~ $npm_check_pattern && -n "$npm_root" ]]; then
        # npm list 会扫描整个全局依赖树；安装状态只需查看对应包元数据。
        [[ -f "$npm_root/${BASH_REMATCH[1]}/package.json" ]] && is_installed=true
    elif [[ -n "$check_cmd" ]]; then
        run_with_timeout "${AI_HUB_STATUS_CHECK_TIMEOUT:-5}" bash -c "$check_cmd" >/dev/null 2>&1 && is_installed=true
    elif [[ -n "$cmd_to_check" ]] && [[ "$cmd_to_check" != "open" ]] && command_exists "$cmd_to_check"; then
        is_installed=true
    elif [[ "$T_type" == "npm" && -n "$T_pkg" && -n "$npm_root" ]]; then
        local pkg_name="${T_pkg%@latest}"
        pkg_name="${pkg_name// /}"
        [[ -d "$npm_root/$pkg_name" || -d "$npm_root/node_modules/$pkg_name" ]] && is_installed=true
    elif [[ "$T_type" == "pip" || "$T_type" == "pip_official" ]] && command_exists pip3; then
        if _pip_console_script_exists "$cmd_to_check"; then
            is_installed=true
        fi
    fi
    
    echo "$is_installed"
}

# 统一工具状态检测入口
# 模式: fast (仅检查二进制), full (含版本号), force (强制刷新)
detect_tool_status() {
    local mode="${1:-fast}"
    local force_refresh=false
    [[ "$mode" == "force" ]] && force_refresh=true
    
    local categories="${2:-}"
    # 交互菜单只检测当前分类；未访问分类保留 unknown，不能误报为未安装。
    if [[ ${#TOOL_STATUS[@]} -eq 0 && "$force_refresh" == false ]]; then
        _load_tools_status_cache || true
    fi
    local pending=() idx
    for idx in "${!TOOLS[@]}"; do
        parse_tool_data "${TOOLS[$idx]}" "SCAN"
        [[ -n "${TOOL_STATUS[$idx]:-}" ]] || TOOL_STATUS[$idx]=unknown
        [[ -z "$categories" || " $categories " == *" $SCAN_cat "* ]] || continue
        if [[ "$force_refresh" == true || "${TOOL_STATUS[$idx]}" == unknown ]]; then
            pending+=("$idx")
        fi
    done
    local npm_root=""
    local npm_check_pattern='^npm list -g ([^[:space:]]+) --depth=0$'
    if [[ ${#pending[@]} -gt 0 ]]; then
        for idx in "${pending[@]}"; do
            parse_tool_data "${TOOLS[$idx]}" "SCAN"
            if [[ "$SCAN_check" =~ $npm_check_pattern ]] || { [[ "$SCAN_type" == npm && -z "$SCAN_check" ]] && ! command_exists "${SCAN_cmd:-$SCAN_id}"; }; then
                npm_root=$(_get_npm_root)
                break
            fi
        done
    fi

    # 固定大小的工作池；Bash 3.2 不支持 wait -n，按批回收明确的 PID。
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-status-check.XXXXXX") || return 1
    local limit="${MAX_CONCURRENT_PROCS:-5}"
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=5
    [[ "$limit" -le 32 ]] || limit=32
    local i=0 j pid status
    local pids=()
    [[ ${#pending[@]} -gt 0 ]] && echo -e "${CYAN}🚀 正在检测工具状态...${NC}" >&2
    for idx in "${pending[@]}"; do
        (_check_single_tool_fast "${TOOLS[$idx]}" "$npm_root" > "$tmp_dir/$idx") &
        pids+=("$!")
        i=$((i + 1))
        if [[ ${#pids[@]} -ge "$limit" ]]; then
            for pid in "${pids[@]}"; do wait "$pid" || true; done
            pids=()
        fi
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    for j in "${pending[@]}"; do
        status=false
        read -r status < "$tmp_dir/$j" || status=false
        TOOL_STATUS[$j]="$status"
    done
    INSTALLED_MCP_TOOLS=(); INSTALLED_MCP_CONFIGS=()
    for j in "${!TOOLS[@]}"; do
        if [[ "${TOOL_STATUS[$j]}" == "true" ]]; then
            parse_tool_data "${TOOLS[$j]}" "TMP"
            [[ -n "$TMP_conf" ]] && INSTALLED_MCP_TOOLS+=("$TMP_name") && INSTALLED_MCP_CONFIGS+=("$TMP_conf")
        fi
    done
    rm -rf "$tmp_dir"

    [[ ${#pending[@]} -eq 0 ]] || _save_tools_status_cache
    return 0
}

# 工具状态全局变量
TOOL_STATUS=()

# 已安装且支持MCP的工具列表
INSTALLED_MCP_TOOLS=()
INSTALLED_MCP_CONFIGS=()

# 工具状态缓存
TOOLS_STATUS_CACHE_FILE="${AI_HUB_STATUS_CACHE_FILE:-$HOME/.ai-tools-status-cache}"
TOOLS_STATUS_CACHE_TTL=300  # 5分钟

# 异步状态检测标志
ASYNC_STATUS_UPDATED=false
ASYNC_STATUS_CHECKING=false

# 异步状态检测：优先返回缓存，后台静默刷新
# 用法: detect_tool_status_async
detect_tool_status_async() {
    local force_refresh=false
    [[ "$1" == "force" ]] && force_refresh=true
    
    # 1. 优先从缓存加载（毫秒级响应）
    if [[ "$force_refresh" == false ]] && _load_tools_status_cache; then
        # 缓存命中，标记为正在后台检测
        ASYNC_STATUS_CHECKING=true
        _async_refresh_status &
        return 0
    fi
    
    # 2. 缓存失效，立即同步检测一次
    detect_tool_status "fast"
    ASYNC_STATUS_CHECKING=true
    _async_refresh_status &
}

# 后台异步刷新状态
_async_refresh_status() {
    local tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-status-async.XXXXXX")
    local npm_root=$(_get_npm_root)
    
    local i=0
    for tool in "${TOOLS[@]}"; do
        (
            local status=$(_check_single_tool_fast "$tool" "$npm_root")
            echo "$i|$status" > "$tmp_dir/$i.res"
        ) &
        ((i++))
        [[ $(jobs -r | wc -l) -ge 8 ]] && sleep 0.1
    done
    wait
    
    # 更新全局状态
    for ((j=0; j<i; j++)); do
        if [[ -f "$tmp_dir/$j.res" ]]; then
            IFS='|' read -r r_idx r_status < "$tmp_dir/$j.res"
            TOOL_STATUS[$j]="$r_status"
        fi
    done
    
    _save_tools_status_cache
    rm -rf "$tmp_dir"
    
    # 标记更新完成
    ASYNC_STATUS_UPDATED=true
    ASYNC_STATUS_CHECKING=false
}

# 获取异步检测状态提示
get_async_status_hint() {
    if [[ "$ASYNC_STATUS_CHECKING" == true ]]; then
        echo -e "${YELLOW}🔄 状态检测中...${NC}"
    elif [[ "$ASYNC_STATUS_UPDATED" == true ]]; then
        echo -e "${GREEN}✓ 状态已更新，按 R 刷新显示${NC}"
    fi
}

# 重置工具相关数组
reset_tool_arrays() {
    TOOL_STATUS=()
    INSTALLED_MCP_TOOLS=()
    INSTALLED_MCP_CONFIGS=()
}

# 计算配置目录的修改时间戳
_get_config_mtime() {
    local config_dir="${SCRIPT_DIR:-.}/conf"
    local lib_dir="${SCRIPT_DIR:-.}/lib"

    {
        local stat_cmd=""
        if stat -f "%m" . >/dev/null 2>&1; then
            stat_cmd="stat -f %m:%N"
        elif stat -c "%Y" . >/dev/null 2>&1; then
            stat_cmd="stat -c %Y:%n"
        fi

        if [[ -n "$stat_cmd" ]]; then
            if [[ -d "$config_dir" ]]; then
                find "$config_dir" -name "*.json" -type f 2>/dev/null | sort | tr '\n' '\0' | xargs -0 $stat_cmd 2>/dev/null
            fi

            for file in "$lib_dir/json.sh" "$lib_dir/parse-tools.jq" "$lib_dir/tools.sh"; do
                [[ -f "$file" ]] && $stat_cmd "$file" 2>/dev/null
            done
        fi
    } | cksum | awk '{print $1":"$2}'
}

# 保存工具状态到缓存
_save_tools_status_cache() {
    local cache_data=""
    for status in "${TOOL_STATUS[@]}"; do
        cache_data+="${status}"$'\n'
    done
    # 同时保存配置目录的时间戳
    local conf_mtime=$(_get_config_mtime)
    {
        echo "#CONF_MTIME:$conf_mtime"
        echo "$cache_data"
    } > "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
}

# 从缓存加载工具状态（force=1 时强制刷新）
_load_tools_status_cache() {
    local force_refresh="${1:-0}"

    # Force cache invalidation if marker file exists
    local marker="${SCRIPT_DIR:-.}/conf/.force_cache_invalid"
    if [[ -f "$marker" ]]; then
        rm -f "$marker" 2>/dev/null || true
        rm -f "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
        return 1
    fi

    if [[ "$force_refresh" == "1" ]] || [[ ! -f "$TOOLS_STATUS_CACHE_FILE" ]]; then
        return 1
    fi

    local cache_age=$(($(date +%s) - $(stat -f %m "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || stat -c %Y "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || echo 0)))
    if [[ $cache_age -gt $TOOLS_STATUS_CACHE_TTL ]]; then
        rm -f "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
        return 1
    fi

    # 检查配置目录是否被修改
    local current_mtime=$(_get_config_mtime)
    local cached_mtime
    cached_mtime=$(head -1 "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null | sed 's/#CONF_MTIME://')
    if [[ "$current_mtime" != "$cached_mtime" ]]; then
        rm -f "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
        return 1
    fi

    TOOL_STATUS=()
    while IFS= read -r line; do
        [[ "$line" == \#* ]] && continue
        [[ -n "$line" ]] && TOOL_STATUS+=("$line")
    done < "$TOOLS_STATUS_CACHE_FILE"

    debug_log "从缓存加载工具状态 (${#TOOL_STATUS[@]} 项, 年龄: ${cache_age}s)"
    return 0
}

# 强制刷新工具状态缓存
refresh_tools_status() {
    debug_log "强制刷新工具状态缓存..."
    rm -f "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
    # 同时清除 npm_root 缓存，确保重新检测
    clear_cache "npm_global_root" 2>/dev/null || true
    detect_tool_status "fast"
}

# 兼容旧入口名
check_tools() {
    local mode="${1:-fast}"
    [[ "$mode" == "true" ]] && mode="fast"
    detect_tool_status "$mode"
}

check_tools_fast() {
    detect_tool_status "fast"
}

# 构建工具菜单选项 (用于子菜单)
# 参数1: filter - "all", "installable", "installed"
# 参数2: opts_var - 选项数组名
# 参数3: idxs_var - 索引数组名
build_tool_menu_options() {
    local filter=$1; local opts_var=$2; local idxs_var=$3
    local _built_opts=(); local _built_idxs=()
    local i=0 _gj
    local _seen_groups=""  # 已显示的变体组名
    for tool in "${TOOLS[@]}"; do
        parse_tool_data "$tool" "BT"
        local status="${TOOL_STATUS[$i]}"
        local add=false
        local display_text=""
        local badge=""
        if declare -F tool_category_badge >/dev/null 2>&1; then
            badge=$(tool_category_badge "$BT_cat")
        fi

        # === 变体工具合并处理 ===
        if [[ -n "$BT_group" ]]; then
            if [[ " $_seen_groups " == *" $BT_group "* ]]; then
                ((i++)); continue  # 跳过，已在合并条目中显示
            fi
            _seen_groups+=" $BT_group"

            # 统计该 group 下所有变体
            local _g_count=0 _g_installed=0 _g_first_idx=-1
            for ((_gj=0; _gj<${#TOOLS[@]}; _gj++)); do
                parse_tool_data "${TOOLS[$_gj]}" "_GC"
                [[ "$_GC_group" == "$BT_group" ]] || continue
                [[ $_g_first_idx -lt 0 ]] && _g_first_idx=$_gj
                ((_g_count++))
                [[ "${TOOL_STATUS[$_gj]}" == "true" ]] && ((_g_installed++))
            done

            # 根据 filter 决定是否添加
            if [[ "$filter" == "installed" && $_g_installed -eq 0 ]]; then
                ((i++)); continue
            fi
            if [[ "$filter" == "installable" && $_g_installed -eq $_g_count ]]; then
                ((i++)); continue
            fi

            local _g_disp_name="${BT_name% (*}"
            [[ "$_g_disp_name" == "$BT_name" ]] && _g_disp_name="$BT_name"
            local g_status_icon="${YELLOW}⚠️ ${NC}"
            local g_extra="未安装"
            if [[ $_g_installed -gt 0 ]]; then
                g_status_icon="${GREEN}✅ ${NC}"
                if [[ $_g_installed -lt $_g_count ]]; then
                    g_extra="${_g_installed}/${_g_count}已安装"
                else
                    g_extra="全部已安装"
                fi
            fi
            display_text="${g_status_icon}${badge}${_g_disp_name} 📦${_g_count}版本${NC} - ${g_extra}"
            add=true
        fi
        # === 变体工具合并处理结束 ===

        if [[ "$add" != "true" ]]; then
            if [[ "$status" == "true" ]]; then
                if [[ "$filter" != "installable" ]]; then
                    local status_text="已安装"
                    if declare -F get_tool_display_status >/dev/null 2>&1; then
                        status_text=$(get_tool_display_status "$i")
                    fi
                    display_text="${GREEN}✅ ${badge}${BT_name}${NC} - ${status_text}"; add=true
                fi
            else
                if [[ "$filter" != "installed" ]]; then
                    display_text="${YELLOW}⚠️ ${badge}${BT_name}${NC} - 未安装"; add=true
                fi
            fi
        fi
        if [[ "$add" == "true" ]]; then _built_opts+=("$display_text"); _built_idxs+=($i); fi
        ((i++))
    done
    [[ "$opts_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$idxs_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    eval "$opts_var=(\"\${_built_opts[@]}\")"
    eval "$idxs_var=(\"\${_built_idxs[@]}\")"
}

# 批量校验所有已安装工具的配置
validate_all_configs() {
    echo -e "${CYAN}🔍 校验所有AI工具配置...${NC}\n"
    
    # 刷新工具列表
    check_tools
    
    local has_errors=false
    
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        echo -e "${BLUE}检查: $ai_tool${NC}"
        if ! validate_config "$config_file" "$ai_tool" "false"; then
            has_errors=true
            read -p "是否要修复 $ai_tool 的配置? (y/N): " fix_config
            if [[ "$fix_config" == "y" || "$fix_config" == "Y" ]]; then
                interactive_config_fix "$config_file" "$ai_tool"
            fi
        fi
        echo ""
    done
    
    if [[ "$has_errors" == false ]]; then
        echo -e "${GREEN}✅ 所有配置校验通过${NC}"
    fi
}

# 获取工具版本号
get_tool_version() {
    local tool_index=$1
    local timeout_sec="${2:-2}"
    local version=""
    
    local tool="${TOOLS[$tool_index]}"
    parse_tool_data "$tool" "V"
    
    # 优先从缓存获取
    version=$(get_cache "ver:${V_id}")
    [[ -n "$version" ]] && { echo "$version"; return 0; }

    # 解析版本检查逻辑 (优化：避免重复 jq 调用)
    if [[ "$V_vcheck" != "null" && "$V_vcheck" != "{}" ]]; then
        local method=""
        if echo "$V_vcheck" | jq -e 'type == "object"' >/dev/null 2>&1; then
            method=$(echo "$V_vcheck" | jq -r '.method // ""' 2>/dev/null)
        else
            # 兼容配置中的字符串版本命令，例如 `tool --version` 或脚本查询命令。
            version=$(run_with_timeout "$timeout_sec" bash -c "$V_vcheck" 2>/dev/null | head -n 1)
            method="string"
        fi
        case "$method" in
            "npm")
                local pkg_clean="${V_pkg%@*}"; [[ "$V_pkg" == @* ]] && pkg_clean="@${V_pkg#@}" && pkg_clean="@${pkg_clean%%@*}"
                version=$(npm list -g "$pkg_clean" --depth=0 2>/dev/null | grep "@" | head -1 | sed 's/.*@//' | awk '{print $1}')
                ;;
            "pip")
                version=$(pip3 show "$V_pkg" 2>/dev/null | grep "^Version:" | cut -d' ' -f2)
                ;;
            "cmd")
                local args=$(echo "$V_vcheck" | jq -r '.args // ["--version"] | join(" ")' 2>/dev/null)
                version=$(run_with_timeout $timeout_sec "${V_cmd:-$V_id}" $args 2>/dev/null | head -n 1)
                ;;
        esac
    else
        # 默认尝试 --version
        version=$(run_with_timeout $timeout_sec "${V_cmd:-$V_id}" --version 2>/dev/null | head -n 1)
    fi

    # 清理非版本号字符
    version=$(echo "$version" | tr -cd '0-9.a-zA-Z\-' | head -c 20)
    [[ -n "$version" ]] && set_cache "ver:${V_id}" "$version" 3600
    echo "$version"
}

# 自动校验所有已安装工具的配置（静默模式）
auto_validate_all_configs() {
    local silent_mode="${1:-false}"
    [[ "$silent_mode" != "true" ]] && debug_log "开始自动校验配置..."
    
    # 不再重复调用 check_tools，因为在 init_config 中已经调用过了
    # 只在 INSTALLED_MCP_TOOLS 为空时才调用
    if [[ ${#INSTALLED_MCP_TOOLS[@]} -eq 0 ]]; then
        check_tools "true"
    fi
    
    local has_errors=false
    
    for idx in "${!INSTALLED_MCP_TOOLS[@]}"; do
        local ai_tool="${INSTALLED_MCP_TOOLS[$idx]}"
        local config_file="${INSTALLED_MCP_CONFIGS[$idx]}"
        
        # 只在配置文件存在时才校验
        if [[ -n "$config_file" && -f "$config_file" ]]; then
            debug_log "检查配置: $ai_tool"
            if ! validate_config "$config_file" "$ai_tool" "true"; then
                has_errors=true
                # 静默模式下只记录日志，不提示用户
                warn_log "$ai_tool 配置校验发现问题，请使用菜单选项 'm' 进行修复"
            fi
        fi
    done
    
    if [[ "$has_errors" == false ]]; then
        debug_log "所有配置校验通过"
    fi
}

# 通用包管理操作函数
exec_pkg_op() {
    local mgr=$1     # npm / brew
    local op=$2      # install / update / uninstall
    local name=$3
    local pkg=$(echo "$4" | xargs)
    local registry=${5:-$npm_registry}
    local tool_id=$6     # 工具 id
    local tool_type=$7   # 工具类型
    local tool_cmd=$8    # 执行命令名
    
    local clean_pkg="${pkg%%@*}"; [[ "$pkg" == @* ]] && clean_pkg="@${pkg#@}" && clean_pkg="@${clean_pkg%%@*}"

    # 检查基础工具
    # pip 检查时使用 pip3，与执行命令保持一致
    local check_cmd="$mgr"
    [[ "$mgr" == "pip" || "$mgr" == "pip_official" ]] && check_cmd="pip3"

    if [[ "$mgr" == npm && ( "$op" == install || "$op" == update ) ]]; then
        ensure_node_runtime || return $?
    fi

    if ! command_exists "$check_cmd"; then
        case "$mgr" in
            npm)
                error_log "未找到 npm 包管理器。请安装 Node.js 和 npm: macOS: 'brew install node' | Linux: 'apt install nodejs npm' 或访问 https://nodejs.org/"
                return 1
                ;;
            brew)
                if [[ "$OS" == "macOS" ]]; then
                    warn_log "未找到 Homebrew，尝试安装..."
                    local brew_install_script
                    brew_install_script=$(mktemp "${TMPDIR:-/tmp}/aihub-homebrew.XXXXXX") || return 1
                    if curl -fsSL --max-time 30 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$brew_install_script"; then
                        /bin/bash "$brew_install_script" >/dev/null 2>&1 || {
                            rm -f "$brew_install_script"
                            error_log "Homebrew 安装失败，请手动安装: https://brew.sh/"
                            return 1
                        }
                    else
                        rm -f "$brew_install_script"
                        error_log "Homebrew 安装脚本下载失败，请手动安装: https://brew.sh/"
                        return 1
                    fi
                    rm -f "$brew_install_script"
                else
                    error_log "Linux 不支持 Homebrew，请使用其他包管理器"
                    return 1
                fi
                ;;
            pip|pip_official)
                error_log "未找到 pip3，请先安装 Python 3 和 pip。macOS: 'brew install python3' | Linux: 'apt install python3-pip' | 或访问 https://www.python.org/"
                return 1
                ;;
            uv)
                warn_log "未找到 uv，尝试安装..."
                local uv_install_script
                uv_install_script=$(mktemp "${TMPDIR:-/tmp}/aihub-uv.XXXXXX") || return 1
                if curl -LsSf --max-time 30 https://astral.sh/uv/install.sh -o "$uv_install_script"; then
                    sh "$uv_install_script" >/dev/null 2>&1 || {
                        rm -f "$uv_install_script"
                        error_log "uv 安装失败，请手动安装: https://github.com/astral-sh/uv 或使用 'pip install uv'"
                        return 1
                    }
                else
                    rm -f "$uv_install_script"
                    error_log "uv 安装脚本下载失败，请手动安装: https://github.com/astral-sh/uv 或使用 'pip install uv'"
                    return 1
                fi
                rm -f "$uv_install_script"
                # 重新加载 PATH
                export PATH="$HOME/.cargo/bin:$PATH"
                ;;
            bash)
                error_log "Bash 安装方式需要 curl 命令，请安装 curl: macOS: 'brew install curl' | Linux: 'apt install curl'"
                return 1
                ;;
            *)
                error_log "不支持的包管理器: $mgr。支持的类型: npm, brew, pip, pip_official, uv, bash"
                return 1
                ;;
        esac
    fi

    # 命令映射
    local sub_cmd="$op"
    if [[ "$mgr" == "npm" && "$op" == "update" ]]; then
        sub_cmd="install"
    elif [[ "$mgr" == "brew" && "$op" == "update" ]]; then
        sub_cmd="upgrade"
    elif [[ "$mgr" == "uv" && "$op" == "update" ]]; then
        sub_cmd="upgrade"
    fi

    local run_cmd=""
    case $mgr in
        npm)
            run_cmd="npm $sub_cmd -g '$pkg' --registry '$registry'"
            # 添加代理支持
            [[ -n "$proxy_http" ]] && run_cmd="HTTP_PROXY='$proxy_http' $run_cmd"
            [[ -n "$proxy_https" ]] && run_cmd="HTTPS_PROXY='$proxy_https' $run_cmd"
            ;;
        brew)
            run_cmd="brew $sub_cmd '$pkg'"
            # 添加代理支持
            [[ -n "$proxy_http" ]] && run_cmd="ALL_PROXY='$proxy_http' $run_cmd"
            ;;
        pip)
            local pip_pkg="$pkg"
            # 如果是 git+https://github.com/ 开头的 URL，使用 URL 替换服务
            if [[ "$pkg" == git+https://github.com/* ]]; then
                if [[ -n "$proxy_git_url_replace" ]]; then
                    pip_pkg="git+${proxy_git_url_replace}/${pkg#git+https://github.com/}"
                fi
            fi
            if [[ "$op" == "uninstall" ]]; then
                run_cmd="pip3 $sub_cmd -y $pip_pkg"
            else
                run_cmd="pip3 $sub_cmd $pip_pkg"
            fi
            # 添加代理支持
            [[ -n "$proxy_pip" ]] && run_cmd="$run_cmd --proxy '$proxy_pip'"
            ;;
        pip_official)
            local pip_pkg="$pkg"
            if [[ "$op" == "uninstall" ]]; then
                # 使用官方 PyPI，卸载不需 index
                run_cmd="pip3 $sub_cmd -y $pip_pkg"
            else
                # 使用官方 PyPI
                run_cmd="pip3 $sub_cmd $pip_pkg --index-url https://pypi.org/simple/ --trusted-host pypi.org --trusted-host files.pythonhosted.org"
            fi
            # 添加代理支持
            [[ -n "$proxy_pip" ]] && run_cmd="$run_cmd --proxy '$proxy_pip'"
            ;;
        uv)
            run_cmd="uv $sub_cmd '$pkg'"
            # 添加代理支持
            [[ -n "$proxy_http" ]] && run_cmd="HTTP_PROXY='$proxy_http' HTTPS_PROXY='$proxy_https' $run_cmd"
            ;;
        bash)
            # 特殊处理 bash 安装方式
            if [[ "$op" == "install" || "$op" == "update" ]]; then
                # pkg 应该已经是完整的 curl | bash 命令
                # 检查是否已经包含管道符
                if [[ "$pkg" == *"|"* ]]; then
                    run_cmd="$pkg"
                else
                    # 如果只是 URL，先下载到受控临时文件再执行，避免 curl | bash。
                    if [[ -z "$pkg" ]]; then
                        error_log "$name $op 缺少安装 URL 或命令，已停止执行"
                        return 1
                    fi
                    run_cmd="tmp=\$(mktemp \"\${TMPDIR:-/tmp}/aihub-install.XXXXXX\") && curl -LsSf '$pkg' -o \"\$tmp\" && bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc"
                fi
                # 添加代理支持
                if [[ -n "$proxy_http" ]]; then
                    run_cmd="HTTP_PROXY='$proxy_http' HTTPS_PROXY='$proxy_https' $run_cmd"
                fi
            else
                # 卸载由 bash 脚本安装的工具
                # 这里需要根据具体工具的卸载方式进行处理
                # 暂时返回成功，实际卸载需要在 extended_commands 中处理
                return 0
            fi
            ;;
        *)
            error_log "不支持的包管理器: $mgr"
            return 1
            ;;
    esac

    # 执行命令
    debug_log "执行包管理命令: $run_cmd"
    if eval "$run_cmd"; then
        return 0
    fi

    local rc=$?
    # 针对 npm install -g 的 ENOTEMPTY 错误进行特殊处理
    if [[ "$mgr" == "npm" && ("$op" == "install" || "$op" == "update") ]]; then
        # 简单重试逻辑
        warn_log "npm 安装失败 (rc=$rc)，尝试清理残留目录并重试..."
        local npm_root
        npm_root=$(_get_npm_root)
        if [[ -n "$npm_root" ]]; then
            local pkg_name="${pkg%%@*}"
            [[ "$pkg" == @* ]] && pkg_name="@${pkg#@}" && pkg_name="@${pkg_name%%@*}"
            local pkg_path="$npm_root/$pkg_name"
            if [[ -d "$pkg_path" ]]; then
                info_log "正在清理冲突目录: $pkg_path"
                rm -rf "$pkg_path" 2>/dev/null || sudo rm -rf "$pkg_path" 2>/dev/null || true
            fi
            # 清理可能的临时重命名目录 (npm 常见行为)
            local parent_dir=$(dirname "$pkg_path")
            local base_name=$(basename "$pkg_path")
            find "$parent_dir" -maxdepth 1 -name ".${base_name}-*" -type d -exec rm -rf {} + 2>/dev/null || true
        fi
        
        info_log "正在重试安装..."
        eval "$run_cmd"
        return $?
    fi

    return $rc
}

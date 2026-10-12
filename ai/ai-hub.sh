#!/usr/bin/env bash

# AI 工具中枢 (AI Hub) - 全生命周期 AI 工具管理系统
# 整合 AI 客户端、AI 原生 IDE、网关、MCP 与 Skills
# 兼容 Bash 3.2+ (macOS/Linux)

# ==================== 1. 基础加载 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AI_HUB_SCRIPT_DIR="$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/loader.sh"

# 常量
DEFAULT_TIMEOUT=10
KEY_INPUT_TIMEOUT=0.15
MAX_CONCURRENT_PROCS=5

# 全局变量
TOOL_STATUS=()
INSTALLED_MCP_TOOLS=()
INSTALLED_MCP_CONFIGS=()
MCP_SERVERS_NAMES=()
[[ "$_USE_ASSOC_ARRAY" == "true" ]] && declare -A MCP_SERVER_CONFIGS 2>/dev/null
FILTERED_MCP_SKIPPED=()
SKILLS=()
SKILLS_NAMES=()
[[ "$_USE_ASSOC_ARRAY" == "true" ]] && declare -A SKILL_CONFIGS 2>/dev/null
INSTALLED_SKILLS=()
BATCH_LOCK_DIR=""
CONFIG_LOCK_DIR=""
AI_HUB_CONFIG_PROMPT_TIMEOUT="${AI_HUB_CONFIG_PROMPT_TIMEOUT:-30}"

# 配置变量
RECOMMENDED_TOOLS_STR=""
DEFAULT_SCENARIO="productivity"
SCENARIO_KEYS=()
SCENARIO_NAMES=()
SCENARIO_DESCS=()
SCENARIO_INCLUDE_OPTIONAL=()
SCENARIO_INCLUDE_EXPERIMENTAL=()

# ==================== 2. 初始化逻辑 ====================

init_config() {
    local v2_dir="${SCRIPT_DIR:-.}/conf"
    if [[ -d "$v2_dir" && -f "$v2_dir/global.json" ]]; then
        CONFIG_DIR_PATH="$v2_dir"
        CONFIG_FILE_PATH="$v2_dir/global.json"
        _init_config_v2 "$v2_dir"
    else
        _init_config_legacy "./ai-cli.json"
    fi
}

_init_config_v2() {
    local dir="$1"
    command_exists jq || { error_log "缺少 jq"; exit 1; }

    # 1. 加载全局配置
    local gf="$dir/global.json"
    if [[ -f "$gf" ]]; then
        _load_expand_vars
        proxy_http=$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "proxy_http")
        proxy_https=$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "proxy_https")
        npm_registry=$(assoc_get_wrapper "_EXPAND_VARS_CACHE" "npm_registry")

        # 全局运行参数必须以 global.json 为准，保留默认值作为兼容兜底。
        DEFAULT_TIMEOUT=$(jq -r '.global.default_timeout // 10' "$gf" 2>/dev/null)
        KEY_INPUT_TIMEOUT=$(jq -r '.global.key_input_timeout // 0.15' "$gf" 2>/dev/null)
        MAX_CONCURRENT_PROCS=$(jq -r '.global.max_concurrent_procs // 5' "$gf" 2>/dev/null)
        
        # 使用哈希缓存 global.json 的解析结果，大幅提升加载速度
        local cache_dir="${AI_HUB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-hub}"
        [[ "$(uname -s 2>/dev/null)" == "Darwin" && -z "${AI_HUB_CACHE_DIR:-}" && -z "${XDG_CACHE_HOME:-}" ]] && cache_dir="$HOME/Library/Caches/ai-hub"
        mkdir -p "$cache_dir" 2>/dev/null || true
        local global_cache="$cache_dir/global_config_cache.tsv"

        local current_gf_hash
        current_gf_hash=$(cat "$gf" 2>/dev/null | if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'; elif command -v md5 >/dev/null 2>&1; then md5 -q; else cksum | awk '{print $1}'; fi)

        local use_cache=false
        if [[ -f "$global_cache" && ! -L "$global_cache" ]]; then
            local cached_hash=$(head -1 "$global_cache" | sed 's/#HASH://')
            if [[ "$current_gf_hash" == "$cached_hash" ]]; then
                use_cache=true
            fi
        fi

        if $use_cache; then
            # 缓存是数据文件，不 source 用户可写内容。
            while IFS=$'\t' read -r cache_key cache_value; do
                case "$cache_key" in
                    RECOMMENDED_TOOLS_STR) RECOMMENDED_TOOLS_STR="$cache_value" ;;
                    DEFAULT_SCENARIO) DEFAULT_SCENARIO="$cache_value" ;;
                    SCENARIO_KEYS) IFS=$'\034' read -r -a SCENARIO_KEYS <<< "$cache_value" ;;
                    SCENARIO_NAMES) IFS=$'\034' read -r -a SCENARIO_NAMES <<< "$cache_value" ;;
                    SCENARIO_DESCS) IFS=$'\034' read -r -a SCENARIO_DESCS <<< "$cache_value" ;;
                    SCENARIO_INCLUDE_OPTIONAL) IFS=$'\034' read -r -a SCENARIO_INCLUDE_OPTIONAL <<< "$cache_value" ;;
                    SCENARIO_INCLUDE_EXPERIMENTAL) IFS=$'\034' read -r -a SCENARIO_INCLUDE_EXPERIMENTAL <<< "$cache_value" ;;
                esac
            done < <(tail -n +2 "$global_cache")
        else
            RECOMMENDED_TOOLS_STR=" $(jq -r '.recommended_tools | join(" ")' "$gf") "
            DEFAULT_SCENARIO=$(jq -r '.default_scenario // "productivity"' "$gf")
            SCENARIO_KEYS=(); SCENARIO_NAMES=(); SCENARIO_DESCS=(); SCENARIO_INCLUDE_OPTIONAL=(); SCENARIO_INCLUDE_EXPERIMENTAL=()
            while IFS=$'\t' read -r skey sname sdesc sopt sexp; do
                [[ -z "$skey" ]] && continue
                SCENARIO_KEYS+=("$skey")
                SCENARIO_NAMES+=("${sname:-$skey}")
                SCENARIO_DESCS+=("${sdesc:-}")
                SCENARIO_INCLUDE_OPTIONAL+=("${sopt:-false}")
                SCENARIO_INCLUDE_EXPERIMENTAL+=("${sexp:-false}")
            done < <(jq -r '.scenarios // {} | to_entries | sort_by(.value.order // 999)[] | [.key, (.value.name // .key), (.value.description // ""), ((.value.include_optional // false)|tostring), ((.value.include_experimental // false)|tostring)] | @tsv' "$gf")

            # 写入纯数据缓存，禁止 source；使用临时文件保证中断时不留下半成品。
            local cache_tmp
            cache_tmp=$(mktemp "${cache_dir}/.global_config_cache.XXXXXX" 2>/dev/null) || cache_tmp=""
            if [[ -n "$cache_tmp" ]]; then
                {
                    printf '#HASH:%s\n' "$current_gf_hash"
                    printf 'RECOMMENDED_TOOLS_STR\t%s\n' "$RECOMMENDED_TOOLS_STR"
                    printf 'DEFAULT_SCENARIO\t%s\n' "$DEFAULT_SCENARIO"
                    printf 'SCENARIO_KEYS\t%s\n' "$(printf '%s\034' "${SCENARIO_KEYS[@]}")"
                    printf 'SCENARIO_NAMES\t%s\n' "$(printf '%s\034' "${SCENARIO_NAMES[@]}")"
                    printf 'SCENARIO_DESCS\t%s\n' "$(printf '%s\034' "${SCENARIO_DESCS[@]}")"
                    printf 'SCENARIO_INCLUDE_OPTIONAL\t%s\n' "$(printf '%s\034' "${SCENARIO_INCLUDE_OPTIONAL[@]}")"
                    printf 'SCENARIO_INCLUDE_EXPERIMENTAL\t%s\n' "$(printf '%s\034' "${SCENARIO_INCLUDE_EXPERIMENTAL[@]}")"
                } > "$cache_tmp" && chmod 600 "$cache_tmp" 2>/dev/null && mv "$cache_tmp" "$global_cache" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null
            fi
        fi
    fi

    # 2. 批量加载工具列表
    TOOLS=()
    [[ -d "$dir/tools" ]] && while IFS= read -r t; do [[ -n "$t" ]] && TOOLS+=("$t"); done < <(parse_all_tool_configs "$dir/tools")

    # 3. 加载公共 MCP 服务器
    mcp_servers=(); MCP_SERVERS_NAMES=()
    local md="$dir/shared/mcp-servers"
    if [[ -d "$md" ]]; then
        local mcp_files=()
        for f in "$md"/*.json; do
            [[ -f "$f" ]] && [[ "${f##*/}" != _* ]] && mcp_files+=("$f")
        done
        if [[ ${#mcp_files[@]} -gt 0 ]]; then
            while IFS=$'\t' read -r mid mname mtype mconf; do
                mcp_servers+=("$mid:$mname::${mtype}")
                MCP_SERVERS_NAMES+=("$mid")
                [[ "$CACHE_SUPPORTED" == true ]] && assoc_set_wrapper "MCP_SERVER_CONFIGS" "$mid" "$mconf"
            done < <(cache_dir_jq "$md" "mcp_servers" '[.id//"", .name//"", .install.type//"npm", (.config//{}|tojson)]|join("\t")' "${mcp_files[@]}")
        fi
    fi

    # 4. 加载公共 Skills
    local sd="$dir/shared/skills"
    if [[ -d "$sd" ]]; then
        local skill_files=()
        for f in "$sd"/*.json; do
            [[ -f "$f" ]] && [[ "${f##*/}" != _* ]] && skill_files+=("$f")
        done
        if [[ ${#skill_files[@]} -gt 0 ]]; then
            while IFS=$'\t' read -r sid sname sdesc sjson; do
                SKILLS+=("$sid|$sname|$sdesc|shared")
                SKILLS_NAMES+=("$sid")
                [[ "$CACHE_SUPPORTED" == true ]] && assoc_set_wrapper "SKILL_CONFIGS" "$sid" "$sjson"
            done < <(cache_dir_jq "$sd" "skills" '[.id//"", .name//"", .description//"", tojson]|join("\t")' "${skill_files[@]}")
        fi
    fi
}

_init_config_legacy() {
    [[ -f "$1" ]] && npm_registry=$(jq -r '.npm_registry//"https://registry.npmmirror.com"' "$1")
}

# ==================== 3. 工具管理核心 ====================

operate_tool() {
    local index=$1; local op=$2; local skip_ext="${3:-false}"
    parse_tool_data "${TOOLS[$index]}" "OP"

    # 配置中的 npm 命令也需要运行环境，不能仅在 exec_pkg_op 的兜底分支检查。
    if [[ "$OP_type" == "npm" && ( "$op" == "install" || "$op" == "update" ) ]]; then
        ensure_node_runtime || return $?
    fi

    # 仅在需要网络的安装/更新操作前检测代理，避免每次启动阻塞 5 秒
    if [[ "$op" == "install" || "$op" == "update" ]]; then
        check_proxy_connectivity
    fi

    # 1. 获取命令
    local run_cmd=""
    local core_rc=0
    if [[ -n "$OP_file" && -f "$OP_file" ]]; then
        case "$op" in
            "install") run_cmd=$(jq -r '.install.methods[0].command // ""' "$OP_file" 2>/dev/null) ;;
            "update") run_cmd=$(jq -r '.update.command // ""' "$OP_file" 2>/dev/null) ;;
            "uninstall")
                run_cmd=$(jq -r '
                    (.install.methods[0].uninstall // [])
                    | if type == "array" then
                        map(if type == "string" then . else (.command // empty) end) | join(" && ")
                      elif type == "string" then .
                      else "" end
                ' "$OP_file" 2>/dev/null)
                ;;
        esac
    fi

    # 2. 运行检查。显式配置为空的 process_check 表示在线/无本地进程工具，跳过 pkill。
    if [[ "$op" != "install" ]]; then
        local process_pattern="${OP_cmd:-$OP_id}"
        local process_check_enabled=true
        if [[ -n "$OP_file" && -f "$OP_file" ]]; then
            if jq -e 'has("process_check")' "$OP_file" >/dev/null 2>&1; then
                process_pattern=$(jq -r '.process_check // empty' "$OP_file" 2>/dev/null)
                [[ -n "$process_pattern" ]] || process_check_enabled=false
            fi
        fi
        if [[ "$process_check_enabled" == true && -n "$process_pattern" ]]; then
            check_and_kill_process "$process_pattern" "$OP_name" "$op" || return 1
        fi
    fi

    # 3. 执行核心逻辑
    if [[ -n "$OP_plugin" ]]; then
        info_log "➜ 正在执行插件 $OP_plugin ($op) $OP_name..."
        local p_script="$SCRIPT_DIR/scripts/plugins/run_plugin.sh"
        if [[ -f "$p_script" ]]; then
            # 允许实时输出，解决卡死错觉
            bash "$p_script" run "$op" "$OP_plugin" "$OP_id" "$OP_name"
        else
            error_log "插件执行器不存在: $p_script"; return 1
        fi
    elif [[ -z "$run_cmd" ]]; then
        if [[ "$OP_type" == "npm" || "$OP_type" == "pip" || "$OP_type" == "pip_official" || "$OP_type" == "brew" || "$OP_type" == "uv" || "$OP_type" == "bash" ]]; then
            info_log "➜ 正在通过 $OP_type $op $OP_name..."
            exec_pkg_op "$OP_type" "$op" "$OP_name" "$OP_pkg" "$npm_registry" "$OP_id" "$OP_type" "$OP_cmd"
            core_rc=$?
        else
            # 不支持自动操作，直接报错返回，移除已无法执行的死代码
            warn_log "工具 $OP_name 不支持自动 $op（类型: ${OP_type:-未知}）"
            return 1
        fi
    else
        info_log "➜ 正在执行 $op $OP_name..."
        run_configured_command "$(expand_vars "$run_cmd")" "$OP_name $op"
        core_rc=$?
    fi

    # 4. 结果处理
    if [[ ${core_rc:-0} -eq 0 ]]; then
        success_msg "$OP_name $op 成功"
        # 5. 执行扩展命令
        if [[ "$op" == "uninstall" ]]; then
            info_log "正在清理配置..."
            if type remove_mcp_configs_from_file >/dev/null 2>&1; then
                remove_mcp_configs_from_file "$HOME/.gemini/config/mcp_config.json" "$OP_id" >/dev/null 2>&1 || true
                remove_mcp_configs_from_file "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "$OP_id" >/dev/null 2>&1 || true
            fi
            if [[ -f "$HOME/.gemini/config/plugins" ]]; then
                sed -i '' "/$OP_id/d" "$HOME/.gemini/config/plugins" 2>/dev/null || true
            fi
        fi

        if [[ "$skip_ext" != "true" ]]; then
            local commands_json
            commands_json=$(load_extended_commands "$OP_id" "post_${op}")
            if [[ -n "$commands_json" && "$commands_json" != "null" && "$commands_json" != "[]" ]]; then
                local count
                count=$(echo "$commands_json" | jq 'length')
                for ((i=0; i<count; i++)); do
                    local d
                    local c
                    d=$(echo "$commands_json" | jq -r ".[$i].description // \"执行步骤 $((i+1))\"")
                    c=$(echo "$commands_json" | jq -r ".[$i].command")
                    echo -e "${YELLOW}[$((i+1))/$count] $d${NC}"
                    run_configured_command "$(expand_vars "$c")" "$d" || warn_log "步骤失败: $d"
                done
            fi
        fi

        if [[ "$op" == "install" || "$op" == "update" ]]; then
            show_tool_usage_guide "$OP_file" "$OP_name" "$op"
        fi

        # 清除缓存，强制下一次刷新状态
        rm -f "$TOOLS_STATUS_CACHE_FILE" 2>/dev/null || true
        TOOL_STATUS=()
        return 0
    else
        if [[ ${core_rc:-0} -eq 3 ]]; then
            warn_log "$OP_name 需要手动安装，未完成自动安装"
            return 3
        fi
        error_log "$OP_name $op 失败"
        return 1
    fi
}

execute_extended_commands() {
    local id=$1; local type=$2; local name=$3
    local json
    json=$(load_extended_commands "$id" "$type")
    [[ -z "$json" || "$json" == "null" || "$json" == "[]" ]] && return 0

    local count
    count=$(echo "$json" | jq 'length')
    for ((i=0; i<count; i++)); do
        local item_type d c
        item_type=$(echo "$json" | jq -r ".[$i] | type")
        if [[ "$item_type" == "string" ]]; then
            d="执行步骤 $((i+1))"
            c=$(echo "$json" | jq -r ".[$i]")
        else
            d=$(echo "$json" | jq -r ".[$i].description // \"执行步骤 $((i+1))\"")
            c=$(echo "$json" | jq -r ".[$i].command // empty")
        fi
        [[ -z "$c" ]] && continue
        echo -e "${YELLOW}[$((i+1))/$count] $d${NC}"
        local ext_cmd ext_safe ext_pfx
        ext_cmd=$(expand_vars "$c")
        # 扩展命令（post_install/post_uninstall/uninstall_extended/status_check 等）多为复合 shell
        # 语句（echo/cd/if/&& 等），不以白名单动词开头时用 bash -c 包装执行；
        # 破坏性命令（rm -rf 等）仍由 run_configured_command 统一拦截确认
        if [[ "${AI_HUB_ALLOW_CUSTOM_CMD:-0}" != "1" ]]; then
            ext_safe=false
            for ext_pfx in npm npx pip pip3 uv brew curl wget bash sh python python3 node rm mkdir cp mv ln chmod chown tar zip unzip git docker sudo; do
                if [[ "$ext_cmd" == "$ext_pfx "* || "$ext_cmd" == "$ext_pfx" ]]; then
                    ext_safe=true
                    break
                fi
            done
            [[ "$ext_safe" == true ]] || ext_cmd="bash -c $(printf '%q' "$ext_cmd")"
        fi
        run_configured_command "$ext_cmd" "$d" || warn_log "步骤失败: $d"
    done
}

safe_remove_config_path() {
    local target="$1"
    local tool_name="$2"
    local allowed_dir="${3:-}"
    [[ -z "$target" ]] && return 1

    local expanded real home_real
    expanded=$(expand_path "$target")
    # 父目录存在时解析真实路径（处理符号链接）；不存在（如已随卸载删除）时沿路径
    # 向上找最近存在目录做符号链接解析，再拼接缺失部分，保证与 allowed_dir 归一化一致
    if cd "$(dirname "$expanded")" 2>/dev/null; then
        real=$(pwd -P)/$(basename "$expanded")
    else
        local _ap="$expanded" _tail="" _base _adir
        while [[ ! -d "$_ap" ]]; do
            _adir=$(dirname "$_ap")
            _base=$(basename "$_ap")
            _tail="$_base${_tail:+/$_tail}"
            [[ "$_adir" == "$_ap" ]] && break
            _ap="$_adir"
        done
        if [[ -d "$_ap" ]]; then
            real=$(cd "$_ap" 2>/dev/null && pwd -P)${_tail:+/$_tail}
        else
            real="$expanded"
        fi
    fi
    home_real=$(cd "$HOME" 2>/dev/null && pwd -P)

    case "$real" in
        "/"|"$home_real"|"$home_real/"|"/Users"|"/Users/"|"/Applications"|"/Applications/")
            error_log "拒绝删除高风险路径: $real"
            return 1
            ;;
        *"/../"*|*"/..")
            error_log "拒绝删除包含路径穿越的路径: $real"
            return 1
            ;;
    esac

    # 规范化并校验允许目录（工具自身声明的配置目录），避免其落入高风险路径
    if [[ -n "$allowed_dir" ]]; then
        allowed_dir=$(expand_path "$allowed_dir")
        if [[ -d "$allowed_dir" ]]; then
            allowed_dir=$(cd "$allowed_dir" 2>/dev/null && pwd -P)
        else
            local _allowed_parent
            _allowed_parent=$(cd "$(dirname "$allowed_dir")" 2>/dev/null && pwd -P) || _allowed_parent=""
            [[ -n "$_allowed_parent" ]] && allowed_dir="$_allowed_parent/$(basename "$allowed_dir")"
        fi
        case "$allowed_dir" in
            "/"|"$home_real"|"$home_real/"|"/Users"|"/Users/"|"/Applications"|"/Applications/")
                allowed_dir=""
                ;;
        esac
    fi

    local _os
    _os="$(uname -s 2>/dev/null)"
    case "$real" in
        "$home_real/."*|\
        "$home_real/Library/Application Support/"*|\
        "$home_real/Library/Preferences/"*|\
        "$home_real/.config/"*) ;;
        # Linux: 允许 /etc 和 /opt 下的工具配置路径
        "/etc/"*|"/opt/"*)
            if [[ "$_os" != "Linux" ]]; then
                error_log "拒绝在非 Linux 系统上删除系统路径: $real"
                return 1
            fi
            ;;
        *)
            if [[ -n "$allowed_dir" && ( "$real" == "$allowed_dir" || "$real" == "$allowed_dir/"* ) ]]; then
                :
            else
                error_log "拒绝删除不在允许配置目录内的路径: $real"
                return 1
            fi
            ;;
    esac

    rm -rf -- "$real"
}

uninstall_tool_extended() {
    local idx=$1; parse_tool_data "${TOOLS[$idx]}" "UN"
    echo -e "${RED}⚠️ 彻底卸载 $UN_name...${NC}"
    operate_tool "$idx" "uninstall" "true" || return 1
    execute_extended_commands "$UN_id" "post_uninstall" "$UN_name"
    execute_extended_commands "$UN_id" "uninstall_extended" "$UN_name"
    execute_extended_commands "$UN_id" "uninstall_cleanup" "$UN_name"
    if [[ -n "$UN_conf" ]]; then
        read -p "是否删除配置文件 $UN_conf? (y/N): " rm_c
        if [[ "$rm_c" == "y" ]]; then
            local conf_root
            if [[ -d "$UN_conf" ]]; then
                conf_root="$UN_conf"
            else
                conf_root=$(dirname "$UN_conf")
            fi
            safe_remove_config_path "$UN_conf" "$UN_name" "$conf_root"
        fi
    fi
}

show_tool_usage_guide() {
    local file="$1" name="$2" operation="${3:-安装}"
    [[ -f "$file" ]] || return 0

    # trae 安装/更新后不打印「使用指南」输出（其他工具不受影响）。
    # 恢复显示时，把对应名称从下面列表去掉即可。
    case "$name" in
        [Tt]rae|[Tt]raecode|[Tt]raework) return 0 ;;
    esac

    local manual notes homepage repository docs
    manual=$(jq -r '.setup_guide.manual // .usage_guide.manual // empty' "$file" 2>/dev/null)
    notes=$(jq -r '.notes // empty' "$file" 2>/dev/null)
    homepage=$(jq -r '.homepage // empty' "$file" 2>/dev/null)
    repository=$(jq -r '.repository // empty' "$file" 2>/dev/null)
    docs=$(jq -r '.docs // empty' "$file" 2>/dev/null)
    local has_guide=false
    [[ -n "$manual$notes$homepage$repository$docs" ]] && has_guide=true
    jq -e '(.setup_guide.workflows // .usage_guide.workflows // .commands // {}) | length > 0' "$file" >/dev/null 2>&1 && has_guide=true
    [[ "$has_guide" == true ]] || return 0

    echo -e "\n${CYAN}📖 ${name} 使用指南（${operation}完成）${NC}"
    [[ -n "$manual" ]] && echo -e "  ${manual}"
    local workflow_name workflow_example
    while IFS=$'\t' read -r workflow_name workflow_example; do
        [[ -n "$workflow_name" || -n "$workflow_example" ]] || continue
        echo -e "  ${YELLOW}${workflow_name:-使用方式}:${NC} ${workflow_example}"
    done < <(jq -r '(.setup_guide.workflows // .usage_guide.workflows // [])[]? | [(.name // ""), (.example // .command // "")] | @tsv' "$file" 2>/dev/null)

    local command_key command_value
    while IFS=$'\t' read -r command_key command_value; do
        [[ -n "$command_key" && -n "$command_value" ]] || continue
        case "$command_key" in
            start|start-*|run*|open|help|auth|config|version|chat|sessions)
                echo -e "  ${GREEN}${command_key}:${NC} ${command_value}" ;;
        esac
    done < <(jq -r '.commands // {} | to_entries[] | [ .key, (if (.value | type) == "string" then .value else (.value.command // "") end) ] | @tsv' "$file" 2>/dev/null)

    [[ -n "$notes" ]] && echo -e "  ${YELLOW}说明:${NC} ${notes}"
    [[ -n "$homepage" ]] && echo -e "  ${BLUE}主页:${NC} $homepage"
    [[ -n "$repository" && "$repository" != "$homepage" ]] && echo -e "  ${BLUE}仓库:${NC} $repository"
    [[ -n "$docs" ]] && echo -e "  ${BLUE}文档:${NC} $docs"
}

is_destructive_command() {
    local cmd="$1"
    # 检测命令替换和远程脚本执行，避免仅匹配 rm -rf 被绕过。
    [[ "$cmd" == *'`'* || "$cmd" == *'$('* ]] && return 0
    [[ "$cmd" == *"rm -rf"* || "$cmd" == *"rm -fr"* || "$cmd" == *"rm -r "* ]] && return 0
    [[ "$cmd" == *"sudo "* || "$cmd" == *"mkfs"* || "$cmd" == *"dd if="* ]] && return 0
    [[ "$cmd" == *"git reset --hard"* || "$cmd" == *"git clean -fd"* ]] && return 0
    [[ "$cmd" == *"curl"* && "$cmd" == *"|"* && "$cmd" == *"bash"* ]] && return 0
    [[ "$cmd" == *"wget"* && "$cmd" == *"|"* && "$cmd" == *"sh"* ]] && return 0
    return 1
}

run_configured_command() {
    local cmd="$1"
    local desc="${2:-命令}"
    [[ -z "$cmd" ]] && return 0

    # 白名单校验：命令必须以已知安全动词开头，防止任意字符串 RCE
    # 如需执行自定义命令，设置 AI_HUB_ALLOW_CUSTOM_CMD=1
    if [[ "${AI_HUB_ALLOW_CUSTOM_CMD:-0}" != "1" ]]; then
        local _safe_prefix=false
        local _pfx
        for _pfx in npm npx pip pip3 uv brew curl wget bash sh python python3 node rm mkdir cp mv ln chmod chown tar zip unzip git docker sudo; do
            if [[ "$cmd" == "$_pfx "* || "$cmd" == "$_pfx" ]]; then
                _safe_prefix=true
                break
            fi
        done
        if [[ "$_safe_prefix" != "true" ]]; then
            warn_log "命令前缀不在白名单，已拒绝执行: $desc（设置 AI_HUB_ALLOW_CUSTOM_CMD=1 可允许）"
            warn_log "  命令: $cmd"
            return 1
        fi
    fi

    if is_destructive_command "$cmd" && [[ "${AI_HUB_ALLOW_DANGEROUS:-}" != "1" ]]; then
        if [[ "${AI_HUB_NON_INTERACTIVE:-0}" == "1" ]]; then
            warn_log "已跳过高风险非交互命令: $desc。设置 AI_HUB_ALLOW_DANGEROUS=1 可允许执行。"
            return 1
        elif [[ -t 0 ]]; then
            echo -e "${YELLOW}⚠️  即将执行高风险步骤: $desc${NC}"
            echo "$cmd"
            read -p "确认执行？(y/N): " confirm_danger
            [[ "$confirm_danger" == "y" || "$confirm_danger" == "Y" ]] || return 1
        else
            warn_log "已跳过高风险非交互命令: $desc。设置 AI_HUB_ALLOW_DANGEROUS=1 可允许执行。"
            return 1
        fi
    fi

    if [[ "${AI_HUB_USE_ADL:-1}" != "0" && "$cmd" == *curl* ]] && command_exists adl; then
        local adl_bin
        adl_bin=$(command -v adl)
        (cd "$SCRIPT_DIR" && AI_HUB_ADL_BIN="$adl_bin" bash -c '
curl() {
    local out="" url="" arg next_is_out=false
    for arg in "$@"; do
        if [[ "$next_is_out" == true ]]; then
            out="$arg"
            next_is_out=false
            continue
        fi
        case "$arg" in
            -o|--output) next_is_out=true ;;
            -o*) out="${arg#-o}" ;;
            http://*|https://*) url="$arg" ;;
        esac
    done

    if [[ -n "$url" && -n "${AI_HUB_ADL_BIN:-}" ]]; then
        if [[ -n "$out" ]]; then
            mkdir -p "$(dirname "$out")"
            "$AI_HUB_ADL_BIN" "$url" "$(dirname "$out")" "$(basename "$out")"
            return $?
        fi

        local tmp
        tmp=$(mktemp "${TMPDIR:-/tmp}/aihub-curl.XXXXXX") || return 1
        "$AI_HUB_ADL_BIN" "$url" "$(dirname "$tmp")" "$(basename "$tmp")" >&2
        local rc=$?
        [[ $rc -eq 0 ]] && cat "$tmp"
        rm -f "$tmp"
        return $rc
    fi

    command curl "$@"
}
eval "$1"
' _ "$cmd")
    else
        (cd "$SCRIPT_DIR" && bash -c "$cmd")
    fi
}

# ==================== 4. 菜单与交互 ====================

is_id_in_words() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

get_tool_display_status() {
    local idx="$1"
    local status="${TOOL_STATUS[$idx]}"
    [[ "$status" != "true" ]] && { echo "未安装"; return 0; }
    local version
    parse_tool_data "${TOOLS[$idx]}" "DISPLAY"
    # 菜单只读已有缓存，避免启动 CLI / IDE 或串行调用包管理器。
    version=$(get_cache "ver:${DISPLAY_id}" 2>/dev/null)
    if [[ -n "$version" ]]; then
        echo "v$version"
    else
        echo "已安装"
    fi
}

# npm 全局包列表缓存，避免 is_mcp_server_installed 多次调用 npm list -g
_NPM_GLOBAL_LIST_CACHE=""
_get_npm_global_list() {
    if [[ -z "$_NPM_GLOBAL_LIST_CACHE" ]] && command_exists npm; then
        _NPM_GLOBAL_LIST_CACHE=$(npm list -g --depth=0 2>/dev/null || true)
    fi
    echo "$_NPM_GLOBAL_LIST_CACHE"
}

is_mcp_server_installed() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 1
    local check_cmd pkg
    check_cmd=$(jq -r '.status_check[0].command // ""' "$file" 2>/dev/null)
    if [[ "$check_cmd" == npm\ list* ]]; then
        pkg=$(echo "$check_cmd" | sed -E 's/^npm list -g ([^ ]+).*/\1/')
        if [[ -n "$pkg" ]]; then
            _get_npm_global_list | grep -q "$pkg" && return 0
        fi
    fi
    local install_cmd
    install_cmd=$(jq -r '.install.command // ""' "$file" 2>/dev/null)
    if [[ "$install_cmd" == npm\ install* ]]; then
        pkg=$(echo "$install_cmd" | sed -E 's/.*npm install -g ([^ ]+).*/\1/' | awk '{print $1}')
        if [[ -n "$pkg" ]]; then
            _get_npm_global_list | grep -q "$pkg" && return 0
        fi
    fi
    return 1
}

is_skill_installed() {
    local skill_id="$1"
    local dest="${AI_HUB_SKILLS_DIR:-$HOME/.ai-hub/skills}"
    [[ -f "$dest/${skill_id}.json" || -d "$HOME/.claude/skills/$skill_id" || -f "$HOME/.claude/skills/$skill_id/SKILL.md" ]]
}

CURRENT_TAB=0
# 标签页配置
TABS=("⌨️ CLI 助手" "💻 IDE 集成" "🤖 自主智能体" "📊 分析工作台" "🛠️ 应用开发平台" "🌐 API 网关" "⚙️ 推理引擎" "🛡️ 质量与安全" "🔧 工具组件")

tool_category_matches_tab() {
    local tab="$1"
    local cat="$2"
    case "$tab" in
        0) [[ "$cat" == "ai-coding" ]] ;;
        1) [[ "$cat" == "ai-ide" ]] ;;
        2) [[ "$cat" == "ai-agent" ]] ;;
        3) [[ "$cat" == "ai-workbench" ]] ;;
        4) [[ "$cat" == "ai-builder" ]] ;;
        5) [[ "$cat" == "ai-gateway" ]] ;;
        6) [[ "$cat" == "ai-runtime" ]] ;;
        7) [[ "$cat" == "ai-optimizer" || "$cat" == "quality" || "$cat" == "security" ]] ;;
        8) [[ "$cat" == "ai-utility" ]] ;;
        *) return 1 ;;
    esac
}

tool_categories_for_tab() {
    local tab="$1"
    case "$tab" in
        0) echo "ai-coding" ;;
        1) echo "ai-ide" ;;
        2) echo "ai-agent" ;;
        3) echo "ai-workbench" ;;
        4) echo "ai-builder" ;;
        5) echo "ai-gateway" ;;
        6) echo "ai-runtime" ;;
        7) echo "ai-optimizer quality security" ;;
        8) echo "ai-utility" ;;
        *) echo "" ;;
    esac
}

tool_category_badge() {
    # 取消所有前缀徽章，因为分类现在已经被完全独立到了各自的 Tab 中
    echo ""
}

select_tool_interactive() {
    # 每个 tab 独立的选中状态记忆（兼容 Bash 3.2，使用 assoc 兼容层）
    # key=tab_index, value="idx1 idx2 ..."

    while true; do
        detect_tool_status "fast" "$(tool_categories_for_tab "$CURRENT_TAB")"
        local opts=(); local idxs=()
        local display_cat last_header=""
        local _seen_groups=""  # 已显示的 group 名称，用于合并变体工具
        
        for display_cat in $(tool_categories_for_tab "$CURRENT_TAB"); do

            for i in "${!TOOLS[@]}"; do
                parse_tool_data "${TOOLS[$i]}" "C"
                [[ "$C_cat" == "$display_cat" ]] || continue
                if [[ -n "$C_group" ]]; then
                    [[ " $_seen_groups " != *" $C_group "* ]] || continue
                    _seen_groups+=" $C_group"
                    local group_count=0 group_installed=0 gi
                    for gi in $(_resolve_group_members "$i"); do
                        group_count=$((group_count + 1))
                        [[ "${TOOL_STATUS[$gi]}" != true ]] || group_installed=$((group_installed + 1))
                    done
                    local group_name="${C_name% (*}"
                    opts+=("${group_name} [${group_installed}/${group_count} 个版本已安装]")
                    idxs+=("$i")
                    continue
                fi
                local status_icon="${YELLOW}⚠️ ${NC}"
                local extra_info=""
                local badge
                badge=$(tool_category_badge "$C_cat")
                if [[ "${TOOL_STATUS[$i]}" == "true" ]]; then
                    status_icon="${GREEN}✅ ${NC}"
                    extra_info=" [$(get_tool_display_status "$i")]"
                    if [[ "$C_cat" == "ai-gateway" ]]; then
                        if [[ "$C_id" == "sub2api" || "$C_id" == "one-api" || "$C_id" == "new-api" ]]; then
                            if command -v docker >/dev/null 2>&1 && docker ps --filter "name=$C_id" --format "{{.Status}}" | grep -q "Up"; then
                                extra_info=" [${GREEN}Running${NC}]"
                            else
                                extra_info=" [${RED}Stopped${NC}]"
                            fi
                        fi
                    fi
                elif [[ "$C_cat" == "ai-ide" ]]; then
                    _fix_ide_cli_path "$C_id" "$C_name"
                fi
                opts+=("${status_icon}${badge}${C_name}${extra_info}"); idxs+=($i)
            done
        done
        # 3. 添加固定操作项 (使用 @ 标识)
        local FIXED_OPS=("@i 安装/更新" "@u 卸载" "@t 操作" "@f 刷新" "@m MCP" "@s Skills" "@z 批量配置")
        opts+=("${FIXED_OPS[@]}")
        local t_cnt=$((${#opts[@]} - ${#FIXED_OPS[@]}))

        # 初次进入不勾选；切换 Tab 只恢复用户手动选择。
        local res
        # 恢复此 tab 的选中状态记忆（仅用户手动选择）
        _MENU_RESTORE_INDICES="$(assoc_get_wrapper "_TAB_SELECTED" "$CURRENT_TAB" "")"
        _MENU_RESTORE_CURSOR="$(assoc_get_wrapper "_TAB_CURSOR" "$CURRENT_TAB" "0")"
        _MENU_ALT_SCREEN=true
        _MENU_SHOW_ALL=true
        res=$(menu_select "AI Hub 工具中枢 (${TABS[$CURRENT_TAB]})" "true" "true" "" "TABS" "CURRENT_TAB" "${opts[@]}")
        _MENU_ALT_SCREEN=false
        _MENU_SHOW_ALL=false
        
        if [[ "$res" == TAB:* ]]; then
            # 解析 TAB:tab_num:indices:cursor 格式（注意只有 1 个 throwaway _）
            local _tab_idx _tab_sel _tab_cur
            IFS=':' read -r _ _tab_idx _tab_sel _tab_cur <<< "$res"
            # 保存当前 tab 的选中状态
            assoc_set_wrapper "_TAB_SELECTED" "$CURRENT_TAB" "$_tab_sel"
            assoc_set_wrapper "_TAB_CURSOR" "$CURRENT_TAB" "$_tab_cur"
            CURRENT_TAB=$_tab_idx
            continue
        fi
        [[ "$res" == "EXIT" || -z "$res" ]] && return 0

        local sel=($res); local trig=${sel[${#sel[@]}-1]}; unset sel[${#sel[@]}-1]
        # 保存当前选中状态（操作完成后回到菜单时恢复）
        assoc_set_wrapper "_TAB_SELECTED" "$CURRENT_TAB" "${sel[*]:-}"
        assoc_set_wrapper "_TAB_CURSOR" "$CURRENT_TAB" "$trig"
        if [[ $trig -ge $t_cnt ]]; then
            case "${opts[$trig]}" in
                *"安装"*)
                    if [[ ${#sel[@]} -gt 0 ]]; then
                        for s in "${sel[@]}"; do
                            _install_or_update_entry "${idxs[$s]}"
                        done
                    else
                        install_or_update_menu
                    fi
                    ;;
                *"卸载"*)
                    if [[ ${#sel[@]} -gt 0 ]]; then
                        for s in "${sel[@]}"; do
                            local ti="${idxs[$s]}"
                            parse_tool_data "${TOOLS[$ti]}" "_UG"
                            if [[ -n "$_UG_group" ]]; then
                                _show_group_variant_uninstall "$_UG_group"
                            else
                                uninstall_tool_extended "$ti"
                            fi
                        done
                    else
                        uninstall_menu
                    fi
                    ;;
                *"操作"*) tool_operations_select ;;
                *"MCP"*) manage_mcp_servers ;;
                *"技能"*) manage_skills ;;
                *"批量"*) 
                    local batch_opts=()
                    batch_opts+=("🎯 按推荐场景配置")
                    batch_opts+=("🏷️ 按标签精细选择")
                    batch_opts+=("🧩 自定义 MCP / Skills")
                    batch_opts+=("🔍 检查 MCP / Skills 配置")
                    local batch_res
                    batch_res=$(menu_select "选择批量配置方式" "false" "false" "" "" "" "${batch_opts[@]}")
                    [[ "$batch_res" == "EXIT" ]] && continue
                    case "$batch_res" in
                        0) batch_apply_standard_configs ;;
                        1) batch_apply_by_tags ;;
                        2) batch_apply_custom_configs ;;
                        3) check_shared_configs_menu ;;
                    esac
                    ;;
                *"刷新"*) detect_tool_status "force" ;;
            esac
        else
            local tidx=${idxs[$trig]}
            parse_tool_data "${TOOLS[$tidx]}" "_GSEL"
            if [[ -n "$_GSEL_group" ]]; then
                # 变体工具组：弹出二次选择列表
                _show_group_variant_menu "$_GSEL_group"
            else
                local op="install"; [[ "${TOOL_STATUS[$tidx]}" == "true" ]] && op="update"
                operate_tool "$tidx" "$op"; echo ""; read -p "按回车返回..."
            fi
        fi
    done
}

# ==================== 变体工具组辅助函数 ====================

# 解析工具所属组的全部成员索引（空格分隔）
# 用法: _resolve_group_members <tool_index>
# 返回: 该工具的所有组内成员索引（含自身）；若不属于任何组则仅返回自身
_resolve_group_members() {
    local ti=$1
    parse_tool_data "${TOOLS[$ti]}" "_RGM"
    if [[ -z "$_RGM_group" ]]; then
        echo "$ti"
        return
    fi
    local _members="" _rj
    for ((_rj=0; _rj<${#TOOLS[@]}; _rj++)); do
        parse_tool_data "${TOOLS[$_rj]}" "_RGC"
        [[ "$_RGC_group" == "$_RGM_group" ]] && _members+=" $_rj"
    done
    echo "${_members# }"
}

# 显示变体工具二次选择菜单
# 用法: _show_group_variant_menu <group_name>
_show_group_variant_menu() {
    local group="$1"
    local _vi _vp vs

    # 收集变体信息
    local v_opts=() v_idxs=() v_statuses=()
    for ((_vi=0; _vi<${#TOOLS[@]}; _vi++)); do
        parse_tool_data "${TOOLS[$_vi]}" "_GV"
        [[ "$_GV_group" == "$group" ]] || continue
        local v_st_icon="${YELLOW}⚠️ ${NC}"
        local v_extra="未安装"
        if [[ "${TOOL_STATUS[$_vi]}" == "true" ]]; then
            v_st_icon="${GREEN}✅ ${NC}"
            v_extra="$(get_tool_display_status "$_vi")"
        fi
        v_opts+=("${v_st_icon}${_GV_name}  [${v_extra}]")
        v_idxs+=($_vi)
        v_statuses+=("${TOOL_STATUS[$_vi]}")
    done
    
    [[ ${#v_opts[@]} -eq 0 ]] && return
    
    # 默认不勾选；没有勾选时 Enter 仅安装当前版本。
    local v_pre=""
    
    # 构建组显示名
    local _first_name=""
    parse_tool_data "${TOOLS[${v_idxs[0]}]}" "_GFN"
    _first_name="${_GFN_name% (*}"
    [[ "$_first_name" == "$_GFN_name" ]] && _first_name="$_GFN_name"
    
    local v_res
    _MENU_ALT_SCREEN=true
    v_res=$(menu_select "📦 ${_first_name} — 选择版本 (可多选)" "true" "true" "$v_pre" "" "" "${v_opts[@]}")
    _MENU_ALT_SCREEN=false
    
    [[ "$v_res" == "EXIT" || -z "$v_res" ]] && return
    
    # menu_select 的末项是光标位置，不能当作额外的已选版本。
    for vs in $(_menu_selected_indices "$v_res" "${#v_idxs[@]}"); do
        local vi="${v_idxs[$vs]}" vop="install"
        # operate_tool 成功后会清空 TOOL_STATUS，使用菜单打开时的快照。
        [[ "${v_statuses[$vs]}" != true ]] || vop="update"
        operate_tool "$vi" "$vop"
    done
    if [[ -t 0 ]]; then echo ""; read -r -p "按回车返回..."; fi
    return 0
}

# 显示变体工具卸载二次选择菜单（仅显示已安装变体）
# 用法: _show_group_variant_uninstall <group_name>
_show_group_variant_uninstall() {
    local group="$1"
    local _vi _vp vs
    
    # 收集已安装变体信息
    local v_opts=() v_idxs=()
    for ((_vi=0; _vi<${#TOOLS[@]}; _vi++)); do
        parse_tool_data "${TOOLS[$_vi]}" "_GV"
        [[ "$_GV_group" == "$group" ]] || continue
        [[ "${TOOL_STATUS[$_vi]}" != "true" ]] && continue  # 仅已安装
        local v_extra
        v_extra="$(get_tool_display_status "$_vi")"
        v_opts+=("${GREEN}✅ ${_GV_name}${NC}  [${v_extra}]")
        v_idxs+=($_vi)
    done
    
    [[ ${#v_opts[@]} -eq 0 ]] && { warn_log "该组没有已安装的变体"; return; }
    
    # 构建组显示名
    local _first_name=""
    parse_tool_data "${TOOLS[${v_idxs[0]}]}" "_GFN"
    _first_name="${_GFN_name% (*}"
    [[ "$_first_name" == "$_GFN_name" ]] && _first_name="$_GFN_name"
    
    # 如果只有一个已安装变体，直接卸载
    if [[ ${#v_opts[@]} -eq 1 ]]; then
        uninstall_tool_extended "${v_idxs[0]}"
        return
    fi
    
    # 卸载版本也不默认勾选。
    local v_pre=""
    
    local v_res
    _MENU_ALT_SCREEN=true
    v_res=$(menu_select "🗑️ ${_first_name} — 选择要卸载的版本 (可多选)" "true" "true" "$v_pre" "" "" "${v_opts[@]}")
    _MENU_ALT_SCREEN=false
    
    [[ "$v_res" == "EXIT" || -z "$v_res" ]] && return
    
    for vs in $(_menu_selected_indices "$v_res" "${#v_idxs[@]}"); do
        local vi="${v_idxs[$vs]}"
        uninstall_tool_extended "$vi"
    done
    if [[ -t 0 ]]; then echo ""; read -r -p "按回车返回..."; fi
    return 0
}

# ==================== 5. 辅助与修复逻辑 ====================

_fix_ide_cli_path() {
    local id=$1; local name=$2
    [[ "$(uname -s)" != "Darwin" ]] && return
    local target_bin="/usr/local/bin/$id"; command -v "$id" >/dev/null 2>&1 && return
    local app_path=""; case "$id" in "trae") app_path=$(ls -d /Applications/*Trae*.app 2>/dev/null | head -1) ;; "cursor") app_path="/Applications/Cursor.app" ;; "devin") app_path="/Applications/Devin.app" ;; esac
    if [[ -d "$app_path" && -w "/usr/local/bin" ]]; then
        local cli_src=""; [[ "$id" == "trae" ]] && cli_src="$app_path/Contents/Resources/app/bin/trae"
        [[ "$id" == "cursor" ]] && cli_src="$app_path/Contents/Resources/app/bin/code"
        [[ "$id" == "devin" ]] && cli_src="$app_path/Contents/Resources/app/bin/devin"
        [[ -f "$cli_src" ]] && ln -sf "$cli_src" "$target_bin" && debug_log "已修复 $name 软链接"
    fi
}

# 多选结果 = 勾选项 + 光标；无勾选时仅使用光标，去重并检查边界。
_menu_selected_indices() {
    local raw="$1" count="$2" values=() cursor idx seen=" "
    [[ -n "$raw" && "$raw" != EXIT && "$raw" != TAB:* ]] || return 0
    read -r -a values <<< "$raw"
    cursor="${values[${#values[@]}-1]}"
    unset 'values[${#values[@]}-1]'
    [[ ${#values[@]} -gt 0 ]] || values=("$cursor")
    for idx in "${values[@]}"; do
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        [[ "$idx" -lt "$count" && " $seen " != *" $idx "* ]] || continue
        printf '%s\n' "$idx"
        seen+="$idx "
    done
}

_install_or_update_entry() {
    local ti="$1" op=install
    parse_tool_data "${TOOLS[$ti]}" ENTRY
    detect_tool_status fast "$ENTRY_cat"
    if [[ -n "$ENTRY_group" ]]; then
        _show_group_variant_menu "$ENTRY_group"
    else
        [[ "${TOOL_STATUS[$ti]}" != true ]] || op=update
        operate_tool "$ti" "$op"
    fi
}

install_or_update_menu() {
    detect_tool_status fast
    local opts=() idxs=() i
    build_tool_menu_options "all" "opts" "idxs"
    local res
    res=$(menu_select "📦 安装/更新工具" "true" "true" "" "" "" "${opts[@]}")
    for i in $(_menu_selected_indices "$res" "${#idxs[@]}"); do
        _install_or_update_entry "${idxs[$i]}"
    done
}

uninstall_menu() {
    local opts=(); local idxs=()
    build_tool_menu_options "installed" "opts" "idxs"
    [[ ${#opts[@]} -eq 0 ]] && { warn_log "没有已安装的工具"; return; }
    
    local res
    res=$(menu_select "🗑️ 卸载工具" "false" "true" "" "" "" "${opts[@]}")
    [[ "$res" == "EXIT" || -z "$res" ]] && return
    
    local tidx=${idxs[$res]}
    parse_tool_data "${TOOLS[$tidx]}" "_UG"
    if [[ -n "$_UG_group" ]]; then
        _show_group_variant_uninstall "$_UG_group"
    else
        uninstall_tool_extended "$tidx"
    fi
}

tool_operations_select() {
    local opts=(); local idxs=()
    build_tool_menu_options "installed" "opts" "idxs"
    [[ ${#opts[@]} -eq 0 ]] && return
    local res
    res=$(menu_select "🛠️ 选择工具" "false" "true" "" "TABS" "CURRENT_TAB" "${opts[@]}")
    [[ "$res" != "EXIT" && -n "$res" ]] && tool_operations_menu "${idxs[$res]}"
}

tool_command_display_label() {
    local key="$1"
    local desc="${2:-}"
    local group="Command"
    local action="$key"

    case "$key" in
        desktop-*)
            group="Desktop"
            action="${key#desktop-}"
            ;;
        cc-switch-*)
            group="CC-Switch"
            action="${key#cc-switch-}"
            ;;
    esac

    if [[ -n "$desc" && "$desc" != "null" ]]; then
        printf '▶️ %s / %s - %s\n' "$group" "$action" "$desc"
    else
        printf '▶️ %s / %s\n' "$group" "$action"
    fi
}

tool_operations_menu() {
    local idx=$1; parse_tool_data "${TOOLS[$idx]}" "M"
    local opts=("@v 👁️ 查看配置" "@e ✏️ 编辑配置" "@s 🔄 重置配置" "@t 🔍 状态" "@r 🗑️ 卸载")
    local base_count=${#opts[@]}
    local command_keys=()
    local command_cmds=()
    local key cmd desc label

    if [[ -f "$M_file" ]]; then
        while IFS=$'\t' read -r key cmd desc; do
            [[ -n "$key" && -n "$cmd" ]] || continue
            label=$(tool_command_display_label "$key" "$desc")
            opts+=("$label")
            command_keys+=("$key")
            command_cmds+=("$cmd")
        done < <(jq -r '
            .commands // {}
            | to_entries[]
            | [
                .key,
                (if (.value | type) == "string" then .value else (.value.command // "") end),
                (if (.value | type) == "object" then (.value.description // "") else "" end)
              ]
            | @tsv
        ' "$M_file" 2>/dev/null)
    fi

    local res
    res=$(menu_select "🛠️ $M_name 操作" "false" "true" "" "TABS" "CURRENT_TAB" "${opts[@]}")
    [[ "$res" == "EXIT" || -z "$res" ]] && return
    case $res in
        0) show_tool_config "$idx" ;;
        1) edit_tool_config "$idx" ;;
        2) reset_tool_config "$idx" ;;
        3) execute_extended_commands "$M_id" "status_check" "$M_name" ;;
        4) uninstall_menu ;;
        *)
            local cmd_idx=$((res - base_count))
            [[ $cmd_idx -ge 0 && $cmd_idx -lt ${#command_cmds[@]} ]] || return 1
            run_configured_command "$(expand_vars "${command_cmds[$cmd_idx]}")" "$M_name: ${command_keys[$cmd_idx]}"
            ;;
    esac
}

is_supported_mcp_config_path() {
    local config_file="$1"
    case "$config_file" in
        *.json|*.yaml|*.yml|*.toml) return 0 ;;
        *) return 1 ;;
    esac
}

is_batch_config_target() {
    local tool_cat="$1"
    local config_file="$2"
    [[ "$tool_cat" == "ai-coding" || "$tool_cat" == "ai-agent" || "$tool_cat" == "ai-ide" ]] || return 1
    is_supported_mcp_config_path "$config_file"
}

profile_skill_dir_for_config() {
    local kind="$1"
    local config_file="$2"
    local profile_dir
    profile_dir=$(dirname "$config_file")

    case "$kind" in
        codex) echo "$profile_dir/skills/ai-hub" ;;
        opencode) echo "$HOME/.config/opencode/skills" ;;
        qwen) echo "$profile_dir/skills" ;;
        *) skill_target_dir "$kind" ;;
    esac
}

_emit_extra_profile_target() {
    local profile_id="$1"
    local profile_name="$2"
    local kind="$3"
    local config_file="$4"
    local skill_dir="${5:-}"

    [[ -n "$profile_id" && -n "$kind" && -n "$config_file" ]] || return 0
    config_file=$(expand_path "$config_file")
    [[ -f "$config_file" ]] || return 0
    is_supported_mcp_config_path "$config_file" || return 0

    [[ -n "$profile_name" ]] || profile_name="$profile_id"
    if [[ -n "$skill_dir" ]]; then
        skill_dir=$(expand_path "$skill_dir")
    else
        skill_dir=$(profile_skill_dir_for_config "$kind" "$config_file")
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$profile_id" "$profile_name" "$kind" "$config_file" "$skill_dir"
}

collect_extra_profile_targets() {
    if [[ "${AI_HUB_INCLUDE_EXTRA_PROFILES:-1}" != "0" ]]; then
        _emit_extra_profile_target "codex-token173" "OpenAI Codex CLI (token173)" "codex" "$HOME/.codex-token173/config.toml" "$HOME/.codex-token173/skills/ai-hub"

        local qwen_studio_home="${AI_STUDIO_QWEN_HOME:-${QWEN_STUDIO_HOME:-$HOME/.qwen-studio}}"
        _emit_extra_profile_target "qwen-studio" "Qwen CLI (Studio)" "qwen" "$qwen_studio_home/settings.json" "$qwen_studio_home/skills"
        [[ "$qwen_studio_home" != "$HOME/.qwen-studio" ]] && \
            _emit_extra_profile_target "qwen-studio-default" "Qwen CLI (Studio Default)" "qwen" "$HOME/.qwen-studio/settings.json" "$HOME/.qwen-studio/skills"
        [[ "$qwen_studio_home" != "$HOME/qwen-studio" ]] && \
            _emit_extra_profile_target "qwen-studio-home" "Qwen CLI (Studio Home)" "qwen" "$HOME/qwen-studio/settings.json" "$HOME/qwen-studio/skills"
    fi

    local specs="${AI_HUB_EXTRA_PROFILE_TARGETS:-}"
    [[ -z "$specs" ]] && return 0

    local old_ifs="$IFS"
    local entry profile_id profile_name kind config_file skill_dir
    IFS=';'
    for entry in $specs; do
        [[ -n "$entry" ]] || continue
        IFS='|'
        IFS='|' read -r profile_id profile_name kind config_file skill_dir <<< "$entry"
        _emit_extra_profile_target "$profile_id" "$profile_name" "$kind" "$config_file" "$skill_dir"
        IFS=';'
    done
    IFS="$old_ifs"
}

# 收集所有已发现且支持 MCP 写入的客户端配置文件
# 输出格式: "name<TAB>config_path"，每行一个；由调用方负责按 config_path 去重。
collect_mcp_config_targets() {
    detect_tool_status "fast"
    local i
    for i in "${!INSTALLED_MCP_CONFIGS[@]}"; do
        if [[ -n "${INSTALLED_MCP_CONFIGS[$i]}" ]] && is_supported_mcp_config_path "${INSTALLED_MCP_CONFIGS[$i]}"; then
            printf '%s\t%s\n' "${INSTALLED_MCP_TOOLS[$i]}" "${INSTALLED_MCP_CONFIGS[$i]}"
        fi
    done
    local _pid _pname _pkind _pconf _pskills
    while IFS=$'\t' read -r _pid _pname _pkind _pconf _pskills; do
        [[ -n "$_pid" && -n "$_pconf" ]] || continue
        printf '%s\t%s\n' "$_pname" "$_pconf"
    done < <(collect_extra_profile_targets)
}

config_path_in_list() {
    local candidate="$1"
    shift
    candidate=$(expand_path "$candidate")

    local existing
    for existing in "$@"; do
        [[ "$(expand_path "$existing")" == "$candidate" ]] && return 0
    done
    return 1
}

target_id_matches() {
    local candidate="$1"
    local wanted="$2"
    [[ -n "$candidate" && -n "$wanted" ]] || return 1
    [[ "$candidate" == "$wanted" ]] && return 0
    [[ "${candidate#.}" == "$wanted" ]] && return 0
    [[ "$candidate" == ".$wanted" ]] && return 0
    return 1
}

unique_menu_indices() {
    local seen=()
    local out=()
    local item
    for item in "$@"; do
        [[ -z "$item" ]] && continue
        is_id_in_words "$item" "${seen[@]}" && continue
        seen+=("$item")
        out+=("$item")
    done
    echo "${out[@]}"
}

batch_apply_selected_configs() {
    local title="$1"
    shift

    # 批量配置模式：自动执行前置依赖，不逐个询问
    export BATCH_MODE=1

    local selected_mcps=()
    local selected_skills=()
    local mode="mcp"
    local skipped_mcps=()
    local item
    for item in "$@"; do
        if [[ "$item" == "--" ]]; then
            mode="skills"
            continue
        fi
        [[ -n "$item" ]] || continue
        if [[ "$mode" == "mcp" ]]; then
            is_id_in_words "$item" "${selected_mcps[@]}" || selected_mcps+=("$item")
        else
            is_id_in_words "$item" "${selected_skills[@]}" || selected_skills+=("$item")
        fi
    done

    local requested_mcp_count=${#selected_mcps[@]}
    local install_mcps=("${selected_mcps[@]}")
    filter_mcps_by_compatibility install_mcps
    local incompatible_mcps=("${FILTERED_MCP_INCOMPATIBLE[@]:-}")
    local incompatible_mcp_details=("${FILTERED_MCP_INCOMPATIBLE_DETAILS[@]:-}")

    local runtime_mcp_confs=()
    build_runtime_mcp_configs runtime_mcp_confs "${install_mcps[@]}"
    skipped_mcps=("${FILTERED_MCP_SKIPPED[@]}")
    local skipped_mcp_details=("${FILTERED_MCP_SKIPPED_DETAILS[@]:-}")
    local config_mcps=()
    local _runtime_pair _runtime_id
    for _runtime_pair in "${runtime_mcp_confs[@]}"; do
        _runtime_id="${_runtime_pair%%:*}"
        [[ -n "$_runtime_id" ]] && config_mcps+=("$_runtime_id")
    done

    if [[ ${#install_mcps[@]} -eq 0 && ${#selected_skills[@]} -eq 0 ]]; then
        warn_log "未匹配到可配置的 MCP 或 Skills"
        return 1
    fi

    detect_tool_status "force"

    local target_opts=() target_confs=() target_names=() target_ids=() target_kinds=() target_skill_dirs=()
    local i
    for i in "${!TOOLS[@]}"; do
        parse_tool_data "${TOOLS[$i]}" "BTG"
        local _is_target_explicit=false
        if [[ -n "${AI_HUB_BATCH_TARGETS_RAW:-}" && "$AI_HUB_BATCH_TARGETS_RAW" != "all" && "$AI_HUB_BATCH_TARGETS_RAW" != "*" ]]; then
            local w
            IFS=',' read -ra wanted_targets <<< "$AI_HUB_BATCH_TARGETS_RAW"
            for w in "${wanted_targets[@]}"; do
                if [[ "$w" == "$BTG_id" || "$w" == "$BTG_cmd" ]]; then
                    _is_target_explicit=true
                    break
                fi
            done
        fi
        
        if [[ ("${TOOL_STATUS[$i]}" == "true" || "$_is_target_explicit" == "true") && -n "$BTG_conf" ]] && is_batch_config_target "$BTG_cat" "$BTG_conf"; then
            local _kind
            _kind=$(skill_target_kind "$BTG_id" "$BTG_name")
            target_opts+=("${GREEN}✅ ${BTG_name}${NC} - $(get_tool_display_status "$i")")
            target_confs+=("$BTG_conf")
            target_names+=("$BTG_name")
            target_ids+=("$BTG_id")
            target_kinds+=("$_kind")
            target_skill_dirs+=("$(profile_skill_dir_for_config "$_kind" "$BTG_conf")")
        fi
    done
    local _pid _pname _pkind _pconf _pskills
    while IFS=$'\t' read -r _pid _pname _pkind _pconf _pskills; do
        [[ -n "$_pid" && -n "$_pconf" ]] || continue
        config_path_in_list "$_pconf" "${target_confs[@]}" && continue
        target_opts+=("${GREEN}✅ ${_pname}${NC} - profile: ${_pconf}")
        target_confs+=("$_pconf")
        target_names+=("$_pname")
        target_ids+=("$_pid")
        target_kinds+=("$_pkind")
        target_skill_dirs+=("$_pskills")
    done < <(collect_extra_profile_targets)

    [[ ${#target_opts[@]} -eq 0 ]] && { warn_log "未发现已安装且支持 MCP 写入的 CLI/Agent/profile 配置"; return 1; }

    local target_res=""
    if [[ -n "${AI_HUB_BATCH_TARGETS_RAW:-}" ]]; then
        if [[ "$AI_HUB_BATCH_TARGETS_RAW" == "all" || "$AI_HUB_BATCH_TARGETS_RAW" == "*" ]]; then
            for i in "${!target_opts[@]}"; do target_res+="$i "; done
        else
            IFS=',' read -ra wanted_targets <<< "$AI_HUB_BATCH_TARGETS_RAW"
            local w i_idx
            for w in "${wanted_targets[@]}"; do
                for i_idx in "${!target_ids[@]}"; do
                    if target_id_matches "${target_ids[$i_idx]}" "$w"; then
                        target_res+="$i_idx "
                    fi
                done
            done
        fi
        if [[ -z "$target_res" ]]; then
            warn_log "指定的 target ($AI_HUB_BATCH_TARGETS_RAW) 未找到。"
            return 1
        fi
    else
        echo -e "\n✅ 解析完毕！共准备了 ${#selected_mcps[@]} 个 MCP 和 ${#selected_skills[@]} 个 Skills（部分无需配置变量已自动就绪）。"
        target_opts+=("🛠️ 配置到所有环境")
        target_res=$(menu_select "选择要写入配置的 CLI/Agent/profile（可多选）" "true" "true" "" "" "" "${target_opts[@]}")
        [[ "$target_res" == "EXIT" || -z "$target_res" ]] && return 0
    fi

    target_res=$(unique_menu_indices "$target_res")
    local target_count=0 idx
    for idx in $target_res; do target_count=$((target_count + 1)); done

    # 显示已选择数量
    echo ""
    echo "已选择 ${target_count} 个 CLI/Agent/profile"

    echo -e "\n📊 ${CYAN}${title}${NC}"
    echo -e "   MCP 安装 (${#install_mcps[@]}): ${CYAN}${install_mcps[*]:-无}${NC}"
    echo -e "   MCP 写入 (${#config_mcps[@]}): ${CYAN}${config_mcps[*]:-无}${NC}"
    if [[ ${#incompatible_mcps[@]} -gt 0 ]]; then
        echo -e "   MCP 系统不兼容 (${#incompatible_mcps[@]}): ${YELLOW}${incompatible_mcps[*]}${NC}"
        printf '      - %s\n' "${incompatible_mcp_details[@]}"
    fi
    if [[ ${#skipped_mcps[@]} -gt 0 ]]; then
        echo -e "   MCP 跳过写入 (${#skipped_mcps[@]}): ${YELLOW}${skipped_mcps[*]}${NC}"
        printf '      - %s\n' "${skipped_mcp_details[@]}"
    fi
    echo -e "   Skills (${#selected_skills[@]}): ${CYAN}${selected_skills[*]:-无}${NC}"

    local m
    for m in "${install_mcps[@]}"; do
        prepare_mcp_server_if_needed "$m"
    done

    local cf="y"
    if [[ "${AI_HUB_BATCH_CONFIRM:-}" != "true" ]]; then
        read -p "$(printf "${YELLOW}将安装 %s 个 MCP、写入 %s 个 MCP、应用 %s 个 Skills 到 %s 个 CLI/Agent/profile，确认执行？(y/N): ${NC}" "${#install_mcps[@]}" "${#config_mcps[@]}" "${#selected_skills[@]}" "$target_count")" cf
    fi
    [[ "$cf" == "y" || "$cf" == "Y" ]] || return 0

    local mcp_config_ok=0 mcp_config_failed=0
    local skill_config_ok=0 skill_config_failed=0
    local mcp_install_ok=0 mcp_install_failed=0
    local skill_install_ok=0 skill_install_failed=0
    local failed_mcp_ids=() failed_skill_ids=() installed_mcp_ids=()

    for m in "${install_mcps[@]}"; do
        if install_mcp_server_package "$m"; then
            mcp_install_ok=$((mcp_install_ok + 1))
            installed_mcp_ids+=("$m")
        else
            mcp_install_failed=$((mcp_install_failed + 1))
            failed_mcp_ids+=("$m")
        fi
    done

    local m_confs=() c _conf_id _base_id
    for c in "${runtime_mcp_confs[@]}"; do
        _conf_id="${c%%:*}"
        _base_id="$_conf_id"
        [[ "$_conf_id" == ssh-* ]] && _base_id="ssh"
        is_id_in_words "$_base_id" "${installed_mcp_ids[@]}" || continue
        [[ -n "$c" ]] && m_confs+=("$c")
    done

    for idx in $target_res; do
        local _tname="${target_names[$idx]}"
        [[ -z "$_tname" ]] && _tname="${target_ids[$idx]}"
        echo -ne "   ➜ 配置 ${_tname} MCP ... "
        if [[ ${#skipped_mcps[@]} -gt 0 || ${#incompatible_mcps[@]} -gt 0 ]]; then
            remove_mcp_configs_from_file "${target_confs[$idx]}" "${skipped_mcps[@]}" "${incompatible_mcps[@]}" >/dev/null 2>&1 || true
        fi
        local missing_m_confs=()
        if [[ ${#m_confs[@]} -gt 0 ]]; then
            if [[ "${AI_HUB_UPDATE_CONFIGS:-0}" == "1" ]]; then
                missing_m_confs=("${m_confs[@]}")
            else
                while IFS= read -r _missing_m_conf; do
                    [[ -n "$_missing_m_conf" ]] && missing_m_confs+=("$_missing_m_conf")
                done < <(filter_missing_mcp_configs_for_file "${target_confs[$idx]}" "${m_confs[@]}")
            fi
        fi
        if [[ ${#missing_m_confs[@]} -gt 0 ]]; then
            if add_all_mcp_configs_to_file "${target_confs[$idx]}" "${missing_m_confs[@]}" >/dev/null 2>&1; then
                echo "成功"
                mcp_config_ok=$((mcp_config_ok + 1))
            else
                echo "失败"
                mcp_config_failed=$((mcp_config_failed + 1))
            fi
        else
            echo "跳过(已配置或无可写入项)"
        fi
    done
    for item in "${selected_skills[@]}"; do
        if install_skill "$item" >/dev/null 2>&1; then
            skill_install_ok=$((skill_install_ok + 1))
        else
            skill_install_failed=$((skill_install_failed + 1))
            failed_skill_ids+=("$item")
        fi
    done
    for idx in $target_res; do
        echo -ne "   ➜ 配置 ${target_names[$idx]} Skills ... "
        local missing_skills=()
        if [[ ${#selected_skills[@]} -gt 0 ]]; then
            if [[ "${AI_HUB_UPDATE_CONFIGS:-0}" == "1" ]]; then
                missing_skills=("${selected_skills[@]}")
            else
                while IFS= read -r _missing_skill; do
                    [[ -n "$_missing_skill" ]] && missing_skills+=("$_missing_skill")
                done < <(filter_missing_skills_for_profile_target "${target_kinds[$idx]}" "${target_skill_dirs[$idx]}" "${selected_skills[@]}")
            fi
        fi
        if [[ ${#missing_skills[@]} -gt 0 ]]; then
            if install_skills_for_profile_target "${target_ids[$idx]}" "${target_names[$idx]}" "${target_kinds[$idx]}" "${target_skill_dirs[$idx]}" "${missing_skills[@]}" >/dev/null 2>&1; then
                echo "成功"
                skill_config_ok=$((skill_config_ok + 1))
            else
                echo "失败"
                skill_config_failed=$((skill_config_failed + 1))
            fi
        else
            echo "跳过(已配置或无可写入项)"
        fi
    done

    [[ ${#selected_skills[@]} -gt 0 ]] && prompt_extension_commands_for_skills "${selected_skills[@]}"
    echo -e "\n📊 批量安装配置结果"
    echo "   目标: ${target_count}"
    echo "   MCP: 请求 ${requested_mcp_count}，安装候选 ${#install_mcps[@]}，写入候选 ${#config_mcps[@]}，跳过写入 ${#skipped_mcps[@]}，系统不兼容 ${#incompatible_mcps[@]}，安装成功 ${mcp_install_ok}，安装失败 ${mcp_install_failed}，目标写入成功 ${mcp_config_ok}，目标写入失败 ${mcp_config_failed}"
    echo "   Skills: 请求 ${#selected_skills[@]}，安装成功 ${skill_install_ok}，安装失败 ${skill_install_failed}，目标写入成功 ${skill_config_ok}，目标写入失败 ${skill_config_failed}"
    [[ ${#failed_mcp_ids[@]} -gt 0 ]] && echo -e "   ${RED}失败 MCP: ${failed_mcp_ids[*]}${NC}"
    [[ ${#failed_skill_ids[@]} -gt 0 ]] && echo -e "   ${RED}失败 Skills: ${failed_skill_ids[*]}${NC}"

    local batch_failed=$((mcp_config_failed + skill_config_failed + mcp_install_failed + skill_install_failed))
    if [[ $batch_failed -eq 0 ]]; then
        echo -e "\n✅ 批量配置完成！"
    else
        echo -e "\n${RED}❌ 批量配置完成，但有 ${batch_failed} 项失败。${NC}"
    fi
    if [[ "${AI_HUB_BATCH_CONFIRM:-}" != "true" ]]; then
        read -p "按回车返回..."
    fi
    [[ $batch_failed -eq 0 ]]
}

batch_apply_standard_configs() {
    echo -e "${CYAN}🎯 按推荐场景配置 MCP 和 Skills${NC}"
    echo -e "${YELLOW}💡 场景来自 global.json.scenarios，具体 MCP/Skills 由各自配置文件 scenarios 字段动态匹配。${NC}"

    validate_shared_configs "structure" || {
        error_log "MCP/Skills 配置存在结构错误，请先修复后再批量配置。"
        read -p "按回车返回..."
        return 1
    }

    local scenario_opts=()
    local i
    for i in "${!SCENARIO_KEYS[@]}"; do
        if [[ -n "${SCENARIO_DESCS[$i]:-}" ]]; then
            scenario_opts+=("🎯 ${SCENARIO_NAMES[$i]} - ${SCENARIO_DESCS[$i]} (${SCENARIO_KEYS[$i]})")
        else
            scenario_opts+=("🎯 ${SCENARIO_NAMES[$i]} (${SCENARIO_KEYS[$i]})")
        fi
    done
    [[ ${#scenario_opts[@]} -eq 0 ]] && { warn_log "未找到可用场景配置"; return 1; }

    local scenario_res
    scenario_res=$(menu_select "选择要应用的场景（可多选）" "true" "true" "" "" "" "${scenario_opts[@]}")
    [[ "$scenario_res" == "EXIT" || -z "$scenario_res" ]] && return 0

    local selected_scenarios=() selected_mcps=() selected_skills=() idx
    local include_optional="false" include_experimental="false"
    scenario_res=$(unique_menu_indices $scenario_res)
    for idx in $scenario_res; do
        [[ -n "${SCENARIO_KEYS[$idx]:-}" ]] || continue
        selected_scenarios+=("${SCENARIO_KEYS[$idx]}")
        [[ "${SCENARIO_INCLUDE_OPTIONAL[$idx]:-false}" == "true" ]] && include_optional="true"
        [[ "${SCENARIO_INCLUDE_EXPERIMENTAL[$idx]:-false}" == "true" ]] && include_experimental="true"
    done
    selected_mcps=($(find_items_by_scenarios "mcp-servers" "$include_optional" "$include_experimental" "${selected_scenarios[@]}"))
    selected_skills=($(find_items_by_scenarios "skills" "$include_optional" "$include_experimental" "${selected_scenarios[@]}"))
    merge_skill_dependency_mcps selected_mcps "${selected_skills[@]}"

    echo -e "\n📌 已选场景: ${CYAN}${selected_scenarios[*]}${NC}"
    batch_apply_selected_configs "推荐场景配置" "${selected_mcps[@]}" -- "${selected_skills[@]}"
}

# ==================== 基于标签的动态配置 ====================

canonical_tag() {
    local tag="$1"
    tag="${tag#"${tag%%[![:space:]]*}"}"
    tag="${tag%"${tag##*[![:space:]]}"}"
    case "$tag" in
        prd|Prd|pRd|prD|PRd|PrD|pRD|PRD) echo "PRD" ;;
        ui|Ui|uI|UI) echo "UI" ;;
        ux|Ux|uX|UX) echo "UX" ;;
        api|Api|aPI|API) echo "API" ;;
        pdf|Pdf|pDF|PDF) echo "PDF" ;;
        git) echo "Git" ;;
        github|Github|GitHub) echo "GitHub" ;;
        gitlab|Gitlab|GitLab) echo "GitLab" ;;
        ssh|Ssh|sSH|SSH) echo "SSH" ;;
        ocr|Ocr|oCR|OCR) echo "OCR" ;;
        token|Token) echo "Token" ;;
        mcp|Mcp|MCP) echo "MCP" ;;
        drawio|Drawio|draw.io|Draw.io) echo "draw.io" ;;
        diagram|Diagram) echo "diagram" ;;
        markdown|Markdown) echo "Markdown" ;;
        documentation|Documentation) echo "文档" ;;
        research|Research) echo "研究" ;;
        science|Science) echo "科研" ;;
        *) echo "$tag" ;;
    esac
}

# 收集所有可用标签
collect_all_tags() {
    local type="$1"  # "skills" 或 "mcp-servers"
    local dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/$type"
    local f
    
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == _* ]] && continue
        while IFS= read -r tag; do
            canonical_tag "$tag"
        done < <(jq -r '.tags[]? | select(. != null and . != "")' "$f" 2>/dev/null)
    done
}

count_items_by_tag() {
    local type="$1"
    local tag="$2"
    local dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/$type"
    local count=0 f
    local wanted
    wanted="$(canonical_tag "$tag")"

    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == _* ]] && continue
        local raw_tag matched=false
        while IFS= read -r raw_tag; do
            [[ "$(canonical_tag "$raw_tag")" == "$wanted" ]] && { matched=true; break; }
        done < <(jq -r '.tags[]? | select(. != null and . != "")' "$f" 2>/dev/null)
        if [[ "$matched" == "true" ]]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

tag_icon() {
    local tag="$1"
    case "$tag" in
        *设计*|UI|*原型*|*网页*|*视觉*|*信息图*) echo "🎨" ;;
        *架构*|*流程*|*图*|drawio|diagram) echo "📈" ;;
        PRD|prd|*产品*|*需求*|*评审*|*路线图*|*埋点*|*营销*|SEO|CRO|*增长*|*广告*|*文案*) echo "📋" ;;
        *编程*|*代码*|Git|GitHub|GitLab|*开发*|*测试*|TypeScript|Python|Golang|Web|*工程实践*|*Issue*|*规则*) echo "💻" ;;
        *Token*|token|*上下文*|*压缩*|*优化*|*记忆*) echo "🧠" ;;
        *工作台*|*编排*|*Agent平台*|Harness|Handoff|Hooks|MCP|Claude\ Code|Codex|OpenCode|Cursor) echo "🧩" ;;
        *安全*|*审计*|*扫描*|*权限*|*注入*) echo "🛡️" ;;
        *研究*|research|science|*知识*|PDF|*文档*|*Skill\ 集合*|*精选索引*|*Claude\ Skills*) echo "📚" ;;
        *数据库*|PostgreSQL|*数据*) echo "🗄️" ;;
        *浏览器*|*前端*) echo "🌐" ;;
        *SSH*|*远程*|*服务器*) echo "🛠️" ;;
        *) echo "🏷️" ;;
    esac
}

tag_group() {
    local tag="$1"
    case "$tag" in
        *设计*|UI|*原型*|*视觉*|*交互*|*草图*|*配色*|*字体*|*审美*|*风格*|Figma|Penpot|Pixso|Design2Code|TypeUI) echo "设计/原型" ;;
        *架构*|*流程*|*图*|drawio|draw.io|diagram|Mermaid|*可视化*) echo "图表/架构" ;;
        PRD|prd|*产品*|*需求*|*评审*|*路线图*|*埋点*|*优先级*|*复盘*|*问卷*|*实验*|A/B*|*文案*) echo "产品/文档" ;;
        *编程*|*代码*|*开发*|*重构*|*调试*|Debug|CR|Tree-sitter|Git*|Python|Golang|Rust|TypeScript|React|HTML|Web|*工程实践*|*Issue*|*规则*) echo "研发/代码" ;;
        *测试*|QA|E2E|Playwright|Appium|k6|TDD|*压测*) echo "测试/QA" ;;
        *安全*|*审计*|*扫描*|*权限*|*注入*|CVE|Cybersecurity|OWASP|MITRE|*漏洞*|*隐私*) echo "安全/审计" ;;
        *Token*|token|*上下文*|*压缩*|*优化*|*记忆*) echo "上下文/Token" ;;
        *工作台*|*编排*|*Agent*|*多代理*|Harness|Handoff|Hooks|MCP|Claude\ Code|claude-code|Codex|OpenCode|Cursor|skill-generation|team-architecture|*技能*) echo "Agent平台" ;;
        *研究*|research|science|*知识*|PDF|*笔记*|*信息*|*思维*|*逻辑*|*推理*|*科研*|bioinformatics|cheminformatics|genomics|proteomics|drug-discovery|ml) echo "研究/知识" ;;
        *数据库*|PostgreSQL|*数据*|API|*请求*|*接口*) echo "数据/接口" ;;
        *浏览器*|*前端*|*爬虫*|*网页*) echo "浏览器/爬虫" ;;
        *运维*|*监控*|*服务器*|Ops|AIOps|APM|OpenTelemetry|Sentry|SigNoz|IaC|SSH|*远程*) echo "云与运维" ;;
        *市场*|*商业*|*运营*|*用户*|*竞品*|*财务*|*法务*|*定价*|*合规*|*营销*|SEO|CRO|*增长*|*广告*|GDPR|*社交*|Slack) echo "业务/运营" ;;
        *工具*|*自动化*|*效率*|RPA|n8n|SaaS*|*插件*|plugin|*文件*|OCR|*批量*) echo "通用/工具" ;;
        *) echo "其他" ;;
    esac
}

tag_group_icon() {
    local group="$1"
    case "$group" in
        设计/原型) echo "🎨" ;;
        图表/架构) echo "📈" ;;
        产品/文档) echo "📋" ;;
        研发/代码) echo "💻" ;;
        测试/QA) echo "🛡️" ;;
        安全/审计) echo "🔒" ;;
        上下文/Token) echo "🧠" ;;
        Agent平台) echo "🧩" ;;
        研究/知识) echo "📚" ;;
        数据/接口) echo "🗄️" ;;
        浏览器/爬虫) echo "🌐" ;;
        云与运维) echo "🛠️" ;;
        业务/运营) echo "💼" ;;
        通用/工具) echo "🧰" ;;
        *) echo "🏷️" ;;
    esac
}

# 根据标签查找对应的 Skills/MCP
find_items_by_tags() {
    local type="$1"  # "skills" 或 "mcp-servers"
    shift
    local tags=("$@")
    
    local dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/$type"
    [[ -d "$dir" ]] || return 0

    local selected_tags=() raw selected
    for raw in "${tags[@]}"; do
        selected="$(canonical_tag "$raw")"
        is_id_in_words "$selected" "${selected_tags[@]}" || selected_tags+=("$selected")
    done

    local f id raw_tag
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == _* ]] && continue
        id=$(jq -r '.id // empty' "$f" 2>/dev/null)
        [[ -n "$id" ]] || continue
        while IFS= read -r raw_tag; do
            if is_id_in_words "$(canonical_tag "$raw_tag")" "${selected_tags[@]}"; then
                printf '%s ' "$id"
                break
            fi
        done < <(jq -r '.tags[]? | select(. != null and . != "")' "$f" 2>/dev/null)
    done
}

find_items_by_scenarios() {
    local type="$1"  # "skills" 或 "mcp-servers"
    shift
    local include_optional="false" include_experimental="false"
    if [[ "${1:-}" =~ ^(true|false)$ && "${2:-}" =~ ^(true|false)$ ]]; then
        include_optional="$1"
        include_experimental="$2"
        shift 2
    fi
    local scenarios=("$@")
    local dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/$type"

    [[ ${#scenarios[@]} -gt 0 ]] || return 0
    [[ -d "$dir" ]] || return 0

    local selected_json
    selected_json=$(printf '%s\n' "${scenarios[@]}" | jq -R . | jq -s .)

    # 性能优化：用 jq -s 一次处理全部文件，替代循环中每个文件单独调用 jq
    # shellcheck disable=SC2046
    jq -r \
        --argjson selected "$selected_json" \
        --argjson include_optional "$include_optional" \
        --argjson include_experimental "$include_experimental" '
        . as $item
        | ($item.id // empty) as $id
        | if (($item.scenarios // []) | any(. as $s | $selected | index($s)))
            and ($include_optional or (($item.optional // false) | not))
            and ($include_experimental or (($item.experimental // false) | not))
          then $id
          else empty end
    ' $(find "$dir" -maxdepth 1 -name "*.json" ! -name "_*" 2>/dev/null) 2>/dev/null \
    | tr '\n' ' '
}

merge_skill_dependency_mcps() {
    local result_var="$1"
    shift
    # 严格校验变量名：仅允许合法标识符，防止代码注入
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { error_log "merge_skill_dependency_mcps: 非法变量名 '$result_var'"; return 1; }

    local merged=()
    # shellcheck disable=SC2086 # eval 变量名已通过正则校验
    eval "merged=(\"\${${result_var}[@]}\")"

    local sid file dep
    for sid in "$@"; do
        file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills/${sid}.json"
        [[ -f "$file" ]] || continue
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            # 校验依赖 ID 也是合法标识符，防止注入
            [[ "$dep" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
            [[ -f "${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${dep}.json" ]] || continue
            is_id_in_words "$dep" "${merged[@]}" || merged+=("$dep")
        done < <(jq -r '.dependencies.mcp_servers[]?' "$file" 2>/dev/null)
    done

    # shellcheck disable=SC2086
    eval "$result_var=(\"\${merged[@]}\")"
}

filter_mcps_by_env() {
    local result_var="$1"
    # 严格校验变量名：仅允许合法标识符，防止代码注入
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { error_log "filter_mcps_by_env: 非法变量名 '$result_var'"; return 1; }

    FILTERED_MCP_SKIPPED=()
    FILTERED_MCP_SKIPPED_DETAILS=()
    local input=()
    # shellcheck disable=SC2086
    eval "input=(\"\${${result_var}[@]}\")"

    local kept=() skipped=() m file env_name missing compatibility_check compatibility_reason
    for m in "${input[@]}"; do
        # 校验每个 MCP ID 是合法标识符
        [[ "$m" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${m}.json"
        [[ -f "$file" ]] || continue
        compatibility_check=$(jq -r '.compatibility.check // empty' "$file" 2>/dev/null)
        compatibility_reason=$(jq -r '.compatibility.reason // "当前系统不兼容"' "$file" 2>/dev/null)
        if [[ -n "$compatibility_check" ]] && ! bash -c "$compatibility_check" >/dev/null 2>&1; then
            skipped+=("${m}(系统不兼容)")
            FILTERED_MCP_SKIPPED+=("$m")
            FILTERED_MCP_SKIPPED_DETAILS+=("$m: 系统不兼容 - $compatibility_reason")
            warn_log "MCP $m 已跳过: $compatibility_reason"
            continue
        fi
        missing=()
        while IFS= read -r env_name; do
            [[ -n "$env_name" ]] || continue
            [[ "$env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
            [[ -n "${!env_name:-}" ]] || missing+=("$env_name")
        done < <(jq -r '.requires_env[]? | if type=="object" then (select(.required != false) | .name) else . end' "$file" 2>/dev/null)
        if [[ ${#missing[@]} -gt 0 ]]; then
            skipped+=("${m}(${missing[*]})")
            FILTERED_MCP_SKIPPED+=("$m")
            FILTERED_MCP_SKIPPED_DETAILS+=("$m: 缺少必需环境变量 ${missing[*]}")
        else
            kept+=("$m")
        fi
    done

    if [[ ${#skipped[@]} -gt 0 ]]; then
        warn_log "以下 MCP 缺少必需环境变量，已跳过本次写入，避免启动后 Disconnected: ${skipped[*]}"
    fi

    # shellcheck disable=SC2086
    eval "$result_var=(\"\${kept[@]}\")"
}

mcp_required_envs() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 0
    jq -r '.requires_env[]? | if type=="object" then (select(.required != false) | .name) else . end' "$file" 2>/dev/null \
    | while IFS= read -r env_name; do
        [[ "$env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && echo "$env_name"
    done
}

mcp_missing_envs() {
    local server_id="$1"
    local env_name
    while IFS= read -r env_name; do
        [[ -n "$env_name" ]] || continue
        [[ -n "${!env_name:-}" ]] || echo "$env_name"
    done < <(mcp_required_envs "$server_id")
}

prompt_mcp_missing_envs() {
    local server_id="$1"
    shift
    local missing=("$@")
    [[ ${#missing[@]} -gt 0 ]] || return 0

    if [[ "${AI_HUB_BATCH_CONFIRM:-}" == "true" || "${AI_HUB_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        return 1
    fi

    echo -e "\n${YELLOW}MCP $server_id 需要以下运行时变量，留空则不写入该 MCP 配置:${NC}"
    local env_name value
    for env_name in "${missing[@]}"; do
        read_mcp_config_value "$env_name" "" "$server_id" value || return 1
        validate_mcp_config_value "$env_name" "$value" || return 1
        export "$env_name=$value"
    done
    return 0
}

read_mcp_config_value() {
    local var_name="$1"
    local default_value="${2:-}"
    local label="${3:-MCP}"
    local result_var="$4"
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1

    local prompt="  ${var_name}"
    [[ -n "$default_value" ]] && prompt+=" [$default_value]"
    prompt+=": "

    # 清空输入缓冲区（纯 Bash 兼容实现，支持 macOS Bash 3.2）
    while read -t 0 2>/dev/null; do read -r -t 1 discard 2>/dev/null || true; done

    local value=""
    local timeout="${AI_HUB_CONFIG_PROMPT_TIMEOUT:-30}"
    local read_ok=0
    case "$var_name" in
        *PATH*|*FILE*)
            if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
                read -r -t "$timeout" -p "$prompt" value || read_ok=$?
            else
                read -r -p "$prompt" value || read_ok=$?
            fi
            ;;
        *TOKEN*|*KEY*|*SECRET*|*PASSWORD*)
            if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
                read -r -s -t "$timeout" -p "$prompt" value || read_ok=$?
            else
                read -r -s -p "$prompt" value || read_ok=$?
            fi
            echo ""
            ;;
        *)
            if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
                read -r -t "$timeout" -p "$prompt" value || read_ok=$?
            else
                read -r -p "$prompt" value || read_ok=$?
            fi
            ;;
    esac

    # 去除可能包含的回车符（\r），当输入缓冲区残留 CRLF 时可能出现
    value="${value//$'\r'/}"

    if [[ $read_ok -ne 0 ]]; then
        warn_log "$label: $var_name 未在 ${timeout}s 内完成输入，跳过写入。"
        return 1
    fi
    value="${value:-$default_value}"
    [[ -n "$value" ]] || { warn_log "$label: $var_name 未配置，跳过写入。"; return 1; }
    printf -v "$result_var" '%s' "$value"
}

validate_mcp_config_value() {
    local var_name="$1"
    local value="$2"
    [[ -n "$value" ]] || return 1
    case "$var_name" in
        *_PORT|PORT|SSH_PORT)
            [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le 65535 ]] || { warn_log "$var_name 端口无效: $value"; return 1; }
            ;;
        *_URL|DATABASE_URL)
            case "$var_name:$value" in
                DATABASE_URL:postgres://*|DATABASE_URL:postgresql://*) ;;
                DATABASE_URL:*) warn_log "$var_name 应为 postgres/postgresql URL"; return 1 ;;
                *:http://*|*:https://*) ;;
                *) warn_log "$var_name 应为 http(s) URL"; return 1 ;;
            esac
            ;;
        SSH_KEY_PATH)
            local expanded
            expanded=$(expand_path "$value")
            [[ -f "$expanded" ]] || { warn_log "$var_name 文件不存在: $value"; return 1; }
            ;;
    esac
    return 0
}

sanitize_mcp_instance_id() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')
    [[ -n "$raw" ]] || raw="ssh"
    [[ "$raw" == ssh* ]] || raw="ssh-$raw"
    printf '%s\n' "$raw"
}

ssh_instance_config_json() {
    local host="$1"
    local user="$2"
    local port="${3:-22}"
    local key_path="${4:-$HOME/.ssh/id_rsa}"
    local base
    base=$(get_server_config "ssh") || return 1
    jq -c \
        --arg host "$host" \
        --arg user "$user" \
        --arg port "$port" \
        --arg key_path "$key_path" \
        '.env.SSH_HOST=$host | .env.SSH_USER=$user | .env.SSH_PORT=$port | .env.SSH_KEY_PATH=$key_path' \
        <<< "$base"
}

collect_ssh_mcp_configs() {
    local result_var="$1"
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    local configs=()

    if [[ "${AI_HUB_BATCH_CONFIRM:-}" == "true" || "${AI_HUB_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        if [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]]; then
            validate_mcp_config_value "SSH_PORT" "${SSH_PORT:-22}" || {
                FILTERED_MCP_SKIPPED+=("ssh")
                FILTERED_MCP_SKIPPED_DETAILS+=("ssh: SSH_PORT 配置无效")
                eval "$result_var=(\"\${configs[@]}\")"
                return 0
            }
            if [[ -n "${SSH_KEY_PATH:-}" ]]; then
                validate_mcp_config_value "SSH_KEY_PATH" "$SSH_KEY_PATH" || {
                    FILTERED_MCP_SKIPPED+=("ssh")
                    FILTERED_MCP_SKIPPED_DETAILS+=("ssh: SSH_KEY_PATH 配置无效")
                    eval "$result_var=(\"\${configs[@]}\")"
                    return 0
                }
            fi
            local conf
            conf=$(ssh_instance_config_json "$SSH_HOST" "$SSH_USER" "${SSH_PORT:-22}" "${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}") || return 1
            configs+=("ssh:$conf")
        else
            local conf
            conf=$(get_server_config "ssh") || return 1
            configs+=("ssh:$conf")
        fi
        eval "$result_var=(\"\${configs[@]}\")"
        return 0
    fi

    echo -e "\n${CYAN}SSH MCP 配置${NC}"
    echo "可写入多个 SSH 实例。实例名用于区分配置，例如 ssh-hk、ssh-sg。"
    local index=1 alias default_alias host user port key_path conf
    while :; do
        if [[ $index -eq 1 ]]; then
            default_alias="ssh"
        else
            default_alias="ssh-$index"
        fi

        # 清空输入缓冲区（纯 Bash 兼容实现，支持 macOS Bash 3.2）
        while read -t 0 2>/dev/null; do read -r -t 1 discard 2>/dev/null || true; done

        read -r -t "${AI_HUB_CONFIG_PROMPT_TIMEOUT:-30}" -p "实例名 [默认 $default_alias，直接回车继续]: " alias || {
            warn_log "SSH 实例名输入超时，结束 SSH 配置。"
            break
        }
        alias="${alias//$'\r'/}"
        alias="${alias:-$default_alias}"
        alias=$(sanitize_mcp_instance_id "$alias")

        read_mcp_config_value "SSH_HOST" "" "$alias" host || break
        [[ -n "$host" ]] || break
        read_mcp_config_value "SSH_USER" "${SSH_USER:-$USER}" "$alias" user || break
        read_mcp_config_value "SSH_PORT" "22" "$alias" port || break
        validate_mcp_config_value "SSH_PORT" "$port" || break
        read_mcp_config_value "SSH_KEY_PATH" "${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}" "$alias" key_path || break
        validate_mcp_config_value "SSH_KEY_PATH" "$key_path" || break

        conf=$(ssh_instance_config_json "$host" "$user" "$port" "$key_path") || return 1
        configs+=("$alias:$conf")

        read -r -t "${AI_HUB_CONFIG_PROMPT_TIMEOUT:-30}" -p "继续添加 SSH 实例？(y/N): " _more_ssh || _more_ssh=""
        [[ "$_more_ssh" == "y" || "$_more_ssh" == "Y" ]] || break
        index=$((index + 1))
    done

    if [[ ${#configs[@]} -eq 0 ]]; then
        FILTERED_MCP_SKIPPED+=("ssh")
        FILTERED_MCP_SKIPPED_DETAILS+=("ssh: 未提供 SSH_HOST，未写入配置")
    fi
    eval "$result_var=(\"\${configs[@]}\")"
}

build_runtime_mcp_configs() {
    local result_var="$1"
    shift
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { error_log "build_runtime_mcp_configs: 非法变量名 '$result_var'"; return 1; }

    FILTERED_MCP_SKIPPED=()
    FILTERED_MCP_SKIPPED_DETAILS=()

    local configs=() m missing=() env_name conf ssh_configs=()
    for m in "$@"; do
        [[ -n "$m" ]] || continue
        if [[ "$m" == "ssh" ]]; then
            collect_ssh_mcp_configs ssh_configs
            configs+=("${ssh_configs[@]}")
            continue
        fi

        missing=()
        while IFS= read -r env_name; do
            [[ -n "$env_name" ]] && missing+=("$env_name")
        done < <(mcp_missing_envs "$m")

        if [[ ${#missing[@]} -gt 0 ]]; then
            if ! prompt_mcp_missing_envs "$m" "${missing[@]}"; then
                FILTERED_MCP_SKIPPED+=("$m")
                FILTERED_MCP_SKIPPED_DETAILS+=("$m: 缺少必需环境变量 ${missing[*]}")
                continue
            fi
        fi

        conf=$(get_server_config "$m")
        [[ -n "$conf" ]] && configs+=("$m:$conf")
    done

    eval "$result_var=(\"\${configs[@]}\")"
}

filter_mcps_by_compatibility() {
    local result_var="$1"
    [[ "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { error_log "filter_mcps_by_compatibility: 非法变量名 '$result_var'"; return 1; }

    FILTERED_MCP_INCOMPATIBLE=()
    FILTERED_MCP_INCOMPATIBLE_DETAILS=()
    local input=()
    # shellcheck disable=SC2086
    eval "input=(\"\${${result_var}[@]}\")"

    local kept=() m file compatibility_check compatibility_reason
    for m in "${input[@]}"; do
        [[ "$m" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${m}.json"
        [[ -f "$file" ]] || continue
        compatibility_check=$(jq -r '.compatibility.check // empty' "$file" 2>/dev/null)
        compatibility_reason=$(jq -r '.compatibility.reason // "当前系统不兼容"' "$file" 2>/dev/null)
        if [[ -n "$compatibility_check" ]] && ! bash -c "$compatibility_check" >/dev/null 2>&1; then
            FILTERED_MCP_INCOMPATIBLE+=("$m")
            FILTERED_MCP_INCOMPATIBLE_DETAILS+=("$m: 系统不兼容 - $compatibility_reason")
            warn_log "MCP $m 已跳过安装: $compatibility_reason"
            continue
        fi
        kept+=("$m")
    done

    # shellcheck disable=SC2086
    eval "$result_var=(\"\${kept[@]}\")"
}

mcp_prepare_needed() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 1

    case "$server_id" in
        bb-browser)
            command_exists bb-browser || return 0
            if bb-browser site list 2>/dev/null | grep -q "未找到任何 site adapter"; then
                return 0
            fi
            bb-browser daemon status 2>/dev/null | grep -q "Daemon running: yes" || return 0
            return 1
            ;;
        umi-ocr)
            curl -fsS --max-time 15 "${UMI_OCR_URL:-http://localhost:1224}/api/ocr" \
                -X POST \
                -H "Content-Type: application/json" \
                -d '{"base64":""}' >/dev/null 2>&1 && return 1
            return 0
            ;;
    esac

    local prepare_cmd
    # 兼容旧配置：prepare 可能位于 install.prepare 或顶层 prepare。
    prepare_cmd=$(jq -r '.install.prepare // .prepare // empty' "$file" 2>/dev/null)
    [[ -n "$prepare_cmd" ]]
}

prepare_mcp_server_if_needed() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 1
    mcp_prepare_needed "$server_id" || return 0

    local prepare_cmd
    # 兼容旧配置：prepare 可能位于 install.prepare 或顶层 prepare。
    prepare_cmd=$(jq -r '.install.prepare // .prepare // empty' "$file" 2>/dev/null)
    [[ -n "$prepare_cmd" ]] || return 0
    prepare_cmd=$(expand_vars "$prepare_cmd")

    if [[ ! -t 0 && "${AI_HUB_MCP_PREPARE_AUTO:-0}" != "1" && "${BATCH_MODE:-0}" != "1" ]]; then
        warn_log "MCP $server_id 需要准备前置依赖，非交互模式已跳过。可设置 AI_HUB_MCP_PREPARE_AUTO=1 自动执行。"
        return 0
    fi

    local answer="y"
    if [[ -t 0 && "${AI_HUB_MCP_PREPARE_AUTO:-0}" != "1" ]]; then
        # 批量配置模式下（非交互或场景配置）自动执行，不询问
        if [[ "${BATCH_MODE:-0}" == "1" ]]; then
            answer="y"
        else
            read -p "MCP $server_id 需要准备前置依赖，是否现在执行？(Y/n): " answer
            [[ "$answer" =~ ^[Nn]$ ]] && { warn_log "已跳过 MCP $server_id 前置依赖准备。"; return 0; }
        fi
    fi

    run_configured_command "$prepare_cmd" "准备 MCP 前置依赖: $server_id"
    local rc=$?
    if [[ $rc -eq 2 ]]; then
        warn_log "MCP $server_id 前置依赖未自动启动；本次继续写入配置，服务可稍后手动启动。"
    elif [[ $rc -ne 0 ]]; then
        warn_log "MCP $server_id 前置依赖准备失败，可稍后手动执行: $prepare_cmd"
    fi
}

validate_shared_configs() {
    local mode="${1:-warn}"
    local base="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}"
    local check_env="false"
    [[ "$mode" == "warn" || "$mode" == "env" ]] && check_env="true"
    local errors=0 warnings=0 f id filename type dep env_name cmd

    _config_issue() {
        local level="$1" file="$2" msg="$3"
        if [[ "$level" == "ERROR" ]]; then
            errors=$((errors + 1))
            echo -e "${RED}[ERROR]${NC} 配置错误: ${file}"
        else
            warnings=$((warnings + 1))
            echo -e "${YELLOW}[WARN]${NC} 配置需关注: ${file}"
        fi
        echo "  - ${msg}"
    }

    for type in "mcp-servers" "skills"; do
        for f in "$base/shared/$type"/*.json; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == _* ]] && continue
            if ! jq -e . "$f" >/dev/null 2>&1; then
                _config_issue "ERROR" "$f" "不是合法 JSON 或文件为空"
                continue
            fi
            id=$(jq -r '.id // empty' "$f")
            filename=$(basename "$f" .json)
            [[ -n "$id" ]] || _config_issue "ERROR" "$f" "缺少必填字段 id"
            [[ -z "$id" || "$id" == "$filename" ]] || _config_issue "WARN" "$f" "文件名建议与 id 一致: ${id}.json"
            for field in name description category; do
                jq -e --arg field "$field" '.[$field] and (.[$field] | tostring | length > 0)' "$f" >/dev/null 2>&1 || \
                    _config_issue "ERROR" "$f" "缺少必填字段 ${field}"
            done
            jq -e '.tags and (.tags | type == "array") and (.tags | length > 0)' "$f" >/dev/null 2>&1 || \
                _config_issue "ERROR" "$f" "缺少 tags 数组，无法按标签分类"
            while IFS=$'\t' read -r raw_tag canonical; do
                [[ -n "$raw_tag" ]] || continue
                [[ "$raw_tag" == "$canonical" ]] || \
                    _config_issue "WARN" "$f" "tags 包含非规范标签 '${raw_tag}'，建议改为 '${canonical}'"
            done < <(jq -r '.tags[]? | select(. != null) | tostring' "$f" 2>/dev/null | while IFS= read -r _tag; do
                printf '%s\t%s\n' "$_tag" "$(canonical_tag "$_tag")"
            done)
            jq -e '.scenarios and (.scenarios | type == "array") and (.scenarios | length > 0)' "$f" >/dev/null 2>&1 || \
                _config_issue "ERROR" "$f" "缺少 scenarios 数组，无法进入场景批量配置"
            jq -e '(.homepage // .repository // .references.github // .docs // "") | tostring | length > 0' "$f" >/dev/null 2>&1 || \
                _config_issue "WARN" "$f" "缺少 homepage/repository/references.github 链接"

            while IFS= read -r scenario; do
                [[ -n "$scenario" ]] || continue
                if ! is_id_in_words "$scenario" "${SCENARIO_KEYS[@]}"; then
                    _config_issue "ERROR" "$f" "scenarios 包含未在 global.json 注册的场景: $scenario"
                fi
            done < <(jq -r '.scenarios[]?' "$f" 2>/dev/null)

            if [[ "$type" == "mcp-servers" ]]; then
                jq -e '.config.command and (.config.command | tostring | length > 0)' "$f" >/dev/null 2>&1 || \
                    _config_issue "ERROR" "$f" "MCP 缺少 config.command"
                # MCP 可能依赖本机 CLI；提前报告缺失依赖，避免启动后才出现 tools=0。
                while IFS= read -r req_tool; do
                    [[ -n "$req_tool" ]] || continue
                    if [[ "$req_tool" == */* ]]; then
                        [[ -x "$req_tool" ]] || _config_issue "WARN" "$f" "MCP 依赖命令未找到或不可执行: $req_tool"
                    else
                        command_exists "$req_tool" || _config_issue "WARN" "$f" "MCP 依赖命令未找到: $req_tool（请先安装后再重启 MCP）"
                    fi
                done < <(jq -r '.required_tools[]? | if type == "object" then (.command // .name // empty) else tostring end' "$f" 2>/dev/null)
                if [[ "$check_env" == "true" ]]; then
                    while IFS= read -r env_name; do
                        [[ -n "$env_name" ]] || continue
                        [[ "$env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || \
                            { _config_issue "WARN" "$f" "requires_env 含非法环境变量名 '${env_name}'，应为字符串或 {name:...} 对象"; continue; }
                        [[ -n "${!env_name:-}" ]] || _config_issue "WARN" "$f" "requires_env 声明了 ${env_name}，但当前环境未设置；该 MCP 启动时可能 Disconnected"
                    done < <(jq -r '.requires_env[]? | if type=="object" then (select(.required != false) | .name) else . end' "$f" 2>/dev/null)
                fi
            else
                while IFS= read -r dep; do
                    [[ -n "$dep" ]] || continue
                    [[ -f "$base/shared/mcp-servers/${dep}.json" ]] || \
                        _config_issue "ERROR" "$f" "dependencies.mcp_servers 引用了不存在的 MCP: $dep"
                done < <(jq -r '.dependencies.mcp_servers[]?' "$f" 2>/dev/null)
            fi
        done
    done

    # tools 目录是产品分类的边界：cli 仅允许 AI 客户端，其他命令行工具必须归入 utility。
    local tool_dir expected_category actual_category
    for tool_dir in cli ide agent gateway runtime optimizer workbench builder utility; do
        case "$tool_dir" in
            cli) expected_category="ai-coding" ;;
            ide) expected_category="ai-ide" ;;
            agent) expected_category="ai-agent" ;;
            gateway) expected_category="ai-gateway" ;;
            runtime) expected_category="ai-runtime" ;;
            optimizer) expected_category="ai-optimizer" ;;
            workbench) expected_category="ai-workbench" ;;
            builder) expected_category="ai-builder" ;;
            utility) expected_category="ai-utility" ;;
        esac
        for f in "$base/tools/$tool_dir"/*.json; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == _* ]] && continue
            actual_category=$(jq -r '.category // empty' "$f" 2>/dev/null)
            [[ "$actual_category" == "$expected_category" ]] || \
                _config_issue "ERROR" "$f" "目录 ${tool_dir} 要求 category=${expected_category}，实际为 ${actual_category:-未设置}"
        done
    done

    if [[ "$mode" != "quiet" && $((errors + warnings)) -gt 0 ]]; then
        echo -e "${YELLOW}配置验证完成: ${errors} 个错误, ${warnings} 个警告。${NC}"
    fi
    [[ "$errors" -eq 0 ]]
}

check_shared_configs_menu() {
    echo -e "${CYAN}🔍 检查 MCP / Skills 配置${NC}"
    echo -e "${YELLOW}说明: 结构错误会阻断批量配置；环境变量缺失、链接缺失等为警告。${NC}"
    if validate_shared_configs "warn"; then
        success_log "MCP/Skills 配置结构校验通过。"
    else
        error_log "MCP/Skills 配置存在结构错误，请按上方文件路径修复。"
    fi
    read -p "按回车返回..."
}

# 基于标签的批量配置
batch_apply_by_tags() {
    echo -e "${CYAN}🏷️ 按标签精细选择 MCP 和 Skills${NC}"
    echo -e "${YELLOW}💡 标签菜单来自 conf/shared/skills 与 conf/shared/mcp-servers 的 tags 字段。${NC}"

    validate_shared_configs "structure" || {
        error_log "MCP/Skills 配置存在结构错误，请先修复后再批量配置。"
        read -p "按回车返回..."
        return 1
    }
    
    local all_tags=() t
    while IFS= read -r t; do
        [[ -n "$t" ]] && all_tags+=("$t")
    done < <({ collect_all_tags "skills"; collect_all_tags "mcp-servers"; } | sort -u)
    
    [[ ${#all_tags[@]} -eq 0 ]] && { warn_log "未找到可用标签"; return 1; }

    local groups=() group group_opts=() group_counts=()
    for t in "${all_tags[@]}"; do
        group=$(tag_group "$t")
        if ! is_id_in_words "$group" "${groups[@]}"; then
            groups+=("$group")
            group_counts+=("0")
        fi
        local gi
        for gi in "${!groups[@]}"; do
            if [[ "${groups[$gi]}" == "$group" ]]; then
                group_counts[$gi]=$((group_counts[$gi] + 1))
                break
            fi
        done
    done

    local i
    for i in "${!groups[@]}"; do
        group_opts+=("$(tag_group_icon "${groups[$i]}") ${groups[$i]} (${group_counts[$i]} tags)")
    done
    group_opts+=("🛠️ 全部分组")

    local group_res
    group_res=$(menu_select "选择标签分组（可多选）" "true" "true" "" "" "" "${group_opts[@]}")
    [[ "$group_res" == "EXIT" || -z "$group_res" ]] && return 0

    local selected_groups=() idx all_group_idx
    all_group_idx="${#groups[@]}"
    group_res=$(unique_menu_indices $group_res)
    for idx in $group_res; do
        if [[ "$idx" == "$all_group_idx" ]]; then
            selected_groups=("${groups[@]}")
            break
        fi
        [[ -n "${groups[$idx]:-}" ]] && selected_groups+=("${groups[$idx]}")
    done
    [[ ${#selected_groups[@]} -eq 0 ]] && { warn_log "未选择任何标签分组"; return 1; }

    local scoped_tags=() tag_opts=()
    # 性能优化：一次性批量获取所有 tag → (mcp_count, skill_count) 映射，
    # 避免对每个 tag 各调用一次 count_items_by_tag（O(tags × files) → O(files)）
    local _mcp_dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers"
    local _skill_dir="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills"
    # 用临时文件实现关联数组降级兼容
    local _tag_count_tmp
    _tag_count_tmp=$(mktemp "${TMPDIR:-/tmp}/aihub-tagcnt.XXXXXX") || true
    trap "rm -f '${_tag_count_tmp:-}'" RETURN

    if [[ -n "$_tag_count_tmp" ]] && command_exists jq; then
        local _f _tid
        for _f in "$_mcp_dir"/*.json; do
            [[ -f "$_f" && "$(basename "$_f")" != _* ]] || continue
            while IFS= read -r _tid; do
                [[ -n "$_tid" ]] || continue
                printf 'mcp\t%s\n' "$(canonical_tag "$_tid")"
            done < <(jq -r '.tags[]? // empty' "$_f" 2>/dev/null)
        done >> "$_tag_count_tmp"
        for _f in "$_skill_dir"/*.json; do
            [[ -f "$_f" && "$(basename "$_f")" != _* ]] || continue
            while IFS= read -r _tid; do
                [[ -n "$_tid" ]] || continue
                printf 'skill\t%s\n' "$(canonical_tag "$_tid")"
            done < <(jq -r '.tags[]? // empty' "$_f" 2>/dev/null)
        done >> "$_tag_count_tmp"
    fi

    for t in "${all_tags[@]}"; do
        group=$(tag_group "$t")
        is_id_in_words "$group" "${selected_groups[@]}" || continue
        scoped_tags+=("$t")
        local mcp_count skill_count
        if [[ -n "$_tag_count_tmp" && -f "$_tag_count_tmp" ]]; then
            mcp_count=$(awk -F '\t' -v tag="$t" '$1 == "mcp" && $2 == tag { count++ } END { print count + 0 }' "$_tag_count_tmp" 2>/dev/null)
            skill_count=$(awk -F '\t' -v tag="$t" '$1 == "skill" && $2 == tag { count++ } END { print count + 0 }' "$_tag_count_tmp" 2>/dev/null)
        else
            mcp_count=$(count_items_by_tag "mcp-servers" "$t")
            skill_count=$(count_items_by_tag "skills" "$t")
        fi
        tag_opts+=("$(tag_icon "$t") $t (MCP:${mcp_count} Skills:${skill_count})")
    done
    tag_opts+=("🛠️ 全选当前分组标签")

    local tag_res
    tag_res=$(menu_select "选择场景标签（可多选）" "true" "true" "" "" "" "${tag_opts[@]}")
    [[ "$tag_res" == "EXIT" || -z "$tag_res" ]] && return 0

    local selected_tags=() all_idx
    all_idx="${#scoped_tags[@]}"
    tag_res=$(unique_menu_indices $tag_res)
    for idx in $tag_res; do
        if [[ "$idx" == "$all_idx" ]]; then
            selected_tags=("${scoped_tags[@]}")
            break
        fi
        [[ -n "${scoped_tags[$idx]:-}" ]] && selected_tags+=("${scoped_tags[$idx]}")
    done
    
    [[ ${#selected_tags[@]} -eq 0 ]] && { warn_log "未选择任何标签"; return 1; }
    
    # 根据标签查找 Skills 和 MCP
    local selected_mcps=($(find_items_by_tags "mcp-servers" "${selected_tags[@]}"))
    local selected_skills=($(find_items_by_tags "skills" "${selected_tags[@]}"))
    merge_skill_dependency_mcps selected_mcps "${selected_skills[@]}"

    echo -e "\n📌 已选标签: ${CYAN}${selected_tags[*]}${NC}"
    batch_apply_selected_configs "标签精细配置" "${selected_mcps[@]}" -- "${selected_skills[@]}"
}

batch_apply_custom_configs() {
    echo -e "${CYAN}🧩 自定义选择 MCP / Skills${NC}"

    validate_shared_configs "structure" || {
        error_log "MCP/Skills 配置存在结构错误，请先修复后再批量配置。"
        read -p "按回车返回..."
        return 1
    }

    local mcp_opts=() mcp_ids=() skill_opts=() skill_ids=()
    local id name file s desc

    mcp_ids+=("")
    mcp_opts+=("跳过 MCP 选择")
    for id in "${MCP_SERVERS_NAMES[@]}"; do
        file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${id}.json"
        [[ -f "$file" ]] || continue
        name=$(jq -r '.name // .id' "$file" 2>/dev/null)
        mcp_ids+=("$id")
        mcp_opts+=("🔧 $name ($id)")
    done

    skill_ids+=("")
    skill_opts+=("跳过 Skills 选择")
    for s in "${SKILLS[@]}"; do
        IFS='|' read -r id name desc _ <<< "$s"
        [[ -n "$id" ]] || continue
        skill_ids+=("$id")
        skill_opts+=("🎯 $name ($id)")
    done

    local selected_mcps=() selected_skills=() res idx
    if [[ ${#mcp_opts[@]} -gt 0 ]]; then
        res=$(menu_select "选择 MCP（可多选）" "true" "true" "" "" "" "${mcp_opts[@]}")
        [[ "$res" == "EXIT" ]] && return 0
        res=$(unique_menu_indices $res)
        for idx in $res; do [[ -n "${mcp_ids[$idx]:-}" ]] && selected_mcps+=("${mcp_ids[$idx]}"); done
    fi

    if [[ ${#skill_opts[@]} -gt 0 ]]; then
        res=$(menu_select "选择 Skills（可多选）" "true" "true" "" "" "" "${skill_opts[@]}")
        [[ "$res" == "EXIT" ]] && return 0
        res=$(unique_menu_indices $res)
        for idx in $res; do [[ -n "${skill_ids[$idx]:-}" ]] && selected_skills+=("${skill_ids[$idx]}"); done
    fi

    batch_apply_selected_configs "自定义配置" "${selected_mcps[@]}" -- "${selected_skills[@]}"
}

# ==================== 6. 配置管理 ====================

show_tool_config() {
    local idx=$1
    parse_tool_data "${TOOLS[$idx]}" "C"
    if [[ -n "$C_conf" ]]; then
        echo -e "--- $C_name 配置 ($C_conf) ---"
        cat "$C_conf" 2>/dev/null || echo "为空"
    else
        echo "无配置路径"
    fi
    read -p "按回车返回..."
}

edit_tool_config() {
    local idx=$1
    parse_tool_data "${TOOLS[$idx]}" "C"
    if [[ -n "$C_conf" ]]; then
        ${EDITOR:-vim} "$C_conf"
    else
        echo "无配置路径"
    fi
}

reset_tool_config() {
    local idx=$1
    parse_tool_data "${TOOLS[$idx]}" "C"
    if [[ -n "$C_conf" ]]; then
        local cf
        read -p "重置 $C_name 配置? (y/N): " cf
        [[ "$cf" == "y" ]] && create_default_config "$C_conf" "$C_name"
    fi
}

# ==================== 7. 其他功能 ====================

create_default_config() {
    local config_file="$1"
    local tool_name="$2"
    [[ -z "$config_file" ]] && return 1
    mkdir -p "$(dirname "$config_file")"
    get_default_config_template "$tool_name" > "$config_file"
}

# 配置文件写入锁：macOS 没有默认 flock，使用同目录 mkdir 作为原子锁。
acquire_config_lock() {
    local config_file="$1"
    local lock_dir="${config_file}.aihub.lock"
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        [[ "$waited" -ge "${AI_HUB_CONFIG_LOCK_TIMEOUT:-30}" ]] && {
            error_log "配置文件被其他 AI Hub 进程锁定: $config_file"
            return 1
        }
        sleep 1
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
    CONFIG_LOCK_DIR="$lock_dir"
    return 0
}

release_config_lock() {
    local lock_dir="${1:-${CONFIG_LOCK_DIR:-}}"
    [[ -n "$lock_dir" ]] || return 0
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    [[ "${CONFIG_LOCK_DIR:-}" == "$lock_dir" ]] && CONFIG_LOCK_DIR=""
}

backup_config_file() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 0
    local backup_file="${config_file}.backup.aihub.$(date +%Y%m%d_%H%M%S).$$"
    cp -p "$config_file" "$backup_file" 2>/dev/null || {
        warn_log "无法创建配置备份: $backup_file"
        return 1
    }
}

_find_python_with_yaml() {
    # 缓存探测结果，避免重复执行
    if [[ -n "${_PYTHON_WITH_YAML_CACHE:-}" ]]; then
        echo "$_PYTHON_WITH_YAML_CACHE"
        return 0
    fi
    local candidate
    for candidate in \
        "$HOME/.hermes/hermes-agent/venv/bin/python" \
        "$HOME/.hermes/hermes-agent/.venv/bin/python" \
        "$(command -v python3 2>/dev/null)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
            _PYTHON_WITH_YAML_CACHE="$candidate"
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

add_mcp_configs_to_yaml_file() {
    local config_file="$1"
    local servers_json="$2"
    local config_lock="${config_file}.aihub.lock"
    acquire_config_lock "$config_file" || return 1
    local py
    py=$(_find_python_with_yaml) || { warn_log "写入 YAML MCP 配置需要 PyYAML；Hermes venv 或 python3 中未找到 yaml 模块"; release_config_lock "$config_lock"; return 1; }

    "$py" - "$config_file" "$servers_json" <<'PY'
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path
import yaml

config_path = Path(sys.argv[1]).expanduser()
servers_path = Path(sys.argv[2])
servers = json.loads(servers_path.read_text())
config_path.parent.mkdir(parents=True, exist_ok=True)
if config_path.exists():
    backup = config_path.with_name(config_path.name + ".backup.aihub." + datetime.now().strftime("%Y%m%d_%H%M%S"))
    shutil.copy2(config_path, backup)
    data = yaml.safe_load(config_path.read_text()) or {}
else:
    data = {}
if not isinstance(data, dict):
    data = {}
mcp_servers = data.get("mcp_servers")
if not isinstance(mcp_servers, dict):
    mcp_servers = {}
for name, conf in servers.items():
    if isinstance(conf, dict):
        conf.pop("transportType", None)
        conf["enabled"] = True
        mcp_servers[name] = conf
data["mcp_servers"] = mcp_servers
config_path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
PY
    local rc=$?
    release_config_lock "$config_lock"
    return $rc
}

write_codex_mcp_configs_to_toml() {
    local config_file="$1"
    local servers_json="$2"
    local config_lock="${config_file}.aihub.lock"
    acquire_config_lock "$config_file" || return 1
    local py
    py="$(command -v python3 2>/dev/null || true)"
    [[ -n "$py" ]] || { warn_log "写入 Codex TOML MCP 配置需要 python3"; release_config_lock "$config_lock"; return 1; }

    "$py" - "$config_file" "$servers_json" <<'PY'
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
servers_path = Path(sys.argv[2])
servers = json.loads(servers_path.read_text())
config_path.parent.mkdir(parents=True, exist_ok=True)

if config_path.exists():
    backup = config_path.with_name(config_path.name + ".backup.aihub." + datetime.now().strftime("%Y%m%d_%H%M%S"))
    shutil.copy2(config_path, backup)
    lines = config_path.read_text().splitlines()
else:
    lines = []

managed = set(servers.keys())
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    remove = False
    if stripped.startswith("[mcp_servers.") and stripped.endswith("]"):
        name = stripped[len("[mcp_servers."):-1]
        if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
            try:
                name = json.loads(name)
            except Exception:
                pass
        remove = name in managed
    if remove:
        i += 1
        while i < len(lines):
            next_stripped = lines[i].strip()
            if next_stripped.startswith("[") and next_stripped.endswith("]"):
                break
            i += 1
        continue
    out.append(line)
    i += 1

def toml_string(value):
    return json.dumps(str(value), ensure_ascii=False)

def toml_array(values):
    return "[" + ", ".join(toml_string(v) for v in values) + "]"

if out and out[-1].strip():
    out.append("")

for name, conf in servers.items():
    if not isinstance(conf, dict):
        continue
    command = conf.get("command")
    if not command:
        continue
    args = conf.get("args") if isinstance(conf.get("args"), list) else []
    env = conf.get("env") if isinstance(conf.get("env"), dict) else {}
    cwd = conf.get("cwd")
    startup_timeout_sec = conf.get("startup_timeout_sec")

    out.append(f"[mcp_servers.{toml_string(name)}]")
    out.append(f"command = {toml_string(command)}")
    if args:
        out.append(f"args = {toml_array(args)}")
    if cwd:
        out.append(f"cwd = {toml_string(cwd)}")
    if startup_timeout_sec is not None:
        out.append(f"startup_timeout_sec = {int(startup_timeout_sec)}")
    for key, value in env.items():
        if value is None or value == "":
            continue
        out.append(f"env.{key} = {toml_string(value)}")
    out.append("")

config_path.write_text("\n".join(out).rstrip() + "\n")
PY
    local rc=$?
    release_config_lock "$config_lock"
    return $rc
}

remove_codex_mcp_configs_from_toml() {
    local config_file="$1"
    local ids_json_file="$2"
    local config_lock="${config_file}.aihub.lock"
    acquire_config_lock "$config_file" || return 1
    local py
    py="$(command -v python3 2>/dev/null || true)"
    [[ -n "$py" ]] || { warn_log "清理 Codex TOML MCP 配置需要 python3"; release_config_lock "$config_lock"; return 1; }

    "$py" - "$config_file" "$ids_json_file" <<'PY'
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
ids_path = Path(sys.argv[2])
ids = set(json.loads(ids_path.read_text()))
if not config_path.exists():
    raise SystemExit(0)

backup = config_path.with_name(config_path.name + ".backup.aihub." + datetime.now().strftime("%Y%m%d_%H%M%S"))
shutil.copy2(config_path, backup)
lines = config_path.read_text().splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    remove = False
    if stripped.startswith("[mcp_servers.") and stripped.endswith("]"):
        name = stripped[len("[mcp_servers."):-1]
        if len(name) >= 2 and name[0] == '"' and name[-1] == '"':
            try:
                name = json.loads(name)
            except Exception:
                pass
        remove = name in ids
    if remove:
        i += 1
        while i < len(lines):
            next_stripped = lines[i].strip()
            if next_stripped.startswith("[") and next_stripped.endswith("]"):
                break
            i += 1
        continue
    out.append(line)
    i += 1

config_path.write_text("\n".join(out).rstrip() + "\n")
PY
    local rc=$?
    release_config_lock "$config_lock"
    return $rc
}

remove_mcp_configs_from_yaml_file() {
    local config_file="$1"
    local ids_json_file="$2"
    local config_lock="${config_file}.aihub.lock"
    acquire_config_lock "$config_file" || return 1
    local py
    py=$(_find_python_with_yaml) || { warn_log "清理 YAML MCP 配置需要 PyYAML；Hermes venv 或 python3 中未找到 yaml 模块"; release_config_lock "$config_lock"; return 1; }

    "$py" - "$config_file" "$ids_json_file" <<'PY'
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path
import yaml

config_path = Path(sys.argv[1]).expanduser()
ids_path = Path(sys.argv[2])
ids = json.loads(ids_path.read_text())
if not config_path.exists():
    raise SystemExit(0)

backup = config_path.with_name(config_path.name + ".backup.aihub." + datetime.now().strftime("%Y%m%d_%H%M%S"))
shutil.copy2(config_path, backup)
data = yaml.safe_load(config_path.read_text()) or {}
if not isinstance(data, dict):
    data = {}

for key in ("mcp_servers", "mcpServers"):
    block = data.get(key)
    if isinstance(block, dict):
        for item in ids:
            block.pop(item, None)
        data[key] = block

config_path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
PY
    local rc=$?
    release_config_lock "$config_lock"
    return $rc
}

remove_mcp_configs_from_file() {
    local config_file="$1"
    shift
    local ids=("$@")
    [[ ${#ids[@]} -gt 0 ]] || return 0
    [[ -f "$config_file" ]] || return 0

    case "$config_file" in
        *.json)
            command_exists jq || return 1
            local ids_json tmp_file
            local config_lock="${config_file}.aihub.lock"
            acquire_config_lock "$config_file" || return 1
            backup_config_file "$config_file" || { release_config_lock "$config_lock"; return 1; }
            ids_json=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)
            tmp_file=$(mktemp "$(dirname "$config_file")/.aihub-json.XXXXXX") || { release_config_lock "$config_lock"; return 1; }
            if jq --argjson ids "$ids_json" '
                reduce $ids[] as $id (.;
                    if has("mcpServers") then .mcpServers |= del(.[$id]) else . end
                    | if has("mcp_servers") then .mcp_servers |= del(.[$id]) else . end
                )
            ' "$config_file" > "$tmp_file" && jq empty "$tmp_file" >/dev/null 2>&1; then
                mv "$tmp_file" "$config_file"
                release_config_lock "$config_lock"
            else
                rm -f "$tmp_file"
                release_config_lock "$config_lock"
                return 1
            fi
            ;;
        *.yaml|*.yml)
            local ids_file
            ids_file=$(mktemp "${TMPDIR:-/tmp}/aihub-mcp-remove.XXXXXX") || return 1
            # trap 保证异常退出时也能清理临时文件
            trap "rm -f '$ids_file'" RETURN
            printf '%s\n' "${ids[@]}" | jq -R . | jq -s . > "$ids_file"
            remove_mcp_configs_from_yaml_file "$config_file" "$ids_file"
            return $?
            ;;
        *.toml)
            local ids_file
            ids_file=$(mktemp "${TMPDIR:-/tmp}/aihub-mcp-remove.XXXXXX") || return 1
            trap "rm -f '$ids_file'" RETURN
            printf '%s\n' "${ids[@]}" | jq -R . | jq -s . > "$ids_file"
            remove_codex_mcp_configs_from_toml "$config_file" "$ids_file"
            return $?
            ;;
        *)
            warn_log "暂不支持自动清理该配置格式中的 MCP: $config_file"
            return 1
            ;;
    esac
}

mcp_config_exists_in_file() {
    local config_file="$1"
    local server_id="$2"
    [[ -n "$config_file" && -n "$server_id" && -f "$config_file" ]] || return 1

    case "$config_file" in
        *.json)
            command_exists jq || return 1
            jq -e --arg id "$server_id" '(.mcpServers? // .mcp_servers? // {}) | has($id)' "$config_file" >/dev/null 2>&1
            ;;
        *.yaml|*.yml)
            local py
            py=$(_find_python_with_yaml) || return 1
            "$py" - "$config_file" "$server_id" <<'PY'
import sys
from pathlib import Path
import yaml

config_path = Path(sys.argv[1]).expanduser()
server_id = sys.argv[2]
data = yaml.safe_load(config_path.read_text()) or {}
if not isinstance(data, dict):
    raise SystemExit(1)
for key in ("mcp_servers", "mcpServers"):
    block = data.get(key)
    if isinstance(block, dict) and server_id in block:
        raise SystemExit(0)
raise SystemExit(1)
PY
            ;;
        *.toml)
            command_exists python3 || return 1
            python3 - "$config_file" "$server_id" <<'PY'
import json
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
server_id = sys.argv[2]
section_re = re.compile(r'^\s*\[mcp_servers\.(.+)\]\s*$')
for line in config_path.read_text().splitlines():
    match = section_re.match(line)
    if not match:
        continue
    raw = match.group(1).strip()
    try:
        name = json.loads(raw) if raw.startswith('"') else raw
    except Exception:
        name = raw.strip('"')
    if name == server_id:
        raise SystemExit(0)
raise SystemExit(1)
PY
            ;;
        *)
            return 1
            ;;
    esac
}

filter_missing_mcp_configs_for_file() {
    local config_file="$1"
    shift
    local missing=() item server_id
    for item in "$@"; do
        server_id="${item%%:*}"
        [[ -n "$server_id" ]] || continue
        if ! mcp_config_exists_in_file "$config_file" "$server_id"; then
            missing+=("$item")
        fi
    done
    printf '%s\n' "${missing[@]}"
}

add_all_mcp_configs_to_file() {
    local config_file="$1"
    shift
    command_exists jq || return 1
    case "$config_file" in
        *.json|*.yaml|*.yml|*.toml) ;;
        *) warn_log "暂不支持自动写入该配置格式: $config_file"; return 1 ;;
    esac
    mkdir -p "$(dirname "$config_file")"

    local gemini_mcp_schema=false
    local agy_mcp_schema=false
    case "$config_file" in
        "$HOME/.gemini/settings.json"|*/.gemini/settings.json)
            # Gemini CLI MCP server schema does not accept "enabled".
            # Each mcpServers.<name> object accepts command/args/env/cwd,
            # url/httpUrl/headers, timeout/trust/description and
            # includeTools/excludeTools. Per-server "enabled" is invalid.
            gemini_mcp_schema=true
            ;;
        "$HOME/.gemini/config/mcp_config.json"|*/.gemini/config/mcp_config.json)
            agy_mcp_schema=true
            ;;
        *)
            gemini_mcp_schema=false
            agy_mcp_schema=false
            ;;
    esac

    local servers_json
    servers_json=$(mktemp "${TMPDIR:-/tmp}/aihub-mcp.XXXXXX") || return 1
    # trap 保证函数返回时（含异常）清理临时文件
    trap "rm -f '$servers_json'" RETURN
    echo '{}' > "$servers_json"

    local server_pair server_id server_config tmp_file
    for server_pair in "$@"; do
        server_id="${server_pair%%:*}"
        server_config="${server_pair#*:}"
        [[ -z "$server_id" || -z "$server_config" ]] && continue
        server_config=$(expand_vars "$server_config")
        tmp_file="${servers_json}.tmp"
        jq --arg id "$server_id" --argjson conf "$server_config" \
            --argjson gemini "$gemini_mcp_schema" --argjson agy "$agy_mcp_schema" \
            '.[$id] = ($conf
                | if $gemini and $id == "filesystem" then
                    {
                      command: "bash",
                      args: [
                        "-lc",
                        "root=\"${AI_HUB_WORKSPACE_PATH:-${WORKSPACE_PATH:-$PWD}}\"; exec npx -y @modelcontextprotocol/server-filesystem \"$root\""
                      ],
                      env: {}
                    }
                  else . end
                | if has("args") and (.args | type == "array") then
                    .args |= map(select((type != "string") or (. != "" and (test("\\{\\{") | not))))
                  else . end
                | if has("env") and (.env | type == "object") then
                    .env |= with_entries(select((.value | type != "string") or (.value != "" and (.value | test("\\{\\{") | not))))
                  else . end
                | if ($gemini or $agy) then del(.transportType, .enabled) else del(.transportType) | .enabled = true end)' \
            "$servers_json" > "$tmp_file" && mv "$tmp_file" "$servers_json" || {
                rm -f "$tmp_file" "$servers_json"
                return 1
            }
    done

    case "$config_file" in
        *.json)
            [[ -s "$config_file" ]] || echo '{"mcpServers":{}}' > "$config_file"
            local config_lock="${config_file}.aihub.lock"
            acquire_config_lock "$config_file" || return 1
            backup_config_file "$config_file" || { release_config_lock "$config_lock"; return 1; }
            tmp_file=$(mktemp "$(dirname "$config_file")/.aihub-json.XXXXXX") || { release_config_lock "$config_lock"; return 1; }
            if jq --slurpfile servers "$servers_json" \
                '.mcpServers = (.mcpServers // {}) | .mcpServers += $servers[0]' \
                "$config_file" > "$tmp_file" && jq empty "$tmp_file" >/dev/null 2>&1; then
                mv "$tmp_file" "$config_file"
                release_config_lock "$config_lock"
                return $?
            fi
            rm -f "$tmp_file"
            release_config_lock "$config_lock"
            return 1
            ;;
        *.yaml|*.yml)
            add_mcp_configs_to_yaml_file "$config_file" "$servers_json"
            return $?
            ;;
        *.toml)
            write_codex_mcp_configs_to_toml "$config_file" "$servers_json"
            return $?
            ;;
    esac
}

install_mcp_server_package() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 1

    # 1. 检查是否已安装 (优化: 避免重复安装)
    local check_cmd
    check_cmd=$(jq -r '.status_check[]? | select(.name | contains("安装")) | .command' "$file" 2>/dev/null | head -1)
    if [[ -n "$check_cmd" && "${AI_HUB_UPDATE_PACKAGES:-0}" != "1" ]]; then
        local check_output
        check_output=$(bash -c "$(expand_vars "$check_cmd")" 2>&1 || true)
        if [[ -n "$check_output" ]] && ! printf '%s\n' "$check_output" | grep -Eqi '未安装|不可用|not found|not installed|missing|error'; then
             debug_log "MCP $server_id 已安装，跳过自动安装过程。"
             return 0
        fi
    fi

    local install_type cmd
    install_type=$(jq -r '.install.type // "npm"' "$file" 2>/dev/null)
    cmd=$(jq -r '.install.command // ""' "$file" 2>/dev/null)

    # 执行安装前预处理命令
    local pre_installs
    pre_installs=$(jq -r '.install.pre_install[]?' "$file" 2>/dev/null)
    if [[ -n "$pre_installs" ]]; then
        while IFS= read -r pi; do
            [[ -n "$pi" ]] && run_configured_command "$(expand_vars "$pi")" "安装前准备: $server_id"
        done <<< "$pre_installs"
    fi

    # 检查 prerequisites（如 Python 版本要求）
    local prereq_count
    prereq_count=$(jq '.install.prerequisites // [] | length' "$file" 2>/dev/null)
    if [[ "$prereq_count" -gt 0 ]]; then
        local _pi_name _pi_check _pi_hint _pi_pass
        _pi_pass=true
        for ((_pi_idx=0; _pi_idx<prereq_count; _pi_idx++)); do
            _pi_name=$(jq -r ".install.prerequisites[$_pi_idx].name // \"前置条件 $((_pi_idx+1))\"" "$file" 2>/dev/null)
            _pi_check=$(jq -r ".install.prerequisites[$_pi_idx].check // empty" "$file" 2>/dev/null)
            _pi_hint=$(jq -r ".install.prerequisites[$_pi_idx].install_hint // empty" "$file" 2>/dev/null)
            if [[ -n "$_pi_check" ]]; then
                if ! bash -c "$_pi_check" >/dev/null 2>&1; then
                    warn_log "MCP $server_id 前置条件不满足: $_pi_name"
                    [[ -n "$_pi_hint" ]] && warn_log "  安装建议: $_pi_hint"
                    _pi_pass=false
                fi
            fi
        done
        if [[ "$_pi_pass" != "true" ]]; then
            warn_log "MCP $server_id 因前置条件不满足，跳过自动安装（配置仍会写入）"
            return 0
        fi
    fi

    case "$install_type" in
        download|manual)
            info_log "MCP $server_id 需要手动下载/启动，本次仅写入配置，不执行自动安装。"
            local setup_line
            while IFS= read -r setup_line; do
                [[ -n "$setup_line" ]] && echo "   - $setup_line"
            done < <(jq -r '.install.setup[]?' "$file" 2>/dev/null)
            return 0
            ;;
        custom)
            [[ -n "$cmd" && "$cmd" != "null" ]] && run_configured_command "$(expand_vars "$cmd")" "安装说明 MCP: $server_id" || true
            return 0
            ;;
        app)
            [[ -z "$cmd" || "$cmd" == "null" ]] && return 0
            if run_configured_command "$(expand_vars "$cmd")" "安装 App MCP: $server_id"; then
                return 0
            fi
            warn_log "MCP $server_id 的桌面应用安装未完成，本次不作为批量失败处理。"
            return 0
            ;;
    esac

    [[ -z "$cmd" || "$cmd" == "null" ]] && return 0
    local expanded_cmd
    expanded_cmd=$(expand_vars "$cmd")
    
    # 2. 执行安装并处理错误
    local install_log
    install_log=$(mktemp "${TMPDIR:-/tmp}/ai-hub-mcp-install.XXXXXX") || return 1
    local rc
    if run_configured_command "$expanded_cmd" "安装 MCP: $server_id" 2> >(tee "$install_log" >&2); then
        rm -f "$install_log"
        return 0
    else
        rc=$?
    fi

    # 3. 仅针对 npm 目录冲突重试；E404、网络及编译错误直接返回。
    if [[ "$install_type" == "npm" || "$expanded_cmd" == *"npm install -g"* ]] && grep -Eq 'ENOTEMPTY|EEXIST' "$install_log"; then
        warn_log "MCP $server_id 安装失败 (rc=$rc)，尝试清理冲突目录并重试..."
        local pkg
        pkg=$(echo "$expanded_cmd" | sed -E 's/.*npm install -g ([^ ]+).*/\1/' | awk '{print $1}')
        local npm_root
        npm_root=$(_get_npm_root)
        if [[ -n "$npm_root" && -n "$pkg" ]]; then
            local pkg_name="$pkg"
            pkg_name="${pkg_name#npm:}"
            pkg_name="${pkg_name%%@latest}"
            if [[ "$pkg_name" != @* ]]; then
                pkg_name="${pkg_name%%@*}"
            fi
            local pkg_path="$npm_root/$pkg_name"
            if [[ -d "$pkg_path" ]]; then
                info_log "正在清理: $pkg_path"
                rm -rf "$pkg_path" 2>/dev/null || sudo rm -rf "$pkg_path" 2>/dev/null || true
            fi
            local parent_dir
            local base_name
            parent_dir=$(dirname "$pkg_path")
            base_name=$(basename "$pkg_path")
            find "$parent_dir" -maxdepth 1 -name ".${base_name}-*" -type d -exec rm -rf {} + 2>/dev/null || true
        fi
        
        info_log "正在重试安装 MCP $server_id..."
        rm -f "$install_log"
        run_configured_command "$expanded_cmd" "重试安装 MCP: $server_id"
        return $?
    fi
    rm -f "$install_log"
    return $rc
}

skill_extension_command_installed() {
    local item_json="$1"
    local env_name env_value p expanded cmd

    env_name=$(printf '%s' "$item_json" | jq -r '.check.env // empty' 2>/dev/null)
    if [[ -n "$env_name" ]]; then
        env_value="${!env_name:-}"
        [[ -n "$env_value" ]] && { expanded=$(expand_path "$env_value"); [[ -x "$expanded" || -f "$expanded" ]] && return 0; }
    fi

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        expanded=$(expand_path "$p")
        [[ -x "$expanded" || -f "$expanded" ]] && return 0
    done < <(printf '%s' "$item_json" | jq -r '.check.paths // [] | .[]' 2>/dev/null)

    cmd=$(printf '%s' "$item_json" | jq -r '.check.command // empty' 2>/dev/null)
    [[ -n "$cmd" ]] && command_exists "${cmd%% *}" && return 0

    return 1
}

skill_missing_recommended_extension_count() {
    local skill_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills/${skill_id}.json"
    [[ -f "$file" ]] || { echo 0; return 0; }
    local count=0 item
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if ! skill_extension_command_installed "$item"; then
            count=$((count + 1))
        fi
    done < <(jq -c '.recommended_extension_commands // [] | .[]' "$file" 2>/dev/null)
    echo "$count"
}

install_skill_extension_command() {
    local item_json="$1"
    local name cmd os_key
    name=$(printf '%s' "$item_json" | jq -r '.name // .id // "扩展命令"' 2>/dev/null)
    case "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
        darwin*) os_key="darwin" ;;
        linux*) os_key="linux" ;;
        *) os_key="default" ;;
    esac
    cmd=$(printf '%s' "$item_json" | jq -r --arg os "$os_key" '.install[$os] // .install.default // .install.command // empty' 2>/dev/null)
    [[ -z "$cmd" || "$cmd" == "null" ]] && { warn_log "未定义 $name 的安装命令"; return 1; }
    run_configured_command "$(expand_vars "$cmd")" "安装 Skill 扩展命令: $name"
}

prompt_skill_extension_commands() {
    local skill_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills/${skill_id}.json"
    [[ -f "$file" ]] || return 0
    jq -e '.recommended_extension_commands and (.recommended_extension_commands | length > 0)' "$file" >/dev/null 2>&1 || return 0

    local missing_items=() item name desc
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        skill_extension_command_installed "$item" || missing_items+=("$item")
    done < <(jq -c '.recommended_extension_commands // [] | .[]' "$file" 2>/dev/null)

    [[ ${#missing_items[@]} -eq 0 ]] && return 0

    echo -e "\n${YELLOW}检测到该 Skill 有推荐扩展命令尚未安装，正在自动安装：${NC}"
    for item in "${missing_items[@]}"; do
        name=$(printf '%s' "$item" | jq -r '.name // .id // "扩展命令"' 2>/dev/null)
        desc=$(printf '%s' "$item" | jq -r '.description // ""' 2>/dev/null)
        echo -e "  - ${BLUE}${name}${NC}${desc:+：$desc}"
    done

    for item in "${missing_items[@]}"; do
        name=$(printf '%s' "$item" | jq -r '.name // .id // "扩展命令"' 2>/dev/null)
        install_skill_extension_command "$item" && success_log "$name 已安装或安装命令已执行" || warn_log "$name 安装失败或被跳过"
    done
}

prompt_extension_commands_for_skills() {
    local sid
    for sid in "$@"; do
        [[ -n "$sid" ]] && prompt_skill_extension_commands "$sid"
    done
}

install_skill() {
    local skill_id="$1"
    local prompt_extensions="${2:-false}"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills/${skill_id}.json"
    [[ -f "$file" ]] || return 1
    local dest="${AI_HUB_SKILLS_DIR:-$HOME/.ai-hub/skills}"
    mkdir -p "$dest" || return 1
    cp "$file" "$dest/${skill_id}.json" || return 1

    install_hermes_skill_from_aihub_json "$file" || return 1
    if [[ "$prompt_extensions" == "true" || "$prompt_extensions" == "prompt" ]]; then
        prompt_skill_extension_commands "$skill_id" || return 1
    fi
    return 0
}

skill_target_kind() {
    local tool_id="$1"
    local tool_name="$2"

    case "$tool_id" in
        gemini|gemini-cli|antigravity) echo "antigravity" ;;
        claude|claude-code) echo "claude" ;;
        hermes|hermes-agent) echo "hermes" ;;
        codex|codex-cli) echo "codex" ;;
        opencode|opencode-ai) echo "opencode" ;;
        qwen|qwen-code|qwen-cli) echo "qwen" ;;
        *)
            case "$tool_name" in
                *Gemini*|*Antigravity*) echo "antigravity" ;;
                *Claude*) echo "claude" ;;
                *Hermes*) echo "hermes" ;;
                *Codex*) echo "codex" ;;
                *OpenCode*) echo "opencode" ;;
                *Qwen*) echo "qwen" ;;
                *) echo "fallback" ;;
            esac
            ;;
    esac
}

skill_target_dir() {
    local kind="$1"
    case "$kind" in
        antigravity) echo "$HOME/.gemini/skills" ;;
        claude) echo "$HOME/.claude/skills" ;;
        hermes) echo "$HOME/.hermes/skills/ai-hub" ;;
        codex) echo "$HOME/.codex/skills/ai-hub" ;;
        opencode) echo "$HOME/.config/opencode/skills" ;;
        qwen) echo "$HOME/.qwen/skills" ;;
        *) echo "$HOME/.ai-hub/generated-skills" ;;
    esac
}

render_skill_markdown() {
    local file="$1"
    local kind="${2:-generic}"
    command_exists jq || return 1
    [[ -f "$file" ]] || return 1

    local sid sname sdesc scat tips notes homepage
    sid=$(jq -r '.id // empty' "$file")
    sname=$(jq -r '.name // .id // empty' "$file")
    sdesc=$(jq -r '.description // ""' "$file")
    scat=$(jq -r '.category // "ai-hub"' "$file")
    tips=$(jq -r '.tips // ""' "$file")
    notes=$(jq -r '.notes // ""' "$file")
    homepage=$(jq -r '.homepage // ""' "$file")
    [[ -z "$sid" ]] && return 1

    if [[ "$kind" == "hermes" ]]; then
        echo "---"
        echo "name: $sid"
        printf 'description: "%s"\n' "$(printf '%s' "$sdesc" | sed 's/"/\\"/g')"
        echo "version: 1.0.0"
        echo "author: AI Hub"
        echo "license: MIT"
        echo "metadata:"
        echo "  hermes:"
        echo "    tags: [$scat, ai-hub]"
        echo "---"
        echo ""
    else
        echo "---"
        echo "name: $sid"
        printf 'description: "%s"\n' "$(printf '%s' "$sdesc" | sed 's/"/\\"/g')"
        echo "---"
        echo ""
    fi

    echo "# $sname"
    echo ""
    [[ -n "$sdesc" ]] && { echo "$sdesc"; echo ""; }
    echo "## When to Use"
    echo ""
    echo "Use this skill when the user request matches the following AI Hub capability:"
    echo ""
    echo "- Skill ID: \`$sid\`"
    echo "- Category: \`$scat\`"
    [[ -n "$tips" ]] && echo "- Tips: $tips"
    [[ -n "$homepage" ]] && echo "- Homepage: $homepage"
    echo ""
    echo "## Workflow"
    echo ""
    echo "Follow this skill's method explicitly. Apply the prompts, checks, and expected deliverables below."
    echo ""
    if jq -e '.prompts and (.prompts | length > 0)' "$file" >/dev/null 2>&1; then
        echo "## Prompts and Procedures"
        echo ""
        jq -r '.prompts | to_entries[] | "### \(.key)\n\n\(.value)\n"' "$file"
    fi
    if jq -e '.capabilities and (.capabilities | length > 0)' "$file" >/dev/null 2>&1; then
        echo "## Capabilities"
        echo ""
        jq -r '.capabilities[] | "- \(.)"' "$file"
        echo ""
    fi
    if jq -e '.dependencies and (.dependencies | length > 0)' "$file" >/dev/null 2>&1; then
        local deps
        deps=$(jq -r '.dependencies | to_entries[] | select((.value | if type == "array" then length > 0 else tostring != "" end)) | "- \(.key): \(.value | if type == "array" then join(", ") else tostring end)"' "$file")
        if [[ -n "$deps" ]]; then
            echo "## Dependencies"
            echo ""
            printf '%s\n' "$deps"
            echo ""
        fi
    fi
    if jq -e '.recommended_extension_commands and (.recommended_extension_commands | length > 0)' "$file" >/dev/null 2>&1; then
        echo "## Recommended Extension Commands"
        echo ""
        echo "These commands are optional local dependencies. Install only when the task requires the related local capability."
        echo ""
        jq -r '.recommended_extension_commands[] | "- \(.name // .id): \(.description // "")"' "$file"
        echo ""
    fi
    [[ -n "$notes" ]] && { echo "## Notes"; echo ""; echo "$notes"; echo ""; }
    echo "## Output Quality Bar"
    echo ""
    echo "- Produce concrete, reviewable artifacts instead of generic advice."
    echo "- State assumptions, risks, open questions, and validation criteria."
    echo "- If the task modifies files, update the relevant documents directly."
}

install_skill_for_target() {
    local skill_id="$1"
    local kind="$2"
    local custom_dest_root="${3:-}"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/skills/${skill_id}.json"
    [[ -f "$file" ]] || return 1

    local dest_root dest_dir dest_file
    if [[ -n "$custom_dest_root" ]]; then
        dest_root=$(expand_path "$custom_dest_root")
    else
        dest_root=$(skill_target_dir "$kind")
    fi
    dest_dir="$dest_root/$skill_id"
    dest_file="$dest_dir/SKILL.md"
    mkdir -p "$dest_dir"

    render_skill_markdown "$file" "$kind" > "$dest_file"
    cp "$file" "$dest_dir/ai-hub-config.json"
}

install_skills_for_target() {
    local tool_id="$1"
    local tool_name="$2"
    shift 2

    local kind
    kind=$(skill_target_kind "$tool_id" "$tool_name")
    [[ "$kind" == "fallback" ]] && return 0

    local sid
    for sid in "$@"; do
        [[ -n "$sid" ]] || continue
        install_skill_for_target "$sid" "$kind" || return 1
    done
}

install_skills_for_profile_target() {
    local tool_id="$1"
    local tool_name="$2"
    local kind="$3"
    local dest_root="$4"
    shift 4

    [[ -n "$kind" && "$kind" != "fallback" ]] || kind=$(skill_target_kind "$tool_id" "$tool_name")
    [[ "$kind" == "fallback" ]] && return 0

    local sid
    for sid in "$@"; do
        [[ -n "$sid" ]] || continue
        install_skill_for_target "$sid" "$kind" "$dest_root" || return 1
    done
}

skill_config_exists_for_profile_target() {
    local kind="$1"
    local dest_root="$2"
    local skill_id="$3"
    [[ -n "$kind" && "$kind" != "fallback" ]] || kind="fallback"
    [[ "$kind" == "fallback" ]] && return 1
    if [[ -n "$dest_root" ]]; then
        dest_root=$(expand_path "$dest_root")
    else
        dest_root=$(skill_target_dir "$kind")
    fi
    [[ -f "$dest_root/$skill_id/SKILL.md" ]]
}

filter_missing_skills_for_profile_target() {
    local kind="$1"
    local dest_root="$2"
    shift 2
    local missing=() sid
    for sid in "$@"; do
        [[ -n "$sid" ]] || continue
        if ! skill_config_exists_for_profile_target "$kind" "$dest_root" "$sid"; then
            missing+=("$sid")
        fi
    done
    printf '%s\n' "${missing[@]}"
}

install_hermes_skill_from_aihub_json() {
    local file="$1"
    command_exists jq || return 0
    [[ -f "$file" ]] || return 1
    [[ -d "$HOME/.hermes/skills" ]] || return 0

    local sid target_dir target_file
    sid=$(jq -r '.id // empty' "$file")
    [[ -z "$sid" ]] && return 1

    target_dir="$HOME/.hermes/skills/ai-hub/$sid"
    target_file="$target_dir/SKILL.md"
    mkdir -p "$target_dir"

    render_skill_markdown "$file" "hermes" > "$target_file"
    cp "$file" "$target_dir/ai-hub-config.json"
}

manage_mcp_servers_menu() {
    local opts=()
    local ids=()
    local m idx=0
    for m in "${mcp_servers[@]}"; do
        local id="${m%%:*}"
        local rest="${m#*:}"
        local name="${rest%%:*}"
        local status_text="未安装"
        if is_mcp_server_installed "$id"; then
            status_text="已安装"
            opts+=("${GREEN}✅ ${name}${NC} ($id) - $status_text")
        else
            opts+=("${YELLOW}⚠️ ${name}${NC} ($id) - $status_text")
        fi
        ids+=("$id")
        idx=$((idx + 1))
    done
    [[ ${#opts[@]} -eq 0 ]] && { warn_log "没有可用的 MCP 服务器配置"; return 0; }

    local res
    res=$(menu_select "🔧 MCP 服务器（按需勾选）" "true" "true" "" "" "" "${opts[@]}")
    [[ "$res" == "EXIT" || -z "$res" ]] && return 0

    local targets=()
    local names=()
    local _cname _cconf
    while IFS=$'\t' read -r _cname _cconf; do
        [[ -n "$_cname" && -n "$_cconf" ]] || continue
        config_path_in_list "$_cconf" "${targets[@]}" && continue
        targets+=("$_cconf")
        names+=("$_cname")
    done < <(collect_mcp_config_targets)

    [[ ${#targets[@]} -eq 0 ]] && { warn_log "未发现支持 MCP 写入的工具/profile 配置"; return 1; }

    local selected_configs=()
    local selected_ids=()
    local skipped_mcps=()
    local sel_idx
    for sel_idx in $res; do
        local id="${ids[$sel_idx]}"
        [[ -n "$id" ]] && selected_ids+=("$id")
    done

    filter_mcps_by_env selected_ids
    skipped_mcps=("${FILTERED_MCP_SKIPPED[@]}")

    for id in "${selected_ids[@]}"; do
        local conf
        prepare_mcp_server_if_needed "$id"
        conf=$(get_server_config "$id")
        [[ -n "$conf" ]] && selected_configs+=("$id:$conf")
    done
    [[ ${#selected_configs[@]} -gt 0 || ${#skipped_mcps[@]} -gt 0 ]] || { warn_log "未匹配到可同步的 MCP 配置"; return 1; }

    echo -e "${YELLOW}将把 ${#selected_configs[@]} 个 MCP 配置同步到 ${#targets[@]} 个工具/profile 配置，并安装缺失的 MCP 包。${NC}"
    read -p "确认同步？(y/N): " confirm_sync
    [[ "$confirm_sync" == "y" || "$confirm_sync" == "Y" ]] || return 0

    for i in "${!targets[@]}"; do
        echo -ne "   ➜ 同步 ${names[$i]} ... "
        if [[ ${#skipped_mcps[@]} -gt 0 ]]; then
            remove_mcp_configs_from_file "${targets[$i]}" "${skipped_mcps[@]}" >/dev/null 2>&1 || true
        fi
        add_all_mcp_configs_to_file "${targets[$i]}" "${selected_configs[@]}" && echo "成功" || echo "失败"
    done
    for id in "${selected_ids[@]}"; do install_mcp_server_package "$id"; done
}

manage_mcp_servers() {
    manage_mcp_servers_menu
}

# 从 MCP 安装命令中提取包名（供卸载使用）
extract_mcp_pkg_from_install_cmd() {
    local type="$1"
    local cmd="$2"
    [[ -n "$cmd" && "$cmd" != "null" ]] || return 0
    case "$type" in
        npm)
            sed -nE 's/.*npm install -g ([^ ]+).*/\1/p' <<< "$cmd" | cut -d' ' -f1
            ;;
        brew|app)
            sed -nE 's/.*brew install( --cask)? ([^ ;|&]+).*/\2/p' <<< "$cmd" | cut -d' ' -f1
            ;;
        pip|pip_official)
            sed -nE 's/.*pip(3)? install( -[^ ]+ +)?([^ ;|&]+).*/\3/p' <<< "$cmd" | cut -d' ' -f1
            ;;
        uv)
            sed -nE 's/.*uv tool install ([^ ]+).*/\1/p' <<< "$cmd" | cut -d' ' -f1
            ;;
    esac
}

# 卸载指定 MCP 服务器的软件包（安装命令对应的包）
uninstall_mcp_server_package() {
    local server_id="$1"
    local file="${CONFIG_DIR_PATH:-$SCRIPT_DIR/conf}/shared/mcp-servers/${server_id}.json"
    [[ -f "$file" ]] || return 0

    local install_type cmd pkg
    install_type=$(jq -r '.install.type // ""' "$file" 2>/dev/null)
    cmd=$(jq -r '.install.command // ""' "$file" 2>/dev/null)
    [[ -z "$install_type" || "$install_type" == "custom" || "$install_type" == "manual" || "$install_type" == "download" ]] && return 0

    pkg=$(extract_mcp_pkg_from_install_cmd "$install_type" "$cmd")
    [[ -n "$pkg" ]] || return 0
    if [[ "$install_type" == "npm" && "$cmd" != *"npm install -g"* ]]; then
        return 0
    fi

    local un_cmd=""
    case "$install_type" in
        npm)         un_cmd="npm uninstall -g '$pkg' 2>/dev/null" ;;
        brew)        un_cmd="brew uninstall --cask '$pkg' 2>/dev/null || brew uninstall '$pkg' 2>/dev/null" ;;
        pip|pip_official) un_cmd="pip3 uninstall -y '$pkg' 2>/dev/null" ;;
        uv)          un_cmd="uv tool uninstall '$pkg' 2>/dev/null" ;;
        *)           return 0 ;;
    esac

    # 未安装对应包时直接跳过，不当作错误
    local check_found=false
    case "$install_type" in
        npm)  npm list -g "$pkg" >/dev/null 2>&1 && check_found=true ;;
        brew) brew list --cask "$pkg" >/dev/null 2>&1 && check_found=true ;;
        pip)  pip3 show "$(printf '%s' "$pkg" | sed 's/==.*//')" >/dev/null 2>&1 && check_found=true ;;
        uv)   uv tool list 2>/dev/null | grep -qF "$pkg" && check_found=true ;;
    esac
    [[ "$check_found" == "true" ]] || return 0

    info_log "➜ 卸载 MCP 软件包: $pkg"
    eval "$un_cmd"
}

# 一键卸载 MCP：从所有已发现的客户端配置文件移除，并卸载对应软件包
# 用法: remove_mcp_servers_cli <id1[,id2,...]>
remove_mcp_servers_cli() {
    local ids_csv="$1"
    command_exists jq || { error_log "--remove-mcp 需要 jq 支持"; return 1; }
    if [[ -z "$ids_csv" ]]; then
        error_log "用法: $0 --remove-mcp <mcp_id[,mcp_id...]>"
        return 2
    fi

    local want=() id
    IFS=',' read -ra want <<< "$ids_csv"
    [[ ${#want[@]} -gt 0 ]] || { error_log "未提供任何 MCP id"; return 2; }

    local valid_ids=() missing=()
    for id in "${want[@]}"; do
        [[ -n "$id" ]] || continue
        id=$(echo "$id" | xargs)
        if is_id_in_words "$id" "${MCP_SERVERS_NAMES[@]}"; then
            valid_ids+=("$id")
        else
            missing+=("$id")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn_log "MCP 配置目录中未找到，跳过: ${missing[*]}"
    fi
    [[ ${#valid_ids[@]} -gt 0 ]] || { error_log "没有可卸载的 MCP 服务器"; return 1; }

    # 1. 收集所有已发现客户端配置文件
    local targets=() names=() _cname _cconf
    while IFS=$'\t' read -r _cname _cconf; do
        [[ -n "$_cname" && -n "$_cconf" ]] || continue
        config_path_in_list "$_cconf" "${targets[@]}" && continue
        targets+=("$_cconf")
        names+=("$_cname")
    done < <(collect_mcp_config_targets)

    local removed=0 failed=0 i target
    for i in "${!targets[@]}"; do
        target="${targets[$i]}"
        if remove_mcp_configs_from_file "$target" "${valid_ids[@]}" >/dev/null 2>&1; then
            info_log "已从 ${names[$i]} ($target) 移除 MCP: ${valid_ids[*]}"
            removed=$((removed + 1))
        else
            warn_log "从 ${names[$i]} ($target) 移除 MCP 失败"
            failed=$((failed + 1))
        fi
    done

    # 2. 卸载软件包（幂等：未安装则跳过）
    for id in "${valid_ids[@]}"; do
        uninstall_mcp_server_package "$id"
    done

    success_log "完成: ${#valid_ids[@]} 个 MCP 从 ${removed} 个客户端配置移除 (失败 ${failed})"
    return 0
}
manage_skills() {
    echo -e "\n${CYAN}🎯 Skills 技能管理${NC}"
    local opts=() ids=() idx=0
    local s sid sname sd sc
    for s in "${SKILLS[@]}"; do
        IFS='|' read -r sid sname sd sc <<< "$s"
        ids+=("$sid")
        if is_skill_installed "$sid"; then
            local missing_ext
            missing_ext=$(skill_missing_recommended_extension_count "$sid")
            if [[ "$missing_ext" -gt 0 ]]; then
                opts+=("${GREEN}✅ ${sname}${NC} [$sc] - 已安装，推荐扩展缺失: ${missing_ext}")
            else
                opts+=("${GREEN}✅ ${sname}${NC} [$sc] - 已安装")
            fi
        else
            local ext_hint=""
            [[ "$(skill_missing_recommended_extension_count "$sid")" -gt 0 ]] && ext_hint="，含推荐扩展命令"
            opts+=("${YELLOW}⚠️ ${sname}${NC} [$sc] - 未安装${ext_hint}")
        fi
        idx=$((idx + 1))
    done
    [[ ${#opts[@]} -eq 0 ]] && { warn_log "没有可用技能"; return 0; }
    local res
    res=$(menu_select "可用技能（按需勾选）" "true" "true" "" "" "" "${opts[@]}")
    [[ "$res" == "EXIT" || -z "$res" ]] && return
    local selected
    for selected in $res; do
        sid="${ids[$selected]}"
        [[ -z "$sid" ]] && continue
        if is_skill_installed "$sid"; then
            info_log "跳过已安装技能: $sid"
            prompt_skill_extension_commands "$sid"
            continue
        fi
        echo -e "\n${BLUE}正在安装技能: $sid${NC}"
        install_skill "$sid" "prompt" && success_log "已安装" || error_log "失败"
    done
    read -p "按回车返回..."
}

manage_ai_docs() { info_log "管理文档功能暂通过交互菜单直接调用库函数"; }

show_help() {
    # 帮助页也展示当前工具清单；main 在处理 --help 时尚未初始化配置。
    if [[ ${#TOOLS[@]} -eq 0 ]]; then
        init_config
    fi
    echo -e "${BOLD}AI 工具中枢 (AI Hub) - 极致优化版${NC}"
    echo "=========================================="
    echo ""
    echo -e "${YELLOW}用法:${NC}"
    echo "  交互模式:"
    echo "    $0              # 启动交互式标签页菜单"
    echo ""
    echo "  快捷入口 (非交互式):"
    echo "    $0 -m, --mcp      # 直接进入 MCP 服务器管理"
    echo "    $0 -s, --skills   # 直接进入 Skills 技能管理"
    echo "    $0 -d, --docs     # 直接进入 AI 文档管理"
    echo ""
    echo "  非交互式批量配置:"
    echo "    $0 --batch-apply <targets> [--tags <tags>] [--update-configs]"
    echo "    <targets>  可选。指定具有 JSON/YAML/TOML 配置文件的客户端 ID，多个目标用逗号或空格分隔（如: 'codex cursor'）。"
    echo "    --tags     可选。指定要应用的标签，多个标签用逗号分隔（如: 'QA,测试'）。不指定则全量下发。"
    echo "    --update-configs 覆盖更新已写入的 MCP/Skills 配置。默认跳过已配置项。"
    echo "    --update-packages 重新执行 MCP 安装命令以更新 npm/PyPI 等包。默认已安装则跳过。"
    echo "    AI_HUB_CONFIG_PROMPT_TIMEOUT 控制交互式变量输入超时秒数，默认 30。"
    echo "    例如: $0 --batch-apply cursor --tags 'design,coding'"
    echo ""
    echo "  非交互式安装工具:"
    echo "    $0 -i <targets>"
    echo "    -i, --install     安装一个或多个 CLI、IDE、Agent 或 MCP 插件。多个目标用空格分隔。"
    echo "    例如: $0 -i codex antigravity"
    echo ""
    echo "  额外 profile:"
    echo "    默认发现 ~/.codex-token173/config.toml、~/.qwen-studio/settings.json、~/qwen-studio/settings.json"
    echo "    AI_HUB_INCLUDE_EXTRA_PROFILES=0 可关闭默认发现"
    echo "    AI_HUB_EXTRA_PROFILE_TARGETS='id|name|kind|config|skills_dir;...' 可追加目标"
    echo "    kind 支持 codex、opencode、qwen、claude、antigravity、hermes"
    echo ""
    echo "  工具操作 (命令行模式):"
    echo "    $0 -u, --uninstall <ID> # 卸载指定工具"
    echo "    $0 --remove-mcp <id[,id...]>  # 卸载 MCP 并从所有已安装 AI 客户端配置移除"
    echo "    $0 --update <ID>        # 更新指定工具"
    echo "    $0 --status <ID>        # 查看工具状态"
    echo "    $0 -c, --config <ID>    # 查看工具配置"
    echo ""
    echo -e "${YELLOW}当前可用工具:${NC}"
    for t in "${TOOLS[@]}"; do parse_tool_data "$t" "H"; printf "  - %-18s (%s)\n" "$H_id" "$H_name"; done
    echo ""
    echo -e "${BLUE}[提示]${NC} 推荐在交互模式下使用 ← / → 切换分类。"
    exit 0
}

acquire_non_interactive_lock() {
    local purpose="${1:-非交互任务}"
    BATCH_LOCK_DIR="${TMPDIR:-/tmp}/ai-hub-batch-${UID:-$(id -u)}.lock"
    if ! mkdir "$BATCH_LOCK_DIR" 2>/dev/null; then
        local lock_pid=""
        [[ -f "$BATCH_LOCK_DIR/pid" ]] && lock_pid=$(cat "$BATCH_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
            error_log "已有非交互任务正在运行（PID: ${lock_pid}），无法开始: $purpose"
            BATCH_LOCK_DIR=""
            return 1
        fi
        rm -f "$BATCH_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$BATCH_LOCK_DIR" 2>/dev/null || true
        mkdir "$BATCH_LOCK_DIR" 2>/dev/null || {
            error_log "无法创建非交互任务锁: $BATCH_LOCK_DIR"
            BATCH_LOCK_DIR=""
            return 1
        }
    fi
    printf '%s\n' "$$" > "$BATCH_LOCK_DIR/pid"
}

append_csv_value() {
    local current="$1"
    local value="$2"
    [[ -z "$value" ]] && { printf '%s' "$current"; return; }
    [[ -n "$current" ]] && printf '%s,%s' "$current" "$value" || printf '%s' "$value"
}

non_interactive_install_tools() {
    local targets_raw="$1"
    [[ -n "$targets_raw" ]] || {
        error_log "非交互安装需要通过 --target 指定至少一个工具。"
        error_log "示例: $0 --install --target codex,antigravity"
        return 2
    }

    acquire_non_interactive_lock "安装工具: $targets_raw" || return 1
    export AI_HUB_NON_INTERACTIVE=1
    export BATCH_MODE=1
    # 安装命令来自仓库内受控工具定义，允许变量赋值、条件语句等复合命令。
    export AI_HUB_ALLOW_CUSTOM_CMD=1

    local requested_targets=()
    local normalized_raw="${targets_raw//,/ }"
    local requested
    for requested in $normalized_raw; do
        [[ -n "$requested" ]] || continue
        is_id_in_words "$requested" "${requested_targets[@]}" || requested_targets+=("$requested")
    done
    [[ ${#requested_targets[@]} -gt 0 ]] || { error_log "未解析到有效安装目标。"; return 2; }

    local resolved_indices=() resolved_mcps=() unknown_targets=()
    local i found m
    for requested in "${requested_targets[@]}"; do
        found=false
        for i in "${!TOOLS[@]}"; do
            parse_tool_data "${TOOLS[$i]}" "NIT"
            if [[ "$requested" == "$NIT_id" || "$requested" == "$NIT_cmd" ]]; then
                is_id_in_words "$i" "${resolved_indices[@]}" || resolved_indices+=("$i")
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            for m in "${MCP_SERVERS_NAMES[@]}"; do
                if [[ "$requested" == "$m" ]]; then
                    is_id_in_words "$m" "${resolved_mcps[@]}" || resolved_mcps+=("$m")
                    found=true
                    break
                fi
            done
        fi
        [[ "$found" == "true" ]] || unknown_targets+=("$requested")
    done

    echo -e "${CYAN}🚀 开始非交互式安装 AI 工具...${NC}"
    echo "   请求目标: ${#requested_targets[@]}"
    echo "   有效目标: $(( ${#resolved_indices[@]} + ${#resolved_mcps[@]} )) (CLI/Agent: ${#resolved_indices[@]}, MCP: ${#resolved_mcps[@]})"
    [[ ${#unknown_targets[@]} -gt 0 ]] && echo -e "   ${YELLOW}未知目标: ${unknown_targets[*]}${NC}"

    local install_ok=0 install_failed=0 install_manual=0
    local successful_ids=() failed_ids=() manual_ids=()
    local idx current=0 total=$(( ${#resolved_indices[@]} + ${#resolved_mcps[@]} ))
    for idx in "${resolved_indices[@]}"; do
        current=$((current + 1))
        parse_tool_data "${TOOLS[$idx]}" "NII"
        echo -e "\n${BLUE}[$current/$total] ${NII_name} (${NII_id}, ${NII_cat:-其他})${NC}"
        local install_definition=""
        [[ -n "$NII_file" && -f "$NII_file" ]] && install_definition=$(jq -r '.install.methods[0].command // empty' "$NII_file" 2>/dev/null)
        if [[ "$install_definition" == *"open http"* && "$install_definition" != *"curl "* && "$install_definition" != *"wget "* && "$install_definition" != *"brew "* && "$install_definition" != *"hdiutil "* ]]; then
            warn_log "$NII_name 仅提供下载页面，非交互模式无法确认安装完成，已跳过。"
            install_manual=$((install_manual + 1))
            manual_ids+=("$NII_id")
            continue
        fi
        if operate_tool "$idx" "install" </dev/null; then
            install_ok=$((install_ok + 1))
            successful_ids+=("$NII_id")
        else
            install_failed=$((install_failed + 1))
            failed_ids+=("$NII_id")
        fi
    done

    for m in "${resolved_mcps[@]}"; do
        current=$((current + 1))
        echo -e "\n${BLUE}[$current/$total] 安装 MCP 服务器: $m${NC}"
        if install_mcp_server_package "$m"; then
            install_ok=$((install_ok + 1))
            successful_ids+=("$m")
        else
            install_failed=$((install_failed + 1))
            failed_ids+=("$m")
        fi
    done

    echo -e "\n📊 非交互式安装结果"
    echo "   请求: ${#requested_targets[@]}，有效: ${total}，成功: ${install_ok}，失败: ${install_failed}，需手动: ${install_manual}，未知: ${#unknown_targets[@]}"
    [[ ${#successful_ids[@]} -gt 0 ]] && echo -e "   ${GREEN}成功: ${successful_ids[*]}${NC}"
    [[ ${#failed_ids[@]} -gt 0 ]] && echo -e "   ${RED}失败: ${failed_ids[*]}${NC}"
    [[ ${#manual_ids[@]} -gt 0 ]] && echo -e "   ${YELLOW}需手动安装: ${manual_ids[*]}${NC}"
    [[ ${#unknown_targets[@]} -gt 0 ]] && echo -e "   ${YELLOW}未知: ${unknown_targets[*]}${NC}"

    [[ $install_failed -eq 0 && $install_manual -eq 0 && ${#unknown_targets[@]} -eq 0 ]]
}

non_interactive_batch() {
    local b_tags="$1"
    local b_targets="$2"

    echo -e "${CYAN}🚀 开始非交互式批量应用配置...${NC}"

    acquire_non_interactive_lock "批量应用 MCP/Skills 配置" || return 1
    export AI_HUB_NON_INTERACTIVE=1

    if [[ -n "$b_targets" && "$b_targets" != "all" && "$b_targets" != "*" ]]; then
        local normalized_targets=()
        local requested target_found i
        IFS=',' read -ra requested_targets <<< "$b_targets"
        for requested in "${requested_targets[@]}"; do
            target_found=false
            for i in "${!TOOLS[@]}"; do
                parse_tool_data "${TOOLS[$i]}" "NBT"
                if [[ "$requested" == "$NBT_id" || "$requested" == "$NBT_cmd" ]]; then
                    target_found=true
                    if ! is_batch_config_target "$NBT_cat" "$NBT_conf"; then
                        error_log "target '$requested' 对应 ${NBT_name}，但不支持 MCP/Skills 批量写入。"
                        error_log "当前配置路径不是受支持的 JSON/YAML/TOML 文件: ${NBT_conf:-<未配置>}"
                        return 1
                    fi
                    normalized_targets+=("$NBT_id")
                    break
                fi
            done
            [[ "$target_found" == "true" ]] || normalized_targets+=("$requested")
        done
        b_targets=$(IFS=','; echo "${normalized_targets[*]}")
    fi

    local selected_tags=()
    local selected_mcps=()
    local selected_skills=()
    local item rt
    if [[ -z "$b_tags" || "$b_tags" == "all" || "$b_tags" == "*" ]]; then
        selected_mcps=("${MCP_SERVERS_NAMES[@]}")
        for item in "${SKILLS[@]}"; do
            [[ -n "$item" ]] && selected_skills+=("${item%%|*}")
        done
    else
        IFS=',' read -ra raw_tags <<< "$b_tags"
        for rt in "${raw_tags[@]}"; do
            selected_tags+=("$(canonical_tag "$rt")")
        done
        selected_mcps=($(find_items_by_tags "mcp-servers" "${selected_tags[@]}"))
        selected_skills=($(find_items_by_tags "skills" "${selected_tags[@]}"))
    fi
    merge_skill_dependency_mcps selected_mcps "${selected_skills[@]}"

    if [[ ${#selected_mcps[@]} -eq 0 && ${#selected_skills[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未找到匹配标签的任何 MCP 或 Skills。${NC}"
        return 1
    fi

    export AI_HUB_BATCH_CONFIRM="true"
    export AI_HUB_BATCH_TARGETS_RAW="${b_targets:-all}"

    batch_apply_selected_configs "非交互式标签精细配置" "${selected_mcps[@]}" -- "${selected_skills[@]}"
}

# ==================== 8. 主流程 ====================

main() {
    case " $* " in
        *" --install "*|*" -i "*|*" --install="*) export AI_HUB_NON_INTERACTIVE=1 ;;
    esac
    check_dependencies
    local ostty=""; [[ -t 0 ]] && ostty=$(stty -g 2>/dev/null)
    trap 'if [[ -n "$BATCH_LOCK_DIR" ]]; then rm -f "$BATCH_LOCK_DIR/pid" 2>/dev/null; rmdir "$BATCH_LOCK_DIR" 2>/dev/null; fi; if [[ -n "$CONFIG_LOCK_DIR" ]]; then rm -f "$CONFIG_LOCK_DIR/pid" 2>/dev/null; rmdir "$CONFIG_LOCK_DIR" 2>/dev/null; fi; [[ -n "$ostty" ]] && stty "$ostty" 2>/dev/null; exit' INT TERM EXIT

    local log="quiet"; local dm=""; local op=""; local tgt=""; local want_help=false; local do_validate=false
    local do_batch=false; local do_install=false; local batch_tags=""; local targets_raw=""
    local remove_mcp_ids=""
    local positional_args=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log-level=*) log="${1#*=}" ;;
            -m|--mcp) dm="mcp" ;;
            -s|--skills) dm="skills" ;;
            -d|--docs) dm="docs" ;;
            -u|--uninstall) op="uninstall" ;;
            --update) op="update" ;;
            --status) op="status" ;;
            -c|--config) op="config" ;;
            --remove-mcp) remove_mcp_ids="${2:-}"; shift ;;
            --remove-mcp=*) remove_mcp_ids="${1#*=}" ;;
            -i|--install) do_install=true ;;
            --install=*) do_install=true; positional_args+=("${1#*=}") ;;
            -h|--help) want_help=true ;;
            --validate) do_validate=true ;;
            --batch-apply) do_batch=true ;;
            --update-configs) export AI_HUB_UPDATE_CONFIGS=1 ;;
            --update-packages) export AI_HUB_UPDATE_PACKAGES=1 ;;
            --tags)
                [[ -n "${2:-}" ]] || { error_log "--tags 缺少参数"; return 2; }
                batch_tags="$2"
                shift
                ;;
            --tags=*) batch_tags="${1#*=}" ;;
            -*) error_log "未知参数: $1"; return 2 ;;
            *) positional_args+=("$1") ;;
        esac
        shift
    done

    if [[ ${#positional_args[@]} -gt 0 ]]; then
        local p
        for p in "${positional_args[@]}"; do targets_raw=$(append_csv_value "$targets_raw" "$p"); done
        tgt="${positional_args[0]}"
    fi

    set_log_level "$log"
    [[ "$want_help" == true ]] && { show_help; return 0; }
    init_config

    if [[ -n "$targets_raw" && "$do_batch" == false && "$do_install" == false && -z "$op" && -z "$dm" ]]; then
        error_log "提供了目标参数但在非交互模式下必须搭配动作参数 (如 -i, -u, --batch-apply 等)"
        exit 2
    fi
    if [[ -n "$batch_tags" && "$do_batch" == false ]]; then
        error_log "--tags 必须与 --batch-apply 一起使用"
        exit 2
    fi
    
    if [[ -n "$remove_mcp_ids" ]]; then
        [[ "$do_batch" == false && "$do_install" == false && -z "$op" && -z "$dm" ]] || { error_log "--remove-mcp 不能与 -i/-u/--batch-apply/-m 等同用"; exit 2; }
        remove_mcp_servers_cli "$remove_mcp_ids"
        exit $?
    fi
    
    if [[ "$do_batch" == true ]]; then
        [[ "$do_install" == false ]] || { error_log "--install 不能与 --batch-apply 同时使用"; exit 2; }
        non_interactive_batch "$batch_tags" "$targets_raw"
        exit $?
    fi

    if [[ "$do_install" == true ]]; then
        [[ -z "$op" ]] || { error_log "--install 不能与 $op 同时使用"; exit 2; }
        non_interactive_install_tools "$targets_raw"
        exit $?
    fi

    if [[ "$do_validate" == true ]]; then
        validate_shared_configs "warn" || exit 1
        echo -e "${GREEN}✅ 所有配置校验通过！${NC}"
        exit 0
    fi

    if [[ -n "$op" && -n "$tgt" ]]; then
        local idx=-1
        for i in "${!TOOLS[@]}"; do
            parse_tool_data "${TOOLS[$i]}" "FIND"
            [[ "$tgt" == "$FIND_id" ]] && idx=$i && break
        done
        if [[ $idx -ne -1 ]]; then
            if [[ "$op" == "status" ]]; then
                parse_tool_data "${TOOLS[$idx]}" "S"
                execute_extended_commands "$S_id" "status_check" "$S_name"
            elif [[ "$op" == "config" ]]; then
                show_tool_config "$idx"
            else
                operate_tool "$idx" "$op"
            fi
        else
            exit 1
        fi
    elif [[ -n "$dm" ]]; then
        case $dm in "mcp") manage_mcp_servers_menu ;; "skills") manage_skills ;; "docs") manage_ai_docs ;; esac
    else select_tool_interactive; fi
    save_cache
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

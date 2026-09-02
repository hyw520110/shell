#!/usr/bin/env bash
# AI Hub 工具缓存预编译脚本
# 将分散的 JSON 配置文件预编译为单一缓存文件，实现毫秒级启动
# 使用方法: bash scripts/compile_tools_cache.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(dirname "$SCRIPT_DIR")"
CONF_DIR="$AI_DIR/conf"
CACHE_FILE="$AI_DIR/.cache/tools_compiled.txt"
PLUGINS_DIR="$SCRIPT_DIR/plugins"
TOOL_FIELD_SEP="${TOOL_FIELD_SEP:-$'\037'}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# 创建缓存目录
mkdir -p "$(dirname "$CACHE_FILE")"

# 目录到 category 的映射
dir_to_cat() {
    case "$1" in
        cli) echo "ai-coding" ;;
        ide) echo "ai-ide" ;;
        gateway) echo "ai-gateway" ;;
        agent) echo "ai-agent" ;;
        runtime) echo "ai-runtime" ;;
        *) echo "" ;;
    esac
}

# 预编译所有工具配置
compile_tools() {
    local count=0
    local results=()
    
    log_info "开始预编译工具配置..."
    
    # 递归扫描所有 JSON 文件
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ "$(basename "$file")" == "_template.json" ]] && continue
        
        # 获取子目录名，用于推导 category
        local subdir=$(basename "$(dirname "$file")")
        local inferred_cat=$(dir_to_cat "$subdir")
        
        # 使用 jq 提取所有字段
        local entry=$(jq -r --arg sep "$TOOL_FIELD_SEP" '
            def p(v): (v // "") | if . == "" then "__E__" else . end;
            def check_cmd:
                (.install.methods[0].check // "")
                | if type == "string" then . else "" end;
            if (.id != null and .id != "") then
                [
                    p(.id),
                    p(.name),
                    p(.install.methods[0].command // ""),
                    p(.install.methods[0].type // "unknown"),
                    p(.install.methods[0].plugin // ""),
                    p(.config.path),
                    "",
                    p(.commands.start // .id),
                    (p(.commands.version) | tostring),
                    p(.description),
                    p(.category),
                    p(check_cmd),
                    p(.sort_order // .order // 5000),
                    p(.sort_key // .name)
                ] | join($sep)
            else
                empty
            end
        ' "$file" 2>/dev/null)
        
        # 处理空值和占位符
        if [[ -n "$entry" ]]; then
            local id name inst_cmd type plugin conf_path pypi_placeholder start_cmd v_check desc cat check_cmd sort_order sort_key
            IFS="$TOOL_FIELD_SEP" read -r id name inst_cmd type plugin conf_path pypi_placeholder start_cmd v_check desc cat check_cmd sort_order sort_key <<< "$entry"
            
            # 还原占位符
            [[ "$id" == "__E__" || -z "$id" ]] && id=$(basename "$file" .json)
            [[ "$name" == "__E__" ]] && name="$id"
            [[ "$inst_cmd" == "__E__" ]] && inst_cmd=""
            [[ "$type" == "__E__" ]] && type="unknown"
            [[ "$plugin" == "__E__" ]] && plugin=""
            [[ "$conf_path" == "__E__" ]] && conf_path=""
            [[ "$start_cmd" == "__E__" ]] && start_cmd="$id"
            [[ "$v_check" == "__E__" ]] && v_check=""
            [[ "$desc" == "__E__" ]] && desc=""
            [[ "$cat" == "__E__" ]] && cat="$inferred_cat"
            [[ "$check_cmd" == "__E__" ]] && check_cmd=""
            [[ "$sort_order" == "__E__" || ! "$sort_order" =~ ^[0-9]+$ ]] && sort_order=5000
            [[ "$sort_key" == "__E__" || -z "$sort_key" ]] && sort_key="$name"
            
            # 展开 $HOME
            conf_path="${conf_path//\$HOME/$HOME}"
            
            # 提取包名
            local pkg=""
            case "$type" in
                "npm") 
                    pkg=$(echo "$inst_cmd" | sed -E 's/.*npm install -g ([^ ]+).*/\1/' | cut -d' ' -f1)
                    pkg="${pkg%%--*}"
                    pkg=$(echo "$pkg" | xargs)
                    ;;
                "pip"|"pip_official") 
                    pkg=$(echo "$inst_cmd" | sed -E 's/.*pip3 install ([^ ]+).*/\1/')
                    ;;
                "brew") 
                    pkg=$(echo "$inst_cmd" | sed -n 's/.*brew install \([^ ]*\).*/\1/p' | head -1)
                    ;;
            esac
            [[ -z "$pkg" && ( "$type" == "npm" || "$type" == "pip" ) ]] && pkg="$id"
            
            # 提取纯命令
            local cmd=$(echo "$start_cmd" | awk '{print $1}')
            [[ -z "$cmd" ]] && cmd="$id"
            
            # 输出到缓存
            results+=("$(printf '%05d\t%s\t%s\t%s' "$sort_order" "$sort_key" "$file" "${id}${TOOL_FIELD_SEP}${name}${TOOL_FIELD_SEP}${pkg}${TOOL_FIELD_SEP}${type}${TOOL_FIELD_SEP}${plugin}${TOOL_FIELD_SEP}${conf_path}${TOOL_FIELD_SEP}${TOOL_FIELD_SEP}${cmd}${TOOL_FIELD_SEP}${v_check}${TOOL_FIELD_SEP}${desc}${TOOL_FIELD_SEP}${cat}${TOOL_FIELD_SEP}${file}${TOOL_FIELD_SEP}${check_cmd}${TOOL_FIELD_SEP}${sort_order}${TOOL_FIELD_SEP}${sort_key}")")
            ((count++))
        fi
    done < <(find "$CONF_DIR/tools" -name "*.json" -type f 2>/dev/null | sort)
    
    log_info "预编译完成，共 $count 个工具"
    printf '%s\n' "${results[@]}" | sort -t $'\t' -k1,1n -k2,2f -k3,3 | cut -f4-
}

tools_fingerprint() {
    local tools_dir="$1"
    while IFS= read -r file; do
        stat -f "%m:%N" "$file" 2>/dev/null || stat -c "%Y:%n" "$file" 2>/dev/null
    done < <(find "$tools_dir" -name "*.json" -type f 2>/dev/null | sort) | cksum | awk '{print $1":"$2}'
}

# 主函数
main() {
    local force=false
    [[ "$1" == "--force" ]] && force=true
    
    # 检查是否需要重新编译
    if [[ "$force" != true ]]; then
        local tools_dir="$CONF_DIR/tools"
        if [[ -f "$CACHE_FILE" ]]; then
            local cached_fingerprint
            local current_fingerprint
            cached_fingerprint=$(head -1 "$CACHE_FILE" | sed 's/#FINGERPRINT://')
            current_fingerprint=$(tools_fingerprint "$tools_dir")
            
            if [[ -n "$current_fingerprint" && "$cached_fingerprint" == "$current_fingerprint" ]]; then
                log_info "缓存已是最新，跳过编译 (使用 --force 强制重编译)"
                return 0
            fi
        fi
    fi
    
    # 执行编译
    {
        echo "#FINGERPRINT:$(tools_fingerprint "$CONF_DIR/tools")"
        compile_tools
    } > "$CACHE_FILE"
    
    # 验证
    if [[ -s "$CACHE_FILE" ]]; then
        log_info "缓存已保存至: $CACHE_FILE"
        local lines=$(wc -l < "$CACHE_FILE")
        log_info "缓存包含 $lines 个工具配置"
    else
        log_error "缓存编译失败"
        return 1
    fi
}

main "$@"

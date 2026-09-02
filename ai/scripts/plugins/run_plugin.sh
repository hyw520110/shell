#!/usr/bin/env bash
# AI Hub 插件 Hook 执行器
# 负责调用对应的插件脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$SCRIPT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[PLUGIN]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[PLUGIN]${NC} $1"; }
log_error() { echo -e "${RED}[PLUGIN]${NC} $1"; }

# 运行插件
# 用法: run_plugin_hook <action> <plugin_name> <tool_id> <tool_name>
run_plugin_hook() {
    local action="$1"      # install, uninstall, status, update
    local plugin="$2"      # 插件名称
    local tool_id="$3"     # 工具 ID
    local tool_name="${4:-$tool_id}"  # 工具名称
    
    [[ -z "$plugin" ]] && return 1
    if [[ ! "$plugin" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "非法插件名称: $plugin"
        return 1
    fi

    local plugin_script="$PLUGINS_DIR/${plugin}.sh"
    
    # 检查插件是否存在
    if [[ ! -f "$plugin_script" ]]; then
        log_warn "插件 '$plugin' 不存在: $plugin_script"
        return 1
    fi
    
    # 执行插件
    log_info "执行插件 $plugin ($action)"
    bash "$plugin_script" "$action" "$tool_id" "$tool_name"
    return $?
}

# 列出所有可用插件
list_plugins() {
    local count=0
    for plugin in "$PLUGINS_DIR"/*.sh; do
        [[ -f "$plugin" ]] || continue
        [[ "$(basename "$plugin")" == "_template.sh" ]] && continue
        
        local name=$(basename "$plugin" .sh)
        local desc=$(grep -m1 "^#.*用途:" "$plugin" 2>/dev/null | sed 's/#.*用途://' || echo "N/A")
        echo "  $name - $desc"
        ((count++))
    done
    echo "共 $count 个插件"
}

# 主入口
main() {
    local action="$1"
    shift
    
    case "$action" in
        run)
            run_plugin_hook "$@"
            ;;
        list)
            list_plugins
            ;;
        *)
            echo "AI Hub 插件 Hook 执行器"
            echo ""
            echo "用法:"
            echo "  $0 run <action> <plugin> <tool_id> [tool_name]"
            echo "  $0 list"
            echo ""
            echo "操作:"
            echo "  install   - 安装"
            echo "  uninstall - 卸载"
            echo "  status    - 检查状态"
            echo "  update    - 更新"
            exit 1
            ;;
    esac
}

main "$@"

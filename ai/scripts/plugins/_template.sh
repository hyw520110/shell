#!/usr/bin/env bash
# AI Hub 插件安装脚本模板
# 插件名称: {{PLUGIN_NAME}}
# 用途: {{PLUGIN_DESCRIPTION}}

# ============================================
# 插件信息 (必须定义)
# ============================================
PLUGIN_NAME="{{PLUGIN_NAME}}"
PLUGIN_VERSION="{{VERSION:-1.0.0}}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ============================================
# 插件安装函数 (必须实现)
# ============================================
plugin_install() {
    local tool_id="$1"
    local tool_name="$2"
    local options="${3:-}"
    
    log_info "开始安装 $tool_name (插件: $PLUGIN_NAME)"
    
    # TODO: 实现安装逻辑
    # 示例:
    # 1. 下载二进制
    # 2. 解压到指定目录
    # 3. 设置执行权限
    # 4. 创建配置
    
    # 返回 0 表示成功，非 0 表示失败
    return 0
}

# ============================================
# 插件卸载函数 (必须实现)
# ============================================
plugin_uninstall() {
    local tool_id="$1"
    local tool_name="$2"
    local options="${3:-}"
    
    log_info "开始卸载 $tool_name (插件: $PLUGIN_NAME)"
    
    # TODO: 实现卸载逻辑
    # 示例:
    # 1. 删除安装文件
    # 2. 清理配置
    # 3. 清理缓存
    
    return 0
}

# ============================================
# 插件状态检查函数 (可选实现)
# ============================================
plugin_status() {
    local tool_id="$1"
    
    # TODO: 返回安装状态
    # echo "true" 表示已安装
    # echo "false" 表示未安装
    
    return 0
}

# ============================================
# 插件更新函数 (可选实现)
# ============================================
plugin_update() {
    local tool_id="$1"
    local tool_name="$2"
    
    log_info "更新 $tool_name"
    
    # 先卸载再安装，或原地更新
    plugin_uninstall "$tool_id" "$tool_name"
    plugin_install "$tool_id" "$tool_name"
}

# ============================================
# 主入口
# ============================================
main() {
    local action="$1"
    local tool_id="$2"
    local tool_name="${3:-$tool_id}"
    local options="${4:-}"
    
    case "$action" in
        install)
            plugin_install "$tool_id" "$tool_name" "$options"
            ;;
        uninstall)
            plugin_uninstall "$tool_id" "$tool_name" "$options"
            ;;
        status)
            plugin_status "$tool_id"
            ;;
        update)
            plugin_update "$tool_id" "$tool_name"
            ;;
        *)
            echo "用法: $0 {install|uninstall|status|update} <tool_id> [tool_name] [options]"
            exit 1
            ;;
    esac
}

main "$@"

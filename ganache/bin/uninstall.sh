#!/bin/bash
# Ganache 卸载脚本
# 支持 Linux 和 macOS，支持重复执行
# 用法：./uninstall.sh [选项]
# 选项:
#   -f, --force    强制卸载，不确认
#   --keep-config  保留配置文件

set -e
set -u
set -o pipefail

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# 导入通用函数
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# 配置
CONFIG_DIR="$HOME/.ganache"
FORCE=false
KEEP_CONFIG=false

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                FORCE=true
                shift
                ;;
            --keep-config)
                KEEP_CONFIG=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数：$1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# 显示使用说明
show_usage() {
    cat << EOF
Ganache 卸载脚本

用法：$0 [选项]

选项:
  -f, --force        强制卸载，不确认
  --keep-config      保留配置文件和数据
  -h, --help         显示帮助信息

示例:
  $0                 # 交互式卸载
  $0 -f              # 强制卸载，不确认
  $0 --keep-config   # 保留配置文件

卸载内容:
  - Ganache 全局 npm 包
  - 配置文件 ($CONFIG_DIR)
  - 系统服务配置 (systemd/launchd)
  - 启动脚本和日志

EOF
}

# 确认卸载
confirm_uninstall() {
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    
    echo ""
    log_warn "即将卸载 Ganache，这将删除:"
    echo "  - Ganache 全局 npm 包"
    echo "  - 配置文件：$CONFIG_DIR"
    echo "  - 系统服务配置"
    echo ""
    
    if [[ "$KEEP_CONFIG" == true ]]; then
        echo "  (保留配置文件和数据)"
        echo ""
    fi
    
    read -r -p "确定要继续吗？[y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log "已取消卸载"
            exit 0
            ;;
    esac
}

# 停止 Ganache 进程
stop_ganache() {
    log "检查 Ganache 进程..."
    
    if pgrep -f "ganache" > /dev/null; then
        log "正在停止 Ganache 进程..."
        
        # 尝试优雅停止
        pkill -TERM -f "ganache" 2>/dev/null || true
        sleep 3
        
        # 如果还在运行，强制停止
        if pgrep -f "ganache" > /dev/null; then
            log_warn "Ganache 未响应，强制停止..."
            pkill -KILL -f "ganache" 2>/dev/null || true
        fi
        
        log_success "Ganache 进程已停止"
    else
        log "Ganache 未运行"
    fi
}

# 卸载 npm 包
uninstall_npm_package() {
    log "卸载 Ganache npm 包..."
    
    if command -v npm &> /dev/null; then
        if npm list -g ganache &>/dev/null; then
            npm uninstall -g ganache
            log_success "已卸载全局 npm 包"
        else
            log "Ganache npm 包未安装"
        fi
    else
        log_warn "npm 未安装，跳过 npm 包卸载"
    fi
}

# 删除系统服务
remove_systemd_service() {
    if [[ "$(uname)" != "Linux" ]]; then
        return 0
    fi
    
    local service_file="/etc/systemd/system/ganache.service"
    
    if [[ -f "$service_file" ]]; then
        log "删除 systemd 服务..."
        
        # 停止并禁用服务
        systemctl stop ganache 2>/dev/null || true
        systemctl disable ganache 2>/dev/null || true
        
        # 删除服务文件
        rm -f "$service_file"
        
        # 重新加载 systemd
        systemctl daemon-reload 2>/dev/null || true
        
        log_success "已删除 systemd 服务"
    else
        log "systemd 服务文件不存在"
    fi
}

# 删除 launchd 服务 (macOS)
remove_launchd_service() {
    if [[ "$(uname)" != "Darwin" ]]; then
        return 0
    fi
    
    local service_file="$HOME/Library/LaunchAgents/com.trufflesuite.ganache.plist"
    
    if [[ -f "$service_file" ]]; then
        log "删除 launchd 服务..."
        
        # 卸载服务
        launchctl unload "$service_file" 2>/dev/null || true
        
        # 删除服务文件
        rm -f "$service_file"
        
        log_success "已删除 launchd 服务"
    else
        log "launchd 服务文件不存在"
    fi
}

# 删除配置文件和目录
remove_config_files() {
    if [[ "$KEEP_CONFIG" == true ]]; then
        log "保留配置文件，跳过删除"
        return 0
    fi
    
    log "删除配置文件和目录..."
    
    local files_to_remove=(
        "$CONFIG_DIR"
        "/usr/local/bin/ganache"
        "/usr/bin/ganache"
    )
    
    for file in "${files_to_remove[@]}"; do
        if [[ -e "$file" ]]; then
            rm -rf "$file"
            log "已删除：$file"
        fi
    done
    
    log_success "已删除配置文件和目录"
}

# 清理环境变量 (可选)
cleanup_environment() {
    log "检查环境变量配置..."
    
    local shell_files=(
        "$HOME/.bashrc"
        "$HOME/.bash_profile"
        "$HOME/.zshrc"
        "$HOME/.profile"
    )
    
    for file in "${shell_files[@]}"; do
        if [[ -f "$file" ]]; then
            # 检查是否包含 Ganache 相关配置
            if grep -q "ganache" "$file" 2>/dev/null; then
                log "发现 Ganache 相关配置：$file"
                # 不自动删除，让用户手动处理
            fi
        fi
    done
}

# 验证卸载
verify_uninstall() {
    log "验证卸载结果..."
    
    local has_errors=false
    
    # 检查 Ganache 是否还存在
    if command -v ganache &> /dev/null; then
        log_warn "Ganache 命令仍然可用，可能需要重新加载 shell"
        has_errors=true
    else
        log_success "Ganache 命令已移除"
    fi
    
    # 检查进程
    if pgrep -f "ganache" > /dev/null; then
        log_warn "仍有 Ganache 进程在运行"
        has_errors=true
    else
        log_success "Ganache 进程已停止"
    fi
    
    if [[ "$has_errors" == true ]]; then
        log_warn "卸载完成，但存在一些问题，请检查上述警告"
        return 1
    fi
    
    log_success "卸载验证通过"
    return 0
}

# 显示卸载后信息
show_post_uninstall_info() {
    echo ""
    log "========================================="
    log "  Ganache 卸载完成!"
    log "========================================="
    echo ""
    
    if [[ "$KEEP_CONFIG" == true ]]; then
        log "配置文件已保留在：$CONFIG_DIR"
        echo ""
    fi
    
    log "如需重新安装，请运行:"
    echo "  ./install.sh"
    echo ""
    
    log "如果 ganache 命令仍然可用，请尝试:"
    echo "  1. 重新加载 shell: exec \$SHELL -l"
    echo "  2. 或者关闭并重新打开终端"
    echo ""
}

# 主函数
main() {
    log "========================================="
    log "  Ganache 卸载脚本"
    log "========================================="
    
    parse_args "$@"
    
    # 确认卸载
    confirm_uninstall
    
    # 停止 Ganache
    stop_ganache
    
    # 卸载 npm 包
    uninstall_npm_package
    
    # 删除系统服务
    remove_systemd_service
    remove_launchd_service
    
    # 删除配置文件
    remove_config_files
    
    # 清理环境变量
    cleanup_environment
    
    # 验证卸载
    verify_uninstall
    
    # 显示信息
    show_post_uninstall_info
}

# 执行主函数
main "$@"

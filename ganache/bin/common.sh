#!/bin/bash
# Ganache 通用函数库
# 提供日志、检查、卸载等公共函数

set -e
set -u
set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${BLUE}[INFO]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*" >&2
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 执行"
        exit 1
    fi
}

# 检查系统类型
check_os() {
    local os_type
    if [[ "$(uname)" == "Darwin" ]]; then
        os_type="macos"
    elif [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_type=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    elif [[ -f /etc/redhat-release ]]; then
        os_type="centos"
    else
        os_type="unknown"
    fi
    echo "$os_type"
}

# 检查 Node.js 是否安装
check_nodejs() {
    if ! command -v node &> /dev/null; then
        log_error "Node.js 未安装，请先安装 Node.js (v14+)"
        log "安装方法:"
        log "  - macOS: brew install node"
        log "  - Linux: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs"
        exit 1
    fi
    
    local node_version
    node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ "$node_version" -lt 14 ]]; then
        log_error "Node.js 版本过低 (当前: $(node -v)), 需要 v14+"
        exit 1
    fi
    
    log_success "Node.js 已安装：$(node -v)"
}

# 检查 npm 是否安装
check_npm() {
    if ! command -v npm &> /dev/null; then
        log_error "npm 未安装，请先安装 npm"
        exit 1
    fi
    log_success "npm 已安装：$(npm -v)"
}

# 检查 Ganache 是否已安装
check_ganache_installed() {
    if command -v ganache &> /dev/null; then
        return 0
    fi
    return 1
}

# 获取 Ganache 版本
get_ganache_version() {
    if check_ganache_installed; then
        ganache --version 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# 检查 Ganache 是否正在运行
check_ganache_running() {
    if pgrep -f "ganache" > /dev/null; then
        return 0
    fi
    return 1
}

# 停止 Ganache
stop_ganache() {
    if check_ganache_running; then
        log "正在停止 Ganache..."
        pkill -f "ganache" || true
        sleep 2
        log_success "Ganache 已停止"
    else
        log "Ganache 未运行"
    fi
}

# 卸载 Ganache
uninstall_ganache() {
    log "开始卸载 Ganache..."
    
    # 停止运行中的 Ganache
    stop_ganache
    
    # 全局卸载 npm 包
    if command -v npm &> /dev/null; then
        npm uninstall -g ganache 2>/dev/null || true
        log "已卸载全局 npm 包"
    fi
    
    # 删除配置文件
    local config_files=(
        "$HOME/.ganache/config.json"
        "$HOME/.ganache/settings.json"
        "$HOME/.ganache/db"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -e "$file" ]]; then
            rm -rf "$file"
            log "已删除：$file"
        fi
    done
    
    # 删除日志
    if [[ -d "$HOME/.ganache/logs" ]]; then
        rm -rf "$HOME/.ganache/logs"
        log "已删除日志目录"
    fi
    
    log_success "Ganache 卸载完成"
}

# 显示帮助信息
show_usage() {
    cat << EOF
Ganache 管理脚本

用法：$0 [选项] [命令]

选项:
  -h, --help      显示帮助信息
  -v, --version   显示 Ganache 版本

命令:
  install         安装 Ganache
  configure       配置 Ganache
  uninstall       卸载 Ganache
  start           启动 Ganache
  stop            停止 Ganache
  restart         重启 Ganache
  status          查看 Ganache 状态

示例:
  $0 install              # 安装 Ganache
  $0 configure            # 配置 Ganache
  $0 start --port 8545    # 启动 Ganache，指定端口
  $0 status               # 查看状态

EOF
}

# 获取当前脚本所在目录
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [[ -h "$source" ]]; do
        local dir
        dir="$( cd -P "$( dirname "$source" )" >/dev/null 2>&1 && pwd )"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source"
    done
    "$( cd -P "$( dirname "$source" )" >/dev/null 2>&1 && pwd )"
}

# 检查磁盘空间
check_disk_space() {
    local required_mb="${1:-500}"
    local available_mb
    available_mb=$(df -m "$HOME" | awk 'NR==2 {print $4}')
    
    if [[ "$available_mb" -lt "$required_mb" ]]; then
        log_error "磁盘空间不足，需要至少 ${required_mb}MB，当前可用 ${available_mb}MB"
        return 1
    fi
    log "磁盘空间充足：${available_mb}MB 可用"
    return 0
}

# 备份配置文件
backup_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        local backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$config_file" "$backup_file"
        log "已备份配置文件：$backup_file"
    fi
}

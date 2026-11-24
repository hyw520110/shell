#!/bin/bash
# Ganache 安装脚本
# 支持 Linux 和 macOS，支持重复执行
# 用法：./install.sh [选项]
# 选项:
#   -v, --version <版本>   指定 Ganache 版本 (默认：latest)
#   -m, --mirror <镜像>    指定 npm 镜像源 (可选：cnpm, taobao, official)
#   -f, --force            强制重新安装

set -e
set -u
set -o pipefail

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# 导入通用函数
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# 默认配置
GANACHE_VERSION="latest"
NPM_MIRROR="official"
FORCE_INSTALL=false

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
               GANACHE_VERSION="$2"
                shift 2
                ;;
            -m|--mirror)
                NPM_MIRROR="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_INSTALL=true
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
Ganache 安装脚本

用法：$0 [选项]

选项:
  -v, --version <版本>   指定 Ganache 版本 (默认：latest)
  -m, --mirror <镜像>    指定 npm 镜像源 (可选：cnpm, taobao, official)
  -f, --force            强制重新安装
  -h, --help             显示帮助信息

示例:
  $0                              # 使用默认配置安装
  $0 -v 7.9.1                     # 安装指定版本
  $0 -m taobao                    # 使用淘宝镜像源安装
  $0 -f                           # 强制重新安装

镜像源说明:
  - official: 官方源 (https://registry.npmjs.org)
  - taobao:   淘宝镜像 (https://registry.npmmirror.com)
  - cnpm:     CNPM 镜像 (https://r.cnpmjs.org)

EOF
}

# 配置 npm 镜像源
configure_npm_mirror() {
    log "配置 npm 镜像源：$NPM_MIRROR"
    
    case $NPM_MIRROR in
        taobao)
            npm config set registry https://registry.npmmirror.com
            ;;
        cnpm)
            npm config set registry https://r.cnpmjs.org
            ;;
        official|*)
            npm config set registry https://registry.npmjs.org
            ;;
    esac
    
    log_success "npm 镜像源已配置"
}

# 安装 Ganache
install_ganache() {
    log "开始安装 Ganache..."
    
    # 检查是否已安装
    if check_ganache_installed && [[ "$FORCE_INSTALL" == false ]]; then
        local current_version
        current_version=$(get_ganache_version)
        log_warn "Ganache 已安装 (版本：$current_version)"
        log "如需重新安装，请使用 -f 参数强制重装"
        return 0
    fi
    
    # 强制安装时先卸载
    if [[ "$FORCE_INSTALL" == true ]]; then
        log "强制安装模式，正在卸载旧版本..."
        uninstall_ganache
    fi
    
    # 检查 Node.js 和 npm
    check_nodejs
    check_npm
    
    # 检查磁盘空间
    check_disk_space 500
    
    # 配置 npm 镜像源
    configure_npm_mirror
    
    # 安装 Ganache
    log "正在安装 Ganache ${GANACHE_VERSION}..."
    if [[ "$GANACHE_VERSION" == "latest" ]]; then
        npm install -g ganache
    else
        npm install -g ganache@"$GANACHE_VERSION"
    fi
    
    # 验证安装
    if ! check_ganache_installed; then
        log_error "Ganache 安装失败"
        exit 1
    fi
    
    local installed_version
    installed_version=$(get_ganache_version)
    log_success "Ganache 安装成功 (版本：$installed_version)"
    
    # 创建配置目录
    create_config_dir
    
    log_success "Ganache 安装完成"
}

# 创建配置目录
create_config_dir() {
    local config_dir="$HOME/.ganache"
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        log "已创建配置目录：$config_dir"
    fi
    
    local logs_dir="$config_dir/logs"
    if [[ ! -d "$logs_dir" ]]; then
        mkdir -p "$logs_dir"
        log "已创建日志目录：$logs_dir"
    fi
}

# 验证安装
verify_installation() {
    log "验证 Ganache 安装..."
    
    if ! check_ganache_installed; then
        log_error "验证失败：Ganache 未安装"
        return 1
    fi
    
    # 测试 Ganache 是否可以运行
    local version
    version=$(ganache --version 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "验证失败：Ganache 无法正常运行"
        return 1
    fi
    
    log_success "验证通过：Ganache $version"
    return 0
}

# 主函数
main() {
    log "========================================="
    log "  Ganache 安装脚本"
    log "========================================="
    
    parse_args "$@"
    
    log "安装配置:"
    log "  - 版本：$GANACHE_VERSION"
    log "  - 镜像源：$NPM_MIRROR"
    log "  - 强制安装：$FORCE_INSTALL"
    log ""
    
    # 执行安装
    install_ganache
    
    # 验证安装
    verify_installation
    
    log ""
    log_success "========================================="
    log_success "  Ganache 安装完成!"
    log_success "========================================="
    log ""
    log "使用命令:"
    log "  ganache --help          # 查看帮助"
    log "  ganache                 # 启动 Ganache"
    log "  ganache --version       # 查看版本"
    log ""
    log "管理命令:"
    log "  ./ganache.sh start      # 启动 Ganache"
    log "  ./ganache.sh stop       # 停止 Ganache"
    log "  ./ganache.sh status     # 查看状态"
    log ""
}

# 执行主函数
main "$@"

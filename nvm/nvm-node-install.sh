#!/bin/bash
# -*- coding: utf-8 -*-

# 设置严格模式
set -e

# 公共变量定义
SCRIPT_NAME=$(basename "$0")
USAGE="用法: ./$SCRIPT_NAME [选项] [node版本] [nvm版本]"
HELP_TEXT="
$USAGE

选项:
  -h, --help     显示帮助信息
  --registry     指定 npm 镜像源 (taobao|huawei|tencent|official)
  --auto-install 自动安装指定版本的 Node.js (无需用户确认)

参数:
  node版本       要安装的 Node.js 版本 (默认: 22.17.0)
  nvm版本        要安装的 nvm 版本 (默认: v0.40.3)
"

# 默认值
NODE_VERSION="${1:-22.17.0}"
NVM_VERSION="${2:-v0.40.3}"
REGISTRY_TYPE="taobao"
AUTO_INSTALL=false

# 解析命令行选项
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      echo "$HELP_TEXT"
      exit 0
      ;;
    --registry)
      REGISTRY_TYPE="$2"
      shift 2
      ;;
    --auto-install)
      AUTO_INSTALL=true
      shift
      ;;
    *)
      # 如果不是选项，则认为是位置参数
      if [[ -z "$NODE_VERSION_SET" ]]; then
        NODE_VERSION="$1"
        NODE_VERSION_SET=true
      elif [[ -z "$NVM_VERSION_SET" ]]; then
        NVM_VERSION="$1"
        NVM_VERSION_SET=true
      fi
      shift
      ;;
  esac
done

# 镜像源配置
OFFICIAL_REGISTRY="https://registry.npmjs.org/"
TAOBAO_REGISTRY="https://registry.npmmirror.com/"
HUAWEI_REGISTRY="https://mirrors.huaweicloud.com/repository/npm/"
TENCENT_REGISTRY="https://mirrors.cloud.tencent.com/npm/"

# 日志函数
echo_info() {
    echo "[信息] $1"
}

echo_error() {
    echo "[错误] $1" >&2
}

echo_warn() {
    echo "[警告] $1" >&2
}

# 用户确认函数
user_confirm() {
    local prompt="$1"
    local response
    
    if [ "$AUTO_INSTALL" = true ]; then
        return 0  # 自动安装模式下直接返回成功
    fi
    
    while true; do
        read -p "$prompt [y/N]: " response
        case "$response" in
            [Yy]*)
                return 0
                ;;
            [Nn]* | "")
                return 1
                ;;
            *)
                echo "请输入 y 或 n"
                ;;
        esac
    done
}

# 检查依赖命令是否存在
check_dependencies() {
    local deps=("curl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo_warn "$dep 命令未找到，可能会导致脚本执行失败"
        fi
    done
}

# 获取 npm 镜像源 URL
get_registry_url() {
    case "$REGISTRY_TYPE" in
        "taobao")
            echo "$TAOBAO_REGISTRY"
            ;;
        "huawei")
            echo "$HUAWEI_REGISTRY"
            ;;
        "tencent")
            echo "$TENCENT_REGISTRY"
            ;;
        "official"|*)
            echo "$OFFICIAL_REGISTRY"
            ;;
    esac
}

# 查找 nvm 目录
find_nvm_dir() {
    if [ -d "$HOME/.nvm" ]; then
        echo "$HOME/.nvm"
    elif [ -d "$HOME/.config/nvm" ]; then
        echo "$HOME/.config/nvm"
    else
        echo "$HOME/.nvm"  # 默认位置
    fi
}

# 安装 nvm
install_nvm() {
    echo_info "nvm 未安装，开始安装 nvm $NVM_VERSION..."
    
    # 下载并执行安装脚本
    if curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash; then
        echo_info "nvm 安装完成"
        return 0
    else
        echo_error "nvm 安装失败"
        return 1
    fi
}

# 初始化 nvm
init_nvm() {
    local nvm_dir
    nvm_dir=$(find_nvm_dir)
    
    # 如果 nvm 目录不存在，尝试安装
    if [ ! -d "$nvm_dir" ]; then
        if ! install_nvm; then
            return 1
        fi
        nvm_dir=$(find_nvm_dir)  # 重新获取目录
    fi
    
    # 加载 nvm
    if [ -f "$nvm_dir/nvm.sh" ]; then
        source "$nvm_dir/nvm.sh"
        echo_info "nvm 已加载"
        return 0
    else
        echo_error "nvm.sh 文件不存在: $nvm_dir/nvm.sh"
        return 1
    fi
}

# 检查系统中是否已安装 Node.js
check_system_node() {
    if command -v node &> /dev/null; then
        local system_node_version
        system_node_version=$(node -v)
        echo_info "系统中已安装 Node.js: $system_node_version"
        return 0
    else
        echo_info "系统中未安装 Node.js"
        return 1
    fi
}

# 获取当前 nvm 管理的 Node.js 版本
get_current_nvm_node_version() {
    if command -v node &> /dev/null; then
        # 检查是否是 nvm 管理的版本
        local node_path
        node_path=$(which node)
        if [[ "$node_path" == *"nvm"* ]]; then
            node -v 2>/dev/null | sed 's/^v//'
        fi
    fi
}

# 安装 Node.js 版本
install_node() {
    # 检查版本是否已安装
    if nvm ls | grep -q "v$NODE_VERSION"; then
        echo_info "Node.js v$NODE_VERSION 已通过 nvm 安装"
        return 0
    else
        # 检查当前使用的 Node.js 版本
        local current_version
        current_version=$(get_current_nvm_node_version)
        
        if [ -n "$current_version" ]; then
            echo_info "当前通过 nvm 使用的 Node.js 版本: v$current_version"
        fi
        
        # 提示用户是否安装指定版本
        if user_confirm "是否安装 Node.js v$NODE_VERSION？"; then
            echo_info "开始安装 Node.js v$NODE_VERSION..."
            if nvm install "$NODE_VERSION"; then
                echo_info "Node.js v$NODE_VERSION 安装完成"
                return 0
            else
                echo_error "Node.js v$NODE_VERSION 安装失败"
                return 1
            fi
        else
            echo_info "跳过 Node.js v$NODE_VERSION 安装"
            return 0
        fi
    fi
}

# 验证安装
verify_installation() {
    echo_info "验证 Node.js 和 npm 版本..."
    if command -v node &> /dev/null && command -v npm &> /dev/null; then
        echo "Node.js 版本: $(node -v)"
        echo "npm 版本: $(npm -v)"
        return 0
    else
        echo_warn "Node.js 或 npm 未正确安装"
        return 1
    fi
}

# 设置默认 Node.js 版本
set_default_version() {
    echo_info "设置默认 Node.js 版本..."
    if nvm alias default "$NODE_VERSION"; then
        echo_info "默认 Node.js 版本已设置为 v$NODE_VERSION"
        return 0
    else
        echo_error "设置默认 Node.js 版本失败"
        return 1
    fi
}

# 切换 npm 镜像源
switch_registry() {
    # 只有在 npm 可用时才尝试切换镜像源
    if ! command -v npm &> /dev/null; then
        echo_warn "npm 未安装，跳过镜像源切换"
        return 0
    fi
    
    local target_registry
    target_registry=$(get_registry_url)
    
    # 获取当前 npm 镜像源
    local current_registry
    current_registry=$(npm config get registry 2>/dev/null || echo "")
    
    # 判断是否需要切换
    if [ "$current_registry" != "$target_registry" ]; then
        echo_info "当前使用的是 $current_registry"
        if user_confirm "是否切换 npm 镜像源为 $target_registry？"; then
            echo_info "正在切换为 $target_registry..."
            if npm config set registry "$target_registry"; then
                echo_info "切换完成！当前镜像源: $(npm config get registry)"
                return 0
            else
                echo_error "镜像源切换失败"
                return 1
            fi
        else
            echo_info "保持当前镜像源设置"
            return 0
        fi
    else
        echo_info "当前已使用正确的镜像源: $current_registry"
        return 0
    fi
}

# 主函数
main() {
    echo_info "开始 Node.js 环境配置..."
    
    # 检查依赖
    check_dependencies
    
    # 检查系统中是否已安装 Node.js
    check_system_node
    
    # 初始化 nvm
    if ! init_nvm; then
        echo_error "nvm 初始化失败"
        exit 1
    fi
    
    # 安装 Node.js
    if ! install_node; then
        echo_error "Node.js 安装失败"
        exit 1
    fi
    
    # 验证安装
    verify_installation
    
    # 设置默认版本
    set_default_version
    
    # 显示当前路径
    if command -v node &> /dev/null; then
        echo_info "当前使用的 Node.js 路径: $(which node)"
    fi
    
    # 切换镜像源
    switch_registry
    
    echo_info "Node.js 环境配置完成！"
}

# 执行主函数
main "$@"
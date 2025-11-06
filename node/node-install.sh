#!/bin/bash

# 设置严格模式
set -e

# 默认值
NODE_VERSION="${1:-22.17.0}"
NVM_VERSION="v0.40.3"  # 默认 nvm 版本
REGISTRY_TYPE="taobao"
USE_FNM=true   # 默认使用 fnm
USE_NVM=false  # 默认不使用 nvm

# 镜像源配置
OFFICIAL_REGISTRY="https://registry.npmjs.org/"
TAOBAO_REGISTRY="https://registry.npmmirror.com/"
HUAWEI_REGISTRY="https://mirrors.huaweicloud.com/repository/npm/"
TENCENT_REGISTRY="https://mirrors.cloud.tencent.com/npm/"

# 公共变量定义
SCRIPT_NAME=$(basename "$0")
USAGE="用法: ./$SCRIPT_NAME [选项] [node版本]"
HELP_TEXT="
$USAGE

选项:
  -h, --help     显示帮助信息
  --registry     指定 npm 镜像源 (taobao|huawei|tencent|official)
  --use-fnm      使用 fnm (Fast Node Manager) (默认行为)
  --use-nvm      使用 nvm 而不是 fnm

参数:
  node版本       要安装的 Node.js 版本 (默认: $NODE_VERSION)
"


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
    --use-fnm)
      USE_FNM=true
      USE_NVM=false
      shift
      ;;
    --use-nvm)
      USE_FNM=false
      USE_NVM=true
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

# 检查并安装依赖命令
install_dependencies() {
    local deps=("curl" "git")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo_info "$dep 命令未找到，正在安装..."
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                if command -v apt &> /dev/null; then
                    sudo apt update && sudo apt install -y "$dep"
                elif command -v yum &> /dev/null; then
                    sudo yum install -y "$dep"
                elif command -v dnf &> /dev/null; then
                    sudo dnf install -y "$dep"
                else
                    echo_error "无法自动安装 $dep，请手动安装"
                    exit 1
                fi
            else
                echo_error "不支持的操作系统类型，无法自动安装依赖"
                exit 1
            fi
        else
            echo_info "$dep 命令已存在"
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

# 验证下载文件的完整性（使用校验和）
verify_download() {
    local file_path="$1"
    local expected_hash="$2"
    
    if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash=$(sha256sum "$file_path" | cut -d' ' -f1)
        if [ "$actual_hash" != "$expected_hash" ]; then
            echo_error "文件校验失败！"
            return 1
        fi
    fi
    
    return 0
}

# 安装 nvm
install_nvm() {
    echo_info "nvm 未安装，开始安装 nvm $NVM_VERSION..."
    
    # 为 nvm 创建临时目录
    local temp_dir
    temp_dir=$(mktemp -d)
    local install_script="$temp_dir/install.sh"
    
    # 尝试从 GitHub 获取安装脚本
    if curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" -o "$install_script"; then
        # 验证下载（如果知道校验和的话，可以在这里验证）
        # verify_download "$install_script" "expected_hash_value"
        
        echo_info "正在执行 nvm 安装脚本..."
        bash "$install_script"
        
        # 清理临时文件
        rm -rf "$temp_dir"
        
        echo_info "nvm 安装完成"
        return 0
    else
        echo_warn "从 GitHub 获取 nvm 安装脚本失败，尝试从镜像源安装..."
        
        # 清理临时文件
        rm -rf "$temp_dir"
        
        # 方法2: 使用镜像源或直接克隆
        if [ -d "$HOME/.nvm" ]; then
            rm -rf "$HOME/.nvm"
        fi
        
        # 尝试从 GitHub 镜像克隆
        if git clone --depth 1 --branch "$NVM_VERSION" https://ghproxy.com/github.com/nvm-sh/nvm.git "$HOME/.nvm"; then
            echo_info "nvm 从 GitHub 镜像安装完成"
            return 0
        elif git clone --depth 1 --branch "$NVM_VERSION" https://hub.gitmirror.com/https://github.com/nvm-sh/nvm.git "$HOME/.nvm"; then
            echo_info "nvm 从 GitMirror 镜像安装完成"
            return 0
        else
            echo_warn "无法从镜像源安装 nvm，尝试使用 fnm 作为备选方案..."
            # 直接返回错误，让调用者处理使用 fnm
            return 1
        fi
    fi
}

# 安装 fnm (Fast Node Manager)
install_fnm() {
    echo_info "nvm 安装失败，尝试使用 fnm 安装 Node.js..."
    export FNM_NODE_DIST_MIRROR=https://mirrors.aliyun.com/nodejs-release/
    
    # 下载并安装 fnm
    if command -v curl >/dev/null 2>&1; then
        # 为 fnm 创建临时目录
        local temp_dir
        temp_dir=$(mktemp -d)
        local fnm_binary="$temp_dir/fnm"
        
        # 根据操作系统架构确定下载 URL
        local arch
        arch=$(uname -m)
        local os
        os=$(uname -s)
        
        # 确定架构字符串
        case $arch in
            x86_64)
                arch="x64"
                ;;
            aarch64|arm64)
                arch="arm64"
                ;;
            *)
                echo_error "不支持的架构: $arch"
                return 1
                ;;
        esac
        
        # 获取最新的 fnm 版本号
        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/Schniz/fnm/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        if [ -z "$latest_version" ]; then
            latest_version="v1.38.1" # 如果无法获取最新版本，则使用默认版本
        fi

        # 下载 fnm 二进制文件
        local fnm_url
        if [ "$os" = "Linux" ]; then
            fnm_url="https://github.com/Schniz/fnm/releases/download/$latest_version/fnm-linux.zip"
        elif [ "$os" = "Darwin" ]; then
            fnm_url="https://github.com/Schniz/fnm/releases/download/$latest_version/fnm-darwin.zip"
        else
            echo_error "不支持的操作系统: $os"
            return 1
        fi
        
        echo_info "正在下载 fnm 从: $fnm_url"
        if curl -fsSL "$fnm_url" -o "$temp_dir/fnm.zip"; then
            # 解压 zip 文件
            if command -v unzip >/dev/null 2>&1; then
                unzip -o "$temp_dir/fnm.zip" -d "$temp_dir"
                
                # 查找解压后的 fnm 二进制文件
                if [ -f "$temp_dir/fnm" ]; then
                    chmod +x "$temp_dir/fnm"
                    
                    # 移动到用户目录
                    mkdir -p "$HOME/.fnm"
                    mv "$temp_dir/fnm" "$HOME/.fnm/fnm"
                    
                    # 清理临时目录
                    rm -rf "$temp_dir"
                    
                    echo_info "fnm 安装成功"
                    return 0
                else
                    echo_error "解压后未找到 fnm 二进制文件"
                    rm -rf "$temp_dir"
                    return 1
                fi
            else
                echo_error "unzip 命令不可用，无法解压 fnm"
                rm -rf "$temp_dir"
                return 1
            fi
        else
            # 清理临时目录
            rm -rf "$temp_dir"
            
            echo_warn "从官方源安装 fnm 失败，尝试从镜像源..."
            # 尝试从镜像源下载 fnm - 需要确认 Gitee 上的文件结构
            local os_lower=$(echo "$os" | tr '[:upper:]' '[:lower:]')
            if curl -fsSL https://gitee.com/mirrors/fnm/releases/download/$latest_version/fnm-$os_lower.zip -o "$temp_dir/fnm.zip"; then
                # 解压 zip 文件
                if command -v unzip >/dev/null 2>&1; then
                    unzip -o "$temp_dir/fnm.zip" -d "$temp_dir"
                    
                    # 查找解压后的 fnm 二进制文件
                    if [ -f "$temp_dir/fnm" ]; then
                        chmod +x "$temp_dir/fnm"
                        
                        # 移动到用户目录
                        mkdir -p "$HOME/.fnm"
                        mv "$temp_dir/fnm" "$HOME/.fnm/fnm"
                        
                        # 清理临时目录
                        rm -rf "$temp_dir"
                        
                        echo_info "fnm 从镜像源安装成功"
                        return 0
                    else
                        echo_error "从镜像源解压后未找到 fnm 二进制文件"
                        rm -rf "$temp_dir"
                        return 1
                    fi
                else
                    echo_error "unzip 命令不可用，无法解压镜像源的 fnm"
                    rm -rf "$temp_dir"
                    return 1
                fi
            else
                echo_error "fnm 安装失败"
                return 1
            fi
        fi
    else
        echo_error "curl 命令不可用，无法安装 fnm"
        return 1
    fi
}

# 初始化 fnm
init_fnm() {
    # 临时将 fnm 添加到 PATH（仅对当前会话）
    export PATH="$HOME/.fnm:$PATH"
    
    # 检查 fnm 是否可用
    if command -v fnm >/dev/null 2>&1; then
        echo_info "fnm 已加载"
        # 直接执行 fnm env 来设置环境
        eval "$(fnm env)"
        return 0
    else
        if install_fnm; then
            # 重新加载环境
            export PATH="$HOME/.fnm:$PATH"
            # 初始化 fnm 环境
            eval "$(fnm env)"
            echo_info "fnm 已加载"
            return 0
        else
            echo_error "fnm 初始化失败"
            return 1
        fi
    fi
}

# 通过 fnm 安装 Node.js
install_node_with_fnm() {
    echo_info "正在通过 fnm 安装 Node.js v$NODE_VERSION..."
    
    # 初始化 fnm
    if ! init_fnm; then
        return 1
    fi
    
    # 为当前会话临时添加 fnm 到 PATH
    export PATH="$HOME/.fnm:$PATH"
    
    # 初始化 fnm 环境
    eval "$(fnm env)"
    
    # 安装指定版本的 Node.js
    if fnm install $NODE_VERSION; then
        echo_info "Node.js v$NODE_VERSION 通过 fnm 安装完成"
        
        # 使用刚安装的 Node.js 版本
        fnm use $NODE_VERSION --install-if-missing
        
        # 检查 Node.js 是否可用
        if command -v node >/dev/null 2>&1; then
            # 设置为默认版本
            fnm default $NODE_VERSION
            echo_info "Node.js v$NODE_VERSION 已设置为默认版本"
            
            # 输出需要添加到用户配置文件中的内容
            echo ""
            echo_info "=========================================="
            echo_info "请将以下内容添加到您的 shell 配置文件中："
            echo_info ""
            if [ -n "$ZSH_VERSION" ]; then
                echo_info "对于 Zsh shell，请将以下内容添加到 ~/.zshrc："
            else
                echo_info "对于 Bash shell，请将以下内容添加到 ~/.bashrc："
            fi
            echo_info ""
            echo_info '  export PATH="$HOME/.fnm:$PATH"'
            echo_info '  eval "$(fnm env)"'
            echo_info ""
            echo_info "或者，您也可以将其添加到 ~/.profile 或 ~/.bash_profile (如果它们存在) 以确保在登录时加载"
            echo_info "=========================================="
            echo ""
            return 0
        else
            echo_error "Node.js 命令不可用，请按照上面的说明添加环境配置到您的 shell 配置文件中"
            return 1
        fi
    else
        echo_error "Node.js v$NODE_VERSION 通过 fnm 安装失败"
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
            echo_error "nvm 安装失败"
            return 1
        fi
        nvm_dir=$(find_nvm_dir)  # 重新获取目录
    fi
    
    # 加载 nvm
    if [ -f "$nvm_dir/nvm.sh" ]; then
        export NVM_DIR="$nvm_dir"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
        
        echo_info "nvm 已加载"
        return 0
    else
        echo_error "nvm.sh 文件不存在"
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
        # 检查是否使用 fnm 安装了 Node.js
        if command -v fnm &> /dev/null; then
            echo_info "检测到 fnm 已安装，验证 fnm 管理的 Node.js 版本..."
            echo "Node.js 版本: $(fnm current 2>/dev/null || node -v)"
            echo "npm 版本: $(npm -v 2>/dev/null || echo 'Not available')"
            return 0
        else
            echo_warn "Node.js 或 npm 未正确安装"
            return 1
        fi
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
    
    # 安装依赖
    install_dependencies
    
    # 检查系统中是否已安装 Node.js
    check_system_node
    
    if [ "$USE_FNM" = true ]; then
        # 使用 fnm
        echo_info "使用 fnm 安装 Node.js..."
        if ! init_fnm; then
            echo_error "fnm 初始化失败"
            exit 1
        fi
        
        # 通过 fnm 安装 Node.js
        if ! install_node_with_fnm; then
            echo_error "通过 fnm 安装 Node.js 失败"
            exit 1
        fi
    else
        # 使用 nvm（默认）
        # 初始化 nvm（nvm 失败时会自动尝试 fnm）
        if ! init_nvm; then
            echo_error "nvm 初始化失败"
            # 如果用户没有明确要求使用 nvm，也可以尝试使用 fnm 作为备选
            if [ "$USE_NVM" = true ]; then
                echo_error "由于指定了使用 nvm，不再尝试其他方案"
                exit 1
            else
                echo_info "尝试使用 fnm 作为备选方案..."
                if ! init_fnm; then
                    echo_error "nvm 和 fnm 都初始化失败"
                    exit 1
                fi
                
                # 通过 fnm 安装 Node.js
                if ! install_node_with_fnm; then
                    echo_error "通过 fnm 安装 Node.js 也失败"
                    exit 1
                fi
            fi
        fi
    fi
    
    # 检查是否通过 fnm 安装了 Node.js（在这种情况下跳过 nvm 安装步骤）
    if command -v fnm &> /dev/null && ! command -v node &> /dev/null; then
        # 如果 fnm 已安装但 node 还没安装，则跳过 nvm 的安装步骤
        echo_info "检测到使用 fnm，跳过 nvm 的 Node.js 安装步骤"
    elif command -v fnm &> /dev/null && command -v node &> /dev/null; then
        # 如果 fnm 和 node 都已安装，继续其他步骤
        echo_info "Node.js 已通过 fnm 安装"
    else
        # 如果使用 nvm，继续执行安装节点
        # 安装 Node.js
        if ! install_node; then
            echo_error "Node.js 安装失败"
            exit 1
        fi
    fi
    
    # 验证安装
    verify_installation
    
    # 设置默认版本（如果使用 nvm）
    if command -v nvm &> /dev/null; then
        set_default_version
    fi
    
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
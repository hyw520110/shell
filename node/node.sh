#!/bin/bash

# 设置严格模式，但允许某些命令失败
set -e -o pipefail

# 默认值
NODE_VERSION="22.17.0"
NVM_VERSION="v0.40.3"  # 默认 nvm 版本
REGISTRY_TYPE="taobao"
USE_FNM=true   # 默认使用 fnm
USE_NVM=false  # 默认不使用 nvm
ACTION="install"
UNINSTALL_MANAGER=""
ASSUME_YES=false

# 镜像源配置
OFFICIAL_REGISTRY="https://registry.npmjs.org/"
TAOBAO_REGISTRY="https://registry.npmmirror.com/"
HUAWEI_REGISTRY="https://mirrors.huaweicloud.com/repository/npm/"
TENCENT_REGISTRY="https://mirrors.cloud.tencent.com/npm/"

# fnm 下载镜像源配置
FNM_MIRRORS=(
    "https://github.com/Schniz/fnm/releases/download"
    "https://ghproxy.com/https://github.com/Schniz/fnm/releases/download"
    "https://hub.gitmirror.com/https://github.com/Schniz/fnm/releases/download"
    "https://gh.api.99988866.xyz/https://github.com/Schniz/fnm/releases/download"
    "https://mirror.ghproxy.com/https://github.com/Schniz/fnm/releases/download"
    "https://ghproxy.net/https://github.com/Schniz/fnm/releases/download"
)

# Node.js 下载镜像源配置
NODEJS_MIRRORS=(
    "https://mirrors.aliyun.com/nodejs-release/"
    "https://npmmirror.com/mirrors/node/"
    "https://nodejs.org/dist/"
)

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
  --uninstall [版本]
                 卸载指定的 Node.js 版本
  --uninstall-node 版本
                 卸载指定的 Node.js 版本
  --uninstall-manager nvm|fnm
                 卸载版本管理器及其管理的所有 Node.js 版本
  --uninstall-nvm
                 卸载 nvm 及其管理的所有 Node.js 版本
  -y, --yes      跳过卸载确认

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
    --uninstall)
      ACTION="uninstall_node"
      if [[ $# -gt 1 && "$2" != -* ]]; then
        NODE_VERSION="$2"
        NODE_VERSION_SET=true
        shift 2
      else
        NODE_VERSION=""
        shift
      fi
      ;;
    --uninstall-node)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "[错误] --uninstall-node 需要指定 Node.js 版本" >&2
        exit 1
      fi
      ACTION="uninstall_node"
      NODE_VERSION="$2"
      NODE_VERSION_SET=true
      shift 2
      ;;
    --uninstall-manager)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "[错误] --uninstall-manager 需要指定 nvm 或 fnm" >&2
        exit 1
      fi
      case "$2" in
        nvm)
          USE_FNM=false
          USE_NVM=true
          ;;
        fnm)
          USE_FNM=true
          USE_NVM=false
          ;;
        *)
          echo "[错误] 不支持的版本管理器: $2（可选 nvm 或 fnm）" >&2
          exit 1
          ;;
      esac
      ACTION="uninstall_manager"
      UNINSTALL_MANAGER="$2"
      shift 2
      ;;
    --uninstall-nvm)
      ACTION="uninstall_manager"
      UNINSTALL_MANAGER="nvm"
      USE_FNM=false
      USE_NVM=true
      shift
      ;;
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
    *)
      # 如果不是选项，则认为是位置参数
      if [[ "$ACTION" == "uninstall_node" && -z "$NODE_VERSION_SET" ]]; then
        NODE_VERSION="$1"
        NODE_VERSION_SET=true
      elif [[ "$ACTION" == "install" && -z "$NODE_VERSION_SET" ]]; then
        NODE_VERSION="$1"
        NODE_VERSION_SET=true
      elif [[ "$ACTION" == "install" && -z "$NVM_VERSION_SET" ]]; then
        NVM_VERSION="$1"
        NVM_VERSION_SET=true
      else
        echo "[错误] 无法识别的参数: $1" >&2
        exit 1
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

detect_shell_config_files() {
    local shell_name
    shell_name=$(basename "${SHELL:-}")
    local files=()

    case "$shell_name" in
        zsh)
            files+=("$HOME/.zshrc")
            ;;
        bash)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                files+=("$HOME/.bash_profile")
                files+=("$HOME/.bashrc")
            else
                files+=("$HOME/.bashrc")
                files+=("$HOME/.profile")
            fi
            ;;
        *)
            files+=("$HOME/.profile")
            ;;
    esac

    for existing in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [[ -f "$existing" ]] || continue
        local found=false
        for item in "${files[@]}"; do
            [[ "$item" == "$existing" ]] && found=true
        done
        [[ "$found" == false ]] && files+=("$existing")
    done

    printf '%s\n' "${files[@]}"
}

upsert_managed_block() {
    local file="$1"
    local begin="$2"
    local end="$3"
    local content="$4"

    mkdir -p "$(dirname "$file")"
    touch "$file"

    local tmp
    tmp=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        skip != 1 {print}
    ' "$file" > "$tmp"

    {
        cat "$tmp"
        printf '\n%s\n%s\n%s\n' "$begin" "$content" "$end"
    } > "$file"
    rm -f "$tmp"
}

remove_managed_block() {
    local file="$1"
    local begin="$2"
    local end="$3"

    [[ -f "$file" ]] || return 0

    local tmp
    tmp=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        skip != 1 {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

remove_managed_shell_env() {
    local manager="$1"
    local begin
    local end

    case "$manager" in
        nvm)
            begin="# >>> shell/node nvm >>>"
            end="# <<< shell/node nvm <<<"
            ;;
        fnm)
            begin="# >>> shell/node fnm >>>"
            end="# <<< shell/node fnm <<<"
            ;;
        *)
            echo_error "不支持的版本管理器: $manager"
            return 1
            ;;
    esac

    while IFS= read -r rc_file; do
        [[ -n "$rc_file" ]] || continue
        if [[ -f "$rc_file" ]] && grep -Fqx "$begin" "$rc_file"; then
            remove_managed_block "$rc_file" "$begin" "$end"
            echo_info "已移除版本管理器配置: $rc_file"
        fi
    done < <(detect_shell_config_files)
}

configure_fnm_shell_env() {
    local fnm_dir="${1:-$HOME/.fnm}"
    local begin="# >>> shell/node fnm >>>"
    local end="# <<< shell/node fnm <<<"
    local content
    content=$(cat <<EOF
export PATH="$fnm_dir:\$PATH"
if command -v fnm >/dev/null 2>&1; then
  eval "\$(fnm env)"
fi
EOF
)

    local configured=0
    while IFS= read -r rc_file; do
        [[ -n "$rc_file" ]] || continue
        upsert_managed_block "$rc_file" "$begin" "$end" "$content"
        echo_info "已更新 fnm 环境配置: $rc_file"
        configured=1
    done < <(detect_shell_config_files)

    [[ "$configured" -eq 1 ]]
}

configure_nvm_shell_env() {
    local nvm_dir
    nvm_dir=$(find_nvm_dir)
    local begin="# >>> shell/node nvm >>>"
    local end="# <<< shell/node nvm <<<"
    local content
    content=$(cat <<EOF
export NVM_DIR="$nvm_dir"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"
EOF
)

    local configured=0
    while IFS= read -r rc_file; do
        [[ -n "$rc_file" ]] || continue
        upsert_managed_block "$rc_file" "$begin" "$end" "$content"
        echo_info "已更新 nvm 环境配置: $rc_file"
        configured=1
    done < <(detect_shell_config_files)

    [[ "$configured" -eq 1 ]]
}

# 用户确认函数
user_confirm() {
    local prompt="$1"
    local response
    
    if [ "$ASSUME_YES" = true ] || [ "${AUTO_INSTALL:-false}" = true ]; then
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
    if [ -n "${NVM_DIR:-}" ] && [ -d "$NVM_DIR" ]; then
        echo "$NVM_DIR"
    elif [ -d "$HOME/.nvm" ]; then
        echo "$HOME/.nvm"
    elif [ -d "$HOME/.config/nvm" ]; then
        echo "$HOME/.config/nvm"
    else
        echo "$HOME/.nvm"  # 默认位置
    fi
}

# 带超时的 curl 下载函数
curl_with_timeout() {
    local url="$1"
    local output="$2"
    local timeout=30
    
    if curl -fSL --connect-timeout "$timeout" --max-time "$((timeout * 2))" "$url" -o "$output" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 从多个镜像源下载文件
download_from_mirrors() {
    local filename="$1"
    shift
    local mirrors=("$@")
    
    # 优先检查用户下载目录
    local user_download_dir="$HOME/Downloads"
    if [ -f "$user_download_dir/$(basename "$filename")" ]; then
        echo_info "在下载目录中找到已有文件: $user_download_dir/$(basename "$filename")"
        cp "$user_download_dir/$(basename "$filename")" "$filename"
        return 0
    fi
    
    echo_info "尝试下载 $filename，共 ${#mirrors[@]} 个镜像源..."
    
    for i in "${!mirrors[@]}"; do
        local mirror="${mirrors[$i]}"
        local url="${mirror}/${filename}"
        local temp_file=$(mktemp)
        
        echo_info "[$((i + 1))/${#mirrors[@]}] 尝试: $url"
        
        if curl_with_timeout "$url" "$temp_file"; then
            echo_info "下载成功！"
            # 同时备份到下载目录
            mkdir -p "$user_download_dir"
            cp "$temp_file" "$user_download_dir/$(basename "$filename")" 2>/dev/null || true
            
            mv "$temp_file" "$filename" 2>/dev/null || {
                echo_error "移动文件失败"
                rm -f "$temp_file"
                return 1
            }
            return 0
        else
            echo_warn "从该源下载失败，尝试下一个..."
            rm -f "$temp_file"
        fi
    done
    
    echo_error "所有镜像源都下载失败"
    return 1
}

# 安装 nvm
install_nvm() {
    echo_info "正在安装 nvm $NVM_VERSION..."
    
    # nvm 安装脚本镜像源
    local nvm_script_mirrors=(
        "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION"
        "https://ghproxy.com/https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION"
        "https://hub.gitmirror.com/https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION"
    )
    
    local temp_dir
    temp_dir=$(mktemp -d)
    local install_script="$temp_dir/install.sh"
    
    # 尝试从多个镜像源下载安装脚本
    echo_info "正在获取 nvm 安装脚本..."
    # 为 nvm 脚本特殊处理，防止重名为 install.sh 混淆，使用带版本的名字
    local nvm_filename="nvm-install-${NVM_VERSION}.sh"
    if download_from_mirrors "$nvm_filename" "${nvm_script_mirrors[@]}"; then
        mv "$nvm_filename" "$install_script"
        
        echo_info "正在执行 nvm 安装脚本..."
        bash "$install_script"
        
        # 清理临时文件
        rm -rf "$temp_dir"
        
        echo_info "nvm 安装完成"
        return 0
    else
        rm -rf "$temp_dir"
        echo_error "无法获取 nvm 安装脚本"
        return 1
    fi
}

# 安装 fnm (Fast Node Manager)
install_fnm() {
    echo_info "正在安装 fnm (Fast Node Manager)..."
    
    # 根据操作系统架构确定下载文件名
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
    
    # 确定文件名
    local fnm_filename
    if [ "$os" = "Linux" ]; then
        if [ "$arch" = "arm64" ]; then
            fnm_filename="fnm-arm64-linux.zip"
        else
            fnm_filename="fnm-linux.zip"
        fi
    elif [ "$os" = "Darwin" ]; then
        fnm_filename="fnm-macos.zip"
    else
        echo_error "不支持的操作系统: $os"
        return 1
    fi
    
    # 获取最新的 fnm 版本号（如果失败则使用默认版本）
    local latest_version="v1.39.0"
    local version_api_urls=(
        "https://api.github.com/repos/Schniz/fnm/releases/latest"
        "https://ghproxy.com/https://api.github.com/repos/Schniz/fnm/releases/latest"
    )
    
    # 如果本地 Downloads 目录有 fnm-macos.zip，尝试从中推断版本或直接使用
    local user_download_dir="$HOME/Downloads"
    if [ -f "$user_download_dir/$fnm_filename" ]; then
        echo_info "检测到本地已存在 $fnm_filename，将跳过版本检测并优先使用本地文件"
    else
        for api_url in "${version_api_urls[@]}"; do
            local fetched_version
            fetched_version=$(curl -s --connect-timeout 10 "$api_url" 2>/dev/null | grep "tag_name" | head -1 | cut -d '"' -f 4 | tr -d '\r')
            if [ -n "$fetched_version" ]; then
                latest_version="$fetched_version"
                echo_info "检测到 fnm 最新版本: $latest_version"
                break
            fi
        done
    fi
    
    if [ "$latest_version" = "v1.38.1" ]; then
        echo_warn "无法获取最新版本，使用默认版本: $latest_version"
    fi
    
    # 准备下载
    local temp_dir
    temp_dir=$(mktemp -d)
    local fnm_zip="$temp_dir/fnm.zip"
    
    # 这里我们改变策略：如果是本地文件，download_from_mirrors 会处理
    # 但由于 download_from_mirrors 期望的是 $mirror/$filename，我们传入带版本的路径
    local download_target="${latest_version}/${fnm_filename}"
    # 如果本地存在不带版本号的文件，我们传给 download_from_mirrors 时需要能匹配到
    
    # 针对已手动下载的情况，如果 filename 本身就存在于 Downloads
    if [ -f "$user_download_dir/$fnm_filename" ]; then
        echo_info "正在使用本地缓存文件: $user_download_dir/$fnm_filename"
        cp "$user_download_dir/$fnm_filename" "$fnm_zip"
    else
        if download_from_mirrors "$download_target" "${FNM_MIRRORS[@]}"; then
            mv "$(basename "$download_target")" "$fnm_zip"
        else
            rm -rf "$temp_dir"
            echo_error "fnm 安装失败"
            return 1
        fi
    fi
        
        # 解压 zip 文件
        if command -v unzip >/dev/null 2>&1; then
            unzip -o "$fnm_zip" -d "$temp_dir"
            
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
}

# 加载已存在的 fnm，不执行安装
load_fnm() {
    # 临时将 fnm 添加到 PATH（仅对当前会话）
    export PATH="$HOME/.fnm:$PATH"

    # 检查 fnm 是否可用
    if command -v fnm >/dev/null 2>&1; then
        echo_info "fnm 已加载"
        eval "$(fnm env)"
        return 0
    fi

    return 1
}

# 初始化 fnm
init_fnm() {
    if load_fnm; then
        return 0
    elif install_fnm; then
        load_fnm
    else
        echo_error "fnm 初始化失败"
        return 1
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
    
    # 设置 Node.js 镜像源
    for mirror in "${NODEJS_MIRRORS[@]}"; do
        echo_info "尝试使用 Node.js 镜像源: $mirror"
        export FNM_NODE_DIST_MIRROR="$mirror"
        
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
                
                configure_fnm_shell_env "$HOME/.fnm" || echo_warn "自动更新 shell 配置失败，请手动配置 fnm"
                echo ""
                echo_info "=========================================="
                echo_info "fnm 环境变量已自动写入 shell 配置文件。"
                echo_info "请重新打开终端，或执行: source ~/.zshrc / source ~/.bashrc"
                echo_info "=========================================="
                echo ""
                return 0
            else
                echo_error "Node.js 命令不可用，请检查 fnm 环境配置"
                return 1
            fi
        else
            echo_warn "使用该镜像源安装失败，尝试下一个..."
        fi
    done
    
    echo_error "所有镜像源都无法安装 Node.js"
    return 1
}

# 加载已存在的 nvm，不执行安装
load_nvm() {
    local nvm_dir
    nvm_dir=$(find_nvm_dir)

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

# 初始化 nvm
init_nvm() {
    local nvm_dir
    nvm_dir=$(find_nvm_dir)

    if [ ! -d "$nvm_dir" ]; then
        if ! install_nvm; then
            echo_error "nvm 安装失败"
            return 1
        fi
    fi

    load_nvm
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
        return 0
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

# 代理检测函数
detect_and_set_proxy() {
    # 如果用户已经手动设置了代理，则跳过自动检测
    if [ -n "$http_proxy" ] || [ -n "$HTTP_PROXY" ] || [ -n "$https_proxy" ] || [ -n "$HTTPS_PROXY" ]; then
        echo_info "检测到已手动设置代理，跳过自动检测"
        return 0
    fi

    local common_ports=(7890 7891 1080 10808 10809 8889 8118 20171)
    local proxy_found=false
    
    echo_info "正在检测本地常用代理端口..."
    
    for port in "${common_ports[@]}"; do
        # 使用 curl 探测端口是否开放 (不发请求，只建立连接)
        if curl -s --connect-timeout 0.5 "http://127.0.0.1:$port" > /dev/null 2>&1 || [ $? -eq 52 ] || [ $? -eq 56 ]; then
            # 52 (Empty reply) 或 56 (Failure in receiving network data) 通常表示端口开放但协议不匹配或连接被拒绝，但在探测场景下足以说明端口监听中
            echo_info "检测到本地代理端口: $port"
            export HTTP_PROXY="http://127.0.0.1:$port"
            export HTTPS_PROXY="http://127.0.0.1:$port"
            export http_proxy="http://127.0.0.1:$port"
            export https_proxy="http://127.0.0.1:$port"
            proxy_found=true
            break
        fi
    done
    
    if [ "$proxy_found" = true ]; then
        echo_info "已自动应用本地代理: $HTTP_PROXY"
    else
        echo_info "未检测到活跃的本地代理端口"
    fi
}

# 卸载指定的 Node.js 版本
uninstall_node_version() {
    local manager="$1"
    local version="$2"

    if [ -z "$version" ]; then
        echo_error "卸载 Node.js 版本时必须指定版本，例如: --uninstall 20.10.0"
        return 1
    fi

    case "$manager" in
        nvm)
            if ! load_nvm; then
                echo_error "未找到可用的 nvm，无法卸载 Node.js v$version"
                return 1
            fi
            if ! user_confirm "是否通过 nvm 卸载 Node.js v$version？"; then
                echo_info "已取消卸载"
                return 0
            fi
            if nvm uninstall "$version"; then
                echo_info "Node.js v$version 卸载完成"
            else
                echo_error "Node.js v$version 卸载失败。若该版本正在使用，请先切换到其他版本"
                return 1
            fi
            ;;
        fnm)
            if ! load_fnm; then
                echo_error "未找到可用的 fnm，无法卸载 Node.js v$version"
                return 1
            fi
            if ! user_confirm "是否通过 fnm 卸载 Node.js v$version？"; then
                echo_info "已取消卸载"
                return 0
            fi
            if fnm uninstall "$version"; then
                echo_info "Node.js v$version 卸载完成"
            else
                echo_error "Node.js v$version 卸载失败。若该版本正在使用，请先切换到其他版本"
                return 1
            fi
            ;;
        *)
            echo_error "不支持的版本管理器: $manager"
            return 1
            ;;
    esac
}

# 卸载版本管理器及其管理的 Node.js 版本
uninstall_manager() {
    local manager="$1"
    local target_dirs=()
    local dir

    case "$manager" in
        nvm)
            local nvm_dir
            nvm_dir=$(find_nvm_dir)
            target_dirs=("$nvm_dir")
            ;;
        fnm)
            # 本脚本的 fnm 二进制目录，以及 fnm 在 macOS/Linux 的常见数据目录
            target_dirs=(
                "$HOME/.fnm"
                "$HOME/.local/share/fnm"
                "$HOME/Library/Application Support/fnm"
            )
            ;;
        *)
            echo_error "不支持的版本管理器: $manager"
            return 1
            ;;
    esac

    echo_warn "此操作将删除 $manager 及其管理的所有 Node.js 版本"
    if ! user_confirm "确认继续卸载 $manager？"; then
        echo_info "已取消卸载"
        return 0
    fi

    for dir in "${target_dirs[@]}"; do
        if [ -d "$dir" ]; then
            if [[ -z "$dir" || "$dir" == "/" || "$dir" == "$HOME" ]]; then
                echo_warn "检测到不安全的卸载目录，已跳过: $dir"
                continue
            fi
            rm -rf -- "$dir"
            echo_info "已删除: $dir"
        fi
    done

    remove_managed_shell_env "$manager"
    echo_info "$manager 卸载完成。npm/yarn/pnpm 缓存和项目目录未删除。"
}

perform_uninstall() {
    if [ "$ACTION" = "uninstall_manager" ]; then
        uninstall_manager "$UNINSTALL_MANAGER"
        return $?
    fi

    local manager="fnm"
    [ "$USE_NVM" = true ] && manager="nvm"
    uninstall_node_version "$manager" "$NODE_VERSION"
}

# 主函数
main() {
    if [ "$ACTION" != "install" ]; then
        perform_uninstall
        return $?
    fi

    echo_info "开始 Node.js 环境配置..."
    
    # 自动检测并设置本地代理
    detect_and_set_proxy
    
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
        # 使用 nvm
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
        else
            # 安装 Node.js
            if ! install_node; then
                echo_error "Node.js 安装失败"
                exit 1
            fi
            configure_nvm_shell_env || echo_warn "自动更新 shell 配置失败，请手动配置 nvm"
        fi
    fi
    
    # 验证安装
    verify_installation
    
    # 设置默认版本（如果使用 nvm）
    if [ "$USE_NVM" = true ] && type nvm >/dev/null 2>&1; then
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

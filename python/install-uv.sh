#!/bin/bash

set -euo pipefail  # 出错时退出，使用未定义变量时退出，管道失败时退出

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # 无颜色

# === 常量定义 ===
readonly UV_INSTALL_SCRIPT_URL="https://astral.sh/uv/install.sh"
readonly DEFAULT_UV_DIR="$HOME/.local/bin"
readonly UV_BINARY="$DEFAULT_UV_DIR/uv"
readonly DEFAULT_PYPI_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
readonly ALIYUN_PYPI_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
readonly PYPI_ORG_MIRROR="https://pypi.org/simple/"

# === 全局变量 ===
UV_DIR="$DEFAULT_UV_DIR"
INSTALL_PYTHON_VERSION=""
USE_PYTHON_VERSION=""
DRY_RUN=false
FORCE_REINSTALL=false
SETUP_SHELL_CONFIG=true
USE_PYPI_MIRROR="$DEFAULT_PYPI_MIRROR"
UNINSTALL_MODE=false

show_usage() {
    cat << 'EOF'
用法: $0 [选项]

为 Linux/macOS 安装和配置 uv (Python 包管理器)。

选项:
    -h, --help                  显示此帮助信息
    -d, --dir PATH              安装目录 (默认: $DEFAULT_UV_DIR)
    -m, --mirror URL            PyPI 镜像 URL (默认: $DEFAULT_PYPI_MIRROR)
    --dry-run                   显示将要执行的操作但不实际更改
    --force                     即使已安装也重新安装 uv
    --no-shell-config           跳过 shell 配置
    --install-python VERSION    安装和配置特定的 Python 版本
    --use-python VERSION        设置指定版本为默认 python/python3
    --uninstall                 卸载 uv（删除二进制文件和 shell 配置）

示例:
    $0                                  # 使用默认设置安装
    $0 --mirror $ALIYUN_PYPI_MIRROR    # 使用阿里云镜像
    $0 --dir /opt/uv --force           # 在 /opt/uv 中强制重新安装
    $0 --dry-run --mirror $PYPI_ORG_MIRROR  # 使用 PyPI.org 进行试运行
    $0 --install-python 3.12           # 安装 Python 3.12
    $0 --use-python 3.12               # 设置 Python 3.12 为默认版本
    $0 --install-python 3.12 --use-python 3.12  # 安装并设为默认
    $0 --uninstall                     # 卸载 uv

使用指南
常用命令
  初始化项目：uv init my_project
  创建并同步带有依赖项的项目:
    uv init project-name
    cd project-name
    uv add requests
    uv sync
  安装特定版本的 Python：uv python install 3.11
  列出已安装的 Python 版本：uv python list
  卸载特定版本的 Python：uv python uninstall 3.11.2
  查找可用或已安装的 Python 版本：uv python find 3.11 （用于脚本或 IDE 集成）
  显示 `uv` 自身使用的 Python 版本：uv python dir
  指定 Python 版本：uv init my_project --python 3.11
  添加生产依赖：uv add requests
  添加开发依赖：uv add pytest --dev
  移除依赖：uv remove requests

📦 依赖管理：
  安装全局工具：uv tool install ruff
  同步依赖：uv sync
  升级依赖：uv sync --upgrade
  升级特定包：uv sync --upgrade-package requests
  查看已安装包：uv pip list
  生成 requirements.txt：uv pip freeze > requirements.txt
  安装 requirements.txt：uv pip install -r requirements.txt
  运行 Python 代码:
    uv run python script.py
  使用特定 Python 版本:
    uv run --python 3.11 -c "import sys; print(sys.version)"
🌐 国内镜像说明：
  默认使用清华源（https://pypi.tuna.tsinghua.edu.cn/simple），如需切换镜像：
  1. 手动修改环境变量 UV_INDEX_URL
  2. 或运行脚本时指定：UV_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ ./install_uv.sh

🗑️ 清理缓存：
  清理 uv 缓存：uv cache clean
  清理 pip 缓存：uv pip cache purge

高级配置
  临时使用不同的PyPI索引：
    UV_INDEX_URL=https://pypi.org/simple uv pip install package_name

  配置uv缓存目录：
    export UV_CACHE_DIR=""/path/to/cache""

  使用特定Python解释器：
    export UV_PYTHON=""/path/to/python""

故障排除
  如果安装后找不到uv：
    - 尝试打开新终端
    - 或者执行：source ~/.zshrc (或 ~/.bashrc)
    - 检查 $UV_DIR 是否在PATH中

更多信息: https://github.com/astral-sh/uv
EOF
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# sed 命令路径，用于处理配置文件
SED_CMD="sed"

# 尝试检测 sed 命令路径，优先使用 gsed（GNU sed）或 sed
if command -v gsed >/dev/null 2>&1; then
    SED_CMD="gsed"
elif command -v sed >/dev/null 2>&1; then
    SED_CMD="sed"
else
    print_error "找不到 sed 命令，这是必需的工具"
    exit 1
fi

uninstall_uv() {
    local uninstall_dir="$1"
    local config_file

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 模拟卸载 uv"
        print_info "将删除: $uninstall_dir/uv"

        config_file=$(get_shell_config_file)
        print_info "将从 $config_file 中移除 uv 相关配置"
        return 0
    fi

    # 检查 uv 是否存在
    if [ ! -f "$uninstall_dir/uv" ]; then
        print_warning "uv 二进制文件不存在于 $uninstall_dir"
        print_info "可能已卸载或安装在其他位置"
        return 0
    fi

    # 删除 uv 二进制文件
    if rm "$uninstall_dir/uv"; then
        print_success "已删除 uv 二进制文件: $uninstall_dir/uv"
    else
        print_error "删除 uv 二进制文件失败"
        return 1
    fi

    # 从 shell 配置文件中移除 uv 相关配置
    config_file=$(get_shell_config_file)
    if [ -f "$config_file" ]; then
        print_info "正在从 $config_file 中移除 uv 相关配置..."

        # 备份配置文件
        local backup_config="${config_file}.uv_backup"
        cp "$config_file" "$backup_config"
        print_info "已备份原配置文件到: $backup_config"

        # 使用全局变量 SED_CMD 来处理配置文件
        # 首先删除 uv 的 PATH 添加行（包括注释和导出语句）
        if $SED_CMD -i.bak '/# 由 uv 安装脚本添加/d; /export PATH=".*\$PATH"/d; /# uv 的 PyPI 镜像/d; /export UV_INDEX_URL=/d' "$config_file"; then
            print_success "已从 $config_file 中移除 uv 相关配置"
        else
            print_error "修改 $config_file 失败，正在恢复备份..."
            mv "$backup_config" "$config_file" 2>/dev/null || print_error "恢复备份失败，请检查 $backup_config"
            return 1
        fi

        # 删除备份文件
        rm -f "$config_file.bak" 2>/dev/null
    else
        print_warning "$config_file 不存在，跳过配置文件修改"
    fi

    print_success "uv 卸载完成！"
    print_info "提示: 如果当前终端中正在使用 uv，请重新打开终端或运行: source $config_file"
}

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "Linux";;
        Darwin*)    echo "macOS";;
        CYGWIN*|MINGW*) echo "Windows";;
        *)          echo "Unknown";;
    esac
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64)     echo "x86_64";;
        aarch64|arm64) echo "aarch64";;
        *)          echo "unknown";;
    esac
}

check_dependencies() {
    local deps=()
    local os_type
    os_type=$(detect_os)

    # 检查必需工具
    if ! command -v curl >/dev/null 2>&1; then
        deps+=("curl")
    fi

    if [ ${#deps[@]} -eq 0 ]; then
        return 0
    fi

    print_info "正在安装缺失的依赖项: ${deps[*]}"

    case "$os_type" in
        "Linux")
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update
                sudo apt-get install -y "${deps[@]}"
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y "${deps[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "${deps[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                sudo pacman -S --noconfirm "${deps[@]}"
            else
                print_error "未找到已知的包管理器。请手动安装 curl。"
                exit 1
            fi
            ;;
        "macOS")
            if command -v brew >/dev/null 2>&1; then
                brew install "${deps[@]}"
            else
                print_error "macOS 上需要 Homebrew 来安装依赖项。请先安装 Homebrew。"
                exit 1
            fi
            ;;
        *)
            print_error "不支持的操作系统: $os_type"
            exit 1
            ;;
    esac
}

get_shell_config_file() {
    local shell_name
    shell_name="$(basename "$SHELL")"

    case "$shell_name" in
        zsh)
            if [ -f "$HOME/.zshrc" ]; then
                echo "$HOME/.zshrc"
            elif [ -f "$HOME/.zprofile" ]; then
                echo "$HOME/.zprofile"
            else
                echo "$HOME/.zshrc"  # default
            fi
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.profile"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

add_to_path() {
    local target_dir="$1"
    local config_file="$2"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将把 $target_dir 添加到 $config_file 中的 PATH"
        return 0
    fi

    # 检查是否已经在配置文件的 PATH 中
    if ! grep -q "export PATH=.*$target_dir" "$config_file" 2>/dev/null; then
        {
            echo ""
            echo "# 由 uv 安装脚本添加"
            echo "export PATH=\"$target_dir:\$PATH\""
        } >> "$config_file"
        print_success "已将 $target_dir 添加到 $config_file 中的 PATH"
    else
        print_info "路径已在 $config_file 中配置"
    fi
}

configure_uv_index_url() {
    local pypi_mirror="$1"
    local config_file="$2"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将在 $config_file 中配置 PyPI 镜像 $pypi_mirror"
        return 0
    fi

    # 检查配置文件中是否已设置 UV_INDEX_URL
    if ! grep -q "UV_INDEX_URL" "$config_file" 2>/dev/null; then
        {
            echo ""
            echo "# uv 的 PyPI 镜像"
            echo "export UV_INDEX_URL=\"$pypi_mirror\""
        } >> "$config_file"
        print_success "已在 $config_file 中配置 PyPI 镜像"
    else
        print_info "PyPI 镜像已在 $config_file 中配置"
    fi

    # 为当前会话设置
    export UV_INDEX_URL="$pypi_mirror"
}

install_uv() {
    local install_dir="$1"
    
    if [ "$DRY_RUN" = true ]; then
        if [ -x "$install_dir/uv" ]; then
            print_info "试运行: uv 已安装在 $install_dir"
        else
            print_info "试运行: 将安装 uv 到 $install_dir"
        fi
        return 0
    fi

    # Create installation directory
    mkdir -p "$install_dir"

    # Download and run the official install script
    if XDG_BIN_HOME="$install_dir" curl -LsSf "$UV_INSTALL_SCRIPT_URL" | sh; then
        print_success "uv installed successfully to $install_dir"
    else
        print_error "uv 安装失败"
        exit 1
    fi
}

verify_installation() {
    if command -v uv >/dev/null 2>&1; then
        local version
        version=$(uv --version)
        print_success "Installation verified. $version"
        return 0
    else
        print_error "安装后 uv 在 PATH 中不可用"
        return 1
    fi
}


parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                UV_DIR="$2"
                shift 2
                ;;
            -m|--mirror)
                USE_PYPI_MIRROR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --no-shell-config)
                SETUP_SHELL_CONFIG=false
                shift
                ;;
            --install-python)
                INSTALL_PYTHON_VERSION="$2"
                shift 2
                ;;
            --use-python)
                USE_PYTHON_VERSION="$2"
                shift 2
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

main() {
    print_header "uv 安装/卸载脚本"
    print_info "操作系统: $(detect_os) $(detect_architecture)"

    parse_arguments "$@"

    # 检查是否是卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        print_info "卸载目录: $UV_DIR"
        if [ "$DRY_RUN" = true ]; then
            print_warning "试运行模式: 不会进行任何更改"
        fi
        uninstall_uv "$UV_DIR"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_warning "试运行模式: 不会进行任何更改"
    fi

    check_dependencies

    # 检查 uv 是否已安装
    if [ -x "$UV_DIR/uv" ] && [ "$FORCE_REINSTALL" = false ]; then
        print_info "uv 已安装在 $UV_DIR"
        if command -v uv >/dev/null 2>&1; then
            print_info "当前版本: $(uv --version)"
        fi
        print_warning "使用 --force 重新安装"
    else
        install_uv "$UV_DIR"
    fi

    # 为当前会话临时添加到 PATH
    if [[ ":$PATH:" != *":$UV_DIR:"* ]]; then
        export PATH="$UV_DIR:$PATH"
        print_info "已将 $UV_DIR 添加到当前会话的 PATH"
    fi

    # 如果需要则配置 shell
    if [ "$SETUP_SHELL_CONFIG" = true ]; then
        local shell_config
        shell_config=$(get_shell_config_file)

        print_info "Shell 配置文件: $shell_config"

        add_to_path "$UV_DIR" "$shell_config"
        configure_uv_index_url "$USE_PYPI_MIRROR" "$shell_config"
    fi

    # 验证安装
    verify_installation

    # 如果指定了 Python 版本则安装
    if [ -n "$INSTALL_PYTHON_VERSION" ]; then
        print_info "正在安装 Python $INSTALL_PYTHON_VERSION..."
        if [ "$DRY_RUN" = false ]; then
            uv python install "$INSTALL_PYTHON_VERSION"
        else
            print_info "试运行: 将安装 Python $INSTALL_PYTHON_VERSION"
        fi
    fi

    # 处理默认 Python 版本设置
    if [ -n "$USE_PYTHON_VERSION" ]; then
        # 用户明确指定了版本
        set_default_python "$USE_PYTHON_VERSION"
    else
        # 未指定版本，检查是否有多版本并交互式选择
        interactive_select_python
    fi

    print_header "安装完成!"
    print_success "uv 现已安装和配置"

    # 显示版本检测信息
    show_version_info

    if [ "$SETUP_SHELL_CONFIG" = true ]; then
        print_info "要在新终端会话中使用 uv，请打开新终端或运行:"
        print_info "  source $shell_config"
    fi

    # 显示常用命令提示
    show_quick_start_guide

}

# 显示版本检测信息
show_version_info() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  版本检测${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # uv 版本
    if command -v uv >/dev/null 2>&1; then
        local uv_version=$(uv --version 2>/dev/null || echo "未知")
        print_success "uv: $uv_version"
    else
        print_error "uv: 未找到"
    fi

    # Python 版本 (通过 uv)
    if command -v uv >/dev/null 2>&1; then
        local uv_python_list=$(uv python list 2>/dev/null | head -5)
        if [ -n "$uv_python_list" ]; then
            print_info "已安装的 Python 版本:"
            echo "$uv_python_list" | while read -r line; do
                echo -e "  ${GREEN}•${NC} $line"
            done
        else
            print_info "尚未通过 uv 安装 Python"
            print_info "提示: 运行 'uv python install 3.12' 安装 Python 3.12"
        fi
    fi

    # 系统 Python 版本
    if command -v python3 >/dev/null 2>&1; then
        local sys_python=$(python3 --version 2>/dev/null || echo "未知")
        print_info "系统 Python: $sys_python"
    fi

    echo ""
}

# 交互式选择 Python 版本
interactive_select_python() {
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi

    # 获取已安装的 Python 版本列表（排除 "download available" 的）
    local installed_pythons=()
    while IFS= read -r line; do
        # 跳过包含 "download available" 的行（未安装的）
        [[ "$line" == *"download available"* ]] && continue
        # 提取版本号和路径
        local version=$(echo "$line" | awk '{print $1}')
        if [ -n "$version" ]; then
            installed_pythons+=("$line")
        fi
    done < <(uv python list 2>/dev/null | grep -v "download available" || true)

    local count=${#installed_pythons[@]}

    # 如果没有安装任何版本，提示安装
    if [ "$count" -eq 0 ]; then
        echo ""
        print_info "尚未通过 uv 安装任何 Python 版本"
        read -p "是否现在安装 Python? (y/N): " install_now
        if [[ "$install_now" =~ ^[Yy]$ ]]; then
            read -p "请输入要安装的版本 (例如: 3.12): " py_version
            if [ -n "$py_version" ]; then
                uv python install "$py_version"
                set_default_python "$py_version"
            fi
        fi
        return 0
    fi

    # 如果只安装了一个版本，直接询问是否设为默认
    if [ "$count" -eq 1 ]; then
        local version=$(echo "${installed_pythons[0]}" | awk '{print $1}')
        echo ""
        print_info "检测到已安装的 Python 版本:"
        echo "  ${GREEN}•${NC} ${installed_pythons[0]}"
        echo ""
        read -p "是否将 Python $version 设为默认? (Y/n): " set_default
        if [[ ! "$set_default" =~ ^[Nn]$ ]]; then
            set_default_python "$version"
        else
            print_info "已跳过设置默认 Python"
        fi
        return 0
    fi

    # 多个版本，显示列表让用户选择
    echo ""
    print_info "检测到多个已安装的 Python 版本:"
    echo ""

    # 推荐版本逻辑
    local recommended_idx=0
    local recommended_ver=""

    local i=1
    for py in "${installed_pythons[@]}"; do
        local version=$(echo "$py" | awk '{print $1}')
        local path=$(echo "$py" | awk '{print $2}')

        # 推荐 3.12 版本（稳定且兼容性好）
        if [[ "$version" == *"3.12"* ]] && [ "$recommended_idx" -eq 0 ]; then
            recommended_idx=$i
            recommended_ver="$version"
            printf "  ${CYAN}%2d.${NC} ${GREEN}%-20s${NC} %s ${YELLOW}(推荐)${NC}\n" "$i" "$version" "$path"
        else
            printf "  ${CYAN}%2d.${NC} ${GREEN}%-20s${NC} %s\n" "$i" "$version" "$path"
        fi
        ((i++))
    done

    # 显示推荐说明
    if [ "$recommended_idx" -gt 0 ]; then
        echo ""
        print_info "推荐说明:"
        echo "  • Python 3.12 是目前最稳定的版本，兼容性最佳"
        echo "  • Python 3.13 是最新版本，可能部分包尚未完全支持"
        echo "  • Python 3.11 是较旧版本，新特性较少"
    fi

    echo ""
    printf "  ${YELLOW}0.${NC} 跳过设置（保持当前默认）\n"
    printf "  ${YELLOW}s.${NC} 安装其他版本\n"
    echo ""

    read -p "请选择要设为默认的 Python 版本 [0-$count]: " choice

    case "$choice" in
        0|"")
            print_info "已跳过设置默认 Python"
            ;;
        [Ss])
            read -p "请输入要安装的版本 (例如: 3.13): " py_version
            if [ -n "$py_version" ]; then
                uv python install "$py_version"
                set_default_python "$py_version"
            fi
            ;;
        [1-9]|[1-9][0-9])
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
                local selected="${installed_pythons[$((choice-1))]}"
                local version=$(echo "$selected" | awk '{print $1}')
                set_default_python "$version"
            else
                print_error "无效的选择"
            fi
            ;;
        *)
            print_error "无效的选择"
            ;;
    esac
}

# 设置默认 Python 版本
set_default_python() {
    local version="$1"
    
    print_info "设置 Python $version 为默认版本..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将设置 Python $version 为默认版本"
        return 0
    fi

    # 检查是否已安装该版本
    local uv_python_path=""
    uv_python_path=$(uv python find "${version}" 2>/dev/null || true)
    
    if [[ -z "$uv_python_path" ]] || [[ ! -x "$uv_python_path" ]]; then
        print_warning "Python ${version} 未安装，正在安装..."
        uv python install "${version}"
        uv_python_path=$(uv python find "${version}" 2>/dev/null || true)
    fi

    if [[ -z "$uv_python_path" ]] || [[ ! -x "$uv_python_path" ]]; then
        print_error "无法找到 Python ${version} 的可执行文件"
        return 1
    fi

    print_success "找到 Python ${version}: $uv_python_path"

    # 创建符号链接
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"

    # 备份现有的链接
    local backup_suffix=".backup.$(date +%Y%m%d%H%M%S)"
    
    if [[ -L "$bin_dir/python" ]]; then
        mv "$bin_dir/python" "$bin_dir/python${backup_suffix}" 2>/dev/null || true
        print_info "已备份原有的 python 链接"
    fi
    
    if [[ -L "$bin_dir/python3" ]]; then
        mv "$bin_dir/python3" "$bin_dir/python3${backup_suffix}" 2>/dev/null || true
        print_info "已备份原有的 python3 链接"
    fi

    # 创建新的符号链接
    ln -sf "$uv_python_path" "$bin_dir/python"
    ln -sf "$uv_python_path" "$bin_dir/python3"
    
    print_success "已创建符号链接:"
    print_info "  $bin_dir/python -> $uv_python_path"
    print_info "  $bin_dir/python3 -> $uv_python_path"

    # 确保 PATH 配置正确
    local shell_rc=$(get_shell_config_file)
    
    if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$shell_rc" 2>/dev/null; then
        print_info "添加 PATH 配置到 $shell_rc"
        {
            echo ""
            echo "# uv Python 路径配置"
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$shell_rc"
    fi

    # 验证
    echo ""
    print_success "验证:"
    local new_version=$("$bin_dir/python3" --version 2>&1)
    print_success "Python 版本: $new_version"
    
    echo ""
    print_info "提示:"
    print_info "1. 当前终端请运行: hash -r"
    print_info "2. 新终端将自动使用 Python $version"
}

# 显示快速开始指南
show_quick_start_guide() {
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  快速开始指南${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${BOLD}📦 Python 管理:${NC}"
    echo -e "  ${YELLOW}uv python install 3.12${NC}          安装 Python 3.12"
    echo -e "  ${YELLOW}uv python list${NC}                  列出已安装的 Python"
    echo -e "  ${YELLOW}uv python install 3.11 3.12 3.13${NC}  安装多个版本"
    echo -e "  ${YELLOW}uv python pin 3.12${NC}              当前目录固定 Python 版本"
    echo -e "  ${YELLOW}./install-uv.sh --use-python 3.12${NC} 设置全局默认 Python 版本"
    echo ""

    echo -e "${BOLD}🚀 项目管理:${NC}"
    echo -e "  ${YELLOW}uv init my_project${NC}              初始化新项目"
    echo -e "  ${YELLOW}uv add requests${NC}                 添加依赖"
    echo -e "  ${YELLOW}uv add pytest --dev${NC}             添加开发依赖"
    echo -e "  ${YELLOW}uv sync${NC}                         同步依赖"
    echo -e "  ${YELLOW}uv run python script.py${NC}         运行脚本"
    echo ""

    echo -e "${BOLD}🔧 虚拟环境:${NC}"
    echo -e "  ${YELLOW}uv venv${NC}                         创建虚拟环境"
    echo -e "  ${YELLOW}uv venv --python 3.12${NC}           指定 Python 版本"
    echo -e "  ${YELLOW}source .venv/bin/activate${NC}       激活虚拟环境"
    echo ""

    echo -e "${BOLD}🛠️ 工具安装:${NC}"
    echo -e "  ${YELLOW}uv tool install ruff${NC}            安装全局工具"
    echo -e "  ${YELLOW}uv tool list${NC}                    列出已安装工具"
    echo ""

    echo -e "${BOLD}📋 其他常用:${NC}"
    echo -e "  ${YELLOW}uv pip list${NC}                     查看已安装包"
    echo -e "  ${YELLOW}uv cache clean${NC}                  清理缓存"
    echo -e "  ${YELLOW}uv --help${NC}                       查看帮助"
    echo ""

    echo -e "${CYAN}更多详情: https://docs.astral.sh/uv/${NC}"
    echo ""
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
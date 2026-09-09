#!/bin/bash
# ==================== 系统环境检测模块 ====================
# 提供操作系统识别、依赖检查等功能
# 兼容 Bash 3.2+

# 检测操作系统类型
detect_os() {
    local os_type=$(uname -s)
    case "$os_type" in
        Darwin)
            echo "macOS"
            ;;
        Linux)
            echo "Linux"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# 设置全局 OS 变量
OS=$(detect_os)

find_uv_command() {
    if command -v uv >/dev/null 2>&1; then
        command -v uv
        return 0
    fi

    local candidate
    for candidate in \
        "$HOME/.local/bin/uv" \
        "$HOME/.cargo/bin/uv" \
        "/opt/homebrew/bin/uv" \
        "/usr/local/bin/uv"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

python_version_from_cmd() {
    local py_cmd="$1"
    "$py_cmd" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null
}

python_version_ge_310() {
    local py_cmd="$1"
    local py_ver major_py minor_py
    py_ver=$(python_version_from_cmd "$py_cmd") || return 1
    major_py=$(echo "$py_ver" | cut -d. -f1)
    minor_py=$(echo "$py_ver" | cut -d. -f2)
    [[ "$major_py" =~ ^[0-9]+$ && "$minor_py" =~ ^[0-9]+$ ]] || return 1
    [[ $major_py -gt 3 || ($major_py -eq 3 && $minor_py -ge 10) ]]
}

find_suitable_uv_python() {
    local uv_cmd="$1"
    local preferred="${AI_HUB_PYTHON_VERSION:-3.12}"
    local candidates="$preferred 3.13 3.12 3.11 3.10"
    local seen=" "
    local version py_path

    for version in $candidates; do
        case "$seen" in
            *" $version "*) continue ;;
        esac
        seen="${seen}${version} "

        py_path=$("$uv_cmd" python find "$version" 2>/dev/null || true)
        if [[ -n "$py_path" && -x "$py_path" ]] && python_version_ge_310 "$py_path"; then
            echo "$py_path"
            return 0
        fi
    done

    "$uv_cmd" python list 2>/dev/null | while IFS= read -r line; do
        [[ "$line" == *"download available"* ]] && continue
        py_path=$(echo "$line" | awk '{print $2}')
        if [[ -n "$py_path" && -x "$py_path" ]] && python_version_ge_310 "$py_path"; then
            echo "$py_path"
            return 0
        fi
    done
}

ensure_local_bin_in_path() {
    local bin_dir="$HOME/.local/bin"
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) export PATH="$bin_dir:$PATH" ;;
    esac

    local shell_rc=""
    if [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == */zsh ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -n "${BASH_VERSION:-}" || "${SHELL:-}" == */bash ]]; then
        shell_rc="$HOME/.bashrc"
    fi

    if [[ -n "$shell_rc" ]] && ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$shell_rc" 2>/dev/null; then
        {
            echo ""
            echo "# AI Hub Python 路径配置"
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$shell_rc" 2>/dev/null || true
    fi
}

set_uv_python_as_default() {
    local py_path="$1"
    local bin_dir="$HOME/.local/bin"
    local link_name link_path

    mkdir -p "$bin_dir" || return 1
    for link_name in python python3; do
        link_path="$bin_dir/$link_name"
        if [[ -e "$link_path" && ! -L "$link_path" ]]; then
            warn_log "无法自动设置 $link_path：目标已存在且不是符号链接。"
            return 1
        fi
        ln -sf "$py_path" "$link_path" || return 1
    done

    ensure_local_bin_in_path
    hash -r 2>/dev/null || true
    return 0
}

ensure_python_with_uv() {
    local uv_cmd="$1"
    local wanted="${AI_HUB_PYTHON_VERSION:-3.12}"
    local py_path py_ver

    py_path=$(find_suitable_uv_python "$uv_cmd" || true)
    if [[ -z "$py_path" ]]; then
        info_log "未发现可用的 uv Python，正在安装 Python $wanted..."
        "$uv_cmd" python install "$wanted" || return 1
        py_path=$("$uv_cmd" python find "$wanted" 2>/dev/null || true)
    fi

    if [[ -z "$py_path" || ! -x "$py_path" ]] || ! python_version_ge_310 "$py_path"; then
        return 1
    fi

    set_uv_python_as_default "$py_path" || return 1
    py_ver=$(python_version_from_cmd "$py_path" || echo "未知")
    success_log "已通过 uv 设置默认 Python: $py_ver ($py_path)"
    return 0
}

# 检查系统依赖
check_dependencies() {
    local missing_deps=()
    for cmd in jq curl; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  缺失必要依赖: ${missing_deps[*]}${NC}"
        
        # 尝试自动安装：使用数组执行，避免 eval。
        local install_desc=""
        local install_cmd=()
        if [[ "$OS" == "macOS" ]] && command_exists brew; then
            install_cmd=(brew install "${missing_deps[@]}")
            install_desc="brew install ${missing_deps[*]}"
        elif [[ "$OS" == "Linux" ]]; then
            if command_exists apt-get; then
                install_cmd=(sudo apt-get install -y "${missing_deps[@]}")
                install_desc="sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
            elif command_exists yum; then
                install_cmd=(sudo yum install -y "${missing_deps[@]}")
                install_desc="sudo yum install -y ${missing_deps[*]}"
            elif command_exists dnf; then
                install_cmd=(sudo dnf install -y "${missing_deps[@]}")
                install_desc="sudo dnf install -y ${missing_deps[*]}"
            elif command_exists apk; then
                install_cmd=(sudo apk add "${missing_deps[@]}")
                install_desc="sudo apk add ${missing_deps[*]}"
            fi
        fi

        if [[ ${#install_cmd[@]} -gt 0 ]]; then
            if [[ "${AI_HUB_NON_INTERACTIVE:-0}" == "1" ]]; then
                echo -e "${RED}❌ 非交互模式缺少必要依赖: ${missing_deps[*]}${NC}"
                echo -e "${YELLOW}请先执行: ${install_desc}${NC}"
                exit 1
            fi
            read -p "是否尝试自动安装缺少的依赖? (y/N): " auto_install
            if [[ "$auto_install" == "y" || "$auto_install" == "Y" ]]; then
                echo -e "${CYAN}正在安装依赖...${NC}"
                if [[ "$OS" == "Linux" ]] && command_exists apt-get; then
                    sudo apt-get update || true
                fi
                if "${install_cmd[@]}"; then
                    echo -e "${GREEN}✅ 依赖安装成功${NC}"
                else
                    echo -e "${RED}❌ 依赖安装失败${NC}"
                fi
            else
                echo -e "${RED}❌ 错误: 缺少必要依赖: ${missing_deps[*]}${NC}"
                echo -e "${YELLOW}请手动安装这些工具后再试：${NC}"
                [[ "$OS" == "macOS" ]] && echo -e "  brew install ${missing_deps[*]}"
                [[ "$OS" == "Linux" ]] && echo -e "  ${install_desc:-sudo apt-get install ${missing_deps[*]}}"
                exit 1
            fi
        fi
    fi

    # 运行时版本水位线检查
    debug_log "检查运行时版本..."
    if [[ -x "$HOME/.local/bin/python3" ]]; then
        ensure_local_bin_in_path
        hash -r 2>/dev/null || true
    fi

    if command_exists node; then
        local node_ver=""
        node_ver=$(node -v 2>/dev/null | sed 's/^v//') || true
        if [[ "$node_ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            [[ ${node_ver%%.*} -lt 18 ]] && warn_log "Node.js 版本过低 ($node_ver), 建议升级至 >= 18 以确保工具正常运行。"
        else
            warn_log "检测到 node 命令但无法执行，请修复或重新安装 Node.js。"
        fi
    fi
    local uv_cmd=""
    uv_cmd=$(find_uv_command 2>/dev/null || true)
    if command_exists python3; then
        local py_ver=$(python_version_from_cmd "$(command -v python3)" || python3 --version 2>/dev/null | awk '{print $2}')
        if ! python_version_ge_310 "$(command -v python3)"; then
            warn_log "Python 版本过低 ($py_ver), 建议升级至 >= 3.10。"
            if [[ -n "$uv_cmd" ]]; then
                ensure_python_with_uv "$uv_cmd" || echo -e "${CYAN}[建议]${NC} 已检测到 ${BOLD}uv${NC}，但自动安装/设置 Python ${AI_HUB_PYTHON_VERSION:-3.12} 失败，请手动运行 ${BOLD}$uv_cmd python install ${AI_HUB_PYTHON_VERSION:-3.12}${NC}。"
            else
                echo -e "${CYAN}[建议]${NC} 可在 AI Hub 中安装 ${BOLD}uv${NC}，然后运行 ${BOLD}uv python install 3.12${NC} 快速解决。"
            fi
        fi
    elif [[ -n "$uv_cmd" ]]; then
        warn_log "未检测到 Python3，尝试通过 uv 自动安装/设置 Python ${AI_HUB_PYTHON_VERSION:-3.12}。"
        ensure_python_with_uv "$uv_cmd" || echo -e "${CYAN}[建议]${NC} 已检测到 ${BOLD}uv${NC}，但自动安装/设置 Python ${AI_HUB_PYTHON_VERSION:-3.12} 失败，请手动运行 ${BOLD}$uv_cmd python install ${AI_HUB_PYTHON_VERSION:-3.12}${NC}。"
    else
        warn_log "未检测到 Python3。某些 MCP/脚本可能无法运行。"
        echo -e "${CYAN}[建议]${NC} 可在 AI Hub 中安装 ${BOLD}uv${NC}，然后运行 ${BOLD}uv python install 3.12${NC} 快速解决。"
    fi
}

# 检查进程是否运行并提示关闭
check_and_kill_process() {
    local cmd_name=$1
    local display_name=$2
    local operation=$3
    
    if pgrep -f "$cmd_name" >/dev/null 2>&1; then
        warn_log "$display_name 正在运行"
        read -p "$display_name 正在运行，继续 $operation 可能导致冲突，是否强制关闭进程? (y/N): " kill_proc
        if [[ "$kill_proc" == "y" || "$kill_proc" == "Y" ]]; then
            if pkill -f "$cmd_name"; then
                success_log "进程已关闭"
            else
                error_log "无法关闭 $display_name 进程，请先手动退出后重试"
                return 1
            fi
        else
            warn_log "操作已取消"
            return 1
        fi
    fi
    return 0
}

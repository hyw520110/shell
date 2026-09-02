#!/usr/bin/env bash
###############################################################################
# token-savior 安装脚本
# 功能: 环境检查、依赖安装、Python 版本选择
# 优先使用 uv，回退到 pip
###############################################################################

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

PACKAGE="token-savior-recall[mcp]"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=11
INSTALL_DIR="${HOME}/.local/share/ai-hub/mcp-servers/token-savior"

# === Python 版本检测 ===
get_python_version() {
    local py="$1"
    "$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo ""
}

check_python_version() {
    local py="$1"
    local ver
    ver=$(get_python_version "$py")
    [[ -z "$ver" ]] && return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" -ge "$MIN_PYTHON_MAJOR" ]] && [[ "$minor" -ge "$MIN_PYTHON_MINOR" ]]
}

# === 查找可用的 Python ===
find_python() {
    local candidates=(
        "python3.13"
        "python3.12"
        "python3.11"
        "python3"
    )

    # 如果 uv 可用，优先用 uv 查找
    if command -v uv &>/dev/null; then
        local uv_py
        uv_py=$(uv python find 3.11 2>/dev/null || true)
        if [[ -n "$uv_py" ]]; then
            echo "$uv_py"
            return 0
        fi
    fi

    # 检查系统 Python
    for py in "${candidates[@]}"; do
        if command -v "$py" &>/dev/null && check_python_version "$py"; then
            echo "$py"
            return 0
        fi
    done

    return 1
}

# === 列出所有已安装的 Python 版本 ===
list_installed_pythons() {
    echo -e "${CYAN}已安装的 Python 版本:${NC}"
    local found=false
    for py in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
        if command -v "$py" &>/dev/null; then
            local ver
            ver=$(get_python_version "$py")
            local status=""
            if check_python_version "$py"; then
                status="${GREEN}✅ 满足要求${NC}"
            else
                status="${RED}❌ 需要 >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}${NC}"
            fi
            printf "  %-16s %s  %s\n" "$py" "$ver" "$status"
            found=true
        fi
    done

    # uv 管理的 Python
    if command -v uv &>/dev/null; then
        local uv_pythons
        uv_pythons=$(uv python list 2>/dev/null | grep -E "^3\.(11|12|13)" || true)
        if [[ -n "$uv_pythons" ]]; then
            echo -e "${CYAN}uv 管理的 Python:${NC}"
            echo "$uv_pythons" | while read -r line; do
                echo "  $line"
            done
            found=true
        fi
    fi

    if [[ "$found" == "false" ]]; then
        echo -e "${YELLOW}未找到任何 Python${NC}"
    fi
}

# === 使用 uv 安装 ===
install_with_uv() {
    info "使用 uv 安装 token-savior..."

    if ! command -v uv &>/dev/null; then
        warn "未检测到 uv，正在安装..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
        if ! command -v uv &>/dev/null; then
            error "uv 安装失败"
            return 1
        fi
        ok "uv 安装成功"
    fi

    # uv tool install 自动管理 Python 版本
    uv tool install "$PACKAGE"
    ok "token-savior 安装成功 (uv tool)"

    # 获取可执行文件路径
    local bin_path
    bin_path=$(uv tool dir 2>/dev/null)/bin/token-savior
    if [[ -x "$bin_path" ]]; then
        echo ""
        echo "可执行文件: $bin_path"
    fi
}

# === 使用 pip 安装 ===
install_with_pip() {
    local py="$1"

    info "使用 $py 安装 token-savior..."
    echo "  Python: $($py --version)"

    # 检查 pip 是否可用
    if ! "$py" -m pip --version &>/dev/null; then
        warn "pip 不可用，尝试安装..."
        "$py" -m ensurepip --upgrade 2>/dev/null || {
            error "pip 安装失败"
            return 1
        }
    fi

    "$py" -m pip install "$PACKAGE"
    ok "token-savior 安装成功 (pip)"

    # 获取可执行文件路径
    local bin_path
    bin_path=$("$py" -c "import shutil, token_savior; print(shutil.which('token-savior'))" 2>/dev/null || true)
    if [[ -n "$bin_path" ]]; then
        echo ""
        echo "可执行文件: $bin_path"
    fi
}

# === 使用 Homebrew 安装 Python ===
install_python_brew() {
    local version="${1:-3.11}"

    info "使用 Homebrew 安装 Python ${version}..."
    if ! command -v brew &>/dev/null; then
        error "未检测到 Homebrew，请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi

    brew install "python@${version}"
    ok "Python ${version} 安装成功"
}

# === 交互式选择安装方式 ===
select_install_method() {
    echo ""
    echo "选择安装方式:"
    echo "  1) uv tool install (推荐 - 自动管理 Python 版本)"
    echo "  2) 使用现有 Python + pip"
    echo "  3) 安装 Python 3.11 (Homebrew) 后使用 pip"
    echo "  4) 列出已安装的 Python 版本"
    echo "  5) 卸载"
    echo ""
    read -p "请输入选择 [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) install_with_uv ;;
        2)
            local py
            py=$(find_python)
            if [[ -z "$py" ]]; then
                error "未找到满足 Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} 的版本"
                echo "请选择方式 3 安装 Python 3.11，或方式 4 查看已安装版本"
                return 1
            fi
            install_with_pip "$py"
            ;;
        3)
            install_python_brew "3.11"
            local py="python3.11"
            if command -v "$py" &>/dev/null; then
                install_with_pip "$py"
            else
                error "Python 3.11 安装后仍不可用，请检查 PATH"
                return 1
            fi
            ;;
        4)
            list_installed_pythons
            echo ""
            select_install_method
            ;;
        5) uninstall ;;
        *) install_with_uv ;;
    esac
}

# === 卸载 ===
uninstall() {
    info "卸载 token-savior..."

    if command -v uv &>/dev/null; then
        uv tool uninstall token-savior-recall 2>/dev/null && ok "uv tool 卸载成功" || true
    fi

    for py in python3.13 python3.12 python3.11 python3; do
        if command -v "$py" &>/dev/null; then
            "$py" -m pip uninstall -y token-savior-recall 2>/dev/null && ok "pip ($py) 卸载成功" || true
        fi
    done

    ok "卸载完成"
}

# === 状态检查 ===
check_status() {
    echo -e "${CYAN}=== token-savior 状态检查 ===${NC}"
    echo ""

    # 检查 Python 版本
    echo -e "${CYAN}Python 环境:${NC}"
    local py
    py=$(find_python 2>/dev/null || true)
    if [[ -n "$py" ]]; then
        ok "$py $(get_python_version "$py") - 满足要求"
    else
        warn "未找到满足 Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} 的版本"
    fi

    # 检查 uv
    if command -v uv &>/dev/null; then
        ok "uv $(uv --version 2>/dev/null | head -1)"
    else
        warn "uv 未安装"
    fi

    # 检查 token-savior
    echo ""
    echo -e "${CYAN}token-savior:${NC}"
    if command -v token-savior &>/dev/null; then
        ok "token-savior 已安装: $(token-savior --version 2>/dev/null || echo '已安装')"
    elif uv tool list 2>/dev/null | grep -q token-savior; then
        ok "token-savior 已通过 uv tool 安装"
    else
        warn "token-savior 未安装"
    fi
}

# === 帮助信息 ===
show_help() {
    cat <<EOF
${GREEN}token-savior 安装脚本${NC}

${YELLOW}功能:${NC}
  Token 优化 MCP 服务器 - 结构化代码导航、持久记忆、Bash 输出压缩
  tsbench 97.9% 得分，-80% Token 消耗

${YELLOW}要求:${NC}
  Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}

${YELLOW}用法:${NC}
  $(basename "$0") [选项]

${YELLOW}选项:${NC}
  --uv              使用 uv 安装 (推荐)
  --pip              使用 pip 安装
  --check            检查安装状态
  --uninstall       卸载
  --list-python      列出已安装的 Python 版本
  -h, --help         显示帮助

${YELLOW}示例:${NC}
  $(basename "$0")                    # 交互式安装
  $(basename "$0") --uv              # 使用 uv 安装
  $(basename "$0") --check          # 检查状态
  $(basename "$0") --list-python    # 列出 Python 版本

EOF
    exit 0
}

# === 主函数 ===
main() {
    local method=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uv) method="uv"; shift ;;
            --pip) method="pip"; shift ;;
            --check) check_status; exit 0 ;;
            --uninstall) uninstall; exit 0 ;;
            --list-python) list_installed_pythons; exit 0 ;;
            -h|--help) show_help ;;
            *) shift ;;
        esac
    done

    echo "========================================"
    echo "  token-savior 安装"
    echo "  要求: Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}"
    echo "========================================"
    echo ""

    if [[ -n "$method" ]]; then
        case "$method" in
            uv) install_with_uv ;;
            pip)
                local py
                py=$(find_python)
                if [[ -z "$py" ]]; then
                    error "未找到满足 Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} 的版本"
                    list_installed_pythons
                    exit 1
                fi
                install_with_pip "$py"
                ;;
        esac
    else
        select_install_method
    fi

    echo ""
    echo "========================================"
    echo "  安装完成"
    echo "========================================"
    echo ""
    echo "MCP 配置示例:"
    echo '{'
    echo '  "mcpServers": {'
    echo '    "token-savior": {'
    echo '      "command": "token-savior",'
    echo '      "env": {'
    echo '        "TOKEN_SAVIOR_CLIENT": "claude-code",'
    echo '        "TOKEN_SAVIOR_PROFILE": "optimized"'
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
    echo ""
    echo "启用 Bash 压缩 (可选):"
    echo "  export TS_BASH_COMPACT=1"
    echo "  export TS_BASH_REWRITE=1"
    echo "  ts init --agent claude --yes"
}

main "$@"

#!/usr/bin/env bash
###############################################################################
# whichllm 安装脚本
# 功能: 一键安装配置 whichllm (https://github.com/Andyyyy64/whichllm)
# 支持: uv tool / pip / Homebrew 多种安装方式
###############################################################################

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success(){ echo -e "${GREEN}[OK]${NC} $*"; }

# 安装方式
INSTALL_METHOD=""
CHECK_ONLY=false

usage() {
    cat <<EOF
${GREEN}whichllm 安装脚本${NC}

${YELLOW}功能:${NC}
  自动检测 GPU/CPU/RAM，从 HuggingFace 排名推荐最适合本地运行的 LLM 模型

${YELLOW}安装方式:${NC}
  1. uv tool install (推荐 - 自动管理环境)
  2. pip install (Python 环境)
  3. Homebrew (macOS)
  4. uvx whichllm@latest (无需安装，直接运行)

${YELLOW}用法:${NC}
  $(basename "$0") [选项]

${YELLOW}选项:${NC}
  --method METHOD    指定安装方式: uv / pip / brew / uvx
  --check           仅检查安装状态
  -h, --help        显示帮助

${YELLOW}常用命令:${NC}
  whichllm                    # 推荐本机最佳模型
  whichllm --gpu "RTX 4090"  # 模拟 GPU 查看推荐
  whichllm hardware           # 查看硬件信息
  whichllm run "qwen 7b"     # 下载并对话
  whichllm snippet "qwen 7b"  # 生成可运行代码
  whichllm plan "llama 70b"   # 规划所需硬件
  whichllm upgrade            # 对比硬件升级

${YELLOW}示例:${NC}
  $(basename "$0")                    # 默认安装
  $(basename "$0") --method uv        # 使用 uv 安装
  $(basename "$0") --check            # 检查安装状态
  uvx whichllm@latest                # 直接运行（无需安装）

EOF
    exit 0
}

# 检查 whichllm 是否已安装
check_installed() {
    if command -v whichllm >/dev/null 2>&1; then
        local version
        version=$(whichllm --version 2>/dev/null || echo "未知版本")
        echo "whichllm 已安装: $version"
        return 0
    elif pip3 show whichllm >/dev/null 2>&1; then
        echo "whichllm 已通过 pip 安装"
        return 0
    else
        echo "whichllm 未安装"
        return 1
    fi
}

# 使用 uvx 直接运行（无需安装）
run_uvx() {
    info "使用 uvx 直接运行 whichllm..."
    echo ""
    echo "========================================"
    echo "  uvx whichllm@latest"
    echo "========================================"
    echo ""
    uvx whichllm@latest "$@"
}

# 使用 uv tool 安装
install_with_uv() {
    info "使用 uv tool 安装 whichllm..."

    if ! command -v uv >/dev/null 2>&1; then
        error "未检测到 uv，请先安装: curl -LsSf https://astral.sh/uv/install.sh | sh"
        return 1
    fi

    uv tool install whichllm
    success "whichllm 安装成功 (uv tool)"

    # 确保 PATH 包含 uv tool 路径
    local uv_bin_path="$HOME/.local/bin"
    if [[ ":$PATH:" != *":$uv_bin_path:"* ]]; then
        warn "建议将 $uv_bin_path 添加到 PATH"
        if [[ -f "$HOME/.zshrc" ]]; then
            if ! grep -q "$uv_bin_path" "$HOME/.zshrc" 2>/dev/null; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
                info "已添加 PATH 配置到 ~/.zshrc"
            fi
        fi
    fi
}

# 使用 pip 安装
install_with_pip() {
    info "使用 pip 安装 whichllm..."

    pip3 install whichllm
    success "whichllm 安装成功 (pip)"
}

# 使用 Homebrew 安装 (macOS)
install_with_brew() {
    info "使用 Homebrew 安装 whichllm..."

    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "Homebrew 安装方式仅适用于 macOS"
        return 1
    fi

    if ! command -v brew >/dev/null 2>&1; then
        error "未检测到 Homebrew，请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi

    brew install andyyyy64/whichllm/whichllm
    success "whichllm 安装成功 (Homebrew)"
}

# 配置 HuggingFace 镜像（解决国内网络问题）
configure_hf_mirror() {
    local rc_file="${HOME}/.zshrc"
    [[ -f "${HOME}/.bashrc" ]] && ! [[ -n "${ZSH_VERSION:-}" ]] && rc_file="${HOME}/.bashrc"

    local hf_endpoint="https://hf-mirror.com"
    local mirror_configured=false

    # 检查是否已配置镜像
    if grep -q "HF_ENDPOINT" "$rc_file" 2>/dev/null; then
        local current
        current=$(grep "HF_ENDPOINT" "$rc_file" 2>/dev/null | grep -oP 'https?://[^"'\'' ]+' | head -1)
        if [[ -n "$current" ]]; then
            hf_endpoint="$current"
            mirror_configured=true
        fi
    fi

    # 检查当前环境变量
    if [[ -n "${HF_ENDPOINT:-}" ]]; then
        hf_endpoint="${HF_ENDPOINT}"
        mirror_configured=true
    fi

    # 如果已配置且不是默认值，提示用户
    if [[ "$mirror_configured" == "true" && "$hf_endpoint" != "https://huggingface.co" ]]; then
        info "HuggingFace 镜像已配置: $hf_endpoint"
        return 0
    fi

    # 检测网络连通性
    info "检测 HuggingFace 连通性..."
    if curl -s --connect-timeout 5 "https://huggingface.co" >/dev/null 2>&1; then
        info "HuggingFace 直连正常，无需配置镜像"
        return 0
    fi

    # 无法直连，提示配置镜像
    echo ""
    warn "无法直连 HuggingFace，whichllm 需要访问 HuggingFace API 获取模型数据"
    echo ""
    echo "推荐配置 HuggingFace 镜像:"
    echo "  1) hf-mirror.com (推荐)"
    echo "  2) 不配置（后续手动设置 HF_ENDPOINT 环境变量）"
    echo ""
    read -p "是否配置 HuggingFace 镜像? (Y/n): " confirm
    confirm=${confirm:-Y}
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    # 使用 envs 或直接写入
    if command -v envs >/dev/null 2>&1; then
        envs add "HF_ENDPOINT=$hf_endpoint" >/dev/null 2>&1
        success "已通过 envs 配置 HF_ENDPOINT=$hf_endpoint"
    else
        echo "" >> "$rc_file"
        echo "# HuggingFace Mirror (whichllm)" >> "$rc_file"
        echo "export HF_ENDPOINT=\"$hf_endpoint\"" >> "$rc_file"
        success "已添加 HF_ENDPOINT=$hf_endpoint 到 $rc_file"
    fi

    # 立即生效
    export HF_ENDPOINT="$hf_endpoint"
    echo ""
    info "请执行以下命令使配置生效:"
    echo "  source $rc_file"
    echo ""
    info "或重新打开终端后运行 whichllm"
}

# 卸载
uninstall() {
    info "卸载 whichllm..."

    if command -v uv >/dev/null 2>&1; then
        uv tool uninstall whichllm 2>/dev/null && success "uv tool 卸载成功" || true
    fi

    pip3 uninstall -y whichllm 2>/dev/null && success "pip 卸载成功" || true

    if command -v brew >/dev/null 2>&1; then
        brew uninstall andyyyy64/whichllm/whichllm 2>/dev/null && success "Homebrew 卸载成功" || true
    fi

    success "卸载完成"
}

# 交互式选择安装方式
select_install_method() {
    echo ""
    echo "选择安装方式:"
    echo "  1) uv tool install (推荐 - 自动管理环境)"
    echo "  2) pip install (Python 环境)"
    echo "  3) Homebrew (macOS)"
    echo "  4) 直接运行 (uvx whichllm@latest)"
    echo "  5) 卸载"
    echo ""
    read -p "请输入选择 [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) INSTALL_METHOD="uv" ;;
        2) INSTALL_METHOD="pip" ;;
        3) INSTALL_METHOD="brew" ;;
        4) INSTALL_METHOD="uvx" ;;
        5) uninstall; exit 0 ;;
        *) INSTALL_METHOD="uv" ;;
    esac
}

# 主函数
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method)
                INSTALL_METHOD="$2"
                shift 2
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                shift
                ;;
        esac
    done

    # 检查安装状态
    if [[ "$CHECK_ONLY" == "true" ]]; then
        check_installed
        exit 0
    fi

    # 检查是否已安装
    if check_installed >/dev/null 2>&1; then
        warn "whichllm 已安装"
        read -p "是否重新安装? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "取消安装"; exit 0; }
    fi

    # 如果未指定安装方式，交互式选择
    if [[ -z "$INSTALL_METHOD" ]]; then
        select_install_method
    fi

    # 执行安装
    echo ""
    echo "========================================"
    echo "  whichllm 安装"
    echo "========================================"
    echo ""

    case "$INSTALL_METHOD" in
        uv)
            install_with_uv
            ;;
        pip)
            install_with_pip
            ;;
        brew)
            install_with_brew
            ;;
        uvx)
            run_uvx "${@}"
            exit 0
            ;;
        *)
            error "不支持的安装方式: $INSTALL_METHOD"
            usage
            ;;
    esac

    # 显示安装后信息
    echo ""
    echo "========================================"
    echo "  WhichLLM 安装成功！"
    echo "========================================"
    echo ""

    # 配置 HuggingFace 镜像
    configure_hf_mirror

    echo ""
    echo "常用命令:"
    echo "  whichllm                    # 推荐本机最佳模型"
    echo "  whichllm --gpu \"RTX 4090\"  # 模拟 GPU 查看推荐"
    echo "  whichllm hardware           # 查看硬件信息"
    echo "  whichllm run \"qwen 7b\"     # 下载并对话"
    echo "  whichllm snippet \"qwen 7b\"  # 生成可运行代码"
    echo "  whichllm plan \"llama 70b\"   # 规划所需硬件"
    echo ""
    echo "查看完整帮助: whichllm --help"
    echo ""

    # 显示版本
    if command -v whichllm >/dev/null 2>&1; then
        echo "版本信息:"
        whichllm --version || true
    fi
}

main "$@"

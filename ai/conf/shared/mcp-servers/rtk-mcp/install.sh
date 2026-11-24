#!/usr/bin/env bash
###############################################################################
# rtk-mcp 安装脚本
# 功能: 环境检查、Rust/Cargo 安装、RTK MCP 构建安装
# 支持: 自动检测 cargo，未安装时引导安装 Rust
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

REPO_URL="https://github.com/ousamabenyounes/rtk-mcp"
INSTALL_DIR="${HOME}/.local/share/ai-hub/rtk-mcp"
BINARY="${INSTALL_DIR}/target/release/rtk-mcp"

# === 检查 cargo 是否可用 ===
check_cargo() {
    if command -v cargo &>/dev/null; then
        local ver
        ver=$(cargo --version 2>/dev/null || echo "未知版本")
        ok "cargo 已安装: $ver"
        return 0
    else
        warn "cargo 未安装"
        return 1
    fi
}

# === 检查 Rust 工具链 ===
check_rust() {
    if command -v rustc &>/dev/null; then
        local ver
        ver=$(rustc --version 2>/dev/null || echo "未知版本")
        ok "Rust 已安装: $ver"
        return 0
    else
        warn "Rust 未安装"
        return 1
    fi
}

# === 安装 Rust (rustup) ===
install_rust() {
    info "正在安装 Rust 工具链..."

    # 检查是否已安装 rustup
    if command -v rustup &>/dev/null; then
        info "rustup 已存在，执行更新..."
        rustup update
        ok "Rust 工具链更新完成"
    else
        # 下载并运行 rustup 安装脚本
        local rustup_init
        rustup_init=$(mktemp /tmp/rustup-init.XXXXX)

        info "下载 rustup 安装脚本..."
        if command -v curl &>/dev/null; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$rustup_init"
        elif command -v wget &>/dev/null; then
            wget -q https://sh.rustup.rs -O "$rustup_init"
        else
            error "需要 curl 或 wget 来下载 rustup"
            rm -f "$rustup_init"
            return 1
        fi

        # 检查下载是否成功
        if [[ ! -s "$rustup_init" ]]; then
            error "rustup 安装脚本下载失败"
            rm -f "$rustup_init"
            return 1
        fi

        # 非交互式安装 (默认选项: 1 - 默认安装)
        info "执行 rustup 安装 (默认选项)..."
        sh "$rustup_init" -y --default-toolchain stable

        rm -f "$rustup_init"

        # 加载 cargo 环境
        local cargo_env="${HOME}/.cargo/env"
        if [[ -f "$cargo_env" ]]; then
            # shellcheck source=/dev/null
            source "$cargo_env"
        fi

        if ! command -v cargo &>/dev/null; then
            export PATH="${HOME}/.cargo/bin:${PATH:-}"
        fi

        if command -v cargo &>/dev/null; then
            ok "Rust 工具链安装成功: $(rustc --version)"
        else
            error "Rust 安装后 cargo 仍不可用，请手动执行:"
            echo "  source ${HOME}/.cargo/env"
            return 1
        fi
    fi
}

# === 检查 git ===
check_git() {
    if command -v git &>/dev/null; then
        ok "git 已安装: $(git --version 2>/dev/null | head -1)"
        return 0
    else
        error "git 未安装，请先安装 git"
        echo "  macOS: brew install git"
        echo "  Linux: sudo apt install git / sudo yum install git"
        return 1
    fi
}

# === 克隆或更新仓库 ===
clone_or_update() {
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        info "更新已有仓库..."
        git -C "$INSTALL_DIR" pull --ff-only || {
            warn "git pull 失败，尝试重新克隆..."
            rm -rf "$INSTALL_DIR"
            git clone "$REPO_URL" "$INSTALL_DIR"
        }
    else
        info "克隆 rtk-mcp 仓库..."
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    ok "仓库准备完成: $INSTALL_DIR"
}

# === 构建项目 ===
build_rtk_mcp() {
    info "构建 rtk-mcp (release 模式)..."
    echo "  这可能需要几分钟时间，取决于网络和机器性能..."

    cd "$INSTALL_DIR"

    # 检查 Cargo.toml 是否存在
    if [[ ! -f "Cargo.toml" ]]; then
        error "Cargo.toml 不存在，仓库可能不完整"
        return 1
    fi

    cargo build --release

    if [[ -x "$BINARY" ]]; then
        ok "构建成功: $BINARY"
        local size
        size=$(du -h "$BINARY" | cut -f1)
        echo "  二进制大小: $size"
    else
        error "构建完成但未找到可执行文件: $BINARY"
        return 1
    fi
}

# === 检查 RTK (可选依赖) ===
check_rtk() {
    if command -v rtk &>/dev/null; then
        ok "RTK 已安装: $(rtk --version 2>/dev/null || echo '已安装')"
    else
        info "RTK 未安装 (可选依赖，rtk-mcp 可独立工作)"
        echo "  如需安装 RTK: cargo install rtk"
    fi
}

# === 完整安装流程 ===
install() {
    echo "========================================"
    echo "  rtk-mcp 安装"
    echo "  仓库: $REPO_URL"
    echo "========================================"
    echo ""

    # 1. 检查 git
    if ! check_git; then
        return 1
    fi
    echo ""

    # 2. 检查 cargo，不可用则安装 Rust
    if ! check_cargo; then
        echo ""
        echo "rtk-mcp 需要 Rust/Cargo 编译环境"
        read -p "是否安装 Rust 工具链? [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            install_rust || return 1
        else
            error "需要 cargo 才能继续安装"
            return 1
        fi
    fi
    echo ""

    # 3. 克隆/更新代码
    clone_or_update || return 1
    echo ""

    # 4. 构建
    build_rtk_mcp || return 1
    echo ""

    # 5. 检查 RTK
    check_rtk
}

# === 卸载 ===
uninstall() {
    info "卸载 rtk-mcp..."

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "已删除: $INSTALL_DIR"
    else
        warn "安装目录不存在: $INSTALL_DIR"
    fi

    ok "卸载完成"
}

# === 状态检查 ===
check_status() {
    echo -e "${CYAN}=== rtk-mcp 状态检查 ===${NC}"
    echo ""

    # Rust 环境
    echo -e "${CYAN}Rust 环境:${NC}"
    if command -v rustc &>/dev/null; then
        ok "rustc $(rustc --version 2>/dev/null)"
    else
        warn "rustc 未安装"
    fi

    if command -v cargo &>/dev/null; then
        ok "cargo $(cargo --version 2>/dev/null)"
    else
        warn "cargo 未安装"
    fi

    # 仓库
    echo ""
    echo -e "${CYAN}仓库:${NC}"
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        local branch commit
        branch=$(git -C "$INSTALL_DIR" branch --show-current 2>/dev/null || echo "未知")
        commit=$(git -C "$INSTALL_DIR" log -1 --format="%h" 2>/dev/null || echo "未知")
        ok "仓库存在: $INSTALL_DIR (分支: $branch, 提交: $commit)"
    else
        warn "仓库未克隆: $INSTALL_DIR"
    fi

    # 二进制
    echo ""
    echo -e "${CYAN}二进制:${NC}"
    if [[ -x "$BINARY" ]]; then
        ok "rtk-mcp 已构建: $BINARY"
        local size
        size=$(du -h "$BINARY" | cut -f1)
        echo "  大小: $size"
    else
        warn "rtk-mcp 未构建"
    fi

    # RTK
    echo ""
    echo -e "${CYAN}RTK (可选):${NC}"
    if command -v rtk &>/dev/null; then
        ok "rtk $(rtk --version 2>/dev/null || echo '已安装')"
    else
        warn "rtk 未安装"
    fi
}

# === 帮助信息 ===
show_help() {
    cat <<EOF
${GREEN}rtk-mcp 安装脚本${NC}

${YELLOW}功能:${NC}
  RTK MCP 桥接服务 - 将 shell 命令通过 Rust Token Killer 过滤后返回给 MCP 客户端
  减少 Token 消耗，优化上下文窗口使用

${YELLOW}要求:${NC}
  - Rust/Cargo (编译)
  - Git (克隆仓库)

${YELLOW}用法:${NC}
  $(basename "$0") [选项]

${YELLOW}选项:${NC}
  --install          完整安装 (默认)
  --build-only        仅重新构建 (跳过 Rust 检查和克隆)
  --check            检查安装状态
  --uninstall       卸载
  -h, --help         显示帮助

${YELLOW}示例:${NC}
  $(basename "$0")                    # 完整安装
  $(basename "$0") --build-only      # 仅重新构建
  $(basename "$0") --check          # 检查状态
  $(basename "$0") --uninstall      # 卸载

${YELLOW}安装目录:${NC}
  $INSTALL_DIR

${YELLOW}二进制路径:${NC}
  $BINARY

EOF
    exit 0
}

# === 主函数 ===
main() {
    local action="install"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)       action="install"; shift ;;
            --build-only)    action="build"; shift ;;
            --check)         check_status; exit 0 ;;
            --uninstall)     uninstall; exit 0 ;;
            -h|--help)       show_help ;;
            *) shift ;;
        esac
    done

    case "$action" in
        install)
            install
            echo ""
            echo "========================================"
            echo "  安装完成"
            echo "========================================"
            echo ""
            echo "MCP 配置示例:"
            echo '{'
            echo '  "mcpServers": {'
            echo '    "rtk-mcp": {'
            echo "      \"command\": \"$BINARY\""
            echo '    }'
            echo '  }'
            echo '}'
            ;;
        build)
            if [[ -d "${INSTALL_DIR}/.git" ]]; then
                build_rtk_mcp
            else
                error "仓库不存在: $INSTALL_DIR"
                echo "请先运行 $(basename "$0") --install"
                exit 1
            fi
            ;;
    esac
}

main "$@"

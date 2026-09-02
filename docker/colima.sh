#!/bin/bash
#
# Colima 管理脚本
# Colima 是 macOS 和 Linux 上的轻量级容器运行时，兼容 Docker CLI
# 基于 Lima 虚拟机，完全免费开源
#
# 功能：
#   - 自动安装 Homebrew（如未安装）
#   - 安装 colima + docker + docker-compose
#   - 配置 colima 虚拟机（CPU/内存/磁盘）
#   - 自动启动并配置 docker context
#   - 卸载 colima / docker CLI / docker-compose
#
# 用法：
#   ./colima.sh                    # 交互式配置
#   ./colima.sh --cpu 4 --memory 8 --disk 100  # 指定资源
#   ./colima.sh uninstall --purge  # 卸载并删除 ~/.colima
#
# 官网：https://github.com/abiosoft/colima

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# === 颜色定义 ===
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly BOLD=$'\033[1m'
readonly NC=$'\033[0m'

# === 默认配置 ===
CPU=4
MEMORY=8
DISK=100
ARCH=""
RUNTIME="docker"  # docker 或 containerd
ACTION="install"
PURGE=false
YES=false

# === 工具函数 ===
print_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }

# === 显示帮助 ===
show_help() {
    cat << EOF
Colima 管理脚本

Colima 是 macOS/Linux 上的轻量级容器运行时，基于 Lima 虚拟机，
完全兼容 Docker CLI，是 Docker Desktop 的免费替代品。

用法: ./$SCRIPT_NAME [install|uninstall] [选项]

选项:
    -h, --help              显示此帮助信息
    --cpu NUM               CPU 核心数 (默认: 4)
    --memory NUM            内存大小 GB (默认: 8)
    --disk NUM              磁盘大小 GB (默认: 100)
    --arch ARCH             架构 (x86_64, aarch64, host)
    --runtime RUNTIME       运行时 (docker, containerd, 默认: docker)
    --start                 安装后立即启动
    --uninstall             卸载 Colima 相关组件
    --purge                 卸载时同时删除 ~/.colima 数据
    -y, --yes               非交互确认

示例:
    ./$SCRIPT_NAME                           # 交互式安装
    ./$SCRIPT_NAME --cpu 2 --memory 4        # 低配版
    ./$SCRIPT_NAME --cpu 8 --memory 16       # 高配版
    ./$SCRIPT_NAME uninstall                 # 卸载程序，保留 ~/.colima 数据
    ./$SCRIPT_NAME uninstall --purge         # 卸载并删除虚拟机数据

    说明:
    - 仅支持 macOS 和 Linux
    - 需要 Homebrew (macOS) 或 apt/yum (Linux)
    - macOS 14+ 为推荐环境；macOS 12/13 可能需要使用 LLVM 源码编译 QEMU
    - 首次启动需要下载虚拟机镜像，请耐心等待

EOF
}

# === 解析参数 ===
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            install)
                ACTION="install"
                shift
                ;;
            uninstall|remove)
                ACTION="uninstall"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --uninstall)
                ACTION="uninstall"
                shift
                ;;
            --purge)
                PURGE=true
                shift
                ;;
            -y|--yes)
                YES=true
                shift
                ;;
            --cpu)
                CPU="$2"
                shift 2
                ;;
            --memory)
                MEMORY="$2"
                shift 2
                ;;
            --disk)
                DISK="$2"
                shift 2
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --runtime)
                RUNTIME="$2"
                shift 2
                ;;
            --start)
                AUTO_START=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

confirm_action() {
    local prompt="$1"
    local reply

    if [[ "$YES" == "true" ]]; then
        return 0
    fi

    read -rp "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# === 检测系统 ===
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# === 检测芯片 ===
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *) echo "$arch" ;;
    esac
}

# === 获取 macOS 主版本 ===
macos_major_version() {
    local version
    version=$(sw_vers -productVersion)
    echo "${version%%.*}"
}

# === macOS 是否需要 QEMU ===
macos_requires_qemu() {
    local host_arch="$1"
    local macos_major
    macos_major=$(macos_major_version)

    # macOS < 13 不支持 VZ，Colima 必须使用 QEMU。
    if [[ "$macos_major" -lt 13 ]]; then
        return 0
    fi

    # Intel 主机以及显式指定 x86_64 时仍然需要 QEMU。
    [[ "$host_arch" == "x86_64" || "$ARCH" == "x86_64" ]]
}

# === 安装 Homebrew (macOS) ===
install_homebrew() {
    if command -v brew &> /dev/null; then
        print_success "Homebrew 已安装: $(brew --version | head -1)"
        return 0
    fi

    print_info "正在安装 Homebrew..."
    print_info "这可能需要几分钟，请耐心等待..."

    # 使用国内镜像加速
    export HOMEBREW_INSTALL_FROM_API=1
    export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        print_error "Homebrew 安装失败"
        echo "请手动安装: https://brew.sh/"
        exit 1
    }

    # 配置环境变量。Intel Homebrew 位于 /usr/local，Apple Silicon 位于
    # /opt/homebrew，不要写死其中一个路径。
    local brew_shellenv
    brew_shellenv="$(brew shellenv)"
    eval "$brew_shellenv"
    if [[ -f "$HOME/.zshrc" ]] && ! grep -Fq 'brew shellenv' "$HOME/.zshrc"; then
        echo "eval \"\$($(command -v brew) shellenv)\"" >> "$HOME/.zshrc"
    fi

    print_success "Homebrew 安装完成"
}

# === 安装 Colima ===
install_colima() {
    local os=$(detect_os)

    if command -v colima &> /dev/null; then
        local colima_version
        colima_version="$(colima version 2>/dev/null || true)"
        colima_version="${colima_version%%$'\n'*}"
        print_success "Colima 已安装: ${colima_version:-unknown}"
        return 0
    fi

    print_header "安装 Colima"

    if [[ "$os" == "macos" ]]; then
        install_homebrew
        # Colima 在 macOS 12/Intel 上依赖 QEMU。必须先准备 QEMU，否则
        # `brew install colima` 会在依赖阶段用 Apple Clang 14 编译 QEMU，
        # 并在 Meson 配置阶段失败。
        ensure_qemu_dependency
        print_info "通过 Homebrew 安装 colima..."
        brew install colima
    elif [[ "$os" == "linux" ]]; then
        # Linux 使用官方安装脚本
        print_info "下载并安装 colima..."
        curl -fsSL https://raw.githubusercontent.com/abiosoft/colima/main/install.sh | bash
    else
        print_error "不支持的操作系统: $os"
        exit 1
    fi

    print_success "Colima 安装完成"
}

# === 安装 Docker CLI ===
install_docker_cli() {
    print_header "安装 Docker CLI"

    if command -v docker &> /dev/null; then
        print_success "Docker CLI 已安装: $(docker --version)"
        return 0
    fi

    local os=$(detect_os)

    if [[ "$os" == "macos" ]]; then
        print_info "通过 Homebrew 安装 docker..."
        brew install docker
    elif [[ "$os" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y docker.io
        elif command -v yum &> /dev/null; then
            sudo yum install -y docker
        fi
    fi

    print_success "Docker CLI 安装完成"
}

# === 安装 Docker Compose ===
install_docker_compose() {
    print_header "安装 Docker Compose"

    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null 2>&1; then
        print_success "Docker Compose 已安装"
        return 0
    fi

    local os=$(detect_os)

    if [[ "$os" == "macos" ]]; then
        print_info "通过 Homebrew 安装 docker-compose..."
        brew install docker-compose
    elif [[ "$os" == "linux" ]]; then
        # 安装 docker-compose-plugin
        if command -v apt-get &> /dev/null; then
            sudo apt-get install -y docker-compose-plugin
        fi
    fi

    print_success "Docker Compose 安装完成"
}

# === 修复 Docker 凭据助手配置 ===
repair_docker_credential_store() {
    local config_file helper_path backup_file temp_file config_mode

    config_file="$HOME/.docker/config.json"
    [[ -f "$config_file" ]] || return 0

    # Docker Desktop 的凭据助手通常不在 PATH 中，但如果 Docker.app 存在，
    # 先把它加入当前进程的 PATH，避免无谓地修改用户配置。
    for helper_path in \
        "/Applications/Docker.app/Contents/Resources/bin" \
        "$HOME/Applications/Docker.app/Contents/Resources/bin"; do
        if [[ -x "$helper_path/docker-credential-desktop" ]] && \
            ! command -v docker-credential-desktop &> /dev/null; then
            export PATH="$helper_path:$PATH"
            break
        fi
    done

    if command -v docker-credential-desktop &> /dev/null || \
        ! grep -Eq '"credsStore"[[:space:]]*:[[:space:]]*"desktop"' "$config_file"; then
        return 0
    fi

    print_warn "Docker 配置引用了不存在的 docker-credential-desktop。"
    print_info "移除失效的 credsStore 配置；原配置会自动备份。"

    config_mode=$(stat -f '%Lp' "$config_file" 2>/dev/null || echo 600)
    backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    temp_file="$(mktemp "${config_file}.tmp.XXXXXX")"

    if ! cp -p "$config_file" "$backup_file"; then
        rm -f "$temp_file"
        print_error "无法备份 Docker 配置: $config_file"
        return 1
    fi

    if command -v ruby &> /dev/null; then
        if ! ruby -rjson -e '
          path = ARGV.fetch(0)
          data = JSON.parse(File.read(path))
          data.delete("credsStore")
          STDOUT.write(JSON.pretty_generate(data))
          STDOUT.write("\\n")
        ' "$config_file" > "$temp_file"; then
            rm -f "$temp_file"
            print_error "解析 Docker 配置失败，已保留备份: $backup_file"
            return 1
        fi
    elif command -v python3 &> /dev/null; then
        if ! python3 - "$config_file" > "$temp_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
data.pop("credsStore", None)
json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\\n")
PY
        then
            rm -f "$temp_file"
            print_error "解析 Docker 配置失败，已保留备份: $backup_file"
            return 1
        fi
    else
        rm -f "$temp_file"
        print_error "系统没有 Ruby 或 Python，无法安全修改 Docker JSON 配置。"
        print_error "请手动删除 $config_file 中的 credsStore 字段。"
        return 1
    fi

    if ! mv "$temp_file" "$config_file"; then
        rm -f "$temp_file"
        print_error "无法写回 Docker 配置，已保留备份: $backup_file"
        return 1
    fi
    chmod "$config_mode" "$config_file" 2>/dev/null || true
    print_success "Docker 凭据配置已修复，备份文件: $backup_file"
}

# === 配置 Colima ===
ensure_qemu_dependency() {
    local os host_arch macos_major
    os=$(detect_os)
    host_arch=$(detect_arch)

    # macOS 13+ 的 Apple Silicon 默认使用 VZ；其余 macOS 配置使用 QEMU。
    if [[ "$os" == "macos" ]]; then
        if ! macos_requires_qemu "$host_arch"; then
            return 0
        fi

        # MacPorts 安装位置不一定已在当前 shell 的 PATH 中。
        if [[ -x /opt/local/bin/qemu-img ]] && ! command -v qemu-img &> /dev/null; then
            export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
        fi

        if command -v qemu-img &> /dev/null; then
            print_success "QEMU 已安装: $(qemu-img --version | head -1)"
            return 0
        fi

        if ! command -v brew &> /dev/null; then
            print_error "Intel macOS 运行 Colima 需要 QEMU，但未找到 Homebrew。"
            print_error "请先安装 Homebrew，或手工安装 QEMU 后重试。"
            return 1
        fi

        macos_major=$(macos_major_version)
        if [[ "$macos_major" -lt 14 ]]; then
            print_warn "macOS $macos_major 没有当前 QEMU 的 Homebrew bottle。"
            print_info "安装 Homebrew LLVM，并使用 LLVM 编译 QEMU（可能需要较长时间）..."

            if ! brew list --formula llvm &> /dev/null; then
                brew install llvm
            fi
            if ! brew install --build-from-source --cc=llvm_clang qemu; then
                print_error "QEMU 编译失败。"
                print_error "请确认已安装 Xcode Command Line Tools，或安装 Monterey 版 MacPorts 后执行: sudo port install qemu colima docker docker-compose-plugin"
                return 1
            fi
        else
            print_info "正在通过 Homebrew 安装 qemu..."
            brew install qemu
        fi
    elif [[ "$os" == "linux" ]] && ! command -v qemu-img &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            print_info "正在安装 QEMU 工具包 qemu-utils..."
            sudo apt-get update
            sudo apt-get install -y qemu-utils
        elif command -v yum &> /dev/null; then
            print_info "正在安装 QEMU 工具包 qemu-img..."
            sudo yum install -y qemu-img
        else
            print_error "Linux 运行 Colima 需要 qemu-img，请手工安装 QEMU 后重试。"
            return 1
        fi
    fi

    command -v qemu-img &> /dev/null || {
        print_error "QEMU 安装后仍未找到 qemu-img，请检查 PATH。"
        return 1
    }
    print_success "QEMU 已准备好: $(qemu-img --version | head -1)"
}

configure_colima() {
    print_header "配置 Colima"

    ensure_qemu_dependency

    # 如果 Colima 已在运行，先停止；Broken 状态也先做无损清理，避免
    # 复用失效的 Lima socket/pid 文件。
    local current_status
    current_status="$(colima status 2>&1 || true)"
    if grep -Eqi '(^|[[:space:]])running([[:space:]]|$)' <<< "$current_status"; then
        print_info "Colima 正在运行，先停止..."
        colima stop
    elif grep -q "Broken" <<< "$current_status"; then
        print_warn "检测到 Colima 实例处于 Broken 状态，正在清理运行状态..."
        colima stop --force 2>/dev/null || true
    fi

    # 构建启动参数
    local -a start_args=()

    if [[ -n "$ARCH" ]]; then
        start_args+=(--arch "$ARCH")
    fi

    start_args+=(--cpu "$CPU")
    start_args+=(--memory "$MEMORY")
    start_args+=(--disk "$DISK")
    start_args+=(--runtime "$RUNTIME")

    print_info "启动参数: colima start ${start_args[*]}"
    print_info "首次启动需要下载虚拟机镜像，请耐心等待 (约 1-3 分钟)..."
    echo ""

    # 启动 colima
    colima start "${start_args[@]}"

    # colima start 返回成功不等于 Docker socket 已经可用；真正的 Docker
    # 健康检查在配置 context 后执行。
    print_success "Colima 启动命令执行完成"
}

# === 配置 Docker Context ===
configure_docker_context() {
    print_header "配置 Docker Context"

    # 设置 colima 为默认 context
    if docker context inspect colima >/dev/null 2>&1; then
        docker context use colima
    else
        print_warn "未找到 colima Docker context，后续将直接使用 Colima socket 检查。"
    fi

    print_success "Docker Context 已配置"
}

# === 检查 Docker daemon ===
verify_docker() {
    local info_output

    print_header "检查 Docker daemon"

    # 显式指定 colima context，避免当前 shell 中残留 DOCKER_HOST 或默认
    # context 导致误判。
    if ! info_output="$(docker --context colima info 2>&1)"; then
        print_error "Docker daemon 不可用，实际错误如下："
        echo "$info_output" >&2
        print_error "Colima 状态："
        colima status 2>&1 || true
        return 1
    fi

    print_success "Docker daemon 已连接。"
}

# === 卸载 Colima ===
uninstall_colima_stack() {
    print_header "卸载 Colima"
    local os
    os=$(detect_os)

    if ! confirm_action "确认卸载 Colima 相关组件？"; then
        print_info "已取消卸载"
        return 0
    fi

    if command -v colima &> /dev/null; then
        if colima status &>/dev/null; then
            print_info "停止 Colima..."
            colima stop 2>/dev/null || true
        fi

        print_info "删除 Colima 虚拟机实例..."
        colima delete -f 2>/dev/null || true
    else
        print_warn "未检测到 colima 命令"
    fi

    if command -v docker &> /dev/null; then
        print_info "清理 Docker context..."
        docker context use default 2>/dev/null || true
        docker context rm colima -f 2>/dev/null || true
    fi

    if [[ "$os" == "macos" ]] && command -v brew &> /dev/null; then
        print_info "通过 Homebrew 卸载 colima/docker/docker-compose..."
        brew uninstall colima 2>/dev/null || true
        brew uninstall docker-compose 2>/dev/null || true
        brew uninstall docker 2>/dev/null || true
        brew autoremove 2>/dev/null || true
    elif [[ "$os" == "linux" ]]; then
        print_info "卸载 Linux 上的 colima/docker/docker-compose..."
        sudo rm -f /usr/local/bin/colima /usr/bin/colima 2>/dev/null || true
        if command -v apt-get &> /dev/null; then
            sudo apt-get remove -y docker.io docker-compose-plugin 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true
        elif command -v yum &> /dev/null; then
            sudo yum remove -y docker docker-compose-plugin 2>/dev/null || true
        fi
    else
        print_warn "未检测到 Homebrew，请手动移除 colima/docker/docker-compose"
    fi

    if [[ "$PURGE" == "true" ]]; then
        if confirm_action "确认删除 ~/.colima 数据目录？该操作不可恢复"; then
            print_info "删除 ~/.colima..."
            rm -rf "$HOME/.colima"
        else
            print_info "保留 ~/.colima"
        fi
    else
        print_info "保留 ~/.colima。如需删除数据，请使用: ./$SCRIPT_NAME uninstall --purge"
    fi

    print_success "Colima 卸载流程完成"
}

# === 显示使用说明 ===
show_usage() {
    print_header "安装完成"

    cat << EOF
${GREEN}Colima 安装成功！${NC}

${BOLD}Colima 状态:${NC}
  colima status          # 查看状态
  colima start           # 启动
  colima stop            # 停止
  colima restart         # 重启
  colima delete          # 删除虚拟机（数据会丢失）

${BOLD}Docker 命令:${NC}
  docker ps              # 查看容器
  docker compose up -d   # 启动 Compose 项目

${BOLD}配置信息:${NC}
  CPU:    ${CPU} 核
  内存:   ${MEMORY} GB
  磁盘:   ${DISK} GB
  运行时: ${RUNTIME}

${BOLD}虚拟机数据位置:${NC}
  ~/.colima/

${BOLD}更多信息:${NC}
  https://github.com/abiosoft/colima
  https://lima-vm.io/

EOF
}

# === 交互式配置 ===
interactive_config() {
    echo ""
    print_header "Colima 安装配置"
    echo ""

    local input

    read -rp "CPU 核心数 [$CPU]: " input
    CPU="${input:-$CPU}"

    read -rp "内存大小 GB [$MEMORY]: " input
    MEMORY="${input:-$MEMORY}"

    read -rp "磁盘大小 GB [$DISK]: " input
    DISK="${input:-$DISK}"

    read -rp "运行时 (docker/containerd) [$RUNTIME]: " input
    RUNTIME="${input:-$RUNTIME}"

    echo ""
}

# === 主函数 ===
main() {
    print_header "Colima 管理脚本"

    # 检测操作系统
    local os=$(detect_os)
    if [[ "$os" == "unknown" ]]; then
        print_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi

    print_info "检测到系统: $os ($(detect_arch))"
    echo ""

    # 解析参数
    parse_args "$@"

    if [[ "$ACTION" == "uninstall" ]]; then
        uninstall_colima_stack
        return 0
    fi

    if [[ $# -eq 0 ]]; then
        interactive_config
    fi

    # 显示配置
    echo "安装配置:"
    echo "  系统:     $os"
    echo "  CPU:      $CPU 核"
    echo "  内存:     $MEMORY GB"
    echo "  磁盘:     $DISK GB"
    echo "  运行时:   $RUNTIME"
    echo ""

    # 安装组件
    install_colima
    install_docker_cli
    install_docker_compose
    repair_docker_credential_store

    # 配置并启动
    configure_colima
    configure_docker_context

    # 先确认 Docker daemon，再显示安装成功；避免仅凭 colima start 的返回码
    # 把 Broken 或无权限 socket 误报为安装成功。
    if ! verify_docker; then
        print_error "Colima 已启动，但 Docker 尚未通过健康检查。"
        print_error "请执行以下命令获取完整诊断："
        print_error "  colima status"
        print_error "  docker --context colima info"
        exit 1
    fi

    # 显示使用说明
    show_usage
}

# 执行主函数
main "$@"

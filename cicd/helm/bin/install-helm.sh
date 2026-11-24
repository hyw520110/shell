#!/bin/bash

# Helm 一键安装配置脚本
# Helm 是 Kubernetes 包管理器，用于简化 K8s 应用的部署和管理
# 支持通过官方脚本或二进制文件安装

set -e
set -u
set -o pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly HELM_VERSION="${HELM_VERSION:-3.17.0}"
readonly DEFAULT_HELM_DIR="$HOME/helm"
readonly DEFAULT_DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_HELM_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
UNINSTALL_MODE=false
DRY_RUN=false
SKIP_VERIFY=false

# === 工具函数 ===
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }

# === 显示帮助 ===
show_usage() {
    cat << 'EOF'
Helm 一键安装配置脚本

Helm 是 Kubernetes 包管理器，类似 apt/yum，用于管理 K8s 应用的部署、升级和回滚。

用法: ./install-helm.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           安装目录 (默认: $HOME/helm)
    --download-dir DIR      下载目录 (默认: $HOME/Downloads)
    -v, --version VER       Helm 版本 (默认: 3.17.0)
    --skip-verify           跳过 GPG 签名验证
    --dry-run               试运行模式（不实际安装）
    --uninstall             卸载 Helm

示例:
    # 默认安装最新稳定版
    ./install-helm.sh

    # 指定版本
    ./install-helm.sh --version 3.16.4

    # 指定安装目录
    ./install-helm.sh --dir /usr/local/helm

    # 卸载
    ./install-helm.sh --uninstall

使用指南:
    1. 添加常用仓库:
       helm repo add stable https://charts.helm.sh/stable
       helm repo add bitnami https://charts.bitnami.com/bitnami
       helm repo update

    2. 搜索 Chart:
       helm search repo nginx

    3. 安装应用:
       helm install my-nginx bitnami/nginx

    4. 查看已安装:
       helm list

更多信息: https://helm.sh/docs/
EOF
}

# === 解析参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --download-dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            -v|--version)
                HELM_VERSION="$2"
                shift 2
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
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

# === 检测系统 ===
detect_system() {
    local os=""
    local arch=""

    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        CYGWIN*|MINGW*|MSYS*) os="windows" ;;
        *)          print_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        arm64|aarch64)  arch="arm64" ;;
        armv7l|armhf)   arch="arm" ;;
        i386|i686)      arch="386" ;;
        *)              print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    echo "${os}-${arch}"
}

# === 检查 Kubernetes ===
check_kubernetes() {
    if command -v kubectl &> /dev/null; then
        if kubectl version --client &> /dev/null; then
            print_success "kubectl 已安装"
            kubectl version --client 2>/dev/null | head -2
            return 0
        fi
    fi
    print_warning "kubectl 未安装或未配置，Helm 需要 Kubernetes 集群才能使用"
    print_info "请先安装 kubectl 并配置 K8s 集群访问"
    return 1
}

# === 下载文件（带权限修复）===
download_file() {
    local url="$1"
    local output="$2"

    # 修复可能的权限问题（文件被 root 拥有）
    if [[ -f "$output" && ! -w "$output" ]]; then
        print_warning "文件 $output 无写入权限，尝试修复..."
        rm -f "$output" 2>/dev/null || sudo rm -f "$output"
    fi

    # 确保下载目录可写
    if [[ ! -d "$DOWNLOAD_DIR" ]]; then
        mkdir -p "$DOWNLOAD_DIR"
    elif [[ ! -w "$DOWNLOAD_DIR" ]]; then
        print_warning "下载目录无写入权限，尝试修复..."
        sudo chown "$(whoami)" "$DOWNLOAD_DIR" 2>/dev/null || {
            print_error "无法修复下载目录权限: $DOWNLOAD_DIR"
            exit 1
        }
    fi

    if command -v adl &> /dev/null; then
        adl "$url" "$output"
    elif command -v curl &> /dev/null; then
        curl -fSL --progress-bar "$url" -o "$output"
    elif command -v wget &> /dev/null; then
        wget --show-progress -O "$output" "$url"
    else
        print_error "未找到下载工具 (adl/curl/wget)"
        exit 1
    fi
}

# === 安装 Helm ===
install_helm() {
    print_header "安装 Helm ${HELM_VERSION}"

    local platform
    platform=$(detect_system)
    print_info "检测平台: $platform"

    local tarball="helm-v${HELM_VERSION}-${platform}.tar.gz"
    local download_url="https://get.helm.sh/${tarball}"
    local download_path="${DOWNLOAD_DIR}/${tarball}"

    # 检查是否已安装相同版本
    if command -v helm &> /dev/null; then
        local current_version
        current_version=$(helm version --short 2>/dev/null | sed 's/^v//')
        if [[ "$current_version" == "$HELM_VERSION" ]]; then
            print_success "Helm v${HELM_VERSION} 已安装"
            return 0
        else
            print_info "当前版本: v${current_version}，将升级到 v${HELM_VERSION}"
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将下载: $download_url"
        print_info "[Dry-run] 解压到: $INSTALL_DIR"
        return 0
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR/bin"

    # 下载
    print_info "下载 Helm v${HELM_VERSION}..."
    print_info "下载地址: $download_url"

    if [[ -f "$download_path" ]]; then
        print_info "发现已下载文件，跳过下载"
    else
        download_file "$download_url" "$download_path"
        print_success "下载完成"
    fi

    # 验证（可选）
    if [[ "$SKIP_VERIFY" != "true" ]]; then
        print_info "验证下载文件..."
        local checksum_url="${download_url}.sha256"
        local checksum_path="${download_path}.sha256"

        if command -v curl &> /dev/null; then
            curl -fsSL "$checksum_url" -o "$checksum_path" 2>/dev/null || true
        elif command -v wget &> /dev/null; then
            wget -q -O "$checksum_path" "$checksum_url" 2>/dev/null || true
        fi

        if [[ -f "$checksum_path" ]]; then
            local expected_checksum
            expected_checksum=$(awk '{print $1}' "$checksum_path")
            local actual_checksum
            actual_checksum=$(sha256sum "$download_path" 2>/dev/null | awk '{print $1}')
            if [[ -z "$actual_checksum" ]]; then
                actual_checksum=$(shasum -a 256 "$download_path" 2>/dev/null | awk '{print $1}')
            fi

            if [[ "$expected_checksum" == "$actual_checksum" ]]; then
                print_success "校验和验证通过"
            else
                print_warning "校验和不匹配，继续安装..."
            fi
        else
            print_warning "无法获取校验和文件，跳过验证"
        fi
    fi

    # 解压
    print_info "解压文件..."
    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$download_path" -C "$temp_dir"

    # 查找 helm 二进制文件
    local helm_binary
    helm_binary=$(find "$temp_dir" -name "helm" -type f | head -1)

    if [[ -z "$helm_binary" ]]; then
        print_error "未在压缩包中找到 helm 二进制文件"
        rm -rf "$temp_dir"
        exit 1
    fi

    # 安装
    cp "$helm_binary" "$INSTALL_DIR/bin/helm"
    chmod +x "$INSTALL_DIR/bin/helm"

    # 清理
    rm -rf "$temp_dir"

    print_success "Helm 安装完成: $INSTALL_DIR/bin/helm"
}

# === 配置环境变量 ===
setup_environment() {
    print_header "配置环境变量"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将添加 $INSTALL_DIR/bin 到 PATH"
        return 0
    fi

    local shell_rc=""
    case "$(basename "$SHELL")" in
        bash)   shell_rc="$HOME/.bashrc" ;;
        zsh)    shell_rc="$HOME/.zshrc" ;;
        fish)   shell_rc="$HOME/.config/fish/config.fish" ;;
        *)      shell_rc="$HOME/.bashrc" ;;
    esac

    # 检查是否已添加
    if [[ -f "$shell_rc" ]] && grep -q "$INSTALL_DIR/bin" "$shell_rc" 2>/dev/null; then
        print_info "PATH 已配置: $shell_rc"
    else
        print_info "添加 PATH 到 $shell_rc"
        echo "" >> "$shell_rc"
        echo "# Helm" >> "$shell_rc"
        echo "export PATH=\"$INSTALL_DIR/bin:\$PATH\"" >> "$shell_rc"
        print_success "PATH 配置完成"
        print_info "请运行: source $shell_rc"
    fi

    # 当前会话临时添加
    export PATH="$INSTALL_DIR/bin:$PATH"
}

# === 配置自动补全 ===
setup_completion() {
    print_header "配置命令自动补全"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将配置 Helm 自动补全"
        return 0
    fi

    local shell_type=""
    case "$(basename "$SHELL")" in
        bash)   shell_type="bash" ;;
        zsh)    shell_type="zsh" ;;
        fish)   shell_type="fish" ;;
        *)      shell_type="bash" ;;
    esac

    if command -v helm &> /dev/null; then
        local completion_dir=""
        case "$shell_type" in
            bash)
                completion_dir="/etc/bash_completion.d"
                if [[ -d "$completion_dir" && -w "$completion_dir" ]]; then
                    helm completion bash > "$completion_dir/helm"
                    print_success "Bash 自动补全已配置"
                else
                    print_info "Bash 自动补全目录不可写，跳过系统级配置"
                    print_info "可手动添加: helm completion bash >> ~/.bash_completion"
                fi
                ;;
            zsh)
                local zsh_comp_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/helm"
                mkdir -p "$zsh_comp_dir"
                helm completion zsh > "$zsh_comp_dir/_helm"
                print_success "Zsh 自动补全已配置"
                ;;
            fish)
                local fish_comp_dir="$HOME/.config/fish/completions"
                mkdir -p "$fish_comp_dir"
                helm completion fish > "$fish_comp_dir/helm.fish"
                print_success "Fish 自动补全已配置"
                ;;
        esac
    fi
}

# === 添加常用仓库 ===
add_common_repos() {
    print_header "添加常用 Helm 仓库"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将添加常用仓库"
        return 0
    fi

    if ! command -v helm &> /dev/null; then
        print_warning "Helm 未找到，跳过仓库配置"
        return 1
    fi

    # 添加仓库
    helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true

    # 更新
    helm repo update

    print_success "常用仓库添加完成"
}

# === 卸载 Helm ===
uninstall_helm() {
    print_header "卸载 Helm"

    print_warning "此操作将删除 Helm 二进制文件和配置"
    read -p "确定要继续吗？(y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi

    # 删除二进制
    if [[ -f "$INSTALL_DIR/bin/helm" ]]; then
        rm -f "$INSTALL_DIR/bin/helm"
        print_info "删除: $INSTALL_DIR/bin/helm"
    fi

    # 删除配置
    if [[ -d "$HOME/.config/helm" ]]; then
        rm -rf "$HOME/.config/helm"
        print_info "删除: $HOME/.config/helm"
    fi

    if [[ -d "$HOME/.cache/helm" ]]; then
        rm -rf "$HOME/.cache/helm"
        print_info "删除: $HOME/.cache/helm"
    fi

    # 从 PATH 中移除（提示用户手动操作）
    print_info "请手动从 ~/.bashrc 或 ~/.zshrc 中移除以下行:"
    echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""

    print_success "Helm 卸载完成"
}

# === 显示安装信息 ===
show_post_install_info() {
    print_header "安装完成"

    echo -e "${GREEN}Helm 安装成功！${NC}"
    echo ""

    if command -v helm &> /dev/null; then
        echo -e "${BOLD}版本信息:${NC}"
        helm version 2>/dev/null || true
        echo ""
    fi

    echo -e "${BOLD}安装路径:${NC} $INSTALL_DIR/bin/helm"
    echo ""

    echo -e "${BOLD}常用命令:${NC}"
    echo "  查看版本:    helm version"
    echo "  列出仓库:    helm repo list"
    echo "  搜索 Chart:  helm search repo <keyword>"
    echo "  安装应用:    helm install <name> <chart>"
    echo "  查看已安装:  helm list"
    echo "  卸载应用:    helm uninstall <name>"
    echo ""

    echo -e "${BOLD}环境配置:${NC}"
    echo "  请运行: source ~/.bashrc (或 ~/.zshrc)"
    echo "  以更新当前 shell 的 PATH"
    echo ""

    echo -e "${CYAN}更多信息: https://helm.sh/docs/${NC}"
}

# === 主函数 ===
main() {
    print_header "Helm 安装脚本"

    parse_arguments "$@"

    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_helm
        exit 0
    fi

    echo ""
    echo "安装配置:"
    echo "  版本:     v${HELM_VERSION}"
    echo "  安装目录: $INSTALL_DIR"
    echo "  下载目录: $DOWNLOAD_DIR"
    echo "  试运行:   $DRY_RUN"
    echo ""

    # 检查 K8s（非必须，仅提示）
    check_kubernetes || true

    # 安装
    install_helm

    # 配置环境
    setup_environment

    # 配置自动补全
    setup_completion

    # 添加常用仓库
    add_common_repos

    # 显示信息
    show_post_install_info
}

main "$@"

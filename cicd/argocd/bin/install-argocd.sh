#!/bin/bash

# ArgoCD 一键安装配置脚本
# ArgoCD 是 Kubernetes 原生声明式持续交付工具，支持 GitOps 工作流
# 支持通过 kubectl/helm 安装到 K8s 集群，或本地 CLI 安装

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
readonly ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.0}"
readonly ARGOCD_CLI_VERSION="${ARGOCD_CLI_VERSION:-$ARGOCD_VERSION}"
readonly DEFAULT_INSTALL_DIR="$HOME/argocd"
readonly DEFAULT_DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
readonly ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
INSTALL_MODE="auto"     # auto, kubectl, helm, cli-only
UNINSTALL_MODE=false
DRY_RUN=false
EXPOSE_SERVICE=false

# === 工具函数 ===
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_header() { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }

# === 显示帮助 ===
show_usage() {
    cat << 'EOF'
ArgoCD 一键安装配置脚本

ArgoCD 是 Kubernetes 原生声明式持续交付工具，遵循 GitOps 模式。
功能包括：应用同步、多集群管理、自动回滚、RBAC 权限控制等。

用法: ./install-argocd.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           CLI 安装目录 (默认: $HOME/argocd)
    --download-dir DIR      下载目录 (默认: $HOME/Downloads)
    -v, --version VER       ArgoCD 版本 (默认: v2.13.0)
    -m, --mode MODE         安装模式 (auto|kubectl|helm|cli-only，默认: auto)
    --namespace NS          K8s 命名空间 (默认: argocd)
    --expose                暴露 ArgoCD Server 服务（NodePort/LoadBalancer）
    --dry-run               试运行模式（不实际安装）
    --uninstall             卸载 ArgoCD

示例:
    # 默认安装（自动检测 kubectl/helm）
    ./install-argocd.sh

    # 使用 kubectl 安装到 K8s
    ./install-argocd.sh --mode kubectl

    # 使用 Helm 安装到 K8s
    ./install-argocd.sh --mode helm

    # 仅安装 CLI 工具
    ./install-argocd.sh --mode cli-only

    # 暴露服务并指定版本
    ./install-argocd.sh --expose --version v2.12.0

    # 卸载
    ./install-argocd.sh --uninstall

使用指南:
    1. 获取初始密码:
       argocd admin initial-password -n argocd

    2. 登录 ArgoCD:
       argocd login <server-address>

    3. 添加 Git 仓库:
       argocd repo add https://github.com/user/repo.git

    4. 创建应用:
       argocd app create -f app.yaml

更多信息: https://argo-cd.readthedocs.io/
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
                ARGOCD_VERSION="$2"
                ARGOCD_CLI_VERSION="$2"
                shift 2
                ;;
            -m|--mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --namespace)
                ARGOCD_NAMESPACE="$2"
                shift 2
                ;;
            --expose)
                EXPOSE_SERVICE=true
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
        *)          print_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        arm64|aarch64)  arch="arm64" ;;
        *)              print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    echo "${os}-${arch}"
}

# === 检查 Kubernetes ===
check_kubernetes() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl 未安装"
        return 1
    fi

    if ! kubectl version --client &> /dev/null; then
        print_error "kubectl 无法执行"
        return 1
    fi

    # 检查是否能连接集群
    if ! kubectl cluster-info &> /dev/null; then
        print_warning "无法连接到 Kubernetes 集群"
        print_info "请确保 K8s 集群已运行且 kubeconfig 已配置"
        return 1
    fi

    print_success "Kubernetes 集群连接正常"
    return 0
}

# === 检查 Helm ===
check_helm() {
    if command -v helm &> /dev/null; then
        print_success "Helm 已安装"
        return 0
    fi
    return 1
}

# === 确定安装模式 ===
determine_install_mode() {
    if [[ "$INSTALL_MODE" != "auto" ]]; then
        return 0
    fi

    print_info "检测安装环境..."

    local has_kubectl=false
    local has_helm=false
    local has_k8s=false

    if command -v kubectl &> /dev/null; then
        has_kubectl=true
        if kubectl cluster-info &> /dev/null; then
            has_k8s=true
        fi
    fi

    if command -v helm &> /dev/null; then
        has_helm=true
    fi

    if [[ "$has_k8s" == "true" && "$has_helm" == "true" ]]; then
        INSTALL_MODE="helm"
        print_info "检测到 kubectl + Helm + K8s 集群，使用 Helm 模式安装"
    elif [[ "$has_k8s" == "true" && "$has_kubectl" == "true" ]]; then
        INSTALL_MODE="kubectl"
        print_info "检测到 kubectl + K8s 集群，使用 kubectl 模式安装"
    else
        INSTALL_MODE="cli-only"
        print_warning "未检测到 K8s 集群，仅安装 ArgoCD CLI"
    fi
}

# === 下载文件（带权限修复）===
download_file() {
    local url="$1"
    local output="$2"

    # 修复可能的权限问题
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

# === 安装 ArgoCD CLI ===
install_cli() {
    print_header "安装 ArgoCD CLI"

    local platform
    platform=$(detect_system)
    print_info "检测平台: $platform"

    local binary_name="argocd-${platform}"
    local download_url="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/${binary_name}"
    local download_path="${DOWNLOAD_DIR}/argocd-${ARGOCD_CLI_VERSION}"

    # 检查是否已安装相同版本
    if command -v argocd &> /dev/null; then
        local current_version
        current_version=$(argocd version --client 2>/dev/null | grep "argocd:" | head -1 | awk '{print $2}')
        if [[ "$current_version" == "$ARGOCD_CLI_VERSION" ]]; then
            print_success "ArgoCD CLI ${ARGOCD_CLI_VERSION} 已安装"
            return 0
        else
            print_info "当前版本: ${current_version}，将升级到 ${ARGOCD_CLI_VERSION}"
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将下载: $download_url"
        print_info "[Dry-run] 安装到: $INSTALL_DIR/bin/argocd"
        return 0
    fi

    # 创建目录
    mkdir -p "$INSTALL_DIR/bin"

    # 下载
    print_info "下载 ArgoCD CLI ${ARGOCD_CLI_VERSION}..."
    print_info "下载地址: $download_url"

    if [[ -f "$download_path" ]]; then
        print_info "发现已下载文件，跳过下载"
    else
        download_file "$download_url" "$download_path"
        print_success "下载完成"
    fi

    # 安装
    cp "$download_path" "$INSTALL_DIR/bin/argocd"
    chmod +x "$INSTALL_DIR/bin/argocd"

    print_success "ArgoCD CLI 安装完成: $INSTALL_DIR/bin/argocd"
}

# === 使用 kubectl 安装 ArgoCD ===
install_with_kubectl() {
    print_header "使用 kubectl 安装 ArgoCD Server"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将使用 kubectl 安装 ArgoCD"
        return 0
    fi

    # 创建命名空间
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
        print_info "创建命名空间: $ARGOCD_NAMESPACE"
        kubectl create namespace "$ARGOCD_NAMESPACE"
    else
        print_info "命名空间已存在: $ARGOCD_NAMESPACE"
    fi

    # 安装 ArgoCD
    print_info "应用 ArgoCD 安装清单..."
    kubectl apply -n "$ARGOCD_NAMESPACE" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    print_success "ArgoCD Server 安装完成"

    # 等待部署就绪
    print_info "等待 ArgoCD 组件就绪..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n "$ARGOCD_NAMESPACE" 2>/dev/null || {
        print_warning "等待超时，请手动检查状态: kubectl get pods -n $ARGOCD_NAMESPACE"
    }

    # 暴露服务
    if [[ "$EXPOSE_SERVICE" == "true" ]]; then
        expose_service
    fi
}

# === 使用 Helm 安装 ArgoCD ===
install_with_helm() {
    print_header "使用 Helm 安装 ArgoCD Server"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将使用 Helm 安装 ArgoCD"
        return 0
    fi

    # 添加 ArgoCD Helm 仓库
    print_info "添加 ArgoCD Helm 仓库..."
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update

    # 创建命名空间
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
        print_info "创建命名空间: $ARGOCD_NAMESPACE"
        kubectl create namespace "$ARGOCD_NAMESPACE"
    fi

    # 安装 ArgoCD
    print_info "使用 Helm 安装 ArgoCD..."
    helm upgrade --install argocd argo/argo-cd \
        --namespace "$ARGOCD_NAMESPACE" \
        --set server.service.type="${ARGOCD_SERVICE_TYPE:-ClusterIP}" \
        --wait || {
        print_error "Helm 安装失败"
        exit 1
    }

    print_success "ArgoCD Server 安装完成"

    # 暴露服务
    if [[ "$EXPOSE_SERVICE" == "true" ]]; then
        expose_service
    fi
}

# === 暴露 ArgoCD Server 服务 ===
expose_service() {
    print_header "暴露 ArgoCD Server 服务"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将暴露 ArgoCD Server 服务"
        return 0
    fi

    print_info "修改 Service 为 NodePort..."
    kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "NodePort"}}'

    # 获取访问地址
    local node_port
    node_port=$(kubectl get svc argocd-server -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)

    if [[ -n "$node_port" ]]; then
        print_success "ArgoCD Server 已暴露"
        print_info "NodePort: $node_port"
    fi
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

    if [[ -f "$shell_rc" ]] && grep -q "$INSTALL_DIR/bin" "$shell_rc" 2>/dev/null; then
        print_info "PATH 已配置: $shell_rc"
    else
        print_info "添加 PATH 到 $shell_rc"
        echo "" >> "$shell_rc"
        echo "# ArgoCD" >> "$shell_rc"
        echo "export PATH=\"$INSTALL_DIR/bin:\$PATH\"" >> "$shell_rc"
        print_success "PATH 配置完成"
        print_info "请运行: source $shell_rc"
    fi

    export PATH="$INSTALL_DIR/bin:$PATH"
}

# === 配置自动补全 ===
setup_completion() {
    print_header "配置命令自动补全"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 将配置 ArgoCD 自动补全"
        return 0
    fi

    if ! command -v argocd &> /dev/null; then
        return 0
    fi

    local shell_type=""
    case "$(basename "$SHELL")" in
        bash)   shell_type="bash" ;;
        zsh)    shell_type="zsh" ;;
        fish)   shell_type="fish" ;;
        *)      shell_type="bash" ;;
    esac

    case "$shell_type" in
        bash)
            local comp_dir="/etc/bash_completion.d"
            if [[ -d "$comp_dir" && -w "$comp_dir" ]]; then
                argocd completion bash > "$comp_dir/argocd"
                print_success "Bash 自动补全已配置"
            else
                print_info "可手动添加: argocd completion bash >> ~/.bash_completion"
            fi
            ;;
        zsh)
            local zsh_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/argocd"
            mkdir -p "$zsh_dir"
            argocd completion zsh > "$zsh_dir/_argocd"
            print_success "Zsh 自动补全已配置"
            ;;
        fish)
            local fish_dir="$HOME/.config/fish/completions"
            mkdir -p "$fish_dir"
            argocd completion fish > "$fish_dir/argocd.fish"
            print_success "Fish 自动补全已配置"
            ;;
    esac
}

# === 卸载 ArgoCD ===
uninstall_argocd() {
    print_header "卸载 ArgoCD"

    print_warning "此操作将删除 ArgoCD Server 和 CLI"
    read -p "确定要继续吗？(y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi

    # 卸载 K8s 资源
    if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
        print_info "删除 ArgoCD K8s 资源..."

        # 删除 Helm 安装
        if command -v helm &> /dev/null; then
            helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
        fi

        # 删除 kubectl 安装
        kubectl delete -n "$ARGOCD_NAMESPACE" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" 2>/dev/null || true

        # 删除命名空间
        kubectl delete namespace "$ARGOCD_NAMESPACE" 2>/dev/null || true

        print_success "ArgoCD K8s 资源已删除"
    fi

    # 删除 CLI
    if [[ -f "$INSTALL_DIR/bin/argocd" ]]; then
        rm -f "$INSTALL_DIR/bin/argocd"
        print_info "删除 CLI: $INSTALL_DIR/bin/argocd"
    fi

    # 删除配置
    if [[ -d "$HOME/.config/argocd" ]]; then
        rm -rf "$HOME/.config/argocd"
        print_info "删除配置: $HOME/.config/argocd"
    fi

    print_success "ArgoCD 卸载完成"
}

# === 显示安装信息 ===
show_post_install_info() {
    print_header "安装完成"

    echo -e "${GREEN}ArgoCD 安装成功！${NC}"
    echo ""

    if command -v argocd &> /dev/null; then
        echo -e "${BOLD}CLI 版本:${NC}"
        argocd version --client 2>/dev/null || true
        echo ""
    fi

    echo -e "${BOLD}安装路径:${NC} $INSTALL_DIR/bin/argocd"
    echo ""

    if [[ "$INSTALL_MODE" != "cli-only" ]]; then
        echo -e "${BOLD}K8s 部署信息:${NC}"
        echo "  命名空间: $ARGOCD_NAMESPACE"
        echo "  版本:     $ARGOCD_VERSION"
        echo ""

        echo -e "${BOLD}获取初始密码:${NC}"
        echo "  argocd admin initial-password -n $ARGOCD_NAMESPACE"
        echo ""

        echo -e "${BOLD}端口转发访问（本地测试）:${NC}"
        echo "  kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:443"
        echo "  访问: https://localhost:8080"
        echo ""
    fi

    echo -e "${BOLD}常用命令:${NC}"
    echo "  登录:        argocd login <server>"
    echo "  添加仓库:    argocd repo add <url>"
    echo "  创建应用:    argocd app create -f <file>"
    echo "  同步应用:    argocd app sync <app-name>"
    echo "  查看应用:    argocd app list"
    echo "  查看状态:    kubectl get pods -n $ARGOCD_NAMESPACE"
    echo ""

    echo -e "${CYAN}更多信息: https://argo-cd.readthedocs.io/${NC}"
}

# === 主函数 ===
main() {
    print_header "ArgoCD 安装脚本"

    parse_arguments "$@"

    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_argocd
        exit 0
    fi

    echo ""
    echo "安装配置:"
    echo "  版本:       ${ARGOCD_VERSION}"
    echo "  安装目录:   $INSTALL_DIR"
    echo "  下载目录:   $DOWNLOAD_DIR"
    echo "  安装模式:   $INSTALL_MODE"
    echo "  命名空间:   $ARGOCD_NAMESPACE"
    echo "  暴露服务:   $EXPOSE_SERVICE"
    echo "  试运行:     $DRY_RUN"
    echo ""

    # 确定安装模式
    determine_install_mode

    # 安装 CLI（所有模式都需要）
    install_cli

    # K8s 模式安装 Server
    if [[ "$INSTALL_MODE" == "kubectl" ]]; then
        if check_kubernetes; then
            install_with_kubectl
        else
            print_error "无法连接到 K8s 集群，仅安装 CLI"
        fi
    elif [[ "$INSTALL_MODE" == "helm" ]]; then
        if check_kubernetes && check_helm; then
            install_with_helm
        else
            print_error "缺少 kubectl 或 Helm，仅安装 CLI"
        fi
    fi

    # 配置环境
    setup_environment

    # 配置自动补全
    setup_completion

    # 显示信息
    show_post_install_info
}

main "$@"

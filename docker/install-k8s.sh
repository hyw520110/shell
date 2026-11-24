#!/bin/bash

# Kubernetes一键安装脚本, 支持Linux和macOS系统，使用国内镜像源

# 显示帮助信息
show_help() {
    cat << EOF
Kubernetes一键安装脚本

支持Linux和macOS系统的Kubernetes集群一键安装，使用国内镜像源加速。

用法: ./install-k8s.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息
    --skip-cluster        仅安装工具，不启动集群
    --driver <类型>       指定驱动类型 (docker, virtualbox, hyperkit)
    --k8s-version <版本>   指定 Kubernetes 版本 (默认: stable，可用 K8S_VERSION 覆盖)

说明:
    - 自动检测操作系统并选择合适的安装方式
    - 支持国内镜像源，加速下载速度
    - 安装组件：Docker、kubectl、Minikube
    - 自动配置Minikube使用国内镜像
    - 支持单节点Kubernetes集群

支持的操作系统:
    - Linux: CentOS 7+, Ubuntu 18.04+, Debian 9+, Rocky Linux 8+
    - macOS: 10.15+ (支持Intel和Apple Silicon芯片)

示例:
    sudo ./install-k8s.sh                          # 完整安装
    sudo ./install-k8s.sh --skip-cluster           # 仅安装工具
    sudo ./install-k8s.sh --driver virtualbox      # 使用VirtualBox驱动

注意事项:
    - 建议使用 sudo 运行以获得完整权限
    - macOS需要先安装Homebrew
    - 集群启动会消耗较多资源（建议至少4GB内存）
    - 如遇网络问题，可能需要多次重试

配置集群环境:
    eval $(minikube docker-env)
    minikube dashboard

EOF
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
skip_cluster=false
driver_type="docker"
k8s_version="${K8S_VERSION:-stable}"

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Kubernetes安装脚本版本: 1.0"
            exit 0
            ;;
        --skip-cluster)
            skip_cluster=true
            shift
            ;;
        --driver)
            driver_type="$2"
            shift 2
            ;;
        --k8s-version)
            k8s_version="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检测操作系统
OS_TYPE=$(uname -s)
echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"

# 依赖检测函数
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}$1 未安装${NC}"
        return 1
    else
        echo -e "${GREEN}$1 已安装${NC}"
        return 0
    fi
}

# 安装依赖函数
install_dependency() {
    echo -e "${YELLOW}正在安装 $1...${NC}"
    if [[ "$OS_TYPE" == "Linux" ]]; then
        if command -v apt &> /dev/null; then
            sudo apt-get install -y "$1"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "$1"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "$1"
        else
            echo -e "${RED}不支持的包管理器${NC}"
            return 1
        fi
    elif [[ "$OS_TYPE" == "Darwin" ]]; then
        brew install "$1"
    fi
}

install_brew_package() {
    local command_name="$1"
    local formula="$2"
    local cask="${3:-}"

    if check_dependency "$command_name"; then
        return 0
    fi

    echo -e "${YELLOW}正在安装 ${command_name}...${NC}"
    if [[ -n "$cask" ]]; then
        brew install --cask "$cask" || brew install "$formula" || {
            echo -e "${RED}${command_name} 安装失败，请检查 Homebrew 输出${NC}"
            return 1
        }
    else
        brew install "$formula" || {
            echo -e "${RED}${command_name} 安装失败，请检查 Homebrew 输出${NC}"
            return 1
        }
    fi

    check_dependency "$command_name" || {
        echo -e "${RED}${command_name} 安装后仍不可用，请检查 PATH${NC}"
        return 1
    }
}

# Linux系统安装函数
install_linux() {
    # 确保包管理器可用
    if command -v apt &> /dev/null; then
        PKG_MANAGER="apt-get"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    else
        echo -e "${RED}不支持的包管理器${NC}"
        exit 1
    fi

    # 更新包列表
    echo -e "${YELLOW}更新包列表...${NC}"
    sudo $PKG_MANAGER update -y

    # 安装基础依赖
    local base_deps=("curl" "socat" "iproute2" "conntrack" "iptables" "ebtables" "ethtool")
    for dep in "${base_deps[@]}"; do
        if ! check_dependency "$dep"; then
            install_dependency "$dep"
        fi
    done

    # 安装docker
    if ! check_dependency docker; then
        echo -e "${YELLOW}正在安装Docker...${NC}"
        if [ -f ./install-docker-compose.sh ]; then
            sudo bash ./install-docker-compose.sh
        else
            # 使用国内镜像安装Docker
            curl -fsSL https://get.docker.com | sudo sh -s -- --mirror Aliyun
        fi
        # 将当前用户加入docker组
        sudo usermod -aG docker $USER
        echo -e "${YELLOW}已将用户 $USER 添加到docker组，需要重新登录生效${NC}"
    fi

    # 启动docker
    if ! docker system info &>/dev/null; then
        sudo systemctl start docker
        sudo systemctl enable docker
        while ! docker system info &>/dev/null; do
            echo -e "${YELLOW}等待Docker启动...${NC}"
            sleep 3
        done
    fi

    # 下载并安装kubectl（使用国内镜像）
    if ! check_dependency kubectl; then
        echo -e "${YELLOW}正在安装kubectl...${NC}"
        # 使用阿里云镜像
        KUBECTL_URL="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        # 备用镜像
        if ! curl -fLO "$KUBECTL_URL"; then
            echo -e "${YELLOW}使用阿里云镜像下载kubectl...${NC}"
            KUBECTL_URL="https://mirrors.aliyun.com/kubernetes-release/release/$(curl -L -s https://mirrors.aliyun.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
            curl -fLO "$KUBECTL_URL"
        fi

        if [ -f kubectl ]; then
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
            echo -e "${GREEN}kubectl已安装${NC}"
        else
            echo -e "${RED}kubectl下载失败，请手动下载${NC}"
            exit 1
        fi
    fi

    # 下载并安装minikube（使用国内镜像）
    if ! check_dependency minikube; then
        echo -e "${YELLOW}正在安装Minikube...${NC}"
        # 使用阿里云镜像
        MINIKUBE_URL="https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-amd64"
        # 备用镜像
        if ! curl -fLO "$MINIKUBE_URL"; then
            echo -e "${YELLOW}使用阿里云镜像下载Minikube...${NC}"
            MINIKUBE_URL="https://kubernetes.oss-cn-hangzhou.aliyuncs.com/minikube/releases/latest/minikube-linux-amd64"
            curl -fLO "$MINIKUBE_URL"
        fi

        if [ -f minikube-linux-amd64 ]; then
            sudo install minikube-linux-amd64 /usr/local/bin/minikube
            rm minikube-linux-amd64
            echo -e "${GREEN}Minikube已安装${NC}"
        else
            echo -e "${RED}minikube下载失败，请手动下载${NC}"
            exit 1
        fi
    fi
}

# macOS系统安装函数
install_macos() {
    # 安装Homebrew
    if ! check_dependency brew; then
        /bin/bash -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/Homebrew/install@HEAD/install.sh)"
    fi

    # 设置Homebrew国内镜像
    if [ -d "/opt/homebrew" ]; then
        HOMEBREW_PREFIX="/opt/homebrew"
    else
        HOMEBREW_PREFIX="/usr/local"
    fi

    if ! grep -q "mirrors.ustc.edu.cn" ${HOMEBREW_PREFIX}/etc/brew/brew.conf 2>/dev/null; then
        echo -e "${YELLOW}设置Homebrew国内镜像...${NC}"
        git -C "$(brew --repo)" remote set-url origin https://mirrors.ustc.edu.cn/brew.git
        if [ -f "$(brew --repo homebrew/core)" ]; then
            git -C "$(brew --repo homebrew/core)" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-core.git
        fi
        if [ -f "$(brew --repo homebrew/cask)" ]; then
            git -C "$(brew --repo homebrew/cask)" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-cask.git
        fi
        brew update
    fi

    # 安装依赖。kubectl 的 Homebrew formula 是 kubernetes-cli；Docker Desktop 用 cask。
    install_brew_package "socat" "socat" || exit 1
    install_brew_package "kubectl" "kubernetes-cli" || exit 1
    install_brew_package "minikube" "minikube" || exit 1
    install_brew_package "docker" "docker" "docker" || exit 1

    # 确保Docker正在运行
    if ! docker system info &>/dev/null; then
        echo -e "${YELLOW}尝试启动 Docker 守护进程...${NC}"
        if command -v colima &>/dev/null; then
            echo -e "${YELLOW}检测到 Colima，尝试通过 Colima 启动 Docker...${NC}"
            colima start
        else
            open -a Docker 2>/dev/null || { echo -e "${RED}未找到 Docker Desktop 或 Colima，请先手动安装并启动 Docker${NC}"; exit 1; }
        fi

        local retry=0
        while ! docker system info &>/dev/null; do
            if [ $retry -ge 12 ]; then
                echo -e "${RED}等待 Docker 启动超时，请手动检查 Docker 状态${NC}"
                exit 1
            fi
            echo -e "${YELLOW}等待Docker启动 ($retry/12)...${NC}"
            sleep 5
            ((retry++))
        done
        echo -e "${GREEN}Docker 启动成功${NC}"
    fi
}

# 配置minikube使用国内镜像
configure_minikube() {
    echo -e "${YELLOW}配置Minikube使用国内镜像...${NC}"

    # minikube v1.38+ 不再接受 image_repository/http_proxy/https_proxy/no_proxy
    # 这类下划线配置项；镜像仓库和代理改在 minikube start 时通过参数/环境变量传入。
    minikube config set driver "$driver_type" >/dev/null 2>&1 || true
}

# 启动Kubernetes集群
start_cluster() {
    echo -e "${YELLOW}正在启动Kubernetes集群...${NC}"
    local driver="$driver_type"
    local http_proxy_value="${HTTP_PROXY:-${http_proxy:-}}"
    local https_proxy_value="${HTTPS_PROXY:-${https_proxy:-$http_proxy_value}}"
    local no_proxy_value="${NO_PROXY:-${no_proxy:-}}"
    local minikube_no_proxy="localhost,127.0.0.1,::1,192.168.49.0/24,192.168.49.2,10.96.0.0/12,.svc,.cluster.local"
    local start_args=()

    # 配置minikube
    configure_minikube

    if [[ -n "$no_proxy_value" ]]; then
        no_proxy_value="${no_proxy_value},${minikube_no_proxy}"
    else
        no_proxy_value="$minikube_no_proxy"
    fi

    start_args+=("--driver=$driver")
    start_args+=("--image-repository=registry.cn-hangzhou.aliyuncs.com/google_containers")
    start_args+=("--kubernetes-version=$k8s_version")

    if [[ -n "$http_proxy_value" ]]; then
        export HTTP_PROXY="$http_proxy_value"
        export http_proxy="$http_proxy_value"
        start_args+=("--docker-env=HTTP_PROXY=$http_proxy_value")
        start_args+=("--docker-env=http_proxy=$http_proxy_value")
    fi
    if [[ -n "$https_proxy_value" ]]; then
        export HTTPS_PROXY="$https_proxy_value"
        export https_proxy="$https_proxy_value"
        start_args+=("--docker-env=HTTPS_PROXY=$https_proxy_value")
        start_args+=("--docker-env=https_proxy=$https_proxy_value")
    fi
    export NO_PROXY="$no_proxy_value"
    export no_proxy="$no_proxy_value"
    start_args+=("--docker-env=NO_PROXY=$no_proxy_value")
    start_args+=("--docker-env=no_proxy=$no_proxy_value")

    if minikube status | grep -q "Running"; then
        echo -e "${GREEN}集群已在运行中${NC}"
    else
        echo -e "${YELLOW}启动 Minikube (使用驱动: $driver)...${NC}"
        minikube start "${start_args[@]}" || {
            echo -e "${RED}启动集群失败，请检查错误信息${NC}"
            exit 1
        }

        minikube addons enable ingress
        minikube addons enable metrics-server
    fi

    minikube kubectl -- config use-context minikube

    echo -e "${GREEN}集群状态:${NC}"
    minikube status
}

# 验证安装
verify_installation() {
    echo -e "\n${YELLOW}验证安装...${NC}"
    if command -v kubectl &> /dev/null; then
        echo -e "${GREEN}kubectl版本:${NC}"
        kubectl version --client
    fi

    if command -v minikube &> /dev/null; then
        echo -e "\n${GREEN}Minikube版本:${NC}"
        minikube version
    fi

    echo -e "\n${GREEN}Kubernetes节点:${NC}"
    minikube kubectl -- get nodes || echo -e "${RED}无法获取节点信息${NC}"

    echo -e "\n${GREEN}集群信息:${NC}"
    minikube kubectl -- cluster-info || echo -e "${RED}无法获取集群信息${NC}"
}

main() {
    echo "开始安装Kubernetes..."

    # 移除原本建议使用 sudo 的拦截，因为 macOS brew 以及 minikube start 都强烈建议作为普通用户执行
    if [ "$(id -u)" -eq 0 ] && [ "$OS_TYPE" == "Darwin" ]; then
        echo -e "${RED}错误: 在 macOS 上禁止使用 root(sudo) 运行此脚本，因为 Homebrew 不支持 root 运行。请作为普通用户执行。${NC}"
        exit 1
    fi

    if [ "$OS_TYPE" == "Linux" ]; then
        install_linux
    elif [ "$OS_TYPE" == "Darwin" ]; then
        install_macos
    else
        echo -e "${RED}不支持的操作系统: $OS_TYPE${NC}"
        exit 1
    fi

    if [ "$skip_cluster" = false ]; then
        start_cluster
        verify_installation

        echo -e "\n${GREEN}===== 安装完成 ====${NC}"
        echo -e "运行以下命令配置shell环境:"
        echo -e "  Linux/macOS: eval \$(minikube docker-env)"
        echo -e "管理集群:"
        echo -e "  启动: minikube start"
        echo -e "  停止: minikube stop"
        echo -e "  删除: minikube delete"
        echo -e "访问控制台: minikube dashboard"
        echo -e "${YELLOW}注意: 如果使用非root用户运行，某些操作可能需要sudo权限${NC}"
    else
        echo -e "\n${GREEN}===== 工具安装完成 ====${NC}"
        echo -e "要启动集群，请运行: minikube start --driver=$driver_type"
    fi
}

main

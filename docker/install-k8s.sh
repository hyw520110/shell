#!/bin/bash

# Kubernetes一键安装脚本, 支持Linux和macOS系统，使用国内镜像源

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

    # 安装依赖
    local mac_deps=("socat" "kubectl" "minikube" "docker")
    for dep in "${mac_deps[@]}"; do
        if ! check_dependency "$dep"; then
            brew install "$dep"
        fi
    done
    
    # 确保Docker正在运行
    if ! docker system info &>/dev/null; then
        open -a Docker
        while ! docker system info &>/dev/null; do
            echo -e "${YELLOW}等待Docker启动...${NC}"
            sleep 5
        done
    fi
}

# 配置minikube使用国内镜像
configure_minikube() {
    echo -e "${YELLOW}配置Minikube使用国内镜像...${NC}"
    
    # 设置镜像源
    minikube config set image_repository registry.cn-hangzhou.aliyuncs.com/google_containers
    
    # 设置代理（如果需要）
    if [ -n "$http_proxy" ]; then
        minikube config set http_proxy $http_proxy
        minikube config set https_proxy $https_proxy
        minikube config set no_proxy $no_proxy
    fi
    
    # 预加载基础镜像
    minikube config set WantReportErrorPrompt false
}

# 启动Kubernetes集群
start_cluster() {
    echo -e "${YELLOW}正在启动Kubernetes集群...${NC}"
    local driver="docker"
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        driver="docker"
    fi

    # 配置minikube
    configure_minikube

    if minikube status | grep -q "Running"; then
        echo -e "${GREEN}集群已在运行中${NC}"
    else
        # 检查是否有足够的权限
        if [ "$(id -u)" -ne 0 ]; then
            # 尝试使用sudo启动
            echo -e "${YELLOW}尝试使用sudo启动集群...${NC}"
            sudo -E minikube start --driver="$driver" \
                --image-mirror-country='cn' \
                --image-repository='registry.cn-hangzhou.aliyuncs.com/google_containers' \
                --kubernetes-version=stable || {
                echo -e "${RED}启动集群失败，请检查错误信息${NC}"
                exit 1
            }
        else
            minikube start --driver="$driver" \
                --image-mirror-country='cn' \
                --image-repository='registry.cn-hangzhou.aliyuncs.com/google_containers' \
                --kubernetes-version=stable || {
                echo -e "${RED}启动集群失败，请检查错误信息${NC}"
                exit 1
            }
        fi
        
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
    
    # 检测是否使用sudo
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${YELLOW}警告: 建议使用sudo运行此脚本以获得完整权限${NC}"
        read -p "是否继续? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    if [ "$OS_TYPE" == "Linux" ]; then
        install_linux
    elif [ "$OS_TYPE" == "Darwin" ]; then
        install_macos
    else
        echo -e "${RED}不支持的操作系统: $OS_TYPE${NC}"
        exit 1
    fi

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
}

main
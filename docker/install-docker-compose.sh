#!/bin/bash
# docker和docker-compose自动安装、配置

# 显示帮助信息
show_help() {
    cat << EOF
Docker和Docker Compose自动安装脚本

自动安装和配置Docker、Docker Compose，支持Linux和macOS系统。

用法: ./install-docker-compose.sh [选项]

选项:
    -h, --help            显示此帮助信息
    -v, --version         显示版本信息
    --compose-version <版本> 指定Docker Compose版本 (默认: 2.38.2)
    --skip-mirrors        跳过镜像配置

说明:
    - 脚本会自动检测操作系统类型并选择合适的安装方式
    - Linux系统支持 yum、apt-get、dnf 包管理器
    - macOS系统支持 Homebrew 和 Docker Desktop
    - 自动配置国内镜像源加速镜像下载
    - 需要root权限执行

支持的操作系统:
    - Linux: CentOS 7+, Ubuntu 18.04+, Debian 9+, Rocky Linux 8+
    - macOS: 10.15+ (支持Intel和Apple Silicon芯片)

示例:
    sudo ./install-docker-compose.sh                # 使用默认设置安装
    sudo ./install-docker-compose.sh --skip-mirrors # 跳过镜像配置
    sudo ./install-docker-compose.sh --compose-version 2.40.0 # 指定版本

注意事项:
    - 需要 root 权限运行
    - 安装过程中会重启Docker服务
    - macOS需要先安装Homebrew或手动下载Docker Desktop
    - 建议在安装前备份重要数据

EOF
}

# 默认版本
f=/usr/local/bin/docker-compose
docker_compose_version="2.38.2"  # docker-compose版本定义成变量
skip_mirrors=false

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Docker Compose安装脚本版本: 1.0"
            exit 0
            ;;
        --compose-version)
            docker_compose_version="$2"
            shift 2
            ;;
        --skip-mirrors)
            skip_mirrors=true
            shift
            ;;
        *)
            echo "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查操作系统类型
OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"

# 获取真实用户目录（解决 sudo 下 ~ 指向 root 家目录的问题）
get_user_home() {
    if [[ -n "$SUDO_USER" ]]; then
        eval echo "~$SUDO_USER"
    else
        echo "$HOME"
    fi
}
USER_HOME=$(get_user_home)
USER_DOWNLOADS="$USER_HOME/Downloads"

# 权限检查：Linux 需要 sudo，macOS 不需要
if [[ "$OS_TYPE" == "Linux" ]]; then
    if [[ "$EUID" -ne 0 ]]; then
        echo "[INFO] 需要 root 权限，正在自动提权..."
        exec sudo "$0" "$@"
    fi
elif [[ "$OS_TYPE" == "Darwin" ]]; then
    # macOS 安装 Docker Desktop 不需要 root，反而 Homebrew 不能以 root 运行
    if [[ "$EUID" -eq 0 ]]; then
        echo "[INFO] macOS 不需要 sudo 权限，正在切换回普通用户..."
        if [[ -n "$SUDO_USER" ]]; then
            exec su - "$SUDO_USER" -c "cd '$(pwd)' && '$0' $*"
        fi
    fi
fi

# 日志输出函数
echo_info() {
    echo "[INFO] $1"
}

echo_error() {
    echo "[ERROR] $1" >&2
}

# 检查Docker是否已安装
is_docker_installed() {
    command -v docker &> /dev/null
}

# 判断Docker是否已启动
is_docker_running() {
    if [ "$OS_TYPE" = "Linux" ]; then
        systemctl is-active --quiet docker 2>/dev/null
    elif [ "$OS_TYPE" = "Darwin" ]; then
        pgrep -x "Docker" >/dev/null 2>&1
    else
        echo_error "不支持的操作系统: $OS_TYPE"
        return 1
    fi
}

# 验证docker-compose是否可用
verify_docker_compose() {
    if [ -f "$f" ]; then
        echo_info "检测到docker-compose安装文件"
        
        # 检查文件权限
        if [ ! -x "$f" ]; then
            echo_error "docker-compose没有执行权限，正在添加权限..."
            sudo chmod +x "$f"
        fi
        
        # 尝试执行docker-compose版本检查
        if [ ! "$f" --version &> /dev/null ]; then
            echo_error "docker-compose 存在但不可用，正在删除..."
            sudo rm -f "$f"
            echo_info "docker-compose 已删除"
        else
            echo_info "docker-compose 版本: $(sudo "$f" --version)"
        fi
    fi
}

# 安装docker-compose (仅适用于Linux)
install_docker_compose(){
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # 检查现有docker-compose状态
        verify_docker_compose
        if [ ! -f "$f" ]; then
            read -t 10 -p "是否安装docker-compose(y/n,10秒后取消安装)" need_install
            if [ "$need_install" == "y" ]; then
                echo_info "正在安装docker-compose..."
                url="https://github.com/docker/compose/releases/download/v${docker_compose_version}/docker-compose-$(uname -s)-$(uname -m)"
                echo_info "下载docker-compose: $url"
                curl -L $url -o $f
                sudo chmod +x $f
            fi
        else
            echo_info "docker-compose已安装"
        fi
    fi
}

# 检查镜像配置
check_docker_mirrors() {
    if [ "$skip_mirrors" = true ]; then
        echo_info "跳过镜像配置"
        return
    fi
    
    if [ -f /etc/docker/daemon.json ]; then
        echo_info "检测到Docker镜像配置文件存在"
        current_mirrors=$(cat /etc/docker/daemon.json | grep -A 2 "registry-mirrors")
        echo "当前镜像配置：$current_mirrors"
    else
        read -t 10 -p "是否需要配置镜像(y/n,10秒后取消配置)" need_configure
        if [ "$need_configure" == "y" ]; then
            echo_info "正在配置默认镜像..."
            configure_docker_mirrors
        fi
    fi
}

# 配置Docker镜像
configure_docker_mirrors() {
    cat > /etc/docker/daemon.json <<-EOF
{
  "registry-mirrors": ["http://hub-mirror.c.163.com", "https://docker.mirrors.ustc.edu.cn", "https://reg-mirror.qiniu.com", "http://f1361db2.m.daocloud.io"]
}
EOF
    
    if [ "$OS_TYPE" = "Linux" ]; then
        systemctl daemon-reload
        systemctl restart docker
    fi
    
    echo_info "Docker镜像配置已完成"
}

install_docker(){
    # 判断docker是否安装，已安装输出docker版本
    if is_docker_installed; then
        docker -v 2>/dev/null
        echo_info "docker已安装"
        [ "$OSTYPE" == "linux-gnu"* ] && echo -e "如需卸载，执行：\n$(command -v yum || command -v apt-get) -y remove docker docker-client docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine docker-engine-selinux docker-client-latest docker-common docker-ce-cli && rm -rf /etc/docker /run/docker /var/lib/docker /usr/libexec/docker"
        
        # 检查Docker服务状态
        if is_docker_running; then
            echo_info "Docker服务正在运行"
        else
            echo_info "Docker服务未运行，正在启动..."
            systemctl start docker
        fi
        
        # 检查镜像配置
        check_docker_mirrors
        
        return
    fi
    
    # 判断操作系统类型
    if [[ "$OSTYPE" == "linux-gnu"* ]] ; then
        # 检测操作系统类型
        if command -v yum &> /dev/null; then
            yum install -y yum-utils device-mapper-persistent-data lvm2
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            version=$(cat /etc/redhat-release 2>/dev/null | sed -r 's/.* ([0-9]+)\..*/\1/')
            echo_info "检测到系统版本:[$version]"
            if [ "$version" == "7" ]; then
                sudo yum makecache fast
            elif [ "$version" == "8" ]; then
                sudo dnf makecache
            fi
            yum install -y docker-ce docker-ce-cli containerd.io
            systemctl enable docker
            systemctl start docker
        elif command -v apt-get &> /dev/null; then
            apt-get update
            apt install docker.io
            systemctl enable docker
            systemctl start docker
        elif command -v dnf &> /dev/null; then
            dnf install -y docker-ce docker-ce-cli containerd.io
            systemctl enable docker
            systemctl start docker   
        fi    
        if [ ! -d /etc/docker ] ; then
            mkdir -p /etc/docker
            configure_docker_mirrors
        fi
        systemctl daemon-reload
        systemctl restart docker
        return
    fi
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo_info "检测到macOS系统，开始安装Docker..."
        
        # 尝试使用 Homebrew 安装（如果已安装 brew）
        if command -v brew &> /dev/null; then
            echo_info "检测到 Homebrew，尝试通过 Homebrew 安装..."
            brew install --cask docker
            if [ $? -eq 0 ]; then
                brew install docker-compose
                open /Applications/Docker.app
                return 
            fi
            echo_info "Homebrew 安装失败，尝试直接下载..."
        else
            echo_info "未检测到 Homebrew，将直接下载 Docker Desktop"
        fi
        
        # 确定芯片类型并设置下载URL
        if [ "$(uname -m)" = "arm64" ]; then
            echo_info "检测到Apple Silicon芯片"
            DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
        else
            echo_info "检测到Intel芯片"
            DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
        fi
        
        # 不想使用Docker Desktop可以使用Colima替代： brew install colima docker docker-compose
        # 启动 Colima 虚拟机，并指定适合的参数
        # colima start --arch aarch64 --runtime containerd --cpu 4 --memory 8 --disk 20
        # 绑定 Docker CLI 到 Colima
        # docker context use colima
        
        # 定义 Docker Desktop 镜像源
        local mirrors=(
            "https://mirrors.aliyun.com/docker-desktop/mac/arm64/Docker.dmg"
            "https://mirrors.tuna.tsinghua.edu.cn/docker-desktop/mac/arm64/Docker.dmg"
        )
        
        # 下载Docker Desktop
        mkdir -p "$USER_DOWNLOADS"
        DMG_FILE="$USER_DOWNLOADS/Docker.dmg"
        echo_info "正在下载Docker Desktop..."
        echo_info "下载地址: $DMG_URL"
        echo_info "保存路径: $DMG_FILE"
        echo_info "镜像源: ${mirrors[*]}"
        echo ""
        
        # 优先使用 adl（代理检测 + aria2 多线程 + 自动镜像回退）
        local ADL_CMD=""
        if command -v adl &> /dev/null; then
            ADL_CMD="adl"
        elif [[ -x "$(dirname "$0")/../network/tools/adl" ]]; then
            ADL_CMD="$(dirname "$0")/../network/tools/adl"
        elif [[ -x "$(dirname "$0")/../../network/tools/adl" ]]; then
            ADL_CMD="$(dirname "$0")/../../network/tools/adl"
        fi
        
        if [[ -n "$ADL_CMD" ]]; then
            echo_info "检测到 adl ($ADL_CMD)，使用 aria2 加速下载（自动检测代理）..."
            if ! "$ADL_CMD" "$DMG_URL" "$USER_DOWNLOADS" "Docker.dmg" "${mirrors[@]}"; then
                echo_error "adl 下载失败"
                echo ""
                echo "请手动下载 Docker Desktop："
                echo "  官方地址: $DMG_URL"
                echo "  国内镜像:"
                for m in "${mirrors[@]}"; do echo "    $m"; done
                echo ""
                echo "下载完成后，双击 DMG 文件安装，或将 Docker.app 拖到 /Applications 目录"
                exit 1
            fi
        else
            # adl 不可用时，使用 curl 并尝试镜像
            local download_success=false
            for url in "$DMG_URL" "${mirrors[@]}"; do
                echo_info "尝试下载: $url"
                if curl -L -o "$DMG_FILE" "$url" --connect-timeout 30 --max-time 600; then
                    download_success=true
                    break
                fi
            done
            
            if [[ "$download_success" != true ]]; then
                echo_error "下载失败！可能是网络问题"
                echo ""
                echo "请手动下载 Docker Desktop："
                echo "  官方地址: $DMG_URL"
                echo "  国内镜像:"
                for m in "${mirrors[@]}"; do echo "    $m"; done
                echo ""
                echo "下载完成后，双击 DMG 文件安装，或将 Docker.app 拖到 /Applications 目录"
                exit 1
            fi
        fi
        
        # 检查文件是否下载成功
        if [ ! -f "$DMG_FILE" ] || [ ! -s "$DMG_FILE" ]; then
            echo_error "下载的文件不存在或为空"
            echo "请手动下载 Docker Desktop: $DMG_URL"
            exit 1
        fi
        
        # 挂载DMG文件
        echo_info "正在挂载 DMG 文件..."
        VOLUME=$(hdiutil attach "$DMG_FILE" 2>/dev/null | grep 'Volumes' | awk -F '\t' '{print $NF}')
        
        if [ -z "$VOLUME" ]; then
            echo_error "挂载 DMG 文件失败"
            echo "请手动双击 $DMG_FILE 进行安装"
            exit 1
        fi
        
        # 安装到应用程序目录
        echo_info "正在安装Docker Desktop到应用程序目录..."
        if [ -d "/Volumes/Docker/Docker.app" ]; then
            cp -R "/Volumes/Docker/Docker.app" /Applications
        else
            # 某些版本的 DMG 结构不同
            cp -R "$VOLUME/Docker.app" /Applications 2>/dev/null || {
                echo_error "未找到 Docker.app，请手动安装"
                open "$VOLUME"
                exit 1
            }
        fi
        
        # 卸载DMG
        hdiutil detach "$VOLUME" > /dev/null 2>&1
        rm -f "$DMG_FILE"
        
        # 打开Docker
        echo_info "安装完成，正在启动Docker Desktop..."
        open /Applications/Docker.app
        
        # 等待Docker启动
        echo_info "请完成Docker Desktop的初始设置（可能需要授权）"
        sleep 10
    else
        echo_error "不支持的操作系统"
        exit 1
    fi
}

install_docker 
install_docker_compose

#!/bin/bash
# docker和docker-compose自动安装、配置

f=/usr/local/bin/docker-compose
docker_compose_version="2.38.2"  # docker-compose版本定义成变量

# 检查是否以sudo权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：需要以sudo权限运行此脚本"
  exit 1
fi

# 检查操作系统类型
OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"

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
    if [ -f /etc/docker/daemon.json ]; then
        echo_info "检测到Docker镜像配置文件存在"
        current_mirrors=$(cat /etc/docker/daemon.json | grep -A 2 "registry-mirrors")
        echo "当前镜像配置：$current_mirrors"
    else
        # 新增交互式提示
        echo_info "未检测到Docker镜像配置，默认10秒后不配置"
        echo_info "按 Ctrl+C 取消配置"
        sleep 10
        echo_info "正在配置默认镜像..."
        configure_docker_mirrors
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
        # 需科学上网
        brew install --cask docker 
        if [ $? -eq 0 ]; then
            brew install docker-compose
            open /Applications/Docker.app
            return 
        fi    
        # 确定芯片类型并设置下载URL
        if [ "$(uname -m)" = "arm64" ]; then
            echo_info "检测到Apple Silicon芯片(M1/M2)"
            DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
        else
            echo_info "检测到Intel芯片"
            DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
        fi
        # 下载Docker Desktop
        DMG_FILE="~/Downloads/Docker.dmg"
        echo_info "正在下载Docker Desktop: $DMG_URL"
        curl -L -o "$DMG_FILE" "$DMG_URL"
        
        # 挂载DMG文件
        VOLUME=$(hdiutil attach "$DMG_FILE" | grep 'Volumes' | awk -F '\t' '{print $NF}')
        
        # 安装到应用程序目录
        echo_info "正在安装Docker Desktop到应用程序目录..."
        cp -R "/Volumes/Docker/Docker.app" /Applications
        
        # 卸载DMG
        hdiutil detach "$VOLUME" > /dev/null
        rm "$DMG_FILE"
        
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
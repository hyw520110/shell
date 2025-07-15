#!/bin/bash
# docker和docker-compose自动安装、配置

f=/usr/local/bin/docker-compose
install_docker(){
	# 判断docker是否安装，已安装输出docker版本
	if command -v docker &> /dev/null; then
	    docker -v 2>/dev/null
	    echo -e "docker已安装"
	   [ "$OSTYPE" == "linux-gnu"* ] && echo -e "如需卸载，执行：\n$(command -v yum || command -v apt-get) -y remove docker docker-client docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine docker-engine-selinux docker-client-latest docker-common docker-ce-cli && rm -rf /etc/docker /run/docker /var/lib/docker /usr/libexec/docker"
		return 
	fi
	 # docker配置 (仅适用于Linux)
    if [[ "$OSTYPE" == "linux-gnu"* ]] ; then
	    # 检测操作系统类型
	    if command -v yum &> /dev/null; then
	        yum install -y yum-utils device-mapper-persistent-data lvm2
	        yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
	        version=$(cat /etc/redhat-release 2>/dev/null | sed -r 's/.* ([0-9]+)\..*/\1/')
	        echo "version:[$version]"
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
	        cat > /etc/docker/daemon.json <<-EOF
{
  "registry-mirrors": ["http://hub-mirror.c.163.com", "https://docker.mirrors.ustc.edu.cn", "https://reg-mirror.qiniu.com", "http://f1361db2.m.daocloud.io"]
}
EOF
		fi
        systemctl daemon-reload
        systemctl restart docker
        return
    fi
	
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "检测到macOS系统，开始安装Docker..."
        # 需科学上网
        brew install --cask docker 
        if [ $? -eq 0 ]; then
            brew install docker-compose
            open /Applications/Docker.app
            return 
        fi    
        # 确定芯片类型并设置下载URL
        if [ "$(uname -m)" = "arm64" ]; then
            echo "检测到Apple Silicon芯片(M1/M2)"
            DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
        else
            echo "检测到Intel芯片"
            DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
        fi
        # 不想使用Docker Desktop可以使用Colima替代： brew install colima docker docker-compose
        # 启动 Colima 虚拟机，并指定适合的参数
        # colima start --arch aarch64 --runtime containerd --cpu 4 --memory 8 --disk 20
        # 绑定 Docker CLI 到 Colima
        # docker context use colima
        # 下载Docker Desktop
        DMG_FILE="~/Downloads/Docker.dmg"
        echo "正在下载Docker Desktop: $DMG_URL"
        curl -L -o "$DMG_FILE" "$DMG_URL"
        
        # 挂载DMG文件
        VOLUME=$(hdiutil attach "$DMG_FILE" | grep 'Volumes' | awk -F '\t' '{print $NF}')
        
        # 安装到应用程序目录
        echo "正在安装Docker Desktop到应用程序目录..."
        cp -R "/Volumes/Docker/Docker.app" /Applications
        
        # 卸载DMG
        hdiutil detach "$VOLUME" > /dev/null
        rm "$DMG_FILE"
        
        # 打开Docker
        echo "安装完成，正在启动Docker Desktop..."
        open /Applications/Docker.app
        
        # 等待Docker启动
        echo "请完成Docker Desktop的初始设置（可能需要授权）"
        sleep 10
    else
        echo "不支持的操作系统"
        exit 1
    fi
}

install_docker_compose(){
	# 安装docker-compose (仅适用于Linux)
	if [[ "$OSTYPE" == "linux-gnu"* ]] && [ ! -f $f ]; then
	    url="https://github.com/docker/compose/releases/download/v2.11.1/docker-compose-$(uname -s)-$(uname -m)"
	    echo $url
	    curl -L $url -o $f
	    chmod +x $f
	fi
}
 	
install_docker 
install_docker_compose
   

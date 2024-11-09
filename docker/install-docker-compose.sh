#!/bin/bash
# docker和docker-compose自动安装、配置

f=/usr/local/bin/docker-compose

# 判断docker是否安装，已安装输出docker版本，如docker未安装先安装docker
if command -v docker &> /dev/null; then
    docker -v
    echo -e "docker已安装,如需卸载，执行：\n$(command -v yum || command -v apt-get) -y remove docker docker-client docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine docker-engine-selinux docker-client-latest docker-common docker-ce-cli && rm -rf /etc/docker /run/docker /var/lib/docker /usr/libexec/docker"
else
    # 检测操作系统类型
    if command -v yum &> /dev/null; then
        # CentOS
        yum install -y yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
        version=$(cat /etc/redhat-release 2>/dev/null | sed -r 's/.* ([0-9]+)\..*/\1/')
        echo "version:[$version]"
        if [ $version -eq 7 ]; then
            sudo yum makecache fast
        elif [ $version -eq 8 ]; then
            sudo dnf makecache
        fi
        yum install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker
        systemctl start docker
    elif command -v apt-get &> /dev/null; then
        # Deepin
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo \
          "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker
        systemctl start docker
    else
        echo "不支持的操作系统"
        exit 1
    fi

    # docker配置
    if [ ! -d /etc/docker ]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<-EOF
{
  "registry-mirrors": ["http://hub-mirror.c.163.com", "https://docker.mirrors.ustc.edu.cn", "https://reg-mirror.qiniu.com", "http://f1361db2.m.daocloud.io"]
}
EOF
        systemctl daemon-reload
        systemctl restart docker
    fi
fi

# 安装docker-compose
if [ ! -f $f ]; then
    url="https://github.com/docker/compose/releases/download/v2.11.1/docker-compose-$(uname -s)-$(uname -m)"
    echo $url
    curl -L $url -o $f
    chmod +x $f
fi

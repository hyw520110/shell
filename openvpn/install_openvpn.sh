#!/bin/bash

# 检测操作系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "不支持的操作系统"
    exit 1
fi

# 安装OpenVPN
install_openvpn() {
    if [[ "$OS" == "centos" ]]; then
        sudo yum update -y
        sudo yum install epel-release -y
        sudo yum install -y openvpn wget
    elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        sudo apt-get update
        sudo apt-get install openvpn -y
        sudo apt-get install wget -y
    else
        echo "不支持的操作系统"
        exit 1
    fi
}

# 下载和配置Easy-RSA
setup_easy_rsa() {
    wget -O /tmp/easyrsa.tar.gz https://github.com/OpenVPN/easy-rsa-old/archive/2.3.3.tar.gz
    tar xfz /tmp/easyrsa.tar.gz
    sudo mkdir /etc/openvpn/easy-rsa
    sudo cp -rf easy-rsa-old-2.3.3/easy-rsa/2.0/* /etc/openvpn/easy-rsa
    sudo chown $(whoami) /etc/openvpn/easy-rsa/
}

# 生成证书和密钥
generate_certs() {
    cd /etc/openvpn/easy-rsa
    source ./vars
    ./clean-all
    ./build-ca
    ./build-key-server server nopass
    ./build-dh
}

# 配置OpenVPN服务器
configure_openvpn() {
    sudo cp /usr/share/doc/openvpn-2.4.4/sample/sample-config-files/server.conf /etc/openvpn
    sudo nano /etc/openvpn/server.conf
}

# 配置路由和防火墙
configure_routing_firewall() {
    if [[ "$OS" == "centos" ]]; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
        sudo firewall-cmd --zone=public --add-service=openvpn --permanent
        sudo firewall-cmd --reload
    elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
        sudo ufw allow 1194/udp
        sudo ufw enable
    fi
}

# 启动OpenVPN服务
start_openvpn() {
    if [[ "$OS" == "centos" ]]; then
        sudo systemctl start openvpn@server
        sudo systemctl enable openvpn@server
    elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        sudo systemctl start openvpn
        sudo systemctl enable openvpn
    fi
}

# 执行安装
install_openvpn
setup_easy_rsa
generate_certs
configure_openvpn
configure_routing_firewall
start_openvpn

echo "OpenVPN安装完成"

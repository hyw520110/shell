FROM centos:7
# 安装必要的工具
RUN yum-config-manager --save --disable base && yum update -y && \
    yum install -y epel-release && \
    yum install -y openvpn wget

# 将一键安装脚本复制到容器中
COPY install_openvpn.sh /root/install_openvpn.sh

# 给予执行权限
RUN chmod +x /root/install_openvpn.sh

# 执行安装脚本
CMD ["/bin/bash", "/root/install_openvpn.sh"]

#!/usr/bin/env bash

# 全局变量
LOG_FILE="/var/log/init_server.log"
BACKUP_DIR="/etc/yum.repos.d/backup"

# 检查是否为root用户
if [[ "$(whoami)" != "root" ]]; then
    echo "Please run this script as root." >&2 && exit 1
fi

# 配置YUM源
ConfigYum() {
    echo "#--Config Yum CentOS-Base.repo--"
    mkdir -p "$BACKUP_DIR"
    mv /etc/yum.repos.d/* "$BACKUP_DIR" 2>> "$LOG_FILE"
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo >> "$LOG_FILE" 2>&1
    yum -y install epel-release >> "$LOG_FILE" 2>&1
    yum clean all >> "$LOG_FILE" 2>&1
    yum makecache >> "$LOG_FILE" 2>&1
}

# 关闭防火墙和SELinux
initFirewall() {
    systemctl stop firewalld
    systemctl disable firewalld >> "$LOG_FILE" 2>&1
    setenforce 0
    sed -i '/^SELINUX=/ s/enforcing/disabled/' /etc/selinux/config
    sed -i '/^GSSAPIAu/ s/yes/no/' /etc/ssh/sshd_config
    sed -i '/^#UseDNS/ {s/^#//;s/yes/no/}' /etc/ssh/sshd_config
    systemctl enable sshd crond >> "$LOG_FILE" 2>&1
    echo -e "\033[32m [安全配置] ==> OK \033[0m"
}

# SSH安全配置
initSsh() {
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F%T)
    sed -i 's%#Port 22%Port 1020%' /etc/ssh/sshd_config
    sed -i 's%#PermitRootLogin yes%PermitRootLogin no%' /etc/ssh/sshd_config
    systemctl restart sshd
}

# 用户管理
AddSAUser() {
    groupadd -g 901 sa
    for user in user1 user2; do
        useradd -g sa -u 90${i} $user
        echo "${user}123456!@#$%^" | passwd $user --stdin
    done
    echo "%sa ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}

# 时间同步
syncSystemTime() {
    echo "*/5 * * * * /sbin/ntpdate cn.pool.ntp.org >/dev/null 2>&1" >> /var/spool/cron/root
}

# 内核参数优化
optimizationKernel() {
    cat > /etc/sysctl.conf <<EOF
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8288608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
    sysctl -p
}

# 主函数
main() {
    ConfigYum
    initFirewall
    initSsh
    AddSAUser
    syncSystemTime
    optimizationKernel
}

main
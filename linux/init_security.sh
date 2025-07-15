#!/bin/bash

initFirewall() {
    systemctl stop firewalld
    systemctl disable firewalld
    setenforce 0
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
}

initSsh() {
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F%T)
    sed -i 's%#Port 22%Port 1020%' /etc/ssh/sshd_config
    sed -i 's%#PermitRootLogin yes%PermitRootLogin no%' /etc/ssh/sshd_config
    systemctl restart sshd
}
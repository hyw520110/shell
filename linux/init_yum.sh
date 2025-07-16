#!/bin/bash

# 动态获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# 定义全局变量
BACKUP_DIR="$SCRIPT_DIR/yum_backup"
LOG_FILE="$SCRIPT_DIR/init_server.log"

ConfigYum() {
    echo "#--Config Yum CentOS-Base.repo--"
    cd /etc/yum.repos.d/
    cp CentOS-Base.repo CentOS-Base.repo.$(date +%F)
    wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo >/dev/null 2>&1
    yum -y install epel-release >/dev/null 2>&1
    yum clean all >/dev/null 2>&1
    yum makecache >/dev/null 2>&1
}
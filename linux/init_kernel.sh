#!/bin/bash

# 动态获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# 定义全局变量
SYSCTL_CONFIG="/etc/sysctl.conf"

optimizationKernel() {
    cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.$(date +%F_%T)"
    cat >>"$SYSCTL_CONFIG" <<EOF
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
    sysctl -p
}
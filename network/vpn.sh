#!/bin/bash

# 通过 openconnect 连接 VPN（凭据从环境变量读取，避免硬编码）
# 用法:
#   VPN_SERVER="host:port" VPN_USERNAME="user" VPN_PASSWORD="pass" ./vpn.sh
#   ./vpn.sh              # 缺失的配置项会交互式提示输入
#   source vpn.sh && myvpn   # 作为函数库使用

myvpn () {
    local vpn_server="${VPN_SERVER:-183.134.210.243:4443}"
    local vpn_username="${VPN_USERNAME:-}"
    local vpn_password="${VPN_PASSWORD:-}"

    # 从环境变量读取，缺失时交互式提示（不写入脚本/历史）
    if [ -z "$vpn_username" ]; then
        read -r -p "请输入 VPN 用户名: " vpn_username
    fi
    if [ -z "$vpn_password" ]; then
        read -s -r -p "请输入 VPN 密码: " vpn_password
        echo
    fi

    # try connect，断线后自动重连
    while true; do
        retry_time=$(($(date +%s) + 30))
        sudo openconnect -u "$vpn_username" "$vpn_server" --non-inter --passwd-on-stdin <<< "$vpn_password"
        current_time=$(date +%s)
        if [ "$current_time" -lt "$retry_time" ]; then
            sleep $(( retry_time - current_time ))
        fi
    done
}

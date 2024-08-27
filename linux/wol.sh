#!/bin/bash

# 正则表达式用于匹配MAC地址和IPv4地址
MAC_REGEX='^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$'
IPV4_REGEX='^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

# 检查脚本参数
if [ $# -eq 1 ]; then
    target=$1
    if [[ $target =~ $MAC_REGEX ]]; then
        target_mac=$target
        method="MAC"
    elif [[ $target =~ $IPV4_REGEX ]]; then
        target_ip=$target
        method="IPv4"
    else
        echo "无效的地址格式。请提供有效的MAC地址或IPv4地址。"
        exit 1
    fi
else
    # 如果没有提供参数，提示用户输入
    read -p "请输入目标MAC地址或IPv4地址: " target
    if [[ $target =~ $MAC_REGEX ]]; then
        target_mac=$target
        method="MAC"
    elif [[ $target =~ $IPV4_REGEX ]]; then
        target_ip=$target
        ping -c 1 $target_ip
        target_mac=$(arp -a | grep $target_ip | awk '{print $4}' | cut -d' ' -f1)
        method="IPv4"
    else
        echo "无效的地址格式。请提供有效的MAC地址或IPv4地址。"
        exit 1
    fi
fi

# 根据方法执行WOL操作
case $method in
    "MAC")
        echo "正在向255.255.255.255:9发送唤醒数据包，MAC地址为 $target_mac"
        wakeonlan $target_mac
        ;;
    "IPv4")
        echo "正在向 $target_ip 发送唤醒数据包"
        wakeonlan $target_mac -i $target_ip
        ;;
    *)
        echo "无效的选项。请选择MAC或IPv4进行WOL操作。"
        exit 1
        ;;
esac

# 检查wakeonlan命令的返回值
if [ $? -eq 0 ]; then
    echo "WOL操作已成功发起。"
else
    echo "WOL操作失败。请检查您的输入并重试。"
fi

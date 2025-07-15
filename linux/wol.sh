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
    read -t 10 -p "请输入目标MAC地址或IPv4地址: " target
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
fi
if [ -n "$target_ip" ];then
  ping -c 1 $target_ip > /dev/null 2>&1
  target_mac=$(arp -a | grep $target_ip | awk '{print $4}' | cut -d' ' -f1)
fi
read -t 5 -p "您想执行哪个操作？（1:唤醒/2:关机）: " action
action=${action:-"1"}
# 根据方法执行WOL操作
case $method in
    "MAC")
        case $action in
            "1")
                echo "正在向255.255.255.255:9发送唤醒数据包，MAC地址为 $target_mac"
                wakeonlan $target_mac
                ;;
            "2")
                echo "此模式下不支持远程关机。请使用IPv4地址进行远程关机。"
                ;;
            *)
                echo "无效的操作。请选择唤醒(wake)或关机(shutdown)。"
                exit 1
                ;;
        esac
        ;;
    "IPv4")
        case $action in
            "1")
                echo "正在向$target_mac $target_ip 发送唤醒数据包"
                wakeonlan $target_mac -i $target_ip
                ;;
            "2")
                # 确保目标计算机允许SSH登录，并且允许通过SSH关机
                echo "正在远程关机 $target_ip"
                read -t 5 -p "请输入远程主机的用户名: " username
                read -s -t 5 -p "请输入远程主机的密码: " password
                echo
                # 远程主机允许无TTY的sudo操作，/etc/sudoers配置：sky ALL=(ALL) NOPASSWD: /sbin/shutdown
                # 或做免登认证，不修改配置则通过sshpass或Ansible
                expect <<EOF
spawn ssh -o StrictHostKeyChecking=no $username@$target_ip "sudo shutdown -h now"
expect {
"assword:" {send "$ssh_password\r"; exp_continue}
"sudo password:" {send "$ssh_password\r"; exp_continue}
timeout {puts "超时，请检查您的输入。"}
eof {puts "操作完成。"}
}
EOF
                ;;
            *)
                echo "无效的操作。请选择唤醒(wake)或关机(shutdown)。"
                exit 1
                ;;
        esac
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


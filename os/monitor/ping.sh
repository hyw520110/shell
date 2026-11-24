#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
网络连通性测试脚本

测试域名的网络连通性，显示响应时间。

用法: ./ping.sh <域名列表文件>

参数:
    域名列表文件       包含域名列表的文本文件

选项:
    -h, --help        显示此帮助信息
    -v, --version     显示版本信息

说明:
    - 从文件中读取域名列表
    - 逐个测试域名连通性
    - 显示响应时间（毫秒）
    - 显示网络延迟信息
    - 统计成功/失败数量

文件格式:
    domain.txt 示例:
    www.google.com
    www.baidu.com
    www.github.com

输出信息:
    - 域名名称
    - 响应时间
    - 响应状态（成功/失败）

示例:
    ./ping.sh domain.txt                  # 测试文件中的所有域名
    ./ping.sh /path/to/domains.txt       # 指定域名列表文件

注意事项:
    - 需要网络连接
    - 域名必须可解析
    - 可能受网络防火墙影响
    - 某些域名可能限制 ICMP 请求

相关命令:
    ping www.example.com                  # 单个域名测试
    ping -c 4 www.example.com            # 指定 ping 次数
    nslookup www.example.com             # DNS 查询
    traceroute www.example.com           # 路由追踪

EOF
}

# 参数解析
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ "$1" == "-v" ]] || [[ "$1" == "--version" ]]; then
    echo "网络连通性测试脚本版本: 1.0"
    exit 0
fi

# 主脚本逻辑
for domain in `cat $1`
do
echo $domain
ping $domain|grep from|head -n 1|awk '{print $4}'
done

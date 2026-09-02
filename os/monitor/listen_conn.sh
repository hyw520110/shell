#!/bin/bash

# 显示帮助信息
show_help() {
    cat << EOF
TCP 连接监控脚本

实时监控活动的 TCP 网络连接，显示连接详情和进程信息。

用法: ./listen_conn.sh [选项]

选项:
    -h, --help        显示此帮助信息
    -v, --version     显示版本信息

说明:
    - 实时监控 TCP 连接状态
    - 显示本地和远程地址
    - 显示关联的进程信息
    - 自动刷新显示（类似 top）
    - 支持 Ctrl+C 退出

显示信息:
    - 协议类型
    - 本地地址和端口
    - 远程地址和端口
    - 进程 ID 和名称
    - 连接状态

使用方式:
    # 启动监控（需要 root 权限）
    sudo ./listen_conn.sh

    # 退出监控
    按 Ctrl+C

示例:
    ./listen_conn.sh              # 监控所有 TCP 连接

注意事项:
    - 需要 root 权限查看所有进程信息
    - 需要安装 ss 命令（iproute2 包）
    - 监控时会定期刷新屏幕
    - 按键 Ctrl+C 退出监控

依赖要求:
    - ss 命令（通常包含在 iproute2 包中）
    - root 权限（查看进程信息）

安装依赖:
    # Ubuntu/Debian
    sudo apt install iproute2

    # CentOS/RHEL
    sudo yum install iproute

EOF
}

# 参数解析
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ "$1" == "-v" ]] || [[ "$1" == "--version" ]]; then
    echo "TCP连接监控脚本版本: 1.0"
    exit 0
fi

# 脚本功能：在while循环中持续监控TCP连接，使用单个awk高效解析。

set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 此脚本需要root权限才能查看所有进程信息。" >&2
    exit 1
fi

# 检查ss命令是否存在
if ! command -v ss &>/dev/null;
    then error_exit "错误: 'ss' 命令未找到。请安装 'iproute2' 包。"
fi

# 主循环
while true; do
    # 清屏，实现类似'top'的刷新效果
    clear
    
    echo "正在监控活动的TCP连接... (按 Ctrl+C 退出)"
    echo "最后更新: $(date)"
    echo "--------------------------------------------------------------------------"
    printf "% -6s %-25s %-25s %s\n" "协议" "本地地址:端口" "对端地址:端口" "进程信息"
    echo "--------------------------------------------------------------------------"
    
    # 使用单个awk命令完成所有解析和格式化工作，性能极高
    # ss -tnp: 显示活动的TCP连接，并显示进程信息
    ss -tnp | awk '
        NR > 1 {
            # ss的输出格式为: State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Users
            proto = $1
            local_addr = $4
            peer_addr = $5
            process_info = $6
            printf "% -6s %-25s %-25s %s\n", proto, local_addr, peer_addr, process_info
        }
    '
    
    # 刷新间隔
    sleep 5
done

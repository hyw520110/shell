#!/bin/bash

# 脚本功能：使用 NetworkManager (nmcli) 安全地修改网络连接的DNS服务器。

set -eo pipefail

# --- 配置 ---
# 如果用户不提供DNS服务器，则使用下面的默认值
DEFAULT_DNS_SERVERS="223.5.5.5,223.6.6.6"
# --- 结束配置 ---

# --- 帮助函数 ---
show_help() {
    echo "用法: $0 [连接名] [DNS服务器]"
    echo
    echo "  连接名 (可选):     要修改的连接名。如果省略，将从活动连接中选择。"
    echo "  DNS服务器 (可选):  用逗号分隔的DNS地址。默认为: ${DEFAULT_DNS_SERVERS}"
    echo
    echo "示例: $0 eth0 8.8.8.8,8.8.4.4"
}

# --- 主逻辑 ---

# 1. 检查 nmcli 是否存在
if ! command -v nmcli &> /dev/null; then
    echo "错误: 未找到 'nmcli' 命令。请确认系统已安装 NetworkManager。" >&2
    exit 1
fi

# 2. 处理命令行参数
TARGET_CONN_NAME="$1"
DNS_SERVERS="${2:-$DEFAULT_DNS_SERVERS}"

# 3. 如果未指定连接名，则让用户从活动连接中交互式选择
if [ -z "$TARGET_CONN_NAME" ]; then
    echo "未指定连接名，请从以下活动连接中选择一个进行修改："
    
    # 使用 mapfile 将nmcli的输出读入数组，更安全
    mapfile -t active_connections < <(nmcli connection show --active | awk 'NR>1 {print $1, "(" $2, $3, $4 ")"}')
    
    if [ ${#active_connections[@]} -eq 0 ]; then
        echo "错误: 未找到任何活动的网络连接。" >&2
        exit 1
    fi

    # 使用 select 关键字创建交互式菜单
    select choice in "${active_connections[@]}"; do
        if [ -n "$choice" ]; then
            # 从用户的选择中提取出连接名 (第一列)
            TARGET_CONN_NAME=$(echo "$choice" | awk '{print $1}')
            break
        else
            echo "无效选择，请重试。"
        fi
    done
fi

echo "--------------------------------------------------"
echo "将要执行以下操作:"
echo "  - 目标连接: $TARGET_CONN_NAME"
echo "  - 设置DNS为: $DNS_SERVERS"
echo "--------------------------------------------------"

# 4. 修改连接配置
echo "正在修改连接..."
nmcli connection modify "$TARGET_CONN_NAME" ipv4.dns "$DNS_SERVERS"
# 为避免IPv6的DNS设置干扰，建议清空它
nmcli connection modify "$TARGET_CONN_NAME" ipv6.dns ""

# 5. 重启连接以应用更改 (先down后up更可靠)
echo "正在重启连接以应用设置..."
# 如果连接已关闭，down命令会失败，|| true可以忽略这个错误
nmcli connection down "$TARGET_CONN_NAME" || true 
nmcli connection up "$TARGET_CONN_NAME"

echo "成功为连接 '$TARGET_CONN_NAME' 应用了新的DNS设置。"

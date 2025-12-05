#!/bin/bash
    2 # 功能：安全地更新 /etc/hosts 文件，将指定的主机名列表指向本机IP。
    3 
    4 set -eo pipefail
    5 
    6 # --- 配置 ---
    7 HOSTS_TO_ADD=(
    8     "redis-server" "mq-server" "mysql-server" "oss-server"
    9     "es-server" "model-server" "sk-server" "nacos-server"
   10     "task-server" "ssj-show.aipsybot.com" "zk1" "zk2" "zk3"
   11 )
   12 HOSTS_FILE="/etc/hosts"
   13 # --- 结束配置 ---
   14 
   15 log_message() { echo "[信息] $1"; }
   16 error_exit() { echo "[错误] $1" >&2; exit 1; }
   17 
   18 main() {
   19     if [ "$(id -u)" -ne 0 ]; then
   20         error_exit "此脚本必须以root权限运行。"
   21     fi
   22 
   23     # 使用标准命令获取本机主要IP
   24     local_ip=$(hostname -I | awk '{print $1}')
   25     if [ -z "$local_ip" ]; then
   26         error_exit "无法获取本机IP地址。"
   27     fi
   28     log_message "检测到本机IP为: $local_ip"
   29 
   30     # 备份hosts文件
   31     cp -n "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d)"
   32 
   33     for host in "${HOSTS_TO_ADD[@]}"; do
   34         # 检查host是否已存在且IP正确
   35         if grep -q "^${local_ip}\\s.*\\b${host}\\b" "$HOSTS_FILE"; then
   36             log_message "主机 '$host' 配置正确，跳过。"
   37         else
   38             # 如果存在但IP不正确，先删除旧的
   39             if grep -q "\\b${host}\\b" "$HOSTS_FILE"; then
   40                 log_message "发现 '$host' 的旧记录，正在删除..."
   41                 sed -i "/\\b${host}\\b/d" "$HOSTS_FILE"
   42             fi
   43             # 添加新记录
   44             log_message "正在为 '$host' 添加新记录..."
   45             echo "${local_ip}    ${host}" >> "$HOSTS_FILE"
   46         fi
   47     done
   48     log_message "Hosts 文件更新完成。"
   49 }
   50 
   51 main "$@"


#!/bin/bash

# 设置颜色变量
RED="\033[5;31;40m"
GREEN="\033[5;32;40m"
NC="\033[0m"

# 检查是否以管理员身份运行
check_permission() {
    [ "$(id -u)" -ne 0 ] && echo -e "${RED}此脚本需要管理员权限才能运行。请使用 'sudo' 运行脚本。${NC}" && exit 1
}

# 安装依赖
install_dependencies() {
    echo "检查依赖..."
    declare -A dependencies=(
        ["tar"]="tar"
        ["systemctl"]="systemd"
    )
    for dep in "${!dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "$dep 未安装，开始安装..."
            # 根据包管理器选择安装命令
            if command -v apt &> /dev/null; then
                sudo apt update && sudo apt install -y "${dependencies[$dep]}"
            else
                sudo yum install -y "${dependencies[$dep]}"
            fi
            if ! command -v "$dep" &> /dev/null; then
                echo -e "${RED}$dep 安装失败。${NC}"
                exit 1
            fi
        fi
    done
}

# 检测操作系统类型
detect_os() {
    if command -v lsb_release &> /dev/null; then
        OS_TYPE=$(lsb_release -is)
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
    else
        OS_TYPE="unknown"
    fi
    echo "$OS_TYPE"
}
get_dns_hostname() {
  # 尝试获取 FQDN
  fqdn=$(hostname -f)
  # 如果 FQDN 不为空，则使用 FQDN
  if [[ -n "$fqdn" ]]; then
    echo "$fqdn"
  else
    # 如果 FQDN 为空，则尝试从 /etc/hosts 文件获取
    hosts_fqdn=$(grep -i "$(hostname)" /etc/hosts | awk '{print $2}')
    if [[ -n "$hosts_fqdn" ]]; then
      echo "$hosts_fqdn"
    else
      # 如果 /etc/hosts 中也没有 FQDN，则使用短主机名
      short_hostname=$(hostname -s)
      echo "$short_hostname"
    fi
  fi
}
# 获取发行版版本
get_distro_version() {
    local os_type=$(detect_os)
    local distro=""
    case $os_type in
        "Deepin"|"Debian"|"Ubuntu")
            distro="debian$(cat /etc/debian_version | awk -F'.' '{print $1}')"
            ;;
        "CentOS"|"Fedora"|"RedHat")
            if [ "$os_type" = "CentOS" ]; then
                distro="rhel$(cat /etc/redhat-release | awk '{print $3}' | awk -F'.' '{print $1}')0"
            else
                distro="rhel$(cat /etc/os-release | grep VERSION_ID | cut -d '"' -f 2 | awk -F'.' '{print $1}')0"
            fi
            ;;
        *)
            echo "无法确定操作系统架构，下载失败。"
            exit 1
            ;;
    esac
    echo "$distro"
}
# 配置防火墙
detect_firewall() {
    local port=$1
    if [ -z "$port" ]; then
        echo "端口号未指定。请提供一个端口号作为参数。"
        return
    fi
    if systemctl is-active firewalld &> /dev/null; then
        echo "防火墙已启用。正在配置防火墙规则..."
        sudo firewall-cmd --permanent --add-port=$port/tcp
        sudo firewall-cmd --reload
        echo "防火墙规则配置成功。"
    elif systemctl is-active iptables &> /dev/null; then
        echo "iptables 服务正在运行。正在配置 iptables 规则..."
        sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT
        if command -v iptables-persistent &> /dev/null; then
            sudo iptables-persistent save
            echo "iptables 规则配置成功。"
        else
            echo "尝试保存 iptables 规则..."
            if [ -f /etc/sysconfig/iptables ]; then
                sudo iptables-save > /etc/sysconfig/iptables
                echo "iptables 规则已保存到 /etc/sysconfig/iptables。"
            elif [ -f /etc/iptables/rules.v4 ]; then
                sudo iptables-save > /etc/iptables/rules.v4
                echo "iptables 规则已保存到 /etc/iptables/rules.v4。"
            else
                echo "无法保存 iptables 规则。请确保安装了 iptables-persistent 或手动编辑配置文件。"
            fi
        fi
    else
        echo "防火墙服务未运行，跳过防火墙配置。"
    fi
}
generate_keyfile() {
    local keyfile_path=${1:-~/.key}
    confirm=${2:-n}
    [ "$confirm" == "y" ] && read -t 8 -p "密钥文件路径 (默认$keyfile_path): " keyfile_path
    if [ ! -f "$keyfile_path" ]; then
        openssl rand -base64 128 > $keyfile_path
    fi
    echo "$keyfile_path"
}
check_process_ready() {
  local retries=${2:-10}
  process_name=${1:-"mongod"}
  while [ $retries -gt 0 ]; do
    if pgrep -x "$process_name" > /dev/null; then
      local state=$(ps -o state= -p $(pgrep -x "$process_name"))
      if [[ "$state" =~ ^S ]]; then
        echo "$process_name已启动。"
        return 0
      fi
    fi
    echo "等待$process_name启动..."
    sleep 1
    retries=$((retries - 1))
  done
  echo "$process_name未能启动完成。"
  return 1
}
wait_for_process_ready() {
  local max_retries=${1:-30}
  local check_command=${2:-"mongosh --eval 'db.runCommand({connectionStatus: 1});'"}
  local retries=$max_retries
  while [ $retries -gt 0 ]; do
    sleep 1
    if eval "$check_command" &> /dev/null; then
      break
    fi
    echo -n "."
    retries=$((retries - 1))
  done
  if [ $retries -le 0 ]; then
    return 1
  else
    return 0
  fi
}

# 获取当前主机的第一个非环回 IPv4 地址
get_ip_address() {
    # 尝试使用 ip addr show
    if command -v ip &> /dev/null; then
        ip_address=$(ip addr show | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | grep -v 127.0.0.1 | head -n 1)
    else
        ip_address=$(ifconfig | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | grep -v 127.0.0.1 | head -n 1)
    fi
    echo "$ip_address"
}
# 服务用户及其用户组
create_user_and_group() {
    local user=$1
    local group=$2
    if ! getent group "$group" &> /dev/null; then
        echo "创建用户组 $group..."
        if ! groupadd "$group"; then
            echo "创建用户组 $group 失败。"
            return 1
        fi
    fi
    # 检查用户是否已存在
    if ! getent passwd "$user" &> /dev/null; then
        echo "创建用户 $user..."
        if ! useradd -r -g "$group" -s /sbin/nologin "$user"; then
            echo "创建用户 $user 失败。"
            return 1
        fi
        echo "用户 $user 及其用户组 $group 创建完成。"
    fi
}
# 映射 Debian 版本号到代号
get_debian_codename() {
    local version=$(cat /etc/debian_version | cut -d '.' -f1)
    case $version in
        9)
            echo "stretch"
            ;;
        10)
            echo "buster"
            ;;
        11)
            echo "bullseye"
            ;;
        12)
            echo "bookworm"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}
# 导出公共脚本中的函数
export -f check_permission
export -f install_dependencies
export -f detect_os
export -f get_ip_address
export -f get_dns_hostname
export -f detect_firewall
export -f check_process_ready
export -f wait_for_process_ready
export -f create_user_and_group
export -f get_debian_codename
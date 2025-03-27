#!/bin/bash

# 全局变量和配置
NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
DOWNLOAD_DIR="/opt/softs"
SCRIPT_DIR=$(dirname $(readlink -f $0))
BASE_DIR=$(dirname $SCRIPT_DIR)
BIN_DIR="$BASE_DIR/bin"
USER="prometheus"
GROUP="prometheus"

# 检查是否是root用户
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "必须以root用户运行此脚本"
    exit 1
  fi
}

# 安装必要的软件包
setup_environment() {
  local package_manager
  for cmd in wget curl; do
    command -v $cmd > /dev/null 2>&1 && continue
    package_manager=$(command -v apt-get || command -v yum)
    [[ -z "$package_manager" ]] && echo "未知的操作系统，无法继续" && exit 1
    $package_manager update && $package_manager install -y $cmd
  done
}

create_user_and_group() {
  getent group $GROUP > /dev/null 2>&1 || groupadd --system $GROUP
  id -u $USER > /dev/null 2>&1 || useradd -s /sbin/nologin --system -g $GROUP $USER
}

# 下载并解压工具函数
download_and_extract() {
  local url=$1
  local dest_dir=$DOWNLOAD_DIR
  local tar_file="${dest_dir}/${url##*/}"
  local extract_dir=$3

  mkdir -p $dest_dir
  if [ ! -f $tar_file ]; then
    wget -O $tar_file $url || { echo "下载失败: $url"; exit 1; }
  fi
  tar -xzf $tar_file -C $dest_dir || { echo "解压失败: $tar_file"; exit 1; }
  mv $dest_dir/$extract_dir/* $BIN_DIR/
  rm -rf $dest_dir/$extract_dir
}

# 创建 systemd 服务通用函数
create_systemd_service() {
  local service_name=$1

  cat <<EOF >/etc/systemd/system/${service_name}.service
[Unit]
Description=$service_name
Wants=network-online.target
After=network-online.target

[Service]
User=$USER
Group=$GROUP
Type=simple
ExecStart=$BIN_DIR/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable $service_name
  systemctl start $service_name
}

# 检测 Node Exporter 是否安装
detect_node_exporter() {
  [[ -f "$BIN_DIR/node_exporter" ]] && return 0 || return 1
}

# 安装 Node Exporter
install_node_exporter() {
  check_root
  setup_environment
  create_user_and_group
  mkdir -p $BIN_DIR
  download_and_extract $NODE_EXPORTER_URL "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64"
}

# 启动 Node Exporter
start_node_exporter() {
  if detect_node_exporter; then
    create_systemd_service "node_exporter"
    echo "Node Exporter 已启动。"
    lsof -i:9100
  else
    echo "Node Exporter 安装失败或未找到二进制文件。"
    exit 1
  fi
}

# 主函数
function main() {
  if ! detect_node_exporter; then
    install_node_exporter
  fi
  start_node_exporter
}

main
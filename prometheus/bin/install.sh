#!/bin/bash

# 全局变量和配置
PROMETHEUS_VERSION="3.0.1"
NODE_EXPORTER_VERSION="1.8.2"
PROMETHEUS_URL="https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
DOWNLOAD_DIR="/opt/softs"
SCRIPT_DIR=$(dirname $(readlink -f $0))
BASE_DIR=$(dirname $SCRIPT_DIR)
BIN_DIR="$BASE_DIR/bin"
CONFIG_DIR="$BASE_DIR/conf"
DATA_DIR="$BASE_DIR/data"
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
  local tar_file="${DOWNLOAD_DIR}/${url##*/}"
  local extract_dir=$3

  mkdir -p $dest_dir
  if [ ! -f $tar_file ]; then
    wget -O $tar_file $url || { echo "下载失败: $url"; exit 1; }
  fi
  tar -xzf $tar_file -C $dest_dir || { echo "解压失败: $tar_file"; exit 1; }
  mv $dest_dir/$extract_dir/* $BIN_DIR/
  rm -rf $dest_dir/$extract_dir
}

# 配置 Prometheus
configure_prometheus() {
  mkdir -p $CONFIG_DIR $DATA_DIR
  chown $USER:$GROUP $CONFIG_DIR $DATA_DIR

  if [ ! -f $CONFIG_DIR/prometheus.yml ]; then
    cat <<EOF >$CONFIG_DIR/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9091']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF
    chown $USER:$GROUP $CONFIG_DIR/prometheus.yml
  fi

  # 替换配置文件中的 IP 地址
  sed -i "s/localhost/$(/usr/sbin/ip addr | grep -A2 'state UP' | grep inet | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)/g" $CONFIG_DIR/prometheus.yml
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
ExecStart=$BIN_DIR/startup.sh
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

# 主安装函数
install() {
  check_root
  setup_environment
  create_user_and_group
  mkdir -p $BIN_DIR
  download_and_extract $PROMETHEUS_URL "prometheus-$PROMETHEUS_VERSION.linux-amd64"
  configure_prometheus
  create_systemd_service "prometheus"  

  if ! detect_node_exporter; then
    download_and_extract $NODE_EXPORTER_URL "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64"
    create_systemd_service "node_exporter" 
  fi

  echo "Prometheus 和 Node Exporter 安装和配置完成！"
}

install
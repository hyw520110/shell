#!/bin/bash

# 全局变量和配置
PROMETHEUS_VERSION="2.36.1"
NODE_EXPORTER_VERSION="1.8.2"
PROMETHEUS_URL="https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
DOWNLOAD_DIR="/opt/softs"
SCRIPT_DIR=$(dirname $(readlink -f $0))
PROMETHEUS_DIR=$(dirname $SCRIPT_DIR)
PROMETHEUS_TAR="$DOWNLOAD_DIR/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"
NODE_EXPORTER_TAR="$DOWNLOAD_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
CONFIG_DIR="${PROMETHEUS_DIR}/conf"
DATA_DIR="${PROMETHEUS_DIR}/data"
USER="prometheus"
GROUP="prometheus"

# 检查是否是root用户
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "必须以root用户运行此脚本"
    exit 1
  fi
}

# 检测操作系统类型，更新包列表，安装必要软件包
setup_environment() {
  if command -v apt-get > /dev/null 2>&1; then
    apt-get update
    apt-get install -y wget curl
  elif command -v yum > /dev/null 2>&1; then
    yum -y update
    yum -y install wget curl
  else
    echo "未知的操作系统，无法继续"
    exit 1
  fi
}

# 创建 Prometheus 用户和组（如果不存在）
create_user_and_group() {
  if ! getent group $GROUP > /dev/null 2>&1; then
    groupadd --system $GROUP
  fi
  if ! id -u $USER > /dev/null 2>&1; then
    useradd -s /sbin/nologin --system -g $GROUP $USER
  fi
}

# 下载并解压 Prometheus
download_prometheus() {
  mkdir -p $DOWNLOAD_DIR $PROMETHEUS_DIR
  if [ ! -f $PROMETHEUS_TAR ]; then
    wget -O $PROMETHEUS_TAR $PROMETHEUS_URL
  fi
  tar -xzf $PROMETHEUS_TAR -C $PROMETHEUS_DIR
  mv $PROMETHEUS_DIR/prometheus-$PROMETHEUS_VERSION.linux-amd64/* $PROMETHEUS_DIR/
  rm -rf $PROMETHEUS_DIR/prometheus-$PROMETHEUS_VERSION.linux-amd64
  rm -f $PROMETHEUS_TAR
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
      - targets: ['localhost:9090']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF
  else
    [ ! -f /etc/prometheus/rules.yml ] && sed -i "s#/etc/prometheus/rules.yml#$CONFIG_DIR/rules.yml#" $CONFIG_DIR/prometheus.yml
  fi

  # 配置文件 IP 替换
  if [ `grep "localhost" $CONFIG_DIR/prometheus.yml|wc -l` -gt 0 ]; then
    ip=`/usr/sbin/ip addr |grep -A 2 "state UP"|grep inet|grep -Ev "inet6|127|172"|grep -v "\.250\."|head -n 1|awk '{print $2}'|awk -F'/' '{print $1}'`
    sed -i "s/localhost/$ip/g" $CONFIG_DIR/prometheus.yml
  fi

  chown $USER:$GROUP $CONFIG_DIR/prometheus.yml
}

# 创建 systemd 服务
create_systemd_service() {
  if [ ! -f /etc/systemd/system/prometheus.service ]; then
    cat <<EOF >/etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=$USER
Group=$GROUP
Type=simple
ExecStart=$PROMETHEUS_DIR/prometheus --config.file=$CONFIG_DIR/prometheus.yml --storage.tsdb.path=$DATA_DIR --web.console.templates=$PROMETHEUS_DIR/consoles --web.console.libraries=$PROMETHEUS_DIR/console_libraries
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable prometheus
  fi

  # 检查服务是否已经运行
  if systemctl is-active --quiet prometheus; then
    echo "Prometheus 服务已在运行"
  else
    systemctl start prometheus
    echo "Prometheus 服务已启动"
  fi
}

# 检测 Node Exporter 是否安装
detect_node_exporter() {
  if [ -f "$PROMETHEUS_DIR/node_exporter" ]; then
    echo "Node Exporter 已安装。"
    return 0
  else
    echo "Node Exporter 未安装。"
    return 1
  fi
}

# 下载并解压 Node Exporter
download_node_exporter() {
  if [ ! -f $NODE_EXPORTER_TAR ]; then
    wget -O $NODE_EXPORTER_TAR $NODE_EXPORTER_URL
  fi
  tar -xzf $NODE_EXPORTER_TAR -C $PROMETHEUS_DIR
  mv $PROMETHEUS_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter $PROMETHEUS_DIR/
  rm -rf $PROMETHEUS_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64
  rm -f $NODE_EXPORTER_TAR
  chown $USER:$GROUP $PROMETHEUS_DIR/node_exporter
}

# 创建 Node Exporter 的 systemd 服务
create_node_exporter_service() {
  if [ ! -f /etc/systemd/system/node_exporter.service ]; then
    cat <<EOF >/etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$USER
Group=$GROUP
Type=simple
ExecStart=$PROMETHEUS_DIR/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
  fi

  # 检查服务是否已经运行
  if systemctl is-active --quiet node_exporter; then
    echo "Node Exporter 服务已在运行"
  else
    systemctl start node_exporter
    echo "Node Exporter 服务已启动"
  fi
}

# 执行主流程
install() {
  check_root
  setup_environment
  create_user_and_group
  download_prometheus
  configure_prometheus
  create_systemd_service

  if ! detect_node_exporter; then
    download_node_exporter
    create_node_exporter_service
  fi

  echo "Prometheus 和 Node Exporter 安装和配置完成！"
}

install
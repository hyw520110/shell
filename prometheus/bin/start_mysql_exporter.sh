#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}

# 和mysql在同一台服务器，需读取mysql配置文件
MYSQL_EXPORTER_VERSION="0.16.0"
MYSQL_EXPORTER_URL="https://github.com/prometheus/mysqld_exporter/releases/download/v$MYSQL_EXPORTER_VERSION/mysqld_exporter-$MYSQL_EXPORTER_VERSION.linux-amd64.tar.gz"
DOWNLOAD_DIR="/opt/softs"
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
ExecStart=$BIN_DIR/mysqld_exporter --config.my-cnf=/opt/mysql/conf/my.cnf --web.listen-address=":9104"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable $service_name
  systemctl start $service_name
}

# 检测进程是否已运行
function is_running() {
  local service_name=$1
  if pgrep -f "$service_name" > /dev/null; then
    echo "检测到 $service_name 已经运行。"
    return 0
  else
    return 1
  fi
}

# 安装 MySQL Exporter
install_mysql_exporter() {
  check_root
  setup_environment
  create_user_and_group
  mkdir -p $BIN_DIR
  download_and_extract $MYSQL_EXPORTER_URL "mysqld_exporter-$MYSQL_EXPORTER_VERSION.linux-amd64"
  create_systemd_service "mysqld_exporter"
}

# 启动 MySQL Exporter
function start_mysql_exporter() {
  if [ ! -f "$BIN_DIR/mysqld_exporter" ]; then
    install_mysql_exporter
  fi

  if ! is_running "$BIN_DIR/mysqld_exporter"; then
    nohup $BIN_DIR/mysqld_exporter --config.my-cnf=/opt/mysql/conf/my.cnf --web.listen-address=":9104" > /dev/null 2>&1 &
    echo "MySQL Exporter 已启动。"
  else
    echo "MySQL Exporter 已经在运行。"
  fi
}

# 主函数
function main() {
  start_mysql_exporter
}

main
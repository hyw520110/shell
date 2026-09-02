#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}

# 全局变量
DOCKER_COMPOSE_FILE="docker-compose.yml"
PROMETHEUS_BIN="$BASE_DIR/bin/prometheus"
NODE_EXPORTER_BIN="$BASE_DIR/bin/node_exporter"
MYSQL_EXPORTER_BIN="$BASE_DIR/bin/mysqld_exporter"
PORT=9091
# 控制是否跟随日志输出
LOGS_FLAG="-f" 

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

# 检测主机安装
function detect_host_install() {
  [[ -f "$PROMETHEUS_BIN" && -f "$NODE_EXPORTER_BIN" ]] && return 0 || return 1
}

# 检测容器安装
function detect_container_install() {
  [[ -f "$DOCKER_COMPOSE_FILE" ]] && docker images |grep -q prometheus && docker-compose ps | grep -q prometheus && return 0 || return 1
}

# 安装主机模式
function install_host_mode() {
  echo "正在主机模式下安装..."
  $CURRENT_DIR/install.sh
}

# 安装容器模式
function install_container_mode() {
  echo "正在容器模式下安装..."
  docker-compose up -d
}

# 启动主机模式
function start_host_mode() {
	# --web.enable-lifecycle
  ! is_running "$PROMETHEUS_BIN" && nohup $PROMETHEUS_BIN --config.file=$BASE_DIR/conf/prometheus.yml --storage.tsdb.path=$BASE_DIR/data --web.listen-address=":$PORT" --web.console.templates=$BASE_DIR/consoles --web.console.libraries=$BASE_DIR/console_libraries > /dev/null 2>&1 &
  ! is_running "$NODE_EXPORTER_BIN" && nohup $NODE_EXPORTER_BIN > /dev/null 2>&1 &
  # 
  # http://ip:9091/targets 
}

# 启动容器模式
function start_container_mode() {
  if ! docker-compose ps | grep -q prometheus; then
    # 创建必要的目录
    while read -r dir; do
      [[ "$dir" =~ ^\.\.* ]] && dir=$BASE_DIR/${dir#.*/} && [ ! -d "$dir" ] && mkdir -p $dir && chmod -R 777 $dir
    done < <(cat $BASE_DIR/docker-compose.yml |grep -A 4 volumes|grep "-"|awk -F':' '{print $1}'|awk '{print $2}')

    docker-compose up -d
    [[ "$LOGS_FLAG" == "-f" ]] && docker-compose logs -f
  fi
}

function main() {
  if detect_host_install && ! is_running "$PROMETHEUS_BIN"; then
    start_host_mode
  elif detect_container_install && ! docker-compose ps | grep -q prometheus; then
    start_container_mode
  else
    echo "所有服务均已启动或没有可安装的服务。"
  fi
}

main
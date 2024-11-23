#!/bin/bash

# 全局变量
PROMETHEUS_BIN="bin/prometheus"
NODE_EXPORTER_BIN="bin/node_exporter"
DOCKER_COMPOSE_FILE="docker-compose.yml"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}

# 检测主机安装
function detect_host_install() {
  if [[ -f "$PROMETHEUS_BIN" && -f "$NODE_EXPORTER_BIN" ]]; then
    echo "检测到主机安装。"
    return 0
  else
    echo "未检测到主机安装。"
    return 1
  fi
}

# 检测容器安装
function detect_container_install() {
  if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
    if docker-compose ps | grep -q prometheus; then
      echo "检测到容器安装。"
      return 0
    else
      echo "未检测到容器安装。"
      return 1
    fi
  else
    echo "未找到 Docker Compose 文件。"
    return 1
  fi
}

# 安装主机模式
function install_host_mode() {
  echo "正在主机模式下安装..."
  # 调用安装脚本
  bin/install.sh
}

# 安装容器模式
function install_container_mode() {
  echo "正在容器模式下安装..."
  # 调用 Docker Compose 安装
  docker-compose up -d
}

# 启动主机模式
function start_host_mode() {
  echo "正在主机模式下启动..."
  # 启动 Prometheus 和 Node Exporter
  $PROMETHEUS_BIN --config.file=$BASE_DIR/conf/prometheus.yml &
  $NODE_EXPORTER_BIN &
}

# 启动容器模式
function start_container_mode() {
  echo "正在容器模式下启动..."
  cd $BASE_DIR
  # 检查创建目录
  for dir in `cat $BASE_DIR/docker-compose.yml |grep -A 4 volumes|grep "-"|awk -F':' '{print $1}'|awk '{print $2}'`
  do
    if [[ "$dir" == "."* || "$dir" == "/"* ]];then
      [[ "$dir" =~ ^\..* ]] && dir=`echo $dir|sed 's/^\.\///'` && dir=$BASE_DIR/$dir && [ ! -d "$dir" ] && echo "创建目录: $dir" && mkdir -p $dir && chmod -R 777 $dir
    fi
  done
  docker-compose up -d
  docker-compose logs -f
}

# 主逻辑
function main() {
  # 检测主机安装
  if detect_host_install; then
    start_host_mode
    exit 0
  fi

  # 检测容器安装
  if detect_container_install; then
    start_container_mode
    exit 0
  fi

  # 选择安装模式
  read -p "未检测到主机和容器安装。请选择安装模式 (主机/容器): " choice

  case $choice in
    主机)
      install_host_mode
      start_host_mode
      ;;
    容器)
      install_container_mode
      start_container_mode
      ;;
    *)
      echo "无效的选择。默认选择主机安装。"
      install_host_mode
      start_host_mode
      ;;
  esac
}

# 执行主逻辑
main
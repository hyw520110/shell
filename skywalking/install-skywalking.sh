#!/bin/bash
# skywalking自动安装、配置

# 定义变量
SW_HOME=/opt/skywalking
SW_VERSION=8.8.0
SW_URL=https://archive.apache.org/dist/skywalking/$SW_VERSION/apache-skywalking-apm-$SW_VERSION.tgz
SW_FILE=apache-skywalking-apm-$SW_VERSION
SW_TGZ=$SW_HOME/$SW_FILE.tgz

# 检查操作系统
function check_os () {
  if [ -f /etc/redhat-release ]; then
    OS="CentOS"
  elif [ -f /etc/debian_version ]; then
    OS="Deepin"
  else
    echo "Unsupported OS"
    exit 1
  fi
}

# 下载 SkyWalking
function download_sw () {
  if [ ! -d ${SW_TGZ%/*} ]; then
    echo "mkdir -p ${SW_TGZ%/*}"
    mkdir -p ${SW_TGZ%/*}
  fi
  if [ ! -f $SW_TGZ ]; then
    echo "Downloading SkyWalking..."
    wget $SW_URL -O $SW_TGZ
  fi
}

# 解压 SkyWalking
function extract_sw () {
  if [ ! -d $SW_HOME/$SW_FILE ]; then
    echo "Extracting SkyWalking..."
    tar -zxvf $SW_TGZ -C $SW_HOME
  fi
}

# 配置 SkyWalking
function configure_sw () {
  # 配置 collector
  collector_config=$SW_HOME/$SW_FILE/config/application.yml
  sed -i 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $collector_config

  # 配置 UI
  ui_config=$SW_HOME/$SW_FILE/config/application.yml
  sed -i 's/^ui.graphql_endpoint=.*/ui.graphql_endpoint=http:\/\/127.0.0.1:12800\/graphql/' $ui_config

  # 配置 agent
  agent_config=$SW_HOME/$SW_FILE/agent/config/agent.config
  sed -i 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $agent_config
}

# 启动 SkyWalking
function start_sw () {
  # 启动 backend
  echo "Starting SkyWalking Backend..."
  $SW_HOME/$SW_FILE/bin/startup.sh

  # 启动 UI
  echo "Starting SkyWalking UI..."
  $SW_HOME/$SW_FILE/bin/start-ui.sh

  # 启动 agent
  # 代理需要在应用程序中配置，这里不启动
  echo "SkyWalking Agent configuration is done. Please configure it in your application."
}

# 主函数
function main () {
  check_os
  download_sw
  extract_sw
  configure_sw
  start_sw
}

main

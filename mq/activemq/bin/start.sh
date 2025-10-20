#!/bin/bash
# 封装ActiveMQ启动脚本
# 支持 -d/--dir 指定安装目录，--log-level 设置日志级别

DEFAULT_INSTALL_DIR="$HOME/activemq"
LOG_LEVEL="INFO"
INSTALL_DIR=""

log() { echo "[$1] $2"; }

print_usage() {
  echo "用法: $0 [-d DIR] [--log-level LEVEL]"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
      --log-level) LOG_LEVEL="$2"; shift 2 ;;
      -h|--help) print_usage; exit 0 ;;
      *) log ERROR "未知参数: $1"; print_usage; exit 1 ;;
    esac
  done
  if [[ -z "$INSTALL_DIR" ]]; then
    case "$(uname -s)" in
      Linux*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
      Darwin*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
      *) log ERROR "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac
  fi
}

main() {
  parse_arguments "$@"
  export ACTIVEMQ_HOME="$INSTALL_DIR"
  export ACTIVEMQ_BASE="$INSTALL_DIR"
  export ACTIVEMQ_CONF="$INSTALL_DIR/conf"
  export ACTIVEMQ_DATA="$INSTALL_DIR/data"
  # 解决Java 17在非容器环境的cgroup异常
  JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
  if [[ "$JAVA_VERSION" == 17* ]]; then
    export ACTIVEMQ_OPTS="${ACTIVEMQ_OPTS} -XX:-UseContainerSupport"
  fi
  if [[ -x "$INSTALL_DIR/bin/activemq" ]]; then
    "$INSTALL_DIR/bin/activemq" start
  else
    log ERROR "未找到activemq启动脚本: $INSTALL_DIR/bin/activemq"; exit 1
  fi
}

main "$@"

#!/bin/bash
# 封装ActiveMQ/Artemis启动脚本
# 支持 -d/--dir 指定安装目录，--log-level 设置日志级别

DEFAULT_INSTALL_DIR="$HOME/activemq"
LOG_LEVEL="INFO"
INSTALL_DIR=""
MODE="start"  # 默认启动模式
MQ_TYPE="classic"  # 默认Classic类型

# MQ类型检测函数
is_artemis() {
    [[ "$MQ_TYPE" == "artemis" ]]
}

is_classic() {
    [[ "$MQ_TYPE" == "classic" ]]
}

log() { echo "[$1] $2"; }

print_usage() {
  echo "用法: $0 [-d DIR] [--log-level LEVEL] [--artemis|--classic] [start|console]"
  echo "  --artemis   启动ActiveMQ Artemis"
  echo "  --classic   启动ActiveMQ Classic（默认）"
  echo "  start       后台启动MQ (默认)"
  echo "  console     前台启动MQ (调试模式)"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
      --log-level) LOG_LEVEL="$2"; shift 2 ;;
      --artemis) MQ_TYPE="artemis"; shift ;;
      --classic) MQ_TYPE="classic"; shift ;;
      -h|--help) print_usage; exit 0 ;;
      start|console) MODE="$1"; shift ;;
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
  if is_artemis; then
    export ARTEMIS_HOME="$INSTALL_DIR"
    export ARTEMIS_BASE="$INSTALL_DIR"
    export ARTEMIS_CONF="$INSTALL_DIR/conf"
    export ARTEMIS_DATA="$INSTALL_DIR/data"
    # 设置Java 17兼容性参数
    if [[ -f "$ARTEMIS_CONF/setenv" ]]; then
      source "$ARTEMIS_CONF/setenv" 2>/dev/null || true
    fi
    # 解决Java 17在非容器环境的cgroup异常
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ "$JAVA_VERSION" == 17* ]]; then
      export ARTEMIS_OPTS="${ARTEMIS_OPTS} -XX:-UseContainerSupport"
    fi
    if [[ -x "$INSTALL_DIR/bin/artemis" ]]; then
      case "$MODE" in
        start) "$INSTALL_DIR/bin/artemis" run ;;
        console) "$INSTALL_DIR/bin/artemis" console ;;
        *) log ERROR "未知模式: $MODE"; exit 1 ;;
      esac
    else
      log ERROR "未找到artemis启动脚本: $INSTALL_DIR/bin/artemis"; exit 1
    fi
  else
    export ACTIVEMQ_HOME="$INSTALL_DIR"
    export ACTIVEMQ_BASE="$INSTALL_DIR"
    export ACTIVEMQ_CONF="$INSTALL_DIR/conf"
    export ACTIVEMQ_DATA="$INSTALL_DIR/data"
    # 设置Java 17兼容性参数
    if [[ -f "$ACTIVEMQ_CONF/setenv" ]]; then
      source "$ACTIVEMQ_CONF/setenv" 2>/dev/null || true
    fi
    # 解决Java 17在非容器环境的cgroup异常
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ "$JAVA_VERSION" == 17* ]]; then
      export ACTIVEMQ_OPTS="${ACTIVEMQ_OPTS} -XX:-UseContainerSupport"
    fi
    if [[ -x "$INSTALL_DIR/bin/activemq" ]]; then
      case "$MODE" in
        start) "$INSTALL_DIR/bin/activemq" start ;;
        console) "$INSTALL_DIR/bin/activemq" console ;;
        *) log ERROR "未知模式: $MODE"; exit 1 ;;
      esac
    else
      log ERROR "未找到activemq启动脚本: $INSTALL_DIR/bin/activemq"; exit 1
    fi
  fi
}

main "$@"

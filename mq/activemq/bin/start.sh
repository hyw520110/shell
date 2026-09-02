#!/bin/bash

# 封装ActiveMQ/Artemis启动脚本
# 支持 -d/--dir 指定安装目录，--log-level 设置日志级别
# 自动检测MQ类型（Artemis或Classic）
# 使用模块化设计，提高代码可维护性

# 加载公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" || { echo "无法加载公共函数库"; exit 1; }

INSTALL_DIR=""
MODE="start"  # 默认启动模式

print_usage() {
  echo "用法: $0 [-d DIR] [--log-level LEVEL] [start|console]"
  echo "  start       后台启动MQ (默认)"
  echo "  console     前台启动MQ (调试模式)"
  echo ""
  echo "注意: 脚本会自动检测安装的MQ类型（Artemis或Classic）"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
      --log-level) LOG_LEVEL="$2"; shift 2 ;;
      -h|--help) print_usage; exit 0 ;;
      start|console) MODE="$1"; shift ;;
      *) echo "错误: 未知参数: $1"; print_usage; exit 1 ;;
    esac
  done
  if [[ -z "$INSTALL_DIR" ]]; then
    case "$(detect_os)" in
      Linux*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
      MacOS*) INSTALL_DIR="$DEFAULT_INSTALL_DIR" ;;
      *) echo "错误: 不支持的操作系统: $(detect_os)"; exit 1 ;;
    esac
  fi
}

main() {
  parse_arguments "$@"
  
  # 验证安装目录
  if ! validate_install_dir "$INSTALL_DIR"; then
      exit 1
  fi
  
  # 自动检测MQ类型和显示名称
  local mq_type=$(detect_mq_type_by_path "$INSTALL_DIR")
  local mq_display_name=$(get_mq_display_name "$mq_type")
  
  # 设置环境变量和Java 17兼容性
  if [[ "$mq_type" == "artemis" ]]; then
    export ARTEMIS_HOME="$INSTALL_DIR"
    export ARTEMIS_BASE="$INSTALL_DIR"
    export ARTEMIS_CONF="$INSTALL_DIR/etc"  # Artemis使用etc目录而不是conf
    export ARTEMIS_DATA="$INSTALL_DIR/data"
    
    # 设置Java 17兼容性参数
    if [[ -f "$ARTEMIS_CONF/setenv" ]]; then
      source "$ARTEMIS_CONF/setenv" 2>/dev/null || true
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
  fi
  
  # 设置Java 17兼容性
  setup_java17_compatibility_by_type "$INSTALL_DIR" "$mq_type"
  
  # 执行启动命令
  if [[ -x "$INSTALL_DIR/bin/$mq_type" ]]; then
    case "$MODE" in
      start) 
        echo "启动$mq_display_name服务..."
        if [[ "$mq_type" == "artemis" ]]; then
            "$INSTALL_DIR/bin/artemis-service" start
        else
            "$INSTALL_DIR/bin/$mq_type" start
        fi
        ;;
      console) 
        echo "以控制台模式启动$mq_display_name服务..."
        if [[ "$mq_type" == "artemis" ]]; then
            "$INSTALL_DIR/bin/artemis" console
        else
            "$INSTALL_DIR/bin/$mq_type" console
        fi
        ;;
      *) 
        echo "错误: 未知模式: $MODE"
        exit 1 ;;
    esac
  else
    echo "错误: 未找到$mq_type启动脚本: $INSTALL_DIR/bin/$mq_type"
    exit 1
  fi
}

main "$@"
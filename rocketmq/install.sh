#!/bin/bash

# 配置变量
CONF_DIR=conf
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
IP=$(/opt/shell/ip.sh)
DOWNLOAD_URL="https://dist.apache.org/repos/dist/release/rocketmq/5.3.1/rocketmq-all-5.3.1-bin-release.zip"
DOWNLOAD_DIR="/opt/softs"
ZIP_FILE=$(basename "$DOWNLOAD_URL")
EXTRACT_DIR=$(basename "${DOWNLOAD_URL%.*}")

TEMP_EXTRACT_DIR="/tmp/${EXTRACT_DIR}"

# 检查并下载/解压安装包
check_and_extract() {
  if [ ! -d "$DIR/bin" ] || [ ! -d "$DIR/conf" ] || [ ! -d "$DIR/lib" ]; then
    echo "检测到缺少必要目录，开始下载和解压 RocketMQ 安装包"
    # 检查并下载 ZIP 文件
    if [ ! -f "$DOWNLOAD_DIR/$ZIP_FILE" ]; then
      [ ! -d "$DOWNLOAD_DIR" ] && echo "创建下载目录: $DOWNLOAD_DIR" && mkdir -p "$DOWNLOAD_DIR"
      echo "下载 RocketMQ 安装包: $DOWNLOAD_URL"
      wget -O "$DOWNLOAD_DIR/$ZIP_FILE" "$DOWNLOAD_URL"
    fi
    
    # 解压 ZIP 文件
    if [ ! -d "$TEMP_EXTRACT_DIR" ]; then
      echo "解压 RocketMQ 安装包: $DOWNLOAD_DIR/$ZIP_FILE 到 $TEMP_EXTRACT_DIR"
      unzip -d "$TEMP_EXTRACT_DIR" "$DOWNLOAD_DIR/$ZIP_FILE"
    fi
    
    # 拷贝解压后的文件到当前脚本目录
    echo "拷贝解压后的文件到当前脚本目录: $DIR"
    rsync -av --delete "$TEMP_EXTRACT_DIR/" "$DIR/"
  fi
}

# 修改配置文件
modify_conf() {
  local IP=$1
  local CONF_DIR=$2
  local FILE=$3
  local PORT=$4
  echo "修改配置文件: $CONF_DIR/$FILE"
  grep -q "namesrvAddr=$IP:9876" "$CONF_DIR/$FILE" || echo "namesrvAddr=$IP:9876" >> "$CONF_DIR/$FILE"
  grep -q "brokerIP1=$IP:$PORT" "$CONF_DIR/$FILE" || echo "brokerIP1=$IP:$PORT" >> "$CONF_DIR/$FILE"
}

modify_namesrv() {
  local NAMESRV_IP=$1
  local CONF_FILE=$2
  local LOCAL_IP=$3
  echo "修改 Namesrv 配置文件: $CONF_FILE"
  if [ -n "$NAMESRV_IP" ]; then
    sed -i "s|^namesrvAddr=.*|namesrvAddr=$LOCAL_IP:9876;$NAMESRV_IP:9876|" "$CONF_FILE"
  else
    sed -i "s|^namesrvAddr=.*|namesrvAddr=$LOCAL_IP:9876|" "$CONF_FILE"
  fi
}

start_namesrv() {
  echo "启动 NameServer"
  nohup $DIR/bin/mqnamesrv -n $IP:9876 > /dev/null 2>&1 &
}

start_broker() {
  local BROKER_CONF=$1
  local AUTO_CREATE_TOPIC_ENABLE=$2
  echo "启动 Broker: $BROKER_CONF"
  nohup sh $DIR/bin/mqbroker -c "$BROKER_CONF" autoCreateTopicEnable="$AUTO_CREATE_TOPIC_ENABLE" > /dev/null 2>&1 &
}

stop_processes() {
  echo "停止 NameServer 和 Broker 进程"
  pkill -f mqnamesrv
  pkill -f mqbroker
}

# 检查并下载/解压安装包
check_and_extract

# 检查是否已启动
check_running_processes() {
  if ps -ef | grep -E "mqnamesrv|mqbroker" | grep -v grep > /dev/null; then
    echo "检测到 RocketMQ 已经运行"
    read -p "是否停止现有进程？(y/N) " STOP_CHOICE
    case $STOP_CHOICE in
      y|Y)
        stop_processes
        ;;
      *)
        echo "继续使用现有进程"
        exit 0
        ;;
    esac
  fi
}

# 检查是否已启动
check_running_processes

echo "选择模式："
echo "1、2m-noslave"
echo "2、2m-2s-async"
echo "3、2m-2s-sync"
read -n 1 -p "输入数字选择模式 > " MODE

case $MODE in
  1)
    CONF_SUBDIR=2m-noslave
    mkdir -p "$CONF_DIR/$CONF_SUBDIR"
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-a.properties" 10911
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-b.properties" 10912
    read -p "输入另外一台namesrv的ip (留空表示本机) > " NAMESRV_IP
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-a.properties" "$IP"
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-b.properties" "$IP"
    start_namesrv
    start_broker "$CONF_DIR/$CONF_SUBDIR/broker-a.conf" true
    start_broker "$CONF_DIR/$CONF_SUBDIR/broker-b.conf" true
    ;;
  2|3)
    CONF_SUBDIR=$( [ $MODE -eq 2 ] && echo "2m-2s-async" || echo "2m-2s-sync" )
    mkdir -p "$CONF_DIR/$CONF_SUBDIR"
    read -p "输入a或b选择broker > " BROKER
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER.properties" 10911
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER-s.properties" 10912
    read -p "输入另外一台namesrv的ip (留空表示本机) > " NAMESRV_IP
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.properties" "$IP"
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.properties" "$IP"
    start_namesrv
    start_broker "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.conf" true
    start_broker "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.conf" true
    ;;
  *)
    echo "未知模式"
    exit 1
    ;;
esac

echo "显示正在运行的 NameServer 和 Broker 进程"
ps -ef | grep -E "namesrv|broker" | grep -v grep

#!/bin/bash

# 配置变量
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONF_DIR=${DIR}/conf
DOWNLOAD_URL="https://dist.apache.org/repos/dist/release/rocketmq/5.3.1/rocketmq-all-5.3.1-bin-release.zip"
# https://github.com/apache/rocketmq-externals/releases
DOWNLOAD_DIR="/opt/softs"
ZIP_FILE=$(basename "$DOWNLOAD_URL")
EXTRACT_DIR=$(basename "${DOWNLOAD_URL%.*}")
TEMP_EXTRACT_DIR="/tmp/${EXTRACT_DIR}"
IP=$(/opt/shell/ip.sh)
export ROCKETMQ_HOME="$DIR"


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

# 修改配置文件中的特定键值对
modify_key_value() {
  local KEY=$1
  local VALUE=$2
  local CONF_FILE=$3
  echo "修改配置文件: $CONF_FILE"
  if grep -q "^$KEY=" "$CONF_FILE"; then
    sed -i "s|^$KEY=.*|$KEY=$VALUE|" "$CONF_FILE"
  else
    echo "$KEY=$VALUE" >> "$CONF_FILE"
  fi
}

# 修改配置文件
modify_conf() {
  local IP=$1
  local CONF_DIR=$2
  local FILE=$3
  local PORT=$4
  modify_key_value "brokerId" "$IP:$PORT" "$CONF_DIR/$FILE"
}

# 修改 Namesrv 配置文件
modify_namesrv() {
  local NAMESRV_IP=$1
  local CONF_FILE=$2
  local LOCAL_IP=$3
  modify_key_value "namesrvAddr" "$LOCAL_IP:9876;$NAMESRV_IP:9876" "$CONF_FILE"
}

start_namesrv() {
  echo "启动NameServer:$DIR/bin/mqnamesrv -n $IP:9876 > /dev/null 2>&1 &"
  nohup $DIR/bin/mqnamesrv -n $IP:9876 > /dev/null 2>&1 &
}

start_broker() {
  local BROKER_CONF=$1
  local AUTO_CREATE_TOPIC_ENABLE=$2
  if ! grep -q "jdk-11" "$DIR/bin/mqbroker";then
   sed -i '2iJAVA_HOME=$(dirname $(dirname $(readlink -f $(update-alternatives --list java | grep "jdk-11"))))'  $DIR/bin/mqbroker
  fi
  if ! grep -q "jdk-11" "$DIR/bin/runbroker.sh";then
    sed -i '2iJAVA_HOME=$(dirname $(dirname $(readlink -f $(update-alternatives --list java | grep "jdk-11"))))'  $DIR/bin/runbroker.sh
  fi
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

# 检查 NameServer IP 的可达性
check_ip_reachable() {
  local IP=$1
  ping -c 1 "$IP" &> /dev/null
  if [ $? -ne 0 ]; then
    return 1
  else
    return 0
  fi
}

# 检查 SSH 连接是否可达
check_ssh_reachable() {
  local IP=$1
  local USER=$2
  ssh -o ConnectTimeout=5 -T $USER@$IP exit
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

# 同步配置文件和 bin 目录到远程主机
sync_to_remote() {
  local REMOTE_HOST=$1
  local REMOTE_USER=$2
  echo "同步目录到远程主机: $REMOTE_HOST"
  rsync -av --delete "$DIR" "$REMOTE_USER@$REMOTE_HOST:$DIR"
}

# 在远程主机上启动服务
start_remote_services() {
  local REMOTE_HOST=$1
  local REMOTE_USER=$2
  echo "启动远程主机上的 NameServer 和 Broker 服务"
  ssh "$REMOTE_USER@$REMOTE_HOST" "nohup $DIR/bin/mqnamesrv -n $IP:9876 > /dev/null 2>&1 &"
  ssh "$REMOTE_USER@$REMOTE_HOST" "nohup sh $DIR/bin/mqbroker -c \"$CONF_DIR/$CONF_SUBDIR/broker-b.conf\" autoCreateTopicEnable=true > /dev/null 2>&1 &"
}

# 检查是否已启动
check_running_processes

echo "选择模式："
echo "1、2m-noslave(多Master无Slave模式)"
echo "2、2m-2s-async(多Master多Slave异步复制模式)"
echo "3、2m-2s-sync(多Master多Slave同步复制模式)"
read -t 5 -p "输入数字选择模式(开发环境推荐2m-noslave,生产环境推荐2m-2s-async) > " MODE
MODE=${MODE:-1}

while true; do
  read -p "输入另外一台namesrv的ip (非本机IP) > " NAMESRV_IP
  if [ -z "$NAMESRV_IP" ]; then
    break
  fi
  if check_ip_reachable "$NAMESRV_IP"; then
    read -p "输入远程主机的用户名 > " USERNAME
    if check_ssh_reachable "$NAMESRV_IP" "$USERNAME"; then
      echo "SSH 连接成功，继续操作。"
      break
    else
      echo "无法通过 SSH 连接到 $NAMESRV_IP，请重新输入。"
    fi
  else
    echo "IP地址 $NAMESRV_IP 不可达，请重新输入。"
  fi
done

case $MODE in
  1)
    CONF_SUBDIR=2m-noslave
    mkdir -p "$CONF_DIR/$CONF_SUBDIR"
    modify_key_value "listenPort" "10911" "$CONF_DIR/$CONF_SUBDIR/broker-a.properties"
    modify_key_value "brokerId" "0" "$CONF_DIR/$CONF_SUBDIR/broker-a.properties"
    modify_key_value "listenPort" "10912" "$CONF_DIR/$CONF_SUBDIR/broker-b.properties"
    modify_key_value "brokerId" "0" "$CONF_DIR/$CONF_SUBDIR/broker-b.properties"
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-a.properties" "$IP"
    modify_namesrv "$NAMESRV_IP" "$CONF_DIR/$CONF_SUBDIR/broker-b.properties" "$IP"
    start_namesrv
    start_broker "$CONF_DIR/$CONF_SUBDIR/broker-a.conf" true

    # 远程启动 namesrv 和 broker-b 服务
    if [ -n "$NAMESRV_IP" ]; then
      sync_to_remote "$NAMESRV_IP" "$USERNAME"
      start_remote_services "$NAMESRV_IP" "$USERNAME"
    fi

    ;;
  2|3)
    CONF_SUBDIR=$( [ $MODE -eq 2 ] && echo "2m-2s-async" || echo "2m-2s-sync" )
    mkdir -p "$CONF_DIR/$CONF_SUBDIR"
    read -p "输入a或b选择broker > " BROKER
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER.properties" 10911
    modify_conf $IP "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER-s.properties" 10912
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
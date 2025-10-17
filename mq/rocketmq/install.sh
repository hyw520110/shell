#!/bin/bash

# 设置错误处理
set -e

# 配置变量
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

DOWNLOAD_URL="https://dist.apache.org/repos/dist/release/rocketmq/5.3.3/rocketmq-all-5.3.3-bin-release.zip"
# https://github.com/apache/rocketmq-externals/releases
DOWNLOAD_DIR="/tmp"
ZIP_FILE=$(basename "$DOWNLOAD_URL")
EXTRACT_DIR=$(basename "${DOWNLOAD_URL%.*}")
TEMP_EXTRACT_DIR="/tmp"
IP=$(../linux/ip.sh)
INSTALL_DIR=${1:-$HOME/rocketmq}
CONF_DIR=${INSTALL_DIR}/conf
export ROCKETMQ_HOME="$INSTALL_DIR"
OS=$(uname)

SED_INPLACE_OPT=""
if [ "$OS" == "Darwin" ]; then
  SED_INPLACE_OPT="''"
fi

# 检查必要工具
check_tools() {
  local tools=("wget" "unzip" "rsync" "ssh" "ping")
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      echo "错误: 缺少必要工具 $tool，请先安装"
      exit 1
    fi
  done
}

# 自动安装 aria2（如果系统中没有）
install_aria2_if_needed() {
  if ! command -v aria2c &> /dev/null; then
    echo "检测到系统中未安装 aria2，正在尝试自动安装..."
    
    # 检测操作系统类型并尝试安装
    if command -v apt-get &> /dev/null; then
      # Debian/Ubuntu 系统
      echo "检测到 Debian/Ubuntu 系统，使用 apt-get 安装 aria2"
      if sudo apt-get update && sudo apt-get install -y aria2; then
        echo "aria2 安装成功"
        return 0
      else
        echo "使用 apt-get 安装 aria2 失败"
      fi
    elif command -v yum &> /dev/null; then
      # CentOS/RHEL 系统
      echo "检测到 CentOS/RHEL 系统，使用 yum 安装 aria2"
      if sudo yum install -y aria2; then
        echo "aria2 安装成功"
        return 0
      else
        echo "使用 yum 安装 aria2 失败"
      fi
    elif command -v dnf &> /dev/null; then
      # Fedora 系统
      echo "检测到 Fedora 系统，使用 dnf 安装 aria2"
      if sudo dnf install -y aria2; then
        echo "aria2 安装成功"
        return 0
      else
        echo "使用 dnf 安装 aria2 失败"
      fi
    elif command -v brew &> /dev/null; then
      # macOS 系统
      echo "检测到 macOS 系统，使用 brew 安装 aria2"
      if brew install aria2; then
        echo "aria2 安装成功"
        return 0
      else
        echo "使用 brew 安装 aria2 失败"
      fi
    else
      echo "无法自动安装 aria2，未识别到合适的包管理器"
      echo "请手动安装 aria2 以获得更快的下载速度:"
      echo "  Ubuntu/Debian: sudo apt-get install aria2"
      echo "  CentOS/RHEL:   sudo yum install aria2"
      echo "  Fedora:        sudo dnf install aria2"
      echo "  macOS:         brew install aria2"
      return 1
    fi
    
    echo "自动安装 aria2 失败，将使用系统默认的下载工具"
    return 1
  fi
  
  return 0
}

# 支持断点续传的下载函数
download_with_resume() {
  local url=$1
  local dest=$2
  
  echo "正在下载: $url"
  echo "目标文件: $dest"
  
  # 检查是否已部分下载
  if [ -f "$dest" ]; then
    local file_size=$(stat -c %s "$dest" 2>/dev/null || stat -f %z "$dest" 2>/dev/null || echo "0")
    if [ "$file_size" -gt 0 ]; then
      echo "检测到部分下载的文件，大小: $file_size 字节，尝试断点续传..."
    fi
  fi
  
  # 尝试安装 aria2 以提高下载速度
  install_aria2_if_needed
  
  # 优先使用 aria2c（多线程下载工具）如果可用
  # 注意：某些服务器不支持断点续传，所以我们需要检测这种情况
  if command -v aria2c >/dev/null 2>&1; then
    echo "使用 aria2c 多线程下载（最大连接数: 8）"
    # 使用绝对路径确保下载到正确位置，并添加 --allow-overwrite=true
    aria2c -c -x 8 -s 8 --allow-overwrite=true -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url" || {
      echo "aria2c下载失败，尝试wget"
      try_wget_or_curl "$url" "$dest"
    }
  # 使用wget支持断点续传
  elif command -v wget >/dev/null 2>&1; then
    echo "使用 wget 断点续传下载"
    # 检查服务器是否支持断点续传
    if wget --server-response --spider -O /dev/null -o - "$url" 2>&1 | grep -q "Accept-Ranges: bytes"; then
      echo "服务器支持断点续传"
      wget --tries=3 --timeout=30 -c -O "$dest" "$url" || {
        echo "wget下载失败，尝试curl"
        try_curl "$url" "$dest"
      }
    else
      echo "服务器不支持断点续传，重新下载文件"
      rm -f "$dest"  # 删除不完整的文件
      wget --tries=3 --timeout=30 -O "$dest" "$url" || {
        echo "wget下载失败，尝试curl"
        try_curl "$url" "$dest"
      }
    fi
  # 备选方案：使用curl支持断点续传  
  elif command -v curl >/dev/null 2>&1; then
    echo "使用 curl 下载"
    # 检查服务器是否支持断点续传
    if curl -s -I "$url" | grep -q "Accept-Ranges: bytes"; then
      echo "服务器支持断点续传"
      curl --retry 3 --connect-timeout 30 -C - -o "$dest" "$url" || {
        echo "curl下载失败"
        return 1
      }
    else
      echo "服务器不支持断点续传，重新下载文件"
      rm -f "$dest"  # 删除不完整的文件
      curl --retry 3 --connect-timeout 30 -o "$dest" "$url" || {
        echo "curl下载失败"
        return 1
      }
    fi
  else
    echo "系统中未找到wget、curl或aria2c命令，无法下载"
    return 1
  fi
  
  echo "下载完成: $dest"
  return 0
}

# 使用wget下载
try_wget() {
  local url=$1
  local dest=$2
  rm -f "$dest"  # 删除不完整的文件
  wget --tries=3 --timeout=30 -O "$dest" "$url"
  return $?
}

# 使用curl下载
try_curl() {
  local url=$1
  local dest=$2
  rm -f "$dest"  # 删除不完整的文件
  curl --retry 3 --connect-timeout 30 -o "$dest" "$url"
  return $?
}

# 尝试使用wget或curl下载
try_wget_or_curl() {
  local url=$1
  local dest=$2
  
  if command -v wget >/dev/null 2>&1; then
    try_wget "$url" "$dest" || try_curl "$url" "$dest"
    return $?
  elif command -v curl >/dev/null 2>&1; then
    try_curl "$url" "$dest"
    return $?
  else
    return 1
  fi
}

# 检查ZIP文件完整性
check_zip_integrity() {
  local zip_file=$1
  echo "检查ZIP文件完整性: $zip_file"
  
  # 检查文件是否存在
  if [ ! -f "$zip_file" ]; then
    echo "ZIP文件不存在: $zip_file"
    return 1
  fi
  
  # 检查文件大小
  local file_size=$(stat -c %s "$zip_file" 2>/dev/null || stat -f %z "$zip_file" 2>/dev/null || echo "0")
  if [ "$file_size" -lt 1024 ]; then  # 小于1KB认为文件不完整
    echo "ZIP文件太小，可能不完整: $file_size 字节"
    return 1
  fi
  
  # 使用unzip检查文件完整性
  if ! unzip -t "$zip_file" >/dev/null 2>&1; then
    echo "ZIP文件完整性检查失败"
    return 1
  fi
  
  echo "ZIP文件完整性检查通过"
  return 0
}

# 检查并下载/解压安装包
check_and_extract() {
  if [ ! -d "$INSTALL_DIR/bin" ] || [ ! -d "$INSTALL_DIR/conf" ] || [ ! -d "$INSTALL_DIR/lib" ]; then
    echo "检测未安装，开始下载和解压 RocketMQ 安装包"
    local download_needed=true
    
    # 检查本地是否存在ZIP文件
    if [ -f "$DOWNLOAD_DIR/$ZIP_FILE" ]; then
      # 检查文件完整性
      if check_zip_integrity "$DOWNLOAD_DIR/$ZIP_FILE"; then
        echo "本地已存在完整的ZIP文件，跳过下载"
        download_needed=false
      else
        echo "本地ZIP文件不完整，继续下载"
      fi
    fi
    
    # 如果需要下载（文件不存在或不完整）
    if [ "$download_needed" = true ]; then
      [ ! -d "$DOWNLOAD_DIR" ] && echo "创建下载目录: $DOWNLOAD_DIR" && mkdir -p "$DOWNLOAD_DIR"
      echo "下载 RocketMQ 安装包: $DOWNLOAD_URL"
      download_with_resume "$DOWNLOAD_URL" "$DOWNLOAD_DIR/$ZIP_FILE" || {
        echo "下载失败，请检查网络连接或手动下载"
        exit 1
      }
      
      # 验证下载文件的完整性
      if ! check_zip_integrity "$DOWNLOAD_DIR/$ZIP_FILE"; then
        echo "下载的文件完整性检查失败"
        exit 1
      fi
    fi
    
    # 解压 ZIP 文件
    if [ ! -d "$TEMP_EXTRACT_DIR/${EXTRACT_DIR}" ]; then
      echo "解压 RocketMQ 安装包: $DOWNLOAD_DIR/$ZIP_FILE 到 $TEMP_EXTRACT_DIR"
      unzip -d "$TEMP_EXTRACT_DIR" "$DOWNLOAD_DIR/$ZIP_FILE" || {
        echo "解压失败，请检查文件完整性"
        exit 1
      }
    fi
    [ ! -d "$INSTALL_DIR" ] && echo "$INSTALL_DIR 安装目录不存在" && mkdir -p "$INSTALL_DIR"
    echo "同步 $TEMP_EXTRACT_DIR/${EXTRACT_DIR}/ 到 $INSTALL_DIR/"
    rsync -az "$TEMP_EXTRACT_DIR/${EXTRACT_DIR}/" "$INSTALL_DIR/"
  fi
}

# 修改配置文件中的特定键值对
modify_key_value() {
  local KEY=$1
  local VALUE=$2
  local CONF_FILE=$3
  echo "修改配置文件: $CONF_FILE"
  
  # 确保配置文件存在
  [ ! -f "$CONF_FILE" ] && touch "$CONF_FILE"
  
  # 先删除已存在的配置（无论是否注释）
  sed -i $SED_INPLACE_OPT "/^[[:space:]]*#*[[:space:]]*$KEY=/d" "$CONF_FILE"
  
  # 添加新配置
  echo "$KEY=$VALUE" >> "$CONF_FILE"
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
  
  # 处理空的NAMESRV_IP情况
  if [ -z "$NAMESRV_IP" ]; then
    modify_key_value "namesrvAddr" "$LOCAL_IP:9876" "$CONF_FILE"
  else
    modify_key_value "namesrvAddr" "$LOCAL_IP:9876;$NAMESRV_IP:9876" "$CONF_FILE"
  fi
}

# 检查JDK 11是否存在
check_jdk11() {
  if update-alternatives --list java | grep -q "jdk-11"; then
    return 0
  else
    return 1
  fi
}

# 配置JDK 11环境
setup_jdk11() {
  local file=$1
  if check_jdk11; then
    if ! grep -q "jdk-11" "$file"; then
      if [[ "$OS" == "Darwin" ]]; then
        sed -i $SED_INPLACE_OPT '2i\'$'\n''JAVA_HOME=$(dirname $(dirname $(readlink -f $(update-alternatives --list java | grep "jdk-11"))))'$'\n' "$file"
      else
        sed -i $SED_INPLACE_OPT '2iJAVA_HOME=$(dirname $(dirname $(readlink -f $(update-alternatives --list java | grep "jdk-11"))))' "$file"
      fi
    fi
  else
    echo "警告: 系统中未找到 JDK 11，使用默认 Java 环境"
  fi
}

start_namesrv() {
  echo "启动NameServer:$INSTALL_DIR/bin/mqnamesrv -n $IP:9876 > /dev/null 2>&1 &"
  nohup "$INSTALL_DIR/bin/mqnamesrv" -n "$IP:9876" > /dev/null 2>&1 &
}

start_broker() {
  local BROKER_CONF=$1
  local AUTO_CREATE_TOPIC_ENABLE=$2
  
  # 确保配置文件存在
  [ ! -f "$BROKER_CONF" ] && echo "错误: Broker配置文件不存在: $BROKER_CONF" && return 1
  
  setup_jdk11 "$INSTALL_DIR/bin/mqbroker"
  setup_jdk11 "$INSTALL_DIR/bin/runbroker.sh"
  
  echo "启动 Broker: $BROKER_CONF"
  nohup sh "$INSTALL_DIR/bin/mqbroker" -c "$BROKER_CONF" autoCreateTopicEnable="$AUTO_CREATE_TOPIC_ENABLE" > /dev/null 2>&1 &
}

stop_processes() {
  echo "停止 NameServer 和 Broker 进程"
  pkill -f mqnamesrv 2>/dev/null || true
  pkill -f mqbroker 2>/dev/null || true
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
  return $?
}

# 检查 SSH 连接是否可达
check_ssh_reachable() {
  local IP=$1
  local USER=$2
  ssh -o ConnectTimeout=5 -T "$USER@$IP" exit &> /dev/null
  return $?
}

# 同步配置文件和 bin 目录到远程主机
sync_to_remote() {
  local REMOTE_HOST=$1
  local REMOTE_USER=$2
  echo "同步目录到远程主机: $REMOTE_USER@$REMOTE_HOST:$INSTALL_DIR"
  # 使用更安全的同步方式，不直接删除
  rsync -av "$INSTALL_DIR/" "$REMOTE_USER@$REMOTE_HOST:$INSTALL_DIR/" || {
    echo "远程同步失败"
    return 1
  }
}

# 在远程主机上启动服务
start_remote_namesrv() {
  local REMOTE_HOST=$1
  local REMOTE_USER=$2
  echo "启动远程主机上的 NameServer 服务"
  ssh "$REMOTE_USER@$REMOTE_HOST" "nohup $INSTALL_DIR/bin/mqnamesrv -n $REMOTE_HOST:9876 > /dev/null 2>&1 &"
}

start_remote_broker() {
  local REMOTE_HOST=$1
  local REMOTE_USER=$2
  local BROKER_CONF=$3
  echo "启动远程主机上的 Broker 服务: $BROKER_CONF"
  ssh "$REMOTE_USER@$REMOTE_HOST" "nohup $INSTALL_DIR/bin/mqbroker -c \"$BROKER_CONF\" autoCreateTopicEnable=true > /dev/null 2>&1 &"
}

# 检查必要工具
check_tools

# 检查是否已启动
check_running_processes

echo "选择模式："
echo "1、2m-noslave(多Master无Slave模式)"
echo "2、2m-2s-async(多Master多Slave异步复制模式)"
echo "3、2m-2s-sync(多Master多Slave同步复制模式)"
read -p "输入数字选择模式(开发环境推荐2m-noslave,生产环境推荐2m-2s-async) > " MODE
MODE=${MODE:-1}

# 验证模式输入
if [[ ! "$MODE" =~ ^[1-3]$ ]]; then
  echo "无效模式，使用默认模式1"
  MODE=1
fi

NAMESRV_IP=""
USERNAME=""

while true; do
  read -p "输入另外一台namesrv的ip (非本机IP，直接回车跳过) > " NAMESRV_IP
  if [ -z "$NAMESRV_IP" ]; then
    echo "单机部署模式"
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
    
    # 创建基础配置文件（如果不存在）
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-a.properties" ] && cp "$CONF_DIR/broker.conf" "$CONF_DIR/$CONF_SUBDIR/broker-a.properties" 2>/dev/null || touch "$CONF_DIR/$CONF_SUBDIR/broker-a.properties"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-b.properties" ] && cp "$CONF_DIR/broker.conf" "$CONF_DIR/$CONF_SUBDIR/broker-b.properties" 2>/dev/null || touch "$CONF_DIR/$CONF_SUBDIR/broker-b.properties"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-a.conf" ] && echo "# broker-a 配置" > "$CONF_DIR/$CONF_SUBDIR/broker-a.conf"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-b.conf" ] && echo "# broker-b 配置" > "$CONF_DIR/$CONF_SUBDIR/broker-b.conf"
    
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
      start_remote_namesrv "$NAMESRV_IP" "$USERNAME"
      start_remote_broker "$NAMESRV_IP" "$USERNAME" "$CONF_DIR/$CONF_SUBDIR/broker-b.conf"
    fi

    ;;
  2|3)
    CONF_SUBDIR=$( [ $MODE -eq 2 ] && echo "2m-2s-async" || echo "2m-2s-sync" )
    mkdir -p "$CONF_DIR/$CONF_SUBDIR"
    read -p "输入a或b选择broker > " BROKER
    
    # 验证broker输入
    if [[ ! "$BROKER" =~ ^[ab]$ ]]; then
      echo "无效选择，使用默认值 a"
      BROKER="a"
    fi
    
    # 创建基础配置文件（如果不存在）
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.properties" ] && cp "$CONF_DIR/broker.conf" "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.properties" 2>/dev/null || touch "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.properties"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.properties" ] && cp "$CONF_DIR/broker.conf" "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.properties" 2>/dev/null || touch "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.properties"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.conf" ] && echo "# broker-$BROKER 配置" > "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER.conf"
    [ ! -f "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.conf" ] && echo "# broker-$BROKER-s 配置" > "$CONF_DIR/$CONF_SUBDIR/broker-$BROKER-s.conf"
    
    modify_conf "$IP" "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER.properties" 10911
    modify_conf "$IP" "$CONF_DIR/$CONF_SUBDIR" "broker-$BROKER-s.properties" 10912
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

echo "等待服务启动..."
sleep 3

echo "显示正在运行的 NameServer 和 Broker 进程"
ps -ef | grep -E "namesrv|broker" | grep -v grep
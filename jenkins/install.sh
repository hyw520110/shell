#!/bin/bash

# 配置变量
JENKINS_URL="https://get.jenkins.io/war-stable/2.319.1/jenkins.war"
DOWNLOAD_DIR="/opt/jenkins"
JENKINS_HOME="/var/lib/jenkins"
JENKINS_USER="jenkins"
JAVA_VERSION="17"
IP=$(/opt/shell/ip.sh)

# 检测操作系统
detect_os() {
  if command -v apt > /dev/null; then
    OS="Debian"
  elif command -v yum > /dev/null; then
    OS="CentOS"
  else
    echo "不支持的操作系统"
    exit 1
  fi
}

install_java17(){
  case $OS in
    Debian)
      sudo apt update
      sudo apt install -y openjdk-17-jdk
      ;;
    CentOS)
      sudo yum update -y
      sudo yum install -y java-17-openjdk-devel
      ;;
  esac
}

get_java17_path(){
  update-alternatives --list java | grep 'java-17'
}

# 检测 8080 端口是否被占用
check_port_occupied() {
  if netstat -tuln | grep :8080 > /dev/null; then
    echo "8080 端口已被占用"
    exit 1
  fi
}

# 安装依赖项
install_dependencies() {
  case $OS in
    Debian)
      sudo apt update
      sudo apt install -y curl
      ;;
    CentOS)
      sudo yum update -y
      sudo yum install -y curl
      ;;
  esac
}

# 检查依赖项是否已安装
check_dependencies_installed() {
  if ! command -v curl > /dev/null; then
    install_dependencies
  fi
}

# 创建 Jenkins 用户
create_jenkins_user() {
  if ! id -u $JENKINS_USER > /dev/null 2>&1; then
    sudo useradd -r -d $JENKINS_HOME -s /bin/false $JENKINS_USER
  else
    echo "用户$JENKINS_USER已存在"
  fi
}

# 创建 JENKINS_HOME 目录
create_jenkins_home() {
  sudo mkdir -p $JENKINS_HOME
  sudo chown -R $JENKINS_USER:$JENKINS_USER $JENKINS_HOME
}

# 下载 Jenkins
download_jenkins() {
  if [ ! -f "$DOWNLOAD_DIR/jenkins.war" ]; then
    echo "下载 Jenkins"
    sudo wget -O $DOWNLOAD_DIR/jenkins.war $JENKINS_URL
  else
    echo "Jenkins 已经下载"
  fi
}

# 设置文件权限
set_file_permissions() {
  sudo chown -R $JENKINS_USER:$JENKINS_USER $DOWNLOAD_DIR
  sudo chmod -R 755 $DOWNLOAD_DIR
  sudo chown -R $JENKINS_USER:$JENKINS_USER $JENKINS_HOME
  sudo chmod -R 755 $JENKINS_HOME
}

# 配置 Jenkins 服务
configure_jenkins_service() {
  local java_path=$1
  if [[ -z "$java_path" ]]; then
    echo "JAVA_PATH 为空，无法配置 Jenkins 服务"
    exit 1
  fi
  local java_home=$(dirname $(dirname $java_path))
  sudo tee /etc/systemd/system/jenkins.service > /dev/null <<EOF
[Unit]
Description=Jenkins Continuous Integration Server
After=network.target

[Service]
User=$JENKINS_USER
Group=$JENKINS_USER
Type=simple
ExecStart=$java_path -jar $DOWNLOAD_DIR/jenkins.war --httpPort=8080
Restart=on-failure
RestartSec=10
Environment="JAVA_HOME=$java_home"
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF
}

# 启动 Jenkins 服务
start_jenkins_service() {
  sudo systemctl daemon-reload
  sudo systemctl enable jenkins
  sudo systemctl start jenkins
  if sudo systemctl is-active --quiet jenkins; then
    echo "Jenkins 服务已成功启动，访问 http://$IP:8080"
  else
    echo "Jenkins 服务启动失败"
    show_jenkins_log
  fi
}

# 检查 Jenkins 服务状态
check_jenkins_status() {
  sudo systemctl status jenkins
}

# 显示 Jenkins 日志
show_jenkins_log() {
  sudo journalctl -u jenkins -n 50
}

# 主函数
main() {
  detect_os
  JAVA_PATH=$(get_java17_path)
  [ -z "$JAVA_PATH" ] && install_java17 && JAVA_PATH=$(get_java17_path)
  if [ ! -f "$JAVA_PATH" ]; then
    echo "无法完成Java 17的检测或安装"
    exit 1
  fi
  check_port_occupied
  check_dependencies_installed
  create_jenkins_user
  create_jenkins_home
  download_jenkins
  set_file_permissions
  configure_jenkins_service "$JAVA_PATH"
  start_jenkins_service
  check_jenkins_status
}

# 执行主函数
main
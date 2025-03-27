#!/bin/bash

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "必须以root用户运行此脚本"
    exit 1
  fi
}
setup_environment() {
  local package_manager=$(command -v apt-get || command -v yum)
  [[ -z "$package_manager" ]] && echo "未知的操作系统，无法继续" && exit 1

  $package_manager update -y
  $package_manager install -y wget curl
}
 
# 安装 Grafana
install_grafana() {
  # sed -i "s/default_language = en-US/default_language = zh-Hans/" /usr/share/grafana/conf/defaults.ini
  command -v apt-get && apt-get install -y adduser libfontconfig1 musl && wget https://dl.grafana.com/oss/release/grafana_11.4.0_amd64.deb && dpkg -i grafana_11.4.0_amd64.deb
  command -v yum && yum install -y https://dl.grafana.com/oss/release/grafana-11.4.0-1.x86_64.rpm
}

# 配置并启动 Grafana 服务
configure_and_start_grafana() {
  systemctl daemon-reload
  systemctl enable grafana-server
  systemctl start grafana-server

  if systemctl is-active --quiet grafana-server; then
    echo "Grafana 服务已成功启动。"
  else
    echo "Grafana 服务启动失败，请检查日志。"
    exit 1
  fi
}

# 配置防火墙规则（仅限于使用 firewalld 的系统）
configure_firewall() {
  if command -v firewall-cmd > /dev/null 2>&1; then
    firewall-cmd --zone=public --add-port=3000/tcp --permanent
    firewall-cmd --reload
    echo "防火墙已配置为允许端口 3000 的流量。"
  else
    echo "未检测到 firewalld 或不需要配置防火墙。"
  fi
}

main() {
  check_root
  setup_environment
  add_grafana_repo
  install_grafana
  configure_and_start_grafana
  configure_firewall
  echo "Grafana 安装完成！默认可以通过 http://<服务器IP>:3000 访问，默认用户名和密码均为 'admin'。"
}

main
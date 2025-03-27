#!/bin/bash

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

# 提取常用变量
DOWNLOAD_DIR="/opt/softs"
PROMETHEUS_VERSION=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep -Po '"tag_name": "\K(.*)(?=")')
GRAFANA_VERSION=$(curl -s https://api.github.com/repos/grafana/grafana/releases/latest | grep -Po '"tag_name": "\K(.*)(?=")')
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K(.*)(?=")')
PROMETHEUS_URL="https://github.com/prometheus/prometheus/releases/download/${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
GRAFANA_URL="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz"
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"

# 创建下载目录
mkdir -p ${DOWNLOAD_DIR}

# 选择安装模式
echo "选择安装模式："
echo "1、Docker Compose"
echo "2、主机安装"
read -t 5 -n 1 -p "输入数字选择模式（默认为主机安装）> " MODE

# 如果用户没有在5秒内输入，设置默认值
if [ -z "$MODE" ]; then
  MODE=2
fi

# 安装依赖
install_dependencies() {
  case $(uname -s) in
    Linux)
      if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y curl wget
      elif [ -f /etc/redhat-release ]; then
        yum update -y
        yum install -y curl wget
      fi
      ;;
    *)
      echo "不支持的操作系统"
      exit 1
      ;;
  esac
}

# Docker Compose 模式
install_docker_compose() {
  # 安装 Docker
  if ! command -v docker &> /dev/null; then
    echo "安装 Docker..."
    case $(uname -s) in
      Linux)
        if [ -f /etc/debian_version ]; then
          curl -fsSL https://get.docker.com -o ${DOWNLOAD_DIR}/get-docker.sh
          sh ${DOWNLOAD_DIR}/get-docker.sh
          systemctl start docker
          systemctl enable docker
        elif [ -f /etc/redhat-release ]; then
          yum install -y docker
          systemctl start docker
          systemctl enable docker
        fi
        ;;
      *)
        echo "不支持的操作系统"
        exit 1
        ;;
    esac
  fi

  # 安装 Docker Compose
  if ! command -v docker-compose &> /dev/null; then
    echo "安装 Docker Compose..."
    curl -L "${DOCKER_COMPOSE_URL}" -o ${DOWNLOAD_DIR}/docker-compose
    chmod +x ${DOWNLOAD_DIR}/docker-compose
    mv ${DOWNLOAD_DIR}/docker-compose /usr/local/bin/docker-compose
  fi

  # 创建 Docker Compose 文件
  cat <<EOF > docker-compose.yml
version: '3'
services:
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
    restart: always

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    volumes:
      - ./grafana/data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    restart: always
EOF

  # 创建 Prometheus 配置文件
  mkdir -p prometheus
  cat <<EOF > prometheus/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'spring-boot-app'
    static_configs:
      - targets: ['your-spring-boot-app-host:8080']
EOF

  # 启动 Docker Compose
  docker-compose up -d
}

# 主机安装模式
install_host() {
  # 下载 Prometheus
  if [ ! -f "${DOWNLOAD_DIR}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" ]; then
    wget -O "${DOWNLOAD_DIR}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" "${PROMETHEUS_URL}"
  fi

  # 安装 Prometheus
  tar xvfz "${DOWNLOAD_DIR}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -C ${DOWNLOAD_DIR}
  mv ${DOWNLOAD_DIR}/prometheus-${PROMETHEUS_VERSION}.linux-amd64 /opt/prometheus
  ln -s /opt/prometheus/prometheus /usr/local/bin/prometheus
  ln -s /opt/prometheus/promtool /usr/local/bin/promtool

  # 创建 Prometheus 配置文件
  mkdir -p /etc/prometheus
  cat <<EOF > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'spring-boot-app'
    static_configs:
      - targets: ['your-spring-boot-app-host:8080']
EOF

  # 创建 Prometheus 服务
  cat <<EOF > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file /etc/prometheus/prometheus.yml \
    --storage.tsdb.path /var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

  useradd --no-create-home --shell /bin/false prometheus
  mkdir -p /var/lib/prometheus
  chown prometheus:prometheus /var/lib/prometheus
  chown -R prometheus:prometheus /etc/prometheus
  systemctl daemon-reload
  systemctl start prometheus
  systemctl enable prometheus

  # 下载 Grafana
  if [ ! -f "${DOWNLOAD_DIR}/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz" ]; then
    wget -O "${DOWNLOAD_DIR}/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz" "${GRAFANA_URL}"
  fi

  # 安装 Grafana
  tar xvfz "${DOWNLOAD_DIR}/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz" -C ${DOWNLOAD_DIR}
  mv ${DOWNLOAD_DIR}/grafana-${GRAFANA_VERSION} /opt/grafana
  ln -s /opt/grafana/bin/grafana-server /usr/local/bin/grafana-server

  # 创建 Grafana 服务
  cat <<EOF > /etc/systemd/system/grafana.service
[Unit]
Description=Grafana
After=network.target

[Service]
User=grafana
Group=grafana
ExecStart=/usr/local/bin/grafana-server \
    -config /opt/grafana/conf/defaults.ini \
    -homepath /opt/grafana

[Install]
WantedBy=multi-user.target
EOF

  useradd --no-create-home --shell /bin/false grafana
  chown -R grafana:grafana /opt/grafana
  systemctl daemon-reload
  systemctl start grafana
  systemctl enable grafana
}

# 主程序
install_dependencies

case $MODE in
  1)
    install_docker_compose
    ;;
  2)
    install_host
    ;;
  *)
    echo "未知模式"
    exit 1
    ;;
esac

echo "安装完成！"

# 配置 Grafana
echo ""
echo "配置 Grafana:"
echo "1. 访问 Grafana："
echo "   打开浏览器，访问 http://localhost:3000，默认用户名和密码都是 admin。"
echo "2. 添加数据源："
echo "   导航到 Configuration -> Data Sources。"
echo "   点击 Add data source。"
echo "   选择 Prometheus。"
echo "   在 HTTP 标签页中，输入 Prometheus 的 URL（例如 http://localhost:9090）。"
echo "   点击 Save & Test。"
echo "3. 导入仪表盘："
echo "   导航到 Create -> Import。"
echo "   输入或上传一个 Prometheus 监控仪表盘的 JSON 文件（可以从 Grafana 官方库中找到）。"
echo "   选择之前添加的 Prometheus 数据源。"
echo "   点击 Import。"
echo ""
echo "测试监控："
echo "1. 启动 Spring Boot 应用："
echo "   运行你的 Spring Boot 应用，确保它正在监听 8080 端口。"
echo "2. 访问 Prometheus："
echo "   打开浏览器，访问 http://localhost:9090/targets，确保你的 Spring Boot 应用被成功抓取。"
echo "3. 查看 Grafana 仪表盘："
echo "   返回 Grafana，查看已导入的仪表盘，你应该能看到你的 Spring Boot 应用的监控数据。"
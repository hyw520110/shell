#!/bin/bash

# ==========================================
# Elasticsearch Unified Installation Script
# ==========================================

# 默认配置
INSTALL_DIR="$HOME/elasticsearch"
DOWNLOAD_DIR="$HOME/Downloads"
MODE="auto"
CLUSTER_MODE=false
TIMEOUT=8

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 解析参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -i|--install-dir) INSTALL_DIR="$2"; shift ;;
        -d|--download-dir) DOWNLOAD_DIR="$2"; shift ;;
        --mode) MODE="$2"; shift ;;
        --cluster) CLUSTER_MODE=true ;;
        -h|--help) 
            echo "用法: $0 [-i 安装目录] [-d 下载目录] [--mode docker|docker-compose|k8s|host|auto] [--cluster]"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
    shift
done

# 权限检测与提权函数
SUDO_CMD=""
check_privileges() {
    local test_dir="$1"
    mkdir -p "$test_dir" 2>/dev/null
    if [ ! -w "$test_dir" ]; then
        if command -v sudo &> /dev/null; then
            echo -e "${YELLOW}由于目录 $test_dir 权限限制，将自动使用 sudo 提权执行。${NC}"
            SUDO_CMD="sudo "
        else
            echo -e "${RED}错误: 无法写入 $test_dir 且找不到 sudo。${NC}"
            exit 1
        fi
    fi
}

# 模式自动检测
if [ "$MODE" == "auto" ]; then
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
            MODE="docker-compose"
        else
            MODE="docker"
        fi
        echo -e "${GREEN}检测到可用 Docker，自动采用模式: $MODE${NC}"
    else
        echo -e "${YELLOW}未安装 Docker 或 Docker 未启动，自动降级为主机(host)安装模式。${NC}"
        MODE="host"
    fi
fi

# 获取最新 5 个版本
get_latest_versions() {
    if command -v curl &> /dev/null; then
        VERSIONS=$(curl -s https://api.github.com/repos/elastic/elasticsearch/releases | grep '"tag_name":' | head -n 5 | awk -F'"' '{print $4}' | sed 's/^v//')
    fi
    if [ -z "$VERSIONS" ]; then
        # fallback
        VERSIONS="8.13.0\n8.12.2\n8.11.3\n7.17.20\n7.10.2"
    fi
    echo -e "$VERSIONS"
}

# --------------------------
# 主机模式 (Host Mode) 安装
# --------------------------
install_host() {
    echo -e "${GREEN}▶ 开始主机模式安装...${NC}"
    
    # 检查是否已安装
    INSTALLED=false
    if (command -v systemctl &> /dev/null && systemctl list-units --full -all | grep -Fq 'elasticsearch.service') || [ -d "$INSTALL_DIR/bin" ]; then
        INSTALLED=true
    fi
    
    if [ "$INSTALLED" = true ]; then
        echo -e "${YELLOW}检测到 Elasticsearch 已在系统中安装。${NC}"
        read -t $TIMEOUT -p "请选择: 卸载(U/uninstall) 还是 更新(Enter default)? (超时8秒默认更新): " ACTION
        ACTION=${ACTION:-update}
        
        if [[ "$ACTION" =~ ^[uU] ]]; then
            echo -e "${YELLOW}正在卸载...${NC}"
            $SUDO_CMD systemctl stop elasticsearch 2>/dev/null
            $SUDO_CMD systemctl disable elasticsearch 2>/dev/null
            $SUDO_CMD rm -f /etc/systemd/system/elasticsearch.service
            $SUDO_CMD rm -rf "$INSTALL_DIR"
            $SUDO_CMD systemctl daemon-reload 2>/dev/null
            echo -e "${GREEN}卸载完成。${NC}"
            exit 0
        else
            echo "继续执行更新流程..."
        fi
    fi
    
    echo "正在获取最新可用版本..."
    VERSIONS=$(get_latest_versions)
    i=1
    declare -a VERSION_ARRAY
    for v in $VERSIONS; do
        echo "$i) $v"
        VERSION_ARRAY[$i]=$v
        ((i++))
    done
    read -t $TIMEOUT -p "请选择需要更新/安装的版本 (1-5, 默认1, 超时8秒): " V_SEL
    V_SEL=${V_SEL:-1}
    VERSION=${VERSION_ARRAY[$V_SEL]}
    if [ -z "$VERSION" ]; then
        VERSION=${VERSION_ARRAY[1]}
    fi
    echo -e "${GREEN}已选择版本: $VERSION${NC}"
    
    # 准备下载目录
    check_privileges "$DOWNLOAD_DIR"
    $SUDO_CMD mkdir -p "$DOWNLOAD_DIR"
    
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="x86_64"; fi
    if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then ARCH="aarch64"; fi
    if [ "$OS" == "darwin" ]; then OS="darwin"; fi
    
    DOWNLOAD_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${VERSION}-${OS}-${ARCH}.tar.gz"
    TAR_FILE="$DOWNLOAD_DIR/elasticsearch-${VERSION}.tar.gz"
    
    # 下载缓存校验
    DOWNLOAD_NEEDED=true
    if [ -f "$TAR_FILE" ]; then
        echo "检测到已下载文件，正在校验完整性..."
        if tar -tzf "$TAR_FILE" >/dev/null 2>&1; then
            echo -e "${GREEN}本地安装包完整，跳过下载。${NC}"
            DOWNLOAD_NEEDED=false
        else
            echo -e "${YELLOW}包损坏，准备重新下载。${NC}"
            $SUDO_CMD rm -f "$TAR_FILE"
        fi
    fi
    
    # 智能下载 (adl优先)
    if [ "$DOWNLOAD_NEEDED" = true ]; then
        echo "开始从 $DOWNLOAD_URL 下载..."
        if command -v adl &> /dev/null; then
            $SUDO_CMD adl "$DOWNLOAD_URL" -o "$TAR_FILE"
        elif command -v wget &> /dev/null; then
            $SUDO_CMD wget -c "$DOWNLOAD_URL" -O "$TAR_FILE"
        elif command -v curl &> /dev/null; then
            $SUDO_CMD curl -L -C - "$DOWNLOAD_URL" -o "$TAR_FILE"
        else
            echo -e "${RED}找不到下载工具 (adl/wget/curl)，安装终止。${NC}"
            exit 1
        fi
    fi
    
    # 解压安装
    check_privileges "$INSTALL_DIR"
    $SUDO_CMD mkdir -p "$INSTALL_DIR"
    echo "正在解压到 $INSTALL_DIR..."
    $SUDO_CMD tar -xzf "$TAR_FILE" -C "$INSTALL_DIR" --strip-components=1
    
    # 操作系统优化
    echo "执行系统内核与文件描述符优化..."
    if [ "$OS" == "linux" ]; then
        $SUDO_CMD sysctl -w vm.max_map_count=262144
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
            echo "vm.max_map_count=262144" | $SUDO_CMD tee -a /etc/sysctl.conf
        fi
        if ! grep -q "elasticsearch" /etc/security/limits.conf 2>/dev/null; then
            echo -e "elasticsearch - nofile 65535\nelasticsearch - memlock unlimited" | $SUDO_CMD tee -a /etc/security/limits.conf
        fi
    fi
    
    # 自动化配置
    CONFIG_FILE="$INSTALL_DIR/config/elasticsearch.yml"
    echo "初始化 Elasticsearch 配置 (集群模式: $CLUSTER_MODE)..."
    if [ "$CLUSTER_MODE" = true ]; then
        $SUDO_CMD bash -c "echo 'cluster.name: es-cluster' >> $CONFIG_FILE"
        $SUDO_CMD bash -c "echo 'node.name: node-1' >> $CONFIG_FILE"
        $SUDO_CMD bash -c "echo 'discovery.seed_hosts: [\"127.0.0.1\"]' >> $CONFIG_FILE"
        $SUDO_CMD bash -c "echo 'cluster.initial_master_nodes: [\"node-1\"]' >> $CONFIG_FILE"
    else
        $SUDO_CMD bash -c "echo 'discovery.type: single-node' >> $CONFIG_FILE"
    fi
    $SUDO_CMD bash -c "echo 'network.host: 0.0.0.0' >> $CONFIG_FILE"
    $SUDO_CMD bash -c "echo 'http.cors.enabled: true' >> $CONFIG_FILE"
    $SUDO_CMD bash -c "echo 'http.cors.allow-origin: \"*\"' >> $CONFIG_FILE"
    
    # 创建服务与自启
    if [ "$OS" == "linux" ] && command -v systemctl &> /dev/null; then
        if ! id -u elasticsearch >/dev/null 2>&1; then
            $SUDO_CMD useradd -m -s /bin/bash elasticsearch
        fi
        $SUDO_CMD chown -R elasticsearch:elasticsearch "$INSTALL_DIR"
        
        echo "注册 systemd 系统服务..."
        cat <<EOF | $SUDO_CMD tee /etc/systemd/system/elasticsearch.service
[Unit]
Description=Elasticsearch
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=elasticsearch
Group=elasticsearch
ExecStart=$INSTALL_DIR/bin/elasticsearch
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
        $SUDO_CMD systemctl daemon-reload
        $SUDO_CMD systemctl enable elasticsearch.service
        $SUDO_CMD systemctl start elasticsearch.service
        echo -e "${GREEN}Elasticsearch 主机服务已成功启动！${NC}"
    else
        echo -e "${YELLOW}未检测到 Systemd（可能为 macOS/其他 Unix）。您可以手动运行: $INSTALL_DIR/bin/elasticsearch${NC}"
    fi
}

# --------------------------
# Docker 模式安装
# --------------------------
install_docker() {
    echo -e "${GREEN}▶ 开始 Docker/Docker-Compose 模式启动...${NC}"
    if [ "$MODE" == "docker-compose" ]; then
        if [ "$CLUSTER_MODE" = true ]; then
            echo "启动 docker-compose.yml (集群配置)..."
            docker-compose -f docker-compose.yml up -d
        else
            echo "启动 single.yml (单节点配置)..."
            docker-compose -f single.yml up -d
        fi
    else
        echo "使用原生 docker 运行单节点..."
        docker run -d --name elasticsearch \
            -p 9200:9200 -p 9300:9300 \
            -e "discovery.type=single-node" \
            -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
            elasticsearch:7.10.1
    fi
}

# --------------------------
# K8s 模式安装
# --------------------------
install_k8s() {
    echo -e "${GREEN}▶ 开始 Kubernetes 模式安装...${NC}"
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}未检测到 helm 工具，K8s 安装失败。${NC}"
        exit 1
    fi
    echo "使用 Helm 部署 Elastic 原生 Chart..."
    helm repo add elastic https://helm.elastic.co
    helm repo update
    if [ "$CLUSTER_MODE" = true ]; then
        # 默认集群配置
        helm install elasticsearch elastic/elasticsearch
    else
        helm install elasticsearch elastic/elasticsearch --set replicas=1 --set minimumMasterNodes=1
    fi
    echo -e "${GREEN}K8s 部署指令已下发！${NC}"
}

# ==========================
# 核心执行分发
# ==========================
case $MODE in
    host) install_host ;;
    docker|docker-compose) install_docker ;;
    k8s) install_k8s ;;
    *) echo "未知模式，请检查参数。"; exit 1 ;;
esac

echo -e "${GREEN}🎉 流程执行完毕！${NC}"

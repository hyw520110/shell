#!/bin/bash

# ELK Stack 一键安装配置脚本
# ELK 是 Elasticsearch、Logstash、Kibana 的简称，用于日志收集、分析和可视化
# 可选组件：Filebeat（轻量级日志采集器）、Metricbeat（指标采集器）
# 支持 Docker Compose 和主机两种安装模式

set -e
set -u
set -o pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly ELK_VERSION="8.11.1"
readonly ELASTICSEARCH_IMAGE="docker.elastic.co/elasticsearch/elasticsearch"
readonly LOGSTASH_IMAGE="docker.elastic.co/logstash/logstash"
readonly KIBANA_IMAGE="docker.elastic.co/kibana/kibana"
readonly FILEBEAT_IMAGE="docker.elastic.co/beats/filebeat"
readonly DEFAULT_INSTALL_DIR="$HOME/elk"
readonly DEFAULT_ES_PORT=9200
readonly DEFAULT_KIBANA_PORT=5601
readonly DEFAULT_LS_HTTP_PORT=5044
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
ES_PORT="$DEFAULT_ES_PORT"
KIBANA_PORT="$DEFAULT_KIBANA_PORT"
LS_HTTP_PORT="$DEFAULT_LS_HTTP_PORT"
INSTALL_MODE="auto"  # auto, docker, host
INSTALL_COMPONENTS="elk"  # elk, elk+filebeat, elk+metricbeat
MEMORY_LOCK="false"
AUTO_START=false
ASSUME_YES=false
DRY_RUN=false
UNINSTALL_MODE=false
ES_PASSWORD="elastic123"  # Elasticsearch 内置用户密码

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 检查/获取 root 权限
require_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            print_info "需要 root 权限，正在提权..."
            exec sudo "$0" "$@"
        else
            print_error "需要 root 权限但 sudo 不可用"
            exit 1
        fi
    fi
}

# 以 sudo 运行需要权限的单条命令（非 root 用户自动加 sudo 前缀）
run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        print_error "需要 root 权限但 sudo 不可用"
        return 1
    fi
}

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local filename
    local adl_path

    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"
    mkdir -p "$output_dir"

    if adl_path="$(find_adl)"; then
        print_info "检测到可用 adl，优先使用 adl 下载: $filename"
        if "$adl_path" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        print_warning "adl 下载失败，回退 curl/wget: $filename"
    fi

    if command -v curl &> /dev/null; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget &> /dev/null; then
        wget -O "$output" "$url"
    else
        print_error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
ELK Stack 一键安装配置脚本

ELK 是 Elasticsearch、Logstash、Kibana 的简称，用于日志收集、分析和可视化。
- Elasticsearch: 分布式搜索和分析引擎
- Logstash: 服务器端数据处理管道
- Kibana: Elasticsearch 的数据可视化和管理界面
- Filebeat: 轻量级日志采集器（可选）
- Metricbeat: 指标采集器（可选）

用法：./bin/install-elk.sh [选项]

选项:
    -h, --help                      显示此帮助信息
    -d, --dir DIR                   安装目录 (默认：/data/elk)
    --es-port PORT                  Elasticsearch 端口 (默认：9200)
    --kibana-port PORT              Kibana 端口 (默认：5601)
    --ls-port PORT                  Logstash HTTP 端口 (默认：5044)
    --version VERSION               ELK 版本 (默认：8.11.1)
    --es-password PWD               Elasticsearch 密码 (默认：elastic123)
    --components COMPS              安装组件 (elk|elk+filebeat|elk+metricbeat，默认：elk)
    --memory-lock                   锁定内存 (提升 ES 性能，需要足够内存)
    --mode MODE                     安装模式 (auto|docker|host，默认：auto)
    --auto-start                    配置自启动服务
    -y, --yes                       跳过交互确认（自动化部署用）
    --dry-run                       试运行模式（不实际安装）
    --uninstall                     卸载 ELK

示例:
    # Docker 模式（推荐）
    ./bin/install-elk.sh
    
    # 指定端口和组件
    ./bin/install-elk.sh --es-port 9200 --kibana-port 5601 --components elk+filebeat
    
    # 主机模式安装（需要预先安装 Java）
    ./bin/install-elk.sh --mode host
    
    # 配置自启动
    ./bin/install-elk.sh --auto-start
    
    # 卸载
    ./bin/install-elk.sh --uninstall

使用指南:
    Docker 模式:
    1. 启动：cd $INSTALL_DIR && docker compose up -d
    2. 访问 ES: http://localhost:9200 (账号：elastic, 密码：见安装输出)
    3. 访问 Kibana: http://localhost:5601 (账号：elastic, 密码：见安装输出)
    
    主机模式:
    1. 启动：systemctl start elasticsearch / systemctl start logstash / systemctl start kibana
    2. 访问 ES: http://localhost:9200
    3. 访问 Kibana: http://localhost:5601

更多信息：https://www.elastic.co/elastic-stack
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --es-port)
                ES_PORT="$2"
                shift 2
                ;;
            --kibana-port)
                KIBANA_PORT="$2"
                shift 2
                ;;
            --ls-port)
                LS_HTTP_PORT="$2"
                shift 2
                ;;
            --version)
                ELK_VERSION="$2"
                shift 2
                ;;
            --es-password)
                ES_PASSWORD="$2"
                shift 2
                ;;
            --components)
                INSTALL_COMPONENTS="$2"
                shift 2
                ;;
            --memory-lock)
                MEMORY_LOCK="true"
                shift
                ;;
            --mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --auto-start)
                AUTO_START=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            *)
                print_error "未知选项：$1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查是否安装 Docker ===
check_docker() {
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"
    
    # 确定安装模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if check_docker; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，使用 Docker Compose 模式安装"
        else
            INSTALL_MODE="host"
            print_info "未检测到 Docker，使用主机模式安装"
        fi
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # 检查 Docker
        if ! check_docker; then
            print_error "Docker 未安装或无法运行"
            exit 1
        fi
        
        # 检查 Docker Compose
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            print_error "Docker Compose 未安装"
            exit 1
        fi
        
        # 检查内存（ES 建议至少 2GB）
        if command -v free &> /dev/null; then
            local total_mem
            total_mem=$(free -m | awk '/^Mem:/{print $2}')
            if [[ "$total_mem" -lt 2048 ]]; then
                print_warning "总内存不足 2GB (${total_mem}MB)，可能影响 Elasticsearch 运行"
            fi
        fi
        
        print_success "Docker 环境检查通过"
        
        # 检查端口占用
        if command -v lsof &> /dev/null; then
            if lsof -i :"$ES_PORT" &> /dev/null; then
                print_warning "端口 $ES_PORT 已被占用"
            fi
            if lsof -i :"$KIBANA_PORT" &> /dev/null; then
                print_warning "端口 $KIBANA_PORT 已被占用"
            fi
        fi
    else
        # 主机模式检查（不强制 root，需要权限的操作用 sudo 处理）
        # 检查 Java（ES 需要 Java 11+）
        if ! command -v java &> /dev/null; then
            print_error "Java 未安装，请先安装 JDK 11+"
            exit 1
        fi

        local java_version
        java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [[ "$java_version" -lt 11 ]]; then
            print_error "Java 版本过低 (${java_version})，需要 JDK 11+"
            exit 1
        fi

        # 检查 sudo 可用性（用于 useradd/systemd 等操作）
        if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
            print_info "主机模式部分操作需要 sudo 权限（创建用户、配置 systemd）"
        fi

        print_success "主机模式环境检查通过 (Java: $(java -version 2>&1 | head -1))"
    fi
}

# === 创建安装目录 ===
create_directories() {
    print_header "创建安装目录"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建目录：$INSTALL_DIR"
        return
    fi
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        mkdir -p "$INSTALL_DIR"/{data/{elasticsearch,logstash,kibana,filebeat},logs/{elasticsearch,logstash,kibana,filebeat},config/{elasticsearch,logstash,kibana,filebeat},bin}
    else
        mkdir -p "$INSTALL_DIR"/{data/{elasticsearch,logstash,kibana},logs/{elasticsearch,logstash,kibana},config/{elasticsearch,logstash,kibana},bin}
    fi
    
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === Docker Compose 模式安装 ===
docker_install() {
    print_header "Docker Compose 模式安装"
    
    # 创建 docker-compose.yml
    create_docker_compose
    
    # 创建配置文件
    create_es_config
    create_logstash_config
    create_kibana_config
    
    # 创建启动脚本
    create_startup_script
    
    # 创建停止脚本
    create_stop_script
    
    # 创建状态脚本
    create_status_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ -t 0 ]]; then
            print_info "是否立即启动 ELK？(y/N)"
            read -r -p "> " start_now
            if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
                start_docker_service
                
                if [[ "$AUTO_START" == "true" ]]; then
                    configure_docker_autostart
                fi
            fi
        else
            print_info "非交互模式，跳过启动确认"
        fi
    fi
}

# === 创建 Docker Compose 文件 ===
create_docker_compose() {
    print_header "创建 Docker Compose 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 docker-compose.yml"
        return
    fi
    
    local memory_lock_config=""
    if [[ "$MEMORY_LOCK" == "true" ]]; then
        memory_lock_config="    memlock: -1"
    fi
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  elasticsearch:
    image: ${ELASTICSEARCH_IMAGE}:${ELK_VERSION}
    container_name: elasticsearch
    hostname: elasticsearch
    environment:
      - node.name=es01
      - cluster.name=es-cluster
      - discovery.type=single-node
      - bootstrap.memory_lock=${MEMORY_LOCK}
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - ELASTIC_PASSWORD=${ES_PASSWORD}
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
      - ./logs/elasticsearch:/usr/share/elasticsearch/logs
      - ./config/elasticsearch/elasticsearch.yml:/usr/share/elasticsearch/config/elasticsearch.yml
    ports:
      - "${ES_PORT}:9200"
    networks:
      - elk-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -E '(green|yellow)'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  logstash:
    image: ${LOGSTASH_IMAGE}:${ELK_VERSION}
    container_name: logstash
    hostname: logstash
    environment:
      - "LS_JAVA_OPTS=-Xms256m -Xmx256m"
    volumes:
      - ./data/logstash:/usr/share/logstash/data
      - ./logs/logstash:/usr/share/logstash/logs
      - ./config/logstash/logstash.yml:/usr/share/logstash/config/logstash.yml
      - ./config/logstash/pipeline:/usr/share/logstash/pipeline
    ports:
      - "${LS_HTTP_PORT}:5044"
      - "9600:9600"
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - elk-network
    restart: unless-stopped

  kibana:
    image: ${KIBANA_IMAGE}:${ELK_VERSION}
    container_name: kibana
    hostname: kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - ELASTICSEARCH_USERNAME=elastic
      - ELASTICSEARCH_PASSWORD=${ES_PASSWORD}
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
    volumes:
      - ./data/kibana:/usr/share/kibana/data
      - ./logs/kibana:/usr/share/kibana/logs
      - ./config/kibana/kibana.yml:/usr/share/kibana/config/kibana.yml
    ports:
      - "${KIBANA_PORT}:5601"
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - elk-network
    restart: unless-stopped
EOF

    # 如果包含 Filebeat
    if [[ "$INSTALL_COMPONENTS" == *"filebeat"* ]]; then
        cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << 'EOF'

  filebeat:
    image: ${FILEBEAT_IMAGE}:${ELK_VERSION}
    container_name: filebeat
    hostname: filebeat
    user: root
    volumes:
      - ./config/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      logstash:
        condition: service_started
    networks:
      - elk-network
    restart: unless-stopped
EOF
    fi
    
    cat >> "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << 'EOF'

networks:
  elk-network:
    driver: bridge
EOF
    
    # 创建 .env 文件
    cat > "$INSTALL_DIR/.env" << EOF
ELK_VERSION=${ELK_VERSION}
ES_PORT=${ES_PORT}
KIBANA_PORT=${KIBANA_PORT}
LS_HTTP_PORT=${LS_HTTP_PORT}
ES_PASSWORD=${ES_PASSWORD}
MEMORY_LOCK=${MEMORY_LOCK}
EOF
    
    print_success "Docker Compose 文件创建完成"
}

# === 创建 Elasticsearch 配置文件 ===
create_es_config() {
    print_header "创建 Elasticsearch 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 ES 配置"
        return
    fi
    
    cat > "$INSTALL_DIR/config/elasticsearch/elasticsearch.yml" << 'EOF'
cluster.name: es-cluster
node.name: es01
path.data: /usr/share/elasticsearch/data
path.logs: /usr/share/elasticsearch/logs
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
EOF
    
    print_success "Elasticsearch 配置文件创建完成"
}

# === 创建 Logstash 配置文件 ===
create_logstash_config() {
    print_header "创建 Logstash 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 Logstash 配置"
        return
    fi
    
    # logstash.yml
    cat > "$INSTALL_DIR/config/logstash/logstash.yml" << 'EOF'
http.host: "0.0.0.0"
path.logs: /usr/share/logstash/logs
pipeline.workers: 2
pipeline.batch.size: 125
pipeline.batch.delay: 50
EOF
    
    # pipeline 目录
    mkdir -p "$INSTALL_DIR/config/logstash/pipeline"
    
    # 默认 pipeline 配置
    cat > "$INSTALL_DIR/config/logstash/pipeline/logstash.conf" << 'EOF'
input {
  beats {
    port => 5044
  }
  tcp {
    port => 5000
    codec => json_lines
  }
}

filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "%{SYSLOGTIMESTAMP:syslog_timestamp} %{SYSLOGHOST:syslog_hostname} %{DATA:syslog_program}(?:\[%{POSINT:syslog_pid}\])?: %{GREEDYDATA:syslog_message}" }
    }
    date {
      match => [ "syslog_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    user => "elastic"
    password => "${ES_PASSWORD}"
    index => "logs-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }
}
EOF
    
    print_success "Logstash 配置文件创建完成"
}

# === 创建 Kibana 配置文件 ===
create_kibana_config() {
    print_header "创建 Kibana 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 Kibana 配置"
        return
    fi
    
    cat > "$INSTALL_DIR/config/kibana/kibana.yml" << 'EOF'
server.port: 5601
server.host: "0.0.0.0"
server.name: "kibana"
elasticsearch.hosts: ["http://elasticsearch:9200"]
elasticsearch.username: "elastic"
elasticsearch.password: "${ES_PASSWORD}"
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
i18n.locale: "zh-CN"
EOF
    
    print_success "Kibana 配置文件创建完成"
}

# === 创建 Filebeat 配置文件 ===
create_filebeat_config() {
    if [[ "$INSTALL_COMPONENTS" != *"filebeat"* ]]; then
        return
    fi
    
    print_header "创建 Filebeat 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 Filebeat 配置"
        return
    fi
    
    mkdir -p "$INSTALL_DIR/config/filebeat"
    
    cat > "$INSTALL_DIR/config/filebeat/filebeat.yml" << 'EOF'
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/*.log
      - /var/log/syslog
    fields:
      log_type: system

  - type: container
    enabled: true
    paths:
      - /var/lib/docker/containers/*/*.log
    processors:
      - add_kubernetes_metadata:
          host: ${NODE_NAME}
          matchers:
            - logs_path:
                logs_path: "/var/lib/docker/containers/"

output.logstash:
  hosts: ["logstash:5044"]

processors:
  - add_host_metadata: ~
  - add_cloud_metadata: ~
EOF
    
    print_success "Filebeat 配置文件创建完成"
}

# === 创建启动脚本 ===
create_startup_script() {
    print_header "创建启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/startup.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/startup.sh" << 'EOF'
#!/bin/bash

# ELK 启动脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

# 检查 Docker 是否运行
if ! docker info &> /dev/null; then
    echo "错误：Docker 服务未运行"
    exit 1
fi

# 检查 docker-compose.yml 是否存在
if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
    echo "错误：docker-compose.yml 不存在"
    exit 1
fi

echo "正在启动 ELK Stack..."
echo "首次启动可能需要 3-5 分钟，请耐心等待..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "等待服务启动..."
sleep 30

# 检查服务状态
echo "检查服务状态..."
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "ELK 启动完成！"
echo "Elasticsearch: http://localhost:9200 (账号：elastic, 密码：见安装输出)"
echo "Kibana: http://localhost:5601 (账号：elastic, 密码：见安装输出)"
echo "查看日志：docker-compose logs -f elasticsearch"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    print_success "启动脚本创建完成"
}

# === 创建停止脚本 ===
create_stop_script() {
    print_header "创建停止脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/stop.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

# ELK 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"

echo "正在停止 ELK Stack..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "ELK 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    print_success "停止脚本创建完成"
}

# === 创建状态检查脚本 ===
create_status_script() {
    print_header "创建状态检查脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/status.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/status.sh" << 'EOF'
#!/bin/bash

# ELK 状态检查脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

cd "$INSTALL_DIR"

echo "=== ELK 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== Elasticsearch 集群状态 ==="
curl -s -u elastic:${ES_PASSWORD:-elastic123} "http://localhost:${ES_PORT:-9200}/_cluster/health?pretty" 2>/dev/null || echo "无法连接 Elasticsearch"

echo ""
echo "=== 资源使用 ==="
docker stats --no-stream elasticsearch logstash kibana 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20 elasticsearch
else
    docker-compose logs --tail=20 elasticsearch
fi

echo ""
echo "=== 数据目录大小 ==="
du -sh "$INSTALL_DIR/data" 2>/dev/null || echo "无法获取数据目录大小"
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 启动 Docker 服务 ===
start_docker_service() {
    print_header "启动 ELK 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 ELK 服务"
        return
    fi
    
    cd "$INSTALL_DIR"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动（首次启动约需 3-5 分钟）..."
    sleep 60
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    # 等待 ES 就绪
    print_info "等待 Elasticsearch 就绪..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -u elastic:"$ES_PASSWORD" "http://localhost:$ES_PORT/_cluster/health" | grep -q '"status":"green"\|"status":"yellow"'; then
            print_success "Elasticsearch 已就绪"
            break
        fi
        sleep 5
        ((attempt++))
        print_info "等待中... ($attempt/$max_attempts)"
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        print_warning "Elasticsearch 可能还未完全启动，请稍后查看日志"
    fi
    
    print_success "ELK 服务已启动"
}

# === 配置 Docker 自启动 ===
configure_docker_autostart() {
    print_header "配置 Docker 自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    if [[ ! -f /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi
    
    local SERVICE_FILE="/etc/systemd/system/elk.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "ELK systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=ELK Stack (Elasticsearch, Logstash, Kibana)
Documentation=https://www.elastic.co/elastic-stack
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
TimeoutStartSec=600
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用：sudo systemctl enable elk"
        print_info "启动：sudo systemctl start elk"
        print_info "查看状态：sudo systemctl status elk"
    fi
}

# === 主机模式安装 ===
host_install() {
    print_header "主机模式安装"
    
    print_warning "主机模式安装较为复杂，需要手动配置多个组件"
    print_info "推荐使用 Docker Compose 模式安装"
    print_info "如需继续，请确保已安装：JDK 11+, 系统参数已优化"

    if [[ "$ASSUME_YES" != "true" ]]; then
        read -p "是否继续主机模式安装？(y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "取消安装"
            exit 0
        fi
    fi
    
    # 检查依赖
    check_host_dependencies
    
    # 下载并安装 Elasticsearch
    install_elasticsearch
    
    # 下载并安装 Logstash
    install_logstash
    
    # 下载并安装 Kibana
    install_kibana
    
    # 创建启动脚本
    create_host_startup_script
    
    # 配置自启动（如果选择）
    if [[ "$AUTO_START" == "true" ]]; then
        configure_host_autostart
    fi
}

# === 检查主机依赖 ===
check_host_dependencies() {
    print_info "检查主机依赖..."
    
    # 检查 Java
    if ! command -v java &> /dev/null; then
        print_error "Java 未安装"
        exit 1
    fi
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        print_error "curl 未安装"
        exit 1
    fi
    
    print_success "依赖检查通过"
}

# === 安装 Elasticsearch ===
install_elasticsearch() {
    print_info "安装 Elasticsearch..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载并安装 Elasticsearch $ELK_VERSION"
        return
    fi
    
    local ES_HOME="$INSTALL_DIR/elasticsearch"
    mkdir -p "$ES_HOME"
    
    # 下载
    print_info "下载 Elasticsearch..."
    local es_archive="$DOWNLOAD_DIR/elasticsearch-${ELK_VERSION}-linux-x86_64.tar.gz"
    download_file "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ELK_VERSION}-linux-x86_64.tar.gz" "$es_archive"
    tar -xzf "$es_archive" -C "$ES_HOME"
    cd "$ES_HOME"
    mv elasticsearch-*/* .
    rm -rf elasticsearch-*.tar.gz elasticsearch-*/
    
    # 配置
    cat > "$ES_HOME/config/elasticsearch.yml" << EOF
cluster.name: es-cluster
node.name: es01
path.data: $INSTALL_DIR/data/elasticsearch
path.logs: $INSTALL_DIR/logs/elasticsearch
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
EOF
    
    # 创建用户
    if ! id elasticsearch &>/dev/null; then
        run_privileged useradd -r -s /bin/false elasticsearch
    fi
    run_privileged chown -R elasticsearch:elasticsearch "$ES_HOME"
    
    print_success "Elasticsearch 安装完成"
}

# === 安装 Logstash ===
install_logstash() {
    print_info "安装 Logstash..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载并安装 Logstash $ELK_VERSION"
        return
    fi
    
    local LS_HOME="$INSTALL_DIR/logstash"
    mkdir -p "$LS_HOME"
    
    # 下载
    print_info "下载 Logstash..."
    local ls_archive="$DOWNLOAD_DIR/logstash-${ELK_VERSION}-linux-x86_64.tar.gz"
    download_file "https://artifacts.elastic.co/downloads/logstash/logstash-${ELK_VERSION}-linux-x86_64.tar.gz" "$ls_archive"
    tar -xzf "$ls_archive" -C "$LS_HOME"
    cd "$LS_HOME"
    mv logstash-*/* .
    rm -rf logstash-*.tar.gz logstash-*/
    
    # 配置
    mkdir -p "$LS_HOME/pipeline"
    cat > "$LS_HOME/pipeline/logstash.conf" << EOF
input {
  beats {
    port => 5044
  }
}

output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    user => "elastic"
    password => "${ES_PASSWORD}"
    index => "logs-%{+YYYY.MM.dd}"
  }
}
EOF
    
    print_success "Logstash 安装完成"
}

# === 安装 Kibana ===
install_kibana() {
    print_info "安装 Kibana..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载并安装 Kibana $ELK_VERSION"
        return
    fi
    
    local KB_HOME="$INSTALL_DIR/kibana"
    mkdir -p "$KB_HOME"
    
    # 下载
    print_info "下载 Kibana..."
    local kb_archive="$DOWNLOAD_DIR/kibana-${ELK_VERSION}-linux-x86_64.tar.gz"
    download_file "https://artifacts.elastic.co/downloads/kibana/kibana-${ELK_VERSION}-linux-x86_64.tar.gz" "$kb_archive"
    tar -xzf "$kb_archive" -C "$KB_HOME"
    cd "$KB_HOME"
    mv kibana-*/* .
    rm -rf kibana-*.tar.gz kibana-*/
    
    # 配置
    cat > "$KB_HOME/config/kibana.yml" << EOF
server.port: ${KIBANA_PORT}
server.host: "0.0.0.0"
server.name: "kibana"
elasticsearch.hosts: ["http://localhost:${ES_PORT}"]
elasticsearch.username: "elastic"
elasticsearch.password: "${ES_PASSWORD}"
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
i18n.locale: "zh-CN"
EOF
    
    print_success "Kibana 安装完成"
}

# === 创建主机模式启动脚本 ===
create_host_startup_script() {
    print_header "创建主机模式启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建启动脚本"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/startup.sh" << EOF
#!/bin/bash

# ELK 启动脚本（主机模式）

set -e

ES_HOME="$INSTALL_DIR/elasticsearch"
LS_HOME="$INSTALL_DIR/logstash"
KB_HOME="$INSTALL_DIR/kibana"

echo "启动 Elasticsearch..."
if [[ \$EUID -eq 0 ]]; then
    su -s /bin/bash -c "\$ES_HOME/bin/elasticsearch -d" elasticsearch
else
    sudo -u elasticsearch \$ES_HOME/bin/elasticsearch -d
fi

echo "等待 Elasticsearch 启动..."
sleep 30

echo "启动 Logstash..."
\$LS_HOME/bin/logstash -f \$LS_HOME/pipeline/ &

echo "启动 Kibana..."
\$KB_HOME/bin/kibana &

echo ""
echo "ELK 启动完成！"
echo "Elasticsearch: http://localhost:${ES_PORT}"
echo "Kibana: http://localhost:${KIBANA_PORT}"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

# ELK 停止脚本（主机模式）

echo "停止 Kibana..."
pkill -f kibana || true

echo "停止 Logstash..."
pkill -f logstash || true

echo "停止 Elasticsearch..."
pkill -f elasticsearch || true

echo ""
echo "ELK 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    
    print_success "启动脚本创建完成"
}

# === 配置主机模式自启动 ===
configure_host_autostart() {
    print_header "配置主机模式自启动"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动"
        return
    fi
    
    if [[ ! -d /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi

    # Elasticsearch 服务
    cat << EOF | run_privileged tee /etc/systemd/system/elasticsearch.service > /dev/null
[Unit]
Description=Elasticsearch
After=network.target

[Service]
Type=forking
User=elasticsearch
ExecStart=$INSTALL_DIR/elasticsearch/bin/elasticsearch -d
PIDFile=$INSTALL_DIR/elasticsearch/elasticsearch.pid
LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # Logstash 服务
    cat << EOF | run_privileged tee /etc/systemd/system/logstash.service > /dev/null
[Unit]
Description=Logstash
After=network.target elasticsearch.service
Requires=elasticsearch.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/logstash/bin/logstash -f $INSTALL_DIR/logstash/pipeline/
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # Kibana 服务
    cat << EOF | run_privileged tee /etc/systemd/system/kibana.service > /dev/null
[Unit]
Description=Kibana
After=network.target elasticsearch.service
Requires=elasticsearch.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/kibana/bin/kibana
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_privileged systemctl daemon-reload

    print_success "自启动服务配置完成"
    print_info "启用：sudo systemctl enable elasticsearch logstash kibana"
    print_info "启动：sudo systemctl start elasticsearch logstash kibana"
}

# === 卸载 ELK ===
uninstall_elk() {
    print_header "卸载 ELK"
    
    print_warning "此操作将删除 ELK 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    # Docker 模式卸载
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        uninstall_docker
    else
        uninstall_host
    fi
    
    print_success "ELK 卸载完成"
}

# === 卸载 Docker 模式 ===
uninstall_docker() {
    print_info "停止 Docker 容器..."
    cd "$INSTALL_DIR"
    
    if command -v docker compose &> /dev/null; then
        docker compose down 2>/dev/null || true
    else
        docker-compose down 2>/dev/null || true
    fi
    
    # 删除容器
    docker rm -f elasticsearch logstash kibana filebeat 2>/dev/null || true
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/elk.service ]]; then
        systemctl stop elk 2>/dev/null || true
        systemctl disable elk 2>/dev/null || true
        rm -f /etc/systemd/system/elk.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

# === 卸载主机模式 ===
uninstall_host() {
    print_info "停止服务..."

    # 停止 systemd 服务
    run_privileged systemctl stop elasticsearch logstash kibana 2>/dev/null || true
    run_privileged systemctl disable elasticsearch logstash kibana 2>/dev/null || true

    # 删除服务文件
    run_privileged rm -f /etc/systemd/system/{elasticsearch,logstash,kibana}.service
    run_privileged systemctl daemon-reload 2>/dev/null || true

    # 删除用户
    run_privileged userdel elasticsearch 2>/dev/null || true

    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    cat << EOF
${GREEN}ELK Stack 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}Elasticsearch:${NC} http://localhost:${ES_PORT}
${BOLD}Kibana:${NC} http://localhost:${KIBANA_PORT}
${BOLD}Logstash:${NC} localhost:${LS_HTTP_PORT}
${BOLD}账号:${NC} elastic
${BOLD}密码:${NC} $ES_PASSWORD

${BOLD}常用命令:${NC}
EOF
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        cat << EOF
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：cd $INSTALL_DIR && docker-compose logs -f elasticsearch
EOF
    else
        cat << EOF
  启动服务：sudo systemctl start elasticsearch logstash kibana
  停止服务：sudo systemctl stop elasticsearch logstash kibana
  查看状态：sudo systemctl status elasticsearch
  查看日志：sudo journalctl -u elasticsearch -f
EOF
    fi
    
    cat << EOF

${BOLD}自启动配置:${NC}
EOF
    
    if [[ "$AUTO_START" == "true" ]]; then
        echo -e "  ${GREEN}已配置自启动服务${NC}"
    else
        echo "  未配置自启动，如需配置请运行：--auto-start"
    fi
    
    echo ""
    echo -e "${CYAN}更多信息请访问：https://www.elastic.co/elastic-stack${NC}"
}

# === 主函数 ===
main() {
    print_header "ELK Stack 安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_elk
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  Elasticsearch 端口：$ES_PORT"
    echo "  Kibana 端口：$KIBANA_PORT"
    echo "  Logstash 端口：$LS_HTTP_PORT"
    echo "  安装模式：$INSTALL_MODE"
    echo "  安装组件：$INSTALL_COMPONENTS"
    echo "  内存锁定：$MEMORY_LOCK"
    echo "  自动启动：$AUTO_START"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    create_directories
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        docker_install
        create_filebeat_config
    else
        host_install
    fi
    
    show_post_install_info
}

# 执行主函数
main "$@"

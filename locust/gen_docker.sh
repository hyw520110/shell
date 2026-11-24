#!/bin/bash
# ==============================================================================
# 生成 Docker Compose 配置文件 (基于静态 Dockerfile)
# 使用方式: ./gen_docker.sh [HOST] [WORKER_NUM]
# ==============================================================================

HOST=${1:-"https://www.baidu.com"}
WORKERS=${2:-3}
OUT_FILE="docker-compose.yml"

# 检查依赖文件
if [ ! -f "Dockerfile" ] || [ ! -f "requirements.txt" ]; then
    echo -e "\033[0;31m[ERROR] 缺少 Dockerfile 或 requirements.txt，请确保工程完整。\033[0m"
    exit 1
fi

cat <<EOF > "$OUT_FILE"
version: '3.8'

services:
  master:
    build: .
    ports:
      - "8089:8089"
      - "5557:5557"
    volumes:
      - ./:/mnt/locust
    environment:
      - LOCUST_LOCUSTFILE=distributedbench.py
      - LOCUST_HOST=$HOST
      - LOCUST_MODE_MASTER=true
      - LOCUST_PROMETHEUS_EXPORTER=true  # 开启内置监控
    command: --master --expect-workers $WORKERS

  worker:
    build: .
    depends_on:
      - master
    deploy:
      replicas: $WORKERS
    volumes:
      - ./:/mnt/locust
    environment:
      - LOCUST_LOCUSTFILE=distributedbench.py
      - LOCUST_HOST=$HOST
      - LOCUST_MASTER_NODE_HOST=master
    command: --worker
EOF

echo -e "\033[0;32m[SUCCESS] Docker Compose 文件已就绪。\033[0m"
echo "部署命令: docker-compose up --build -d --scale worker=$WORKERS"

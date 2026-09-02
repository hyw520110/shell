#!/bin/bash
# nacos docker容器启动脚本，主机安装时安装包内自带启动脚本
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v docker >/dev/null 2>&1 || { echo >&2 "错误：需要安装 docker 才能运行此脚本"; exit 1; }
docker info >/dev/null 2>&1 || { echo >&2 "错误：Docker daemon 未运行或当前用户无权访问 Docker API"; exit 1; }

if command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d
  exit 0
fi

if docker compose version >/dev/null 2>&1; then
  docker compose up -d
  exit 0
fi

NACOS_VERSION="${NACOS_VERSION:-v2.4.3}"
docker run \
  --name nacos-standalone \
  -e MODE=standalone \
  -p 8848:8848 \
  -p 9848:9848 \
  -p 9849:9849 \
  -d "nacos/nacos-server:${NACOS_VERSION}"

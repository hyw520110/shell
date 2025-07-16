#!/bin/bash
# dependency-track安全系统 安装、配置、启动脚本
# 硬件要求2C1G
# https://docs.dependencytrack.org/getting-started/deploy-docker/
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR


[ ! -f docker-compose.yml ] && curl -LO https://dependencytrack.org/docker-compose.yml
ip=`/opt/shell/ip.sh`
[ `cat ./docker-compose.yml |grep API_BASE_URL|grep $ip|grep -v grep|wc -l` -eq 0 ]  && sed -i "s#API_BASE_URL=http://.*:8082#API_BASE_URL=http://$ip:8082#" ./docker-compose.yml 
docker-compose up -d

# docker-compose down --volumes
#!/bin/bash

command -v docker &> /dev/null || { echo >&2 "错误：需要安装docker才能运行此脚本"; exit 1; }
if command -v docker-compose &> /dev/null; then
  # 如果用户属于docker组，则不需要sudo
  if [ "$(getent group docker | grep -c $USER)" -gt 0 ]; then
    docker-compose up -d && exit 0
  else
    sudo docker-compose up -d && exit 0
  fi
fi

# 如果用户属于docker组，则不需要sudo
if [ "$(getent group docker | grep -c $USER)" -gt 0 ]; then
  docker run --name nacos-standalone -e MODE=standalone -v ./conf/application.properties:/home/nacos/conf/application.properties -p 8848:8848 -d -p 9848:9848  nacos-server:latest
else
  sudo docker run --name nacos-standalone -e MODE=standalone -v ./conf/application.properties:/home/nacos/conf/application.properties -p 8848:8848 -d -p 9848:9848  nacos/nacos-server:latest
fi

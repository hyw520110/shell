#!/bin/bash
export VIPER_DIR=~/viper
[ ! -d $VIPER_DIR ] && sudo  mkdir -p $VIPER_DIR 
cd $VIPER_DIR
[ -f $VIPER_DIR/docker-compose.yml ] && sudo rm -rf docker-compose.yml
pwd

sudo tee docker-compose.yml <<-'EOF'
version: "3"
services:
  viper:
    image: registry.cn-shenzhen.aliyuncs.com/toys/viper:latest
    container_name: viper-c
    network_mode: "host"
    restart: always
    volumes:
      - ${PWD}/loot:/root/.msf4/loot
      - ${PWD}/db:/root/viper/Docker/db
      - ${PWD}/module:/root/viper/Docker/module
      - ${PWD}/log:/root/viper/Docker/log
      - ${PWD}/nginxconfig:/root/viper/Docker/nginxconfig
    command: ["VIPER_PASSWORD"]
EOF

read -sp "输入密码:" VIPER_PASSWORD
sudo sed -i "s/VIPER_PASSWORD/$VIPER_PASSWORD/g" docker-compose.yml
docker-compose config

sudo mkdir {loot,db,module,log,nginxconfig}
docker-compose up -d

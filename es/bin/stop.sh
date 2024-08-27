#!/bin/bash

CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}

for name in $(cat $BASE_DIR/docker-compose.yml |grep container_name|grep -v "^#"|awk '{print $2}')
do
	count=$(docker ps -a|grep $name|grep -v grep|wc -l)
	[ $count -gt 0 ] && docker stop $name
	[ "rm" == "$1" ] && docker rm $name
done
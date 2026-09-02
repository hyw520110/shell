#!/bin/bash

CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}
pid=$( ps -ef|grep $CURRENT_DIR|grep -v grep|awk '{print $2}')

if [ -n "$pid" ];then
	sudo kill -9 $pid && exit 0
fi

cd $BASE_DIR && docker-compose down

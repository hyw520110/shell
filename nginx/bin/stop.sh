#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
[ `docker ps -a 2>/dev/null|grep nginx|grep -v Exited|grep -v grep|wc -l` -gt 0 ] && docker-compose stop 
[ `ps -ef|grep nginx|grep -v grep|wc -l` -gt 0 ] && ps -ef|grep nginx|grep -v grep|awk '{print $2}'|xargs kill -9
#docker-compose down

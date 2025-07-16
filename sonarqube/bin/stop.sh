#!/bin/bash

CURRENT_DIR=`cd $(dirname $0); pwd -P`

BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR

[ `docker-compose ps |grep -v NAME|grep running|grep -v grep|wc -l` -gt 0 ] && docker-compose stop && [ "-f" == "$1" ] && docker-compose down






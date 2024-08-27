#!/bin/bash

CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}
echo $0
cd $BASE_DIR && docker-compose down

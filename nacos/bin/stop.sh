#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}

PIDS=`ps -ef|grep $BASE_DIR | grep -v grep |awk '{print $2}'` 
[ -n "$PIDS" ] && echo kill $BASE_DIR process:$PIDS  && kill -9 $PIDS 1>/dev/null 2>&1 | exit 0
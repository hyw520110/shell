#!/bin/bash

DIR=$(dirname "$(readlink -f "$0")")

PID=$(ps -ef|grep $DIR|grep -v grep|awk '{print $2}')
if [ -n "$PID" ]; then
  kill -9 $PID
  echo "kill $PID"
fi

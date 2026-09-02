#!/bin/bash
# sentinel控制台自动安装启动脚本
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}

pid=`ps -ef|grep $BASE_DIR|grep -v grep|awk '{print $2}'`
[ -n "$pid" ] && echo "kill $pid" && kill -9 $pid


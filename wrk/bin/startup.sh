#!/bin/bash
# wrk http压测工具
# https://www.jianshu.com/p/686233ca909e
URL="https://github.com/wg/wrk/archive/refs/tags/4.2.0.tar.gz"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
# gz文件名
FILE_NAME=${URL##*/}
# gz文件
GZ_FILE=$BASE_DIR/$FILE_NAME
#解压目录
DIR=$BASE_DIR/wrk-4.2.0

if [ ! -f "$CURRENT_DIR/wrk" ];then
	[ ! -f $GZ_FILE ] && wget $URL -o $GZ_FILE
	[ ! -d "$DIR" ] && tar zxvf $GZ_FILE -C $BASE_DIR/ 
	#yum -y install gcc+ gcc-c++ openssl-devel 
	cd $DIR && make && mv ./mrk $CURRENT_DIR/ 
fi
[ -d $DIR ] && rm -rf $DIR

$CURRENT_DIR/wrk -t2 -c10 -d3s http://www.baidu.com




#!/bin/bash
# 传送包到目标服务器
TMP_DIR=/opt/tmp
# 目标服务器主机名或ip
dest_host=$1
[ ! -n "$dest_host" ] && dest_host=pip4
name=$2
[ ! -n "$name" ] && name="*"
# TODO 1、调整为循环查找2、集成到deploy脚本 
[ ! -f "$TMP_DIR/$name-bin.tar.gz" ] && name=${name#*-} 
[ ! -f "/opt/tmp/$name-bin.tar.gz" ] &&  find $TMP_DIR -name "${name}*.tar.gz" | xargs mv -t /opt/tmp 2>/dev/null
[ ! -f "$TMP_DIR/$name-bin.tar.gz" ] && name=${name#*-} 

scp  $TMP_DIR/${name}*-bin.tar.gz root@$dest_host:$TMP_DIR/ && rm -rf $TMP_DIR/*
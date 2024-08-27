#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${DIR%/*}

if [ "" == "$1" ];then
	# 正常停止，输入mysql root密码，停止服务 TODO 必须输入正确密码
	[ `ps -ef|grep mysqld|grep -v grep|wc -l` -gt 0 ] && $DIR/mysqladmin --defaults-file=$BASE_DIR/conf/my.cnf -uroot -p shutdown
else
	# 强制结束
	[ `ps -ef|grep mysqld|grep -v grep|wc -l` -gt 0 ] && ps -ef|grep $BASE_DIR|grep -v grep|awk '{print $2}' |xargs kill -9 
fi
ps -ef|grep mysqld|grep -v grep

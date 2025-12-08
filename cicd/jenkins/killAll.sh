#!/bin/bash
# 批量停止应用服务 注意！只能用于开发、测试环境
ids=`ps -ef|grep /opt/webapps/|grep -v grep |awk '{print $2}'`
[ -n "$ids" ] && echo $ids &&  kill -9 $ids
[ "$1" == "rm" ] && rm -rf /opt/logs/* /opt/tmp/*.md5 /opt/backups/*  ~/logs/nacos/


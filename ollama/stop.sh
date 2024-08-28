#!/bin/bash
process=$(ps -ef|grep ollama|grep -v grep|grep -v "$0")
if [ $(echo $process|wc -l) -eq 0 ];then
  exit 0
fi
echo "$process"
echo "$process" |awk '{print $2}'|xargs kill -9

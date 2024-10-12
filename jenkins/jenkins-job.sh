#!/bin/bash
#jenkins动态构建脚本：根据git变更动态构建发布变更模块,maven多模块工程检测子模块文件是否更改(比对文件摘要)动态生成需构建的子模块
#md5缓存目录
MD5_DIR=~/.md5
#工作目录
WORKSPACE=${1:-/var/lib/jenkins/workspace/pip-dev}
profile=${3:-dev}
module=${2:-""}
#临时文件，缓存更改的子模块
MODULE_FILE=${MD5_DIR}/module
[ ! -n "$WORKSPACE" ] && echo "useage:$0 \$WORKSPACE" && exit 0
[ ! -d $MD5_DIR ] && mkdir $MD5_DIR
if [ ! -n "$module" ];then
  rm -rf $MODULE_FILE && echo -n "module=" > $MODULE_FILE
  for dir in `find ${WORKSPACE} -type d -name src`
  do
    #子目录
    sub=${dir#*$WORKSPACE/}
    #过滤排除common文件夹
    if [ ! -n "`echo $sub|grep common`" ];then
      #子目录
      module=${sub%/src}
      #子目录作为缓存文件名
      name=${module#*/}
      #目录下所有文件的md5摘要；去换行：tr -d "\n"
      md5s=`find $dir -type f | xargs -n 1 md5sum`
      #调试日志
      #if [  "bigdata-app" == "$name" ];then
      #  echo -e "\n\n${name}\n${md5s}"|grep DataServerApplication.java
      #fi
      if [ -f "${MD5_DIR}/$name" ];then
        #比对摘要
        if [ "`cat ${MD5_DIR}/$name`" == "$md5s" ];then
          #echo "$name not changed" 
          continue
        fi
        echo -e "\033[31m $name changed \033[0m"
        [ -n "`echo $module | grep api`" ] && module=${module/api/app}
        if [ -f "$MODULE_FILE" ];then
          [ ! -n "`cat $MODULE_FILE | grep $module`" ] && echo -n "${module}," >> $MODULE_FILE
        else
	   echo -n "${module}," >$MODULE_FILE  
        fi
      fi
      echo "$md5s" > ${MD5_DIR}/$name
      echo -n "${module}," >> $MODULE_FILE
    fi
  done
  #删除文件内容的最后一个字符
  [ -f $MODULE_FILE ] && sed -i 's/,$//' $MODULE_FILE && cat $MODULE_FILE
 
  module=`cat $MODULE_FILE|awk -F'=' '{print $2}'`
else
  echo "module=$module" > $MODULE_FILE
fi
echo -e "\n module:$module"

[ ! -n "$module" ] && echo "未选择构建发布的模块且检测到没有git提交变更的模块" && exit 1

[ -f /etc/profile.d/maven.sh ] && source /etc/profile.d/maven.sh

shell="mvn clean package  -Dmaven.test.skip=true -e -T 12 -Dmaven.compile.fork=true -U  -pl $module -am -P$profile"
echo $shell && exec $shell



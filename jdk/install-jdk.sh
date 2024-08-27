#!/bin/bash
# jdk自动安装、配置

JAVA8_HOME=/opt/dragonwell-8.11.12
#TODO JDK11自动安装、配置
JAVA11_HOME=/usr/local/jdk-11.0.2
#jdk8下载地址
JAVA8_URL=https://github.com/alibaba/dragonwell8/releases/download/dragonwell-8.11.12_jdk8u332-ga/Alibaba_Dragonwell_8.11.12_x64_linux.tar.gz
#下载文件路径，文件名从url提取
gz_file=/opt/softs/${JAVA8_URL##*/}
# profile配置文件
p_file=/etc/profile.d/jdk.sh

function listjava () {
  [ -f /etc/redhat-release ] && update-alternatives --list |grep java
  [ -f /etc/debian_version ] && sudo update-alternatives --list java 
}

function javaversion () {
  echo $(java -version 2>&1 |awk 'NR==1{gsub(/"/,"");print $3}')
}

count=`listjava |grep -Ev "grep|javac" |wc -l`
#echo "shell:$shell,count:$count"
echo "java version:`javaversion`"
if [ `echo $version |grep "1.8" |wc -l` -eq 0 ];then
   [ ! -d ${gz_file%/*} ] && echo "mkdir -p ${gz_file%/*}" && mkdir -p ${gz_file%/*}
   [ ! -d $JAVA8_HOME ] && [ ! -f $gz_file ] && wget $JAVA8_URL -o $gz_file
   [ ! -d $JAVA8_HOME ] && tar -zxvf $gz_file -C ${JAVA8_HOME%/*}
fi 


priority=$((${count}+2))
#echo "priority:$priority"
#优先级越大优先级越高
[ -d $JAVA8_HOME ] &&  update-alternatives --install /usr/bin/java java $JAVA8_HOME/bin/java $priority

[ -d $JAVA11_HOME ] && sudo update-alternatives --install /usr/bin/java java $JAVA11_HOME/bin/java $((${priority}-1))

listjava
echo "java version:`javaversion`"
#交互式配置
#sudo update-alternatives --config java

if [ ! -n "$JAVA_HOME" ];then
  [ ! -f $p_file ] && echo "JAVA_HOME=$JAVA8_HOME" >> $p_file && echo "PATH=\$JAVA8_HOME/bin:\$PATH" >> $p_file 
  [ -f $p_file ] && source $p_file && source /etc/profile
fi

#卸载
#rpm -qa|grep java
#rpm -e java
#ll `whereis java|awk '{print $2}'`
#update-alternatives --remove java $JAVA8_HOME/bin/java



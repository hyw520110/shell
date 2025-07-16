#!/bin/bash
# druid数据源密码加密配置, 指定密码(参数1)或随机密码(不传参数时) 

dir=/opt/webapps
echo "usage:$0 [\$pwd]"
pwd=$1
[ ! -n "$pwd" ] && pwd=`tr -dc A-Za-z0-9_ </dev/urandom | head -c 8 | xargs` && echo "random pwd:$pwd" 

jar=`find $dir -name "druid*.jar" |grep -v starter |head -n 1`
[ ! -f $jar ] && jar=`find ~ -name "druid*.jar" |grep -v starter |head -n 1`

[ ! -f $jar ] && echo "druid*.jar not found!" && exit 1

shell="java -cp $jar com.alibaba.druid.filter.config.ConfigTools $pwd"
echo $shell
result=`exec $shell`
#echo "$result"

pubKey=`echo $result|grep publicKey|awk -F'publicKey:' '{print $2}'|awk '{print $1}'`
pass=`echo $result|awk -F'password:' '{print $2}'`
echo "password:$pass"
echo "publicKey:$pubKey"
echo "" 

echo "nacos配置示例(application.yaml):"
echo "spring.datasource.password: $pass"
echo "spring.datasource.filters: stat,wall,slf4j,config"
echo "spring.datasource.connectionProperties: druid.stat.mergeSql=true;druid.stat.slowSqlMillis=5000;config.decrypt=true;config.decrypt.key=$pubKey"

#!/bin/bash
# druid数据源密码加密配置, 指定密码(参数1)或随机密码(不传参数时) 

set -e

dir=/opt/webapps
mvn_repo=~/.m2/repository/

echo "usage:$0 [\$pwd]"
pwd=$1
[ ! -n "$pwd" ] && pwd=`tr -dc A-Za-z0-9_ </dev/urandom | head -c 8 | xargs` && echo "random pwd:$pwd" 

[ -d $dir ] && jar=`find $dir -name "druid*.jar" |grep -v starter |head -n 1`
[ ! -f "$jar" ] && jar=$(find $mvn_repo -name 'druid-*.jar' -not -name '*-sources.jar' -not -path '*starter*' | sed -E 's#.*/druid-(.+)\.jar$#\1#' | sort -V | tail -n1 | xargs -I {} find $mvn_repo -name "druid-{}.jar")


if [ ! -f "$jar" ]; then
    echo "druid*.jar not found!" 
    exit 1
fi

echo "Executing: java -cp $jar com.alibaba.druid.filter.config.ConfigTools $pwd"
result=$(java -cp "$jar" com.alibaba.druid.filter.config.ConfigTools "$pwd")
echo "$result"

# 更准确地提取密码和公钥
pass=$(echo "$result" | grep "^password:" | cut -d':' -f2)
pubKey=$(echo "$result" | grep "^publicKey:" | cut -d':' -f2)

# 检查结果是否成功提取
if [ -z "$pass" ] || [ -z "$pubKey" ]; then
    echo "Error: Failed to extract password or publicKey from result"
    exit 1
fi

echo "password:$pass"
echo "publicKey:$pubKey"
echo "" 

echo "nacos配置示例(application.yaml):"
echo "spring.datasource.password: $pass"
echo "spring.datasource.filters: stat,wall,slf4j,config"
echo "spring.datasource.connectionProperties: druid.stat.mergeSql=true;druid.stat.slowSqlMillis=5000;config.decrypt=true;config.decrypt.key=$pubKey"

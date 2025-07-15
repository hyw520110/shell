#!/bin/bash
# es启动脚本 docker-compose方式 TODO 1、集群https://blog.csdn.net/qq_46122292/article/details/125522363;2、主机安装模式
# 单机模式s或集群模式c
mode=$1
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
# es版本
version=`cat $BASE_DIR/.env|grep ES_VERSION|awk -F'=' '{print $2}'`
# es ik分词插件
url=https://github.com/medcl/elasticsearch-analysis-ik/releases/download/v$version/elasticsearch-analysis-ik-$version.zip
# ik插件离线包
ik_zip_file=/opt/softs/${url##*/}
ip=$2

cd $BASE_DIR
# 已运行中，则提示退出
[ `docker-compose ps |grep running|wc -l` -gt 0 ] && docker-compose ps && exit 0

echo "usage:$0 \$mode"
[ ! -n "$mode" ] && read -t 5 -n 1 -p "选择模式(c集群模式/s单机模式):" mode
mode=${mode:-c} && echo -e "\n模式:`[ "$mode" == "c" ] && echo 集群 || echo 单机`"

# 挂载目录批量判断，不存在时创建
for dir in `cat $BASE_DIR/docker-compose.yml |grep -A 4 volumes|grep "-"|awk -F':' '{print $1}'|awk '{print $2}'`
do
	# 相对路径转换绝对路径
    [[ "$dir" =~ ^\..* ]] && dir=`echo $dir|sed 's/^\.\///'` && dir=$BASE_DIR/$dir
 	[ ! -d $dir ] && mkdir -p $dir
 	[ -n "`echo $dir|grep log`" ] &&  chmod -R 775 $dir
done

# sysctl -w vm.max_map_count=262144

 [ ! -n "$$JAVA_HOME" ] && [ -f /opt/shell/install-jdk.sh ] && /opt/shell/install-jdk.sh
 [ ! -d $CURRENT_DIR/jdk/bin ] && mkdir -p $CURRENT_DIR/jdk/bin && ln -s $JAVA_HOME/bin/java $CURRENT_DIR/jdk/bin/java

# ik分词器插件 https://github.com/medcl/elasticsearch-analysis-ik
if [ "`ls -A $BASE_DIR/plugins`" == "" ];then
	[ ! -f $ik_zip_file ] && wget $url -o $ik_zip_file 
	[ ! -d $BASE_DIR/plugins/ik ] && unzip $ik_zip_file -d $BASE_DIR/plugins/ik
#	$CURRENT_DIR/elasticsearch-plugin install $ik_zip_file
fi

echo "version:$version"
# 单机模式
#docker run -d --rm --name elasticsearch -p 9200:9200  -p 9300:9300 -e "discovery.type=single-node"  -e ES_JAVA_OPTS="-Xms512m -Xmx512m"  -v $BASE_DIR/config/elasticsearch.yml:/usr/share/elasticsearch/config/elasticsearch.yml  -v $BASE_DIR/data:/usr/share/elasticsearch/data  -v $BASE_DIR/plugins:/usr/share/elasticsearch/plugins elasticsearch:$version
docker-compose -f $BASE_DIR/single.yml up -d
id=`docker ps -a|grep elasticsearch|awk '{print $1}'` 
[ -n "$id" ] && docker cp $id:/usr/share/elasticsearch/bin/ $BASE_DIR/ && docker cp $id:/usr/share/elasticsearch/jdk/ $BASE_DIR/ && docker exec -it $id "ls ./"
# 远程拷贝 参数1:模式;参数2：目标服务器ip
function remoteInstall(){
  # 设置免密登陆
  [ `cat $init_file|grep $2|grep -v grep|wc -l` -eq 0 ] && /opt/shell/ssh_login.sh $2 && echo $2 >> $init_file
  rsync -aWPu --exclude "logs" $BASE_DIR ${2}:${BASE_DIR%/*}
  ssh root@$2 'bash -s' <<'EOF'
chmod +x $CURRENT_DIR/*.sh
$CURRENT_DIR/${0##*/} $1 $2 >/dev/null 2>&1 &
EOF
}
# 集群模式 TODO 待验证
if [ "c" == "$mode" ];then
    # 停单机服务
	docker-compose -f $BASE_DIR/single.yml down && rm -rf $CURRENT_DIR/jdk
	# 当前服务器初始输入集群ip，修改生成集群配置文件，传送到其他集群服务器远程启动服务，在启动当前集群节点服务
	if [ ! -n "$ip" ];then
		# 探测局域网ip 过滤第一行：awk 'NR >1'
		/opt/shell/ip.sh -a
		while : ; do
		  read -p "请输入集群IP地址(多个ip空格隔开,输入至少2个ip和当前服务器组成3节点集群)：" ip 
		  # 验证是否是IP格式，2个ip包含6个点	
		  if [[ (-n "$ip") && ( `echo $ip|grep "."|grep " "|wc -l` -gt 5 ) ]];then
		    for i in $ip
		    do
		      remoteInstall $mode $i && wait $!
		    done      
		    break
		  fi 
		done
	fi
	# 启动集群服务
	docker-compose up -d && docker-compose ps && docker-compose logs -f
fi 


# curl -X GET -H "Content-Type: application/json"  "http://localhost:9200/_analyze?pretty=true" -d'{"text":"中华五千年华夏","analyzer": "ik_smart"}'
# basic插件需安装且支持版本较低，推荐使用nginx代理配置auth_basic
#if [ ! -d $BASE_DIR/plugins/http_basic ];then
# mkdir $BASE_DIR/plugins/http_basic
# wget -P $BASE_DIR/plugins/http_basic  https://github.com/Asquera/elasticsearch-http-basic/releases/download/v1.5.1/elasticsearch-http-basic-1.5.1.jar
#fi 
 #curl http://[your-node-name]:[your-port]/[your-index]/_count?pretty=true
 #curl --user [your-admin]:[your-password] http://[your-node-name]:[your-port]/[your-index]/_count?pretty=true
 
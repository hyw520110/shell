#!/bin/bash
# nacos安装、启动脚本，默认单机模式，可交互式选择集群模式，集群ip交互式输入.TODO 数据库密码配置
# 默认端口，集群模式下的节点服务端口
port=8848
# 启动模式默认单机
mode="-m standalone"

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=`cd $(dirname $0)/..; pwd`
cd $CURRENT_DIR

# 下载url，默认离线安装,如当前目录不完整(nacos-server.jar缺失) 或离线安装包不存在时 执行下载 在离线安装
url=https://github.com/alibaba/nacos/releases/download/2.1.1/nacos-server-2.1.1.tar.gz
# 从url中提取压缩文件名
gz_file_name=${url##*/}
# 下载文件路径，文件名从下载url提取
gz_file=/opt/softs/$gz_file_name
# 解压临时目录
tmp_dir=/tmp/${gz_file_name%*.tar.gz}
# 集群配置文件
cluster_file=$BASE_DIR/conf/cluster.conf
# 记录是否初始化第一次启动，初始提示修改配置文件，设置数据库密码
init_file=~/.nacos_init
# 自启动服务脚本
s_file=/usr/lib/systemd/system/nacos.service
# ip
ip=$1



# 初始第一次 提示修改数据源配置
if [ ! -f $init_file ];then
  echo "Confirm or modify data source configuration:"
  grep "^db." $BASE_DIR/conf/application.properties
  touch $init_file
fi

# 安装自启动服务
if [ ! -f $s_file ];then
cat >> $s_file << EOF
[Unit]
Description=nacos
After=network.target

[Service]
Type=forking
ExecStart=$BASE_DIR/bin/startup.sh $mode
ExecStop=$BASE_DIR/bin/shutdown.sh
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 
systemctl enable nacos.service
fi 

# nacos已启动时提示并退出 
pid=`ps -ef |grep $BASE_DIR |grep -v "grep"|awk '{print $2}'|awk 'NR==1'` && [ -n "$pid" ] && echo "nacos is running,pid:$pid" && exit 0
# 端口占用时 退出
[ `netstat -anp|grep $port|grep LISTEN|grep -v grep |wc -l` -gt 0 ] && print "port $port is already in use" && netstat -anp|grep $port|grep LISTEN && exit 0

# 查看实时日志
function tailfLog {
	sleep 3 && tail $1 -n 100 $BASE_DIR/logs/start.out
}
# 判断文本在文件中不存在时，写入文本到文件,参数1：文本；参数2：文件路径;参数3可选：执行命令,文本写入后的加载命令
function wfile {
 # 当文件存在时，查找文件内容是否存在，不存在时追加文本到文件中,如有加载命令则执行加载命令
 [ -f $2 ] && [ ! -n "`grep "$1" $2`" ] && echo "$1">>$2 && echo "$1" >>$2 && [ -n "$3" ] && exec $3
}
# 远程拷贝
function remoteInstall() {
  [ `cat $init_file|grep $1|grep -v grep|wc -l` -eq 0 ] && /opt/shell/ssh_login.sh $1 && echo $1 >> $init_file
  rsync -aWPu --exclude "logs" $BASE_DIR ${1}:${BASE_DIR%/*}
  ssh  -o StrictHostKeyChecking=no root@$1 > /dev/null 2>&1 << EOF
chmod +x $CURRENT_DIR/*.sh
$CURRENT_DIR/${0##*/} $1 >/dev/null 2>&1 &
exit 
EOF
}
# 如未安装下载
if [ ! -f $BASE_DIR/target/nacos-server.jar ];then
    # jar 
	[ ! -f $gz_file ] && wget $url -o $gz_file
	[ ! -d $tmp_dir ] &&  tar -zxf $gz_file -C ${tmp_dir%/*}
	rsync -aWPu $tmp_dir/target/* $BASE_DIR/target/ && rm -rf $tmp_dir
fi

read -t 5 -n 1 -p "选择模式(单机y/n):" m && echo ""
m=${m:-y}
[ "y" == "$m" ] && echo "单机模式启动..."  && $CURRENT_DIR/startup.sh $mode && tailfLog && exit 0
echo "集群模式启动..."
# yum install -y clustershell 
# yum -y install expect
# 当前服务器初始输入集群ip，修改生成集群配置文件，传送到其他集群服务器远程启动服务，在启动当前集群节点服务
if [ ! -n "$ip" ];then
	# 探测局域网ip 过滤第一行：awk 'NR >1'
	/opt/shell/ip.sh -a
	wfile "`/opt/shell/ip.sh`:$port"  $cluster_file
	while : ; do
	  read -p "请输入集群IP地址(多个ip空格隔开,输入至少2个ip和当前服务器组成3节点集群)：" ip 
	  if [[ (-n "$ip") && ( `echo $ip|grep "."|grep " "|wc -l` -gt 0 ) ]];then
	    for i in $ip
	    do
	      wfile "$i:$port" $cluster_file
	    done
	    for i in $ip
	    do
	      remoteInstall $i && wait $!
	    done      
	    
	    break
	  fi 
	done
fi
$CURRENT_DIR/startup.sh 
[ ! -n "$ip" ] && tailfLog -f || tailfLog


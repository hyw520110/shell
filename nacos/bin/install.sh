#!/bin/bash
# nacos安装、启动脚本，默认单机模式，可交互式选择集群模式，集群ip交互式输入.TODO 数据库密码配置
# 默认端口，集群模式下的节点服务端口
port=8848
# 获取用户输入的安装目录，如果未输入则使用默认路径
INSTALL_DIR="${1:-/opt/nacos}"
# 启动模式默认单机
#mode="-m standalone"
mode="${2:--m standalone}"
# 获取当前脚本所在目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=`cd $(dirname $0)/..; pwd`

# 检查是否以 sudo 权限运行
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 sudo 权限运行此脚本。"
    echo ""
    echo "Usage: sudo $0 [install_dir] [mode]"
    echo "  install_dir  可选，指定安装目录，默认为 /opt/nacos"
    echo "  mode         可选，指定启动模式，默认为 standalone (单机模式)，可选 cluster (集群模式)"
    exit 1
fi
# 检查安装目录是否存在，如果不存在则创建
if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR"
fi

# 如果用户指定的安装目录不是默认目录，则将文件复制到新目录
if [ "$INSTALL_DIR" != "$BASE_DIR" ]; then
  cp -r "$BASE_DIR"/* "$INSTALL_DIR/"
  BASE_DIR="$INSTALL_DIR"
fi
# 下载url，默认离线安装,如当前目录不完整(nacos-server.jar缺失) 或离线安装包不存在时 执行下载 在离线安装
url="https://github.com/alibaba/nacos/releases/download/3.0.2/nacos-server-3.0.2.tar.gz"
# 从url中提取压缩文件名
gz_file_name=${url##*/}
# 下载文件路径，文件名从下载url提取
gz_file=/tmp/$gz_file_name
# 解压临时目录，应该获取INSTALL_DIR的上级目录
tmp_dir=/opt
# 集群配置文件
cluster_file=$BASE_DIR/conf/cluster.conf
# 记录是否初始化第一次启动，初始提示修改配置文件，设置数据库密码
init_file=~/.nacos_init
# 自启动服务脚本
s_file=/usr/lib/systemd/system/nacos.service
# ip
ip=$(hostname -I | awk '{print $1}')


cd $BASE_DIR


# 初始第一次 提示修改数据源配置
if [ ! -f $init_file ];then
  # 检查 mysql-server 是否存在且可连通
  MYSQL_SERVER="mysql-server"
  ping -c 1 "$MYSQL_SERVER" &> /dev/null
  if [ $? -ne 0 ]; then
      echo "无法解析或连接到 $MYSQL_SERVER，需要手动输入 MySQL 服务器 IP。"
      read -p "请输入 MySQL 服务器 IP 地址 (默认为当前主机IP $ip): " MYSQL_IP
      if [ -z "$MYSQL_IP" ]; then
          MYSQL_IP=$(hostname -I | awk '{print $1}')
          echo "已使用当前主机 IP: $MYSQL_IP"
      fi
      # 自定义主机已配置则删除
      grep "$MYSQL_SERVER" /etc/hosts >/dev/null 2>&1 && sed -i "/$MYSQL_SERVER/d" /etc/hosts
      # 添加自定义主机
      echo "$MYSQL_IP $MYSQL_SERVER" >> /etc/hosts
  else
      MYSQL_IP="$MYSQL_SERVER"
  fi
  sed -i "s/^# db.url.0/db.url.0/" $BASE_DIR/conf/application.properties
  
  sed -i "s#jdbc:mysql://127.0.0.1/jdbc:mysql://$MYSQL_SERVER/" $BASE_DIR/conf/application.properties
  # 提示用户输入 MySQL 用户名和密码
  read -p "请输入 MySQL 用户名 (默认: root): " MYSQL_USER
  MYSQL_USER="${MYSQL_USER:-root}"

  read -s -p "请输入 MySQL 密码: " MYSQL_PASSWORD
  echo
  sed -i "s/^# db.user=/db.user=/"  $BASE_DIR/conf/application.properties
  sed -i "s/^db.user.0=.*/db.user.0=$MYSQL_USER/"  $BASE_DIR/conf/application.properties
  sed -i "s/^# db.password=/db.password=/"  $BASE_DIR/conf/application.properties
  sed -i "s/^db.password.0=.*/db.password.0=$MYSQL_PASSWORD/"  $BASE_DIR/conf/application.properties

  echo "数据源配置:"
  grep "^db." $BASE_DIR/conf/application.properties
  touch $init_file
  # 安全配置 注意重复执行时会反复修改密钥
  # 检查openssl是否安装未安装则安装
  secret_key=$(openssl rand -base64 32)
  sed -i "s#nacos.core.auth.plugin.nacos.token.secret.key=.*#nacos.core.auth.plugin.nacos.token.secret.key=$secret_key#" $BASE_DIR/conf/application.properties
  sed -i "s#nacos.core.auth.server.identity.key=.*#nacos.core.auth.server.identity.key=$(openssl rand -base64 32)#" $BASE_DIR/conf/application.properties
  sed -i "s#nacos.core.auth.server.identity.value=.*#nacos.core.auth.server.identity.value=$(openssl rand -hex 16)#" $BASE_DIR/conf/application.properties
  
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
	[ ! -f $gz_file ] && wget $url -O $gz_file
	# 解压过程中获取解压目录名（nacos）
	tar -zxf $gz_file -C ${tmp_dir%/*} 2>/dev/null
	if [ $? -ne 0 ]; then
	   echo "重新下载:wget $url -o $gz_file "
	   #rm -rf $gz_file
	   wget -c $url -O $gz_file && tar -zxf $gz_file -C ${tmp_dir%/*}
	fi
	rsync -aWPu $tmp_dir/nacos/* $BASE_DIR/ && rm -rf $tmp_dir
fi

read -t 5 -n 1 -p "选择模式(单机y/n):" m && echo ""
m=${m:-y}
if [ "y" == "$m" ]; then
  echo "单机模式启动..."  &&
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
  $CURRENT_DIR/startup.sh $mode
  tailfLog && exit 0
fi
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


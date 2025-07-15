#!/bin/bash
# sentinel控制台自动安装启动脚本
# 服务端口
port=8060
# 默认用户名
usr="admin"
# 默认密码
pass="dsXZsnRI"
# 下载url
url=https://github.com/alibaba/Sentinel/releases/download/1.8.6/sentinel-dashboard-1.8.6.jar
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
# jar file
jar=$BASE_DIR/${url##*/}
name=sentinel

# 日志目录、日志文件
log_dir=/var/log/$name
log_file=$log_dir/$name-dashboard.log
service_file=/usr/lib/systemd/system/$name.service

cd $BASE_DIR

[ `netstat -tunlp | grep $port |grep -v grep| wc -l` -gt 0 ] && echo "port $port is already in used"&& exit 0

if [ ! -f $jar ];then
	wget -c -O $jar $url 
    wait $!
fi
if [ ! -f $BASE_DIR/.pass ];then
	[ -f /opt/shell/pwd.sh ] && pass=`/opt/shell/pwd.sh |grep "pwd:"|awk -F':' '{print $2}'` 
	echo $pass > $BASE_DIR/.pass
else
	pass=`cat $BASE_DIR/.pass`
fi
echo "user:$usr,password:$pass"
# 启动参数：sentinel.dashboard.app.hideAppNoMachineMillis:是否隐藏无健康节点的应用，距离最近一次主机心跳时间的毫秒数，默认关闭0,最小值60000；
# sentinel.dashboard.removeAppNoMachineMillis：是否自动删除无健康节点的应用，距离最近一次其下节点的心跳时间毫秒数，默认关闭0，最小值120000
# sentinel.dashboard.unhealthyMachineMillis：主机失联判定，不可关闭，默认值60000，最小30000
# sentinel.dashboard.autoRemoveMachineMillis：距离最近心跳时间超过指定时间是否自动删除失联节点，默认关闭0，最小300000；
# sentinel.dashboard.unhealthyMachineMillis：主机失联判定，不可关闭，默认值60000，最小30000
# server.servlet.session.cookie.name：控制台应用的 cookie 名称，可单独设置避免同一域名下 cookie 名冲突，默认sentinel_dashboard_cookie
shell="java -Dserver.port=$port -Dcsp.sentinel.dashboard.server=localhost:$port -Dproject.name=sentinel-dashboard -Dsentinel.dashboard.auth.username=$usr -Dsentinel.dashboard.auth.password=$pass -Dserver.servlet.session.timeout=7200 -jar $jar"
echo $shell
exec nohup  $shell  > /dev/null 2>&1 & 

# 安装自启动服务
if [ ! -f $service_file ];then
cat >> $service_file << EOF
[Unit]
Description=$name

[Service]
Type=forking
# 指定脚本路径
ExecStart=$CURRENT_DIR/startup.sh
ExecStop=$CURRENT_DIR/stop.sh
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload 
	systemctl enable $name.service
fi



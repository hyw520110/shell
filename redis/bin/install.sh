#!/usr/bin/env bash
# redis install script
# 用法: ./install.sh [INSTALL_DIR] [节点数] [端口]

set -e
# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# 当前脚本父目录
BASE_DIR=$(cd "$SCRIPT_DIR/.."; pwd)
# 下载地址和压缩包名
#url=https://github.com/redis/redis/archive/7.0.5.tar.gz
url="https://github.com/redis/redis/archive/refs/tags/8.0.3.tar.gz"
gz_file_name=${url##*/}
tmp_dir=/tmp
gz_file=$tmp_dir/$gz_file_name
# 安装目录
INSTALL_DIR="${1:-/opt/redis}"
# 节点数，单机模式1(默认);集群模式大于1为集群
num=${2:-1}
# 端口，集群模式为起始端口
port=${3:-6379}
service_dir=/usr/lib/systemd/system

# 检测操作系统类型
OS_TYPE=$(uname)

# 定义sed的in-place编辑选项，解决macOS和Linux的兼容性问题
if [[ "$OS_TYPE" == "Darwin" ]]; then
    SED_I_ARG="-i ''"
    SED_CMD="sed -i ''"
else
    SED_I_ARG="-i"
    SED_CMD="sed -i"
fi

# 检查是否已安装
if [ -x "$INSTALL_DIR/bin/redis-server" ]; then
  echo "检测到 $INSTALL_DIR 已存在且已编译安装，跳过源码下载和编译。"
else
  # 下载源码包
  if [ ! -f "$gz_file" ]; then
    echo "正在下载 Redis 源码包..."
    mkdir -p $tmp_dir
    wget -O "$gz_file" "$url"
  fi

  cd $tmp_dir
  # 获取解压目录名
  extra_dir_name=$(tar -tzf "$gz_file" | head -1 | cut -f1 -d"/")
  if [ ! -d $tmp_dir/$extra_dir_name ]; then
    echo "正在解压..."
    tar -zxf "$gz_file"
  fi
  cd "$extra_dir_name"
  echo "正在编译..."
  make && make install PREFIX="$INSTALL_DIR"
  # 创建目录结构
  mkdir -p "$INSTALL_DIR/conf" "$INSTALL_DIR/data"  "$INSTALL_DIR/bin"
fi


cp -a  $BASE_DIR/{bin,conf} $INSTALL_DIR/

# 安装自启动服务
install-service(){
    # macOS系统不安装systemd服务
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        echo "macOS系统不安装systemd服务"
        return 0
    fi
    
    local BASE_DIR=$1
    local conf_file=$2
    local service_name=$3
    local p=$4
    if [ ! -f $service_dir/$service_name.service ];then
        # 确保service目录存在
        mkdir -p $service_dir
        
cat > $service_dir/$service_name.service << EOF
[Unit]
Description=redis
After=network.target

[Service]
Type=forking
ExecStart=$BASE_DIR/bin/redis-server $conf_file
ExecStop=$BASE_DIR/bin/stop.sh $p
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable $service_name.service
    fi
}

# 初始化集群或单机配置
cd "$INSTALL_DIR"
if [ $num -gt 1 ]; then
	# 集群参数校验
	if [ $num -lt 3 ]; then
	    echo "集群模式节点数小于3，自动调整为3。"
	    num=3
	fi
	if [ $((num % 2)) -eq 0 ]; then
	    echo "集群模式节点数必须为奇数，当前为 $num,+1变更为奇数节点数。" 
	    num=$((num+1))
	fi
    # 集群模式
    for p in $(seq $((port+1)) $((port+num)) ); do
        conf_file="$INSTALL_DIR/conf/redis-$p.conf"
        [ ! -f $conf_file ] && cp "$INSTALL_DIR/conf/redis.conf" $conf_file
        # 修改日志文件路径为相对路径
        $SED_CMD -e "s#logfile .*.log#logfile $INSTALL_DIR/logs/redis-$p.log#" $conf_file
        $SED_CMD "s#dir ./#dir $INSTALL_DIR/data/$p#" $conf_file && mkdir -p "$INSTALL_DIR/data/$p"
        $SED_CMD "s#$port#$p#g" $conf_file
        $SED_CMD "s#daemonize no#daemonize yes#" $conf_file
        $SED_CMD "s/# cluster-enabled yes/cluster-enabled yes/" $conf_file
        $SED_CMD "s/# cluster-node-timeout/cluster-node-timeout/" $conf_file
        $SED_CMD "s/# cluster-config-file/cluster-config-file/" $conf_file
        install-service "$INSTALL_DIR" "$conf_file" "redis-$p" "$p"
    done
    echo "✅ Redis 集群模式已初始化，节点数: $num，起始端口: $((port+1))"
    echo "请手动启动各节点并创建集群。"
else
    # 单机模式
    conf_file="$INSTALL_DIR/conf/redis.conf"
    # 修改日志文件路径为相对路径
    $SED_CMD "s#logfile /var/log/redis/6379.log#logfile $INSTALL_DIR/logs/redis.log#" $conf_file
    $SED_CMD "s#pidfile /var/run/redis_6379.pid#pidfile $INSTALL_DIR/redis.pid#" $conf_file
    $SED_CMD "s#dir ./#dir $INSTALL_DIR/data#" $conf_file
    install-service "$INSTALL_DIR" "$conf_file" "redis" "$port"
    echo "✅ Redis 单机模式已初始化，端口: $port"
fi

cat <<EOF
✅ Redis 已安装到: $INSTALL_DIR
请根据需要修改配置文件: $INSTALL_DIR/conf/redis.conf
如需启动请执行: $INSTALL_DIR/bin/startup.sh
EOF

# 动态安装配置完成后调用安装目录下的启动脚本
if [ -f "$INSTALL_DIR/bin/startup.sh" ] && [ -x "$INSTALL_DIR/bin/startup.sh" ]; then
    echo "正在启动 Redis..."
    "$INSTALL_DIR/bin/startup.sh" "$num" "$port"
else
    echo "提示: 您可以手动执行以下命令启动 Redis:"
    echo "  $INSTALL_DIR/bin/startup.sh"
fi

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
  # 检查安装目录权限
  if [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
    echo "错误: 没有对安装目录父目录的写权限: $(dirname "$INSTALL_DIR")"
    read -p "是否要更改安装目录到用户目录下? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      # 更改安装目录到用户目录下
      INSTALL_DIR="$HOME/redis"
      echo "安装目录已更改为: $INSTALL_DIR"
    else
        echo "将使用sudo权限安装到 $INSTALL_DIR"
        # 设置目录所属和权限
        [ ! -d $INSTALL_DIR ] && sudo mkdir -p $INSTALL_DIR/{conf,data}
	    sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
	    sudo chmod -R 755 "$INSTALL_DIR"
    fi
  fi
  
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
    tar -xzf "$gz_file" -C "$tmp_dir"
  fi

  # 进入源码目录
  cd "$tmp_dir/$extra_dir_name"
  echo "正在编译..."
  
  # 编译源码
  make

  # 安装
  echo "正在安装到 $INSTALL_DIR..."
  make PREFIX="$INSTALL_DIR" install
fi

# 复制配置文件和脚本
#echo "cp -r $BASE_DIR/ $INSTALL_DIR/"
cp -r $BASE_DIR/ $INSTALL_DIR/
chmod +x  $INSTALL_DIR/bin/*.sh

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
         # 重新加载systemd
	    if ! systemctl daemon-reload 2>/dev/null; then
	      echo "警告: 无法重新加载systemd守护进程"
	      return 1
	    fi
	        # 启用服务
	    if ! systemctl enable "$service_name.service" 2>/dev/null; then
	      echo "警告: 无法启用服务 $service_name"
	      return 1
	    fi
    fi
}
# 创建密码函数
generate_password() {
    # 生成随机密码
    password=$(openssl rand -base64 12)
    echo "$password"
}

# 处理配置文件函数
handle_config() {
    local conf_file=$1
    local port=$2
    local is_cluster=$3
    local password=$4
    
    # 创建配置文件目录（如果需要）
    local conf_dir=$(dirname "$conf_file")
    if [ ! -d "$conf_dir" ]; then
       mkdir -p "$conf_dir"
    fi
    
    # 如果是集群模式，先复制模板文件
    if [ "$is_cluster" = "yes" ]; then
        if [ -f "$INSTALL_DIR/conf/redis.conf" ]; then
           cp "$INSTALL_DIR/conf/redis.conf" "$conf_file"
        fi
    fi
    #echo "conf_file:$conf_file"
    $SED_CMD "s/^port .*/port $port/" $conf_file
    $SED_CMD "s/# requirepass foobared/requirepass $password/" "$conf_file"
    $SED_CMD "s/appendonly no/appendonly yes/" "$conf_file"
    $SED_CMD "s/bind 127.0.0.1/bind 0.0.0.0/" "$conf_file"
    $SED_CMD "s/# replica-read-only yes/replica-read-only no/" "$conf_file"
    $SED_CMD "s#dir ./#dir $INSTALL_DIR/data/$port#" "$conf_file" && mkdir -p "$INSTALL_DIR/data/$port"
    $SED_CMD "s#logfile /var/log/redis/6379.log#logfile $INSTALL_DIR/logs/redis-$port.log#" "$conf_file"
    $SED_CMD "s#pidfile /var/run/redis_6379.pid#pidfile $INSTALL_DIR/redis-$port.pid#" "$conf_file"
    
    # 集群模式特有配置
    if [ "$is_cluster" = "yes" ]; then
        $SED_CMD "s/# cluster-enabled yes/cluster-enabled yes/" "$conf_file"
        $SED_CMD "s/# cluster-config-file nodes.conf/cluster-config-file nodes-$port.conf/" "$conf_file"
        $SED_CMD "s/# cluster-node-timeout 15000/cluster-node-timeout 15000/" "$conf_file"
        $SED_CMD "s/protected-mode yes/protected-mode no/" "$conf_file"
        $SED_CMD "s/# masterauth foobared/masterauth $password/" "$conf_file"
    fi
}

# 初始化集群或单机配置
cd "$INSTALL_DIR"

# 生成密码
password=$(generate_password)

if [ $num -gt 1 ]; then
	# 集群参数校验
	[ $num -lt 3 ] && num=3
	[ $((num % 2)) -eq 0 ] && echo "集群模式节点数必须为奇数，当前为 $num,+1变更为奇数节点数。" &&  num=$((num+1))
	# 集群模式
	echo "初始化 Redis 集群模式 ($num 个节点，起始端口 $port)..."
	
	# 生成集群节点配置
	for (( p=port; p<port+num; p++ )); do
        conf_file="$INSTALL_DIR/conf/redis-$p.conf"
        
        # 如果配置文件不存在，则创建
        if [ ! -f "$conf_file" ]; then
            handle_config "$conf_file" "$p" "yes" "$password"
            # 安装服务
            install-service "$INSTALL_DIR" "$conf_file" "redis-$p" "$p"
        fi
    done
    
    echo "✅ Redis 集群模式已初始化，节点数: $num，起始端口: $port"
    echo "生成的密码: $password"
    echo "请手动启动各节点并创建集群。"
    
else
    # 单机模式
    conf_file=$INSTALL_DIR/conf/redis.conf
    # 处理配置文件
    handle_config "$conf_file" "$port" "no" "$password"
    # 安装服务
    install-service "$INSTALL_DIR" "$conf_file" "redis" "$port"
    
    echo "✅ Redis 单机模式已初始化，端口: $port"
    echo "生成的密码: $password"
	  
	# 动态安装配置完成后调用安装目录下的启动脚本
	if [ -f "$INSTALL_DIR/bin/startup.sh" ] && [ -x "$INSTALL_DIR/bin/startup.sh" ]; then
	  echo "正在启动 Redis..."
	  $INSTALL_DIR/bin/startup.sh "$num" "$port"
	else
	  echo "提示: 您可以手动执行以下命令启动 Redis:"
	  echo "  $INSTALL_DIR/bin/startup.sh"
	fi
fi


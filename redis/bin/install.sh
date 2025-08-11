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
# 系统服务目录
service_dir=/usr/lib/systemd/system
# 系统日志目录
system_log_dir=/var/log/redis

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

# 检查并安装编译依赖
install_dependencies() {
    echo "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查基础编译工具
    if ! command -v gcc >/dev/null 2>&1; then
        missing_deps+=("gcc")
    fi
    
    if ! command -v g++ >/dev/null 2>&1; then
        missing_deps+=("g++")
    fi
    
    if ! command -v make >/dev/null 2>&1; then
        missing_deps+=("make")
    fi
    
    if ! command -v wget >/dev/null 2>&1; then
        missing_deps+=("wget")
    fi
    
    # 检查开发库
    if ! ldconfig -p 2>/dev/null | grep -q "libjemalloc"; then
        if command -v apt-get >/dev/null 2>&1; then
            missing_deps+=("libjemalloc-dev")
        elif command -v yum >/dev/null 2>&1; then
            missing_deps+=("jemalloc-devel")
        elif command -v dnf >/dev/null 2>&1; then
            missing_deps+=("jemalloc-devel")
        fi
    fi
    
    # 如果有缺失的依赖，则安装
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "检测到缺失的依赖: ${missing_deps[*]}"
        echo "正在安装缺失的依赖..."
        
        if command -v apt-get >/dev/null 2>&1; then
            # Debian/Ubuntu系统
            echo "检测到 Debian/Ubuntu 系统"
            sudo apt-get update
            sudo apt-get install -y "${missing_deps[@]}"
        elif command -v yum >/dev/null 2>&1; then
            # CentOS/RHEL系统
            echo "检测到 CentOS/RHEL 系统"
            sudo yum install -y "${missing_deps[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            # Fedora系统
            echo "检测到 Fedora 系统"
            sudo dnf install -y "${missing_deps[@]}"
        else
            echo "警告: 无法识别的包管理器，请手动安装以下依赖：${missing_deps[*]}"
            read -p "按回车键继续，或 Ctrl+C 退出..." dummy
        fi
    else
        echo "所有依赖已安装"
    fi
}

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
  
  # 安装编译依赖
  install_dependencies
  
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
  
  # 设置环境变量以正确链接jemalloc
  export USE_JEMALLOC=yes
  export MALLOC=jemalloc
  
  # 编译源码
  make BUILD_TLS=yes STD=-std=gnu99

  # 安装
  echo "正在安装到 $INSTALL_DIR..."
  make PREFIX="$INSTALL_DIR" install
fi

# 复制配置文件和脚本
echo "cp -r $BASE_DIR/* $INSTALL_DIR/"
cp -r $BASE_DIR/* $INSTALL_DIR/
chmod +x $INSTALL_DIR/bin/*.sh 2>/dev/null 

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
    
    # 确保service目录存在
    if [ ! -d "$service_dir" ]; then
        if ! sudo mkdir -p "$service_dir" 2>/dev/null && ! mkdir -p "$service_dir" 2>/dev/null; then
            echo "警告: 无法创建服务目录 $service_dir"
            return 1
        fi
    fi
    
    if [ ! -f $service_dir/$service_name.service ];then
        # 使用sudo tee命令创建服务文件，避免直接写入系统目录的权限问题
        sudo tee "$service_dir/$service_name.service" > /dev/null << EOF
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
        
        # 检查服务文件是否创建成功
        if [ $? -ne 0 ]; then
            echo "警告: 无法创建systemd服务文件 $service_dir/$service_name.service"
            return 1
        else
            echo "systemd服务文件已创建到 $service_dir/$service_name.service"
        fi
        
        # 重新加载systemd
        if ! sudo systemctl daemon-reload 2>/dev/null && ! systemctl daemon-reload 2>/dev/null; then
            echo "警告: 无法重新加载systemd守护进程"
            return 1
        else
            echo "systemd守护进程已重新加载"
        fi
            
        # 启用服务
        if ! sudo systemctl enable "$service_name.service" 2>/dev/null && ! systemctl enable "$service_name.service" 2>/dev/null; then
            echo "警告: 无法启用服务 $service_name"
            return 1
        else
            echo "服务 $service_name 已启用"
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
    
    # 检查配置文件是否存在
    if [ ! -f "$conf_file" ]; then
        echo "错误: 配置文件 $conf_file 不存在"
        return 1
    fi
    
    # 转义可能引起sed命令错误的特殊字符（仅对密码等文本字段）
    local escaped_password=$(printf '%s\n' "$password" | sed -e 's/[\/&]/\\&/g')
    
    # 使用正确的sed语法处理配置文件，确保路径中的特殊字符被正确处理
    $SED_CMD "s/^port .*/port $port/" "$conf_file"
    $SED_CMD "s/# requirepass foobared/requirepass $escaped_password/" "$conf_file"
    $SED_CMD "s/appendonly no/appendonly yes/" "$conf_file"
    $SED_CMD "s/bind 127.0.0.1/bind 0.0.0.0/" "$conf_file"
    $SED_CMD "s/# replica-read-only yes/replica-read-only no/" "$conf_file"
    
    # 处理日志目录
    local logfile_path="$INSTALL_DIR/logs/redis-$port.log"
    local system_logfile_path="$system_log_dir/redis-$port.log"
    
    # 检查是否使用系统日志目录
    if [[ ! "$logfile_path" =~ ^/var/log/ ]]; then
        read -t 8 -p "建议修改为系统日志目录: $system_logfile_path 是否修改? (Y/n): " confirm_modify
        echo
        if [[ "$confirm_modify" != [n] ]]; then
            logfile_path="$system_logfile_path"
            # 创建系统日志目录（需要sudo权限）
            if ! sudo mkdir -p "$system_log_dir" 2>/dev/null && ! mkdir -p "$system_log_dir" 2>/dev/null; then
                echo "警告: 无法创建系统日志目录 $system_log_dir，将使用原路径"
                logfile_path="$INSTALL_DIR/logs/redis-$port.log"
            else
                # 设置日志目录权限
                if ! sudo chown $(id -u):$(id -g) "$system_log_dir" 2>/dev/null && ! chown $(id -u):$(id -g) "$system_log_dir" 2>/dev/null; then
                    echo "警告: 无法设置日志目录权限"
                fi
            fi
        fi
    fi
    
    # 创建日志目录（如果使用默认路径）
    if [[ "$logfile_path" == "$INSTALL_DIR/logs/redis-$port.log" ]]; then
        mkdir -p "$INSTALL_DIR/logs"
    fi
    
    # 使用不同的分隔符处理包含路径的配置项，避免路径中的斜杠干扰sed命令
    $SED_CMD "s#dir ./#dir $INSTALL_DIR/data/$port#" "$conf_file" && mkdir -p "$INSTALL_DIR/data/$port"
    # 使用正则表达式替换日志文件路径，提高通用性
    $SED_CMD "s#logfile .*\.log#logfile $logfile_path#" "$conf_file"
    # 使用正则表达式替换pid文件路径，提高通用性
    $SED_CMD "s#pidfile .*\.pid#pidfile $INSTALL_DIR/redis-$port.pid#" "$conf_file"
    
    # 集群模式特有配置
    if [ "$is_cluster" = "yes" ]; then
        $SED_CMD "s/# cluster-enabled yes/cluster-enabled yes/" "$conf_file"
        $SED_CMD "s/# cluster-config-file nodes.conf/cluster-config-file nodes-$port.conf/" "$conf_file"
        $SED_CMD "s/# cluster-node-timeout 15000/cluster-node-timeout 15000/" "$conf_file"
        $SED_CMD "s/protected-mode yes/protected-mode no/" "$conf_file"
        $SED_CMD "s/# masterauth foobared/masterauth $escaped_password/" "$conf_file"
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


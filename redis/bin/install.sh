#!/usr/bin/env bash
# redis install script
# 用法: ./install.sh [INSTALL_DIR] [节点数] [端口] [REDIS_VERSION]

set -e
# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# 当前脚本父目录
BASE_DIR=$(cd "$SCRIPT_DIR/.."; pwd)
# Redis版本
redis_version=${4:-"8.0.3"}
# 下载地址和压缩包名
url="https://github.com/redis/redis/archive/refs/tags/${redis_version}.tar.gz"
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

echo "复制配置文件和脚本..." 
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' "$BASE_DIR/" "$INSTALL_DIR/"
else
    cp -rp "$BASE_DIR"/* "$INSTALL_DIR/"
fi
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

    # --- 密码处理开始 ---
    # 1. 为确保密码不冲突，首先删除所有以 requirepass 开头的行（无论是否被注释）
    $SED_CMD '/^[[:space:]]*requirepass/d' "$conf_file"

    # 2. 然后，在标准模板行下方，插入新的、唯一的密码配置
    $SED_CMD "/# requirepass foobared/a requirepass $escaped_password" "$conf_file"
    # --- 密码处理结束 ---

    $SED_CMD "s/appendonly no/appendonly yes/" "$conf_file"
    $SED_CMD "s/bind 127.0.0.1/bind 0.0.0.0/" "$conf_file"
    # 保持副本为只读，更安全
    #$SED_CMD "s/# replica-read-only yes/replica-read-only no/" "$conf_file"
    
    # --- 日志目录处理开始 ---
    # 从配置文件中读取当前的日志路径（忽略前导空格）
    current_logfile=$(grep -E '^[[:space:]]*logfile' "$conf_file" | awk '{print $2}')

    # 如果配置文件中没有日志路径，或者路径不是/var/log开头，则提示用户
    if [ -z "$current_logfile" ] || [[ ! "$current_logfile" =~ ^/var/log/ ]]; then
        system_logfile_path="$system_log_dir/redis-$port.log"
        read -t 10 -p "建议修改为系统日志目录: $system_logfile_path 是否修改? (Y/n): " confirm_modify || true
        echo
        if [[ "$confirm_modify" != [nN] ]]; then
            logfile_to_set="$system_logfile_path"
            # 优先使用sudo创建目录和文件，并设置正确的所有者
            if sudo mkdir -p "$system_log_dir" && sudo touch "$logfile_to_set" && sudo chown "$(id -u):$(id -g)" "$logfile_to_set"; then
                # 同时确保目录本身也属于当前用户，以便redis进程有权限访问
                sudo chown "$(id -u):$(id -g)" "$system_log_dir"
                echo "日志文件已在 $logfile_to_set 创建并设置好权限。"
            else
                echo "警告: 无法创建系统日志目录或文件，或无法设置权限。将使用安装目录下的logs/作为备用。"
                logfile_to_set="$INSTALL_DIR/logs/redis-$port.log"
            fi
        else
            logfile_to_set="$INSTALL_DIR/logs/redis-$port.log"
        fi
        
        # 更新配置文件中的日志路径
        logdir_to_set=$(dirname "$logfile_to_set")
        if [[ ! "$logfile_to_set" =~ ^/var/log/ ]]; then # 如果不是系统日志，则在安装目录下创建
             mkdir -p "$logdir_to_set"
        fi

        # 如果配置文件中已存在 logfile 行，则修改它，否则就添加新行
        if grep -q -E '^[[:space:]]*logfile' "$conf_file"; then
            $SED_CMD "s#^[[:space:]]*logfile .*#logfile $logfile_to_set#" "$conf_file"
        else
            echo "logfile $logfile_to_set" >> "$conf_file"
        fi
    else
        echo "日志文件已配置为系统路径: $current_logfile，无需修改。"
    fi
    # --- 日志目录处理结束 ---
    # 使用正则表达式替换pid文件路径，提高通用性
    $SED_CMD "s#pidfile .*\.pid#pidfile $INSTALL_DIR/redis-$port.pid#" "$conf_file"
    
    # 集群模式特有配置
    if [ "$is_cluster" = "yes" ]; then
        $SED_CMD "s/# cluster-enabled yes/cluster-enabled yes/" "$conf_file"
        $SED_CMD "s/# cluster-config-file nodes.conf/cluster-config-file nodes-$port.conf/" "$conf_file"
        $SED_CMD "s/# cluster-node-timeout 15000/cluster-node-timeout 15000/" "$conf_file"
        $SED_CMD "s/protected-mode yes/protected-mode no/" "$conf_file"
        $SED_CMD "s/# masterauth foobared/masterauth $escaped_password/" "$conf_file"
    else
        # 单机模式下，如果bind 0.0.0.0，也禁用保护模式
        $SED_CMD "s/protected-mode yes/protected-mode no/" "$conf_file"    
    fi
}

# 设置环境变量
setup_environment() {
    echo "正在配置环境变量..."

    # 优先尝试在 /etc/profile.d 中进行系统级配置
    if [ -d "/etc/profile.d" ]; then
        if [ -w "/etc/profile.d" ] || sudo -n true 2>/dev/null; then
            echo "检测到 sudo 权限或 /etc/profile.d 写权限，将进行系统级配置。"
            local profile_script="/etc/profile.d/redis.sh"
            # 使用 sudo tee 写入文件，以处理权限问题
            sudo tee "$profile_script" > /dev/null << EOF
#!/bin/sh
export REDIS_HOME=${INSTALL_DIR}
export PATH=$REDIS_HOME/bin:$PATH
EOF
            sudo chmod +x "$profile_script"
            echo "环境变量已配置,加载配置执行: source $profile_script"
            echo -e "\033[33m或启动新 shell 以使配置生效。\033[0m"
            return
        fi
    fi

    # 如果系统级配置失败，则回退到用户级配置
    echo "警告: 无 sudo 权限或无法写入 /etc/profile.d。"
    echo "将回退到用户级别配置 (~/.bashrc, ~/.zshrc)..."
    
    local shell_type
    shell_type=$(basename "$SHELL")
    local rc_file

    if [ "$shell_type" = "bash" ]; then
        rc_file="$HOME/.bashrc"
    elif [ "$shell_type" = "zsh" ]; then
        rc_file="$HOME/.zshrc"
    else
        echo "不支持的 shell 类型: $shell_type"
        echo "请手动将以下内容添加到您的 shell 配置文件中:"
        echo "export REDIS_HOME=$INSTALL_DIR"
        echo 'export PATH=$REDIS_HOME/bin:$PATH'
        return
    fi

    # 检查并设置 REDIS_HOME
    if grep -q "export REDIS_HOME=" "$rc_file"; then
        # 如果存在，则更新
        sed -i.bak "s|export REDIS_HOME=.*|export REDIS_HOME=$INSTALL_DIR|g" "$rc_file"
        echo "已更新 $rc_file 中的 REDIS_HOME"
    else
        # 如果不存在，则添加
        echo "" >> "$rc_file"
        echo "export REDIS_HOME=$INSTALL_DIR" >> "$rc_file"
        echo "已将 REDIS_HOME 添加到 $rc_file"
    fi
    
    # 检查并设置 PATH
    # 使用更健壮的方式检查 $REDIS_HOME/bin 是否已在 PATH 中
    if ! grep -q 'export PATH=.*$REDIS_HOME/bin' "$rc_file"; then
        echo 'export PATH=$REDIS_HOME/bin:$PATH' >> "$rc_file"
        echo "已将 Redis bin 目录添加到 $rc_file 的 PATH 中"
    else
        echo "PATH 配置已包含 Redis bin 目录，无需修改。"
    fi
	
    echo -e "\033[33m请运行 source $rc_file 或重新启动终端使配置生效。\033[0m"
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
    echo "提示: 可以使用以下命令修改密码 (将 NEW_PASSWORD 替换为新密码):"
    echo "  redis-cli -a '$password' -p $port config set requirepass NEW_PASSWORD"
    
    echo "正在启动所有集群节点..."
    $INSTALL_DIR/bin/startup.sh "$num" "$port"
    
    echo "等待节点启动..."
    sleep 8 # 等待几秒钟确保所有进程已启动

    echo "正在创建集群..."
    # 使用 expect 来处理 redis-cli 的交互式输入
    if command -v expect >/dev/null 2>&1; then
        expect <<EOF
spawn $INSTALL_DIR/bin/redis-cli --cluster create $cluster_nodes --cluster-replicas 1 -a "$password"
expect "Type 'yes' to accept):"
send "yes\r"
expect eof
EOF
    else
        echo "警告: 'expect' 命令未安装。请手动执行以下命令创建集群:"
        echo "$INSTALL_DIR/bin/redis-cli --cluster create $cluster_nodes --cluster-replicas 1 -a \"$password\""
        echo "并在提示时输入 'yes'"
    fi

    echo "✅ Redis 集群已创建成功！"
    
else
    # 单机模式
    conf_file=$INSTALL_DIR/conf/redis.conf
    # 处理配置文件
    handle_config "$conf_file" "$port" "no" "$password"
    # 安装服务
    install-service "$INSTALL_DIR" "$conf_file" "redis" "$port"
    
    echo "✅ Redis 单机模式已初始化，端口: $port"
    echo "生成的密码: $password"
    echo "提示: 您可以使用以下命令修改密码 (将 NEW_PASSWORD 替换为您的新密码):"
    echo "  $INSTALL_DIR/bin/redis-cli -a '$password' -p $port config set requirepass NEW_PASSWORD"
	  
	# 动态安装配置完成后调用安装目录下的启动脚本
	if [ -f "$INSTALL_DIR/bin/startup.sh" ] && [ -x "$INSTALL_DIR/bin/startup.sh" ]; then
	  echo "正在停止任何可能在运行的旧 Redis 实例..."
	  # 允许停止失败（例如，如果服务本来就没在运行），并等待2秒确保端口释放
	  $INSTALL_DIR/bin/stop.sh || true
	  sleep 2

	  echo "正在启动 Redis..."
	  # 将配置文件路径作为第3个参数传递给 startup.sh
	  $INSTALL_DIR/bin/startup.sh "$num" "$port" "$conf_file"
	else
	  echo "提示: 您可以手动执行以下命令启动 Redis:"
	  echo "  $INSTALL_DIR/bin/startup.sh"
	fi
fi

# 设置环境变量
setup_environment

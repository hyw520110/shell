#!/usr/bin/env bash
# redis启动脚本

num=${1:-1}
port=${2:-6379}
conf_to_use=${3} # 接收第三个参数作为指定配置文件

CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}
conf_dir="$BASE_DIR/conf"
# 系统日志目录
system_log_dir=/var/log/redis

# 检测操作系统类型
OS_TYPE=$(uname)

# 检查安装目录权限
check_install_permissions() {
    local install_dir="$1"
    if [ ! -w "$install_dir" ]; then
        echo "错误: 没有对安装目录 $install_dir 的写权限"
        read -p "是否尝试修复权限? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # 尝试修复权限
            if [[ "$OS_TYPE" == "Darwin" ]]; then
                sudo chown -R $(whoami) "$install_dir"
            else
                sudo chown -R $(id -u):$(id -g) "$install_dir"
            fi
            chmod -R 755 "$install_dir"
            
            # 再次检查权限
            if [ ! -w "$install_dir" ]; then
                echo "权限修复失败，请手动修复权限或选择其他安装目录"
                return 1
            fi
        else
            echo "请手动修复权限或选择其他安装目录"
            return 1
        fi
    fi
    return 0
}

# 启动 redis-server 并打印进程
startup(){
    local conf_file="$1"
    
    # 检查配置文件是否存在
    if [ ! -f "$conf_file" ]; then
        echo "错误: 配置文件不存在: $conf_file"
        return 1
    fi
    
    # 获取日志文件路径
    local logfile=$(grep "^logfile " "$conf_file" | awk '{print $2}')
    
    # 如果配置文件中没有指定日志文件，则使用默认路径
    if [ -z "$logfile" ]; then
        logfile="$BASE_DIR/logs/redis.log"
    fi
    
    # 确保日志目录存在且有权限
    local logdir=$(dirname "$logfile")
    if [ ! -d "$logdir" ]; then
        echo "正在创建日志目录: $logdir"
        if [[ "$logdir" == /var/log/* ]]; then
            # 系统日志目录需要sudo权限
            if ! sudo mkdir -p "$logdir" 2>/dev/null && ! mkdir -p "$logdir" 2>/dev/null; then
                echo "警告: 无法创建日志目录 $logdir"
            fi
        else
            mkdir -p "$logdir"
        fi
    fi
    
    # 检查日志目录权限
    if [ ! -w "$logdir" ]; then
        echo "警告: 没有对日志目录 $logdir 的写权限"
    fi
    
    $BASE_DIR/bin/redis-server "$conf_file"
    
    # 等待Redis启动
    sleep 2
    
    if is_redis_running; then
        echo "Redis 启动成功，进程信息如下："
        ps -ef|grep "redis-server"|grep -v grep
        echo "日志文件位置: $logfile"
    else
        echo "Redis 启动失败，请检查配置和日志"
        # 显示systemd状态（如果使用systemd）
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status redis.service --no-pager 2>/dev/null || echo "未找到redis systemd服务"
        fi
        return 1
    fi
}

# 如果通过参数指定了配置文件，则直接使用它启动
if [ -n "$conf_to_use" ] && [ -f "$conf_to_use" ]; then
    echo "正在使用指定的配置文件启动: $conf_to_use"
    # 需要 is_redis_running 函数，所以要先定义或移到前面
    is_redis_running() {
      [ `ps -ef|grep "redis-server"|grep -v grep|wc -l` -gt 0 ]
    }
    if is_redis_running; then
      echo "Redis 已经启动，进程信息如下："
      ps -ef|grep $BASE_DIR|grep -v grep
      exit 0
    fi
    startup "$conf_to_use"
    exit $?
fi

cd $BASE_DIR

# 检查安装目录权限
if ! check_install_permissions "$BASE_DIR"; then
    exit 1
fi

# 检查 redis-server 是否存在
if [ ! -f $BASE_DIR/bin/redis-server ] || [ ! -x $BASE_DIR/bin/redis-server ]; then
    echo "未找到可执行的 redis-server，正在尝试安装..."
    # 调用安装目录下的安装脚本
    if [ -f "$BASE_DIR/bin/install.sh" ] && [ -x "$BASE_DIR/bin/install.sh" ]; then
        "$BASE_DIR/bin/install.sh" /opt/redis $num $port
    else
        echo "错误: 未找到可执行的安装脚本"
        exit 1
    fi
fi

# 检查进程是否已启动
is_redis_running() {
    # 更准确地检测Redis进程是否运行，只检测redis-server进程
    [ `ps -ef|grep "redis-server"|grep -v grep|wc -l` -gt 0 ]
}

# systemd 启动服务并打印状态
start_systemd_services() {
    # macOS系统不支持systemd
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "macOS系统不支持systemd服务"
        return 1
    fi
    
    local svcs="$1"
    local desc="$2"
    echo "$desc：$svcs，正在启动..."
    for svc in $svcs; do
        sudo systemctl start $svc
        sudo systemctl status $svc --no-pager
    done
}

# 启动 redis-server 并打印进程
startup(){
    local conf_file="$1"
    
    # 检查配置文件是否存在
    if [ ! -f "$conf_file" ]; then
        echo "错误: 配置文件不存在: $conf_file"
        return 1
    fi
    
    # 获取日志文件路径
    local logfile=$(grep "^logfile " "$conf_file" | awk '{print $2}')
    
    # 如果配置文件中没有指定日志文件，则使用默认路径
    if [ -z "$logfile" ]; then
        logfile="$BASE_DIR/logs/redis.log"
    fi
    
    # 确保日志目录存在且有权限
    local logdir=$(dirname "$logfile")
    if [ ! -d "$logdir" ]; then
        echo "正在创建日志目录: $logdir"
        if [[ "$logdir" == /var/log/* ]]; then
            # 系统日志目录需要sudo权限
            if ! sudo mkdir -p "$logdir" 2>/dev/null && ! mkdir -p "$logdir" 2>/dev/null; then
                echo "警告: 无法创建日志目录 $logdir"
            fi
        else
            mkdir -p "$logdir"
        fi
    fi
    
    # 检查日志目录权限
    if [ ! -w "$logdir" ]; then
        echo "警告: 没有对日志目录 $logdir 的写权限"
    fi
    
    $BASE_DIR/bin/redis-server "$conf_file"
    
    # 等待Redis启动
    sleep 2
    
    if is_redis_running; then
        echo "Redis 启动成功，进程信息如下："
        ps -ef|grep "redis-server"|grep -v grep
        echo "日志文件位置: $logfile"
    else
        echo "Redis 启动失败，请检查配置和日志"
        # 显示systemd状态（如果使用systemd）
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status redis.service --no-pager 2>/dev/null || echo "未找到redis systemd服务"
        fi
        return 1
    fi
}

# 启动集群所有节点
start_cluster_nodes() {
    local confs=("$@")
    local host=""
    for conf in "${confs[@]}"; do
        p=$(grep '^port ' "$conf" | awk '{print $2}')
        # 根据操作系统使用不同的netstat命令
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            [ `netstat -an 2>/dev/null | grep "\.$p " | wc -l` -gt 0 ] && echo "端口 $p 已被占用，跳过该节点。" && continue
        else
            [ `netstat -tunlp 2>/dev/null | grep $p | wc -l` -gt 0 ] && echo "端口 $p 已被占用，跳过该节点。" && continue
        fi
        $CURRENT_DIR/redis-server "$conf"
        host+="127.0.0.1:$p "
    done
    echo "如需自动创建集群请手动执行："
    echo "$CURRENT_DIR/redis-cli --cluster create $host --cluster-replicas 1 -a <password>"
}

# 1. 查找所有 systemd redis 服务，匹配安装目录，提取配置文件
find_redis_services_and_confs() {
    # macOS系统不支持systemd
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "|"
        return
    fi
    
    local match_dir="$BASE_DIR"
    local confs=()
    local svcs=()
    for svc in $(systemctl list-unit-files 2>/dev/null | grep -E '^redis.*\.service' | awk '{print $1}'); do
        exec_line=$(systemctl cat $svc 2>/dev/null | grep ExecStart | grep "$match_dir/bin/redis-server")
        conf_file=$(systemctl cat $svc 2>/dev/null | grep ExecStart | grep -oE '[^ ]+\.conf')
        if [ -n "$exec_line" ] && [ -f "$conf_file" ]; then
            confs+=("$conf_file")
            svcs+=("$svc")
        fi
    done
    echo "${confs[*]}|${svcs[*]}"
}

# 2. 查找安装目录下所有 redis 配置文件
find_local_confs() {
    find "$conf_dir" -maxdepth 1 -type f -name 'redis*.conf'
}

# 3. 判断单个配置文件是单机还是集群
# 返回 single/cluster/none
# 单机: cluster-enabled no 或未开启
# 集群: cluster-enabled yes
# none: 配置文件不存在

detect_mode_by_conf() {
    local conf="$1"
    [ ! -f "$conf" ] && echo none && return
    if grep -q '^cluster-enabled[[:space:]]*yes' "$conf"; then
        echo cluster
    else
        echo single
    fi
}

# 汇总所有配置文件类型，返回 single/cluster/both/none
# 参数: 配置文件列表

detect_mode_by_confs() {
    local has_single=0
    local has_cluster=0
    for conf in "$@"; do
        mode=$(detect_mode_by_conf "$conf")
        [ "$mode" = "single" ] && has_single=1
        [ "$mode" = "cluster" ] && has_cluster=1
    done
    if [ $has_single -eq 1 ] && [ $has_cluster -eq 0 ]; then
        echo single
    elif [ $has_single -eq 0 ] && [ $has_cluster -eq 1 ]; then
        echo cluster
    elif [ $has_single -eq 1 ] && [ $has_cluster -eq 1 ]; then
        echo both
    else
        echo none
    fi
}

# 已启动则打印进程并退出
if is_redis_running; then
    echo "Redis 已经启动，进程信息如下："
    ps -ef|grep $BASE_DIR|grep -v grep
    exit 0
fi

if [ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ] && [ `docker-compose ps 2>/dev/null |grep -Ev "NAME|exited"|grep running|grep -v grep|wc -l` -gt 0 ]; then
    echo "检测到 Redis Docker 服务已启动："
    docker-compose ps 2>/dev/null
    exit 0
fi

[ `netstat -tunlp 2>/dev/null | grep $port |grep -v grep| wc -l` -gt 0 ] && echo "端口 $port 已被占用，无法启动。" && exit 0

# 优先 systemd 服务方式
svc_confs_and_svcs=$(find_redis_services_and_confs)
svc_confs=( $(echo "$svc_confs_and_svcs" | cut -d'|' -f1) )
svcs=( $(echo "$svc_confs_and_svcs" | cut -d'|' -f2) )
mode=
if [ ${#svc_confs[@]} -gt 0 ]; then
    mode=$(detect_mode_by_confs "${svc_confs[@]}")
    if [ "$mode" = "single" ]; then
        start_systemd_services "${svcs[*]}" "检测到单机 systemd 服务"
        [ $? -eq 0 ] && exit 0
    elif [ "$mode" = "cluster" ]; then
        start_systemd_services "${svcs[*]}" "检测到集群 systemd 服务"
        [ $? -eq 0 ] && exit 0
    elif [ "$mode" = "both" ]; then
        if [ "$num" -gt 1 ]; then
            start_systemd_services "${svcs[*]}" "检测到单机和集群 systemd 服务，num=$num，选择启动集群服务"
        else
            start_systemd_services "${svcs[*]}" "检测到单机和集群 systemd 服务，num=$num，选择启动单机服务"
        fi
        [ $? -eq 0 ] && exit 0
    fi
fi

# 本地配置文件方式
local_confs=( $(find_local_confs) )
mode=$(detect_mode_by_confs "${local_confs[@]}")
if [ "$mode" = "single" ]; then
    echo "检测到单机模式配置。"
    startup "${local_confs[0]}"
elif [ "$mode" = "cluster" ]; then
    echo "检测到集群模式配置。"
    start_cluster_nodes "${local_confs[@]}"
elif [ "$mode" = "both" ]; then
    if [ "$num" -gt 1 ]; then
        echo "检测到单机和集群配置，num=$num，选择集群模式。"
        start_cluster_nodes "${local_confs[@]}"
    else
        echo "检测到单机和集群配置，num=$num，选择单机模式。"
        startup "${local_confs[0]}"
    fi
else
    # 如果没有找到配置文件，尝试使用默认配置文件
    default_conf="$BASE_DIR/conf/redis.conf"
    if [ -f "$default_conf" ]; then
        echo "使用默认配置文件启动单机模式。"
        startup "$default_conf"
    else
        echo "未检测到有效的 Redis 配置文件，请检查 $conf_dir 目录。" >&2
        exit 1
    fi
fi

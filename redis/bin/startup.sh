#!/usr/bin/env bash
# redis启动脚本

num=${1:-1}
port=${2:-6379}
CURRENT_DIR=`cd $(dirname $0); pwd -P`
BASE_DIR=${CURRENT_DIR%/*}
conf_dir="$BASE_DIR/conf"
log_dir=/var/log/redis

cd $BASE_DIR

# 检查 redis-server 是否存在
[ ! -f $CURRENT_DIR/redis-server ] && ./install.sh /opt/redis $num $port

# 检查进程是否已启动
is_redis_running() {
    [ `ps -ef|grep $BASE_DIR|grep -v grep|wc -l` -gt 0 ]
}

# systemd 启动服务并打印状态
start_systemd_services() {
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
    $CURRENT_DIR/redis-server $1
    if is_redis_running; then
        echo "Redis 启动成功，进程信息如下："
        ps -ef|grep $BASE_DIR|grep -v grep
    fi
}

# 启动集群所有节点
start_cluster_nodes() {
    local confs=("$@")
    local host=""
    for conf in "${confs[@]}"; do
        p=$(grep '^port ' "$conf" | awk '{print $2}')
        [ `netstat -tunlp | grep $p | wc -l` -gt 0 ] && echo "端口 $p 已被占用，跳过该节点。" && continue
        $CURRENT_DIR/redis-server "$conf"
        host+="127.0.0.1:$p "
    done
    echo "如需自动创建集群请手动执行："
    echo "$CURRENT_DIR/redis-cli --cluster create $host --cluster-replicas 1 -a <password>"
}

# 1. 查找所有 systemd redis 服务，匹配安装目录，提取配置文件
find_redis_services_and_confs() {
    local match_dir="$BASE_DIR"
    local confs=()
    local svcs=()
    for svc in $(systemctl list-unit-files | grep -E '^redis.*\\.service' | awk '{print $1}'); do
        exec_line=$(systemctl cat $svc 2>/dev/null | grep ExecStart | grep "$match_dir/bin/redis-server")
        conf_file=$(systemctl cat $svc 2>/dev/null | grep ExecStart | grep -oE '[^ ]+\\.conf')
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

if [ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ] && [ `docker-compose ps |grep -Ev "NAME|exited"|grep running|grep -v grep|wc -l` -gt 0 ]; then
    echo "检测到 Redis Docker 服务已启动："
    docker-compose ps
    exit 0
fi

[ `netstat -tunlp | grep $port |grep -v grep| wc -l` -gt 0 ] && echo "端口 $port 已被占用，无法启动。" && exit 0

# 优先 systemd 服务方式
svc_confs_and_svcs=$(find_redis_services_and_confs)
svc_confs=( $(echo "$svc_confs_and_svcs" | cut -d'|' -f1) )
svcs=( $(echo "$svc_confs_and_svcs" | cut -d'|' -f2) )
mode=
if [ ${#svc_confs[@]} -gt 0 ]; then
    mode=$(detect_mode_by_confs "${svc_confs[@]}")
    if [ "$mode" = "single" ]; then
        start_systemd_services "${svcs[*]}" "检测到单机 systemd 服务"
        exit 0
    elif [ "$mode" = "cluster" ]; then
        start_systemd_services "${svcs[*]}" "检测到集群 systemd 服务"
        exit 0
    elif [ "$mode" = "both" ]; then
        if [ "$num" -gt 1 ]; then
            start_systemd_services "${svcs[*]}" "检测到单机和集群 systemd 服务，num=$num，选择启动集群服务"
        else
            start_systemd_services "${svcs[*]}" "检测到单机和集群 systemd 服务，num=$num，选择启动单机服务"
        fi
        exit 0
    fi
fi

# 本地配置文件方式
local_confs=( $(find_local_confs) )
mode=$(detect_mode_by_confs "${local_confs[@]}")
if [ "$mode" = "single" ]; then
    echo "检测到单机模式配置。"
    logfile=`cat ${local_confs[0]} |grep "logfile "|awk '{print $2}'`
    [ ! -d ${logfile%/*} ] && mkdir -p ${logfile%/*}
    startup ${local_confs[0]}
elif [ "$mode" = "cluster" ]; then
    echo "检测到集群模式配置。"
    start_cluster_nodes "${local_confs[@]}"
elif [ "$mode" = "both" ]; then
    if [ "$num" -gt 1 ]; then
        echo "检测到单机和集群配置，num=$num，选择集群模式。"
        start_cluster_nodes "${local_confs[@]}"
    else
        echo "检测到单机和集群配置，num=$num，选择单机模式。"
        logfile=`cat ${local_confs[0]} |grep "logfile "|awk '{print $2}'`
        [ ! -d ${logfile%/*} ] && mkdir -p ${logfile%/*}
        startup ${local_confs[0]}
    fi
else
    echo "未检测到有效的 Redis 配置文件，请检查 $conf_dir 目录。" >&2
    exit 1
fi

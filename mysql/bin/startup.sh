#!/bin/bash
# mysql启动脚本

# 日志函数
log() {
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a $BASE_DIR/logs/startup.log
}

# 初始化环境
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR || { log "无法切换到BASE_DIR目录"; exit 1; }

# 创建日志目录
mkdir -p $BASE_DIR/logs

# 校验配置文件
cnf=$BASE_DIR/conf/my.cnf
if [ ! -f "$cnf" ]; then
  log "配置文件 $cnf 不存在"
  exit 1
fi

# 从配置文件中提取端口号和数据目录
port=$(grep '^port' "$cnf" | head -n 1 | cut -d'=' -f2 | xargs)
datadir=$(grep '^datadir' "$cnf" | cut -d'=' -f2 | xargs)

# 进程已启动时 提示退出
if pgrep -f "$BASE_DIR/bin/mysqld" > /dev/null; then
  log "mysql 已经启动"
  exit 0
fi

# 端口占用时 提示退出
if netstat -tlnp | grep ":$port" > /dev/null; then
  log "端口 $port 已被占用"
  exit 1
fi

# 检查Docker环境
if which docker > /dev/null 2>&1; then
  name=$(grep -m 1 'container_name:' "$BASE_DIR/docker-compose.yml" 2>/dev/null | awk -F': ' '{print $2}')
  if [ -n "$name" ] && docker ps -a 2>/dev/null | grep -q "$name"; then
    log "检测到Docker环境，启动容器..."
    docker-compose up -d
    exit 0
  fi
fi

# 检查并创建配置文件中的所有路径
create_dirs() {
  local config_file=$1
  local user=$2

  # 提取所有路径
  while IFS='= ' read -r key value; do
    if [[ $value =~ ^/ ]]; then
      dir=$(dirname "$value")
      if [ ! -d "$dir" ]; then
        log "创建目录: $dir"
        mkdir -p "$dir"
        chown -R "$user:$user" "$dir"
        chmod -R 755 "$dir"
      fi
      if [ ! -d "$value" ] && [ ! -f "$value" ]; then
        log "创建文件: $value"
        touch "$value"
        chown "$user:$user" "$value"
        chmod 644 "$value"
      fi
    fi
  done < <(grep -E '^[^#].*=' "$config_file")
}

# 主启动逻辑
if [ ! -f "$BASE_DIR/bin/mysqld_safe" ]; then
  log "mysqld_safe 不存在，执行安装..."
  $CURRENT_DIR/install.sh || { log "安装失败"; exit 1; }
else
  # 替换配置文件中的路径
  sed -i "s#/opt/mysql#$BASE_DIR#g" $cnf

  usr=$(grep '^user' "$cnf" | cut -d'=' -f2 | xargs)
  
  # 检查并创建配置文件中的所有路径
  create_dirs "$cnf" "$usr"

  # 更改 MySQL 目录权限
  chown -R "$usr:$usr" "$BASE_DIR"
  chmod -R 755 $BASE_DIR/data
  
  # 启动 MySQL
  log "启动MySQL..."
  shell="$BASE_DIR/bin/mysqld_safe --defaults-file="$cnf" --user="$usr" &"
  eval $shell
  
  # 检查启动结果
  sleep 5
  if pgrep -f "$BASE_DIR/bin/mysqld" > /dev/null; then
    log "MySQL启动成功"
  else
    log "MySQL启动失败"
    exit 1
  fi
fi
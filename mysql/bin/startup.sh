#!/bin/bash
# mysql启动脚本
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=${CURRENT_DIR%/*}
cd $BASE_DIR
cnf=$BASE_DIR/conf/my.cnf

# 从配置文件中提取端口号和数据目录
port=$(grep '^port' "$cnf" | head -n 1 | cut -d'=' -f2 | xargs)
datadir=$(grep '^datadir' "$cnf" | cut -d'=' -f2 | xargs)

# 进程已启动时 提示退出
if pgrep -f "$BASE_DIR/bin/mysqld" > /dev/null; then
  echo "mysql has been started!"
  exit 0
fi

# 端口占用时 提示退出
if netstat -tlnp | grep ":$port" > /dev/null; then
  echo "port $port is already in use"
  exit 0
fi

if [ -f "$BASE_DIR/docker-compose.yml" ]; then
  name=$(grep -m 1 'container_name:' "$BASE_DIR/docker-compose.yml" | awk -F': ' '{print $2}')
  if docker ps -a 2>/dev/null | grep -q "$name"; then
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
        echo "创建目录: $dir"
        mkdir -p "$dir"
        chown -R "$user:$user" "$dir"
        chmod -R 777 "$dir"
      fi
      if [ ! -d "$value" ] && [ ! -f "$value" ]; then
        echo "创建文件: $value"
        touch "$value"
        chown "$user:$user" "$value"
        chmod 666 "$value"
      fi
    fi
  done < <(grep -E '^[^#].*=' "$config_file")
}
# 检查数据目录是否存在且不为空，以及 mysqld_safe 是否存在
if [ ! -f "$BASE_DIR/bin/mysqld_safe" ]; then
  $CURRENT_DIR/install.sh
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
  shell="$BASE_DIR/bin/mysqld_safe --defaults-file="$cnf" --user="$usr"  &"
  echo "安全启动:$shell"
  eval $shell
  if [ $? -ne 0 ]; then
    echo "mysql启动失败，检查错误日志!"
    exit 1
  fi

  # 等待一段时间，确保 MySQL 完全启动
  sleep 5

  # 检查 MySQL 是否成功启动
  if pgrep -f "$BASE_DIR/bin/mysqld" > /dev/null; then
    echo "mysql启动成功!"
  else
    echo "mysql启动失败，检查错误日志!"
    exit 1
  fi
fi
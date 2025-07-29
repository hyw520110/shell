#!/bin/bash
# mysql启动脚本

# 检查是否以root或sudo运行，如果不是则自动使用sudo重新运行
if [ "$EUID" -ne 0 ] && [ -z "$ALREADY_ELEVATED" ]; then
  echo "需要root权限来启动MySQL服务，正在使用sudo执行..."
  export ALREADY_ELEVATED=true
  sudo -E "$0" "$@"
  exit $?
fi

# 获取当前脚本的绝对路径（解析符号链接）
SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(dirname "$SOURCE")"
# 通过find_mysql.sh查找安装目录
#SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR="$(bash "$SCRIPT_DIR/find_mysql.sh" "$1")"
if [ -z "$INSTALL_DIR" ]; then
  echo "未找到MySQL安装目录，退出。"
  exit 1
fi

# 日志目录和日志文件
LOG_DIR="/var/log/mysql"
LOG_FILE="$LOG_DIR/startup.log"
SED_INPLACE_OPT=""
if [ "$OS" == "Darwin" ]; then
  SED_INPLACE_OPT="''"
fi
# 日志函数
log() {
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# 初始化环境
cd "$INSTALL_DIR" || { log "无法切换到INSTALL_DIR目录"; exit 1; }

# 创建系统日志目录
mkdir -p "$LOG_DIR"

# 校验配置文件
cnf=$INSTALL_DIR/conf/my.cnf
if [ ! -f "$cnf" ]; then
  log "配置文件 $cnf 不存在"
  exit 1
fi

# 从配置文件中提取端口号和数据目录
# 从配置文件中提取端口号、数据目录和socket路径
port=$(grep '^port' "$cnf" | head -n 1 | cut -d'=' -f2 | xargs)
datadir=$(grep '^datadir' "$cnf" | cut -d'=' -f2 | xargs)
socket_path=$(grep '^socket' "$cnf" | head -n 1 | cut -d'=' -f2 | xargs)

# 进程已启动时 提示退出
if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
  log "mysql 已经启动"
  exit 0
fi

# 端口占用时 提示退出
if [ "$(uname)" == "Linux" ]; then
  if netstat -tlnp | grep ":$port" > /dev/null; then
    log "端口 $port 已被占用"
    exit 1
  fi
elif [ "$(uname)" == "Darwin" ]; then
  if lsof -i :$port > /dev/null; then
    log "端口 $port 已被占用"
    exit 1
  fi
fi

# 检查Docker环境
if which docker > /dev/null 2>&1; then
  name=$(grep -m 1 'container_name:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | awk -F': ' '{print $2}')
  if [ -n "$name" ] && docker ps -a 2>/dev/null | grep -q "$name"; then
    log "检测到Docker环境，启动容器..."
    if [ "$EUID" -ne 0 ] && groups | grep -q docker; then
      # 用户在docker组中，可以直接运行docker命令
      docker-compose up -d
    else
      # 用户不在docker组中或以root运行，使用sudo运行docker命令
      sudo -u "#$(id -u)" -g "#$(id -g)" docker-compose up -d
    fi
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
      
    fi
  done < <(grep -E '^[^#].*=' "$config_file")
}

# 主启动逻辑
if [ ! -f "$INSTALL_DIR/bin/mysqld_safe" ]; then
  log "mysqld_safe 不存在，执行安装..."
  $SCRIPT_DIR/install.sh || { log "安装失败"; exit 1; }
else
  echo "当前根路径：$INSTALL_DIR"
  usr=$(grep '^user' "$cnf" | cut -d'=' -f2 | xargs)

  # 检查并创建配置文件中的所有路径
  create_dirs "$cnf" "$usr"

  # 更改 MySQL 目录权限
  chown -R "$usr:$usr" "$INSTALL_DIR"
  chmod -R 755 $INSTALL_DIR/data

  # 启动 MySQL
  log "启动MySQL..."
  shell="$INSTALL_DIR/bin/mysqld_safe --defaults-file=$cnf --user=$usr --socket=$socket_path &"
  eval $shell

  # 检查启动结果
  sleep 5
  if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
    log "MySQL启动成功"
  else
    log "MySQL启动失败"
    exit 1
  fi
fi
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

check_mysql_running() {
  # 检查MySQL进程是否运行
  if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
    return 0  # 运行中
  else
    return 1  # 未运行
  fi
}

check_port_occupied() {
  # 检查端口是否被占用
  if [ "$(uname)" == "Linux" ]; then
    if netstat -tlnp 2>/dev/null | grep ":$port " > /dev/null; then
      return 0  # 被占用
    fi
  elif [ "$(uname)" == "Darwin" ]; then
    if lsof -i :$port > /dev/null 2>&1; then
      return 0  # 被占用
    fi
  fi
  return 1  # 未占用
}

startup_check() {
  log "开始启动检查..."
  
  # 检查MySQL是否已经运行
  if check_mysql_running; then
    log "MySQL已经在运行"
    log "进程信息:"
    pgrep -f "$INSTALL_DIR/bin/mysqld" | xargs ps -p
    exit 0
  fi

  # 检查端口占用
  if check_port_occupied; then
    log "端口 $port 已被其他进程占用"
    if [ "$(uname)" == "Linux" ]; then
      netstat -tlnp 2>/dev/null | grep ":$port "
    elif [ "$(uname)" == "Darwin" ]; then
      lsof -i :$port
    fi
    log "请检查端口占用情况或修改配置文件中的端口号"
    exit 1
  fi

  log "启动检查完成，准备启动MySQL..."
}

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

# 执行启动检查
startup_check

# 主启动逻辑
if [ ! -f "$INSTALL_DIR/bin/mysqld_safe" ]; then
  log "mysqld_safe 不存在，请先运行安装脚本: $SCRIPT_DIR/install.sh"
  exit 1
fi

log "当前MySQL安装目录：$INSTALL_DIR"
usr=$(grep '^user' "$cnf" | cut -d'=' -f2 | xargs)

# 如果未指定用户，使用默认用户
if [ -z "$usr" ]; then
  if [ "$(uname)" == "Darwin" ]; then
    usr="_mysql"
  else
    usr="mysql"
  fi
  log "配置文件中未指定用户，使用默认用户: $usr"
fi

# 检查并创建配置文件中的所有路径
create_dirs "$cnf" "$usr"

# 清理可能存在的PID文件
if [ -f "$datadir/mysqld.pid" ]; then
  log "清理旧的PID文件"
  rm -f "$datadir/mysqld.pid" 2>/dev/null || {
    log "警告：无法删除PID文件 $datadir/mysqld.pid"
  }
fi

# 安全设置目录权限
safe_set_permissions() {
  log "设置目录权限..."
  
  # 设置基本目录权限
  chown -R "$usr:$usr" "$INSTALL_DIR" 2>/dev/null || {
    log "警告：部分文件权限设置失败"
  }
  
  # 只对静态文件设置权限，避免修改运行时文件
  if [ -d "$INSTALL_DIR/data" ]; then
    find "$INSTALL_DIR/data" -type d -exec chmod 755 {} \; 2>/dev/null
    find "$INSTALL_DIR/data" -name "*.frm" -exec chmod 644 {} \; 2>/dev/null
    find "$INSTALL_DIR/data" -name "*.MYD" -exec chmod 644 {} \; 2>/dev/null
    find "$INSTALL_DIR/data" -name "*.MYI" -exec chmod 644 {} \; 2>/dev/null
  fi
}

safe_set_permissions

# 启动 MySQL
log "启动MySQL服务..."
shell="$INSTALL_DIR/bin/mysqld_safe --defaults-file=$cnf --user=$usr --socket=$socket_path &"
log "执行命令: $shell"
eval $shell

# 等待启动并检查结果
log "等待MySQL启动..."
sleep 5

# 检查启动结果
if check_mysql_running; then
  log "MySQL启动成功"
  log "MySQL进程:"
  pgrep -f "$INSTALL_DIR/bin/mysqld" | xargs ps -p
  log "端口监听:"
  if [ "$(uname)" == "Linux" ]; then
    netstat -tlnp 2>/dev/null | grep ":$port " || log "端口信息获取失败"
  elif [ "$(uname)" == "Darwin" ]; then
    lsof -i :$port 2>/dev/null || log "端口信息获取失败"
  fi
else
  log "MySQL启动失败，请检查错误日志"
  if [ -f "/var/log/mysql/error.log" ]; then
    log "错误日志内容:"
    tail -n 20 /var/log/mysql/error.log
  fi
  exit 1
fi
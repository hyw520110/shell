#!/bin/bash
# mysql启动脚本

# 检查是否以root或sudo运行，如果不是则自动使用sudo重新运行
if [ "$EUID" -ne 0 ] && [ -z "${ALREADY_ELEVATED:-}" ]; then
  echo "需要root权限来启动MySQL服务，正在使用sudo执行..." >&2
  export ALREADY_ELEVATED=true
  sudo -E "$0" "$@"
  exit $?
fi

set -euo pipefail # Exit on error, undefined variable, or pipe failure

# 获取当前脚本的绝对路径（解析符号链接）
SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(dirname "$SOURCE")"
# 通过find_mysql.sh查找安装目录
#SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# 获取第一个找到的安装目录，避免多行输出问题
INSTALL_DIR=$(bash "$SCRIPT_DIR/find_mysql.sh" "${1:-}" | head -n 1)
if [ -z "$INSTALL_DIR" ]; then
  echo "未找到MySQL安装目录，退出。" >&2
  exit 1
fi

# 日志目录和日志文件
LOG_DIR="/var/log/mysql"
LOG_FILE="$LOG_DIR/startup.log"
# 获取操作系统类型
OS=$(uname)
SED_INPLACE_OPT=""
if [ "$OS" == "Darwin" ]; then
  SED_INPLACE_OPT="''"
fi

# 日志函数
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 校验配置文件
CNF_PATH="$INSTALL_DIR/conf/my.cnf"
if [ ! -f "$CNF_PATH" ]; then
  log "配置文件 $CNF_PATH 不存在"
  exit 1
fi

# 初始化环境
cd "$INSTALL_DIR" || { log "无法切换到INSTALL_DIR目录"; exit 1; }

# 从配置文件提取实际的日志目录路径
log_error_line=$(grep -E "^log-error[[:space:]]*=" "$CNF_PATH" | head -n1)
if [ -n "$log_error_line" ]; then
  log_error_path=$(echo "$log_error_line" | cut -d'=' -f2- | xargs)  # 提取等号后的完整路径
  if [ -n "$log_error_path" ]; then
    ACTUAL_LOG_DIR=$(dirname "$log_error_path")
  else
    ACTUAL_LOG_DIR=""
  fi
else
  ACTUAL_LOG_DIR=""
fi

# 创建系统日志目录
mkdir -p "$LOG_DIR"

# 创建实际配置的日志目录
if [ -n "$ACTUAL_LOG_DIR" ] && [ "$ACTUAL_LOG_DIR" != "$LOG_DIR" ]; then
  # 如果实际日志目录与默认路径不同，需要创建并设置权限
  if [ ! -d "$ACTUAL_LOG_DIR" ]; then
    log "创建实际日志目录: $ACTUAL_LOG_DIR"
    mkdir -p "$ACTUAL_LOG_DIR"
  fi

  # 获取配置文件中的用户
  USR=$(grep -E '^user[[:space:]]*=' "$CNF_PATH" | cut -d'=' -f2 | xargs)
  if [ -z "$USR" ]; then
    if [ "$OS" == "Darwin" ]; then
      USR="_mysql"
    else
      USR="mysql"  # Common default for Linux
    fi
    log "配置文件中未指定用户，使用默认用户: $USR"
  fi

  # 设置实际日志目录的权限
  if ! chown -R "$USR:$USR" "$ACTUAL_LOG_DIR" 2>/dev/null; then
    # 如果上面命令失败，尝试获取用户组名
    USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")
    if ! chown -R "$USR:$USR_GROUP" "$ACTUAL_LOG_DIR" 2>/dev/null; then
      log "警告：无法设置日志目录权限 $ACTUAL_LOG_DIR"
    fi
  fi
  if ! chmod -R 755 "$ACTUAL_LOG_DIR" 2>/dev/null; then
    log "警告：无法设置日志目录权限 $ACTUAL_LOG_DIR"
  fi
else
    # Even if no custom log dir, derive USR from CNF for later use
    USR=$(grep -E '^user[[:space:]]*=' "$CNF_PATH" | cut -d'=' -f2 | xargs)
    if [ -z "$USR" ]; then
      if [ "$OS" == "Darwin" ]; then
        USR="_mysql"
      else
        USR="mysql"
      fi
      log "配置文件中未指定用户，使用默认用户: $USR"
    fi
fi


# 从配置文件中提取端口号、数据目录和socket路径
# 使用sed提取[mysqld]段下的配置值
extract_mysqld_config() {
    local config_file="$1"
    local config_key="$2"

    # 从[mysqld]段提取配置，如果没找到则从整个文件查找
    sed -n '/^\[mysqld\]/,/^$/p' "$config_file" | grep -E "^[[:space:]]*${config_key}[[:space:]]*=" | head -n 1 | sed -e "s/^[[:space:]]*${config_key}[[:space:]]*=[[:space:]]*//" -e 's/[[:space:]]*$//' | head -n 1
}

mysqld_socket(){
    awk -F= '
  /^\[mysqld\]/ { in_mysqld=1; next }
  in_mysqld && /^\[/{ in_mysqld=0 }
  in_mysqld && $0 ~ /socket/ && $0 !~ /^#/ {
    gsub(/^[^=]*=/, "");  # 移除 key 部分（如 "socket = "）
    gsub(/^[[:space:]]+|[[:space:]]+$/, "");  # 清理前后空格
    print;
    exit;  # 找到第一个就退出
  }
' "$1"
}

# 提取配置值
PORT=$(extract_mysqld_config "$CNF_PATH" "port")
[ -z "$PORT" ] && PORT=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$CNF_PATH" | head -n 1 | sed -e 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//')

DATADIR=$(extract_mysqld_config "$CNF_PATH" "datadir")
[ -z "$DATADIR" ] && DATADIR=$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$CNF_PATH" | head -n 1 | sed -e 's/^[[:space:]]*datadir[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
SOCKET_PATH=$(mysqld_socket "$CNF_PATH")
[ -z "$SOCKET_PATH" ] && SOCKET_PATH=$(grep -E '^[[:space:]]*socket[[:space:]]*=' "$CNF_PATH" | head -n 1 | sed -e 's/^[[:space:]]*socket[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//')

check_mysql_running() {
  # 检查MySQL进程是否运行
  if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
    return 0  # 运行中
  else
    return 1  # 未运行
  fi
}

check_port_occupied() {
  local port_to_check="$1"
  # 检查端口是否被占用
  if [ "$OS" == "Linux" ]; then
    if netstat -tlnp 2>/dev/null | grep -q ":$port_to_check[[:space:]]"; then
      return 0  # 被占用
    fi
  elif [ "$OS" == "Darwin" ]; then
    if lsof -i :"$port_to_check" > /dev/null 2>&1; then
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
  if check_port_occupied "$PORT"; then
    log "端口 $PORT 已被其他进程占用"
    if [ "$OS" == "Linux" ]; then
      netstat -tlnp 2>/dev/null | grep ":$PORT "
    elif [ "$OS" == "Darwin" ]; then
      lsof -i :"$PORT"
    fi
    log "请检查端口占用情况或修改配置文件中的端口号"
    exit 1
  fi

  log "启动检查完成，准备启动MySQL..."
}

# 检查Docker环境
if which docker > /dev/null 2>&1; then
  local name
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
  local config_file="$1"
  local user="$2"

  # 提取所有路径
  while IFS='=' read -r key raw_value; do
    # Trim leading/trailing whitespace from key and value
    key=$(echo "$key" | xargs)
    value=$(echo "$raw_value" | xargs)
    
    # Check if the value starts with a slash (is an absolute path)
    if [[ "$value" =~ ^/ ]]; then
      dir=$(dirname "$value")
      if [ ! -d "$dir" ]; then
        log "创建目录: $dir"
        if ! mkdir -p "$dir" || ! chown -R "$user:$user" "$dir" || ! chmod -R 755 "$dir"; then
          log "警告：无法创建或设置目录权限: $dir"
        fi
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

# 检查并创建配置文件中的所有路径
create_dirs "$CNF_PATH" "$USR"

# 清理可能存在的PID文件和其他临时文件
if [ -f "$DATADIR/mysqld.pid" ]; then
  log "清理旧的PID文件"
  if ! rm -f "$DATADIR/mysqld.pid" 2>/dev/null; then
    log "警告：无法删除PID文件 $DATADIR/mysqld.pid"
  fi
fi

# 检查socket文件是否存在，如果存在则删除
if [ -n "$SOCKET_PATH" ] && [ -S "$SOCKET_PATH" ]; then
  log "清理旧的socket文件: $SOCKET_PATH"
  if ! rm -f "$SOCKET_PATH" 2>/dev/null; then
    log "警告：无法删除socket文件 $SOCKET_PATH"
  fi
fi

# 安全设置目录权限
safe_set_permissions() {
  log "设置目录权限..."

  # 设置基本目录权限
  if ! chown -R "$USR:$USR" "$INSTALL_DIR" 2>/dev/null; then
    log "警告：部分文件权限设置失败"
  fi

  # 只对静态文件设置权限，避免修改运行时文件
  if [ -d "$INSTALL_DIR/data" ]; then
    find "$INSTALL_DIR/data" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/data" -name "*.frm" -exec chmod 644 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/data" -name "*.MYD" -exec chmod 644 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/data" -name "*.MYI" -exec chmod 644 {} \; 2>/dev/null || true
  fi
}

safe_set_permissions

# 确保日志目录和日志文件存在并有适当权限
log_error_path_from_config=$(grep -E "^log-error[[:space:]]*=" "$CNF_PATH" | grep -v '^#' | cut -d'=' -f2- | xargs)
if [ -n "$log_error_path_from_config" ]; then
  LOG_DIR_PATH=$(dirname "$log_error_path_from_config")
  if [ ! -d "$LOG_DIR_PATH" ]; then
    log "创建日志目录: $LOG_DIR_PATH"
    if ! mkdir -p "$LOG_DIR_PATH"; then
       log "错误：无法创建日志目录 $LOG_DIR_PATH"
       exit 1
    fi
  fi
  # Set permissions regardless of whether the directory existed
  if ! chown "$USR:$USR" "$LOG_DIR_PATH" 2>/dev/null; then
    USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")
    if ! chown "$USR:$USR_GROUP" "$LOG_DIR_PATH" 2>/dev/null; then
      log "警告：无法设置日志目录权限 $LOG_DIR_PATH"
    fi
  fi
  if ! chmod 755 "$LOG_DIR_PATH"; then
    log "警告：无法设置日志目录权限 $LOG_DIR_PATH"
  fi

  # Ensure the log file exists and has proper permissions
  if ! touch "$log_error_path_from_config" 2>/dev/null; then
    log "警告：无法创建或访问日志文件 $log_error_path_from_config"
  fi
  if ! chown "$USR:$USR" "$log_error_path_from_config" 2>/dev/null; then
    USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")
    if ! chown "$USR:$USR_GROUP" "$log_error_path_from_config" 2>/dev/null; then
      log "警告：无法设置日志文件权限 $log_error_path_from_config"
    fi
  fi
  if ! chmod 644 "$log_error_path_from_config"; then
    log "警告：无法设置日志文件权限 $log_error_path_from_config"
  fi
fi

# 启动 MySQL
log "启动MySQL服务..."
CMD="$INSTALL_DIR/bin/mysqld_safe --defaults-file=$CNF_PATH --user=$USR --socket=$SOCKET_PATH &"
log "执行命令: $CMD"
eval "$CMD"

# 等待启动并检查结果
log "等待MySQL启动..."
sleep 5

# 检查启动结果
if check_mysql_running; then
  log "MySQL启动成功"
  log "MySQL进程:"
  pgrep -f "$INSTALL_DIR/bin/mysqld" | xargs ps -p
  log "端口监听:"
  if [ "$OS" == "Linux" ]; then
    netstat -tlnp 2>/dev/null | grep ":$PORT " || log "端口信息获取失败"
  elif [ "$OS" == "Darwin" ]; then
    lsof -i :"$PORT" 2>/dev/null || log "端口信息获取失败"
  fi
else
  log "MySQL启动失败，请检查错误日志"
  if [ -f "/var/log/mysql/error.log" ]; then
    log "错误日志内容:"
    tail -n 20 /var/log/mysql/error.log
  fi
  exit 1
fi
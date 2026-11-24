#!/bin/bash
# mysql启动脚本

set -euo pipefail # Exit on error, undefined variable, or pipe failure

# 错误处理：捕获错误并输出详细信息
trap 'echo "错误: 脚本在第 $LINENO 行失败，执行的命令: $BASH_COMMAND" >&2' ERR

# 获取脚本所在目录的绝对路径（兼容 macOS，避免 readlink -f）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

normalize_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  cd "$path" 2>/dev/null && pwd -P
}

find_brew_mysql_package_for_dir() {
  local mysql_dir="$1"
  local mysql_real pkg prefix prefix_real

  command -v brew >/dev/null 2>&1 || return 1
  mysql_real="$(normalize_path "$mysql_dir" 2>/dev/null || true)"
  [ -n "$mysql_real" ] || return 1

  for pkg in mysql mysql@5.7 mysql@8.0 mysql@8.4 mysql@9.0 mysql@9.1 mysql@9.2 mysql@9.3 mysql@9.4 mysql@9.5 mysql@9.6; do
    prefix="$(brew --prefix "$pkg" 2>/dev/null || true)"
    prefix_real="$(normalize_path "$prefix" 2>/dev/null || true)"
    if [ -n "$prefix_real" ] && [ -e "$prefix_real/bin/mysqld" ] && {
      [ "$mysql_real" = "$prefix_real" ] ||
      [[ "$mysql_real" == "$prefix_real"/* ]] ||
      [[ "$prefix_real" == "$mysql_real"/* ]]
    }; then
      echo "$pkg"
      return 0
    fi
  done

  return 1
}

is_homebrew_mysql_dir() {
  local mysql_dir="$1"
  [ "$(uname)" = "Darwin" ] || return 1
  command -v brew >/dev/null 2>&1 || return 1
  find_brew_mysql_package_for_dir "$mysql_dir" >/dev/null 2>&1
}

show_brew_error_log_if_needed() {
  local lines="${1:-20}"
  local log_file

  command -v brew >/dev/null 2>&1 || return 1
  log_file="$(brew --prefix)/var/mysql/$(hostname).err"
  [ -f "$log_file" ] || return 1

  if tail -"$lines" "$log_file" 2>/dev/null | grep -Eiq '(\[ERROR\]|\bERROR\b|lower_case_table_names|Data Dictionary initialization failed|unknown variable)'; then
    echo "Homebrew MySQL 错误日志最后 ${lines} 行:" >&2
    tail -"$lines" "$log_file" >&2
    echo "" >&2
    echo "如果出现 lower_case_table_names/Data Dictionary 不一致，说明已有数据目录与当前 my.cnf 配置不兼容。" >&2
    echo "不要直接删除数据目录；请先备份 $(brew --prefix)/var/mysql 后，再决定重建数据目录或调整 my.cnf。" >&2
    return 0
  fi

  return 1
}

wait_homebrew_mysql_ready() {
  local mysqladmin_cmd="$1"
  local mysql_cmd="$2"

  for _ in {1..30}; do
    if "$mysqladmin_cmd" ping --protocol=tcp -h 127.0.0.1 -P 3306 >/dev/null 2>&1; then
      echo "MySQL 启动成功"
      "$mysql_cmd" --version 2>/dev/null || true
      return 0
    fi
    sleep 1
  done

  return 1
}

start_homebrew_mysql_once() {
  local mysql_dir="$1"
  local pkg="$2"
  local services_output

  echo "使用 brew services 启动..."
  if ! services_output="$(brew services start "$pkg" 2>&1)"; then
    echo "$services_output" >&2
    echo "brew services 启动失败，尝试使用 mysql.server 直接启动..." >&2
    if [ -x "$mysql_dir/support-files/mysql.server" ]; then
      "$mysql_dir/support-files/mysql.server" start || true
    else
      echo "未找到 mysql.server: $mysql_dir/support-files/mysql.server" >&2
    fi
  fi
}

set_mysql_cnf_value() {
  local cnf_file="$1"
  local key="$2"
  local value="$3"
  local tmp

  mkdir -p "$(dirname "$cnf_file")"
  touch "$cnf_file"
  tmp="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN {
      in_mysqld = 0
      done = 0
      wrote_mysqld = 0
      key_re = key
      gsub("_", "[-_]", key_re)
    }
    /^\[mysqld\][[:space:]]*$/ {
      in_mysqld = 1
      wrote_mysqld = 1
      print
      next
    }
    /^\[/ {
      if (in_mysqld && !done) {
        print key " = " value
        done = 1
      }
      in_mysqld = 0
      print
      next
    }
    in_mysqld && $0 ~ "^[[:space:]]*#?[[:space:]]*" key_re "[[:space:]]*=" {
      if (!done) {
        print key " = " value
        done = 1
      }
      next
    }
    { print }
    END {
      if (!wrote_mysqld) {
        print ""
        print "[mysqld]"
      }
      if (!done) {
        print key " = " value
      }
    }
  ' "$cnf_file" > "$tmp"

  mv "$tmp" "$cnf_file"
}

remove_mysql_cnf_key() {
  local cnf_file="$1"
  local key="$2"
  local tmp

  [ -f "$cnf_file" ] || return 1
  tmp="$(mktemp)"

  awk -v key="$key" '
    BEGIN {
      key_re = key
      gsub("_", "[-_]", key_re)
    }
    $0 ~ "^[[:space:]]*#?[[:space:]]*" key_re "[[:space:]]*=" { next }
    { print }
  ' "$cnf_file" > "$tmp"

  mv "$tmp" "$cnf_file"
}

repair_brew_lower_case_table_names_if_needed() {
  local log_file cnf_file mismatch_line target_value current_value backup_file

  command -v brew >/dev/null 2>&1 || return 1
  log_file="$(brew --prefix)/var/mysql/$(hostname).err"
  cnf_file="$(brew --prefix)/etc/my.cnf"
  [ -f "$log_file" ] || return 1

  mismatch_line="$(grep -E "Different lower_case_table_names settings" "$log_file" 2>/dev/null | tail -1 || true)"
  [ -n "$mismatch_line" ] || return 1

  target_value="$(printf '%s\n' "$mismatch_line" | sed -n "s/.*data dictionary ('\\([0-9]\\)').*/\\1/p")"
  [ -n "$target_value" ] || return 1

  current_value="$(grep -E '^[[:space:]]*(lower_case_table_names|lower-case-table-names)[[:space:]]*=' "$cnf_file" 2>/dev/null | tail -1 | awk -F= '{gsub(/[[:space:]]/, "", $2); print $2}' || true)"
  if [ "$current_value" = "$target_value" ]; then
    return 1
  fi

  backup_file="${cnf_file}.backup.$(date '+%Y%m%d_%H%M%S')"
  if [ -f "$cnf_file" ]; then
    cp "$cnf_file" "$backup_file"
    echo "已备份 MySQL 配置: $backup_file" >&2
  fi

  echo "检测到 lower_case_table_names 与数据目录不一致，自动修正配置为: $target_value" >&2
  set_mysql_cnf_value "$cnf_file" "lower_case_table_names" "$target_value"
  echo "已更新配置文件: $cnf_file" >&2
  return 0
}

repair_brew_unknown_variable_if_needed() {
  local log_file cnf_file unknown_key backup_file

  command -v brew >/dev/null 2>&1 || return 1
  log_file="$(brew --prefix)/var/mysql/$(hostname).err"
  cnf_file="$(brew --prefix)/etc/my.cnf"
  [ -f "$log_file" ] || return 1
  [ -f "$cnf_file" ] || return 1

  unknown_key="$(grep -E "unknown variable '" "$log_file" 2>/dev/null | tail -1 | sed -n "s/.*unknown variable '\\([^=']*\\)=.*/\\1/p")"
  [ -n "$unknown_key" ] || return 1

  case "$unknown_key" in
    default_authentication_plugin|expire_logs_days)
      backup_file="${cnf_file}.backup.$(date '+%Y%m%d_%H%M%S')"
      cp "$cnf_file" "$backup_file"
      echo "已备份 MySQL 配置: $backup_file" >&2
      echo "检测到 MySQL 8.4 不支持配置项: ${unknown_key}，自动移除该配置" >&2
      remove_mysql_cnf_key "$cnf_file" "${unknown_key}"
      echo "已更新配置文件: $cnf_file" >&2
      return 0
      ;;
    *)
      echo "检测到未知 MySQL 配置项: ${unknown_key}，请手动检查 $(brew --prefix)/etc/my.cnf" >&2
      return 1
      ;;
  esac
}

repair_brew_config_if_needed() {
  local repaired=false

  if repair_brew_lower_case_table_names_if_needed; then
    repaired=true
  fi
  if repair_brew_unknown_variable_if_needed; then
    repaired=true
  fi

  [ "$repaired" = true ]
}

show_brew_datadir_summary() {
  local data_dir user_dirs

  command -v brew >/dev/null 2>&1 || return 0
  data_dir="$(brew --prefix)/var/mysql"
  [ -d "$data_dir" ] || return 0

  user_dirs="$(find "$data_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
    base="$(basename "$dir")"
    if [ "$base" = "mysql" ] || \
       [ "$base" = "performance_schema" ] || \
       [ "$base" = "sys" ] || \
       [ "$base" = "#innodb_redo" ] || \
       [ "$base" = "#innodb_temp" ]; then
      continue
    fi
    echo "$dir"
  done)"

  echo "数据目录: $data_dir" >&2
  if [ -n "$user_dirs" ]; then
    echo "检测到可能的用户数据库目录:" >&2
    printf '%s\n' "$user_dirs" | sed 's/^/  - /' >&2
    echo "这只是静态判断；准确库表信息需要 MySQL 成功启动后查询。" >&2
  else
    echo "未检测到明显的用户数据库目录；如确认无需保留数据，可备份后重建数据目录。" >&2
  fi
}

start_homebrew_mysql() {
  local mysql_dir="$1"
  local pkg mysqladmin_cmd mysql_cmd plist_path uid repaired=false
  pkg="$(find_brew_mysql_package_for_dir "$mysql_dir")"

  echo "检测到 Homebrew MySQL: $pkg"
  start_homebrew_mysql_once "$mysql_dir" "$pkg"

  mysqladmin_cmd="$mysql_dir/bin/mysqladmin"
  mysql_cmd="$mysql_dir/bin/mysql"
  command -v mysqladmin >/dev/null 2>&1 && mysqladmin_cmd="$(command -v mysqladmin)"
  command -v mysql >/dev/null 2>&1 && mysql_cmd="$(command -v mysql)"

  if wait_homebrew_mysql_ready "$mysqladmin_cmd" "$mysql_cmd"; then
    return 0
  fi

  if repair_brew_config_if_needed; then
    repaired=true
    echo "MySQL 配置已修正，重新尝试启动..." >&2
    start_homebrew_mysql_once "$mysql_dir" "$pkg"
    if wait_homebrew_mysql_ready "$mysqladmin_cmd" "$mysql_cmd"; then
      return 0
    fi

    if repair_brew_config_if_needed; then
      echo "MySQL 配置再次修正，进行最后一次启动尝试..." >&2
      start_homebrew_mysql_once "$mysql_dir" "$pkg"
      if wait_homebrew_mysql_ready "$mysqladmin_cmd" "$mysql_cmd"; then
        return 0
      fi
    fi
  fi

  echo "MySQL 服务启动后未能就绪" >&2
  show_brew_error_log_if_needed 20 || true
  show_brew_datadir_summary || true
  plist_path="$HOME/Library/LaunchAgents/homebrew.mxcl.${pkg}.plist"
  uid="$(id -u)"
  if [ -f "$plist_path" ]; then
    echo "如果错误是 launchctl bootstrap 5，可先清理当前用户 LaunchAgent 后重试:" >&2
    echo "  launchctl bootout gui/$uid \"$plist_path\" 2>/dev/null || true" >&2
    echo "  rm -f \"$plist_path\"" >&2
    echo "  brew services start $pkg" >&2
  fi
  echo "可检查状态: brew services list | grep mysql" >&2
  if [ "$repaired" = true ]; then
    echo "已尝试自动修正 MySQL 配置，但服务仍未就绪，请查看上述错误日志。" >&2
  fi
  return 1
}

# 通过find_mysql.sh查找安装目录
#SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# 获取第一个找到的安装目录，避免多行输出问题
INSTALL_DIR=$(bash "$SCRIPT_DIR/find_mysql.sh" "${1:-}" | head -n 1 || true)
if [ -z "$INSTALL_DIR" ]; then
  echo "未找到MySQL安装目录，退出。" >&2
  exit 1
fi

if is_homebrew_mysql_dir "$INSTALL_DIR"; then
  if start_homebrew_mysql "$INSTALL_DIR"; then
    exit 0
  else
    exit 1
  fi
fi

# 手工安装模式需要 root 权限处理系统日志、socket、运行用户等资源
if [ "$EUID" -ne 0 ] && [ -z "${ALREADY_ELEVATED:-}" ]; then
  echo "需要root权限来启动MySQL服务，正在使用sudo执行..." >&2
  export ALREADY_ELEVATED=true
  sudo -E "$0" "$INSTALL_DIR"
  exit $?
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

# 首先获取用户信息（用于后续权限设置）
get_mysql_user() {
  local user=$(grep -E '^user[[:space:]]*=' "$CNF_PATH" | cut -d'=' -f2 | xargs)
  if [ -z "$user" ]; then
    if [ "$OS" == "Darwin" ]; then
      user="_mysql"
    else
      user="mysql"
    fi
  else
    # macOS 特殊处理：mysql 是 _mysql 的别名，但实际用户名是 _mysql
    if [ "$OS" == "Darwin" ] && [ "$user" = "mysql" ]; then
      user="_mysql"
      # 输出到 stderr，避免被 $() 捕获
      echo "macOS 平台：将用户 'mysql' 转换为 '_mysql'" >&2
    fi
    # 验证用户是否存在，如果不存在则使用系统默认
    if ! id "$user" > /dev/null 2>&1; then
      local original_usr="$user"
      if [ "$OS" == "Darwin" ]; then
        user="_mysql"
      else
        user="mysql"
      fi
      echo "配置文件中的用户 '$original_usr' 不存在，使用系统默认用户: $user" >&2
    fi
  fi
  echo "$user"
}

# 获取MySQL运行用户
USR=$(get_mysql_user)
USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")
log "MySQL运行用户: $USR:$USR_GROUP"

# 从配置文件提取实际的日志目录路径
log_error_line=$(grep -E "^log-error[[:space:]]*=" "$CNF_PATH" | head -n1)
if [ -n "$log_error_line" ]; then
  log_error_path=$(echo "$log_error_line" | cut -d'=' -f2- | xargs)
  if [ -n "$log_error_path" ]; then
    ACTUAL_LOG_DIR=$(dirname "$log_error_path")
  else
    ACTUAL_LOG_DIR=""
  fi
else
  ACTUAL_LOG_DIR=""
fi

# 创建系统日志目录并设置权限
mkdir -p "$LOG_DIR"
# 修复日志目录权限（确保 MySQL 用户可写）
if [ -d "$LOG_DIR" ]; then
  chown -R "$USR:$USR_GROUP" "$LOG_DIR" 2>/dev/null || log "警告：无法设置系统日志目录权限"
  chmod 755 "$LOG_DIR" 2>/dev/null || true
fi

# 创建实际配置的日志目录并设置权限
if [ -n "$ACTUAL_LOG_DIR" ] && [ "$ACTUAL_LOG_DIR" != "$LOG_DIR" ]; then
  if [ ! -d "$ACTUAL_LOG_DIR" ]; then
    log "创建实际日志目录: $ACTUAL_LOG_DIR"
    mkdir -p "$ACTUAL_LOG_DIR"
  fi
  # 强制修复权限
  chown -R "$USR:$USR_GROUP" "$ACTUAL_LOG_DIR" 2>/dev/null || log "警告：无法设置日志目录权限 $ACTUAL_LOG_DIR"
  chmod 755 "$ACTUAL_LOG_DIR" 2>/dev/null || true
fi

# 从配置文件中提取端口号、数据目录和socket路径
# 使用sed提取[mysqld]段下的配置值
extract_mysqld_config() {
    local config_file="$1"
    local config_key="$2"
    local result=""

    # 从[mysqld]段提取配置，如果没找到则从整个文件查找
    result=$(sed -n '/^\[mysqld\]/,/^$/p' "$config_file" 2>/dev/null | grep -E "^[[:space:]]*${config_key}[[:space:]]*=" | head -n 1 | sed -e "s/^[[:space:]]*${config_key}[[:space:]]*=[[:space:]]*//" -e 's/[[:space:]]*$//' | head -n 1)
    echo "${result:-}"
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
if [ -z "$PORT" ]; then
  PORT=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$CNF_PATH" 2>/dev/null | head -n 1 | sed -e 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
fi

DATADIR=$(extract_mysqld_config "$CNF_PATH" "datadir")
if [ -z "$DATADIR" ]; then
  DATADIR=$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$CNF_PATH" 2>/dev/null | head -n 1 | sed -e 's/^[[:space:]]*datadir[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
fi

SOCKET_PATH=$(mysqld_socket "$CNF_PATH")
if [ -z "$SOCKET_PATH" ]; then
  SOCKET_PATH=$(grep -E '^[[:space:]]*socket[[:space:]]*=' "$CNF_PATH" 2>/dev/null | head -n 1 | sed -e 's/^[[:space:]]*socket[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
fi

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
  name=$(grep -m 1 'container_name:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | awk -F': ' '{print $2}' || true)
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
  
  # 获取用户组
  local user_group=$(id -gn "$user" 2>/dev/null || echo "$user")

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
        mkdir -p "$dir" 2>/dev/null || log "警告：无法创建目录: $dir"
        chown -R "$user:$user_group" "$dir" 2>/dev/null || log "警告：无法设置目录所有者: $dir"
        chmod -R 755 "$dir" 2>/dev/null || log "警告：无法设置目录权限: $dir"
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

# macOS 平台：修复配置文件中的用户设置
# macOS 系统用户通常以 _ 为前缀（如 _mysql, _www 等）
if [ "$OS" == "Darwin" ]; then
  config_user=$(grep -E '^user[[:space:]]*=' "$CNF_PATH" | cut -d'=' -f2 | xargs)
  # 如果用户名不以 _ 开头，检查 _<user> 是否存在于系统中
  if [ -n "$config_user" ] && [ "${config_user#_}" = "$config_user" ]; then
    if id "_${config_user}" &>/dev/null; then
      log "macOS 平台：修复配置文件中的用户设置 ($config_user -> _${config_user})"
      sed -i $SED_INPLACE_OPT "s/^user[[:space:]]*=[[:space:]]*${config_user}$/user = _${config_user}/" "$CNF_PATH"
    fi
  fi
fi

# 检查并创建配置文件中的所有路径
create_dirs "$CNF_PATH" "$USR"

# macOS 平台：检查 socket 路径是否可写
# /tmp 目录在 macOS 上可能对 _mysql 用户没有写权限
if [ "$OS" == "Darwin" ]; then
  config_socket=$(grep -E '^socket[[:space:]]*=' "$CNF_PATH" | head -1 | cut -d'=' -f2 | xargs)
  if [ -n "$config_socket" ]; then
    socket_dir=$(dirname "$config_socket")
    # 检查目录是否对 MySQL 用户可写
    # 方法：检查目录权限或尝试创建测试文件
    socket_writable=false
    if [ -d "$socket_dir" ]; then
      # 尝试以 MySQL 用户身份测试写权限
      if sudo -u "$USR" touch "$socket_dir/.mysql_test_$$" 2>/dev/null; then
        sudo -u "$USR" rm -f "$socket_dir/.mysql_test_$$" 2>/dev/null
        socket_writable=true
      fi
    fi
    
    if [ "$socket_writable" = false ]; then
      new_socket="$INSTALL_DIR/mysql.sock"
      log "macOS 平台：socket 路径 $config_socket 对 $USR 用户不可写"
      log "macOS 平台：修改 socket 路径为 $new_socket"
      # 修改 [mysqld] 段的 socket 路径（只修改第一个匹配，即 [mysqld] 段）
      sed -i $SED_INPLACE_OPT "/^\[mysqld\]/,/^\[/ s|^socket[[:space:]]*=.*|socket = $new_socket|" "$CNF_PATH"
      # 修改 [client] 段的 socket 路径
      sed -i $SED_INPLACE_OPT "/^\[client\]/,/^\[/ s|^socket[[:space:]]*=.*|socket = $new_socket|" "$CNF_PATH"
      # 更新 SOCKET_PATH 变量
      SOCKET_PATH="$new_socket"
    fi
  fi
fi

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

# 清理socket lock文件（可能导致启动失败）
if [ -n "$SOCKET_PATH" ]; then
  socket_lock="${SOCKET_PATH}.lock"
  if [ -f "$socket_lock" ]; then
    log "清理旧的socket lock文件: $socket_lock"
    # 可能需要sudo权限删除
    if [ -w "$socket_lock" ]; then
      rm -f "$socket_lock" 2>/dev/null || log "警告：无法删除socket lock文件"
    else
      sudo rm -f "$socket_lock" 2>/dev/null || log "警告：无法删除socket lock文件（可能需要检查权限）"
    fi
  fi
  # 清理mysqlx socket相关文件
  socket_dir=$(dirname "$SOCKET_PATH")
  mysqlx_sock="${socket_dir}/mysqlx.sock"
  mysqlx_lock="${socket_dir}/mysqlx.sock.lock"
  if [ -S "$mysqlx_sock" ]; then
    log "清理旧的mysqlx socket文件: $mysqlx_sock"
    rm -f "$mysqlx_sock" 2>/dev/null || sudo rm -f "$mysqlx_sock" 2>/dev/null || true
  fi
  if [ -f "$mysqlx_lock" ]; then
    log "清理旧的mysqlx socket lock文件: $mysqlx_lock"
    rm -f "$mysqlx_lock" 2>/dev/null || sudo rm -f "$mysqlx_lock" 2>/dev/null || true
  fi
fi

# 安全设置目录权限
safe_set_permissions() {
  log "设置目录权限..."
  
  # 获取用户组
  local USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")

  # 设置基本目录权限
  chown -R "$USR:$USR_GROUP" "$INSTALL_DIR" 2>/dev/null || log "警告：部分文件权限设置失败"

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
  
  # 获取用户组
  USR_GROUP=$(id -gn "$USR" 2>/dev/null || echo "$USR")
  
  if [ ! -d "$LOG_DIR_PATH" ]; then
    log "创建日志目录: $LOG_DIR_PATH"
    mkdir -p "$LOG_DIR_PATH" || { log "错误：无法创建日志目录 $LOG_DIR_PATH"; exit 1; }
  fi
  
  # 强制设置日志目录权限（即使目录已存在）
  log "设置日志目录权限: $LOG_DIR_PATH -> $USR:$USR_GROUP"
  chown -R "$USR:$USR_GROUP" "$LOG_DIR_PATH" 2>/dev/null || log "警告：无法设置日志目录所有者"
  chmod 755 "$LOG_DIR_PATH" 2>/dev/null || log "警告：无法设置日志目录权限"

  # 确保日志文件存在并有正确权限
  touch "$log_error_path_from_config" 2>/dev/null || log "警告：无法创建日志文件"
  chown "$USR:$USR_GROUP" "$log_error_path_from_config" 2>/dev/null || log "警告：无法设置日志文件所有者"
  chmod 644 "$log_error_path_from_config" 2>/dev/null || log "警告：无法设置日志文件权限"
fi

# 解决macOS下TMPDIR权限问题：由于/tmp可能权限不符，或者sudo -E带入了用户变量
# 这里在$INSTALL_DIR下创建一个专属临时目录，并指定给mysqld使用
if [ "$OS" == "Darwin" ]; then
  MYSQL_TMPDIR="$INSTALL_DIR/tmp"
  mkdir -p "$MYSQL_TMPDIR"
  chown "$USR:$USR_GROUP" "$MYSQL_TMPDIR" 2>/dev/null || true
  chmod 755 "$MYSQL_TMPDIR"
  export TMPDIR="$MYSQL_TMPDIR"
  log "macOS 平台：设置独立 TMPDIR: $TMPDIR"
fi

# 启动 MySQL
log "启动MySQL服务..."
CMD="$INSTALL_DIR/bin/mysqld_safe --defaults-file=$CNF_PATH --user=$USR --socket=$SOCKET_PATH &"
log "执行命令: $CMD"
eval "$CMD"

# 等待启动并检查结果
log "等待MySQL启动..."

# 多次检查进程是否稳定运行
max_attempts=6
attempt=0
mysql_started=false

while [ $attempt -lt $max_attempts ]; do
  sleep 2
  attempt=$((attempt + 1))
  
  if check_mysql_running; then
    # 进程存在，等待更长时间确认进程稳定
    sleep 3
    if check_mysql_running; then
      # 进程仍然存在，尝试用mysqladmin验证
      if [ -x "$INSTALL_DIR/bin/mysqladmin" ]; then
        if "$INSTALL_DIR/bin/mysqladmin" ping -h 127.0.0.1 -P "$PORT" --silent 2>/dev/null; then
          mysql_started=true
          break
        fi
      else
        # 没有mysqladmin，只检查进程
        mysql_started=true
        break
      fi
    fi
  fi
  
  log "等待中... ($attempt/$max_attempts)"
done

# 检查启动结果
if [ "$mysql_started" = true ]; then
  log "MySQL启动成功"
  log "MySQL进程:"
  pgrep -f "$INSTALL_DIR/bin/mysqld" | xargs ps -p
  log "端口监听:"
  if [ "$OS" == "Linux" ]; then
    netstat -tlnp 2>/dev/null | grep ":$PORT " || log "端口信息获取失败"
  elif [ "$OS" == "Darwin" ]; then
    lsof -i :"$PORT" 2>/dev/null || log "端口信息获取失败"
  fi
  
  # 创建符号链接：/tmp/mysql.sock -> 实际socket路径
  # 这样客户端可以直接使用默认的 /tmp/mysql.sock 连接
  if [ -n "$SOCKET_PATH" ] && [ -S "$SOCKET_PATH" ]; then
    default_socket="/tmp/mysql.sock"
    if [ "$SOCKET_PATH" != "$default_socket" ]; then
      # 检查符号链接是否已存在且指向正确的目标
      if [ -L "$default_socket" ]; then
        current_target=$(readlink "$default_socket" 2>/dev/null)
        if [ "$current_target" = "$SOCKET_PATH" ]; then
          # 符号链接已存在且正确，跳过
          :
        else
          # 符号链接指向不同目标，需要更新
          rm -f "$default_socket" 2>/dev/null || sudo rm -f "$default_socket" 2>/dev/null
          if ln -s "$SOCKET_PATH" "$default_socket" 2>/dev/null; then
            log "创建socket符号链接: $default_socket -> $SOCKET_PATH"
          elif sudo ln -s "$SOCKET_PATH" "$default_socket" 2>/dev/null; then
            log "创建socket符号链接: $default_socket -> $SOCKET_PATH"
          else
            log "警告：无法创建socket符号链接 $default_socket"
          fi
        fi
      else
        # 符号链接不存在，创建新的
        if [ -S "$default_socket" ]; then
          rm -f "$default_socket" 2>/dev/null || sudo rm -f "$default_socket" 2>/dev/null
        fi
        if ln -s "$SOCKET_PATH" "$default_socket" 2>/dev/null; then
          log "创建socket符号链接: $default_socket -> $SOCKET_PATH"
        elif sudo ln -s "$SOCKET_PATH" "$default_socket" 2>/dev/null; then
          log "创建socket符号链接: $default_socket -> $SOCKET_PATH"
        else
          log "警告：无法创建socket符号链接 $default_socket"
        fi
      fi
    fi
  fi
else
  log "MySQL启动失败，请检查错误日志"
  # 从配置文件读取错误日志路径
  error_log=$(grep -E '^log-error[[:space:]]*=' "$CNF_PATH" | cut -d'=' -f2 | xargs)
  if [ -z "$error_log" ]; then
    error_log="/var/log/mysql/error.log"
  fi
  if [ -f "$error_log" ]; then
    log "错误日志内容 ($error_log):"
    tail -n 30 "$error_log"
  else
    log "错误日志不存在: $error_log"
  fi
  exit 1
fi

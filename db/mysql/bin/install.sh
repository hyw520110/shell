#!/bin/bash
# MySQL自动安装脚本
# 功能: 自动下载、安装、配置MySQL数据库
# 支持: MySQL 5.7 和 8.0, Linux 和 macOS

set -euo pipefail

# 全局变量定义 
readonly SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly OS=$(uname)

# 用户可配置变量
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"$HOME/Downloads"}
INPUT_TIMEOUT=30
DEFAULT_VERSION="8"
DEFAULT_INSTALL_DIR="$HOME/mysql"

# 运行时变量（将在parse_arguments中初始化）
install_dir=""
data_dir=""
version=""
mysql_url=""
gz_file=""
need_sudo=0
log_dir=""
usr=""
usr_group=""
pass=""
# 新增：用户指定的MySQL用户名和密码
mysql_user=""
mysql_password=""

# 日志级别变量
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3
CURRENT_LOG_LEVEL=${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}  # 默认为info级别

# 平台相关配置
if [ "$OS" == "Darwin" ]; then
  SED_INPLACE_OPT="''"
  DEFAULT_USR="_mysql"
  DEFAULT_USR_GROUP="_mysql"
else
  SED_INPLACE_OPT=""
  DEFAULT_USR="mysql"
  DEFAULT_USR_GROUP="mysql"
fi

# 显示帮助信息
show_help() {
  cat << EOF
MySQL 安装脚本

用法: $0 [选项]

选项:
  -h, --help                显示此帮助信息
  --install-dir=DIR         指定MySQL安装目录 (默认: $HOME/mysql)
  --version=VERSION         指定MySQL版本 (5 或 8, 默认: 8)
  --log-level=LEVEL         指定日志级别 (debug, info, warn, error, 默认: info)
  --mysql-user=USER         指定MySQL用户名 (默认: root)
  --mysql-password=PASS     指定MySQL root密码 (不指定则随机生成)

示例:
  $0                                          # 安装MySQL 8到默认目录，使用默认用户名和随机密码
  $0 --install-dir ~/mysql                    # 安装MySQL 8到 ~/mysql 目录
  $0 --install-dir ~/mysql --version=8        # 安装MySQL 8到 ~/mysql 目录
  $0 --mysql-user=admin --mysql-password=123456  # 指定用户名和密码
  $0 --version=8 --log-level=debug            # 安装MySQL 8到默认目录，使用debug级别
  sudo $0 --install-dir /opt/mysql            # 以root权限安装到系统目录

注意:
  - 如果安装到用户目录 (~ 开头)，脚本不需要 root 权限
  - 如果安装到系统目录 (/opt, /usr 等)，需要 root 权限
  - 日志目录使用 /var/log/mysql (需要root权限) 或 ~/.mysql_log
  - 下载目录可通过 DOWNLOAD_DIR 环境变量指定，默认为 ~/Downloads
  - 如果不指定密码，将自动生成8位随机密码
  - 日志级别说明:
    * debug: 显示所有日志信息，包括调试信息
    * info: 显示一般信息、警告和错误（默认）
    * warn: 只显示警告和错误信息
    * error: 只显示错误信息

EOF
}

# 检查日志级别是否应该输出
should_log() {
  local level=$1
  [ $level -ge $CURRENT_LOG_LEVEL ]
}

# 打印带时间戳的调试日志
debug() {
  if should_log $LOG_LEVEL_DEBUG; then
    echo "$(date +"%Y%m%d %H:%M:%S"): [DEBUG] $1" >&2
  fi
}

# 打印带时间戳的日志
info() {
  should_log $LOG_LEVEL_INFO && echo "$(date +"%Y%m%d %H:%M:%S"): [INFO] $1"
}

# 打印错误信息并退出
error() {
  should_log $LOG_LEVEL_ERROR && echo "$(date +"%Y%m%d %H:%M:%S"): [ERROR] $1" >&2
  exit 1
}

# 打印警告信息
warn() {
  should_log $LOG_LEVEL_WARN && echo "$(date +"%Y%m%d %H:%M:%S"): [WARN] $1" >&2
}

# 检查命令是否存在
check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "需要命令: $1，请先安装"
  fi
}

# 写入文件内容的函数
wfile() {
  local content="$1"
  local file="$2"
  local cmd="${3:-}"
  if ! grep -q "$content" "$file" 2>/dev/null; then
    if [ -n "$cmd" ]; then
      echo "$content" >> "$file" && eval "$cmd"
    else
      echo "$content" >> "$file"
    fi
  fi
}

# 安全创建目录
safe_mkdir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    if [ $need_sudo -eq 1 ] && [[ "$dir" =~ ^/(var|etc)/ ]]; then
      sudo mkdir -p "$dir"
      if [[ "$dir" =~ ^/var/log/ ]]; then
        sudo chown "$usr:$usr_group" "$dir"
        sudo chmod 755 "$dir"
      fi
    else
      mkdir -p "$dir"
    fi
  fi
}

# 检查DNS解析
check_dns() {
    local domain=$1
    debug "检查域名解析: $domain"
    if ! nslookup $domain &> /dev/null; then
        warn "无法解析域名 $domain，建议检查DNS配置"
        return 1
    fi
    return 0
}

# 安全下载文件
safe_download() {
  local url="$1"
  local output="$2"
  local max_retries=3
  local retry=0
  
  # 检查域名解析
  local domain=$(echo $url | awk -F[/:] '{for(i=1;i<=NF;i++) if($i ~ "com|org|cn") {info $i; exit}}')
  if [ -n "$domain" ]; then
      check_dns $domain || return 1
  fi
  
  while [ $retry -lt $max_retries ]; do
    if wget --tries=2 --timeout=10 -O "$output" "$url"; then
      return 0
    fi
    retry=$((retry + 1))
    [ $retry -lt $max_retries ] && sleep 5
  done
  
  return 1
}

# 检查文件完整性
check_file_integrity() {
  local file="$1"
  if ! tar -tf "$file" >/dev/null 2>&1; then
    info "文件损坏或不完整: $file"
    rm -f "$file"
    return 1
  fi
  return 0
}

# 检查安装状态
check_installation() {
  [ -f "$install_dir/bin/mysqld" ] && [ -f "$install_dir/bin/mysql" ]
}

# 检查初始化状态
check_initialization() {
  [ -d "$data_dir" ] && [ -n "$(ls -A "$data_dir" 2>/dev/null)" ] && [ -d "$data_dir/mysql" ]
}

# 预检查：确定权限、用户和安装状态
pre_check() {
  info "开始安装检查..."
  
  # 检查安装目录权限
  local check_dir="$install_dir"
  [ ! -d "$check_dir" ] && check_dir=$(dirname "$check_dir")
  
  if [ ! -w "$check_dir" ] || [ ! -r "$check_dir" ]; then
    need_sudo=1
    info "需要root权限: 对目录 $check_dir 无写权限"
  fi
  
  # 设置用户和用户组
  if [ $need_sudo -eq 1 ]; then
    usr="$DEFAULT_USR"
    usr_group="$DEFAULT_USR_GROUP"
    log_dir="/var/log/mysql"
    debug "使用系统用户: $usr:$usr_group"
  else
    usr=$(whoami)
    usr_group=$(id -gn)
    log_dir="$HOME/.mysql_log"
    debug "使用当前用户: $usr:$usr_group"
  fi
  
  # 确保用户组变量已定义
  : "${usr_group:=$(id -gn "$usr" 2>/dev/null || id -gn)}"
  
  # 创建日志目录
  safe_mkdir "$log_dir"
  
  # 检查安装状态
  if check_installation; then
    if check_initialization; then
      info "MySQL已安装且已初始化"
      [ ! -f "$install_dir/bin/startup.sh" ] && cp -r "$SOURCE_DIR"/{bin,conf} "$install_dir"/
      info "启动现有MySQL服务..."
      debug "执行启动脚本: $install_dir/bin/startup.sh"
      exec "$install_dir/bin/startup.sh" "$install_dir"
    else
      info "MySQL已安装但未初始化，跳过下载步骤"
      debug "设置SKIP_DOWNLOAD=true"
      SKIP_DOWNLOAD=true
    fi
  else
    info "MySQL未安装，开始完整安装..."
    debug "设置SKIP_DOWNLOAD=false"
    SKIP_DOWNLOAD=false
  fi
}

# 检查MySQL版本并调整my.cnf兼容性
adjust_cnf_for_version() {
  local cnf_file="$1"
  local version_bin="$2"
  local mysql_version=$($version_bin --version 2>/dev/null | grep -Eo '[0-9]+\\.[0-9]+' | head -1)
  local major_version=$(echo $mysql_version | cut -d. -f1)

  if [ "$major_version" = "5" ]; then
    # 注释MySQL 8专属参数
    sed -i $SED_INPLACE_OPT 's|^performance_schema\s*=\s*ON|#performance_schema = ON|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^default_authentication_plugin|#default_authentication_plugin|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^log_error_verbosity|#log_error_verbosity|g' "$cnf_file"
    # 启用MySQL 5专属参数
    sed -i $SED_INPLACE_OPT 's|^#skip-name-resolve|skip-name-resolve|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#explicit_defaults_for_timestamp|explicit_defaults_for_timestamp|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#default-time-zone|default-time-zone|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#gtid_mode|gtid_mode|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#enforce_gtid_consistency|enforce_gtid_consistency|g' "$cnf_file"
  elif [ "$major_version" = "8" ]; then
    # 启用MySQL 8专属参数
    sed -i $SED_INPLACE_OPT 's|^#performance_schema|performance_schema|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#default_authentication_plugin|default_authentication_plugin|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^#log_error_verbosity|log_error_verbosity|g' "$cnf_file"
    # 注释MySQL 5专属参数
    sed -i $SED_INPLACE_OPT 's|^skip-name-resolve|#skip-name-resolve|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^explicit_defaults_for_timestamp|#explicit_defaults_for_timestamp|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^default-time-zone|#default-time-zone|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^gtid_mode|#gtid_mode|g' "$cnf_file"
    sed -i $SED_INPLACE_OPT 's|^enforce_gtid_consistency|#enforce_gtid_consistency|g' "$cnf_file"
  fi

}

# 智能路径替换函数
update_config() {
  local config_file="$1"
  
  # 获取配置项的新路径值
  get_new_path() {
    local key="$1"
    local old_value="$2"
    local new_value=""
    
    case $key in
      # 核心目录配置
      basedir)
        new_value="$install_dir"
        ;;
      datadir)
        new_value="$data_dir"
        ;;
      # Socket和PID文件
      socket)
        new_value="$install_dir/mysql.sock"
        ;;
      pid-file)
        new_value="$data_dir/mysqld.pid"
        ;;
      # 用户配置
      user)
        new_value="$usr"
        ;;
      # 日志文件（单文件）
      log-error|slow-query-log-file|slow_query_log_file|general-log-file|general_log_file)
        new_value="$log_dir/$(basename "$old_value")"
        ;;
      # Binlog和Relay log（文件前缀）
      log_bin|log-bin|relay-log|relay_log)
        new_value="$log_dir/binlog/$(basename "$old_value")"
        ;;
      # Binlog和Relay log索引文件
      log_bin-index|log_bin_index|relay-log-index|relay_log_index|master-info-file|master_info_file)
        new_value="$log_dir/binlog/$(basename "$old_value")"
        ;;
      # InnoDB日志目录
      innodb_log_group_home_dir)
        new_value="$log_dir/redolog/"
        ;;
      innodb_undo_directory)
        new_value="$log_dir/undolog/"
        ;;
      # 其他路径配置，检查是否需要替换
      *)
        # 如果路径不在正确的目录下，则替换
        if [[ $old_value != $install_dir* && $old_value != $data_dir* && $old_value != $log_dir* ]]; then
          new_value="$install_dir/$(basename "$old_value")"
        fi
        ;;
    esac
    
    echo "$new_value"
  }
  
  # 提取所有配置行（包括被注释的），匹配包含路径的配置
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    
    # 判断是否被注释
    local is_commented=false
    [[ $line =~ ^[[:space:]]*# ]] && is_commented=true
    
    # 提取key和value（处理注释行）
    local key value
    if $is_commented; then
      # 注释行：提取 # 后面的内容
      if [[ $line =~ ^[[:space:]]*#[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
      else
        continue
      fi
    else
      # 非注释行
      if [[ $line =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
      else
        continue
      fi
    fi
    
    # 检查value是否为路径（以/开头）或者是特殊的user配置
    if [[ $value =~ ^/ ]] || [[ $key == "user" ]]; then
      local new_value=$(get_new_path "$key" "$value")
      
      # 如果确定了新值，则更新配置
      if [[ -n "$new_value" ]]; then
        if $is_commented; then
          # 取消注释并设置新值
          sed -i $SED_INPLACE_OPT "s|^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|g" "$config_file"
        else
          # 直接替换
          sed -i $SED_INPLACE_OPT "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|g" "$config_file"
        fi
      fi
    fi
  done < <(grep -E '(^[[:space:]]*#?[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=)' "$config_file")
  
  # 确保关键配置存在
  for key in basedir datadir socket; do
    if ! grep -q "^[[:space:]]*${key}[[:space:]]*=" "$config_file"; then
      local value=$(get_new_path "$key" "")
      sed -i $SED_INPLACE_OPT "/^\[mysqld\]/a ${key} = ${value}" "$config_file"
    fi
  done
  
  # 确保[client]段也有socket配置
  if grep -q "^\[client\]" "$config_file" && ! sed -n '/^\[client\]/,/^\[.*\]/p' "$config_file" | grep -q "^[[:space:]]*socket"; then
    sed -i $SED_INPLACE_OPT "/^\[client\]/a socket = $install_dir/mysql.sock" "$config_file"
  fi
}

copy_files() {
	info "复制配置文件..."
	if [ "$SOURCE_DIR" != "$install_dir" ]; then
	  debug "拷贝配置文件从 $SOURCE_DIR 到 $install_dir"
	  safe_mkdir "$install_dir"
	  if [ -d "$SOURCE_DIR/bin" ] && [ -d "$SOURCE_DIR/conf" ]; then
	    cp -r "$SOURCE_DIR"/{bin,conf} "$install_dir"/ || warn "配置文件复制失败"
	  else
	    warn "源目录中缺少bin或conf目录"
	  fi
	  if [ $need_sudo -eq 1 ]; then
	    sudo chown -R ${usr}:${usr_group} "$install_dir" || warn "设置安装目录所有者失败"
	  else
	    chown -R ${usr}:${usr_group} "$install_dir" 2>/dev/null || warn "无法更改 $install_dir 的所有者（非 root 用户）"
	  fi
	else
	  debug "安装目录与源目录相同，跳过复制"
	fi
	
  # 动态替换my.cnf中的路径，日志目录始终为/var/log/mysql
  local cnf_file="$install_dir/conf/my.cnf"
  if [ -f "$cnf_file" ]; then
    debug "调整MySQL配置文件..."
    # 根据实际MySQL版本调整配置兼容性
    if [ -f "$install_dir/bin/mysqld" ]; then
      adjust_cnf_for_version "$cnf_file" "$install_dir/bin/mysqld"
    else
      warn "MySQL二进制文件不存在，跳过版本兼容性调整"
    fi
    # 更新配置文件中的路径
    update_config "$cnf_file"
    debug "配置文件调整完成"
  else
    warn "配置文件不存在: $cnf_file"
  fi
  debug "配置文件复制完成"
}

# 下载并解压MySQL
download_and_extract() {
  # 确保下载目录存在
  safe_mkdir "$DOWNLOAD_DIR"
  
  # 检查是否需要下载
  if [ ! -f "$gz_file" ] || ! check_file_integrity "$gz_file"; then
    info "下载MySQL安装包: $mysql_url"
    
    if ! safe_download "$mysql_url" "$gz_file"; then
      error "无法下载MySQL安装包，请检查网络连接或手动下载到: $DOWNLOAD_DIR"
    fi
    
    if ! check_file_integrity "$gz_file"; then
      error "下载的文件损坏或不完整: $gz_file"
    fi
  else
    debug "MySQL安装包已存在: $gz_file"
  fi

  # 解压安装包
  info "解压MySQL安装包..."
  local extract_dir=$(tar -tf "$gz_file" | head -1 | cut -d/ -f1)
  local extract_path="$DOWNLOAD_DIR/$extract_dir"
  debug "解压目录: $extract_path"
  
  # 清理旧的解压目录
  [ -d "$extract_path" ] && rm -rf "$extract_path"
  
  # 解压文件
  if ! tar -xf "$gz_file" -C "$DOWNLOAD_DIR"; then
    rm -f "$gz_file"
    error "解压失败: $gz_file"
  fi
  
  # 确保安装目录存在
  safe_mkdir "$install_dir"
  
  # 复制文件到安装目录（避免覆盖现有文件）
  debug "复制文件到安装目录: $install_dir"
  if ! rsync -az --ignore-existing "$extract_path"/ "$install_dir"/; then
    error "复制文件失败"
  fi
  
  # 清理临时目录
  rm -rf "$extract_path"
  debug "解压完成"
}

install_dependencies() {
  info "检查系统依赖..."
  if [ "$OS" == "Linux" ]; then
    if which rpm > /dev/null 2>&1 && which yum > /dev/null 2>&1; then
      if [ `rpm -qa | grep -i libaio | grep -v grep | wc -l` -eq 0 ]; then
        info "安装libaio依赖..."
        yum install -y libaio || warn "libaio安装失败，请手动安装"
      else
        debug "libaio依赖已安装"
      fi
    elif which apt > /dev/null 2>&1; then
      if [ `dpkg -l | grep -i libaio1 | grep -v grep | wc -l` -eq 0 ]; then
        info "安装libaio1依赖..."
        apt-get update && apt-get install -y libaio1 || warn "libaio1安装失败，请手动安装"
      else
        debug "libaio1依赖已安装"
      fi
      if [ `dpkg -l | grep -i libncurses5 | grep -v grep | wc -l` -eq 0 ]; then
        info "安装libncurses5依赖..."
        apt-get install -y libncurses5 || warn "libncurses5安装失败，请手动安装"
      else
        debug "libncurses5依赖已安装"
      fi
    else
      warn "未知的包管理器，跳过依赖安装"
    fi
  else
    # sudo执行安装脚本时会提权为root而brew不支持root，需以当前用户执行brew安装依赖
    info "macOS系统：需安装wget、lsof依赖，执行安装命令：brew install wget lsof"
  fi
  debug "依赖安装检查完成"
}

setup_user_and_system() {
  info "配置用户和系统设置..."
  if [ $need_sudo -eq 1 ]; then
    # 需要提权，设置系统级用户和限制
    if [ "$OS" == "Linux" ]; then
      if ! id -u $usr > /dev/null 2>&1; then
        info "创建MySQL用户: $usr"
        sudo useradd -M -s /sbin/nologin $usr || warn "用户 $usr 创建失败，可能已存在"
      else
        debug "MySQL用户 $usr 已存在"
      fi
      if ! getent group $usr_group > /dev/null 2>&1; then
        info "创建MySQL用户组: $usr_group"
        sudo groupadd $usr_group || warn "用户组 $usr_group 创建失败，可能已存在"
      else
        debug "MySQL用户组 $usr_group 已存在"
      fi
      limits=/etc/security/limits.conf
      if [ -w "$limits" ]; then
        wfile "mysql    soft    nproc    16384" $limits
        wfile "mysql    hard    nproc    16384" $limits
        wfile "mysql    soft    nofile    65536" $limits
        wfile "mysql    hard    nofile    65536" $limits
        wfile "mysql    soft    stack    1024000" $limits
        wfile "mysql    hard    stack    1024000" $limits
        debug "系统资源限制配置已更新"
      fi
      if [ -w "/etc/sysctl.conf" ]; then
        wfile "vm.swappiness = 5" /etc/sysctl.conf "sysctl -p" || warn "sysctl配置更新失败"
      fi
    elif [ "$OS" == "Darwin" ]; then
      if ! dscl . -read /Users/_mysql > /dev/null 2>&1; then
        info "创建用户 $usr"
        dscl . -create /Users/$usr || warn "用户 $usr 创建失败"
        dscl . -create /Users/$usr UserShell /usr/bin/false || warn "用户shell设置失败"
        dscl . -create /Users/$usr UniqueID "$(uuidgen)" || warn "用户ID设置失败"
        dscl . -create /Users/$usr PrimaryGroupID 89 # _mysql group ID || warn "用户组ID设置失败"
        dscl . -create /Users/$usr NFSHomeDirectory /var/empty || warn "用户家目录设置失败"
      fi
      if ! dscl . -read /Groups/$usr_group > /dev/null 2>&1; then
        info "创建组 $usr_group"
        dscl . -create /Groups/$usr_group || warn "用户组 $usr_group 创建失败"
        dscl . -create /Groups/$usr_group PrimaryGroupID 89 || warn "用户组ID设置失败"
      fi
      debug "在macOS上跳过系统资源限制配置"
    fi
  else
    debug "使用当前用户，跳过系统用户创建"
  fi
  debug "用户和系统设置配置完成"
}

prepare_dirs() {
	info "准备目录结构..."
	# 清理旧的日志目录下的内容（不删除目录本身）
	if [ -d "$log_dir" ]; then
	  debug "清理旧日志目录: $log_dir"
	  if [ $need_sudo -eq 1 ]; then
	    sudo find "$log_dir" -mindepth 1 -delete 2>/dev/null || sudo rm -rf "$log_dir"/* "$log_dir"/.* 2>/dev/null || warn "清理日志目录失败"
	  else
	    find "$log_dir" -mindepth 1 -delete 2>/dev/null || rm -rf "$log_dir"/* "$log_dir"/.* 2>/dev/null || warn "清理日志目录失败"
	  fi
	fi

	# 创建主日志目录以及子目录
	local log_subdirs=("$log_dir" "$log_dir/binlog" "$log_dir/redolog" "$log_dir/undolog")

	debug "创建日志目录..."
	for dir in "${log_subdirs[@]}"; do
	  if [ ! -d "$dir" ]; then
	    debug "创建目录: $dir"
	    if [ $need_sudo -eq 1 ] && [[ "$dir" =~ ^/(var|etc)/ ]]; then
	      # 如果需要提权且目录在系统目录中，使用sudo创建
	      sudo mkdir -p "$dir" || warn "创建系统目录失败: $dir"
	      # 对于日志目录，设置适当的权限
	      if [[ "$dir" =~ ^/var/log/ ]]; then
	        sudo chown $usr:$usr_group "$dir" || warn "设置日志目录所有者失败: $dir"
	        sudo chmod 755 "$dir" || warn "设置日志目录权限失败: $dir"
	      fi
	    else
	      mkdir -p "$dir" || warn "创建目录失败: $dir"
	      # 为用户目录设置适当的权限
	      if [[ "$dir" != "$HOME" ]]; then
	        chown $usr:$usr_group "$dir" 2>/dev/null || warn "设置目录所有者失败: $dir"
	        chmod 755 "$dir" 2>/dev/null || warn "设置目录权限失败: $dir"
	      fi
	    fi
	  else
	    debug "目录已存在: $dir"
	  fi
	done

	# 确保安装目录存在
	if [ ! -d "$install_dir" ]; then
	  info "创建安装目录: $install_dir"
	  safe_mkdir "$install_dir"
	fi
	debug "目录结构准备完成"
}

create_default_cnf() {
  info "创建MySQL配置文件..."
  local cnf="$install_dir/conf/my.cnf"
  if [ ! -f "$cnf" ]; then
    debug "创建新的配置文件: $cnf"
    safe_mkdir "$(dirname "$cnf")"
    cat > "$cnf" << EOF
[mysqld]
port=3306
user=$usr
basedir=$install_dir
datadir=$data_dir
socket=$install_dir/mysql.sock
log-error=$log_dir/error.log
pid-file=$install_dir/data/mysqld.pid
lower-case-table-names=1
explicit_defaults_for_timestamp=true

# 日志配置
log_bin=mysql-bin
binlog_format=mixed
server-id=1
EOF
    if [ $? -eq 0 ]; then
      debug "配置文件创建成功"
    else
      warn "配置文件创建失败"
    fi
  else
    debug "配置文件已存在，更新路径配置"
    # 智能路径替换，包含所有路径处理
    update_config "$cnf"
  fi

  debug "创建数据目录: $data_dir"
  safe_mkdir "$data_dir"
  
  debug "设置目录权限..."
  if [ $need_sudo -eq 1 ]; then
    sudo chown -R ${usr}:${usr_group} "$log_dir" || warn "设置日志目录所有者失败"
    sudo chown -R ${usr}:${usr_group} "$install_dir" || warn "设置安装目录所有者失败"
    sudo chown -R ${usr}:${usr_group} "$data_dir" || warn "设置数据目录所有者失败"
    sudo chmod -R 755 "$data_dir" || warn "设置数据目录权限失败"
    sudo chmod -R 755 "$log_dir" || warn "设置日志目录权限失败"
  else
    chown -R ${usr}:${usr_group} "$log_dir" 2>/dev/null || warn "无法更改 $log_dir 的所有者（非 root 用户）"
    chown -R ${usr}:${usr_group} "$install_dir" 2>/dev/null || warn "无法更改安装目录所有者（非 root 用户）"
    chown -R ${usr}:${usr_group} "$data_dir" 2>/dev/null || warn "无法更改数据目录所有者（非 root 用户）"
    chmod -R 755 "$data_dir" 2>/dev/null || warn "无法设置数据目录权限"
    chmod -R 755 "$log_dir" 2>/dev/null || warn "无法设置日志目录权限"
  fi
  debug "配置文件和目录设置完成"
}

# 初始化MySQL数据目录
initialize() {
  local cnf="$install_dir/conf/my.cnf"
  
  # 检查数据目录是否为空或不存在
  if [ ! -d "$data_dir" ] || [ -z "$(ls -A "$data_dir" 2>/dev/null)" ]; then
    info "初始化MySQL数据目录: $data_dir"
    
    # 创建数据目录并设置权限
    safe_mkdir "$data_dir"
    if [ $need_sudo -eq 1 ]; then
      sudo chown -R "$usr:$usr_group" "$data_dir"
      sudo chmod -R 755 "$data_dir"
    else
      chown -R "$usr:$usr_group" "$data_dir"
      chmod -R 755 "$data_dir"
    fi
    
    # 执行初始化
    local init_log="$log_dir/init.log"
    local init_cmd="$install_dir/bin/mysqld --initialize --user=$usr --basedir=$install_dir --datadir=$data_dir --console --lower-case-table-names=1 --explicit_defaults_for_timestamp=true"
    
    debug "执行初始化命令..."
    if ! eval "$init_cmd" > "$init_log" 2>&1; then
      error "MySQL初始化失败"
      [ -f "$init_log" ] && cat "$init_log" >&2
      exit 1
    fi
    
    # 提取临时密码
    if [ -f "$init_log" ]; then
      pass=$(grep "password" "$init_log" | awk -F ': ' '{print $2}')
      info "MySQL临时密码: $pass"
      rm -f "$init_log"
    fi
    
    # 设置日志目录权限
    if [ $need_sudo -eq 1 ]; then
      sudo chown -R "$usr:$usr_group" "$log_dir"
    else
      chown -R "$usr:$usr_group" "$log_dir"
    fi
  else
    debug "数据目录已存在且非空，跳过初始化"
  fi
  
  # 确保配置文件权限正确
  chmod 644 "$cnf"
}

startup() {
  # 如果安装到系统目录，则以mysql用户执行启动脚本，否则直接执行
  if [ ! -f "$install_dir/bin/startup.sh" ]; then
    error "启动脚本不存在: $install_dir/bin/startup.sh"
    exit 1
  fi

  if [ $need_sudo -eq 1 ]; then
    # 需要提权，使用mysql用户启动
    sudo -u $usr $install_dir/bin/startup.sh
  else
    # 不需要提权，直接启动
    $install_dir/bin/startup.sh
  fi

  [ $? -gt 0 ] && error "启动失败，查看错误日志: $log_dir/error.log" && exit 1
  debug "MySQL进程信息:"
  ps -ef | grep mysql
}

setup_service() {
  if [ "$OS" == "Linux" ]; then
    if [ `ls /usr/lib/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ] && [ `ls /etc/systemd/system/ | grep mysql | grep -v grep | wc -l` -eq 0 ]; then
      info "安装mysqld服务:/usr/lib/systemd/system/mysqld.service"
      cat >> /usr/lib/systemd/system/mysqld.service << EOF
[Unit]
Description=mysql service
[Service]
Type=forking
ExecStart=$install_dir/bin/startup.sh
ExecStop=$install_dir/bin/stop.sh
User=$usr
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable mysqld.service
      debug "MySQL服务已安装并启用"
    else
      debug "MySQL服务已存在，跳过安装"
    fi
  elif [ "$OS" == "Darwin" ]; then
    info "在macOS上不自动设置系统服务。请手动启动MySQL："
    info "cd $install_dir && ./bin/mysqld_safe --datadir=$data_dir &"
  fi
}

set_root_password_and_remote() {
	local current_pass="$pass"
	local target_user="$mysql_user"
	local target_password="$mysql_password"
	
	# 如果用户指定了密码，直接使用
	if [ -n "$target_password" ]; then
		info "使用预设密码设置MySQL用户 '$target_user'"
		password="$target_password"
	elif [ -n "$current_pass" ]; then
		# 如果没有指定密码但有临时密码，提示用户输入
		read -t $INPUT_TIMEOUT -p "为用户 '$target_user' 输入新密码(超时时间$INPUT_TIMEOUT 秒):" password
		# 如未输入密码，则生成8位不包含特殊字符的随机数作为默认密码
		[ ! -n "$password" ] && password=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 8) && echo -en "\n密码输入超时, 生成默认密码:\033[31m $password \033[0m \n"
	else
		# 既没有指定密码也没有临时密码，生成随机密码
		password=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 8)
		info "为用户 '$target_user' 生成随机密码: $password"
	fi
	
	if [ -n "$password" ]; then
		if [ -n "$current_pass" ]; then
			# 使用临时密码修改
			$install_dir/bin/mysql -uroot -p${current_pass} --connect-expired-password --socket=$install_dir/mysql.sock <<EOF
ALTER USER '${target_user}'@'localhost' IDENTIFIED BY '$password';
flush privileges;
exit
EOF
		else
			# 直接设置新密码（适用于全新安装）
			$install_dir/bin/mysql -uroot --socket=$install_dir/mysql.sock <<EOF
ALTER USER '${target_user}'@'localhost' IDENTIFIED BY '$password';
flush privileges;
exit
EOF
		fi
		current_pass=$password
		info "用户 '$target_user' 密码已设置为: $password"
	fi
	
	if [ -n "$current_pass" ]; then
		# 检查MySQL版本
		mysql_version=$($install_dir/bin/mysql -u${target_user} -p${current_pass} --socket=$install_dir/mysql.sock -e 'select version();' 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+')
		major_version=$(echo $mysql_version | cut -d. -f1)
		debug "MySQL版本: $mysql_version, 主版本: $major_version"
		
		# 配置远程访问权限
		if [ "$major_version" = "8" ]; then
			# MySQL 8 远程授权
			debug "配置MySQL 8远程访问权限"
			$install_dir/bin/mysql -u${target_user} -p${current_pass} --socket=$install_dir/mysql.sock <<EOF
CREATE USER IF NOT EXISTS '${target_user}'@'%' IDENTIFIED BY '$current_pass';
ALTER USER '${target_user}'@'%' IDENTIFIED BY '$current_pass';
GRANT ALL PRIVILEGES ON *.* TO '${target_user}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
exit
EOF
		else
			# MySQL 5 远程授权
			debug "配置MySQL 5远程访问权限"
			$install_dir/bin/mysql -u${target_user} -p${current_pass} --socket=$install_dir/mysql.sock <<EOF
use mysql;
update user set host = '%' where user = '${target_user}';
grant all privileges on *.* to '${target_user}'@'%' with grant option;
flush privileges;
exit
EOF
		fi
		debug "远程访问权限配置完成"
	fi
}

# 解析命令行参数并初始化变量
parse_arguments() {
  local temp_install_dir="$DEFAULT_INSTALL_DIR"
  local temp_version="$DEFAULT_VERSION"
  local temp_log_level="info"
  local temp_mysql_user="root"
  local temp_mysql_password=""
  
  # 处理参数
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      --install-dir)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --install-dir 需要指定目录路径" >&2
          show_help
          exit 1
        fi
        temp_install_dir="$2"
        shift 2
        ;;
      --install-dir=*)
        temp_install_dir="${1#*=}"
        shift
        ;;
      --version)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --version 需要指定版本号" >&2
          show_help
          exit 1
        fi
        temp_version="$2"
        shift 2
        ;;
      --version=*)
        temp_version="${1#*=}"
        shift
        ;;
      --log-level)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --log-level 需要指定日志级别" >&2
          show_help
          exit 1
        fi
        temp_log_level="$2"
        shift 2
        ;;
      --log-level=*)
        temp_log_level="${1#*=}"
        shift
        ;;
      --mysql-user)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --mysql-user 需要指定用户名" >&2
          show_help
          exit 1
        fi
        temp_mysql_user="$2"
        shift 2
        ;;
      --mysql-user=*)
        temp_mysql_user="${1#*=}"
        shift
        ;;
      --mysql-password)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --mysql-password 需要指定密码" >&2
          show_help
          exit 1
        fi
        temp_mysql_password="$2"
        shift 2
        ;;
      --mysql-password=*)
        temp_mysql_password="${1#*=}"
        shift
        ;;
      -*)
        echo "错误: 未知选项: $1" >&2
        show_help
        exit 1
        ;;
      *)
        echo "错误: 不支持的位置参数: $1" >&2
        echo "请使用命名参数，例如: --install-dir=/path/to/mysql --version=8" >&2
        show_help
        exit 1
        ;;
    esac
  done

  # 验证版本号
  if [[ ! "$temp_version" =~ ^(5|8)$ ]]; then
    echo "错误: 版本必须是 5 或 8，当前为: $temp_version" >&2
    exit 1
  fi

  # 验证用户名
  if [[ -z "$temp_mysql_user" ]]; then
    echo "错误: MySQL用户名不能为空" >&2
    exit 1
  fi

  # 设置日志级别
  case "$temp_log_level" in
    debug)
      CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG
      ;;
    info)
      CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO
      ;;
    warn)
      CURRENT_LOG_LEVEL=$LOG_LEVEL_WARN
      ;;
    error)
      CURRENT_LOG_LEVEL=$LOG_LEVEL_ERROR
      ;;
    *)
      echo "错误: 日志级别必须是 debug、info、warn 或 error 之一，当前为: $temp_log_level" >&2
      exit 1
      ;;
  esac

  # 设置全局变量
  install_dir="$temp_install_dir"
  data_dir="$install_dir/data"
  version="$temp_version"
  mysql_user="$temp_mysql_user"
  mysql_password="$temp_mysql_password"
  
  # 根据版本设置下载URL
  set_mysql_url
  
  # 初始化其他变量
  gz_file="$DOWNLOAD_DIR/$(basename "$mysql_url")"
  
  info "配置信息:"
  info "  安装目录: $install_dir"
  info "  数据目录: $data_dir"
  info "  MySQL版本: $version"
  info "  MySQL用户名: $mysql_user"
  if [[ -n "$mysql_password" ]]; then
    info "  MySQL密码: [已设置]"
  else
    info "  MySQL密码: [将自动生成]"
  fi
  info "  日志级别: $temp_log_level"
  info "  下载目录: $DOWNLOAD_DIR"
}

# 根据操作系统和版本设置MySQL下载URL
set_mysql_url() {
  if [ "$OS" == "Linux" ]; then
    if command -v rpm >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
      if [ "$version" = "5" ]; then
        mysql_url="https://mirrors.aliyun.com/mysql/MySQL-5.7/mysql-5.7.36-el7-x86_64.tar.gz"
      else
        mysql_url="https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.27-el7-x86_64.tar.gz"
      fi
    elif command -v apt >/dev/null 2>&1; then
      mysql_url="https://mirrors.aliyun.com/mysql/MySQL-8.0/mysql-8.0.28-linux-glibc2.17-x86_64-minimal.tar.xz"
    else
      echo "错误: 不支持的Linux发行版" >&2
      exit 1
    fi
  elif [ "$OS" == "Darwin" ]; then
    if [ "$version" = "5" ]; then
      echo "错误: macOS 不支持 MySQL 5.7 的官方预编译二进制包" >&2
      exit 1
    else
      mysql_url="https://mirrors.huaweicloud.com/mysql/Downloads/MySQL-8.0/mysql-8.0.29-macos12-x86_64.tar.gz"
    fi
  else
    echo "错误: 不支持的操作系统: $OS" >&2
    exit 1
  fi
}


# 主函数
main() {
  # 阶段1: 参数解析和初始化
  parse_arguments "$@"
  
  info "开始安装MySQL"
  
  pre_check
  
  if [ "${SKIP_DOWNLOAD:-false}" != "true" ]; then
    download_and_extract
  else
    debug "跳过下载步骤"
  fi
  
  copy_files
  install_dependencies
  setup_user_and_system
  prepare_dirs
  create_default_cnf
  initialize
  if [ ! -f "$install_dir/bin/startup.sh" ]; then
    error "启动脚本不存在: $install_dir/bin/startup.sh"
  fi
  
  info "启动MySQL服务..."
  if [ $need_sudo -eq 1 ]; then
    sudo -u "$usr" "$install_dir/bin/startup.sh" "$install_dir"
  else
    "$install_dir/bin/startup.sh" "$install_dir"
  fi
  
  # 阶段7: 等待服务就绪
  wait_for_mysql_ready
  
  # 阶段8: 配置MySQL
  info "配置MySQL"
  set_root_password_and_remote
  
  info "MySQL安装完成"
  info "安装目录: $install_dir"
  info "数据目录: $data_dir"
  info "日志目录: $log_dir"
  info "使用命令连接: $install_dir/bin/mysql -u root -p"
}

# 等待MySQL服务就绪
wait_for_mysql_ready() {
  info "等待MySQL服务就绪..."
  local max_wait_time=60
  local wait_time=0
  
  # 尝试多个可能的socket路径
  local socket_paths=(
    "$install_dir/mysql.sock"
    "/tmp/mysql.sock"
    "/var/run/mysqld/mysqld.sock"
  )
  
  # 从配置文件中获取socket路径
  if [ -f "$install_dir/conf/my.cnf" ]; then
    local config_socket=$(grep "^[[:space:]]*socket[[:space:]]*=" "$install_dir/conf/my.cnf" | grep -v '^#' | cut -d'=' -f2- | tr -d ' ')
    if [ -n "$config_socket" ]; then
      socket_paths=("$config_socket" "${socket_paths[@]}")
    fi
  fi
  
  # 去重
  local unique_sockets=()
  for socket in "${socket_paths[@]}"; do
    if [[ ! " ${unique_sockets[@]} " =~ " ${socket} " ]]; then
      unique_sockets+=("$socket")
    fi
  done
  socket_paths=("${unique_sockets[@]}")
  
  debug "将尝试以下socket路径: ${socket_paths[*]}"
  
  while [ $wait_time -lt $max_wait_time ]; do
    # 检查进程是否运行
    if pgrep -f "$install_dir/bin/mysqld" >/dev/null; then
      debug "MySQL进程正在运行"
      
      # 尝试每个socket路径
      for socket_path in "${socket_paths[@]}"; do
        debug "检查socket: $socket_path"
        if [ -S "$socket_path" ]; then
          debug "Socket文件存在: $socket_path"
          # 尝试连接
          if $install_dir/bin/mysqladmin -u root --socket="$socket_path" ping >/dev/null 2>&1; then
            info "MySQL服务已就绪 (使用socket: $socket_path)"
            return 0
          else
            debug "Socket连接失败: $socket_path"
          fi
        else
          debug "Socket文件不存在: $socket_path"
        fi
      done
    else
      debug "MySQL进程未运行"
    fi
    
    sleep 2
    wait_time=$((wait_time + 2))
    debug "等待中... ($wait_time/$max_wait_time 秒)"
  done
  
  error "等待MySQL服务就绪超时"
  info "请检查:"
  info "  1. 进程状态: pgrep -f mysqld"
  for socket_path in "${socket_paths[@]}"; do
    info "  2. Socket文件: ls -la $socket_path"
  done
  info "  3. 错误日志或端口: tail -50 $log_dir/error.log"
  exit 1
}

main "$@"
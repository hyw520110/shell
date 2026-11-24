#!/bin/bash
# MySQL自动安装脚本
# 功能: 自动下载、安装、配置MySQL数据库
# 支持: MySQL 5.7 和 8.0, Linux 和 macOS

set -euo pipefail

# 错误处理：捕获错误并输出详细信息
trap 'echo "$(date +"%Y%m%d %H:%M:%S"): [ERROR] 脚本在第 $LINENO 行失败，执行的命令: $BASH_COMMAND" >&2' ERR

# 全局变量定义 
readonly SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly OS=$(uname)
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REMOTE_SCRIPT="$SCRIPT_DIR/remote.sh"

if [ -f "$REMOTE_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$REMOTE_SCRIPT"
fi

# 用户可配置变量
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"$HOME/Downloads"}
INPUT_TIMEOUT=30
DEFAULT_VERSION="8"
DEFAULT_INSTALL_DIR="$HOME/mysql"

# 运行时变量（将在parse_arguments中初始化）
install_dir=""
data_dir=""
version=""
version_full=""       # 完整版本号，如 8.0 或 8.4
brew_mysql_package="" # brew 包名，如 mysql@8.4
BREW_CMD=""
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
# 标记是否已在pre_check中启动MySQL
MYSQL_STARTED_IN_PRECHECK=false
# 修复模式标记（保留数据目录）
REPAIR_MODE=false
# 跳过初始化标记
SKIP_INIT=false
# 跳过密码设置标记
SKIP_PASSWORD=false
# 可选 MySQL 指标采集
ENABLE_MYSQL_EXPORTER=false
MYSQL_EXPORTER_SCRIPT="${MYSQL_EXPORTER_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/monitor/prometheus/bin/start_mysql_exporter.sh}"
MYSQL_EXPORTER_USER="${MYSQL_EXPORTER_USER:-exporter}"
MYSQL_EXPORTER_PASSWORD="${MYSQL_EXPORTER_PASSWORD:-}"
MYSQL_EXPORTER_LISTEN_ADDRESS="${MYSQL_EXPORTER_LISTEN_ADDRESS:-:9104}"
INSTALL_SERVICE_ONLY=false
UNINSTALL_SERVICE_ONLY=false
MYSQL_LAUNCHAGENT_LABEL="${MYSQL_LAUNCHAGENT_LABEL:-org.mysql.server}"
UPGRADE_MODE=false
UPGRADE_BACKUP_DIR=""
MYSQL_84_RELEASE="${MYSQL_84_RELEASE:-8.4.9}"
MYSQL_UPGRADE_PASSWORD="${MYSQL_UPGRADE_PASSWORD:-}"
MYSQL_UPGRADE_WAIT_SECONDS="${MYSQL_UPGRADE_WAIT_SECONDS:-600}"

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
  --version=VERSION         指定MySQL版本 (5, 5.7, 8, 8.0, 8.4, 9, 9.6 等, 默认: 8)
                         支持大版本号(如 8)或完整版本号(如 8.4)
                         大版本号会自动查找该版本下最新的可用包
                         指定版本不存在时回退到最新版本
  --log-level=LEVEL         指定日志级别 (debug, info, warn, error, 默认: info)
  --mysql-user=USER         指定MySQL用户名 (默认: root)
  --mysql-password=PASS     指定MySQL root密码 (不指定则随机生成)
  --enable-exporter         安装并启动 mysqld_exporter，用于采集 MySQL Server 指标
  --exporter-user=USER      mysqld_exporter MySQL账号 (默认: exporter)
  --exporter-password=PASS  mysqld_exporter MySQL密码 (不指定则自动生成)
  --exporter-listen=ADDR    mysqld_exporter监听地址 (默认: :9104)
  --install-service         只安装/刷新自启动服务，不重新安装 MySQL
  --uninstall-service       只卸载自启动服务
  --upgrade                 原地升级现有 MySQL，保留配置和数据
  --upgrade-backup-dir=DIR  升级前完整备份目录（默认: 安装目录同级 upgrade-backups）

示例:
  $0                                          # 安装MySQL 8到默认目录，使用默认用户名和随机密码
  $0 --install-dir ~/mysql                    # 安装MySQL 8到 ~/mysql 目录
  $0 --version=8                              # 安装MySQL 8.x最新版
  $0 --version=8.4                            # 安装MySQL 8.4（精确匹配）
  MYSQL_UPGRADE_PASSWORD='***' $0 --upgrade --version=8.4 --install-dir=~/mysql
  $0 --version=9                              # 安装MySQL 9.x最新版
  $0 --mysql-user=admin --mysql-password=123456  # 指定用户名和密码
  $0 --mysql-password=123456 --enable-exporter    # 安装MySQL并启用 MySQL 指标采集
  $0 --version=8 --log-level=debug            # 安装MySQL 8到默认目录，使用debug级别
  sudo $0 --install-dir /opt/mysql            # 以root权限安装到系统目录

注意:
  - 如果安装到用户目录 (~ 开头)，脚本不需要 root 权限
  - 如果安装到系统目录 (/opt, /usr 等)，需要 root 权限
  - 日志目录使用 /var/log/mysql (需要root权限) 或 ~/.mysql_log
  - 下载目录可通过 DOWNLOAD_DIR 环境变量指定，默认为 ~/Downloads
  - 如果不指定密码，将自动生成8位随机密码
  - 升级必须通过 MYSQL_UPGRADE_PASSWORD 提供现有 root 密码；脚本不会打印密码
  - 升级会执行慢关闭并完整备份，默认等待首次数据升级 600 秒，失败时自动恢复
  - --enable-exporter 只负责启动 mysqld_exporter；接入 SkyWalking 还需运行:
    apm/skywalking/bin/setup-mysql-monitoring.sh --mysql-exporter-target 127.0.0.1:9104 --oap-endpoint 127.0.0.1:11800
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

brew_command() {
  if [ -n "$BREW_CMD" ] && [ -x "$BREW_CMD" ]; then
    echo "$BREW_CMD"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  if [ -x /opt/homebrew/bin/brew ]; then
    echo /opt/homebrew/bin/brew
    return 0
  fi
  if [ -x /usr/local/bin/brew ]; then
    echo /usr/local/bin/brew
    return 0
  fi
  return 1
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

# 查找 adl 工具
find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

# 安装 wget
install_wget() {
    info "正在安装 wget..."
    if [[ "$OS" == "Darwin" ]]; then
        if command -v brew &> /dev/null; then
            brew install wget
        else
            error "请先安装 Homebrew: https://brew.sh"
            return 1
        fi
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y wget
    elif [[ -f /etc/debian_version ]]; then
        apt-get update && apt-get install -y wget
    else
        error "无法自动安装 wget，请手动安装"
        return 1
    fi
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

  # 优先使用 adl
  local adl_cmd
  if adl_cmd=$(find_adl); then
      info "使用 adl 加速下载..."
      local dir=$(dirname "$output")
      local file=$(basename "$output")
      if "$adl_cmd" "$url" "$dir" "$file"; then
          return 0
      fi
      warn "adl 下载失败，尝试 wget..."
  fi

  # 检查并安装 wget
  if ! command -v wget &> /dev/null; then
      install_wget || return 1
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

# 检查系统中已有的MySQL安装
check_existing_installs() {
  local found_installs=()
  local all_installs=()
  
  # 常见安装目录
  local current_user=$(whoami)
  local possible_dirs=(
    "$HOME"
    "/home/$current_user"
    "/usr/local/mysql"
    "/usr/local"
    "/opt/mysql"
    "/opt"
  )
  
  for dir in "${possible_dirs[@]}"; do
    [ ! -d "$dir" ] && continue
    # 限制搜索深度避免超时
    local found=$(find "$dir" -maxdepth 3 -type f -name mysqld 2>/dev/null | awk -F'/bin/mysqld' '{print $1}' | sort -u)
    if [ -n "$found" ]; then
      for f in $found; do
        # 规范化路径
        local normalized=$(cd "$f" 2>/dev/null && pwd)
        if [ -n "$normalized" ]; then
          # 避免重复
          local already_found=false
          for existing in "${all_installs[@]:-}"; do
            [ "$existing" = "$normalized" ] && already_found=true && break
          done
          [ "$already_found" = false ] && all_installs+=("$normalized")
        fi
      done
    fi
  done
  
  # 检查当前目标安装目录是否已有安装
  local current_has_install=false
  if [ -f "$install_dir/bin/mysqld" ]; then
    current_has_install=true
    # 确保当前目录在列表中
    local in_list=false
    for existing in "${all_installs[@]:-}"; do
      [ "$existing" = "$install_dir" ] && in_list=true && break
    done
    [ "$in_list" = false ] && all_installs+=("$install_dir")
  fi
  
  # 如果找到安装
  if [ ${#all_installs[@]} -gt 0 ]; then
    warn "检测到系统中已有MySQL安装:"
    
    local i=1
    local new_install_option=""
    for existing_dir in "${all_installs[@]}"; do
      local version=""
      local data_status=""
      if [ -f "$existing_dir/bin/mysqld" ]; then
        version=$("$existing_dir/bin/mysqld" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "未知")
      fi
      # 检查数据目录状态
      local existing_data_dir="$existing_dir/data"
      if [ -d "$existing_data_dir" ] && [ -d "$existing_data_dir/mysql" ]; then
        data_status="已初始化"
      elif [ -d "$existing_data_dir" ]; then
        data_status="数据目录存在(未初始化)"
      else
        data_status="未初始化"
      fi
      echo "  $i) $existing_dir (版本: ${version:-未知}, $data_status)"
      i=$((i+1))
    done
    
    # 添加"安装到新目录"选项
    new_install_option=$i
    echo "  $i) 安装到新目录: $install_dir"
    echo ""
    
    read -p "请选择操作目标 [1-$i]: " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$new_install_option" ]; then
      # 选择了已有安装
      local selected_dir="${all_installs[$((selection-1))]}"
      echo ""
      echo "已选择: $selected_dir"
      
      # 更新安装目录
      install_dir="$selected_dir"
      data_dir="$install_dir/data"
      
      # 自动检测数据目录状态，决定是否跳过初始化
      if [ -d "$data_dir" ] && [ -d "$data_dir/mysql" ]; then
        SKIP_INIT=true
        SKIP_PASSWORD=true
        REPAIR_MODE=true
        SKIP_DOWNLOAD=true
        
        # 询问是否要强制重新初始化
        echo ""
        read -p "是否强制重新初始化数据目录？这将清空所有数据 [y/N]: " force_init
        if [ "$force_init" = "y" ] || [ "$force_init" = "Y" ]; then
          warn "警告: 将清空数据目录，所有数据将丢失!"
          read -p "确认清空数据目录？[y/N]: " confirm_init
          if [ "$confirm_init" = "y" ] || [ "$confirm_init" = "Y" ]; then
            # 备份数据目录（重命名）
            if [ -d "$data_dir" ]; then
              backup_dir="${data_dir}_backup_$(date +%Y%m%d_%H%M%S)"
              info "备份数据目录: $data_dir -> $backup_dir"
              mv "$data_dir" "$backup_dir"
              info "数据已备份，原数据目录将被重新初始化"
            fi
            SKIP_INIT=false
            SKIP_PASSWORD=false
            REPAIR_MODE=false
            SKIP_DOWNLOAD=false
          fi
        else
          # 用户选择不清空数据目录，显示跳过初始化提示
          info "数据目录已初始化，将跳过数据初始化和密码设置"
        fi
      else
        info "数据目录未初始化，将执行初始化"
        SKIP_INIT=false
        SKIP_PASSWORD=false
        REPAIR_MODE=true
        SKIP_DOWNLOAD=true
      fi
      
    elif [ "$selection" = "$new_install_option" ]; then
      # 安装到新目录
      info "将安装到新目录: $install_dir"
      REPAIR_MODE=false
      SKIP_INIT=false
      SKIP_PASSWORD=false
    else
      echo "无效选择，退出。"
      exit 1
    fi
    echo ""
  else
    # 没有找到已有安装，直接安装
    REPAIR_MODE=false
    SKIP_INIT=false
    SKIP_PASSWORD=false
  fi
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
  
  # 修复模式：检查 MySQL 是否已在运行，并更新脚本
  if [ "${REPAIR_MODE:-false}" = "true" ]; then
    # 修复模式：强制复制最新脚本
    info "修复模式：更新脚本文件..."
    
    # 如果需要 sudo 权限，先获取权限
    if [ $need_sudo -eq 1 ]; then
      # 验证 sudo 权限
      if ! sudo -n true 2>/dev/null; then
        info "需要sudo权限来更新脚本文件..."
        sudo -v || { warn "无法获取sudo权限，跳过脚本更新"; }
      fi
    fi
    
    # 复制脚本文件（仅当源目录与目标目录不同时）
    if [ "$SOURCE_DIR" != "$install_dir" ]; then
      if [ -d "$SOURCE_DIR/bin" ]; then
        if [ $need_sudo -eq 1 ]; then
          sudo cp -r "$SOURCE_DIR/bin"/* "$install_dir/bin/" || warn "部分脚本文件复制失败"
        else
          cp -r "$SOURCE_DIR/bin"/* "$install_dir/bin/" || warn "部分脚本文件复制失败"
        fi
        info "脚本文件已更新"
      fi
      # 修复模式下不覆盖配置文件，保留用户配置
      # 配置文件的更新在 create_default_cnf 中通过 update_config 完成
    else
      debug "源目录与目标目录相同，跳过复制"
    fi
    
    if pgrep -f "$install_dir/bin/mysqld" > /dev/null 2>&1; then
      info "MySQL已在运行，跳过启动"
      MYSQL_STARTED_IN_PRECHECK=true
      SKIP_DOWNLOAD=true
      return 0
    fi
  fi
  
  # 检查安装状态
  if check_installation; then
    if check_initialization; then
      info "MySQL已安装且已初始化"
      [ ! -f "$install_dir/bin/startup.sh" ] && cp -r "$SOURCE_DIR"/{bin,conf} "$install_dir"/
      info "启动MySQL服务..."
      debug "执行启动脚本: $install_dir/bin/startup.sh"
      if [ $need_sudo -eq 1 ]; then
        # 系统级安装，使用sudo直接启动（startup.sh内部会切换用户）
        sudo bash "$install_dir/bin/startup.sh" "$install_dir"
      else
        # 用户级安装，直接启动（startup.sh内部会检查是否需要sudo）
        "$install_dir/bin/startup.sh" "$install_dir"
      fi
      if [ $? -eq 0 ]; then
        MYSQL_STARTED_IN_PRECHECK=true
        info "MySQL服务启动成功"
      else
        # 显示错误日志帮助诊断
        warn "MySQL服务启动失败，查看错误日志:"
        local error_log="$log_dir/error.log"
        if [ -f "$error_log" ]; then
          tail -20 "$error_log"
        else
          echo "错误日志不存在: $error_log"
          # 尝试从配置文件中查找日志路径
          local cnf_error_log=$(grep '^log-error' "$install_dir/conf/my.cnf" 2>/dev/null | awk -F'=' '{print $2}' | xargs)
          if [ -n "$cnf_error_log" ] && [ -f "$cnf_error_log" ]; then
            echo "从配置文件找到错误日志:"
            tail -20 "$cnf_error_log"
          fi
        fi
        error "MySQL服务启动失败"
      fi
      SKIP_DOWNLOAD=true
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
  
  # 检查文件是否需要 sudo 权限
  local use_sudo=false
  if [ ! -w "$config_file" ]; then
    use_sudo=true
    debug "配置文件需要 sudo 权限修改"
  fi
  
  # sed 命令包装函数
  do_sed() {
    if $use_sudo; then
      sudo sed -i $SED_INPLACE_OPT "$@"
    else
      sed -i $SED_INPLACE_OPT "$@"
    fi
  }
  
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
        # 对于 socket 和 user，只更新 [mysqld] 段
        if [[ $key == "socket" ]] || [[ $key == "user" ]]; then
          if $is_commented; then
            do_sed "/^\[mysqld\]/,/^\[/ s|^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|" "$config_file"
          else
            do_sed "/^\[mysqld\]/,/^\[/ s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|" "$config_file"
          fi
        else
          # 其他配置使用全局替换
          if $is_commented; then
            do_sed "s|^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|g" "$config_file"
          else
            do_sed "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${new_value}|g" "$config_file"
          fi
        fi
      fi
    fi
  done < <(grep -E '(^[[:space:]]*#?[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=)' "$config_file")
  
  # 确保关键配置存在
  for key in basedir datadir socket; do
    if ! grep -q "^[[:space:]]*${key}[[:space:]]*=" "$config_file"; then
      local value=$(get_new_path "$key" "")
      do_sed "/^\[mysqld\]/a ${key} = ${value}" "$config_file"
    fi
  done
  
  # 更新 [client] 段的 socket 配置（如果存在则更新，不存在则添加）
  local client_socket="$install_dir/mysql.sock"
  if grep -q "^\[client\]" "$config_file"; then
    if sed -n '/^\[client\]/,/^\[/p' "$config_file" | grep -q "^[[:space:]]*socket"; then
      # 已有 socket 配置，更新它（只更新 [client] 段的）
      do_sed "/^\[client\]/,/^\[/ s|^[[:space:]]*socket[[:space:]]*=.*|socket = $client_socket|" "$config_file"
    else
      # 没有 socket 配置，添加
      do_sed "/^\[client\]/a socket = $client_socket" "$config_file"
    fi
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
  # 修复模式或跳过初始化时，不执行初始化
  if [ "${SKIP_INIT:-false}" = "true" ] || [ "${REPAIR_MODE:-false}" = "true" ]; then
    info "跳过数据目录初始化（修复模式/保留数据）"
    # 确保配置文件权限正确
    local cnf="$install_dir/conf/my.cnf"
    [ -f "$cnf" ] && chmod 644 "$cnf"
    return 0
  fi
  
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
    install_macos_mysql_launchagent
  fi
}

install_macos_mysql_launchagent() {
  [ "$OS" = "Darwin" ] || return 1

  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_file="$plist_dir/$MYSQL_LAUNCHAGENT_LABEL.plist"
  local mysql_home="$install_dir"
  local mysql_data="$data_dir"
  local mysqld_safe="$install_dir/bin/mysqld_safe"
  local log_dir="$HOME/Library/Logs"

  local brew_bin=""
  brew_bin="$(brew_command 2>/dev/null || true)"
  if [ -n "$brew_bin" ] && [ -n "$brew_mysql_package" ] && "$brew_bin" list "$brew_mysql_package" >/dev/null 2>&1; then
    mysql_home="$("$brew_bin" --prefix "$brew_mysql_package")"
    mysql_data="$("$brew_bin" --prefix)/var/mysql"
    mysqld_safe="$mysql_home/bin/mysqld_safe"
    info "使用 Homebrew MySQL 创建 LaunchAgent: $brew_mysql_package"
  fi

  [ -x "$mysqld_safe" ] || error "mysqld_safe 不存在或不可执行: $mysqld_safe"
  mkdir -p "$plist_dir" "$log_dir"

  if [ -n "$brew_mysql_package" ]; then
    launchctl bootout "gui/$(id -u)/homebrew.mxcl.$brew_mysql_package" >/dev/null 2>&1 || true
    launchctl unload "$HOME/Library/LaunchAgents/homebrew.mxcl.$brew_mysql_package.plist" >/dev/null 2>&1 || true
  fi
  launchctl bootout "gui/$(id -u)/$MYSQL_LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
  launchctl unload "$plist_file" >/dev/null 2>&1 || true

  cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$MYSQL_LAUNCHAGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$mysqld_safe</string>
        <string>--datadir=$mysql_data</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/mysql-launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/mysql-launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$mysql_home</string>
</dict>
</plist>
EOF

  if pgrep -f "mysqld_safe|/mysqld([[:space:]]|$)" >/dev/null 2>&1; then
    info "检测到 MySQL 已在运行，仅刷新 LaunchAgent；下次登录将自动启动"
    info "macOS LaunchAgent 已安装: $plist_file"
    return 0
  fi

  launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load -w "$plist_file"
  launchctl enable "gui/$(id -u)/$MYSQL_LAUNCHAGENT_LABEL" 2>/dev/null || true
  launchctl kickstart -k "gui/$(id -u)/$MYSQL_LAUNCHAGENT_LABEL" 2>/dev/null || true
  info "macOS LaunchAgent 已安装: $plist_file"
}

uninstall_mysql_autostart_service() {
  if [ "$OS" = "Darwin" ]; then
    local plist_file="$HOME/Library/LaunchAgents/$MYSQL_LAUNCHAGENT_LABEL.plist"
    launchctl bootout "gui/$(id -u)/$MYSQL_LAUNCHAGENT_LABEL" >/dev/null 2>&1 || true
    launchctl unload "$plist_file" >/dev/null 2>&1 || true
    rm -f "$plist_file"
    info "macOS LaunchAgent 已卸载: $MYSQL_LAUNCHAGENT_LABEL"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now mysqld.service >/dev/null 2>&1 || true
    rm -f /usr/lib/systemd/system/mysqld.service /etc/systemd/system/mysqld.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "Linux systemd 服务已卸载: mysqld"
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

# ============================================
# 版本解析与 Homebrew 包查找
# ============================================

# 解析版本号，提取大版本号和完整版本号
# 输入: "5" -> version=5, version_full=5
# 输入: "5.7" -> version=5, version_full=5.7
# 输入: "8" -> version=8, version_full=8
# 输入: "8.0" -> version=8, version_full=8.0
# 输入: "8.4" -> version=8, version_full=8.4
# 输入: "9" -> version=9, version_full=9
# 输入: "9.6" -> version=9, version_full=9.6
parse_version_number() {
    local input_version="$1"
    
    # 提取大版本号（第一个数字）
    local major=$(echo "$input_version" | grep -oE '^[0-9]+' | head -1)
    
    if [ -z "$major" ]; then
        echo "错误: 无法解析版本号: $input_version" >&2
        return 1
    fi
    
    # 保留完整输入作为 version_full
    echo "$major"
    echo "$input_version"
    return 0
}

# 在 Homebrew 中查找最佳的 MySQL 包
# 优先级: 精确匹配 > 大版本下最新 > 最新版 mysql
# 输入: version=8, version_full=8.4
# 输出: 设置 brew_mysql_package 全局变量
find_brew_mysql_package() {
    local major="$1"
    local full_version="$2"
    local brew_bin
    brew_bin="$(brew_command 2>/dev/null || true)"
    [ -n "$brew_bin" ] || { error "未找到 Homebrew"; return 1; }
    
    # 1. 如果指定了完整版本号（如 8.4），尝试精确匹配
    if [ "$full_version" != "$major" ]; then
        local exact_package="mysql@${full_version}"
        if "$brew_bin" search "$exact_package" 2>/dev/null | grep -q "^${exact_package}"; then
            brew_mysql_package="$exact_package"
            info "找到精确匹配的包: $brew_mysql_package"
            return 0
        else
            warn "未找到精确匹配的包: $exact_package，将在大版本 $major 下查找最新版本"
        fi
    fi
    
    # 2. 在大版本下查找所有可用版本，选择最新的
    local available_packages=$("$brew_bin" search "mysql@${major}" 2>/dev/null | grep -oE "mysql@${major}\.[0-9]+" | sort -V -r)
    
    if [ -n "$available_packages" ]; then
        # 取最新的版本
        brew_mysql_package=$(echo "$available_packages" | head -1)
        info "在大版本 $major 下找到最新包: $brew_mysql_package"
        return 0
    fi
    
    # 3. 大版本下没有找到，使用最新版 mysql（通常是 MySQL 9）
    if "$brew_bin" search mysql 2>/dev/null | grep -q "^mysql "; then
        brew_mysql_package="mysql"
        if [ "$major" != "9" ]; then
            warn "未找到 MySQL $major 系列的包，将安装最新版 MySQL"
        fi
        info "使用最新版包: $brew_mysql_package"
        return 0
    fi
    
    # 4. 都找不到
    error "未找到任何可用的 MySQL 包"
    return 1
}

# ============================================
# 参数解析
# ============================================

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
        if [[ -z "${2:-}" ]] || [[ "${2}" == -* ]]; then
          # 没有版本号参数，检测已安装的版本
          if command -v mysql >/dev/null 2>&1; then
            VERSION=$(mysql --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [ -n "$VERSION" ]; then
              echo "$VERSION"
            else
              echo "已安装"
            fi
            exit 0
          elif pgrep -f "mysqld" > /dev/null 2>&1; then
            echo "运行中"
            exit 0
          else
            echo ""
            exit 1
          fi
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
      --enable-exporter)
        ENABLE_MYSQL_EXPORTER=true
        shift
        ;;
      --install-service)
        INSTALL_SERVICE_ONLY=true
        shift
        ;;
      --uninstall-service)
        UNINSTALL_SERVICE_ONLY=true
        shift
        ;;
      --upgrade)
        UPGRADE_MODE=true
        shift
        ;;
      --upgrade-backup-dir)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --upgrade-backup-dir 需要指定目录" >&2
          exit 1
        fi
        UPGRADE_BACKUP_DIR="$2"
        shift 2
        ;;
      --upgrade-backup-dir=*)
        UPGRADE_BACKUP_DIR="${1#*=}"
        shift
        ;;
      --exporter-user)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --exporter-user 需要指定用户名" >&2
          show_help
          exit 1
        fi
        MYSQL_EXPORTER_USER="$2"
        shift 2
        ;;
      --exporter-user=*)
        MYSQL_EXPORTER_USER="${1#*=}"
        shift
        ;;
      --exporter-password)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --exporter-password 需要指定密码" >&2
          show_help
          exit 1
        fi
        MYSQL_EXPORTER_PASSWORD="$2"
        shift 2
        ;;
      --exporter-password=*)
        MYSQL_EXPORTER_PASSWORD="${1#*=}"
        shift
        ;;
      --exporter-listen)
        if [[ -z "${2:-}" ]]; then
          echo "错误: --exporter-listen 需要指定监听地址" >&2
          show_help
          exit 1
        fi
        MYSQL_EXPORTER_LISTEN_ADDRESS="$2"
        shift 2
        ;;
      --exporter-listen=*)
        MYSQL_EXPORTER_LISTEN_ADDRESS="${1#*=}"
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

  # 验证版本号格式（支持 5, 5.7, 8, 8.0, 8.4, 9, 9.6 等）
  if [[ ! "$temp_version" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "错误: 版本号格式不正确: $temp_version" >&2
    echo "  支持的格式: 5, 5.7, 8, 8.0, 8.4, 9, 9.6" >&2
    exit 1
  fi
  
  # 解析版本号，提取大版本号和完整版本号
  local parsed=$(parse_version_number "$temp_version")
  if [ $? -ne 0 ]; then
    echo "错误: 版本号解析失败: $temp_version" >&2
    exit 1
  fi
  version=$(echo "$parsed" | head -1)
  version_full=$(echo "$parsed" | tail -1)
  
  # 如果是 macOS + Homebrew，提前查找对应的 brew 包
  BREW_CMD="$(brew_command 2>/dev/null || true)"
  if [ "$OS" = "Darwin" ] && [ -n "$BREW_CMD" ]; then
    find_brew_mysql_package "$version" "$version_full"
    if [ $? -ne 0 ]; then
      echo "错误: 未找到 MySQL $temp_version 对应的 Homebrew 包" >&2
      exit 1
    fi
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
  
  # 初始化其他变量（下载URL延迟到需要时再设置）
  gz_file=""
}

# 设置下载URL并初始化gz_file
init_download_url() {
  set_mysql_url
  gz_file="$DOWNLOAD_DIR/$(basename "$mysql_url")"
}

# 显示配置信息
show_config() {
  info "MySQL ${version_full} 配置:"
  info "  安装目录: $install_dir"
  info "  数据目录: $data_dir"
  info "  MySQL用户名: $mysql_user"
  if [ "$OS" = "Darwin" ] && [ -n "$(brew_command 2>/dev/null || true)" ] && [ -n "$brew_mysql_package" ]; then
    info "  Homebrew包: $brew_mysql_package"
  fi
  # 只在全新安装时显示密码提示（修复模式下跳过密码设置）
  if [ "${SKIP_PASSWORD:-false}" != "true" ]; then
    if [[ -n "$mysql_password" ]]; then
      info "  MySQL密码: [已设置]"
    else
      info "  MySQL密码: [将自动生成]"
    fi
  fi
  # 只在需要下载时才显示下载目录
  if [ "${SKIP_DOWNLOAD:-false}" != "true" ]; then
    info "  下载目录: $DOWNLOAD_DIR"
  fi
  if [ "$ENABLE_MYSQL_EXPORTER" = true ]; then
    info "  MySQL Exporter: 启用"
    info "  Exporter监听: $MYSQL_EXPORTER_LISTEN_ADDRESS"
    info "  Exporter账号: $MYSQL_EXPORTER_USER"
  fi
}

# 配置环境变量（将 MySQL bin 目录添加到 PATH）
setup_env_path() {
  local mysql_bin="$install_dir/bin"
  
  # 检查 PATH 中是否已包含该目录
  if [[ ":$PATH:" == *":$mysql_bin:"* ]]; then
    debug "PATH 已包含 $mysql_bin"
    return 0
  fi
  
  # 确定用户的 shell 配置文件
  local shell_rc=""
  local shell_name=$(basename "$SHELL")
  
  case "$shell_name" in
    zsh)
      shell_rc="$HOME/.zshrc"
      ;;
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        shell_rc="$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        shell_rc="$HOME/.bash_profile"
      fi
      ;;
    sh)
      shell_rc="$HOME/.profile"
      ;;
    *)
      shell_rc="$HOME/.profile"
      ;;
  esac
  
  if [ -z "$shell_rc" ]; then
    warn "无法确定 shell 配置文件，请手动添加到 PATH: export PATH=\"\$PATH:$mysql_bin\""
    return 1
  fi
  
  # 检查配置文件中是否已有该路径
  if [ -f "$shell_rc" ] && grep -q "export.*PATH.*$mysql_bin" "$shell_rc" 2>/dev/null; then
    debug "配置文件已包含 MySQL PATH 配置"
    return 0
  fi
  
  # 添加到配置文件
  local marker="# MySQL PATH (added by install script)"
  
  # 检查是否已有标记行（可能路径不同）
  if [ -f "$shell_rc" ] && grep -q "$marker" "$shell_rc" 2>/dev/null; then
    # 更新已有配置中的路径
    if [ -w "$shell_rc" ]; then
      sed -i $SED_INPLACE_OPT "s|export PATH=.*$marker|export PATH=\"\$PATH:$mysql_bin\" $marker|" "$shell_rc"
      info "更新环境变量配置: $shell_rc"
    else
      warn "无法更新 $shell_rc，请手动修改 PATH"
    fi
  else
    # 添加新的配置
    echo "" >> "$shell_rc"
    echo "$marker" >> "$shell_rc"
    echo "export PATH=\"\$PATH:$mysql_bin\"" >> "$shell_rc"
    info "添加环境变量到 $shell_rc"
  fi
  
  # 提示用户重新加载配置
  info "请执行以下命令使环境变量生效:"
  info "  source $shell_rc"
}

# 显示安装完成信息
show_install_complete() {
  info "MySQL安装完成"
  info "安装目录: $install_dir"
  info "数据目录: $data_dir"
  info "日志目录: $log_dir"
  # 如果有备份，显示备份位置
  if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ]; then
    info "数据备份: $backup_dir"
  fi
  
  # 配置环境变量
  setup_env_path
  
  info "使用命令连接: mysql -u root -p"
}

# 检测系统架构
detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

# 根据操作系统、架构和版本设置MySQL下载URL
set_mysql_url() {
  local mysql_arch="unknown"
  mysql_arch=$(detect_arch)
  
  if [ "$OS" = "Linux" ]; then
    if command -v rpm >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
      if [ "${version}" = "5" ]; then
        mysql_url="https://mirrors.aliyun.com/mysql/MySQL-5.7/mysql-5.7.36-el7-x86_64.tar.gz"
      elif [[ "${version_full}" == 8.4* ]]; then
        if [ "$mysql_arch" = "arm64" ] || [ "$mysql_arch" = "aarch64" ]; then
          mysql_url="https://cdn.mysql.com/archives/mysql-8.4/mysql-${MYSQL_84_RELEASE}-linux-glibc2.28-aarch64.tar.xz"
        else
          mysql_url="https://cdn.mysql.com/archives/mysql-8.4/mysql-${MYSQL_84_RELEASE}-linux-glibc2.28-x86_64.tar.xz"
        fi
      else
        # 根据架构选择
        if [ "$mysql_arch" = "arm64" ] || [ "$mysql_arch" = "aarch64" ]; then
          mysql_url="https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-linux-glibc2.28-aarch64.tar.xz"
        else
          mysql_url="https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz"
        fi
      fi
    elif command -v apt >/dev/null 2>&1; then
      if [[ "${version_full}" == 8.4* ]] && { [ "$mysql_arch" = "arm64" ] || [ "$mysql_arch" = "aarch64" ]; }; then
        mysql_url="https://cdn.mysql.com/archives/mysql-8.4/mysql-${MYSQL_84_RELEASE}-linux-glibc2.28-aarch64.tar.xz"
      elif [[ "${version_full}" == 8.4* ]]; then
        mysql_url="https://cdn.mysql.com/archives/mysql-8.4/mysql-${MYSQL_84_RELEASE}-linux-glibc2.28-x86_64.tar.xz"
      elif [ "$mysql_arch" = "arm64" ] || [ "$mysql_arch" = "aarch64" ]; then
        mysql_url="https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-linux-glibc2.28-aarch64.tar.xz"
      else
        mysql_url="https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz"
      fi
    else
      echo "错误: 不支持的Linux发行版" >&2
      exit 1
    fi
  elif [ "$OS" = "Darwin" ]; then
    if [ "${version}" = "5" ]; then
      echo "错误: macOS 不支持 MySQL 5.7 的官方预编译二进制包" >&2
      echo "请使用 Homebrew 安装: brew install mysql@5.7" >&2
      exit 1
    else
      # 根据架构选择 macOS 版本
      if [ "$mysql_arch" = "arm64" ]; then
        mysql_url="https://mirrors.huaweicloud.com/mysql/Downloads/MySQL-8.0/mysql-8.0.36-macos13-arm64.tar.gz"
      else
        mysql_url="https://mirrors.huaweicloud.com/mysql/Downloads/MySQL-8.0/mysql-8.0.36-macos13-x86_64.tar.gz"
      fi
    fi
  else
    echo "错误: 不支持的操作系统: $OS" >&2
    exit 1
  fi
  
  info "检测到架构: ${mysql_arch}，下载地址: $mysql_url"
}


# ============================================
# 公共函数：MySQL 配置管理（适用于所有安装方式）
# ============================================

# 等待 MySQL 服务就绪（通用）
wait_mysql_ready() {
    local max_wait=${1:-60}
    local wait_time=0
    local mysql_cmd="${2:-mysql}"
    
    info "等待 MySQL 服务就绪..."
    while [ $wait_time -lt $max_wait ]; do
        if $mysql_cmd -u root -e "SELECT 1" &>/dev/null; then
            info "MySQL 服务已就绪"
            return 0
        fi
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    warn "等待 MySQL 服务就绪超时"
    return 1
}

# 获取 MySQL 主版本号（通用）
get_mysql_major_version() {
    local mysql_cmd="${1:-mysql}"
    local version=$($mysql_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    echo "$version" | cut -d. -f1
}

# 设置 root 密码（通用）
set_mysql_root_password() {
    local mysql_cmd="${1:-mysql}"
    local current_pass="$2"
    local new_pass="$3"
    local major_version="$4"
    
    if [ -z "$new_pass" ]; then
        warn "新密码为空，跳过设置"
        return 1
    fi
    
    info "正在设置 root 密码..."
    
    local password_set=false
    local auth_cmd=""
    
    # 构建认证参数
    if [ -n "$current_pass" ]; then
        auth_cmd="-p$current_pass"
        # 临时密码需要添加 --connect-expired-password
        if [ "$major_version" = "8" ] || [ "$major_version" = "9" ]; then
            auth_cmd="$auth_cmd --connect-expired-password"
        fi
    fi
    
    # 执行密码修改
    if [ "$major_version" = "8" ] || [ "$major_version" = "9" ]; then
        if $mysql_cmd -u root $auth_cmd -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_pass';" 2>/dev/null; then
            password_set=true
        fi
    else
        if $mysql_cmd -u root $auth_cmd -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$new_pass');" 2>/dev/null; then
            password_set=true
        fi
    fi
    
    if [ "$password_set" = "true" ]; then
        info "root 密码已设置成功"
        return 0
    else
        warn "root 密码设置失败"
        return 1
    fi
}

# 配置远程访问权限（通用）
configure_mysql_remote() {
    local mysql_cmd="${1:-mysql}"
    local root_pass="$2"
    local major_version="${3:-8}"
    
    if [ -z "$root_pass" ]; then
        warn "root 密码为空，无法配置远程访问"
        return 1
    fi
    
    info "配置远程访问权限..."

    if command -v mysql_remote_configure_root >/dev/null 2>&1; then
        if mysql_remote_configure_root "$mysql_cmd" "$root_pass" "root" 2>/dev/null; then
            info "远程访问权限已配置"
            return 0
        fi
    fi

    # 公共脚本不可用时的兼容兜底
    if $mysql_cmd -u root -p"$root_pass" -e "
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$root_pass';
ALTER USER 'root'@'%' IDENTIFIED BY '$root_pass';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
" 2>/dev/null; then
        info "远程访问权限已配置"
        return 0
    else
        warn "远程访问权限配置失败"
        return 1
    fi
}

# 更新配置文件允许远程访问（通用）
# 根据版本生成 MySQL 配置文件
# 参数: $1=版本(5|8|9), $2=输出文件路径, $3=配置源目录(可选)
generate_mysql_cnf_by_version() {
    local mysql_version="$1"
    local output_file="$2"
    local conf_dir="${3:-$SOURCE_DIR/conf}"
    
    info "生成 MySQL $mysql_version 配置文件..."
    
    # 确保输出目录存在
    local output_dir=$(dirname "$output_file")
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir" || {
            warn "无法创建配置目录: $output_dir"
            return 1
        }
    fi
    
    # 基础配置文件
    local base_cnf="$conf_dir/my-base.cnf"
    # 版本特有配置文件
    local version_cnf="$conf_dir/my-$mysql_version.cnf"
    
    # 检查基础配置是否存在
    if [ ! -f "$base_cnf" ]; then
        warn "基础配置文件不存在: $base_cnf"
        # 回退到旧版 my.cnf
        local fallback_cnf="$conf_dir/my.cnf"
        if [ -f "$fallback_cnf" ]; then
            info "使用回退配置文件: $fallback_cnf"
            cp "$fallback_cnf" "$output_file"
            return 0
        else
            error "无法找到任何配置文件"
            return 1
        fi
    fi
    
    # 合并配置文件
    {
        echo "# ============================================"
        echo "# MySQL $mysql_version 配置文件"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ============================================"
        echo ""
        echo "# ----- 基础配置 -----"
        cat "$base_cnf"
        
        # 如果版本特有配置存在，追加到文件
        if [ -f "$version_cnf" ]; then
            echo ""
            echo "# ----- MySQL $mysql_version 特有配置 -----"
            cat "$version_cnf"
        else
            warn "版本特有配置不存在: $version_cnf，使用基础配置"
        fi
        
    } > "$output_file"
    
    if [ $? -eq 0 ]; then
        info "配置文件已生成: $output_file"
        return 0
    else
        error "配置文件生成失败"
        return 1
    fi
}

# 更新配置文件允许远程访问（通用）
update_mysql_cnf_for_remote() {
    local cnf_file="$1"
    local mysql_version="${2:-8}"
    local conf_dir="${3:-$SOURCE_DIR/conf}"
    
    # 如果配置文件不存在，根据版本生成
    if [ ! -f "$cnf_file" ]; then
        warn "配置文件不存在: $cnf_file"
        info "将根据 MySQL $mysql_version 版本生成配置文件..."
        
        if generate_mysql_cnf_by_version "$mysql_version" "$cnf_file" "$conf_dir"; then
            info "配置文件已生成"
        else
            warn "配置文件生成失败，将创建最小化配置"
            local cnf_dir=$(dirname "$cnf_file")
            mkdir -p "$cnf_dir" 2>/dev/null || true
            cat > "$cnf_file" << 'EOF'
[mysqld]
port = 3306
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
max_connections = 200

[client]
default-character-set = utf8mb4
EOF
            info "最小化配置文件已创建: $cnf_file"
        fi
    fi
    
    info "检查配置文件: $cnf_file"

    if command -v mysql_remote_configure_bind_address >/dev/null 2>&1; then
        mysql_remote_configure_bind_address "$cnf_file"
        info "已配置 bind-address = 0.0.0.0"
        return 0
    fi

    # 公共脚本不可用时的兼容兜底
    if ! grep -E '^[^#]*bind-address\s*=' "$cnf_file" 2>/dev/null | grep -q '0.0.0.0'; then
        info "添加 bind-address = 0.0.0.0"
        echo "" >> "$cnf_file"
        echo "# 允许远程连接" >> "$cnf_file"
        echo "bind-address = 0.0.0.0" >> "$cnf_file"
    fi
    return 0
}

# 生成随机密码
generate_random_password() {
    local length="${1:-12}"
    cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$length"
}

# ============================================
# Homebrew 安装相关函数
# ============================================

# 从 Homebrew 日志中提取临时密码
get_brew_temp_password() {
    local log_file="$(brew --prefix)/var/mysql/$(hostname).err"
    if [ -f "$log_file" ]; then
        # 尝试多种可能的日志格式
        local temp_pass=$(grep -i "temporary password" "$log_file" 2>/dev/null | tail -1 | awk '{print $NF}')
        if [ -z "$temp_pass" ]; then
            # 尝试另一种格式
            temp_pass=$(grep -i "generated.*password" "$log_file" 2>/dev/null | tail -1 | awk -F': ' '{print $2}' | tr -d ' ')
        fi
        echo "$temp_pass"
    fi
}

# 仅当 Homebrew MySQL 日志尾部确实包含 ERROR 时输出诊断日志
show_brew_error_log_if_needed() {
    local log_file="$1"
    local lines="${2:-10}"

    [ -f "$log_file" ] || return 1

    local recent_log
    recent_log=$(tail -"$lines" "$log_file" 2>/dev/null || true)
    if printf '%s\n' "$recent_log" | grep -Eiq '(\[ERROR\]|\bERROR\b)'; then
        warn "错误日志最后 ${lines} 行:"
        printf '%s\n' "$recent_log" >&2
        return 0
    fi

    debug "错误日志最后 ${lines} 行未发现 ERROR，跳过日志输出: $log_file"
    return 1
}

# 检测当前 MySQL 认证状态（无密码/有密码/未知）
check_brew_mysql_auth() {
    local mysql_cmd="${1:-mysql}"
    
    # 尝试无密码登录
    if $mysql_cmd -u root -e "SELECT 1" &>/dev/null; then
        echo "no_password"
        return 0
    fi
    
    # 尝试使用常见默认密码
    if $mysql_cmd -u root -p"root" -e "SELECT 1" &>/dev/null; then
        echo "default_root"
        return 0
    fi
    
    # 检查是否有临时密码（从日志）
    local temp_pass=$(get_brew_temp_password)
    if [ -n "$temp_pass" ]; then
        if $mysql_cmd -u root -p"$temp_pass" --connect-expired-password -e "SELECT 1" &>/dev/null; then
            echo "temp_password:$temp_pass"
            return 0
        fi
    fi
    
    echo "unknown"
    return 1
}

# 使用 Homebrew 安装 MySQL
install_with_brew() {
    local is_fresh_install=false
    local current_pass=""
    local root_password=""
    local mysql_cmd="mysql"
    
    # 使用全局变量 brew_mysql_package（在 parse_arguments 中已确定）
    info "选择的 MySQL 包: $brew_mysql_package (版本: $version_full)"
    
    # 检查是否已安装
    if brew list "$brew_mysql_package" &>/dev/null 2>/dev/null; then
        info "MySQL $brew_mysql_package 已通过 Homebrew 安装"
        # 确保服务启动
        brew services start "$brew_mysql_package" 2>/dev/null || true
    else
        info "使用 Homebrew 安装 MySQL ($brew_mysql_package)..."
        is_fresh_install=true
        
        # 安装前备份已有配置文件（避免旧配置导致初始化失败）
        local brew_cnf="$(brew --prefix)/etc/my.cnf"
        if [ -f "$brew_cnf" ]; then
            info "备份已有配置文件: ${brew_cnf}.bak"
            mv "$brew_cnf" "${brew_cnf}.bak" 2>/dev/null || true
        fi
        
        # 安装 MySQL
        brew install "$brew_mysql_package"
        
        # 检查 brew 安装后的初始化是否成功
        local brew_data_dir="$(brew --prefix)/var/mysql"
        local brew_log_file="$(brew --prefix)/var/mysql/$(hostname).err"
        
        if [ -f "$brew_log_file" ] && grep -q "ERROR" "$brew_log_file" 2>/dev/null; then
            warn "brew 初始化过程中出现错误:"
            grep "ERROR" "$brew_log_file" | tail -5
            warn "可能是配置文件不兼容导致，清理数据目录后重试..."
            
            # 停止服务
            brew services stop "$brew_mysql_package" 2>/dev/null || true
            sleep 2
            
            # 清理失败的数据目录
            if [ -d "$brew_data_dir" ]; then
                info "清理数据目录: $brew_data_dir"
                rm -rf "$brew_data_dir"
            fi
            
            # 重新初始化
            info "重新执行 brew postinstall..."
            brew postinstall "$brew_mysql_package" 2>&1 || true
            
            # 检查是否仍然失败
            if [ -f "$brew_log_file" ] && grep -q "ERROR" "$brew_log_file" 2>/dev/null; then
                error "MySQL 初始化失败，请检查日志: $brew_log_file"
            fi
        fi
        
        # 启动服务
        brew services start "$brew_mysql_package"
    fi
    
    # 等待服务就绪（brew 初始化失败后可能需要更长时间）
    if ! wait_mysql_ready 90 "$mysql_cmd"; then
        warn "MySQL 服务未能就绪"
        
        # 尝试诊断
        local brew_log_file="$(brew --prefix)/var/mysql/$(hostname).err"
        if show_brew_error_log_if_needed "$brew_log_file" 10; then
            warn "检测到 MySQL 启动错误，Homebrew 安装流程失败"
            return 1
        fi
        
        warn "尝试继续配置..."
    fi
    
    # 获取 MySQL 版本
    local major_version=$(get_mysql_major_version "$mysql_cmd")
    info "MySQL 主版本: $major_version"
    
    # 确定 root 密码
    if [ -n "$mysql_password" ]; then
        # 使用用户指定的密码
        root_password="$mysql_password"
        info "使用用户指定密码: $root_password"
    else
        # 生成随机密码
        root_password=$(generate_random_password 12)
        info "生成随机密码"
    fi
    
    # 检测当前认证状态
    local auth_status=$(check_brew_mysql_auth "$mysql_cmd")
    info "当前认证状态: $auth_status"
    
    case "$auth_status" in
        "no_password")
            # 无密码状态，直接设置新密码
            info "当前为无密码状态，将设置新密码"
            current_pass=""
            ;;
        "default_root")
            # 使用默认密码 root
            info "检测到默认密码 'root'，将修改为新密码"
            current_pass="root"
            ;;
        temp_password:*)
            # 有临时密码
            current_pass="${auth_status#temp_password:}"
            info "检测到临时密码，将修改为新密码"
            ;;
        "unknown")
            # 未知状态，可能是已有自定义密码
            warn "无法确定当前 MySQL 认证状态"
            warn "可能原因："
            warn "  1. MySQL 已设置了自定义密码"
            warn "  2. MySQL 服务未完全启动"
            warn "  3. 其他认证问题"
            info ""
            info "当前配置:"
            info "  数据目录: $(brew --prefix)/var/mysql"
            info "  配置文件: $(brew --prefix)/etc/my.cnf"
            info "  日志文件: $(brew --prefix)/var/mysql/$(hostname).err"
            info ""
            info "如需修改密码，请手动执行: mysqladmin -u root -p password 新密码"
            configure_mysql_exporter_if_requested "$mysql_cmd" "$mysql_password"
            return 0
            ;;
    esac
    
    # 设置 root 密码
    if set_mysql_root_password "$mysql_cmd" "$current_pass" "$root_password" "$major_version"; then
        info "root 密码: $root_password"
    else
        warn "密码设置可能失败，请检查日志"
    fi
    
    # 配置远程访问
    configure_mysql_remote "$mysql_cmd" "$root_password" "$major_version"
    
    # 更新配置文件
    local my_cnf="$(brew --prefix)/etc/my.cnf"
    local config_updated=false
    if update_mysql_cnf_for_remote "$my_cnf" "$major_version" "$SOURCE_DIR/conf"; then
        config_updated=true
        brew services restart "$brew_mysql_package"
        info "MySQL 服务已重启以应用新配置"
        
        # 等待服务重新就绪
        info "等待服务重启后重新就绪..."
        if wait_mysql_ready 60 "$mysql_cmd"; then
            info "服务已就绪"
        else
            warn "服务可能未完全就绪，继续验证..."
        fi
        
        # 服务重启后，验证密码是否仍然有效
        info "验证密码是否仍然有效..."
        if ! $mysql_cmd -u root -p"$root_password" -e "SELECT 1" &>/dev/null; then
            warn "服务重启后密码验证失败，尝试重新设置..."
            
            # 重新检测认证状态
            local auth_status_after_restart=$(check_brew_mysql_auth "$mysql_cmd")
            info "重启后认证状态: $auth_status_after_restart"
            
            case "$auth_status_after_restart" in
                "no_password")
                    # 无密码状态，重新设置密码
                    info "检测到无密码状态，重新设置密码..."
                    if set_mysql_root_password "$mysql_cmd" "" "$root_password" "$major_version"; then
                        info "密码重新设置成功"
                    else
                        warn "密码重新设置失败"
                    fi
                    ;;
                "default_root")
                    # 使用默认密码 root 重新设置
                    info "检测到默认密码，使用 root 重新设置..."
                    if set_mysql_root_password "$mysql_cmd" "root" "$root_password" "$major_version"; then
                        info "密码重新设置成功"
                    else
                        warn "密码重新设置失败"
                    fi
                    ;;
                *)
                    warn "无法自动重新设置密码，可能需要手动处理"
                    ;;
            esac
            
            # 重新配置远程访问
            configure_mysql_remote "$mysql_cmd" "$root_password" "$major_version"
        else
            info "密码验证成功，无需重新设置"
        fi
    fi
    
    # 输出完成信息
    info "MySQL 安装完成！"
    
    # 执行安装验证
    verify_mysql_installation "$mysql_cmd" "$root_password" "$major_version" "$brew_mysql_package"

    configure_mysql_exporter_if_requested "$mysql_cmd" "$root_password"
    
    return 0
}

# ============================================
# 安装验证和结果输出
# ============================================

# 验证 MySQL 安装结果
verify_mysql_installation() {
    local mysql_cmd="${1:-mysql}"
    local root_pass="$2"
    local major_version="${3:-8}"
    local brew_package="${4:-mysql}"
    local is_brew=false
    
    # 检测是否是 brew 安装
    if command -v brew &>/dev/null && brew list "$brew_package" &>/dev/null 2>/dev/null; then
        is_brew=true
    fi
    
    info ""
    info "========================================"
    info "       MySQL 安装验证报告"
    info "========================================"
    info ""
    
    # 1. 版本验证
    info "【1. 版本信息】"
    local version_info=$($mysql_cmd --version 2>/dev/null)
    info "  $version_info"
    
    # 2. 服务状态验证
    info ""
    info "【2. 服务状态】"
    if pgrep -f "mysqld" > /dev/null 2>&1; then
        local mysql_pid=$(pgrep -f "mysqld" | head -1)
        info "  状态: ✓ 运行中 (PID: $mysql_pid)"
    else
        warn "  状态: ✗ 未运行"
    fi
    
    # 3. 连接验证
    info ""
    info "【3. 连接测试】"
    if [ -n "$root_pass" ]; then
        if $mysql_cmd -u root -p"$root_pass" -e "SELECT 1" &>/dev/null; then
            info "  root 登录: ✓ 成功"
        else
            warn "  root 登录: ✗ 失败"
        fi
    else
        if $mysql_cmd -u root -e "SELECT 1" &>/dev/null; then
            info "  root 登录: ✓ 成功 (无密码)"
        else
            warn "  root 登录: ✗ 失败"
        fi
    fi
    
    # 4. 远程访问验证
    info ""
    info "【4. 远程访问配置】"
    if [ -n "$root_pass" ]; then
        local remote_user=$($mysql_cmd -u root -p"$root_pass" -e "SELECT user FROM mysql.user WHERE user='root' AND host='%';" 2>/dev/null | tail -1)
        if [ -n "$remote_user" ]; then
            info "  root@%' 用户: ✓ 已创建"
        else
            warn "  root@%' 用户: ✗ 未创建"
        fi
        
        local bind_addr=$($mysql_cmd -u root -p"$root_pass" -e "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null | tail -1)
        if [[ "$bind_addr" == *"0.0.0.0"* ]] || [[ "$bind_addr" == *"*"* ]]; then
            info "  bind-address: ✓ $bind_addr"
        else
            warn "  bind-address: $bind_addr (可能限制远程访问)"
        fi
    fi
    
    # 5. 配置信息
    info ""
    info "【5. 配置信息】"
    if [ "$is_brew" = true ]; then
        info "  安装方式: Homebrew"
        info "  数据目录: $(brew --prefix)/var/mysql"
        info "  配置文件: $(brew --prefix)/etc/my.cnf"
        info "  日志文件: $(brew --prefix)/var/mysql/$(hostname).err"
    else
        info "  安装方式: 手动安装"
        info "  安装目录: $install_dir"
        info "  数据目录: $data_dir"
        info "  配置文件: $install_dir/conf/my.cnf"
        info "  日志目录: $log_dir"
    fi
    
    # 6. 关键参数
    info ""
    info "【6. 关键参数】"
    if [ -n "$root_pass" ]; then
        local charset=$($mysql_cmd -u root -p"$root_pass" -e "SHOW VARIABLES LIKE 'character_set_server';" 2>/dev/null | tail -1)
        local max_conn=$($mysql_cmd -u root -p"$root_pass" -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | tail -1)
        local auth_plugin=$($mysql_cmd -u root -p"$root_pass" -e "SHOW VARIABLES LIKE 'default_authentication_plugin';" 2>/dev/null | tail -1)
        
        info "  字符集: $charset"
        info "  最大连接数: $max_conn"
        [ -n "$auth_plugin" ] && info "  认证插件: $auth_plugin"
    fi
    
    # 7. 连接信息汇总
    info ""
    info "========================================"
    info "【连接信息】"
    info "========================================"
    if [ -n "$root_pass" ]; then
        info "  root 密码: $root_pass"
    else
        info "  root 密码: (无密码)"
    fi
    info ""
    info "  本地连接:"
    info "    mysql -u root -p"
    info ""
    info "  远程连接:"
    local hostname=$(hostname)
    local ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' || echo "<IP地址>")
    info "    mysql -h $ip -u root -p"
    info "    mysql -h $hostname -u root -p"
    info ""
    info "========================================"
    info ""
    
    # 8. 常用命令提示
    info "【常用命令】"
    if [ "$is_brew" = true ]; then
        info "  启动服务: brew services start $brew_package"
        info "  停止服务: brew services stop $brew_package"
        info "  重启服务: brew services restart $brew_package"
    else
        info "  启动服务: $install_dir/bin/startup.sh"
        info "  停止服务: $install_dir/bin/stop.sh"
    fi
    info ""
}

configure_mysql_exporter_if_requested() {
    local mysql_cmd="${1:-mysql}"
    local root_pass="${2:-}"

    if [ "$ENABLE_MYSQL_EXPORTER" != true ]; then
        return 0
    fi

    if [ ! -f "$MYSQL_EXPORTER_SCRIPT" ]; then
        warn "MySQL Exporter 脚本不存在，跳过指标采集配置: $MYSQL_EXPORTER_SCRIPT"
        return 0
    fi

    local exporter_args=(
        "--mysql-host" "127.0.0.1"
        "--mysql-port" "3306"
        "--admin-user" "root"
        "--exporter-user" "$MYSQL_EXPORTER_USER"
        "--listen-address" "$MYSQL_EXPORTER_LISTEN_ADDRESS"
    )

    if [ -n "$MYSQL_EXPORTER_PASSWORD" ]; then
        exporter_args+=("--exporter-password" "$MYSQL_EXPORTER_PASSWORD")
    fi

    if [ -n "$root_pass" ]; then
        exporter_args+=("--setup-user" "--admin-password" "$root_pass")
        info "开始安装并启动 MySQL Exporter..."
        if bash "$MYSQL_EXPORTER_SCRIPT" "${exporter_args[@]}"; then
            info "MySQL Exporter 配置完成"
        else
            warn "MySQL Exporter 配置失败，请检查输出后手动运行: $MYSQL_EXPORTER_SCRIPT --help"
        fi
    else
        warn "未获得 root 密码，无法自动创建 exporter 最小权限账号"
        warn "请稍后手动运行: $MYSQL_EXPORTER_SCRIPT --setup-user --admin-password 'root密码'"
        bash "$MYSQL_EXPORTER_SCRIPT" "${exporter_args[@]}" --install-only || true
    fi
}

mysql_version_number() {
  "$1" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

mysql_upgrade_stop_processes() {
  local install_real
  install_real="$(cd "$install_dir" 2>/dev/null && pwd -P || printf '%s' "$install_dir")"

  if [ -x "$install_dir/bin/stop.sh" ]; then
    bash "$install_dir/bin/stop.sh" --install-dir "$install_dir" force >/dev/null 2>&1 || true
  fi
  pkill -TERM -f "$install_real/bin/mysqld" 2>/dev/null || true
  sleep 3
  pkill -KILL -f "$install_real/bin/mysqld" 2>/dev/null || true
}

rollback_mysql_upgrade() {
  local backup_dir="$1"
  warn "MySQL 升级失败，开始从备份恢复"
  mysql_upgrade_stop_processes
  rsync -a --delete "$backup_dir/" "$install_dir/"
  bash "$install_dir/bin/startup.sh" "$install_dir" >/dev/null 2>&1 || true
  warn "已恢复升级前文件: $backup_dir"
}

upgrade_mysql_in_place() {
  [ "$OS" = "Linux" ] || error "当前 --upgrade 仅支持 Linux 主机二进制安装"
  [ -x "$install_dir/bin/mysqld" ] || error "未找到现有 MySQL: $install_dir/bin/mysqld"
  [ -d "$data_dir/mysql" ] || error "数据目录未初始化: $data_dir"
  [ -f "$install_dir/conf/my.cnf" ] || error "配置文件不存在: $install_dir/conf/my.cnf"
  [ -n "$MYSQL_UPGRADE_PASSWORD" ] || error "请通过 MYSQL_UPGRADE_PASSWORD 提供现有 root 密码"
  command -v rsync >/dev/null 2>&1 || error "MySQL 升级需要 rsync"

  local current_version target_series backup_root backup_dir socket_path
  local temp_dir extract_dir target_version config_test runtime_dir
  current_version="$(mysql_version_number "$install_dir/bin/mysqld")"
  target_series="$version_full"
  socket_path="$install_dir/mysql.sock"

  [ -n "$current_version" ] || error "无法识别当前 MySQL 版本"
  [[ "$current_version" == 8.0.* ]] || error "仅支持从 MySQL 8.0.x 原地升级，当前版本: $current_version"
  [[ "$target_series" == 8.4* ]] || error "当前升级目标必须是 8.4，实际为: $target_series"

  info "MySQL 原地升级: $current_version -> ${MYSQL_84_RELEASE}"
  info "验证现有 root 账号和数据目录"
  if ! MYSQL_PWD="$MYSQL_UPGRADE_PASSWORD" "$install_dir/bin/mysql" --socket="$socket_path" -uroot \
      -N -e "SELECT VERSION();" >/dev/null 2>&1; then
    error "MySQL root 认证失败，停止升级"
  fi

  init_download_url
  safe_mkdir "$DOWNLOAD_DIR"
  if [ ! -f "$gz_file" ] || ! check_file_integrity "$gz_file"; then
    info "下载 MySQL ${MYSQL_84_RELEASE}: $mysql_url"
    safe_download "$mysql_url" "$gz_file" || error "MySQL 8.4 安装包下载失败"
    check_file_integrity "$gz_file" || error "MySQL 8.4 安装包校验失败"
  else
    info "复用已校验安装包: $gz_file"
  fi

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mysql-upgrade.XXXXXX")"
  tar -xf "$gz_file" -C "$temp_dir" || error "MySQL 8.4 安装包解压失败"
  extract_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -x "$extract_dir/bin/mysqld" ] || error "安装包中未找到 mysqld"
  target_version="$(mysql_version_number "$extract_dir/bin/mysqld")"
  [[ "$target_version" == 8.4.* ]] || error "安装包版本不符合预期: ${target_version:-未知}"

  config_test="$temp_dir/my.cnf"
  cp "$install_dir/conf/my.cnf" "$config_test"
  sed -i -E '/^[[:space:]]*(default_authentication_plugin|expire_logs_days|innodb_buffer_pool_instances)[[:space:]]*=/d' "$config_test"
  if ! "$extract_dir/bin/mysqld" --defaults-file="$config_test" --validate-config >/dev/null 2>"$temp_dir/validate.log"; then
    cat "$temp_dir/validate.log" >&2
    error "MySQL 8.4 配置兼容性检查失败，未修改现有安装"
  fi

  info "执行 InnoDB 慢关闭，确保物理备份一致"
  MYSQL_PWD="$MYSQL_UPGRADE_PASSWORD" "$install_dir/bin/mysql" --socket="$socket_path" -uroot \
    -e "SET GLOBAL innodb_fast_shutdown=0;" >/dev/null
  MYSQL_PWD="$MYSQL_UPGRADE_PASSWORD" "$install_dir/bin/mysqladmin" --socket="$socket_path" -uroot shutdown

  backup_root="${UPGRADE_BACKUP_DIR:-$(dirname "$install_dir")/mysql-upgrade-backups}"
  backup_dir="$backup_root/mysql-${current_version}-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"
  info "完整备份 MySQL 安装与数据: $backup_dir"
  rsync -a --delete --exclude='mysql.sock' --exclude='*.pid' "$install_dir/" "$backup_dir/"

  cp "$config_test" "$install_dir/conf/my.cnf"
  for runtime_dir in bin docs include lib man share support-files; do
    rm -rf "$install_dir/$runtime_dir"
    [ ! -e "$extract_dir/$runtime_dir" ] || cp -a "$extract_dir/$runtime_dir" "$install_dir/"
  done
  cp -a "$SOURCE_DIR/bin/." "$install_dir/bin/"
  chmod +x "$install_dir/bin/"*.sh 2>/dev/null || true

  if ! "$install_dir/bin/mysqld" --defaults-file="$install_dir/conf/my.cnf" --validate-config >/dev/null 2>"$temp_dir/validate-installed.log"; then
    cat "$temp_dir/validate-installed.log" >&2
    rollback_mysql_upgrade "$backup_dir"
    return 1
  fi

  info "启动 MySQL 8.4 并执行自动数据字典升级"
  if ! bash "$install_dir/bin/startup.sh" "$install_dir"; then
    warn "常规启动脚本等待超时；首次跨 LTS 升级可能需要更久，将继续等待 ${MYSQL_UPGRADE_WAIT_SECONDS} 秒"
  fi

  local attempt=0
  local max_attempts=$((MYSQL_UPGRADE_WAIT_SECONDS / 2))
  [ "$max_attempts" -gt 0 ] || max_attempts=1
  while [ "$attempt" -lt "$max_attempts" ]; do
    if MYSQL_PWD="$MYSQL_UPGRADE_PASSWORD" "$install_dir/bin/mysql" --socket="$socket_path" -uroot \
        -N -e "SELECT VERSION();" >/dev/null 2>&1; then
      break
    fi
    if [ "$attempt" -ge 5 ] && ! pgrep -f "$install_dir/bin/mysqld" >/dev/null 2>&1; then
      warn "MySQL 8.4 进程已退出，停止等待"
      attempt="$max_attempts"
      break
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  if [ "$attempt" -ge "$max_attempts" ]; then
    rollback_mysql_upgrade "$backup_dir"
    return 1
  fi

  target_version="$(MYSQL_PWD="$MYSQL_UPGRADE_PASSWORD" "$install_dir/bin/mysql" --socket="$socket_path" -uroot -N -e "SELECT VERSION();")"
  [[ "$target_version" == 8.4.* ]] || { rollback_mysql_upgrade "$backup_dir"; return 1; }
  rm -rf "$temp_dir"
  info "MySQL 升级完成: $target_version"
  info "可恢复备份: $backup_dir"
}

# 主函数
main() {
  # 阶段1: 参数解析和初始化
  parse_arguments "$@"

  if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    uninstall_mysql_autostart_service
    return 0
  fi

  if [ "$INSTALL_SERVICE_ONLY" = true ]; then
    if [ "$OS" = "Darwin" ]; then
      install_macos_mysql_launchagent
    else
      setup_service
    fi
    return $?
  fi

  if [ "$UPGRADE_MODE" = true ]; then
    upgrade_mysql_in_place
    return $?
  fi
  
  # 检查是否已有其他MySQL安装
  check_existing_installs
  
  # macOS 优先使用 Homebrew，失败则回退到手动安装
  if [ "$OS" == "Darwin" ] && command -v brew &>/dev/null; then
      info "检测到 Homebrew，优先使用 brew 安装 MySQL"
      if install_with_brew; then
          exit 0
      fi
      warn "Homebrew 安装失败，回退到手动下载安装..."
  fi
  
  # 显示配置信息（brew 安装模式不显示，因为路径固定）
  show_config
  
  info "开始安装MySQL"
  
  # 初始化下载URL（延迟到需要时）
  init_download_url
  
  pre_check
  
  if [ "${SKIP_DOWNLOAD:-false}" != "true" ]; then
    download_and_extract
  else
    debug "跳过下载步骤"
  fi
  
  # 如果已经在pre_check中启动了MySQL，直接进入配置阶段
  if [ "$MYSQL_STARTED_IN_PRECHECK" = "true" ]; then
    info "MySQL已在预检查阶段启动，跳过重复安装和启动步骤"
    
    # 修复模式下需要更新配置文件中的路径
    if [ "${REPAIR_MODE:-false}" = "true" ]; then
      local cnf="$install_dir/conf/my.cnf"
      if [ -f "$cnf" ]; then
        info "更新配置文件路径..."
        update_config "$cnf"
      fi
    fi
    
    # 阶段7: 等待服务就绪
    wait_for_mysql_ready
    
    # 创建 socket 符号链接（如果 socket 不在 /tmp）
    create_socket_symlink
    
    # 阶段8: 配置MySQL（根据状态决定是否设置密码）
    if [ "${SKIP_PASSWORD:-false}" != "true" ]; then
      info "配置MySQL"
      set_root_password_and_remote
    fi
    
    show_install_complete
    configure_mysql_exporter_if_requested "$install_dir/bin/mysql" "${password:-$mysql_password}"
    return 0
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
    sudo bash "$install_dir/bin/startup.sh" "$install_dir"
  else
    "$install_dir/bin/startup.sh" "$install_dir"
  fi
  
  if [ $? -eq 0 ]; then
    info "MySQL服务启动成功"
  else
    error "MySQL服务启动失败"
  fi
  
  # 阶段7: 等待服务就绪
  wait_for_mysql_ready
  
  # 创建 socket 符号链接
  create_socket_symlink
  
  # 阶段8: 配置MySQL（根据状态决定是否设置密码）
  if [ "${SKIP_PASSWORD:-false}" = "true" ]; then
    info "数据目录已初始化，跳过密码配置（保留原有密码）"
  else
    info "配置MySQL"
    set_root_password_and_remote
  fi
  
  show_install_complete
  configure_mysql_exporter_if_requested "$install_dir/bin/mysql" "${password:-$mysql_password}"
}

# 创建 socket 符号链接（将实际 socket 链接到 /tmp/mysql.sock）
create_socket_symlink() {
  local actual_socket=""
  
  # 尝试多个可能的 socket 路径
  local socket_paths=(
    "$install_dir/mysql.sock"
    "/tmp/mysql.sock"
  )
  
  for socket in "${socket_paths[@]}"; do
    if [ -S "$socket" ]; then
      actual_socket="$socket"
      break
    fi
  done
  
  # 如果找到了实际 socket 且不是 /tmp/mysql.sock，创建符号链接
  local default_socket="/tmp/mysql.sock"
  if [ -n "$actual_socket" ] && [ "$actual_socket" != "$default_socket" ]; then
    # 检查符号链接是否已存在且指向正确的目标
    if [ -L "$default_socket" ]; then
      local current_target=$(readlink "$default_socket" 2>/dev/null)
      if [ "$current_target" = "$actual_socket" ]; then
        # 符号链接已存在且正确，跳过
        return 0
      fi
      # 符号链接指向不同目标，需要更新
    fi
    
    # 删除旧的符号链接或文件
    if [ -L "$default_socket" ] || [ -S "$default_socket" ] || [ -e "$default_socket" ]; then
      rm -f "$default_socket" 2>/dev/null || sudo rm -f "$default_socket" 2>/dev/null
    fi
    # 创建符号链接
    if ln -s "$actual_socket" "$default_socket" 2>/dev/null; then
      info "创建socket符号链接: $default_socket -> $actual_socket"
    elif sudo ln -s "$actual_socket" "$default_socket" 2>/dev/null; then
      info "创建socket符号链接: $default_socket -> $actual_socket"
    else
      warn "无法创建socket符号链接 $default_socket"
    fi
  fi
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
    if [[ ! " ${unique_sockets[*]:-} " =~ " ${socket} " ]]; then
      unique_sockets+=("$socket")
    fi
  done
  socket_paths=("${unique_sockets[@]+"${unique_sockets[@]}"}")
  
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
            info "MySQL服务已就绪"
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

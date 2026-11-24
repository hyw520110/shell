#!/bin/bash
# MySQL root 密码检测/重置脚本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SCRIPT="$SCRIPT_DIR/remote.sh"

if [ -f "$REMOTE_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$REMOTE_SCRIPT"
else
  echo "缺少远程访问公共脚本: $REMOTE_SCRIPT" >&2
  exit 1
fi

NEW_PASSWORD=""
CURRENT_PASSWORD=""
FORCE_RESET=false
SHOW_STATUS=false

usage() {
  cat << EOF
用法: $0 [选项]

选项:
  --status                     检测 root 当前认证状态
  --reset                      重置 root 密码
  --new-password PASSWORD      指定新密码
  --current-password PASSWORD  已知当前密码时指定
  --force                      当前密码未知时，使用 init-file 强制重置
  -h, --help                   显示帮助

示例:
  $0 --status
  $0 --reset --new-password root
  $0 --reset --current-password oldpass --new-password newpass
  $0 --reset --new-password root --force
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status)
      SHOW_STATUS=true
      shift
      ;;
    --reset)
      SHOW_STATUS=false
      shift
      ;;
    --new-password)
      NEW_PASSWORD="${2:-}"
      shift 2
      ;;
    --new-password=*)
      NEW_PASSWORD="${1#*=}"
      shift
      ;;
    --current-password)
      CURRENT_PASSWORD="${2:-}"
      shift 2
      ;;
    --current-password=*)
      CURRENT_PASSWORD="${1#*=}"
      shift
      ;;
    --force)
      FORCE_RESET=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

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

MYSQL_DIR="$(bash "$SCRIPT_DIR/find_mysql.sh" | head -n 1 || true)"
if [ -z "$MYSQL_DIR" ]; then
  echo "未找到 MySQL 安装目录" >&2
  exit 1
fi

MYSQL_CMD="$MYSQL_DIR/bin/mysql"
MYSQLADMIN_CMD="$MYSQL_DIR/bin/mysqladmin"
MYSQLD_SAFE_CMD="$MYSQL_DIR/bin/mysqld_safe"
[ -x "$MYSQL_CMD" ] || MYSQL_CMD="$(command -v mysql || true)"
[ -x "$MYSQLADMIN_CMD" ] || MYSQLADMIN_CMD="$(command -v mysqladmin || true)"

if [ -z "$MYSQL_CMD" ] || [ -z "$MYSQLADMIN_CMD" ]; then
  echo "未找到 mysql/mysqladmin 命令" >&2
  exit 1
fi

BREW_PKG=""
if [ "$(uname)" = "Darwin" ]; then
  BREW_PKG="$(find_brew_mysql_package_for_dir "$MYSQL_DIR" 2>/dev/null || true)"
fi

CNF_FILE=""
if [ -n "$BREW_PKG" ] && command -v brew >/dev/null 2>&1; then
  CNF_FILE="$(brew --prefix)/etc/my.cnf"
elif [ -f "$MYSQL_DIR/conf/my.cnf" ]; then
  CNF_FILE="$MYSQL_DIR/conf/my.cnf"
fi

# 从 my.cnf 读取 socket 路径（mysql 客户端默认连接 /tmp/mysql.sock，可能与实际不符）
MYSQL_SOCKET=""
if [ -n "$CNF_FILE" ] && [ -f "$CNF_FILE" ]; then
  MYSQL_SOCKET="$(awk -F'=' '/^[[:space:]]*socket[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$CNF_FILE" | head -1)"
fi
[ -n "$MYSQL_SOCKET" ] || MYSQL_SOCKET="/tmp/mysql.sock"

get_brew_temp_password() {
  local log_file
  command -v brew >/dev/null 2>&1 || return 0
  log_file="$(brew --prefix)/var/mysql/$(hostname).err"
  [ -f "$log_file" ] || return 0
  grep -i "temporary password" "$log_file" 2>/dev/null | tail -1 | awk '{print $NF}'
}

generate_random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
  fi
}

# 使用新密码进行连接测试并输出结果
test_mysql_connection() {
  local password="$1"
  local label="${2:-MySQL}"
  echo "测试 ${label} 连接..."
  if "$MYSQL_CMD" --socket="$MYSQL_SOCKET" -u root -p"$password" -e "SELECT VERSION() AS version, NOW() AS server_time;" 2>/dev/null; then
    echo "[成功] ${label} 连接测试通过"
    return 0
  else
    echo "[失败] ${label} 连接测试失败" >&2
    return 1
  fi
}

require_os_auth() {
  echo "强制重置 MySQL root 密码需要操作系统用户认证。"
  # 先尝试非交互式（NOPASSWD sudo 场景，如 SSH 无终端时）
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # 交互式（需要输入密码）
  if sudo -v; then
    return 0
  fi
  echo "操作系统用户认证失败，已取消重置。" >&2
  return 1
}

mysql_exec_no_password() {
  "$MYSQL_CMD" --socket="$MYSQL_SOCKET" -u root -e "SELECT 1" >/dev/null 2>&1
}

mysql_exec_with_password() {
  local password="$1"
  "$MYSQL_CMD" --socket="$MYSQL_SOCKET" -u root -p"$password" -e "SELECT 1" >/dev/null 2>&1
}

detect_auth_status() {
  local temp_pass

  if mysql_exec_no_password; then
    echo "no_password"
    return 0
  fi

  if mysql_exec_with_password "root"; then
    echo "password:root"
    return 0
  fi

  temp_pass="$(get_brew_temp_password)"
  if [ -n "$temp_pass" ] && "$MYSQL_CMD" --socket="$MYSQL_SOCKET" -u root -p"$temp_pass" --connect-expired-password -e "SELECT 1" >/dev/null 2>&1; then
    echo "temp_password:$temp_pass"
    return 0
  fi

  echo "unknown"
  return 1
}

print_status() {
  local status
  status="$(detect_auth_status || true)"
  echo "MySQL目录: $MYSQL_DIR"
  [ -n "$BREW_PKG" ] && echo "Homebrew包: $BREW_PKG"
  echo "认证状态: $status"
  case "$status" in
    no_password)
      echo "root 当前可无密码登录"
      ;;
    password:root)
      echo "root 当前密码可能是: root"
      ;;
    temp_password:*)
      echo "检测到临时密码: ${status#temp_password:}"
      ;;
    unknown)
      echo "无法自动判断密码，可能已设置自定义密码"
      ;;
  esac
}

set_root_password_online() {
  local current_password="$1"
  local new_password="$2"
  local auth_args=(--socket="$MYSQL_SOCKET")

  if [ -n "$current_password" ]; then
    auth_args+=(-p"$current_password")
  fi

  "$MYSQL_CMD" -u root "${auth_args[@]}" --connect-expired-password \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_password}'; FLUSH PRIVILEGES;"
}

configure_remote_root() {
  local root_password="$1"

  mysql_remote_configure_root "$MYSQL_CMD" "$root_password" "root"
  echo "已配置 root@'%' 远程访问"
}

ensure_remote_bind_address() {
  if [ -n "$CNF_FILE" ]; then
    mysql_remote_configure_bind_address "$CNF_FILE"
    echo "已配置 bind-address = 0.0.0.0: $CNF_FILE"
  else
    echo "未找到 my.cnf，跳过 bind-address 配置" >&2
  fi
}

stop_mysql() {
  if [ -n "$BREW_PKG" ]; then
    brew services stop "$BREW_PKG" >/dev/null 2>&1 || true
  fi
  if [ -x "$MYSQL_DIR/support-files/mysql.server" ]; then
    "$MYSQL_DIR/support-files/mysql.server" stop >/dev/null 2>&1 || true
  fi
  sleep 2
  # 如果仍在运行（密码未知时 mysql.server stop 会失败），用 kill 强制停止
  if pgrep -x mysqld >/dev/null 2>&1; then
    pkill -TERM -x mysqld 2>/dev/null || sudo kill -TERM "$(pgrep -x mysqld | head -1)" 2>/dev/null || true
    sleep 3
    if pgrep -x mysqld >/dev/null 2>&1; then
      pkill -KILL -x mysqld 2>/dev/null || sudo kill -KILL "$(pgrep -x mysqld | head -1)" 2>/dev/null || true
      sleep 1
    fi
  fi
}

start_mysql() {
  if [ -n "$BREW_PKG" ]; then
    brew services start "$BREW_PKG" >/dev/null 2>&1 || true
    return
  fi
  # 已在运行则跳过
  if "$MYSQLADMIN_CMD" --socket="$MYSQL_SOCKET" ping >/dev/null 2>&1; then
    return 0
  fi
  # 直接用 mysqld_safe 启动（mysql.server 可能因 basedir 不匹配而失败）
  if [ -n "$CNF_FILE" ] && [ -f "$CNF_FILE" ]; then
    "$MYSQLD_SAFE_CMD" --defaults-file="$CNF_FILE" >/dev/null 2>&1 &
  else
    "$MYSQLD_SAFE_CMD" >/dev/null 2>&1 &
  fi
}

force_reset_password() {
  local new_password="$1"
  local init_file safe_log safe_pid

  require_os_auth || return 1

  if [ ! -x "$MYSQLD_SAFE_CMD" ]; then
    echo "未找到 mysqld_safe，无法强制重置: $MYSQLD_SAFE_CMD" >&2
    return 1
  fi

  init_file="$(mktemp)"
  # 权限设为 644，确保 mysql 系统用户可读（mktemp 默认 600，mysql 进程可能无法读取）
  chmod 644 "$init_file"
  cat > "$init_file" << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_password}';
FLUSH PRIVILEGES;
EOF

  # 捕获 mysqld_safe 输出，便于失败时诊断
  safe_log="$(mktemp)"

  echo "停止 MySQL..."
  stop_mysql
  sleep 2

  echo "使用 init-file 重置 root 密码..."
  # 必须指定 --defaults-file，否则 MySQL 无法读取 user/datadir/socket 等配置
  if [ -n "$CNF_FILE" ] && [ -f "$CNF_FILE" ]; then
    "$MYSQLD_SAFE_CMD" --defaults-file="$CNF_FILE" --init-file="$init_file" >"$safe_log" 2>&1 &
  else
    "$MYSQLD_SAFE_CMD" --init-file="$init_file" >"$safe_log" 2>&1 &
  fi
  safe_pid=$!

  for _ in {1..40}; do
    if mysql_exec_with_password "$new_password"; then
      rm -f "$init_file"
      echo "root 密码已重置"
      # mysqld_safe --init-file 启动的实例已是正常运行状态，无需重启
      test_mysql_connection "$new_password" "重置后"
      configure_remote_root "$new_password" || true
      ensure_remote_bind_address || true
      rm -f "$safe_log"
      return 0
    fi
    sleep 1
  done

  # 重置失败：输出诊断信息
  rm -f "$init_file"
  echo "强制重置后仍无法使用新密码登录" >&2
  echo "--- mysqld_safe 输出日志 ---" >&2
  cat "$safe_log" >&2 2>/dev/null || true
  echo "--- 日志结束 ---" >&2
  echo "提示: MySQL 8.0 默认密码策略要求长度≥8 且包含大小写字母+数字+特殊字符" >&2
  echo "      密码 '${new_password}' 可能不符合策略，请使用更强的密码后重试" >&2
  rm -f "$safe_log"
  # 清理：停止临时实例并尝试恢复正常服务
  kill "$safe_pid" 2>/dev/null || true
  wait "$safe_pid" 2>/dev/null || true
  start_mysql || true
  return 1
}

if [ "$SHOW_STATUS" = true ]; then
  print_status
  exit 0
fi

if [ -z "$NEW_PASSWORD" ]; then
  read -r -s -p "请输入新的 root 密码: " NEW_PASSWORD
  echo ""
fi

if [ -z "$NEW_PASSWORD" ]; then
  echo "新密码不能为空" >&2
  exit 1
fi

status="$(detect_auth_status || true)"
case "$status" in
  no_password)
    set_root_password_online "" "$NEW_PASSWORD"
    echo "root 密码已设置为: $NEW_PASSWORD"
    configure_remote_root "$NEW_PASSWORD" || true
    ensure_remote_bind_address || true
    test_mysql_connection "$NEW_PASSWORD"
    ;;
  password:*)
    set_root_password_online "${status#password:}" "$NEW_PASSWORD"
    echo "root 密码已修改为: $NEW_PASSWORD"
    configure_remote_root "$NEW_PASSWORD" || true
    ensure_remote_bind_address || true
    test_mysql_connection "$NEW_PASSWORD"
    ;;
  temp_password:*)
    set_root_password_online "${status#temp_password:}" "$NEW_PASSWORD"
    echo "root 临时密码已修改为: $NEW_PASSWORD"
    configure_remote_root "$NEW_PASSWORD" || true
    ensure_remote_bind_address || true
    test_mysql_connection "$NEW_PASSWORD"
    ;;
  unknown)
    if [ -n "$CURRENT_PASSWORD" ]; then
      set_root_password_online "$CURRENT_PASSWORD" "$NEW_PASSWORD"
      echo "root 密码已修改为: $NEW_PASSWORD"
      configure_remote_root "$NEW_PASSWORD" || true
      ensure_remote_bind_address || true
      test_mysql_connection "$NEW_PASSWORD"
    elif [ "$FORCE_RESET" = true ]; then
      force_reset_password "$NEW_PASSWORD"
    else
      echo "无法判断当前 MySQL root 密码。"
      # 参数已指定新密码时直接重置，未指定时显示选择菜单
      if [ -n "$NEW_PASSWORD" ]; then
        echo "开始强制重置..."
        force_reset_password "$NEW_PASSWORD"
      else
        echo "请选择重置方式:"
        echo "  1) 输入新密码重置"
        echo "  2) 生成随机密码重置"
        echo "  3) 取消"
        read -r -p "请选择 [1]: " choice
        case "${choice:-1}" in
          1)
            read -r -s -p "请输入新的 root 密码: " NEW_PASSWORD
            echo ""
            [ -z "$NEW_PASSWORD" ] && { echo "密码不能为空" >&2; exit 1; }
            force_reset_password "$NEW_PASSWORD"
            ;;
          2)
            NEW_PASSWORD="$(generate_random_password)"
            echo "已生成随机 MySQL root 密码: $NEW_PASSWORD"
            force_reset_password "$NEW_PASSWORD"
            ;;
          3|*)
            echo "已取消。已知当前密码时使用 --current-password；未知时可使用 --force 强制重置。" >&2
            exit 1
            ;;
        esac
      fi
    fi
    ;;
esac

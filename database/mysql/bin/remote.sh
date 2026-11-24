#!/bin/bash
# MySQL 远程访问配置公共脚本

set -euo pipefail

mysql_remote_log_info() { echo "[INFO] $*"; }
mysql_remote_log_warn() { echo "[WARN] $*" >&2; }

mysql_remote_set_cnf_value() {
  local cnf_file="$1"
  local key="$2"
  local value="$3"
  local tmp

  [ -n "$cnf_file" ] || return 1
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

mysql_remote_configure_root() {
  local mysql_cmd="${1:-mysql}"
  local root_pass="$2"
  local root_user="${3:-root}"

  if [ -z "$root_pass" ]; then
    mysql_remote_log_warn "root 密码为空，无法配置远程访问"
    return 1
  fi

  "$mysql_cmd" -u "$root_user" -p"$root_pass" -e "
CREATE USER IF NOT EXISTS '${root_user}'@'%' IDENTIFIED BY '${root_pass}';
ALTER USER '${root_user}'@'%' IDENTIFIED BY '${root_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${root_user}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
" >/dev/null
}

mysql_remote_configure_bind_address() {
  local cnf_file="$1"
  mysql_remote_set_cnf_value "$cnf_file" "bind-address" "0.0.0.0"
}

mysql_remote_configure_all() {
  local mysql_cmd="${1:-mysql}"
  local root_pass="$2"
  local cnf_file="${3:-}"
  local root_user="${4:-root}"

  mysql_remote_configure_root "$mysql_cmd" "$root_pass" "$root_user"
  if [ -n "$cnf_file" ]; then
    mysql_remote_configure_bind_address "$cnf_file"
  else
    mysql_remote_log_warn "未指定 my.cnf，跳过 bind-address 配置"
  fi
}

mysql_remote_usage() {
  cat << EOF
用法: $0 --password PASSWORD [选项]

选项:
  --mysql-cmd CMD       mysql 命令路径，默认: mysql
  --password PASSWORD   root 密码
  --user USER           用户名，默认: root
  --cnf FILE            my.cnf 路径，用于配置 bind-address=0.0.0.0
  --grant-only          只配置 root@'%'
  --bind-only           只配置 bind-address
  -h, --help            显示帮助
EOF
}

mysql_remote_main() {
  local mysql_cmd="mysql"
  local root_pass=""
  local root_user="root"
  local cnf_file=""
  local grant=true
  local bind=true

  while [ $# -gt 0 ]; do
    case "$1" in
      --mysql-cmd)
        mysql_cmd="$2"
        shift 2
        ;;
      --mysql-cmd=*)
        mysql_cmd="${1#*=}"
        shift
        ;;
      --password)
        root_pass="$2"
        shift 2
        ;;
      --password=*)
        root_pass="${1#*=}"
        shift
        ;;
      --user)
        root_user="$2"
        shift 2
        ;;
      --user=*)
        root_user="${1#*=}"
        shift
        ;;
      --cnf)
        cnf_file="$2"
        shift 2
        ;;
      --cnf=*)
        cnf_file="${1#*=}"
        shift
        ;;
      --grant-only)
        grant=true
        bind=false
        shift
        ;;
      --bind-only)
        grant=false
        bind=true
        shift
        ;;
      -h|--help)
        mysql_remote_usage
        return 0
        ;;
      *)
        mysql_remote_log_warn "未知参数: $1"
        mysql_remote_usage
        return 1
        ;;
    esac
  done

  if [ "$grant" = true ]; then
    mysql_remote_configure_root "$mysql_cmd" "$root_pass" "$root_user"
    mysql_remote_log_info "已配置 ${root_user}@'%' 远程访问"
  fi

  if [ "$bind" = true ]; then
    if [ -z "$cnf_file" ]; then
      mysql_remote_log_warn "未指定 --cnf，无法配置 bind-address"
      return 1
    fi
    mysql_remote_configure_bind_address "$cnf_file"
    mysql_remote_log_info "已配置 bind-address = 0.0.0.0: $cnf_file"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  mysql_remote_main "$@"
fi

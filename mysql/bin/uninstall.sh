#!/bin/bash
# 优化版卸载脚本，支持指定安装目录，自动查找mysqld目录，优先调用安装目录下脚本

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR="$(bash "$SCRIPT_DIR/find_mysql.sh" "$1")"
if [ -z "$INSTALL_DIR" ]; then
  echo "未找到MySQL安装目录，退出。"
  exit 1
fi

BIN_DIR="$INSTALL_DIR/bin"

# 确认是否继续卸载
read -p "是否继续卸载 $INSTALL_DIR？[Y/n] " confirm
confirm=${confirm:-Y}
if [ "$confirm" == "n" ] || [ "$confirm" == "N" ]; then
  echo "取消卸载。"
  exit 0
fi

echo "执行卸载脚本..."

# 停止服务，优先调用安装目录下的stop.sh
if [ -f "$BIN_DIR/stop.sh" ]; then
  echo "调用 $BIN_DIR/stop.sh 停止MySQL..."
  bash "$BIN_DIR/stop.sh"
  stop_ret=$?
  if [ $stop_ret -eq 0 ]; then
    echo "MySQL服务已停止。"
  else
    echo "MySQL服务停止失败，请检查。"
  fi
else
  echo "未找到 $BIN_DIR/stop.sh，尝试kill mysqld 进程..."
  pkill -f "$INSTALL_DIR/bin/mysqld" || true
fi

# 再次检测并强制kill mysqld进程
if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
  echo "mysqld进程仍在运行，强制kill..."
  pkill -9 -f "$INSTALL_DIR/bin/mysqld"
  sleep 2
  if pgrep -f "$INSTALL_DIR/bin/mysqld" > /dev/null; then
    echo "mysqld进程仍未终止，请手动处理。"
  else
    echo "mysqld进程已被强制终止。"
  fi
else
  echo "mysqld进程已终止。"
fi

# 检查端口占用
if netstat -tlnp 2>/dev/null | grep ":3306" | grep mysqld; then
  echo "警告：3306端口仍被mysqld占用，请手动kill进程。"
else
  echo "3306端口未被mysqld占用。"
fi

# 从配置文件中读取日志目录
cnf=$INSTALL_DIR/conf/my.cnf
if [ -f "$cnf" ]; then
  log_dir=$(grep '^log-error' "$cnf" | awk -F'=' '{print $2}' | awk '$1=$1' | xargs dirname)
else
  log_dir="/var/log/mysql"
fi

echo "准备删除安装目录内容: $INSTALL_DIR"
ls -la "$INSTALL_DIR"

# 删除整个安装目录
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  if [ -d "$INSTALL_DIR" ]; then
    echo "目录删除失败，请检查权限或进程占用。"
    echo "被占用文件列表："
    lsof +D "$INSTALL_DIR" || echo "lsof未安装或无占用。"
  else
    echo "安装目录已成功删除。"
  fi
else
  echo "安装目录不存在，无需删除。"
fi

# 删除日志目录
if [ -n "$log_dir" ] && [ -d "$log_dir" ]; then
  rm -rf "$log_dir"
  if [ -d "$log_dir" ]; then
    echo "日志目录删除失败，请检查权限。"
  else
    echo "日志目录已成功删除。"
  fi
else
  echo "日志目录不存在，无需删除。"
fi

echo "MySQL已卸载：$INSTALL_DIR"

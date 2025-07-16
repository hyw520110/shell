#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR="$(bash "$SCRIPT_DIR/find_mysql.sh" "$1")"

MYSQLD_PIDS=$(pgrep -f mysqld)

if [ -z "$INSTALL_DIR" ]; then
  echo "未找到MySQL安装目录。"
  if [ -n "$MYSQLD_PIDS" ]; then
    echo "警告：系统中有mysqld进程在运行，进程信息如下："
    ps -ef | grep mysqld | grep -v grep
    # 优先尝试mysqladmin
    if command -v mysqladmin >/dev/null 2>&1; then
      echo "尝试使用mysqladmin正常停止MySQL..."
      mysqladmin -uroot -p shutdown
      ret=$?
      if [ $ret -eq 0 ]; then
        echo "MySQL已正常停止。"
      else
        echo "mysqladmin 停止失败，尝试强制kill mysqld进程..."
        echo "强制kill进程: $MYSQLD_PIDS"
        echo $MYSQLD_PIDS | xargs kill -9
        sleep 2
      fi
    else
      echo "未找到mysqladmin，直接强制kill mysqld进程..."
      echo $MYSQLD_PIDS | xargs kill -9
      sleep 2
    fi
    # 停止后再次检测
    REMAIN_PIDS=$(pgrep -f mysqld)
    if [ -n "$REMAIN_PIDS" ]; then
      echo "警告：以下mysqld进程仍在运行："
      ps -ef | grep mysqld | grep -v grep
    else
      echo "mysqld进程已全部终止。"
    fi
  else
    echo "未检测到mysqld进程。"
  fi
  # 检查3306端口占用
  port_info=$(netstat -tlnp 2>/dev/null | grep ":3306")
  if [ -n "$port_info" ]; then
    if echo "$port_info" | grep mysqld; then
      echo "警告：3306端口仍被mysqld占用，请手动kill进程。"
    else
      echo "警告：3306端口被其他程序占用："
      echo "$port_info"
    fi
  else
    echo "3306端口未被mysqld或其他程序占用。"
  fi
  # 最终判断
  if [ -z "$REMAIN_PIDS" ]; then
    echo "MySQL已完全停止。"
    exit 0
  else
    echo "MySQL未完全停止，请手动处理。"
    exit 1
  fi
fi

# 有安装目录时，按原逻辑处理
MYSQLD_PIDS=$(ps -ef|grep $INSTALL_DIR|grep mysqld|grep -v grep|awk '{print $2}')

if [ "" == "$1" ];then
    if [ -n "$MYSQLD_PIDS" ]; then
        echo "检测到以下mysqld进程："
        ps -ef | grep $INSTALL_DIR | grep mysqld | grep -v grep
        echo "尝试使用mysqladmin正常停止MySQL..."
        $INSTALL_DIR/bin/mysqladmin --defaults-file=$INSTALL_DIR/conf/my.cnf -uroot -p shutdown
        ret=$?
        if [ $ret -eq 0 ]; then
            echo "MySQL已正常停止。"
        else
            echo "mysqladmin 停止失败，尝试强制kill mysqld进程..."
            echo "强制kill进程: $MYSQLD_PIDS"
            echo $MYSQLD_PIDS | xargs kill -9
            sleep 2
        fi
        # 停止后再次检测
        REMAIN_PIDS=$(ps -ef|grep $INSTALL_DIR|grep mysqld|grep -v grep|awk '{print $2}')
        if [ -n "$REMAIN_PIDS" ]; then
          echo "警告：以下mysqld进程仍在运行："
          ps -ef | grep $INSTALL_DIR | grep mysqld | grep -v grep
        else
          echo "mysqld进程已全部终止。"
        fi
    else
        echo "未检测到mysqld进程，无需停止。"
    fi
else
    if [ -n "$MYSQLD_PIDS" ]; then
        echo "检测到以下mysqld进程："
        ps -ef | grep $INSTALL_DIR | grep mysqld | grep -v grep
        echo "强制kill进程: $MYSQLD_PIDS"
        echo $MYSQLD_PIDS | xargs kill -9
        sleep 2
        REMAIN_PIDS=$(ps -ef|grep $INSTALL_DIR|grep mysqld|grep -v grep|awk '{print $2}')
        if [ -n "$REMAIN_PIDS" ]; then
          echo "警告：以下mysqld进程仍在运行："
          ps -ef | grep $INSTALL_DIR | grep mysqld | grep -v grep
        else
          echo "mysqld进程已全部终止。"
        fi
    else
        echo "未检测到mysqld进程，无需停止。"
    fi
fi

# 检查3306端口占用
port_info=$(netstat -tlnp 2>/dev/null | grep ":3306")
if [ -n "$port_info" ]; then
  if echo "$port_info" | grep mysqld; then
    echo "警告：3306端口仍被mysqld占用，请手动kill进程。"
  else
    echo "警告：3306端口被其他程序占用："
    echo "$port_info"
  fi
else
  echo "3306端口未被mysqld或其他程序占用。"
fi

# 最终判断
if [ -z "$REMAIN_PIDS" ]; then
  echo "MySQL已完全停止。"
  exit 0
else
  echo "MySQL未完全停止，请手动处理。"
  exit 1
fi

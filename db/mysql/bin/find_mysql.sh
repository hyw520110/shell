#!/bin/bash
# 查找MySQL安装目录，优先参数指定，从进程中检测，然后在常见位置查找
#
# 使用方法:
#   find_mysql.sh [OPTIONS] [INSTALL_DIR_HINT]
#
# 参数:
#   INSTALL_DIR_HINT  可选的安装目录提示，若未指定则自动查找
#
# 选项:
#   --all             查找所有可能的 MySQL 安装目录
#   -h, --help        显示此帮助信息

set -euo pipefail  # 严格模式：遇到错误立即退出，未定义变量报错，管道错误传播

# 公共变量定义
ALL=false
OS=$(uname)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
install_dir="$SCRIPT_DIR/.."

show_help() {
    sed -n '3,13p' "$0" | sed 's/^# *//'
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            ALL=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            # 第一个非选项参数作为安装目录提示
            install_dir="$1"
            shift
            ;;
    esac
done


find_mysql_dirs() {
	# 常见安装目录查找是否已安装
	local found_dirs=()
	possible_dirs=(
	  "/home/$USER/"
	  "$HOME/"
	  "/usr/local/"
	  "/opt/"
	  "/"
	)
	for dir in "${possible_dirs[@]}"; do
	  #在常见目录下查找mysql是否安装，如指定目录下查找到则获取安装目录
	  local found=$(find "$dir" -type f -name mysqld 2>/dev/null | awk -F'/bin/mysqld' '{print $1}' | sort -u)
      if [ -n "$found" ]; then
          found_dirs+=($found)
          if [ "$ALL" = false ]; then
              break
          fi
      fi
	done

	# 输出常见目录下的查找结果
	if [ ${#found_dirs[@]} -gt 0 ]; then
        for dir in "${found_dirs[@]}"; do
            echo "$dir"
        done
        if [ "$ALL" = false ]; then
            return
        fi
    fi

	# 2. 从进程中检测（优先方法）
	proc_dir=""
	proc_pid=$(pgrep -f "mysqld.*--defaults-file" 2>/dev/null | head -n1)
	if [ -n "$proc_pid" ]; then
	  # 尝试从进程命令行参数中提取 basedir
	  if [ "$OS" == "Linux" ]; then
	    proc_cmd=$(ps -p $proc_pid -o args= 2>/dev/null)
        # 检查 ps 命令是否成功执行
        if [ $? -ne 0 ]; then
            proc_cmd=""
        fi
	    if [ -n "$proc_cmd" ]; then
	      proc_dir=$(echo "$proc_cmd" | grep -oP -- '--basedir=\K[^[:space:]]+' | head -n1)
	      if [ -z "$proc_dir" ]; then
	        # 尝试从datadir推断
	        data_dir=$(echo "$proc_cmd" | grep -oP -- '--datadir=\K[^[:space:]]+' | head -n1)
	        if [ -n "$data_dir" ]; then
	          # 尝试向上一级目录找到安装目录，因为datadir通常在basedir/data下
	          possible_basedir=$(dirname "$data_dir")
	          if [ -d "$possible_basedir/bin" ] && [ -f "$possible_basedir/bin/mysqld" ]; then
	            proc_dir="$possible_basedir"
	          fi
	        fi
	      fi
	      if [ -z "$proc_dir" ]; then
	        proc_path=$(readlink -f /proc/$proc_pid/exe 2>/dev/null)
            # 检查 readlink 命令是否成功执行
            if [ $? -ne 0 ]; then
                echo "Warning: Failed to readlink for PID $proc_pid (may be due to permission)" >&2
                proc_path=""
            fi
	        if [ -n "$proc_path" ]; then
	          proc_dir=$(dirname $(dirname "$proc_path"))
	        fi
	      fi
	    fi
	  elif [ "$OS" == "Darwin" ]; then
	    proc_cmd=$(ps -p $proc_pid -o command= 2>/dev/null)
        # 检查 ps 命令是否成功执行
        if [ $? -ne 0 ]; then
            proc_cmd=""
        fi
	    proc_dir=$(echo "$proc_cmd" | grep -E -- '--basedir=([^\ ]+)' | awk -F'--basedir=' '{print $2}' | awk '{print $1}')
	    if [ -z "$proc_dir" ]; then
	      proc_path=$(echo "$proc_cmd" | awk '{print $1}')
	      if [ -n "$proc_path" ]; then
	        proc_dir=$(dirname $(dirname "$proc_path"))
	      fi
	    fi
	  fi

      # 检查找到的目录是否有效
      if [ -n "$proc_dir" ] && [ -d "$proc_dir" ] && [ -f "$proc_dir/bin/mysqld" ]; then
        echo "$proc_dir"
        return
      fi
	fi
}

find_mysql_dirs $ALL
  
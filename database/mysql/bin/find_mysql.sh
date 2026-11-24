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

# 错误处理：捕获错误并输出详细信息
trap 'echo "错误: find_mysql.sh 在第 $LINENO 行失败，执行的命令: $BASH_COMMAND" >&2' ERR

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
    local found=""

    # macOS Homebrew 安装位置优先；启动/停止应使用 brew services，而不是通用 mysqld_safe 流程
    if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        local pkg prefix
        for pkg in mysql mysql@5.7 mysql@8.0 mysql@8.4 mysql@9.0 mysql@9.1 mysql@9.2 mysql@9.3 mysql@9.4 mysql@9.5 mysql@9.6; do
            prefix="$(brew --prefix "$pkg" 2>/dev/null || true)"
            prefix="$(cd "$prefix" 2>/dev/null && pwd -P || true)"
            if [ -n "$prefix" ] && [ -e "$prefix/bin/mysqld" ]; then
                echo "$prefix"
                [ "$ALL" = false ] && return
                found_dirs+=("$prefix")
            fi
        done
    fi

    # PATH 中的 mysqld，兼容用户手工安装和普通软链接
    if command -v mysqld >/dev/null 2>&1; then
        found="$(command -v mysqld)"
        found="$(cd "$(dirname "$found")/.." 2>/dev/null && pwd -P || true)"
        if [ -n "$found" ] && [ -e "$found/bin/mysqld" ]; then
            echo "$found"
            [ "$ALL" = false ] && return
            found_dirs+=("$found")
        fi
    fi

	# 优先搜索常见目录，限制深度避免超时
	possible_dirs=(
	  "$HOME"
	  "/home/$USER"
	  "/usr/local/mysql"
	  "/usr/local"
	  "/opt/homebrew"
	  "/opt/mysql"
	  "/opt"
	)
	for dir in "${possible_dirs[@]}"; do
	  # 跳过不存在的目录
	  [ ! -d "$dir" ] && continue
	  # 在常见目录下查找mysql是否安装，跟随软链接并限制深度
	  found=$(find -L "$dir" -maxdepth 6 \( -type f -o -type l \) -name mysqld 2>/dev/null | awk -F'/bin/mysqld' '{print $1}' | sort -u || true)
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

# 如果传入了安装目录参数，优先验证并输出
if [ -n "${install_dir:-}" ] && [ "$install_dir" != "$SCRIPT_DIR/.." ]; then
    # 规范化路径（去掉可能的尾部斜杠和双斜杠）
    if [ -d "$install_dir" ]; then
        install_dir=$(cd "$install_dir" 2>/dev/null && pwd)
        if [ -n "$install_dir" ] && [ -f "$install_dir/bin/mysqld" ]; then
            echo "$install_dir"
            exit 0
        fi
    fi
fi

find_mysql_dirs "$ALL" || true
  

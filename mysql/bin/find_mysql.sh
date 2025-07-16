#!/bin/bash
# 查找MySQL安装目录，优先参数指定，否则自动递归/opt查找，或从进程中检测

find_mysql_dirs() {
  local search_dir="$1"
  find "$search_dir" -type f -name mysqld 2>/dev/null | awk -F'/bin/mysqld' '{print $1}' | sort -u
}

# 1. 优先用参数
install_dir="${1:-}"
if [ -n "$install_dir" ] && [ -d "$install_dir" ] && [ -f "$install_dir/bin/mysqld" ]; then
  echo "$install_dir"
  exit 0
fi

# 2. 从进程中检测
proc_dir=""
proc_pid=$(pgrep -f mysqld | head -n1)
if [ -n "$proc_pid" ]; then
  # 尝试从进程命令行参数中提取 basedir
  proc_cmd=$(ps -p $proc_pid -o args=)
  proc_dir=$(echo "$proc_cmd" | grep -oP -- '--basedir=\K[^ ]+')
  if [ -z "$proc_dir" ]; then
    # fallback: 从进程路径推断
    proc_path=$(readlink -f /proc/$proc_pid/exe 2>/dev/null)
    if [ -n "$proc_path" ]; then
      proc_dir=$(dirname $(dirname "$proc_path"))
    fi
  fi
  if [ -n "$proc_dir" ] && [ -d "$proc_dir" ] && [ -f "$proc_dir/bin/mysqld" ]; then
    echo "$proc_dir"
    exit 0
  fi
fi

# 3. 自动查找
mapfile -t dirs < <(find_mysql_dirs "/opt")
for d in "${dirs[@]}"; do
  if [ -d "$d" ] && [ -f "$d/bin/mysqld" ]; then
    echo "$d"
    exit 0
  fi
done

# 4. 多个目录时让用户选择
if [ ${#dirs[@]} -gt 1 ]; then
  echo "找到多个MySQL安装目录："
  for i in "${!dirs[@]}"; do
    echo "$((i+1)). ${dirs[$i]}"
  done
  read -p "请选择要操作的目录编号: " idx
  idx=$((idx-1))
  if [ -z "${dirs[$idx]}" ]; then
    echo ""
    exit 1
  fi
  echo "${dirs[$idx]}"
  exit 0
fi

echo ""
exit 1 
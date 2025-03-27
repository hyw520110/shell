#!/bin/bash
# 卸载脚本，停止服务并删除相关文件，保留安装脚本相关文件

# 获取脚本所在目录
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=${CURRENT_DIR%/*}

if [ $(id -u) != "0" ]; then
    echo "使用root运行此脚本安装mysql!"
    exit 1
fi
# 确认是否继续卸载
read -p "是否继续卸载？[Y/n] " confirm
confirm=${confirm:-Y}
if [ "$confirm" == "n" ] || [ "$confirm" == "N" ]; then
  echo "取消卸载。"
  exit 0
fi
echo "执行卸载脚本..."

# 停止服务
$CURRENT_DIR/stop.sh

# 从配置文件中读取日志目录
cnf=$BASE_DIR/conf/my.cnf
if [ -f "$cnf" ]; then
  log_dir=$(grep '^log-error' "$cnf" | awk -F'=' '{print $2}' | awk '$1=$1' | xargs dirname)
else
  log_dir=$(grep '^log_dir=' "$CURRENT_DIR/install.sh" | awk -F'=' '{print $2}' | xargs)
fi

# 删除除安装脚本相关文件以外的文件和目录
rm -rf $CURRENT_DIR/{mysql*,ib*,inno*,lz*,my*,pe*,zl*}
rm -rf $BASE_DIR/{docs,include,logs,lib,man,share,LICENSE,support-files,data}

# 删除日志目录
if [ -n "$log_dir" ] && [ -d "$log_dir" ]; then
  sudo rm -rf "$log_dir"
fi

#!/bin/bash

# Nacos 安装入口脚本
# 本脚本为 bin/install.sh 的包装器，统一入口点
# 实际安装逻辑请参见 bin/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/bin/install.sh"

if [ ! -f "$INSTALL_SCRIPT" ]; then
    echo "错误: 找不到安装脚本 $INSTALL_SCRIPT" >&2
    exit 1
fi

# 透传所有参数给实际安装脚本
exec bash "$INSTALL_SCRIPT" "$@"

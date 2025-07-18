#!/bin/bash
# -*- coding: utf-8 -*-

# 设置严格模式
set -e

# 公共变量定义
SCRIPT_NAME=$(basename "$0")
USAGE="用法: ./$SCRIPT_NAME [nvm版本] [node版本]
示例: ./$SCRIPT_NAME v0.39.7 20.16.0"

# 默认版本
NVM_VERSION="${1:-v0.40.3}"
NODE_VERSION="${2:-22.17.0}"  # 使用 LTS 版本

# 官方默认镜像源地址
OFFICIAL_REGISTRY="https://registry.npmjs.org/"
# 国内镜像源（以淘宝镜像为例）
TAOBAO_REGISTRY="https://registry.npmmirror.com/"

# 日志函数
echo_info() {
    echo "[信息] $1"
}
echo_error() {
    echo "[错误] $1" >&2
}
nvm_dir="$HOME/.nvm"
if [ ! -d "$nvm_dir" ]; then
    nvm_dir="$HOME/.config/nvm"
fi

# 检查 nvm 安装状态
if [  -d "$nvm_dir" ]; then
    [ -f $nvm_dir/nvm.sh ] && source "$nvm_dir/nvm.sh" || echo_error "nvm.sh 文件不存在"
    # 检查当前版本和要安装的nvm版本是否匹配，提示用户进行选择是否安装指定版本
else
    echo_info "nvm 未安装，开始安装 nvm $NVM_VERSION..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
fi


[ -f $nvm_dir/nvm.sh ] && source "$nvm_dir/nvm.sh" || echo_error "nvm.sh 文件不存在"

if nvm ls | grep -q "$NODE_VERSION"; then
  echo "版本$NODE_VERSION已安装"
else
   echo_info "Node.js v$NODE_VERSION 未安装，开始安装..."
   nvm install $NODE_VERSION
fi

# 验证版本
echo_info "验证 Node.js 和 npm 版本..."
node -v
npm -v

# 设置默认版本
echo_info "设置默认 Node.js 版本..."
nvm alias default $NODE_VERSION

# 显示当前路径
echo_info "当前使用的 Node.js 路径: $(which node)"

# 获取当前 npm 镜像源
CURRENT_REGISTRY=$(npm config get registry)
# 判断当前是否为官方镜像
if [ "$CURRENT_REGISTRY" == "$OFFICIAL_REGISTRY" ]; then
    echo "当前使用的是官方 npm 镜像源 ($OFFICIAL_REGISTRY)，正在切换为国内镜像源 ($TAOBAO_REGISTRY)..."
    npm config set registry "$TAOBAO_REGISTRY"
    echo "切换完成！当前镜像源: $(npm config get registry)"
    # 设置华为镜像
	#npm config set registry https://mirrors.huaweicloud.com/repository/npm/
	# 设置腾讯云镜像
	#npm config set registry https://mirrors.cloud.tencent.com/npm/
fi


#!/bin/bash

# 下载并执行 nvm 安装脚本
wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash

# 源 .bashrc 文件以确保 nvm 命令可用
source ~/.bashrc

# 检查 nvm 是否安装成功
nvm --version

# 安装最新稳定版的 Node.js
nvm install stable

# 验证 Node.js 和 npm 版本
node -v
npm -v

# 设置默认 Node.js 版本为最新稳定版
nvm alias default stable
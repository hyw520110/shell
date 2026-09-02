# Ganache 管理脚本

> 📦 Ethereum 个人区块链 - 快速开发测试环境

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](readme.md)

## 📖 简介

Ganache 是一个用于 Ethereum 开发的个人区块链，可以让您快速开发去中心化应用。它会创建一个本地区块链，提供以下功能：

- 🚀 快速启动本地区块链
- 💼 自动生成测试账户和 ETH
- 🔧 可配置的 Gas 限制和网络参数
- 📊 实时查看交易和事件日志
- 💾 持久化存储区块链状态

## 📑 目录

- [快速开始](#-快速开始)
- [系统要求](#-系统要求)
- [命令参考](#-命令参考)
- [配置选项](#-配置选项)
- [使用示例](#-使用示例)
- [常见问题](#-常见问题)
- [文件结构](#-文件结构)

---

## 🚀 快速开始

### 一键安装

```bash
# 进入目录
cd ganache

# 安装 Ganache (使用默认配置)
./ganache.sh install

# 或者使用淘宝镜像源加速安装
./ganache.sh install -m taobao
```

### 配置

```bash
# 使用默认配置
./ganache.sh configure

# 自定义配置
./ganache.sh configure --port 7545 --accounts 5 --balance 1000
```

### 启动

```bash
# 前台启动
./ganache.sh start

# 后台启动
./ganache.sh start -d

# 指定端口启动
./ganache.sh start --port 8545
```

### 查看状态

```bash
./ganache.sh status
```

---

## 📋 系统要求

| 要求 | 说明 |
|------|------|
| **操作系统** | Linux (CentOS 7+, Ubuntu 18.04+) 或 macOS 10.15+ |
| **Bash** | 4.0+ |
| **Node.js** | 14+ (必需) |
| **npm** | 6+ (随 Node.js 安装) |
| **磁盘空间** | 至少 500MB 可用空间 |
| **权限** | 需要 sudo 权限安装全局 npm 包 |

### 检查 Node.js

```bash
# 检查 Node.js 版本
node -v

# 检查 npm 版本
npm -v
```

### 安装 Node.js

**macOS:**
```bash
brew install node
```

**Ubuntu/Debian:**
```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
```

**CentOS/RHEL:**
```bash
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo -E bash -
sudo yum install -y nodejs
```

---

## 📂 命令参考

### 主命令

| 命令 | 说明 |
|------|------|
| `./ganache.sh install` | 安装 Ganache |
| `./ganache.sh configure` | 配置 Ganache |
| `./ganache.sh uninstall` | 卸载 Ganache |
| `./ganache.sh start` | 启动 Ganache |
| `./ganache.sh stop` | 停止 Ganache |
| `./ganache.sh restart` | 重启 Ganache |
| `./ganache.sh status` | 查看状态 |
| `./ganache.sh logs` | 查看日志 |
| `./ganache.sh version` | 显示版本 |

### 安装选项

```bash
./ganache.sh install [选项]

选项:
  -v, --version <版本>   指定 Ganache 版本 (默认：latest)
  -m, --mirror <镜像>    指定 npm 镜像源 (cnpm|taobao|official)
  -f, --force            强制重新安装
  -h, --help             显示帮助
```

**镜像源说明:**
| 镜像源 | URL | 适用地区 |
|--------|-----|----------|
| official | https://registry.npmjs.org | 全球 |
| taobao | https://registry.npmmirror.com | 中国大陆 |
| cnpm | https://r.cnpmjs.org | 中国大陆 |

### 配置选项

```bash
./ganache.sh configure [选项]

选项:
  --port <端口>          RPC 监听端口 (默认：8545)
  --network-id <ID>      网络 ID (默认：5777)
  --accounts <数量>      生成账户数量 (默认：10)
  --balance <ETH>        每个账户的 ETH 余额 (默认：100)
  --gas-limit <限制>     Gas 限制 (默认：6721975)
  --gas-price <价格>     Gas 价格 (默认：20000000000)
  --host <主机>          监听主机 (默认：127.0.0.1)
  --db-path <路径>       数据库路径
  --reset                重置为默认配置
  -h, --help             显示帮助
```

### 启动选项

```bash
./ganache.sh start [选项]

选项:
  -d, --detach           后台运行
  --port <端口>          覆盖配置文件的端口
  --host <主机>          覆盖配置文件的主机
```

### 卸载选项

```bash
./ganache.sh uninstall [选项]

选项:
  -f, --force            强制卸载，不确认
  --keep-config          保留配置文件和数据
  -h, --help             显示帮助
```

---

## ⚙️ 配置选项

### 默认配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| port | 8545 | RPC 监听端口 |
| networkId | 5777 | Ethereum 网络 ID |
| host | 127.0.0.1 | 监听主机地址 |
| totalAccounts | 10 | 自动生成的测试账户数 |
| defaultBalanceETH | 100 | 每个账户的初始 ETH 余额 |
| gasLimit | 6721975 | 区块 Gas 限制 |
| gasPrice | 20000000000 | Gas 价格 (Wei) |
| dbPath | ~/.ganache/db | 区块链数据持久化路径 |

### 配置文件位置

```
~/.ganache/
├── config.json      # 主配置文件
├── start.sh         # 启动脚本
├── ganache.pid      # 进程 ID 文件
├── db/              # 区块链数据目录
└── logs/            # 日志目录
    └── ganache.log  # 运行日志
```

---

## 💡 使用示例

### 基础使用

```bash
# 1. 安装 Ganache
./ganache.sh install -m taobao

# 2. 配置 (使用默认参数)
./ganache.sh configure

# 3. 启动 (前台运行，推荐)
./ganache.sh start

# 4. 查看状态
./ganache.sh status

# 5. 查看日志
./ganache.sh logs

# 6. 停止
./ganache.sh stop
```

### macOS 长期运行（推荐）

在 macOS 上，`./ganache.sh start -d` 后台模式在终端关闭后可能会停止。
**推荐使用 launchd 服务长期运行：**

```bash
# 1. 配置 Ganache
./ganache.sh configure

# 2. 加载 launchd 服务
launchctl load ~/Library/LaunchAgents/com.trufflesuite.ganache.plist

# 3. 查看状态
./ganache.sh status

# 4. 停止服务
launchctl unload ~/Library/LaunchAgents/com.trufflesuite.ganache.plist
```

### 自定义配置

```bash
# 配置自定义端口和账户
./ganache.sh configure --port 7545 --accounts 20 --balance 1000

# 启动并覆盖端口
./ganache.sh start --port 8545
```

### 开发环境

```bash
# 安装指定版本
./ganache.sh install -v 7.9.1

# 重置配置为默认值
./ganache.sh configure --reset

# 后台启动，方便开发
./ganache.sh start -d

# 实时查看日志
./ganache.sh logs -f
```

### 连接 MetaMask

配置 Ganache 后，在 MetaMask 中添加网络:

| 参数 | 值 |
|------|-----|
| 网络名称 | Ganache Local |
| 新 RPC URL | http://127.0.0.1:8545 |
| Chain ID | 5777 |
| 货币符号 | ETH |

### 连接 Truffle/Hardhat

**Truffle 配置 (`truffle-config.js`):**
```javascript
module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*"
    }
  }
};
```

**Hardhat 配置 (`hardhat.config.js`):**
```javascript
module.exports = {
  networks: {
    ganache: {
      url: "http://127.0.0.1:8545",
      network_id: 5777
    }
  }
};
```

---

## ❓ 常见问题

### Q: 安装失败，提示权限错误

**A:** 使用 sudo 执行安装:
```bash
sudo ./ganache.sh install
```

### Q: ganache 命令找不到

**A:** 可能需要重新加载 shell 或检查 npm 全局路径:
```bash
# 重新加载 shell
exec $SHELL -l

# 检查 npm 全局路径
npm config get prefix

# 将 npm 全局路径添加到 PATH
export PATH=$(npm config get prefix)/bin:$PATH
```

### Q: 端口已被占用

**A:** 使用其他端口启动:
```bash
./ganache.sh start --port 7545
```

或者查找并停止占用端口的进程:
```bash
# 查找占用 8545 端口的进程
lsof -i :8545

# 停止进程
kill -9 <PID>
```

### Q: 如何清除区块链数据

**A:** 删除数据库目录:
```bash
rm -rf ~/.ganache/db
```

或者重新配置时指定新的数据库路径:
```bash
./ganache.sh configure --db-path ~/.ganache/db_new
```

### Q: 如何更新 Ganache

**A:** 使用强制安装参数:
```bash
./ganache.sh install -f
```

### Q: 日志文件在哪里

**A:** 日志文件位置:
```
~/.ganache/logs/ganache.log
```

查看日志:
```bash
./ganache.sh logs
./ganache.sh logs -f  # 实时查看
```

---

## 📁 文件结构

```
ganache/
├── ganache.sh           # 主管理脚本（一键入口）
├── bin/
│   ├── common.sh        # 通用函数库（日志、检查等）
│   ├── install.sh       # 安装脚本
│   ├── configure.sh     # 配置脚本
│   └── uninstall.sh     # 卸载脚本
├── conf/                # 配置文件目录 (可选)
└── readme.md            # 说明文档
```

### 运行时生成的文件

```
~/.ganache/
├── config.json          # Ganache 配置文件
├── start.sh             # 启动脚本
├── ganache.pid          # 进程 ID 文件
├── db/                  # 区块链数据目录
└── logs/
    └── ganache.log      # 运行日志

~/Library/LaunchAgents/
└── com.trufflesuite.ganache.plist  # macOS launchd 服务配置
```

---

## 🔗 相关链接

- [Ganache 官方文档](https://trufflesuite.com/docs/ganache/)
- [Ganache GitHub](https://github.com/trufflesuite/ganache)
- [Truffle Suite](https://trufflesuite.com/)
- [Ethereum 开发文档](https://ethereum.org/en/developers/)

---

## 📝 许可证

MIT License

---

## ⚠️ 安全警告

- Ganache 仅用于开发和测试环境，**不要用于生产环境**
- Ganache 生成的私钥和助记词不应存储真实资产
- 定期备份重要数据
- 执行卸载操作前请确认数据已备份

# BanyanDB 一键安装配置脚本

本目录包含 BanyanDB 数据库的一键安装配置脚本，支持主机和 Docker Compose 两种安装方式。

## 功能特性

- 🚀 一键安装，自动检测环境
- 🐳 支持 Docker Compose 部署
- 🖥️ 支持主机直接部署
- 🔧 自动配置文件生成
- 📊 内置监控和健康检查
- 🛡️ 安全配置选项

## 目录结构

```
banyandb/
├── bin/                    # 脚本目录
│   ├── install.sh         # 一键安装脚本
│   ├── startup.sh         # 启动脚本
│   └── stop.sh            # 停止脚本
├── conf/                   # 配置文件目录
│   └── banyandb.toml      # 配置文件模板
├── data/                   # 数据目录
├── logs/                   # 日志目录
├── docker-compose.yml      # Docker Compose 配置
└── README.md               # 本文档
```

## 快速开始

### 1. 一键安装

```bash
# 进入 BanyanDB 目录
cd /home/dev/work/shell/db/banyandb

# 执行安装脚本
./bin/install.sh
```

安装脚本会自动检测环境：
- 如果 Docker 已安装并启动，优先使用 Docker Compose 方式
- 否则使用主机安装方式

### 2. 自定义安装

```bash
# 指定安装目录
./bin/install.sh --install-dir=/usr/local/banyandb

# 指定版本
./bin/install.sh --version=v1.0.0

# 强制使用 Docker 方式
./bin/install.sh --docker

# 强制使用主机方式
./bin/install.sh --host

# 指定端口
./bin/install.sh --port=17912 --grpc-port=17913 --http-port=17914
```

### 3. 服务管理

```bash
# 启动服务
./bin/startup.sh

# 停止服务
./bin/stop.sh

# 强制停止
./bin/stop.sh --force

# 使用指定配置文件启动
./bin/startup.sh --config=/path/to/config.toml
```

## 配置说明

### 默认端口

- 服务端口: 17912
- gRPC 端口: 17913
- HTTP 端口: 17914
- 监控端口: 17915

### 配置文件

主配置文件位于 `conf/banyandb.toml`，包含以下主要配置项：

- `[server]` - 服务器配置
- `[storage]` - 存储引擎配置
- `[replication]` - 副本配置
- `[monitoring]` - 监控配置
- `[security]` - 安全配置
- `[performance]` - 性能配置

### 环境变量

Docker 方式支持以下环境变量：

- `BANYANDB_DATA_DIR` - 数据目录
- `BANYANDB_LOG_DIR` - 日志目录
- `BANYANDB_CONFIG_FILE` - 配置文件路径

## 安装方式对比

| 特性 | Docker Compose | 主机安装 |
|------|---------------|----------|
| 部署难度 | 简单 | 中等 |
| 资源占用 | 较高 | 较低 |
| 性能 | 中等 | 高 |
| 隔离性 | 好 | 一般 |
| 管理便利性 | 好 | 一般 |
| 适用场景 | 开发测试、快速部署 | 生产环境、性能要求高 |

## 故障排除

### 1. Docker 方式问题

```bash
# 查看容器状态
docker-compose ps

# 查看容器日志
docker-compose logs -f

# 重启容器
docker-compose restart

# 重新构建容器
docker-compose up -d --force-recreate
```

### 2. 主机方式问题

```bash
# 查看服务状态
sudo systemctl status banyandb

# 查看服务日志
sudo journalctl -u banyandb -f

# 重启服务
sudo systemctl restart banyandb

# 查看配置文件
cat /opt/banyandb/conf/banyandb.toml
```

### 3. 常见问题

**Q: 端口被占用**
```bash
# 查看端口占用
netstat -tlnp | grep 17912

# 解决方法：修改配置文件中的端口或停止占用端口的进程
```

**Q: 权限问题**
```bash
# 确保脚本有执行权限
chmod +x bin/*.sh

# 主机安装需要 root 权限
sudo ./bin/install.sh
```

**Q: 内存不足**
```bash
# 调整配置文件中的内存限制
vim conf/banyandb.toml

# 修改 [storage] 部分的 max-memory 配置
```

## 卸载

### Docker 方式

```bash
cd /home/dev/work/shell/db/banyandb
docker-compose down -v
```

### 主机方式

```bash
# 停止服务
sudo systemctl stop banyandb

# 禁用服务
sudo systemctl disable banyandb

# 删除服务文件
sudo rm /etc/systemd/system/banyandb.service

# 重新加载 systemd
sudo systemctl daemon-reload

# 删除安装目录
sudo rm -rf /opt/banyandb

# 删除用户（可选）
sudo userdel banyandb
```

## 更多资源

- [BanyanDB 官方文档](https://github.com/banyandb/banyandb)
- [BanyanDB 配置参考](https://github.com/banyandb/banyandb/blob/main/docs/configuration.md)
- [Docker 官方文档](https://docs.docker.com/)
- [Docker Compose 文档](https://docs.docker.com/compose/)

## 许可证

本脚本遵循 MIT 许可证。
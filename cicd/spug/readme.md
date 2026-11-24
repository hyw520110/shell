# Spug 自动化运维平台

Spug 是轻量级自动化运维平台，由 Python + Vue3 开发。功能涵盖主机管理、批量执行、任务计划、监控告警、CI/CD、配置中心等。

> 官网：https://ops.spug.cc/

## 📋 目录

- [快速开始](#快速开始)
- [脚本说明](#脚本说明)
- [使用指南](#使用指南)
- [功能模块](#功能模块)
- [常用命令](#常用命令)
- [配置说明](#配置说明)
- [故障排查](#故障排查)

---

## 🚀 快速开始

### 一键安装

```bash
# 进入目录
cd cicd/spug

# Docker 模式（推荐，自动检测 Docker）
./bin/install-spug.sh

# 指定端口和密码
./bin/install-spug.sh --port 8080 --admin-password MyPwd123

# 配置自启动
./bin/install-spug.sh --auto-start

# 主机模式（需要手动配置 Python/MySQL/Redis/Nginx）
./bin/install-spug.sh --mode host
```

### 访问控制台

```
访问地址：http://localhost:<PORT>
管理员账号：admin
默认密码：spug.cc
```

> ⚠️ **首次登录后请立即修改管理员密码！**

### 卸载

```bash
# 交互式卸载
./bin/uninstall-spug.sh

# 强制卸载
./bin/uninstall-spug.sh --force

# 保留数据文件卸载
./bin/uninstall-spug.sh --keep-data
```

---

## 📝 脚本说明

### install-spug.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `/data/spug` |
| `-p, --port PORT` | 访问端口（仅 Docker 模式） | `80` |
| `--admin-password PWD` | 管理员初始密码 | `spug.cc` |
| `--mysql-password PWD` | MySQL 密码 | `spug.cc` |
| `--mode MODE` | 安装模式 (auto\|docker\|host) | `auto` |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-spug.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | Spug 安装目录 | `/data/spug` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--mode MODE` | 卸载模式 (auto\|docker\|host) | `auto` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 安装模式说明

#### Docker Compose 模式（推荐）

自动检测 Docker，使用容器化部署：

```bash
# 自动检测并安装
./bin/install-spug.sh

# 强制使用 Docker 模式
./bin/install-spug.sh --mode docker
```

**优点：**
- 一键部署，无需手动配置依赖
- 环境隔离，不影响宿主机
- 便于迁移和备份

#### 主机模式

直接在宿主机安装，需要预先配置：
- Python 3
- MySQL
- Redis
- Nginx

```bash
./bin/install-spug.sh --mode host
```

**适用场景：**
- 无法使用 Docker 的环境
- 需要深度定制配置

### 启动服务

#### Docker 模式

```bash
cd /data/spug

# 方式 1：使用启动脚本
./bin/startup.sh

# 方式 2：使用 docker-compose
docker compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start spug
```

#### 主机模式

```bash
# 使用 systemd
sudo systemctl start spug

# 使用 init.d
sudo /etc/init.d/spug start

# 使用启动脚本
/data/spug/bin/startup.sh
```

### 停止服务

#### Docker 模式

```bash
cd /data/spug

# 方式 1：使用停止脚本
./bin/stop.sh

# 方式 2：使用 docker-compose
docker compose down

# 方式 3：使用 systemd
sudo systemctl stop spug
```

#### 主机模式

```bash
sudo systemctl stop spug
```

### 查看状态

#### Docker 模式

```bash
cd /data/spug

# 查看服务状态
./bin/status.sh

# 查看容器状态
docker compose ps

# 查看详细日志
docker compose logs -f spug
```

#### 主机模式

```bash
# 查看 systemd 状态
sudo systemctl status spug

# 查看日志
sudo journalctl -u spug -f
```

---

## 🎯 功能模块

| 模块 | 功能说明 |
|------|----------|
| **主机管理** | 添加和管理服务器主机、分组管理、SSH 认证 |
| **批量执行** | 多主机批量执行命令、实时查看结果、文件分发 |
| **任务计划** | Cron 定时任务、任务依赖、执行日志 |
| **监控告警** | 资源监控（CPU/内存/磁盘）、告警通知（邮件/Webhook） |
| **CI/CD** | 应用发布、构建流水线、版本管理、回滚 |
| **配置中心** | 配置文件管理、版本控制、配置对比、批量下发 |
| **作业中心** | 自动化运维作业、作业模板、作业编排 |

---

## 🔧 常用命令

### Docker 模式命令

```bash
# 查看所有容器
docker compose ps

# 重启 Spug 服务
docker compose restart spug

# 查看 Spug 日志
docker compose logs -f spug

# 查看数据库日志
docker compose logs -f spug-db

# 进入 Spug 容器
docker exec -it spug bash

# 进入数据库容器
docker exec -it spug-db mysql -uspug -pspug.cc
```

### 数据库操作

```bash
# 备份数据库
docker exec spug-db mysqldump -uroot -pspug.cc spug > spug_backup.sql

# 恢复数据库
docker exec -i spug-db mysql -uroot -pspug.cc spug < spug_backup.sql

# 查看数据库
docker exec -it spug-db mysql -uspug -pspug.cc
```

### 重新初始化

```bash
# 重新初始化管理员密码
docker exec spug init_spug admin new_password
```

### 数据备份

```bash
# 备份数据目录
tar -czf spug_backup_$(date +%Y%m%d).tar.gz /data/spug

# 备份数据库
docker exec spug-db mysqldump -uroot -pspug.cc spug > spug_$(date +%Y%m%d).sql
```

### 系统管理

```bash
# 查看数据目录大小
du -sh /data/spug/*

# 查看日志目录大小
du -sh /data/spug/logs

# 清理旧日志
find /data/spug/logs -name "*.log" -mtime +30 -delete
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SPUG_PORT` | Spug 访问端口 | `80` |
| `ADMIN_PASSWORD` | 管理员初始密码 | `spug.cc` |
| `MYSQL_PASSWORD` | MySQL 用户密码 | `spug.cc` |
| `MYSQL_ROOT_PASSWORD` | MySQL root 密码 | `spug.cc` |

### 目录结构

```
spug/
├── bin/
│   ├── install-spug.sh    # 安装脚本
│   ├── uninstall-spug.sh  # 卸载脚本
│   ├── startup.sh         # 启动脚本
│   ├── stop.sh            # 停止脚本
│   └── status.sh          # 状态检查脚本
├── data/
│   ├── service/           # Spug 服务数据
│   ├── repos/             # 代码仓库目录
│   └── mysql/             # MySQL 数据文件
├── logs/                  # 日志目录
├── docker-compose.yml     # Docker Compose 配置文件
└── .env                   # 环境变量配置
```

### 系统要求

| 资源 | Docker 模式 | 主机模式 |
|------|------------|----------|
| CPU | 1 核 | 2 核 + |
| 内存 | 1GB | 2GB+ |
| 磁盘 | 10GB | 50GB+ |
| Docker | 20.10+ | - |
| Python | - | 3.8+ |
| MySQL | - | 5.7+ |
| Redis | - | 5.0+ |
| Nginx | - | 1.18+ |

---

## 🔍 故障排查

### 服务无法启动

#### Docker 模式

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :80

# 3. 查看错误日志
docker compose logs spug

# 4. 检查磁盘空间
df -h

# 5. 检查容器状态
docker compose ps

# 6. 重新创建容器
docker compose down
docker compose up -d
```

#### 主机模式

```bash
# 1. 检查服务状态
systemctl status spug

# 2. 查看日志
journalctl -u spug -f

# 3. 检查依赖服务
systemctl status mysqld
systemctl status redis
systemctl status nginx

# 4. 检查端口占用
lsof -i :8000
lsof -i :80
```

### Spug 页面无法访问

```bash
# 1. 检查容器状态
docker compose ps

# 2. 检查 Spug 是否健康
docker inspect spug | grep Health

# 3. 查看 Spug 日志
docker compose logs spug

# 4. 测试容器内服务
docker exec spug curl -s http://localhost:80

# 5. 重启 Spug
docker compose restart spug
```

### 数据库连接失败

```bash
# 1. 检查数据库容器状态
docker compose ps spug-db

# 2. 测试数据库连接
docker exec spug-db mysqladmin ping -uroot -pspug.cc

# 3. 查看数据库日志
docker compose logs spug-db

# 4. 重启数据库
docker compose restart spug-db
```

### 初始化失败

```bash
# 1. 等待服务就绪
sleep 30

# 2. 手动执行初始化
docker exec spug init_spug admin spug.cc

# 3. 查看日志
docker compose logs spug
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
du -sh /data/spug/*

# 2. 清理 MySQL 二进制日志
docker exec spug-db mysql -uroot -pspug.cc -e "RESET MASTER;"

# 3. 清理旧日志
find /data/spug/logs -name "*.log" -mtime +30 -delete

# 4. 清理旧备份
find /data/spug -name "*.tar.gz" -mtime +30 -delete
```

### 内存不足

```bash
# 1. 查看内存使用
free -h
docker stats

# 2. 限制容器内存（编辑 docker-compose.yml）
# 在 spug 服务中添加：
# deploy:
#   resources:
#     limits:
#       memory: 1G
```

---

## 📚 参考资源

- [Spug 官网](https://ops.spug.cc/)
- [Spug GitHub](https://github.com/openspug/spug)
- [Spug 文档](https://ops.spug.cc/docs/)
- [Docker Hub](https://hub.docker.com/r/openspug/spug-service)

---

**最后更新**: 2026 年 3 月 13 日

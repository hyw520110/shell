# JumpServer 堡垒机

JumpServer 是广受欢迎的开源堡垒机，支持资产管理、权限控制、操作审计等功能。

> 官网：https://www.jumpserver.org/

## 📋 目录

- [快速开始](#快速开始)
- [脚本说明](#脚本说明)
- [使用指南](#使用指南)
- [功能特性](#功能特性)
- [常用命令](#常用命令)
- [配置说明](#配置说明)
- [故障排查](#故障排查)

---

## 🚀 快速开始

### 一键安装

```bash
# 进入目录
cd jumpserver

# 使用默认设置安装
sudo ./bin/install-jumpserver.sh

# 指定域名和端口
sudo ./bin/install-jumpserver.sh --domain jump.example.com --port 80

# 配置自启动
sudo ./bin/install-jumpserver.sh --auto-start
```

### 访问控制台

```
访问地址：http://<domain>:<port>
管理员账号：admin
默认密码：admin123
```

> ⚠️ **首次登录后请立即修改管理员密码！**

### 卸载

```bash
# 交互式卸载
sudo ./bin/uninstall-jumpserver.sh

# 强制卸载
sudo ./bin/uninstall-jumpserver.sh --force

# 保留数据文件卸载
sudo ./bin/uninstall-jumpserver.sh --keep-data
```

---

## 📝 脚本说明

### install-jumpserver.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `/data/jumpserver` |
| `--domain DOMAIN` | JumpServer 访问域名 | `jumpserver.local` |
| `--port PORT` | 访问端口 | `8080` |
| `--db-password PWD` | 数据库密码 | `jumpserver123` |
| `--redis-password PWD` | Redis 密码 | `jumpserver123` |
| `--secret-key KEY` | SECRET_KEY | 随机生成 |
| `--bootstrap-token TOKEN` | BOOTSTRAP_TOKEN | 随机生成 |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-jumpserver.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | JumpServer 安装目录 | `/data/jumpserver` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 启动服务

```bash
cd /data/jumpserver

# 方式 1：使用启动脚本
sudo ./bin/startup.sh

# 方式 2：使用 docker-compose
cd /data/jumpserver && docker-compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start jumpserver
```

### 停止服务

```bash
cd /data/jumpserver

# 方式 1：使用停止脚本
sudo ./bin/stop.sh

# 方式 2：使用 docker-compose
docker-compose down

# 方式 3：使用 systemd
sudo systemctl stop jumpserver
```

### 查看状态

```bash
cd /data/jumpserver

# 查看服务状态
sudo ./bin/status.sh

# 查看容器状态
docker-compose ps

# 查看详细日志
docker-compose logs -f core
```

---

## 🎯 功能特性

| 功能 | 说明 |
|------|------|
| **资产管理** | 服务器、数据库、云资源统一管理，支持自动发现 |
| **权限控制** | 基于角色的访问控制（RBAC），细粒度权限管理 |
| **操作审计** | 会话录制、命令记录、操作日志、文件传输记录 |
| **多协议支持** | SSH、RDP、VNC、Telnet、MySQL、PostgreSQL、Oracle 等 |
| **自动化运维** | 批量命令执行、文件分发、任务计划 |
| **多租户** | 支持多组织、多用户、多权限域 |
| **会话协作** | 会话共享、多人协同操作 |
| **工单系统** | 提单审批流程，支持自定义审批流 |

---

## 🔧 常用命令

### 资产管理

```bash
# 通过 Web 界面添加资产
# 资产管理 -> 创建资产 -> 填写服务器信息

# 批量导入资产（CSV 格式）
# 资产管理 -> 导入 -> 上传 CSV 文件

# 测试资产连通性
# 资产管理 -> 选择资产 -> 测试连通性
```

### 用户管理

```bash
# 创建用户（通过 Web 界面）
# 用户管理 -> 创建用户 -> 填写用户信息

# 批量导入用户
# 用户管理 -> 导入 -> 上传 CSV 文件

# 重置用户密码
# 用户管理 -> 选择用户 -> 重置密码
```

### 授权管理

```bash
# 创建授权规则
# 权限管理 -> 创建授权 -> 选择用户和资产 -> 设置权限

# 查看授权
# 权限管理 -> 授权列表 -> 查看授权详情
```

### 会话管理

```bash
# 查看在线会话
# 会话管理 -> 在线会话

# 查看历史会话
# 会话管理 -> 历史会话 -> 搜索会话

# 回放会话录像
# 会话管理 -> 历史会话 -> 选择会话 -> 回放
```

### 审计日志

```bash
# 查看操作日志
# 审计 -> 操作日志 -> 搜索操作记录

# 查看命令记录
# 审计 -> 命令审计 -> 搜索命令

# 查看文件传输记录
# 审计 -> 文件传输 -> 查看上传/下载记录
```

### 系统管理

```bash
# 查看系统信息
docker exec jms_core python /opt/jumpserver/utils/get_local_ip_addr.py

# 查看版本
curl http://localhost:8080/api/v1/settings/setting/

# 备份数据库
docker exec jms_mysql mysqldump -ujumpserver -p jumpserver > jumpserver_backup.sql

# 恢复数据库
docker exec -i jms_mysql mysql -ujumpserver -p jumpserver < jumpserver_backup.sql
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `JUMPSERVER_DOMAIN` | JumpServer 访问域名 | `jumpserver.local` |
| `JUMPSERVER_PORT` | 访问端口 | `8080` |
| `DB_PASSWORD` | 数据库密码 | `jumpserver123` |
| `REDIS_PASSWORD` | Redis 密码 | `jumpserver123` |
| `SECRET_KEY` | 加密密钥 | 随机生成 |
| `BOOTSTRAP_TOKEN` | 注册令牌 | 随机生成 |

### 目录结构

```
jumpserver/
├── bin/
│   ├── install-jumpserver.sh  # 安装脚本
│   ├── uninstall-jumpserver.sh # 卸载脚本
│   ├── startup.sh             # 启动脚本
│   ├── stop.sh                # 停止脚本
│   └── status.sh              # 状态检查脚本
├── data/
│   ├── core/                  # 核心数据（审计录像等）
│   ├── mysql/                 # MySQL 数据
│   └── redis/                 # Redis 数据
├── logs/                      # 日志目录
├── conf/                      # 配置文件目录
├── docker-compose.yml         # Docker Compose 配置
└── .env                       # 环境变量配置
```

### 端口说明

| 端口 | 用途 |
|------|------|
| `8080` | Web 访问端口（可自定义） |
| `2222` | SSH 代理端口 |
| `33060` | MySQL 数据库代理端口 |
| `54320` | PostgreSQL 数据库代理端口 |

### 系统要求

| 资源 | 要求 |
|------|------|
| CPU | 2 核 + (推荐 4 核+) |
| 内存 | 2GB+ (推荐 4GB+) |
| 磁盘 | 20GB+ (根据审计数据量) |
| Docker | 20.10+ |
| Docker Compose | 2.0+ |

---

## 🔍 故障排查

### JumpServer 无法启动

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :8080

# 3. 查看错误日志
docker-compose logs core

# 4. 检查磁盘空间
df -h

# 5. 检查内存
free -h

# 6. 重新创建容器
docker-compose down
docker-compose up -d
```

### 无法登录 Web 界面

```bash
# 1. 检查服务状态
docker-compose ps

# 2. 测试连接
curl -I http://localhost:8080

# 3. 查看 core 日志
docker-compose logs core

# 4. 重启服务
docker-compose restart

# 5. 重置 admin 密码
docker exec -it jms_core python /opt/jumpserver/apps/users/utils.py
```

### 无法连接资产

```bash
# 1. 检查 koko 服务
docker-compose ps koko

# 2. 查看 koko 日志
docker-compose logs koko

# 3. 测试 SSH 代理端口
telnet localhost 2222

# 4. 检查资产连通性
# Web 界面：资产管理 -> 测试连通性

# 5. 重启 koko
docker-compose restart koko
```

### 会话录制失败

```bash
# 1. 检查存储空间
df -h /data/jumpserver/data/core

# 2. 查看核心服务日志
docker-compose logs core

# 3. 检查权限
ls -la /data/jumpserver/data/core

# 4. 重启服务
docker-compose restart core koko
```

### 数据库连接失败

```bash
# 1. 检查 MySQL 状态
docker-compose ps mysql

# 2. 测试数据库连接
docker exec jms_mysql mysql -ujumpserver -p -e "SELECT 1"

# 3. 查看 MySQL 日志
docker-compose logs mysql

# 4. 重启 MySQL
docker-compose restart mysql
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
du -sh /data/jumpserver/data/*

# 2. 查看审计录像大小
du -sh /data/jumpserver/data/core

# 3. 清理旧会话录像
# Web 界面：审计 -> 会话管理 -> 批量删除

# 4. 设置录像保留策略
# 系统设置 -> 安全设置 -> 会话录像保留天数
```

---

## 📚 参考资源

- [JumpServer 官网](https://www.jumpserver.org/)
- [JumpServer GitHub](https://github.com/jumpserver/jumpserver)
- [JumpServer 文档](https://docs.jumpserver.org/)
- [JumpServer 社区](https://github.com/jumpserver/jumpserver/discussions)

---

**最后更新**: 2026 年 3 月 13 日

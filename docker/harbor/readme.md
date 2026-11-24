# Harbor 容器镜像仓库

Harbor 是一个开源的容器镜像仓库，支持镜像漏洞扫描、镜像复制、权限管理、镜像签名等功能。

> 官网：https://goharbor.io/

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
cd harbor

# 使用默认设置安装
sudo ./bin/install-harbor.sh

# 指定域名和密码
sudo ./bin/install-harbor.sh --domain registry.example.com --password MyPwd123

# 不安装漏洞扫描
sudo ./bin/install-harbor.sh --without-trivy

# 配置自启动
sudo ./bin/install-harbor.sh --auto-start
```

### 访问控制台

```
访问地址：http://<domain>:80
管理员账号：admin
默认密码：Harbor12345 (或安装时自定义)
```

> ⚠️ **首次登录后请立即修改管理员密码！**

### Docker 使用

```bash
# 登录 Harbor
docker login <domain>:80

# 推送镜像
docker push <domain>:80/library/myimage:tag

# 拉取镜像
docker pull <domain>:80/library/myimage:tag
```

### 卸载

```bash
# 交互式卸载
sudo ./bin/uninstall-harbor.sh

# 强制卸载
sudo ./bin/uninstall-harbor.sh --force

# 保留数据文件卸载
sudo ./bin/uninstall-harbor.sh --keep-data
```

---

## 📝 脚本说明

### install-harbor.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `/data/harbor` |
| `--domain DOMAIN` | Harbor 访问域名 | `harbor.local` |
| `--port PORT` | HTTP 端口 | `80` |
| `--https-port PORT` | HTTPS 端口 | `443` |
| `--password PWD` | admin 初始密码 | `Harbor12345` |
| `--with-trivy` | 安装 Trivy 漏洞扫描 | `true` |
| `--without-trivy` | 不安装 Trivy | `false` |
| `--with-notary` | 安装 Notary 镜像签名 | `false` |
| `--auto-start` | 配置自启动服务 | `false` |
| `--skip-download` | 跳过下载（使用已有安装包） | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-harbor.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | Harbor 安装目录 | `/data/harbor` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 启动服务

```bash
cd /data/harbor

# 方式 1：使用启动脚本
sudo ./bin/startup.sh

# 方式 2：使用 docker-compose
cd /data/harbor/harbor && docker-compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start harbor
```

### 停止服务

```bash
cd /data/harbor

# 方式 1：使用停止脚本
sudo ./bin/stop.sh

# 方式 2：使用 docker-compose
cd /data/harbor/harbor && docker-compose down

# 方式 3：使用 systemd
sudo systemctl stop harbor
```

### 查看状态

```bash
cd /data/harbor

# 查看服务状态
sudo ./bin/status.sh

# 查看容器状态
cd /data/harbor/harbor && docker-compose ps

# 查看日志
cd /data/harbor/harbor && docker-compose logs -f
```

---

## 🎯 功能特性

| 功能 | 说明 |
|------|------|
| **镜像管理** | 上传、下载、删除、复制容器镜像 |
| **漏洞扫描** | 集成 Trivy，自动扫描镜像漏洞 |
| **权限管理** | 基于角色的访问控制（RBAC） |
| **镜像复制** | 支持跨仓库镜像复制 |
| **镜像签名** | 支持 Notary 镜像签名（可选） |
| **Web 界面** | 友好的 Web 管理界面 |
| **日志审计** | 操作日志记录和审计 |
| **多租户** | 支持多项目和多用户 |

---

## 🔧 常用命令

### 镜像操作

```bash
# 登录 Harbor
docker login registry.example.com

# 标记镜像
docker tag myimage:latest registry.example.com/library/myimage:latest

# 推送镜像
docker push registry.example.com/library/myimage:latest

# 拉取镜像
docker pull registry.example.com/library/myimage:latest

# 删除镜像
docker rmi registry.example.com/library/myimage:latest
```

### 用户和项目操作

```bash
# 创建项目（通过 Web 界面或 API）
curl -X POST "http://registry.example.com/api/v2.0/projects" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"myproject","public":false}'

# 创建用户
curl -X POST "http://registry.example.com/api/v2.0/users" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"username":"newuser","email":"user@example.com","password":"Password123","realname":"New User"}'
```

### 漏洞扫描

```bash
# 触发漏洞扫描（通过 Web 界面或 API）
curl -X POST "http://registry.example.com/api/v2.0/projects/myproject/repositories/myimage/scan" \
  -H "Authorization: Bearer <token>"

# 查看扫描结果
curl -X GET "http://registry.example.com/api/v2.0/projects/myproject/repositories/myimage/scan/summary" \
  -H "Authorization: Bearer <token>"
```

### 系统管理

```bash
# 查看 Harbor 版本
curl -X GET "http://registry.example.com/api/v2.0/systeminfo" | jq

# 查看存储使用情况
du -sh /data/harbor/data/*

# 清理旧镜像
# 通过 Web 界面设置保留策略
```

### 备份与恢复

```bash
# 备份数据
rsync -av /data/harbor/data/ /backup/harbor/

# 备份数据库
docker exec harbor-db pg_dump -U postgres registry > registry_backup.sql

# 恢复数据库
docker exec -i harbor-db psql -U postgres registry < registry_backup.sql
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `HARBOR_DOMAIN` | Harbor 访问域名 | `harbor.local` |
| `HARBOR_PORT` | HTTP 端口 | `80` |
| `HARBOR_HTTPS_PORT` | HTTPS 端口 | `443` |
| `HARBOR_PASSWORD` | admin 初始密码 | `Harbor12345` |
| `WITH_TRIVY` | 是否安装 Trivy | `true` |

### 目录结构

```
harbor/
├── bin/
│   ├── install-harbor.sh    # 安装脚本
│   ├── uninstall-harbor.sh  # 卸载脚本
│   ├── startup.sh           # 启动脚本
│   ├── stop.sh              # 停止脚本
│   └── status.sh            # 状态检查脚本
├── data/
│   ├── registry/            # 镜像存储
│   ├── redis/               # Redis 数据
│   ├── postgresql/          # 数据库数据
│   ├── trivy-adapter/       # Trivy 数据
│   └── upload/              # 上传目录
├── logs/                    # 日志目录
├── harbor/                  # Harbor 程序目录
│   ├── docker-compose.yml   # Docker Compose 配置
│   ├── harbor.yml           # Harbor 配置文件
│   └── install.sh           # Harbor 安装脚本
└── harbor-offline-installer-*.tgz  # 离线安装包
```

### 系统要求

| 资源 | 要求 |
|------|------|
| CPU | 4 核 + |
| 内存 | 4GB+ (推荐 8GB+) |
| 磁盘 | 50GB+ (根据镜像数量) |
| Docker | 20.10+ |
| Docker Compose | 2.0+ |

---

## 🔍 故障排查

### Harbor 无法启动

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :80

# 3. 查看错误日志
cd /data/harbor/harbor && docker-compose logs

# 4. 检查磁盘空间
df -h

# 5. 检查内存
free -h

# 6. 重新创建容器
cd /data/harbor/harbor
docker-compose down
docker-compose up -d
```

### 无法登录 Harbor

```bash
# 1. 检查服务状态
cd /data/harbor/harbor && docker-compose ps

# 2. 测试连接
curl -I http://localhost:80

# 3. 查看 core 日志
docker-compose logs core

# 4. 重置 admin 密码
docker exec -it harbor-core /harbor/harbor_admin_password --reset

# 5. 重启服务
docker-compose restart
```

### 镜像推送失败

```bash
# 1. 检查 Docker 登录
docker login <domain>

# 2. 检查存储空间
df -h /data/harbor/data

# 3. 查看 registry 日志
docker-compose logs registry

# 4. 检查权限
ls -la /data/harbor/data/registry

# 5. 重启 registry
docker-compose restart registry
```

### 漏洞扫描失败

```bash
# 1. 检查 Trivy 状态
docker-compose ps trivy-adapter

# 2. 查看 Trivy 日志
docker-compose logs trivy-adapter

# 3. 重启 Trivy
docker-compose restart trivy-adapter

# 4. 更新 Trivy 数据库
docker exec trivy-adapter trivy image --download-db-only
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
du -sh /data/harbor/data/*

# 2. 查看镜像存储大小
du -sh /data/harbor/data/registry

# 3. 清理未使用镜像
# 通过 Web 界面删除旧镜像

# 4. 设置保留策略
# 在项目中配置镜像保留规则
```

---

## 📚 参考资源

- [Harbor 官网](https://goharbor.io/)
- [Harbor GitHub](https://github.com/goharbor/harbor)
- [Harbor 文档](https://goharbor.io/docs/)
- [Trivy 漏洞扫描](https://aquasecurity.github.io/trivy/)

---

**最后更新**: 2026 年 3 月 13 日

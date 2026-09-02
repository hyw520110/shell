# Nexus Repository 仓库管理器

Nexus Repository 是强大的仓库管理器，支持 Maven、npm、Docker、PyPI 等多种格式的私有仓库管理。

> 官网：https://www.sonatype.com/products/nexus-repository

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
cd nexus

# Docker 模式（推荐）
sudo ./bin/install-nexus.sh

# 指定端口和密码
sudo ./bin/install-nexus.sh --port 8081 --admin-password MyPwd123

# 主机模式
sudo ./bin/install-nexus.sh --mode host --java-home /usr/lib/jvm/java-11

# 配置自启动
sudo ./bin/install-nexus.sh --auto-start
```

### 访问控制台

```
访问地址：http://localhost:8081
管理员账号：admin
默认密码：admin123 (或安装时自定义)
```

> ⚠️ **首次登录后请立即修改管理员密码！**

### 卸载

```bash
# 交互式卸载
sudo ./bin/uninstall-nexus.sh

# 强制卸载
sudo ./bin/uninstall-nexus.sh --force

# 保留数据文件卸载
sudo ./bin/uninstall-nexus.sh --keep-data
```

---

## 📝 脚本说明

### install-nexus.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `/data/nexus` |
| `-p, --port PORT` | 访问端口 | `8081` |
| `--admin-password PWD` | admin 初始密码 | `admin123` |
| `--mode MODE` | 安装模式 (auto\|docker\|host) | `auto` |
| `--java-home PATH` | Java 安装路径（主机模式） | 自动检测 |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-nexus.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | Nexus 安装目录 | `/data/nexus` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--mode MODE` | 卸载模式 (auto\|docker\|host) | `auto` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 安装模式说明

#### Docker Compose 模式（推荐）

使用 Docker 容器化部署：

```bash
sudo ./bin/install-nexus.sh --mode docker
```

**优点：**
- 部署简单，环境隔离
- 便于迁移和备份
- 不影响宿主机系统

#### 主机模式

直接在宿主机安装，需要 Java 环境：

```bash
sudo ./bin/install-nexus.sh --mode host --java-home /usr/lib/jvm/java-11
```

**优点：**
- 性能最佳
- 直接访问系统资源

### 启动服务

#### Docker 模式

```bash
cd /data/nexus

# 方式 1：使用启动脚本
sudo ./bin/startup.sh

# 方式 2：使用 docker-compose
docker-compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start nexus
```

#### 主机模式

```bash
# 使用启动脚本
/data/nexus/bin/startup.sh

# 使用 systemd
sudo systemctl start nexus
```

### 停止服务

#### Docker 模式

```bash
cd /data/nexus

# 方式 1：使用停止脚本
sudo ./bin/stop.sh

# 方式 2：使用 docker-compose
docker-compose down

# 方式 3：使用 systemd
sudo systemctl stop nexus
```

#### 主机模式

```bash
# 使用停止脚本
/data/nexus/bin/stop.sh

# 使用 systemd
sudo systemctl stop nexus
```

### 查看状态

#### Docker 模式

```bash
cd /data/nexus

# 查看服务状态
sudo ./bin/status.sh

# 查看容器状态
docker-compose ps

# 查看详细日志
docker-compose logs -f nexus
```

#### 主机模式

```bash
# 查看服务状态
/data/nexus/bin/status.sh

# 查看 systemd 状态
sudo systemctl status nexus

# 查看日志
tail -f /data/nexus/data/log/nexus.log
```

---

## 🎯 功能特性

| 功能 | 说明 |
|------|------|
| **Maven 仓库** | 中央仓库代理、私有仓库、仓库组 |
| **npm 仓库** | npm 包代理和私有仓库 |
| **Docker Registry** | Docker 镜像仓库（支持 v2） |
| **PyPI 仓库** | Python 包代理和私有仓库 |
| **NuGet 仓库** | .NET 包管理 |
| **RubyGems** | Ruby 包管理 |
| **Yum/Apt** | Linux 包仓库 |
| **Raw 仓库** | 任意文件存储 |
| **仓库组** | 多个仓库聚合访问 |
| **权限管理** | 基于角色的访问控制（RBAC） |
| **清理策略** | 自动清理旧版本和快照 |
| **备份恢复** | 数据备份和恢复功能 |

---

## 🔧 常用命令

### Maven 配置

```xml
<!-- settings.xml 配置 -->
<mirrors>
  <mirror>
    <id>nexus</id>
    <mirrorOf>*</mirrorOf>
    <url>http://localhost:8081/repository/maven-public/</url>
  </mirror>
</mirrors>

<servers>
  <server>
    <id>nexus-releases</id>
    <username>admin</username>
    <password>admin123</password>
  </server>
  <server>
    <id>nexus-snapshots</id>
    <username>admin</username>
    <password>admin123</password>
  </server>
</servers>
```

### Docker 配置

```bash
# 配置 Docker daemon（/etc/docker/daemon.json）
{
  "insecure-registries": ["localhost:8081"]
}

# 重启 Docker
systemctl restart docker

# 登录 Nexus Docker 仓库
docker login localhost:8081

# 推送镜像
docker tag myimage:latest localhost:8081/docker-local/myimage:latest
docker push localhost:8081/docker-local/myimage:latest

# 拉取镜像
docker pull localhost:8081/docker-local/myimage:latest
```

### npm 配置

```bash
# 配置 npm 仓库
npm config set registry http://localhost:8081/repository/npm-public/

# 登录
npm config set //localhost:8081/repository/npm-hosted/:_authToken=<token>

# 发布包
npm publish --registry http://localhost:8081/repository/npm-hosted/
```

### PyPI 配置

```bash
# 配置 pip（~/.pip/pip.conf）
[global]
index-url = http://localhost:8081/repository/pypi-public/simple/

# 发布包
twine upload -r nexus dist/*
```

### 备份与恢复

#### Docker 模式

```bash
# 备份数据
docker exec nexus tar czf /backup/nexus_backup.tar.gz /nexus-data

# 恢复数据
docker-compose down
docker run --rm -v /data/nexus:/nexus-data -v /backup:/backup \
  alpine tar xzf /backup/nexus_backup.tar.gz -C /nexus-data
docker-compose up -d
```

#### 主机模式

```bash
# 备份数据
tar czf /backup/nexus_backup.tar.gz /data/nexus/data

# 恢复数据
systemctl stop nexus
tar xzf /backup/nexus_backup.tar.gz -C /data/nexus
systemctl start nexus
```

### 系统管理

```bash
# 查看 Nexus 版本
# Web 界面：System -> About

# 检查磁盘空间
df -h /data/nexus

# 查看仓库大小
du -sh /data/nexus/data/*

# 清理旧版本
# Web 界面：Repository -> Cleanup Policies
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `NEXUS_PORT` | 访问端口 | `8081` |
| `NEXUS_VERSION` | Nexus 版本 | `3.65.0` |
| `ADMIN_PASSWORD` | admin 初始密码 | `admin123` |

### 目录结构

#### Docker 模式

```
nexus/
├── bin/
│   ├── install-nexus.sh     # 安装脚本
│   ├── uninstall-nexus.sh   # 卸载脚本
│   ├── startup.sh           # 启动脚本
│   ├── stop.sh              # 停止脚本
│   ├── status.sh            # 状态检查脚本
│   └── backup.sh            # 备份脚本
├── data/                    # Nexus 数据目录
├── nexus-data/              # Nexus 程序数据
├── docker-compose.yml       # Docker Compose 配置
└── .env                     # 环境变量配置
```

#### 主机模式

```
nexus/
├── bin/                     # 管理脚本
├── nexus/                   # Nexus 程序目录
├── data/                    # Nexus 数据目录
│   ├── blobstore/           # 仓库存储
│   ├── db/                  # 数据库
│   ├── etc/                 # 配置文件
│   └── log/                 # 日志目录
└── sonatype-work/           # 工作目录
```

### 系统要求

| 资源 | Docker 模式 | 主机模式 |
|------|------------|----------|
| CPU | 2 核 + | 2 核 + |
| 内存 | 2GB+ (推荐 4GB+) | 2GB+ (推荐 4GB+) |
| 磁盘 | 50GB+ | 50GB+ |
| Docker | 20.10+ | - |
| Java | - | JDK 11+ |

### JVM 配置

编辑 `$INSTALL_DIR/data/etc/jvm/java-opts`：

```
-Xms512m
-Xmx1g
-XX:MaxDirectMemorySize=512m
-Djava.util.prefs.userRoot=/data/nexus
```

---

## 🔍 故障排查

### Nexus 无法启动

#### Docker 模式

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :8081

# 3. 查看错误日志
docker-compose logs nexus

# 4. 检查磁盘空间
df -h

# 5. 检查内存
free -h

# 6. 重新创建容器
docker-compose down
docker-compose up -d
```

#### 主机模式

```bash
# 1. 检查 Java 版本
java -version

# 2. 查看日志
tail -f /data/nexus/data/log/nexus.log

# 3. 检查端口占用
lsof -i :8081

# 4. 检查磁盘空间
df -h

# 5. 检查权限
ls -la /data/nexus/

# 6. 重启 Nexus
/data/nexus/bin/nexus restart
```

### 无法访问 Web 界面

```bash
# 1. 检查服务状态
# Docker 模式
docker-compose ps

# 主机模式
systemctl status nexus

# 2. 测试连接
curl -I http://localhost:8081

# 3. 查看日志
# Docker 模式
docker-compose logs nexus

# 主机模式
tail -f /data/nexus/data/log/nexus.log

# 4. 重启服务
# Docker 模式
docker-compose restart

# 主机模式
/data/nexus/bin/nexus restart
```

### 内存不足

```bash
# 1. 查看内存使用
free -h

# 2. 调整 JVM 参数
# 编辑 $INSTALL_DIR/data/etc/jvm/java-opts
-Xms1g
-Xmx2g
-XX:MaxDirectMemorySize=1g

# 3. 重启 Nexus
# Docker 模式
docker-compose restart

# 主机模式
/data/nexus/bin/nexus restart
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
du -sh /data/nexus/data/*

# 2. 查看 blobstore 大小
du -sh /data/nexus/data/blobstore/*

# 3. 配置清理策略
# Web 界面：Repository -> Cleanup Policies

# 4. 手动清理旧版本
# Web 界面：Browse -> 选择仓库 -> 删除旧版本
```

### Docker 仓库无法连接

```bash
# 1. 检查 Docker daemon 配置
cat /etc/docker/daemon.json

# 2. 重启 Docker
systemctl restart docker

# 3. 测试连接
curl -I http://localhost:8081/v2/

# 4. 查看日志
docker-compose logs nexus | grep docker
```

### 忘记密码

```bash
# Docker 模式：重置 admin 密码
docker exec nexus cat /nexus-data/admin.password

# 主机模式：重置 admin 密码
cat /data/nexus/data/admin.password

# 使用临时密码登录后修改
```

---

## 📚 参考资源

- [Nexus Repository 官网](https://www.sonatype.com/products/nexus-repository)
- [Nexus 文档](https://help.sonatype.com/repomanager3)
- [Nexus GitHub](https://github.com/sonatype/nexus-public)
- [Nexus 社区](https://community.sonatype.com/)

---

**最后更新**: 2026 年 3 月 13 日

# Docker 容器管理

> Docker 容器编排和管理工具脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `colima-manager.sh` | Colima 安装/卸载管理脚本 | ✅ | ✅ |
| `install-docker-compose.sh` | Docker Compose 安装脚本 | ✅ | ✅ |
| `install-k8s.sh` | Kubernetes 安装脚本 | ✅ | ✅ |
| `backup.sh` | Docker Compose 备份脚本 | ✅ | ✅ |
| `load.sh` | Docker 镜像加载脚本 | ✅ | ✅ |
| `save-compose-images.sh` | Docker Compose 镜像保存脚本 | ✅ | ✅ |
| `search-docker-image-tags.sh` | Docker 镜像标签搜索脚本 | ✅ | ✅ |
| `setup-docker-proxy.sh` | Docker 镜像代理配置脚本 | ✅ | ✅ |

## 🚀 快速开始

### 安装 Docker Compose

```bash
cd docker
./install-docker-compose.sh
```

### 管理 Colima

```bash
cd docker
./colima-manager.sh
./colima-manager.sh uninstall
./colima-manager.sh uninstall --purge
```

### 安装 Kubernetes

```bash
cd docker
./install-k8s.sh
```

### 备份 Docker Compose

```bash
cd docker
./backup.sh [目标目录] [目标主机]
```

## 🔧 详细说明

### 核心脚本

#### install-docker-compose.sh - Docker Compose 安装

**功能**: 安装 Docker Compose 工具

**特性**:
- 自动下载最新版本
- 系统服务配置
- 用户权限配置
- 版本验证

#### colima-manager.sh - Colima 管理

**功能**: 安装、配置、卸载 Colima 容器运行时

**特性**:
- 安装 Colima、Docker CLI、Docker Compose
- 配置 CPU、内存、磁盘、运行时
- 配置 Docker context
- 支持卸载组件和可选清理 `~/.colima`

#### install-k8s.sh - Kubernetes 安装

**功能**: 安装 Kubernetes 集群

**特性**:
- 单节点集群
- 集群初始化
- 网络插件配置
- Dashboard 部署

#### backup.sh - 备份脚本

**功能**: 备份 Docker Compose 镜像和数据卷

**备份内容**:
- 镜像文件
- 数据卷
- 网络配置
- 容器配置

#### load.sh - 镜像加载

**功能**: 从 tar 文件加载 Docker 镜像

#### save-compose-images.sh - 镜像保存

**功能**: 保存 Docker Compose 所有镜像到 tar 文件

#### search-docker-image-tags.sh - 镜像标签搜索

**功能**: 搜索 Docker 镜像的所有可用标签

#### setup-docker-proxy.sh - 镜像代理

**功能**: 配置 Docker 镜像加速代理

## 🔗 相关链接

- [Docker 官方网站](https://www.docker.com/)
- [Kubernetes 官方网站](https://kubernetes.io/)
- [Docker Compose 文档](https://docs.docker.com/compose/)

## 📝 使用场景

- **容器部署**: Docker 容器化应用部署
- **镜像管理**: Docker 镜像的保存和加载
- **容器编排**: Docker Compose 多容器编排
- **集群管理**: Kubernetes 集群部署和管理

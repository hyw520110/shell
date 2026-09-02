# Rancher 容器管理平台

> Rancher Kubernetes 管理平台的安装和配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install-rancher.sh` | Rancher 安装脚本 | ✅ | ✅ |
| `startup.sh` | Rancher 启动脚本 | ✅ | ✅ |
| `stop.sh` | Rancher 停止脚本 | ✅ | ✅ |

## 🚀 快速开始

### 安装 Rancher

```bash
cd rancher
./install-rancher.sh

# 启动 Rancher
./startup.sh

# 停止 Rancher
./stop.sh
```

## 🔧 详细说明

### Rancher 功能

**Kubernetes 管理**:
- 集群部署和管理
- 应用部署和升级
- 用户权限管理
- 资源监控

**DevOps 功能**:
- CI/CD 集成
- 多集群管理
- 应用市场
- 模板管理

### 访问界面

- **Rancher 控制台**: http://localhost
- **默认用户**: admin
- **默认密码**: admin

## 🔗 相关链接

- [Rancher 官方网站](https://rancher.com/)
- [Rancher 文档](https://rancher.com/docs/)

## 📝 使用场景

- **Kubernetes 管理**: 统一管理多个 K8s 集群
- **应用部署**: 可视化部署和管理应用
- **团队协作**: 多用户、多项目管理
- **DevOps**: 自动化部署和运维

# PHP 开发环境

> PHP 编程语言和开发环境的安装配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install.sh` | PHP 安装脚本 | ❌ | ❌ |
| `uninstall.sh` | PHP 卸载脚本 | ❌ | ❌ |
| `docker-compose.yml` | Docker 部署配置 | - | - |
| `Dockerfile` | Docker 镜像构建配置 | - | - |

## 🚀 快速开始

### 安装 PHP

```bash
cd php
./install.sh
```

### 使用 Docker 部署

```bash
cd php
docker-compose up -d
```

## 🔧 详细说明

### install.sh - PHP 安装脚本

**功能**: 安装 PHP 运行环境和扩展

**PHP 特点**:
- 广泛的 Web 开发支持
- 丰富的扩展库
- 跨平台支持
- 强大的社区生态

**常用命令**:
```bash
# 查看 PHP 版本
php -v

# 运行 PHP 脚本
php script.php

# 启动内置 Web 服务器
php -S localhost:8000

# 检查 PHP 配置
php -i
```

### Docker 部署

**使用 Docker Compose**:
```bash
docker-compose up -d
```

**访问应用**:
- 应用端口: http://localhost:80
- PHP 版本: 根据配置确定

## 🔗 相关链接

- [PHP 官方网站](https://www.php.net/)
- [PHP 文档](https://www.php.net/docs.php)
- [Composer 包管理器](https://getcomposer.org/)

## 📝 使用场景

- **Web 开发**: 网站开发和 API 开发
- **后端开发**: 服务器端逻辑实现
- **脚本编程**: 自动化脚本和工具
- **微服务**: 微服务后端开发

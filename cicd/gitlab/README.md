# GitLab DevOps 平台

GitLab 是完整的 DevOps 平台，支持代码管理、CI/CD、代码审查、问题跟踪、容器 Registry 等功能。

> 官网：https://about.gitlab.com/

## 📋 目录

- [快速开始](#快速开始)
- [脚本说明](#脚本说明)
- [使用指南](#使用指南)
- [功能特性](#功能特性)
- [GitLab Runner](#gitlab-runner)
- [仓库统计工具](#仓库统计工具)
- [常用命令](#常用命令)
- [配置说明](#配置说明)
- [故障排查](#故障排查)

---

## 🚀 快速开始

### 一键安装

```bash
# 进入目录
cd gitlab

# 交互式安装（无参数，引导式配置）
sudo ./bin/install-gitlab.sh

# Docker 模式（推荐，资源占用少）
sudo ./bin/install-gitlab.sh --mode docker

# 主机模式（Omnibus 包安装，功能完整）
sudo ./bin/install-gitlab.sh --mode host

# 指定域名和端口
sudo ./bin/install-gitlab.sh --domain git.example.com --port 8080

# 配置自启动
sudo ./bin/install-gitlab.sh --auto-start
```

### 访问控制台

```
访问地址：http://<domain>:<port>
管理员账号：root
默认密码：gitlab123 (或安装时自定义)
```

> ⚠️ **首次登录后请立即修改管理员密码！**

### 卸载

```bash
# 交互式卸载
sudo ./bin/uninstall-gitlab.sh

# 强制卸载
sudo ./bin/uninstall-gitlab.sh --force

# 保留数据文件卸载
sudo ./bin/uninstall-gitlab.sh --keep-data
```

---

## 📝 脚本说明

### install-gitlab.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `--domain DOMAIN` | GitLab 访问域名 | `gitlab.local` |
| `--port PORT` | HTTP 端口 | `80` |
| `--ssh-port PORT` | SSH 端口 | `22` |
| `--root-password PWD` | root 初始密码 | `gitlab123` |
| `--email EMAIL` | 管理员邮箱 | `admin@example.com` |
| `--mode MODE` | 安装模式 (auto\|docker\|host) | `auto` |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-gitlab.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | GitLab 安装目录 | `/data/gitlab` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--mode MODE` | 卸载模式 (auto\|docker\|host) | `auto` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 安装模式说明

#### Docker Compose 模式（推荐）

使用 Docker 容器化部署，资源占用相对较少：

```bash
sudo ./bin/install-gitlab.sh --mode docker
```

**优点：**
- 部署简单，环境隔离
- 便于迁移和备份
- 不影响宿主机系统

**缺点：**
- 性能略低于主机模式
- 需要 Docker 环境

#### 主机模式（Omnibus 包）

使用官方 Omnibus 包直接安装：

```bash
sudo ./bin/install-gitlab.sh --mode host
```

**优点：**
- 性能最佳
- 功能完整
- 官方推荐方式

**缺点：**
- 需要较多系统资源
- 影响宿主机环境

### 启动服务

#### Docker 模式

```bash
cd /data/gitlab

# 方式 1：使用启动脚本
sudo ./bin/startup.sh

# 方式 2：使用 docker-compose
docker-compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start gitlab-docker
```

#### 主机模式

```bash
# 重新配置
gitlab-ctl reconfigure

# 重启
gitlab-ctl restart

# 使用 systemd
sudo systemctl start gitlab-runsvdir
```

### 停止服务

#### Docker 模式

```bash
cd /data/gitlab

# 方式 1：使用停止脚本
sudo ./bin/stop.sh

# 方式 2：使用 docker-compose
docker-compose down

# 方式 3：使用 systemd
sudo systemctl stop gitlab-docker
```

#### 主机模式

```bash
# 停止 GitLab
gitlab-ctl stop

# 使用 systemd
sudo systemctl stop gitlab-runsvdir
```

### 查看状态

#### Docker 模式

```bash
cd /data/gitlab

# 查看服务状态
sudo ./bin/status.sh

# 查看容器状态
docker-compose ps

# 查看详细日志
docker-compose logs -f gitlab
```

#### 主机模式

```bash
# 查看服务状态
gitlab-ctl status

# 查看进程状态
gitlab-ctl proc-status

# 查看日志
gitlab-ctl tail
```

---

## 🎯 功能特性

| 功能 | 说明 |
|------|------|
| **代码管理** | Git 仓库管理、分支管理、标签管理 |
| **CI/CD** | 内置 CI/CD 流水线、Auto DevOps |
| **代码审查** | Merge Request、代码对比、审批流程 |
| **问题跟踪** | Issue 管理、看板、里程碑 |
| **容器 Registry** | 内置 Docker 镜像仓库 |
| **包管理** | Maven、NPM、PyPI 等包管理 |
| **Wiki 文档** | 项目文档协作 |
| **监控** | 内置 Prometheus 监控 |
| **安全扫描** | SAST、DAST、依赖扫描 |
| **多租户** | 群组、项目、成员权限管理 |

---

## 🏃 GitLab Runner

Docker Compose 模式已内置 GitLab Runner 服务，随 GitLab 一起自动启动。

### 注册 Runner

安装完成后，需要在 GitLab 界面注册 Runner：

```bash
# 1. 获取 Runner Token
#    GitLab 界面 -> Admin Area -> CI/CD -> Runners -> New instance runner

# 2. 进入 Runner 容器注册
docker exec -it gitlab-runner gitlab-runner register

# 3. 按提示输入：
#    - GitLab instance URL: http://<gitlab-domain>:<port>/
#    - Registration token: <从界面获取的 token>
#    - Executor: docker
#    - Default Docker image: docker:24.0.5
```

### Runner 管理

```bash
# 查看已注册的 Runner
docker exec -it gitlab-runner gitlab-runner list

# 验证 Runner 状态
docker exec -it gitlab-runner gitlab-runner verify

# 查看 Runner 日志
docker logs gitlab-runner

# 重启 Runner
docker restart gitlab-runner
```

### Runner 数据持久化

Runner 配置持久化到宿主机 `./data/runner` 目录，重新部署不会丢失注册信息。

---

## 📊 仓库统计工具

`GitLabAPI.sh` 用于统计 GitLab 仓库信息，生成 HTML 格式报表。

### 功能

- 获取所有仓库元信息（名称、描述、分支、URL、创建时间、最新变更时间）
- 检测空置项目（无分支的仓库）
- 生成 HTML 格式报表并自动打包为 zip

### 用法

```bash
# 基本用法
./GitLabAPI.sh <GitLab_URL> <PRIVATE_TOKEN>

# 示例
./GitLabAPI.sh http://gitlab.example.com glpat-xxxxxxxxxxxx

# 交互式输入 Token（使用默认 URL）
./GitLabAPI.sh
```

### 输出

- `report/GitLab_result.html` — 有效项目报表（含分支详情）
- `report/unoccupied_projects_lists.html` — 空置项目报表
- `report/report-<时间戳>.zip` — 报表压缩包

---

## 🔧 常用命令

### Git 操作

```bash
# 克隆仓库
git clone http://<domain>:<port>/username/project.git

# 添加远程仓库
git remote add origin http://<domain>:<port>/username/project.git

# 推送代码
git push -u origin main

# 拉取代码
git pull origin main
```

### 备份与恢复

#### Docker 模式

```bash
# 创建备份
docker exec gitlab gitlab-rake gitlab:backup:create

# 查看备份
docker exec gitlab ls -la /var/opt/gitlab/backups/

# 恢复备份
docker exec -it gitlab bash
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
gitlab-rake gitlab:backup:restore BACKUP=timestamp
gitlab-ctl start
```

#### 主机模式

```bash
# 创建备份
gitlab-rake gitlab:backup:create

# 查看备份
ls -la /var/opt/gitlab/backups/

# 恢复备份
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
gitlab-rake gitlab:backup:restore BACKUP=timestamp
gitlab-ctl start
```

### 系统管理

```bash
# 检查 GitLab 状态
gitlab-rake gitlab:check

# 查看 GitLab 版本
gitlab-rake gitlab:env:info

# 清理旧数据
gitlab-rake gitlab:cleanup

# 重建授权
gitlab-rake gitlab:permissions:fix

# 清理仓库
gitlab-rake gitlab:git:fsck
```

### 用户管理

```bash
# 创建用户（GitLab Rails 控制台）
docker exec -it gitlab gitlab-rails console
# 或
gitlab-rails console

# 在控制台中执行：
user = User.new(
  name: 'New User',
  username: 'newuser',
  email: 'user@example.com',
  password: 'Password123',
  password_confirmation: 'Password123',
  admin: false
)
user.save!

# 重置 root 密码
docker exec -it gitlab gitlab-rails console
# 或
gitlab-rails console

# 在控制台中执行：
user = User.where(id: 1).first
user.password = 'NewPassword123'
user.password_confirmation = 'NewPassword123'
user.save!
```

### 邮件配置

```bash
# 编辑 GitLab 配置
# Docker 模式：编辑 $INSTALL_DIR/data/config/gitlab.rb
# 主机模式：编辑 /etc/gitlab/gitlab.rb

# 添加邮件配置：
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.example.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "gitlab@example.com"
gitlab_rails['smtp_password'] = "password"
gitlab_rails['smtp_domain'] = "example.com"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true

# 重新配置
gitlab-ctl reconfigure

# 测试邮件
gitlab-rails console
Notify.test_email('admin@example.com', 'Test Subject', 'Test Body').deliver_now
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GITLAB_DOMAIN` | GitLab 访问域名 | `gitlab.local` |
| `GITLAB_PORT` | HTTP 端口 | `80` |
| `GITLAB_SSH_PORT` | SSH 端口 | `22` |
| `GITLAB_ROOT_PASSWORD` | root 初始密码 | `gitlab123` |
| `GITLAB_ROOT_EMAIL` | 管理员邮箱 | `admin@example.com` |
| `GITLAB_VERSION` | GitLab 版本 | `16.6.0` |

### 目录结构

#### Docker 模式

```
gitlab/
├── bin/
│   ├── install-gitlab.sh    # 安装脚本（支持交互式和命令行参数）
│   ├── uninstall-gitlab.sh  # 卸载脚本
│   ├── startup.sh           # 启动脚本
│   ├── stop.sh              # 停止脚本
│   └── status.sh            # 状态检查脚本
├── data/
│   ├── config/              # GitLab 配置
│   ├── logs/                # GitLab 日志
│   ├── data/                # GitLab 数据
│   └── runner/              # GitLab Runner 配置
├── docker-compose.yml       # Docker Compose 配置（含 GitLab + Runner）
├── GitLabAPI.sh             # 仓库统计工具
└── .env                     # 环境变量配置
```

#### 主机模式

```
/etc/gitlab/                 # 配置文件
/var/opt/gitlab/             # 数据目录
/var/log/gitlab/             # 日志目录
/opt/gitlab/                 # 程序目录
```

### 系统要求

| 资源 | Docker 模式 | 主机模式 |
|------|------------|----------|
| CPU | 4 核 + | 4 核 + |
| 内存 | 4GB+ (推荐 8GB+) | 4GB+ (推荐 8GB+) |
| 磁盘 | 50GB+ | 50GB+ |
| Docker | 20.10+ | - |

### 端口说明

| 端口 | 用途 |
|------|------|
| `80` | HTTP Web 访问 |
| `443` | HTTPS Web 访问（可选） |
| `22` | SSH Git 操作 |

---

## 🔍 故障排查

### GitLab 无法启动

#### Docker 模式

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :80

# 3. 查看错误日志
docker-compose logs gitlab

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
# 1. 检查服务状态
gitlab-ctl status

# 2. 查看日志
gitlab-ctl tail

# 3. 重新配置
gitlab-ctl reconfigure

# 4. 检查系统资源
free -h
df -h

# 5. 重启 GitLab
gitlab-ctl restart
```

### 无法访问 Web 界面

```bash
# 1. 检查服务状态
# Docker 模式
docker-compose ps

# 主机模式
gitlab-ctl status

# 2. 测试连接
curl -I http://localhost:80

# 3. 查看 Nginx 日志
# Docker 模式
docker exec gitlab tail -f /var/log/gitlab/nginx/gitlab_access.log

# 主机模式
tail -f /var/log/gitlab/nginx/gitlab_access.log

# 4. 重启 GitLab
# Docker 模式
docker-compose restart

# 主机模式
gitlab-ctl restart
```

### Git SSH 连接失败

```bash
# 1. 测试 SSH 连接
ssh -T -p 22 git@<domain>

# 2. 检查 SSH 端口
netstat -tlnp | grep 22

# 3. 查看 SSH 日志
# Docker 模式
docker exec gitlab tail -f /var/log/gitlab/gitlab-rails/production.log

# 主机模式
tail -f /var/log/gitlab/gitlab-rails/production.log

# 4. 重启 GitLab
gitlab-ctl restart
```

### CI/CD Runner 无法连接

```bash
# 1. 检查 Runner 状态
# Docker 模式
docker exec gitlab gitlab-rake gitlab:runner:check

# 主机模式
gitlab-rake gitlab:runner:check

# 2. 查看 Runner 日志
# 在 Runner 机器上查看

# 3. 重新注册 Runner
# GitLab 界面：Admin -> Runners -> 注册新 Runner

# 4. 检查网络连通性
curl http://<gitlab-domain>:<port>/
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
# Docker 模式
du -sh /data/gitlab/data/*

# 主机模式
du -sh /var/opt/gitlab/*

# 2. 清理旧备份
# Docker 模式
docker exec gitlab find /var/opt/gitlab/backups -name "*.tar" -mtime +30 -delete

# 主机模式
find /var/opt/gitlab/backups -name "*.tar" -mtime +30 -delete

# 3. 清理旧日志
# Docker 模式
docker exec gitlab gitlab-ctl logger-rotate

# 主机模式
gitlab-ctl logger-rotate

# 4. 清理仓库
gitlab-rake gitlab:git:fsck
```

### 邮件发送失败

```bash
# 1. 测试邮件配置
gitlab-rails console
Notify.test_email('admin@example.com', 'Test', 'Body').deliver_now

# 2. 查看邮件日志
# Docker 模式
docker exec gitlab tail -f /var/log/gitlab/postfix/log

# 主机模式
tail -f /var/log/gitlab/postfix/log

# 3. 检查 SMTP 配置
# 编辑 gitlab.rb 文件，确认 SMTP 配置正确

# 4. 重新配置
gitlab-ctl reconfigure
```

---

## 📚 参考资源

- [GitLab 官网](https://about.gitlab.com/)
- [GitLab 文档](https://docs.gitlab.com/)
- [GitLab GitHub](https://github.com/gitlabhq/gitlabhq)
- [GitLab 社区](https://forum.gitlab.com/)

---

**最后更新**: 2026 年 5 月 18 日

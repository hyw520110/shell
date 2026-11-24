# Harness

开源的 CI/CD 和 DevOps 平台，支持流水线自动化、代码托管、Gitspaces 云端开发环境和 Artifact 注册表。

## 项目信息

- **官网**: https://developer.harness.io
- **GitHub**: https://github.com/harness/harness
- **Docker Hub**: https://hub.docker.com/r/harness/harness

## 主要功能

| 功能 | 说明 |
|------|------|
| **CI/CD 流水线** | 构建、测试、部署自动化 |
| **代码托管** | 完整的 Git 仓库管理 |
| **Gitspaces** | 云端开发环境 |
| **Artifact 注册表** | 容器镜像和包管理 |

## 快速开始

### 方式一：安装脚本（推荐）

```bash
# 安装并启动
~/workspace/shell/cicd/harness/install-harness.sh install

# 常用命令
~/workspace/shell/cicd/harness/install-harness.sh start    # 启动
~/workspace/shell/cicd/harness/install-harness.sh stop     # 停止
~/workspace/shell/cicd/harness/install-harness.sh restart  # 重启
~/workspace/shell/cicd/harness/install-harness.sh logs      # 查看日志
~/workspace/shell/cicd/harness/install-harness.sh status    # 查看状态
```

### 方式二：Docker Compose

```bash
cd ~/workspace/shell/cicd/harness
docker-compose up -d
```

### 方式三：直接运行 Docker

```bash
docker run -d \
  --name harness \
  --restart always \
  -p 3000:3000 \
  -p 3022:3022 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/harness-data:/data \
  harness/harness
```

## 访问信息

| 服务 | 地址 |
|------|------|
| Web UI | http://localhost:3000 |
| API | http://localhost:3000/api/v1 |
| Swagger | http://localhost:3000/swagger |

**默认账号**:
- 用户名: `admin`
- 密码: `changeit`

## 数据位置

- 数据目录: `~/.harness/`
- Docker 卷: `harness-data`

## Docker Socket 配置

Harness 流水线需要在 Docker 容器内运行构建步骤。根据您的 Docker 环境，可能需要配置 socket 位置：

| Docker 环境 | Socket 位置 | 配置方式 |
|-------------|-------------|----------|
| Docker Desktop | `/var/run/docker.sock` | 默认，无需配置 |
| Rancher Desktop | `~/.rd/docker.sock` | 创建软链接 |
| Colima | `~/.colima/default/docker.sock` | 创建软链接 |
| Linux 原生 | `/var/run/docker.sock` | 默认，无需配置 |

### 创建软链接（如果需要）

```bash
# Rancher Desktop
sudo ln -sf ~/.rd/docker.sock /var/run/docker.sock

# Colima
sudo ln -sf ~/.colima/default/docker.sock /var/run/docker.sock
```

## CLI 使用

```bash
# 登录
./gitness login
# 用户名: admin
# 密码: changeit

# 生成 PAT
./gitness user pat "my-pat-uid" 2592000

# 使用 API
curl http://localhost:3000/api/v1/user \
  -H "Authorization: Bearer $TOKEN"
```

## 与 Drone 的关系

Harness 开源版是 Drone 的下一代产品。Drone 专注于持续集成，Harness 在此基础上增加了：
- 源代码托管
- Gitspaces 云端开发环境
- Artifact 注册表

Drone 的代码库保留在 [`drone`](https://github.com/harness/harness/tree/drone) 分支。

## 本地开发

```bash
# 克隆仓库
git clone https://github.com/harness/harness.git
cd harness

# 安装依赖
make dep
make tools

# 构建前端
cd web && yarn install && yarn build && cd ..

# 构建后端
make build

# 运行服务
./gitness server .local.env
```

## 卸载

```bash
# 使用安装脚本卸载
~/workspace/shell/cicd/harness/install-harness.sh uninstall

# 或手动卸载
docker stop harness
docker rm harness
rm -rf ~/.harness
```

## 文档

- [官方文档](https://developer.harness.io/docs/open-source)
- [API 文档](http://localhost:3000/swagger)
- [Drone 文档](https://docs.drone.io/)

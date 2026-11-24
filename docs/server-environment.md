# 开发服务器环境

开发服务器环境所需软件清单及安装时间估算。

## 当前已有软件

| 类别 | 软件 | 数量 | 状态 |
|------|------|------|------|
| 数据库 | MySQL、PostgreSQL、MongoDB、Redis、Neo4j、TiDB、BanyanDB | 7个 | ✅ 已配置 |
| 消息队列 | RocketMQ、Kafka、ActiveMQ、Canal | 4个 | ✅ 已配置 |
| 配置中心 | Nacos | 1个 | ✅ 已配置 |
| 监控 | Prometheus、Grafana、SkyWalking | 3个 | ✅ 已配置 |
| 网关 | Sentinel、Dubbo-Admin | 2个 | ✅ 已配置 |
| CI/CD | Jenkins、GitLab、Gitea、Spug | 4个 | ✅ 已配置 |
| 远程访问 | FRP、OpenVPN、Shadowsocks、RustDesk | 4个 | ✅ 已配置 |
| 容器 | Docker、Kubernetes、Rancher | 3个 | ✅ 已配置 |

## 推荐补充软件

| 软件 | 用途 | 优先级 | 安装时间 | 下载来源 |
|------|------|--------|----------|----------|
| **团队协作** |
| Mattermost | 团队沟通 (开源) | 中 | 15分钟 | 官网/Docker |
| Confluence | 知识库 | 中 | 20分钟 | Atlassian 官网 |
| Jira | 项目管理 | 中 | 20分钟 | Atlassian 官网 |
| **远程桌面** |
| Apache Guacamole | 浏览器远程桌面 | 中 | 15分钟 | 官网/Docker |
| ToDesk | 远程桌面 | 中 | 5分钟 | 官网 (已下载) |
| **文件同步** |
| Nextcloud | 私有云盘 | 中 | 20分钟 | 官网/Docker |
| Syncthing | P2P 文件同步 | 低 | 10分钟 | 官网 |
| **代码审查** |
| SonarQube | 代码质量 | 高 | 15分钟 | 官网/Docker |
| **API 文档** |
| Swagger UI | API 文档 | 高 | 10分钟 | Docker |
| YApi | API 管理平台 | 中 | 15分钟 | GitHub/Docker |
| **其他** |
| Harbor | 镜像仓库 | 中 | 20分钟 | 官网 (已配置) |
| Nexus | Maven 仓库 | 中 | 15分钟 | 官网 (已配置) |
| XXL-Job | 分布式任务调度 | 中 | 10分钟 | GitHub (已配置) |

## 安装时间汇总

| 优先级 | 软件数量 | 预估时间 |
|--------|----------|----------|
| 高优先级 | 2个 | 25分钟 |
| 中优先级 | 10个 | 150分钟 |
| 低优先级 | 1个 | 10分钟 |
| **总计** | **13个** | **约 3 小时** |

## 快速安装命令

```bash
# 团队协作
./server/install-mattermost.sh    # 如需添加
./server/install-confluence.sh    # 如需添加

# 代码质量
./cicd/install-sonarqube.sh       # 如需添加

# API 文档
./server/install-yapi.sh          # 如需添加

# 远程桌面 (已下载)
# ToDesk: 双击安装 ~/Downloads/ToDesk_4.8.8.9.pkg
```

## 已下载可用软件

从 `~/Downloads` 目录可直接安装：

| 软件 | 文件名 | 用途 |
|------|--------|------|
| ToDesk | ToDesk_4.8.8.9.pkg | 远程桌面 |
| Tailscale | Tailscale-1.98.1-macos.pkg | 异地组网 |
| Chrome | googlechrome.dmg | 浏览器 |

## 服务端口速查

| 服务 | 默认端口 | 访问地址 |
|------|----------|----------|
| Nacos | 8848 | http://localhost:8848/nacos |
| Prometheus | 9090 | http://localhost:9090 |
| Grafana | 3000 | http://localhost:3000 |
| Jenkins | 8080 | http://localhost:8080 |
| GitLab | 8081 | http://localhost:8081 |
| SonarQube | 9000 | http://localhost:9000 (如需添加) |

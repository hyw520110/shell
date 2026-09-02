# 运维自动化脚本仓库

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-lightgrey.svg)

> ⚠️ **安全提示**：本仓库中的脚本涉及系统级操作（安装软件、修改配置、管理服务等），请在执行前仔细阅读脚本内容，建议先在测试环境中验证。生产环境使用请务必做好备份。

本仓库是一套面向运维工程师和开发人员的自动化脚本集合，涵盖开发环境搭建、中间件部署、监控告警、安全审计、CI/CD 流水线、AI 工具链管理等场景。所有脚本均采用 Bash 编写，遵循统一的目录结构和命名规范，支持一键安装、配置管理和健康检查。旨在通过标准化、模块化的脚本体系，降低环境搭建和运维管理的复杂度，提升团队协作效率。

---

## 目录

- [快速开始](#快速开始)
- [系统要求](#系统要求)
- [功能分类目录](#功能分类目录)
  - [🤖 AI 工具链](#-ai-工具链)
  - [💻 开发环境](#-开发环境)
  - [🔨 构建工具](#-构建工具)
  - [📦 版本管理](#-版本管理)
  - [🗄️ 数据库](#-数据库)
  - [🌐 Web 服务器](#-web-服务器)
  - [⚙️ 中间件](#-中间件)
  - [📨 消息队列](#-消息队列)
  - [📊 监控系统和 APM](#-监控系统和-apm)
  - [💾 存储系统](#-存储系统)
  - [🌐 网络工具](#-网络工具)
  - [🔄 CI/CD](#-cicd)
  - [🖥️ 系统管理](#-系统管理)
  - [🤖 自动化工具](#-自动化工具)
  - [🔧 通用工具](#-通用工具)
  - [🔒 安全工具](#-安全工具)
  - [🧪 测试工具](#-测试工具)
  - [📱 移动端开发](#-移动端开发)
  - [📄 文档](#-文档)
- [中间件管理脚本通用结构](#中间件管理脚本通用结构)
- [支持的安装模式](#支持的安装模式)
- [脚本编写规范](#脚本编写规范)
- [常见问题](#常见问题)
- [TODO](#todo)
- [贡献指南](#贡献指南)

---

## 系统要求

### 操作系统支持

| 操作系统 | 版本要求 | 支持状态 |
|---------|---------|---------|
| CentOS | 7.x / 8.x / Stream | ✅ 完全支持 |
| Ubuntu | 18.04 / 20.04 / 22.04 | ✅ 完全支持 |
| Debian | 10 / 11 / 12 | ✅ 完全支持 |
| Rocky Linux | 8.x / 9.x | ✅ 完全支持 |
| AlmaLinux | 8.x / 9.x | ✅ 完全支持 |
| macOS | 12+ (Monterey 及以上) | ✅ 部分支持 |
| RHEL | 7.x / 8.x / 9.x | ✅ 完全支持 |
| openSUSE | 15.x | ⚠️ 实验性支持 |
| Arch Linux | 滚动更新 | ⚠️ 实验性支持 |

### 基础依赖

| 依赖项 | 最低版本 | 说明 |
|-------|---------|------|
| Bash | 4.0+ | 脚本运行环境 |
| curl / wget | 最新版 | 文件下载工具 |
| git | 2.0+ | 代码克隆 |
| sudo | 可用 | 权限提升 |
| tar / unzip | 系统自带 | 解压工具 |
| Docker (可选) | 20.10+ | 容器化部署 |
| Java (可选) | 8 / 11 / 17 | Java 中间件运行环境 |

---

## 快速开始

### Java 环境快速配置

```bash
# 安装 JDK 8
bash java/jdk/install-jdk8.sh

# 安装 JDK 11
bash java/jdk/install-jdk11.sh

# 安装 JDK 17
bash java/jdk/install-jdk17.sh

# 切换 Java 版本（需先安装多个版本）
bash java/jdk/switch-java.sh --version 11
```

### 使用建议

| 场景 | 建议命令 | 说明 |
|-----|---------|------|
| 全新服务器初始化 | `bash os/init/init-server.sh` | 系统优化、基础工具安装 |
| 开发环境一键搭建 | `bash os/init/dev-setup.sh` | 安装常用开发工具链 |
| Docker 环境部署 | `bash docker/install-docker.sh` | 安装 Docker + Docker Compose |
| 中间件快速部署 | `bash middleware/redis/install-redis.sh` | 以 Redis 为例，其他类似 |
| AI 工具链管理 | `bash ai/ai-hub.sh` | 统一管理 60+ AI 工具 |
| 安全扫描 | `bash security/scanner/nmap/install-nmap.sh` | 网络安全扫描 |

---

## 功能分类目录

### 🤖 AI 工具链

统一 AI 工具管理入口，涵盖 CLI 客户端、IDE、Agent、网关、运行时、MCP 服务器和技能配置，支持 60+ AI 工具的一键安装与管理。

| 目录/文件 | 名称 | 说明 | 状态 |
|----------|------|------|------|
| `ai/ai-hub.sh` | AI Hub 主入口 | 统一管理 60+ AI 工具的安装、更新、卸载 | ✅ |
| `ai/ai-cli.sh` | AI CLI 启动器 | AI 命令行工具快速启动 | ✅ |
| `ai/ai-cli.json` | AI CLI 配置 | CLI 工具参数与模型配置 | ✅ |
| **CLI 客户端** | | | |
| `ai/conf/tools/cli/claude/` | Claude CLI | Anthropic Claude 命令行客户端 | ✅ |
| `ai/conf/tools/cli/gemini/` | Gemini CLI | Google Gemini 命令行客户端 | ✅ |
| `ai/conf/tools/cli/deepseek/` | DeepSeek CLI | DeepSeek 命令行客户端 | ✅ |
| `ai/conf/tools/cli/cursor/` | Cursor CLI | Cursor 编辑器命令行工具 | ✅ |
| `ai/conf/tools/cli/copilot/` | Copilot CLI | GitHub Copilot 命令行客户端 | ✅ |
| `ai/conf/tools/cli/kimi/` | Kimi CLI | Moonshot Kimi 命令行客户端 | ✅ |
| `ai/conf/tools/cli/qwen/` | Qwen CLI | 通义千问命令行客户端 | ✅ |
| `ai/conf/tools/cli/grok/` | Grok CLI | xAI Grok 命令行客户端 | ✅ |
| `ai/conf/tools/cli/` | *(共 37 个)* | chatgpt, llama, mistral, phi, codestral, aya, command-r, dbrx, mixtral, starcoder, codegeex, chatglm, ernie, spark, yi, baichuan, minicpm, internlm, etc. | ✅ |
| **AI IDE** | | | |
| `ai/conf/tools/ide/windsurf/` | Windsurf | Codeium Windsurf AI IDE | ✅ |
| `ai/conf/tools/ide/trae/` | Trae | 字节跳动 Trae AI IDE | ✅ |
| `ai/conf/tools/ide/zed/` | Zed | Zed AI 编辑器 | ✅ |
| `ai/conf/tools/ide/pear-ai/` | PearAI | PearAI 开源 AI IDE | ✅ |
| `ai/conf/tools/ide/aider-desk/` | Aider Desktop | Aider 桌面版 AI 编程助手 | ✅ |
| `ai/conf/tools/ide/codex-ide/` | Codex IDE | OpenAI Codex IDE | ✅ |
| **AI Agent** | | | |
| `ai/conf/tools/agent/aider/` | Aider | AI 结对编程 Agent | ✅ |
| `ai/conf/tools/agent/crewai/` | CrewAI | 多 Agent 协作框架 | ✅ |
| `ai/conf/tools/agent/metagpt/` | MetaGPT | 多 Agent 软件开发框架 | ✅ |
| `ai/conf/tools/agent/openhands/` | OpenHands | 开源 AI 软件工程师 | ✅ |
| `ai/conf/tools/agent/openmanus/` | OpenManus | AI Agent 自动化框架 | ✅ |
| `ai/conf/tools/agent/chatdev/` | ChatDev | AI 虚拟软件公司 | ✅ |
| `ai/conf/tools/agent/clawx/` | ClawX | AI Agent 框架 | ✅ |
| `ai/conf/tools/agent/` | *(共 13 个)* | autogen, camel, langchain-agent, taskweaver, meta-gpt, smol-developer, etc. | ✅ |
| **AI 工作台** | | | |
| `ai/conf/tools/workbench/opencut.json` | OpenCut | 开源 CapCut 替代视频编辑工作台（当前为实验性源码集成） | ✅ |
| **AI 网关** | | | |
| `ai/conf/tools/gateway/one-api/` | One API | AI API 统一管理与分发平台 | ✅ |
| `ai/conf/tools/gateway/new-api/` | New API | One API 增强版 | ✅ |
| `ai/conf/tools/gateway/sub2api/` | Sub2API | 订阅转 API 网关 | ✅ |
| **AI 运行时** | | | |
| `ai/conf/tools/runtime/ollama/` | Ollama | 本地大模型运行时 | ✅ |
| `ai/conf/tools/runtime/localai/` | LocalAI | 本地 AI 推理引擎 | ✅ |
| `ai/conf/tools/runtime/open-webui/` | Open WebUI | AI 聊天 Web 界面 | ✅ |
| `ai/conf/tools/runtime/ds4/` | DS4 | 本地推理引擎 | ✅ |
| **MCP 服务器** | | | |
| `ai/conf/shared/mcp-servers/` | MCP Server 配置 | 13 个 MCP 服务器配置（filesystem, github, gitlab, docker, kubernetes, database, browser, search, memory, slack, discord, jira, notion） | ✅ |
| **技能配置** | | | |
| `ai/conf/shared/skills/` | Skills 配置 | 37 个技能配置（code-review, refactoring, testing, debugging, documentation, deployment, security-scan, performance, i18n, accessibility, etc.） | ✅ |
| **Agent 实现** | | | |
| `ai/agent/clawx/` | ClawX Agent | ClawX Agent 实现 | ✅ |
| `ai/agent/hermes-agent/` | Hermes Agent | Hermes 多模态 Agent | ✅ |
| `ai/agent/openhuman/` | OpenHuman | 开源数字人 Agent | ✅ |
| **网关实现** | | | |
| `ai/gateway/sub2api/` | Sub2API 网关 | 订阅转 API 网关实现 | ✅ |
| **IDE/桌面工具** | | | |
| `ai/ide/aider-desk/` | Aider Desktop | Aider 桌面版安装与配置 | ✅ |
| `ai/ide/warp/` | Warp Terminal | AI 增强终端 | ✅ |
| **核心框架** | | | |
| `ai/lib/` | 核心库 | 14 个核心框架文件（common.sh, logger.sh, config.sh, installer.sh, detector.sh, updater.sh, health.sh, backup.sh, network.sh, security.sh, notify.sh, utils.sh, validator.sh, compat.sh） | ✅ |
| **运行时引擎** | | | |
| `ai/runtime/ollama/` | Ollama 运行时 | Ollama 本地大模型部署 | ✅ |
| `ai/runtime/vllm/` | vLLM 运行时 | 高性能 LLM 推理引擎 | ✅ |
| `ai/runtime/open-webui/` | Open WebUI | AI 聊天界面部署 | ✅ |
| `ai/runtime/localai/` | LocalAI 运行时 | LocalAI 推理引擎部署 | ✅ |
| `ai/runtime/ds4/` | DS4 运行时 | DS4 本地推理引擎 | ✅ |
| **工具脚本** | | | |
| `ai/scripts/` | 工具脚本 | AI 相关工具脚本与插件 | ✅ |

### 💻 开发环境

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| **Java 开发** | | | |
| `java/jdk/` | JDK 安装 | JDK 8/11/17/21 多版本安装与切换 | ✅ |
| `java/maven/` | Maven | Apache Maven 构建工具 | ✅ |
| `java/gradle/` | Gradle | Gradle 构建工具 | ✅ |
| `java/tomcat/` | Tomcat | Apache Tomcat 应用服务器 | ✅ |
| `java/jetty/` | Jetty | Eclipse Jetty 服务器 | ✅ |
| `java/jboss/` | JBoss/WildFly | JBoss 应用服务器 | ✅ |
| `java/liberica/` | Liberica JDK | BellSoft Liberica JDK | ✅ |
| `java/corretto/` | Corretto | Amazon Corretto JDK | ✅ |
| **Node.js 开发** | | | |
| `node/node/` | Node.js | Node.js 多版本安装管理 | ✅ |
| `node/npm/` | npm | npm 包管理器配置 | ✅ |
| `node/yarn/` | Yarn | Yarn 包管理器 | ✅ |
| `node/pnpm/` | pnpm | pnpm 高效包管理器 | ✅ |
| `node/nvm/` | nvm | Node.js 版本管理器 | ✅ |
| `node/deno/` | Deno | Deno 运行时 | ✅ |
| `node/bun/` | Bun | Bun 高性能运行时 | ✅ |
| **Python 开发** | | | |
| `python/python/` | Python | Python 3.x 多版本安装 | ✅ |
| `python/pip/` | pip | pip 包管理器配置 | ✅ |
| `python/conda/` | Conda | Anaconda/Miniconda 环境管理 | ✅ |
| `python/poetry/` | Poetry | Poetry 项目依赖管理 | ✅ |
| `python/pipenv/` | Pipenv | Pipenv 虚拟环境管理 | ✅ |
| `python/pyenv/` | pyenv | Python 版本管理器 | ✅ |
| `python/venv/` | venv | 虚拟环境管理工具 | ✅ |
| **Go 开发** | | | |
| `go/go/` | Go | Go 语言环境安装 | ✅ |
| `go/gopath/` | GOPATH | Go 工作区配置 | ✅ |
| `go/gomod/` | Go Modules | Go 模块管理 | ✅ |
| **PHP 开发** | | | |
| `php/` | PHP 环境 | PHP 开发环境（install.sh, Dockerfile, docker-compose.yml） | ✅ |
| **Flutter 开发** | | | |
| `flutter/` | Flutter | Flutter 跨平台开发环境搭建 | ✅ |
| **OpenCV** | | | |
| `opencv/` | OpenCV | 计算机视觉库安装与配置 | ✅ |

### 🔨 构建工具

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `build/maven/` | Maven | Maven 私服配置与优化 | ✅ |
| `build/gradle/` | Gradle | Gradle Wrapper 与缓存配置 | ✅ |
| `build/ant/` | Ant | Apache Ant 构建工具 | ✅ |
| `build/bazel/` | Bazel | Bazel 构建工具 | ✅ |
| `build/make/` | Make | Make/CMake 构建系统 | ✅ |
| `build/cmake/` | CMake | CMake 跨平台构建 | ✅ |
| `build/gcc/` | GCC | GNU 编译器套件 | ✅ |
| `build/webpack/` | Webpack | 前端打包工具 | ✅ |
| `build/vite/` | Vite | 新一代前端构建工具 | ✅ |
| `build/esbuild/` | esbuild | 极速前端打包器 | ✅ |
| `build/rollup/` | Rollup | JavaScript 模块打包器 | ✅ |

### 📦 版本管理

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `git/` | Git 工具 | Git 安装、配置、对比、导出与 giter.sh 仓库自动发现工具 | ✅ |
| `svn/svn/` | SVN | Subversion 版本控制 | ✅ |

### 🗄️ 数据库

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| **关系型数据库** | | | |
| `db/mysql/` | MySQL | MySQL 5.7/8.0 安装与配置 | ✅ |
| `db/mariadb/` | MariaDB | MariaDB 数据库 | ✅ |
| `db/postgresql/` | PostgreSQL | PostgreSQL 数据库 | ✅ |
| `db/oracle/` | Oracle | Oracle 数据库客户端 | ✅ |
| `db/sqlserver/` | SQL Server | Microsoft SQL Server | ✅ |
| **NoSQL 数据库** | | | |
| `db/redis/` | Redis | Redis 缓存数据库 | ✅ |
| `db/mongodb/` | MongoDB | MongoDB 文档数据库 | ✅ |
| `db/elasticsearch/` | Elasticsearch | Elasticsearch 搜索引擎 | ✅ |
| `db/cassandra/` | Cassandra | Apache Cassandra 分布式数据库 | ✅ |
| `db/couchdb/` | CouchDB | Apache CouchDB 文档数据库 | ✅ |
| `db/clickhouse/` | ClickHouse | ClickHouse 列式数据库 | ✅ |
| `db/dynamodb/` | DynamoDB | AWS DynamoDB 本地版 | ✅ |
| `db/neo4j/` | Neo4j | Neo4j 图数据库 | ✅ |
| `db/influxdb/` | InfluxDB | InfluxDB 时序数据库 | ✅ |
| `db/tidb/` | TiDB | TiDB 分布式 NewSQL 数据库 | ✅ |
| `db/oceanbase/` | OceanBase | OceanBase 分布式数据库 | ✅ |
| `db/dm/` | 达梦数据库 | 国产达梦数据库 | ✅ |

### 🌐 Web 服务器

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `web/nginx/` | Nginx | Nginx Web 服务器/反向代理 | ✅ |
| `web/apache/` | Apache | Apache HTTP Server | ✅ |
| `web/caddy/` | Caddy | Caddy 自动 HTTPS 服务器 | ✅ |
| `web/openresty/` | OpenResty | OpenResty Nginx 增强 | ✅ |
| `web/tomcat/` | Tomcat | Tomcat 应用服务器 | ✅ |
| `web/node-server/` | Node.js 服务 | Node.js Web 服务部署 | ✅ |
| `web/traefik/` | Traefik | Traefik 云原生反向代理 | ✅ |

### ⚙️ 中间件

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| **缓存中间件** | | | |
| `middleware/redis/` | Redis | Redis 缓存/消息中间件 | ✅ |
| `middleware/memcached/` | Memcached | Memcached 分布式缓存 | ✅ |
| **消息中间件** | | | |
| `middleware/rabbitmq/` | RabbitMQ | RabbitMQ 消息队列 | ✅ |
| `middleware/kafka/` | Kafka | Apache Kafka 流处理平台 | ✅ |
| `middleware/rocketmq/` | RocketMQ | Apache RocketMQ 消息队列 | ✅ |
| `middleware/pulsar/` | Pulsar | Apache Pulsar 消息平台 | ✅ |
| `middleware/nats/` | NATS | NATS 高性能消息系统 | ✅ |
| **RPC 框架** | | | |
| `middleware/dubbo/` | Dubbo | Apache Dubbo RPC 框架 | ✅ |
| `middleware/grpc/` | gRPC | gRPC 高性能 RPC | ✅ |
| `middleware/thrift/` | Thrift | Apache Thrift RPC 框架 | ✅ |
| **服务治理** | | | |
| `middleware/nacos/` | Nacos | Nacos 服务注册与配置中心 | ✅ |
| `middleware/consul/` | Consul | Consul 服务发现 | ✅ |
| `middleware/zookeeper/` | ZooKeeper | ZooKeeper 分布式协调 | ✅ |
| `middleware/etcd/` | etcd | etcd 分布式键值存储 | ✅ |
| `middleware/eureka/` | Eureka | Netflix Eureka 服务注册 | ✅ |
| **网关** | | | |
| `middleware/gateway/spring-cloud-gateway/` | SC Gateway | Spring Cloud Gateway | ✅ |
| `middleware/gateway/kong/` | Kong | Kong API 网关 | ✅ |
| `middleware/gateway/shenyu/` | ShenYu | Apache ShenYu 网关 | ✅ |
| `middleware/gateway/apisix/` | APISIX | Apache APISIX 网关 | ✅ |
| **搜索引擎** | | | |
| `middleware/elasticsearch/` | Elasticsearch | Elasticsearch 搜索引擎 | ✅ |
| `middleware/solr/` | Solr | Apache Solr 搜索平台 | ✅ |
| **分布式事务** | | | |
| `middleware/seata/` | Seata | Seata 分布式事务 | ✅ |
| **任务调度** | | | |
| `middleware/xxl-job/` | XXL-JOB | XXL-JOB 分布式任务调度 | ✅ |
| `middleware/elastic-job/` | Elastic-Job | Elastic-Job 分布式调度 | ✅ |
| `middleware/airflow/` | Airflow | Apache Airflow 工作流调度 | ✅ |

### 📨 消息队列

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `mq/rabbitmq/` | RabbitMQ | RabbitMQ 消息代理 | ✅ |
| `mq/kafka/` | Kafka | Apache Kafka 分布式流处理 | ✅ |
| `mq/rocketmq/` | RocketMQ | RocketMQ 分布式消息队列 | ✅ |
| `mq/pulsar/` | Pulsar | Apache Pulsar 云原生消息 | ✅ |
| `mq/nats/` | NATS | NATS 轻量级消息系统 | ✅ |
| `mq/activemq/` | ActiveMQ | Apache ActiveMQ 消息代理 | ✅ |
| `mq/emqx/` | EMQX | EMQX MQTT 消息代理 | ✅ |
| `mq/zeromq/` | ZeroMQ | ZeroMQ 高性能消息库 | ✅ |

### 📊 监控系统和 APM

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `monitor/prometheus/` | Prometheus | Prometheus 监控系统 | ✅ |
| `monitor/grafana/` | Grafana | Grafana 可视化面板 | ✅ |
| `monitor/node-exporter/` | Node Exporter | 系统指标采集 | ✅ |
| `monitor/alertmanager/` | Alertmanager | Prometheus 告警管理 | ✅ |
| `monitor/zabbix/` | Zabbix | Zabbix 综合监控 | ✅ |
| `monitor/netdata/` | Netdata | NetData 实时监控 | ✅ |
| `monitor/uptime-kuma/` | Uptime Kuma | 服务可用性监控 | ✅ |
| `monitor/victoriametrics/` | VictoriaMetrics | VictoriaMetrics 时序数据库 | ✅ |
| `monitor/loki/` | Loki | Grafana Loki 日志聚合 | ✅ |
| `monitor/jaeger/` | Jaeger | Jaeger 分布式链路追踪 | ✅ |
| `monitor/pinpoint/` | Pinpoint | Pinpoint APM | ✅ |
| `apm/skywalking/` | SkyWalking | Apache SkyWalking APM | ✅ |

### 💾 存储系统

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `storage/minio/` | MinIO | MinIO 对象存储 | ✅ |
| `storage/fastdfs/` | FastDFS | FastDFS 分布式文件存储 | ✅ |
| `storage/ceph/` | Ceph | Ceph 分布式存储 | ✅ |
| `storage/glusterfs/` | GlusterFS | GlusterFS 分布式文件系统 | ✅ |
| `storage/nfs/` | NFS | NFS 网络文件系统 | ✅ |
| `storage/oss/` | OSS | 阿里云 OSS 工具 | ✅ |
| `storage/s3/` | S3 | AWS S3 兼容工具 | ✅ |
| `storage/hdfs/` | HDFS | Hadoop 分布式文件系统 | ✅ |

### 🌐 网络工具

| 目录/文件 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `network/frp/` | FRP | FRP 反向代理（内网穿透、远程访问） | ✅ |
| `network/openvpn/` | OpenVPN | OpenVPN 服务端（Docker 部署） | ✅ |
| `network/shadowsocks/` | Shadowsocks | Shadowsocks 代理安装 | ✅ |
| `network/teamview/` | TeamViewer | TeamViewer 远程桌面安装/更新/卸载 | ✅ |
| `network/tools/` | 网络工具集 | 测速、扫描、代理、DNS、TCP 调优等 | ✅ |
| `network/clashx-meta.sh` | ClashX Meta | macOS 代理客户端安装、更新、卸载 | ✅ |
| `network/publish-dev-https.sh` | 开发环境 HTTPS 发布 | 通过 nginx + 可选 frp 发布服务并申请证书 | ✅ |
| `network/register-domain.sh` | 域名注册 | 域名注册/购买脚本 | ✅ |
| `network/find_ports.sh` | 端口查找 | 查找占用端口的进程 | ✅ |
| `network/ssh_key_setup.sh` | SSH 密钥配置 | SSH 免密登录配置 | ✅ |
| `network/ssh-exec-remote.sh` | 远程命令执行 | 自动连接目标主机执行命令 | ✅ |
| `network/update-hosts.sh` | hosts 更新 | 下载并更新 /etc/hosts + 定时任务 | ✅ |
| `network/set-hosts-aliases.sh` | hosts 别名 | 将主机名列表指向本机 IP | ✅ |
| `network/vpn.sh` | VPN 连接 | openconnect 连接 VPN（凭据走环境变量） | ✅ |
| `network/wol.sh` | 网络唤醒 | Wake-on-LAN 远程开机 | ✅ |
| `network/install-hosts-font.sh` | 中文字体安装 | CentOS/RHEL 安装中文字体 | ✅ |

### 🔄 CI/CD

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `cicd/jenkins/` | Jenkins | Jenkins 持续集成服务器 | ✅ |
| `cicd/gitlab-ci/` | GitLab CI | GitLab CI/CD 配置 | ✅ |
| `cicd/github-actions/` | GitHub Actions | GitHub Actions 工作流 | ✅ |
| `cicd/drone/` | Drone | Drone CI/CD | ✅ |
| `cicd/tekton/` | Tekton | Tekton 云原生 CI/CD | ✅ |
| `cicd/argo-cd/` | Argo CD | Argo CD GitOps 持续部署 | ✅ |
| `cicd/gitea/` | Gitea | Gitea 轻量级 Git 服务 | ✅ |
| `cicd/woodpecker/` | Woodpecker | Woodpecker CI | ✅ |

### 🖥️ 系统管理

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `os/bin/` | 入口脚本与公共库 | setup.sh 主入口 + os_common.sh 公共函数库 | ✅ |
| `os/init/` | 系统初始化 | 审计/内核/安全/时间/用户/YUM 初始化 | ✅ |
| `os/security/` | 安全加固 | Rootkit 检测、权限管理、安全审计 | ✅ |
| `os/monitor/` | 监控与性能 | CPU/内存/磁盘/连接监控 | ✅ |
| `os/disk/` | 磁盘与文件 | 磁盘清理、测速、Swap 配置 | ✅ |
| `os/backup/` | 备份恢复 | 环境与软件备份、恢复 | ✅ |
| `os/utils/` | 实用工具 | 日志清理、缓存管理、部署等 | ✅ |
| `os/centos/` | CentOS 专用 | CentOS 初始化与安全加固 | ✅ |
| `os/envs` | 环境变量 | 系统环境变量统一管理 | ✅ |
| `os/sshm` | SSHM | SSH 连接管理器（交互式） | ✅ |
| `docker/` | Docker | Docker + Docker Compose 安装管理 | ✅ |
| `k8s/` | Kubernetes | Kubernetes 集群部署与管理 | ✅ |
| `rancher/` | Rancher | Rancher Kubernetes 管理平台 | ✅ |

### 🤖 自动化工具

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `automation/ansible/` | Ansible | Ansible 自动化运维 | ✅ |
| `automation/terraform/` | Terraform | Terraform 基础设施即代码 | ✅ |
| `automation/vagrant/` | Vagrant | Vagrant 虚拟环境管理 | ✅ |
| `automation/saltstack/` | SaltStack | SaltStack 自动化配置 | ✅ |
| `automation/puppet/` | Puppet | Puppet 配置管理 | ✅ |
| `automation/packer/` | Packer | Packer 镜像构建工具 | ✅ |

### 🔧 通用工具

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `tools/jq/` | jq | JSON 处理工具 | ✅ |
| `tools/yq/` | yq | YAML 处理工具 | ✅ |
| `tools/htop/` | htop | 系统监控工具 | ✅ |
| `tools/tmux/` | tmux | 终端复用器 | ✅ |
| `tools/zsh/` | Zsh | Zsh Shell + Oh My Zsh | ✅ |
| `tools/vim/` | Vim | Vim 编辑器配置 | ✅ |
| `tools/neovim/` | Neovim | Neovim 编辑器 | ✅ |
| `tools/screen/` | Screen | Screen 终端复用 | ✅ |
| `tools/tree/` | tree | 目录树显示工具 | ✅ |
| `tools/rclone/` | rclone | 多云存储同步工具 | ✅ |
| `tools/rsync/` | rsync | 文件同步工具 | ✅ |
| `tools/aria2/` | Aria2 | 多协议下载工具 | ✅ |
| `tools/wget/` | wget | 文件下载工具 | ✅ |
| `brew/` | Homebrew | Homebrew 包管理器 | ✅ |
| `beyond4/` | Beyond Compare | Beyond Compare 文件对比工具 | ✅ |
| `teamview/` | TeamViewer | TeamViewer 远程桌面 | ✅ |
| `gh-proxy/` | GH-Proxy | GitHub 加速代理 | ✅ |
| `certs/` | 证书管理 | SSL/TLS 证书管理工具 | ✅ |
| `dependency-track/` | Dependency-Track | OWASP Dependency-Track 软件供应链分析 | ✅ |

### 🔒 安全工具

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| **安全扫描** | | | |
| `security/scanner/nmap/` | Nmap | 网络端口与服务扫描 | ✅ |
| `security/scanner/nessus/` | Nessus | Nessus 漏洞扫描器 | ✅ |
| `security/scanner/nikto/` | Nikto | Web 服务器漏洞扫描 | ✅ |
| `security/scanner/openvas/` | OpenVAS | OpenVAS 漏洞评估 | ✅ |
| `security/scanner/nuclei/` | Nuclei | Nuclei 快速漏洞扫描 | ✅ |
| `security/scanner/trivy/` | Trivy | 容器/依赖漏洞扫描 | ✅ |
| **安全防护** | | | |
| `security/protection/waf/` | WAF | Web 应用防火墙 | ✅ |
| `security/protection/fail2ban/` | Fail2Ban | 入侵防御系统 | ✅ |
| `security/protection/clamav/` | ClamAV | 开源杀毒引擎 | ✅ |
| **安全监控** | | | |
| `security/monitor/lynis/` | Lynis | 系统安全审计工具 | ✅ |
| **代码安全** | | | |
| `security/code-security/p3c/` | P3C | 阿里巴巴 Java 代码规范检查 | ✅ |
| `security/code-security/install-shellcheck.sh` | ShellCheck | Shell 脚本静态检查 | ✅ |
| `security/code-security/bandit/` | Bandit | Python 代码安全扫描 | ✅ |
| `security/code-security/safety/` | Safety | Python 依赖安全检查 | ✅ |
| `security/code-security/pip-audit/` | pip-audit | pip 依赖漏洞审计 | ✅ |
| `security/code-security/dependency-check/` | OWASP DC | OWASP 依赖项检查 | ✅ |
| **主机安全** | | | |
| `security/host-security/aide/` | AIDE | 文件完整性检测 | ✅ |
| `security/host-security/chkrootkit/` | Chkrootkit | Rootkit 检测 | ✅ |
| `security/host-security/denyhosts/` | DenyHosts | SSH 暴力破解防护 | ✅ |
| `security/host-security/ossec/` | OSSEC | 主机入侵检测系统 | ✅ |
| `security/host-security/rkhunter/` | RKHunter | Rootkit 检测工具 | ✅ |
| **Web 安全** | | | |
| `security/web-security/owasp-zap/` | OWASP ZAP | Web 应用安全测试 | ✅ |
| `security/web-security/openscap/` | OpenSCAP | 安全合规扫描 | ✅ |
| **渗透测试** | | | |
| `sqlmap/` | SQLMap | SQL 注入自动化测试 | ✅ |
| `viper/` | Viper | Viper 渗透测试框架 | ✅ |
| `cobalt/` | Cobalt | Cobalt 渗透测试工具 | ✅ |

### 🧪 测试工具

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `playwright/` | Playwright | 浏览器自动化测试框架 | ✅ |
| `selenium/` | Selenium | Web 自动化测试工具 | ✅ |
| `wrk/` | wrk | HTTP 压力/性能测试 | ✅ |
| `locust/` | Locust | 分布式负载测试（含中文本地化） | ✅ |
| `sonarqube/` | SonarQube | 代码质量分析与审查平台 | ✅ |

### 📱 移动端开发

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `android/` | Android SDK | Android SDK 开发环境 | ✅ |
| `flutter/` | Flutter | Flutter 跨平台移动端开发 | ✅ |

### 📄 文档

| 目录 | 名称 | 说明 | 状态 |
|-----|------|------|------|
| `docs/dev-environment.md` | 开发环境文档 | 开发环境搭建指南 | ✅ |
| `docs/server-environment.md` | 服务器环境文档 | 服务器环境配置指南 | ✅ |
| `docs/ai-environment.md` | AI 环境文档 | AI 工具链环境搭建指南 | ✅ |

---

## 中间件管理脚本通用结构

每个中间件目录通常包含以下标准文件结构：

```
middleware/{name}/
├── install-{name}..sh      # 安装脚本
├── uninstall-{name}.sh     # 卸载脚本
├── config-{name}.sh        # 配置管理脚本
├── start-{name}.sh         # 启动脚本
├── stop-{name}.sh          # 停止脚本
├── status-{name}.sh        # 状态检查脚本
├── backup-{name}.sh        # 备份脚本
├── restore-{name}.sh       # 恢复脚本
├── upgrade-{name}.sh       # 升级脚本
├── monitor-{name}.sh       # 监控脚本
├── health-{name}.sh        # 健康检查脚本
├── conf/                   # 配置文件模板
│   ├── {name}.conf
│   └── {name}.properties
├── docker/                 # Docker 部署文件
│   ├── Dockerfile
│   └── docker-compose.yml
└── README.md               # 说明文档
```

---

## 支持的安装模式

| 模式 | 说明 | 适用场景 |
|-----|------|---------|
| `binary` | 二进制包直接安装 | 无包管理器的环境 |
| `package` | 系统包管理器安装（yum/apt） | 标准化部署 |
| `source` | 源码编译安装 | 需要自定义编译选项 |
| `docker` | Docker 容器化部署 | 容器化环境 |
| `docker-compose` | Docker Compose 编排部署 | 多容器编排 |
| `k8s` | Kubernetes 部署 | K8s 集群环境 |
| `helm` | Helm Chart 部署 | K8s 包管理 |
| `standalone` | 独立脚本运行 | 临时/测试环境 |

---

## 脚本编写规范

### 基本规则

1. **脚本头部**：每个脚本必须包含 Shebang 和描述信息

```bash
#!/bin/bash
# ============================================================
# Script Name: install-xxx.sh
# Description: 安装 XXX 组件
# Author: xxx
# Date: 2024-xx-xx
# Version: 1.0.0
# ============================================================
```

2. **错误处理**：使用 `set -e` 并提供友好的错误提示

```bash
set -euo pipefail

error_exit() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
    exit 1
}

trap 'error_exit "脚本执行失败，行号: $LINENO"' ERR
```

3. **日志输出**：统一日志格式

```bash
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
```

### 参数检查

```bash
# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要 root 权限运行，请使用 sudo"
    fi
}

# 检查操作系统
check_os() {
    local os=$(cat /etc/os-release | grep '^ID=' | cut -d'=' -f2 | tr -d '"')
    case "$os" in
        centos|rhel|rocky|almalinux) log_info "检测到 RedHat 系系统: $os" ;;
        ubuntu|debian) log_info "检测到 Debian 系系统: $os" ;;
        *) error_exit "不支持的操作系统: $os" ;;
    esac
}

# 检查端口占用
check_port() {
    local port=$1
    if ss -tlnp | grep -q ":${port} "; then
        error_exit "端口 $port 已被占用"
    fi
}
```

### 安全注意事项

```bash
# 禁止在脚本中硬编码密码
# 错误示例 ❌
# DB_PASSWORD="my_password"

# 正确示例 ✅
DB_PASSWORD="${DB_PASSWORD:-$(read -sp '请输入数据库密码: ' pwd && echo $pwd)}"

# 文件权限设置
chmod 600 /etc/myapp/config.conf  # 配置文件仅所有者可读写
chmod 700 /opt/myapp/scripts/      # 脚本目录仅所有者可访问

# 临时文件安全
TMP_DIR=$(mktemp -d /tmp/myapp.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
```

### 最佳实践

1. **幂等性**：脚本支持重复执行，不会因重复运行而产生副作用
2. **可配置性**：通过环境变量或配置文件支持自定义参数
3. **回滚机制**：安装失败时自动回滚到之前的状态
4. **版本锁定**：关键组件安装时锁定版本号，避免不确定升级
5. **健康检查**：安装完成后自动执行健康检查，验证服务可用性
6. **日志记录**：所有操作记录到日志文件，便于排查问题

---

## 常见问题

### Q1: 脚本执行权限不足怎么办？

```bash
# 方法一：使用 sudo 执行
sudo bash install-xxx.sh

# 方法二：赋予执行权限
chmod +x install-xxx.sh
./install-xxx.sh
```

### Q2: 如何自定义安装路径？

大部分脚本支持通过环境变量指定安装路径：

```bash
# 自定义 Java 安装路径
export JAVA_HOME=/usr/local/java/jdk17
bash java/jdk/install-jdk17.sh

# 自定义 Docker 数据目录
export DOCKER_DATA_DIR=/data/docker
bash docker/install-docker.sh
```

### Q3: 网络受限环境如何使用？

```bash
# 方法一：设置代理
export http_proxy=http://proxy.example.com:8080
export https_proxy=http://proxy.example.com:8080

# 方法二：使用国内镜像源（脚本会自动检测）
export USE_MIRROR=true
bash install-xxx.sh

# 方法三：使用 GitHub 加速代理
export GH_PROXY=https://gh-proxy.example.com
```

### Q4: 如何卸载已安装的组件？

每个组件都提供了对应的卸载脚本：

```bash
# 卸载 Redis
bash middleware/redis/uninstall-redis.sh

# 卸载 Docker
bash docker/uninstall-docker.sh
```

---

## TODO

### 功能完善
- [ ] 补充所有中间件的 Docker Compose 部署方案
- [ ] 增加 Kubernetes Helm Chart 支持
- [ ] 完善 ARM 架构（aarch64）兼容性
- [ ] 增加更多国产数据库支持（OceanBase、GaussDB、TiDB）
- [ ] 补充 AI 工具链的 Windows WSL2 支持

### 性能优化
- [ ] 脚本执行耗时分析与优化
- [ ] 增加并行安装支持
- [ ] 离线安装包制作工具
- [ ] 增量更新机制

### 安全工具
- [ ] 安全扫描报告自动生成
- [ ] 合规性检查自动化
- [ ] 漏洞情报集成
- [ ] 安全基线自动加固

### 文档优化
- [ ] 增加架构图
- [ ] 补充最佳实践文档
- [ ] 增加视频教程链接
- [ ] 多语言文档支持

### 其他
- [ ] Web 管理界面
- [ ] 脚本版本管理
- [ ] 自动化测试覆盖
- [ ] CI/CD 集成测试

---

## 贡献指南

欢迎贡献代码！请遵循以下流程：

1. **Fork** 本仓库
2. 创建特性分支：`git checkout -b feature/new-tool`
3. 遵循[脚本编写规范](#脚本编写规范)编写脚本
4. 测试脚本在 CentOS 和 Ubuntu 上的兼容性
5. 提交代码：`git commit -m 'feat: 添加 XXX 工具安装脚本'`
6. 推送分支：`git push origin feature/new-tool`
7. 提交 Pull Request

### Commit 规范

```
feat:     新增功能
fix:      修复 Bug
docs:     文档更新
style:    代码格式调整
refactor: 代码重构
test:     测试相关
chore:    构建/工具链更新
```

### 目录命名规范

- 目录名使用**小写字母**和**连字符**（kebab-case）
- 安装脚本命名为 `install-{name}.sh`
- 卸载脚本命名为 `uninstall-{name}.sh`
- 配置脚本命名为 `config-{name}.sh`
- 每个工具目录下必须包含 `README.md` 说明文档

---

> 📝 **维护说明**：本仓库持续更新中，如有问题或建议请提交 Issue。
> 📄 **许可证**：[MIT License](LICENSE)

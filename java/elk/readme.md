# ELK Stack 日志平台

ELK 是 Elasticsearch、Logstash、Kibana 的简称，是目前最流行的开源日志收集、分析和可视化解决方案。

- **Elasticsearch**: 分布式搜索和分析引擎
- **Logstash**: 服务器端数据处理管道
- **Kibana**: Elasticsearch 的数据可视化和管理界面
- **Filebeat** (可选): 轻量级日志采集器

> 官网：https://www.elastic.co/elastic-stack

## 📋 目录

- [快速开始](#快速开始)
- [脚本说明](#脚本说明)
- [使用指南](#使用指南)
- [组件说明](#组件说明)
- [常用命令](#常用命令)
- [配置说明](#配置说明)
- [故障排查](#故障排查)

---

## 🚀 快速开始

### 一键安装

```bash
# 进入目录
cd elk

# Docker 模式（推荐，自动检测 Docker）
sudo ./bin/install-elk.sh

# 指定端口和组件
sudo ./bin/install-elk.sh --es-port 9200 --kibana-port 5601 --components elk+filebeat

# 配置自启动
sudo ./bin/install-elk.sh --auto-start

# 主机模式（需要预先安装 Java 11+）
sudo ./bin/install-elk.sh --mode host
```

### 访问控制台

```
Elasticsearch: http://localhost:9200
Kibana: http://localhost:5601
账号：elastic
密码：elastic123 (或安装时自定义)
```

> ⚠️ **首次登录后请立即修改默认密码！**

### 卸载

```bash
# 交互式卸载
sudo ./bin/uninstall-elk.sh

# 强制卸载
sudo ./bin/uninstall-elk.sh --force

# 保留数据文件卸载
sudo ./bin/uninstall-elk.sh --keep-data
```

---

## 📝 脚本说明

### install-elk.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `/data/elk` |
| `--es-port PORT` | Elasticsearch 端口 | `9200` |
| `--kibana-port PORT` | Kibana 端口 | `5601` |
| `--ls-port PORT` | Logstash HTTP 端口 | `5044` |
| `--version VERSION` | ELK 版本 | `8.11.1` |
| `--es-password PWD` | Elasticsearch 密码 | `elastic123` |
| `--components COMPS` | 安装组件 (elk\|elk+filebeat\|elk+metricbeat) | `elk` |
| `--memory-lock` | 锁定内存（提升 ES 性能） | `false` |
| `--mode MODE` | 安装模式 (auto\|docker\|host) | `auto` |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-elk.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | ELK 安装目录 | `/data/elk` |
| `-f, --force` | 强制卸载 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--mode MODE` | 卸载模式 (auto\|docker\|host) | `auto` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 安装模式说明

#### Docker Compose 模式（推荐）

自动检测 Docker，使用容器化部署：

```bash
# 自动检测并安装
sudo ./bin/install-elk.sh

# 强制使用 Docker 模式
sudo ./bin/install-elk.sh --mode docker
```

**优点：**
- 一键部署，无需手动配置依赖
- 环境隔离，不影响宿主机
- 便于迁移和备份

#### 主机模式

直接在宿主机安装，需要预先配置：
- JDK 11+
- 系统参数优化（vm.max_map_count 等）

```bash
sudo ./bin/install-elk.sh --mode host
```

**适用场景：**
- 无法使用 Docker 的环境
- 需要深度定制配置
- 生产环境性能要求高

### 启动服务

#### Docker 模式

```bash
cd /data/elk

# 方式 1：使用启动脚本
sudo ./bin/startup.sh

# 方式 2：使用 docker-compose
cd /data/elk && docker compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start elk
```

#### 主机模式

```bash
# 使用 systemd
sudo systemctl start elasticsearch
sudo systemctl start logstash
sudo systemctl start kibana

# 使用启动脚本
/data/elk/bin/startup.sh
```

### 停止服务

#### Docker 模式

```bash
cd /data/elk

# 方式 1：使用停止脚本
sudo ./bin/stop.sh

# 方式 2：使用 docker-compose
docker compose down

# 方式 3：使用 systemd
sudo systemctl stop elk
```

#### 主机模式

```bash
sudo systemctl stop elasticsearch logstash kibana
```

### 查看状态

#### Docker 模式

```bash
cd /data/elk

# 查看服务状态
sudo ./bin/status.sh

# 查看容器状态
docker compose ps

# 查看 ES 集群健康
curl -u elastic:elastic123 "http://localhost:9200/_cluster/health?pretty"

# 查看详细日志
docker compose logs -f elasticsearch
```

#### 主机模式

```bash
# 查看 systemd 状态
sudo systemctl status elasticsearch

# 查看 ES 集群健康
curl -u elastic:elastic123 "http://localhost:9200/_cluster/health?pretty"

# 查看日志
sudo journalctl -u elasticsearch -f
```

---

## 🧩 组件说明

### Elasticsearch

分布式搜索和分析引擎，负责存储和索引数据。

**端口**: 9200 (HTTP)
**数据目录**: /data/elk/data/elasticsearch
**日志目录**: /data/elk/logs/elasticsearch

```bash
# 检查集群健康
curl -u elastic:elastic123 "http://localhost:9200/_cluster/health?pretty"

# 查看所有索引
curl -u elastic:elastic123 "http://localhost:9200/_cat/indices?v"

# 查看节点信息
curl -u elastic:elastic123 "http://localhost:9200/_cat/nodes?v"
```

### Logstash

服务器端数据处理管道，负责收集、转换和加载数据。

**端口**: 5044 (Beats 输入), 5000 (TCP 输入), 9600 (监控 API)
**配置目录**: /data/elk/config/logstash/pipeline

```bash
# 查看 Logstash 状态
curl "http://localhost:9600/_node/stats?pretty"

# 测试管道配置
/data/elk/logstash/bin/logstash --config.test_and_exit
```

### Kibana

Elasticsearch 的数据可视化和管理界面。

**端口**: 5601
**数据目录**: /data/elk/data/kibana

访问：http://localhost:5601

### Filebeat (可选)

轻量级日志采集器，负责收集日志文件并发送到 Logstash 或 Elasticsearch。

**配置目录**: /data/elk/config/filebeat

```bash
# 测试 Filebeat 配置
filebeat test config -c /data/elk/config/filebeat/filebeat.yml

# 查看 Filebeat 模块
filebeat modules list
```

---

## 🔧 常用命令

### Elasticsearch 操作

```bash
# 创建索引
curl -X PUT "localhost:9200/my-index" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  }
}'

# 添加文档
curl -X POST "localhost:9200/my-index/_doc" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "message": "Hello World",
  "timestamp": "2024-01-01T00:00:00Z"
}'

# 搜索文档
curl -X GET "localhost:9200/my-index/_search" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "query": {
    "match": {
      "message": "Hello"
    }
  }
}'

# 删除索引
curl -X DELETE "localhost:9200/my-index" -u elastic:elastic123

# 备份索引
curl -X PUT "localhost:9200/_snapshot/backup" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "type": "fs",
  "settings": {
    "location": "/data/elk/backups"
  }
}'
```

### Kibana 操作

```bash
# 重置 Kibana 索引（谨慎使用）
curl -X DELETE "localhost:9200/.kibana*" -u elastic:elastic123
```

### 日志管理

```bash
# 查看 ES 日志
tail -f /data/elk/logs/elasticsearch/es-cluster.log

# 查看 Logstash 日志
tail -f /data/elk/logs/logstash/logstash-plain.log

# 查看 Kibana 日志
tail -f /data/elk/logs/kibana/kibana.log

# Docker 模式查看日志
docker compose logs -f elasticsearch
docker compose logs -f logstash
docker compose logs -f kibana
```

### 数据备份

```bash
# 创建快照仓库
curl -X PUT "localhost:9200/_snapshot/backup" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "type": "fs",
  "settings": {
    "location": "/data/elk/backups"
  }
}'

# 创建快照
curl -X PUT "localhost:9200/_snapshot/backup/snapshot_1?wait_for_completion=true" -u elastic:elastic123

# 恢复快照
curl -X POST "localhost:9200/_snapshot/backup/snapshot_1/_restore" -u elastic:elastic123 -H 'Content-Type: application/json' -d '{
  "indices": "my-index"
}'

# 查看快照
curl "localhost:9200/_snapshot/backup/_all" -u elastic:elastic123 | jq
```

### 系统管理

```bash
# 查看数据目录大小
du -sh /data/elk/data/*

# 查看日志目录大小
du -sh /data/elk/logs/*

# 清理旧日志
find /data/elk/logs -name "*.log" -mtime +30 -delete

# 查看索引大小
curl -u elastic:elastic123 "http://localhost:9200/_cat/indices?v&s=store.size:desc"
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `ES_PORT` | Elasticsearch 端口 | `9200` |
| `KIBANA_PORT` | Kibana 端口 | `5601` |
| `LS_HTTP_PORT` | Logstash HTTP 端口 | `5044` |
| `ES_PASSWORD` | Elasticsearch 密码 | `elastic123` |
| `ELK_VERSION` | ELK 版本 | `8.11.1` |
| `MEMORY_LOCK` | 内存锁定 | `false` |

### 目录结构

```
elk/
├── bin/
│   ├── install-elk.sh     # 安装脚本
│   ├── uninstall-elk.sh   # 卸载脚本
│   ├── startup.sh         # 启动脚本
│   ├── stop.sh            # 停止脚本
│   └── status.sh          # 状态检查脚本
├── data/
│   ├── elasticsearch/     # ES 数据目录
│   ├── logstash/          # Logstash 数据目录
│   └── kibana/            # Kibana 数据目录
├── logs/
│   ├── elasticsearch/     # ES 日志目录
│   ├── logstash/          # Logstash 日志目录
│   └── kibana/            # Kibana 日志目录
├── config/
│   ├── elasticsearch/     # ES 配置目录
│   ├── logstash/          # Logstash 配置目录
│   │   └── pipeline/      # Logstash 管道配置
│   ├── kibana/            # Kibana 配置目录
│   └── filebeat/          # Filebeat 配置目录（可选）
├── docker-compose.yml     # Docker Compose 配置文件
└── .env                   # 环境变量配置
```

### 系统要求

| 资源 | Docker 模式 | 主机模式 |
|------|------------|----------|
| CPU | 2 核 + | 4 核 + |
| 内存 | 2GB+ | 4GB+ (推荐 8GB+) |
| 磁盘 | 20GB+ | 50GB+ |
| Docker | 20.10+ | - |
| Java | - | JDK 11+ |

### 主机模式系统优化

```bash
# 增加虚拟内存映射数
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 增加文件描述符限制
ulimit -n 65536
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf

# 禁用交换分区（可选）
swapoff -a
```

---

## 🔍 故障排查

### Elasticsearch 无法启动

#### Docker 模式

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :9200

# 3. 查看错误日志
docker compose logs elasticsearch

# 4. 检查磁盘空间
df -h

# 5. 检查内存
free -h

# 6. 重新创建容器
docker compose down
docker compose up -d
```

#### 主机模式

```bash
# 1. 检查系统参数
sysctl vm.max_map_count

# 2. 检查 Java 版本
java -version

# 3. 查看日志
tail -f /data/elk/logs/elasticsearch/es-cluster.log

# 4. 检查文件权限
ls -la /data/elk/elasticsearch/

# 5. 检查用户
id elasticsearch
```

### Kibana 无法连接 Elasticsearch

```bash
# 1. 检查 ES 是否运行
curl -u elastic:elastic123 "http://localhost:9200/_cluster/health"

# 2. 检查 Kibana 配置
cat /data/elk/config/kibana/kibana.yml

# 3. 查看 Kibana 日志
docker compose logs kibana

# 4. 重启 Kibana
docker compose restart kibana
```

### Logstash 管道错误

```bash
# 1. 测试管道配置
docker exec logstash logstash --config.test_and_exit

# 2. 查看 Logstash 日志
docker compose logs logstash

# 3. 检查管道配置
cat /data/elk/config/logstash/pipeline/logstash.conf

# 4. 重新加载管道
docker compose restart logstash
```

### 内存不足

```bash
# 1. 查看内存使用
free -h
docker stats

# 2. 调整 ES 堆内存（编辑 docker-compose.yml）
# ES_JAVA_OPTS=-Xms1g -Xmx1g

# 3. 调整 Logstash 堆内存
# LS_JAVA_OPTS=-Xms512m -Xmx512m

# 4. 重启服务
docker compose restart
```

### 磁盘空间不足

```bash
# 1. 查看各目录大小
du -sh /data/elk/data/*
du -sh /data/elk/logs/*

# 2. 查看索引大小
curl -u elastic:elastic123 "http://localhost:9200/_cat/indices?v&s=store.size:desc"

# 3. 删除旧索引
curl -X DELETE "localhost:9200/logs-2023.*" -u elastic:elastic123

# 4. 设置索引生命周期管理（ILM）
# 在 Kibana 中配置 ILM 策略
```

### 认证失败

```bash
# 1. 重置 elastic 用户密码
docker exec elasticsearch bin/elasticsearch-reset-password -u elastic -i

# 2. 或使用默认密码
docker exec elasticsearch bin/elasticsearch-reset-password -u elastic -a

# 3. 清除 Kibana 缓存
rm -rf /data/elk/data/kibana/*
docker compose restart kibana
```

---

## 📚 参考资源

- [Elastic 官网](https://www.elastic.co/)
- [Elasticsearch 文档](https://www.elastic.co/guide/en/elasticsearch/reference/index.html)
- [Logstash 文档](https://www.elastic.co/guide/en/logstash/current/index.html)
- [Kibana 文档](https://www.elastic.co/guide/en/kibana/current/index.html)
- [Filebeat 文档](https://www.elastic.co/guide/en/beats/filebeat/current/index.html)

---

**最后更新**: 2026 年 3 月 13 日

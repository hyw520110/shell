# Kafka 安装和管理脚本

Apache Kafka 是高吞吐量的分布式消息队列系统，广泛用于日志处理、流式数据处理、事件驱动架构等场景。

## 📋 目录

- [快速开始](#快速开始)
- [脚本说明](#脚本说明)
- [使用指南](#使用指南)
- [常用命令](#常用命令)
- [配置说明](#配置说明)
- [故障排查](#故障排查)

---

## 🚀 快速开始

### 一键安装（Docker 模式）

```bash
# 进入目录
cd mq/kafka

# 使用默认设置安装
./install-kafka.sh

# 指定端口安装
./install-kafka.sh --port 9093

# 安装并配置自启动
./install-kafka.sh --auto-start
```

### 卸载

```bash
# 交互式卸载
./uninstall-kafka.sh

# 强制卸载
./uninstall-kafka.sh --force

# 保留数据文件卸载
./uninstall-kafka.sh --keep-data
```

---

## 📝 脚本说明

### install-kafka.sh - 安装脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | 安装目录 | `~/kafka` |
| `-p, --port PORT` | Kafka 端口号 | `9092` |
| `-z, --zookeeper-port PORT` | ZooKeeper 端口号 | `2181` |
| `-m, --mode MODE` | 安装模式 (docker\|host) | `docker` |
| `--auto-start` | 配置自启动服务 | `false` |
| `--dry-run` | 试运行模式 | `false` |
| `--uninstall` | 卸载模式 | `false` |

### uninstall-kafka.sh - 卸载脚本

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息 | - |
| `-d, --dir DIR` | Kafka 安装目录 | `~/kafka` |
| `-f, --force` | 强制卸载，不确认提示 | `false` |
| `--keep-data` | 保留数据文件 | `false` |
| `--dry-run` | 试运行模式 | `false` |

---

## 📖 使用指南

### 启动服务

```bash
cd ~/kafka

# 方式 1：使用启动脚本
./bin/startup.sh

# 方式 2：使用 docker-compose
docker-compose up -d

# 方式 3：使用 systemd（如果已配置）
sudo systemctl start kafka
```

### 停止服务

```bash
cd ~/kafka

# 方式 1：使用停止脚本
./bin/stop.sh

# 方式 2：使用 docker-compose
docker-compose down

# 方式 3：使用 systemd
sudo systemctl stop kafka
```

### 查看状态

```bash
cd ~/kafka

# 查看服务状态
./bin/status.sh

# 查看容器状态
docker-compose ps

# 查看详细日志
docker-compose logs -f
```

---

## 🔧 常用命令

### 主题管理

```bash
# 创建主题
docker exec -it kafka kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --create \
    --topic my-topic \
    --partitions 3 \
    --replication-factor 1

# 查看主题列表
docker exec -it kafka kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --list

# 查看主题详情
docker exec -it kafka kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --topic my-topic

# 删除主题
docker exec -it kafka kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --delete \
    --topic my-topic
```

### 消息测试

```bash
# 生产消息
docker exec -it kafka kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic my-topic

# 消费消息
docker exec -it kafka kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic my-topic \
    --from-beginning

# 消费最新消息
docker exec -it kafka kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic my-topic \
    --max-messages 10
```

### 消费者组管理

```bash
# 查看消费者组列表
docker exec -it kafka kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --list

# 查看消费者组详情
docker exec -it kafka kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --group my-group

# 删除消费者组
docker exec -it kafka kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --delete \
    --group my-group
```

### 日志管理

```bash
# 查看 Kafka 日志
docker-compose logs kafka

# 查看 ZooKeeper 日志
docker-compose logs zookeeper

# 实时查看日志
docker-compose logs -f kafka

# 查看最近 100 行日志
docker-compose logs --tail=100 kafka
```

---

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `KAFKA_PORT` | Kafka 服务端口 | `9092` |
| `ZOOKEEPER_PORT` | ZooKeeper 端口 | `2181` |
| `KAFKA_BROKER_ID` | Broker ID | `1` |
| `KAFKA_NUM_PARTITIONS` | 默认分区数 | `1` |
| `KAFKA_LOG_RETENTION_HOURS` | 日志保留时间（小时） | `168` (7 天) |
| `KAFKA_LOG_SEGMENT_BYTES` | 日志段大小 | `1GB` |

### 目录结构

```
kafka/
├── bin/
│   ├── startup.sh      # 启动脚本
│   ├── stop.sh         # 停止脚本
│   └── status.sh       # 状态检查脚本
├── conf/               # 配置文件目录
├── data/
│   ├── kafka/          # Kafka 数据目录
│   └── zookeeper/      # ZooKeeper 数据目录
├── logs/
│   ├── kafka/          # Kafka 日志目录
│   └── zookeeper/      # ZooKeeper 日志目录
├── docker-compose.yml  # Docker Compose 配置文件
├── install-kafka.sh    # 安装脚本
└── uninstall-kafka.sh  # 卸载脚本
```

---

## 🔍 故障排查

### 服务无法启动

```bash
# 1. 检查 Docker 是否运行
docker info

# 2. 检查端口占用
lsof -i :9092
lsof -i :2181

# 3. 查看错误日志
docker-compose logs kafka
docker-compose logs zookeeper

# 4. 检查磁盘空间
df -h
```

### ZooKeeper 连接失败

```bash
# 1. 检查 ZooKeeper 是否启动
docker-compose ps zookeeper

# 2. 测试 ZooKeeper 连接
docker exec zookeeper echo ruok | nc localhost 2181

# 3. 重启 ZooKeeper
docker-compose restart zookeeper

# 4. 查看 ZooKeeper 日志
docker-compose logs zookeeper
```

### Kafka Broker 无法连接

```bash
# 1. 检查 Broker 状态
docker exec kafka kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# 2. 检查监听器配置
docker exec kafka cat /opt/kafka/config/server.properties | grep listeners

# 3. 重启 Kafka
docker-compose restart kafka

# 4. 重新创建容器
docker-compose down
docker-compose up -d
```

### 消息积压

```bash
# 1. 查看消费者组延迟
docker exec -it kafka kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --group my-group

# 2. 增加分区数
docker exec -it kafka kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --alter \
    --topic my-topic \
    --partitions 6

# 3. 增加消费者实例
```

### 磁盘空间不足

```bash
# 1. 查看数据目录大小
du -sh ~/kafka/data

# 2. 修改日志保留时间（在 docker-compose.yml 中）
# KAFKA_LOG_RETENTION_HOURS: "24"  # 保留 24 小时

# 3. 清理旧数据
docker-compose down
rm -rf ~/kafka/data/kafka/*
docker-compose up -d
```

---

## 📚 参考资源

- [Apache Kafka 官网](https://kafka.apache.org/)
- [Kafka 官方文档](https://kafka.apache.org/documentation/)
- [Kafka GitHub](https://github.com/apache/kafka)
- [Docker Hub - Apache Kafka](https://hub.docker.com/r/apache/kafka)

---

**最后更新**: 2026 年 3 月 13 日

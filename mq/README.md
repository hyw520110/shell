# 消息队列管理脚本

> 分布式消息中间件的自动化安装、配置和管理工具

## 📋 目录说明

| 消息队列 | 类型 | 安装脚本 | 版本检测 | 帮助函数 |
|----------|------|----------|---------|---------|
| **ActiveMQ** | JMS 消息队列 | ✅ | ❌ | ❌ |
| **Kafka** | 分布式流处理 | ✅ | ❌ | ❌ |
| **RocketMQ** | 分布式消息队列 | ✅ | ✅ | ✅ |
| **RocketMQ Console** | 管理控制台 | ✅ | ❌ | ❌ |
| **Canal** | 数据同步工具 | ✅ | ❌ | ❌ |

## 🚀 快速开始

### RocketMQ（推荐）

```bash
cd mq/rocketmq
# 安装 RocketMQ
./bin/install.sh

# 启动 NameServer
./bin/startup.sh namesrv

# 启动 Broker
./bin/startup.sh broker

# 查看控制台
cd ../rocketmq-console
./bin/install.sh
```

### Kafka

```bash
cd mq/kafka
# 安装 Kafka
./install-kafka.sh

# 查看 README 了解详细使用方式
cat readme.md
```

### ActiveMQ

```bash
cd mq/activemq
# 使用 bin 目录下的管理脚本
./bin/install.sh
```

### Canal（数据同步）

```bash
cd mq
# 安装 Canal
./install-canal.sh
```

## 🔧 详细说明

### 1. RocketMQ

**类型**: 分布式消息队列中间件

**特点**:
- 高吞吐量
- 低延迟
- 支持事务消息
- 消息回溯
- 分布式架构

**适用场景**:
- 电商订单系统
- 金融交易系统
- 日志收集系统
- 大数据流处理

**目录结构**:
```
rocketmq/
└── bin/
    ├── install.sh     # 安装脚本
    ├── startup.sh     # 启动脚本
    └── stop.sh        # 停止脚本
```

**常用操作**:
```bash
# 安装 RocketMQ
cd rocketmq
./bin/install.sh

# 启动 NameServer
./bin/startup.sh namesrv

# 启动 Broker
./bin/startup.sh broker

# 停止服务
./bin/stop.sh

# 发送消息
sh mqadmin updateTopic -n DefaultCluster -t TopicName

# 查看消息
sh mqadmin queryMsgByTopic -n DefaultCluster -t TopicName
```

### 2. Kafka

**类型**: 分布式流处理平台

**特点**:
- 高吞吐量
- 低延迟
- 可扩展性
- 持久化存储
- 支持流处理

**适用场景**:
- 实时数据处理
- 日志收集
- 事件溯源
- 数据管道

**目录结构**:
```
kafka/
├── bin/
├── install-kafka.sh    # 安装脚本
├── uninstall-kafka.sh  # 卸载脚本
└── readme.md           # 使用说明
```

**常用操作**:
```bash
# 安装 Kafka
./install-kafka.sh

# 启动 Kafka 服务
kafka-server-start.sh config/server.properties

# 创建主题
kafka-topics.sh --create --topic my-topic --bootstrap-server localhost:9092

# 生产消息
kafka-console-producer.sh --topic my-topic --bootstrap-server localhost:9092

# 消费消息
kafka-console-consumer.sh --topic my-topic --bootstrap-server localhost:9092 --from-beginning

# 列出主题
kafka-topics.sh --list --bootstrap-server localhost:9092
```

### 3. ActiveMQ

**类型**: JMS 消息队列

**特点**:
- JMS 标准实现
- 支持 STOMP、AMQP
- 多种协议支持
- 易于配置

**适用场景**:
- 企业应用集成
- 消息广播
- 异步处理
- 解耦系统

**目录结构**:
```
activemq/
├── bin/                 # 管理脚本
└── conf/                # 配置文件
```

**常用操作**:
```bash
# 启动 ActiveMQ
./bin/startup.sh

# 停止 ActiveMQ
./bin/stop.sh

# 查看状态
./bin/status.sh

# 访问管理界面
# http://localhost:8161
```

### 4. RocketMQ Console

**类型**: RocketMQ 管理控制台

**功能**:
- 消息队列可视化
- 消息查询
- 集群管理
- 性能监控

**适用场景**:
- RocketMQ 运维管理
- 消息调试
- 性能分析

**常用操作**:
```bash
# 安装控制台
cd rocketmq-console
./bin/install.sh

# 访问控制台
# http://localhost:8080
```

### 5. Canal

**类型**: 数据同步工具

**功能**:
- MySQL 增量数据同步
- 数据库变更监听
- 异地多活
- 数据备份

**适用场景**:
- 数据同步
- 缓存更新
- 搜索引擎同步
- 数据仓库同步

**常用操作**:
```bash
# 安装 Canal
cd mq
./install-canal.sh

# 配置数据源
# 编辑 conf/canal.properties

# 启动 Canal
sh bin/startup.sh

# 查看日志
tail -f logs/canal/canal.log
```

## 📊 消息队列对比

### 功能对比

| 特性 | RocketMQ | Kafka | ActiveMQ | Canal |
|------|----------|-------|----------|-------|
| **吞吐量** | 高 | 极高 | 中 | 低 |
| **延迟** | 低 | 极低 | 中 | 高 |
| **可靠性** | 高 | 高 | 中 | 高 |
| **事务支持** | ✅ | ✅ | ✅ | ❌ |
| **消息回溯** | ✅ | ❌ | ❌ | ❌ |
| **分布式** | ✅ | ✅ | ❌ | ❌ |
| **持久化** | ✅ | ✅ | ✅ | ✅ |
| **管理界面** | ✅ | ❌ | ✅ | ❌ |

### 适用场景对比

| 场景 | 推荐方案 | 原因 |
|------|----------|------|
| **高并发电商** | RocketMQ | 事务支持、消息回溯 |
| **大数据流处理** | Kafka | 高吞吐、流处理 |
| **企业集成** | ActiveMQ | JMS 标准、易用 |
| **数据同步** | Canal | MySQL 增量同步 |
| **日志收集** | Kafka | 高吞吐、持久化 |
| **金融交易** | RocketMQ | 可靠性、事务支持 |

## ⚙️ 环境配置

### RocketMQ 配置

```properties
# NameServer 配置
listenPort=9876

# Broker 配置
namesrvAddr=127.0.0.1:9876
brokerClusterName=DefaultCluster
brokerName=broker-a
brokerId=0
storePathRootDir=/data/rocketmq/store
autoCreateTopicEnable=true
```

### Kafka 配置

```properties
# Server 配置
broker.id=1
listeners=PLAINTEXT://:9092
log.dirs=/data/kafka
zookeeper.connect=localhost:2181

# Topic 配置
num.partitions=3
default.replication.factor=2
```

### ActiveMQ 配置

```xml
<!-- 连接器配置 -->
<transportConnectors>
    <transportConnector name="openwire" uri="tcp://0.0.0.0:61616"/>
    <transportConnector name="stomp" uri="stomp://0.0.0.0:61613"/>
</transportConnectors>
```

### Canal 配置

```properties
# Canal 配置
canal.instance.mysql.slaveId=1234
canal.instance.master.address=127.0.0.1:3306
canal.instance.master.journal.name=
canal.instance.master.position=
canal.instance.master.timestamp=
canal.instance.dbUsername=canal
canal.instance.dbPassword=canal
canal.instance.connectionCharset=UTF-8
canal.instance.filter.regex=.*\\..*
```

## 🔗 相关链接

### 官方网站
- [RocketMQ 官方网站](https://rocketmq.apache.org/)
- [Kafka 官方网站](https://kafka.apache.org/)
- [ActiveMQ 官方网站](https://activemq.apache.org/)
- [Canal 官方网站](https://github.com/alibaba/canal)

### 文档资源
- [RocketMQ 文档](https://rocketmq.apache.org/docs/)
- [Kafka 文档](https://kafka.apache.org/documentation/)
- [ActiveMQ 文档](https://activemq.apache.org/components/)
- [Canal 文档](https://github.com/alibaba/canal/wiki)

## ❓ 常见问题

### Q: 如何选择合适的消息队列？

**A**: 根据需求选择：

- **高并发电商**: RocketMQ（事务支持）
- **大数据处理**: Kafka（高吞吐）
- **企业集成**: ActiveMQ（JMS 标准）
- **数据同步**: Canal（MySQL 增量）

### Q: 如何保证消息不丢失？

**A**: 可靠性配置：

- 生产者确认机制
- 持久化配置
- 副本机制
- 事务消息
- 消费者确认机制

### Q: 如何处理消息堆积？

**A**: 处理策略：

- 增加消费者数量
- 优化消费者处理逻辑
- 使用死信队列
- 监控和告警
- 临时扩容

### Q: 如何监控消息队列？

**A**: 监控工具：

- RocketMQ Console
- Kafka Manager
- ActiveMQ Web Console
- Prometheus + Grafana
- 自定义监控脚本

### Q: 如何保证顺序性？

**A**: 顺序性保证：

- 单分区（Kafka）
- 单队列（RocketMQ）
- 消费者串行处理
- 全局顺序配置

## 📝 最佳实践

### 生产者配置

```java
// RocketMQ 生产者配置
DefaultMQProducer producer = new DefaultMQProducer("producer_group");
producer.setNamesrvAddr("localhost:9876");
producer.setRetryTimesWhenSendFailed(3);
producer.start();

// Kafka 生产者配置
Properties props = new Properties();
props.put("bootstrap.servers", "localhost:9092");
props.put("acks", "all");
props.put("retries", 3);
Producer<String, String> producer = new KafkaProducer<>(props);
```

### 消费者配置

```java
// RocketMQ 消费者配置
DefaultMQPushConsumer consumer = new DefaultMQPushConsumer("consumer_group");
consumer.setNamesrvAddr("localhost:9876");
consumer.setConsumeFromWhere(ConsumeFromWhere.CONSUME_FROM_FIRST_OFFSET);
consumer.setMessageModel(MessageModel.CLUSTERING);
consumer.subscribe("topic", "*");
consumer.registerMessageListener(new MessageListenerConcurrently() {
    @Override
    public ConsumeConcurrentlyStatus consumeMessage(List<MessageExt> msgs, ConsumeConcurrentlyContext context) {
        // 处理消息
        return ConsumeConcurrentlyStatus.CONSUME_SUCCESS;
    }
});
consumer.start();

// Kafka 消费者配置
Properties props = new Properties();
props.put("bootstrap.servers", "localhost:9092");
props.put("group.id", "consumer_group");
props.put("enable.auto.commit", "false");
KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
consumer.subscribe("topic", "*");
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    // 处理消息
    consumer.commitSync();
}
```

### 集群配置

```bash
# RocketMQ 集群配置
# NameServer 集群
namesrvAddr=192.168.1.1:9876;192.168.1.2:9876;192.168.1.3:9876

# Broker 集群
brokerClusterName=ClusterA
brokerName=broker-a
brokerId=0
```

## 🚧 TODO

- [ ] 为 ActiveMQ 添加帮助函数和版本检测
- [ ] 为 Kafka 添加帮助函数和版本检测
- [ ] 为 Canal 添加帮助函数和版本检测
- [ ] 添加消息队列监控脚本
- [ ] 添加消息队列集群配置模板
- [ ] 添加消息队列性能测试工具
- [ ] 添加消息队列故障恢复脚本
- [ ] 添加消息队列安全加固配置

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。
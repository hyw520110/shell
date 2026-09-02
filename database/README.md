# 数据库管理脚本

> 关系型和非关系型数据库的自动化安装、配置和管理工具

## 📋 目录说明

| 数据库 | 类型 | 安装脚本 | 版本检测 | 帮助函数 |
|--------|------|----------|---------|---------|
| **MySQL** | 关系型 | ✅ | ❌ | ❌ |
| **PostgreSQL** | 关系型 | ✅ | ❌ | ❌ |
| **MongoDB** | 文档型 | ✅ | ❌ | ❌ |
| **Redis** | 键值存储 | ✅ | ❌ | ❌ |
| **Neo4j** | 图数据库 | ✅ | ❌ | ❌ |
| **TiDB** | 分布式关系型 | ✅ | ❌ | ❌ |
| **BanyanDB** | 时序数据库 | ✅ | ❌ | ❌ |

## 🚀 快速开始

### MySQL（关系型数据库）

```bash
cd database/mysql
# 查看具体使用方式
cat README

# 使用 Docker Compose 启动
docker-compose up -d
```

### Redis（缓存数据库）

```bash
cd database/redis
# 使用 Docker Compose 启动
docker-compose up -d
```

### MongoDB（文档数据库）

```bash
cd database/mongodb
# 安装 MongoDB
./install.sh

# 备份数据
./mongodb_backup.sh
```

### PostgreSQL（关系型数据库）

```bash
cd database/postgresql
# 安装 PostgreSQL
./install.sh
```

### TiDB（分布式关系型数据库）

```bash
cd database/tidb
# 安装 TiDB
./install-tidb.sh

# 启动 TiDB
./startup.sh

# 停止 TiDB
./stop.sh
```

### Neo4j（图数据库）

```bash
cd database/neo4j
# 使用 Docker Compose 启动
docker-compose up -d
```

### BanyanDB（时序数据库）

```bash
cd database/banyandb
# 查看具体使用方式
cat README

# 使用 Docker Compose 启动
docker-compose up -d
```

## 🔧 详细说明

### 1. MySQL

**类型**: 关系型数据库管理系统

**特点**:
- 最流行的开源关系型数据库
- 支持事务、存储引擎
- 丰富的生态系统
- 企业级特性

**适用场景**:
- Web 应用后端
- 企业级应用
- 数据仓库
- 事务处理系统

**目录结构**:
```
mysql/
├── bin/              # 管理脚本
├── conf/             # 配置文件
├── docker-compose.yml # Docker 部署配置
└── README            # 使用说明
```

**常用操作**:
```bash
# 连接 MySQL
mysql -u root -p

# 创建数据库
CREATE DATABASE mydb;

# 导入 SQL 文件
mysql -u root -p mydb < backup.sql

# 备份数据库
mysqldump -u root -p mydb > backup.sql
```

### 2. PostgreSQL

**类型**: 高级开源关系型数据库

**特点**:
- 完整的事务支持
- 丰富的数据类型
- 强大的扩展性
- 高性能和可靠性

**适用场景**:
- 复杂查询需求
- 地理信息系统
- 大型企业应用
- 数据分析

**常用操作**:
```bash
# 连接 PostgreSQL
psql -U postgres

# 创建数据库
CREATE DATABASE mydb;

# 导入 SQL 文件
psql -U postgres -d mydb < backup.sql

# 备份数据库
pg_dump -U postgres mydb > backup.sql
```

### 3. MongoDB

**类型**: 文档型 NoSQL 数据库

**特点**:
- 灵活的文档模型
- 高性能
- 水平扩展
- 丰富的查询语言

**适用场景**:
- 内容管理系统
- 移动应用后端
- 大数据存储
- 实时分析

**目录结构**:
```
mongodb/
├── install.sh           # 安装脚本
└── mongodb_backup.sh    # 备份脚本
```

**常用操作**:
```bash
# 连接 MongoDB
mongo

# 创建数据库
use mydb

# 插入文档
db.users.insert({name: "John"})

# 查询文档
db.users.find()

# 备份数据库
mongodump --db mydb --out /backup
```

### 4. Redis

**类型**: 内存键值存储数据库

**特点**:
- 极高性能
- 丰富的数据结构
- 持久化支持
- 高可用性

**适用场景**:
- 缓存系统
- 会话存储
- 消息队列
- 实时排行榜

**目录结构**:
```
redis/
├── bin/                 # 管理脚本
├── conf/                # 配置文件
└── docker-compose.yml   # Docker 部署配置
```

**常用操作**:
```bash
# 连接 Redis
redis-cli

# 设置键值
SET key value

# 获取值
GET key

# 列出所有键
KEYS *
```

### 5. Neo4j

**类型**: 图数据库

**特点**:
- 原生图存储
- Cypher 查询语言
- 关系型数据处理
- 社交网络分析

**适用场景**:
- 社交网络
- 推荐系统
- 知识图谱
- 欺诈检测

**常用操作**:
```bash
# 连接 Neo4j
cypher-shell

# 创建节点
CREATE (p:Person {name: 'Alice'})

# 查询节点
MATCH (p:Person) RETURN p

# 创建关系
MATCH (a:Person), (b:Person)
WHERE a.name = 'Alice' AND b.name = 'Bob'
CREATE (a)-[r:KNOWS]->(b)
```

### 6. TiDB

**类型**: 分布式关系型数据库

**特点**:
- MySQL 兼容
- 水平扩展
- 高可用性
- HTAP 能力

**适用场景**:
- 大规模数据存储
- 高并发场景
- 金融级应用
- 云原生应用

**目录结构**:
```
tidb/
├── install-tidb.sh     # 安装脚本
├── startup.sh          # 启动脚本
├── stop.sh             # 停止脚本
├── backup.sh           # 备份脚本
├── export.sh           # 导出脚本
└── import.sh           # 导入脚本
```

**常用操作**:
```bash
# 连接 TiDB (兼容 MySQL)
mysql -u root -h 127.0.0.1 -P 4000

# 查看 TiDB 状态
./tidbctl status

# 数据备份
./backup.sh

# 数据恢复
./import.sh
```

### 7. BanyanDB

**类型**: 时序数据库

**特点**:
- 高性能时序数据存储
- 压缩存储
- 灵活的查询
- IoT 友好

**适用场景**:
- IoT 设备监控
- 性能监控
- 日志分析
- 指标收集

**目录结构**:
```
banyandb/
├── bin/                 # 管理脚本
├── conf/                # 配置文件
├── docker-compose.yml   # Docker 部署配置
└── README               # 使用说明
```

## 📊 数据库分类与对比

### 关系型数据库

| 数据库 | 特点 | 适用场景 | 优势 |
|--------|------|----------|------|
| **MySQL** | 成熟稳定 | Web 应用 | 生态丰富，社区庞大 |
| **PostgreSQL** | 功能强大 | 复杂查询 | 高级特性，扩展性强 |
| **TiDB** | 分布式 | 大规模数据 | 水平扩展，高可用 |

### NoSQL 数据库

| 数据库 | 类型 | 特点 | 适用场景 |
|--------|------|------|----------|
| **MongoDB** | 文档型 | 灵活模式 | 内容管理，移动应用 |
| **Redis** | 键值存储 | 高性能 | 缓存，会话，消息队列 |
| **Neo4j** | 图数据库 | 关系处理 | 社交网络，推荐系统 |
| **BanyanDB** | 时序数据库 | 时序数据 | IoT 监控，性能指标 |

## ⚙️ 环境配置

### Docker 部署

大部分数据库都支持 Docker 部署：

```bash
# MySQL Docker
docker run -d -p 3306:3306 --name mysql mysql:8.0

# Redis Docker
docker run -d -p 6379:6379 --name redis redis:7.0

# PostgreSQL Docker
docker run -d -p 5432:5432 --name postgres postgres:15

# MongoDB Docker
docker run -d -p 27017:27017 --name mongo mongo:7.0
```

### 数据库连接配置

**通用配置模板**:
```yaml
# application.yml (Spring Boot)
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mydb
    username: root
    password: password
    driver-class-name: com.mysql.cj.jdbc.Driver
```

**连接字符串示例**:
```
MySQL:        mysql://user:pass@localhost:3306/dbname
PostgreSQL:   postgresql://user:pass@localhost:5432/dbname
MongoDB:      mongodb://user:pass@localhost:27017/dbname
Redis:        redis://localhost:6379
Neo4j:        bolt://localhost:7687
```

## 🔗 相关链接

### 官方网站
- [MySQL 官方网站](https://www.mysql.com/)
- [PostgreSQL 官方网站](https://www.postgresql.org/)
- [MongoDB 官方网站](https://www.mongodb.com/)
- [Redis 官方网站](https://redis.io/)
- [Neo4j 官方网站](https://neo4j.com/)
- [TiDB 官方网站](https://www.pingcap.com/)
- [BanyanDB 官方网站](https://banyandb.com/)

### 文档资源
- [MySQL 文档](https://dev.mysql.com/doc/)
- [PostgreSQL 文档](https://www.postgresql.org/docs/)
- [MongoDB 文档](https://docs.mongodb.com/)
- [Redis 文档](https://redis.io/documentation)
- [Neo4j 文档](https://neo4j.com/docs/)
- [TiDB 文档](https://docs.pingcap.com/)
- [BanyanDB 文档](https://banyandb.com/docs/)

## ❓ 常见问题

### Q: 如何选择合适的数据库？

**A**: 根据应用场景选择：

- **关系型数据**: MySQL、PostgreSQL
- **缓存和会话**: Redis
- **文档和灵活模式**: MongoDB
- **关系和图数据**: Neo4j
- **时序数据**: BanyanDB
- **大规模分布式**: TiDB

### Q: 如何备份数据库？

**A**: 各数据库备份方式：

```bash
# MySQL 备份
mysqldump -u root -p mydb > backup.sql

# PostgreSQL 备份
pg_dump -U postgres mydb > backup.sql

# MongoDB 备份
mongodump --db mydb --out /backup

# Redis 备份
redis-cli --rdb /backup/dump.rdb
```

### Q: 如何恢复数据库？

**A**: 数据库恢复方式：

```bash
# MySQL 恢复
mysql -u root -p mydb < backup.sql

# PostgreSQL 恢复
psql -U postgres -d mydb < backup.sql

# MongoDB 恢复
mongorestore --db mydb /backup/mydb

# Redis 恢复
redis-cli --rdb /backup/dump.rdb
```

### Q: 如何优化数据库性能？

**A**: 通用优化建议：

- 创建适当的索引
- 优化查询语句
- 配置连接池
- 使用缓存机制
- 定期维护和清理
- 监控数据库性能

### Q: 如何设置数据库集群？

**A**: 高可用配置：

- **MySQL**: 主从复制、MHA、Galera Cluster
- **PostgreSQL**: 流复制、Patroni
- **MongoDB**: 副本集、分片集群
- **Redis**: Sentinel、Cluster
- **TiDB**: 原生分布式架构

## 📝 最佳实践

### 安全配置

```bash
# 创建专用数据库用户
CREATE USER 'appuser'@'%' IDENTIFIED BY 'strong_password';

# 授予最小权限
GRANT SELECT, INSERT, UPDATE ON mydb.* TO 'appuser'@'%';

# 定期更新密码
ALTER USER 'appuser'@'%' IDENTIFIED BY 'new_strong_password';
```

### 性能优化

```sql
-- 创建索引
CREATE INDEX idx_username ON users(username);

-- 优化查询
EXPLAIN SELECT * FROM users WHERE username = 'john';

-- 分析查询计划
EXPLAIN ANALYZE SELECT * FROM users WHERE id = 1;
```

### 监控和日志

```bash
# 查看数据库状态
SHOW PROCESSLIST;  -- MySQL
SELECT * FROM pg_stat_activity;  -- PostgreSQL

# 查看慢查询日志
cat /var/log/mysql/slow.log
```

## 🚧 TODO

- [ ] 为 MySQL/Redis 等添加帮助函数
- [ ] 添加数据库性能监控脚本
- [ ] 添加数据库自动备份脚本
- [ ] 添加数据库集群配置模板
- [ ] 添加数据库迁移工具
- [ ] 添加数据库连接池配置
- [ ] 添加数据库安全加固脚本
- [ ] 添加数据库故障恢复指南

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。
# Java 环境管理脚本

> Java 开发和服务器环境的自动化安装和管理工具集合

## 📋 目录说明

| 目录/文件 | 说明 | 状态 |
|----------|------|------|
| `java-env-setup.sh` | Java环境一键安装配置脚本 | ✅ |
| `jdk/` | JDK 安装和管理工具 | ✅ |
| `arthas/` | Arthas Java 诊断工具 | ✅ |
| `build-tools/` | Java 构建工具集合 | ✅ |
| `java-app/` | Java 应用生命周期管理脚本 | ✅ |

## 🚀 快速开始

### 一键安装 Java 开发环境

```bash
cd java
./java-env-setup.sh --dev
```

### 一键安装 Java 服务器环境

```bash
cd java
./java-env-setup.sh --server
```

### 自动安装推荐软件

```bash
./java-env-setup.sh --auto
```

## 📜 脚本列表

### 主脚本

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `java-env-setup.sh` | Java环境一键安装配置脚本 | ✅ | ✅ |

### JDK 安装

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `jdk/install-jdk.sh` | JDK安装脚本 | ✅ | ✅ |
| `jdk/uninstall-jdk.sh` | JDK卸载脚本 | ✅ | ✅ |
| `jdk/import_cert.sh` | SSL证书导入工具 | ❌ | ❌ |

### 诊断工具

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `arthas/install-arthas.sh` | Arthas诊断工具安装 | ✅ | ✅ |
| `arthas/arthas.sh` | Arthas工具启动脚本 | ❌ | ❌ |

### 构建工具

#### Maven

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `build-tools/maven/maven.sh` | Maven安装脚本 | ✅ | ✅ |
| `build-tools/maven/clean-maven.sh` | Maven清理脚本 | ❌ | ❌ |
| `build-tools/maven/mvnd.sh` | mvnd启动脚本 | ❌ | ❌ |
| `build-tools/maven/deploy-maven.bat` | Maven部署脚本（Windows） | ❌ | ❌ |

#### Gradle

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `build-tools/gradle/install-gradle.sh` | Gradle安装脚本 | ✅ | ✅ |

#### Maven Daemon

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `build-tools/mvnd/install-mvnd.sh` | mvnd安装脚本 | ✅ | ✅ |

### 应用管理

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `java-app/deploy.sh` | 应用部署脚本（支持增量部署、备份、回滚） | ❌ | ✅ |
| `java-app/package.sh` | Maven构建脚本（支持依赖分析） | ❌ | ✅ |
| `java-app/start.sh` | 应用启动脚本（支持监控和端口检测） | ❌ | ✅ |
| `java-app/status.sh` | 应用状态检查和批量管理 | ❌ | ✅ |
| `java-app/stop.sh` | 应用停止脚本（支持优雅停止和强制停止） | ❌ | ✅ |

## 🔧 详细说明

### java-env-setup.sh - Java环境一键安装

**功能**：根据用户选择的环境类型（开发环境/服务器环境），推荐并自动安装所需的软件

**用法**：
```bash
./java-env-setup.sh [选项]

选项:
    --dev          安装Java开发环境（推荐JDK、Git、Maven、Gradle、Arthas、IDE等）
    --server       安装Java服务器环境（推荐JDK、Maven、Arthas、中间件、数据库等）
    --auto         自动安装推荐软件（跳过选择确认）
    -h, --help     显示帮助信息
```

**开发环境推荐软件**：
- **必需**：JDK、Git
- **推荐**：Maven、Gradle、Arthas
- **可选**：mvnd、IntelliJ IDEA、Eclipse、VS Code

**服务器环境推荐软件**：
- **必需**：JDK
- **推荐**：Maven、Arthas、Nacos、Sentinel、Seata、RocketMQ、Redis、MySQL、Prometheus、Grafana、SkyWalking
- **可选**：ZooKeeper

### JDK 安装

**安装JDK**：
```bash
./jdk/install-jdk.sh
```

**指定版本安装**：
```bash
./jdk/install-jdk.sh 17
```

**卸载JDK**：
```bash
./jdk/uninstall-jdk.sh
```

**查看版本**：
```bash
./jdk/install-jdk.sh --version
```

### Arthas 诊断工具

**安装Arthas**：
```bash
./arthas/install-arthas.sh
```

**查看版本**：
```bash
./arthas/install-arthas.sh --version
```

**启动Arthas**：
```bash
./arthas/arthas.sh
```

### 构建工具

#### Maven
```bash
./build-tools/maven/maven.sh
./build-tools/maven/maven.sh --version
./build-tools/maven/maven.sh --mirror tencent
./build-tools/maven/maven.sh --repo ~/maven-repo
```

#### Gradle
```bash
./build-tools/gradle/install-gradle.sh
./build-tools/gradle/install-gradle.sh --version
```

#### Maven Daemon（mvnd）
```bash
./build-tools/mvnd/install-mvnd.sh
./build-tools/mvnd/install-mvnd.sh --version
```

### Java 应用管理

**部署应用**：
```bash
cd java-app
./deploy.sh --services user-service,order-service
```

**构建应用**：
```bash
cd java-app
./package.sh --module user-service
```

**启动应用**：
```bash
cd java-app
./start.sh -j "-Xms512m -Xmx1024m"
```

**查看状态**：
```bash
cd java-app
./status.sh --sort-by status --filter running
```

**停止应用**：
```bash
cd java-app
./stop.sh --force
```

## ⚙️ 配置说明

### 环境变量

脚本支持以下环境变量：

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `JAVA_HOME` | Java安装目录 | 自动检测 |
| `MAVEN_OPTS` | Maven JVM选项 | `-Xmx2048m` |
| `GRADLE_OPTS` | Gradle JVM选项 | `-Xmx2048m` |

### 配置文件

| 配置文件 | 说明 |
|---------|------|
| `~/.m2/settings.xml` | Maven配置文件 |
| `~/.gradle/gradle.properties` | Gradle配置文件 |
| `~/.arthas/` | Arthas配置目录 |

## 📊 Java开发环境分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **运行环境** | JDK | ✅ | jdk/install-jdk.sh |
| | JRE | ✅ (JDK包含) | - |
| | GraalVM | ❌ | - |
| **构建工具** | Maven | ✅ | build-tools/maven/maven.sh |
| | Gradle | ✅ | build-tools/gradle/install-gradle.sh |
| | mvnd | ✅ | build-tools/mvnd/install-mvnd.sh |
| | Ant | ❌ | - |
| **应用服务器** | Tomcat | ❌ | - |
| | Jetty | ❌ | - |
| | WildFly | ❌ | - |
| **代码质量** | Checkstyle | ❌ | - |
| | PMD | ❌ | - |
| | SpotBugs | ❌ | - |
| | SonarQube Scanner | ⚠️ | - |
| **诊断工具** | Arthas | ✅ | arthas/install-arthas.sh |
| | VisualVM | ❌ | - |
| | JProfiler | ❌ | - |
| **测试框架** | JUnit | ❌ | - |
| | TestNG | ❌ | - |
| | Mockito | ❌ | - |
| | Cucumber | ❌ | - |
| **性能测试** | JMeter | ⚠️ | - |
| | Gatling | ❌ | - |
| | Locust | ✅ | ../locust/ (支持Java测试) |
| **框架脚手架** | Spring Boot | ⚠️ | java-app/ (只有部署脚本) |
| | Spring Initializr | ❌ | - |
| | Maven Archetype | ❌ | - |
| **容器化** | Docker | ⚠️ | ../docker/ (通用，非Java专用) |
| | Docker Compose | ⚠️ | ../docker/ (通用，非Java专用) |
| | Kubernetes | ⚠️ | ../docker/ (通用，非Java专用) |
| **配置管理** | Nacos | ⚠️ | - |
| | Consul | ❌ | - |
| | ZooKeeper | ⚠️ | - |
| **服务注册** | Eureka | ❌ | - |
| | Consul | ❌ | - |
| **分布式追踪** | SkyWalking | ✅ | ../apm/skywalking/bin/install.sh |
| | Zipkin | ❌ | - |
| | Jaeger | ❌ | - |
| **日志系统** | ELK Stack | ❌ | - |
| | Logback | ❌ | - |
| | Log4j2 | ❌ | - |
| **消息中间件** | RocketMQ | ✅ | ../mq/rocketmq/bin/install.sh |
| | Kafka | ⚠️ | ../mq/kafka/ |
| | RabbitMQ | ⚠️ | ../mq/activemq/ |
| **API文档** | Swagger/OpenAPI | ❌ | - |
| | Javadoc | ❌ | - |
| **缓存** | Redis | ✅ | ../database/redis/bin/install.sh |
| | Caffeine | ❌ | - |
| | Ehcache | ❌ | - |
| **连接池** | HikariCP | ❌ | - |
| | Druid | ⚠️ | ../druid/druid_encrypt_pwd.sh |
| **数据库** | MySQL | ✅ | ../database/mysql/bin/install.sh |
| | PostgreSQL | ⚠️ | ../database/postgresql/ |
| | MongoDB | ⚠️ | ../database/mongodb/ |
| | Redis | ✅ | ../database/redis/bin/install.sh |
| **CI/CD** | Jenkins | ⚠️ | ../cicd/jenkins/ |
| | GitLab CI | ⚠️ | - |
| **IDE** | IntelliJ IDEA | ✅ | ../ide/install-intellij-idea.sh |
| | Eclipse | ✅ | ../ide/install-eclipse.sh |
| | VS Code | ✅ | ../ide/install-vscode.sh |
| | NetBeans | ❌ | - |

## ❓ 常见问题

### Q: 如何切换多个JDK版本？

**A**: 脚本默认安装到 `/opt/java/` 目录，可以通过以下方式切换：

```bash
# 临时切换
export JAVA_HOME=/opt/java/jdk-17
export PATH=$JAVA_HOME/bin:$PATH

# 永久切换（添加到 ~/.bashrc 或 ~/.zshrc）
echo 'export JAVA_HOME=/opt/java/jdk-17' >> ~/.bashrc
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> ~/.bashrc
```

### Q: 如何优化Maven构建速度？

**A**: 推荐使用 mvnd（Maven Daemon）：

```bash
# 安装 mvnd
./build-tools/mvnd/install-mvnd.sh

# 使用 mvnd 构建
mvnd clean package
```

### Q: 如何配置Maven镜像源？

**A**: 脚本会自动配置阿里云镜像源，如需自定义：

```bash
# 支持 aliyun、tencent、huawei、official
./build-tools/maven/maven.sh --mirror huawei
./build-tools/maven/maven.sh --mirror official
```

### Q: 如何使用Arthas诊断线上问题？

**A**: Arthas 提供了强大的诊断功能：

```bash
# 启动 Arthas
./arthas/arthas.sh

# 查看所有Java进程
./arthas/arthas.sh --select

# 常用命令
# 查看线程信息：thread
# 查看类加载情况：sc
# 查看类信息：sm
# 热更新代码：jad/mc/redefine
```

### Q: 如何配置SkyWalking Agent？

**A**: java-app/start.sh 脚本会自动检测并配置SkyWalking Agent：

```bash
# 脚本会自动：
# 1. 检测SkyWalking安装路径
# 2. 复制Agent配置到应用目录
# 3. 配置服务名称和后端地址
# 4. 添加JVM参数启动应用
```

### Q: 如何回滚应用部署？

**A**: deploy.sh 脚本支持自动回滚：

```bash
# 使用回滚参数部署
./deploy.sh --rollback

# 或者手动选择备份版本
./deploy.sh --services user-service --backup-dir /path/to/backups
```

## 🔗 相关链接

- [Java 官方网站](https://www.java.com/)
- [Maven 官方网站](https://maven.apache.org/)
- [Gradle 官方网站](https://gradle.org/)
- [Arthas 官方文档](https://arthas.aliyun.com/)
- [SkyWalking 官方网站](https://skywalking.apache.org/)

## 📝 注意事项

1. **权限要求**：大部分安装脚本需要 root 权限，请使用 `sudo` 执行
2. **网络要求**：在线安装需要稳定的网络连接
3. **版本兼容性**：请确保安装的JDK版本与应用要求兼容
4. **备份重要**：在卸载或升级前请备份重要配置
5. **测试环境**：建议先在测试环境验证后再用于生产环境

## 🚧 TODO

- [ ] 添加 Tomcat 安装脚本
- [ ] 添加 Jetty 安装脚本
- [ ] 添加代码质量工具（Checkstyle、PMD、SpotBugs）
- [ ] 完善 IDE 集成脚本
- [ ] 添加性能测试工具（JMeter、Gatling）
- [ ] 添加 Spring Boot 项目脚手架
- [ ] 添加 Dockerfile 模板
- [ ] 添加日志系统配置模板

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。

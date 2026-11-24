#!/bin/bash
# Apache Spark - 通用大数据计算引擎
# 功能：批处理、流处理、SQL查询、机器学习、图计算
# 官方文档：https://spark.apache.org/
# GitHub: https://github.com/apache/spark

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
SPARK_VERSION="3.5.0"
SPARK_HADOOP_VERSION="3"
SPARK_INSTALL_DIR="/opt/spark"
SPARK_URL="https://downloads.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop${SPARK_HADOOP_VERSION}.tgz"

echo -e "${GREEN}=== Apache Spark 大数据计算引擎 安装脚本 ===${NC}"

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo -e "${RED}错误: 未找到Java环境，请先安装Java 8+${NC}"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2)
echo -e "${YELLOW}Java版本: ${JAVA_VERSION}${NC}"

# 设置JAVA_HOME
if [ -z "$JAVA_HOME" ]; then
    JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    export JAVA_HOME
fi
echo -e "${YELLOW}JAVA_HOME: ${JAVA_HOME}${NC}"

# 创建安装目录
sudo mkdir -p ${SPARK_INSTALL_DIR}

# 下载Spark
TEMP_DIR="/tmp/spark"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [ ! -f "spark-${SPARK_VERSION}-bin-hadoop${SPARK_HADOOP_VERSION}.tgz" ]; then
    echo -e "${YELLOW}下载Apache Spark ${SPARK_VERSION}...${NC}"
    curl -fsSL -o "spark-${SPARK_VERSION}-bin-hadoop${SPARK_HADOOP_VERSION}.tgz" ${SPARK_URL}
fi

# 解压
if [ -d "${SPARK_INSTALL_DIR}/spark-${SPARK_VERSION}" ]; then
    echo -e "${YELLOW}Spark已安装，删除旧版本...${NC}"
    sudo rm -rf "${SPARK_INSTALL_DIR}/spark-${SPARK_VERSION}"
fi

echo -e "${YELLOW}解压到 ${SPARK_INSTALL_DIR}...${NC}"
sudo tar -xzf "spark-${SPARK_VERSION}-bin-hadoop${SPARK_HADOOP_VERSION}.tgz" -C ${SPARK_INSTALL_DIR}

# 创建软链接
sudo ln -sf ${SPARK_INSTALL_DIR}/spark-${SPARK_VERSION} ${SPARK_INSTALL_DIR}/current

# 配置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/spark.sh > /dev/null
# Apache Spark环境变量
export SPARK_HOME=/opt/spark/current
export PATH=\$PATH:\$SPARK_HOME/bin:\$SPARK_HOME/sbin
export PYSPARK_PYTHON=python3
EOF

source /etc/profile.d/spark.sh

# 创建配置文件
SPARK_CONF="${SPARK_INSTALL_DIR}/current/conf"

# spark-env.sh
cat << 'EOF' | sudo tee ${SPARK_CONF}/spark-env.sh > /dev/null
# Spark环境配置

# Java环境
export JAVA_HOME=${JAVA_HOME}

# 内存配置
export SPARK_DRIVER_MEMORY=2g
export SPARK_EXECUTOR_MEMORY=2g

# Spark主节点
# export SPARK_MASTER_HOST=hostname
# export SPARK_MASTER_PORT=7077

# 其他配置
# export SPARK_WORKER_CORES=2
# export SPARK_WORKER_MEMORY=4g
# export SPARK_WORKER_INSTANCES=1
EOF

# spark-defaults.conf
cat << 'EOF' | sudo tee ${SPARK_CONF}/spark-defaults.conf > /dev/null
# Spark默认配置

# 本地模式
spark.master                     local[*]

# 应用配置
spark.app.name                   SparkApp
spark.driver.memory              2g
spark.executor.memory            2g
spark.executor.cores             2

# 动态资源分配
spark.dynamicAllocation.enabled  false
spark.dynamicAllocation.minExecutors 1
spark.dynamicAllocation.maxExecutors 10

# 序列化
spark.serializer                 org.apache.spark.serializer.KryoSerializer

# 日志
spark.eventLog.enabled           true
spark.eventLog.dir               file:///tmp/spark-logs
spark.history.fs.logDirectory    file:///tmp/spark-logs

# 临时目录
spark.local.dir                  /tmp/spark-temp
EOF

# log4j.properties（降低日志级别）
cat << 'EOF' | sudo tee ${SPARK_CONF}/log4j.properties > /dev/null
# Log4j配置
log4j.rootCategory=WARN, console
log4j.appender.console=org.apache.log4j.ConsoleAppender
log4j.appender.console.target=System.err
log4j.appender.console.layout=org.apache.log4j.PatternLayout
log4j.appender.console.layout.ConversionPattern=%d{yy/MM/dd HH:mm:ss} %p %c{1}: %m%n
EOF

# 创建日志和临时目录
sudo mkdir -p /tmp/spark-logs /tmp/spark-temp
sudo chmod 777 /tmp/spark-logs /tmp/spark-temp

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/spark-shell > /dev/null
#!/bin/bash
# Spark Shell启动脚本

SPARK_HOME=/opt/spark/current

if [ ! -d "${SPARK_HOME}" ]; then
    echo "错误: Spark未安装"
    echo "请运行: install-spark.sh"
    exit 1
fi

${SPARK_HOME}/bin/spark-shell "$@"
EOF

sudo chmod +x /usr/local/bin/spark-shell

cat << 'EOF' | sudo tee /usr/local/bin/spark-submit > /dev/null
#!/bin/bash
# Spark提交脚本

SPARK_HOME=/opt/spark/current

if [ ! -d "${SPARK_HOME}" ]; then
    echo "错误: Spark未安装"
    echo "请运行: install-spark.sh"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "用法: spark-submit [选项] <应用程序> [应用参数]"
    echo ""
    echo "常用选项:"
    echo "  --master MASTER          Spark master URL"
    echo "  --deploy-mode MODE      部署模式 (client/cluster)"
    echo "  --class CLASS           主类 (Java/Scala应用)"
    echo "  --name NAME             应用名称"
    echo "  --jars JARS             额外的JAR包"
    echo "  --py-files PY_FILES     Python文件"
    echo "  --driver-memory MEM     Driver内存"
    echo "  --executor-memory MEM   Executor内存"
    echo "  --num-executors NUM     Executor数量"
    echo ""
    echo "示例:"
    echo "  spark-submit --master local[*] myapp.py"
    echo "  spark-submit --master spark://host:7077 myapp.jar"
    echo "  spark-submit --master yarn --deploy-mode cluster myapp.jar"
    exit 1
fi

${SPARK_HOME}/bin/spark-submit "$@"
EOF

sudo chmod +x /usr/local/bin/spark-submit

cat << 'EOF' | sudo tee /usr/local/bin/pyspark > /dev/null
#!/bin/bash
# PySpark启动脚本

SPARK_HOME=/opt/spark/current

if [ ! -d "${SPARK_HOME}" ]; then
    echo "错误: Spark未安装"
    echo "请运行: install-spark.sh"
    exit 1
fi

${SPARK_HOME}/bin/pyspark "$@"
EOF

sudo chmod +x /usr/local/bin/pyspark

cat << 'EOF' | sudo tee /usr/local/bin/spark-sql > /dev/null
#!/bin/bash
# Spark SQL启动脚本

SPARK_HOME=/opt/spark/current

if [ ! -d "${SPARK_HOME}" ]; then
    echo "错误: Spark未安装"
    echo "请运行: install-spark.sh"
    exit 1
fi

${SPARK_HOME}/bin/spark-sql "$@"
EOF

sudo chmod +x /usr/local/bin/spark-sql

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${SPARK_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  spark-master:
    image: bitnami/spark:3.5.0
    container_name: spark-master
    ports:
      - "8080:8080"
      - "7077:7077"
    environment:
      - SPARK_MODE=master
      - SPARK_RPC_AUTHENTICATION_ENABLED=no
      - SPARK_RPC_ENCRYPTION_ENABLED=no
      - SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED=no
      - SPARK_SSL_ENABLED=no
    volumes:
      - ./spark-data:/bitnami/spark
    restart: unless-stopped

  spark-worker:
    image: bitnami/spark:3.5.0
    container_name: spark-worker
    depends_on:
      - spark-master
    ports:
      - "8081:8081"
    environment:
      - SPARK_MODE=worker
      - SPARK_MASTER_URL=spark://spark-master:7077
      - SPARK_WORKER_MEMORY=2G
      - SPARK_WORKER_CORES=2
    volumes:
      - ./spark-data:/bitnami/spark
    restart: unless-stopped
EOF

# 创建示例Python应用
cat << 'EOF' | sudo tee ${SPARK_INSTALL_DIR}/examples/wordcount.py > /dev/null
#!/usr/bin/env python3
# Spark WordCount示例

from pyspark.sql import SparkSession

# 创建SparkSession
spark = SparkSession.builder \
    .appName("WordCount") \
    .master("local[*]") \
    .getOrCreate()

# 示例文本
text = """
Apache Spark is a unified analytics engine for large-scale data processing.
It provides high-level APIs in Java, Scala, Python and R.
Spark supports workloads such as batch processing, streaming, machine learning and graph processing.
"""

# 创建RDD
rdd = spark.sparkContext.parallelize(text.split())

# WordCount
word_counts = rdd.flatMap(lambda line: line.split(" ")) \
                 .map(lambda word: (word, 1)) \
                 .reduceByKey(lambda a, b: a + b) \
                 .sortBy(lambda x: x[1], ascending=False)

# 显示结果
print("Word Count Results:")
for word, count in word_counts.collect():
    print(f"{word}: {count}")

# 停止SparkSession
spark.stop()
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Apache Spark安装完成 ===${NC}"
echo -e "安装目录: ${SPARK_INSTALL_DIR}/current"
echo -e "配置文件: ${SPARK_CONF}"
echo -e "日志目录: /tmp/spark-logs"
echo ""
echo "常用命令:"
echo "  Spark Shell (Scala): spark-shell"
echo "  PySpark (Python): pyspark"
echo "  Spark SQL: spark-sql"
echo "  提交应用: spark-submit <app>"
echo ""
echo "示例应用:"
echo "  运行WordCount: spark-submit ${SPARK_INSTALL_DIR}/examples/wordcount.py"
echo ""
echo "Docker部署:"
echo "  cd ${SPARK_INSTALL_DIR}"
echo "  docker-compose up -d"
echo "  访问: http://localhost:8080"
echo ""
echo "卸载: sudo rm -rf ${SPARK_INSTALL_DIR} /usr/local/bin/spark-* /etc/profile.d/spark.sh"
echo ""
echo -e "${YELLOW}提示: 首次运行会下载依赖，请耐心等待${NC}"
echo -e "${YELLOW}建议: 根据实际需求调整内存配置${NC}"
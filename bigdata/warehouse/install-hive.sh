#!/bin/bash
# Apache Hive - 传统数仓工具
# 功能：数据仓库、SQL查询、数据ETL
# 官方文档：https://hive.apache.org/
# GitHub: https://github.com/apache/hive

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
HIVE_VERSION="3.1.3"
HADOOP_VERSION="3.3.4"
HIVE_INSTALL_DIR="/opt/hive"
HIVE_URL="https://downloads.apache.org/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz"

echo -e "${GREEN}=== Apache Hive 数据仓库工具 安装脚本 ===${NC}"

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

# 检查Hadoop环境
if [ -d "/opt/hadoop" ]; then
    HADOOP_HOME="/opt/hadoop"
    echo -e "${YELLOW}检测到Hadoop: ${HADOOP_HOME}${NC}"
else
    echo -e "${YELLOW}未检测到Hadoop，将使用本地模式${NC}"
    HADOOP_HOME="/opt/hadoop"
fi

# 创建安装目录
sudo mkdir -p ${HIVE_INSTALL_DIR}

# 下载Hive
TEMP_DIR="/tmp/hive"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [ ! -f "apache-hive-${HIVE_VERSION}-bin.tar.gz" ]; then
    echo -e "${YELLOW}下载Apache Hive ${HIVE_VERSION}...${NC}"
    curl -fsSL -o "apache-hive-${HIVE_VERSION}-bin.tar.gz" ${HIVE_URL}
fi

# 解压
if [ -d "${HIVE_INSTALL_DIR}/apache-hive-${HIVE_VERSION}-bin" ]; then
    echo -e "${YELLOW}Hive已安装，删除旧版本...${NC}"
    sudo rm -rf "${HIVE_INSTALL_DIR}/apache-hive-${HIVE_VERSION}-bin"
fi

echo -e "${YELLOW}解压到 ${HIVE_INSTALL_DIR}...${NC}"
sudo tar -xzf "apache-hive-${HIVE_VERSION}-bin.tar.gz" -C ${HIVE_INSTALL_DIR}

# 创建软链接
sudo ln -sf ${HIVE_INSTALL_DIR}/apache-hive-${HIVE_VERSION}-bin ${HIVE_INSTALL_DIR}/current

# 配置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/hive.sh > /dev/null
# Apache Hive环境变量
export HIVE_HOME=/opt/hive/current
export HIVE_CONF_DIR=\$HIVE_HOME/conf
export PATH=\$PATH:\$HIVE_HOME/bin
EOF

source /etc/profile.d/hive.sh

# 创建配置文件
HIVE_CONF="${HIVE_INSTALL_DIR}/current/conf"

# hive-site.xml
cat << 'EOF' | sudo tee ${HIVE_CONF}/hive-site.xml > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <!-- Metastore配置 -->
    <property>
        <name>javax.jdo.option.ConnectionURL</name>
        <value>jdbc:mysql://localhost:3306/metastore?createDatabaseIfNotExist=true&amp;useSSL=false</value>
        <description>JDBC connect string for a JDBC metastore</description>
    </property>

    <property>
        <name>javax.jdo.option.ConnectionDriverName</name>
        <value>com.mysql.cj.jdbc.Driver</value>
        <description>Driver class name for a JDBC metastore</description>
    </property>

    <property>
        <name>javax.jdo.option.ConnectionUserName</name>
        <value>hive</value>
        <description>Username to use against metastore database</description>
    </property>

    <property>
        <name>javax.jdo.option.ConnectionPassword</name>
        <value>hive</value>
        <description>Password to use against metastore database</description>
    </property>

    <!-- Warehouse目录 -->
    <property>
        <name>hive.metastore.warehouse.dir</name>
        <value>/user/hive/warehouse</value>
        <description>Location of default database for the warehouse</description>
    </property>

    <!-- 执行引擎 -->
    <property>
        <name>hive.execution.engine</name>
        <value>mr</value>
        <description>Exection engine: mr or tez or spark</description>
    </property>

    <!-- 资源配置 -->
    <property>
        <name>hive.exec.reducers.bytes.per.reducer</name>
        <value>256000000</value>
        <description>Size per reducer</description>
    </property>

    <!-- 临时目录 -->
    <property>
        <name>hive.exec.local.scratchdir</name>
        <value>/tmp/hive</value>
        <description>Local scratch space for Hive jobs</description>
    </property>

    <property>
        <name>hive.downloaded.resources.dir</name>
        <value>/tmp/hive/resources</value>
        <description>Temporary local directory for added resources in the remote file system</description>
    </property>

    <!-- 日志配置 -->
    <property>
        <name>hive.querylog.location</name>
        <value>/tmp/hive/querylog</value>
        <description>Location of Hive query logs</description>
    </property>

    <!-- 其他配置 -->
    <property>
        <name>hive.cli.print.header</name>
        <value>true</value>
        <description>Whether to print column names in query results</description>
    </property>

    <property>
        <name>hive.cli.print.current.db</name>
        <value>true</value>
        <description>Whether to print the current database name in the prompt</description>
    </property>

    <property>
        <name>hive.server2.thrift.bind.host</name>
        <value>0.0.0.0</value>
        <description>Bind host on which to run the HiveServer2 Thrift service</description>
    </property>

    <property>
        <name>hive.server2.thrift.port</name>
        <value>10000</value>
        <description>Port number of HiveServer2 Thrift interface</description>
    </property>

    <property>
        <name>hive.server2.webui.host</name>
        <value>0.0.0.0</value>
        <description>The host address the HiveServer2 WebUI will listen on</description>
    </property>

    <property>
        <name>hive.server2.webui.port</name>
        <value>10002</value>
        <description>The port the HiveServer2 WebUI will listen on</description>
    </property>
</configuration>
EOF

# hive-env.sh
cat << 'EOF' | sudo tee ${HIVE_CONF}/hive-env.sh > /dev/null
# Hive环境配置

# Hadoop配置
HADOOP_HOME=${HADOOP_HOME:-/opt/hadoop}

# Hive配置目录
export HIVE_CONF_DIR=${HIVE_CONF_DIR:-/opt/hive/current/conf}

# Java Home
export JAVA_HOME=${JAVA_HOME}

# HCatalog配置
export HIVE_AUX_JARS_PATH=${HIVE_HOME}/hcatalog/share/hcatalog

# 其他配置
export HIVE_OPTS="-hiveconf hive.metastore.schema.verification=false"
EOF

# 创建日志和临时目录
sudo mkdir -p /tmp/hive /tmp/hive/querylog /tmp/hive/resources
sudo chmod 777 /tmp/hive /tmp/hive/querylog /tmp/hive/resources

# 下载MySQL JDBC驱动
echo -e "${YELLOW}下载MySQL JDBC驱动...${NC}"
JDBC_VERSION="8.0.33"
JDBC_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java/${JDBC_VERSION}/mysql-connector-java-${JDBC_VERSION}.jar"

curl -fsSL -o ${HIVE_INSTALL_DIR}/current/lib/mysql-connector-java.jar ${JDBC_URL}

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/hive-shell > /dev/null
#!/bin/bash
# Hive CLI启动脚本

HIVE_HOME=/opt/hive/current

if [ ! -d "${HIVE_HOME}" ]; then
    echo "错误: Hive未安装"
    echo "请运行: install-hive.sh"
    exit 1
fi

${HIVE_HOME}/bin/hive "$@"
EOF

sudo chmod +x /usr/local/bin/hive-shell

cat << 'EOF' | sudo tee /usr/local/bin/hive-server > /dev/null
#!/bin/bash
# HiveServer2启动脚本

HIVE_HOME=/opt/hive/current

if [ ! -d "${HIVE_HOME}" ]; then
    echo "错误: Hive未安装"
    echo "请运行: install-hive.sh"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动HiveServer2..."
    ${HIVE_HOME}/bin/hive --service hiveserver2 &
    echo "HiveServer2已启动"
    echo "JDBC URL: jdbc:hive2://localhost:10000"
    echo "Web UI: http://localhost:10002"
elif [ "$1" == "stop" ]; then
    echo "停止HiveServer2..."
    pkill -f hiveserver2
    echo "HiveServer2已停止"
else
    echo "用法: hive-server {start|stop}"
fi
EOF

sudo chmod +x /usr/local/bin/hive-server

cat << 'EOF' | sudo tee /usr/local/bin/hive-metastore > /dev/null
#!/bin/bash
# Hive Metastore启动脚本

HIVE_HOME=/opt/hive/current

if [ ! -d "${HIVE_HOME}" ]; then
    echo "错误: Hive未安装"
    echo "请运行: install-hive.sh"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动Hive Metastore..."
    ${HIVE_HOME}/bin/hive --service metastore &
    echo "Hive Metastore已启动"
elif [ "$1" == "stop" ]; then
    echo "停止Hive Metastore..."
    pkill -f metastore
    echo "Hive Metastore已停止"
else
    echo "用法: hive-metastore {start|stop}"
fi
EOF

sudo chmod +x /usr/local/bin/hive-metastore

cat << 'EOF' | sudo tee /usr/local/bin/hive-beeline > /dev/null
#!/bin/bash
# Hive Beeline启动脚本

HIVE_HOME=/opt/hive/current

if [ ! -d "${HIVE_HOME}" ]; then
    echo "错误: Hive未安装"
    echo "请运行: install-hive.sh"
    exit 1
fi

${HIVE_HOME}/bin/beeline "$@"
EOF

sudo chmod +x /usr/local/bin/hive-beeline

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${HIVE_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  mysql:
    image: mysql:8.0
    container_name: hive-mysql
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: metastore
      MYSQL_USER: hive
      MYSQL_PASSWORD: hive
    ports:
      - "3306:3306"
    volumes:
      - ./mysql-data:/var/lib/mysql
    restart: unless-stopped

  hiveserver2:
    image: apache/hive:3.1.3
    container_name: hiveserver2
    depends_on:
      - mysql
    ports:
      - "10000:10000"
      - "10002:10002"
    environment:
      HIVE_SITE_CONF_javax_jdo_option_ConnectionURL: "jdbc:mysql://mysql:3306/metastore?createDatabaseIfNotExist=true&amp;useSSL=false"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionDriverName: "com.mysql.cj.jdbc.Driver"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionUserName: "hive"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionPassword: "hive"
      HIVE_SITE_CONF_hive_metastore_warehouse_dir: "/user/hive/warehouse"
    volumes:
      - ./hive-data:/user/hive/warehouse
      - ./hive-conf:/opt/hive/conf
    restart: unless-stopped

  metastore:
    image: apache/hive:3.1.3
    container_name: hive-metastore
    depends_on:
      - mysql
    environment:
      HIVE_SITE_CONF_javax_jdo_option_ConnectionURL: "jdbc:mysql://mysql:3306/metastore?createDatabaseIfNotExist=true&amp;useSSL=false"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionDriverName: "com.mysql.cj.jdbc.Driver"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionUserName: "hive"
      HIVE_SITE_CONF_javax_jdo_option_ConnectionPassword: "hive"
      SERVICE_OPTS: "-Dhive.metastore.schema.verification=false"
    command: /opt/hive/bin/hive --service metastore
    restart: unless-stopped
EOF

# 创建示例SQL脚本
cat << 'EOF' | sudo tee ${HIVE_INSTALL_DIR}/examples/sample_queries.hql > /dev/null
-- Hive示例查询

-- 创建数据库
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

-- 创建表
CREATE TABLE IF NOT EXISTS employees (
    id INT,
    name STRING,
    department STRING,
    salary DOUBLE
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ','
STORED AS TEXTFILE;

-- 插入示例数据
INSERT INTO employees VALUES
    (1, '张三', '研发部', 15000),
    (2, '李四', '市场部', 12000),
    (3, '王五', '研发部', 18000),
    (4, '赵六', '市场部', 13000),
    (5, '钱七', '人事部', 11000);

-- 查询数据
SELECT * FROM employees;

-- 聚合查询
SELECT department, COUNT(*) as count, AVG(salary) as avg_salary
FROM employees
GROUP BY department;

-- 创建分区表
CREATE TABLE IF NOT EXISTS sales (
    id INT,
    product STRING,
    amount DOUBLE,
    region STRING
)
PARTITIONED BY (year INT, month INT)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ','
STORED AS TEXTFILE;

-- 插入分区数据
INSERT INTO sales PARTITION(year=2024, month=1) VALUES
    (1, '产品A', 1000, '北京'),
    (2, '产品B', 1500, '上海'),
    (3, '产品A', 800, '广州');

-- 查询分区数据
SELECT * FROM sales WHERE year=2024 AND month=1;

-- 销售额统计
SELECT region, SUM(amount) as total_sales
FROM sales
WHERE year=2024 AND month=1
GROUP BY region;
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Apache Hive安装完成 ===${NC}"
echo -e "安装目录: ${HIVE_INSTALL_DIR}/current"
echo -e "配置文件: ${HIVE_CONF}"
echo -e "日志目录: /tmp/hive"
echo ""
echo "使用前准备:"
echo "  1. 确保MySQL已安装并运行"
echo "  2. 创建Hive元数据库: mysql -u root -p < ${HIVE_INSTALL_DIR}/examples/init_schema.sql"
echo "  3. 初始化Metastore: schematool -dbType mysql -initSchema"
echo ""
echo "常用命令:"
echo "  Hive CLI: hive-shell"
echo "  启动HiveServer2: hive-server start"
echo "  启动Metastore: hive-metastore start"
echo "  Beeline客户端: hive-beeline"
echo ""
echo "连接方式:"
echo "  CLI: hive-shell"
echo "  JDBC: jdbc:hive2://localhost:10000"
echo "  Beeline: hive-beeline -u jdbc:hive2://localhost:10000"
echo ""
echo "Docker部署:"
echo "  cd ${HIVE_INSTALL_DIR}"
echo "  docker-compose up -d"
echo "  访问: http://localhost:10002"
echo ""
echo "示例查询:"
echo "  hive-shell -f ${HIVE_INSTALL_DIR}/examples/sample_queries.hql"
echo ""
echo "卸载: sudo rm -rf ${HIVE_INSTALL_DIR} /usr/local/bin/hive-* /etc/profile.d/hive.sh"
echo ""
echo -e "${YELLOW}提示: Hive需要MySQL作为元数据库${NC}"
echo -e "${YELLOW}建议: 生产环境建议使用PostgreSQL作为元数据库${NC}"
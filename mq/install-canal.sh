#!/bin/bash
# Canal - MySQL binlog增量同步工具
# 功能：MySQL binlog解析、数据增量同步、数据同步到Kafka/消息队列
# 官方文档：https://github.com/alibaba/canal
# GitHub: https://github.com/alibaba/canal

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
CANAL_VERSION="1.1.7"
CANAL_INSTALL_DIR="/opt/canal"
CANAL_DATA_DIR="/data/canal"
CANAL_ADMIN_PORT="8089"
CANAL_INSTANCE_NAME="example"

echo -e "${GREEN}=== Canal MySQL binlog增量同步工具 安装脚本 ===${NC}"

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

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
else
    OS=$(uname -s)
    OS_VERSION=$(uname -r)
fi

echo -e "${YELLOW}检测到操作系统: ${OS} ${OS_VERSION}${NC}"

# 提示MySQL配置
echo -e "${YELLOW}=== MySQL配置要求 ===${NC}"
echo -e "${YELLOW}1. MySQL需要开启binlog${NC}"
echo -e "${YELLOW}2. MySQL配置示例:${NC}"
cat << 'EOF'
[mysqld]
log-bin=mysql-bin
binlog_format=ROW
binlog_row_image=FULL
server-id=1

# 创建Canal用户
CREATE USER 'canal'@'%' IDENTIFIED BY 'canal';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'canal'@'%';
FLUSH PRIVILEGES;
EOF

echo ""
read -p "MySQL已配置好binlog和用户吗? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}请先配置MySQL，然后重新运行此脚本${NC}"
    exit 1
fi

# 获取MySQL连接信息
read -p "MySQL主机地址 (默认: localhost): " MYSQL_HOST
MYSQL_HOST=${MYSQL_HOST:-localhost}

read -p "MySQL端口 (默认: 3306): " MYSQL_PORT
MYSQL_PORT=${MYSQL_PORT:-3306}

read -p "MySQL用户名 (默认: canal): " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-canal}

read -p "MySQL密码 (默认: canal): " MYSQL_PASSWORD
MYSQL_PASSWORD=${MYSQL_PASSWORD:-canal}

# 创建安装和数据目录
sudo mkdir -p ${CANAL_INSTALL_DIR} ${CANAL_DATA_DIR}/{conf,logs,meta}
sudo chmod 755 ${CANAL_INSTALL_DIR} ${CANAL_DATA_DIR}

# 下载Canal
TEMP_DIR="/tmp/canal"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [ ! -f "canal.deployer-${CANAL_VERSION}.tar.gz" ]; then
    echo -e "${YELLOW}下载Canal ${CANAL_VERSION}...${NC}"
    CANAL_URL="https://github.com/alibaba/canal/releases/download/canal-${CANAL_VERSION}/canal.deployer-${CANAL_VERSION}.tar.gz"
    curl -fsSL -o "canal.deployer-${CANAL_VERSION}.tar.gz" ${CANAL_URL}
fi

# 解压
if [ -d "${CANAL_INSTALL_DIR}/canal.deployer-${CANAL_VERSION}" ]; then
    echo -e "${YELLOW}Canal已安装，删除旧版本...${NC}"
    sudo rm -rf "${CANAL_INSTALL_DIR}/canal.deployer-${CANAL_VERSION}"
fi

echo -e "${YELLOW}解压到 ${CANAL_INSTALL_DIR}...${NC}"
sudo tar -xzf "canal.deployer-${CANAL_VERSION}.tar.gz" -C ${CANAL_INSTALL_DIR}

# 创建软链接
sudo ln -sf ${CANAL_INSTALL_DIR}/canal.deployer-${CANAL_VERSION} ${CANAL_INSTALL_DIR}/current

# 配置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/canal.sh > /dev/null
# Canal环境变量
export CANAL_HOME=/opt/canal/current
export PATH=\$PATH:\$CANAL_HOME/bin
EOF

source /etc/profile.d/canal.sh

# 配置canal.properties
CANAL_CONF="${CANAL_INSTALL_DIR}/current/conf"

cat << EOF | sudo tee ${CANAL_CONF}/canal.properties > /dev/null
# Canal Server配置

# 注册中心
# canal.register.ip = 
canal.port = 11111
canal.metrics.pull.port = 11112

# Canal admin配置
canal.admin.manager = 127.0.0.1:8089
canal.admin.port = 11110

# 数据存储
canal.instance.global.spring.xml.location = classpath:spring/file-instance.xml

# 实例扫描目录
canal.destinations = ${CANAL_INSTANCE_NAME}

# 其他配置
canal.serverMode = tcp
canal.instance.parser.parallelThreadSize = 16
canal.instance.parser.parallelBufferSize = 256
EOF

# 配置实例
INSTANCE_CONF="${CANAL_CONF}/${CANAL_INSTANCE_NAME}"

sudo mkdir -p ${INSTANCE_CONF}

cat << EOF | sudo tee ${INSTANCE_CONF}/instance.properties > /dev/null
# Canal Instance配置

# MySQL配置
canal.instance.master.address=${MYSQL_HOST}:${MYSQL_PORT}
canal.instance.master.journal.name=
canal.instance.master.position=
canal.instance.master.timestamp=
canal.instance.master.gtid=

# MySQL用户配置
canal.instance.dbUsername=${MYSQL_USER}
canal.instance.dbPassword=${MYSQL_PASSWORD}
canal.instance.connectionCharset=UTF-8
canal.instance.defaultDatabaseName=

# MySQL binlog配置
canal.instance.filter.regex=.*\\..*
canal.instance.filter.black.regex=
canal.mq.topic=example
canal.mq.partition=0

# 其他配置
canal.instance.connectionCharset=UTF-8
canal.instance.filter.table.error=true
canal.instance.filter.druid.ddl=true
canal.instance.filter.row=false
canal.instance.filter.dml=false
canal.instance.filter.dml=false
EOF

cat << 'EOF' | sudo tee ${INSTANCE_CONF}/meta.dat > /dev/null
# Canal Instance元数据
EOF

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/canal-server > /dev/null
#!/bin/bash
# Canal Server启动脚本

CANAL_HOME=/opt/canal/current

if [ ! -d "${CANAL_HOME}" ]; then
    echo "错误: Canal未安装"
    echo "请运行: install-canal.sh"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动Canal Server..."
    ${CANAL_HOME}/bin/startup.sh
    echo "Canal Server已启动"
    echo "Admin端口: 8089"
    echo "Client端口: 11111"
elif [ "$1" == "stop" ]; then
    echo "停止Canal Server..."
    ${CANAL_HOME}/bin/stop.sh
    echo "Canal Server已停止"
elif [ "$1" == "restart" ]; then
    echo "重启Canal Server..."
    ${CANAL_HOME}/bin/restart.sh
    echo "Canal Server已重启"
elif [ "$1" == "status" ]; then
    ${CANAL_HOME}/bin/status.sh
else
    echo "用法: canal-server {start|stop|restart|status}"
fi
EOF
sudo chmod +x /usr/local/bin/canal-server

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${CANAL_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  canal-server:
    image: canal/canal-server:v1.1.7
    container_name: canal-server
    ports:
      - "11111:11111"
      - "11112:11112"
      - "8089:8089"
    environment:
      - canal.auto.scan=false
      - canal.destinations=example
      - canal.instance.master.address=mysql:3306
      - canal.instance.dbUsername=canal
      - canal.instance.dbPassword=canal
      - canal.mq.topic=example
    volumes:
      - ./canal-data/conf:/home/admin/canal-server/conf
      - ./canal-data/logs:/home/admin/canal-server/logs
      - ./canal-data/meta:/home/admin/canal-server/meta
    depends_on:
      - mysql
    restart: unless-stopped

  mysql:
    image: mysql:8.0
    container_name: canal-mysql
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: canal_test
      MYSQL_USER: canal
      MYSQL_PASSWORD: canal
    ports:
      - "3306:3306"
    volumes:
      - ./mysql-data:/var/lib/mysql
      - ./mysql-conf:/etc/mysql/conf.d
    command: >
      --default-authentication-plugin=mysql_native_password
      --log-bin=mysql-bin
      --binlog-format=ROW
      --binlog-row-image=FULL
      --server-id=1
    restart: unless-stopped
EOF

# 创建MySQL配置文件
mkdir -p ${CANAL_INSTALL_DIR}/mysql-conf

cat << 'EOF' | sudo tee ${CANAL_INSTALL_DIR}/mysql-conf/my.cnf > /dev/null
[mysqld]
log-bin=mysql-bin
binlog-format=ROW
binlog-row-image=FULL
server-id=1
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF

# 创建示例客户端脚本
cat << 'EOF' | sudo tee ${CANAL_INSTALL_DIR}/examples/canal-client.py > /dev/null
#!/usr/bin/env python3
"""
Canal客户端示例
使用canal-python客户端订阅MySQL binlog
"""

import canal.client

# 创建Canal客户端
client = canal.client.CanalClient(host='127.0.0.1', port=11111)

# 连接Canal Server
client.connect()
client.check_valid()
client.subscribe('.*\\..*')

print("Canal客户端已连接，等待消息...")

# 持续拉取消息
while True:
    message = client.get(100)
    entries = message['entries']
    
    if not entries:
        continue
    
    for entry in entries:
        entry_type = entry['entryType']
        
        if entry_type == canal.client.EntryType.ROWDATA:
            print(f"=== RowData ===")
            print(f"Database: {entry['header']['schemaName']}")
            print(f"Table: {entry['header']['tableName']}")
            print(f"Event type: {entry['header']['eventType']}")
            
            # 获取变更数据
            row_data = entry['storeValue']
            if 'insertRows' in row_data:
                print("Insert rows:", row_data['insertRows'])
            if 'updateRows' in row_data:
                print("Update rows:", row_data['updateRows'])
            if 'deleteRows' in row_data:
                print("Delete rows:", row_data['deleteRows'])

# 断开连接
client.disconnect()
EOF

# 创建Kafka适配器配置
cat << 'EOF' | sudo tee ${CANAL_INSTALL_DIR}/examples/canal-to-kafka.properties > /dev/null
# Canal到Kafka的配置示例

# Kafka配置
kafka.bootstrap.servers=localhost:9092
kafka.topic=canal_binlog

# Canal配置
canal.instance.master.address=localhost:3306
canal.instance.dbUsername=canal
canal.instance.dbPassword=canal

# 数据过滤
canal.mq.topic=canal_binlog
canal.mq.partitionsNum=1
canal.mq.partitionHash=.*\\..*
EOF

# 创建同步到ClickHouse的配置
cat << 'EOF' | sudo tee ${CANAL_INSTALL_DIR}/examples/canal-to-clickhouse.sh > /dev/null
#!/bin/bash
# Canal同步到ClickHouse示例脚本

# Canal配置
CANAL_HOST="127.0.0.1"
CANAL_PORT="11111"
CANAL_DESTINATION="example"

# ClickHouse配置
CLICKHOUSE_HOST="127.0.0.1"
CLICKHOUSE_PORT="9000"
CLICKHOUSE_USER="default"
CLICKHOUSE_PASSWORD=""

# 表映射配置
# 格式: MySQL数据库.表名 -> ClickHouse数据库.表名
TABLE_MAPPINGS=(
    "testdb.users -> chdb.users"
    "testdb.orders -> chdb.orders"
)

echo "开始同步MySQL数据到ClickHouse..."

for mapping in "${TABLE_MAPPINGS[@]}"; do
    IFS=' -> ' read -r mysql_table clickhouse_table <<< "$mapping"
    
    echo "同步表: $mysql_table -> $clickhouse_table"
    
    # 这里可以使用canal-adapter或者自定义脚本
    # 示例：使用Canal Adapter同步
    # canal-adapter -c canal-to-clickhouse.yml
done

echo "同步完成"
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Canal安装完成 ===${NC}"
echo -e "安装目录: ${CANAL_INSTALL_DIR}"
echo -e "数据目录: ${CANAL_DATA_DIR}"
echo -e "配置目录: ${CANAL_CONF}"
echo ""
echo "MySQL连接信息:"
echo "  主机: ${MYSQL_HOST}"
echo "  端口: ${MYSQL_PORT}"
echo "  用户: ${MYSQL_USER}"
echo ""
echo "服务端口:"
echo "  Admin端口: 8089"
echo "  Client端口: 11111"
echo "  Metrics端口: 11112"
echo ""
echo "启动方式:"
echo "  启动: canal-server start"
echo "  停止: canal-server stop"
echo "  重启: canal-server restart"
echo "  状态: canal-server status"
echo ""
echo "Docker部署:"
echo "  cd ${CANAL_INSTALL_DIR}"
echo "  docker-compose up -d"
echo "  访问: http://localhost:8089"
echo ""
echo "使用场景:"
echo "  1. MySQL -> Kafka: 配置MQ适配器"
echo "  2. MySQL -> ClickHouse: 使用Canal Adapter"
echo "  3. MySQL -> Elasticsearch: 使用Canal Adapter"
echo "  4. MySQL -> Redis: 自定义客户端"
echo ""
echo "示例客户端:"
echo "  Python客户端: python3 ${CANAL_INSTALL_DIR}/examples/canal-client.py"
echo "  同步到ClickHouse: bash ${CANAL_INSTALL_DIR}/examples/canal-to-clickhouse.sh"
echo ""
echo "常见问题:"
echo "  1. 确保MySQL已开启binlog"
echo "  2. 确保Canal用户有REPLICATION权限"
echo "  3. 检查MySQL的server-id配置"
echo "  4. 查看Canal日志: tail -f ${CANAL_DATA_DIR}/logs/canal/canal.log"
echo ""
echo "卸载:"
echo "  停止: canal-server stop"
echo "  删除: sudo rm -rf ${CANAL_INSTALL_DIR} ${CANAL_DATA_DIR} /usr/local/bin/canal-server /etc/profile.d/canal.sh"
echo ""
echo -e "${YELLOW}提示: Canal需要MySQL开启binlog和REPLICATION权限${NC}"
echo -e "${YELLOW}建议: 生产环境使用Canal Adapter实现更丰富的同步功能${NC}"
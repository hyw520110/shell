#!/bin/bash
# ClickHouse - OLAP分析数据库
# 功能：实时OLAP分析、高性能列式存储、SQL查询
# 官方文档：https://clickhouse.com/
# GitHub: https://github.com/ClickHouse/ClickHouse

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
CLICKHOUSE_VERSION="23.12"
CLICKHOUSE_INSTALL_DIR="/opt/clickhouse"
CLICKHOUSE_DATA_DIR="/var/lib/clickhouse"
CLICKHOUSE_LOG_DIR="/var/log/clickhouse"

echo -e "${GREEN}=== ClickHouse OLAP分析数据库 安装脚本 ===${NC}"

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

# 根据操作系统选择安装方式
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${YELLOW}使用APT安装ClickHouse...${NC}"
    
    # 添加ClickHouse官方仓库
    sudo apt-get install -y apt-transport-https ca-certificates dirmngr
    sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 8919F6BD2B48D754
    
    echo "deb https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list
    sudo apt-get update
    
    # 安装ClickHouse
    sudo apt-get install -y clickhouse-server clickhouse-client
    
    CLICKHOUSE_BIN="/usr/bin/clickhouse"
    
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    echo -e "${YELLOW}使用YUM安装ClickHouse...${NC}"
    
    # 添加ClickHouse官方仓库
    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo
    
    # 安装ClickHouse
    sudo yum install -y clickhouse-server clickhouse-client
    
    CLICKHOUSE_BIN="/usr/bin/clickhouse"
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Homebrew安装ClickHouse...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}错误: 未找到Homebrew，请先安装Homebrew${NC}"
        exit 1
    fi
    
    brew install clickhouse
    
    CLICKHOUSE_BIN="/usr/local/bin/clickhouse"
    
else
    echo -e "${YELLOW}使用Docker安装ClickHouse...${NC}"
    
    # 创建安装目录
    sudo mkdir -p ${CLICKHOUSE_INSTALL_DIR}
    
    # 创建Docker Compose文件
    cat << 'EOF' | sudo tee ${CLICKHOUSE_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse-server
    ports:
      - "8123:8123"
      - "9000:9000"
      - "9004:9004"
      - "9009:9009"
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: default
      CLICKHOUSE_PASSWORD: ""
      CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: 1
    volumes:
      - ./data:/var/lib/clickhouse
      - ./logs:/var/log/clickhouse
      - ./config/config.xml:/etc/clickhouse-server/config.d/config.xml
      - ./config/users.xml:/etc/clickhouse-server/users.d/users.xml
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    restart: unless-stopped

  clickhouse-client:
    image: clickhouse/clickhouse-client:latest
    container_name: clickhouse-client
    depends_on:
      - clickhouse
    command: clickhouse-client --host clickhouse
    stdin_open: true
    tty: true
EOF
    
    # 创建配置目录
    sudo mkdir -p ${CLICKHOUSE_INSTALL_DIR}/config
    
    # 配置文件
    cat << 'EOF' | sudo tee ${CLICKHOUSE_INSTALL_DIR}/config/config.xml > /dev/null
<?xml version="1.0"?>
<yandex>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse/clickhouse-server.log</log>
        <errorlog>/var/log/clickhouse/clickhouse-server.err.log</errorlog>
        <size>1000M</size>
        <count>10</count>
    </logger>

    <listen_host>::</listen_host>

    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <mysql_port>9004</mysql_port>
    <postgresql_port>9005</postgresql_port>

    <max_connections>4096</max_connections>
    <keep_alive_timeout>3</keep_alive_timeout>

    <max_concurrent_queries>100</max_concurrent_queries>

    <uncompressed_cache_size>8589934592</uncompressed_cache_size>
    <mark_cache_size>5368709120</mark_cache_size>

    <path>/var/lib/clickhouse/</path>
    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>

    <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>

    <users_config>users.xml</users_config>
    <default_profile>default</default_profile>
    <default_database>default</default_database>

    <timezone>Asia/Shanghai</timezone>
</yandex>
EOF

    # 用户配置文件
    cat << 'EOF' | sudo tee ${CLICKHOUSE_INSTALL_DIR}/config/users.xml > /dev/null
<?xml version="1.0"?>
<yandex>
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <use_uncompressed_cache>0</use_uncompressed_cache>
            <load_balancing>random</load_balancing>
        </default>
        <readonly>
            <readonly>1</readonly>
        </readonly>
    </profiles>

    <users>
        <default>
            <password></password>
            <networks incl="networks" replace="replace">
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>

    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>

    <networks>
        <ip>::/0</ip>
    </networks>
</yandex>
EOF

    CLICKHOUSE_BIN="docker"
fi

# 创建数据目录
sudo mkdir -p ${CLICKHOUSE_DATA_DIR} ${CLICKHOUSE_LOG_DIR}
sudo chmod 777 ${CLICKHOUSE_DATA_DIR} ${CLICKHOUSE_LOG_DIR}

# 创建启动脚本（非Docker模式）
if [[ "$OS" != "darwin" ]]; then
    cat << 'EOF' | sudo tee /usr/local/bin/clickhouse-server > /dev/null
#!/bin/bash
# ClickHouse Server启动脚本

if [ "$1" == "start" ]; then
    echo "启动ClickHouse Server..."
    sudo clickhouse-server --config=/etc/clickhouse-server/config.xml --daemon
    echo "ClickHouse Server已启动"
elif [ "$1" == "stop" ]; then
    echo "停止ClickHouse Server..."
    sudo clickhouse-server --stop
    echo "ClickHouse Server已停止"
elif [ "$1" == "restart" ]; then
    echo "重启ClickHouse Server..."
    sudo clickhouse-server --restart
    echo "ClickHouse Server已重启"
else
    echo "用法: clickhouse-server {start|stop|restart}"
fi
EOF
    sudo chmod +x /usr/local/bin/clickhouse-server

    cat << 'EOF' | sudo tee /usr/local/bin/clickhouse-client > /dev/null
#!/bin/bash
# ClickHouse Client启动脚本

clickhouse-client "$@"
EOF
    sudo chmod +x /usr/local/bin/clickhouse-client
fi

# 创建Docker启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/clickhouse-docker > /dev/null
#!/bin/bash
# ClickHouse Docker启动脚本

CLICKHOUSE_DIR="/opt/clickhouse"

if [ ! -d "${CLICKHOUSE_DIR}" ]; then
    echo "错误: ClickHouse目录不存在: ${CLICKHOUSE_DIR}"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动ClickHouse Docker..."
    cd ${CLICKHOUSE_DIR}
    docker-compose up -d
    echo "ClickHouse Docker已启动"
    echo "HTTP接口: http://localhost:8123"
    echo "Native接口: localhost:9000"
elif [ "$1" == "stop" ]; then
    echo "停止ClickHouse Docker..."
    cd ${CLICKHOUSE_DIR}
    docker-compose down
    echo "ClickHouse Docker已停止"
elif [ "$1" == "restart" ]; then
    echo "重启ClickHouse Docker..."
    cd ${CLICKHOUSE_DIR}
    docker-compose restart
    echo "ClickHouse Docker已重启"
elif [ "$1" == "client" ]; then
    echo "连接ClickHouse客户端..."
    docker exec -it clickhouse-server clickhouse-client
else
    echo "用法: clickhouse-docker {start|stop|restart|client}"
fi
EOF
sudo chmod +x /usr/local/bin/clickhouse-docker

# 创建示例SQL脚本
cat << 'EOF' | sudo tee ${CLICKHOUSE_INSTALL_DIR}/examples/sample_queries.sql > /dev/null
-- ClickHouse示例查询

-- 创建数据库
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

-- 创建表
CREATE TABLE IF NOT EXISTS sales (
    id UInt32,
    product String,
    amount Decimal(10, 2),
    region String,
    sale_date Date
) ENGINE = MergeTree()
ORDER BY (sale_date, region);

-- 插入示例数据
INSERT INTO sales VALUES
    (1, '产品A', 1000.50, '北京', '2024-01-01'),
    (2, '产品B', 1500.75, '上海', '2024-01-02'),
    (3, '产品A', 800.25, '广州', '2024-01-03'),
    (4, '产品C', 2000.00, '深圳', '2024-01-04'),
    (5, '产品B', 1200.50, '北京', '2024-01-05'),
    (6, '产品A', 950.75, '上海', '2024-01-06'),
    (7, '产品C', 1800.25, '广州', '2024-01-07'),
    (8, '产品B', 1450.00, '深圳', '2024-01-08'),
    (9, '产品A', 1100.50, '北京', '2024-01-09'),
    (10, '产品C', 2100.75, '上海', '2024-01-10');

-- 查询数据
SELECT * FROM sales;

-- 聚合查询
SELECT 
    region,
    product,
    COUNT(*) as sales_count,
    SUM(amount) as total_amount,
    AVG(amount) as avg_amount
FROM sales
GROUP BY region, product
ORDER BY region, total_amount DESC;

-- 时间序列分析
SELECT 
    toDate(sale_date) as date,
    SUM(amount) as daily_sales
FROM sales
GROUP BY date
ORDER BY date;

-- 创建物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS sales_daily_mv
ENGINE = SummingMergeTree()
ORDER BY (date, region)
AS SELECT
    toDate(sale_date) as date,
    region,
    product,
    SUM(amount) as total_amount
FROM sales
GROUP BY date, region, product;

-- 查询物化视图
SELECT * FROM sales_daily_mv;

-- 创建分区表
CREATE TABLE IF NOT EXISTS sales_partitioned (
    id UInt32,
    product String,
    amount Decimal(10, 2),
    region String,
    sale_date Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (sale_date, region);

-- 插入数据到分区表
INSERT INTO sales_partitioned SELECT * FROM sales;

-- 查看分区信息
SELECT 
    partition,
    sum_rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'sales_partitioned'
AND active;

-- 性能测试
SELECT 
    count() as total_rows,
    sum(amount) as total_sales,
    avg(amount) as avg_sales
FROM sales
WHERE sale_date >= '2024-01-01' AND sale_date <= '2024-01-31';
EOF

# 显示安装信息
echo -e "${GREEN}=== ClickHouse安装完成 ===${NC}"
echo -e "安装目录: ${CLICKHOUSE_INSTALL_DIR}"
echo -e "数据目录: ${CLICKHOUSE_DATA_DIR}"
echo -e "日志目录: ${CLICKHOUSE_LOG_DIR}"
echo ""
echo "连接方式:"
echo "  HTTP接口: http://localhost:8123"
echo "  Native接口: localhost:9000"
echo "  MySQL接口: localhost:9004"
echo "  PostgreSQL接口: localhost:9005"
echo ""
echo "使用方式:"
if [[ "$OS" == "darwin" ]]; then
    echo "  启动: clickhouse-docker start"
    echo "  停止: clickhouse-docker stop"
    echo "  客户端: clickhouse-docker client"
else
    echo "  启动: clickhouse-server start"
    echo "  停止: clickhouse-server stop"
    echo "  客户端: clickhouse-client"
fi
echo ""
echo "示例查询:"
echo "  执行SQL: clickhouse-client --query 'SELECT 1'"
echo "  执行文件: clickhouse-client --queries-file ${CLICKHOUSE_INSTALL_DIR}/examples/sample_queries.sql"
echo ""
echo "卸载:"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo "  apt: sudo apt-get remove clickhouse-server clickhouse-client"
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    echo "  yum: sudo yum remove clickhouse-server clickhouse-client"
elif [[ "$OS" == "darwin" ]]; then
    echo "  brew: brew uninstall clickhouse"
fi
echo "  手动: sudo rm -rf ${CLICKHOUSE_INSTALL_DIR} ${CLICKHOUSE_DATA_DIR} ${CLICKHOUSE_LOG_DIR}"
echo ""
echo -e "${YELLOW}提示: ClickHouse需要足够的内存和磁盘空间${NC}"
echo -e "${YELLOW}建议: 生产环境配置ZooKeeper集群实现高可用${NC}"
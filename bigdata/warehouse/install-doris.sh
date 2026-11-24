#!/bin/bash
# Apache Doris - 实时分析数据库
# 功能：实时OLAP、极速查询、高并发、MPP架构
# 官方文档：https://doris.apache.org/
# GitHub: https://github.com/apache/doris

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
DORIS_VERSION="2.1.0"
DORIS_INSTALL_DIR="/opt/doris"
DORIS_DATA_DIR="/data/doris"
DORIS_LOG_DIR="/var/log/doris"
DORIS_FE_HTTP_PORT="8030"
DORIS_FE_QUERY_PORT="9030"
DORIS_BE_PORT="9060"

echo -e "${GREEN}=== Apache Doris 实时分析数据库 安装脚本 ===${NC}"

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo -e "${RED}错误: 未找到Java环境，请先安装Java 8+${NC}"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2)
echo -e "${YELLOW}Java版本: ${JAVA_VERSION}${NC}"

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

# 创建安装和数据目录
sudo mkdir -p ${DORIS_INSTALL_DIR} ${DORIS_DATA_DIR}/{fe,be,meta} ${DORIS_LOG_DIR}
sudo chmod 755 ${DORIS_INSTALL_DIR} ${DORIS_DATA_DIR} ${DORIS_LOG_DIR}

# 下载Doris
TEMP_DIR="/tmp/doris"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${YELLOW}下载Apache Doris ${DORIS_VERSION} for Linux...${NC}"
    DORIS_FILE="apache-doris-${DORIS_VERSION}-bin-x64.tar.gz"
    DORIS_URL="https://downloads.apache.org/doris/${DORIS_VERSION}/${DORIS_FILE}"
    
    if [ ! -f "${DORIS_FILE}" ]; then
        curl -fsSL -o "${DORIS_FILE}" ${DORIS_URL}
    fi
    
    # 解压
    if [ -d "${DORIS_INSTALL_DIR}/apache-doris-${DORIS_VERSION}-bin-x64" ]; then
        echo -e "${YELLOW}Doris已安装，删除旧版本...${NC}"
        sudo rm -rf "${DORIS_INSTALL_DIR}/apache-doris-${DORIS_VERSION}-bin-x64"
    fi
    
    echo -e "${YELLOW}解压到 ${DORIS_INSTALL_DIR}...${NC}"
    sudo tar -xzf "${DORIS_FILE}" -C ${DORIS_INSTALL_DIR}
    
    # 创建软链接
    sudo ln -sf ${DORIS_INSTALL_DIR}/apache-doris-${DORIS_VERSION}-bin-x64 ${DORIS_INSTALL_DIR}/current
    
elif [[ "$OS" == "darwin" ]]; then
    echo -e "${YELLOW}macOS系统，使用Docker部署Doris...${NC}"
    
    # 创建Docker Compose文件
    cat << 'EOF' | sudo tee ${DORIS_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  doris-fe:
    image: apache/doris:2.1.0-fe-x64
    container_name: doris-fe
    ports:
      - "8030:8030"
      - "9030:9030"
      - "9010:9010"
    environment:
      - FE_SERVERS=fe1:127.0.0.1:9010
      - FE_ID=1
    volumes:
      - ./doris-data/fe:/opt/apache-doris/fe/doris-meta
      - ./doris-data/log:/opt/apache-doris/fe/log
    command: /opt/apache-doris/fe/bin/start_fe.sh --daemon
    restart: unless-stopped

  doris-be:
    image: apache/doris:2.1.0-be-x64
    container_name: doris-be
    ports:
      - "9060:9060"
      - "8040:8040"
      - "9050:9050"
    environment:
      - FE_SERVERS=fe1:127.0.0.1:9010
      - BE_ADDR=127.0.0.1:9050
    volumes:
      - ./doris-data/be/storage:/opt/apache-doris/be/storage
      - ./doris-data/be/log:/opt/apache-doris/be/log
    command: /opt/apache-doris/be/bin/start_be.sh --daemon
    depends_on:
      - doris-fe
    restart: unless-stopped

  doris-init:
    image: apache/doris:2.1.0-fe-x64
    container_name: doris-init
    depends_on:
      - doris-fe
      - doris-be
    command: >
      sh -c "
        sleep 30 &&
        mysql -h doris-fe -P 9030 -uroot -e 'ALTER SYSTEM ADD BACKEND \"doris-be:9050\";'
      "
    restart: "no"
EOF
    
    DORIS_BIN="docker"
    FE_BIN="docker exec -it doris-fe"
else
    echo -e "${RED}错误: 不支持的操作系统${NC}"
    exit 1
fi

# 配置环境变量
if [[ "$OS" != "darwin" ]]; then
    cat << 'EOF' | sudo tee /etc/profile.d/doris.sh > /dev/null
# Apache Doris环境变量
export DORIS_HOME=/opt/doris/current
export PATH=\$PATH:\$DORIS_HOME/fe/bin:\$DORIS_HOME/be/bin
EOF
    
    source /etc/profile.d/doris.sh
    
    # 配置FE
    DORIS_FE_HOME="${DORIS_INSTALL_DIR}/current/fe"
    
    # fe.conf
    cat << 'EOF' | sudo tee ${DORIS_FE_HOME}/conf/fe.conf > /dev/null
# Doris FE配置

# 基础配置
http_port = 8030
query_port = 9030
edit_log_port = 9010
rpc_port = 9020

# 集群配置
priority_networks = 127.0.0.0/8
meta_dir = /data/doris/fe/meta

# 内存配置
JAVA_OPTS="-Xmx8g -Xms8g -Xmn4g -XX:+UseMembar -XX:SurvivorRatio=8 -XX:MaxTenuringThreshold=7"

# 审计日志
audit_log_dir = /var/log/doris/fe
audit_log_module = \${DORIS_HOME}/fe/conf/audit_module.xml

# 其他配置
enable_fqdn_check = true
enable_deploy_group = false
EOF
    
    # 配置BE
    DORIS_BE_HOME="${DORIS_INSTALL_DIR}/current/be"
    
    # be.conf
    cat << 'EOF' | sudo tee ${DORIS_BE_HOME}/conf/be.conf > /dev/null
# Doris BE配置

# 基础配置
be_port = 9060
webserver_port = 8040
heartbeat_service_port = 9050
brpc_port = 8060

# 集群配置
priority_networks = 127.0.0.0/8

# 数据目录
storage_root_path = /data/doris/be

# 内存配置
mem_limit = 80%
buffer_pool_limit = 20%

# 日志配置
sys_log_dir = /var/log/doris/be
sys_log_roll_mode = SIZE-MB-1024
sys_log_roll_num = 10

# 其他配置
max_compaction_threads = 4
max_tablet_version_num = 1000
default_rowset_type = alpha
EOF
    
    # 创建启动脚本
    cat << 'EOF' | sudo tee /usr/local/bin/doris-fe > /dev/null
#!/bin/bash
# Doris FE启动脚本

DORIS_HOME=/opt/doris/current

if [ ! -d "${DORIS_HOME}/fe" ]; then
    echo "错误: Doris FE未安装"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动Doris FE..."
    ${DORIS_HOME}/fe/bin/start_fe.sh --daemon
    echo "Doris FE已启动"
    echo "Web UI: http://localhost:8030"
    echo "Query Port: 9030"
elif [ "$1" == "stop" ]; then
    echo "停止Doris FE..."
    ${DORIS_HOME}/fe/bin/stop_fe.sh
    echo "Doris FE已停止"
elif [ "$1" == "status" ]; then
    ${DORIS_HOME}/fe/bin/status_fe.sh
else
    echo "用法: doris-fe {start|stop|status}"
fi
EOF
    sudo chmod +x /usr/local/bin/doris-fe
    
    cat << 'EOF' | sudo tee /usr/local/bin/doris-be > /dev/null
#!/bin/bash
# Doris BE启动脚本

DORIS_HOME=/opt/doris/current

if [ ! -d "${DORIS_HOME}/be" ]; then
    echo "错误: Doris BE未安装"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动Doris BE..."
    ${DORIS_HOME}/be/bin/start_be.sh --daemon
    echo "Doris BE已启动"
elif [ "$1" == "stop" ]; then
    echo "停止Doris BE..."
    ${DORIS_HOME}/be/bin/stop_be.sh
    echo "Doris BE已停止"
elif [ "$1" == "status" ]; then
    ${DORIS_HOME}/be/bin/status_be.sh
else
    echo "用法: doris-be {start|stop|status}"
fi
EOF
    sudo chmod +x /usr/local/bin/doris-be
fi

# 创建Docker启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/doris-docker > /dev/null
#!/bin/bash
# Doris Docker启动脚本

DORIS_DIR="/opt/doris"

if [ ! -d "${DORIS_DIR}" ]; then
    echo "错误: Doris目录不存在: ${DORIS_DIR}"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动Doris Docker..."
    cd ${DORIS_DIR}
    docker-compose up -d
    echo "Doris Docker已启动"
    echo "Web UI: http://localhost:8030"
    echo "Query Port: 9030"
elif [ "$1" == "stop" ]; then
    echo "停止Doris Docker..."
    cd ${DORIS_DIR}
    docker-compose down
    echo "Doris Docker已停止"
elif [ "$1" == "restart" ]; then
    echo "重启Doris Docker..."
    cd ${DORIS_DIR}
    docker-compose restart
    echo "Doris Docker已重启"
elif [ "$1" == "client" ]; then
    echo "连接Doris客户端..."
    docker exec -it doris-fe mysql -h 127.0.0.1 -P 9030 -uroot
elif [ "$1" == "logs" ]; then
    echo "查看Doris日志..."
    docker logs -f doris-fe
else
    echo "用法: doris-docker {start|stop|restart|client|logs}"
fi
EOF
sudo chmod +x /usr/local/bin/doris-docker

# 创建示例SQL脚本
cat << 'EOF' | sudo tee ${DORIS_INSTALL_DIR}/examples/sample_queries.sql > /dev/null
-- Doris示例查询

-- 创建数据库
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

-- 创建聚合模型表
CREATE TABLE IF NOT EXISTS sales (
    id BIGINT,
    product_id INT,
    user_id INT,
    amount DECIMAL(10, 2),
    sale_time DATETIME,
    region VARCHAR(50),
    status TINYINT
) ENGINE=OLAP
AGGREGATE KEY(id, product_id, user_id, sale_time, region, status)
PARTITION BY RANGE(sale_time) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01')),
    PARTITION p202403 VALUES [('2024-03-01'), ('2024-04-01'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 10
PROPERTIES (
    "replication_num" = "1",
    "storage_format" = "V2"
);

-- 插入示例数据
INSERT INTO sales VALUES
    (1, 101, 1001, 1000.50, '2024-01-15 10:30:00', '北京', 1),
    (2, 102, 1002, 1500.75, '2024-01-16 11:45:00', '上海', 1),
    (3, 101, 1003, 800.25, '2024-01-17 14:20:00', '广州', 1),
    (4, 103, 1004, 2000.00, '2024-01-18 09:15:00', '深圳', 1),
    (5, 102, 1005, 1200.50, '2024-02-01 16:30:00', '北京', 1),
    (6, 101, 1006, 950.75, '2024-02-02 13:40:00', '上海', 1),
    (7, 103, 1007, 1800.25, '2024-02-03 10:50:00', '广州', 1),
    (8, 102, 1008, 1450.00, '2024-03-01 15:25:00', '深圳', 1);

-- 查询数据
SELECT * FROM sales;

-- 聚合查询
SELECT 
    region,
    COUNT(DISTINCT user_id) as unique_users,
    SUM(amount) as total_sales,
    AVG(amount) as avg_sales,
    COUNT(*) as order_count
FROM sales
GROUP BY region;

-- 时间序列分析
SELECT 
    DATE_TRUNC('DAY', sale_time) as date,
    COUNT(*) as daily_orders,
    SUM(amount) as daily_sales
FROM sales
GROUP BY date
ORDER BY date;

-- 创建明细模型表
CREATE TABLE IF NOT EXISTS sales_detail (
    id BIGINT,
    order_id BIGINT,
    product_name VARCHAR(100),
    quantity INT,
    price DECIMAL(10, 2),
    total_amount DECIMAL(10, 2),
    sale_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(id, order_id)
PARTITION BY RANGE(sale_time) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 10
PROPERTIES (
    "replication_num" = "1"
);

-- 插入明细数据
INSERT INTO sales_detail VALUES
    (1, 1001, '产品A', 2, 500.25, 1000.50, '2024-01-15 10:30:00'),
    (2, 1002, '产品B', 3, 500.25, 1500.75, '2024-01-16 11:45:00'),
    (3, 1003, '产品A', 1, 800.25, 800.25, '2024-01-17 14:20:00');

-- 创建物化视图
CREATE MATERIALIZED VIEW mv_sales_region AS
SELECT 
    region,
    COUNT(*) as order_count,
    SUM(amount) as total_amount
FROM sales
GROUP BY region;

-- 查询物化视图
SELECT * FROM mv_sales_region;

-- 性能测试
SELECT 
    COUNT(*) as total_rows,
    SUM(amount) as total_sales,
    AVG(amount) as avg_sales
FROM sales
WHERE sale_time >= '2024-01-01' AND sale_time <= '2024-03-31';

-- 查看表结构
SHOW CREATE TABLE sales;

-- 查看分区
SHOW PARTITIONS FROM sales;

-- 查看副本状态
SHOW BACKENDS;
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Apache Doris安装完成 ===${NC}"
echo -e "安装目录: ${DORIS_INSTALL_DIR}"
echo -e "数据目录: ${DORIS_DATA_DIR}"
echo -e "日志目录: ${DORIS_LOG_DIR}"
echo ""
echo "连接方式:"
echo "  Web UI: http://localhost:8030"
echo "  Query Port: localhost:9030"
echo "  默认用户: root"
echo "  默认密码: (空)"
echo ""
echo "使用方式:"
if [[ "$OS" == "darwin" ]]; then
    echo "  启动: doris-docker start"
    echo "  停止: doris-docker stop"
    echo "  客户端: doris-docker client"
    echo "  日志: doris-docker logs"
else
    echo "  启动FE: doris-fe start"
    echo "  启动BE: doris-be start"
    echo "  停止FE: doris-fe stop"
    echo "  停止BE: doris-be stop"
fi
echo ""
echo "连接Doris:"
echo "  MySQL客户端: mysql -h 127.0.0.1 -P 9030 -uroot"
echo "  执行SQL: mysql -h 127.0.0.1 -P 9030 -uroot -e 'SELECT 1'"
echo ""
echo "示例查询:"
echo "  执行文件: mysql -h 127.0.0.1 -P 9030 -uroot < ${DORIS_INSTALL_DIR}/examples/sample_queries.sql"
echo ""
echo "添加BE节点:"
echo "  ALTER SYSTEM ADD BACKEND \"127.0.0.1:9050\";"
echo ""
echo "卸载:"
if [[ "$OS" == "darwin" ]]; then
    echo "  Docker: cd ${DORIS_INSTALL_DIR} && docker-compose down"
    echo "  删除: sudo rm -rf ${DORIS_INSTALL_DIR} /usr/local/bin/doris-docker"
else
    echo "  停止: doris-fe stop && doris-be stop"
    echo "  删除: sudo rm -rf ${DORIS_INSTALL_DIR} ${DORIS_DATA_DIR} ${DORIS_LOG_DIR} /usr/local/bin/doris-*"
fi
echo ""
echo -e "${YELLOW}提示: Doris需要足够的内存（建议8GB+）和磁盘空间${NC}"
echo -e "${YELLOW}建议: 生产环境配置多个FE和BE节点实现高可用${NC}"
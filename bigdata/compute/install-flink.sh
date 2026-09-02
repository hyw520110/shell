#!/bin/bash
# Apache Flink - 实时流计算引擎
# 功能：实时流处理、批处理、复杂事件处理、状态管理
# 官方文档：https://flink.apache.org/
# GitHub: https://github.com/apache/flink

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
FLINK_VERSION="1.18.0"
FLINK_SCALA_VERSION="2.12"
FLINK_INSTALL_DIR="/opt/flink"
FLINK_URL="https://downloads.apache.org/flink/flink-${FLINK_VERSION}/flink-${FLINK_VERSION}-bin-scala_${FLINK_SCALA_VERSION}.tgz"

echo -e "${GREEN}=== Apache Flink 实时流计算引擎 安装脚本 ===${NC}"

# 检查Java环境
if ! command -v java &> /dev/null; then
    echo -e "${RED}错误: 未找到Java环境，请先安装Java 11+${NC}"
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
sudo mkdir -p ${FLINK_INSTALL_DIR}

# 下载Flink
TEMP_DIR="/tmp/flink"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [ ! -f "flink-${FLINK_VERSION}-bin-scala_${FLINK_SCALA_VERSION}.tgz" ]; then
    echo -e "${YELLOW}下载Apache Flink ${FLINK_VERSION}...${NC}"
    curl -fsSL -o "flink-${FLINK_VERSION}-bin-scala_${FLINK_SCALA_VERSION}.tgz" ${FLINK_URL}
fi

# 解压
if [ -d "${FLINK_INSTALL_DIR}/flink-${FLINK_VERSION}" ]; then
    echo -e "${YELLOW}Flink已安装，删除旧版本...${NC}"
    sudo rm -rf "${FLINK_INSTALL_DIR}/flink-${FLINK_VERSION}"
fi

echo -e "${YELLOW}解压到 ${FLINK_INSTALL_DIR}...${NC}"
sudo tar -xzf "flink-${FLINK_VERSION}-bin-scala_${FLINK_SCALA_VERSION}.tgz" -C ${FLINK_INSTALL_DIR}

# 创建软链接
sudo ln -sf ${FLINK_INSTALL_DIR}/flink-${FLINK_VERSION} ${FLINK_INSTALL_DIR}/current

# 配置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/flink.sh > /dev/null
# Apache Flink环境变量
export FLINK_HOME=/opt/flink/current
export PATH=\$PATH:\$FLINK_HOME/bin
EOF

source /etc/profile.d/flink.sh

# 创建配置文件
FLINK_CONF="${FLINK_INSTALL_DIR}/current/conf"

# flink-conf.yaml
cat << 'EOF' | sudo tee ${FLINK_CONF}/flink-conf.yaml > /dev/null
# Flink配置文件

# 基础配置
jobmanager.rpc.address: localhost
jobmanager.rpc.port: 6123
jobmanager.memory.process.size: 1600m
taskmanager.memory.process.size: 1728m
taskmanager.numberOfTaskSlots: 1

# 并行度
parallelism.default: 1

# 检查点
state.backend: filesystem
state.checkpoints.dir: file:///tmp/flink-checkpoints
state.savepoints.dir: file:///tmp/flink-savepoints

# Web UI
rest.address: localhost
rest.port: 8081

# 高可用
# high-availability: zookeeper
# high-availability.zookeeper.quorum: localhost:2181
# high-availability.storageDir: hdfs:///flink/ha/

# 时间特性
# time-characteristic: event-time

# 容错
# restart-strategy: fixed-delay
# restart-strategy.fixed-delay.attempts: 3
# restart-strategy.fixed-delay.delay: 10 s
EOF

# slaves配置（单机模式）
cat << 'EOF' | sudo tee ${FLINK_CONF}/workers > /dev/null
localhost
EOF

# masters配置
cat << 'EOF' | sudo tee ${FLINK_CONF}/masters > /dev/null
localhost:8081
EOF

# 创建日志和检查点目录
sudo mkdir -p /tmp/flink-checkpoints /tmp/flink-savepoints /tmp/flink-logs
sudo chmod 777 /tmp/flink-checkpoints /tmp/flink-savepoints /tmp/flink-logs

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/flink-start > /dev/null
#!/bin/bash
# Flink启动脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    echo "请运行: install-flink.sh"
    exit 1
fi

if [ "$1" == "cluster" ]; then
    echo "启动Flink集群..."
    ${FLINK_HOME}/bin/start-cluster.sh
    echo "Flink集群已启动"
    echo "Web UI: http://localhost:8081"
elif [ "$1" == "standalone" ]; then
    echo "启动Flink Standalone..."
    ${FLINK_HOME}/bin/standalone-job.sh
else
    echo "用法: flink-start {cluster|standalone}"
fi
EOF

sudo chmod +x /usr/local/bin/flink-start

cat << 'EOF' | sudo tee /usr/local/bin/flink-stop > /dev/null
#!/bin/bash
# Flink停止脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    exit 1
fi

echo "停止Flink集群..."
${FLINK_HOME}/bin/stop-cluster.sh
echo "Flink集群已停止"
EOF

sudo chmod +x /usr/local/bin/flink-stop

cat << 'EOF' | sudo tee /usr/local/bin/flink-submit > /dev/null
#!/bin/bash
# Flink提交脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    echo "请运行: install-flink.sh"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "用法: flink-submit [选项] <应用程序> [应用参数]"
    echo ""
    echo "常用选项:"
    echo "  --class CLASS           主类 (Java/Scala应用)"
    echo "  --parallelism NUM       并行度"
    echo "  --detached              后台运行"
    echo "  --savepointPath PATH    保存点路径"
    echo "  --fromSavepoint PATH    从保存点恢复"
    echo ""
    echo "示例:"
    echo "  flink-submit --class com.example.MyJob myjob.jar"
    echo "  flink-submit --parallelism 4 myjob.jar"
    exit 1
fi

${FLINK_HOME}/bin/flink run "$@"
EOF

sudo chmod +x /usr/local/bin/flink-submit

cat << 'EOF' | sudo tee /usr/local/bin/flink-run > /dev/null
#!/bin/bash
# Flink快速运行脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    exit 1
fi

if [ -z "$1" ]; then
    echo "用法: flink-run <应用程序>"
    exit 1
fi

${FLINK_HOME}/bin/flink run "$@"
EOF

sudo chmod +x /usr/local/bin/flink-run

cat << 'EOF' | sudo tee /usr/local/bin/flink-list > /dev/null
#!/bin/bash
# Flink作业列表脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    exit 1
fi

${FLINK_HOME}/bin/flink list
EOF

sudo chmod +x /usr/local/bin/flink-list

cat << 'EOF' | sudo tee /usr/local/bin/flink-cancel > /dev/null
#!/bin/bash
# Flink取消作业脚本

FLINK_HOME=/opt/flink/current

if [ ! -d "${FLINK_HOME}" ]; then
    echo "错误: Flink未安装"
    exit 1
fi

if [ -z "$1" ]; then
    echo "用法: flink-cancel <job-id>"
    exit 1
fi

${FLINK_HOME}/bin/flink cancel "$@"
EOF

sudo chmod +x /usr/local/bin/flink-cancel

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${FLINK_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  jobmanager:
    image: flink:1.18.0
    container_name: flink-jobmanager
    ports:
      - "8081:8081"
    command: jobmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address=jobmanager
        taskmanager.numberOfTaskSlots=2
    volumes:
      - ./flink-data:/opt/flink/data
    restart: unless-stopped

  taskmanager:
    image: flink:1.18.0
    container_name: flink-taskmanager
    depends_on:
      - jobmanager
    command: taskmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address=jobmanager
        taskmanager.numberOfTaskSlots=2
    volumes:
      - ./flink-data:/opt/flink/data
    restart: unless-stopped
EOF

# 创建示例Java应用
cat << 'EOF' | sudo tee ${FLINK_INSTALL_DIR}/examples/WordCount.java > /dev/null
import org.apache.flink.api.common.functions.FlatMapFunction;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.util.Collector;

public class WordCount {
    public static void main(String[] args) throws Exception {
        // 创建执行环境
        final StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // 示例数据
        DataStream<String> text = env.fromElements(
            "Apache Flink is a framework and distributed processing engine",
            "for stateful computations over unbounded and bounded data streams",
            "Flink has been designed to run in all common cluster environments"
        );

        // WordCount
        DataStream<Tuple2<String, Integer>> counts = text
            .flatMap(new Tokenizer())
            .keyBy(0)
            .sum(1);

        // 输出结果
        counts.print();

        // 执行作业
        env.execute("WordCount");
    }

    public static final class Tokenizer implements FlatMapFunction<String, Tuple2<String, Integer>> {
        @Override
        public void flatMap(String value, Collector<Tuple2<String, Integer>> out) {
            String[] words = value.toLowerCase().split("\\s+");
            for (String word : words) {
                if (word.length() > 0) {
                    out.collect(new Tuple2<>(word, 1));
                }
            }
        }
    }
}
EOF

# 创建示例Python应用
cat << 'EOF' | sudo tee ${FLINK_INSTALL_DIR}/examples/wordcount.py > /dev/null
#!/usr/bin/env python3
# Flink WordCount示例

from pyflink.datastream import StreamExecutionEnvironment
from pyflink.table import StreamTableEnvironment

# 创建执行环境
env = StreamExecutionEnvironment.get_execution_environment()
t_env = StreamTableEnvironment.create(env)

# 创建临时表
t_env.execute_sql("""
    CREATE TABLE word_count (
        word STRING,
        count BIGINT
    ) WITH (
        'connector' = 'print'
    )
""")

# 示例数据
data = [("hello", 1), ("world", 1), ("hello", 1), ("flink", 1)]

# 创建DataStream并注册为表
ds = env.from_collection(data)
t_env.create_temporary_view("source_table", ds)

# 执行查询并输出
t_env.execute_sql("""
    INSERT INTO word_count
    SELECT word, SUM(count) as count
    FROM source_table
    GROUP BY word
""").wait()
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Apache Flink安装完成 ===${NC}"
echo -e "安装目录: ${FLINK_INSTALL_DIR}/current"
echo -e "配置文件: ${FLINK_CONF}"
echo -e "检查点目录: /tmp/flink-checkpoints"
echo ""
echo "常用命令:"
echo "  启动集群: flink-start cluster"
echo "  停止集群: flink-stop"
echo "  提交作业: flink-submit <app>"
echo "  列出作业: flink-list"
echo "  取消作业: flink-cancel <job-id>"
echo ""
echo "Web UI:"
echo "  本地模式: http://localhost:8081"
echo ""
echo "Docker部署:"
echo "  cd ${FLINK_INSTALL_DIR}"
echo "  docker-compose up -d"
echo "  访问: http://localhost:8081"
echo ""
echo "卸载: sudo rm -rf ${FLINK_INSTALL_DIR} /usr/local/bin/flink-* /etc/profile.d/flink.sh"
echo ""
echo -e "${YELLOW}提示: Flink需要Java 11+环境${NC}"
echo -e "${YELLOW}建议: 根据实际需求调整TaskManager内存和Slot数量${NC}"
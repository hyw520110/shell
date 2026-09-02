#!/bin/bash
# Apache Hadoop - 分布式计算框架
# 功能：HDFS分布式文件系统、YARN资源管理、MapReduce计算
# 官方文档：https://hadoop.apache.org/
# GitHub: https://github.com/apache/hadoop

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
HADOOP_VERSION="3.3.6"
HADOOP_INSTALL_DIR="/opt/hadoop"
HADOOP_DATA_DIR="/data/hadoop"
HADOOP_CONF_DIR="${HADOOP_INSTALL_DIR}/etc/hadoop"
HADOOP_USER="hadoop"
HADOOP_NAMENODE_PORT="9000"
HADOOP_SECONDARY_NAMENODE_PORT="9001"
HADOOP_DATANODE_PORT="9866"
HADOOP_YARN_RM_PORT="8032"
HADOOP_YARN_NM_PORT="8042"
HADOOP_YARN_RM_WEB_PORT="8088"
HADOOP_YARN_NM_WEB_PORT="8042"

echo -e "${GREEN}=== Apache Hadoop ${HADOOP_VERSION} 安装脚本 ===${NC}"

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

# 检查SSH（Hadoop需要SSH免密登录）
if ! command -v ssh &> /dev/null; then
    echo -e "${YELLOW}警告: 未找到SSH，Hadoop需要SSH支持${NC}"
    echo -e "${YELLOW}单机模式可以不需要SSH，集群模式必须配置SSH免密登录${NC}"
fi

# 创建Hadoop用户
if ! id -u ${HADOOP_USER} > /dev/null 2>&1; then
    echo -e "${YELLOW}创建Hadoop用户: ${HADOOP_USER}${NC}"
    sudo useradd -m -s /bin/bash ${HADOOP_USER}
    echo -e "${YELLOW}设置Hadoop用户密码${NC}"
    sudo passwd ${HADOOP_USER}
else
    echo -e "${YELLOW}Hadoop用户已存在: ${HADOOP_USER}${NC}"
fi

# 创建安装和数据目录
sudo mkdir -p ${HADOOP_INSTALL_DIR}
sudo mkdir -p ${HADOOP_DATA_DIR}/{namenode,datanode,logs,tmp,journal}
sudo chown -R ${HADOOP_USER}:${HADOOP_USER} ${HADOOP_INSTALL_DIR} ${HADOOP_DATA_DIR}

# 下载Hadoop
TEMP_DIR="/tmp/hadoop"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

if [ ! -f "hadoop-${HADOOP_VERSION}.tar.gz" ]; then
    echo -e "${YELLOW}下载Hadoop ${HADOOP_VERSION}...${NC}"
    APACHE_MIRROR="https://downloads.apache.org/hadoop/common"
    curl -fsSL -o "hadoop-${HADOOP_VERSION}.tar.gz" ${APACHE_MIRROR}/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz
fi

# 解压
if [ -d "${HADOOP_INSTALL_DIR}/hadoop-${HADOOP_VERSION}" ]; then
    echo -e "${YELLOW}Hadoop已安装，删除旧版本...${NC}"
    sudo rm -rf "${HADOOP_INSTALL_DIR}/hadoop-${HADOOP_VERSION}"
fi

echo -e "${YELLOW}解压到 ${HADOOP_INSTALL_DIR}...${NC}"
sudo tar -xzf "hadoop-${HADOOP_VERSION}.tar.gz" -C ${HADOOP_INSTALL_DIR}

# 创建软链接
sudo ln -sf ${HADOOP_INSTALL_DIR}/hadoop-${HADOOP_VERSION} ${HADOOP_INSTALL_DIR}/current
sudo chown -R ${HADOOP_USER}:${HADOOP_USER} ${HADOOP_INSTALL_DIR}

# 配置环境变量
cat << EOF | sudo tee /etc/profile.d/hadoop.sh > /dev/null
# Hadoop环境变量
export HADOOP_HOME=/opt/hadoop/current
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_HOME/lib/native
export HADOOP_OPTS="-Djava.library.path=\$HADOOP_HOME/lib/native"
export YARN_HOME=\$HADOOP_HOME
export YARN_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
EOF

source /etc/profile.d/hadoop.sh

# 配置hadoop-env.sh
cat << EOF | sudo tee ${HADOOP_CONF_DIR}/hadoop-env.sh > /dev/null
# Hadoop环境变量配置

export JAVA_HOME=${JAVA_HOME}
export HADOOP_HOME=${HADOOP_INSTALL_DIR}/current
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop

# JVM配置
export HADOOP_HEAPSIZE_MAX=2048
export HADOOP_NAMENODE_OPTS="-Xmx2048m -Dhadoop.security.logger=INFO,DRFAS"
export HADOOP_DATANODE_OPTS="-Xmx1024m -Dhadoop.security.logger=ERROR,DRFAS"
export HADOOP_SECONDARYNAMENODE_OPTS="-Xmx1536m"

# 其他配置
export HADOOP_PID_DIR=/data/hadoop/tmp
export HADOOP_LOG_DIR=/data/hadoop/logs
export YARN_RESOURCEMANAGER_OPTS="-Xmx2048m"
export YARN_NODEMANAGER_OPTS="-Xmx1024m"
EOF

# 配置core-site.xml
cat << EOF | sudo tee ${HADOOP_CONF_DIR}/core-site.xml > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <!-- HDFS文件系统地址 -->
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:${HADOOP_NAMENODE_PORT}</value>
    </property>
    
    <!-- Hadoop临时目录 -->
    <property>
        <name>hadoop.tmp.dir</name>
        <value>${HADOOP_DATA_DIR}/tmp</value>
    </property>
    
    <!-- 垃圾回收策略 -->
    <property>
        <name>fs.trash.interval</name>
        <value>1440</value>
    </property>
    
    <!-- 压缩配置 -->
    <property>
        <name>io.compression.codecs</name>
        <value>org.apache.hadoop.io.compress.GzipCodec,org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.BZip2Codec,org.apache.hadoop.io.compress.SnappyCodec</value>
    </property>
    
    <!-- 缓冲区大小 -->
    <property>
        <name>io.file.buffer.size</name>
        <value>131072</value>
    </property>
</configuration>
EOF

# 配置hdfs-site.xml
cat << EOF | sudo tee ${HADOOP_CONF_DIR}/hdfs-site.xml > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <!-- 副本数量 -->
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
    
    <!-- NameNode数据目录 -->
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>${HADOOP_DATA_DIR}/namenode</value>
    </property>
    
    <!-- DataNode数据目录 -->
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>${HADOOP_DATA_DIR}/datanode</value>
    </property>
    
    <!-- Secondary NameNode配置 -->
    <property>
        <name>dfs.namenode.secondary.http-address</name>
        <value>localhost:${HADOOP_SECONDARY_NAMENODE_PORT}</value>
    </property>
    
    <!-- Web UI端口 -->
    <property>
        <name>dfs.namenode.http-address</name>
        <value>0.0.0.0:9870</value>
    </property>
    
    <property>
        <name>dfs.namenode.https-address</name>
        <value>0.0.0.0:9871</value>
    </property>
    
    <!-- DataNode端口 -->
    <property>
        <name>dfs.datanode.address</name>
        <value>0.0.0.0:${HADOOP_DATANODE_PORT}</value>
    </property>
    
    <property>
        <name>dfs.datanode.http.address</name>
        <value>0.0.0.0:9864</value>
    </property>
    
    <!-- 权限检查（单机模式关闭） -->
    <property>
        <name>dfs.permissions.enabled</name>
        <value>false</value>
    </property>
    
    <!-- 副本放置策略 -->
    <property>
        <name>dfs.namenode.replication.considerLoad</name>
        <value>false</value>
    </property>
</configuration>
EOF

# 配置yarn-site.xml
cat << EOF | sudo tee ${HADOOP_CONF_DIR}/yarn-site.xml > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <!-- NodeManager运行的服务 -->
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    
    <!-- ResourceManager地址 -->
    <property>
        <name>yarn.resourcemanager.address</name>
        <value>localhost:${HADOOP_YARN_RM_PORT}</value>
    </property>
    
    <!-- ResourceManager Web UI -->
    <property>
        <name>yarn.resourcemanager.webapp.address</name>
        <value>0.0.0.0:${HADOOP_YARN_RM_WEB_PORT}</value>
    </property>
    
    <!-- NodeManager资源 -->
    <property>
        <name>yarn.nodemanager.resource.memory-mb</name>
        <value>4096</value>
    </property>
    
    <property>
        <name>yarn.nodemanager.resource.cpu-vcores</name>
        <value>4</value>
    </property>
    
    <!-- 内存分配配置 -->
    <property>
        <name>yarn.scheduler.minimum-allocation-mb</name>
        <value>512</value>
    </property>
    
    <property>
        <name>yarn.scheduler.maximum-allocation-mb</name>
        <value>4096</value>
    </property>
    
    <!-- 日志聚合 -->
    <property>
        <name>yarn.log-aggregation-enable</name>
        <value>true</value>
    </property>
    
    <property>
        <name>yarn.log.server.url</name>
        <value>http://localhost:19888/jobhistory/logs</value>
    </property>
    
    <!-- NodeManager环境 -->
    <property>
        <name>yarn.nodemanager.env-whitelist</name>
        <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME</value>
    </property>
</configuration>
EOF

# 配置mapred-site.xml
cat << EOF | sudo tee ${HADOOP_CONF_DIR}/mapred-site.xml > /dev/null
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <!-- 使用YARN运行MapReduce -->
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
    
    <!-- JobHistory地址 -->
    <property>
        <name>mapreduce.jobhistory.address</name>
        <value>localhost:10020</value>
    </property>
    
    <property>
        <name>mapreduce.jobhistory.webapp.address</name>
        <value>localhost:19888</value>
    </property>
    
    <!-- 内存配置 -->
    <property>
        <name>mapreduce.map.memory.mb</name>
        <value>1024</value>
    </property>
    
    <property>
        <name>mapreduce.reduce.memory.mb</name>
        <value>2048</value>
    </property>
    
    <!-- JVM参数 -->
    <property>
        <name>mapreduce.map.java.opts</name>
        <value>-Xmx819m</value>
    </property>
    
    <property>
        <name>mapreduce.reduce.java.opts</name>
        <value>-Xmx1638m</value>
    </property>
    
    <!-- 压缩配置 -->
    <property>
        <name>mapreduce.map.output.compress</name>
        <value>true</value>
    </property>
    
    <property>
        <name>mapreduce.map.output.compress.codec</name>
        <value>org.apache.hadoop.io.compress.SnappyCodec</value>
    </property>
</configuration>
EOF

# 配置workers
echo "localhost" | sudo tee ${HADOOP_CONF_DIR}/workers > /dev/null

# 配置SSH（如果需要）
if [ -d "${HOME}/.ssh" ]; then
    echo -e "${YELLOW}配置SSH免密登录...${NC}"
    if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
        ssh-keygen -t rsa -P "" -f ${HOME}/.ssh/id_rsa
    fi
    cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
    chmod 600 ${HOME}/.ssh/authorized_keys
fi

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/hadoop-ctl > /dev/null
#!/bin/bash
# Hadoop控制脚本

HADOOP_HOME=/opt/hadoop/current
ACTION=$1

case "$ACTION" in
    start)
        echo "启动Hadoop集群..."
        
        # 格式化NameNode（仅首次）
        if [ ! -d "/data/hadoop/namenode/current" ]; then
            echo "格式化NameNode..."
            $HADOOP_HOME/bin/hdfs namenode -format
        fi
        
        # 启动HDFS
        echo "启动HDFS..."
        $HADOOP_HOME/sbin/start-dfs.sh
        
        # 启动YARN
        echo "启动YARN..."
        $HADOOP_HOME/sbin/start-yarn.sh
        
        # 启动JobHistory
        echo "启动JobHistory..."
        $HADOOP_HOME/sbin/mr-jobhistory-daemon.sh start historyserver
        
        echo "Hadoop集群已启动"
        echo ""
        echo "Web界面:"
        echo "  HDFS: http://localhost:9870"
        echo "  YARN: http://localhost:8088"
        echo "  JobHistory: http://localhost:19888"
        ;;
    
    stop)
        echo "停止Hadoop集群..."
        $HADOOP_HOME/sbin/stop-yarn.sh
        $HADOOP_HOME/sbin/stop-dfs.sh
        $HADOOP_HOME/sbin/mr-jobhistory-daemon.sh stop historyserver
        echo "Hadoop集群已停止"
        ;;
    
    restart)
        echo "重启Hadoop集群..."
        $0 stop
        sleep 5
        $0 start
        ;;
    
    status)
        echo "Hadoop进程状态:"
        jps | grep -E "(NameNode|DataNode|SecondaryNameNode|ResourceManager|NodeManager|JobHistoryServer)"
        ;;
    
    format)
        echo "格式化NameNode..."
        read -p "警告: 这将删除所有HDFS数据，确认吗? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            $HADOOP_HOME/bin/hdfs namenode -format
        else
            echo "已取消"
        fi
        ;;
    
    *)
        echo "用法: hadoop-ctl {start|stop|restart|status|format}"
        exit 1
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/hadoop-ctl

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${HADOOP_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  namenode:
    image: apache/hadoop:3.3.6
    container_name: hadoop-namenode
    hostname: namenode
    environment:
      - CLUSTER_NAME=hadoop
      - CORE_CONF_fs_defaultFS=hdfs://namenode:9000
      - HDFS_CONF_dfs_replication=1
    ports:
      - "9000:9000"
      - "9870:9870"
    volumes:
      - ./hadoop-data/namenode:/hadoop/dfs/name
      - ./hadoop-data/logs:/hadoop/logs
    restart: unless-stopped

  datanode:
    image: apache/hadoop:3.3.6
    container_name: hadoop-datanode
    hostname: datanode
    environment:
      - CLUSTER_NAME=hadoop
      - CORE_CONF_fs_defaultFS=hdfs://namenode:9000
      - HDFS_CONF_dfs_replication=1
      - HDFS_CONF_dfs_datanode_address=0.0.0.0:9866
    ports:
      - "9866:9866"
      - "9864:9864"
    volumes:
      - ./hadoop-data/datanode:/hadoop/dfs/data
      - ./hadoop-data/logs:/hadoop/logs
    depends_on:
      - namenode
    restart: unless-stopped

  resourcemanager:
    image: apache/hadoop:3.3.6
    container_name: hadoop-resourcemanager
    hostname: resourcemanager
    environment:
      - CLUSTER_NAME=hadoop
      - CORE_CONF_fs_defaultFS=hdfs://namenode:9000
      - YARN_CONF_yarn_resourcemanager_hostname=resourcemanager
      - YARN_CONF_yarn_nodemanager_aux_services=mapreduce_shuffle
    ports:
      - "8088:8088"
      - "8032:8032"
    depends_on:
      - namenode
    restart: unless-stopped

  nodemanager:
    image: apache/hadoop:3.3.6
    container_name: hadoop-nodemanager
    hostname: nodemanager
    environment:
      - CLUSTER_NAME=hadoop
      - CORE_CONF_fs_defaultFS=hdfs://namenode:9000
      - YARN_CONF_yarn_resourcemanager_hostname=resourcemanager
      - YARN_CONF_yarn_nodemanager_aux_services=mapreduce_shuffle
    ports:
      - "8042:8042"
    depends_on:
      - resourcemanager
    restart: unless-stopped
EOF

# 创建示例脚本
cat << 'EOF' | sudo tee ${HADOOP_INSTALL_DIR}/examples/hdfs-operations.sh > /dev/null
#!/bin/bash
# HDFS操作示例

echo "=== HDFS基本操作 ==="

# 创建目录
echo "创建目录 /user/hadoop/example"
hdfs dfs -mkdir -p /user/hadoop/example

# 上传文件
echo "上传文件到HDFS"
# hdfs dfs -put /local/file.txt /user/hadoop/example/

# 查看文件
echo "查看HDFS文件列表"
hdfs dfs -ls /user/hadoop/example

# 下载文件
echo "从HDFS下载文件"
# hdfs dfs -get /user/hadoop/example/file.txt /local/

# 删除文件
echo "删除HDFS文件"
# hdfs dfs -rm /user/hadoop/example/file.txt

# 查看文件内容
echo "查看HDFS文件内容"
# hdfs dfs -cat /user/hadoop/example/file.txt

# 设置副本数
echo "设置文件副本数为2"
# hdfs dfs -setrep 2 /user/hadoop/example/file.txt

# 查看文件统计信息
echo "查看HDFS统计信息"
hdfs dfs -du -h /user/hadoop/example

# 查看目录大小
echo "查看目录大小"
hdfs dfs -du -s -h /user/hadoop/example

echo "=== HDFS管理命令 ==="

# 查看HDFS状态
echo "查看HDFS状态"
hdfs dfsadmin -report

# 查看安全模式
echo "查看安全模式"
hdfs dfsadmin -safemode get

# 退出安全模式
# hdfs dfsadmin -safemode leave

# 查看HDFS配额
echo "查看HDFS配额"
hdfs dfsadmin -report

# 查看块信息
echo "查看块信息"
hdfs fsck /user/hadoop/example -files -blocks -locations
EOF

# 创建MapReduce示例
cat << 'EOF' | sudo tee ${HADOOP_INSTALL_DIR}/examples/wordcount.sh > /dev/null
#!/bin/bash
# MapReduce WordCount示例

HADOOP_HOME=/opt/hadoop/current

# 创建输入文件
echo "创建测试文件"
echo "Hello Hadoop Hello World Hello MapReduce Hello YARN" > /tmp/input.txt
echo "Spark Flink Hive HBase Zookeeper Kafka" >> /tmp/input.txt

# 上传到HDFS
echo "上传文件到HDFS"
hdfs dfs -mkdir -p /user/hadoop/wordcount/input
hdfs dfs -put /tmp/input.txt /user/hadoop/wordcount/input/

# 运行WordCount
echo "运行WordCount MapReduce作业"
$HADOOP_HOME/bin/hadoop jar \
    $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar \
    wordcount \
    /user/hadoop/wordcount/input \
    /user/hadoop/wordcount/output

# 查看结果
echo "查看结果"
hdfs dfs -cat /user/hadoop/wordcount/output/part-r-00000

# 清理
# hdfs dfs -rm -r /user/hadoop/wordcount
EOF

# 清理临时文件
rm -rf ${TEMP_DIR}

# 显示安装信息
echo -e "${GREEN}=== Hadoop安装完成 ===${NC}"
echo -e "安装目录: ${HADOOP_INSTALL_DIR}"
echo -e "数据目录: ${HADOOP_DATA_DIR}"
echo -e "配置目录: ${HADOOP_CONF_DIR}"
echo -e "Hadoop用户: ${HADOOP_USER}"
echo ""
echo "服务端口:"
echo "  HDFS NameNode: 9000"
echo "  HDFS Web UI: 9870"
echo "  HDFS Secondary NN: 9001"
echo "  YARN ResourceManager: 8032"
echo "  YARN Web UI: 8088"
echo "  DataNode: 9866"
echo "  NodeManager: 8042"
echo "  JobHistory: 19888"
echo ""
echo "启动方式:"
echo "  启动: hadoop-ctl start"
echo "  停止: hadoop-ctl stop"
echo "  重启: hadoop-ctl restart"
echo "  状态: hadoop-ctl status"
echo "  格式化: hadoop-ctl format"
echo ""
echo "HDFS命令:"
echo "  查看文件: hdfs dfs -ls /"
echo "  上传文件: hdfs dfs -put localfile /hdfs/path"
echo "  下载文件: hdfs dfs -get /hdfs/path localfile"
echo "  删除文件: hdfs dfs -rm /hdfs/path"
echo "  查看内容: hdfs dfs -cat /hdfs/path"
echo ""
echo "YARN命令:"
echo "  查看作业: yarn application -list"
echo "  查看日志: yarn logs -applicationId app_id"
echo "  杀死作业: yarn application -kill app_id"
echo ""
echo "Web界面:"
echo "  HDFS: http://localhost:9870"
echo "  YARN: http://localhost:8088"
echo "  JobHistory: http://localhost:19888"
echo ""
echo "Docker部署:"
echo "  cd ${HADOOP_INSTALL_DIR}"
echo "  docker-compose up -d"
echo ""
echo "示例脚本:"
echo "  HDFS操作: bash ${HADOOP_INSTALL_DIR}/examples/hdfs-operations.sh"
echo "  WordCount: bash ${HADOOP_INSTALL_DIR}/examples/wordcount.sh"
echo ""
echo "集成组件:"
echo "  Hive: 依赖HDFS存储数据"
echo "  Spark: 可运行在YARN上"
echo "  Flink: 可运行在YARN上"
echo "  HBase: 依赖HDFS存储"
echo ""
echo "卸载:"
echo "  停止: hadoop-ctl stop"
echo "  删除: sudo rm -rf ${HADOOP_INSTALL_DIR} ${HADOOP_DATA_DIR} /usr/local/bin/hadoop-ctl /etc/profile.d/hadoop.sh"
echo "  删除用户: sudo userdel -r ${HADOOP_USER}"
echo ""
echo -e "${YELLOW}注意: 首次启动会自动格式化NameNode${NC}"
echo -e "${YELLOW}建议: 生产环境使用HA（高可用）集群配置${NC}"
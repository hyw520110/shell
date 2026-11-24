#!/bin/bash
# 大数据、数仓和人工智能工具总览脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}"
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║          大数据、数仓和人工智能工具安装指南                  ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# 统计脚本数量
TOTAL_SCRIPTS=$(find /Users/mac/workspace/shell/bigdata -name "install-*.sh" 2>/dev/null | wc -l)

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第一优先级（大数据核心）- 已完成${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
✅ 1. Apache Spark - 通用大数据计算引擎
   用途: 批处理、流处理、SQL查询、机器学习、图计算
   适用: 大数据处理、数据分析、机器学习
   安装: ./compute/install-spark.sh
   官方: https://spark.apache.org/

✅ 2. Apache Flink - 实时流计算引擎
   用途: 实时流处理、批处理、复杂事件处理
   适用: 实时数据分析、流式ETL
   安装: ./compute/install-flink.sh
   官方: https://flink.apache.org/

✅ 3. Apache Hive - 传统数仓工具
   用途: 数据仓库、SQL查询、数据ETL
   适用: 离线数仓、批处理ETL
   安装: ./warehouse/install-hive.sh
   官方: https://hive.apache.org/

✅ 4. Apache Airflow - 工作流调度平台
   用途: 数据管道编排、工作流调度、ETL自动化
   适用: 数据调度、工作流管理
   安装: ./orchestration/install-airflow.sh
   官方: https://airflow.apache.org/

✅ 5. ClickHouse - OLAP分析数据库
   用途: 实时OLAP分析、高性能列式存储
   适用: 实时分析、BI报表
   安装: ./warehouse/install-clickhouse.sh
   官方: https://clickhouse.com/
EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第二优先级（现代数仓）- 待开发${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
✅ 6. Apache Doris - 实时分析数据库
   用途: 实时OLAP、极速查询、高并发
   适用: 实时数仓、BI分析
   安装: ./warehouse/install-doris.sh
   官方: https://doris.apache.org/

⏳ 7. Apache Presto/Trino - 分布式SQL查询引擎
   用途: 跨数据源查询、联邦查询
   适用: 数据湖查询、多源数据分析
   目录: ./query/install-presto.sh

⏳ 8. Apache Hudi - 数据湖表格式
   用途: 数据湖、ACID事务、增量处理
   适用: 数据湖、流批一体
   目录: ./datalake/install-hudi.sh

⏳ 9. Apache Superset - BI可视化工具
   用途: 数据可视化、BI报表、仪表板
   适用: 数据分析、BI展示
   目录: ./bi/install-superset.sh

⏳ 10. Apache Kafka - 分布式消息系统（已有）
   用途: 分布式流处理、日志收集
   适用: 大数据流处理、消息队列
   目录: ../mq/kafka/
EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}第三优先级（AI/ML）- 待开发${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
⏳ 11. JupyterHub - 多用户Jupyter环境
   用途: AI开发、数据科学、交互式分析
   适用: AI/ML开发、数据科学
   目录: ./ai-ml/install-jupyterhub.sh

✅ 12. MLflow - ML实验跟踪
   用途: ML实验管理、模型跟踪、部署
   适用: 机器学习、模型管理
   安装: ./ai-ml/install-mlflow.sh
   官方: https://mlflow.org/

⏳ 13. Dask - Python并行计算框架
   用途: 并行计算、分布式计算
   适用: Python数据分析、科学计算
   目录: ./ai-ml/install-dask.sh
EOF

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}已完成的安装脚本${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
✅ compute/install-spark.sh - Apache Spark
✅ compute/install-flink.sh - Apache Flink
✅ warehouse/install-hive.sh - Apache Hive
✅ orchestration/install-airflow.sh - Apache Airflow
✅ warehouse/install-clickhouse.sh - ClickHouse
✅ warehouse/install-doris.sh - Apache Doris
✅ ai-ml/install-mlflow.sh - MLflow

总计: 7个完成 / 13个计划
EOF

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}快速安装指南${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
# 安装所有第一优先级工具
cd /Users/mac/workspace/shell/bigdata

# 计算引擎
./compute/install-spark.sh
./compute/install-flink.sh

# 数仓工具
./warehouse/install-hive.sh
./warehouse/install-clickhouse.sh

# 数据编排
./orchestration/install-airflow.sh
EOF

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}典型架构示例${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
数据源 → Kafka → Flink → ClickHouse/Doris → Superset
                 ↓
              Spark → Hive → Airflow
EOF

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}注意事项${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

cat << 'EOF'
1. Spark/Flink需要Java 8+环境
2. Hive需要MySQL/PostgreSQL作为元数据库
3. Airflow需要Python 3.8+环境
4. ClickHouse建议使用Docker部署
5. Doris需要足够的内存（建议8GB+）
6. MLflow需要Python 3.7+环境
7. 根据实际需求调整内存和资源配置
8. 生产环境建议配置ZooKeeper集群
9. 定期备份数据和配置文件
EOF

echo ""
echo -e "${BLUE}已完成脚本数量: ${TOTAL_SCRIPTS} 个${NC}"
echo -e "${BLUE}进度: 7/13 (53.8%)${NC}"
echo ""
echo -e "${YELLOW}继续开发剩余工具...${NC}"
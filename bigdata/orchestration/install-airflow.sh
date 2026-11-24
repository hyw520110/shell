#!/bin/bash
# Apache Airflow - 工作流调度平台
# 功能：数据管道编排、工作流调度、ETL自动化
# 官方文档：https://airflow.apache.org/
# GitHub: https://github.com/apache/airflow

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
AIRFLOW_VERSION="2.8.0"
PYTHON_VERSION="3.9"
AIRFLOW_HOME="/opt/airflow"
AIRFLOW_USER="airflow"
AIRFLOW_UID="50000"

echo -e "${GREEN}=== Apache Airflow 工作流调度平台 安装脚本 ===${NC}"

# 检查Python环境
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误: 未找到Python 3环境，请先安装Python 3.8+${NC}"
    exit 1
fi

PYTHON_CMD="python3"
PYTHON_VERSION=$(${PYTHON_CMD} --version 2>&1)
echo -e "${YELLOW}Python版本: ${PYTHON_VERSION}${NC}"

# 检查pip
if ! command -v pip3 &> /dev/null; then
    echo -e "${RED}错误: 未找到pip3${NC}"
    exit 1
fi

# 创建Airflow用户和目录
echo -e "${YELLOW}创建Airflow用户和目录...${NC}"
sudo groupadd -g ${AIRFLOW_UID} ${AIRFLOW_USER} 2>/dev/null || true
sudo useradd -r -g ${AIRFLOW_USER} -u ${AIRFLOW_UID} -d ${AIRFLOW_HOME} -s /bin/bash ${AIRFLOW_USER} 2>/dev/null || true
sudo mkdir -p ${AIRFLOW_HOME}
sudo chown -R ${AIRFLOW_USER}:${AIRFLOW_USER} ${AIRFLOW_HOME}

# 设置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/airflow.sh > /dev/null
# Apache Airflow环境变量
export AIRFLOW_HOME=/opt/airflow
export AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/dags
export AIRFLOW__CORE__PLUGINS_FOLDER=/opt/airflow/plugins
export AIRFLOW__CORE__EXECUTOR=LocalExecutor
EOF

source /etc/profile.d/airflow.sh

# 安装Airflow
echo -e "${YELLOW}安装Apache Airflow ${AIRFLOW_VERSION}...${NC}"
sudo -u ${AIRFLOW_USER} pip3 install "apache-airflow==${AIRFLOW_VERSION}"

# 安装常用provider
echo -e "${YELLOW}安装常用Provider...${NC}"
sudo -u ${AIRFLOW_USER} pip3 install \
    apache-airflow-providers-apache-spark \
    apache-airflow-providers-apache-hive \
    apache-airflow-providers-cncf-kubernetes \
    apache-airflow-providers-docker \
    apache-airflow-providers-sqlite \
    apache-airflow-providers-mysql \
    apache-airflow-providers-postgres \
    apache-airflow-providers-ssh \
    apache-airflow-providers-http \
    apache-airflow-providers-ftp \
    apache-airflow-providers-google \
    apache-airflow-providers-amazon

# 创建必要的目录
sudo -u ${AIRFLOW_USER} mkdir -p ${AIRFLOW_HOME}/{dags,logs,plugins,tests}

# 初始化数据库
echo -e "${YELLOW}初始化Airflow数据库...${NC}"
sudo -u ${AIRFLOW_USER} airflow db init

# 创建管理员用户
echo -e "${YELLOW}创建Airflow管理员用户...${NC}"
sudo -u ${AIRFLOW_USER} airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin

# 创建配置文件
cat << 'EOF' | sudo tee ${AIRFLOW_HOME}/airflow.cfg > /dev/null
[core]
# Airflow home directory
airflow_home = /opt/airflow

# The folder where your airflow pipelines live
dags_folder = /opt/airflow/dags

# The folder where airflow should store its log files
base_log_folder = /opt/airflow/logs

# The executor class that airflow should use
executor = LocalExecutor

# The SqlAlchemy connection string to the metadata database
sql_alchemy_conn = sqlite:////opt/airflow/airflow.db

# The amount of parallelism as a setting to the executor
parallelism = 32

# The number of task instances allowed to run concurrently
dag_concurrency = 16

# The maximum number of task instances that can run per task
max_active_tasks_per_dag = 16

# The maximum number of active DAG runs per DAG
max_active_runs_per_dag = 16

# Are DAGs paused by default at creation
dags_are_paused_at_creation = False

# Are DAGs paused by default at creation
load_examples = False

[webserver]
# The base url of your website as airflow cannot guess what domain or
cname you are using
base_url = http://localhost:8080

# The ip on which the web server will listen
web_server_host = 0.0.0.0

# The port on which the web server will listen
web_server_port = 8080

# The time in seconds that the webserver waits for the gunicorn master process
# to gracefully shutdown
web_server_worker_timeout = 120

# Number of workers to run the Gunicorn web server
workers = 4

# The worker class gunicorn should use
worker_class = sync

[database]
# The encoding to use for sqlalchemy
sql_engine_encoding = utf-8

# Sqlalchemy connection string
sql_alchemy_conn = sqlite:////opt/airflow/airflow.db

[cli]
# In what way should the cli access the api
api_client = airflow.api.client.local_client

# Number of workers to run at a time when using the 'airflow dags run' command
dag_run_processor_concurrency = 4

[scheduler]
# Task instances listen for external kill signal (when you clear tasks
# externally using the UI or CLI
child_process_log_directory = /opt/airflow/logs/scheduler

# The scheduler can run multiple threads in parallel to schedule dags
max_threads = 2

# How often (in seconds) to scan the dags directory for new files
dag_dir_list_interval = 300

# How often should scheduler check for orphaned tasks or dead jobs
orphaned_tasks_check_interval = 300

# Pickle configuration for the DAGs
pickle_dags = False

[celery]
# This section is only relevant if you use the CeleryExecutor

[elasticsearch]
# Elasticsearch configuration

[kerberos]
# Kerberos configuration

[github_enterprise]
# Github Enterprise configuration

[admin]
# UI configuration

[smtp]
# SMTP configuration

[oauth]
# OAuth configuration

[api]
# API configuration

[lineage]
# Lineage configuration

[atlas]
# Apache Atlas configuration

[sentry]
# Sentry configuration

[dask]
# Dask configuration
EOF

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/airflow-webserver > /dev/null
#!/bin/bash
# Airflow Web Server启动脚本

AIRFLOW_HOME=/opt/airflow
AIRFLOW_USER=airflow

if [ "$1" == "start" ]; then
    echo "启动Airflow Web Server..."
    sudo -u ${AIRFLOW_USER} airflow webserver --port 8080
elif [ "$1" == "stop" ]; then
    echo "停止Airflow Web Server..."
    sudo -u ${AIRFLOW_USER} pkill -f "airflow webserver"
else
    echo "用法: airflow-webserver {start|stop}"
fi
EOF

sudo chmod +x /usr/local/bin/airflow-webserver

cat << 'EOF' | sudo tee /usr/local/bin/airflow-scheduler > /dev/null
#!/bin/bash
# Airflow Scheduler启动脚本

AIRFLOW_HOME=/opt/airflow
AIRFLOW_USER=airflow

if [ "$1" == "start" ]; then
    echo "启动Airflow Scheduler..."
    sudo -u ${AIRFLOW_USER} airflow scheduler
elif [ "$1" == "stop" ]; then
    echo "停止Airflow Scheduler..."
    sudo -u ${AIRFLOW_USER} pkill -f "airflow scheduler"
else
    echo "用法: airflow-scheduler {start|stop}"
fi
EOF

sudo chmod +x /usr/local/bin/airflow-scheduler

cat << 'EOF' | sudo tee /usr/local/bin/airflow-worker > /dev/null
#!/bin/bash
# Airflow Worker启动脚本

AIRFLOW_HOME=/opt/airflow
AIRFLOW_USER=airflow

if [ "$1" == "start" ]; then
    echo "启动Airflow Worker..."
    sudo -u ${AIRFLOW_USER} airflow worker
elif [ "$1" == "stop" ]; then
    echo "停止Airflow Worker..."
    sudo -u ${AIRFLOW_USER} pkill -f "airflow worker"
else
    echo "用法: airflow-worker {start|stop}"
fi
EOF

sudo chmod +x /usr/local/bin/airflow-worker

# 创建示例DAG
cat << 'EOF' | sudo tee ${AIRFLOW_HOME}/dags/example_dag.py > /dev/null
"""
示例Airflow DAG
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

# 默认参数
default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2024, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

# 创建DAG
dag = DAG(
    'example_dag',
    default_args=default_args,
    description='示例工作流',
    schedule_interval=timedelta(days=1),
    catchup=False,
)

# 任务1: 打印消息
t1 = BashOperator(
    task_id='print_date',
    bash_command='date',
    dag=dag,
)

# 任务2: 睡眠
t2 = BashOperator(
    task_id='sleep',
    bash_command='sleep 5',
    retries=3,
    dag=dag,
)

# 任务3: Python任务
def print_hello(**kwargs):
    print('Hello from Airflow!')

t3 = PythonOperator(
    task_id='print_hello',
    python_callable=print_hello,
    dag=dag,
)

# 设置任务依赖
t1 >> [t2, t3]
EOF

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${AIRFLOW_HOME}/docker-compose.yml > /dev/null
version: '3.8'

services:
  postgres:
    image: postgres:13
    container_name: airflow-postgres
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: airflow
      POSTGRES_DB: airflow
    ports:
      - "5432:5432"
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7
    container_name: airflow-redis
    ports:
      - "6379:6379"
    restart: unless-stopped

  airflow-webserver:
    image: apache/airflow:2.8.0
    container_name: airflow-webserver
    depends_on:
      - postgres
      - redis
    environment:
      - AIRFLOW__CORE__EXECUTOR=CeleryExecutor
      - AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CELERY__BROKER_URL=redis://:@redis:6379/0
      - AIRFLOW__CELERY__RESULT_BACKEND=db+postgresql://airflow:airflow@postgres/airflow
      - AIRFLOW__WEBSERVER__SECRET_KEY=secret_key
    ports:
      - "8080:8080"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: webserver
    restart: unless-stopped

  airflow-scheduler:
    image: apache/airflow:2.8.0
    container_name: airflow-scheduler
    depends_on:
      - postgres
      - redis
    environment:
      - AIRFLOW__CORE__EXECUTOR=CeleryExecutor
      - AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CELERY__BROKER_URL=redis://:@redis:6379/0
      - AIRFLOW__CELERY__RESULT_BACKEND=db+postgresql://airflow:airflow@postgres/airflow
      - AIRFLOW__WEBSERVER__SECRET_KEY=secret_key
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: scheduler
    restart: unless-stopped

  airflow-worker:
    image: apache/airflow:2.8.0
    container_name: airflow-worker
    depends_on:
      - postgres
      - redis
    environment:
      - AIRFLOW__CORE__EXECUTOR=CeleryExecutor
      - AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CELERY__BROKER_URL=redis://:@redis:6379/0
      - AIRFLOW__CELERY__RESULT_BACKEND=db+postgresql://airflow:airflow@postgres/airflow
      - AIRFLOW__WEBSERVER__SECRET_KEY=secret_key
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: celery worker
    restart: unless-stopped

  flower:
    image: apache/airflow:2.8.0
    container_name: airflow-flower
    depends_on:
      - redis
    environment:
      - AIRFLOW__CELERY__BROKER_URL=redis://:@redis:6379/0
    ports:
      - "5555:5555"
    command: celery flower
    restart: unless-stopped
EOF

# 显示安装信息
echo -e "${GREEN}=== Apache Airflow安装完成 ===${NC}"
echo -e "安装目录: ${AIRFLOW_HOME}"
echo -e "配置文件: ${AIRFLOW_HOME}/airflow.cfg"
echo -e "DAG目录: ${AIRFLOW_HOME}/dags"
echo -e "日志目录: ${AIRFLOW_HOME}/logs"
echo ""
echo "用户信息:"
echo "  用户名: admin"
echo "  密码: admin"
echo ""
echo "启动方式:"
echo "  单机模式:"
echo "    airflow-webserver start &"
echo "    airflow-scheduler start &"
echo ""
echo "  Docker模式:"
echo "    cd ${AIRFLOW_HOME}"
echo "    docker-compose up -d"
echo ""
echo "访问地址:"
echo "  Web UI: http://localhost:8080"
echo "  Flower: http://localhost:5555"
echo ""
echo "常用命令:"
echo "  列出DAG: airflow dags list"
echo "  暂停DAG: airflow dags pause <dag_id>"
echo "  恢复DAG: airflow dags unpause <dag_id>"
echo "  触发DAG: airflow dags trigger <dag_id>"
echo ""
echo "卸载:"
echo "  卸载包: sudo -u airflow pip3 uninstall apache-airflow"
echo "  删除目录: sudo rm -rf ${AIRFLOW_HOME} /usr/local/bin/airflow-*"
echo ""
echo -e "${YELLOW}提示: 首次启动需要初始化数据库${NC}"
echo -e "${YELLOW}建议: 生产环境使用PostgreSQL作为元数据库${NC}"

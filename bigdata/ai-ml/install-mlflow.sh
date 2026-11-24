#!/bin/bash
# MLflow - 机器学习实验跟踪平台
# 功能：ML实验管理、模型跟踪、模型部署、参数记录
# 官方文档：https://mlflow.org/
# GitHub: https://github.com/mlflow/mlflow

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置
MLFLOW_VERSION="2.9.0"
MLFLOW_INSTALL_DIR="/opt/mlflow"
MLFLOW_DATA_DIR="/data/mlflow"
MLFLOW_PORT="5000"
MLFLOW_BACKEND_STORE="${MLFLOW_DATA_DIR}/mlflow.db"
MLFLOW_ARTIFACT_ROOT="${MLFLOW_DATA_DIR}/artifacts"

echo -e "${GREEN}=== MLflow 机器学习实验跟踪平台 安装脚本 ===${NC}"

# 检查Python环境
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误: 未找到Python 3环境，请先安装Python 3.7+${NC}"
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

# 创建安装和数据目录
sudo mkdir -p ${MLFLOW_INSTALL_DIR} ${MLFLOW_DATA_DIR}/{artifacts,models,experiments}
sudo chmod 755 ${MLFLOW_INSTALL_DIR} ${MLFLOW_DATA_DIR}

# 创建MLflow用户
if ! id "mlflow" &>/dev/null; then
    echo -e "${YELLOW}创建MLflow用户...${NC}"
    sudo useradd -r -s /bin/bash -d ${MLFLOW_INSTALL_DIR} mlflow || true
    sudo chown -R mlflow:mlflow ${MLFLOW_INSTALL_DIR} ${MLFLOW_DATA_DIR}
fi

# 设置环境变量
cat << 'EOF' | sudo tee /etc/profile.d/mlflow.sh > /dev/null
# MLflow环境变量
export MLFLOW_HOME=/opt/mlflow
export MLFLOW_TRACKING_URI=http://localhost:5000
export MLFLOW_S3_ENDPOINT_URL=http://localhost:9000
export MLFLOW_EXPERIMENT_NAME=default
EOF

source /etc/profile.d/mlflow.sh

# 安装MLflow
echo -e "${YELLOW}安装MLflow ${MLFLOW_VERSION}...${NC}"
sudo -u mlflow pip3 install "mlflow==${MLFLOW_VERSION}"

# 安装常用依赖
echo -e "${YELLOW}安装常用依赖...${NC}"
sudo -u mlflow pip3 install \
    mlflow[extras] \
    scikit-learn \
    pandas \
    numpy \
    matplotlib \
    seaborn \
    boto3 \
    psycopg2-binary \
    mysql-connector-python \
    sqlalchemy \
    click \
    docker

# 创建配置文件
cat << 'EOF' | sudo tee ${MLFLOW_INSTALL_DIR}/mlflow.conf > /dev/null
[mlflow]
# MLflow配置

# 数据库配置
db_uri = sqlite:////data/mlflow/mlflow.db

# 实验配置
experiment_name = default

# 模型注册
registry_uri = sqlite:////data/mlflow/registry.db

# 工件存储
artifact_root = /data/mlflow/artifacts

# 服务器配置
host = 0.0.0.0
port = 5000

# 日志配置
log_level = INFO

# 其他配置
default_artifact_root = /data/mlflow/artifacts
tracking_uri = sqlite:////data/mlflow/mlflow.db
EOF

# 创建启动脚本
cat << 'EOF' | sudo tee /usr/local/bin/mlflow-server > /dev/null
#!/bin/bash
# MLflow Server启动脚本

MLFLOW_HOME=/opt/mlflow
MLFLOW_USER=mlflow
MLFLOW_DATA_DIR=/data/mlflow
MLFLOW_PORT=5000

if [ ! -d "${MLFLOW_HOME}" ]; then
    echo "错误: MLflow未安装"
    echo "请运行: install-mlflow.sh"
    exit 1
fi

if [ "$1" == "start" ]; then
    echo "启动MLflow Server..."
    sudo -u ${MLFLOW_USER} mlflow server \
        --backend-store-uri sqlite:////${MLFLOW_DATA_DIR}/mlflow.db \
        --default-artifact-root ${MLFLOW_DATA_DIR}/artifacts \
        --host 0.0.0.0 \
        --port ${MLFLOW_PORT} \
        --serve-artifacts \
        --gunicorn-opts "--workers 4 --timeout 60" &
    echo "MLflow Server已启动"
    echo "Web UI: http://localhost:${MLFLOW_PORT}"
    echo "Tracking URI: http://localhost:${MLFLOW_PORT}"
elif [ "$1" == "stop" ]; then
    echo "停止MLflow Server..."
    sudo -u ${MLFLOW_USER} pkill -f "mlflow server"
    echo "MLflow Server已停止"
elif [ "$1" == "status" ]; then
    if pgrep -f "mlflow server" > /dev/null; then
        echo "MLflow Server正在运行"
        echo "Web UI: http://localhost:${MLFLOW_PORT}"
    else
        echo "MLflow Server未运行"
    fi
elif [ "$1" == "restart" ]; then
    echo "重启MLflow Server..."
    /usr/local/bin/mlflow-server stop
    sleep 2
    /usr/local/bin/mlflow-server start
else
    echo "用法: mlflow-server {start|stop|status|restart}"
fi
EOF
sudo chmod +x /usr/local/bin/mlflow-server

cat << 'EOF' | sudo tee /usr/local/bin/mlflow-ui > /dev/null
#!/bin/bash
# MLflow UI启动脚本（开发模式）

MLFLOW_HOME=/opt/mlflow
MLFLOW_DATA_DIR=/data/mlflow

if [ ! -d "${MLFLOW_HOME}" ]; then
    echo "错误: MLflow未安装"
    exit 1
fi

echo "启动MLflow UI（开发模式）..."
sudo -u mlflow mlflow ui \
    --backend-store-uri sqlite:////${MLFLOW_DATA_DIR}/mlflow.db \
    --default-artifact-root ${MLFLOW_DATA_DIR}/artifacts \
    --host 0.0.0.0 \
    --port 5000
EOF
sudo chmod +x /usr/local/bin/mlflow-ui

# 创建Docker Compose文件
cat << 'EOF' | sudo tee ${MLFLOW_INSTALL_DIR}/docker-compose.yml > /dev/null
version: '3.8'

services:
  mlflow:
    image: mlflow/mlflow:v2.9.0
    container_name: mlflow-server
    ports:
      - "5000:5000"
    environment:
      - BACKEND_STORE_URI=sqlite:///mlflow.db
      - DEFAULT_ARTIFACT_ROOT=./artifacts
    volumes:
      - ./mlflow-data:/mlflow
      - ./mlflow-db:/mlflow/db
      - ./artifacts:/artifacts
    command: >
      mlflow server
      --backend-store-uri sqlite:////mlflow/mlflow.db
      --default-artifact-root /artifacts
      --host 0.0.0.0
      --port 5000
    restart: unless-stopped

  postgres:
    image: postgres:13
    container_name: mlflow-postgres
    environment:
      POSTGRES_USER: mlflow
      POSTGRES_PASSWORD: mlflow
      POSTGRES_DB: mlflow
    ports:
      - "5432:5432"
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    restart: unless-stopped

  s3:
    image: minio/minio:latest
    container_name: mlflow-s3
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - ./minio-data:/data
    command: server /data --console-address ":9001"
    restart: unless-stopped
EOF

# 创建示例Python脚本
cat << 'EOF' | sudo tee ${MLFLOW_INSTALL_DIR}/examples/basic_tracking.py > /dev/null
#!/usr/bin/env python3
"""
MLflow基础跟踪示例
"""

import mlflow
import mlflow.sklearn
from sklearn.ensemble import RandomForestRegressor
from sklearn.datasets import make_regression
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error, r2_score

# 设置实验
mlflow.set_experiment("mlflow-example")

# 生成示例数据
X, y = make_regression(n_samples=1000, n_features=10, noise=0.1, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# 开始MLflow运行
with mlflow.start_run():
    # 记录参数
    mlflow.log_param("n_estimators", 100)
    mlflow.log_param("max_depth", 5)
    mlflow.log_param("random_state", 42)
    
    # 训练模型
    model = RandomForestRegressor(
        n_estimators=100,
        max_depth=5,
        random_state=42
    )
    model.fit(X_train, y_train)
    
    # 预测
    y_pred = model.predict(X_test)
    
    # 计算指标
    mse = mean_squared_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)
    
    # 记录指标
    mlflow.log_metric("mse", mse)
    mlflow.log_metric("r2", r2)
    
    # 记录模型
    mlflow.sklearn.log_model(model, "random_forest_model")
    
    # 记录额外信息
    mlflow.set_tag("model_type", "RandomForest")
    mlflow.set_tag("framework", "scikit-learn")
    
    print(f"MSE: {mse:.4f}")
    print(f"R2: {r2:.4f}")
    print(f"Run ID: {mlflow.active_run().info.run_id}")
EOF

# 创建高级示例脚本
cat << 'EOF' | sudo tee ${MLFLOW_INSTALL_DIR}/examples/advanced_tracking.py > /dev/null
#!/usr/bin/env python3
"""
MLflow高级跟踪示例
包含参数调优、模型对比、可视化
"""

import mlflow
import mlflow.sklearn
import numpy as np
from sklearn.ensemble import RandomForestRegressor, GradientBoostingRegressor
from sklearn.datasets import make_regression
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error, r2_score
import matplotlib.pyplot as plt

# 设置实验
mlflow.set_experiment("mlflow-advanced-example")

# 生成示例数据
X, y = make_regression(n_samples=1000, n_features=10, noise=0.1, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# 参数搜索空间
param_grid = {
    'n_estimators': [50, 100, 200],
    'max_depth': [3, 5, 7]
}

best_score = -float('inf')
best_run_id = None

# 参数搜索
for n_estimators in param_grid['n_estimators']:
    for max_depth in param_grid['max_depth']:
        # 开始MLflow运行
        with mlflow.start_run(nested=True):
            # 记录参数
            mlflow.log_params({
                "n_estimators": n_estimators,
                "max_depth": max_depth,
                "random_state": 42
            })
            
            # 训练RandomForest模型
            rf_model = RandomForestRegressor(
                n_estimators=n_estimators,
                max_depth=max_depth,
                random_state=42
            )
            rf_model.fit(X_train, y_train)
            
            # 预测
            y_pred = rf_model.predict(X_test)
            
            # 计算指标
            mse = mean_squared_error(y_test, y_pred)
            r2 = r2_score(y_test, y_pred)
            
            # 记录指标
            mlflow.log_metrics({
                "mse": mse,
                "r2": r2,
                "train_score": rf_model.score(X_train, y_train)
            })
            
            # 记录模型
            mlflow.sklearn.log_model(rf_model, "model")
            
            # 记录特征重要性图表
            feature_importance = rf_model.feature_importances_
            plt.figure(figsize=(10, 6))
            plt.bar(range(len(feature_importance)), feature_importance)
            plt.xlabel('Feature Index')
            plt.ylabel('Importance')
            plt.title('Feature Importance')
            plt.savefig('feature_importance.png')
            mlflow.log_artifact('feature_importance.png')
            plt.close()
            
            # 跟踪最佳模型
            if r2 > best_score:
                best_score = r2
                best_run_id = mlflow.active_run().info.run_id
            
            print(f"n_estimators={n_estimators}, max_depth={max_depth}: R2={r2:.4f}")

# 训练GradientBoosting模型进行对比
with mlflow.start_run(run_name="gradient_boosting"):
    mlflow.log_params({
        "n_estimators": 100,
        "max_depth": 5,
        "random_state": 42
    })
    
    gb_model = GradientBoostingRegressor(
        n_estimators=100,
        max_depth=5,
        random_state=42
    )
    gb_model.fit(X_train, y_train)
    
    y_pred = gb_model.predict(X_test)
    r2 = r2_score(y_test, y_pred)
    mse = mean_squared_error(y_test, y_pred)
    
    mlflow.log_metrics({"mse": mse, "r2": r2})
    mlflow.sklearn.log_model(gb_model, "model")
    
    print(f"Gradient Boosting: R2={r2:.4f}")

print(f"\nBest model R2: {best_score:.4f}")
print(f"Best run ID: {best_run_id}")
EOF

# 创建模型部署示例
cat << 'EOF' | sudo tee ${MLFLOW_INSTALL_DIR}/examples/model_deployment.py > /dev/null
#!/usr/bin/env python3
"""
MLflow模型部署示例
"""

import mlflow
from mlflow.tracking import MlflowClient
import numpy as np

# 设置Tracking URI
mlflow.set_tracking_uri("http://localhost:5000")

# 创建客户端
client = MlflowClient()

# 列出所有实验
print("=== 所有实验 ===")
experiments = client.search_experiments()
for exp in experiments:
    print(f"名称: {exp.name}, ID: {exp.experiment_id}")

# 列出模型
print("\n=== 注册的模型 ===")
for model in client.search_registered_models():
    print(f"名称: {model.name}")

# 加载模型（假设已注册）
print("\n=== 加载模型 ===")
try:
    model_uri = "models:/mlflow-example/1"  # 替换为实际模型URI
    model = mlflow.pyfunc.load_model(model_uri)
    
    # 预测
    test_data = np.random.randn(1, 10)  # 替换为实际特征维度
    prediction = model.predict(test_data)
    print(f"预测结果: {prediction}")
except Exception as e:
    print(f"模型加载失败: {e}")

print("\n模型部署提示:")
print("1. 本地部署: mlflow models serve -m models:/<model_name>/<version> -p 5001")
print("2. Docker部署: mlflow models build-docker -m models:/<model_name>/<version> -n <image_name>")
print("3. Kubernetes部署: mlflow models deploy -m models:/<model_name>/<version> -t kubernetes")
EOF

# 创建systemd服务文件
cat << 'EOF' | sudo tee /etc/systemd/system/mlflow.service > /dev/null
[Unit]
Description=MLflow Server
After=network.target

[Service]
Type=simple
User=mlflow
Group=mlflow
WorkingDirectory=/opt/mlflow
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/bin/python3 -m mlflow server \
    --backend-store-uri sqlite:////data/mlflow/mlflow.db \
    --default-artifact-root /data/mlflow/artifacts \
    --host 0.0.0.0 \
    --port 5000 \
    --serve-artifacts \
    --gunicorn-opts "--workers 4 --timeout 60"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 清理临时文件
echo -e "${YELLOW}清理临时文件...${NC}"

# 显示安装信息
echo -e "${GREEN}=== MLflow安装完成 ===${NC}"
echo -e "安装目录: ${MLFLOW_INSTALL_DIR}"
echo -e "数据目录: ${MLFLOW_DATA_DIR}"
echo -e "数据库: ${MLFLOW_BACKEND_STORE}"
echo -e "工件存储: ${MLFLOW_ARTIFACT_ROOT}"
echo ""
echo "用户信息:"
echo "  用户: mlflow"
echo "  UID: $(id -u mlflow 2>/dev/null || echo 'N/A')"
echo ""
echo "启动方式:"
echo "  方式1（开发）: mlflow-ui"
echo "  方式2（生产）: mlflow-server start"
echo "  方式3（服务）: sudo systemctl start mlflow"
echo "  方式4（Docker）: cd ${MLFLOW_INSTALL_DIR} && docker-compose up -d"
echo ""
echo "访问地址:"
echo "  Web UI: http://localhost:5000"
echo "  Tracking URI: http://localhost:5000"
echo ""
echo "示例脚本:"
echo "  基础跟踪: python3 ${MLFLOW_INSTALL_DIR}/examples/basic_tracking.py"
echo "  高级跟踪: python3 ${MLFLOW_INSTALL_DIR}/examples/advanced_tracking.py"
echo "  模型部署: python3 ${MLFLOW_INSTALL_DIR}/examples/model_deployment.py"
echo ""
echo "常用命令:"
echo "  创建实验: mlflow experiments create -n <experiment_name>"
echo "  列出实验: mlflow experiments list"
echo "  删除实验: mlflow experiments delete -n <experiment_name>"
echo "  服务模型: mlflow models serve -m <model_uri> -p 5001"
echo "  构建Docker: mlflow models build-docker -m <model_uri> -n <image_name>"
echo ""
echo "卸载:"
echo "  卸载包: sudo -u mlflow pip3 uninstall mlflow"
echo "  停止服务: sudo systemctl stop mlflow"
echo "  删除目录: sudo rm -rf ${MLFLOW_INSTALL_DIR} ${MLFLOW_DATA_DIR} /usr/local/bin/mlflow-* /etc/systemd/system/mlflow.service"
echo ""
echo -e "${YELLOW}提示: MLflow需要Python 3.7+环境${NC}"
echo -e "${YELLOW}建议: 生产环境使用PostgreSQL作为后端存储${NC}"
echo -e "${YELLOW}建议: 生产环境使用S3兼容存储（如MinIO）存储工件${NC}"
# Locust 分布式压测镜像
# 支持 WSL2/Docker Desktop
FROM python:3.11-slim

# 设置工作目录
WORKDIR /locust

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    bc \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 复制依赖文件
COPY requirements.txt .

# 安装 Python 依赖
RUN pip install --no-cache-dir -r requirements.txt

# 复制脚本和模板
COPY *.py *.sh ./
COPY templates/ ./templates/

# 创建报告目录
RUN mkdir -p /root/locust_reports

# 设置环境变量
ENV BASE_REPORT_DIR="/root/locust_reports"
ENV PYTHONUNBUFFERED=1

# 设置入口点
ENTRYPOINT ["./distributedbench.sh"]

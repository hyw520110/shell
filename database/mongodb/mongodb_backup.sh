#!/bin/bash

# 默认连接信息
DEFAULT_HOST="localhost"
DEFAULT_PORT="27017"
DEFAULT_DB=""
DEFAULT_BACKUP_DIR="/data/backup/mongodb"

# 读取命令行参数
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--host)
      HOST="$2"
      shift 2
      ;;
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -d|--db)
      DB="$2"
      shift 2
      ;;
    -b|--backup-dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 使用默认值
HOST=${HOST:-$DEFAULT_HOST}
PORT=${PORT:-$DEFAULT_PORT}
BACKUP_DIR=${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}

# 检查 MongoDB 连接
check_connection() {
  mongo --host $HOST --port $PORT --eval "db.runCommand({ping:1})" --quiet
}

# 如果连接不可用，提示用户输入
if ! check_connection; then
  echo "无法连接到 MongoDB ($HOST:$PORT)，请检查连接信息或重新输入："
  read -p "Host: " HOST
  read -p "Port: " PORT
  if ! check_connection; then
    echo "连接仍然失败，请检查 MongoDB 服务是否正常运行。"
    exit 1
  fi
fi

# 创建备份目录
mkdir -p $BACKUP_DIR

# 生成备份文件名
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/mongodb_backup_$TIMESTAMP"

# 备份整个数据库或指定数据库
if [ -z "$DB" ]; then
  echo "备份整个数据库..."
  mongodump --host $HOST --port $PORT --out $BACKUP_FILE
else
  echo "备份数据库: $DB"
  mongodump --host $HOST --port $PORT --db $DB --out $BACKUP_FILE
fi

# 检查备份是否成功
if [ $? -eq 0 ]; then
  echo "备份成功: $BACKUP_FILE"
else
  echo "备份失败"
  exit 1
fi

# 添加定时任务
add_cron_job() {
  CRON_JOB="0 1 * * * /path/to/this/script.sh -h $HOST -p $PORT -b $BACKUP_DIR"
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
  echo "定时任务已添加，每天凌晨1点备份 MongoDB。"
}

# 检查是否存在定时任务
if ! crontab -l 2>/dev/null | grep -q "/path/to/this/script.sh"; then
  add_cron_job
else
  echo "定时任务已存在，无需重复添加。"
fi
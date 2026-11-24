#!/bin/bash

# TiDB 备份脚本

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="/opt/tidb"
readonly DEFAULT_BACKUP_DIR="/data/tidb/backup"
readonly DEFAULT_HOST="127.0.0.1"
readonly DEFAULT_PORT="4000"
readonly DEFAULT_USER="root"
readonly DEFAULT_PASSWORD=""

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
USER="$DEFAULT_USER"
PASSWORD="$DEFAULT_PASSWORD"
DATABASE="all"
DRY_RUN=false

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
TiDB 备份脚本

用法: ./backup.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: /opt/tidb)
    -b, --backup-dir DIR 备份目录 (默认: /data/tidb/backup)
    -H, --host HOST     TiDB 主机 (默认: 127.0.0.1)
    -P, --port PORT     TiDB 端口 (默认: 4000)
    -u, --user USER     用户名 (默认: root)
    -p, --password PASS 密码 (默认: 空)
    -D, --database DB   数据库名 (默认: all，备份所有数据库)
    --dry-run           试运行模式
    -h, --help          显示此帮助信息

示例:
    ./backup.sh                                    # 备份所有数据库
    ./backup.sh -D testdb                         # 备份指定数据库
    ./backup.sh -H 192.168.1.100 -P 4000          # 指定主机和端口
    ./backup.sh --dry-run                          # 试运行模式

说明:
    使用 mysqldump 进行备份，TiDB 兼容 MySQL 协议
    备份文件命名格式: tidb_backup_<database>_<timestamp>.sql
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -b|--backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            -H|--host)
                HOST="$2"
                shift 2
                ;;
            -P|--port)
                PORT="$2"
                shift 2
                ;;
            -u|--user)
                USER="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            -D|--database)
                DATABASE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查依赖 ===
check_dependencies() {
    if ! command_exists mysqldump; then
        print_error "未检测到 mysqldump，请先安装 MySQL 客户端"
        exit 1
    fi
    
    print_success "依赖检查通过"
}

# === 检查连接 ===
check_connection() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将检查连接: $HOST:$PORT"
        return 0
    fi
    
    print_info "检查 TiDB 连接..."
    
    local mysql_cmd="mysql -h$HOST -P$PORT -u$USER"
    if [[ -n "$PASSWORD" ]]; then
        mysql_cmd="$mysql_cmd -p$PASSWORD"
    fi
    
    if ! $mysql_cmd -e "SELECT 1" &>/dev/null; then
        print_error "无法连接到 TiDB: $HOST:$PORT"
        exit 1
    fi
    
    print_success "连接成功"
}

# === 获取数据库列表 ===
get_databases() {
    local mysql_cmd="mysql -h$HOST -P$PORT -u$USER"
    if [[ -n "$PASSWORD" ]]; then
        mysql_cmd="$mysql_cmd -p$PASSWORD"
    fi
    
    $mysql_cmd -N -e "SHOW DATABASES" | grep -v "information_schema\|performance_schema\|mysql\|sys"
}

# === 备份数据库 ===
backup_database() {
    local db="$1"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/tidb_backup_${db}_${timestamp}.sql"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将备份数据库: $db 到 $backup_file"
        return 0
    fi
    
    print_info "备份数据库: $db"
    
    local mysqldump_cmd="mysqldump -h$HOST -P$PORT -u$USER"
    if [[ -n "$PASSWORD" ]]; then
        mysqldump_cmd="$mysqldump_cmd -p$PASSWORD"
    fi
    
    # 创建备份
    $mysqldump_cmd --single-transaction --quick --lock-tables=false --routines --triggers --events "$db" > "$backup_file"
    
    # 压缩备份文件
    gzip "$backup_file"
    
    local backup_size=$(du -h "${backup_file}.gz" | cut -f1)
    print_success "备份完成: ${backup_file}.gz (${backup_size})"
}

# === 备份所有数据库 ===
backup_all_databases() {
    print_info "备份所有数据库..."
    
    local databases=$(get_databases)
    
    if [[ -z "$databases" ]]; then
        print_warning "没有找到可备份的数据库"
        return 0
    fi
    
    for db in $databases; do
        backup_database "$db"
    done
}

# === 清理旧备份 ===
cleanup_old_backups() {
    local retention_days=${1:-7}
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将清理 $retention_days 天前的备份"
        return 0
    fi
    
    print_info "清理 $retention_days 天前的备份..."
    
    find "$BACKUP_DIR" -name "tidb_backup_*.sql.gz" -type f -mtime +$retention_days -delete
    
    print_success "旧备份清理完成"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 检查连接
    check_connection
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    
    # 备份数据库
    if [[ "$DATABASE" == "all" ]]; then
        backup_all_databases
    else
        backup_database "$DATABASE"
    fi
    
    # 清理旧备份（保留 7 天）
    cleanup_old_backups 7
    
    print_success "备份完成!"
    print_info "备份目录: $BACKUP_DIR"
}

# === 执行主函数 ===
main "$@"
#!/bin/bash

# TiDB 导出脚本

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
TABLE=""
DRY_RUN=false
COMPRESS=true

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
TiDB 导出脚本

用法: ./export.sh [选项]

选项:
    -d, --dir DIR       安装目录 (默认: /opt/tidb)
    -b, --backup-dir DIR 备份目录 (默认: /data/tidb/backup)
    -H, --host HOST     TiDB 主机 (默认: 127.0.0.1)
    -P, --port PORT     TiDB 端口 (默认: 4000)
    -u, --user USER     用户名 (默认: root)
    -p, --password PASS 密码 (默认: 空)
    -D, --database DB   数据库名 (默认: all，导出所有数据库)
    -t, --table TABLE   表名 (与 -D 一起使用，导出指定表)
    --no-compress       不压缩导出文件
    --dry-run           试运行模式
    -h, --help          显示此帮助信息

示例:
    ./export.sh                                    # 导出所有数据库
    ./export.sh -D testdb                         # 导出指定数据库
    ./export.sh -D testdb -t users                # 导出指定表
    ./export.sh --no-compress -D testdb           # 导出不压缩
    ./export.sh --dry-run                          # 试运行模式

说明:
    使用 mysqldump 导出数据，TiDB 兼容 MySQL 协议
    导出文件命名格式: tidb_export_<database>_<timestamp>.sql
    默认压缩为 .sql.gz 格式
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
            -t|--table)
                TABLE="$2"
                shift 2
                ;;
            --no-compress)
                COMPRESS=false
                shift
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
    
    if ! command_exists gzip; then
        print_error "未检测到 gzip，请先安装 gzip"
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

# === 导出数据库 ===
export_database() {
    local db="$1"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/tidb_export_${db}_${timestamp}.sql"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将导出数据库: $db 到 $backup_file"
        return 0
    fi
    
    print_info "导出数据库: $db"
    
    local mysqldump_cmd="mysqldump -h$HOST -P$PORT -u$USER"
    if [[ -n "$PASSWORD" ]]; then
        mysqldump_cmd="$mysqldump_cmd -p$PASSWORD"
    fi
    
    # 导出表或整个数据库
    if [[ -n "$TABLE" ]]; then
        print_info "导出表: $TABLE"
        $mysqldump_cmd --single-transaction --quick --lock-tables=false --routines --triggers --events "$db" "$TABLE" > "$backup_file"
    else
        $mysqldump_cmd --single-transaction --quick --lock-tables=false --routines --triggers --events "$db" > "$backup_file"
    fi
    
    # 压缩导出文件
    if [[ "$COMPRESS" == true ]]; then
        gzip "$backup_file"
        local backup_size=$(du -h "${backup_file}.gz" | cut -f1)
        print_success "导出完成: ${backup_file}.gz (${backup_size})"
    else
        local backup_size=$(du -h "$backup_file" | cut -f1)
        print_success "导出完成: $backup_file (${backup_size})"
    fi
}

# === 导出所有数据库 ===
export_all_databases() {
    print_info "导出所有数据库..."
    
    local databases=$(get_databases)
    
    if [[ -z "$databases" ]]; then
        print_warning "没有找到可导出的数据库"
        return 0
    fi
    
    for db in $databases; do
        export_database "$db"
    done
}

# === 清理旧导出 ===
cleanup_old_exports() {
    local retention_days=${1:-7}
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将清理 $retention_days 天前的导出"
        return 0
    fi
    
    print_info "清理 $retention_days 天前的导出..."
    
    find "$BACKUP_DIR" -name "tidb_export_*.sql*" -type f -mtime +$retention_days -delete
    
    print_success "旧导出清理完成"
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
    
    # 导出数据库
    if [[ "$DATABASE" == "all" ]]; then
        export_all_databases
    else
        export_database "$DATABASE"
    fi
    
    # 清理旧导出（保留 7 天）
    cleanup_old_exports 7
    
    print_success "导出完成!"
    print_info "导出目录: $BACKUP_DIR"
}

# === 执行主函数 ===
main "$@"
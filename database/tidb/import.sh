#!/bin/bash

# TiDB 导入脚本

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly DEFAULT_INSTALL_DIR="/opt/tidb"
readonly DEFAULT_HOST="127.0.0.1"
readonly DEFAULT_PORT="4000"
readonly DEFAULT_USER="root"
readonly DEFAULT_PASSWORD=""

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
USER="$DEFAULT_USER"
PASSWORD="$DEFAULT_PASSWORD"
DATABASE=""
FILE=""
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
TiDB 导入脚本

用法: ./import.sh [选项] <备份文件>

选项:
    -d, --dir DIR       安装目录 (默认: /opt/tidb)
    -H, --host HOST     TiDB 主机 (默认: 127.0.0.1)
    -P, --port PORT     TiDB 端口 (默认: 4000)
    -u, --user USER     用户名 (默认: root)
    -p, --password PASS 密码 (默认: 空)
    -D, --database DB   目标数据库 (默认: 从备份文件名提取)
    --dry-run           试运行模式
    -h, --help          显示此帮助信息

参数:
    <备份文件>           要导入的 SQL 文件（支持 .sql 和 .sql.gz）

示例:
    ./import.sh backup.sql                     # 导入 SQL 文件
    ./import.sh backup.sql.gz                  # 导入压缩的 SQL 文件
    ./import.sh -D testdb backup.sql          # 导入到指定数据库
    ./import.sh --dry-run backup.sql          # 试运行模式

说明:
    使用 mysql 客户端导入数据，TiDB 兼容 MySQL 协议
    支持导入单个数据库或整个数据库集群
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
            -*)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
            *)
                FILE="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$FILE" ]]; then
        print_error "请指定要导入的备份文件"
        show_usage
        exit 1
    fi
}

# === 检查依赖 ===
check_dependencies() {
    if ! command_exists mysql; then
        print_error "未检测到 mysql，请先安装 MySQL 客户端"
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

# === 检查备份文件 ===
check_backup_file() {
    if [[ ! -f "$FILE" ]]; then
        print_error "备份文件不存在: $FILE"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将导入文件: $FILE"
        return 0
    fi
    
    # 提取数据库名
    if [[ -z "$DATABASE" ]]; then
        local filename=$(basename "$FILE")
        DATABASE=$(echo "$filename" | sed -E 's/tidb_backup_([^_]+).*/\1/')
        
        if [[ "$DATABASE" == "$filename" ]]; then
            print_warning "无法从文件名提取数据库名，将导入到指定数据库"
            DATABASE="temp_$(date +%s)"
        fi
    fi
    
    print_info "导入到数据库: $DATABASE"
}

# === 导入备份文件 ===
import_backup_file() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将执行导入操作"
        return 0
    fi
    
    print_info "开始导入备份文件: $FILE"
    
    local mysql_cmd="mysql -h$HOST -P$PORT -u$USER"
    if [[ -n "$PASSWORD" ]]; then
        mysql_cmd="$mysql_cmd -p$PASSWORD"
    fi
    
    # 创建数据库
    print_info "创建数据库: $DATABASE"
    $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS $DATABASE;"
    
    # 解压并导入
    if [[ "$FILE" == *.gz ]]; then
        print_info "解压并导入数据..."
        gunzip -c "$FILE" | $mysql_cmd "$DATABASE"
    else
        print_info "导入数据..."
        $mysql_cmd "$DATABASE" < "$FILE"
    fi
    
    print_success "导入完成!"
    
    # 显示数据库信息
    print_info "数据库信息:"
    $mysql_cmd "$DATABASE" -e "SHOW TABLES;"
}

# === 主函数 ===
main() {
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 检查连接
    check_connection
    
    # 检查备份文件
    check_backup_file
    
    # 导入备份文件
    import_backup_file
    
    print_success "导入完成!"
    print_info "数据库: $DATABASE"
    print_info "访问方式: mysql -h $HOST -P $PORT -u $USER -D $DATABASE"
}

# === 执行主函数 ===
main "$@"
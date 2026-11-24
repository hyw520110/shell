#!/bin/bash

# =====================================================================
# export_sql.sh - MySQL 数据库备份/导出脚本
#
# 功能：
#   - 将指定数据库（或全部用户数据库）导出为 SQL 文件
#   - 支持可选 gzip 压缩
#   - 按日期归档到导出目录
#   - 双模式：本地 mysql 命令 / Docker MySQL 容器
#
# 用法：
#   ./export_sql.sh
#
# 环境变量（可选，优先级低于交互输入）：
#   MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD
#   MYSQL_ROOT_PASSWORD   - Docker 容器 root 密码
#   EXPORT_DIR            - 导出目录（默认 /opt/mysql/export）
# =====================================================================

# 公共变量
MYSQL_HOST="mysql-server"
MYSQL_PORT=3306
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
ENV_FILE="./conf/.mysql.env"
# 默认导出目录：当前用户 home 下（可写），非硬编码系统目录
DEFAULT_EXPORT_DIR="${HOME:-/tmp}/mysql_exports"
USE_GZIP=true
USE_PACK=false
# 本次会话导出的最终文件列表（after_export 记录，pack_exports 使用）
EXPORTED_FILES=()

# ----------------------------
# 从环境变量文件加载密码
# ----------------------------
load_env_password() {
    if [ -f "$ENV_FILE" ]; then
        local pw
        pw=$(grep "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2-)
        if [ -n "$pw" ]; then
            MYSQL_PASSWORD="$pw"
            MYSQL_ROOT_PASSWORD="$pw"
            return 0
        fi
    fi
    return 1
}

# ----------------------------
# 解析可执行文件路径（不硬编码：当前目录 -> PATH -> 常见安装位置）
# ----------------------------
resolve_bin() {
    local name="$1"
    if [ -x "./$name" ]; then
        echo "./$name"
        return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    for p in /usr/local/mysql/bin /usr/local/mysql*/bin /usr/local/bin \
             /usr/bin /usr/local/sbin /opt/mysql/bin /opt/mysql/*/bin \
             /www/server/mysql/bin /usr/local/mariadb/bin; do
        if [ -x "$p/$name" ]; then
            echo "$p/$name"
            return 0
        fi
    done
    return 1
}

# 已解析的二进制路径（main 中初始化）
MYSQL_BIN=""
MYSQLDUMP_BIN=""
MYSQLADMIN_BIN=""

init_bins() {
    MYSQL_BIN=$(resolve_bin mysql) || true
    MYSQLDUMP_BIN=$(resolve_bin mysqldump) || true
    MYSQLADMIN_BIN=$(resolve_bin mysqladmin) || true
    if [ -z "$MYSQL_BIN" ]; then
        echo "错误：未找到 mysql 可执行文件。"
        exit 1
    fi
}

# ----------------------------
# 检查命令是否存在
# ----------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1 || { test -x "./$1" && chmod +x "./$1"; }
}

# ----------------------------
# 检测 Docker 容器 ID
# ----------------------------
find_docker_container() {
    docker ps 2>/dev/null | grep "mysql" | grep -v "NAMES" | awk '{print $1}'
}

# ----------------------------
# 检查本地 MySQL 连接
# ----------------------------
check_mysql_connection() {
    MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQL_BIN" -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -e "SELECT 1;" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "错误：MySQL 连接失败（$MYSQL_HOST:$MYSQL_PORT）。"
        return 1
    fi
    return 0
}

# ----------------------------
# 列出数据库（本地模式）
# ----------------------------
list_databases_local() {
    MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQL_BIN" -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -N -e \
        "SELECT SCHEMA_NAME FROM information_schema.schemata WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME;"
}

# ----------------------------
# 列出数据库（Docker 模式）
# ----------------------------
list_databases_docker() {
    local container_id="$1"
    docker exec -i "$container_id" env MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root -N -e \
        "SELECT SCHEMA_NAME FROM information_schema.schemata WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME;"
}

# ----------------------------
# 导出单个数据库（本地模式）
# ----------------------------
export_db_local() {
    local db_name="$1"
    local export_dir="$2"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local sql_file="$export_dir/${db_name}_${timestamp}.sql"

    echo "导出 $db_name -> $export_dir/ ..."
    MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQLDUMP_BIN" -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" \
        --single-transaction --routines --triggers --events \
        --databases "$db_name" > "$sql_file"
    if [ $? -ne 0 ]; then
        echo "错误：导出数据库 '$db_name' 失败。"
        rm -f "$sql_file"
        return 1
    fi
    after_export "$sql_file" "$db_name" "$export_dir"
    return 0
}

# ----------------------------
# 导出单个数据库（Docker 模式）
# ----------------------------
export_db_docker() {
    local container_id="$1"
    local db_name="$2"
    local export_dir="$3"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local sql_file="$export_dir/${db_name}_${timestamp}.sql"

    echo "导出 $db_name（Docker: $container_id）-> $export_dir/ ..."
    docker exec -i "$container_id" env MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -u root \
        --single-transaction --routines --triggers --events \
        --databases "$db_name" > "$sql_file"
    if [ $? -ne 0 ]; then
        echo "错误：导出数据库 '$db_name' 失败。"
        rm -f "$sql_file"
        return 1
    fi
    after_export "$sql_file" "$db_name" "$export_dir"
    return 0
}

# ----------------------------
# 导出后处理：可选 gzip 压缩
# ----------------------------
after_export() {
    local sql_file="$1"
    local db_name="$2"
    local export_dir="$3"
    local size
    size=$(du -h "$sql_file" 2>/dev/null | awk '{print $1}')

    if $USE_GZIP; then
        gzip -f "$sql_file"
        if [ $? -eq 0 ]; then
            echo "已生成：$sql_file.gz（压缩后 $(du -h "$sql_file.gz" | awk '{print $1}')，原始 $size）"
            EXPORTED_FILES+=("$sql_file.gz")
        else
            echo "警告：gzip 压缩失败，保留原始 SQL 文件。已生成：$sql_file（$size）"
            EXPORTED_FILES+=("$sql_file")
        fi
    else
        echo "已生成：$sql_file（$size）"
        EXPORTED_FILES+=("$sql_file")
    fi
}

# ----------------------------
# 确认压缩选项
# ----------------------------
ask_compress() {
    read -p "是否 gzip 压缩导出文件？(Y/n): " compress_input
    case "$compress_input" in
        [Nn]*) USE_GZIP=false ;;
        *)     USE_GZIP=true ;;
    esac
    if $USE_GZIP; then
        echo "将生成 .sql.gz 文件。"
    else
        echo "将生成纯 .sql 文件。"
    fi
}

# ----------------------------
# 确认是否打包（多库导出时才有意义）
# ----------------------------
ask_pack() {
    if [ ${#SELECTED_DATABASES[@]} -le 1 ]; then
        USE_PACK=false
        return 0
    fi
    read -p "是否打包所有导出为单个 .tar.gz 方便传输？(y/N): " pack_input
    case "$pack_input" in
        [Yy]*) USE_PACK=true ;;
        *)     USE_PACK=false ;;
    esac
}

# ----------------------------
# 打包导出的压缩包为单个 tar.gz，成功后删除中间 .sql.gz
# ----------------------------
pack_exports() {
    local export_dir="$1"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local tar_file="$export_dir/mysql_backup_${timestamp}.tar.gz"

    # 使用本次会话记录的导出文件（EXPORTED_FILES）
    if [ ${#EXPORTED_FILES[@]} -eq 0 ]; then
        echo "警告：未找到本次导出的文件，跳过打包。"
        return 1
    fi

    local count=${#EXPORTED_FILES[@]}
    echo "正在打包 $count 个文件 -> $tar_file ..."

    # 打包（basename 列表，-C 切到目录）
    local names=""
    for f in "${EXPORTED_FILES[@]}"; do
        names="$names $(basename "$f")"
    done

    if tar czf "$tar_file" -C "$export_dir" $names 2>/dev/null; then
        local size
        size=$(du -h "$tar_file" 2>/dev/null | awk '{print $1}')
        echo "已生成：$tar_file（$size）"

        # 删除中间 .sql.gz / .sql（用户要求：打包完成删除中间压缩包）
        local deleted=0
        for f in "${EXPORTED_FILES[@]}"; do
            if rm -f "$f" 2>/dev/null; then
                deleted=$((deleted + 1))
            fi
        done
        echo "已删除中间文件（共 $deleted 个）。"
        return 0
    else
        echo "错误：tar 打包失败，保留原始文件。"
        return 1
    fi
}

# ----------------------------
# 交互式收集导出库列表
# ----------------------------
collect_databases() {
    local list_source="$1"
    local dbs
    dbs=$(echo "$list_source")

    if [ -z "$dbs" ]; then
        echo "未发现可导出的用户数据库。"
        return 1
    fi

    echo "检测到以下用户数据库："
    local idx=1
    local -a db_array=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        db_array+=("$line")
        printf "  %d) %s\n" "$idx" "$line"
        idx=$((idx + 1))
    done <<< "$dbs"

    echo ""
    read -p "输入要导出的数据库序号（多个用空格分隔，输入 all 导出全部，直接回车导出全部）: " selection

    if [ -z "$selection" ] || [ "$selection" = "all" ]; then
        SELECTED_DATABASES=("${db_array[@]}")
        return 0
    fi

    SELECTED_DATABASES=()
    for token in $selection; do
        if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#db_array[@]}" ]; then
            SELECTED_DATABASES+=("${db_array[$((token - 1))]}")
        else
            echo "警告：忽略无效输入 '$token'。"
        fi
    done

    if [ ${#SELECTED_DATABASES[@]} -eq 0 ]; then
        echo "未选择任何数据库。"
        return 1
    fi
    return 0
}

# ----------------------------
# 主函数
# ----------------------------
main() {
    init_bins

    # 确保 nc 可用（nc 存在优先；否则尝试静默安装 nmap-ncat；再失败回退 /dev/tcp）
    ensure_nc() {
        if command -v nc >/dev/null 2>&1; then
            return 0
        fi
        # 尝试静默安装（免密 sudo + yum）
        if command -v yum >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo yum install -y nmap-ncat >/dev/null 2>&1 && command -v nc >/dev/null 2>&1 && return 0
        fi
        if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo apt-get install -y netcat-openbsd >/dev/null 2>&1 && command -v nc >/dev/null 2>&1 && return 0
        fi
        return 1
    }

    # 检测本机 3306 是否可用（有 mysql 客户端且端口可达）
    local local_3306_ok=false
    if [ -n "$MYSQL_BIN" ] && [ -x "$MYSQL_BIN" ]; then
        if ensure_nc; then
            nc -z -w 2 127.0.0.1 3306 >/dev/null 2>&1 && local_3306_ok=true
        elif (exec 3<>/dev/tcp/127.0.0.1/3306) 2>/dev/null; then
            exec 3>&- 2>/dev/null
            local_3306_ok=true
        fi
    fi

    # 连接信息：本机 3306 可用时，回车直接确认；否则需输入
    if $local_3306_ok; then
        read -p "检测到本机 3306 可用。回车直接使用 (127.0.0.1:3306)，或输入 IP 和端口 (如 192.168.1.10:3306): " host_port
        if [ -n "$host_port" ]; then
            MYSQL_HOST="${host_port%%:*}"
            local port_part="${host_port#*:}"
            if [ "$port_part" != "$host_port" ] && [ -n "$port_part" ]; then
                MYSQL_PORT="$port_part"
            fi
        else
            MYSQL_HOST="127.0.0.1"
            MYSQL_PORT=3306
        fi
    else
        read -p "输入连接地址 (默认: ${MYSQL_HOST}): " host_input
        MYSQL_HOST="${host_input:-${MYSQL_HOST}}"
        read -p "输入端口 (默认: ${MYSQL_PORT}): " port_input
        MYSQL_PORT="${port_input:-$MYSQL_PORT}"
    fi
    echo "连接目标：$MYSQL_HOST:$MYSQL_PORT"

    read -p "请输入 MySQL 用户名 (默认: ${MYSQL_USER}): " input_user
    MYSQL_USER="${input_user:-root}"

    if [ "$MYSQL_USER" = "root" ] && ! load_env_password; then
        read -sp "请输入 MySQL 密码: " MYSQL_PASSWORD
        echo
    fi
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$MYSQL_PASSWORD}"

    # 导出目录
    read -p "请输入导出目录 (默认: ${DEFAULT_EXPORT_DIR}): " dir_input
    DEFAULT_EXPORT_DIR="${dir_input:-$DEFAULT_EXPORT_DIR}"
    if ! mkdir -p "$DEFAULT_EXPORT_DIR" 2>/dev/null || [ ! -w "$DEFAULT_EXPORT_DIR" ]; then
        # 自动回退到可写目录
        local fallback_dir="/tmp/mysql_exports"
        if mkdir -p "$fallback_dir" 2>/dev/null && [ -w "$fallback_dir" ]; then
            echo "目录 $DEFAULT_EXPORT_DIR 不可写，回退到 $fallback_dir"
            DEFAULT_EXPORT_DIR="$fallback_dir"
        else
            echo "错误：无法写入导出目录 $DEFAULT_EXPORT_DIR（且回退 $fallback_dir 失败）。"
            exit 1
        fi
    fi

    ask_compress

    # 确定连接方式
    local container_id=""
    container_id=$(find_docker_container)
    local use_docker=false

    # 判断本地 mysql 是否可用（已解析出路径即为可用）
    local have_local=false
    [ -n "$MYSQL_BIN" ] && [ -x "$MYSQL_BIN" ] && have_local=true

    if $have_local && [ -n "$container_id" ]; then
        read -p "请选择连接方式 (1: 本地 MySQL, 2: Docker 容器): " choice
        case "$choice" in
            2) use_docker=true ;;
            *)  use_docker=false ;;
        esac
    elif [ -n "$container_id" ]; then
        use_docker=true
        echo "未找到本地 mysql 命令，使用 Docker 容器连接。"
    elif $have_local; then
        use_docker=false
        if ! check_mysql_connection; then
            echo "本地 MySQL 连接失败，终止。"
            exit 1
        fi
    else
        echo "错误：未找到可用的 MySQL 连接方式（既无本地 mysql 命令，也无运行中的 MySQL 容器）。"
        exit 1
    fi

    # 列出数据库
    local db_list
    if $use_docker; then
        db_list=$(list_databases_docker "$container_id")
    else
        db_list=$(list_databases_local)
    fi

    # 选择数据库
    if ! collect_databases "$db_list"; then
        exit 1
    fi

    echo ""
    echo "即将导出：${SELECTED_DATABASES[*]} -> $DEFAULT_EXPORT_DIR（$($USE_GZIP && echo 'gzip' || echo '无压缩')）"

    # 询问是否打包（多库导出）
    ask_pack

    read -p "确认开始导出？(Y/n): " confirm
    case "$confirm" in
        [Nn]*) echo "已取消。"; exit 0 ;;
    esac

    # 执行导出
    local fail=0
    local ok=0
    for db in "${SELECTED_DATABASES[@]}"; do
        if $use_docker; then
            export_db_docker "$container_id" "$db" "$DEFAULT_EXPORT_DIR"
        else
            export_db_local "$db" "$DEFAULT_EXPORT_DIR"
        fi
        if [ $? -eq 0 ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    echo ""
    echo "导出完成：成功 $ok 个，失败 $fail 个。"
    if [ $fail -gt 0 ]; then
        exit 1
    fi

    # 打包（若启用）
    if $USE_PACK; then
        pack_exports "$DEFAULT_EXPORT_DIR"
    fi
    exit 0
}

main

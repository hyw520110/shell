#!/bin/bash

# 公共变量
MYSQL_HOST="mysql-server"
MYSQL_PORT=3306
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
ENV_FILE="./conf/.mysql.env"
DEFAULT_SQL_DIR="/opt/mysql/db"

# 检查 MySQL 是否可达
check_mysql_connection() {
    echo "正在检查与 $MYSQL_HOST:$MYSQL_PORT 的 MySQL 连接..."
    ./mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "MySQL 连接成功。"
        return 0
    else
        echo "MySQL 连接失败。"
        return 1
    fi
}

# 执行 MySQL 命令
execute_mysql_command() {
    local command="$1"
    echo "正在执行 MySQL 命令: $command"
    ./mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "$command"
    if [ $? -ne 0 ]; then
        echo "MySQL 命令执行失败: $command"
        return 1
    fi
    echo "MySQL 命令执行成功: $command"
    return 0
}

# 使用 Docker 执行 MySQL 命令
execute_with_docker() {
    local sql_file="$1"
    local db_name="$2"
    local container_id=$(docker ps 2>/dev/null|grep "mysql"|grep -v "NAMES"|awk '{print $1}')

    if [ -z "$container_id" ]; then
        echo "未找到正在运行的 MySQL Docker 容器。"
        return 1
    fi

    echo "找到 MySQL Docker 容器，ID: $container_id"

    # 检查数据库是否已存在
    if docker exec -i "$container_id" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT COUNT(1) FROM information_schema.schemata WHERE schema_name = '$db_name'" | grep -qw 1; then
        read -p "数据库 '$db_name' 已经存在。是否跳过此文件的创建和导入？(y/n): " skip_input
        if [[ "$skip_input" =~ ^[Yy]$ ]]; then
            echo "跳过导入 '$sql_file' 到数据库 '$db_name'。"
            return 0
        else
            timestamp=$(date +"%Y%m%d%H%M%S")
            new_db_name="${db_name}_backup_${timestamp}"
            echo "尝试备份现有数据库 '$db_name' 并导入新数据..."

            # 备份现有数据库
            backup_sql_file="/tmp/${db_name}_backup_${timestamp}.sql"
            docker exec -i "$container_id" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$db_name" > "$backup_sql_file"
            if [ $? -ne 0 ]; then
                echo "无法备份数据库 '$db_name'。"
                return 1
            fi
            echo "成功备份数据库 '$db_name' 到 '$backup_sql_file'。"

            # 删除现有数据库
            docker exec -i "$container_id" mysqladmin -u root -p"$MYSQL_ROOT_PASSWORD" drop "$db_name" -f
            if [ $? -ne 0 ]; then
                echo "无法删除数据库 '$db_name'。"
                return 1
            fi
            echo "成功删除数据库 '$db_name'。"

            # 创建新的数据库
            docker exec -i "$container_id" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $db_name;"
            if [ $? -ne 0 ]; then
                echo "无法创建数据库 '$db_name'。"
                return 1
            fi
            echo "成功创建数据库 '$db_name'。"

            # 导入 SQL 文件
            docker cp "$sql_file" "$container_id:/tmp/$db_name.sql"
            docker exec -i "$container_id" mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$db_name" < "/tmp/$db_name.sql"
            if [ $? -ne 0 ]; then
                echo "无法将数据导入到数据库 '$db_name'。"
                return 1
            fi
            echo "成功将数据导入到数据库 '$db_name'（使用 Docker）。"
            return 0
        fi
    fi

    # 创建数据库
    echo "正在创建数据库 '$db_name'..."
    docker exec -i "$container_id" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $db_name;"
    if [ $? -ne 0 ]; then
        echo "无法创建数据库 '$db_name'。"
        return 1
    fi
    echo "成功创建数据库 '$db_name'。"

    # 导入 SQL 文件
    echo "正在将 SQL 文件 '$sql_file' 复制到容器中..."
    docker cp "$sql_file" "$container_id:/tmp/$db_name.sql"
    if [ $? -ne 0 ]; then
        echo "无法将 SQL 文件复制到容器中。"
        return 1
    fi
    echo "SQL 文件已成功复制到容器中。"

    echo "正在导入 SQL 文件到数据库 '$db_name'..."
    docker exec -i "$container_id" mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$db_name" < "/tmp/$db_name.sql"
    if [ $? -ne 0 ]; then
        echo "无法将数据导入到数据库 '$db_name'。"
        return 1
    fi
    echo "成功将数据导入到数据库 '$db_name'（使用 Docker）。"
    return 0
}

# 处理 SQL 文件
process_sql_files() {
    local sql_dir="$1"
    local sql_prefix="$2"
    local use_docker=false
    local use_mysql=false

    # 检测 mysql 命令是否存在
    if command_exists mysql; then
        use_mysql=true
    fi

    # 检测是否有正在运行的 MySQL Docker 容器
    local container_id=$(docker ps 2>/dev/null|grep "mysql"|grep -v "NAMES"|awk '{print $1}')

    if [ -z "$container_id" ]; then
        use_docker=true
    fi

    if ! $use_mysql && ! $use_docker; then
        echo "未找到可用的 MySQL 连接方式。请确保安装了 MySQL 或启动了 MySQL Docker 容器。"
        exit 1
    fi

    if $use_mysql && $use_docker; then
        read -p "请选择连接方式 (1: MySQL, 2: Docker): " choice
        case $choice in
            1)
                use_docker=false
                ;;
            2)
                use_mysql=false
                ;;
            *)
                echo "无效的选择，默认使用 MySQL。"
                use_docker=false
                ;;
        esac
    elif $use_mysql; then
        echo "仅找到 MySQL 命令，使用 MySQL 进行连接。"
    elif $use_docker; then
        echo "仅找到 MySQL Docker 容器，使用 Docker 进行连接。"
    fi

    # 检查 MySQL 连接
    if $use_mysql && ! check_mysql_connection; then
        echo "本地 MySQL 连接失败，尝试使用 Docker..."
        use_mysql=false
        use_docker=true
    fi

    if [ -z "$sql_prefix" ]; then
        sql_pattern="$sql_dir/*.sql"
    else
        sql_pattern="$sql_dir/$sql_prefix*.sql"
    fi

    for sql_file in $sql_pattern; do
        if [ -f "$sql_file" ]; then
            base_name=$(basename "$sql_file" ".sql")
            db_name_from_sql=$(grep -Eo 'CREATE\s+DATABASE\s+\S+' "$sql_file" | awk '{print $3}' | head -n 1)
            read -p "请输入数据库名 (默认: ${db_name_from_sql:-$base_name}): " db_name_input
            db_name="${db_name_input:-${db_name_from_sql:-$base_name}}"

            if $use_docker; then
                execute_with_docker "$sql_file" "$db_name"
            else
                create_and_import_db "$sql_file" "$db_name"
            fi
        fi
    done
}

# 创建数据库并导入 SQL 文件
create_and_import_db() {
    local sql_file="$1"
    local db_name="$2"

    # 检查数据库是否已存在
    if execute_mysql_command "SELECT COUNT(1) FROM information_schema.schemata WHERE schema_name = '$db_name';" | grep -qw 1; then
        read -p "数据库 '$db_name' 已经存在。是否跳过此文件的创建和导入？(y/n): " skip_input
        if [[ "$skip_input" =~ ^[Yy]$ ]]; then
            echo "跳过导入 '$sql_file' 到数据库 '$db_name'。"
            return 0
        else
            timestamp=$(date +"%Y%m%d%H%M%S")
            new_db_name="${db_name}_backup_${timestamp}"
            echo "尝试备份现有数据库 '$db_name' 并导入新数据..."

            # 备份现有数据库
            backup_sql_file="/tmp/${db_name}_backup_${timestamp}.sql"
            ./mysqldump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$db_name" > "$backup_sql_file"
            if [ $? -ne 0 ]; then
                echo "无法备份数据库 '$db_name'。"
                return 1
            fi
            echo "成功备份数据库 '$db_name' 到 '$backup_sql_file'。"

            # 删除现有数据库
            ./mysqladmin -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" drop "$db_name" -f
            if [ $? -ne 0 ]; then
                echo "无法删除数据库 '$db_name'。"
                return 1
            fi
            echo "成功删除数据库 '$db_name'。"
        fi
    fi

    # 创建数据库
    echo "正在创建数据库 '$db_name'..."
    execute_mysql_command "CREATE DATABASE IF NOT EXISTS $db_name;"
    if [ $? -ne 0 ]; then
        echo "无法创建数据库 '$db_name'。"
        return 1
    fi
    echo "成功创建数据库 '$db_name'。"

    # 导入 SQL 文件
    echo "正在导入 SQL 文件到数据库 '$db_name'..."
    ./mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$db_name" < "$sql_file"
    if [ $? -ne 0 ]; then
        echo "无法将数据导入到数据库 '$db_name'。"
        return 1
    fi
    echo "成功将数据导入到数据库 '$db_name'。"
    return 0
}

# 函数：检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1 || { test -f "./$1" && chmod +x "./$1"; }
}

# 主函数
main() {
    read -p "输入连接地址(默认: ${MYSQL_HOST}): " host_input
    MYSQL_HOST="${host_input:-${MYSQL_HOST}}"
    read -p "输入端口(默认: ${MYSQL_PORT}): " port_input
    MYSQL_PORT=${port_input:-$MYSQL_PORT}
    read -p "请输入 MySQL 用户名 (默认: ${MYSQL_USER}): " input_user
    MYSQL_USER="${input_user:-root}"

    if [ "$MYSQL_USER" == "root" ] && [ -f "$ENV_FILE" ]; then
        MYSQL_PASSWORD=$(grep "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2-)
    else
        read -sp "请输入 MySQL 密码: " MYSQL_PASSWORD
        echo
    fi

    read -p "请输入 SQL 文件目录 (默认: $DEFAULT_SQL_DIR): " dir_input
    DEFAULT_SQL_DIR="${dir_input:-$DEFAULT_SQL_DIR}"

    read -p "请输入 SQL 文件名前缀（留空导入全部 SQL 文件）: " sql_prefix

    process_sql_files "$DEFAULT_SQL_DIR" "$sql_prefix"
}

# 运行主函数
main







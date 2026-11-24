#!/bin/bash

# XXL-JOB一键安装配置脚本
# 分布式任务调度平台，支持任务可视化管理、监控、调度

set -e

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly XXL_JOB_VERSION="2.4.0"
readonly XXL_JOB_IMAGE="xuxueli/xxl-job-admin"
readonly DEFAULT_XXL_JOB_PORT=18080
readonly DEFAULT_INSTALL_DIR="$HOME/xxl-job"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
readonly DEFAULT_MYSQL_HOST="localhost"
readonly DEFAULT_MYSQL_PORT=3306
readonly DEFAULT_MYSQL_DATABASE="xxl_job"
readonly DEFAULT_MYSQL_USERNAME="root"
readonly DEFAULT_MYSQL_PASSWORD=""
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
readonly DEFAULT_HEALTH_TIMEOUT=60

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
XXL_JOB_PORT="$DEFAULT_XXL_JOB_PORT"
MYSQL_HOST="${XXL_JOB_MYSQL_HOST:-$DEFAULT_MYSQL_HOST}"
MYSQL_PORT="${XXL_JOB_MYSQL_PORT:-$DEFAULT_MYSQL_PORT}"
MYSQL_DATABASE="${XXL_JOB_MYSQL_DATABASE:-$DEFAULT_MYSQL_DATABASE}"
MYSQL_USERNAME="${XXL_JOB_MYSQL_USERNAME:-$DEFAULT_MYSQL_USERNAME}"
MYSQL_PASSWORD="${XXL_JOB_MYSQL_PASSWORD:-$DEFAULT_MYSQL_PASSWORD}"
MYSQL_PASSWORD_CONFIGURED=false
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
ADMIN_JAR_FILE="${XXL_JOB_ADMIN_JAR:-}"
JAVA_HOME_OVERRIDE="${XXL_JOB_JAVA_HOME:-${JAVA_HOME:-}}"
XXL_JOB_ACCESS_TOKEN="${XXL_JOB_ACCESS_TOKEN:-}"
HEALTH_TIMEOUT="${XXL_JOB_HEALTH_TIMEOUT:-$DEFAULT_HEALTH_TIMEOUT}"
DRY_RUN=false
UNINSTALL_MODE=false
USE_DOCKER=auto

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

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

# === 检查命令是否存在 ===
command_exists() {
    command -v "$1" &>/dev/null
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [[ "$(basename "$input")" == xxl-job* ]]; then
        echo "$input"
    else
        echo "$input/xxl-job"
    fi
}

detect_java_cmd() {
    if [[ -n "${JAVA_HOME_OVERRIDE:-}" && -x "$JAVA_HOME_OVERRIDE/bin/java" ]]; then
        echo "$JAVA_HOME_OVERRIDE/bin/java"
        return 0
    fi

    if command_exists java; then
        command -v java
        return 0
    fi

    local candidate
    for candidate in \
        "$HOME/.local/jdk/openjdk-21/bin/java" \
        "$HOME/jdk/jdk-21/zulu-21.jdk/Contents/Home/bin/java" \
        "/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home/bin/java"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

find_adl() {
    command -v adl 2>/dev/null || return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local output_file

    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"
    mkdir -p "$output_dir"

    if find_adl >/dev/null 2>&1; then
        print_info "使用 adl 下载: $url"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi

    if command_exists curl; then
        print_info "使用 curl 下载: $url"
        rm -f "$output"
        curl --http1.1 --retry 3 --retry-delay 2 --connect-timeout 20 -fsSL "$url" -o "$output"
        return $?
    fi

    if command_exists wget; then
        print_info "使用 wget 下载: $url"
        wget -q "$url" -O "$output"
        return $?
    fi

    print_error "未找到可用下载工具，请先安装 adl、curl 或 wget"
    return 1
}

mysql_exec() {
    local args=("-h${MYSQL_HOST}" "-P${MYSQL_PORT}" "-u${MYSQL_USERNAME}")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        args+=("-p${MYSQL_PASSWORD}")
    fi
    mysql "${args[@]}" "$@"
}

mysql_db_exec() {
    local database="$1"
    shift
    mysql_exec "$database" "$@"
}

mysql_config_complete() {
    [[ -n "${MYSQL_HOST:-}" && -n "${MYSQL_PORT:-}" && -n "${MYSQL_USERNAME:-}" ]] || return 1
    [[ "$MYSQL_PASSWORD_CONFIGURED" == true || -n "${MYSQL_PASSWORD:-}" ]] || return 1
    return 0
}

prompt_mysql_config() {
    local input

    read -r -p "请输入 MySQL 主机/IP (默认: ${MYSQL_HOST:-localhost}): " input
    MYSQL_HOST="${input:-${MYSQL_HOST:-localhost}}"

    read -r -p "请输入 MySQL 端口 (默认: ${MYSQL_PORT:-3306}): " input
    MYSQL_PORT="${input:-${MYSQL_PORT:-3306}}"

    read -r -p "请输入 MySQL 用户名 (默认: ${MYSQL_USERNAME:-root}): " input
    MYSQL_USERNAME="${input:-${MYSQL_USERNAME:-root}}"

    read -r -s -p "请输入 MySQL 密码 (可为空): " MYSQL_PASSWORD
    echo
    MYSQL_PASSWORD_CONFIGURED=true
}

check_tcp_port() {
    local host="$1"
    local port="$2"

    if command_exists nc; then
        nc -z -G 3 "$host" "$port" >/dev/null 2>&1 || nc -z -w 3 "$host" "$port" >/dev/null 2>&1
        return $?
    fi

    if command_exists perl; then
        perl -MIO::Socket::INET -e 'exit(IO::Socket::INET->new(PeerAddr=>$ARGV[0],PeerPort=>$ARGV[1],Proto=>"tcp",Timeout=>3)?0:1)' "$host" "$port"
        return $?
    fi

    print_warning "未找到 nc/perl，无法检测 TCP 端口通达性"
    return 1
}

test_mysql_connection() {
    if command_exists mysql; then
        mysql_exec -e "SELECT 1" &>/dev/null
        return $?
    fi

    print_warning "未检测到 mysql 客户端，仅检测 $MYSQL_HOST:$MYSQL_PORT 端口通达性"
    check_tcp_port "$MYSQL_HOST" "$MYSQL_PORT"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
XXL-JOB一键安装配置脚本

用法: ./install-xxl-job.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/xxl-job)
    --download-dir DIR          下载目录 (默认: ~/Downloads，可用 DOWNLOAD_DIR 覆盖)
    -p, --port PORT             XXL-JOB 端口 (默认: 18080)
    --mysql-host HOST           MySQL 主机地址 (默认: localhost)
    --mysql-port PORT           MySQL 端口 (默认: 3306)
    --mysql-database DATABASE   MySQL 数据库名 (默认: xxl_job)
    --mysql-username USERNAME   MySQL 用户名 (默认: root)
    --mysql-password PASSWORD   MySQL 密码 (默认: 空)
    --admin-jar FILE            使用已构建的 xxl-job-admin jar，适合目标机无 Maven 的环境
    --java-home DIR             指定 JDK 目录；未指定时自动识别常见 JDK 路径
    --access-token TOKEN        XXL-JOB 调度中心通信令牌，需与执行器配置保持一致
    --health-timeout SECONDS    启动健康检查等待秒数 (默认: 60)
    --dry-run                   试运行模式，显示将要执行的操作但不实际执行
    --uninstall                 卸载XXL-JOB

环境变量:
    XXL_JOB_MYSQL_HOST          MySQL 主机 (等效 --mysql-host)
    XXL_JOB_MYSQL_PORT          MySQL 端口 (等效 --mysql-port)
    XXL_JOB_MYSQL_DATABASE      MySQL 数据库 (等效 --mysql-database)
    XXL_JOB_MYSQL_USERNAME      MySQL 用户名 (等效 --mysql-username)
    XXL_JOB_MYSQL_PASSWORD      MySQL 密码 (等效 --mysql-password)
    XXL_JOB_ADMIN_JAR           已构建的 xxl-job-admin jar 路径
    XXL_JOB_JAVA_HOME           JDK 目录
    XXL_JOB_ACCESS_TOKEN        调度中心通信令牌

环境要求:
    Docker - 容器化部署 (推荐)
    MySQL 5.7+ - 数据库存储
    JDK 8+ - Java 运行环境 (如不使用 Docker)

示例:
    ./install-xxl-job.sh                           # 使用默认设置安装
    ./install-xxl-job.sh --port 19080             # 指定端口
    ./install-xxl-job.sh --mysql-host 192.168.1.100 --mysql-password 123456
    ./install-xxl-job.sh --uninstall              # 卸载XXL-JOB
    ./install-xxl-job.sh --dry-run                # 试运行模式

使用指南:
    1. 安装完成后，访问: http://localhost:18080/xxl-job-admin
    2. 默认账号: admin / 123456
    3. 在业务项目中集成 Executor 执行器
    4. 在管理界面创建任务并配置调度规则

更多信息: https://www.xuxueli.com/xxl-job/
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            --download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            -p|--port)
                XXL_JOB_PORT="$2"
                shift 2
                ;;
            --mysql-host)
                MYSQL_HOST="$2"
                shift 2
                ;;
            --mysql-port)
                MYSQL_PORT="$2"
                shift 2
                ;;
            --mysql-database)
                MYSQL_DATABASE="$2"
                shift 2
                ;;
            --mysql-username)
                MYSQL_USERNAME="$2"
                shift 2
                ;;
            --mysql-password)
                MYSQL_PASSWORD="$2"
                MYSQL_PASSWORD_CONFIGURED=true
                shift 2
                ;;
            --admin-jar)
                ADMIN_JAR_FILE="${2/#\~/$HOME}"
                shift 2
                ;;
            --java-home)
                JAVA_HOME_OVERRIDE="${2/#\~/$HOME}"
                shift 2
                ;;
            --access-token)
                XXL_JOB_ACCESS_TOKEN="$2"
                shift 2
                ;;
            --health-timeout)
                HEALTH_TIMEOUT="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
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
    if [[ "$USE_DOCKER" == auto ]]; then
        if command_exists docker && docker info &>/dev/null && { docker compose version &>/dev/null || command_exists docker-compose; }; then
            USE_DOCKER=true
            print_success "Docker 环境检查通过"
        else
            USE_DOCKER=false
            print_warning "Docker 未安装、未启动或 Docker Compose 不可用，将使用主机系统安装模式"
        fi
    fi

    if [[ "$USE_DOCKER" == true ]]; then
        if ! command_exists docker; then
            print_warning "未检测到 Docker，将使用主机系统安装模式"
            USE_DOCKER=false
            return 0
        fi

        if ! docker info &>/dev/null; then
            print_warning "Docker 命令存在但服务未运行，将使用主机系统安装模式"
            USE_DOCKER=false
            return 0
        fi
        
        if ! docker compose version &>/dev/null && ! command_exists docker-compose; then
            print_warning "未检测到 Docker Compose，将使用主机系统安装模式"
            USE_DOCKER=false
            return 0
        fi
        
        print_success "Docker 环境检查通过"
    else
        if ! detect_java_cmd >/dev/null 2>&1; then
            print_error "主机模式需要 Java，请先安装 JDK"
            exit 1
        fi
        if [[ -z "${ADMIN_JAR_FILE:-}" ]] && ! command_exists mvn; then
            print_error "主机模式需要 Maven，请先安装 Maven"
            print_info "或通过 --admin-jar FILE 指定已构建的 xxl-job-admin jar"
            exit 1
        fi
        print_success "主机系统环境检查通过"
    fi
}

# 检测是否有 TTY（交互式终端）
has_tty() {
    [[ -t 0 ]]
}

# === 检查 MySQL 连接 ===
check_mysql_connection() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将检查 MySQL 连接: $MYSQL_HOST:$MYSQL_PORT"
        return 0
    fi

    if ! mysql_config_complete; then
        if has_tty; then
            print_warning "MySQL 连接配置不完整，请输入连接信息"
            prompt_mysql_config
        else
            print_error "MySQL 连接配置不完整，且当前为非交互式环境，无法提示输入"
            print_info "请通过以下方式提供 MySQL 连接信息:"
            print_info "  1. 命令行参数: --mysql-host HOST --mysql-port PORT --mysql-username USER --mysql-password PASS"
            print_info "  2. 环境变量: XXL_JOB_MYSQL_HOST/HOST/USER/PASS"
            print_info ""
            print_info "示例:"
            print_info "  ./install-xxl-job.sh --mysql-host 127.0.0.1 --mysql-port 3306 --mysql-username root --mysql-password 123456"
            print_info "  XXL_JOB_MYSQL_PASSWORD=123456 ./install-xxl-job.sh"
            exit 1
        fi
    fi

    print_info "检查 MySQL 连接: $MYSQL_HOST:$MYSQL_PORT..."

    if ! test_mysql_connection; then
        if has_tty; then
            print_warning "MySQL 连接测试失败，请重新输入连接信息"
            prompt_mysql_config

            if ! test_mysql_connection; then
                print_error "无法连接到 MySQL: $MYSQL_HOST:$MYSQL_PORT"
                print_info "请检查 MySQL 是否运行，IP/端口/用户名/密码是否正确"
                exit 1
            fi
        else
            print_error "无法连接到 MySQL: $MYSQL_HOST:$MYSQL_PORT"
            print_info "请检查 MySQL 是否运行，IP/端口/用户名/密码是否正确"
            print_info "当前配置:"
            print_info "  主机: $MYSQL_HOST"
            print_info "  端口: $MYSQL_PORT"
            print_info "  用户名: $MYSQL_USERNAME"
            print_info "  密码: $(if [[ -n "$MYSQL_PASSWORD" ]]; then echo '***已设置***'; else echo '未设置'; fi)"
            exit 1
        fi
    fi

    print_success "MySQL 连接成功"
}

# === 创建数据库 ===
create_database() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将创建数据库: $MYSQL_DATABASE"
        return 0
    fi

    if ! command_exists mysql; then
        print_warning "未安装 mysql 客户端，跳过自动创建数据库: $MYSQL_DATABASE"
        print_warning "请手动确保数据库存在并导入 XXL-JOB 表结构"
        return 0
    fi
    
    print_info "检查数据库..."
    
    # 检查数据库是否存在
    DB_EXISTS=$(mysql_exec -N -B \
        -e "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$MYSQL_DATABASE';" 2>/dev/null | tr -d '[:space:]')
    DB_EXISTS=${DB_EXISTS:-0}
    
    if [[ "$DB_EXISTS" -eq 0 ]]; then
        print_info "创建数据库: $MYSQL_DATABASE"
        mysql_exec -e "CREATE DATABASE \`$MYSQL_DATABASE\` DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;"
        print_success "数据库创建成功"
    else
        print_info "数据库已存在: $MYSQL_DATABASE"
    fi
}

# === 初始化数据库 ===
init_database() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将初始化数据库表结构"
        return 0
    fi

    if ! command_exists mysql; then
        print_warning "未安装 mysql 客户端，跳过自动初始化 XXL-JOB 表结构"
        return 0
    fi
    
    print_info "初始化数据库表结构..."
    
    # 检查是否已初始化
    TABLE_COUNT=$(mysql_db_exec "$MYSQL_DATABASE" -N -B -e "SHOW TABLES;" 2>/dev/null | wc -l | tr -d '[:space:]')
    TABLE_COUNT=${TABLE_COUNT:-0}
    
    if [[ "$TABLE_COUNT" -gt 0 ]]; then
        print_warning "数据库已包含表，跳过初始化"
        return 0
    fi
    
    # 下载并执行初始化脚本
    local init_sql_url="https://raw.githubusercontent.com/xuxueli/xxl-job/${XXL_JOB_VERSION}/doc/db/tables_xxl_job.sql"
    
    local init_sql_file="$DOWNLOAD_DIR/tables_xxl_job-${XXL_JOB_VERSION}.sql"
    if ! download_file "$init_sql_url" "$init_sql_file"; then
        print_error "下载初始化脚本失败: $init_sql_url"
        exit 1
    fi

    mysql_db_exec "$MYSQL_DATABASE" < "$init_sql_file"
    
    print_success "数据库初始化成功"
}

# === 创建目录结构 ===
create_directories() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将创建目录: $INSTALL_DIR"
        return 0
    fi
    
    mkdir -p "$INSTALL_DIR"
    print_success "目录创建完成: $INSTALL_DIR"
}

# === 生成 docker-compose.yml ===
generate_docker_compose() {
    local compose_file="$INSTALL_DIR/$DOCKER_COMPOSE_FILE"
    local access_token_param=""
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将生成: $compose_file"
        return 0
    fi
    
    print_info "生成 docker-compose.yml..."

    if [[ -n "${XXL_JOB_ACCESS_TOKEN:-}" ]]; then
        access_token_param=" \\
               --xxl.job.accessToken=${XXL_JOB_ACCESS_TOKEN}"
    fi
    
    cat > "$compose_file" << EOF
version: '3.8'

services:
  xxl-job-admin:
    image: xuxueli/xxl-job-admin:${XXL_JOB_VERSION}
    container_name: xxl-job-admin
    restart: unless-stopped
    ports:
      - "${XXL_JOB_PORT}:8080"
    environment:
      - PARAMS=--spring.datasource.url=jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}?useUnicode=true&characterEncoding=UTF-8&autoReconnect=true&serverTimezone=Asia/Shanghai \\
               --spring.datasource.username=${MYSQL_USERNAME} \\
               --spring.datasource.password=${MYSQL_PASSWORD}${access_token_param}
    volumes:
      - ./data/applogs:/data/applogs
    networks:
      - xxl-job-network

networks:
  xxl-job-network:
    driver: bridge
EOF

    print_success "docker-compose.yml 生成成功"
}

# === 启动 XXL-JOB ===
start_xxl_job() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将启动 XXL-JOB"
        return 0
    fi
    
    print_info "启动 XXL-JOB..."
    cd "$INSTALL_DIR"
    docker compose up -d
    
    print_success "XXL-JOB 启动成功"
    print_info "访问地址: http://localhost:${XXL_JOB_PORT}/xxl-job-admin"
    print_info "默认账号: admin / 123456"
}

install_host_xxl_job() {
    print_header "主机系统安装 XXL-JOB..."

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将下载源码并构建 XXL-JOB Admin"
        return 0
    fi

    local source_url="https://github.com/xuxueli/xxl-job/archive/refs/tags/${XXL_JOB_VERSION}.zip"
    local source_zip="$DOWNLOAD_DIR/xxl-job-${XXL_JOB_VERSION}.zip"
    local build_dir="$DOWNLOAD_DIR/xxl-job-${XXL_JOB_VERSION}"
    local jar_file
    local java_cmd

    mkdir -p "$DOWNLOAD_DIR" "$INSTALL_DIR"/{bin,logs,conf}

    if [[ -n "${ADMIN_JAR_FILE:-}" ]]; then
        if [[ ! -f "$ADMIN_JAR_FILE" ]]; then
            print_error "指定的 xxl-job-admin jar 不存在: $ADMIN_JAR_FILE"
            exit 1
        fi
        jar_file="$ADMIN_JAR_FILE"
    else
        if [[ ! -f "$source_zip" ]]; then
            download_file "$source_url" "$source_zip"
        fi

        rm -rf "$build_dir"
        # macOS 自带 unzip 遇到仓库 doc 目录中的中文文件名时可能误报 write error 并进入交互。
        # 构建 xxl-job-admin 不需要 doc 目录，排除它以保证非交互安装稳定。
        unzip -q -o "$source_zip" -d "$DOWNLOAD_DIR" -x "*/doc/*" "*/doc/**"

        if [[ ! -d "$build_dir" ]]; then
            print_error "源码解压失败: $build_dir"
            exit 1
        fi

        if [[ -n "${JAVA_HOME_OVERRIDE:-}" && -x "$JAVA_HOME_OVERRIDE/bin/java" ]]; then
            (cd "$build_dir" && JAVA_HOME="$JAVA_HOME_OVERRIDE" PATH="$JAVA_HOME_OVERRIDE/bin:$PATH" mvn -q -DskipTests package)
        else
            (cd "$build_dir" && mvn -q -DskipTests package)
        fi
        jar_file="$(find "$build_dir/xxl-job-admin/target" -maxdepth 1 -name 'xxl-job-admin-*.jar' ! -name '*sources*' | head -1)"
    fi
    if [[ -z "$jar_file" || ! -f "$jar_file" ]]; then
        print_error "未找到 xxl-job-admin jar"
        exit 1
    fi

    cp "$jar_file" "$INSTALL_DIR/xxl-job-admin.jar"
    java_cmd="$(detect_java_cmd)"

    cat > "$INSTALL_DIR/conf/logback.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration debug="false" scan="true" scanPeriod="30 seconds">
    <contextName>logback</contextName>
    <property name="log.path" value="$INSTALL_DIR/logs/xxl-job-admin.file.log"/>

    <appender name="console" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <pattern>%d{HH:mm:ss.SSS} %contextName [%thread] %-5level %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>

    <appender name="file" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>\${log.path}</file>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>\${log.path}.%d{yyyy-MM-dd}.zip</fileNamePattern>
        </rollingPolicy>
        <encoder>
            <pattern>%date %level [%thread] %logger{36} [%file : %line] %msg%n</pattern>
        </encoder>
    </appender>

    <root level="info">
        <appender-ref ref="console"/>
        <appender-ref ref="file"/>
    </root>
</configuration>
EOF

    cat > "$INSTALL_DIR/start.sh" << EOF
#!/bin/bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
mkdir -p "\$SCRIPT_DIR/logs"
JAVA_CMD="${java_cmd}"
if pgrep -f "\$SCRIPT_DIR/xxl-job-admin.jar" >/dev/null 2>&1; then
  echo "XXL-JOB Admin 已在运行"
  exit 0
fi
nohup "\$JAVA_CMD" \\
  -Dlogging.config="file:\$SCRIPT_DIR/conf/logback.xml" \\
  -Dlogback.configurationFile="\$SCRIPT_DIR/conf/logback.xml" \\
  -jar "\$SCRIPT_DIR/xxl-job-admin.jar" \\
  --server.port=${XXL_JOB_PORT} \\
  --spring.datasource.url='jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}?useUnicode=true&characterEncoding=UTF-8&autoReconnect=true&serverTimezone=Asia/Shanghai' \\
  --spring.datasource.username='${MYSQL_USERNAME}' \\
  --spring.datasource.password='${MYSQL_PASSWORD}' \\
  --xxl.job.accessToken='${XXL_JOB_ACCESS_TOKEN}' \\
  > "\$SCRIPT_DIR/logs/xxl-job-admin.log" 2>&1 &
echo "XXL-JOB Admin 已启动: http://localhost:${XXL_JOB_PORT}/xxl-job-admin"
echo "日志: \$SCRIPT_DIR/logs/xxl-job-admin.log"
EOF

    cat > "$INSTALL_DIR/stop.sh" << EOF
#!/bin/bash
pids=\$(pgrep -f "$INSTALL_DIR/xxl-job-admin.jar" || true)
if [ -z "\$pids" ]; then
  echo "XXL-JOB Admin 未运行"
  exit 0
fi
kill \$pids 2>/dev/null || true
echo "XXL-JOB Admin 已停止"
EOF

    chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/stop.sh"
    print_success "XXL-JOB 主机系统安装完成"
}

start_host_xxl_job() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将启动主机模式 XXL-JOB"
        return 0
    fi

    "$INSTALL_DIR/start.sh"
}

wait_xxl_job_health() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将等待 XXL-JOB 健康检查"
        return 0
    fi

    local url="http://127.0.0.1:${XXL_JOB_PORT}/xxl-job-admin"
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    print_info "等待 XXL-JOB Admin 启动: $url"

    while (( SECONDS < deadline )); do
        if command_exists curl && curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
            print_success "XXL-JOB Admin 健康检查通过"
            return 0
        fi
        sleep 2
    done

    print_error "XXL-JOB Admin 启动超时，请查看日志: $INSTALL_DIR/logs/xxl-job-admin.log"
    return 1
}

# === 停止 XXL-JOB ===
stop_xxl_job() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将停止 XXL-JOB"
        return 0
    fi
    
    print_info "停止 XXL-JOB..."
    cd "$INSTALL_DIR"
    docker compose down
    print_success "XXL-JOB 已停止"
}

# === 卸载 XXL-JOB ===
uninstall_xxl_job() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将卸载 XXL-JOB"
        print_info "[试运行] 将删除目录: $INSTALL_DIR"
        return 0
    fi
    
    print_info "卸载 XXL-JOB..."
    
    # 停止并删除容器
    if [[ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]]; then
        cd "$INSTALL_DIR"
        docker compose down -v
    fi
    
    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        print_success "已删除安装目录: $INSTALL_DIR"
    fi
    
    # 询问是否删除数据库
    read -p "是否删除数据库 $MYSQL_DATABASE? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" \
            -e "DROP DATABASE $MYSQL_DATABASE;"
        print_success "数据库已删除"
    fi
    
    print_success "XXL-JOB 卸载完成"
}

# === 主函数 ===
main() {
    print_header "XXL-JOB一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_xxl_job
        exit 0
    fi
    
    # 检查 MySQL 连接
    check_mysql_connection
    
    # 创建数据库
    create_database
    
    # 初始化数据库
    init_database
    
    # 创建目录
    create_directories

    if [[ "$USE_DOCKER" == true ]]; then
        generate_docker_compose
        start_xxl_job
    else
        install_host_xxl_job
        start_host_xxl_job
    fi

    wait_xxl_job_health
    
    print_header "安装完成!"
    print_success "XXL-JOB 已成功安装并启动"
    print_info "访问地址: http://localhost:${XXL_JOB_PORT}/xxl-job-admin"
    print_info "默认账号: admin / 123456"
    print_info "安装目录: $INSTALL_DIR"
    
    print_info "常用命令:"
    if [[ "$USE_DOCKER" == true ]]; then
        print_info "  启动: cd $INSTALL_DIR && docker compose up -d"
        print_info "  停止: cd $INSTALL_DIR && docker compose down"
        print_info "  查看日志: cd $INSTALL_DIR && docker compose logs -f"
    else
        print_info "  启动: cd $INSTALL_DIR && ./start.sh"
        print_info "  停止: cd $INSTALL_DIR && ./stop.sh"
        print_info "  查看日志: tail -f $INSTALL_DIR/logs/xxl-job-admin.log"
    fi
}

# === 执行主函数 ===
main "$@"

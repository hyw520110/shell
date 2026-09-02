#!/bin/bash

# Seata一键安装配置脚本
# 阿里巴巴开源的分布式事务解决方案

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
readonly SEATA_VERSION="2.0.0"
readonly SEATA_IMAGE="seataio/seata-server"
readonly DEFAULT_SEATA_PORT=8091
readonly DEFAULT_INSTALL_DIR="$HOME/seata"
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
SEATA_PORT="$DEFAULT_SEATA_PORT"
DRY_RUN=false
UNINSTALL_MODE=false
INSTALL_BACKEND=""

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "seata" ]; then
        echo "$input"
    else
        echo "$input/seata"
    fi
}

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

download_file() {
    local url="$1"
    local output="$2"
    local output_dir
    local output_file

    output_dir="$(dirname "$output")"
    output_file="$(basename "$output")"

    # 确保下载目录存在且当前用户可写
    if [ -d "$output_dir" ]; then
        if [ ! -w "$output_dir" ]; then
            print_warning "下载目录无写入权限，尝试修复: $output_dir"
            if command -v sudo >/dev/null 2>&1; then
                sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
            fi
        fi
    else
        mkdir -p "$output_dir" || {
            print_error "无法创建下载目录: $output_dir"
            return 1
        }
    fi

    # 如果目标文件存在但不可写（如之前用 sudo 下载），删除它
    if [ -f "$output" ] && [ ! -w "$output" ]; then
        print_warning "目标文件存在但无写入权限，尝试删除: $output"
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -f "$output" 2>/dev/null || {
                print_error "无法删除只读文件: $output"
                return 1
            }
        else
            print_error "目标文件只读且无法删除: $output"
            return 1
        fi
    fi

    # 如果存在同名的 aria2 断点文件也可能导致问题，一并清理
    if [ -f "$output.aria2" ] && [ ! -w "$output.aria2" ]; then
        sudo rm -f "$output.aria2" 2>/dev/null || rm -f "$output.aria2" 2>/dev/null || true
    fi

    if command -v adl >/dev/null 2>&1; then
        print_info "使用 adl 下载: $url"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi

    if command -v curl >/dev/null 2>&1; then
        print_info "使用 curl 下载: $url"
        curl -L -C - "$url" -o "$output"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        print_info "使用 wget 下载: $url"
        wget -c "$url" -O "$output"
        return $?
    fi

    print_error "未找到可用下载工具，请先安装 adl、curl 或 wget"
    return 1
}

verify_archive() {
    local archive="$1"
    [ -s "$archive" ] && tar -tzf "$archive" >/dev/null 2>&1
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Seata一键安装配置脚本

Seata是阿里巴巴开源的分布式事务解决方案，致力于提供高性能和简单易用的分布式事务服务。

用法: ./install-seata.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/seata)
    --download-dir DIR          下载目录 (默认: ~/Downloads，可用 DOWNLOAD_DIR 覆盖)
    -p, --port PORT             端口号 (默认: 8091)
    --dry-run                   试运行模式
    --uninstall                 卸载Seata

示例:
    ./install-seata.sh                           # 使用默认设置安装
    ./install-seata.sh --port 7091              # 指定端口
    ./install-seata.sh --uninstall              # 卸载Seata

使用指南:
    1. 启动Seata: cd $INSTALL_DIR && docker-compose up -d
    2. 访问控制台: http://localhost:7091
    3. 客户端接入: 在应用中引入seata依赖

更多信息: https://seata.io/
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
                SEATA_PORT="$2"
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

# === 检查Docker是否可用于安装 ===
check_docker_available() {
    if ! command -v docker &> /dev/null; then
        print_warning "未检测到Docker，将使用主机系统安装模式"
        return 1
    fi

    if ! docker info &> /dev/null; then
        print_warning "检测到Docker命令，但Docker未启动，将使用主机系统安装模式"
        return 1
    fi

    print_info "检测到Docker: $(docker --version)"
    return 0
}

check_docker_compose_available() {
    if command -v docker-compose &> /dev/null; then
        print_info "检测到Docker Compose: $(docker-compose --version)"
        return 0
    elif docker compose version &> /dev/null; then
        print_info "检测到Docker Compose Plugin: $(docker compose version)"
        return 0
    else
        print_warning "未检测到Docker Compose，将使用主机系统安装模式"
        return 1
    fi
}

docker_install_available() {
    check_docker_available && check_docker_compose_available
}

# === 创建Docker Compose配置 ===
create_docker_compose() {
    print_header "创建Docker Compose配置..."
    
    mkdir -p "$INSTALL_DIR"
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  seata-server:
    image: ${SEATA_IMAGE}:${SEATA_VERSION}
    container_name: seata-server
    restart: always
    ports:
      - "${SEATA_PORT}:8091"
      - "7091:7091"
    environment:
      - TZ=Asia/Shanghai
      - SEATA_PORT=8091
      - STORE_MODE=db
    volumes:
      - ./conf:/seata-server/resources
      - ./logs:/root/logs/seata
    networks:
      - seata-network
    depends_on:
      - mysql
      - redis

  mysql:
    image: mysql:8.0
    container_name: seata-mysql
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=seata
      - TZ=Asia/Shanghai
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d
    networks:
      - seata-network
    ports:
      - "3306:3306"

  redis:
    image: redis:7.0
    container_name: seata-redis
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - seata-network

networks:
  seata-network:
    driver: bridge

volumes:
  mysql-data:
  redis-data:
EOF
    
    print_success "Docker Compose配置创建完成: $INSTALL_DIR/$DOCKER_COMPOSE_FILE"
}

# === 创建配置文件 ===
create_config_files() {
    print_header "创建配置文件..."
    
    mkdir -p "$INSTALL_DIR/conf"
    
    # 创建file.conf
    cat > "$INSTALL_DIR/conf/file.conf" << 'EOF'
## transaction log store, only used in seata-server
store {
  ## store mode: file、db、redis
  mode = "db"

  ## rsa decryption public key
  publicKey = ""

  ## file store property
  file {
    ## store location dir
    dir = "sessionStore"

    # branch session size , if exceeded first try compress keysize 1024 bytes
    maxBranchSessionSize = 16384
    # globe session size , if exceeded first try compress keysize 1024 bytes
    maxGlobalSessionSize = 512
    # file buffer size , if exceeded allocate new buffer
    fileWriteBufferCacheSize = 16384
    # when recover batch read size
    sessionReloadReadSize = 100
    # async delete session
    asyncCommitBufferLimit = 10000
  }

  ## database store property
  db {
    ## the implement of javax.sql.DataSource, such as DruidDataSource(druid)/BasicDataSource(dbcp)/HikariDataSource(hikari) etc.
    datasource = "druid"
    ## mysql/oracle/postgresql/h2/oceanbase etc.
    dbType = "mysql"
    driverClassName = "com.mysql.cj.jdbc.Driver"
    ## if using mysql to store the data, recommend add rewriteBatchedStatements=true in jdbc connection param
    url = "jdbc:mysql://mysql:3306/seata?rewriteBatchedStatements=true&serverTimezone=Asia/Shanghai"
    user = "root"
    password = "root"
    minConn = 5
    maxConn = 100
    globalTable = "global_table"
    branchTable = "branch_table"
    lockTable = "lock_table"
    distributedLockTable = "distributed_lock"
    queryLimit = 100
    maxWait = 5000
  }

  ## redis store property
  redis {
    ## redis mode: single、sentinel
    mode = "single"
    ## single mode property
    single {
      host = "redis"
      port = "6379"
      password = ""
      database = "0"
    }
    ## sentinel mode property
    sentinel {
      masterName = ""
      ## such as "10.28.235.65:26379,10.28.235.65:26380,10.28.235.65:26381"
      sentinelHosts = ""
      sentinelPassword = ""
      database = "0"
    }
  }
}
EOF
    
    # 创建registry.conf
    cat > "$INSTALL_DIR/conf/registry.conf" << 'EOF'
registry {
  # file 、nacos 、eureka 、redis 、zk 、consul、etcd3、sofa
  type = "nacos"

  nacos {
    application = "seata-server"
    serverAddr = "localhost"
    namespace = ""
    group = "SEATA_GROUP"
    username = ""
    password = ""
  }
}

config {
  # file、nacos 、apollo、zk、consul、etcd3
  type = "file"

  file {
    name = "file.conf"
  }
}
EOF
    
    print_success "配置文件创建完成"
}

# === 创建启动脚本 ===
create_launch_script() {
    local launch_script="$INSTALL_DIR/start.sh"
    
    cat > "$launch_script" << 'EOF'
#!/bin/bash

# Seata启动脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Seata启动脚本 ==="
echo ""

# 检查Docker Compose配置文件
if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    echo "错误: 找不到docker-compose.yml文件"
    exit 1
fi

# 启动Seata
echo "正在启动Seata..."
cd "$SCRIPT_DIR"

if command -v docker-compose &> /dev/null; then
    docker-compose up -d
else
    docker compose up -d
fi

echo ""
echo "=== 启动完成 ==="
echo "Seata Server: http://localhost:7091"
echo "MySQL: localhost:3306"
echo "Redis: localhost:6379"
echo ""
echo "查看日志: docker logs -f seata-server"
echo "停止服务: cd $SCRIPT_DIR && docker-compose down"
EOF
    
    chmod +x "$launch_script"
    print_success "创建启动脚本: $launch_script"
}

# === 创建停止脚本 ===
create_stop_script() {
    local stop_script="$INSTALL_DIR/stop.sh"
    
    cat > "$stop_script" << 'EOF'
#!/bin/bash

# Seata停止脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Seata停止脚本 ==="
echo ""

cd "$SCRIPT_DIR"

if command -v docker-compose &> /dev/null; then
    docker-compose down
else
    docker compose down
fi

echo ""
echo "=== 停止完成 ==="
EOF
    
    chmod +x "$stop_script"
    print_success "创建停止脚本: $stop_script"
}

create_host_start_script() {
    local start_script="$INSTALL_DIR/start.sh"

    cat > "$start_script" << EOF
#!/bin/bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
SEATA_PORT="${SEATA_PORT:-8091}"

if [ ! -x "\$SCRIPT_DIR/bin/seata-server.sh" ]; then
    echo "错误: 未找到 \$SCRIPT_DIR/bin/seata-server.sh" >&2
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "错误: 未找到 Java，请先安装 JDK" >&2
    exit 1
fi

mkdir -p "\$SCRIPT_DIR/logs"

if pgrep -f "\$SCRIPT_DIR.*seata-server" >/dev/null 2>&1; then
    echo "Seata 已经在运行"
    exit 0
fi

nohup "\$SCRIPT_DIR/bin/seata-server.sh" -p "\$SEATA_PORT" > "\$SCRIPT_DIR/logs/seata-server.out" 2>&1 &
echo "Seata 已启动，端口: \$SEATA_PORT"
echo "日志: \$SCRIPT_DIR/logs/seata-server.out"
EOF

    chmod +x "$start_script"
    print_success "创建主机启动脚本: $start_script"
}

create_host_stop_script() {
    local stop_script="$INSTALL_DIR/stop.sh"

    cat > "$stop_script" << 'EOF'
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pids="$(pgrep -f "$SCRIPT_DIR.*seata-server" || true)"
if [ -z "$pids" ]; then
    echo "Seata 未运行"
    exit 0
fi

echo "停止 Seata 进程: $pids"
kill $pids 2>/dev/null || true
sleep 3

pids="$(pgrep -f "$SCRIPT_DIR.*seata-server" || true)"
if [ -n "$pids" ]; then
    echo "强制停止 Seata 进程: $pids"
    kill -9 $pids 2>/dev/null || true
fi
EOF

    chmod +x "$stop_script"
    print_success "创建主机停止脚本: $stop_script"
}

install_host_seata() {
    print_header "使用主机系统安装模式..."

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将下载到 $DOWNLOAD_DIR 并安装到 $INSTALL_DIR"
        return 0
    fi

    if ! command -v java >/dev/null 2>&1; then
        print_error "未找到 Java，请先安装 JDK"
        return 1
    fi

    # 确保下载目录存在且可写
    if [ -d "$DOWNLOAD_DIR" ]; then
        if [ ! -w "$DOWNLOAD_DIR" ]; then
            print_warning "下载目录无写入权限，尝试修复: $DOWNLOAD_DIR"
            if command -v sudo >/dev/null 2>&1; then
                sudo chown "$(id -u):$(id -g)" "$DOWNLOAD_DIR" 2>/dev/null || {
                    print_error "无法修复下载目录权限: $DOWNLOAD_DIR"
                    print_info "建议: sudo chown -R $(whoami) '$DOWNLOAD_DIR'"
                    return 1
                }
            else
                print_error "下载目录无写入权限且无法提权: $DOWNLOAD_DIR"
                return 1
            fi
        fi
    else
        mkdir -p "$DOWNLOAD_DIR" || {
            print_error "无法创建下载目录: $DOWNLOAD_DIR"
            return 1
        }
    fi

    local urls=(
        "https://github.com/seata/seata/releases/download/v${SEATA_VERSION}/seata-server-${SEATA_VERSION}.tar.gz"
        "https://archive.apache.org/dist/incubator/seata/${SEATA_VERSION}/apache-seata-${SEATA_VERSION}-incubating-bin.tar.gz"
        "https://mirrors.tuna.tsinghua.edu.cn/apache/incubator/seata/${SEATA_VERSION}/apache-seata-${SEATA_VERSION}-incubating-bin.tar.gz"
    )
    local archive_path=""
    local existing_archive

    for existing_archive in "$DOWNLOAD_DIR/seata-server-${SEATA_VERSION}.tar.gz" "$DOWNLOAD_DIR/apache-seata-${SEATA_VERSION}-incubating-bin.tar.gz"; do
        if [ -f "$existing_archive" ] && verify_archive "$existing_archive"; then
            archive_path="$existing_archive"
            break
        fi
    done

    if [ -z "$archive_path" ]; then
        local downloaded=false
        local url
        for url in "${urls[@]}"; do
            archive_path="$DOWNLOAD_DIR/$(basename "$url")"
            if [ -f "$archive_path" ] && ! verify_archive "$archive_path"; then
                print_warning "检测到损坏或未完成的安装包，删除后重新下载: $archive_path"
                rm -f "$archive_path"
            fi
            if download_file "$url" "$archive_path" && verify_archive "$archive_path"; then
                downloaded=true
                break
            fi
            print_warning "下载失败或文件不完整: $url"
            rm -f "$archive_path"
        done

        if [ "$downloaded" != true ]; then
            print_error "Seata 安装包下载失败"
            return 1
        fi
    else
        print_info "检测到已存在安装包并验证通过: $archive_path"
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$temp_dir"

    local server_script
    local extracted_dir
    server_script="$(find "$temp_dir" -type f -name 'seata-server.sh' -print -quit)"
    if [ -z "$server_script" ]; then
        rm -rf "$temp_dir"
        print_error "解压后未找到 seata-server.sh"
        return 1
    fi
    extracted_dir="$(dirname "$(dirname "$server_script")")"

    mkdir -p "$INSTALL_DIR"
    cp -R "$extracted_dir"/. "$INSTALL_DIR"/
    rm -rf "$temp_dir"

    mkdir -p "$INSTALL_DIR/logs"
    find "$INSTALL_DIR/bin" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true

    create_host_start_script
    create_host_stop_script

    print_success "Seata 主机系统安装完成"
}

# === 安装Seata ===
install_seata() {
    print_info "准备安装 Seata"
    print_info "版本: $SEATA_VERSION"
    print_info "安装目录: $INSTALL_DIR"
    print_info "端口: $SEATA_PORT"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将安装Seata到 $INSTALL_DIR"
        return 0
    fi
    
    if docker_install_available; then
        INSTALL_BACKEND="docker"
        create_docker_compose
        create_config_files
        create_launch_script
        create_stop_script
    else
        INSTALL_BACKEND="host"
        install_host_seata
    fi
    
    print_success "Seata安装完成"
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 跳过安装结果验证"
        return 0
    fi
    
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_success "Docker Compose配置文件存在"
    elif [ -x "$INSTALL_DIR/bin/seata-server.sh" ]; then
        print_success "主机系统 Seata 可执行文件存在"
    else
        print_error "Seata 安装文件不存在"
        return 1
    fi
    
    # 显示使用说明
    print_header "使用说明"
    print_info "1. 启动Seata: cd $INSTALL_DIR && ./start.sh"
    print_info "2. Seata Server端口: $SEATA_PORT"
    if [ "$INSTALL_BACKEND" = "docker" ] || [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "3. 控制台: http://localhost:7091"
        print_info "4. MySQL数据库: localhost:3306 (root/root)"
        print_info "5. Redis缓存: localhost:6379"
        print_info "6. 查看日志: docker logs -f seata-server"
    else
        print_info "3. 查看日志: $INSTALL_DIR/logs/seata-server.out"
    fi
    print_info "停止服务: cd $INSTALL_DIR && ./stop.sh"
    
    return 0
}

# === 卸载Seata ===
uninstall_seata() {
    print_header "卸载Seata..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        return 0
    fi
    
    # 停止并删除容器
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "停止并删除Seata容器..."
        cd "$INSTALL_DIR"
        if command -v docker-compose &> /dev/null; then
            docker-compose down -v
        else
            docker compose down -v
        fi
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi
    
    print_success "Seata卸载完成"
}

# === 主函数 ===
main() {
    print_header "Seata一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_seata
        return 0
    fi
    
    # 安装Seata
    install_seata
    
    # 验证安装
    verify_installation
    
    print_header "安装完成!"
    print_success "Seata已成功安装并配置"
    print_info "执行以下命令启动Seata:"
    print_info "  cd $INSTALL_DIR && ./start.sh"
}

# === 执行主函数 ===
main "$@"

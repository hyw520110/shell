#!/bin/bash
# nacos安装、启动脚本，默认单机模式，可交互式选择集群模式，集群ip交互式输入.
# 支持 Docker Compose 和主机系统两种安装模式

# --- 全局变量和环境检查 ---

# 获取操作系统类型
OS_TYPE=$(uname -s)

# 非登录 bash 在 macOS 上经常拿不到 Homebrew / 用户 bin 路径。
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH"

# 默认端口，集群模式下的节点服务端口
port=8848
DEFAULT_INSTALL_DIR="$HOME/nacos"
INSTALL_DIR_INPUT="$DEFAULT_INSTALL_DIR"
SOURCE_DIR=""
UNINSTALL_MODE=false
INSTALL_SERVICE_ONLY=false
UNINSTALL_SERVICE_ONLY=false

# Docker 相关
INSTALL_MODE="auto"       # auto, docker, host
NACOS_VERSION="${NACOS_VERSION:-2.4.3}"
NACOS_IMAGE="${NACOS_IMAGE:-nacos/nacos-server}"
DOCKER_COMPOSE_FILE="docker-compose.yml"
CLUSTER_MODE=false

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "nacos" ]; then
        echo "$input"
    else
        echo "$input/nacos"
    fi
}

# MySQL 连接参数（支持环境变量和命令行参数）
MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_PORT:-}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
AUTO_START="${AUTO_START:-false}"

has_tty() {
    [[ -t 0 ]]
}

# === Docker 检测 ===
check_docker_available() {
    if ! command -v docker &> /dev/null; then
        return 1
    fi
    if ! docker info &> /dev/null; then
        return 1
    fi
    return 0
}

check_docker_compose_available() {
    if command -v docker-compose &> /dev/null; then
        return 0
    elif docker compose version &> /dev/null; then
        return 0
    fi
    return 1
}

docker_install_available() {
    check_docker_available && check_docker_compose_available
}

# === 确定安装模式 ===
determine_install_mode() {
    if [ "$INSTALL_MODE" != "auto" ]; then
        return 0
    fi

    if docker_install_available; then
        INSTALL_MODE="docker"
        echo "[INFO] 检测到 Docker + Docker Compose，使用 Docker 模式安装"
    else
        INSTALL_MODE="host"
        echo "[INFO] Docker 不可用，使用主机系统安装模式"
    fi
}

parse_args() {
    local opt
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--install-dir|--install-parent|--base-dir)
                opt="$1"
                shift
                if [ $# -eq 0 ]; then
                    echo "错误：$opt 需要指定目录" >&2
                    exit 1
                fi
                INSTALL_DIR_INPUT="$1"
                ;;
            --install-dir=*|--install-parent=*|--base-dir=*)
                INSTALL_DIR_INPUT="${1#*=}"
                ;;
            --source-dir)
                opt="$1"
                shift
                if [ $# -eq 0 ]; then
                    echo "错误：$opt 需要指定目录" >&2
                    exit 1
                fi
                SOURCE_DIR="$1"
                ;;
            --source-dir=*)
                SOURCE_DIR="${1#*=}"
                ;;
            -m|--mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --mode=*)
                INSTALL_MODE="${1#*=}"
                shift
                ;;
            --cluster)
                CLUSTER_MODE=true
                shift
                ;;
            --mysql-host)
                MYSQL_HOST="$2"
                shift 2
                ;;
            --mysql-host=*)
                MYSQL_HOST="${1#*=}"
                shift
                ;;
            --mysql-port)
                MYSQL_PORT="$2"
                shift 2
                ;;
            --mysql-port=*)
                MYSQL_PORT="${1#*=}"
                shift
                ;;
            --mysql-user)
                MYSQL_USER="$2"
                shift 2
                ;;
            --mysql-user=*)
                MYSQL_USER="${1#*=}"
                shift
                ;;
            --mysql-password)
                MYSQL_PASSWORD="$2"
                shift 2
                ;;
            --mysql-password=*)
                MYSQL_PASSWORD="${1#*=}"
                shift
                ;;
            --auto-start)
                AUTO_START=true
                shift
                ;;
            --install-service)
                INSTALL_SERVICE_ONLY=true
                shift
                ;;
            --uninstall-service)
                UNINSTALL_SERVICE_ONLY=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                ;;
            -h|--help)
                cat << 'EOF'
用法: $0 [选项]

选项:
    -d, --dir DIR           安装目录或父目录 (默认: ~/nacos)
    --source-dir DIR        源码目录（从源码构建）
    -m, --mode MODE         安装模式: auto|docker|host (默认: auto)
    --cluster               集群模式
    --mysql-host HOST       MySQL 主机
    --mysql-port PORT       MySQL 端口
    --mysql-user USER       MySQL 用户名
    --mysql-password PASS   MySQL 密码
    --auto-start            安装后自动启动（非交互模式）
    --install-service       只安装/刷新自启动服务，不重新安装
    --uninstall-service     只卸载自启动服务，不删除安装目录
    --uninstall             卸载 Nacos
    -h, --help              显示此帮助

示例:
    $0                              # 自动检测模式安装
    $0 -m docker                    # 强制 Docker 模式
    $0 -m host --auto-start         # 主机模式，安装后自动启动
    $0 --mysql-host 127.0.0.1 --mysql-port 3306 --mysql-user root --mysql-password secret
EOF
                exit 0
                ;;
            *)
                if [ -z "$INSTALL_DIR_INPUT" ] || [ "$INSTALL_DIR_INPUT" = "$DEFAULT_INSTALL_DIR" ]; then
                    INSTALL_DIR_INPUT="$1"
                elif [ -z "$SOURCE_DIR" ]; then
                    SOURCE_DIR="$1"
                else
                    echo "未知参数: $1" >&2
                    exit 1
                fi
                ;;
        esac
        shift
    done
}

parse_args "$@"
INSTALL_DIR="$(normalize_install_dir "$INSTALL_DIR_INPUT")"

# 确定安装模式（auto 时自动检测 Docker）
determine_install_mode

# 获取当前脚本所在目录和项目根目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=$(cd "$(dirname "$0")"/..; pwd)
# 下载url (nacos3 要求17)
url="https://github.com/alibaba/nacos/releases/download/3.0.2/nacos-server-3.0.2.tar.gz"
gz_file_name=${url##*/}
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
tmp_dir="$DOWNLOAD_DIR"
gz_file=$tmp_dir/$gz_file_name

# 集群配置文件
cluster_file=$BASE_DIR/conf/cluster.conf
# 记录是否初始化第一次启动
init_file=~/.nacos_init
# 自启动服务
s_file=/usr/lib/systemd/system/nacos.service
launchagent_label=org.nacos.server
launchagent_file="$HOME/Library/LaunchAgents/$launchagent_label.plist"

# 获取本机主 IP 地址（跨平台）
get_main_ip() {
    if [ "$OS_TYPE" = "Linux" ]; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
    elif [ "$OS_TYPE" = "Darwin" ]; then
        local interface
        interface=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
        if [ -n "$interface" ]; then
            ifconfig "$interface" 2>/dev/null | awk '$1 == "inet" {print $2}'
        else
            ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1
        fi
    else
        ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1
    fi
}

# 获取本机IP
ip=$(get_main_ip)

check_java_version() {
	version=${1:-17}
    # 检查Java是否安装
    if ! command -v java &> /dev/null; then
        echo "错误：Java未安装，请先安装Java $version。"
        return 1
    fi
    # 获取Java版本信息（处理不同平台的输出）
    java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    # 提取主版本号
    if [[ $java_version == 1.* ]]; then
        # 处理旧版Java格式 (1.x.x)
        major_version=$(echo "$java_version" | awk -F '.' '{print $2}')
    else
        # 处理新版Java格式 (x.x.x)
        major_version=$(echo "$java_version" | awk -F '.' '{print $1}')
    fi

    # 检查主版本是否满足最低版本要求
    if [ "$major_version" -ge "$version" ]; then
        echo "Java版本符合要求：$version+"
        return 0
    else
        echo "需要Java $version+，但当前版本是 $major_version"
        return 1
    fi
}
# 兼容不同系统的sed -i命令
sed_inplace() {
    if [ "$OS_TYPE" = "Darwin" ]; then
        LC_ALL=C sed -i '' "$@"
    else
        LC_ALL=C sed -i "$@"
    fi
}

# 查看实时日志
tailfLog() {
    local log_file="$BASE_DIR/logs/startup.log"
    [ ! -f $log_file ] && sleep 5
    local tail_opts="$1" 
    if [ -f "$log_file" ]; then
        tail -n 100 "$tail_opts" "$log_file"
    else
        echo "日志文件 $log_file 未找到。"
    fi
}

# 判断文本在文件中不存在时，写入文本到文件
wfile() {
    if [ -f "$2" ] && ! grep -qF "$1" "$2"; then
        echo "$1" >> "$2"
    fi
}

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_file() {
    local download_url="$1"
    local output_file="$2"
    local output_dir
    local filename
    output_dir=$(dirname "$output_file")
    filename=$(basename "$output_file")

    mkdir -p "$output_dir"

    local adl_path
    if adl_path=$(find_adl); then
        echo "检测到可用 adl，优先使用 adl 下载"
        if "$adl_path" "$download_url" "$output_dir" "$filename"; then
            return 0
        fi
        echo "adl 下载失败，尝试使用 curl/wget 回退下载..."
    else
        echo "未检测到可用 adl"
        echo "尝试使用 curl/wget 下载..."
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$output_file" "$download_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -c "$download_url" -O "$output_file"
    else
        echo "错误：未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

verify_tar_gz() {
    local file="$1"
    [ -f "$file" ] && tar -tzf "$file" >/dev/null 2>&1
}

ensure_nacos_package() {
    mkdir -p "$DOWNLOAD_DIR"

    if verify_tar_gz "$gz_file"; then
        return 0
    fi

    if [ -f "$gz_file" ]; then
        echo "检测到安装包损坏或不完整，尝试断点续传: $gz_file"
    fi

    if ! download_file "$url" "$gz_file"; then
        echo "错误：Nacos安装包下载失败。"
        exit 1
    fi

    if ! verify_tar_gz "$gz_file"; then
        echo "错误：Nacos安装包不是有效的 tar.gz 文件: $gz_file"
        exit 1
    fi
}

get_archive_root_dir() {
    ensure_nacos_package
    tar -tzf "$gz_file" | head -1 | cut -f1 -d"/"
}

nacos_pid_for_dir() {
    local nacos_home="$1"
    pgrep -f "nacos-server.jar.*-Dnacos.home=${nacos_home}" 2>/dev/null || true
}

nacos_health_url() {
    local nacos_port="${1:-8848}"
    printf 'http://127.0.0.1:%s/nacos/actuator/health\n' "$nacos_port"
}

nacos_health_ready() {
    local nacos_port="${1:-8848}"
    curl -fsS "$(nacos_health_url "$nacos_port")" 2>/dev/null | grep -q '"status":"UP"' && return 0
    curl -fsS "http://127.0.0.1:${nacos_port}/nacos/v1/console/health/readiness" >/dev/null 2>&1
}

# === Docker Compose 配置生成 ===

docker_compose_cmd() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

create_docker_standalone_compose() {
    local install_dir="$1"
    local nacos_port="${2:-8848}"

    mkdir -p "$install_dir"/{conf,data,logs}

    cat > "$install_dir/$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  nacos:
    image: ${NACOS_IMAGE}:${NACOS_VERSION}
    container_name: nacos-standalone
    restart: always
    ports:
      - "${nacos_port}:8848"
      - "8080:8080"
      - "9848:9848"
      - "9849:9849"
    environment:
      - MODE=standalone
      - SPRING_DATASOURCE_PLATFORM=mysql
      - MYSQL_SERVICE_HOST=mysql
      - MYSQL_SERVICE_PORT=3306
      - MYSQL_SERVICE_DB_NAME=nacos_config
      - MYSQL_SERVICE_USER=root
      - MYSQL_SERVICE_PASSWORD=root
      - MYSQL_SERVICE_DB_PARAM=characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true
      - NACOS_AUTH_ENABLE=true
      - NACOS_AUTH_TOKEN=SecretKey012345678901234567890123456789012345678901234567890123456789
      - NACOS_AUTH_IDENTITY_KEY=nacos
      - NACOS_AUTH_IDENTITY_VALUE=nacos
      - TZ=Asia/Shanghai
    volumes:
      - ./conf:/home/nacos/conf
      - ./data:/home/nacos/data
      - ./logs:/home/nacos/logs
    networks:
      - nacos-network
    depends_on:
      - mysql
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8848/nacos/actuator/health | grep -q '\"status\":\"UP\"' || curl -fsS http://localhost:8848/nacos/v1/console/health/readiness"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  mysql:
    image: mysql:8.0
    container_name: nacos-mysql
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=nacos_config
      - TZ=Asia/Shanghai
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d
    networks:
      - nacos-network
    ports:
      - "3306:3306"

networks:
  nacos-network:
    driver: bridge

volumes:
  mysql-data:
EOF
}

create_docker_launch_script() {
    local install_dir="$1"
    local launch_script="$install_dir/start.sh"
    local compose_cmd
    compose_cmd=$(docker_compose_cmd)

    cat > "$launch_script" << EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
if [ ! -f "\$SCRIPT_DIR/$DOCKER_COMPOSE_FILE" ]; then
    echo "错误: 找不到 $DOCKER_COMPOSE_FILE 文件"
    exit 1
fi
cd "\$SCRIPT_DIR"
$compose_cmd up -d
echo "Nacos 已启动"
echo "Nacos 3.x 控制台: http://${ip}:8080/"
echo "Nacos 2.x 控制台: http://${ip}:8848/nacos"
echo "默认账号: nacos / nacos"
EOF
    chmod +x "$launch_script"
}

create_docker_stop_script() {
    local install_dir="$1"
    local stop_script="$install_dir/stop.sh"
    local compose_cmd
    compose_cmd=$(docker_compose_cmd)

    cat > "$stop_script" << EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$SCRIPT_DIR"
$compose_cmd down
echo "Nacos 已停止"
EOF
    chmod +x "$stop_script"
}

install_docker_nacos() {
    local install_dir="$1"
    local nacos_port="${2:-8848}"

    echo "[INFO] 使用 Docker Compose 安装 Nacos"
    create_docker_standalone_compose "$install_dir" "$nacos_port"
    mkdir -p "$install_dir/mysql-init"
    create_docker_launch_script "$install_dir"
    create_docker_stop_script "$install_dir"
    echo "[SUCCESS] Docker Compose 配置已创建: $install_dir/$DOCKER_COMPOSE_FILE"
}

# 远程拷贝 (集群功能)
remoteInstall() {
    local target_host="$1"
    echo "请确保到 $target_host 的SSH免密登录已配置。"
    rsync -aWPu --exclude "logs" "$BASE_DIR/" "${target_host}:${BASE_DIR%/nacos*}"
    ssh -o StrictHostKeyChecking=no "root@$target_host" > /dev/null 2>&1 << EOF
chmod +x $CURRENT_DIR/*.sh
$CURRENT_DIR/${0##*/} "$1" >/dev/null 2>&1 &
exit
EOF
}

# 下载并解压
download_and_extract() {
    local extra_dir="$1"
    ensure_nacos_package
    extracted_name=$(get_archive_root_dir)
    if [ -d "$extra_dir/$extracted_name" ]; then
        read -p "解压目录 $extra_dir/$extracted_name 已存在。是否覆盖？(y/n)" extra_confirm
        if [ "$extra_confirm" != "y" ]; then
            echo "取消解压。"
            exit
        fi
    fi
    echo "正在解压 $gz_file 到 $extra_dir ..."
    tar -zxf "$gz_file" -C "$extra_dir"
    if [ $? -ne 0 ]; then
        echo "解压失败，请检查压缩包或权限。"
        exit 1
    fi
}

# 从源码构建并安装
build_from_source() {
    local source_dir="$1"
    local target_dir="$2"
    
    echo "从源码目录构建: $source_dir"
    
    # 检查源码目录是否存在
    if [ ! -d "$source_dir" ]; then
        echo "错误：源码目录 $source_dir 不存在"
        exit 1
    fi
    
    # 检查是否包含pom.xml文件
    if [ ! -f "$source_dir/pom.xml" ]; then
        echo "错误：源码目录中未找到 pom.xml 文件"
        exit 1
    fi
    
    # 检查distribution/target目录下是否已经有.tar.gz文件
    local dist_target_dir="$source_dir/distribution/target"
    local tar_gz_file=$(find "$dist_target_dir" -name "*.tar.gz" -type f 2>/dev/null | head -n 1)
    
    if [ -z "$tar_gz_file" ]; then
        echo "未在 $dist_target_dir 目录下找到 .tar.gz 文件，开始编译源码..."
        
        # 进入源码目录并执行mvn命令
        cd "$source_dir"
        mvn -Prelease-nacos clean install -Dmaven.test.skip=true -Drat.skip=true
        
        # 再次查找.tar.gz文件
        tar_gz_file=$(find "$dist_target_dir" -name "*.tar.gz" -type f 2>/dev/null | head -n 1)
        
        if [ -z "$tar_gz_file" ]; then
            echo "错误：编译完成后仍未在 $dist_target_dir 目录下找到 .tar.gz 文件"
            exit 1
        fi
    else
        echo "找到已有的构建文件: $tar_gz_file"
    fi
    
    # 解压.tar.gz文件到安装目录
    echo "正在解压 $tar_gz_file 到 $target_dir ..."
    mkdir -p "$target_dir"
    tar -zxf "$tar_gz_file" -C "$target_dir" --strip-components=1
    
    if [ $? -ne 0 ]; then
        echo "解压失败，请检查压缩包或权限。"
        exit 1
    fi
    
    echo "源码构建并解压完成。"
}

# 安装主函数
install_main() {
    if [ ! -f "$INSTALL_DIR/target/nacos-server.jar" ] || [ ! -d "$INSTALL_DIR/conf" ]; then
        echo "Nacos未安装，开始安装过程..."
        if [ ! -w "$tmp_dir" ]; then
            echo "错误：下载目录 $tmp_dir 没有写权限。" && exit 1
        fi
        
        # 如果提供了源码目录，则从源码构建
        if [ -n "$SOURCE_DIR" ]; then
            build_from_source "$SOURCE_DIR" "$INSTALL_DIR"
        else
            # 原有的下载安装逻辑
            extracted_name=$(get_archive_root_dir)
            # 智能解压逻辑：如果安装目录是nacos结尾则直接解压到安装目录，否则解压到临时目录再拷贝到安装目录
            if [ "$(basename $INSTALL_DIR)" != "$extracted_name" ]; then
                download_and_extract $tmp_dir
                echo "拷贝到安装目录：$INSTALL_DIR"
                mkdir -p "$INSTALL_DIR"
                rsync -aWPu "$tmp_dir/$extracted_name/" "$INSTALL_DIR/"
            else
                echo "解压到安装目录：$INSTALL_DIR"
                download_and_extract $(dirname "$INSTALL_DIR")
            fi
        fi
        
        if [ "$SUDO_USER" != "" ]; then
             # 如果是通过sudo运行，则将所有权设置给sudo的原始用户
             chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $INSTALL_DIR
         else
             # 否则使用当前用户
             chown -R $(id -u):$(id -g) $INSTALL_DIR
         fi
        echo "Nacos安装完成。"
    else
        echo "Nacos已安装，跳过安装过程。"
    fi
}

stop_nacos_for_uninstall() {
    if [ -x "$INSTALL_DIR/bin/shutdown.sh" ]; then
        echo "停止 Nacos: $INSTALL_DIR/bin/shutdown.sh"
        "$INSTALL_DIR/bin/shutdown.sh" >/dev/null 2>&1 || true
        sleep 2
    fi

    local pids
    pids=$(nacos_pid_for_dir "$INSTALL_DIR")
    if [ -n "$pids" ]; then
        echo "终止 Nacos 进程: $pids"
        kill $pids 2>/dev/null || true
        sleep 2
    fi

    pids=$(nacos_pid_for_dir "$INSTALL_DIR")
    if [ -n "$pids" ]; then
        echo "强制终止 Nacos 进程: $pids"
        kill -9 $pids 2>/dev/null || true
    fi
}

remove_nacos_systemd_service() {
    [ "$OS_TYPE" = "Linux" ] || return 0
    [ -f "$s_file" ] || return 0

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nacos >/dev/null 2>&1 || true
        systemctl disable nacos >/dev/null 2>&1 || true
    fi

    if [ -w "$(dirname "$s_file")" ]; then
        rm -f "$s_file"
    else
        sudo rm -f "$s_file"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

install_nacos_autostart_service() {
    local start_script="$INSTALL_DIR/bin/start.sh"
    local log_dir="$INSTALL_DIR/logs"

    if [ ! -x "$start_script" ]; then
        echo "错误：Nacos 启动脚本不存在或不可执行: $start_script" >&2
        return 1
    fi
    mkdir -p "$log_dir"

    if [ "$OS_TYPE" = "Linux" ]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            echo "错误：当前 Linux 系统未检测到 systemctl" >&2
            return 1
        fi
        cat <<EOF | sudo tee "$s_file" >/dev/null
[Unit]
Description=Nacos Server
After=network-online.target mysql.service mysqld.service
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=$INSTALL_DIR
ExecStart=$start_script
ExecStop=$INSTALL_DIR/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable nacos.service
        echo "Linux systemd 服务已安装: $s_file"
        return 0
    fi

    if [ "$OS_TYPE" = "Darwin" ]; then
        local runtime_root="$HOME/Library/LaunchAgents/runtime/$launchagent_label"
        local runtime_bin="$runtime_root/bin"
        local runtime_conf="$runtime_root/conf"
        local runtime_target="$runtime_root/target"
        local runtime_logs="$runtime_root/logs"
        local runtime_jdk="$HOME/Library/LaunchAgents/runtime/shared-jdk"
        local real_install_dir
        local java_home="${JAVA_HOME:-}"
        local java_bin="java"

        real_install_dir="$(cd "$INSTALL_DIR" && pwd -P)"
        if [ -z "$java_home" ] && [ -x "$HOME/jdk/current/bin/java" ]; then
            java_home="$HOME/jdk/current"
        fi
        if [ -n "$java_home" ]; then
            java_bin="$java_home/bin/java"
        fi
        if [ ! -x "$java_bin" ]; then
            java_bin="$(command -v java || true)"
        fi
        [ -n "$java_bin" ] || { echo "错误：未找到 Java 可执行文件" >&2; return 1; }
        if [ -n "$java_home" ] && [ -d "$java_home" ]; then
            mkdir -p "$runtime_jdk"
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete "$java_home/" "$runtime_jdk/"
            else
                rm -rf "$runtime_jdk"
                mkdir -p "$runtime_jdk"
                cp -R "$java_home/." "$runtime_jdk/"
            fi
            java_home="$runtime_jdk"
            java_bin="$runtime_jdk/bin/java"
        fi
        [ -x "$java_bin" ] || { echo "错误：Java 运行缓存不可执行: $java_bin" >&2; return 1; }
        [ -f "$real_install_dir/target/nacos-server.jar" ] || { echo "错误：Nacos jar 不存在: $real_install_dir/target/nacos-server.jar" >&2; return 1; }
        [ -d "$real_install_dir/conf" ] || { echo "错误：Nacos conf 目录不存在: $real_install_dir/conf" >&2; return 1; }

        mkdir -p "$HOME/Library/LaunchAgents" "$runtime_bin" "$runtime_conf" "$runtime_target" "$runtime_logs" "$runtime_root/data"
        cp "$real_install_dir/target/nacos-server.jar" "$runtime_target/nacos-server.jar"
        cp -R "$real_install_dir/conf/." "$runtime_conf/"
        launchctl bootout "gui/$(id -u)/$launchagent_label" >/dev/null 2>&1 || true
        launchctl unload "$launchagent_file" >/dev/null 2>&1 || true
        local old_pids
        old_pids="$(pgrep -f "nacos-server.jar|nacos.nacos" 2>/dev/null || true)"
        if [ -n "$old_pids" ]; then
            echo "停止旧 Nacos 进程: $old_pids"
            kill $old_pids 2>/dev/null || true
            sleep 3
        fi
        cat > "$runtime_bin/nacos-launchd.sh" <<EOF
#!/usr/bin/env bash
set -e
export PATH="${java_home:+$java_home/bin:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
${java_home:+export JAVA_HOME="$java_home"}
mkdir -p "$runtime_root/logs" "$runtime_root/data"
cd "$runtime_root"
exec "$java_bin" \\
  -Djava.net.preferIPv4Stack=true \\
  --add-opens java.base/jdk.internal.platform=ALL-UNNAMED \\
  -Xms512m -Xmx512m -Xmn256m \\
  -Dnacos.standalone=true \\
  -Dnacos.member.list= \\
  -Dnacos.deployment.type=merged \\
  -Dloader.path="$runtime_root/plugins,$runtime_root/plugins/health,$runtime_root/plugins/cmdb,$runtime_root/plugins/selector" \\
  -Dnacos.home="$runtime_root" \\
  -jar "$runtime_target/nacos-server.jar" \\
  --spring.config.additional-location=file:"$runtime_conf/" \\
  --logging.config="$runtime_conf/nacos-logback.xml" \\
  --server.max-http-request-header-size=524288 \\
  nacos.nacos
EOF
        chmod +x "$runtime_bin/nacos-launchd.sh"
        cat > "$launchagent_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$launchagent_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$runtime_bin/nacos-launchd.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$runtime_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$runtime_logs/launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$runtime_root</string>
</dict>
</plist>
EOF
        launchctl bootstrap "gui/$(id -u)" "$launchagent_file" 2>/dev/null || launchctl load -w "$launchagent_file"
        launchctl enable "gui/$(id -u)/$launchagent_label" 2>/dev/null || true
        launchctl kickstart -k "gui/$(id -u)/$launchagent_label" 2>/dev/null || true
        echo "macOS LaunchAgent 已安装: $launchagent_file"
        return 0
    fi

    echo "错误：暂不支持当前系统自启动: $OS_TYPE" >&2
    return 1
}

remove_nacos_launchd_service() {
    [ "$OS_TYPE" = "Darwin" ] || return 0
    launchctl bootout "gui/$(id -u)/$launchagent_label" >/dev/null 2>&1 || true
    launchctl unload "$launchagent_file" >/dev/null 2>&1 || true
    rm -f "$launchagent_file"
    rm -rf "$HOME/Library/LaunchAgents/runtime/$launchagent_label"
    echo "macOS LaunchAgent 已卸载: $launchagent_label"
}

remove_nacos_autostart_service() {
    remove_nacos_systemd_service
    remove_nacos_launchd_service
}

uninstall_nacos() {
    echo "--- 开始卸载 Nacos ---"
    echo "安装目录: $INSTALL_DIR"

    stop_nacos_for_uninstall
    remove_nacos_autostart_service

    if [ -d "$INSTALL_DIR" ]; then
        echo "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        echo "安装目录不存在，跳过: $INSTALL_DIR"
    fi

    if [ -f "$init_file" ]; then
        echo "删除初始化标记: $init_file"
        rm -f "$init_file"
    fi

    echo "Nacos 卸载完成"
}

if [ "$UNINSTALL_MODE" = true ]; then
    uninstall_nacos
    exit 0
fi

if [ "$UNINSTALL_SERVICE_ONLY" = true ]; then
    remove_nacos_autostart_service
    exit 0
fi

if [ "$INSTALL_SERVICE_ONLY" = true ]; then
    install_nacos_autostart_service
    exit $?
fi

# 重构配置更新函数
update_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    local tmp

    if [[ ! -f "$config_file" ]]; then
        echo "错误：配置文件不存在 '$config_file'" && return 1
    fi

    tmp="$(mktemp)"
    if LC_ALL=C awk -F= -v key="$key" '
        {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            split(line, parts, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
            if (parts[1] == key) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$config_file"; then
        echo "正在更新配置文件：$config_file 中的配置项 '$key'..."
        LC_ALL=C awk -F= -v key="$key" -v value="$value" '
            BEGIN { updated = 0 }
            {
                line = $0
                sub(/^[[:space:]]*#[[:space:]]*/, "", line)
                split(line, parts, "=")
                prop = parts[1]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", prop)
                if (prop == key) {
                    if (!updated) {
                        if (value == "") {
                            sub(/^[[:space:]]*#[[:space:]]*/, "", $0)
                            print
                        } else {
                            print key "=" value
                        }
                        updated = 1
                    }
                    next
                }
                print
            }
        ' "$config_file" > "$tmp"
        mv "$tmp" "$config_file"
    else
        echo "配置文件：$config_file 中配置项 '$key' 不存在，正在添加..."
        rm -f "$tmp"
        echo "${key}=${value}" >> "$config_file"
    fi
    return 0
}

get_config_value() {
    local config_file="$1"
    local key="$2"

    [ -f "$config_file" ] || return 1
    LC_ALL=C awk -F= -v key="$key" '
        {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            split(line, parts, "=")
            prop = parts[1]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", prop)
            if (prop == key) {
                sub(/^[^=]*=/, "", line)
                print line
                exit
            }
        }
    ' "$config_file"
}

is_printable_ascii() {
    local value="$1"
    [ -n "$value" ] || return 1
    LC_ALL=C printf '%s' "$value" | LC_ALL=C grep -Eq '^[ -~]+$'
}

random_base64_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 33 | tr -d '\n'
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48
    fi
}

random_ascii_secret() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"
}

ensure_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    local current_value

    current_value="$(get_config_value "$config_file" "$key" || true)"
    if is_printable_ascii "$current_value"; then
        echo "配置文件：$config_file 中配置项 '$key' 已配置，跳过覆盖。"
        return 0
    fi

    if [ -n "$current_value" ]; then
        echo "配置文件：$config_file 中配置项 '$key' 存在异常字符，重新生成。"
    fi
    update_config_value "$config_file" "$key" "$value"
}

is_valid_nacos_token_secret() {
    local value="$1"
    local decoded_len

    is_printable_ascii "$value" || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    [ $(( ${#value} % 4 )) -eq 0 ] || return 1

    decoded_len="$(printf '%s' "$value" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')"
    [ "${decoded_len:-0}" -gt 32 ]
}

ensure_nacos_token_secret() {
    local config_file="$1"
    local key="nacos.core.auth.plugin.nacos.token.secret.key"
    local current_value

    current_value="$(get_config_value "$config_file" "$key" || true)"
    if is_valid_nacos_token_secret "$current_value"; then
        echo "配置文件：$config_file 中配置项 '$key' 已配置，跳过覆盖。"
        return 0
    fi

    if [ -n "$current_value" ]; then
        echo "配置文件：$config_file 中配置项 '$key' 不是有效 Base64 密钥，重新生成。"
    fi
    update_config_value "$config_file" "$key" "$(random_base64_secret)"
}

normalize_nacos_mysql_url() {
    local raw_url="$1"
    local host="$2"
    local port="$3"
    local db_name="nacos"

    if echo "$raw_url" | grep -qE 'jdbc:mysql://[^/?]+/[^?]+'; then
        db_name="$(echo "$raw_url" | sed -E 's|.*jdbc:mysql://[^/]+/([^?]+).*|\1|' | cut -d'&' -f1)"
        [ -n "$db_name" ] || db_name="nacos"
    fi

    echo "jdbc:mysql://${host}:${port}/${db_name}?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useUnicode=true&useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true"
}

get_nacos_db_name_from_url() {
    local db_url="$1"
    local db_name="nacos"

    if echo "$db_url" | grep -qE 'jdbc:mysql://[^/?]+/[^?]+'; then
        db_name="$(echo "$db_url" | sed -E 's|.*jdbc:mysql://[^/]+/([^?]+).*|\1|' | cut -d'?' -f1 | cut -d'&' -f1)"
    fi

    db_name="${db_name:-nacos}"
    printf '%s\n' "$db_name"
}

escape_mysql_identifier() {
    printf '%s' "$1" | sed 's/`/``/g'
}

escape_mysql_string() {
    printf '%s' "$1" | sed "s/'/''/g"
}

ensure_nacos_mysql_database() {
    local mysql_host="$1"
    local mysql_port="$2"
    local mysql_user="$3"
    local mysql_password="$4"
    local db_name="$5"
    local schema_file="$INSTALL_DIR/conf/mysql-schema.sql"
    local fallback_schema_file="$BASE_DIR/conf/nacos-mysql.sql"
    local mysql_args
    local escaped_db
    local escaped_db_string
    local table_exists

    if ! command -v mysql >/dev/null 2>&1; then
        echo "警告：未找到 mysql 命令，无法自动创建 Nacos 数据库和表。"
        echo "请手动创建数据库 '$db_name' 并导入: $schema_file"
        return 1
    fi

    if [ ! -f "$schema_file" ] && [ -f "$INSTALL_DIR/conf/nacos-mysql.sql" ]; then
        schema_file="$INSTALL_DIR/conf/nacos-mysql.sql"
    elif [ ! -f "$schema_file" ] && [ -f "$fallback_schema_file" ]; then
        schema_file="$fallback_schema_file"
    fi

    if [ ! -f "$schema_file" ]; then
        echo "警告：未找到 Nacos MySQL 初始化脚本: $schema_file"
        return 1
    fi

    escaped_db="$(escape_mysql_identifier "$db_name")"
    escaped_db_string="$(escape_mysql_string "$db_name")"
    mysql_args=(--protocol=tcp -h "$mysql_host" -P "$mysql_port" -u "$mysql_user")

    echo "--- 正在初始化 Nacos MySQL 数据库 ---"
    echo "数据库: $db_name"
    local create_err
    if ! create_err="$(MYSQL_PWD="$mysql_password" mysql "${mysql_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$escaped_db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1)"; then
        echo "错误：创建数据库失败，请检查 MySQL 地址、账号密码和权限: $mysql_host:$mysql_port"
        echo "       MySQL 用户: $mysql_user"
        echo "       MySQL 错误: $create_err"
        return 1
    fi

    table_exists="$(MYSQL_PWD="$mysql_password" mysql "${mysql_args[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$escaped_db_string' AND table_name='config_info';" 2>/dev/null || echo 0)"
    if [ "${table_exists:-0}" = "0" ]; then
        echo "导入 Nacos 表结构: $schema_file"
        if ! MYSQL_PWD="$mysql_password" mysql "${mysql_args[@]}" "$db_name" < "$schema_file"; then
            echo "错误：导入 Nacos 表结构失败: $schema_file"
            return 1
        fi
    else
        echo "检测到 Nacos 表结构已存在，跳过导入。"
    fi

    ensure_nacos_mysql_required_tables "$mysql_host" "$mysql_port" "$mysql_user" "$mysql_password" "$db_name" "$schema_file" "$fallback_schema_file"

    echo "Nacos MySQL 数据库初始化完成"
    return 0
}

extract_create_table_sql() {
    local schema_file="$1"
    local table_name="$2"

    awk -v table="$table_name" '
        $0 ~ "CREATE TABLE `" table "`" { printing = 1 }
        printing { print }
        printing && /;[[:space:]]*$/ { exit }
    ' "$schema_file"
}

ensure_nacos_mysql_required_tables() {
    local mysql_host="$1"
    local mysql_port="$2"
    local mysql_user="$3"
    local mysql_password="$4"
    local db_name="$5"
    local schema_file="$6"
    local fallback_schema_file="${7:-}"
    local mysql_args
    local escaped_db_string
    local required_table
    local table_exists
    local ddl_file

    mysql_args=(--protocol=tcp -h "$mysql_host" -P "$mysql_port" -u "$mysql_user")
    escaped_db_string="$(escape_mysql_string "$db_name")"

    local tables_to_check=""
    if [ -f "$schema_file" ]; then
        tables_to_check=$(awk 'toupper($0) ~ /CREATE TABLE/ {gsub(/`/, "", $3); print $3}' "$schema_file")
    elif [ -n "$fallback_schema_file" ] && [ -f "$fallback_schema_file" ]; then
        tables_to_check=$(awk 'toupper($0) ~ /CREATE TABLE/ {gsub(/`/, "", $3); print $3}' "$fallback_schema_file")
    elif [ -f "$INSTALL_DIR/conf/nacos-mysql.sql" ]; then
        tables_to_check=$(awk 'toupper($0) ~ /CREATE TABLE/ {gsub(/`/, "", $3); print $3}' "$INSTALL_DIR/conf/nacos-mysql.sql")
    fi

    for required_table in $tables_to_check; do
        table_exists="$(MYSQL_PWD="$mysql_password" mysql "${mysql_args[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$escaped_db_string' AND table_name='$required_table';" 2>/dev/null || echo 0)"
        if [ "${table_exists:-0}" != "0" ]; then
            continue
        fi

        ddl_file="$(mktemp)"
        extract_create_table_sql "$schema_file" "$required_table" > "$ddl_file"
        if [ ! -s "$ddl_file" ] && [ -n "$fallback_schema_file" ] && [ -f "$fallback_schema_file" ]; then
            extract_create_table_sql "$fallback_schema_file" "$required_table" > "$ddl_file"
        fi
        if [ ! -s "$ddl_file" ] && [ -f "$INSTALL_DIR/conf/nacos-mysql.sql" ]; then
            extract_create_table_sql "$INSTALL_DIR/conf/nacos-mysql.sql" "$required_table" > "$ddl_file"
        fi
        if [ ! -s "$ddl_file" ]; then
            rm -f "$ddl_file"
            echo "错误：当前 SQL 初始化脚本缺少 Nacos 3.x 必需表: $required_table"
            echo "请确认安装目录或脚本目录包含 Nacos MySQL 初始化脚本。"
            return 1
        fi

        echo "补创建 Nacos 必需表: $required_table"
        if ! MYSQL_PWD="$mysql_password" mysql "${mysql_args[@]}" "$db_name" < "$ddl_file"; then
            rm -f "$ddl_file"
            echo "错误：创建 Nacos 必需表失败: $required_table"
            return 1
        fi
        rm -f "$ddl_file"
    done

    return 0
}

# 检查MySQL连接是否可达
check_mysql_connection() {
    local mysql_host="$1"
    local mysql_port="$2"
    
    echo "正在检查MySQL连接: $mysql_host:$mysql_port..."
    
    # 使用nc命令检查端口连通性
    if command -v nc >/dev/null 2>&1; then
        if nc -z "$mysql_host" "$mysql_port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    # 使用telnet命令检查端口连通性
    elif command -v telnet >/dev/null 2>&1; then
        if timeout 5 telnet "$mysql_host" "$mysql_port" 2>&1 | grep -q "Connected"; then
            return 0
        else
            return 1
        fi
    else
        # 如果没有nc或telnet，则尝试ping主机
        if ping -c 1 "$mysql_host" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
}

# Docker 模式：跳过主机安装逻辑，直接生成 Docker Compose 配置
if [ "$INSTALL_MODE" = "docker" ]; then
    install_parent=$(dirname "$INSTALL_DIR")
    mkdir -p "$install_parent" 2>/dev/null || true
    if [ ! -w "$install_parent" ]; then
        echo "错误：安装目录父目录不可写: $install_parent" && exit 1
    fi
    # Docker 模式直接跳转到启动逻辑（在脚本末尾）
    # 但先确保 INSTALL_DIR 存在
    mkdir -p "$INSTALL_DIR"
else
    # 主机模式：原有逻辑
    # 用户目录安装不要求 root；仅当目标父目录不可写时要求提权
    install_parent=$(dirname "$INSTALL_DIR")
    mkdir -p "$install_parent" 2>/dev/null || true
    if [ ! -w "$install_parent" ]; then
        echo "错误：安装目录父目录不可写，请使用 sudo 或指定用户可写目录: $install_parent" && exit 1
    fi

    # 检查端口占用
    if lsof -i :"$port" -sTCP:LISTEN -t >/dev/null ; then
        echo "错误：端口 $port 已被占用。" && exit 1
    fi

    # 检查进程是否已运行
    if ps -ef | grep "nacos.jar" | grep -v "grep" > /dev/null; then
        echo "Nacos 已在运行。" && exit 0
    fi

    # 执行安装
    install_main

    # 检查 INSTALL_DIR 和 BASE_DIR 不相等则只同步辅助脚本
    if [ "$INSTALL_DIR" != "$BASE_DIR" ]; then
        rsync -a \
            --exclude 'conf/' \
            --exclude 'target/' \
            --exclude 'plugins/' \
            --exclude 'logs/' \
            --exclude 'data/' \
            "$BASE_DIR/" "$INSTALL_DIR/"
        BASE_DIR="$INSTALL_DIR"
    fi
    conf_file="$INSTALL_DIR/conf/application.properties"
    if [ ! -f "$conf_file" ]; then
        echo "错误：找不到配置文件 $conf_file " && exit 1
    fi

    # 配置数据库
    echo "--- 开始配置数据库 ---"
    update_config_value "$conf_file" "spring.sql.init.platform" "mysql"
    update_config_value "$conf_file" "spring.datasource.platform" "mysql"
    update_config_value "$conf_file" "db.num" "1"
fi


# 主机模式：配置数据库和安全密钥
if [ "$INSTALL_MODE" != "docker" ]; then
    # 提取配置文件中的MySQL连接信息
    # 首先尝试获取未注释的配置
    DB_URL=$(grep "^db.url.0=" "$conf_file" | head -n 1 | cut -d'=' -f2-)
    if [ -z "$DB_URL" ]; then
        # 尝试获取被注释掉的配置（兼容前面可能有0个或多个空格的情况）
        DB_URL=$(grep "^#[[:space:]]*db.url.0=" "$conf_file" | head -n 1 | cut -d'=' -f2-)
    fi
    # 从URL中提取主机和端口，仅提取//和第一个?之间的内容
    MYSQL_HOST="127.0.0.1"
    MYSQL_PORT="3306"
    HOST_AND_PORT=""

    if [ -n "$DB_URL" ]; then
        # 提取//和第一个?之间的内容，然后从中提取主机和端口
        HOST_AND_PORT=$(echo "$DB_URL" | sed -E 's/.*jdbc:mysql:\/\/([^\/?]+).*/\1/')
        if [ -n "$HOST_AND_PORT" ]; then
            # 进一步提取主机:端口部分（处理可能的路径）
            HOST_PORT_PART=$(echo "$HOST_AND_PORT" | cut -d'/' -f1)
            if echo "$HOST_PORT_PART" | grep -q ':'; then
                MYSQL_HOST=$(echo "$HOST_PORT_PART" | cut -d':' -f1)
                MYSQL_PORT=$(echo "$HOST_PORT_PART" | cut -d':' -f2)
            else
                MYSQL_HOST="$HOST_PORT_PART"
                MYSQL_PORT="3306"
            fi
        fi
    fi
    # echo "$MYSQL_HOST:$MYSQL_PORT"
    # 非交互模式下要求通过参数或环境变量传入 MySQL 信息
    if ! has_tty; then
        if [ -z "$MYSQL_HOST" ] || [ -z "$MYSQL_PORT" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
            echo "错误：非交互模式下必须通过参数或环境变量指定 MySQL 连接信息"
            echo "用法示例:"
            echo "  $0 --mysql-host 127.0.0.1 --mysql-port 3306 --mysql-user root --mysql-password secret"
            echo "或设置环境变量:"
            echo "  MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=root MYSQL_PASSWORD=secret $0"
            exit 1
        fi
    fi

    # 如果配置文件中的连接信息不可达，则提示用户输入
    if [ -n "$MYSQL_HOST" ] && [ -n "$MYSQL_PORT" ]; then
        # 使用命令行/环境变量传入的值
        NEW_DB_URL=$(normalize_nacos_mysql_url "$DB_URL" "$MYSQL_HOST" "$MYSQL_PORT")
        update_config_value "$conf_file" "db.url.0" "$NEW_DB_URL"
    else
        if [ -n "$DB_URL" ]; then
            if ! check_mysql_connection "$MYSQL_HOST" "$MYSQL_PORT"; then
                echo "配置文件中的MySQL连接 ($MYSQL_HOST:$MYSQL_PORT) 不可达"
                if has_tty; then
                    input_host=""
                    input_port=""
                    read -p "请输入 MySQL 服务器主机名/IP (默认为: $MYSQL_HOST): " input_host
                    MYSQL_HOST="${input_host:-$MYSQL_HOST}"
                    read -p "请输入 MySQL 服务器端口 (默认为: $MYSQL_PORT): " input_port
                    MYSQL_PORT="${input_port:-$MYSQL_PORT}"
                else
                    echo "错误：无法在非交互模式下获取 MySQL 连接信息"
                    exit 1
                fi
            else
                echo "配置文件中的MySQL连接 ($MYSQL_HOST:$MYSQL_PORT) 可达"
            fi
        else
            echo "未在配置文件中找到有效的MySQL连接信息"
            if has_tty; then
                input_host=""
                input_port=""
                read -p "请输入 MySQL 服务器主机名/IP (默认为: 127.0.0.1): " input_host
                MYSQL_HOST="${input_host:-127.0.0.1}"
                read -p "请输入 MySQL 服务器端口 (默认为: 3306): " input_port
                MYSQL_PORT="${input_port:-3306}"
            else
                MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
                MYSQL_PORT="${MYSQL_PORT:-3306}"
            fi
        fi
        NEW_DB_URL=$(normalize_nacos_mysql_url "$DB_URL" "$MYSQL_HOST" "$MYSQL_PORT")
        update_config_value "$conf_file" "db.url.0" "$NEW_DB_URL"
    fi


    # 提取配置文件中的MySQL用户名
    DB_USER=$(grep "^db.user.0=" "$conf_file" | sed 's/^db.user.0=//' | head -n 1)
    if [ -z "$DB_USER" ]; then
        # 尝试获取被注释掉的配置
        DB_USER=$(grep "^#[[:space:]]*db.user.0=" "$conf_file" | sed 's/^#[[:space:]]*db.user.0=//' | head -n 1)
    fi

    if [ -n "$MYSQL_USER" ]; then
        # 使用命令行/环境变量传入的值
        :
    elif [ -z "$DB_USER" ]; then
        if has_tty; then
            read -p "请输入 MySQL 用户名 (默认: root): " MYSQL_USER
            MYSQL_USER=${MYSQL_USER:-root}
        else
            MYSQL_USER="root"
        fi
    else
        if has_tty; then
            read -p "请输入 MySQL 用户名 (默认: $DB_USER): " MYSQL_USER
            MYSQL_USER=${MYSQL_USER:-$DB_USER}
        else
            MYSQL_USER="$DB_USER"
        fi
    fi

    # 更新用户名配置
    update_config_value "$conf_file" "db.user.0" "$MYSQL_USER"

    # 处理MySQL密码
    if [ -z "$MYSQL_PASSWORD" ]; then
        DB_PASSWORD=$(grep "^db.password.0=" "$conf_file" | sed 's/^db.password.0=//' | head -n 1)
        if [ -z "$DB_PASSWORD" ]; then
            # 尝试获取被注释掉的配置
            DB_PASSWORD=$(grep "^#[[:space:]]*db.password.0=" "$conf_file" | sed 's/^#[[:space:]]*db.password.0=//' | head -n 1)
        fi

        if [ -n "$DB_PASSWORD" ]; then
            MYSQL_PASSWORD="$DB_PASSWORD"
        elif has_tty; then
            # 提示用户输入密码
            while true; do
                read -s -p "请输入 MySQL 密码: " MYSQL_PASSWORD
                echo
                if [ -n "$MYSQL_PASSWORD" ]; then
                    break
                fi
                echo "错误：MySQL密码不能为空，请重新输入。"
            done
        else
            echo "错误：非交互模式下必须通过 --mysql-password 参数或 MYSQL_PASSWORD 环境变量传入密码"
            exit 1
        fi
    fi

    # 更新密码配置
    update_config_value "$conf_file" "db.password.0" "$MYSQL_PASSWORD"

    echo "数据源已更新:"
    grep -E '^(db\.num|db\.url\.0|db\.user\.0|db\.password\.0)=' "$conf_file"

    NACOS_DB_NAME="$(get_nacos_db_name_from_url "$NEW_DB_URL")"
    if ! ensure_nacos_mysql_database "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD" "$NACOS_DB_NAME"; then
        echo "错误：Nacos MySQL 数据库初始化失败，停止启动。"
        exit 1
    fi

    touch "$init_file"

    # 安全配置
    echo "--- 正在配置安全密钥 ---"
    ensure_nacos_token_secret "$conf_file"
    ensure_config_value "$conf_file" "nacos.core.auth.server.identity.key" "$(random_ascii_secret 32)"
    ensure_config_value "$conf_file" "nacos.core.auth.server.identity.value" "$(random_ascii_secret 32)"
    # java17的话需要在启动脚本中添加JVM参数不然会启动报错
    if check_java_version 17; then
      # 添加解决Java 17容器兼容性问题的JVM参数
        OPT="${JAVA_OPT} --add-opens java.base/jdk.internal.platform=ALL-UNNAMED -XX:-UseContainerSupport"
        # 判断启动脚本中是否有JVM参数UseContainerSupport，如果没有则使用sed添加
        if ! grep -q "UseContainerSupport" "$BASE_DIR/bin/startup.sh"; then
            echo "当前是java17需在启动脚本中添加JVM参数:$OPT"
            # 因为启动脚本中有多行JAVA_OPT,所以需要使用sed添加，添加到# JVM Configuration的后2行
            #sed_inplace '/^[[:space:]]*#\{1,\}[[:space:]]*JVM Configuration/,+1 {/^[[:space:]]*#\{1,\}[[:space:]]*JVM Configuration/ {n;n} s/^/JAVA_OPT=\"\$JAVA_OPT -XX:\+UseContainerSupport\"\n/}' "$BASE_DIR/bin/startup.sh"
        fi
    fi
fi
# === 启动 Nacos（非阻塞） ===

wait_for_nacos_health() {
    local max_wait="${1:-60}"
    local waited=0
    local health_url
    health_url="$(nacos_health_url "$port")"

    echo "[INFO] 等待 Nacos 启动就绪（最多 ${max_wait} 秒）..."
    echo "[INFO] 健康检查: $health_url"
    while [ "$waited" -lt "$max_wait" ]; do
        if nacos_health_ready "$port"; then
            echo "[SUCCESS] Nacos 启动成功"
            return 0
        fi
        # 也检查进程是否还在
        if ! nacos_pid_for_dir "$BASE_DIR" >/dev/null 2>&1; then
            echo "[ERROR] Nacos 进程已退出"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""
    echo "[WARNING] Nacos 启动超时，请手动检查日志: $BASE_DIR/logs/startup.log"
    return 1
}

start_nacos_host() {
    local mode="${1:-standalone}"

    echo "[INFO] 启动 Nacos（$mode 模式）..."

    # 确保权限正确
    if [ -n "$SUDO_USER" ]; then
        chown -R "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$BASE_DIR/"
    fi

    # 后台启动（关键：使用 nohup 避免被 SIGHUP 终止）
    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" nohup "$BASE_DIR/bin/startup.sh" -m "$mode" >/dev/null 2>&1 &
    else
        nohup "$BASE_DIR/bin/startup.sh" -m "$mode" >/dev/null 2>&1 &
    fi

    # 等待健康检查
    if wait_for_nacos_health 60; then
        echo "[INFO] Nacos 3.x 控制台: http://${ip}:8080/"
        echo "[INFO] Nacos 2.x/1.x 控制台: http://${ip}:${port}/nacos"
        echo "[INFO] 默认账号: nacos / nacos"
        return 0
    else
        return 1
    fi
}

start_nacos_docker() {
    local install_dir="$1"
    local compose_cmd
    compose_cmd=$(docker_compose_cmd)

    echo "[INFO] 启动 Nacos Docker 容器..."
    cd "$install_dir"
    $compose_cmd up -d

    echo "[INFO] 等待容器启动..."
    sleep 5

    local max_wait=60
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker ps --format '{{.Names}}' | grep -q "nacos-standalone"; then
            if docker logs nacos-standalone 2>&1 | grep -q "Nacos started successfully"; then
                echo "[SUCCESS] Nacos Docker 容器启动成功"
                echo "[INFO] Nacos 3.x 控制台: http://${ip}:8080/"
                echo "[INFO] Nacos 2.x/1.x 控制台: http://${ip}:${port}/nacos"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""
    echo "[WARNING] Docker 容器启动超时，请检查: docker logs nacos-standalone"
    return 1
}

# === 模式选择与启动 ===

# Docker 模式：安装配置后启动容器
if [ "$INSTALL_MODE" = "docker" ]; then
    install_docker_nacos "$INSTALL_DIR" "$port"

    if [ "$AUTO_START" = "true" ]; then
        start_nacos_docker "$INSTALL_DIR"
    elif has_tty; then
        read -n 1 -p "是否启动 Nacos Docker 容器? (Y/n): " choice
        echo
        choice=${choice:-Y}
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            start_nacos_docker "$INSTALL_DIR"
        fi
    else
        echo "[INFO] Docker 配置已创建，手动启动: cd $INSTALL_DIR && ./start.sh"
    fi

    echo "[SUCCESS] Nacos Docker 安装完成"
    exit 0
fi

# 主机模式
if [ "$AUTO_START" = "true" ]; then
    if [ "$CLUSTER_MODE" = "true" ]; then
        start_nacos_host cluster
    else
        start_nacos_host standalone
    fi
    exit 0
fi

if has_tty; then
    read -n 1 -p "是否以单机模式启动? (Y/n): " choice
    echo
    choice=${choice:-Y}

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        start_nacos_host standalone
        exit 0
    fi

    echo "集群模式启动..."
    # 集群配置逻辑
    wfile "${ip}:${port}" "$cluster_file"

    while : ; do
        read -p "请输入其他集群节点的IP地址 (多个IP用空格隔开, 输入q退出): " cluster_ips
        if [[ "$cluster_ips" == "q" ]]; then break; fi
        if [ -n "$cluster_ips" ]; then
            for node_ip in $cluster_ips; do
                wfile "${node_ip}:${port}" "$cluster_file"
                echo "--- 正在向 $node_ip 同步并启动 ---"
                remoteInstall "$node_ip" && wait $!
            done
            break
        fi
    done

    echo "启动当前节点..."
    start_nacos_host cluster
else
    echo "[INFO] 非交互模式，跳过启动。如需自动启动请添加 --auto-start 参数"
fi

exit 0

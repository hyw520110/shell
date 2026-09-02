#!/bin/bash
# MongoDB 安装脚本
# 支持 Docker 模式和主机模式，支持 macOS 和 Linux

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }

# === 常量 ===
MONGODB_VERSION="7.0.0"
DEFAULT_INSTALL_DIR="$HOME/mongodb"
DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
DEFAULT_PORT=27017

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"
PORT="$DEFAULT_PORT"
INSTALL_MODE="auto"   # auto|docker|host
UNINSTALL_MODE=false
DRY_RUN=false

# === 帮助 ===
show_usage() {
    cat <<EOF
MongoDB 安装脚本

用法: $0 [选项]

选项:
    -h, --help                  显示此帮助
    -d, --dir DIR               安装目录 (默认: ~/mongodb)
    -w, --download-dir DIR      下载目录 (默认: ~/Downloads)
    -p, --port PORT             端口号 (默认: 27017)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    --dry-run                   试运行
    --uninstall                 卸载 MongoDB

示例:
    $0                          # 自动模式安装
    $0 --mode host              # 强制主机模式
    $0 --mode docker            # 强制 Docker 模式
    $0 --uninstall              # 卸载
EOF
}

# === 参数解析 ===
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_usage; exit 0 ;;
            -d|--dir)
                INSTALL_DIR="${2/#\~/$HOME}"
                shift 2 ;;
            -w|--download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2 ;;
            -p|--port)
                PORT="$2"
                shift 2 ;;
            -m|--mode)
                INSTALL_MODE="$2"
                shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --uninstall) UNINSTALL_MODE=true; shift ;;
            *) log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done
}

# === 检测系统 ===
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*) echo "linux" ;;
        *) echo "unknown" ;;
    esac
}

OS_TYPE=$(detect_os)

# === Docker 检测 ===
docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

# === 下载函数 ===
download_file() {
    local url="$1" output="$2"
    local output_dir="$(dirname "$output")"
    local output_file="$(basename "$output")"

    if [ -d "$output_dir" ] && [ ! -w "$output_dir" ]; then
        log_warn "下载目录无写入权限，尝试修复"
        if command -v sudo &>/dev/null; then
            sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
        fi
    fi
    mkdir -p "$output_dir"

    if [ -f "$output" ] && [ ! -w "$output" ]; then
        if command -v sudo &>/dev/null; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl &>/dev/null; then
        log_info "使用 adl 下载"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi
    if command -v curl &>/dev/null; then
        log_info "使用 curl 下载"
        curl -L -C - -o "$output" "$url"
        return $?
    fi
    if command -v wget &>/dev/null; then
        log_info "使用 wget 下载"
        wget -c -O "$output" "$url"
        return $?
    fi
    log_error "未找到可用下载工具"
    return 1
}

verify_archive() {
    local file="$1"
    [ -f "$file" ] && [ -s "$file" ] && tar -tzf "$file" &>/dev/null
}

# === Docker 模式安装 ===
install_docker() {
    log_info "使用 Docker 模式安装 MongoDB"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将创建 Docker Compose 配置到 $INSTALL_DIR"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  mongodb:
    image: mongo:${MONGODB_VERSION}
    container_name: mongodb
    restart: unless-stopped
    ports:
      - "${PORT}:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD: root
    volumes:
      - mongodb-data:/data/db
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - mongodb-network

volumes:
  mongodb-data:

networks:
  mongodb-network:
    driver: bridge
EOF

    cat > "$INSTALL_DIR/start.sh" <<'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if docker compose version &>/dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi
echo "MongoDB 已启动"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    cat > "$INSTALL_DIR/stop.sh" <<'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
if docker compose version &>/dev/null; then
    docker compose down
else
    docker-compose down
fi
echo "MongoDB 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    log_ok "MongoDB Docker 配置创建完成"
    log_info "启动: $INSTALL_DIR/start.sh"
}

# === 主机模式安装 ===
install_host() {
    log_info "使用主机模式安装 MongoDB"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将下载到 $DOWNLOAD_DIR 并安装到 $INSTALL_DIR"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) log_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    local os_name
    case "$OS_TYPE" in
        macos) os_name="macos" ;;
        linux) os_name="linux" ;;
        *) log_error "不支持的操作系统"; exit 1 ;;
    esac

    local tgz_name="mongodb-${os_name}-${arch}-${MONGODB_VERSION}.tgz"
    local url="https://fastdl.mongodb.org/${os_name}/${tgz_name}"
    local archive="$DOWNLOAD_DIR/$tgz_name"

    mkdir -p "$DOWNLOAD_DIR"

    if [ -f "$archive" ] && verify_archive "$archive"; then
        log_info "检测到已存在安装包: $archive"
    else
        log_info "下载 MongoDB: $url"
        if ! download_file "$url" "$archive"; then
            log_error "下载失败"
            exit 1
        fi
        if ! verify_archive "$archive"; then
            log_error "安装包验证失败"
            rm -f "$archive"
            exit 1
        fi
    fi

    # 解压
    local temp_dir
    temp_dir="$(mktemp -d)"
    tar -xzf "$archive" -C "$temp_dir"

    local extracted
    extracted="$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)"
    if [ -z "$extracted" ]; then
        rm -rf "$temp_dir"
        log_error "解压后未找到 MongoDB 目录"
        exit 1
    fi

    # 安装到目标目录
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR"/*
    cp -R "$extracted"/* "$INSTALL_DIR/"
    rm -rf "$temp_dir"

    # 创建目录
    mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/logs" "$INSTALL_DIR/conf"

    # 创建配置
    cat > "$INSTALL_DIR/conf/mongodb.conf" <<EOF
storage:
  dbPath: ${INSTALL_DIR}/data
  journal:
    enabled: true

net:
  port: ${PORT}
  bindIp: 127.0.0.1

systemLog:
  destination: file
  path: ${INSTALL_DIR}/logs/mongodb.log
  logAppend: true

processManagement:
  fork: true
  pidFilePath: ${INSTALL_DIR}/mongodb.pid
EOF

    # 创建启动脚本
    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash
if pgrep -f "mongod.*${INSTALL_DIR}" > /dev/null 2>&1; then
    echo "MongoDB 已在运行"
    exit 0
fi
"${INSTALL_DIR}/bin/mongod" --config "${INSTALL_DIR}/conf/mongodb.conf"
echo "MongoDB 已启动，端口: ${PORT}"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    # 创建停止脚本
    cat > "$INSTALL_DIR/stop.sh" <<EOF
#!/bin/bash
pids="\$(pgrep -f "mongod.*${INSTALL_DIR}" || true)"
if [ -n "\$pids" ]; then
    kill \$pids 2>/dev/null || true
    sleep 2
    pids="\$(pgrep -f "mongod.*${INSTALL_DIR}" || true)"
    [ -n "\$pids" ] && kill -9 \$pids 2>/dev/null || true
fi
echo "MongoDB 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    log_ok "MongoDB 主机模式安装完成"
}

# === 卸载 ===
uninstall_mongodb() {
    log_info "卸载 MongoDB..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将删除 $INSTALL_DIR"
        return 0
    fi

    # 停止主机进程
    if pgrep -f "mongod.*$INSTALL_DIR" &>/dev/null; then
        log_info "停止 MongoDB 进程..."
        pids="$(pgrep -f "mongod.*$INSTALL_DIR" || true)"
        [ -n "$pids" ] && kill $pids 2>/dev/null || true
        sleep 2
        pids="$(pgrep -f "mongod.*$INSTALL_DIR" || true)"
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi

    # 停止 Docker 容器
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        log_info "停止 Docker 容器..."
        cd "$INSTALL_DIR"
        if docker compose version &>/dev/null; then
            docker compose down -v 2>/dev/null || true
        elif command -v docker-compose &>/dev/null; then
            docker-compose down -v 2>/dev/null || true
        fi
    fi

    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        log_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    log_ok "MongoDB 卸载完成"
}

# === 主函数 ===
main() {
    parse_args "$@"

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_mongodb
        exit 0
    fi

    log_info "MongoDB 安装"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载目录: $DOWNLOAD_DIR"
    log_info "端口: $PORT"

    # 自动选择模式
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if docker_available; then
            INSTALL_MODE="docker"
            log_info "检测到 Docker，使用 Docker 模式"
        else
            INSTALL_MODE="host"
            log_info "Docker 不可用，使用主机模式"
        fi
    fi

    case "$INSTALL_MODE" in
        docker)
            if ! docker_available; then
                log_error "Docker 不可用，无法使用 Docker 模式"
                exit 1
            fi
            install_docker ;;
        host)
            install_host ;;
        *)
            log_error "未知安装模式: $INSTALL_MODE"
            exit 1 ;;
    esac

    log_ok "MongoDB 安装完成"
    log_info "安装目录: $INSTALL_DIR"
    log_info "启动: $INSTALL_DIR/start.sh"
    log_info "停止: $INSTALL_DIR/stop.sh"
}

main "$@"

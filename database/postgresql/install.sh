#!/bin/bash
# PostgreSQL 安装脚本
# 支持 Docker 模式和主机模式，支持 macOS 和 Linux

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }

# === 常量 ===
PG_VERSION="15"
DEFAULT_INSTALL_DIR="$HOME/postgresql"
DEFAULT_PORT=5432

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
PORT="$DEFAULT_PORT"
INSTALL_MODE="auto"   # auto|docker|host
UNINSTALL_MODE=false
DRY_RUN=false

# === 帮助 ===
show_usage() {
    cat <<EOF
PostgreSQL 安装脚本

用法: $0 [选项]

选项:
    -h, --help                  显示此帮助
    -d, --dir DIR               安装目录 (默认: ~/postgresql)
    -p, --port PORT             端口号 (默认: 5432)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    --dry-run                   试运行
    --uninstall                 卸载 PostgreSQL

示例:
    $0                          # 自动模式安装
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

# === Docker 模式安装 ===
install_docker() {
    log_info "使用 Docker 模式安装 PostgreSQL"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将创建 Docker Compose 配置到 $INSTALL_DIR"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  postgres:
    image: postgres:${PG_VERSION}
    container_name: postgres
    restart: unless-stopped
    ports:
      - "${PORT}:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: postgres
      TZ: Asia/Shanghai
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - postgres-network

volumes:
  postgres-data:

networks:
  postgres-network:
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
echo "PostgreSQL 已启动"
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
echo "PostgreSQL 已停止"
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    log_ok "PostgreSQL Docker 配置创建完成"
    log_info "启动: $INSTALL_DIR/start.sh"
}

# === 主机模式安装 ===
install_host() {
    log_info "使用主机模式安装 PostgreSQL"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将安装 PostgreSQL 到 $INSTALL_DIR"
        return 0
    fi

    case "$OS_TYPE" in
        macos)
            if command -v brew &>/dev/null; then
                log_info "使用 Homebrew 安装 PostgreSQL..."
                brew install postgresql@${PG_VERSION}
                brew services start postgresql@${PG_VERSION}
            else
                log_error "macOS 上需要 Homebrew 来安装 PostgreSQL"
                log_info "安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                exit 1
            fi
            ;;
        linux)
            log_info "使用系统包管理器安装 PostgreSQL..."
            if command -v apt &>/dev/null; then
                sudo apt update
                sudo apt install -y postgresql-${PG_VERSION} postgresql-client-${PG_VERSION}
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}-contrib
            elif command -v yum &>/dev/null; then
                sudo yum install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}-contrib
            else
                log_error "不支持的包管理器"
                exit 1
            fi
            ;;
        *)
            log_error "不支持的操作系统"
            exit 1
            ;;
    esac

    log_ok "PostgreSQL 主机模式安装完成"
}

# === 卸载 ===
uninstall_postgresql() {
    log_info "卸载 PostgreSQL..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[Dry-run] 将卸载 PostgreSQL"
        return 0
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

    # macOS Homebrew 卸载
    if [[ "$OS_TYPE" == "macos" ]] && command -v brew &>/dev/null; then
        log_info "使用 Homebrew 卸载 PostgreSQL..."
        brew uninstall postgresql@${PG_VERSION} 2>/dev/null || true
    fi

    # Linux 包管理器卸载
    if [[ "$OS_TYPE" == "linux" ]]; then
        if command -v apt &>/dev/null; then
            sudo apt remove -y postgresql-${PG_VERSION} 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            sudo dnf remove -y postgresql${PG_VERSION}-server 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            sudo yum remove -y postgresql${PG_VERSION}-server 2>/dev/null || true
        fi
    fi

    log_ok "PostgreSQL 卸载完成"
}

# === 主函数 ===
main() {
    parse_args "$@"

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_postgresql
        exit 0
    fi

    log_info "PostgreSQL 安装"
    log_info "安装目录: $INSTALL_DIR"
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
                log_error "Docker 不可用"
                exit 1
            fi
            install_docker ;;
        host)
            install_host ;;
        *)
            log_error "未知安装模式: $INSTALL_MODE"
            exit 1 ;;
    esac

    log_ok "PostgreSQL 安装完成"
    log_info "启动: $INSTALL_DIR/start.sh"
    log_info "停止: $INSTALL_DIR/stop.sh"
}

main "$@"

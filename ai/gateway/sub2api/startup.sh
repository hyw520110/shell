#!/bin/bash

# sub2api 统一部署脚本 (Docker / 主机模式自适应)
# 功能：自动检测环境，优先使用 Docker 部署，无环境时尝试主机安装。

set -e

# ── 颜色定义 ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── 基础变量 ──────────────────────────────────────────────────────────
APP_NAME="sub2api"
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_URL="https://github.com/Wei-Shaw/sub2api.git"
GH_PROXY_URL="${GH_PROXY_URL:-}"

info()    { echo -e "${CYAN}[INFO]${RESET} $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${RESET} $*" >&2; }

# ── 环境检测 ──────────────────────────────────────────────────────────

detect_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        echo "docker"
        return
    fi
    echo "host"
}

check_service() {
    local url="${1:-http://localhost:8080}"
    if curl -fsS "$url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ── Docker 部署模式 ───────────────────────────────────────────────────

deploy_docker() {
    info "检测到 Docker 环境，启动容器化部署..."
    
    # 检查 docker-compose
    local dc_cmd="docker compose"
    if ! docker compose version &>/dev/null; then
        if command -v docker-compose &>/dev/null; then
            dc_cmd="docker-compose"
        else
            error "未找到 docker compose 命令。请先安装 Docker Compose。"
            exit 1
        fi
    fi

    # 检查 .env 文件
    if [[ ! -f "${WORK_DIR}/.env" ]]; then
        info "初始化配置文件..."
        if [[ -f "${WORK_DIR}/.env.example" ]]; then
            cp "${WORK_DIR}/.env.example" "${WORK_DIR}/.env"
        else
            touch "${WORK_DIR}/.env"
        fi
        warn "已生成默认 .env，请根据需要修改后重新运行。"
    fi

    info "正在拉取镜像并启动服务..."
    $dc_cmd -f "${WORK_DIR}/docker-compose.yml" up -d

    if check_service "http://localhost:8080"; then
        success "sub2api 已通过 Docker 启动并可访问！"
    else
        warn "服务已启动，但暂不可访问，可能正在初始化中..."
    fi
    info "管理后台: http://localhost:8080"
}

# ── 主机部署模式 ───────────────────────────────────────────────────

deploy_host() {
    info "未检测到 Docker 或环境受限，尝试主机系统原生安装..."
    
    # 检查基础依赖
    local missing_deps=()
    command -v go &>/dev/null || missing_deps+=("Go 1.21+")
    command -v node &>/dev/null || missing_deps+=("Node.js 18+")
    command -v pnpm &>/dev/null || missing_deps+=("pnpm")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "主机模式缺少必要组件: ${missing_deps[*]}"
        info "建议先安装 Docker 环境以简化部署，或手动补全上述依赖。"
        exit 1
    fi

    # 下载源码逻辑 (如果目录为空)
    if [[ ! -d "${WORK_DIR}/src" ]]; then
        local url="$REPO_URL"
        [[ -n "$GH_PROXY_URL" ]] && url="${GH_PROXY_URL}/${url}"
        info "正在克隆 sub2api 源码 (从 $url)..."
        git clone "$url" "${WORK_DIR}/src"
    fi

    cd "${WORK_DIR}/src"
    info "开始编译后端..."
    go build -o ../sub2api_backend main.go

    info "开始编译前端..."
    if [[ -d "frontend" ]]; then
        cd frontend && pnpm install && pnpm build
    fi

    success "主机模式编译完成！"
    warn "注意：主机模式需要您手动配置 Postgres 和 Redis 并在 .env 中指定连接信息。"
}

# ── 状态检查 ──────────────────────────────────────────────────────────

status_check() {
    info "正在检查 sub2api 状态..."
    if [[ $(detect_docker) == "docker" ]]; then
        docker ps --filter "name=sub2api" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
    
    if check_service "http://localhost:8080"; then
        success "服务状态: 运行中 (http://localhost:8080)"
    else
        error "服务状态: 无法访问"
    fi
}

# ── 主逻辑 ────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        status)
            status_check
            ;;
        *)
            echo -e "${BOLD}=========================================="
            echo -e "  sub2api 自动化部署系统 (2026)"
            echo -e "==========================================${RESET}"

            local mode=$(detect_docker)
            case "$mode" in
                docker) deploy_docker ;;
                host)   deploy_host ;;
            esac
            ;;
    esac
}

main "$@"

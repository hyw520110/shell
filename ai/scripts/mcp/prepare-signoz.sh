#!/usr/bin/env bash
set -euo pipefail

# Prepare the local SigNoz backend for the SigNoz MCP server.
# The supported self-hosted installation path is Foundry. On macOS, when
# Docker is absent and AI_HUB_SIGNOZ_AUTO_INSTALL_DOCKER=1 is set, this script
# uses the repository's Colima helper to provide a Docker-compatible runtime.

info() { echo "[INFO] [SigNoz Prepare] $*"; }
warn() { echo "[WARN] [SigNoz Prepare] $*"; }
error() { echo "[ERROR] [SigNoz Prepare] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SIGNOZ_DIR="${SIGNOZ_DIR:-$HOME/.signoz}"
CASTING_FILE="$SIGNOZ_DIR/casting.yaml"
MIN_FREE_GB="${AI_HUB_SIGNOZ_MIN_FREE_GB:-12}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_free_space() {
    local available_kb available_gb
    available_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
    available_gb=$((available_kb / 1024 / 1024))
    if (( available_gb < MIN_FREE_GB )); then
        error "磁盘可用空间约 ${available_gb}GB，SigNoz 建议至少预留 ${MIN_FREE_GB}GB。"
        error "请先清理安全的缓存或移除不需要的镜像，再重新选择 SigNoz。"
        return 1
    fi
    info "磁盘可用空间约 ${available_gb}GB，满足 SigNoz 预检查。"
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1 || command_exists docker-compose
}

ensure_docker_runtime() {
    if command_exists docker; then
        return 0
    fi

    if [[ "$OSTYPE" == "darwin"* && "${AI_HUB_SIGNOZ_AUTO_INSTALL_DOCKER:-0}" == "1" ]]; then
        local colima_script="${AI_HUB_COLIMA_SCRIPT:-$WORKSPACE_ROOT/docker/colima.sh}"
        if [[ ! -f "$colima_script" ]]; then
            error "未找到 Colima 管理脚本: $colima_script"
            return 1
        fi

        warn "未找到 Docker，按低资源方案安装并启动 Colima Docker 运行时。"
        info "Colima 资源: CPU=${AI_HUB_SIGNOZ_COLIMA_CPU:-4}、内存=${AI_HUB_SIGNOZ_COLIMA_MEMORY:-4}GB、磁盘=${AI_HUB_SIGNOZ_COLIMA_DISK:-30}GB"
        bash "$colima_script" install \
            --cpu "${AI_HUB_SIGNOZ_COLIMA_CPU:-4}" \
            --memory "${AI_HUB_SIGNOZ_COLIMA_MEMORY:-4}" \
            --disk "${AI_HUB_SIGNOZ_COLIMA_DISK:-30}" \
            --start --yes
    fi

    if ! command_exists docker; then
        error "未找到 Docker。SigNoz 需要 Docker Engine/Docker Desktop。"
        error "macOS 可执行: AI_HUB_SIGNOZ_AUTO_INSTALL_DOCKER=1 bash ai/scripts/mcp/prepare-signoz.sh"
        return 1
    fi
}

wait_for_docker() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi

    if [[ "$OSTYPE" == "darwin"* && "${AI_HUB_SIGNOZ_AUTO_INSTALL_DOCKER:-0}" == "1" ]] && command_exists colima; then
        warn "Docker 守护进程尚未就绪，正在启动 Colima..."
        colima start \
            --cpu "${AI_HUB_SIGNOZ_COLIMA_CPU:-4}" \
            --memory "${AI_HUB_SIGNOZ_COLIMA_MEMORY:-4}" \
            --disk "${AI_HUB_SIGNOZ_COLIMA_DISK:-30}" \
            --runtime docker >/dev/null
    fi

    info "等待 Docker 守护进程就绪 (最多 120 秒)..."
    for _ in {1..24}; do
        docker info >/dev/null 2>&1 && return 0
        sleep 5
    done

    error "Docker 守护进程启动超时。请先确认 Colima 或 Docker Desktop 正常运行。"
    return 1
}

ensure_foundryctl() {
    if command_exists foundryctl; then
        return 0
    fi

    local temp_dir install_script
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/signoz-foundry.XXXXXX")"
    install_script="$temp_dir/foundry.sh"

    info "正在安装 SigNoz 官方 foundryctl..."
    curl -fsSL https://signoz.io/foundry.sh -o "$install_script"
    bash "$install_script"
    rm -rf "$temp_dir"

    export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
    if ! command_exists foundryctl; then
        error "foundryctl 安装完成但未在 PATH 中找到。请重新打开终端后重试。"
        return 1
    fi
}

write_casting_file() {
    mkdir -p "$SIGNOZ_DIR"
    if [[ -f "$CASTING_FILE" ]]; then
        info "复用现有 Foundry 配置: $CASTING_FILE"
        return 0
    fi

    cat > "$CASTING_FILE" <<'YAML'
apiVersion: v1alpha1
kind: Installation
metadata:
  name: signoz
spec:
  deployment:
    flavor: compose
    mode: docker
YAML
    info "已创建 Foundry 配置: $CASTING_FILE"
}

wait_for_signoz() {
    info "等待 SigNoz UI/API 就绪 (最多 180 秒)..."
    for _ in {1..36}; do
        if curl -fsS --max-time 5 http://127.0.0.1:8080/ >/dev/null 2>&1; then
            info "SigNoz 已就绪: http://localhost:8080"
            return 0
        fi
        sleep 5
    done

    warn "SigNoz 容器已启动但 UI 尚未响应。当前容器状态："
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed -n '1,20p'
    error "SigNoz 尚未就绪，请查看 ~/.signoz/pours/deployment 的日志后重试。"
    return 1
}

main() {
    ensure_docker_runtime
    wait_for_docker
    ensure_free_space

    if ! docker_compose_available; then
        error "未找到 Docker Compose v2。请安装 docker compose 插件后重试。"
        return 1
    fi

    ensure_foundryctl
    write_casting_file

    info "正在通过 Foundry 启动 SigNoz 后端..."
    foundryctl cast -f "$CASTING_FILE"
    wait_for_signoz
    info "SigNoz 后端环境准备完毕。"
}

main "$@"

#!/bin/bash
# FreeLLMAPI 启动/停止/状态管理脚本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-$SCRIPT_DIR}"
COMPOSE_CMD="docker compose"

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

cd "$INSTALL_DIR"

case "${1:-start}" in
    start|up)
        if [[ "$(basename "$0")" != "start.sh" ]]; then
            shift 2>/dev/null || true
        fi
        echo "启动 FreeLLMAPI..."
        $COMPOSE_CMD up -d
        echo "管理面板: http://localhost:$(grep '^PORT=' .env 2>/dev/null | cut -d= -f2 || echo 3001)"
        ;;
    stop|down)
        if [[ "$(basename "$0")" != "stop.sh" ]]; then
            shift 2>/dev/null || true
        fi
        echo "停止 FreeLLMAPI..."
        $COMPOSE_CMD down
        echo "已停止"
        ;;
    restart)
        shift 2>/dev/null || true
        echo "重启 FreeLLMAPI..."
        $COMPOSE_CMD restart
        ;;
    logs)
        shift 2>/dev/null || true
        $COMPOSE_CMD logs -f --tail 100
        ;;
    status)
        shift 2>/dev/null || true
        $COMPOSE_CMD ps
        ;;
    update)
        shift 2>/dev/null || true
        echo "更新代码..."
        git pull --rebase origin main
        echo "重建并重启..."
        $COMPOSE_CMD up -d --build
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs|status|update}"
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  logs    - 查看日志"
        echo "  status  - 查看状态"
        echo "  update  - 更新代码并重启"
        ;;
esac

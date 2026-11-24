#!/bin/bash
# Harness 安装脚本
# 项目: https://github.com/harness/harness
# 文档: https://developer.harness.io/docs/open-source

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $*${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
log_error() { echo -e "${RED}[ERROR] $*${NC}"; }
log_step() { echo -e "${BLUE}[STEP] $*${NC}"; }

HARNESS_CONTAINER_NAME="harness"
HARNESS_PORT=3000
HARNESS_SSH_PORT=3022
HARNESS_DATA_DIR="${HOME}/.harness"

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        return 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker 未运行，请先启动 Docker"
        return 1
    fi
    log_info "Docker 已就绪"
}

stop_existing() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${HARNESS_CONTAINER_NAME}$"; then
        log_warn "发现已存在的 Harness 容器"
        read -r -p "是否停止并删除现有容器? [y/N]: " confirm
        if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
            log_info "停止并删除现有容器..."
            docker stop "${HARNESS_CONTAINER_NAME}" 2>/dev/null || true
            docker rm "${HARNESS_CONTAINER_NAME}" 2>/dev/null || true
        else
            log_info "保留现有容器，退出"
            exit 0
        fi
    fi
}

start_existing() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${HARNESS_CONTAINER_NAME}$"; then
        log_info "发现已存在的 Harness 容器，尝试启动..."
        docker start "${HARNESS_CONTAINER_NAME}"
        log_info "Harness 已启动"
        show_access_info
        return 0
    fi
    return 1
}

install_harness() {
    log_step "安装 Harness"

    mkdir -p "${HARNESS_DATA_DIR}"

    log_info "下载并启动 Harness 容器..."
    docker run -d \
        --name "${HARNESS_CONTAINER_NAME}" \
        --restart always \
        -p ${HARNESS_PORT}:3000 \
        -p ${HARNESS_SSH_PORT}:3022 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${HARNESS_DATA_DIR}:/data" \
        harness/harness

    log_info "Harness 容器已启动"
}

wait_for_ready() {
    log_step "等待 Harness 服务就绪..."
    local max_wait=120
    local count=0

    while [ $count -lt $max_wait ]; do
        if curl -sf http://localhost:${HARNESS_PORT} >/dev/null 2>&1; then
            log_info "Harness 服务已就绪"
            return 0
        fi
        sleep 2
        count=$((count + 2))
        echo -n "."
    done
    echo ""
    log_warn "等待超时，但服务可能仍在启动中"
    return 0
}

show_access_info() {
    echo ""
    log_info "========================================"
    log_info "Harness 安装完成！"
    log_info "========================================"
    echo ""
    log_info "访问地址:"
    log_info "  Web UI:     http://localhost:${HARNESS_PORT}"
    log_info "  API:        http://localhost:${HARNESS_PORT}/api/v1"
    log_info "  Swagger:    http://localhost:${HARNESS_PORT}/swagger"
    echo ""
    log_info "默认账号:"
    log_info "  用户名:     admin"
    log_info "  密码:      changeit"
    echo ""
    log_info "数据目录:    ${HARNESS_DATA_DIR}"
    echo ""
    log_info "容器管理命令:"
    log_info "  启动:      docker start ${HARNESS_CONTAINER_NAME}"
    log_info "  停止:      docker stop ${HARNESS_CONTAINER_NAME}"
    log_info "  日志:      docker logs -f ${HARNESS_CONTAINER_NAME}"
    log_info "  状态:      docker ps --filter name=${HARNESS_CONTAINER_NAME}"
    echo ""
    log_info "文档:       https://developer.harness.io/docs/open-source"
    log_info "========================================"
    echo ""
}

show_help() {
    cat << EOF
Harness 安装脚本

用法: $0 [命令]

命令:
    install     安装并启动 Harness (默认)
    start       启动已存在的 Harness 容器
    stop        停止 Harness 容器
    restart     重启 Harness 容器
    logs        查看 Harness 日志
    status      查看容器状态
    uninstall   卸载 Harness 容器和配置
    help        显示此帮助信息

示例:
    $0 install      # 安装 Harness
    $0 start        # 启动 Harness
    $0 stop         # 停止 Harness
    $0 logs         # 查看日志
EOF
}

cmd_start() {
    docker start "${HARNESS_CONTAINER_NAME}" && log_info "Harness 已启动" || log_error "启动失败"
}

cmd_stop() {
    docker stop "${HARNESS_CONTAINER_NAME}" && log_info "Harness 已停止" || log_error "停止失败"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_logs() {
    docker logs -f "${HARNESS_CONTAINER_NAME}"
}

cmd_status() {
    docker ps --filter "name=${HARNESS_CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_uninstall() {
    log_warn "即将卸载 Harness..."
    read -r -p "确认删除容器和数据? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
        docker stop "${HARNESS_CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${HARNESS_CONTAINER_NAME}" 2>/dev/null || true
        log_info "容器已删除"
        read -r -p "是否删除数据目录 ${HARNESS_DATA_DIR}? [y/N]: " confirm_data
        if [[ "${confirm_data:-N}" =~ ^[Yy]$ ]]; then
            rm -rf "${HARNESS_DATA_DIR}"
            log_info "数据目录已删除"
        fi
        log_info "卸载完成"
    else
        log_info "取消卸载"
    fi
}

main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install)
            check_docker || exit 1
            start_existing && exit 0
            stop_existing
            install_harness
            wait_for_ready
            show_access_info
            ;;
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        restart) cmd_restart ;;
        logs)    cmd_logs ;;
        status)  cmd_status ;;
        uninstall) cmd_uninstall ;;
        help|--help|-h) show_help ;;
        *)
            log_error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

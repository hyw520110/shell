#!/bin/bash
#
# Milvus 管理脚本 — 向量数据库（Docker/Kiri standalone 部署）
# Milvus 用 Docker Compose 跑 standalone（milvus-standalone + etcd + minio）
# 用 Kiri 或系统 docker 跑（国内用 daocloud 镜像加速）
#
# 功能：
#   install    下载官方 standalone docker-compose.yml，拉镜像，启动 milvus-standalone
#   update     检测最新版本（GitHub API），拉新镜像，安全替换后重启
#   uninstall  docker compose down -v，删数据目录（默认保留 volumes）
#   status     显示容器状态与 Milvus 版本
#   --print-version  打印最新版本（不下载）
#   --help      显示帮助
#
# 用法：
#   ./install.sh install
#   ./install.sh update
#   ./install.sh uninstall [--purge]
#   ./install.sh status
#   ./install.sh --print-version
#
# 官网：https://github.com/milvus-io/milvus  |  https://milvus.io
# 镜像：milvusdb/milvus:vX.Y.Z  |  国内加速：docker.m.daocloud.io/milvusdb/milvus:vX.Y.Z

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# === 常量 ===
GH_OWNER="milvus-io"
GH_REPO="milvus"
COMPOSE_URL="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/master/deployments/docker/standalone/docker-compose.yml"
# 镜像加速（国内 Docker Hub 直连不可达，默认 daocloud）
MIRROR="${KIRI_REGISTRY_MIRROR:-docker.m.daocloud.io}"
# 安装目录（compose + volumes）
INSTALL_DIR="${MILVUS_HOME:-$HOME/milvus}"
# 容器名
CONTAINER="milvus-standalone"
ETCD_CONTAINER="milvus-etcd"
MINIO_CONTAINER="milvus-minio"
# 健康检查端口
HEALTH_PORT=9091
GRPC_PORT=19530

# === 颜色 ===
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly NC=$'\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
print_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 检测 docker（Kiri 优先，回退系统 docker）===
find_docker() {
    # Kiri 自带 CLI 优先（若 Kiri 已装且 daemon 在）
    if [[ -x "$HOME/.kiri/bin/docker" ]]; then
        echo "$HOME/.kiri/bin/docker"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        echo "docker"
        return 0
    fi
    return 1
}

# === 检测已装版本（运行中容器的镜像 tag）===
get_current_version() {
    local dk
    dk=$(find_docker) || return 1
    local img
    img=$("$dk" inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)
    if [[ -n "$img" ]]; then
        echo "$img" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//'
    fi
}

# === 检测最新版本（GitHub API，限流回退 URL 探测）===
get_latest_version() {
    local api="https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/releases/latest"
    local json ver
    json=$(curl -sL --max-time 15 -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" "$api" 2>/dev/null || true)
    if [[ -n "$json" ]] && ! echo "$json" | grep -q "API rate limit exceeded"; then
        ver=$(echo "$json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("tag_name",""))' 2>/dev/null || echo "")
        ver="${ver#v}"
        if [[ -n "$ver" && "$ver" != "null" ]]; then
            echo "$ver"
            return 0
        fi
    fi
    # 回退：tags 列表（动态取 top tag）
    local tags_json
    tags_json=$(curl -sL --max-time 15 -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/tags?per_page=10" 2>/dev/null || true)
    if [[ -n "$tags_json" ]] && ! echo "$tags_json" | grep -q "API rate limit exceeded"; then
        local top_ver
        top_ver=$(echo "$tags_json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([t["name"].lstrip("v") for t in d if "name" in t][0] if d else "")' 2>/dev/null || echo "")
        if [[ -n "$top_ver" && "$top_ver" != "null" ]]; then
            echo "$top_ver"
            return 0
        fi
    fi
    # 最后兜底：官方 compose 里的镜像 tag（master 分支）
    local compose_ver
    compose_ver=$(curl -sL --max-time 15 "$COMPOSE_URL" 2>/dev/null | grep -oE 'milvusdb/milvus:v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [[ -n "$compose_ver" ]]; then
        echo "$compose_ver"
        return 0
    fi
    return 1
}

# === 下载官方 compose ===
download_compose() {
    mkdir -p "$INSTALL_DIR"
    local target="$INSTALL_DIR/docker-compose.yml"
    if [[ -f "$target" ]] && grep -q "milvusdb/milvus" "$target"; then
        print_info "compose 已存在（${target}），保留"
        return 0
    fi
    print_info "下载官方 standalone compose..."
    curl -sL --max-time 30 "$COMPOSE_URL" -o "$target" || { print_error "compose 下载失败"; return 1; }
    grep -q "milvusdb/milvus" "$target" || { print_error "compose 内容异常"; return 1; }
    print_success "compose 已下载（${target}）"
}

# === 用镜像加速改写 compose（仅 milvusdb/ → daocloud；etcd 保持 quay.io 直连）===
apply_mirror() {
    local target="$INSTALL_DIR/docker-compose.yml"
    if grep -q "${MIRROR}/milvusdb" "$target"; then
        return 0  # 已应用
    fi
    # 只替换 milvusdb/ 和 milvusdb/minio（etcd 是 quay.io，daocloud 无此镜像，保持直连）
    sed -i '' "s|image: milvusdb/|image: ${MIRROR}/milvusdb/|g" "$target" 2>/dev/null \
        || sed -i "s|image: milvusdb/|image: ${MIRROR}/milvusdb/|g" "$target"
    print_info "已应用镜像加速（${MIRROR}，milvus/minio；etcd 保持 quay.io 直连）"
}

# === 等 milvus 健康（9091/healthz）===
wait_healthy() {
    local dk timeout_s=180 i
    dk=$(find_docker) || return 1
    print_info "等待 Milvus 就绪（最多 ${timeout_s}s）..."
    for i in $(seq 1 "$timeout_s"); do
        if "$dk" exec "$CONTAINER" curl -sf http://localhost:9091/healthz >/dev/null 2>&1; then
            print_success "Milvus 健康检查通过（9091/healthz）"
            return 0
        fi
        sleep 1
    done
    print_warn "Milvus 未在 ${timeout_s}s 内就绪，可能仍在启动"
    return 1
}

# === 安装 ===
action_install() {
    local dk
    dk=$(find_docker) || { print_error "未找到 docker（需 Kiri 或系统 docker）"; return 1; }
    # 幂等：已运行则跳过
    if "$dk" inspect "$CONTAINER" >/dev/null 2>&1; then
        local cur
        cur=$(get_current_version)
        print_info "Milvus 已安装（${cur:-未知}），跳过重复安装"
        action_status
        return 0
    fi
    local latest
    latest=$(get_latest_version) || { print_error "无法获取最新版本"; return 1; }
    print_info "安装 Milvus $latest"
    download_compose || return 1
    apply_mirror
    print_info "拉取镜像并启动（首次拉取较慢）..."
    "$dk" compose -f "$INSTALL_DIR/docker-compose.yml" up -d || { print_error "docker compose up 失败"; return 1; }
    wait_healthy || true
    print_success "Milvus $latest 安装完成"
    print_info "连接: docker exec -it ${CONTAINER} milvus version"
    print_info "端口: gRPC ${GRPC_PORT} / 健康检查 ${HEALTH_PORT}"
    print_info "数据: $INSTALL_DIR/volumes"
}

# === 更新 ===
action_update() {
    local dk
    dk=$(find_docker) || { print_error "未找到 docker"; return 1; }
    local current latest
    current=$(get_current_version)
    latest=$(get_latest_version) || { print_error "无法获取最新版本"; return 1; }
    print_info "当前: ${current:-未安装}  最新: $latest"
    if [[ -z "$current" ]]; then
        print_warn "未检测到已安装的 Milvus，执行安装"
        action_install
        return 0
    fi
    if [[ "$current" == "$latest" ]]; then
        print_success "Milvus 已是最新版本 ($latest)"
        return 0
    fi
    print_info "升级 $current -> $latest"
    # 用最新 compose（可能更新镜像 tag）
    download_compose || return 1
    apply_mirror
    # 拉新镜像（镜像源）
    "$dk" pull "${MIRROR}/milvusdb/milvus:v${latest}" 2>/dev/null || "$dk" pull "milvusdb/milvus:v${latest}" || { print_error "拉取新镜像失败"; return 1; }
    # 更新 compose 镜像 tag 后重建
    sed -i '' "s|milvusdb/milvus:v[0-9]*\.[0-9]*\.[0-9]*|milvusdb/milvus:v${latest}|g" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null \
        || sed -i "s|milvusdb/milvus:v[0-9]*\.[0-9]*\.[0-9]*|milvusdb/milvus:v${latest}|g" "$INSTALL_DIR/docker-compose.yml"
    apply_mirror
    "$dk" compose -f "$INSTALL_DIR/docker-compose.yml" up -d || { print_error "docker compose up 失败"; return 1; }
    wait_healthy || true
    print_success "Milvus 已升级到 $latest"
}

# === 卸载 ===
action_uninstall() {
    local dk
    dk=$(find_docker) || { print_error "未找到 docker"; return 1; }
    local purge="${PURGE:-0}"
    print_info "卸载 Milvus..."
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        "$dk" compose -f "$INSTALL_DIR/docker-compose.yml" down -v 2>/dev/null || "$dk" compose -f "$INSTALL_DIR/docker-compose.yml" down || true
    fi
    if [[ "$purge" == "1" ]]; then
        # 安全校验：INSTALL_DIR 必须非空/非 / / 在 $HOME 下
        if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "/" || "$INSTALL_DIR" != "$HOME"/* ]]; then
            print_error "INSTALL_DIR 校验失败，拒绝删除: $INSTALL_DIR"
            return 1
        fi
        print_info "删除数据目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_info "保留数据目录: ${INSTALL_DIR}（--purge 删除）"
    fi
    print_success "Milvus 卸载完成"
}

# === 状态 ===
action_status() {
    local dk
    dk=$(find_docker) || { print_error "未找到 docker"; return 1; }
    if ! "$dk" inspect "$CONTAINER" >/dev/null 2>&1; then
        print_info "Milvus 未安装"
        return 1
    fi
    local state ver
    state=$("$dk" inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
    ver=$(get_current_version)
    print_info "Milvus 版本: ${ver:-未知}"
    print_info "容器状态: ${state}"
    "$dk" ps --filter "name=milvus" --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true
}

# === 帮助 ===
show_help() {
    cat <<EOF
Milvus 管理脚本（向量数据库，Docker/Kiri standalone）

用法: $SCRIPT_NAME <command> [选项]

命令:
  install            安装（下载官方 compose，启动 standalone）
  update             更新（检测最新版，拉新镜像重启）
  uninstall [--purge]  卸载（--purge 连数据目录一起删）
  status             显示状态
  --print-version    打印最新版本
  --help             显示此帮助

环境变量:
  MILVUS_HOME        安装目录（默认 ~/milvus）
  KIRI_REGISTRY_MIRROR  镜像加速（默认 docker.m.daocloud.io）

示例:
  $SCRIPT_NAME install
  $SCRIPT_NAME update
  $SCRIPT_NAME uninstall --purge
  $SCRIPT_NAME status
EOF
}

# === 主流程 ===
ACTION=""
PURGE=0
v=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        install)  ACTION="install"; shift ;;
        update)   ACTION="update"; shift ;;
        uninstall) ACTION="uninstall"; shift ;;
        status)   ACTION="status"; shift ;;
        --purge)  PURGE=1; shift ;;
        --print-version)
            v=$(get_latest_version) && { echo "$v"; exit 0; } || { print_error "无法获取最新版本"; exit 1; }
            ;;
        --help|-h) show_help; exit 0 ;;
        *) print_error "未知命令: $1"; show_help; exit 1 ;;
    esac
done

case "$ACTION" in
    install)   action_install ;;
    update)    action_update ;;
    uninstall) action_uninstall ;;
    status)    action_status ;;
    "")        show_help; exit 0 ;;
    *)         print_error "未知命令: $ACTION"; show_help; exit 1 ;;
esac

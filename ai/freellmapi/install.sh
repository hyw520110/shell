#!/bin/bash
#
# FreeLLMAPI 安装脚本
# 聚合 16 家 LLM 厂商免费额度到统一的 OpenAI 兼容 API 端点
#
# GitHub: https://github.com/tashfeenahmed/freellmapi
#

set -euo pipefail

# === 颜色 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# === 配置 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/freellmapi"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
DEFAULT_PORT=3001
PORT="${PORT:-$DEFAULT_PORT}"
REPO_URL="https://github.com/tashfeenahmed/freellmapi.git"
REPO_BRANCH="main"

# === 帮助 ===
show_help() {
    cat << 'EOF'
FreeLLMAPI 安装脚本

聚合 16 家 LLM 厂商免费额度到统一的 OpenAI 兼容 API 端点。
每月约 17 亿 Token 免费容量，100+ 模型。

用法: ./install.sh [选项]

选项:
    -d, --dir DIR         安装目录 (默认: ~/freellmapi)
    -p, --port PORT       服务端口 (默认: 3001)
    --uninstall            卸载 FreeLLMAPI
    -h, --help             显示此帮助

支持的提供商:
    Google (Gemini 2.5 Flash)    Groq (Llama 3.3, Qwen3)
    Cerebras (Qwen3 235B)         SambaNova (DeepSeek V3.x)
    Mistral (Large 3, Codestral)  OpenRouter (21 个免费模型)
    GitHub Models (GPT-4.1, GPT-4o) Cloudflare (Kimi K2, GLM-4.7)
    Cohere, 智谱, NVIDIA, HuggingFace, Ollama Cloud, Kilo Gateway, Pollinations, LLM7

安装后:
    1. 访问 http://localhost:3001 管理面板
    2. 在 Keys 页面添加各提供商 API Key
    3. 调整 Fallback Chain 模型顺序
    4. 使用统一 API Key 调用

使用示例:
    export OPENAI_BASE_URL="http://localhost:3001/v1"
    export OPENAI_API_KEY="freellmapi-你的统一密钥"
    # 然后使用任何 OpenAI 兼容客户端
EOF
}

# === 参数解析 ===
UNINSTALL_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            err "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# === 前置检查 ===
check_prerequisites() {
    local missing=()

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
        missing+=("docker-compose")
    fi

    if ! command -v openssl &>/dev/null; then
        missing+=("openssl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少前置依赖: ${missing[*]}"
        info "安装方式:"
        info "  docker:     https://docs.docker.com/get-docker/"
        info "  openssl:    brew install openssl (macOS) / apt install openssl (Linux)"
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        err "Docker 守护进程未运行，请先启动 Docker"
        exit 1
    fi

    ok "前置依赖检查通过"
}

# === 卸载 ===
do_uninstall() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        warn "安装目录不存在: $INSTALL_DIR"
        exit 0
    fi

    info "停止并移除 Docker 容器..."
    cd "$INSTALL_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true

    read -p "是否删除安装目录 $INSTALL_DIR? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        ok "已删除 $INSTALL_DIR"
    else
        info "保留安装目录"
    fi

    ok "卸载完成"
    exit 0
}

# === 安装 ===
do_install() {
    info "FreeLLMAPI 安装"
    echo ""

    # 检查是否已安装
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "检测到已有安装，更新代码..."
        cd "$INSTALL_DIR"
        git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || warn "代码更新失败，使用现有版本"
    else
        if [[ -d "$INSTALL_DIR" ]] && [[ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            err "安装目录已存在且非空: $INSTALL_DIR"
            err "请指定其他目录: ./install.sh -d /path/to/dir"
            exit 1
        fi

        info "克隆仓库..."
        git clone -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" || {
            err "克隆失败，请检查网络连接"
            exit 1
        }
    fi

    cd "$INSTALL_DIR"

    # 生成加密密钥
    if [[ ! -f .env ]]; then
        local encryption_key
        encryption_key=$(openssl rand -hex 32)
        printf "ENCRYPTION_KEY=%s\nPORT=%s\n" "$encryption_key" "$PORT" > .env
        ok "已生成 .env 配置文件"
    else
        warn ".env 已存在，跳过生成"
    fi

    # 确保 PORT 正确
    if ! grep -q "^PORT=" .env; then
        echo "PORT=$PORT" >> .env
    fi

    # 检查端口占用
    if lsof -i :"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
        err "端口 $PORT 已被占用"
        info "请修改端口: ./install.sh -p 3002"
        exit 1
    fi

    # 启动服务
    info "启动 Docker Compose 服务..."
    docker compose up -d --build || {
        err "Docker Compose 启动失败"
        exit 1
    }

    # 等待服务就绪
    info "等待服务启动..."
    local waited=0
    while [[ $waited -lt 30 ]]; do
        if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""

    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        ok "FreeLLMAPI 启动成功"
    else
        warn "服务可能仍在启动中，请稍后检查: docker logs freellmapi"
    fi

    # 输出使用说明
    echo ""
    echo "=========================================="
    ok "FreeLLMAPI 安装完成!"
    echo "=========================================="
    echo ""
    info "管理面板: http://localhost:$PORT"
    info "API 端点:  http://localhost:$PORT/v1/chat/completions"
    info "模型列表:  http://localhost:$PORT/v1/models"
    echo ""
    echo "下一步:"
    echo "  1. 打开管理面板，在 Keys 页面添加各提供商 API Key"
    echo "  2. 调整 Fallback Chain 模型顺序"
    echo "  3. 复制页面顶部的统一 API Key"
    echo ""
    echo "使用示例:"
    echo "  export OPENAI_BASE_URL=\"http://localhost:$PORT/v1\""
    echo "  export OPENAI_API_KEY=\"freellmapi-你的统一密钥\""
    echo ""
    echo "管理命令:"
    echo "  启动: cd $INSTALL_DIR && docker compose up -d"
    echo "  停止: cd $INSTALL_DIR && docker compose down"
    echo "  日志: cd $INSTALL_DIR && docker compose logs -f"
    echo "  卸载: ./install.sh --uninstall"
    echo ""
}

# === 主逻辑 ===
check_prerequisites

if [[ "$UNINSTALL_MODE" == "true" ]]; then
    do_uninstall
else
    do_install
fi

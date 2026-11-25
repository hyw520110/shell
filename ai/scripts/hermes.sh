#!/usr/bin/env bash
# Hermes Agent 一键安装 / 更新 / 卸载 / 状态
# 用法: hermes.sh <install|update|uninstall|status|install-mcp>

set -uo pipefail

HERMES_HOME="${HERMES_HOME:-${HOME:-}/.hermes}"
UV_INDEX="${UV_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
OFFICIAL_INSTALLER="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-hub/logs"
LOG=""
# GitHub 直连不通且无代理时使用的加速镜像（<host>/https://github.com/... 形式）
GIT_MIRRORS=(
    "https://ghproxy.net"
    "https://gh-proxy.com"
    "https://ghfast.top"
)
MIRROR=""

info() { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

check_home() {
    if [[ -z "${HOME:-}" || "$HOME" == "/" ]]; then
        die "HOME 为空或为 /，拒绝执行（避免误删系统目录）"
    fi
}

# 官方安装脚本会用 git / curl 拉仓库和依赖，需要把代理传进去，否则会卡住
detect_proxy() {
    local v p
    for v in ADL_PROXY HTTPS_PROXY https_proxy ALL_PROXY all_proxy HTTP_PROXY http_proxy; do
        p="${!v:-}"
        if [[ -n "$p" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    local cands=(
        "http://127.0.0.1:7890"
        "socks5h://127.0.0.1:7890"
        "socks5h://127.0.0.1:7891"
        "http://127.0.0.1:7897"
        "socks5h://127.0.0.1:1080"
        "socks5h://127.0.0.1:10871"
        "socks5h://127.0.0.1:10808"
        "http://127.0.0.1:8080"
    )
    for p in "${cands[@]}"; do
        if curl -fsS -m 3 -x "$p" -o /dev/null "https://www.gstatic.com/generate_204" 2>/dev/null; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

github_reachable() {
    curl -fsS -m 6 -o /dev/null https://github.com 2>/dev/null
}

# 逐个镜像试 git ls-remote，找到第一个真正能代理 git 的
detect_git_mirror() {
    local m
    for m in "${GIT_MIRRORS[@]}"; do
        if timeout 12 git ls-remote --heads "$m/https://github.com/NousResearch/hermes-agent.git" HEAD >/dev/null 2>&1; then
            printf '%s' "$m"
            return 0
        fi
    done
    return 1
}

# 用 GIT_CONFIG_* 注入 url.insteadOf，只作用于本次进程，不改任何 git 配置文件
setup_git_mirror() {
    local m
    if ! m=$(detect_git_mirror); then
        return 1
    fi
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.${m}/https://github.com/.insteadOf"
    export GIT_CONFIG_VALUE_0="https://github.com/"
    MIRROR="$m"
    info "已切换 GitHub 镜像: $m"
    return 0
}

setup_proxy() {
    local proxy np
    if proxy=$(detect_proxy); then
        export HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" ALL_PROXY="$proxy" \
            http_proxy="$proxy" https_proxy="$proxy" all_proxy="$proxy"
        # git 不读大小写混写的变量时，用 GIT_CONFIG_* 再兜一层
        export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.proxy" GIT_CONFIG_VALUE_0="$proxy"
        # api.github.com 的匿名配额按出口 IP 计：走代理会落到被共享耗尽的 IP 上，
        # 直连仍有余量。只让 API 绕过代理，git 与 raw 继续走代理。
        np="${no_proxy:-${NO_PROXY:-}}"
        case ",$np," in
            *,api.github.com,*) ;;
            *) np="${np:+$np,}api.github.com" ;;
        esac
        export NO_PROXY="$np" no_proxy="$np"
        info "使用代理: $proxy（api.github.com 直连，避开共享 IP 的 API 限流）"
    elif github_reachable; then
        info "未检测到代理，但 github.com 可直连"
    else
        warn "未检测到可用代理且 github.com 不可达，尝试 GitHub 镜像"
        setup_git_mirror || warn "未找到可用镜像，直连执行（GitHub 访问失败时会停在 git clone）"
    fi
    export GIT_TERMINAL_PROMPT=0
}

# 失败时把日志尾部打出来并暂停，避免 TUI 刷新导致错误一闪而过
show_failure() {
    local rc="$1"
    printf '\n错误: 安装失败（退出码 %s）\n' "$rc" >&2
    if [[ -n "$LOG" && -s "$LOG" ]]; then
        printf '最近日志:\n' >&2
        tail -n 20 "$LOG" >&2
        printf '完整日志: %s\n' "$LOG" >&2
    fi
    if [[ -t 0 && "${AI_HUB_NON_INTERACTIVE:-0}" != "1" && "${AI_HUB_NO_PAUSE:-0}" != "1" ]]; then
        read -rsn1 -p "按任意键返回菜单..." || true
        printf '\n'
    fi
    exit 1
}

ensure_uv() {
    command -v uv >/dev/null 2>&1 && return 0
    command -v curl >/dev/null 2>&1 || die "未找到 curl，无法安装 uv"
    info "未找到 uv，正在安装..."
    curl -LsSf https://astral.sh/uv/install.sh | sh || die "uv 安装失败"
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv 安装后仍不可用，请检查 PATH"
}

install_mcp() {
    local repo="$HERMES_HOME/hermes-agent"
    [[ -d "$repo" ]] || die "未找到 $repo，请先执行 install"
    # 优先走 hermes 自带的 pm：它套用 pyproject 的 override 和 vetted 锁文件。
    # 直接用 uv pip install 会因 pillow==13.0.0 override 与 browser-harness
    # 的精确 pin 冲突而求解失败。
    if command -v hermes >/dev/null 2>&1; then
        info "通过 hermes pm 安装 MCP 依赖..."
        if ( cd "$repo" && hermes pm install --extra mcp ); then
            info "MCP 依赖就绪"
            return 0
        fi
        warn "MCP 依赖未安装，可稍后手动执行: cd \"$repo\" && hermes pm install --extra mcp"
        return 0
    fi
    cd "$repo" || die "无法进入 $repo"
    if [[ ! -x venv/bin/python ]]; then
        info "创建 Python 虚拟环境..."
        UV_INDEX_URL="$UV_INDEX" uv venv venv || die "创建虚拟环境失败"
    fi
    if ! venv/bin/python -c 'import mcp' >/dev/null 2>&1; then
        info "安装 MCP 依赖..."
        UV_INDEX_URL="$UV_INDEX" uv pip install --python venv/bin/python -e ".[mcp]" \
            || warn "MCP 依赖安装失败，可稍后手动重试"
    fi
    info "MCP 依赖就绪"
}

cmd_install() {
    check_home
    setup_proxy

    local tmp rc
    mkdir -p "$LOG_DIR" || die "无法创建日志目录 $LOG_DIR"
    LOG="$LOG_DIR/hermes-install-$(date +%Y%m%d-%H%M%S).log"

    tmp=$(mktemp "${TMPDIR:-/tmp}/aihub-hermes.XXXXXX") || die "创建临时文件失败"
    trap 'rm -f -- "$tmp"' EXIT

    ensure_uv
    info "下载官方安装脚本..."
    if ! curl -fsSL -o "$tmp" "$OFFICIAL_INSTALLER"; then
        if [[ -n "${MIRROR:-}" ]]; then
            info "直连失败，改用镜像下载安装脚本..."
            curl -fsSL -o "$tmp" "$MIRROR/$OFFICIAL_INSTALLER" || show_failure 1
        else
            show_failure 1
        fi
    fi
    info "执行安装（pip 镜像: $UV_INDEX）..."
    UV_INDEX_URL="$UV_INDEX" bash "$tmp" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || show_failure "$rc"

    install_mcp
    info "Hermes Agent 安装完成。重新加载 shell 后运行 'hermes setup' 完成配置。"
    info "安装日志: $LOG"
}

cmd_update() {
    check_home
    setup_proxy
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    LOG="$LOG_DIR/hermes-update-$(date +%Y%m%d-%H%M%S).log"

    if command -v hermes >/dev/null 2>&1; then
        info "执行 hermes update ..."
        hermes update 2>&1 | tee "$LOG"
        local rc=${PIPESTATUS[0]}
        [[ $rc -eq 0 ]] || show_failure "$rc"
        install_mcp
    else
        warn "未检测到 hermes 命令，转为执行安装"
        cmd_install
    fi
}

# 删除前做三层判断：路径为空 / 高风险路径 / 是否真实存在
remove_path() {
    local path="$1" desc="$2"
    if [[ -z "$path" ]]; then
        warn "跳过 $desc：路径为空"
        return 0
    fi
    case "$path" in
        /|"$HOME"|"$HOME/")
            warn "拒绝删除高风险路径: $path"
            return 1
            ;;
    esac
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        info "$desc 不存在，跳过: $path"
        return 0
    fi
    if rm -rf -- "$path"; then
        info "已删除 $desc: $path"
    else
        warn "删除 $desc 失败: $path"
        return 1
    fi
}

cmd_uninstall() {
    check_home
    pkill -f 'hermes gateway' >/dev/null 2>&1 || true
    remove_path "$HERMES_HOME" "配置目录"
    remove_path "$HOME/.local/share/hermes" "数据目录"
    local f
    for f in "$HOME/.bashrc.d/hermes"* "$HOME/.zshrc.d/hermes"*; do
        [[ -e "$f" ]] || continue
        rm -f -- "$f" && info "已删除 shell 配置: $f"
    done
    info "Hermes Agent 已卸载"
}

cmd_status() {
    if command -v hermes >/dev/null 2>&1; then
        info "hermes: $(command -v hermes)"
        hermes --version 2>/dev/null || true
    else
        info "hermes: 未安装"
    fi
    if [[ -d "$HERMES_HOME" ]]; then
        info "配置目录: $HERMES_HOME"
    else
        info "配置目录: 不存在 ($HERMES_HOME)"
    fi
}

case "${1:-}" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    install-mcp) install_mcp ;;
    *) die "用法: $(basename "$0") <install|update|uninstall|status|install-mcp>" ;;
esac

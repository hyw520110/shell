#!/usr/bin/env bash
# Google Antigravity 一键安装 / 更新 / 卸载 / 状态
# 用法: antigravity.sh <install|update|uninstall|status> [cli|app]
#   cli  命令行版，安装 agy（默认）
#   app  桌面 IDE（Linux tar.gz 解压到 ~/.local/opt/antigravity-ide）

set -uo pipefail

CLI_INSTALL_URL="https://antigravity.google/cli/install.sh"
IDE_DOWNLOAD_PAGE="https://antigravity.google/download"
# 页面解析失败时的兜底地址（2.8.0）
IDE_FALLBACK_URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/linux-x64/Antigravity%20IDE.tar.gz"
APP_DIR="${HOME:-}/.local/opt/antigravity-ide"
APP_LAUNCHER="${HOME:-}/.local/bin/antigravity"
APP_DESKTOP="${HOME:-}/.local/share/applications/antigravity-ide.desktop"
ADL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/network/tools/adl"
LOG_DIR="${XDG_CACHE_HOME:-${HOME:-}/.cache}/ai-hub/logs"
LOG=""

info() { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# 失败时把日志尾部打出来并暂停，避免 TUI 刷新导致错误一闪而过
show_failure() {
    local rc="$1"
    printf '\n错误: 执行失败（退出码 %s）\n' "$rc" >&2
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

check_home() {
    if [[ -z "${HOME:-}" || "$HOME" == "/" ]]; then
        die "HOME 为空或为 /，拒绝执行（避免误删系统目录）"
    fi
}

# 官方脚本内部的 curl/wget/git 需要代理，否则下载会卡住
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

with_proxy() {
    local proxy
    if proxy=$(detect_proxy); then
        HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" ALL_PROXY="$proxy" \
            http_proxy="$proxy" https_proxy="$proxy" all_proxy="$proxy" "$@"
    else
        "$@"
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

# ==================== CLI ====================

install_cli() {
    check_home
    local tmpdir=""
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aihub-antigravity.XXXXXX") || die "创建临时目录失败"
    # trap 在函数返回后的 subshell 退出时才触发，此时 local 已出作用域，
    # 必须用 ${tmpdir:-} 兜底，否则 set -u 会报未绑定变量并跳过清理
    trap 'if [[ -n "${tmpdir:-}" ]]; then rm -rf -- "$tmpdir"; fi' EXIT

    if [[ -x "$ADL" ]]; then
        info "使用 ADL 下载 CLI 安装脚本..."
        "$ADL" "$CLI_INSTALL_URL" "$tmpdir" "install.sh" || die "下载安装脚本失败"
    else
        info "使用 curl 下载 CLI 安装脚本..."
        with_proxy curl -fsSL -o "$tmpdir/install.sh" "$CLI_INSTALL_URL" || die "下载安装脚本失败"
    fi
    [[ -s "$tmpdir/install.sh" ]] || die "安装脚本为空"

    local proxy
    if proxy=$(detect_proxy); then
        info "使用代理执行安装: $proxy"
        HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" ALL_PROXY="$proxy" \
            http_proxy="$proxy" https_proxy="$proxy" \
            bash "$tmpdir/install.sh" || die "官方安装脚本执行失败"
    else
        info "未检测到可用代理，直连执行安装"
        bash "$tmpdir/install.sh" || die "官方安装脚本执行失败"
    fi

    if [[ -x "$HOME/.local/bin/agy" ]] || command -v agy >/dev/null 2>&1; then
        info "Antigravity CLI 安装完成。若提示找不到 agy，请把 ~/.local/bin 加入 PATH。"
    else
        die "安装脚本执行完毕，但未找到 agy 可执行文件"
    fi

    # 显式清理：trap 在函数返回后才触发，那时 local tmpdir 已失效
    rm -rf -- "$tmpdir" && tmpdir=""
}

uninstall_cli() {
    check_home
    remove_path "$HOME/.local/bin/agy" "agy 可执行文件"
    remove_path "$HOME/.cache/antigravity" "下载缓存"
    info "Antigravity CLI 已卸载"
}

status_cli() {
    if command -v agy >/dev/null 2>&1; then
        info "agy: $(command -v agy)"
        agy --version 2>/dev/null || true
    elif [[ -x "$HOME/.local/bin/agy" ]]; then
        info "agy: $HOME/.local/bin/agy（未加入 PATH）"
    else
        info "agy: 未安装"
    fi
}

# ==================== APP（桌面 IDE） ====================

ide_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'linux-x64' ;;
        aarch64|arm64) printf 'linux-arm' ;;
        *) return 1 ;;
    esac
}

resolve_ide_url() {
    local arch="$1" html url
    html=$(curl -fsSL -m 25 "$IDE_DOWNLOAD_PAGE" 2>/dev/null) || true
    if [[ -n "$html" ]]; then
        url=$(printf '%s' "$html" \
            | grep -oE "https://[^\"'< ]*antigravity/stable/[^\"'< ]*/${arch}/Antigravity(%20| )IDE\.tar\.gz" \
            | head -1 | sed 's/ /%20/g')
        if [[ -n "$url" ]]; then
            printf '%s' "$url"
            return 0
        fi
    fi
    [[ "$arch" == "linux-x64" ]] && printf '%s' "$IDE_FALLBACK_URL"
}

write_desktop_entry() {
    local bin="$1" dir="$HOME/.local/share/applications"
    mkdir -p "$dir" || return 1
    cat > "$dir/antigravity-ide.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Google Antigravity IDE
Comment=Google AI-first IDE
Exec=$bin %F
Terminal=false
Categories=Development;IDE;
StartupWMClass=Antigravity
EOF
    info "已写入桌面入口: $dir/antigravity-ide.desktop"
}

install_app() {
    check_home
    local arch url tmpdir extract launcher root bin
    arch=$(ide_arch) || die "不支持的架构: $(uname -m)，官方 IDE 仅提供 x64/ARM64"
    url=$(resolve_ide_url "$arch") || die "无法从 $IDE_DOWNLOAD_PAGE 解析 IDE 下载地址"
    info "IDE 下载地址: $url"

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aihub-antigravity-app.XXXXXX") || die "创建临时目录失败"
    # 同上：trap 触发时 local tmpdir 可能已出作用域
    trap 'if [[ -n "${tmpdir:-}" ]]; then rm -rf -- "$tmpdir"; fi' EXIT

    if [[ -x "$ADL" ]]; then
        info "使用 ADL 下载 IDE 安装包（约 190MB）..."
        "$ADL" "$url" "$tmpdir" "antigravity-ide.tar.gz" || die "下载 IDE 安装包失败"
    else
        info "使用 curl 下载 IDE 安装包（约 190MB）..."
        with_proxy curl -fLsS -o "$tmpdir/antigravity-ide.tar.gz" "$url" \
            || die "下载 IDE 安装包失败"
    fi

    extract="$tmpdir/extract"
    mkdir -p "$extract" || die "创建解压目录失败"
    info "解压安装包..."
    tar -xzf "$tmpdir/antigravity-ide.tar.gz" -C "$extract" --no-same-owner \
        || die "解压失败"

    launcher=$(find "$extract" -maxdepth 3 -type f \( -name antigravity -o -name "Antigravity IDE" \) -perm -u+x 2>/dev/null | head -1)
    [[ -n "$launcher" ]] || launcher=$(find "$extract" -maxdepth 3 -type f -perm -u+x 2>/dev/null | head -1)
    [[ -n "$launcher" ]] || die "解压后未找到可执行文件（包结构可能已变化）"
    root=$(dirname "$launcher")

    remove_path "$APP_DIR" "旧应用目录" >/dev/null 2>&1 || true
    mkdir -p "$APP_DIR" || die "创建 $APP_DIR 失败"
    shopt -s dotglob nullglob
    mv "$root"/* "$APP_DIR"/ || die "移动到 $APP_DIR 失败"
    shopt -u dotglob nullglob

    bin="$APP_DIR/$(basename "$launcher")"
    chmod +x "$bin" 2>/dev/null || true
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$bin" "$APP_LAUNCHER" || die "创建启动器软链失败"
    write_desktop_entry "$bin"
    info "Antigravity IDE 安装完成: $APP_LAUNCHER"

    # 显式清理：trap 在函数返回后才触发，那时 local tmpdir 已失效
    rm -rf -- "$tmpdir" && tmpdir=""
}

uninstall_app() {
    check_home
    pkill -f "$APP_DIR" >/dev/null 2>&1 || true
    remove_path "$APP_LAUNCHER" "应用启动器"
    remove_path "$APP_DESKTOP" "桌面入口"
    remove_path "$APP_DIR" "应用目录"
    info "Antigravity IDE 已卸载"
}

status_app() {
    if [[ -L "$APP_LAUNCHER" || -x "$APP_LAUNCHER" ]]; then
        local target
        target=$(readlink -f "$APP_LAUNCHER" 2>/dev/null || true)
        if [[ -n "$target" && -x "$target" ]]; then
            info "IDE: 已安装 ($target)"
        else
            warn "IDE: 启动器存在但目标缺失: $APP_LAUNCHER"
        fi
    elif [[ -d "$APP_DIR" ]]; then
        info "IDE: 应用目录存在但无启动器: $APP_DIR"
    else
        info "IDE: 未安装"
    fi
    [[ -e "$APP_DESKTOP" ]] && info "桌面入口: $APP_DESKTOP"
    return 0
}

# ==================== 入口 ====================

dispatch() {
    local action="$1" target="$2"
    case "$action:$target" in
        install:cli|update:cli) install_cli ;;
        install:app|update:app) install_app ;;
        uninstall:cli) uninstall_cli ;;
        uninstall:app) uninstall_app ;;
        status:cli) status_cli ;;
        status:app) status_app ;;
    esac
}

# install/update 全程写入日志；失败时打印日志尾部并暂停等按键
run_logged() {
    local action="$1" target="$2" rc
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]]; then
        LOG="$LOG_DIR/antigravity-${action}-${target}-$(date +%Y%m%d-%H%M%S).log"
        dispatch "$action" "$target" 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
    else
        warn "日志目录不可写（$LOG_DIR），本次不记录日志"
        dispatch "$action" "$target"
        rc=$?
    fi
    [[ $rc -eq 0 ]] || show_failure "$rc"
    [[ -n "$LOG" ]] && info "日志: $LOG"
    return 0
}

action="${1:-}"
target="${2:-cli}"

case "$target" in
    cli|app) ;;
    *) die "未知目标: $target（可选 cli 或 app）" ;;
esac

case "$action" in
    install|update) run_logged "$action" "$target" ;;
    uninstall|status) dispatch "$action" "$target" ;;
    *)
        # 兼容旧调用：antigravity.sh install 等已由 target 默认 cli 覆盖
        die "用法: $(basename "$0") <install|update|uninstall|status> [cli|app]"
        ;;
esac

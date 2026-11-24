#!/usr/bin/env bash
# CC-Switch helper for AI Hub / Claude Code commands.

set -euo pipefail

REPO="farion1231/cc-switch"
GH_PROXY_URL="${GH_PROXY_URL:-}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
[[ -n "$GH_PROXY_URL" ]] && API_URL="${GH_PROXY_URL}/${API_URL}"
DOWNLOAD_DIR="${CC_SWITCH_DOWNLOAD_DIR:-$HOME/Downloads}"
APP_NAME="CC-Switch.app"

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        log_error "缺少依赖: $cmd"
        exit 1
    }
}

cc_switch_app_path() {
    local app
    for app in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
        [[ -d "$app" ]] && { printf '%s\n' "$app"; return 0; }
    done
    return 1
}

detect_asset_pattern() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            printf 'macOS.dmg\n'
            ;;
        Linux)
            case "$arch" in
                arm64|aarch64) printf 'Linux-arm64.AppImage\n' ;;
                x86_64|amd64) printf 'Linux-x86_64.AppImage\n' ;;
                *)
                    log_error "暂不支持的 Linux 架构: $arch"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "暂不支持的系统: $os"
            exit 1
            ;;
    esac
}

latest_asset_field() {
    local field="$1"
    local pattern="$2"

    require_cmd curl
    require_cmd jq

    local url="$API_URL"
    curl -fsSL "$url" |
        jq -r --arg pattern "$pattern" --arg field "$field" '
            .assets
            | map(select(.name | endswith($pattern)))
            | first
            | .[$field] // empty
        '
}

download_latest() {
    local pattern name url target
    pattern="$(detect_asset_pattern)"
    name="$(latest_asset_field name "$pattern")"
    url="$(latest_asset_field browser_download_url "$pattern")"

    if [[ -z "$name" || -z "$url" ]]; then
        log_error "未在最新 release 中找到匹配资产: *${pattern}"
        log_info "请手动访问: https://github.com/${REPO}/releases/latest"
        exit 1
    fi

    if [[ -n "$GH_PROXY_URL" ]]; then
        url="${GH_PROXY_URL}/${url}"
    fi

    mkdir -p "$DOWNLOAD_DIR"
    target="$DOWNLOAD_DIR/$name"

    if [[ -s "$target" ]]; then
        log_info "检测到已下载文件: $target"
    else
        log_info "下载 CC-Switch: $name (从 $url)"
        curl -fL --retry 3 --retry-delay 2 "$url" -o "$target"
    fi

    printf '%s\n' "$target"
}

install_cc_switch() {
    local target
    target="$(download_latest)"

    case "$(uname -s)" in
        Darwin)
            log_info "已下载 macOS 安装包: $target"
            log_info "即将打开 DMG，请按安装包界面将 CC-Switch 拖入 Applications。"
            open "$target"
            ;;
        Linux)
            chmod +x "$target"
            log_info "已下载 AppImage: $target"
            log_info "可直接运行: $target"
            ;;
    esac
}

open_cc_switch() {
    # 优先尝试命令名
    if command -v cc-switch >/dev/null 2>&1; then
        cc-switch "$@" || true
        return 0
    fi

    case "$(uname -s)" in
        Darwin)
            local app
            app="$(cc_switch_app_path || true)"
            [[ -n "$app" ]] || {
                log_error "未检测到 $APP_NAME，请先执行 install。"
                exit 1
            }
            open "$app"
            ;;
        Linux)
            log_error "未检测到 cc-switch 命令。请先执行 install，并运行下载的 AppImage。"
            exit 1
            ;;
    esac
}

status_cc_switch() {
    local found=0 app
    if command -v cc-switch >/dev/null 2>&1; then
        echo -e "[CC-Switch CLI] $(command -v cc-switch)"
        cc-switch --version 2>/dev/null || true
        found=1
    fi

    app="$(cc_switch_app_path || true)"
    if [[ -n "$app" ]]; then
        echo -e "[CC-Switch App] $app"
        found=1
    fi

    if [[ "$found" -eq 0 ]]; then
        log_warn "未检测到 CC-Switch"
        return 1
    fi
    return 0
}

config_cc_switch() {
    echo -e "\n--- Claude Code 配置 ---"
    local claude_conf="$HOME/.claude/config.json"
    [[ -f "$claude_conf" ]] && ls -la "$claude_conf" || echo "未找到 $claude_conf"

    echo -e "\n--- CC-Switch 配置目录 ---"
    local dir
    for dir in "$HOME/.cc-switch" "$HOME/Library/Application Support/CC-Switch" "$HOME/.config/cc-switch"; do
        if [[ -e "$dir" ]]; then
             echo "检测到: $dir"
             ls -la "$dir" | grep -v "^total" | head -n 5
        fi
    done
}

case "${1:-}" in
    install) install_cc_switch ;;
    download) download_latest >/dev/null ;;
    open) shift; open_cc_switch "$@" ;;
    status) status_cc_switch ;;
    config) config_cc_switch ;;
    *)
        cat <<EOF
用法: $0 {install|download|open|status|config}

选项:
  install   下载并启动 macOS 安装包或 Linux AppImage
  download  仅下载最新版本到 $DOWNLOAD_DIR
  open      启动 CC-Switch 应用或执行 CLI
  status    检查安装状态
  config    查看相关配置文件路径

来源: https://github.com/${REPO}
EOF
        exit 1
        ;;
esac

#!/bin/bash

set -euo pipefail

QODER_DOWNLOAD_PAGE="https://qoder.com/download"
QODER_INSTALL_URL="https://qoder.com/install"
QODER_WAKE_INSTALL_URL="https://download.qoder.com/qoderwake/install.sh"

export PATH="$HOME/.local/bin:$HOME/.qoderwake/bin:${PATH:-}"

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        qoder --version 2>/dev/null || qodercli --version 2>/dev/null || qoderwake --version 2>/dev/null || true
        exit 0
    fi

    if ! command_exists qoder && ! command_exists qodercli; then
        log_warn "QoderWork 旧版桌面 DMG 下载入口已不可用，改为安装官方 Qoder CLI 并打开官方下载页。"
        log_info "安装 Qoder CLI..."
        curl -fsSL "$QODER_INSTALL_URL" | bash
    else
        log_info "Qoder CLI 已安装，跳过"
    fi

    if [[ "${AI_HUB_INSTALL_QODERWAKE:-0}" == "1" ]]; then
        if ! command_exists qoderwake && [[ ! -x "$HOME/.qoderwake/bin/qoderwake" ]]; then
            log_warn "Qoder Wake 官方安装器会触发网页登录；仅在 AI_HUB_INSTALL_QODERWAKE=1 时执行。"
            curl -fsSL "$QODER_WAKE_INSTALL_URL" | bash
        else
            log_info "Qoder Wake 已安装，跳过"
        fi
    else
        log_info "跳过 Qoder Wake 自动安装；如需安装并登录，手动运行: curl -fsSL $QODER_WAKE_INSTALL_URL | bash"
    fi

    if command_exists open; then
        open "$QODER_DOWNLOAD_PAGE" >/dev/null 2>&1 || true
    fi

    log_info "Qoder 当前官方下载页: $QODER_DOWNLOAD_PAGE"
    log_info "如需桌面端或 Wake 登录，请按官网当前入口安装；脚本不会再使用已失效的 QoderWork-darwin-*.dmg。"
}

main "$@"

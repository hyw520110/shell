#!/usr/bin/env bash

set -euo pipefail

RTK_GIT_URL="${RTK_GIT_URL:-https://github.com/rtk-ai/rtk}"
ACTION="${1:-install}"

log() { printf '[RTK] %s\n' "$*"; }
warn() { printf '[RTK][WARN] %s\n' "$*" >&2; }
error() { printf '[RTK][ERROR] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

load_cargo_env() {
    local cargo_env="${HOME}/.cargo/env"
    if [[ -f "$cargo_env" ]]; then
        # shellcheck source=/dev/null
        source "$cargo_env"
    fi
    export PATH="${HOME}/.cargo/bin:${PATH:-}"
}

confirm_yes() {
    local prompt="$1"
    local answer=""

    if [[ -t 0 ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer=${answer:-Y}
        [[ "$answer" =~ ^[Yy]$ ]]
    else
        [[ "${AI_HUB_ASSUME_YES:-0}" == "1" ]]
    fi
}

download_file() {
    local url="$1"
    local out="$2"

    if [[ "${AI_HUB_USE_ADL:-1}" != "0" ]] && command_exists adl; then
        log "使用 adl 下载: $url"
        adl "$url" "$(dirname "$out")" "$(basename "$out")"
    elif command_exists curl; then
        curl --proto '=https' --tlsv1.2 -sSf "$url" -o "$out"
    elif command_exists wget; then
        wget -q "$url" -O "$out"
    else
        error "需要 curl、wget 或 adl 下载依赖"
        return 1
    fi
}

install_system_package() {
    local pkg="$1"

    case "$(uname -s 2>/dev/null)" in
        Darwin)
            if command_exists brew; then
                brew install "$pkg"
            else
                error "未检测到 Homebrew，请先安装 $pkg"
                return 1
            fi
            ;;
        Linux)
            if command_exists apt-get; then
                sudo apt-get update
                sudo apt-get install -y "$pkg"
            elif command_exists yum; then
                sudo yum install -y "$pkg"
            elif command_exists dnf; then
                sudo dnf install -y "$pkg"
            elif command_exists apk; then
                sudo apk add "$pkg"
            else
                error "未找到可用包管理器，请手动安装 $pkg"
                return 1
            fi
            ;;
        *)
            error "未知系统，请手动安装 $pkg"
            return 1
            ;;
    esac
}

ensure_git() {
    if command_exists git; then
        log "git 已就绪: $(git --version 2>/dev/null | head -1)"
        return 0
    fi

    warn "RTK 通过 Git 仓库安装，需要 git"
    if confirm_yes "是否安装 git?"; then
        install_system_package git
    else
        error "已取消。请先安装 git 后重试"
        return 1
    fi
}

install_rust_toolchain() {
    if command_exists rustup; then
        log "rustup 已存在，更新 Rust 工具链..."
        rustup update
        load_cargo_env
        command_exists cargo
        return $?
    fi

    local rustup_init
    rustup_init=$(mktemp "${TMPDIR:-/tmp}/rtk-rustup.XXXXXX") || return 1

    log "下载 rustup 安装脚本..."
    if ! download_file "https://sh.rustup.rs" "$rustup_init" || [[ ! -s "$rustup_init" ]]; then
        rm -f "$rustup_init"
        error "rustup 安装脚本下载失败"
        return 1
    fi

    log "安装 Rust stable 工具链..."
    sh "$rustup_init" -y --default-toolchain stable
    local rc=$?
    rm -f "$rustup_init"
    [[ $rc -eq 0 ]] || return $rc

    load_cargo_env
    command_exists cargo
}

ensure_cargo() {
    load_cargo_env
    if command_exists cargo; then
        log "cargo 已就绪: $(cargo --version 2>/dev/null)"
        return 0
    fi

    warn "未检测到 cargo，RTK 需要 Rust/Cargo 安装"
    if confirm_yes "是否安装 Rust 工具链?"; then
        install_rust_toolchain || {
            error "Rust/Cargo 安装失败，请手动安装: https://rustup.rs/"
            return 1
        }
    else
        error "已取消。请先安装 Rust/Cargo 后重试: https://rustup.rs/"
        return 1
    fi

    load_cargo_env
    if command_exists cargo; then
        log "cargo 已就绪: $(cargo --version 2>/dev/null)"
        return 0
    fi

    error "Rust 安装后 cargo 仍不可用，请执行: source ${HOME}/.cargo/env"
    return 1
}

install_rtk() {
    local force="${1:-false}"

    ensure_git
    ensure_cargo

    if command_exists rtk && [[ "$force" != "true" ]]; then
        log "RTK 已安装: $(rtk --version 2>/dev/null || echo '已安装')"
        return 0
    fi

    if [[ "$force" == "true" ]]; then
        log "安装/更新 RTK..."
        cargo install --git "$RTK_GIT_URL" --force
    else
        log "安装 RTK..."
        cargo install --git "$RTK_GIT_URL"
    fi

    load_cargo_env
    if command_exists rtk; then
        log "RTK 安装完成: $(rtk --version 2>/dev/null || echo '已安装')"
    else
        error "RTK 安装后命令仍不可用，请检查 ${HOME}/.cargo/bin 是否在 PATH 中"
        return 1
    fi
}

uninstall_rtk() {
    load_cargo_env

    if command_exists cargo; then
        if cargo uninstall rtk; then
            log "RTK 已卸载"
        else
            warn "cargo uninstall rtk 未成功，可能 RTK 未通过 cargo 安装或已卸载"
        fi
    elif [[ -f "${HOME}/.cargo/bin/rtk" ]]; then
        rm -f "${HOME}/.cargo/bin/rtk"
        log "已删除 ${HOME}/.cargo/bin/rtk"
    else
        log "未检测到 RTK，无需卸载"
    fi
}

status_rtk() {
    load_cargo_env
    if command_exists cargo; then
        cargo --version
    else
        echo "Cargo 未安装"
    fi

    if command_exists rtk; then
        rtk --version 2>/dev/null || echo "RTK 已安装"
    else
        echo "RTK 未安装"
    fi
}

case "$ACTION" in
    install)
        install_rtk false
        ;;
    update)
        install_rtk true
        ;;
    uninstall)
        uninstall_rtk
        ;;
    status|check)
        status_rtk
        ;;
    *)
        error "未知操作: $ACTION"
        echo "用法: $0 {install|update|uninstall|status}"
        exit 1
        ;;
esac

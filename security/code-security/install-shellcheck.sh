#!/usr/bin/env bash
#
# ShellCheck 一键安装配置脚本
# 支持 macOS / Linux，重复运行不会重复安装。

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly DEFAULT_VERSION="${SHELLCHECK_VERSION:-v0.11.0}"
readonly DEFAULT_DOWNLOAD_DIR="${SHELLCHECK_DOWNLOAD_DIR:-$HOME/Downloads}"
readonly DEFAULT_INSTALL_DIR="${SHELLCHECK_INSTALL_DIR:-/usr/local/bin}"

VERSION="$DEFAULT_VERSION"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
METHOD="auto"
FORCE=false
UNINSTALL=false

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_header() { echo -e "${CYAN}${BOLD}$*${NC}"; }

show_help() {
    cat <<EOF
用法: $0 [选项]

安装并配置 ShellCheck，支持 macOS 和 Linux。

选项:
  -h, --help              显示帮助
  -v, --version VERSION   ShellCheck 版本，默认: $DEFAULT_VERSION
  -d, --download-dir DIR  下载目录，默认: $DEFAULT_DOWNLOAD_DIR
  -i, --install-dir DIR   二进制安装目录，默认: $DEFAULT_INSTALL_DIR
  -m, --method METHOD     安装方式: auto|package|binary，默认: auto
  -f, --force             已安装时仍强制重装
  -u, --uninstall         卸载通过二进制方式安装的 shellcheck

环境变量:
  SHELLCHECK_VERSION      覆盖默认版本
  SHELLCHECK_DOWNLOAD_DIR 覆盖默认下载目录
  SHELLCHECK_INSTALL_DIR  覆盖默认安装目录

示例:
  $0
  $0 --method binary
  $0 -v v0.11.0 -d ~/Downloads
EOF
}

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*) echo "linux" ;;
        *) echo "unknown" ;;
    esac
}

detect_asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        armv6l|armv6*) echo "armv6hf" ;;
        riscv64) echo "riscv64" ;;
        *)
            log_error "暂不支持当前 CPU 架构: $(uname -m)"
            exit 1
            ;;
    esac
}

normalize_version() {
    local raw="$1"
    if [[ "$raw" == v* ]]; then
        printf '%s\n' "$raw"
    else
        printf 'v%s\n' "$raw"
    fi
}

version_without_v() {
    printf '%s\n' "${VERSION#v}"
}

find_adl() {
    if command -v adl >/dev/null 2>&1; then
        command -v adl
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local candidates=(
        "$script_dir/../../network/tools/adl"
        "$script_dir/../../../network/tools/adl"
    )

    local p
    for p in "${candidates[@]}"; do
        if [[ -x "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local output_dir output_name adl_cmd

    mkdir -p "$(dirname "$output")"

    if [[ -s "$output" && "$FORCE" != true ]]; then
        log_info "安装包已存在，跳过下载: $output"
        return 0
    fi

    output_dir="$(dirname "$output")"
    output_name="$(basename "$output")"

    if adl_cmd="$(find_adl 2>/dev/null)"; then
        log_info "使用 adl 下载: $output_name"
        if "$adl_cmd" "$url" "$output_dir" "$output_name"; then
            return 0
        fi
        log_warn "adl 下载失败，尝试常规下载工具。"
    fi

    if command -v curl >/dev/null 2>&1; then
        log_info "使用 curl 下载: $output_name"
        curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        log_info "使用 wget 下载: $output_name"
        wget -O "$output" "$url"
    else
        log_error "缺少下载工具，请安装 adl、curl 或 wget。"
        return 1
    fi
}

need_sudo_for_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        [[ ! -w "$dir" ]]
    else
        [[ ! -w "$(dirname "$dir")" ]]
    fi
}

run_install_cmd() {
    if need_sudo_for_dir "$INSTALL_DIR"; then
        sudo "$@"
    else
        "$@"
    fi
}

setup_shell_path() {
    if [[ "$INSTALL_DIR" == "/usr/local/bin" || "$INSTALL_DIR" == "/usr/bin" || "$INSTALL_DIR" == "/opt/homebrew/bin" ]]; then
        return 0
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        return 0
    fi

    local rc_file=""
    case "${SHELL:-}" in
        */zsh) rc_file="$HOME/.zshrc" ;;
        */bash) rc_file="$HOME/.bashrc" ;;
    esac

    [[ -n "$rc_file" ]] || return 0
    mkdir -p "$(dirname "$rc_file")"

    if ! grep -Fq "$INSTALL_DIR" "$rc_file" 2>/dev/null; then
        {
            echo ""
            echo "# ShellCheck"
            echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        } >> "$rc_file"
        log_info "已添加 PATH 到 $rc_file，当前终端可执行: source $rc_file"
    fi
}

installed_shellcheck_version() {
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck --version 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}'
    fi
}

verify_install() {
    if command -v shellcheck >/dev/null 2>&1; then
        log_ok "ShellCheck 可用: $(command -v shellcheck)"
        shellcheck --version | sed 's/^/  /'
        return 0
    fi

    if [[ -x "$INSTALL_DIR/shellcheck" ]]; then
        log_ok "ShellCheck 已安装: $INSTALL_DIR/shellcheck"
        "$INSTALL_DIR/shellcheck" --version | sed 's/^/  /'
        return 0
    fi

    log_error "ShellCheck 安装后仍不可用。"
    return 1
}

install_with_package_manager() {
    local os
    os="$(detect_os)"

    if [[ "$os" == "macos" ]]; then
        if ! command -v brew >/dev/null 2>&1; then
            log_warn "未检测到 Homebrew，跳过包管理器安装。"
            return 1
        fi
        log_info "使用 Homebrew 安装 ShellCheck..."
        brew list shellcheck >/dev/null 2>&1 || brew install shellcheck
        return 0
    fi

    if [[ "$os" != "linux" ]]; then
        log_error "当前系统不支持: $(uname -s)"
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        log_info "使用 apt 安装 ShellCheck..."
        sudo apt-get update
        sudo apt-get install -y shellcheck
    elif command -v dnf >/dev/null 2>&1; then
        log_info "使用 dnf 安装 ShellCheck..."
        sudo dnf install -y ShellCheck || sudo dnf install -y shellcheck
    elif command -v yum >/dev/null 2>&1; then
        log_info "使用 yum 安装 ShellCheck..."
        sudo yum install -y ShellCheck || sudo yum install -y shellcheck
    elif command -v pacman >/dev/null 2>&1; then
        log_info "使用 pacman 安装 ShellCheck..."
        sudo pacman -Sy --noconfirm shellcheck
    elif command -v zypper >/dev/null 2>&1; then
        log_info "使用 zypper 安装 ShellCheck..."
        sudo zypper --non-interactive install ShellCheck || sudo zypper --non-interactive install shellcheck
    else
        log_warn "未检测到支持的包管理器，跳过包管理器安装。"
        return 1
    fi
}

install_with_binary() {
    local os arch version_no_v asset archive url tmp_dir extracted shellcheck_bin
    os="$(detect_os)"
    arch="$(detect_asset_arch)"
    version_no_v="$(version_without_v)"

    if [[ "$os" != "macos" && "$os" != "linux" ]]; then
        log_error "二进制安装仅支持 macOS/Linux，当前系统: $(uname -s)"
        return 1
    fi

    asset="shellcheck-${VERSION}.${os}.${arch}.tar.xz"
    archive="$DOWNLOAD_DIR/$asset"
    url="https://github.com/koalaman/shellcheck/releases/download/${VERSION}/${asset}"

    log_info "下载目录: $DOWNLOAD_DIR"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载地址: $url"

    download_file "$url" "$archive"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    log_info "解压安装包..."
    tar -xJf "$archive" -C "$tmp_dir"

    extracted="$tmp_dir/shellcheck-${version_no_v}"
    shellcheck_bin="$extracted/shellcheck"
    if [[ ! -x "$shellcheck_bin" ]]; then
        shellcheck_bin="$(find "$tmp_dir" -type f -name shellcheck -perm -111 | head -n 1)"
    fi

    if [[ -z "$shellcheck_bin" || ! -x "$shellcheck_bin" ]]; then
        log_error "安装包中未找到 shellcheck 可执行文件。"
        return 1
    fi

    run_install_cmd mkdir -p "$INSTALL_DIR"
    run_install_cmd install -m 0755 "$shellcheck_bin" "$INSTALL_DIR/shellcheck"
    setup_shell_path
}

uninstall_binary() {
    local target="$INSTALL_DIR/shellcheck"
    if [[ ! -e "$target" ]]; then
        log_info "未发现二进制安装文件: $target"
        return 0
    fi

    log_info "删除: $target"
    if need_sudo_for_dir "$INSTALL_DIR"; then
        sudo rm -f "$target"
    else
        rm -f "$target"
    fi
    log_ok "已卸载二进制 ShellCheck。"
}

install_shellcheck() {
    local installed_version
    installed_version="$(installed_shellcheck_version || true)"

    if [[ -n "$installed_version" && "$FORCE" != true ]]; then
        log_ok "ShellCheck 已安装，跳过重复安装: $installed_version ($(command -v shellcheck))"
        return 0
    fi

    case "$METHOD" in
        auto)
            if install_with_package_manager; then
                return 0
            fi
            log_warn "包管理器安装不可用，切换为二进制安装。"
            install_with_binary
            ;;
        package)
            install_with_package_manager
            ;;
        binary)
            install_with_binary
            ;;
        *)
            log_error "未知安装方式: $METHOD"
            exit 1
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                [[ $# -ge 2 ]] || { log_error "$1 需要版本号"; exit 1; }
                VERSION="$(normalize_version "$2")"
                shift 2
                ;;
            --version=*)
                VERSION="$(normalize_version "${1#*=}")"
                shift
                ;;
            -d|--download-dir)
                [[ $# -ge 2 ]] || { log_error "$1 需要目录"; exit 1; }
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --download-dir=*)
                DOWNLOAD_DIR="${1#*=}"
                DOWNLOAD_DIR="${DOWNLOAD_DIR/#\~/$HOME}"
                shift
                ;;
            -i|--install-dir)
                [[ $# -ge 2 ]] || { log_error "$1 需要目录"; exit 1; }
                INSTALL_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            --install-dir=*)
                INSTALL_DIR="${1#*=}"
                INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
                shift
                ;;
            -m|--method)
                [[ $# -ge 2 ]] || { log_error "$1 需要安装方式"; exit 1; }
                METHOD="$2"
                shift 2
                ;;
            --method=*)
                METHOD="${1#*=}"
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -u|--uninstall)
                UNINSTALL=true
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    log_header "========================================"
    log_header "  ShellCheck 安装配置"
    log_header "========================================"

    if [[ "$(detect_os)" == "unknown" ]]; then
        log_error "仅支持 macOS 和 Linux。"
        exit 1
    fi

    if [[ "$UNINSTALL" == true ]]; then
        uninstall_binary
        return 0
    fi

    log_info "系统: $(detect_os) ($(uname -m))"
    log_info "安装方式: $METHOD"
    install_shellcheck
    verify_install
}

main "$@"

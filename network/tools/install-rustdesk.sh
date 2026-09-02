#!/usr/bin/env bash

set -euo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

SERVER_REPO="rustdesk/rustdesk-server"
CLIENT_REPO="rustdesk/rustdesk"
CONF_DIR="${RUSTDESK_CONF_DIR:-/etc/rustdesk}"
SERVER_TCP_PORTS="21114:21119"
SERVER_UDP_PORTS="21116"

MODE="auto"
ACTION="install"
INSTALL_DIR=""
DOWNLOAD_DIR=""
VERSION=""
SERVER_HOST="${RUSTDESK_SERVER_HOST:-}"
SERVER_KEY="${RUSTDESK_SERVER_KEY:-}"
RELAY_SERVER="${RUSTDESK_RELAY_SERVER:-}"
CLIENT_PASSWORD=""
PASSWORD_SET=0
YES=0
NO_START=0
KEEP_DOWNLOAD=1

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

home_for_user() {
    local user="$1"
    local home=""
    if is_macos && command -v dscl >/dev/null 2>&1; then
        home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
    [[ -n "$home" ]] || home="$(eval echo "~${user}")"
    printf '%s\n' "$home"
}

default_download_dir() {
    printf '%s/Downloads\n' "$(home_for_user "$(target_user)")"
}

default_install_dir() {
    if is_macos; then
        printf '%s\n' "/Applications"
    else
        printf '%s\n' "/usr/local/rustdesk-server"
    fi
}

expand_path() {
    local path="$1"
    path="${path/#\~/$HOME}"
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    printf '%s\n' "${path%/}"
}

run_as_target_user() {
    local user
    user="$(target_user)"
    if [[ "$EUID" -eq 0 && "$user" != "root" ]]; then
        sudo -u "$user" "$@"
    else
        "$@"
    fi
}

remove_path() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ "$EUID" -eq 0 || ( -w "$(dirname "$path")" && -w "$path" ) ]]; then
        rm -rf -- "$path"
        return 0
    fi

    command_exists sudo || {
        log_error "删除需要管理员权限，但未找到 sudo: $path"
        return 1
    }
    log_info "删除需要管理员权限: $path"
    log_info "请输入管理员密码完成提权（输入时终端不会显示字符）。"
    if ! sudo -v; then
        log_error "管理员授权失败，未删除: $path"
        return 1
    fi
    sudo rm -rf -- "$path"
}

need_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "该操作需要 root 权限，请使用 sudo 运行。"
        exit 1
    fi
}

show_help() {
    cat <<EOF
RustDesk 一键安装配置和卸载脚本

用法:
  $0 [选项]

操作:
  -i, --install             安装或更新（默认）
  -u, --uninstall           卸载
  -S, --status              查看状态
  -l, --list-versions       显示最新 5 个稳定版本

组件:
  -s, --server              Linux 服务端 hbbs/hbbr
  -c, --client              macOS/Linux 客户端
  -a, --all                 Linux 同时安装服务端和客户端；macOS 等同客户端

参数:
  -d, --install-dir DIR     安装目录
                            Linux 服务端默认: /usr/local/rustdesk-server
                            macOS 客户端默认: /Applications
  -D, --download-dir DIR    下载目录（默认: 当前用户 ~/Downloads）
  -v, --version VERSION     指定版本 tag，如 1.4.3；未指定时显示最新 5 个稳定版本
  -p, --password PASSWORD   安装后设置固定访问密码
      --server-host HOST    配置客户端使用自建服务器 ID server
  -r, --relay-server HOST   配置客户端使用自建中继服务器
      --server-key KEY      配置客户端使用自建服务器 key
  -y, --yes                 非交互确认，默认选择更新和最新版
      --no-start            安装后不自动启动客户端
  -h, --help                显示帮助

下载:
  - 检测到 adl 时优先使用 adl 下载。
  - 下载文件已存在且非空时直接复用，不重复下载。

示例:
  $0 --client
  $0 --client --password '<fixed-password>'
  sudo $0 --server --install-dir /opt/rustdesk-server
  sudo $0 --all --download-dir /var/cache/rustdesk
  $0 --client --server-host 1.2.3.4 --server-key '<public-key>'
  sudo $0 --uninstall --server
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -i|--install) ACTION="install"; shift ;;
            -u|--uninstall) ACTION="uninstall"; shift ;;
            -S|--status) ACTION="status"; shift ;;
            -l|--list-versions) ACTION="list_versions"; shift ;;
            -s|--server) MODE="server"; shift ;;
            -c|--client) MODE="client"; shift ;;
            -a|--all) MODE="all"; shift ;;
            -d|--install-dir)
                [[ $# -gt 1 ]] || { log_error "$1 需要目录参数"; exit 1; }
                INSTALL_DIR="$(expand_path "$2")"; shift 2 ;;
            --install-dir=*) INSTALL_DIR="$(expand_path "${1#*=}")"; shift ;;
            -D|--download-dir)
                [[ $# -gt 1 ]] || { log_error "$1 需要目录参数"; exit 1; }
                DOWNLOAD_DIR="$(expand_path "$2")"; shift 2 ;;
            --download-dir=*) DOWNLOAD_DIR="$(expand_path "${1#*=}")"; shift ;;
            -v|--version)
                [[ $# -gt 1 ]] || { log_error "$1 需要版本参数"; exit 1; }
                VERSION="${2#v}"; shift 2 ;;
            --version=*) VERSION="${1#*=}"; VERSION="${VERSION#v}"; shift ;;
            -p|--password)
                [[ $# -gt 1 ]] || { log_error "$1 需要密码参数"; exit 1; }
                CLIENT_PASSWORD="$2"; PASSWORD_SET=1; shift 2 ;;
            --password=*) CLIENT_PASSWORD="${1#*=}"; PASSWORD_SET=1; shift ;;
            --server-host)
                [[ $# -gt 1 ]] || { log_error "$1 需要 HOST 参数"; exit 1; }
                SERVER_HOST="$2"; shift 2 ;;
            --server-host=*) SERVER_HOST="${1#*=}"; shift ;;
            -r|--relay-server)
                [[ $# -gt 1 ]] || { log_error "$1 需要 HOST 参数"; exit 1; }
                RELAY_SERVER="$2"; shift 2 ;;
            --relay-server=*) RELAY_SERVER="${1#*=}"; shift ;;
            --server-key)
                [[ $# -gt 1 ]] || { log_error "$1 需要 KEY 参数"; exit 1; }
                SERVER_KEY="$2"; shift 2 ;;
            --server-key=*) SERVER_KEY="${1#*=}"; shift ;;
            -y|--yes) YES=1; shift ;;
            --no-start) NO_START=1; shift ;;
            --no-keep-download) KEEP_DOWNLOAD=0; shift ;;
            *) log_error "未知参数: $1"; show_help; exit 1 ;;
        esac
    done

    DOWNLOAD_DIR="${DOWNLOAD_DIR:-$(default_download_dir)}"
    INSTALL_DIR="${INSTALL_DIR:-$(default_install_dir)}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_with_timeout() {
    local seconds="$1"
    shift
    if command_exists timeout; then
        timeout "$seconds" "$@"
    elif command_exists gtimeout; then
        gtimeout "$seconds" "$@"
    elif [[ -x /usr/bin/perl ]]; then
        /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
    else
        "$@"
    fi
}

client_executable() {
    local app
    if is_macos; then
        app="$INSTALL_DIR/RustDesk.app/Contents/MacOS/RustDesk"
        [[ -x "$app" ]] || app="/Applications/RustDesk.app/Contents/MacOS/RustDesk"
        [[ -x "$app" ]] && printf '%s\n' "$app"
    elif command_exists rustdesk; then
        command -v rustdesk
    elif [[ -x "$INSTALL_DIR/rustdesk" ]]; then
        printf '%s\n' "$INSTALL_DIR/rustdesk"
    fi
}

run_client_user_cli() {
    local seconds="$1"
    shift
    local binary user
    binary="$(client_executable)"
    [[ -n "$binary" ]] || return 1
    user="$(target_user)"
    if [[ "$EUID" -eq 0 && "$user" != "root" ]]; then
        run_with_timeout "$seconds" sudo -u "$user" "$binary" "$@"
    else
        run_with_timeout "$seconds" "$binary" "$@"
    fi
}

run_client_admin_cli() {
    local seconds="$1"
    shift
    local binary
    binary="$(client_executable)"
    [[ -n "$binary" ]] || return 1
    if [[ "$EUID" -eq 0 ]]; then
        run_with_timeout "$seconds" "$binary" "$@"
    else
        command_exists sudo || return 1
        run_with_timeout "$seconds" sudo "$binary" "$@"
    fi
}

generate_client_password() {
    local random_hex
    random_hex="$(od -An -N8 -tx1 /dev/urandom | tr -d '[:space:]')"
    printf 'Rd%s\n' "$random_hex"
}

find_adl() {
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$(command -v adl 2>/dev/null || true)" \
        "$script_dir/adl" \
        "$script_dir/../tools/adl" \
        "/opt/homebrew/bin/adl" \
        "/usr/local/bin/adl" \
        "$HOME/.local/bin/adl"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        "$candidate" --help >/dev/null 2>&1 || true
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local desc="${3:-文件}"
    local adl_path output_dir output_name

    mkdir -p "$(dirname "$output")"
    if [[ -s "$output" ]]; then
        log_info "已存在，跳过下载: $output"
        return 0
    fi

    output_dir="$(dirname "$output")"
    output_name="$(basename "$output")"

    if adl_path="$(find_adl)"; then
        log_info "使用 adl 下载 ${desc}: $output_name"
        if "$adl_path" "$url" "$output_dir" "$output_name" && [[ -s "$output" ]]; then
            return 0
        fi
        log_warn "adl 下载失败，回退 curl/wget。"
        rm -f "$output"
    fi

    if command_exists curl; then
        log_info "使用 curl 下载 ${desc}: $output_name"
        curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url"
    elif command_exists wget; then
        log_info "使用 wget 下载 ${desc}: $output_name"
        wget -O "$output" "$url"
    else
        log_error "未找到下载工具，请安装 adl、curl 或 wget。"
        return 1
    fi

    [[ -s "$output" ]]
}

github_api() {
    local path="$1"
    curl -fsSL --retry 3 --connect-timeout 20 "https://api.github.com/repos/${path}"
}

release_json() {
    local repo="$1"
    local version="${2:-}"
    if [[ -n "$version" ]]; then
        github_api "${repo}/releases/tags/${version}" || github_api "${repo}/releases/tags/v${version}"
    else
        github_api "${repo}/releases/latest"
    fi
}

latest_versions() {
    local repo="$1"
    github_api "${repo}/releases?per_page=30" \
        | grep -E '"tag_name"[[:space:]]*:' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | awk 'count < 5 { print; count++ }'
}

choose_version() {
    local repo="$1"
    local current="${2:-}"
    local versions=()
    local line choice

    if [[ -n "$VERSION" ]]; then
        printf '%s\n' "$VERSION"
        return 0
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] && versions+=("${line#v}")
    done < <(latest_versions "$repo")

    [[ ${#versions[@]} -gt 0 ]] || {
        log_error "无法获取 ${repo} 版本列表"
        return 1
    }

    echo "" >&2
    echo -e "${CYAN}${repo} 最新 5 个稳定版本:${NC}" >&2
    local i
    for i in "${!versions[@]}"; do
        if [[ -n "$current" && "$current" == "${versions[$i]}" ]]; then
            printf '  %d) %s (当前)\n' "$((i + 1))" "${versions[$i]}" >&2
        else
            printf '  %d) %s\n' "$((i + 1))" "${versions[$i]}" >&2
        fi
    done

    if [[ "$YES" -eq 1 || ! -t 0 ]]; then
        printf '%s\n' "${versions[0]}"
        return 0
    fi

    read -r -p "请选择版本 [默认 1 最新稳定版]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#versions[@]}" ]]; then
        printf '%s\n' "${versions[$((choice - 1))]}"
    else
        log_error "无效版本选择: $choice"
        return 1
    fi
}

asset_urls() {
    local repo="$1"
    local version="$2"
    release_json "$repo" "$version" \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

find_asset_url() {
    local repo="$1"
    local version="$2"
    local include="$3"
    local exclude="${4:-}"
    local url
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        if printf '%s\n' "$url" | grep -Eiq "$include"; then
            if [[ -z "$exclude" ]] || ! printf '%s\n' "$url" | grep -Eiq "$exclude"; then
                printf '%s\n' "$url"
                return 0
            fi
        fi
    done < <(asset_urls "$repo" "$version")
    log_error "未找到匹配资源: ${repo} ${version} ${include}"
    return 1
}

normalize_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        i386|i686) echo "i386" ;;
        *) uname -m ;;
    esac
}

server_installed() {
    is_linux || return 1
    [[ -x "$INSTALL_DIR/hbbs" && -x "$INSTALL_DIR/hbbr" ]] && return 0
    command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^rustdesk-hbbs\.service' && return 0
    return 1
}

client_installed() {
    if is_macos; then
        if [[ -d "$INSTALL_DIR/RustDesk.app" ]]; then
            return 0
        fi
        [[ "$INSTALL_DIR" == "/Applications" && -d "/Applications/RustDesk.app" ]]
    elif is_linux; then
        command_exists rustdesk \
            || { command_exists dpkg && dpkg -l 2>/dev/null | grep -q '^ii[[:space:]]*rustdesk'; } \
            || { command_exists rpm && rpm -q rustdesk >/dev/null 2>&1; } \
            || [[ -x "$INSTALL_DIR/rustdesk" || -x "/usr/local/bin/rustdesk" ]]
    else
        return 1
    fi
}

installed_server_version() {
    [[ -x "$INSTALL_DIR/hbbs" ]] && "$INSTALL_DIR/hbbs" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1 || true
}

installed_client_version() {
    if is_macos; then
        local app="$INSTALL_DIR/RustDesk.app"
        [[ -d "$app" ]] || {
            [[ "$INSTALL_DIR" == "/Applications" ]] && app="/Applications/RustDesk.app"
        }
        [[ -d "$app" ]] || return 0
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true
    elif command_exists rustdesk; then
        rustdesk --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1 || true
    fi
}

confirm_installed_action() {
    local component="$1"
    local current="${2:-}"
    local choice=""

    if [[ -n "$current" ]]; then
        log_warn "检测到 RustDesk ${component} 已安装（当前版本: ${current}）" >&2
    else
        log_warn "检测到 RustDesk ${component} 已安装" >&2
    fi
    if [[ "$YES" -eq 1 || ! -t 0 ]]; then
        log_info "默认执行更新。" >&2
        echo "update"
        return 0
    fi

    read -r -p "请选择: [U]更新(默认) / [R]卸载 / [S]跳过: " choice
    case "${choice:-u}" in
        u|U|update) echo "update" ;;
        r|R|remove|uninstall) echo "uninstall" ;;
        s|S|skip) echo "skip" ;;
        *) log_error "无效选择: $choice"; return 1 ;;
    esac
}

server_asset_url() {
    local version="$1"
    case "$(normalize_arch)" in
        amd64) find_asset_url "$SERVER_REPO" "$version" 'rustdesk-server-linux-amd64\.zip$' ;;
        arm64) find_asset_url "$SERVER_REPO" "$version" 'rustdesk-server-linux-(arm64v8|arm64|aarch64)\.zip$' ;;
        armv7) find_asset_url "$SERVER_REPO" "$version" 'rustdesk-server-linux-armv7\.zip$' ;;
        i386) find_asset_url "$SERVER_REPO" "$version" 'rustdesk-server-linux-i386\.zip$' ;;
        *) log_error "不支持的服务端架构: $(uname -m)"; return 1 ;;
    esac
}

linux_client_asset_url() {
    local version="$1"
    local arch pkg
    arch="$(normalize_arch)"
    if command_exists apt-get && command_exists dpkg; then
        pkg="deb"
    elif command_exists dnf || command_exists yum || command_exists zypper; then
        pkg="rpm"
    else
        pkg="appimage"
    fi

    case "${pkg}:${arch}" in
        deb:amd64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-x86_64\.deb$' ;;
        deb:arm64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-aarch64\.deb$' ;;
        deb:armv7) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-armv7.*\.deb$' ;;
        rpm:amd64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-0\.x86_64\.rpm$' 'suse' ;;
        rpm:arm64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-0\.aarch64\.rpm$' 'suse' ;;
        appimage:amd64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-x86_64\.AppImage$' ;;
        appimage:arm64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-aarch64\.AppImage$' ;;
        *) log_error "不支持的 Linux 客户端包类型或架构: ${pkg}/${arch}"; return 1 ;;
    esac
}

macos_client_asset_url() {
    local version="$1"
    case "$(normalize_arch)" in
        arm64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-aarch64\.dmg$' ;;
        amd64) find_asset_url "$CLIENT_REPO" "$version" 'rustdesk-[^/]+-x86_64\.dmg$' ;;
        *) log_error "不支持的 macOS 架构: $(uname -m)"; return 1 ;;
    esac
}

public_ip() {
    local api ip
    for api in https://api.ipify.org https://icanhazip.com https://checkip.amazonaws.com; do
        ip="$(curl -fsSL --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

configure_firewall() {
    is_linux || return 0
    if command_exists ufw && ufw status >/dev/null 2>&1; then
        ufw allow "${SERVER_TCP_PORTS}/tcp" >/dev/null 2>&1 || true
        ufw allow "${SERVER_UDP_PORTS}/udp" >/dev/null 2>&1 || true
    fi
    if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=21114-21119/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=21116/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

write_server_services() {
    local host="$1"
    cat > /etc/systemd/system/rustdesk-hbbs.service <<EOF
[Unit]
Description=RustDesk Signal Server (hbbs)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/hbbs${host:+ -r ${host}}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/rustdesk-hbbr.service <<EOF
[Unit]
Description=RustDesk Relay Server (hbbr)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/hbbr
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_server() {
    is_linux || { log_error "RustDesk 服务端安装仅支持 Linux。"; return 1; }
    need_root

    local current action version url archive host key
    current="$(installed_server_version)"
    if server_installed; then
        action="$(confirm_installed_action "服务端" "$current")"
        case "$action" in
            uninstall) uninstall_server; return 0 ;;
            skip) return 0 ;;
        esac
        systemctl stop rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
    fi

    version="$(choose_version "$SERVER_REPO" "$current")"
    url="$(server_asset_url "$version")"
    archive="$DOWNLOAD_DIR/$(basename "$url")"

    log_info "安装/更新 RustDesk 服务端版本: ${version}"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载目录: $DOWNLOAD_DIR"
    download_file "$url" "$archive" "RustDesk 服务端"

    mkdir -p "$INSTALL_DIR"
    unzip -o "$archive" -d "$INSTALL_DIR/.extract" >/dev/null
    local bin_dir hbbs_path
    hbbs_path="$(find "$INSTALL_DIR/.extract" -type f -name hbbs -print -quit 2>/dev/null || true)"
    bin_dir=""
    [[ -n "$hbbs_path" ]] && bin_dir="$(dirname "$hbbs_path")"
    [[ -n "$bin_dir" && -f "$bin_dir/hbbr" ]] || {
        log_error "安装包中未找到 hbbs/hbbr"
        rm -rf "$INSTALL_DIR/.extract"
        return 1
    }
    cp -f "$bin_dir/hbbs" "$bin_dir/hbbr" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbr"
    rm -rf "$INSTALL_DIR/.extract"

    mkdir -p "$CONF_DIR"
    host="${SERVER_HOST:-$(public_ip || true)}"
    write_server_services "$host"
    systemctl daemon-reload
    systemctl enable rustdesk-hbbs rustdesk-hbbr >/dev/null
    systemctl restart rustdesk-hbbs rustdesk-hbbr
    configure_firewall

    key=""
    [[ -f "$INSTALL_DIR/id_ed25519.pub" ]] && key="$(cat "$INSTALL_DIR/id_ed25519.pub")"
    cat > "$CONF_DIR/server.conf" <<EOF
INSTALL_DIR=${INSTALL_DIR}
PUBLIC_IP=${host}
VERSION=${version}
EOF
    [[ -n "$key" ]] && cp -f "$INSTALL_DIR/id_ed25519.pub" "$CONF_DIR/id_ed25519.pub"

    echo ""
    echo -e "${GREEN}RustDesk 服务端安装完成${NC}"
    echo "  ID 服务器: ${host:-<请手动配置公网 IP 或域名>}"
    echo "  中继服务器: ${host:-<host>}:21117"
    echo "  Key: ${key:-<首次启动后查看 $INSTALL_DIR/id_ed25519.pub>}"
}

install_linux_client() {
    need_root

    local current action version url pkg
    current="$(installed_client_version)"
    if client_installed; then
        action="$(confirm_installed_action "客户端" "$current")"
        case "$action" in
            uninstall) uninstall_linux_client; return 0 ;;
            skip) return 0 ;;
        esac
    fi

    version="$(choose_version "$CLIENT_REPO" "$current")"
    url="$(linux_client_asset_url "$version")"
    pkg="$DOWNLOAD_DIR/$(basename "$url")"
    log_info "安装/更新 RustDesk Linux 客户端版本: ${version}"
    download_file "$url" "$pkg" "RustDesk Linux 客户端"

    case "$pkg" in
        *.deb)
            apt-get update -qq
            apt-get install -y "$pkg"
            ;;
        *.rpm)
            if command_exists dnf; then dnf install -y "$pkg"
            elif command_exists yum; then yum install -y "$pkg"
            elif command_exists zypper; then zypper --non-interactive install "$pkg"
            else rpm -Uvh "$pkg"
            fi
            ;;
        *.AppImage)
            mkdir -p "$INSTALL_DIR"
            install -m 755 "$pkg" "$INSTALL_DIR/rustdesk"
            ln -sfn "$INSTALL_DIR/rustdesk" /usr/local/bin/rustdesk
            ;;
        *) log_error "未知 Linux 客户端包: $pkg"; return 1 ;;
    esac

    configure_client "$SERVER_HOST" "$SERVER_KEY" "$RELAY_SERVER"
    audit_client_server_config
    start_client || true
    finish_client_setup
}

copy_app_to_dir() {
    local source_app="$1"
    local target_dir="$2"
    local target_app="$target_dir/RustDesk.app"
    mkdir -p "$target_dir"
    if [[ -e "$target_app" ]]; then
        remove_path "$target_app"
    fi
    if [[ -w "$target_dir" ]]; then
        ditto "$source_app" "$target_app"
    else
        sudo ditto "$source_app" "$target_app"
    fi
    sudo xattr -cr "$target_app" 2>/dev/null || xattr -cr "$target_app" 2>/dev/null || true
}

install_macos_client() {
    local current action version url dmg mount_output mount_point app
    current="$(installed_client_version)"
    if client_installed; then
        action="$(confirm_installed_action "客户端" "$current")"
        case "$action" in
            uninstall) uninstall_macos_client; return 0 ;;
            skip) return 0 ;;
        esac
    fi

    version="$(choose_version "$CLIENT_REPO" "$current")"
    url="$(macos_client_asset_url "$version")"
    dmg="$DOWNLOAD_DIR/$(basename "$url")"
    log_info "安装/更新 RustDesk macOS 客户端版本: ${version}"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载目录: $DOWNLOAD_DIR"
    download_file "$url" "$dmg" "RustDesk macOS DMG"

    mount_output="$(hdiutil attach "$dmg" -nobrowse 2>&1)"
    mount_point="$(printf '%s\n' "$mount_output" | sed -n 's|^/dev/.*\(/Volumes/.*\)$|\1|p' | head -1)"
    [[ -n "$mount_point" && -d "$mount_point" ]] || {
        log_error "DMG 挂载失败: $mount_output"
        return 1
    }
    trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true' RETURN

    app="$(find "$mount_point" -maxdepth 1 -name '*.app' -type d | head -1)"
    [[ -n "$app" ]] || { log_error "DMG 中未找到 .app"; return 1; }
    copy_app_to_dir "$app" "$INSTALL_DIR"
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    trap - RETURN

    ensure_macos_client_service
    configure_client "$SERVER_HOST" "$SERVER_KEY" "$RELAY_SERVER"
    audit_client_server_config
    start_client || true
    finish_client_setup
}

configure_client() {
    local host="${1:-}"
    local key="${2:-}"
    local relay="${3:-}"
    [[ -n "$host" || -n "$key" || -n "$relay" ]] || return 0

    if is_macos || is_linux; then
        local actual_host actual_relay actual_key
        [[ -n "$host" && -z "$relay" ]] && relay="${host}:21117"
        [[ -n "$host" ]] && run_client_admin_cli 15 --option custom-rendezvous-server "$host" >/dev/null
        [[ -n "$relay" ]] && run_client_admin_cli 15 --option relay-server "$relay" >/dev/null
        [[ -n "$key" ]] && run_client_admin_cli 15 --option key "$key" >/dev/null

        actual_host="$(run_client_admin_cli 15 --option custom-rendezvous-server 2>/dev/null || true)"
        actual_relay="$(run_client_admin_cli 15 --option relay-server 2>/dev/null || true)"
        actual_key="$(run_client_admin_cli 15 --option key 2>/dev/null || true)"
        if [[ -n "$host" && "$actual_host" != "$host" ]] || [[ -n "$relay" && "$actual_relay" != "$relay" ]]; then
            log_error "RustDesk 自建服务器配置校验失败。"
            return 1
        fi
        if [[ -n "$key" && "$actual_key" != "$key" ]]; then
            log_error "RustDesk 自建服务器密钥配置校验失败。"
            return 1
        fi
        log_info "RustDesk 自建服务器配置已生效: ${host:-<沿用现有服务器>}"
    fi
}

ensure_macos_client_service() {
    is_macos || return 0
    log_info "正在安装或更新 RustDesk 后台服务..."
    run_client_admin_cli 30 --install-service >/dev/null 2>&1 || {
        log_error "RustDesk 后台服务安装失败。"
        return 1
    }
    sleep 2
}

parse_server_endpoint() {
    local endpoint="$1"
    local default_port="$2"
    endpoint="${endpoint#*://}"
    endpoint="${endpoint%%/*}"
    ENDPOINT_HOST="$endpoint"
    ENDPOINT_PORT="$default_port"

    if [[ "$endpoint" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        [[ -n "${BASH_REMATCH[3]:-}" ]] && ENDPOINT_PORT="${BASH_REMATCH[3]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        ENDPOINT_PORT="${BASH_REMATCH[2]}"
    fi
}

check_tcp_endpoint() {
    local host="$1"
    local port="$2"
    if command_exists python3; then
        python3 - "$host" "$port" <<'PY'
import socket
import sys

try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3):
        pass
except OSError:
    sys.exit(1)
PY
    elif command_exists nc; then
        if is_macos; then
            nc -z -G 3 "$host" "$port" >/dev/null 2>&1
        else
            nc -z -w 3 "$host" "$port" >/dev/null 2>&1
        fi
    else
        return 2
    fi
}

clear_client_server_config() {
    run_client_admin_cli 15 --option custom-rendezvous-server "" >/dev/null
    run_client_admin_cli 15 --option relay-server "" >/dev/null
    run_client_admin_cli 15 --option key "" >/dev/null

    local id_server relay_server server_key
    id_server="$(run_client_admin_cli 15 --option custom-rendezvous-server 2>/dev/null || true)"
    relay_server="$(run_client_admin_cli 15 --option relay-server 2>/dev/null || true)"
    server_key="$(run_client_admin_cli 15 --option key 2>/dev/null || true)"
    if [[ -n "$id_server" || -n "$relay_server" || -n "$server_key" ]]; then
        log_error "RustDesk 自建服务器配置清除失败。"
        return 1
    fi
    log_info "已清除不可达的自建 ID/中继服务器配置，将使用 RustDesk 公共服务器。"
}

prompt_missing_client_server_config() {
    local id_server="$1"
    local relay_server="$2"
    local answer server_key default_relay

    [[ -t 0 && "$YES" -eq 0 ]] || return 0
    if [[ -z "$id_server" && -z "$relay_server" ]]; then
        read -r -p "当前未配置自建 ID/中继服务器，是否现在配置？(y/N): " answer
        [[ "${answer:-n}" =~ ^[Yy]$ ]] || return 0

        read -r -p "请输入 ID 服务器（域名/IP，可含端口）: " id_server
        [[ -n "$id_server" ]] || {
            log_warn "ID 服务器为空，保持公共服务器配置。"
            return 0
        }
        parse_server_endpoint "$id_server" 21116
        if [[ "$ENDPOINT_HOST" == *:* ]]; then
            default_relay="[${ENDPOINT_HOST}]:21117"
        else
            default_relay="${ENDPOINT_HOST}:21117"
        fi
        read -r -p "请输入中继服务器 [默认 ${default_relay}]: " relay_server
        relay_server="${relay_server:-$default_relay}"
        read -r -s -p "请输入服务器公钥（可留空）: " server_key
        echo ""
        configure_client "$id_server" "$server_key" "$relay_server"
    elif [[ -n "$id_server" && -z "$relay_server" ]]; then
        read -r -p "当前未配置中继服务器，是否现在配置？(y/N): " answer
        [[ "${answer:-n}" =~ ^[Yy]$ ]] || return 0

        parse_server_endpoint "$id_server" 21116
        if [[ "$ENDPOINT_HOST" == *:* ]]; then
            default_relay="[${ENDPOINT_HOST}]:21117"
        else
            default_relay="${ENDPOINT_HOST}:21117"
        fi
        read -r -p "请输入中继服务器 [默认 ${default_relay}]: " relay_server
        relay_server="${relay_server:-$default_relay}"
        configure_client "" "" "$relay_server"
    fi
}

audit_client_server_config() {
    local id_server relay_server endpoint status unreachable=0 unknown=0 answer
    id_server="$(run_client_admin_cli 15 --option custom-rendezvous-server 2>/dev/null || true)"
    relay_server="$(run_client_admin_cli 15 --option relay-server 2>/dev/null || true)"

    prompt_missing_client_server_config "$id_server" "$relay_server"
    id_server="$(run_client_admin_cli 15 --option custom-rendezvous-server 2>/dev/null || true)"
    relay_server="$(run_client_admin_cli 15 --option relay-server 2>/dev/null || true)"

    echo ""
    echo -e "${CYAN}RustDesk 服务器配置${NC}"
    if [[ -z "$id_server" && -z "$relay_server" ]]; then
        echo "  模式: 公共服务器（未配置自建中继）"
        return 0
    fi

    echo "  ID 服务器: ${id_server:-<未配置>}"
    echo "  中继服务器: ${relay_server:-<未配置>}"

    if [[ -n "$id_server" ]]; then
        parse_server_endpoint "$id_server" 21116
        endpoint="${ENDPOINT_HOST}:${ENDPOINT_PORT}"
        status=0
        check_tcp_endpoint "$ENDPOINT_HOST" "$ENDPOINT_PORT" || status=$?
        case "$status" in
            0) echo "  ID 服务器可达性: 可达 ($endpoint)" ;;
            1) echo "  ID 服务器可达性: 不可达 ($endpoint)"; unreachable=1 ;;
            *) echo "  ID 服务器可达性: 未检测（缺少 python3/nc）"; unknown=1 ;;
        esac
    fi

    if [[ -n "$relay_server" ]]; then
        parse_server_endpoint "$relay_server" 21117
        endpoint="${ENDPOINT_HOST}:${ENDPOINT_PORT}"
        status=0
        check_tcp_endpoint "$ENDPOINT_HOST" "$ENDPOINT_PORT" || status=$?
        case "$status" in
            0) echo "  中继服务器可达性: 可达 ($endpoint)" ;;
            1) echo "  中继服务器可达性: 不可达 ($endpoint)"; unreachable=1 ;;
            *) echo "  中继服务器可达性: 未检测（缺少 python3/nc）"; unknown=1 ;;
        esac
    fi

    [[ "$unknown" -eq 0 ]] || log_warn "无法完成可达性检测，保留现有服务器配置。"
    [[ "$unreachable" -eq 1 ]] || return 0

    log_warn "检测到自建 ID/中继服务器不可达，保留该配置会导致 RustDesk 无法连接。"
    if [[ "$YES" -eq 1 || ! -t 0 ]]; then
        answer="y"
    else
        read -r -p "是否清除不可达配置并恢复公共服务器？(Y/n): " answer
    fi
    if [[ "${answer:-y}" =~ ^[Yy]$ ]]; then
        clear_client_server_config
    else
        log_warn "已保留不可达的自建服务器配置。"
    fi
}

select_client_password() {
    local answer entered confirm
    if [[ "$PASSWORD_SET" -eq 1 ]]; then
        [[ ${#CLIENT_PASSWORD} -ge 6 ]] || {
            log_error "固定访问密码至少需要 6 个字符。"
            return 2
        }
        return 0
    fi

    [[ -t 0 && "$YES" -eq 0 ]] || return 1
    read -r -p "是否配置或重置固定访问密码？(y/N): " answer
    [[ "${answer:-n}" =~ ^[Yy]$ ]] || return 1

    read -r -s -p "请输入固定访问密码（至少 6 位，留空自动生成）: " entered
    echo ""
    if [[ -z "$entered" ]]; then
        CLIENT_PASSWORD="$(generate_client_password)"
        PASSWORD_SET=1
        return 0
    fi
    [[ ${#entered} -ge 6 ]] || {
        log_error "固定访问密码至少需要 6 个字符。"
        return 2
    }
    read -r -s -p "请再次输入固定访问密码: " confirm
    echo ""
    [[ "$entered" == "$confirm" ]] || {
        log_error "两次输入的密码不一致。"
        return 2
    }
    CLIENT_PASSWORD="$entered"
    PASSWORD_SET=1
}

configure_client_password() {
    local output approve_mode verification_method

    output="$(run_client_admin_cli 15 --password "$CLIENT_PASSWORD" 2>&1)" || {
        log_error "固定访问密码设置失败: ${output:-命令执行失败或超时}"
        return 1
    }
    if [[ "$output" != *"Done!"* ]]; then
        log_error "固定访问密码设置失败: ${output:-RustDesk 未确认设置成功}"
        return 1
    fi

    run_client_admin_cli 15 --option approve-mode password >/dev/null 2>&1 || {
        log_error "无法启用 RustDesk 密码验证模式。"
        return 1
    }
    run_client_admin_cli 15 --option verification-method use-permanent-password >/dev/null 2>&1 || {
        log_error "无法启用 RustDesk 固定密码验证。"
        return 1
    }

    approve_mode="$(run_client_admin_cli 15 --option approve-mode 2>/dev/null || true)"
    verification_method="$(run_client_admin_cli 15 --option verification-method 2>/dev/null || true)"
    if [[ "$approve_mode" != "password" || "$verification_method" != "use-permanent-password" ]]; then
        log_error "RustDesk 密码验证配置校验失败: approve-mode=${approve_mode:-<空>}, verification-method=${verification_method:-<空>}"
        return 1
    fi
    log_info "已启用固定密码验证模式。"
}

get_client_id() {
    local output id attempt
    for attempt in 1 2 3 4 5; do
        output="$(run_client_user_cli 8 --get-id 2>/dev/null || true)"
        id="$(printf '%s\n' "$output" | tr -cd '0-9\n' | awk 'length($0) >= 6 { print; exit }')"
        if [[ -n "$id" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
        sleep 2
    done
    return 1
}

finish_client_setup() {
    local password_configured=0 client_id="" selection_status=0
    select_client_password || selection_status=$?
    if [[ "$selection_status" -eq 2 ]]; then
        return 1
    elif [[ "$selection_status" -eq 0 ]]; then
        configure_client_password
        password_configured=1
    fi

    client_id="$(get_client_id || true)"
    echo ""
    echo -e "${CYAN}RustDesk 客户端信息${NC}"
    if [[ -n "$client_id" ]]; then
        echo "  ID: $client_id"
    else
        echo "  ID: 暂未获取，请启动 RustDesk 后查看"
    fi
    if [[ "$password_configured" -eq 1 ]]; then
        echo "  固定访问密码: $CLIENT_PASSWORD"
        log_warn "密码仅在本次设置后显示，请妥善保存。"
    else
        echo "  固定访问密码: 未修改（已有密码无法读取明文）"
    fi
}

start_client() {
    [[ "$NO_START" -eq 0 ]] || return 0
    if is_macos; then
        run_as_target_user open "$INSTALL_DIR/RustDesk.app" 2>/dev/null || run_as_target_user open /Applications/RustDesk.app 2>/dev/null || true
    elif is_linux && command_exists rustdesk; then
        [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 0
        local user="${SUDO_USER:-$(id -un)}"
        if [[ "$EUID" -eq 0 && "$user" != "root" ]]; then
            sudo -u "$user" env DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" nohup rustdesk >/tmp/rustdesk.log 2>&1 &
        else
            nohup rustdesk >/tmp/rustdesk.log 2>&1 &
        fi
    fi
}

uninstall_server() {
    is_linux || return 0
    need_root
    systemctl stop rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
    systemctl disable rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
    rm -f /etc/systemd/system/rustdesk-hbbs.service /etc/systemd/system/rustdesk-hbbr.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log_info "RustDesk 服务端已卸载，配置目录保留: $CONF_DIR"
}

uninstall_linux_client() {
    need_root
    if command_exists apt-get && command_exists dpkg && dpkg -l 2>/dev/null | grep -q '^ii[[:space:]]*rustdesk'; then
        apt-get purge -y rustdesk
    elif command_exists rpm && rpm -q rustdesk >/dev/null 2>&1; then
        if command_exists dnf; then dnf remove -y rustdesk
        elif command_exists yum; then yum remove -y rustdesk
        elif command_exists zypper; then zypper --non-interactive remove rustdesk
        else rpm -e rustdesk
        fi
    fi
    rm -f /usr/local/bin/rustdesk
    [[ -d "$INSTALL_DIR" && "$INSTALL_DIR" != "/usr/local/rustdesk-server" ]] && rm -rf "$INSTALL_DIR/rustdesk" 2>/dev/null || true
    log_info "RustDesk Linux 客户端已卸载。"
}

uninstall_macos_client() {
    local app="$INSTALL_DIR/RustDesk.app"
    [[ -d "$app" ]] || app="/Applications/RustDesk.app"
    if [[ -d "$app" ]]; then
        run_as_target_user osascript -e 'tell application "RustDesk" to quit' >/dev/null 2>&1 || true
        run_client_admin_cli 30 --uninstall-service >/dev/null 2>&1 \
            || log_warn "RustDesk 后台服务未卸载或未安装，将继续删除客户端。"
        remove_path "$app"
        log_info "RustDesk macOS 客户端已卸载: $app"
    else
        log_info "RustDesk macOS 客户端未安装。"
    fi
}

status() {
    echo -e "${CYAN}RustDesk 状态${NC}"
    echo "  系统: $(uname -s) $(uname -m)"
    echo "  安装目录: $INSTALL_DIR"
    echo "  下载目录: $DOWNLOAD_DIR"
    if is_linux; then
        if server_installed; then
            echo "  服务端: 已安装 ${INSTALL_DIR}"
            systemctl is-active rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
        else
            echo "  服务端: 未安装"
        fi
    fi
    if client_installed; then
        echo "  客户端: 已安装 $(installed_client_version)"
    else
        echo "  客户端: 未安装"
    fi
}

install_by_mode() {
    case "$MODE" in
        auto)
            if is_linux; then install_server
            elif is_macos; then install_macos_client
            else log_error "不支持的系统: $(uname -s)"; return 1
            fi
            ;;
        server) install_server ;;
        client)
            if is_macos; then install_macos_client
            elif is_linux; then install_linux_client
            else log_error "不支持的系统: $(uname -s)"; return 1
            fi
            ;;
        all)
            if is_linux; then install_server; install_linux_client
            elif is_macos; then install_macos_client
            else log_error "不支持的系统: $(uname -s)"; return 1
            fi
            ;;
        *) log_error "未知模式: $MODE"; return 1 ;;
    esac
}

uninstall_by_mode() {
    case "$MODE" in
        auto)
            if is_linux; then uninstall_server; uninstall_linux_client
            elif is_macos; then uninstall_macos_client
            fi
            ;;
        server) uninstall_server ;;
        client) if is_macos; then uninstall_macos_client; else uninstall_linux_client; fi ;;
        all) if is_linux; then uninstall_server; uninstall_linux_client; else uninstall_macos_client; fi ;;
    esac
}

list_versions() {
    echo "服务端 ${SERVER_REPO}:"
    latest_versions "$SERVER_REPO" | sed 's/^/  /'
    echo "客户端 ${CLIENT_REPO}:"
    latest_versions "$CLIENT_REPO" | sed 's/^/  /'
}

main() {
    parse_args "$@"
    case "$ACTION" in
        install) install_by_mode ;;
        uninstall) uninstall_by_mode ;;
        status) status ;;
        list_versions) list_versions ;;
        *) log_error "未知操作: $ACTION"; exit 1 ;;
    esac
}

main "$@"

#!/usr/bin/env bash

set -euo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

ACTION="install"
INSTALL_DIR=""
DOWNLOAD_DIR=""
PASSWORD=""
PASSWORD_SET=0
YES=0
NO_START=0
FORCE_DOWNLOAD=0

MAC_URL="https://download.teamviewer.com/download/TeamViewer.dmg"
DEB_URL="https://download.teamviewer.com/download/linux/teamviewer_amd64.deb"
RPM_URL="https://download.teamviewer.com/download/linux/teamviewer.x86_64.rpm"

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

home_for_user() {
    local user="$1" home=""
    if is_macos && command_exists dscl; then
        home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
    [[ -n "$home" ]] || home="$(eval echo "~${user}")"
    printf '%s\n' "$home"
}

default_install_dir() {
    if is_macos; then printf '%s\n' "/Applications"; else printf '%s\n' "/opt/teamviewer"; fi
}

default_download_dir() {
    printf '%s/Downloads\n' "$(home_for_user "$(target_user)")"
}

expand_path() {
    local value="$1"
    value="${value/#\~/$HOME}"
    [[ "$value" == /* ]] || value="$(pwd)/$value"
    printf '%s\n' "${value%/}"
}

show_help() {
    cat <<EOF
TeamViewer 一键安装、更新和卸载脚本

用法:
  $0 [选项]

操作:
  -i, --install             安装或更新（默认）
  -u, --uninstall           卸载 TeamViewer
  -s, --status              显示版本、设备 ID 和服务状态

参数:
  -d, --install-dir DIR     安装目录（系统包路径固定，仅用于显式校验）
                            macOS: /Applications，Linux: /opt/teamviewer
  -D, --download-dir DIR    下载目录（默认: 当前用户 ~/Downloads）
  -p, --password PASSWORD   Linux 安装后设置无人值守访问密码
  -y, --yes                 非交互确认，默认执行更新
  -f, --force-download      忽略已下载的安装包并重新下载
      --no-start            安装后不启动 TeamViewer
  -h, --help                显示帮助

说明:
  - 使用 TeamViewer 官方当前稳定版下载地址。
  - TeamViewer 不提供公开的最近 5 个稳定版本接口，因此不显示历史版本菜单。
  - 检测到 adl 时优先使用 adl，失败后回退 curl/wget。

示例:
  $0
  $0 --status
  $0 --download-dir ~/Downloads
  sudo $0 --password '<fixed-password>'
  $0 --uninstall
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -i|--install) ACTION="install"; shift ;;
            -u|--uninstall) ACTION="uninstall"; shift ;;
            -s|--status) ACTION="status"; shift ;;
            -d|--install-dir)
                [[ $# -gt 1 ]] || { log_error "$1 需要目录参数"; exit 1; }
                INSTALL_DIR="$(expand_path "$2")"; shift 2 ;;
            --install-dir=*) INSTALL_DIR="$(expand_path "${1#*=}")"; shift ;;
            -D|--download-dir)
                [[ $# -gt 1 ]] || { log_error "$1 需要目录参数"; exit 1; }
                DOWNLOAD_DIR="$(expand_path "$2")"; shift 2 ;;
            --download-dir=*) DOWNLOAD_DIR="$(expand_path "${1#*=}")"; shift ;;
            -p|--password)
                [[ $# -gt 1 ]] || { log_error "$1 需要密码参数"; exit 1; }
                PASSWORD="$2"; PASSWORD_SET=1; shift 2 ;;
            --password=*) PASSWORD="${1#*=}"; PASSWORD_SET=1; shift ;;
            -y|--yes) YES=1; shift ;;
            -f|--force-download) FORCE_DOWNLOAD=1; shift ;;
            --no-start) NO_START=1; shift ;;
            *) log_error "未知参数: $1"; show_help; exit 1 ;;
        esac
    done

    INSTALL_DIR="${INSTALL_DIR:-$(default_install_dir)}"
    DOWNLOAD_DIR="${DOWNLOAD_DIR:-$(default_download_dir)}"
    if [[ "$INSTALL_DIR" != "$(default_install_dir)" ]]; then
        log_error "TeamViewer 系统安装包不支持自定义安装目录；当前系统必须使用 $(default_install_dir)"
        exit 1
    fi
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
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

download_file() {
    local url="$1" output="$2" description="$3"
    local adl_path
    mkdir -p "$(dirname "$output")"
    if [[ "$FORCE_DOWNLOAD" -eq 0 && -s "$output" ]]; then
        log_info "已存在，跳过下载: $output"
        return 0
    fi
    rm -f "$output"

    if adl_path="$(find_adl)"; then
        log_info "使用 adl 下载 ${description}: $(basename "$output")"
        if "$adl_path" "$url" "$(dirname "$output")" "$(basename "$output")" && [[ -s "$output" ]]; then
            return 0
        fi
        log_warn "adl 下载失败，回退 curl/wget。"
        rm -f "$output"
    fi

    if command_exists curl; then
        curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url"
    elif command_exists wget; then
        wget -O "$output" "$url"
    else
        log_error "未找到 adl、curl 或 wget。"
        return 1
    fi
    [[ -s "$output" ]]
}

latest_version() {
    local headers version
    if command_exists curl; then
        headers="$(curl -fsSIL --retry 2 --connect-timeout 10 --max-time 30 "$DEB_URL" 2>/dev/null || true)"
        version="$(printf '%s\n' "$headers" | sed -nE 's#.*teamviewer_([0-9]+(\.[0-9]+)+)_amd64\.deb.*#\1#p' | tail -1)"
    fi
    printf '%s\n' "${version:-latest}"
}

installed_version() {
    if is_macos; then
        local plist="$INSTALL_DIR/TeamViewer.app/Contents/Info.plist"
        [[ -f "$plist" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true
    elif command_exists teamviewer; then
        teamviewer --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1 || true
    elif command_exists dpkg-query; then
        dpkg-query -W -f='${Version}\n' teamviewer 2>/dev/null | sed 's/[^0-9.].*//' || true
    fi
}

is_installed() {
    if is_macos; then
        [[ -d "$INSTALL_DIR/TeamViewer.app" ]]
    elif command_exists dpkg-query && dpkg-query -W teamviewer >/dev/null 2>&1; then
        return 0
    elif command_exists rpm && rpm -q teamviewer >/dev/null 2>&1; then
        return 0
    else
        command_exists teamviewer
    fi
}

confirm_installed_action() {
    local current="$1" choice=""
    log_warn "检测到 TeamViewer 已安装${current:+（当前版本: $current）}" >&2
    if [[ "$YES" -eq 1 || ! -t 0 ]]; then
        printf '%s\n' "update"
        return 0
    fi
    read -r -p "请选择: [U]更新(默认) / [R]卸载 / [S]跳过: " choice
    case "${choice:-u}" in
        u|U) printf '%s\n' "update" ;;
        r|R) printf '%s\n' "uninstall" ;;
        s|S) printf '%s\n' "skip" ;;
        *) log_error "无效选择: $choice"; return 1 ;;
    esac
}

package_url_and_name() {
    local version="$1"
    if is_macos; then
        PACKAGE_URL="$MAC_URL"
        PACKAGE_PATH="$DOWNLOAD_DIR/TeamViewer-${version}.dmg"
    elif [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
        log_error "TeamViewer Linux 完整客户端官方包仅支持 x86_64；当前架构: $(uname -m)"
        return 1
    elif command_exists apt-get && command_exists dpkg; then
        PACKAGE_URL="$DEB_URL"
        PACKAGE_PATH="$DOWNLOAD_DIR/teamviewer-${version}-amd64.deb"
    else
        PACKAGE_URL="$RPM_URL"
        PACKAGE_PATH="$DOWNLOAD_DIR/teamviewer-${version}-x86_64.rpm"
    fi
}

install_macos() {
    local dmg="$1" mount_output mount_point pkg
    mount_output="$(hdiutil attach "$dmg" -nobrowse 2>&1)"
    mount_point="$(printf '%s\n' "$mount_output" | sed -n 's|^/dev/.*\(/Volumes/.*\)$|\1|p' | head -1)"
    [[ -n "$mount_point" && -d "$mount_point" ]] || { log_error "DMG 挂载失败: $mount_output"; return 1; }
    trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true' RETURN
    pkg="$(find "$mount_point" -maxdepth 2 -name '*.pkg' -type f | head -1)"
    [[ -n "$pkg" ]] || { log_error "DMG 中未找到 TeamViewer 安装包。"; return 1; }
    sudo installer -pkg "$pkg" -target /
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    trap - RETURN
}

install_linux() {
    local package="$1"
    if [[ "$package" == *.deb ]]; then
        sudo apt-get update -qq
        sudo apt-get install -y "$package"
    elif command_exists dnf; then
        sudo dnf install -y "$package"
    elif command_exists yum; then
        sudo yum install -y "$package"
    elif command_exists zypper; then
        sudo zypper --non-interactive install "$package"
    else
        sudo rpm -Uvh "$package"
    fi
}

set_access_password() {
    local answer entered confirm random_hex
    if [[ "$PASSWORD_SET" -eq 0 && "$YES" -eq 0 && -t 0 ]] && is_linux; then
        read -r -p "是否配置或重置无人值守访问密码？(y/N): " answer
        if [[ "${answer:-n}" =~ ^[Yy]$ ]]; then
            read -r -s -p "请输入访问密码（至少 6 位，留空自动生成）: " entered
            echo ""
            if [[ -z "$entered" ]]; then
                random_hex="$(od -An -N8 -tx1 /dev/urandom | tr -d '[:space:]')"
                PASSWORD="Tv${random_hex}"
            else
                read -r -s -p "请再次输入访问密码: " confirm
                echo ""
                [[ "$entered" == "$confirm" ]] || { log_error "两次输入的密码不一致。"; return 1; }
                PASSWORD="$entered"
            fi
            PASSWORD_SET=1
        fi
    fi

    [[ "$PASSWORD_SET" -eq 1 ]] || return 0
    [[ ${#PASSWORD} -ge 6 ]] || { log_error "访问密码至少需要 6 个字符。"; return 1; }
    if is_linux; then
        sudo teamviewer passwd "$PASSWORD"
        log_info "TeamViewer 无人值守访问密码已设置。"
        echo "  无人值守访问密码: $PASSWORD"
        log_warn "密码仅在本次设置后显示，请妥善保存。"
    else
        log_warn "TeamViewer macOS 公共版没有稳定的密码设置 CLI，请在应用的远程控制设置中配置无人值守访问。"
    fi
}

start_teamviewer() {
    [[ "$NO_START" -eq 0 ]] || return 0
    if is_macos; then
        open -a TeamViewer
    else
        sudo teamviewer daemon start >/dev/null 2>&1 || true
    fi
}

teamviewer_id() {
    if is_linux && command_exists teamviewer; then
        teamviewer info 2>/dev/null | sed -nE 's/.*TeamViewer ID:[[:space:]]*([0-9 ]+).*/\1/p' | tr -d ' ' | head -1
    elif is_macos; then
        local plist id
        for plist in \
            "/Library/Preferences/com.teamviewer.teamviewer.preferences.plist" \
            "$HOME/Library/Preferences/com.teamviewer.teamviewer.preferences.plist"; do
            [[ -f "$plist" ]] || continue
            id="$(/usr/libexec/PlistBuddy -c 'Print :ClientID' "$plist" 2>/dev/null || true)"
            [[ -n "$id" ]] && { printf '%s\n' "$id"; return 0; }
        done
    fi
}

show_status() {
    local version id
    echo -e "${CYAN}TeamViewer 状态${NC}"
    echo "  系统: $(uname -s) $(uname -m)"
    echo "  安装目录: $INSTALL_DIR"
    echo "  下载目录: $DOWNLOAD_DIR"
    if ! is_installed; then
        echo "  客户端: 未安装"
        return 0
    fi
    version="$(installed_version)"
    id="$(teamviewer_id || true)"
    echo "  客户端: 已安装 ${version:-<版本未知>}"
    echo "  TeamViewer ID: ${id:-<启动客户端后获取>}"
    if is_linux; then
        teamviewer daemon status 2>/dev/null | sed 's/^/  /' || true
    fi
}

uninstall_teamviewer() {
    if ! is_installed; then
        log_info "TeamViewer 未安装。"
        return 0
    fi
    if is_linux; then
        if command_exists apt-get && command_exists dpkg-query; then
            sudo apt-get purge -y teamviewer
        elif command_exists dnf; then sudo dnf remove -y teamviewer
        elif command_exists yum; then sudo yum remove -y teamviewer
        elif command_exists zypper; then sudo zypper --non-interactive remove teamviewer
        else sudo rpm -e teamviewer
        fi
    else
        osascript -e 'tell application "TeamViewer" to quit' >/dev/null 2>&1 || true
        sudo rm -rf "$INSTALL_DIR/TeamViewer.app"
        sudo rm -f /Library/LaunchDaemons/com.teamviewer.*.plist /Library/LaunchAgents/com.teamviewer.*.plist
        sudo rm -f /Library/PrivilegedHelperTools/com.teamviewer.*
        log_warn "用户偏好和账户配置已保留；可在 TeamViewer 官方卸载界面选择彻底删除。"
    fi
    log_info "TeamViewer 已卸载。"
}

install_or_update() {
    local current action version
    current="$(installed_version)"
    if is_installed; then
        action="$(confirm_installed_action "$current")"
        case "$action" in
            uninstall) uninstall_teamviewer; return 0 ;;
            skip) return 0 ;;
        esac
    fi

    version="$(latest_version)"
    package_url_and_name "$version"
    log_info "安装/更新 TeamViewer 官方稳定版: $version"
    log_info "安装目录: $INSTALL_DIR"
    log_info "下载目录: $DOWNLOAD_DIR"
    download_file "$PACKAGE_URL" "$PACKAGE_PATH" "TeamViewer 安装包"
    if is_macos; then install_macos "$PACKAGE_PATH"; else install_linux "$PACKAGE_PATH"; fi
    set_access_password
    start_teamviewer
    show_status
}

main() {
    is_macos || is_linux || { log_error "不支持的系统: $(uname -s)"; exit 1; }
    parse_args "$@"
    case "$ACTION" in
        install) install_or_update ;;
        uninstall) uninstall_teamviewer ;;
        status) show_status ;;
    esac
}

main "$@"

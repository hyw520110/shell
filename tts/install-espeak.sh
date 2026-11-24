#!/usr/bin/env bash
#
# install-espeak - espeak 跨平台一键安装/更新脚本 (macOS / Linux)
#
# 特性:
#   - 幂等: 未安装则安装, 已安装则自动更新到最新 (重复执行安全)
#   - 跨平台: macOS (Homebrew) / Linux (apt / dnf / yum / pacman / zypper / apk)
#   - 非交互模式: 需要提权的命令只输出提示, 不执行 (与 disk-clean.sh 一致)
#   - 安装后验证 espeak / espeak-ng 命令与中文语音可用性
#
# 用法:
#   install-espeak.sh            安装或更新
#   install-espeak.sh --check    仅检查并打印状态, 不安装
#   install-espeak.sh --force    强制更新 (即使已是最新)
#   install-espeak.sh --quiet    静默模式 (仅输出错误与提示)
#
# 环境变量:
#   ESK_FORCE=true        强制更新
#   ESK_QUIET=true        静默模式
#
# 集成: tts-notify.sh 的 `tts-notify install-espeak` 会调用本脚本;
#       tts-notify 播报引擎回退链为 edge-tts -> macOS say -> espeak(ng)。

set -u -o pipefail

VERSION="1.0.0"

# ---------- 基础工具 ----------
log()  { [ "${ESK_QUIET:-false}" = "true" ] || printf '%s\n' "[espeak] $1"; }
info() { printf '%s\n' "[espeak] $1"; }
warn() { printf '%s\n' "[espeak] 警告: $1" >&2; }
die()  { printf '%s\n' "[espeak] 错误: $1" >&2; exit "${2:-1}"; }

usage() {
    printf '%s\n' \
        "用法: $0 [--check] [--force] [--quiet]" \
        "  (无参数)          安装或更新 espeak" \
        "  --check           仅检查状态并退出" \
        "  --force           强制更新 (已安装也重新更新)" \
        "  --quiet           静默模式" >&2
}

# ---------- 平台与包管理器检测 ----------
detect_os() {
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"
    case "$os" in
        Darwin) echo macos ;;
        Linux)  echo linux ;;
        *) echo "unknown" ;;
    esac
}

# 检测 Linux 包管理器 (输出 pm 名, 或空)
detect_pkg_mgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v yum     >/dev/null 2>&1; then echo yum
    elif command -v pacman  >/dev/null 2>&1; then echo pacman
    elif command -v zypper  >/dev/null 2>&1; then echo zypper
    elif command -v apk     >/dev/null 2>&1; then echo apk
    else echo ""; fi
}

# 需要 root 的命令: 交互模式用 sudo; 非交互模式只输出提示
run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [ -t 0 ] || [ -n "${SUDO_ASKPASS:-}" ]; then
        sudo "$@"
    else
        info "非交互模式无法提权, 请手动执行以下命令:"
        printf '  sudo %s\n' "$*"
        return 127
    fi
}

# ---------- 状态检查 ----------
# 输出: 找到的引擎命令路径 (espeak-ng 优先, 其次 espeak)
find_espeak_bin() {
    local bin=""
    command -v espeak-ng >/dev/null 2>&1 && bin="$(command -v espeak-ng)"
    if [ -z "$bin" ]; then
        command -v espeak >/dev/null 2>&1 && bin="$(command -v espeak)"
    fi
    printf '%s\n' "$bin"
}

check_status() {
    local bin pkg=""
    bin="$(find_espeak_bin)"
    if [ -n "$bin" ]; then
        local ver
        ver="$("$bin" --version 2>/dev/null | head -1 || echo "版本未知")"
        info "已安装: $bin ($ver)"
        # 中文语音可用性
        if "$bin" --voices=zh >/dev/null 2>&1; then
            info "中文语音: 可用"
        else
            warn "未检测到中文语音包 (tts-notify 将使用 -v zh 尝试, 可能静默失败)"
        fi
        return 0
    fi
    info "未安装 espeak / espeak-ng"
    return 1
}

# ---------- macOS (Homebrew) ----------
install_macos() {
    command -v brew >/dev/null 2>&1 || die "未找到 Homebrew。请先安装: https://brew.sh/ 或运行: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    # 幂等策略: 确保 espeak-ng 存在 (现代引擎) -> 已存在则升级, 不存在则安装
    if command -v espeak-ng >/dev/null 2>&1 && [ "${ESK_FORCE:-false}" != "true" ]; then
        log "macOS 已安装 espeak-ng, 执行 brew upgrade 更新到最新..."
        brew upgrade espeak-ng 2>&1 | tail -3 || warn "brew upgrade 未完全成功 (可能已是最新)"
    else
        log "macOS 安装 espeak-ng (提供 espeak-ng 命令)..."
        brew install espeak-ng 2>&1 | tail -3 || die "brew install espeak-ng 失败"
    fi
    # 若 espeak 命令不存在则建立兼容链接 (espeak-ng 兼容 espeak 参数)
    if ! command -v espeak >/dev/null 2>&1 && command -v espeak-ng >/dev/null 2>&1; then
        local ng bin_dir
        ng="$(command -v espeak-ng)"
        bin_dir="$(dirname "$ng")"
        [ -w "$bin_dir" ] && ln -sf "$ng" "$bin_dir/espeak" 2>/dev/null \
            || info "未创建 espeak 链接 (目录无写权限); tts-notify 将直接使用 espeak-ng"
    fi
}

# ---------- Linux (包管理器) ----------
# 包名: 现代发行版为 espeak-ng, 老旧发行版为 espeak
install_linux() {
    local pm
    pm="$(detect_pkg_mgr)"
    [ -n "$pm" ] || die "未识别的 Linux 包管理器 (支持 apt/dnf/yum/pacman/zypper/apk)"
    local pkg="espeak-ng"
    if [ -n "$(find_espeak_bin)" ] && [ "${ESK_FORCE:-false}" != "true" ]; then
        log "Linux 已安装 espeak, 执行更新..."
        update_via "$pm" "$pkg"
    else
        log "Linux 安装 $pkg (包管理器: $pm)..."
        install_via "$pm" "$pkg" || {
            # 老发行版无 espeak-ng 包时回退 espeak
            if [ "$pm" = "apt" ]; then
                warn "未找到 $pkg 包, 回退安装 espeak"
                install_via "$pm" "espeak" || die "安装失败"
            else
                die "安装 $pkg 失败"
            fi
        }
    fi
}

install_via() {
    local pm="$1" pkg="$2"
    case "$pm" in
        apt)
            run_privileged apt-get update -qq 2>&1 | tail -2 || true
            run_privileged apt-get install -y "$pkg" ;;
        dnf)   run_privileged dnf install -y "$pkg" ;;
        yum)   run_privileged yum install -y "$pkg" ;;
        pacman) run_privileged pacman -S --noconfirm "$pkg" ;;
        zypper) run_privileged zypper install -y "$pkg" ;;
        apk)   run_privileged apk add "$pkg" ;;
    esac
}

update_via() {
    local pm="$1" pkg="$2"
    case "$pm" in
        apt)
            run_privileged apt-get update -qq 2>&1 | tail -2 || true
            run_privileged apt-get install --only-upgrade -y "$pkg" ;;
        dnf)   run_privileged dnf upgrade -y "$pkg" ;;
        yum)   run_privileged yum update -y "$pkg" ;;
        pacman) run_privileged pacman -S --noconfirm --needed "$pkg" ;;
        zypper) run_privileged zypper update -y "$pkg" ;;
        apk)   run_privileged apk upgrade "$pkg" ;;
    esac
}

# ---------- 主流程 ----------
main() {
    local check=false force=false quiet=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) check=true ;;
            --force) force=true; ESK_FORCE=true ;;
            --quiet) quiet=true; ESK_QUIET=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; exit 2 ;;
        esac
        shift
    done

    local os
    os="$(detect_os)"
    log "平台: $os"

    if [ "$check" = "true" ]; then
        check_status
        exit $?
    fi

    case "$os" in
        macos) install_macos ;;
        linux) install_linux ;;
        *) die "不支持的操作系统: $os" ;;
    esac

    # 安装/更新后验证
    info "验证安装结果..."
    if check_status; then
        info "✅ espeak 就绪。tts-notify 播报回退链: edge-tts -> macOS say -> espeak(ng)"
        exit 0
    fi
    die "安装后验证失败, 请检查上面的错误信息"
}

main "$@"

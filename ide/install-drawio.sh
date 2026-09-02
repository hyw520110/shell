#!/bin/bash
# install-drawio.sh - Draw.io Desktop 安装脚本
# 支持: macOS, Linux
# 版本: 29.0.3

set -euo pipefail

# 颜色定义（使用 $'...' 兼容 bash/zsh）
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# 日志函数
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()  { printf "${BLUE}[STEP]${NC} %s\n" "$*"; }
success(){ printf "${GREEN}[OK]${NC} %s\n" "$*"; }

# 版本和下载链接
VERSION="29.0.3"
GITHUB_BASE="https://github.com/jgraph/drawio-desktop/releases/download/v${VERSION}"

# 查找 adl 下载工具
find_adl() {
    local adl_path=""
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    if command -v adl &>/dev/null; then
        adl_path=$(command -v adl)
    elif [[ -f "$script_dir/adl" ]] && [[ -x "$script_dir/adl" ]]; then
        adl_path="$script_dir/adl"
    elif [[ -f "/usr/local/bin/adl" ]] && [[ -x "/usr/local/bin/adl" ]]; then
        adl_path="/usr/local/bin/adl"
    elif [[ -f "/opt/homebrew/bin/adl" ]] && [[ -x "/opt/homebrew/bin/adl" ]]; then
        adl_path="/opt/homebrew/bin/adl"
    fi

    if [[ -n "$adl_path" ]]; then
        echo "$adl_path"
        return 0
    fi
    return 1
}

# 通用下载函数
download_file() {
    local url="$1"
    local output="$2"
    local adl_bin
    adl_bin=$(find_adl 2>/dev/null || true)

    if [[ -n "$adl_bin" ]]; then
        info "使用 adl 下载..."
        local output_dir
        output_dir=$(dirname "$output")
        "$adl_bin" "$url" "$output_dir" "$(basename "$output")"
        return $?
    fi

    if command -v curl &>/dev/null; then
        info "使用 curl 下载..."
        curl -fsSL -o "$output" "$url" || {
            error "下载失败: $url"
            return 1
        }
    elif command -v wget &>/dev/null; then
        info "使用 wget 下载..."
        wget -q --show-progress -O "$output" "$url" || {
            error "下载失败: $url"
            return 1
        }
    else
        error "需要 adl、curl 或 wget 来下载"
        return 1
    fi
}

# 检测操作系统
detect_os() {
    case "$(uname -s)" in
        Darwin*)  echo "macOS";;
        Linux*)   echo "Linux";;
        *)        echo "Unknown";;
    esac
}

# 检测 CPU 架构
detect_arch() {
    case "$(uname -m)" in
        x86_64)     echo "amd64";;
        aarch64|arm64) echo "arm64";;
        armv7l)     echo "armhf";;
        *)          echo "amd64";;
    esac
}

# 检测 Draw.io 是否已安装
is_installed() {
    local os
    os=$(detect_os)

    case "$os" in
        macOS)
            [[ -d "/Applications/draw.io.app" ]] || [[ -d "/Applications/Draw.io.app" ]]
            ;;
        Linux)
            command -v drawio &>/dev/null || \
            [[ -f "/usr/bin/drawio" ]] || \
            [[ -f "/opt/drawio/drawio" ]] || \
            [[ -f "$HOME/.local/bin/drawio" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# 获取已安装版本
get_installed_version() {
    local os
    os=$(detect_os)

    case "$os" in
        macOS)
            if [[ -d "/Applications/draw.io.app" ]]; then
                defaults read "/Applications/draw.io.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ""
            elif [[ -d "/Applications/Draw.io.app" ]]; then
                defaults read "/Applications/Draw.io.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ""
            fi
            ;;
        Linux)
            drawio --version 2>/dev/null | head -1 || echo ""
            ;;
    esac
}

# macOS 安装
install_macos() {
    local arch
    arch=$(detect_arch)
    local dmg_url dmg_path mount_point

    # 选择下载链接
    if [[ "$arch" == "arm64" ]]; then
        dmg_url="${GITHUB_BASE}/draw.io-arm64-${VERSION}.dmg"
        info "检测到 Apple Silicon，选择 ARM64 版本"
    else
        dmg_url="${GITHUB_BASE}/draw.io-universal-${VERSION}.dmg"
        info "检测到 Intel/M1，选择 Universal 版本"
    fi

    dmg_path="/tmp/draw.io-${VERSION}.dmg"
    mount_point="/Volumes/draw.io"

    # 检查是否已安装
    if [[ -d "/Applications/draw.io.app" ]] || [[ -d "/Applications/Draw.io.app" ]]; then
        local installed_version
        installed_version=$(get_installed_version)
        installed_version="${installed_version:-unknown}"
        info "Draw.io 已安装 (版本: $installed_version)"

        if [[ "$installed_version" == "$VERSION" ]]; then
            success "已是最新版本，无需更新"
            return 0
        else
            warn "已安装版本: $installed_version，最新版本: $VERSION"
            printf "是否更新? [Y/n] "
            read -r confirm
            confirm="${confirm:-Y}"
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                info "跳过更新"
                return 0
            fi
        fi
    fi

    # 卸载已挂载的 DMG
    if mountpoint -q "$mount_point" 2>/dev/null; then
        info "卸载已挂载的 DMG..."
        hdiutil detach "$mount_point" 2>/dev/null || true
    fi

    # 删除旧安装
    if [[ -d "/Applications/draw.io.app" ]]; then
        info "删除旧版本..."
        rm -rf "/Applications/draw.io.app"
    fi
    if [[ -d "/Applications/Draw.io.app" ]]; then
        info "删除旧版本..."
        rm -rf "/Applications/Draw.io.app"
    fi

    # 下载
    step "下载 Draw.io v${VERSION}..."
    download_file "$dmg_url" "$dmg_path" || {
        rm -f "$dmg_path"
        exit 1
    }

    # 挂载并安装
    step "挂载 DMG..."
    hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse

    step "安装到 Applications..."
    cp -R "$mount_point/draw.io.app" /Applications/ || \
    cp -R "$mount_point/Draw.io.app" /Applications/draw.io.app

    # 卸载并清理
    hdiutil detach "$mount_point" 2>/dev/null || true
    rm -f "$dmg_path"

    success "Draw.io v${VERSION} 安装完成！"
}

# Linux 安装
install_linux() {
    local arch
    arch=$(detect_arch)
    local pkg_url pkg_path

    # 检查是否已安装
    if is_installed; then
        local installed_version
        installed_version=$(get_installed_version)
        installed_version="${installed_version:-unknown}"
        info "Draw.io 已安装 (版本: $installed_version)"

        if [[ "$installed_version" == "$VERSION" ]]; then
            success "已是最新版本，无需更新"
            return 0
        else
            warn "已安装版本: $installed_version，最新版本: $VERSION"
            printf "是否更新? [Y/n] "
            read -r confirm
            confirm="${confirm:-Y}"
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                info "跳过更新"
                return 0
            fi
        fi
    fi

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        pkg_url="${GITHUB_BASE}/drawio-${arch}-${VERSION}.deb"
        pkg_path="/tmp/drawio_${VERSION}.deb"

        step "下载 Draw.io v${VERSION} (DEB)..."
        download_file "$pkg_url" "$pkg_path" || {
            rm -f "$pkg_path"
            exit 1
        }

        step "安装..."
        sudo apt-get install -y "$pkg_path" || {
            sudo dpkg -i "$pkg_path" || true
            sudo apt-get -f install -y
        }
        rm -f "$pkg_path"

    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        # Fedora/RHEL
        pkg_url="${GITHUB_BASE}/draw.io-x86_64-${VERSION}.rpm"
        pkg_path="/tmp/drawio_${VERSION}.rpm"

        step "下载 Draw.io v${VERSION} (RPM)..."
        download_file "$pkg_url" "$pkg_path" || {
            rm -f "$pkg_path"
            exit 1
        }

        step "安装..."
        sudo rpm -ivh "$pkg_path" || sudo dnf install -y "$pkg_path"
        rm -f "$pkg_path"

    elif command -v pacman &>/dev/null; then
        # Arch Linux - 使用 AppImage
        warn "Arch Linux 检测，使用 AppImage 方式"
        local appimage_url="${GITHUB_BASE}/draw.io-${arch}-${VERSION}.AppImage"
        local appimage_path="/tmp/drawio_${VERSION}.AppImage"

        step "下载 Draw.io v${VERSION} (AppImage)..."
        download_file "$appimage_url" "$appimage_path" || {
            rm -f "$appimage_path"
            exit 1
        }

        step "安装到 ~/.local/bin..."
        chmod +x "$appimage_path"
        mkdir -p "$HOME/.local/bin"
        mv "$appimage_path" "$HOME/.local/bin/drawio"
        success "AppImage 已安装到 ~/.local/bin/drawio"
        info "如需桌面快捷方式，请手动创建"
        return 0

    else
        # 备选：使用 AppImage
        warn "未检测到支持的包管理器，使用 AppImage 方式"
        local appimage_url="${GITHUB_BASE}/draw.io-${arch}-${VERSION}.AppImage"
        local appimage_path="/tmp/drawio_${VERSION}.AppImage"

        step "下载 Draw.io v${VERSION} (AppImage)..."
        download_file "$appimage_url" "$appimage_path" || {
            rm -f "$appimage_path"
            exit 1
        }

        step "安装到 ~/.local/bin..."
        chmod +x "$appimage_path"
        mkdir -p "$HOME/.local/bin"
        mv "$appimage_path" "$HOME/.local/bin/drawio"
        success "AppImage 已安装到 ~/.local/bin/drawio"
        return 0
    fi

    success "Draw.io v${VERSION} 安装完成！"
}

# 显示版本信息
show_version() {
    local os
    os=$(detect_os)

    info "Draw.io Desktop v${VERSION}"
    info "操作系统: $os ($(uname -m))"
    echo ""

    if is_installed; then
        local installed_version
        installed_version=$(get_installed_version)
        if [[ -n "$installed_version" ]]; then
            success "已安装: v${installed_version}"
        else
            success "已安装"
        fi
    else
        warn "未安装"
    fi
}

# 显示帮助
show_help() {
    cat << EOF
${GREEN}Draw.io Desktop 安装脚本${NC} v${VERSION}

${YELLOW}用法:${NC}
  $(basename "$0") [选项]

${YELLOW}选项:${NC}
  install     安装 Draw.io Desktop
  uninstall   卸载 Draw.io Desktop
  version     显示版本信息
  -h, --help  显示帮助信息

${YELLOW}示例:${NC}
  $(basename "$0")           # 安装
  $(basename "$0") install    # 安装
  $(basename "$0") version   # 查看版本
  $(basename "$0") uninstall # 卸载

${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${CYAN}📌 其他使用方式${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${YELLOW}1、网页端免安装 (Web App)${NC}
   打开 https://app.diagrams.net/，选择"打开现有图表"，
   把 .drawio 源文件拖进去即可编辑，编辑完点击保存覆盖原文件。

${YELLOW}2、在 VS Code / Cursor 中直接编辑（开发者首选）${NC}
   - 在插件市场搜索并安装 ${CYAN}Draw.io Integration${NC}（作者: Henning Dieterichs）
   - 安装后，直接在编辑器里双击打开 .drawio 文件
   - 它会变成拥有完整 UI 的画图面板，像改代码一样直接改图
   - 保存后自动同步到原文件

${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
}

# 卸载
uninstall() {
    local os
    os=$(detect_os)

    step "卸载 Draw.io..."

    case "$os" in
        macOS)
            if [[ -d "/Applications/draw.io.app" ]]; then
                rm -rf "/Applications/draw.io.app"
                success "已卸载 /Applications/draw.io.app"
            fi
            if [[ -d "/Applications/Draw.io.app" ]]; then
                rm -rf "/Applications/Draw.io.app"
                success "已卸载 /Applications/Draw.io.app"
            fi
            ;;
        Linux)
            if command -v drawio &>/dev/null; then
                if command -v apt-get &>/dev/null; then
                    sudo apt-get remove -y drawio || true
                elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
                    sudo rpm -e draw.io || sudo dnf remove -y draw.io || true
                fi
            fi
            if [[ -f "$HOME/.local/bin/drawio" ]]; then
                rm -f "$HOME/.local/bin/drawio"
                success "已卸载 ~/.local/bin/drawio"
            fi
            ;;
    esac

    success "卸载完成"
}

# 主函数
main() {
    echo ""
    info "Draw.io Desktop 安装脚本 v${VERSION}"
    echo ""

    case "${1:-install}" in
        install)
            install
            ;;
        uninstall)
            uninstall
            ;;
        version)
            show_version
            ;;
        -h|--help)
            show_help
            ;;
        *)
            error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

install() {
    local os
    os=$(detect_os)

    case "$os" in
        macOS)
            install_macos
            ;;
        Linux)
            install_linux
            ;;
        *)
            error "不支持的操作系统: $os"
            exit 1
            ;;
    esac

    echo ""
    success "安装完成！"
    echo ""
    info "启动方式:"
    case "$os" in
        macOS)
            info "  open -a \"draw.io\""
            info "  或从启动台点击"
            ;;
        Linux)
            info "  drawio"
            info "  或从应用菜单点击"
            ;;
    esac
    echo ""
    info "其他使用方式:"
    info "  网页端: https://app.diagrams.net/ (免安装)"
    info "  VS Code: 安装 Draw.io Integration 插件"
}

main "$@"

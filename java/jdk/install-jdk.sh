#!/bin/bash

# JDK Install Script - Simplified with Apple Silicon Support
# Simple and reliable JDK installation

set -e

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ============================================
# 共享工具函数
# ============================================

# 下载目录
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

# ADL下载函数 - 优先使用adl工具
download_with_adl() {
    local url="$1"
    local output="$2"
    local filename="$(basename "$output")"
    local output_dir="$(dirname "$output")"

    # 确保输出目录存在
    mkdir -p "$output_dir"

    local adl_path
    if adl_path=$(find_adl); then
        "$adl_path" "$url" "$output_dir" "$filename"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        echo "错误: 未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

# 检查文件完整性（基本大小检查）
check_file_valid() {
    local file="$1"
    local min_size="${2:-1000}"  # default 1KB
    [[ -f "$file" ]] && [[ -s "$file" ]] && [[ $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null) -gt $min_size ]]
}

# 自动特权提升
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要root权限，正在提权..."
        # 传递版本参数避免重复询问
        exec sudo "$0" -v "${JDK_VERSION:-$DEFAULT_VERSION}" -d "$INSTALL_DIR"
    fi
}

# ============================================
# 安装配置
# ============================================

# Default Installation Directory
DEFAULT_INSTALL_DIR="$HOME/jdk"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"

# Default Version
DEFAULT_VERSION="21"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Detect architecture
is_arm64() {
    [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]
}

# Get macOS URL with architecture support
get_mac_url() {
    local version="$1"
    local arch="x64"
    if is_arm64; then
        arch="aarch64"
    fi

    case "$version" in
        8) echo "https://cdn.azul.com/zulu/bin/zulu8.84.0.15-ca-jdk8.0.442-macosx_$arch.tar.gz" ;;
        11) echo "https://cdn.azul.com/zulu/bin/zulu11.74.15-ca-jdk11.0.24-macosx_$arch.tar.gz" ;;
        17) echo "https://cdn.azul.com/zulu/bin/zulu17.52.17-ca-jdk17.0.12-macosx_$arch.tar.gz" ;;
        21) echo "https://cdn.azul.com/zulu/bin/zulu21.38.21-ca-jdk21.0.5-macosx_$arch.tar.gz" ;;
        *) echo "" ;;
    esac
}

# Get Linux URL
get_linux_url() {
    local version="$1"
    local arch="x64"
    if is_arm64; then
        arch="aarch64"
    fi

    case "$version" in
        8) echo "https://cdn.azul.com/zulu/bin/zulu8.84.0.15-ca-jdk8.0.442-linux_$arch.tar.gz" ;;
        11) echo "https://cdn.azul.com/zulu/bin/zulu11.74.15-ca-jdk11.0.24-linux_$arch.tar.gz" ;;
        17) echo "https://cdn.azul.com/zulu/bin/zulu17.52.17-ca-jdk17.0.12-linux_$arch.tar.gz" ;;
        21) echo "https://cdn.azul.com/zulu/bin/zulu21.38.21-ca-jdk21.0.5-linux_$arch.tar.gz" ;;
        *) echo "" ;;
    esac
}

# Detect OS
is_mac() {
    [[ "$(uname -s)" == "Darwin" ]]
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "jdk" ]; then
        echo "$input"
    else
        echo "$input/jdk"
    fi
}

# Get download URL
get_download_url() {
    local version="$1"
    if is_mac; then
        get_mac_url "$version"
    else
        get_linux_url "$version"
    fi
}

# Download with integrity check
download_jdk() {
    local url="$1"
    local output_file="$2"
    local filename="$(basename "$output_file")"

    # 检查文件是否已存在且有效
    if check_file_valid "$output_file" 1000000; then  # 至少1MB
        log "文件已存在且有效: $output_file"
        return 0
    fi

    log "正在下载 JDK ..."
    download_with_adl "$url" "$output_file"

    # 验证下载的文件
    if ! check_file_valid "$output_file" 1000000; then
        log "错误: 下载的文件无效或太小"
        rm -f "$output_file"
        exit 1
    fi

    log "下载完成: $filename"
}

# Download and install
install_jdk() {
    local version="$1"

    if [ -z "$version" ]; then
        version="$DEFAULT_VERSION"
    fi

    # 导出版本变量供 require_root 使用
    export JDK_VERSION="$version"

    log "开始安装 Java $version"
    if is_arm64; then
        log "检测到 ARM64 架构"
    fi
    log "安装目录: $INSTALL_DIR"
    log "下载目录: $DOWNLOAD_DIR"

    # Get URL
    local url=$(get_download_url "$version")
    if [ -z "$url" ]; then
        log "错误: 不支持的版本 $version"
        exit 1
    fi

    local filename="${url##*/}"
    local download_file="$DOWNLOAD_DIR/$filename"

    # 确保下载目录存在
    mkdir -p "$DOWNLOAD_DIR"

    # Download with integrity check
    download_jdk "$url" "$download_file"

    # Extract
    log "正在解压 ..."
    local temp_dir=$(mktemp -d)
    tar -xzf "$download_file" -C "$temp_dir"

    # Find extracted dir
    local extract_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$extract_dir" ]; then
        log "错误: 解压失败"
        exit 1
    fi

    if [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
        require_root
    fi

    mkdir -p "$INSTALL_DIR"
    local target_dir="$INSTALL_DIR/jdk-$version"
    if [ -d "$target_dir" ]; then
        rm -rf "$target_dir"
    fi
    mv "$extract_dir" "$target_dir"
    rm -rf "$temp_dir"
    ln -sfn "$target_dir" "$INSTALL_DIR/current"

    # Configure environment via switch-java.sh (复用切换逻辑，保证配置一致性)
    local switch_script="$SCRIPT_DIR/switch-java.sh"
    if [ -x "$switch_script" ]; then
        log "调用 switch-java.sh 切换到 JDK $version"
        bash "$switch_script" -v "$version" -d "$INSTALL_DIR" || \
            log "警告: switch-java.sh 执行失败，请手动运行: $switch_script -v $version -d $INSTALL_DIR"
    else
        # 回退: 直接写 shell rc (兼容 switch-java.sh 不存在的情况)
        local java_home="$target_dir"
        if is_mac && [ -d "$java_home/Contents/Home" ]; then
            java_home="$java_home/Contents/Home"
        fi

        local shell_config="$HOME/.bashrc"
        if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
            shell_config="$HOME/.zshrc"
        fi

        sed -i.bak '/# Java Environment Variables/,+2d' "$shell_config" 2>/dev/null || true
        rm -f "$shell_config.bak" 2>/dev/null || true

        echo "" >> "$shell_config"
        echo "# Java Environment Variables" >> "$shell_config"
        echo "export JAVA_HOME=\"$java_home\"" >> "$shell_config"
        echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\"" >> "$shell_config"
        log "环境变量已配置到: $shell_config"
    fi

    log "Java $version 安装完成"
    log "请执行: source ${HOME}/.zshrc"

    # Verify
    local verify_home
    if is_mac && [ -d "$target_dir/Contents/Home" ]; then
        verify_home="$target_dir/Contents/Home"
    else
        verify_home="$target_dir"
    fi
    if [ -x "$verify_home/bin/java" ]; then
        "$verify_home/bin/java" -version 2>&1 | head -1
    fi
}

# Main
USER_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            USER_VERSION="$2"
            shift 2
            ;;
        -d|--dir)
            INSTALL_DIR="$(normalize_install_dir "$2")"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [-v VERSION] [-d INSTALL_DIR]"
            echo "  -v, --version VERSION   JDK版本，默认: $DEFAULT_VERSION"
            echo "  -d, --dir DIR           安装父目录或实际安装目录，默认: $DEFAULT_INSTALL_DIR"
            exit 0
            ;;
        *)
            log "未知参数: $1"
            exit 1
            ;;
    esac
done

if [ -z "$USER_VERSION" ]; then
    # Ask for version first (user mode)
    echo "请选择要安装的JDK版本 (支持: 8 11 17 21)"
    echo "默认: $DEFAULT_VERSION (30秒后自动选择)"
    read -t 30 -p "请输入版本号: " USER_VERSION

    if [ -z "$USER_VERSION" ]; then
        USER_VERSION="$DEFAULT_VERSION"
        echo ""
        log "超时，使用默认版本: $USER_VERSION"
    fi

    # Validate version
    test_url=$(get_download_url "$USER_VERSION")
    if [ -z "$test_url" ]; then
        log "警告: 不支持的版本 $USER_VERSION，使用默认版本 $DEFAULT_VERSION"
        USER_VERSION="$DEFAULT_VERSION"
    fi

    # Install JDK (will auto-elevate if needed)
fi

install_jdk "$USER_VERSION"

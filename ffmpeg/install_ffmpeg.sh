#!/bin/bash

FFMPEG_VERSION="4.4.6"
FFMPEG_TAG="n${FFMPEG_VERSION}"
DOWNLOAD_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_TAG}.tar.gz"
DOWNLOAD_DIR="$HOME/Downloads"

# 设置错误处理
set -euo pipefail

# 全局变量用于trap清理
SOURCE_DIR=""

# 清理函数
cleanup() {
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]]; then
        echo "🧹 清理临时源码目录: $SOURCE_DIR"
        rm -rf "$SOURCE_DIR"
    fi
}
trap cleanup EXIT # 注册trap，在脚本退出时执行清理

# 下载文件函数
download_file() {
    local url="$1"
    local dir="${2:-.}"
    local force_download="$3"
    local filename=$(basename "$url" | cut -d'?' -f1)
    local download_path="$dir/$filename"

    # 强制下载或文件不存在/为空
    if [[ "$force_download" == "true" || ! -f "$download_path" || ! -s "$download_path" ]]; then
        mkdir -p "$dir"
        wget -O "$download_path" "$url" --show-progress
        if [ $? -ne 0 ]; then
            echo "❌ 下载失败，请检查网络或 URL。"
            exit 1
        fi
    fi
     echo "$download_path"
}

# 解压文件函数
extract_file() {
    local file_path="$1"
    local extract_dir="${2:-$(dirname "$file_path")}"
    local filename=$(basename "$file_path")
    local extract_dirname=""

    # 提取目录名
    case "$filename" in
        *.zip)
            extract_dirname=$(unzip -l "$file_path" | grep -m1 '^  ' | awk '{print $4}' | head -n1 | cut -d'/' -f1)
            ;;
        *.tar.gz | *.tgz)
            extract_dirname=$(tar -tzf "$file_path" | grep '/$' | head -1 | cut -d'/' -f1)
            ;;
        *.tar.bz2 | *.tbz2)
            extract_dirname=$(tar -tjf "$file_path" | grep '/$' | head -1 | cut -d'/' -f1)
            ;;
    esac

    case "$filename" in
        *.zip)
            unzip -q "$file_path" -d "$extract_dir"
            ;;
        *.tar.gz | *.tgz)
            tar -xzf "$file_path" -C "$extract_dir"
            ;;
        *.tar.bz2 | *.tbz2)
            tar -xjf "$file_path" -C "$extract_dir"
            ;;
    esac

    echo "$extract_dirname"
}

# 检查并安装依赖 (macOS)
install_mac_deps() {
    echo "🍏 检查 macOS 依赖..."
    # 确保 Homebrew 已安装
    if ! command -v brew &> /dev/null; then
        echo "❌ 请先安装 Homebrew: https://brew.sh"
        exit 1
    fi
    # 依赖列表
    local deps=("wget" "yasm" "nasm" "libtool" "automake" "autoconf" "libvpx" "x264" "x265" "nettle" "fdk-aac")
    for dep in "${deps[@]}"; do
        if brew list "$dep" &>/dev/null; then
            echo "✅ $dep 已安装"
        else
            echo "⬇️  安装 $dep..."
            brew install "$dep"
        fi
    done
    # 检查 yasm 、nasm是否安装
    command -v yasm &> /dev/null || brew reinstall yasm
    command -v nasm &> /dev/null || brew reinstall nasm
    # 确保openssl链接正确
    if ! brew link --force openssl &>/dev/null; then
        echo "⚠️  注意: openssl 链接可能需要手动处理"
    fi
}

# 检查并安装依赖 (Linux)
install_linux_deps() {
    echo "🐧 检查 Linux 依赖..."
    local deps=()
    local pkg_manager=""

    if command -v apt-get &>/dev/null; then
        pkg_manager="apt-get"
        deps=(build-essential yasm nasm libssl-dev zlib1g-dev libvpx-dev libopus-dev libogg-dev libvorbis-dev libtheora-dev libfdk-aac-dev libmp3lame-dev libwebp-dev x264 x265)
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        deps=(nasm yasm openssl-devel zlib-devel libvpx-devel opus-devel libogg-devel libvorbis-devel libtheora-devel fdk-aac-devel lame-devel libwebp-devel x264-devel x265-devel)
        sudo dnf groupinstall -y "Development Tools"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        deps=(nasm yasm openssl-devel zlib-devel libvpx-devel opus-devel libogg-devel libvorbis-devel libtheora-devel fdk-aac-devel lame-devel libwebp-devel x264-devel x265-devel)
        sudo yum groupinstall -y "Development Tools"
    else
        echo "❌ 未找到支持的包管理器 (apt, dnf, yum)。"
        exit 1
    fi

    echo "使用包管理器: $pkg_manager"
    for dep in "${deps[@]}"; do
        # 使用通用的方式检查包是否安装可能很复杂，这里简化为直接尝试安装
        echo "⬇️  确保已安装 $dep..."
        sudo "$pkg_manager" install -y "$dep"
    done
}

# 安装依赖
install_deps() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        install_linux_deps
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        install_mac_deps
    else
        echo "❌ 不支持的操作系统: $OSTYPE"
        exit 1
    fi
}

install_ffmpeg() {
    echo "🚀 开始安装 FFmpeg ${FFMPEG_VERSION}..."
 	install_deps
    # 下载文件
    download_path=$(download_file "$DOWNLOAD_URL" "$DOWNLOAD_DIR" "false")
    echo "📄 文件路径: $download_path"

    # 解压文件
    extract_dirname=$(extract_file "$download_path" "$DOWNLOAD_DIR")
    echo "📂 解压目录名: $extract_dirname"

    DIR_NAME=$(echo "$extract_dirname" | xargs basename)
    # 为全局变量赋值，以便trap可以清理
    SOURCE_DIR="$DOWNLOAD_DIR/$DIR_NAME"
    echo "💻 源码目录: $SOURCE_DIR"

    if [ -d "$SOURCE_DIR" ]; then
        cd "$SOURCE_DIR"
    else
        echo "❌ 错误：找不到解压目录 $SOURCE_DIR"
        exit 1
    fi

    # 配置 FFmpeg
    echo "⚙️  配置 FFmpeg (这可能需要几分钟)..."

    # 根据不同平台设置配置参数
    local configure_flags=(
        --prefix=/usr/local
        --enable-shared
        --disable-static
        --enable-gpl
        --enable-libmp3lame
        --enable-libopus
        --enable-libvorbis
        --enable-libvpx
        --enable-libx264
        --enable-libx265
        --enable-libwebp
        --enable-libfdk-aac
        --enable-nonfree
    )

    # macOS 特定配置
    if [[ "$OSTYPE" == "darwin"* ]]; then
        configure_flags+=(
            --extra-cflags="-I/usr/local/include -I$(brew --prefix libvpx)/include"
            --extra-ldflags="-L/usr/local/lib -L$(brew --prefix libvpx)/lib"
        )
    fi

    # 执行配置
    ./configure "${configure_flags[@]}" | tee $DOWNLOAD_DIR/ffmpeg_configure.log

    # 检查配置是否成功
    if [ $? -ne 0 ]; then
        echo "❌ 配置失败！请查看 $DOWNLOAD_DIR/ffmpeg_configure.log 文件中的错误信息"
        exit 1
    fi

    # 编译
    echo "🔨 编译 FFmpeg (这可能需要较长时间)..."
    local cores=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu || echo 4)
    make -j$cores | tee $DOWNLOAD_DIR/ffmpeg_make.log

    if [ $? -ne 0 ]; then
        echo "❌ 编译失败！请查看 $DOWNLOAD_DIR/ffmpeg_make.log 文件中的错误信息"
        exit 1
    fi

    # 安装
    echo "📦 安装 FFmpeg..."
    sudo make install | tee $DOWNLOAD_DIR/ffmpeg_install.log

    if [ $? -ne 0 ]; then
        echo "❌ 安装失败！请查看 $DOWNLOAD_DIR/ffmpeg_install.log 文件中的错误信息"
        exit 1
    fi

    # 验证安装
    echo "🔍 验证安装..."
    ffmpeg -version

    if [ $? -eq 0 ]; then
        echo "🎉 FFmpeg 安装成功！"
        rm -rf $download_path
        # 成功后源码目录会被trap清理，无需手动调用
    else
        echo "❌ FFmpeg 安装验证失败"
        exit 1
    fi
}

# 主流程
main() {
    # 记录开始时间
    local start_time=$(date +%s)

    install_ffmpeg

    # 计算并显示总耗时
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo "⏱️  总耗时: $(($duration / 60)) 分 $(($duration % 60)) 秒"
}

main

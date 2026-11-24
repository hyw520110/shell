#!/bin/bash

# Android SDK 优化版自动安装脚本
# 适用于Linux系统，支持多种包管理器

set -euo pipefail  # 遇到错误立即退出，禁止未定义变量，管道错误也退出

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 默认变量定义
INSTALL_DIR="$HOME/Android/Sdk"
ANDROID_HOME="$INSTALL_DIR"
# 注意：这里使用的是截至2024年的版本，建议定期检查更新
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip"
# 可以通过命令行参数指定自定义URL
CUSTOM_CMDLINE_TOOLS_URL=""
TEMP_DIR=""
DOWNLOAD_DIR="$HOME/Downloads"
SKIP_JDK_INSTALLATION=0
FORCE_REINSTALL=0

# 定义默认的 Android SDK 组件版本
DEFAULT_BUILD_TOOLS_VERSIONS=("33.0.2" "34.0.0")
DEFAULT_PLATFORM_VERSIONS=("android-33" "android-34")
DEFAULT_SYSTEM_IMAGE="system-images;android-34;google_apis;x86_64"

# 获取最新 build-tools 版本的函数
get_latest_build_tools_version() {
    if [ -d "$ANDROID_HOME/build-tools" ]; then
        ls -v "$ANDROID_HOME/build-tools" 2>/dev/null | tail -n 1
    fi
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --install-dir DIR     指定安装目录 (默认: $HOME/Android/Sdk)"
    echo "  --download-dir DIR    指定下载目录 (默认: $HOME/Downloads)"
    echo "  --cmdline-tools-url URL  指定命令行工具下载URL (可选)"
    echo "  --skip-jdk            跳过JDK安装检查"
    echo "  --force-reinstall     强制重新安装 (备份现有安装)"
    echo "  --help                显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                            # 使用默认设置安装"
    echo "  $0 --install-dir /opt/android # 自定义安装路径"
    echo "  $0 --download-dir /tmp        # 自定义下载路径"
    echo "  $0 --cmdline-tools-url https://... # 自定义命令行工具URL"
    echo "  $0 --skip-jdk                 # 跳过JDK检查直接安装"
}

# 解析命令行参数
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --install-dir)
                INSTALL_DIR="$2"
                ANDROID_HOME="$INSTALL_DIR"
                shift 2
                ;;
            --download-dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            --cmdline-tools-url)
                CUSTOM_CMDLINE_TOOLS_URL="$2"
                shift 2
                ;;
            --skip-jdk)
                SKIP_JDK_INSTALLATION=1
                shift
                ;;
            --force-reinstall)
                FORCE_REINSTALL=1
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 如果提供了自定义URL，则使用它
    if [ -n "$CUSTOM_CMDLINE_TOOLS_URL" ]; then
        CMDLINE_TOOLS_URL="$CUSTOM_CMDLINE_TOOLS_URL"
        log_info "使用自定义命令行工具URL: $CMDLINE_TOOLS_URL"
    fi
}

# 验证路径安全性
validate_path() {
    local path=$1
    if [[ "$path" =~ \.\.\/|\/\.\. ]]; then
        log_error "路径包含不安全的 '..' 组件: $path"
        exit 1
    fi
}

# 检查必要工具
check_dependencies() {
    local deps=("wget" "unzip" "java")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "缺少必要工具: ${missing_deps[*]}"
        if [ "$missing_deps" != "java" ]; then
            exit 1
        fi
    fi
}

# 检查下载文件的完整性
check_file_integrity() {
    local file_path=$1
    local url=$2

    if [ ! -f "$file_path" ]; then
        return 1
    fi

    # 获取远程文件大小（如果可能）
    local remote_size
    remote_size=$(curl -sI "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n')

    if [ -n "$remote_size" ]; then
        local local_size
        local_size=$(stat -c%s "$file_path")

        if [ "$local_size" -eq "$remote_size" ]; then
            log_info "本地文件大小与远程文件匹配: $(basename "$file_path")"
            return 0
        else
            log_warn "本地文件大小 ($local_size) 与远程文件大小 ($remote_size) 不匹配"
            return 1
        fi
    else
        # 如果无法获取远程大小，至少检查文件存在且非空
        if [ -s "$file_path" ]; then
            log_info "本地文件存在且非空: $(basename "$file_path")"
            return 0
        else
            return 1
        fi
    fi
}

# 检查系统是否支持多线程下载
check_multithread_support() {
    if command -v aria2c &> /dev/null; then
        log_debug "检测到 aria2c，支持多线程下载"
        return 0
    elif command -v axel &> /dev/null; then
        log_debug "检测到 axel，支持多线程下载"
        return 0
    else
        log_debug "未检测到多线程下载工具，将使用 wget"
        return 1
    fi
}

# 带重试的多线程下载函数
download_with_retry() {
    local url=$1
    local filename=$(basename "$url")
    local dest="$DOWNLOAD_DIR/$filename"  # 使用指定的下载目录
    local max_attempts=3
    local attempt=1

    # 检查是否本地已存在完整文件
    if check_file_integrity "$dest" "$url"; then
        log_info "使用已存在的文件: $dest"
        return 0
    fi

    log_info "文件不存在或不完整，开始下载: $filename"

    # 根据可用工具选择下载方法
    if check_multithread_support; then
        # 使用 aria2c 进行多线程下载
        if command -v aria2c &> /dev/null; then
            log_info "使用 aria2c 进行多线程下载 (16 线程)"
            while [ $attempt -le $max_attempts ]; do
                log_info "尝试下载 ($attempt/$max_attempts): $filename"
                # 使用 aria2c 进行多线程下载，支持断点续传
                if aria2c -x 16 -s 16 --continue=true --max-tries="$max_attempts" --timeout=30 --auto-save-interval=5 --dir="$DOWNLOAD_DIR" --out="$filename" "$url"; then
                    if check_file_integrity "$dest" "$url"; then
                        log_info "多线程下载成功: $filename"
                        return 0
                    else
                        log_error "下载的文件可能不完整，尝试重新下载"
                    fi
                fi
                attempt=$((attempt + 1))
                sleep 5
            done
        # 使用 axel 进行多线程下载（备用方案）
        elif command -v axel &> /dev/null; then
            log_info "使用 axel 进行多线程下载 (10 线程)"
            while [ $attempt -le $max_attempts ]; do
                log_info "尝试下载 ($attempt/$max_attempts): $filename"
                # 使用 axel 进行多线程下载，支持断点续传
                if axel -n 10 -a -c --max-redirect=3 "$url" -o "$dest"; then
                    if check_file_integrity "$dest" "$url"; then
                        log_info "多线程下载成功: $filename"
                        return 0
                    else
                        log_error "下载的文件可能不完整，尝试重新下载"
                    fi
                fi
                attempt=$((attempt + 1))
                sleep 5
            done
        fi
    else
        # 如果没有多线程下载工具，回退到使用 wget 并启用断点续传
        log_warn "未找到多线程下载工具，使用 wget 进行断点续传下载"
        while [ $attempt -le $max_attempts ]; do
            log_info "尝试下载 ($attempt/$max_attempts): $filename"
            # 使用 wget 的断点续传功能 (-c) 和进度显示 (--show-progress)
            if wget -c --show-progress --timeout=30 --tries=2 "$url" -O "$dest"; then
                if check_file_integrity "$dest" "$url"; then
                    log_info "下载成功: $(basename "$dest")"
                    return 0
                else
                    log_error "下载的文件可能不完整，尝试重新下载"
                fi
            fi
            attempt=$((attempt + 1))
            sleep 5
        done
    fi

    log_error "下载失败，已达到最大重试次数: $filename"
    return 1
}

# 检查并安装 JDK
install_jdk_if_needed() {
    if [ "$SKIP_JDK_INSTALLATION" -eq 1 ]; then
        log_info "跳过JDK安装检查"
        return 0
    fi

    if command -v java &> /dev/null; then
        local java_version
        java_version=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2)
        log_info "已安装Java版本: $java_version"
        return 0
    fi

    log_info "Java 未找到，正在尝试安装 OpenJDK 11..."

    # 检查可用的包管理器并安装
    if command -v apt &> /dev/null; then
        log_info "检测到 apt 包管理器"
        sudo apt update || {
            log_error "apt update 失败"
            exit 1
        }
        sudo apt install -y openjdk-11-jdk || {
            log_error "安装 openjdk-11-jdk 失败"
            exit 1
        }
    elif command -v dnf &> /dev/null; then
        log_info "检测到 dnf 包管理器"
        sudo dnf install -y java-11-openjdk-devel || {
            log_error "安装 java-11-openjdk-devel 失败"
            exit 1
        }
    elif command -v yum &> /dev/null; then
        log_info "检测到 yum 包管理器"
        sudo yum install -y java-11-openjdk-devel || {
            log_error "安装 java-11-openjdk-devel 失败"
            exit 1
        }
    elif command -v pacman &> /dev/null; then
        log_info "检测到 pacman 包管理器"
        sudo pacman -S --noconfirm jdk11-openjdk || {
            log_error "安装 jdk11-openjdk 失败"
            exit 1
        }
    else
        log_error "错误：未找到 apt, dnf, yum 或 pacman 包管理器。请手动安装 JDK 11+。"
        exit 1
    fi

    log_info "JDK 安装完成"
}

# 检查现有安装
check_existing_installation() {
    if [ "$FORCE_REINSTALL" -eq 1 ]; then
        log_warn "强制重新安装模式，将删除现有安装: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
        return
    fi

    if [ -d "$INSTALL_DIR" ]; then
        log_warn "检测到现有安装: $INSTALL_DIR"

        # 检查现有的命令行工具版本
        if [ -d "$INSTALL_DIR/cmdline-tools/latest" ] || [ -d "$INSTALL_DIR/cmdline-tools" ]; then
            log_info "现有安装包含命令行工具，检查版本信息..."
            if [ -f "$INSTALL_DIR/cmdline-tools/latest/bin/sdkmanager" ]; then
                local current_version
                current_version=$("$INSTALL_DIR/cmdline-tools/latest/bin/sdkmanager" --version 2>/dev/null || echo "Unknown")
                log_info "当前安装的 sdkmanager 版本: $current_version"
            fi
        fi

        read -p "是否继续安装并覆盖现有文件? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "用户取消安装"
            exit 0
        fi

        # 创建备份而不是直接删除
        local backup_dir="$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "正在备份现有安装到: $backup_dir"
        mv "$INSTALL_DIR" "$backup_dir" || {
            log_error "无法创建备份，退出安装"
            exit 1
        }
    fi
}

# 清理函数
cleanup() {
    local exit_code=$?
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_debug "清理临时目录: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    exit $exit_code
}

# 设置环境变量
setup_environment() {
    log_info "设置环境变量..."

    # 从.bashrc中移除旧的Android SDK环境变量（如果有）
    # 创建备份
    if [ -f ~/.bashrc ]; then
        cp ~/.bashrc ~/.bashrc.backup.$(date +%Y%m%d_%H%M%S)
        log_info "已备份原始 ~/.bashrc 到 ~/.bashrc.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # 从.bashrc中移除任何现有的Android相关配置
    if grep -q "Android SDK\|# ANDROID\|ANDROID_HOME" ~/.bashrc 2>/dev/null; then
        sed -i '/Android SDK\|# ANDROID\|ANDROID_HOME/d' ~/.bashrc
        log_info "已从 ~/.bashrc 中移除旧的Android SDK配置"
    fi

    # 添加新的环境变量设置
    {
        echo ""
        echo "# Android SDK"
        echo "export ANDROID_HOME=$ANDROID_HOME"
        echo "export PATH=\$PATH:\$ANDROID_HOME/cmdline-tools/latest/bin"
        echo "export PATH=\$PATH:\$ANDROID_HOME/platform-tools"
        # 查找并添加最新的build-tools版本到PATH
        local latest_build_tools_version
        latest_build_tools_version=$(get_latest_build_tools_version)
        if [ -n "$latest_build_tools_version" ] && [ -d "$ANDROID_HOME/build-tools/$latest_build_tools_version" ]; then
            echo "export PATH=\$PATH:\$ANDROID_HOME/build-tools/$latest_build_tools_version"
            log_info "已将最新的 build-tools 版本添加到 PATH: $latest_build_tools_version"
        else
            log_warn "未找到 build-tools 目录或版本"
        fi
    } >> ~/.bashrc

    log_info "环境变量已正确添加到 ~/.bashrc"

    # 设置当前 shell 的环境变量
    export ANDROID_HOME
    export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
    export PATH=$PATH:$ANDROID_HOME/platform-tools
    # 查找并添加最新的build-tools版本到当前shell的PATH
    local latest_build_tools_version
    latest_build_tools_version=$(get_latest_build_tools_version)
    if [ -n "$latest_build_tools_version" ] && [ -d "$ANDROID_HOME/build-tools/$latest_build_tools_version" ]; then
        export PATH=$PATH:$ANDROID_HOME/build-tools/$latest_build_tools_version
        log_info "已将最新的 build-tools 版本添加到当前shell PATH: $latest_build_tools_version"
    else
        log_warn "未找到 build-tools 目录或版本用于当前shell"
    fi
}

# 主安装函数
main() {
    # 首先解析参数，这应该在任何其他逻辑之前
    parse_arguments "$@"

    log_info "开始安装 Android SDK..."

    # 验证路径
    validate_path "$INSTALL_DIR"

    # 检查依赖
    check_dependencies

    # 检查现有安装
    check_existing_installation

    # 创建安装目录和下载目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DOWNLOAD_DIR"

    # 设置清理函数
    trap cleanup EXIT

    # 创建临时目录
    TEMP_DIR=$(mktemp -d)
    log_debug "使用临时目录: $TEMP_DIR"

    # 安装JDK（如果需要）
    install_jdk_if_needed

    # 下载命令行工具
    log_info "正在下载 Android SDK Command-line Tools..."
    download_with_retry "$CMDLINE_TOOLS_URL" || exit 1

    # 解压工具（从下载目录直接解压到临时目录）
    local filename=$(basename "$CMDLINE_TOOLS_URL")
    local downloaded_file="$DOWNLOAD_DIR/$filename"

    # 验证下载文件
    if [ ! -f "$downloaded_file" ]; then
        log_error "下载的文件不存在: $downloaded_file"
        exit 1
    fi

    log_info "正在解压命令行工具..."
    unzip -q "$downloaded_file" -d "$TEMP_DIR/" || {
        log_error "解压失败: $downloaded_file"
        exit 1
    }

    # 重要修复：新版的命令行工具zip包中包含一个名为 cmdline-tools 的目录
    # 这个目录内还包含一个名为 latest 的子目录
    # 我们需要将内容移动到正确的位置
    log_debug "检查解压后的目录结构..."
    ls -la "$TEMP_DIR/"

    # 检查解压后的目录结构（新版结构）
    if [ -d "$TEMP_DIR/cmdline-tools" ]; then
        # 检查是否有嵌套的 cmdline-tools 目录结构（新版结构）
        if [ -d "$TEMP_DIR/cmdline-tools/cmdline-tools" ]; then
            # 如果解压后的目录中有 cmdline-tools/cmdline-tools，这可能不是预期结构
            # 实际的新版结构是 cmdline-tools/bin, cmdline-tools/lib 等
            # 我们需要将其移动到 INSTALL_DIR 并创建 latest 目录
            if [ -d "$INSTALL_DIR/cmdline-tools" ]; then
                log_warn "备份现有 cmdline-tools 目录"
                rm -rf "$INSTALL_DIR/cmdline-tools.old"
                mv "$INSTALL_DIR/cmdline-tools" "$INSTALL_DIR/cmdline-tools.old"
            fi
            # 创建目标目录
            mkdir -p "$INSTALL_DIR/cmdline-tools"
            # 移动内容
            mv "$TEMP_DIR/cmdline-tools"/* "$INSTALL_DIR/cmdline-tools/" 2>/dev/null || {
                # 如果移动失败，可能是因为目录已存在，尝试其他方式
                rm -rf "$INSTALL_DIR/cmdline-tools"
                mv "$TEMP_DIR/cmdline-tools" "$INSTALL_DIR/cmdline-tools"
            }
        else
            # 旧版或标准结构，直接移动整个目录
            if [ -d "$INSTALL_DIR/cmdline-tools" ]; then
                log_warn "备份现有 cmdline-tools 目录"
                rm -rf "$INSTALL_DIR/cmdline-tools.old"
                mv "$INSTALL_DIR/cmdline-tools" "$INSTALL_DIR/cmdline-tools.old"
            fi
            mv "$TEMP_DIR/cmdline-tools" "$INSTALL_DIR/"
        fi
    else
        log_error "错误：解压后的 cmdline-tools 目录不存在。"
        ls -la "$TEMP_DIR/"
        exit 1
    fi

    # 为新版本的命令行工具创建 latest 目录结构（新版推荐的目录结构）
    if [ -d "$INSTALL_DIR/cmdline-tools/bin" ]; then
        log_info "检测到新版命令行工具结构，设置 latest 目录..."
        # 创建 latest 目录结构
        mkdir -p "$INSTALL_DIR/cmdline-tools/latest"
        # 移动内容到 latest 目录，避免目录结构冲突
        if [ -d "$INSTALL_DIR/cmdline-tools/latest/bin" ]; then
            # 如果latest目录下已经有bin目录，说明结构已经正确
            log_info "命令行工具 latest 目录结构已存在"
        else
            # 将内容移动到 latest 目录
            find "$INSTALL_DIR/cmdline-tools" -maxdepth 1 -mindepth 1 -not -name "latest" -exec mv '{}' "$INSTALL_DIR/cmdline-tools/latest/" \; 2>/dev/null || true
        fi
        # 确保 tools/bin 目录存在
        if [ ! -d "$ANDROID_HOME/cmdline-tools/latest/bin" ]; then
            log_error "错误：Android SDK 命令行工具路径错误，路径不存在: $ANDROID_HOME/cmdline-tools/latest/bin"
            exit 1
        fi
    fi

    # 确保没有重复的命令行工具安装
    if [ -d "$INSTALL_DIR/cmdline-tools.old" ] && [ -d "$INSTALL_DIR/cmdline-tools/latest" ]; then
        log_info "清理旧的 cmdline-tools 目录..."
        rm -rf "$INSTALL_DIR/cmdline-tools.old"
    fi

    # 设置环境变量
    setup_environment

    # 使用 sdkmanager 安装基本组件
    log_info "正在安装基本 Android SDK 组件..."

    # 首先接受许可证
    log_debug "接受许可证..."
    # 正确的路径应该是 cmdline-tools/latest/bin/sdkmanager
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" --licenses > /dev/null 2>&1 || true

    # 安装组件
    log_debug "开始安装SDK组件..."
    install_sdk_components || {
        log_error "安装 Android SDK 组件失败。"
        exit 1
    }

    # 验证安装
    validate_installation

    log_info "Android SDK 安装完成！"
    log_info "请确保重启终端或执行 'source ~/.bashrc' 以使环境变量生效。"
    log_info "验证安装命令："
    log_info "   sdkmanager --version"
    log_info "   adb --version"
}

# 安装SDK组件
install_sdk_components() {
    # 构建要安装的组件列表
    local components=(
        "cmdline-tools;latest"
        "platform-tools"
    )

    # 添加默认平台版本
    for platform in "${DEFAULT_PLATFORM_VERSIONS[@]}"; do
        components+=("platforms;$platform")
    done

    # 添加默认构建工具版本
    for build_tool in "${DEFAULT_BUILD_TOOLS_VERSIONS[@]}"; do
        components+=("build-tools;$build_tool")
    done

    # 添加其他组件
    components+=(
        "emulator"
        "$DEFAULT_SYSTEM_IMAGE"
    )

    # 使用构建的组件列表进行安装
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" "${components[@]}"
}

# 验证安装是否成功
validate_installation() {
    log_info "验证安装..."

    # 检查关键目录是否存在
    local missing_dirs=()
    local dirs_to_check=(
        "$ANDROID_HOME/cmdline-tools/latest/bin"
        "$ANDROID_HOME/platform-tools"
    )

    # 添加默认平台版本到检查列表
    for platform in "${DEFAULT_PLATFORM_VERSIONS[@]}"; do
        dirs_to_check+=("$ANDROID_HOME/platforms/$platform")
    done

    # 添加默认build-tools版本到检查列表
    # 首先检查build-tools目录是否存在
    if [ -d "$ANDROID_HOME/build-tools" ]; then
        # 检查每个默认的build-tools版本
        local build_tools_found=0
        for build_tool in "${DEFAULT_BUILD_TOOLS_VERSIONS[@]}"; do
            if [ -d "$ANDROID_HOME/build-tools/$build_tool" ]; then
                dirs_to_check+=("$ANDROID_HOME/build-tools/$build_tool")
                build_tools_found=1
            fi
        done

        # 如果没有找到默认版本，检查是否有任何build-tools版本
        if [ $build_tools_found -eq 0 ]; then
            for build_tool_version in "$ANDROID_HOME/build-tools"/*; do
                if [ -d "$build_tool_version" ]; then
                    dirs_to_check+=("$build_tool_version")
                    build_tools_found=1
                    break
                fi
            done
        fi

        # 如果什么版本都没有找到，标记为缺失
        if [ $build_tools_found -eq 0 ]; then
            missing_dirs+=("$ANDROID_HOME/build-tools/*")
        fi
    else
        missing_dirs+=("$ANDROID_HOME/build-tools")
    fi

    for dir in "${dirs_to_check[@]}"; do
        if [ ! -d "$dir" ]; then
            missing_dirs+=("$dir")
        fi
    done

    if [ ${#missing_dirs[@]} -ne 0 ]; then
        log_error "安装验证失败，缺少以下目录："
        for dir in "${missing_dirs[@]}"; do
            log_error "  - $dir"
        done
        exit 1
    fi

    # 检查关键工具是否存在
    local missing_tools=()
    local tools_to_check=(
        "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
        "$ANDROID_HOME/platform-tools/adb"
    )

    for tool in "${tools_to_check[@]}"; do
        if [ ! -x "$tool" ]; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "安装验证失败，缺少以下工具："
        for tool in "${missing_tools[@]}"; do
            log_error "  - $tool"
        done
        exit 1
    fi

    # 验证关键工具是否能正常运行
    validate_sdk_tools

    log_info "安装验证成功！"
}

# 验证SDK工具是否正常运行
validate_sdk_tools() {
    log_info "验证SDK工具是否正常运行..."

    # 验证sdkmanager
    if ! "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --version &> /dev/null; then
        log_error "sdkmanager 无法正常运行"
        exit 1
    fi

    # 验证adb
    if ! "$ANDROID_HOME/platform-tools/adb" version &> /dev/null; then
        log_warn "adb 无法正常运行，但这可能不是致命错误"
    fi

    # 验证是否安装了必要组件
    if ! "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --list_installed | grep -q "build-tools"; then
        log_warn "警告：可能未正确安装某些SDK组件"
    fi

    log_info "SDK工具验证通过"
}

# 执行主函数
main "$@"
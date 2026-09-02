#!/bin/bash

# Gradle一键安装配置脚本
# 支持多版本安装、国内镜像源、环境变量自动配置

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
        exec sudo "$0" "$@"
    fi
}

# ============================================
# 安装配置
# ============================================

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # 无颜色

# === 常量定义 ===
readonly DEFAULT_GRADLE_VERSION="8.10.2"
readonly GRADLE_RELEASE_URL="https://services.gradle.org/distributions/"
readonly DEFAULT_INSTALL_DIR="$HOME/gradle"
readonly DEFAULT_GRADLE_USER_HOME="$HOME/.gradle"
readonly ALIYUN_MIRROR="https://mirrors.aliyun.com/gradle/"
readonly HUAWEI_MIRROR="https://mirrors.huaweicloud.com/gradle/"
readonly TENCENT_MIRROR="https://mirrors.cloud.tencent.com/gradle/"
readonly OFFICIAL_MIRROR="https://services.gradle.org/distributions/"

# === 全局变量 ===
GRADLE_VERSION="$DEFAULT_GRADLE_VERSION"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
GRADLE_USER_HOME="$DEFAULT_GRADLE_USER_HOME"
USE_MIRROR="$HUAWEI_MIRROR"
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_SHELL_CONFIG=false
FORCE_REINSTALL=false

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "gradle" ]; then
        echo "$input"
    else
        echo "$input/gradle"
    fi
}

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Gradle一键安装配置脚本

用法: ./install-gradle.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -v, --version VERSION       指定Gradle版本 (默认: 8.10.2)
    -d, --dir DIR               安装父目录或实际安装目录 (默认: ~/gradle)
    -m, --mirror MIRROR         Gradle镜像源 (aliyun|huawei|tencent|official)
    --dry-run                   试运行模式，显示将要执行的操作但不实际执行
    --uninstall                 卸载Gradle
    --skip-shell-config         跳过shell配置文件修改
    --force                     强制重新安装，即使已安装

镜像源说明:
    aliyun    - 阿里云镜像 (https://mirrors.aliyun.com/gradle/)
    huawei    - 华为云镜像 (https://mirrors.huaweicloud.com/gradle/)
    tencent   - 腾讯云镜像 (https://mirrors.cloud.tencent.com/gradle/)
    official  - 官方源 (https://services.gradle.org/distributions/)

示例:
    ./install-gradle.sh                           # 使用默认设置安装
    ./install-gradle.sh --version 8.5.0          # 安装特定版本
    ./install-gradle.sh --mirror aliyun          # 使用阿里云镜像
    ./install-gradle.sh --uninstall              # 卸载Gradle
    ./install-gradle.sh --dry-run                # 试运行模式

使用指南:
    1. 安装完成后，重启终端或执行: source ~/.zshrc (或 ~/.bashrc)
    2. 验证安装: gradle --version
    3. 创建项目: gradle init
    4. 构建项目: gradle build
    5. 运行测试: gradle test

更多信息: https://gradle.org/
EOF
}

# === 检测操作系统 ===
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "darwin";;
        CYGWIN*|MINGW*) echo "windows";;
        *)          echo "unknown";;
    esac
}

# === 检测系统架构 ===
detect_architecture() {
    case "$(uname -m)" in
        x86_64)     echo "amd64";;
        aarch64|arm64) echo "aarch64";;
        armv7l)     echo "arm";;
        *)          echo "unknown";;
    esac
}

# === 获取shell配置文件 ===
get_shell_config_file() {
    local shell_name
    shell_name="$(basename "$SHELL")"

    case "$shell_name" in
        zsh)
            if [ -f "$HOME/.zshrc" ]; then
                echo "$HOME/.zshrc"
            elif [ -f "$HOME/.zprofile" ]; then
                echo "$HOME/.zprofile"
            else
                echo "$HOME/.zshrc"
            fi
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.profile"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                GRADLE_VERSION="$2"
                shift 2
                ;;
            -d|--dir)
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            -m|--mirror)
                case "$2" in
                    aliyun)
                        USE_MIRROR="$ALIYUN_MIRROR"
                        ;;
                    huawei)
                        USE_MIRROR="$HUAWEI_MIRROR"
                        ;;
                    tencent)
                        USE_MIRROR="$TENCENT_MIRROR"
                        ;;
                    official)
                        USE_MIRROR="$OFFICIAL_MIRROR"
                        ;;
                    *)
                        print_error "不支持的镜像源: $2"
                        print_info "支持的镜像源: aliyun, huawei, tencent, official"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --skip-shell-config)
                SKIP_SHELL_CONFIG=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查依赖 ===
check_dependencies() {
    local missing_deps=()

    for dep in curl tar unzip; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少依赖: ${missing_deps[*]}"
        print_info "请先安装缺少的依赖，然后重试"
        exit 1
    fi
}

# === 获取Gradle版本URL ===
get_gradle_download_url() {
    local version="$1"

    # 格式化版本号（移除v前缀）
    version="${version#v}"

    # 构建下载URL - 使用bin版本
    local filename="gradle-${version}-bin.zip"
    echo "${USE_MIRROR}${filename}"
}

# === 检查Gradle是否已安装 ===
check_gradle_installed() {
    # 先检查命令是否在 PATH
    if command -v gradle &> /dev/null; then
        return 0
    fi
    # 再检查安装目录是否存在
    if [ -d "$INSTALL_DIR/gradle-current" ] && [ -f "$INSTALL_DIR/gradle-current/bin/gradle" ]; then
        return 0
    fi
    return 1
}

# === 下载Gradle ===
download_gradle() {
    local download_url="$1"
    local archive_file="$2"
    local filename="$(basename "$archive_file")"

    # 检查文件是否已存在且有效
    if check_file_valid "$archive_file" 1000000; then  # 至少1MB
        print_info "文件已存在且有效: $archive_file"
        return 0
    fi

    print_header "下载Gradle..."
    download_with_adl "$download_url" "$archive_file"

    # 验证下载的文件
    if ! check_file_valid "$archive_file" 1000000; then
        print_error "下载的文件无效或太小"
        rm -f "$archive_file"
        exit 1
    fi

    # 检查压缩包是否有效
    if ! unzip -t "$archive_file" &> /dev/null; then
        print_error "下载的文件不是有效的zip文件"
        rm -f "$archive_file"
        exit 1
    fi

    print_success "下载完成: $filename"
}

# === 安装Gradle ===
install_gradle() {
    local download_url
    local archive_file

    download_url=$(get_gradle_download_url "$GRADLE_VERSION")
    local filename="gradle-${GRADLE_VERSION}-bin.zip"
    archive_file="$DOWNLOAD_DIR/$filename"

    print_info "准备安装 Gradle $GRADLE_VERSION"
    print_info "安装目录: $INSTALL_DIR"
    print_info "Gradle User Home: $GRADLE_USER_HOME"
    print_info "镜像源: $USE_MIRROR"

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将下载 $download_url"
        print_info "将下载到: $archive_file"
        print_info "将解压到 $INSTALL_DIR"
        return 0
    fi

    # 确保下载目录存在
    mkdir -p "$DOWNLOAD_DIR"

    # 下载Gradle
    download_gradle "$download_url" "$archive_file"

    print_header "解压Gradle..."

    # 删除旧的安装目录
    if [ -d "$INSTALL_DIR/gradle-$GRADLE_VERSION" ]; then
        print_warning "删除现有安装目录: $INSTALL_DIR/gradle-$GRADLE_VERSION"
        rm -rf "$INSTALL_DIR/gradle-$GRADLE_VERSION"
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 解压Gradle
    if ! unzip -q "$archive_file" -d "$INSTALL_DIR"; then
        print_error "解压失败"
        rm -rf "$INSTALL_DIR/gradle-$GRADLE_VERSION"
        exit 1
    fi

    print_success "解压完成"

    # 创建符号链接
    if [ -L "$INSTALL_DIR/gradle-current" ]; then
        rm "$INSTALL_DIR/gradle-current"
    fi
    ln -sf "$INSTALL_DIR/gradle-$GRADLE_VERSION" "$INSTALL_DIR/gradle-current"
    print_success "创建符号链接: $INSTALL_DIR/gradle-current"

    # 配置Gradle镜像源
    configure_gradle_mirror

    # 清理下载文件
    rm -f "$archive_file"
}

# === 配置Gradle镜像源 ===
configure_gradle_mirror() {
    print_header "配置Gradle镜像源..."

    # 创建gradle配置目录
    local gradle_config_dir="$GRADLE_USER_HOME"
    mkdir -p "$gradle_config_dir"

    # 创建init.gradle文件
    local init_file="$gradle_config_dir/init.gradle"

    cat > "$init_file" << 'EOF'
allprojects {
    repositories {
        mavenLocal()
        maven { url 'https://maven.aliyun.com/repository/public/' }
        maven { url 'https://maven.aliyun.com/repository/spring/' }
        maven { url 'https://maven.aliyun.com/repository/spring-plugin/' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin/' }
        maven { url 'https://maven.aliyun.com/repository/google/' }
        maven { url 'https://maven.aliyun.com/repository/apache-snapshots/' }
        maven { url 'https://maven.aliyun.com/repository/central/' }
        mavenCentral()
        google()
    }

    buildscript {
        repositories {
            maven { url 'https://maven.aliyun.com/repository/public/' }
            maven { url 'https://maven.aliyun.com/repository/spring/' }
            maven { url 'https://maven.aliyun.com/repository/gradle-plugin/' }
            maven { url 'https://maven.aliyun.com/repository/google/' }
            maven { url 'https://maven.aliyun.com/repository/central/' }
            mavenCentral()
            google()
        }
    }
}
EOF

    print_success "Gradle镜像源配置完成: $init_file"
}

# === 配置shell环境 ===
configure_shell() {
    if [ "$SKIP_SHELL_CONFIG" = true ]; then
        print_info "跳过shell配置"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将配置shell环境变量"
        return 0
    fi

    local config_file
    config_file=$(get_shell_config_file)

    print_info "配置shell环境: $config_file"

    # 检查是否已配置
    if grep -q "GRADLE_HOME" "$config_file" 2>/dev/null; then
        if [ "$FORCE_REINSTALL" = false ]; then
            print_warning "Gradle环境变量已配置，跳过添加"
            print_info "使用 --force 选项强制重新配置"
            return 0
        fi

        # 删除旧的Gradle配置
        print_info "删除旧的Gradle配置..."
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# Gradle环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        else
            sed -i '/# Gradle环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        fi
    fi

    # 添加新的Gradle配置
    cat >> "$config_file" << 'EOF'

# Gradle环境配置
export GRADLE_HOME=$HOME/.gradle/gradle-current
export PATH=$GRADLE_HOME/bin:$PATH
export GRADLE_USER_HOME=$HOME/.gradle
EOF

    # 替换为实际的路径
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|export GRADLE_HOME=\$HOME/.gradle/gradle-current|export GRADLE_HOME=$INSTALL_DIR/gradle-current|" "$config_file"
        sed -i '' "s|export GRADLE_USER_HOME=\$HOME/.gradle|export GRADLE_USER_HOME=$GRADLE_USER_HOME|" "$config_file"
    else
        sed -i "s|export GRADLE_HOME=\$HOME/.gradle/gradle-current|export GRADLE_HOME=$INSTALL_DIR/gradle-current|" "$config_file"
        sed -i "s|export GRADLE_USER_HOME=\$HOME/.gradle|export GRADLE_USER_HOME=$GRADLE_USER_HOME|" "$config_file"
    fi

    print_success "Gradle环境变量已配置"
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."

    # 临时添加到PATH
    export PATH="$INSTALL_DIR/gradle-current/bin:$PATH"

    if ! command -v gradle &> /dev/null; then
        print_error "Gradle未正确安装或不在PATH中"
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
        return 1
    fi

    local installed_version
    installed_version=$(gradle --version | grep "Gradle" | head -1)
    print_success "Gradle安装成功!"
    print_info "版本: $installed_version"
    print_info "GRADLE_HOME: $INSTALL_DIR/gradle-current"
    print_info "GRADLE_USER_HOME: $GRADLE_USER_HOME"

    # 测试Gradle命令
    if gradle --version &> /dev/null; then
        print_success "Gradle命令测试通过"
    else
        print_warning "Gradle命令测试失败，请检查环境配置"
    fi

    return 0
}

# === 卸载Gradle ===
uninstall_gradle() {
    print_header "卸载Gradle..."

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        print_info "  Gradle配置: $GRADLE_USER_HOME"
        return 0
    fi

    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi

    # 清理shell配置
    local config_file
    config_file=$(get_shell_config_file)

    if [ -f "$config_file" ] && grep -q "Gradle环境配置" "$config_file"; then
        print_info "清理shell配置: $config_file"
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# Gradle环境配置/,/^$/d' "$config_file"
        else
            sed -i '/# Gradle环境配置/,/^$/d' "$config_file"
        fi
        print_success "Shell配置已清理"
    fi

    print_success "Gradle卸载完成"
    print_info "请重启终端或执行: source $config_file"
}

# === 主函数 ===
main() {
    print_header "Gradle一键安装配置脚本"

    # 解析参数
    parse_arguments "$@"

    # 检查依赖
    check_dependencies

    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_gradle
        return 0
    fi

    # 检查是否已安装
    if check_gradle_installed && [ "$FORCE_REINSTALL" = false ]; then
        print_info "Gradle已安装"
        print_info "使用 --force 选项强制重新安装"

        # 尝试获取版本信息
        if command -v gradle &> /dev/null; then
            local current_version
            current_version=$(gradle --version | grep "Gradle" | head -1)
            print_info "当前版本: $current_version"

            # 显示当前配置
            print_info "当前配置:"
            print_info "  GRADLE_HOME: $(gradle --version | grep 'GRADLE_HOME' | awk '{print $2}')"
            print_info "  GRADLE_USER_HOME: $(gradle --version | grep 'Gradle user home' | awk '{print $4}')"
        else
            print_info "  命令尚未加载到 PATH，请执行: source $(get_shell_config_file)"
        fi

        return 0
    fi

    # 安装Gradle
    install_gradle

    # 配置shell环境
    configure_shell

    # 验证安装
    verify_installation

    print_header "安装完成!"
    print_success "Gradle已成功安装并配置"

    if [ "$SKIP_SHELL_CONFIG" = false ]; then
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
    fi

    print_info "开始使用Gradle吧!"
}

# === 执行主函数 ===
main "$@"

#!/bin/bash

# Maven Daemon (mvnd) 一键安装配置脚本
# Maven Daemon 是 Maven 的守护进程版本，提供更快的构建速度

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
    else
        if command -v curl >/dev/null 2>&1; then
            curl -L --fail -o "$output" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$output" "$url"
        else
            echo "错误: 未找到可用下载工具，请安装 adl、curl 或 wget"
            return 1
        fi
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
readonly DEFAULT_MVND_VERSION="latest"
readonly MVND_DIR="$HOME/mvnd"
readonly MAVEN_MIRROR_ALIYUN="https://maven.aliyun.com/repository/public"
readonly MAVEN_MIRROR_TENCENT="https://mirrors.cloud.tencent.com/nexus/repository/maven-public/"
readonly MAVEN_MIRROR_HUAWEI="https://mirrors.huaweicloud.com/repository/maven/"
readonly DEFAULT_LOCAL_REPO="$HOME/.m2/repository"

# === 全局变量 ===
SCRIPT_NAME="$(basename "$0")"
MVND_VERSION="$DEFAULT_MVND_VERSION"
INSTALL_DIR="$MVND_DIR"
LOCAL_REPO="$DEFAULT_LOCAL_REPO"
USE_MIRROR="$MAVEN_MIRROR_ALIYUN"
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_SHELL_CONFIG=false
FORCE_REINSTALL=false
INTERACTIVE=true

normalize_install_dir() {
    local input="${1:-$MVND_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "mvnd" ]; then
        echo "$input"
    else
        echo "$input/mvnd"
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

# === 检查命令是否存在 ===
command_exists() {
    command -v "$1" &>/dev/null
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

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Maven Daemon (mvnd) 一键安装配置脚本

Maven Daemon 是 Apache Maven 的守护进程版本，提供更快的构建速度和更好的用户体验。
它通过在后台保持 JVM 进程运行，避免了每次构建都启动 JVM 的开销。

用法: ./install-mvnd.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -v, --version VERSION       指定mvnd版本 (默认: latest，自动获取最新版本)
    -d, --dir DIR               安装父目录或实际安装目录 (默认: ~/mvnd)
    -r, --repo DIR              本地仓库路径 (默认: ~/.m2/repository)
    -m, --mirror MIRROR         Maven镜像源 (aliyun|tencent|huawei|official)
    --dry-run                   试运行模式，显示将要执行的操作但不实际执行
    --uninstall                 卸载mvnd
    --skip-shell-config         跳过shell配置文件修改
    --force                     强制重新安装，即使已安装
    --non-interactive           非交互模式，自动确认所有操作

镜像源说明:
    aliyun    - 阿里云镜像 (https://maven.aliyun.com/repository/public) [默认]
    tencent   - 腾讯云镜像 (https://mirrors.cloud.tencent.com/nexus/repository/maven-public/)
    huawei    - 华为云镜像 (https://mirrors.huaweicloud.com/repository/maven/)
    official  - 官方源 (不使用镜像)

示例:
    ./install-mvnd.sh                           # 使用默认设置安装
    ./install-mvnd.sh --version 1.0-m4          # 安装特定版本
    ./install-mvnd.sh --mirror tencent          # 使用腾讯云镜像
    ./install-mvnd.sh --repo ~/maven-repo       # 自定义本地仓库
    ./install-mvnd.sh --uninstall               # 卸载mvnd
    ./install-mvnd.sh --dry-run                 # 试运行模式

使用指南:
    1. 安装完成后，重启终端或执行: source ~/.zshrc (或 ~/.bashrc)
    2. 验证安装: mvnd --version
    3. 创建项目: mvnd archetype:generate -DgroupId=com.example -DartifactId=myapp
    4. 编译项目: mvnd clean compile
    5. 运行项目: mvnd exec:java -Dexec.mainClass="com.example.App"

mvnd 与 mvn 的区别:
    - mvnd 使用守护进程，构建速度更快（通常快 20-50%）
    - mvnd 支持并行构建，充分利用多核 CPU
    - mvnd 命令与 mvn 完全兼容，可以直接替换使用
    - mvnd 在后台保持 JVM 进程运行，避免重复启动开销

更多信息: https://github.com/apache/maven-mvnd
EOF
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
                # 检查是否有第二个参数
                if [[ -z "$2" ]] || [[ "$2" == -* ]]; then
                    # 没有版本号参数，检测已安装的版本
                    check_mvnd_installed --quiet
                    exit 0
                else
                    MVND_VERSION="$2"
                    shift 2
                fi
                ;;
            -d|--dir)
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            -r|--repo)
                LOCAL_REPO="$2"
                shift 2
                ;;
            -m|--mirror)
                case "$2" in
                    aliyun)
                        USE_MIRROR="$MAVEN_MIRROR_ALIYUN"
                        ;;
                    tencent)
                        USE_MIRROR="$MAVEN_MIRROR_TENCENT"
                        ;;
                    huawei)
                        USE_MIRROR="$MAVEN_MIRROR_HUAWEI"
                        ;;
                    official)
                        USE_MIRROR=""
                        ;;
                    *)
                        print_error "不支持的镜像源: $2"
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
            --non-interactive)
                INTERACTIVE=false
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

    for dep in curl tar jq; do
        if ! command_exists "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少依赖: ${missing_deps[*]}"
        print_info "请先安装缺少的依赖"

        # 尝试自动安装依赖
        if [[ "$INTERACTIVE" == true ]]; then
            read -p "是否尝试自动安装依赖? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_dependencies "${missing_deps[@]}"
            else
                exit 1
            fi
        else
            exit 1
        fi
    fi
}

# === 安装依赖 ===
install_dependencies() {
    local deps=("$@")
    local os_type=$(detect_os)

    print_info "正在安装依赖: ${deps[*]}"

    case "$os_type" in
        linux)
            if command_exists apt-get; then
                sudo apt-get update && sudo apt-get install -y "${deps[@]}"
            elif command_exists yum; then
                sudo yum install -y "${deps[@]}"
            elif command_exists dnf; then
                sudo dnf install -y "${deps[@]}"
            elif command_exists pacman; then
                sudo pacman -S --noconfirm "${deps[@]}"
            else
                print_error "无法识别的 Linux 包管理器"
                exit 1
            fi
            ;;
        darwin)
            if command_exists brew; then
                brew install "${deps[@]}"
            else
                print_error "需要 Homebrew 来安装依赖"
                print_info "请安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                exit 1
            fi
            ;;
        *)
            print_error "不支持的操作系统: $os_type"
            exit 1
            ;;
    esac
}

# === 获取最新版本 ===
get_latest_version() {
    local GITHUB_REPO="https://api.github.com/repos/apache/maven-mvnd/releases/latest"

    local json_response
    json_response=$(curl -sL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Mozilla/5.0" "${GITHUB_REPO}")

    if [ -z "${json_response}" ] || echo "${json_response}" | grep -q "API rate limit exceeded"; then
        return 1
    fi

    local latest_version
    latest_version=$(echo "${json_response}" | jq -r '.tag_name' | sed 's/^maven-mvnd-//' | sed 's/^v//')

    if [[ -z "$latest_version" ]] || [[ "$latest_version" == "null" ]]; then
        return 1
    fi

    echo "$latest_version"
    return 0
}

# === 检测 mvnd 是否已安装 ===
check_mvnd_installed() {
    local quiet_mode=false
    if [[ "$1" == "--quiet" ]]; then
        quiet_mode=true
    fi

    local version=""

    # 快速方法：从安装目录读取版本信息
    if [ -d "$INSTALL_DIR" ]; then
        # 方法1：从mvn/lib/mvnd目录读取jar文件名
        local mvnd_lib=$(find "$INSTALL_DIR/mvn/lib/mvnd" -name "mvnd-client-*.jar" 2>/dev/null | head -1)
        if [[ -n "$mvnd_lib" ]] && [[ -f "$mvnd_lib" ]]; then
            version=$(basename "$mvnd_lib" | sed 's/mvnd-client-//' | sed 's/\.jar$//')
        fi

        # 方法2：从mvn/lib目录读取mvnd-logging文件名
        if [[ -z "$version" ]]; then
            local mvnd_logging=$(find "$INSTALL_DIR/mvn/lib" -name "mvnd-logging-*.jar" 2>/dev/null | head -1)
            if [[ -n "$mvnd_logging" ]] && [[ -f "$mvnd_logging" ]]; then
                version=$(basename "$mvnd_logging" | sed 's/mvnd-logging-//' | sed 's/\.jar$//')
            fi
        fi

        # 方法3：从bin/mvnd文件读取版本
        if [[ -z "$version" ]] && [[ -f "$INSTALL_DIR/bin/mvnd" ]]; then
            version=$(grep -o "mvnd [0-9][0-9.]*" "$INSTALL_DIR/bin/mvnd" 2>/dev/null | head -1 | awk '{print $2}')
        fi

        # 方法4：从release文件读取
        if [[ -z "$version" ]] && [[ -f "$INSTALL_DIR/release" ]]; then
            version=$(cat "$INSTALL_DIR/release" 2>/dev/null | grep -o "[0-9][0-9.]*" | head -1)
        fi
    fi

    # 如果快速方法失败，使用mvnd命令（慢速方法）
    if [[ -z "$version" ]] && command_exists mvnd &> /dev/null; then
        version=$(mvnd --version 2>&1 | grep -i "maven daemon" | head -1)
    fi

    # 判断是否已安装
    if [[ -n "$version" ]]; then
        if $quiet_mode; then
            # 静默模式，只输出版本信息
            echo "$version"
        else
            # 正常模式，输出详细信息
            print_info "检测到已安装的 mvnd: $version"
        fi
        return 0
    else
        if $quiet_mode; then
            echo ""
        fi
        return 1
    fi
}

# === 下载mvnd ===
download_mvnd() {
    local version="$1"
    local os_type=$(detect_os)
    local arch_type=$(detect_architecture)

    if [[ "$os_type" == "unknown" ]]; then
        print_error "不支持的操作系统"
        exit 1
    fi

    if [[ "$arch_type" == "unknown" ]]; then
        print_error "不支持的系统架构"
        exit 1
    fi

    # 确定平台名称
    local platform_name
    case "$os_type" in
        linux)
            platform_name="linux-${arch_type}"
            ;;
        darwin)
            platform_name="darwin-${arch_type}"
            ;;
        windows)
            platform_name="windows-${arch_type}"
            ;;
    esac

    # 获取最新版本信息
    local download_url
    local filename

    if [[ "$version" == "latest" ]]; then
        print_info "正在从 GitHub 获取最新版本信息..."
        local latest_version
        if ! latest_version=$(get_latest_version); then
            print_error "无法获取最新版本信息"
            exit 1
        fi

        version="$latest_version"
        MVND_VERSION="$latest_version" # 更新全局变量，以便 install_mvnd 使用
        print_info "最新版本: $version"
    fi

    # 直接构造 GitHub 下载 URL（更可靠，避免 API 限流）
    # 注意：URL 路径使用裸版本号（如 1.0.5），不是 maven-mvnd-1.0.5
    local github_base="https://github.com/apache/maven-mvnd/releases/download"
    download_url="${github_base}/${version}/maven-mvnd-${version}-${platform_name}.tar.gz"

    filename=$(basename "$download_url")
    local download_file="$DOWNLOAD_DIR/$filename"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将下载: $download_url"
        print_info "[试运行] 保存到: $download_file"
        return 0
    fi

    # 检查文件是否已存在且有效
    if check_file_valid "$download_file" 1000000; then  # 至少1MB
        print_info "发现已存在的下载文件: $download_file"

        # 验证文件完整性
        print_info "验证文件完整性..."
        if tar -tzf "$download_file" >/dev/null 2>&1; then
            print_success "文件完整性验证通过，跳过下载"
            return 0
        else
            print_warning "文件已损坏，将重新下载"
            rm -f "$download_file"
        fi
    fi

    # 使用统一的下载工具
    print_info "正在下载: $filename"
    download_with_adl "$download_url" "$download_file"

    # 验证文件完整性
    print_info "验证文件完整性..."
    if ! tar -tzf "$download_file" >/dev/null 2>&1; then
        print_warning "文件完整性检查失败，准备重新处理..."
        rm -f "$download_file"
        exit 1
    fi

    print_success "下载完成: $filename"
}

# === 安装mvnd ===
install_mvnd() {
    local version="$1"
    local os_type=$(detect_os)
    local arch_type=$(detect_architecture)

    # 确定平台名称
    local platform_name
    case "$os_type" in
        linux)
            platform_name="linux-${arch_type}"
            ;;
        darwin)
            platform_name="darwin-${arch_type}"
            ;;
        windows)
            platform_name="windows-${arch_type}"
            ;;
    esac

    # 确定文件名
    local filename="maven-mvnd-${version}-${platform_name}.tar.gz"
    local download_file="$DOWNLOAD_DIR/$filename"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将解压: $download_file 到 $INSTALL_DIR"
        return 0
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 解压文件
    print_info "正在解压文件..."
    if ! tar -xzf "$download_file" -C "$INSTALL_DIR" --strip-components=1; then
        print_error "解压失败"
        exit 1
    fi

    print_success "文件解压成功"

    # 确保 mvnd 可执行文件存在并添加权限
    if [[ -f "$INSTALL_DIR/bin/mvnd" ]]; then
        chmod +x "$INSTALL_DIR/bin/mvnd"
        print_success "已添加执行权限"
    else
        # 尝试在解压后的目录中查找 mvnd
        local found_mvnd=$(find "$INSTALL_DIR" -type f -name mvnd | head -1)
        if [[ -n "$found_mvnd" ]]; then
            chmod +x "$found_mvnd"
            print_success "已添加执行权限"
        else
            print_error "未找到 mvnd 可执行文件"
            exit 1
        fi
    fi

    # 清理下载文件
    rm -f "$download_file"
}

# === 配置Maven镜像源 ===
configure_maven_mirror() {
    if [[ -z "$USE_MIRROR" ]]; then
        print_info "使用官方源，跳过镜像配置"
        return 0
    fi

    print_info "配置 Maven 镜像源..."

    local settings_file="$HOME/.m2/settings.xml"

    # 创建 .m2 目录
    mkdir -p "$(dirname "$settings_file")"

    cat > "$settings_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">

    <!-- 本地仓库路径 -->
    <localRepository>$LOCAL_REPO</localRepository>

    <!-- 镜像配置 -->
    <mirrors>
        <mirror>
            <id>aliyun-maven</id>
            <mirrorOf>*</mirrorOf>
            <name>Aliyun Maven</name>
            <url>$USE_MIRROR</url>
        </mirror>
    </mirrors>

    <!-- 配置文件 -->
    <profiles>
        <profile>
            <id>default</id>
            <activation>
                <activeByDefault>true</activeByDefault>
            </activation>
            <properties>
                <maven.compiler.source>1.8</maven.compiler.source>
                <maven.compiler.target>1.8</maven.compiler.target>
                <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
            </properties>
        </profile>
    </profiles>
</settings>
EOF

    print_success "Maven 镜像源配置完成"
}

# === 配置shell环境 ===
configure_shell() {
    if [[ "$SKIP_SHELL_CONFIG" == true ]]; then
        print_info "跳过 shell 配置"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将配置 shell 环境变量"
        return 0
    fi

    local config_file
    config_file=$(get_shell_config_file)

    print_info "配置 shell 环境: $config_file"

    # 检查是否已配置
    if grep -q "MVND_HOME" "$config_file" 2>/dev/null; then
        if [[ "$FORCE_REINSTALL" == false ]]; then
            print_warning "mvnd 环境变量已配置，跳过添加"
            print_info "使用 --force 选项强制重新配置"
            return 0
        fi

        # 删除旧的 mvnd 配置
        print_info "删除旧的 mvnd 配置..."
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# mvnd环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        else
            sed -i '/# mvnd环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        fi
    fi

    # 添加新的 mvnd 配置
    cat >> "$config_file" << EOF

# mvnd环境配置
export MVND_HOME="$INSTALL_DIR"
export PATH="\$MVND_HOME/bin:\$PATH"
EOF

    print_success "mvnd 环境变量已配置"
}

# === 验证安装 ===
verify_installation() {
    print_info "验证安装..."

    # 临时添加到 PATH
    export PATH="$INSTALL_DIR/bin:$PATH"

    if ! command_exists mvnd &> /dev/null; then
        print_warning "mvnd 未在 PATH 中找到"
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
        return 1
    fi

    local installed_version
    installed_version=$(mvnd --version 2>/dev/null | head -n 1)
    print_success "mvnd 安装成功!"
    print_info "版本: $installed_version"
    print_info "安装目录: $INSTALL_DIR"

    # 测试 mvnd 命令
    if mvnd --version &> /dev/null; then
        print_success "mvnd 命令测试通过"
    else
        print_warning "mvnd 命令测试失败，请检查环境配置"
    fi

    return 0
}

# === 卸载mvnd ===
uninstall_mvnd() {
    print_info "卸载 mvnd..."

    if [[ "$INTERACTIVE" == true ]]; then
        read -p "确定要卸载 mvnd 吗? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "取消卸载"
            return 0
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[试运行] 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        return 0
    fi

    # 停止 mvnd 守护进程
    if command_exists mvnd &> /dev/null; then
        print_info "停止 mvnd 守护进程..."
        mvnd --stop &>/dev/null || true
    fi

    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi

    # 清理 shell 配置
    local config_file
    config_file=$(get_shell_config_file)

    if [[ -f "$config_file" ]] && grep -q "mvnd环境配置" "$config_file"; then
        print_info "清理 shell 配置: $config_file"
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# mvnd环境配置/,/^$/d' "$config_file"
        else
            sed -i '/# mvnd环境配置/,/^$/d' "$config_file"
        fi
        print_success "Shell 配置已清理"
    fi

    print_success "mvnd 卸载完成"
    print_info "请重启终端或执行: source $config_file"
}

# === 主函数 ===
main() {
    # 先解析参数，因为可能在参数处理中就需要退出
    parse_arguments "$@"

    # 打印标题
    print_header "Maven Daemon (mvnd) 一键安装配置脚本"

    # 检查依赖
    check_dependencies

    # 卸载模式
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_mvnd
        exit 0
    fi

    # 检查是否已安装
    if check_mvnd_installed && [[ "$FORCE_REINSTALL" == false ]]; then
        print_info "使用 --force 选项强制重新安装"

        # 显示当前配置
        if command_exists mvnd &> /dev/null; then
            print_info "当前配置:"
            mvnd --version 2>/dev/null | head -n 5
        fi

        exit 0
    fi

    # 下载 mvnd
    download_mvnd "$MVND_VERSION"

    # 安装 mvnd
    install_mvnd "$MVND_VERSION"

    # 配置 Maven 镜像源
    configure_maven_mirror

    # 配置 shell 环境
    configure_shell

    # 验证安装
    verify_installation

    print_header "安装完成!"
    print_success "mvnd 已成功安装并配置"
    print_info "安装目录: $INSTALL_DIR"
    print_info "配置文件: $HOME/.m2/settings.xml"
    print_info "本地仓库: $LOCAL_REPO"

    if [[ "$SKIP_SHELL_CONFIG" == false ]]; then
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
    fi

    print_info "开始使用 mvnd 吧！"
}

# === 执行主函数 ===
main "$@"

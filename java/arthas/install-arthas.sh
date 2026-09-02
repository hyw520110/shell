#!/bin/bash

# Arthas一键安装配置脚本
# Java诊断工具，支持在线诊断和问题排查

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
readonly NC='\033[0m'

# === 常量定义 ===
readonly ARTHAS_BOOT_URL="https://arthas.aliyun.com/arthas-boot.jar"
readonly ARTHAS_VERSION="3.7.2"
readonly DEFAULT_INSTALL_DIR="$HOME/arthas"
readonly OFFICIAL_REPO="https://github.com/alibaba/arthas"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_SHELL_CONFIG=false
FORCE_REINSTALL=false
TARGET_IP=""

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "arthas" ]; then
        echo "$input"
    else
        echo "$input/arthas"
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

# === 检查Arthas是否已安装 ===
check_arthas_installed() {
    local quiet_mode=false
    if [[ "$1" == "--quiet" ]]; then
        quiet_mode=true
    fi

    # 检查arthas-boot.jar是否存在
    if [ -f "$INSTALL_DIR/arthas-boot.jar" ]; then
        # 获取Arthas版本
        local version=""
        # 尝试从jar文件获取版本信息
        if command -v unzip &> /dev/null; then
            version=$(unzip -p "$INSTALL_DIR/arthas-boot.jar" META-INF/MANIFEST.MF 2>/dev/null | grep -i "Implementation-Version" | cut -d':' -f2 | tr -d ' \r')
        fi

        # 如果无法获取版本，使用默认版本号
        if [ -z "$version" ]; then
            version="$ARTHAS_VERSION"
        fi

        if $quiet_mode; then
            echo "$version"
        else
            print_info "检测到已安装的 Arthas: $version"
        fi
        return 0
    fi

    # 未安装
    if $quiet_mode; then
        echo ""
    else
        print_info "Arthas 未安装"
    fi
    return 1
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Arthas一键安装配置脚本

Arthas是阿里巴巴开源的Java诊断工具，支持在线诊断，无需重启服务。

用法: ./install-arthas.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装父目录或实际安装目录 (默认: ~/arthas)
    --target-ip IP              目标IP地址（用于远程诊断）
    --dry-run                   试运行模式
    --uninstall                 卸载Arthas
    --skip-shell-config         跳过shell配置文件修改
    --force                     强制重新安装

示例:
    ./install-arthas.sh                           # 使用默认设置安装
    ./install-arthas.sh --target-ip 192.168.1.100  # 指定目标IP
    ./install-arthas.sh --uninstall               # 卸载Arthas
    ./install-arthas.sh --dry-run                 # 试运行模式

使用指南:
    1. 安装完成后，重启终端或执行: source ~/.zshrc (或 ~/.bashrc)
    2. 诊断应用: as.sh [pid]
    3. 查看Java进程: jps
    4. 常用命令:
       - dashboard: 查看系统实时数据面板
       - thread: 查看线程信息
       - jvm: 查看JVM信息
       - sc: 查看类信息
       - sm: 查看方法信息
       - watch: 方法执行观测
       - trace: 方法内部调用路径
       - stack: 输出当前方法被调用的调用路径

更多信息: https://arthas.aliyun.com/
EOF
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
                # 检查Arthas是否已安装并输出版本
                check_arthas_installed --quiet
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            --target-ip)
                TARGET_IP="$2"
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

# === 检查Java环境 ===
check_java() {
    if ! command -v java &> /dev/null; then
        print_error "未检测到Java环境"
        print_info "请先安装Java，建议使用JDK 8+"
        print_info "可以使用 jdk/install-jdk.sh 脚本安装Java"
        exit 1
    fi

    local java_version
    java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)

    if [ "$java_version" -lt 8 ]; then
        print_warning "检测到Java版本较低: $java_version"
        print_info "Arthas建议使用JDK 8+"
    fi

    print_info "检测到Java版本: $(java -version 2>&1 | head -1)"
}

# === 检查依赖 ===
check_dependencies() {
    local missing_deps=()

    for dep in java; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if ! find_adl >/dev/null 2>&1 && \
       ! command -v curl >/dev/null 2>&1 && \
       ! command -v wget >/dev/null 2>&1; then
        missing_deps+=("adl/curl/wget")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少依赖: ${missing_deps[*]}"
        print_info "请先安装缺少的依赖，然后重试"
        exit 1
    fi
}

# === 获取本机IP地址 ===
get_local_ip() {
    # 尝试多种方法获取本机IP
    local ip=""

    # 方法1: 使用hostname -I
    if command -v hostname &> /dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # 方法2: 使用ip命令
    if [ -z "$ip" ] && command -v ip &> /dev/null; then
        ip=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi

    # 方法3: 使用ifconfig
    if [ -z "$ip" ] && command -v ifconfig &> /dev/null; then
        ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
    fi

    echo "$ip"
}

# === 下载Arthas ===
download_arthas() {
    local output_file="$1"
    local filename="$(basename "$output_file")"

    # 检查文件是否已存在且有效
    if check_file_valid "$output_file" 100000; then  # 至少100KB
        if [ "$FORCE_REINSTALL" = false ]; then
            print_info "文件已存在且有效: $output_file"
            return 0
        else
            print_info "强制重新下载..."
        fi
    fi

    print_header "下载Arthas..."
    download_with_adl "$ARTHAS_BOOT_URL" "$output_file"

    # 验证下载的文件
    if ! check_file_valid "$output_file" 100000; then
        print_error "下载的文件无效或太小"
        rm -f "$output_file"
        exit 1
    fi

    print_success "下载完成: $filename"
}

# === 安装Arthas ===
install_arthas() {
    print_info "准备安装 Arthas"
    print_info "安装目录: $INSTALL_DIR"
    print_info "下载地址: $ARTHAS_BOOT_URL"

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将下载Arthas到 $INSTALL_DIR"
        return 0
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 下载arthas-boot.jar到统一下载目录，再复制到安装目录
    local download_jar="$DOWNLOAD_DIR/arthas-boot.jar"
    local arthas_jar="$INSTALL_DIR/arthas-boot.jar"
    mkdir -p "$DOWNLOAD_DIR"
    download_arthas "$download_jar"
    cp "$download_jar" "$arthas_jar"

    # 创建启动脚本
    create_launch_script

    print_success "Arthas安装完成"
}

# === 创建启动脚本 ===
create_launch_script() {
    local launch_script="$INSTALL_DIR/as.sh"

    cat > "$launch_script" << 'EOF'
#!/bin/bash

# Arthas启动脚本

ARHAS_HOME="$(cd "$(dirname "$0")" && pwd)"
ARTHAS_BOOT_JAR="$ARHAS_HOME/arthas-boot.jar"

if [ ! -f "$ARTHAS_BOOT_JAR" ]; then
    echo "错误: 找不到arthas-boot.jar"
    echo "请运行 install-arthas.sh 脚本安装Arthas"
    exit 1
fi

# 显示Java进程列表
echo "=== Java进程列表 ==="
jps -l

# 询问目标进程
if [ -z "$1" ]; then
    echo ""
    read -p "请输入要诊断的Java进程PID: " pid
else
    pid="$1"
fi

# 验证PID
if ! ps -p "$pid" > /dev/null 2>&1; then
    echo "错误: 进程 $pid 不存在"
    exit 1
fi

# 启动Arthas
echo ""
echo "正在启动Arthas诊断工具..."
echo "目标进程: $pid"
echo "按 Ctrl+C 退出Arthas"
echo ""

java -jar "$ARTHAS_BOOT_JAR" "$pid"
EOF

    chmod +x "$launch_script"
    print_success "创建启动脚本: $launch_script"
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
    if grep -q "ARTHAS_HOME" "$config_file" 2>/dev/null; then
        if [ "$FORCE_REINSTALL" = false ]; then
            print_warning "Arthas环境变量已配置，跳过添加"
            print_info "使用 --force 选项强制重新配置"
            return 0
        fi

        # 删除旧的Arthas配置
        print_info "删除旧的Arthas配置..."
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# Arthas环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        else
            sed -i '/# Arthas环境配置/,/^$/d' "$config_file" 2>/dev/null || true
        fi
    fi

    # 添加新的Arthas配置
    cat >> "$config_file" << 'EOF'

# Arthas环境配置
export ARTHAS_HOME=$HOME/.arthas
alias as='$HOME/.arthas/as.sh'
EOF

    # 替换为实际的路径
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|export ARTHAS_HOME=\$HOME/.arthas|export ARTHAS_HOME=$INSTALL_DIR|" "$config_file"
        sed -i '' "s|alias as='\$HOME/.arthas/as.sh'|alias as='$INSTALL_DIR/as.sh'|" "$config_file"
    else
        sed -i "s|export ARTHAS_HOME=\$HOME/.arthas|export ARTHAS_HOME=$INSTALL_DIR|" "$config_file"
        sed -i "s|alias as='\$HOME/.arthas/as.sh'|alias as='$INSTALL_DIR/as.sh'|" "$config_file"
    fi

    print_success "Arthas环境变量已配置"
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."

    if [ ! -f "$INSTALL_DIR/arthas-boot.jar" ]; then
        print_error "Arthas安装文件不存在"
        return 1
    fi

    print_success "Arthas安装成功!"
    print_info "安装目录: $INSTALL_DIR"
    print_info "启动脚本: $INSTALL_DIR/as.sh"

    # 显示使用说明
    print_header "使用说明"
    print_info "1. 启动Arthas: as [pid]"
    print_info "2. 查看Java进程: jps"
    print_info "3. 常用命令:"
    print_info "   - dashboard: 查看系统实时数据"
    print_info "   - thread: 查看线程信息"
    print_info "   - jvm: 查看JVM信息"
    print_info "   - sc: 查看类信息"
    print_info "   - sm: 查看方法信息"
    print_info "   - watch: 方法执行观测"
    print_info "   - trace: 方法内部调用路径"
    print_info "   - stack: 输出当前方法被调用的调用路径"

    return 0
}

# === 卸载Arthas ===
uninstall_arthas() {
    print_header "卸载Arthas..."

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
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

    if [ -f "$config_file" ] && grep -q "Arthas环境配置" "$config_file"; then
        print_info "清理shell配置: $config_file"
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/# Arthas环境配置/,/^$/d' "$config_file"
        else
            sed -i '/# Arthas环境配置/,/^$/d' "$config_file"
        fi
        print_success "Shell配置已清理"
    fi

    print_success "Arthas卸载完成"
    print_info "请重启终端或执行: source $config_file"
}

# === 主函数 ===
main() {
    # 解析参数（可以在标题输出前退出）
    parse_arguments "$@"

    # 打印标题（仅在安装模式时显示）
    print_header "Arthas一键安装配置脚本"

    # 检查Java环境
    check_java

    # 检查依赖
    check_dependencies

    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_arthas
        return 0
    fi

    # 安装Arthas
    install_arthas

    # 配置shell环境
    configure_shell

    # 验证安装
    verify_installation

    print_header "安装完成!"
    print_success "Arthas已成功安装并配置"

    if [ "$SKIP_SHELL_CONFIG" = false ]; then
        print_info "请执行以下命令使配置生效:"
        print_info "  source $(get_shell_config_file)"
        print_info "或者重启终端"
    fi

    print_info "开始使用Arthas进行Java应用诊断吧!"
}

# === 执行主函数 ===
main "$@"

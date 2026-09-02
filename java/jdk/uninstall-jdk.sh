#!/bin/bash

# 脚本名称：JDK 卸载脚本
# 功能：卸载指定版本的 JDK，支持 macOS 和 Linux（apt/dnf/yum）
# 用法：
#   ./uninstall-jdk.sh [版本号] [-d 安装目录] [--prefix DIR]
#   ./uninstall-jdk.sh              # 列出已安装的 JDK
#   sudo ./uninstall-jdk.sh 21      # 卸载 JDK 21
#   ./uninstall-jdk.sh -d /root/jdk # 卸载指定目录下的 JDK（免 root）
#   ./uninstall-jdk.sh 21 -d ~/jdk  # 卸载 ~/jdk/jdk-21

set -eo pipefail

# ============================================
# 颜色与日志
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ============================================
# 配置
# ============================================
OS="$(uname)"
# 默认 JDK 安装根目录列表，查找时依次探测
DEFAULT_JDK_PREFIXES=(
    "/opt/jdk"
    "$HOME/jdk"
    "/usr/lib/jvm"
    "/usr/local/java"
)

JDK_VERSION=""
JDK_PREFIX=""
# 用户可通过 -d 指定的安装目录
USER_INSTALL_DIR=""

# ============================================
# 参数解析
# ============================================
usage() {
    cat << 'EOF'
用法: ./uninstall-jdk.sh [版本号] [选项]

参数:
  版本号            要卸载的 JDK 版本，如 21。不指定则列出已安装的 JDK
  -d, --dir DIR    指定 JDK 安装根目录（如 /root/jdk），免去自动探测
  --prefix DIR     同 -d
  -h, --help       显示此帮助信息

示例:
  ./uninstall-jdk.sh                       # 列出已安装的 JDK
  sudo ./uninstall-jdk.sh 21               # 卸载 JDK 21（自动探测）
  ./uninstall-jdk.sh -d /root/jdk          # 卸载 /root/jdk 下所有 JDK
  ./uninstall-jdk.sh 21 -d /root/jdk      # 卸载 /root/jdk/jdk-21
  ./uninstall-jdk.sh 21 -d ~/jdk           # 免 root 卸载用户目录下的 JDK

支持平台: macOS、Linux (apt/dnf/yum + 手动解压安装)
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -d|--dir|--prefix)
                USER_INSTALL_DIR="$2"
                shift 2
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$JDK_VERSION" ]; then
                    JDK_VERSION="$1"
                    shift
                else
                    error "未知参数: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done
}

# ============================================
# 查找 JDK 安装
# ============================================
# 检测包管理器安装的 JDK（Linux）
find_package_jdks() {
    if command -v dnf &>/dev/null; then
        dnf list installed 2>/dev/null | grep -iE 'java-.*jdk|java-.*openjdk' || true
    elif command -v yum &>/dev/null; then
        yum list installed 2>/dev/null | grep -iE 'java-.*jdk|java-.*openjdk' || true
    elif command -v rpm &>/dev/null; then
        rpm -qa 2>/dev/null | grep -iE 'java-.*jdk|java-.*openjdk' || true
    fi
}

# 列出指定目录下已安装的 JDK
# 参数: prefix_dir
# 输出: 每行一个 "prefix/jdk-XX"
list_dir_jdks() {
    local prefix="$1"
    [ -d "$prefix" ] || return 0

    # 列出 jdk-* 目录和符号链接
    local item
    for item in "$prefix"/jdk-*; do
        [ -e "$item" ] || continue
        echo "$item"
    done

    # current 符号链接
    if [ -L "$prefix/current" ]; then
        echo "$prefix/current -> $(readlink -f "$prefix/current" 2>/dev/null || readlink "$prefix/current")"
    fi
}

# macOS: 列出已安装的 JDK
list_macos_jdks() {
    if [ -d "/opt/jdk" ]; then
        list_dir_jdks "/opt/jdk"
    fi
    if [ -d "/Library/Java/JavaVirtualMachines" ]; then
        ls -d /Library/Java/JavaVirtualMachines/jdk* 2>/dev/null || true
    fi
    if [ -d "$HOME/jdk" ]; then
        list_dir_jdks "$HOME/jdk"
    fi
}

list_all_jdks() {
    echo "已安装的 JDK:"
    echo "===================="

    if [ "$OS" == "Darwin" ]; then
        list_macos_jdks
    else
        # Linux: 先列包管理器安装的
        local pkg_jdks
        pkg_jdks="$(find_package_jdks)"
        if [ -n "$pkg_jdks" ]; then
            echo "[包管理器安装]"
            echo "$pkg_jdks"
            echo ""
        fi

        # 再列手动解压安装的
        echo "[手动解压安装]"
        for prefix in "${DEFAULT_JDK_PREFIXES[@]}"; do
            if [ -d "$prefix" ]; then
                local found
                found="$(list_dir_jdks "$prefix")"
                [ -n "$found" ] && echo "$found"
            fi
        done
    fi

    echo ""
}

# ============================================
# 卸载逻辑
# ============================================

# 卸载手动解压安装的 JDK（目录形式）
# 参数: jdk_dir
uninstall_dir_jdk() {
    local jdk_dir="$1"

    if [ ! -d "$jdk_dir" ] && [ ! -L "$jdk_dir" ]; then
        warn "JDK 目录不存在: $jdk_dir"
        return 1
    fi

    info "正在卸载 JDK 目录: $jdk_dir"

    local real_dir=""
    if [ -L "$jdk_dir" ]; then
        real_dir="$(readlink -f "$jdk_dir" 2>/dev/null || readlink "$jdk_dir")"
        info "符号链接指向: $real_dir"
    fi

    # 判断是否有写权限
    if [ ! -w "$(dirname "$jdk_dir")" ]; then
        error "无权限删除 $jdk_dir，请使用 sudo 或有权限的用户运行"
        return 1
    fi

    # 删除符号链接
    if [ -L "$jdk_dir" ]; then
        rm -f "$jdk_dir"
        success "已删除符号链接: $jdk_dir"
    fi

    # 删除实际目录
    if [ -n "$real_dir" ] && [ -d "$real_dir" ]; then
        if [ -w "$(dirname "$real_dir")" ]; then
            rm -rf "$real_dir"
            success "已删除 JDK 目录: $real_dir"
        else
            warn "无权限删除 $real_dir，尝试 sudo..."
            sudo rm -rf "$real_dir" && success "已删除 JDK 目录: $real_dir" || {
                error "sudo 删除失败: $real_dir"
                return 1
            }
        fi
    elif [ -d "$jdk_dir" ]; then
        rm -rf "$jdk_dir"
        success "已删除 JDK 目录: $jdk_dir"
    fi

    return 0
}

# 卸载包管理器安装的 JDK（Linux）
uninstall_package_jdk() {
    local version="$1"
    info "正在卸载包管理器安装的 JDK $version (Linux)..."

    if command -v dnf &>/dev/null; then
        sudo dnf remove -y "java-*openjdk*$version*" "java-*jdk*$version*" 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        sudo yum remove -y "java-*openjdk*$version*" "java-*jdk*$version*" 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
        sudo apt-get purge -y "openjdk-*-$version*" "oracle-java*$version*" 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
    else
        error "未找到支持的包管理器 (dnf/yum/apt-get)"
        return 1
    fi

    # 清理 /usr/lib/jvm 残留
    if [ -d "/usr/lib/jvm" ]; then
        sudo rm -rf "/usr/lib/jvm"/jdk-"$version"* 2>/dev/null || true
        sudo rm -rf "/usr/lib/jvm"/java-"$version"* 2>/dev/null || true
    fi

    success "JDK $version 包管理器卸载完成"
    return 0
}

# 在指定 prefix 下查找并卸载
# 参数: prefix, version(可选)
uninstall_from_prefix() {
    local prefix="$1"
    local version="${2:-}"

    [ -d "$prefix" ] || return 1

    if [ -n "$version" ]; then
        # 精确匹配 jdk-XX
        local jdk_dir="$prefix/jdk-$version"
        if [ -d "$jdk_dir" ] || [ -L "$jdk_dir" ]; then
            uninstall_dir_jdk "$jdk_dir"
            return $?
        fi
        # 模糊匹配 jdk-XX.*
        local matched
        matched="$(find "$prefix" -maxdepth 1 -name "jdk-$version*" 2>/dev/null | head -1)"
        if [ -n "$matched" ]; then
            uninstall_dir_jdk "$matched"
            return $?
        fi
        return 1
    else
        # 未指定版本：卸载该 prefix 下所有 jdk-* 及 current 符号链接
        local found_any=false
        local item
        for item in "$prefix"/jdk-*; do
            [ -e "$item" ] || continue
            uninstall_dir_jdk "$item" || true
            found_any=true
        done
        # 删除 current 符号链接
        if [ -L "$prefix/current" ]; then
            uninstall_dir_jdk "$prefix/current" || true
            found_any=true
        fi
        $found_any && return 0 || return 1
    fi
}

# ============================================
# 主逻辑
# ============================================
main() {
    parse_args "$@"

    # 如果没有指定版本和目录，列出已安装的 JDK
    if [ -z "$JDK_VERSION" ] && [ -z "$USER_INSTALL_DIR" ]; then
        list_all_jdks
        exit 0
    fi

    local overall_success=false

    # 用户指定了安装目录
    if [ -n "$USER_INSTALL_DIR" ]; then
        # 展开 ~
        USER_INSTALL_DIR="${USER_INSTALL_DIR/#\~/$HOME}"
        USER_INSTALL_DIR="${USER_INSTALL_DIR%/}"

        info "从指定目录卸载: $USER_INSTALL_DIR"
        if uninstall_from_prefix "$USER_INSTALL_DIR" "$JDK_VERSION"; then
            overall_success=true
        else
            warn "在 $USER_INSTALL_DIR 下未找到"
        fi
    else
        # 自动探测
        if [ "$OS" == "Darwin" ]; then
            for prefix in "/opt/jdk" "$HOME/jdk" "/Library/Java/JavaVirtualMachines"; do
                if uninstall_from_prefix "$prefix" "$JDK_VERSION"; then
                    overall_success=true
                fi
            done
        else
            # Linux: 先尝试手动解压安装的目录
            for prefix in "${DEFAULT_JDK_PREFIXES[@]}"; do
                if uninstall_from_prefix "$prefix" "$JDK_VERSION"; then
                    overall_success=true
                fi
            done
            # 再尝试包管理器
            if [ -n "$JDK_VERSION" ]; then
                info "尝试卸载包管理器安装的 JDK $JDK_VERSION..."
                if uninstall_package_jdk "$JDK_VERSION"; then
                    overall_success=true
                fi
            fi
        fi
    fi

    if $overall_success; then
        success "JDK 卸载完成"
        info "请检查 shell 配置文件中的 JAVA_HOME 和 PATH 是否需要清理"
    else
        error "未找到可卸载的 JDK"
        list_all_jdks
        exit 1
    fi
}

main "$@"

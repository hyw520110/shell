#!/bin/bash

# JDK 版本切换脚本
# 用途: 在已安装的多个 JDK 版本之间快速切换
# 依赖: install-jdk.sh 已安装的 JDK

set -euo pipefail

# === 默认配置 ===
DEFAULT_INSTALL_DIR="$HOME/jdk"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"

# === 颜色输出 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# === 平台检测 ===
is_mac() { [[ "$(uname -s)" == "Darwin" ]]; }

# 获取真实的 JAVA_HOME（macOS 需指向 Contents/Home）
get_real_java_home() {
    local jdk_dir="$1"
    if is_mac && [ -d "$jdk_dir/Contents/Home" ]; then
        echo "$jdk_dir/Contents/Home"
    else
        echo "$jdk_dir"
    fi
}

# 从 JAVA_HOME 路径提取版本号
extract_version_from_home() {
    local java_home="$1"
    local base
    base="${java_home%/Contents/Home}"
    base="${base##*jdk-}"
    echo "$base"
}

# 从路径中提取 jdk-XX 的目录部分（不含 Contents/Home）
extract_jdk_dir_from_home() {
    local java_home="$1"
    local base
    base="${java_home%/Contents/Home}"
    echo "$base"
}

# 检测 shell 配置文件
detect_shell_rc() {
    if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
        echo "$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ] || [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
    else
        echo "$HOME/.zshrc"
    fi
}

# 跨平台 sed 原地替换
safe_sed() {
    local pattern="$1"
    local file="$2"
    sed -i.bak "$pattern" "$file" 2>/dev/null || true
    rm -f "${file}.bak" 2>/dev/null || true
}

# === 核心功能 ===

# 列出已安装的 JDK
list_installed_jdks() {
    local install_dir="$1"
    if [ ! -d "$install_dir" ]; then
        return 1
    fi

    local found=0
    for dir in "$install_dir"/jdk-*; do
        [ -d "$dir" ] || continue
        local version="${dir##*-}"
        # 只保留数字版本号
        [[ "$version" =~ ^[0-9]+$ ]] || continue
        local java_home
        java_home=$(get_real_java_home "$dir")
        if [ -x "$java_home/bin/java" ]; then
            echo "$version|$dir|$java_home"
            found=1
        fi
    done
    return $found
}

# 获取当前 JAVA_HOME
current_java_home() {
    echo "${JAVA_HOME:-}"
}

# 在 shell rc 中更新 JAVA_HOME 和 PATH
update_shell_rc() {
    local new_version="$1"
    local install_dir="$2"
    local rc_file
    rc_file=$(detect_shell_rc)

    if [ ! -f "$rc_file" ]; then
        warn "未找到 shell 配置文件: $rc_file"
        return 1
    fi

    local target_dir="$install_dir/jdk-$new_version"
    local new_java_home
    new_java_home=$(get_real_java_home "$target_dir")

    # 1. 替换或添加 JAVA_HOME 行
    if grep -q '^[[:space:]]*export[[:space:]]\{1,\}JAVA_HOME=' "$rc_file"; then
        safe_sed "s|^[[:space:]]*export[[:space:]]\{1,\}JAVA_HOME=.*|export JAVA_HOME=\"$new_java_home\"|" "$rc_file"
        info "已更新 JAVA_HOME: $new_java_home"
    else
        {
            echo ""
            echo "# Java Environment Variables"
            echo "export JAVA_HOME=\"$new_java_home\""
            echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
        } >> "$rc_file"
        info "已添加 JAVA_HOME 配置到 $rc_file"
    fi

    # 2. 替换 PATH 中写死的 jdk-XX/bin 路径（只替换版本号部分）
    # 匹配 install_dir/jdk-数字/bin，替换为 install_dir/jdk-新版本/bin
    local count
    count=$(grep -c "$install_dir/jdk-[0-9]*/bin" "$rc_file" 2>/dev/null || true)
    count=${count:-0}
    if [ "$count" -gt 0 ] 2>/dev/null; then
        safe_sed "s|$install_dir/jdk-[0-9]*/bin|$install_dir/jdk-$new_version/bin|g" "$rc_file"
        info "已替换 PATH 中的 JDK 路径 ($count 处)"
    fi
}

# 执行切换
do_switch() {
    local target_version="$1"
    local install_dir="$2"

    local target_dir="$install_dir/jdk-$target_version"
    if [ ! -d "$target_dir" ]; then
        error "JDK $target_version 未安装，目录不存在: $target_dir"
        error "请先运行: $(dirname "$0")/install-jdk.sh -v $target_version -d $install_dir"
        return 1
    fi

    local new_java_home
    new_java_home=$(get_real_java_home "$target_dir")
    if [ ! -x "$new_java_home/bin/java" ]; then
        error "JDK 安装不完整: $new_java_home/bin/java 不存在"
        return 1
    fi

    # 更新 current 软链接
    ln -sfn "$target_dir" "$install_dir/current" 2>/dev/null || warn "无法更新 current 软链接（可能需要 sudo）"

    # 更新 shell rc
    update_shell_rc "$target_version" "$install_dir"

    success "已切换到 JDK $target_version"
    info "JAVA_HOME: $new_java_home"
    info "请执行: source $(detect_shell_rc)"
    echo ""
    "$new_java_home/bin/java" -version 2>&1 | head -3
}

# === 命令实现 ===

cmd_list() {
    info "已安装的 JDK 版本 ($INSTALL_DIR):"
    echo ""

    local current_ver
    current_ver=$(extract_version_from_home "$(current_java_home)" 2>/dev/null || echo "")

    local found=0
    while IFS='|' read -r version dir java_home; do
        found=1
        if [ "$version" = "$current_ver" ]; then
            printf "  * JDK %s  %s  (当前)\n" "$version" "$java_home"
        else
            printf "    JDK %s  %s\n" "$version" "$java_home"
        fi
    done < <(list_installed_jdks "$INSTALL_DIR")

    if [ "$found" -eq 0 ]; then
        error "未找到已安装的 JDK，目录: $INSTALL_DIR"
        error "请先运行: $(dirname "$0")/install-jdk.sh"
        exit 1
    fi
}

cmd_current() {
    local java_home
    java_home=$(current_java_home)

    if [ -z "$java_home" ]; then
        warn "JAVA_HOME 未设置"
        exit 0
    fi

    local version
    version=$(extract_version_from_home "$java_home")
    info "当前 JDK 版本: $version"
    info "JAVA_HOME: $java_home"
    echo ""
    if [ -x "$java_home/bin/java" ]; then
        "$java_home/bin/java" -version 2>&1 | head -3
    else
        warn "java 命令不存在: $java_home/bin/java"
    fi
}

cmd_switch() {
    local target_version="$1"
    do_switch "$target_version" "$INSTALL_DIR"
}

cmd_interactive() {
    info "已安装的 JDK 版本:"
    echo ""

    local current_ver
    current_ver=$(extract_version_from_home "$(current_java_home)" 2>/dev/null || echo "")

    local versions=()
    local idx=1
    while IFS='|' read -r version dir java_home; do
        versions+=("$version")
        if [ "$version" = "$current_ver" ]; then
            printf "  [%d] JDK %s  (当前)\n" "$idx" "$version"
        else
            printf "  [%d] JDK %s\n" "$idx" "$version"
        fi
        idx=$((idx + 1))
    done < <(list_installed_jdks "$INSTALL_DIR")

    if [ ${#versions[@]} -eq 0 ]; then
        error "未找到已安装的 JDK，目录: $INSTALL_DIR"
        error "请先运行: $(dirname "$0")/install-jdk.sh"
        exit 1
    fi

    echo ""
    printf "请选择要切换的版本序号 (1-%d): " "${#versions[@]}"
    read -r choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#versions[@]} ]; then
        error "无效的选择: $choice"
        exit 1
    fi

    local target_version="${versions[$((choice - 1))]}"
    echo ""
    do_switch "$target_version" "$INSTALL_DIR"
}

# === 帮助信息 ===
show_help() {
    cat << EOF
JDK 版本切换脚本

用法:
  $0 [选项] [版本号]

选项:
  -l, --list          列出已安装的 JDK 版本
  -c, --current       显示当前使用的 JDK 版本
  -d, --dir DIR       指定 JDK 安装目录 (默认: $DEFAULT_INSTALL_DIR)
  -v, --version VER   切换到指定版本
  -h, --help          显示此帮助信息

示例:
  $0                   # 交互式选择版本
  $0 -l                # 列出已安装版本
  $0 17                # 切换到 JDK 17
  $0 -v 21             # 切换到 JDK 21
  $0 -c                # 显示当前版本
  $0 -d /opt/jdk 17    # 切换 /opt/jdk 下的 JDK 17

说明:
  切换会更新 \$JAVA_HOME 和 current 软链接，同时替换 PATH 中写死的
  jdk-XX/bin 路径。切换后请执行 source ~/.zshrc 使配置生效。
EOF
}

# === 参数解析 ===
main() {
    local action="interactive"
    local target_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--list)
                action="list"
                shift
                ;;
            -c|--current)
                action="current"
                shift
                ;;
            -d|--dir)
                [[ -n "${2:-}" ]] || { error "-d|--dir 参数需要提供目录路径"; exit 1; }
                INSTALL_DIR="$2"
                shift 2
                ;;
            -v|--version)
                [[ -n "${2:-}" ]] || { error "-v|--version 参数需要提供版本号"; exit 1; }
                target_version="$2"
                action="switch"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            [0-9]*)
                target_version="$1"
                action="switch"
                shift
                ;;
            *)
                error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    case "$action" in
        list)        cmd_list ;;
        current)     cmd_current ;;
        switch)      cmd_switch "$target_version" ;;
        interactive) cmd_interactive ;;
    esac
}

main "$@"

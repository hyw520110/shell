#!/bin/bash
# beyond4.sh - Beyond Compare 4 安装与破解脚本
# 支持: macOS, Linux
# 用途: 安装或破解 Beyond Compare 4

set -euo pipefail

# 颜色定义（使用 $'...' 确保转义序列生效）
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

# 检测操作系统
detect_os() {
    case "$(uname -s)" in
        Darwin*)  echo "macOS";;
        Linux*)   echo "Linux";;
        *)        echo "Unknown";;
    esac
}

# 检测是否已安装 Beyond Compare 4
is_installed() {
    local os
    os=$(detect_os)
    
    case "$os" in
        macOS)
            [[ -d "/Applications/Beyond Compare.app" ]] || [[ -d "$HOME/Applications/Beyond Compare.app" ]]
            ;;
        Linux)
            command -v bcompare &>/dev/null || [[ -f "/usr/lib/beyondcompare/BCompare" ]] || [[ -f "/opt/beyondcompare/bcompare" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# 获取 Beyond Compare 可执行文件路径
get_bcompare_path() {
    local os
    os=$(detect_os)
    local path=""
    
    case "$os" in
        macOS)
            if [[ -d "/Applications/Beyond Compare.app/Contents/MacOS" ]]; then
                path="/Applications/Beyond Compare.app/Contents/MacOS/BCompare"
            elif [[ -d "$HOME/Applications/Beyond Compare.app/Contents/MacOS" ]]; then
                path="$HOME/Applications/Beyond Compare.app/Contents/MacOS/BCompare"
            fi
            ;;
        Linux)
            for p in "/usr/lib/beyondcompare/BCompare" "/opt/beyondcompare/bcompare" "/opt/apps/com.scootersoftware.bcompare/files/BCompare"; do
                if [[ -f "$p" ]]; then
                    path="$p"
                    break
                fi
            done
            ;;
    esac
    
    echo "$path"
}

# 检测是否已破解
is_cracked() {
    local bcompare_path
    bcompare_path=$(get_bcompare_path)
    
    if [[ -z "$bcompare_path" ]]; then
        return 1
    fi
    
    # 检查是否包含破解后的哈希
    grep -q "GXN1eh9FbDiX1ACdd7XKMV7h" "$bcompare_path" 2>/dev/null
}

# 检测密钥文件是否存在
has_license_key() {
    local os
    os=$(detect_os)
    
    case "$os" in
        macOS)
            [[ -f "$HOME/Library/Application Support/Beyond Compare/BC4Key.txt" ]]
            ;;
        Linux)
            [[ -f "$HOME/.config/bcompare/BC4Key.txt" ]] || [[ -f "/etc/bcompare/BC4Key.txt" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# 检测是否已激活（软件内检测）
is_activated() {
    is_cracked || has_license_key
}

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

# 通用下载函数（adl 优先）
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

# 自动安装 Beyond Compare 4
install_beyond_compare() {
    local os
    os=$(detect_os)
    
    step "开始安装 Beyond Compare 4..."
    
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
}

# macOS 安装
install_macos() {
    if [[ -d "/Applications/Beyond Compare.app" ]]; then
        info "Beyond Compare 已在 /Applications 目录，跳过安装"
        return 0
    fi
    
    local pkg_url="https://www.scootersoftware.com/files/BCompareOSX-4.4.7.28397.zip"
    local pkg_path="/tmp/BCompareOSX.zip"
    local tmp_dir="/tmp/bcompare_install"
    
    # 下载
    info "正在下载 Beyond Compare 4 for macOS..."
    download_file "$pkg_url" "$pkg_path" || exit 1
    
    # 解压并安装
    info "解压安装包..."
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    unzip -q -o "$pkg_path" -d "$tmp_dir"
    
    info "复制到 Applications..."
    cp -R "$tmp_dir"/*.app /Applications/ 2>/dev/null || {
        # 如果没有 .app 目录结构，尝试其他方式
        if [[ -d "$tmp_dir/Beyond Compare.app" ]]; then
            cp -R "$tmp_dir/Beyond Compare.app" /Applications/
        else
            error "解压后未找到 Beyond Compare.app"
            exit 1
        fi
    }
    
    # 清理
    rm -rf "$tmp_dir"
    rm -f "$pkg_path"
    
    success "Beyond Compare 4 安装完成"
}

# Linux 安装
install_linux() {
    local apt_pkg="/tmp/bcompare-4.4.12.27003_amd64.deb"
    local rpm_pkg="/tmp/bcompare-4.4.12.27003.x86_64.rpm"
    
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        if [[ -f "$apt_pkg" ]]; then
            info "安装 DEB 包..."
            sudo apt-get install -y "$apt_pkg"
        else
            info "使用 apt-get 安装..."
            # 添加官方仓库或使用 snap
            if command -v snap &>/dev/null; then
                sudo snap install beyondcompare --classic || {
                    warn "snap 安装失败，尝试下载安装..."
                    download_and_install_deb
                }
            else
                download_and_install_deb
            fi
        fi
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        # Fedora/RHEL
        if [[ -f "$rpm_pkg" ]]; then
            info "安装 RPM 包..."
            sudo rpm -ivh "$rpm_pkg" || sudo dnf install -y "$rpm_pkg"
        else
            info "下载并安装 RPM..."
            download_and_install_rpm
        fi
    elif command -v pacman &>/dev/null; then
        # Arch Linux
        info "使用 pacman 安装..."
        yay -S beyondcompare || sudo pacman -S beyondcompare
    else
        error "不支持的 Linux 发行版"
        exit 1
    fi
    
    success "Beyond Compare 4 安装完成"
}

# 下载并安装 DEB
download_and_install_deb() {
    local url="https://www.scootersoftware.com/files/bcompare-4.4.7.28397_amd64.deb"
    local pkg="/tmp/bcompare.deb"
    
    download_file "$url" "$pkg" || exit 1
    
    info "安装 DEB 包..."
    sudo apt-get install -y "$pkg" || {
        sudo dpkg -i "$pkg" || true
        sudo apt-get -f install -y
    }
    
    rm -f "$pkg"
}

# 下载并安装 RPM
download_and_install_rpm() {
    local url="https://www.scootersoftware.com/files/bcompare-4.4.7.28397.x86_64.rpm"
    local pkg="/tmp/bcompare.rpm"
    
    download_file "$url" "$pkg" || exit 1
    
    info "安装 RPM 包..."
    sudo rpm -ivh "$pkg" || sudo dnf install -y "$pkg"
    rm -f "$pkg"
}

# 使用 sudo 执行命令
exec_sudo() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# 破解 Beyond Compare 4
crack_beyond_compare() {
    local bcompare_path
    bcompare_path=$(get_bcompare_path)
    
    if [[ -z "$bcompare_path" ]]; then
        error "未找到 Beyond Compare 可执行文件"
        exit 1
    fi
    
    local os
    os=$(detect_os)
    
    # 哈希值（Linux 破解用）
    local old_hash='keexjEP3t4Mue23hrnuPtY4TdcsqNiJL-5174TsUdLmJSIXKfG2NGPwBL6vnRPddT7tH29qpkneX63DO9ECSPE9rzY1zhThHERg8lHM9IBFT+rVuiY823aQJuqzxCKIE1bcDqM4wgW01FH6oCBP1G4ub01xmb4BGSUG6ZrjxWHJyNLyIlGvOhoY2HAYzEtzYGwxFZn2JZ66o4RONkXjX0DF9EzsdUef3UAS+JQ+fCYReLawdjEe6tXCv88GKaaPKWxCeaUL9PejICQgRQOLGOZtZQkLgAelrOtehxz5ANOOqCaJgy2mJLQVLM5SJ9Dli909c5ybvEhVmIC0dc9dWH+/N9KmiLVlKMU7RJqnE+WXEEPI1SgglmfmLc1yVH7dqBb9ehOoKG9UE+HAE1YvH1XX2XVGeEqYUY-Tsk7YBTz0WpSpoYyPgx6Iki5KLtQ5G-aKP9eysnkuOAkrvHU8bLbGtZteGwJarev03PhfCioJL4OSqsmQGEvDbHFEbNl1qJtdwEriR+VNZts9vNNLk7UGfeNwIiqpxjk4Mn09nmSd8FhM4ifvcaIbNCRoMPGl6KU12iseSe+w+1kFsLhX+OhQM8WXcWV10cGqBzQE9OqOLUcg9n0krrR3KrohstS9smTwEx9olyLYppvC0p5i7dAx2deWvM1ZxKNs0BvcXGukR+/g||||g'
    local new_hash='GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++'
    
    step "破解 Beyond Compare 4..."
    
    if [[ "$os" == "macOS" ]]; then
        # macOS: 只创建密钥文件（SIP 保护不允许修改 /Applications）
        info "macOS 检测到，将创建密钥文件（无需修改二进制）"
        create_license_key "$os"
    else
        # Linux: 修改二进制 + 创建密钥文件
        info "备份原文件..."
        exec_sudo cp "$bcompare_path" "${bcompare_path}.backup.$(date +%Y%m%d_%H%M%S)"
        
        info "应用破解补丁..."
        exec_sudo LC_ALL=C sed -i.bak "s#${old_hash}#${new_hash}#" "$bcompare_path"
        exec_sudo rm -f "${bcompare_path}.bak"
        
        create_license_key "$os"
    fi
    
    success "破解完成"
}

# 创建密钥文件
create_license_key() {
    local os="$1"
    local key_dir=""
    local key_file=""
    
    step "创建密钥文件..."
    
    case "$os" in
        macOS)
            key_dir="$HOME/Library/Application Support/Beyond Compare"
            key_file="$key_dir/BC4Key.txt"
            ;;
        Linux)
            key_dir="$HOME/.config/bcompare"
            key_file="$key_dir/BC4Key.txt"
            ;;
    esac
    
    info "创建密钥文件: $key_file"
    mkdir -p "$key_dir"
    cat > "$key_file" << 'LICENSE'
GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++
LICENSE
    
    # Linux 额外复制到系统目录
    if [[ "$os" == "Linux" ]]; then
        exec_sudo mkdir -p /etc/bcompare/
        exec_sudo cp "$key_file" /etc/bcompare/BC4Key.txt 2>/dev/null || true
    fi
    
    success "密钥文件创建完成"
}

# 主函数
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Beyond Compare 4 安装与破解脚本          ║${NC}"
    echo -e "${CYAN}║       支持: macOS, Linux                       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local os
    os=$(detect_os)
    info "检测到操作系统: $os"
    
    # 检查是否已安装
    if ! is_installed; then
        warn "Beyond Compare 4 未安装"
        printf "是否自动安装? [Y/n] "
        read -r confirm
        confirm="${confirm:-Y}"
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            install_beyond_compare
        else
            info "请手动安装 Beyond Compare 4 后重新运行此脚本"
            exit 0
        fi
    else
        info "Beyond Compare 4 已安装"
    fi
    
    # 检查是否已破解
    if is_activated; then
        success "Beyond Compare 4 已激活，无需再次破解"
        exit 0
    fi
    
    # 执行破解
    crack_beyond_compare
    
    echo ""
    success "Beyond Compare 4 破解完成！"
    echo ""
    info "请按以下步骤完成激活："
    info "1. 打开 Beyond Compare 4"
    info "2. 密钥输入界面，输入以下密钥："
    echo -e "${YELLOW}   GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++${NC}"
    echo ""
    info "3. 如果程序正在运行，请重启使更改生效"
}

# 帮助信息
show_help() {
    cat << 'HELP'
用法: beyond4.sh [选项]

选项:
  install     仅安装 Beyond Compare 4（不破解）
  crack       仅破解 Beyond Compare 4（不安装）
  git         显示 Git difftool/mergetool 配置指南
  status      检查安装和激活状态
  -h, --help  显示帮助信息

示例:
  beyond4.sh              # 完整安装+破解
  beyond4.sh install      # 仅安装
  beyond4.sh crack        # 仅破解
  beyond4.sh git          # 查看 Git 集成配置指南
  beyond4.sh status       # 查看状态

Git 集成注意:
  macOS 建议先在 Beyond Compare 菜单中执行:
    Beyond Compare > Install Command Line Tools
  官方命令行工具会安装 /usr/local/bin/bcomp 和 /usr/local/bin/bcompare。
  如果未安装官方命令行工具，可参考 git 指南命令中的 ~/.local/bin wrapper 方案。
HELP
}

# Git difftool/mergetool 配置指南
show_git_guide() {
    cat << 'GUIDE'
Beyond Compare 4 + Git 配置指南

1. macOS 官方命令行工具
   打开 Beyond Compare 后，先执行菜单:
     Beyond Compare > Install Command Line Tools

   正常情况下会生成:
     /usr/local/bin/bcomp
     /usr/local/bin/bcompare

   如果菜单安装失败或无权限，可在 ~/.local/bin 下创建 wrapper，但 wrapper 必须调用:
     /Applications/Beyond Compare.app/Contents/MacOS/bcomp

   注意: bcompare 也应转到 bcomp，而不是直接转到 BCompare 主程序。
   直接调用 BCompare 容易打开默认首页，不进入文件对比。

2. 推荐 Git 配置
   diff.tool / merge.tool 仍使用 Git 内置的 bc 工具名:

     git config --global diff.tool bc
     git config --global merge.tool bc
     git config --global difftool.prompt false
     git config --global mergetool.prompt false
     git config --global mergetool.bc.trustExitCode true

3. difftool 临时文件注意
   git difftool 传给 Beyond Compare 的 $LOCAL/$REMOTE 是 Git 临时 blob，
   常见路径类似:
     /var/folders/.../T/git-blob-*/<file>

   bcomp 会把请求交给 GUI 后很快返回，Git 随后可能清理临时文件。
   这会导致 Beyond Compare 报错:
     文件找不到 / 不能加载 /var/folders/.../git-blob-...

   解决方式: difftool 先复制 $LOCAL/$REMOTE 到稳定临时目录，再交给 bcomp。
   当前推荐配置:

     git config --global difftool.bc.cmd 'git-bc-difftool "$LOCAL" "$REMOTE" "$MERGED"'
     git config --global mergetool.bc.cmd 'bcomp "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'

4. git-bc-difftool wrapper 示例
   保存为 ~/.local/bin/git-bc-difftool 并 chmod +x:

     #!/usr/bin/env bash
     set -euo pipefail

     left="${1:?left file required}"
     right="${2:?right file required}"
     name="${3:-$(basename "$right")}"
     base_dir="${TMPDIR:-/tmp}/git-bc-difftool"
     run_dir="$base_dir/$(date +%Y%m%d_%H%M%S)_$$"
     mkdir -p "$run_dir"
     find "$base_dir" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true

     safe_name=$(basename "$name")
     left_copy="$run_dir/LOCAL_${safe_name}"
     right_copy="$run_dir/REMOTE_${safe_name}"
     cp "$left" "$left_copy"
     cp "$right" "$right_copy"

     exec bcomp "$left_copy" "$right_copy"

5. 常见现象与原因
   - git difftool 一直等待:
     正常。Git 需要等 Beyond Compare 关闭后再清理临时文件。

   - 打开默认首页:
     多数是 bcompare wrapper 指向了 BCompare 主程序，应改为调用 bcomp。

   - 提示 /var/folders/.../git-blob-* 文件不存在:
     bcomp 过早返回，Git 清理了临时文件。使用 git-bc-difftool 复制稳定副本。
GUIDE
}

# 显示状态
show_status() {
    local os
    os=$(detect_os)
    
    echo ""
    info "操作系统: $os"
    echo ""
    
    if is_installed; then
        success "已安装"
        local path
        path=$(get_bcompare_path)
        info "路径: $path"
    else
        warn "未安装"
    fi
    echo ""
    
    if is_activated; then
        success "已激活"
    else
        warn "未激活"
    fi

    echo ""
    info "Git 集成检查:"
    if command -v bcomp >/dev/null 2>&1; then
        success "bcomp: $(command -v bcomp)"
    else
        warn "未检测到 bcomp。macOS 请在 Beyond Compare 菜单执行 Install Command Line Tools"
    fi
    if command -v bcompare >/dev/null 2>&1; then
        success "bcompare: $(command -v bcompare)"
    else
        warn "未检测到 bcompare。macOS 请在 Beyond Compare 菜单执行 Install Command Line Tools"
    fi
    if command -v git-bc-difftool >/dev/null 2>&1; then
        success "git-bc-difftool: $(command -v git-bc-difftool)"
    else
        warn "未检测到 git-bc-difftool；git difftool 可能遇到临时文件被清理问题"
    fi

    local difftool_cmd
    local mergetool_cmd
    difftool_cmd=$(git config --global --get difftool.bc.cmd 2>/dev/null || true)
    mergetool_cmd=$(git config --global --get mergetool.bc.cmd 2>/dev/null || true)
    [[ -n "$difftool_cmd" ]] && info "difftool.bc.cmd: $difftool_cmd"
    [[ -n "$mergetool_cmd" ]] && info "mergetool.bc.cmd: $mergetool_cmd"
    info "详细说明: $0 git"
}

# 参数处理
case "${1:-}" in
    install)
        install_beyond_compare
        ;;
    crack)
        if ! is_installed; then
            error "Beyond Compare 4 未安装，请先安装"
            exit 1
        fi
        crack_beyond_compare
        ;;
    git|git-guide|git-config)
        show_git_guide
        ;;
    status)
        show_status
        ;;
    -h|--help)
        show_help
        ;;
    "")
        main
        ;;
    *)
        error "未知参数: $1"
        echo "使用 $0 --help 查看帮助信息"
        exit 1
        ;;
esac

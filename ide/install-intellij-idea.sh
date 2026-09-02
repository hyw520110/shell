#!/bin/bash

# IntelliJ IDEA 一键安装配置脚本
# 支持检测、安装、配置 IntelliJ IDEA

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置变量
IDEA_VERSION="2024.2"
IDEA_DOWNLOAD_URL="https://download.jetbrains.com/idea/ideaIC-${IDEA_VERSION}.tar.gz"
IDEA_INSTALL_DIR="/opt/idea"
IDEA_DESKTOP_FILE="/usr/share/applications/intellij-idea.desktop"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 检测IntelliJ IDEA是否已安装
check_installed() {
    # 方法1: 检查idea命令
    if command -v idea &> /dev/null; then
        return 0
    fi
    
    # 方法2: 检查安装目录
    if [ -d "$IDEA_INSTALL_DIR" ] && [ -f "$IDEA_INSTALL_DIR/bin/idea.sh" ]; then
        return 0
    fi
    
    # 方法3: 检查是否已安装到用户目录
    local user_idea_dir="$HOME/.local/share/JetBrains/IntelliJIdea"
    if [ -d "$user_idea_dir" ]; then
        return 0
    fi
    
    # 方法4: 检查/Applications (macOS)
    if [ -d "/Applications/IntelliJ IDEA.app" ] || [ -d "/Applications/IntelliJ IDEA CE.app" ]; then
        return 0
    fi
    
    return 1
}

# 获取IntelliJ IDEA版本信息
get_version() {
    if command -v idea &> /dev/null; then
        idea --version 2>&1 | head -1
    elif [ -f "$IDEA_INSTALL_DIR/bin/idea.sh" ]; then
        "$IDEA_INSTALL_DIR/bin/idea.sh" --version 2>&1 | head -1
    elif [ -d "/Applications/IntelliJ IDEA.app" ]; then
        defaults read /Applications/IntelliJ\ IDEA.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo ""
    elif [ -d "/Applications/IntelliJ IDEA CE.app" ]; then
        defaults read /Applications/IntelliJ\ IDEA\ CE.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 检测系统类型
detect_os() {
    local os_type=$(uname -s)
    case "$os_type" in
        Linux*)
            echo "linux"
            ;;
        Darwin*)
            echo "macos"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 下载IntelliJ IDEA
download_idea() {
    local os=$(detect_os)
    local arch=$(detect_arch)
    local download_url
    local download_file
    
    if [ "$os" == "macos" ]; then
        if [ "$arch" == "arm64" ] || [ "$arch" == "aarch64" ]; then
            download_url="https://download.jetbrains.com/idea/ideaIC-${IDEA_VERSION}-aarch64.dmg"
            download_file="ideaIC-${IDEA_VERSION}-aarch64.dmg"
        else
            download_url="https://download.jetbrains.com/idea/ideaIC-${IDEA_VERSION}.dmg"
            download_file="ideaIC-${IDEA_VERSION}.dmg"
        fi
    else
        download_url="https://download.jetbrains.com/idea/ideaIC-${IDEA_VERSION}.tar.gz"
        download_file="ideaIC-${IDEA_VERSION}.tar.gz"
    fi
    
    log_info "下载 IntelliJ IDEA..."
    log_info "下载地址: $download_url"
    log_info "保存目录: $DOWNLOAD_DIR"
    
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        log_info "创建下载目录: $DOWNLOAD_DIR"
        mkdir -p "$DOWNLOAD_DIR"
    fi
    
    local target_file="$DOWNLOAD_DIR/$download_file"
    
    # 检查文件是否已存在并验证完整性
    if [ -f "$target_file" ]; then
        log_info "发现已存在的文件: $target_file"
        
        local valid=true
        if [ "$os" == "macos" ]; then
            log_info "验证 DMG 文件完整性..."
            if ! hdiutil imageinfo "$target_file" &>/dev/null; then
                log_warn "DMG 文件损坏或不完整"
                valid=false
            fi
        else
            log_info "验证压缩包完整性..."
            if ! tar -tzf "$target_file" &>/dev/null; then
                log_warn "压缩包损坏或不完整"
                valid=false
            fi
        fi
        
        if [ "$valid" == "true" ]; then
            log_info "文件验证通过，跳过下载"
            echo "$DOWNLOAD_DIR"
            return 0
        else
            log_warn "删除损坏的文件并重新下载..."
            rm -f "$target_file"
        fi
    fi
    
    # 调用统一的下载工具 adl
    if command -v adl &>/dev/null && adl --help >/dev/null 2>&1; then
        adl "$download_url" "$DOWNLOAD_DIR" "$download_file"
    else
        log_error "未找到可用 adl，请确认 adl 已加入 PATH"
        return 1
    fi
    
    echo "$DOWNLOAD_DIR"
}

# 安装IntelliJ IDEA
install_idea() {
    local os=$(detect_os)
    local arch=$(detect_arch)
    local download_file
    
    log_info "开始安装 IntelliJ IDEA..."
    
    if [ "$os" == "linux" ] && [ "$EUID" -ne 0 ]; then
        log_warn "Linux系统需要root权限安装到系统目录"
        log_warn "将尝试安装到用户目录: $HOME/.local/share/JetBrains/IntelliJIdea"
        IDEA_INSTALL_DIR="$HOME/.local/share/JetBrains/IntelliJIdea"
    fi
    
    local download_dir
    download_dir=$(download_idea) || {
        log_error "下载失败"
        return 1
    }
    
    if [ -z "$download_dir" ] || [ ! -d "$download_dir" ]; then
        log_error "无效的下载目录: $download_dir"
        return 1
    fi
    
    cd "$download_dir" || {
        log_error "无法进入下载目录: $download_dir"
        return 1
    }
    
    if [ "$os" == "macos" ]; then
        if [ "$arch" == "arm64" ] || [ "$arch" == "aarch64" ]; then
            download_file="ideaIC-${IDEA_VERSION}-aarch64.dmg"
        else
            download_file="ideaIC-${IDEA_VERSION}.dmg"
        fi
        log_info "安装到 /Applications..."
        
        # 挂载并获取挂载点
        local mount_output
        mount_output=$(hdiutil attach "$download_file" -nobrowse -readonly)
        
        local volume_path
        volume_path=$(echo "$mount_output" | grep -o "/Volumes/.*" | tail -1)
        
        if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
            log_error "无法找到挂载的 DMG 卷"
            hdiutil detach "$download_file" 2>/dev/null || true
            return 1
        fi
        
        log_info "发现挂载卷: $volume_path"
        
        local app_path=$(find "$volume_path" -maxdepth 1 -name "*.app" | head -1)
        if [ -n "$app_path" ] && [ -d "$app_path" ]; then
            cp -R "$app_path" /Applications/
        else
            log_error "未在卷中找到 IntelliJ IDEA 应用"
            ls -la "$volume_path/" 2>/dev/null || true
            hdiutil detach "$volume_path" 2>/dev/null || true
            return 1
        fi
        
        hdiutil detach "$volume_path"
    else
        download_file="ideaIC-${IDEA_VERSION}.tar.gz"
        # Linux: 解压并安装
        log_info "安装到 $IDEA_INSTALL_DIR..."
        mkdir -p "$IDEA_INSTALL_DIR"
        tar -xzf "$download_file" -C "$IDEA_INSTALL_DIR" --strip-components=1
        
        # 创建桌面快捷方式
        create_desktop_shortcut
    fi
    
    # 创建命令行启动器
    create_command_launcher
    
    log_info "IntelliJ IDEA 安装完成！"
}

# 创建桌面快捷方式
create_desktop_shortcut() {
    if [ ! -d "/usr/share/applications" ]; then
        return
    fi
    
    log_info "创建桌面快捷方式..."
    
    cat > "$IDEA_DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=IntelliJ IDEA
Comment=Capable and Ergonomic IDE for JVM
Exec=$IDEA_INSTALL_DIR/bin/idea.sh
Icon=$IDEA_INSTALL_DIR/bin/idea.png
Terminal=false
Categories=Development;IDE;
EOF
    
    chmod +x "$IDEA_DESKTOP_FILE"
}

# 创建命令行启动器
create_command_launcher() {
    local launcher_dir="/usr/local/bin"
    
    if [ ! -d "$launcher_dir" ]; then
        launcher_dir="$HOME/.local/bin"
        mkdir -p "$launcher_dir"
    fi
    
    log_info "创建命令行启动器..."
    
    cat > "$launcher_dir/idea" << 'EOF'
#!/bin/bash
if [ -f "/opt/idea/bin/idea.sh" ]; then
    /opt/idea/bin/idea.sh "$@"
elif [ -f "$HOME/.local/share/JetBrains/IntelliJIdea/bin/idea.sh" ]; then
    "$HOME/.local/share/JetBrains/IntelliJIdea/bin/idea.sh" "$@"
elif [ -d "/Applications/IntelliJ IDEA.app" ]; then
    open -a "IntelliJ IDEA" "$@"
else
    echo "IntelliJ IDEA 未安装"
    exit 1
fi
EOF
    
    chmod +x "$launcher_dir/idea"
}

# 显示使用帮助
show_help() {
    cat << EOF
IntelliJ IDEA 一键安装配置脚本

用法: $0 [选项]

选项:
  -h, --help     显示此帮助信息
  -v, --version  显示版本信息（空表示未安装）
  -i, --install  安装 IntelliJ IDEA

示例:
  $0              # 交互式安装
  $0 --version    # 检查是否已安装
  $0 --install    # 直接安装

EOF
}

# 主函数
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            ;;
        -v|--version)
            get_version
            ;;
        -i|--install|"")
            if check_installed; then
                log_warn "IntelliJ IDEA 已安装"
                echo "版本: $(get_version)"
                read -p "是否重新安装? (y/N): " reinstall
                if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
                    exit 0
                fi
            fi
            install_idea
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

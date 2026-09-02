#!/bin/bash

# Eclipse IDE 一键安装配置脚本
# 支持检测、安装、配置 Eclipse IDE

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置变量
ECLIPSE_VERSION="2024-09"
ECLIPSE_DOWNLOAD_URL="https://www.eclipse.org/downloads/download.php?file=/technology/epp/downloads/release/${ECLIPSE_VERSION}/R/eclipse-java-${ECLIPSE_VERSION}-R-linux-gtk-x86_64.tar.gz"
ECLIPSE_INSTALL_DIR="/opt/eclipse"
ECLIPSE_DESKTOP_FILE="/usr/share/applications/eclipse.desktop"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 检测Eclipse是否已安装
check_installed() {
    # 方法1: 检查eclipse命令
    if command -v eclipse &> /dev/null; then
        return 0
    fi
    
    # 方法2: 检查安装目录
    if [ -d "$ECLIPSE_INSTALL_DIR" ] && [ -f "$ECLIPSE_INSTALL_DIR/eclipse" ]; then
        return 0
    fi
    
    # 方法3: 检查是否已安装到用户目录
    local user_eclipse_dir="$HOME/eclipse"
    if [ -d "$user_eclipse_dir" ] && [ -f "$user_eclipse_dir/eclipse" ]; then
        return 0
    fi
    
    # 方法4: 检查/Applications (macOS)
    if [ -d "/Applications/Eclipse.app" ]; then
        return 0
    fi
    
    return 1
}

# 获取Eclipse版本信息
get_version() {
    if command -v eclipse &> /dev/null; then
        eclipse -version 2>&1 | head -1
    elif [ -f "$ECLIPSE_INSTALL_DIR/eclipse" ]; then
        "$ECLIPSE_INSTALL_DIR/eclipse" -version 2>&1 | head -1
    elif [ -d "/Applications/Eclipse.app" ]; then
        defaults read /Applications/Eclipse.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo ""
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
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 下载Eclipse
download_eclipse() {
    local os=$(detect_os)
    local arch=$(detect_arch)
    local download_url
    local download_file
    
    if [ "$os" == "macos" ]; then
        # macOS 架构名称映射
        local eclipse_arch="$arch"
        if [ "$arch" == "aarch64" ]; then
            eclipse_arch="aarch64"
        else
            eclipse_arch="x86_64"
        fi
        
        # 国内镜像源优化 (验证具体文件是否存在)
        local mirror_base=""
        log_info "正在探测可用的国内镜像..."
        
        # 定义待测试的镜像路径
        local rel_path="/technology/epp/downloads/release/${ECLIPSE_VERSION}/R/eclipse-java-${ECLIPSE_VERSION}-R-macosx-cocoa-${eclipse_arch}.dmg"
        
        # 尝试中科大 (USTC)
        if curl -s -I -m 3 "https://mirrors.ustc.edu.cn/eclipse${rel_path}" | grep -q "200 OK"; then
            mirror_base="https://mirrors.ustc.edu.cn/eclipse"
            log_info "发现有效镜像: 中科大 (USTC)"
        # 尝试清华 (Tsinghua)
        elif curl -s -I -m 3 "https://mirrors.tuna.tsinghua.edu.cn/eclipse${rel_path}" | grep -q "200 OK"; then
            mirror_base="https://mirrors.tuna.tsinghua.edu.cn/eclipse"
            log_info "发现有效镜像: 清华大学 (Tsinghua)"
        fi

        if [ -n "$mirror_base" ]; then
            download_url="${mirror_base}${rel_path}"
        else
            log_warn "未发现包含此版本的国内镜像，将使用官方直链 (可能需要较多跳转)..."
            # 官方直链备选
            download_url="https://www.eclipse.org/downloads/download.php?file=${rel_path}&r=1"
        fi
        download_file="eclipse-java-${ECLIPSE_VERSION}-R-macosx-cocoa-${eclipse_arch}.dmg"
    else
        download_url="https://www.eclipse.org/downloads/download.php?file=/technology/epp/downloads/release/${ECLIPSE_VERSION}/R/eclipse-java-${ECLIPSE_VERSION}-R-linux-gtk-x86_64.tar.gz"
        download_file="eclipse-java-${ECLIPSE_VERSION}-R-linux-gtk-x86_64.tar.gz"
    fi
    
    log_info "下载 Eclipse IDE..."
    log_info "下载地址: $download_url"
    log_info "保存目录: $DOWNLOAD_DIR"
    
    # 确保下载目录存在
    mkdir -p "$DOWNLOAD_DIR"
    
    local target_file="$DOWNLOAD_DIR/$download_file"
    
    # 检查文件是否已存在并验证完整性
    if [ -f "$target_file" ]; then
        log_info "发现已存在的文件: $target_file"
        
        local valid=true
        if [ "$os" == "macos" ]; then
            log_info "正在进行深度验证..."
            
            # 1. 检查文件大小 (Eclipse DMG 通常 > 100MB)
            local file_size=$(stat -f%z "$target_file" 2>/dev/null || stat -c%s "$target_file" 2>/dev/null)
            if [ -n "$file_size" ] && [ "$file_size" -lt 10000000 ]; then
                log_warn "文件大小异常 ($((file_size/1024/1024))MB)，安装包不完整"
                valid=false
            fi
            
            # 2. 检查文件类型 (防止下到 HTML 页面)
            if [ "$valid" == "true" ]; then
                local file_type=$(file -b "$target_file")
                if [[ "$file_type" == *"HTML"* ]] || [[ "$file_type" == *"text"* ]]; then
                    log_warn "文件类型错误: 检测到为 HTML/文本，而非 DMG 镜像"
                    valid=false
                fi
            fi

            # 3. 尝试进行静默挂载测试 (最可靠的验证方法)
            if [ "$valid" == "true" ]; then
                log_info "尝试进行 hdiutil verify 校验 (包含校验和)..."
                if ! hdiutil verify "$target_file" &>/dev/null; then
                    log_warn "DMG 校验和验证失败"
                    valid=false
                fi
            fi

            # 4. 模拟挂载测试
            if [ "$valid" == "true" ]; then
                log_info "尝试模拟挂载以验证文件系统..."
                # 注意：不要使用 -noverify，我们要确保它能被识别
                local test_mount
                if ! test_mount=$(hdiutil attach "$target_file" -nomount -noautoopen 2>&1); then
                    log_warn "DMG 文件系统无法识别: $test_mount"
                    valid=false
                fi
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
            log_warn "检测到损坏或无效的文件，准备处理..."
            # 如果文件损坏且不是断点续传，我们先删除它以免影响后续操作
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

# 安装Eclipse
install_eclipse() {
    local os=$(detect_os)
    local download_file
    
    log_info "开始安装 Eclipse IDE..."
    
    # 检查是否需要root权限
    if [ "$os" == "linux" ] && [ "$EUID" -ne 0 ]; then
        log_warn "Linux系统需要root权限安装到系统目录"
        log_warn "将尝试安装到用户目录: $HOME/eclipse"
        ECLIPSE_INSTALL_DIR="$HOME/eclipse"
    fi
    
    local download_dir=$(download_eclipse)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    cd "$download_dir"
    
    if [ "$os" == "macos" ]; then
        local arch=$(detect_arch)
        local eclipse_arch="$arch"
        if [ "$arch" == "aarch64" ]; then
            eclipse_arch="aarch64"
        else
            eclipse_arch="x86_64"
        fi
        download_file="eclipse-java-${ECLIPSE_VERSION}-R-macosx-cocoa-${eclipse_arch}.dmg"
        # macOS: 挂载DMG并复制到Applications
        log_info "安装到 /Applications..."
        
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
            log_error "未在卷中找到 Eclipse 应用"
            hdiutil detach "$volume_path" 2>/dev/null || true
            return 1
        fi
        
        hdiutil detach "$volume_path"
    else
        download_file="eclipse-java-${ECLIPSE_VERSION}-R-linux-gtk-x86_64.tar.gz"
        # Linux: 解压并安装
        log_info "安装到 $ECLIPSE_INSTALL_DIR..."
        mkdir -p "$ECLIPSE_INSTALL_DIR"
        tar -xzf "$download_file" -C "$ECLIPSE_INSTALL_DIR"
        
        # 创建桌面快捷方式
        create_desktop_shortcut
    fi
    
    # 创建命令行启动器
    create_command_launcher
    
    log_info "Eclipse IDE 安装完成！"
}

# 创建桌面快捷方式
create_desktop_shortcut() {
    if [ ! -d "/usr/share/applications" ]; then
        return
    fi
    
    log_info "创建桌面快捷方式..."
    
    cat > "$ECLIPSE_DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Eclipse
Comment=Eclipse IDE
Exec=$ECLIPSE_INSTALL_DIR/eclipse
Icon=$ECLIPSE_INSTALL_DIR/icon.xpm
Terminal=false
Categories=Development;IDE;
EOF
    
    chmod +x "$ECLIPSE_DESKTOP_FILE"
}

# 创建命令行启动器
create_command_launcher() {
    local launcher_dir="/usr/local/bin"
    
    if [ ! -d "$launcher_dir" ]; then
        launcher_dir="$HOME/.local/bin"
        mkdir -p "$launcher_dir"
    fi
    
    log_info "创建命令行启动器..."
    
    cat > "$launcher_dir/eclipse" << 'EOF'
#!/bin/bash
if [ -f "/opt/eclipse/eclipse" ]; then
    /opt/eclipse/eclipse "$@"
elif [ -f "$HOME/eclipse/eclipse" ]; then
    "$HOME/eclipse/eclipse" "$@"
elif [ -d "/Applications/Eclipse.app" ]; then
    open -a "Eclipse" "$@"
else
    echo "Eclipse 未安装"
    exit 1
fi
EOF
    
    chmod +x "$launcher_dir/eclipse"
}

# 显示使用帮助
show_help() {
    cat << EOF
Eclipse IDE 一键安装配置脚本

用法: $0 [选项]

选项:
  -h, --help     显示此帮助信息
  -v, --version  显示版本信息（空表示未安装）
  -i, --install  安装 Eclipse IDE

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
                log_warn "Eclipse IDE 已安装"
                echo "版本: $(get_version)"
                read -p "是否重新安装? (y/N): " reinstall
                if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
                    exit 0
                fi
            fi
            install_eclipse
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

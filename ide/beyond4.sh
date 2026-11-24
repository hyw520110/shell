#!/bin/bash
# beyond4.sh - Beyond Compare 4 破解脚本
# 用途: 移除Beyond Compare 4的试用限制
# 参数: 无

set -e

# 错误处理函数
error_exit() {
    echo_error "$1"
    exit 1
}

# 全局变量定义
BCOMPARE_VERSION="4.4.7.28397"
LINUX_DOWNLOAD_URL="https://www.scootersoftware.com/files/bcompare-${BCOMPARE_VERSION}_amd64.deb"
MACOS_DOWNLOAD_URL="https://www.scootersoftware.com/files/BCompareOSX-${BCOMPARE_VERSION}.zip"
LINUX_FILE_NAME="bcompare-${BCOMPARE_VERSION}_amd64.deb"
MACOS_FILE_NAME="BCompareOSX-${BCOMPARE_VERSION}.zip"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
# KEEP_PACKAGE=1 时安装成功后保留安装包，默认安装成功即删除
KEEP_PACKAGE="${KEEP_PACKAGE:-0}"
BCOMPARE_EXE="BCompare"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否以root权限运行
is_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# 使用sudo执行命令
exec_sudo() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# 统一安全删除安装包：只允许删除明确指向安装包的绝对路径。
# 防止 $VAR 为空时 rm -rf 展开成 rm -rf /Applications/ 之类事故（曾发生过）。
# 调用方必须传入已确定非空的完整文件路径，禁止裸写 rm -rf "$VAR"。
safe_rm_file() {
    local path="$1"
    [ -z "$path" ] && { echo_warn "safe_rm_file: 路径为空，跳过删除"; return 0; }
    case "$path" in
        /*) : ;;
        *) echo_warn "safe_rm_file: 非绝对路径，跳过: $path"; return 0 ;;
    esac
    case "$path" in
        /|/tmp|/var|/var/folders|/Users|/Applications|/etc|/usr|/bin|/sbin|/System|/Library)
            echo_warn "safe_rm_file: 拒绝删除受保护目录: $path"; return 0 ;;
    esac
    [ -d "$path" ] && [ ! -f "$path" ] && { echo_warn "safe_rm_file: 目标是目录，跳过: $path"; return 0; }
    if rm -f -- "$path" "$path.url" 2>/dev/null; then
        echo_info "已删除安装包: $path"
    else
        echo_warn "安装包清理失败(可忽略): $path"
    fi
}

# Beyond Compare 安装检测：.app 存在且其可执行文件真实可读，避免断裂符号链接造成假阳性
check_bcompare_installed() {
    local app="/Applications/Beyond Compare.app"
    if [ ! -d "$app" ]; then
        return 1
    fi
    local exe
    exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null)
    [ -z "$exe" ] && return 1
    [ -x "$app/Contents/MacOS/$exe" ]
}

# macOS 自动安装：解压 zip 内 dmg -> 挂载 -> 拷 .app 到 /Applications
install_bcompare_macos() {
    local zip_file="$1"
    [ -f "$zip_file" ] || { echo_error "未找到安装包: $zip_file"; return 1; }

    echo_step "正在安装 Beyond Compare 4 (macOS) ..."
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/bcompare.XXXXXX") || { echo_error "无法创建临时目录"; return 1; }

    echo_info "解压: $zip_file"
    unzip -q -o "$zip_file" -d "$work" || { echo_error "解压失败"; return 1; }

    local dmg app_src volume_path mount_output
    dmg=$(find "$work" -maxdepth 1 -iname "*.dmg" | head -1)

    # 官方 macOS 包（BCompareOSX-<ver>.zip）直接包含 Beyond Compare.app，无 dmg。
    # 兼容两种形态：zip 内有 dmg（挂载后取 .app）或 zip 内直接是 .app。
    if [ -z "$dmg" ] || [ ! -f "$dmg" ]; then
        app_src=$(find "$work" -maxdepth 1 -iname "*.app" -type d | head -1)
        if [ -z "$app_src" ] || [ ! -d "$app_src" ]; then
            echo_error "未在安装包中找到 dmg 或 .app: $zip_file"
            return 1
        fi
        echo_info "安装包为目录形式（.app），直接安装"
        if ! install_app_to_applications "$app_src"; then
            echo_error "安装到 /Applications 失败"
            return 1
        fi
        echo_info "Beyond Compare 4 安装完成: /Applications/Beyond Compare.app"
        return 0
    fi

    mount_output=$(hdiutil attach "$dmg" -nobrowse -readonly) || { echo_error "挂载 dmg 失败"; return 1; }
    volume_path=$(printf '%s\n' "$mount_output" | grep -o "/Volumes/.*" | tail -1)
    if [ -z "$volume_path" ] || [ ! -d "$volume_path" ]; then
        echo_error "无法找到挂载卷"
        hdiutil detach "$dmg" 2>/dev/null || true
        return 1
    fi

    local app_src
    app_src=$(find "$volume_path" -maxdepth 1 -iname "BCompare*.app" | head -1)
    if [ -z "$app_src" ] || [ ! -d "$app_src" ]; then
        echo_error "挂载卷中未找到 BCompare.app: $volume_path"
        hdiutil detach "$volume_path" 2>/dev/null || true
        return 1
    fi

    echo_info "复制 $(basename "$app_src") -> /Applications ..."
    if ! install_app_to_applications "$app_src"; then
        hdiutil detach "$volume_path" 2>/dev/null || true
        echo_error "安装到 /Applications 失败"
        return 1
    fi

    hdiutil detach "$volume_path" 2>/dev/null || true
    echo_info "Beyond Compare 4 安装完成: /Applications/Beyond Compare.app"
}

# 把 .app 安全安装进 /Applications：只删精确匹配的 Beyond Compare 包，防止误删其他 app
install_app_to_applications() {
    local src="$1"
    local old="/Applications/Beyond Compare.app"
    if [ -d "$old" ]; then
        echo_info "先退出正在运行的 Beyond Compare ..."
        osascript -e 'tell application "Beyond Compare" to quit' 2>/dev/null || true
        sleep 1
        echo_info "替换旧版本: $old"
        if ! mv "$old" "${TMPDIR:-/tmp}/BeyondCompare.old.$$" 2>/dev/null; then
            if ! exec_sudo mv "$old" "${TMPDIR:-/tmp}/BeyondCompare.old.$$"; then
                echo_error "无法移除旧版本: $old"
                return 1
            fi
        fi
    fi
    if ! cp -R "$src" /Applications/ 2>/dev/null; then
        if ! exec_sudo cp -R "$src" /Applications/; then
            echo_error "复制应用失败: $src"
            return 1
        fi
    fi
    # 清理旧版本副本
    rm -rf "${TMPDIR:-/tmp}/BeyondCompare.old.$$" 2>/dev/null || true
    return 0
}

# 通用下载函数（支持断点续传；存在 adl 时优先调用，回退 aria2c / wget / curl）
download_file() {
    local url="$1"
    local dest="$2"

    if [ -z "$url" ] || [ -z "$dest" ]; then
        echo_error "下载函数需要URL和目标路径参数"
        return 1
    fi

    # 确保下载目录存在
    local download_dir=$(dirname "$dest")
    if [ ! -d "$download_dir" ]; then
        mkdir -p "$download_dir"
    fi

    echo_info "正在下载 $url 到 $dest"

    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        # adl（Aria2 Downloader）：自带代理自动探测与断点续传
        echo_info "使用 adl 加速下载..."
        if adl "$url" "$download_dir" "$(basename "$dest")"; then
            return 0
        else
            echo_warn "adl 下载失败，回退到其他下载器"
        fi
    elif command -v aria2c >/dev/null 2>&1; then
        # 使用 aria2c 进行多线程下载
        echo_info "使用 aria2c 进行多线程下载..."
        aria2c -x 8 -s 8 -c --file-allocation=none -o "$(basename "$dest")" -d "$download_dir" "$url"
    elif command -v wget >/dev/null 2>&1; then
        # 使用 wget 进行断点续传下载
        echo_info "使用 wget 进行断点续传下载..."
        wget -c --tries=5 --timeout=30 -O "$dest" "$url"
    elif command -v curl >/dev/null 2>&1; then
        # 使用 curl 进行断点续传下载
        echo_info "使用 curl 进行断点续传下载..."
        curl -L -C - -o "$dest" "$url"
    else
        echo_error "系统中没有找到 aria2c, wget 或 curl，无法下载文件"
        echo_info "建议安装下载工具: sudo apt install aria2 wget curl"
        return 1
    fi
    
    return $?
}

# 检测操作系统
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux"* ]]; then
        echo "linux"
    else
        # 如果无法通过OSTYPE确定，尝试使用其他方法
        if [ -f /usr/bin/sw_vers ]; then
            echo "macos"
        elif [ -f /etc/os-release ] || [ -f /etc/debian_version ] || [ -f /etc/redhat-release ]; then
            echo "linux"
        else
            # 默认假设为linux
            echo "linux"
        fi
    fi
}

# 检查文件是否已存在且完整
check_file_exists() {
    local file_path="$1"
    local expected_size="$2"
    
    if [ ! -f "$file_path" ]; then
        return 1
    fi
    
    # 如果没有提供期望大小，则认为文件存在即可
    if [ -z "$expected_size" ]; then
        return 0
    fi
    
    local actual_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [ "$actual_size" -ge "$expected_size" ]; then
        return 0
    else
        echo_info "文件大小不匹配，需重新下载"
        return 1
    fi
}

# 下载Beyond Compare
download_bcompare() {
    local os_type=$(detect_os)
    echo_step "正在下载 Beyond Compare 4 ..."
    
    # 确保下载目录存在
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR="/tmp"
    fi
    
    if [ "$os_type" = "macos" ]; then
        # macOS 下载 + 自动安装
        local download_url="$MACOS_DOWNLOAD_URL"
        local zip_file="$DOWNLOAD_DIR/$MACOS_FILE_NAME"

        # 检查文件是否已存在且完整
        if check_file_exists "$zip_file"; then
            echo_info "文件已存在且完整: $zip_file"
        else
            echo_info "下载地址: $download_url"
            echo_info "下载到: $zip_file"

            if download_file "$download_url" "$zip_file"; then
                echo_info "下载完成: $zip_file"
            else
                echo_error "下载失败"
                exit 1
            fi
        fi

        # macOS：自动安装（解压 dmg -> 挂载 -> 拷 .app 到 /Applications）
        if ! install_bcompare_macos "$zip_file"; then
            echo_error "Beyond Compare 4 安装失败"
            exit 1
        fi
        # 默认安装成功即删除安装包；KEEP_PACKAGE=1 时保留
        if [ "$KEEP_PACKAGE" != "1" ]; then
            safe_rm_file "$zip_file"
        fi
        return 0
    else
        # Linux 下载 (默认)
        local download_url="$LINUX_DOWNLOAD_URL"
        local deb_file="$DOWNLOAD_DIR/$LINUX_FILE_NAME"
        
        # 检查文件是否已存在且完整
        if check_file_exists "$deb_file"; then
            echo_info "文件已存在且完整: $deb_file"
        else
            echo_info "下载地址: $download_url"
            echo_info "下载到: $deb_file"
            
            if download_file "$download_url" "$deb_file"; then
                echo_info "下载完成: $deb_file"
            else
                echo_error "下载失败"
                exit 1
            fi
        fi
        
        echo_info "正在安装 Beyond Compare 4 ..."
        exec_sudo dpkg -i "$deb_file"
        if [ $? -ne 0 ]; then
            echo_warn "dpkg 安装失败，尝试使用 apt 安装依赖 ..."
            exec_sudo apt-get install -f -y
        fi
        echo_info "安装完成，请重新运行此脚本来破解软件。"
    fi
}

# 查找BCompare文件位置
find_bcompare_dir() {
    local dir=""
    
    # macOS：Beyond Compare.app 内的可执行文件目录
    local os_type=$(detect_os)
    if [ "$os_type" = "macos" ] && [ -d "/Applications/Beyond Compare.app" ]; then
        local bcompare_exe
        bcompare_exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "/Applications/Beyond Compare.app/Contents/Info.plist" 2>/dev/null)
        if [ -n "$bcompare_exe" ] && [ -f "/Applications/Beyond Compare.app/Contents/MacOS/$bcompare_exe" ]; then
            echo "/Applications/Beyond Compare.app/Contents/MacOS"
            return 0
        fi
    fi

    # 常见安装路径
    local paths=(
        "/usr/lib/beyondcompare"
        "/opt/apps/com.scootersoftware.bcompare/files/lib64/beyondcompare"
        "/opt/apps/com.scootersoftware.bcompare/files"
        "/opt/BeyondCompare"
        "/usr/bin"
        "/usr/local/bin"
        "/opt/local/bin"
    )
    
    for path in "${paths[@]}"; do
        # 检查BCompare可执行文件
        local bcompare_path="$path/BCompare"
        if [ -f "$bcompare_path" ]; then
            echo "$path"
            return 0
        fi
        
        # 有些安装可能文件名为bcompare(小写)
        bcompare_path="$path/bcompare"
        if [ -f "$bcompare_path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # 如果在常见路径中未找到，也在常用目录中查找（不进行全盘搜索）
    echo_info "在常见路径中未找到 BCompare，正在常用目录中搜索..."
    for search_dir in /usr /opt /usr/local /opt/local; do
        if [ -d "$search_dir" ]; then
            local found_path=$(find "$search_dir" -name "BCompare" -type f 2>/dev/null | head -1)
            if [ -n "$found_path" ] && [ -f "$found_path" ]; then
                dir=$(dirname "$found_path")
                if [ -n "$dir" ] && [ -d "$dir" ]; then
                    echo "$dir"
                    return 0
                fi
            fi
        fi
    done
    
    echo_error "未在常见路径中找到 BCompare 文件"
    return 1
}

# 卸载Beyond Compare (如意玲珑应用)
uninstall_bcompare() {
    echo_step "正在卸载 Beyond Compare ..."
    
    # 检查是否为如意玲珑应用
    if [ -d "/var/lib/linglong/layers" ]; then
        echo_info "检测到如意玲珑环境"
        # 查找Beyond Compare的如意玲珑包
        local ll_apps=$(find /var/lib/linglong/layers -path "*/com.scootersoftware.bcompare/*" 2>/dev/null | head -1)
        if [ -n "$ll_apps" ]; then
            local pkg_name=$(echo "$ll_apps" | grep -o "com.scootersoftware.bcompare[^/]*")
            if [ -n "$pkg_name" ] && command -v ll-cli >/dev/null 2>&1; then
                echo_info "使用 ll-cli 卸载 $pkg_name ..."
                if exec_sudo ll-cli uninstall "$pkg_name"; then
                    echo_info "如意玲珑应用 $pkg_name 已卸载"
                else
                    echo_warn "如意玲珑卸载命令执行失败"
                fi
            else
                echo_info "找到如意玲珑包路径: $ll_apps"
                echo_info "使用命令: ll-cli uninstall com.scootersoftware.bcompare 卸载"
            fi
        fi
    fi
    
    # 删除可能的安装目录
    local possible_paths=(
        "/opt/apps/com.scootersoftware.bcompare"
        "/usr/lib/beyondcompare"
        "/opt/BeyondCompare"
    )
    
    for path in "${possible_paths[@]}"; do
        if [ -d "$path" ]; then
            echo_info "删除目录: $path"
            exec_sudo rm -rf "$path"
        fi
    done
    
    # 删除系统配置
    if [ -d ~/.config/bcompare ]; then
        echo_info "删除用户配置: ~/.config/bcompare"
        rm -rf ~/.config/bcompare
    fi
    
    if [ -d ~/.config/bcomapre ]; then
        echo_info "删除用户配置: ~/.config/bcomapre"
        rm -rf ~/.config/bcomapre
    fi
    
    # 删除系统级配置
    if [ -d /etc/bcompare ]; then
        echo_info "删除系统配置: /etc/bcompare"
        exec_sudo rm -rf /etc/bcompare
    fi
    
    echo_info "卸载完成"
}

# 主函数
main() {
    
    # 检查是否有卸载参数
    if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
        uninstall_bcompare
        exit 0
    fi

    # 安装状态检测：--check / -c
    if [ "$1" = "--check" ] || [ "$1" = "-c" ]; then
        if check_bcompare_installed; then
            echo_info "Beyond Compare 已安装: /Applications/Beyond Compare.app"
            exit 0
        else
            echo_error "Beyond Compare 未安装（或可执行文件缺失，可能为断裂符号链接）"
            exit 1
        fi
    fi

    # 显式安装：--install / -i，未安装时自动下载并安装
    if [ "$1" = "--install" ] || [ "$1" = "-i" ] || [ "$1" = "--check-install" ]; then
        if check_bcompare_installed; then
            echo_info "Beyond Compare 已安装: /Applications/Beyond Compare.app"
            # 已安装则无需下载，直接进入破解流程
        else
            echo_warn "Beyond Compare 未安装，开始下载并自动安装 ..."
            download_bcompare
            if ! check_bcompare_installed; then
                echo_error "自动安装后仍未检测到 Beyond Compare，请手动检查"
                exit 1
            fi
        fi
        # 继续进入破解流程（下面原有的步骤1）
    fi

    # 步骤1: 修改BCompare文件
    echo_step "步骤1: 修改BCompare文件"
    
    # 删除注册表数据
    if [ -d ~/.config/bcomapre ]; then
        if ! rm -rf ~/.config/bcomapre; then
            echo_warn "无法删除 ~/.config/bcomapre 目录"
        fi
    fi
    
    # 查找BCompare文件位置
    dir=""
    if ! dir=$(find_bcompare_dir); then
        # 如果没找到目录，开始下载并自动安装
        download_bcompare
        # 下载完成后重新查找目录
        if ! dir=$(find_bcompare_dir); then
            error_exit "下载后仍未找到 BCompare 目录"
        fi
    fi
    
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        download_bcompare
        # 重新查找目录
        if ! dir=$(find_bcompare_dir); then
            error_exit "下载后仍未找到 BCompare 目录"
        fi
    fi

    echo_info "BCompare 目录: $dir"
    
    # 检查BCompare文件是否存在
    if [ ! -f "$dir/BCompare" ]; then
        # 检查小写名称
        if [ -f "$dir/bcompare" ]; then
            # 更新文件名
            BCOMPARE_EXE="bcompare"
        else
            error_exit "未找到 BCompare 文件 ( neither BCompare nor bcompare found in $dir )"
        fi
    else
        BCOMPARE_EXE="BCompare"
    fi
    
    # 备份原文件
    echo_info "备份 BCompare 文件..."
    if ! exec_sudo cp "$dir/$BCOMPARE_EXE" "$dir/${BCOMPARE_EXE}.backup"; then
        error_exit "无法备份 BCompare 文件"
    fi
    
    # 修改文件
    echo_info "执行sed命令修改 BCompare 文件..."
    exec_sudo sed -i "s/keexjEP3t4Mue23hrnuPtY4TdcsqNiJL-5174TsUdLmJSIXKfG2NGPwBL6vnRPddT7tH29qpkneX63DO9ECSPE9rzY1zhThHERg8lHM9IBFT+rVuiY823aQJuqzxCKIE1bcDqM4wgW01FH6oCBP1G4ub01xmb4BGSUG6ZrjxWHJyNLyIlGvOhoY2HAYzEtzYGwxFZn2JZ66o4RONkXjX0DF9EzsdUef3UAS+JQ+fCYReLawdjEe6tXCv88GKaaPKWxCeaUL9PejICQgRQOLGOZtZQkLgAelrOtehxz5ANOOqCaJgy2mJLQVLM5SJ9Dli909c5ybvEhVmIC0dc9dWH+/N9KmiLVlKMU7RJqnE+WXEEPI1SgglmfmLc1yVH7dqBb9ehOoKG9UE+HAE1YvH1XX2XVGeEqYUY-Tsk7YBTz0WpSpoYyPgx6Iki5KLtQ5G-aKP9eysnkuOAkrvHU8bLbGtZteGwJarev03PhfCioJL4OSqsmQGEvDbHFEbNl1qJtdwEriR+VNZts9vNNLk7UGfeNwIiqpxjk4Mn09nmSd8FhM4ifvcaIbNCRoMPGl6KU12iseSe+w+1kFsLhX+OhQM8WXcWV10cGqBzQE9OqOLUcg9n0krrR3KrohstS9smTwEx9olyLYppvC0p5i7dAx2deWvM1ZxKNs0BvcXGukR+/g" "$dir/BCompare"

    # 步骤2: 创建密钥文件
    echo_step "步骤2: 创建密钥文件"
    echo_info "创建BC4Key.txt密钥文件..."
    
    # 创建密钥内容
    if ! cat > /tmp/BC4Key.txt << 'EOF'
GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++
EOF
    then
        error_exit "创建密钥文件失败"
    fi
    
    # 确保配置目录存在
    #[ ! -d ~/.config/bcompare ] && mkdir -p ~/.config/bcompare
    # 复制密钥文件到用户配置目录
    #cp /tmp/BC4Key.txt ~/.config/bcompare/BC4Key.txt
    
    # 步骤3: 为所有用户注册bcompare命令
    echo_step "步骤3: 为所有用户注册bcompare命令"
    echo_info "复制密钥文件到系统目录..."
    if [ ! -d /etc/bcompare/ ]; then
        if ! exec_sudo mkdir -p /etc/bcompare/; then
            error_exit "无法创建 /etc/bcompare/ 目录"
        fi
    fi
    if [ -d /etc/bcompare/ ]; then
        if ! exec_sudo cp /tmp/BC4Key.txt /etc/bcompare/; then
            error_exit "无法复制密钥文件到 /etc/bcompare/"
        fi
    fi
    
    # 清理临时文件
    if [ -f /tmp/BC4Key.txt ]; then
        rm -f /tmp/BC4Key.txt
    fi
    
    echo_info "Beyond Compare 4 破解完成！"
    echo_info "请按以下步骤完成激活："
    echo_info "1. 打开 Beyond Compare 4"
    echo_info "2. 密钥输入界面，输入以下密钥："
    echo_info "   GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++"
    echo_info "3. 如果程序正在运行，请重启使更改生效。"
}

# 帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help        显示帮助信息"
    echo "  -u, --uninstall   卸载 Beyond Compare"
    echo "  -i, --install     安装 Beyond Compare（未安装时自动下载并安装；已安装则直接破解）"
    echo "  -c, --check       检测 Beyond Compare 是否已安装（exit 0=已装, 1=未装）"
    echo ""
    echo "说明:"
    echo "  此脚本用于安装 + 移除 Beyond Compare 4 的试用限制"
    echo "  脚本将按照以下步骤执行："
    echo "    0. 未安装时自动下载并安装（macOS: 解压 dmg -> 挂载 -> 拷 .app；Linux: dpkg）"
    echo "    1. 修改 BCompare 文件"
    echo "    2. 创建密钥文件 ~/.config/bcompare/BC4Key.txt"
    echo "    3. 复制密钥文件到系统目录 /etc/bcompare/"
    echo ""
    echo "注意:"
    echo "  1. 此脚本可能需要 sudo 权限"
    echo "  2. 安装包默认下载到 ~/Downloads 并在安装成功后删除（设置 KEEP_PACKAGE=1 可保留）"
    echo "  3. 下载优先使用 adl（存在时），回退 aria2c / wget / curl"
    echo "  4. 完成后需要在软件界面输入密钥"
    echo "  5. 如需卸载软件，使用 --uninstall 选项"
}

# 参数处理
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    -u|--uninstall)
        main "$1"
        ;;
    -c|--check)
        main "$1"
        ;;
    -i|--install)
        main "$1"
        ;;
    "")
        main
        ;;
    *)
        echo_error "未知参数: $1"
        echo "使用 $0 --help 查看帮助信息"
        exit 1
        ;;
esac
